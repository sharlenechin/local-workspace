-- ============================================================================
-- PLATINUM. Loan-level collections rolled to the month. One row per
-- (CASE_SK, REPORTING_MONTH, CURRENCY_ID), in both euro and local currency.
-- GRAIN: reporting_month is MONTH-START. PROD.
-- ============================================================================
-- Join to dim_portfolio_case on CASE_SK for the book, the seller and the drill
-- path. PORTFOLIO_SK is carried here too, so the common case needs no join.
--
-- ⚠⚠ THIS IS THE LOAN FEED, AND IT IS NOT THE WHOLE BOOK. It covers roughly
-- half of what the servicer's portfolio report shows in euro: some portfolios
-- arrive as portfolio-level aggregates with no loan detail at all. Reconciling
-- this against agg_portfolio_collection_monthly is expected to show a gap on
-- those books -- that is an absence of detail, not missing money.
--
-- ⚠⚠ CURRENCY IS IN THE GRAIN, so one row carries exactly one currency and its
-- rate applies cleanly. NEVER SUM COLLECTIONS_LOCAL_CURRENCY across rows of
-- different currency; the warehouse carries six.
--
-- ⚠⚠ RATE_FLOW, NOT RATE_STOCK. A collection is a flow.
-- ⚠ THE FX JOIN USES MONTH-END WHILE THE OUTPUT IS MONTH-START. Deliberate --
-- FCT_EXCHANGE_RATE_MONTHLY is keyed on the last day of the month. "Aligning"
-- them matches nothing, silently, and every euro figure comes back NULL.
--
-- ⚠⚠ COLLECTION DATES IN THE YEAR 4570 EXIST IN THIS WAREHOUSE. Bounded to
-- CURRENT_DATE() below. Without it the month spine runs to the 46th century.
--
-- ⚠ THE CURRENT MONTH IS EXCLUDED. A part-month reads as a collapse in
-- collections against a full one. The newest month returned is always complete.
--
-- ⚠ CASE_SK IS A VERSION KEY. The fact carries the version in force at the
-- collection, which is correct and point-in-time. To count LOANS, join to
-- dim_portfolio_case and count DISTINCT CASE_BK -- counting CASE_SK counts one
-- loan once per version it has had.
-- ============================================================================
WITH fx_rates AS (
    -- ⚠ 'EUR', UPPERCASE, IS THE LITERAL IN BOTH TABLES.
    SELECT
        quote_currency                                 AS currency_id,
        date_day                                       AS month_end,
        monthly_avg                                    AS rate_flow
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR'
      AND rate_type = 'PMI'
      AND quote_currency <> 'EUR'

    UNION ALL

    -- ⚠ EUR IS NOT A CONVERSION -- rate 1 -- so it must not depend on the FX
    -- table's coverage. Spine is the portfolio fact's own months.
    SELECT DISTINCT
        'EUR',
        period_end_date,
        1
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

case_collection_monthly AS (
    -- The ONLY read of the 134m-row collection fact.
    SELECT
        c.case_sk,
        c.portfolio_sk,
        DATE_TRUNC('MONTH', c.collection_date)::DATE   AS reporting_month,
        c.currency_id,
        SUM(c.amount)                                  AS collections_local_currency,
        COUNT(*)                                       AS collection_count,
        MIN(c.collection_date)                         AS first_collection_date,
        MAX(c.collection_date)                         AS last_collection_date
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
    -- ⚠ BOTH BOUNDS MATTER. See the header: 4570 dates, and part-months.
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
    GROUP BY 1, 2, 3, 4
)

SELECT
    -- ---- keys -------------------------------------------------------------
    c.case_sk,
    -- Carried so the common "collections by book" question needs no join.
    c.portfolio_sk,
    c.reporting_month,
    YEAR(c.reporting_month)                            AS reporting_year,
    c.currency_id,

    -- ---- local currency. ⚠ ONLY SUM WITHIN ONE CURRENCY. ------------------
    c.collections_local_currency,

    -- ---- euro. Safe to sum across anything. -------------------------------
    c.collections_local_currency * fx.rate_flow        AS collections_eur,
    fx.rate_flow,

    -- ---- how the month was made up ----------------------------------------
    c.collection_count,
    c.first_collection_date,
    c.last_collection_date,

    -- ⚠ FALSE means no rate for that currency-month, so COLLECTIONS_EUR is
    -- NULL. Filter before quoting a euro total.
    fx.rate_flow IS NOT NULL                           AS has_fx_flag
FROM case_collection_monthly AS c
-- ⚠ THE CONVERSION. Month-END key, month-START output -- see the header.
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = c.currency_id
    AND fx.month_end = LAST_DAY(c.reporting_month)
