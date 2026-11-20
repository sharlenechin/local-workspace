-- ============================================================================
-- PLATINUM. All three forecasts, one row per (PORTFOLIO_SK, REPORTING_MONTH,
-- CURRENCY_ID). Every amount in BOTH euro and the book's own currency.
-- GRAIN: reporting_month is MONTH-START. PROD.
-- ============================================================================
-- THE THREE FORECASTS ANSWER DIFFERENT QUESTIONS. Never average or swap them:
--   UNDERWRITING  what we assumed when we BOUGHT. Frozen, one vintage.
--                 The benchmark for "was the purchase a good one?"
--   ACCOUNTING    our CURRENT view, revised as we learn. THE ONE FINANCE
--                 TRACKS in flash and revaluations.
--   SERVICER      the servicer's own projection. Answers "is the servicer
--                 hitting the plan?" and nothing else.
-- ⚠ ACCOUNTING IS BORN AS A COPY OF UNDERWRITING -- 91.3% of portfolio-months
-- are still identical. Where they differ, WE have marked the book.
--
-- ⚠⚠ CURRENCY IS IN THE GRAIN ON PURPOSE. It is what lets one row carry both
-- its local figure and its euro figure honestly: the rate applies to a row that
-- has exactly one currency. Summing to portfolio-month is the CONSUMER'S job,
-- and only the _EUR columns may be summed across currencies.
-- ⚠⚠ NEVER SUM A _LOCAL_CURRENCY COLUMN ACROSS ROWS OF DIFFERENT CURRENCY.
-- The warehouse carries six (SEK, EUR, PLN, DKK, CHF, GBP).
--
-- ⚠⚠ THE FORECAST FACTS ARE NOT DEDUPED UPSTREAM, unlike the portfolio
-- snapshot. Each revision is a new SNAPSHOT_VERSION, so without the QUALIFY
-- every restatement is counted again. VERSION_COUNT records how many existed.
-- ⚠ DO NOT SUM VERSION_COUNT. It is a count of revisions, not of anything real.
--
-- ⚠⚠ RATE_FLOW, NOT RATE_STOCK. A forecast is a flow -- money expected to
-- arrive DURING the month -- so it takes the monthly average, not the month-end
-- close. The two differ by 0.87% on average for SEK and up to 1.70% in a single
-- month, so this is a real choice and not a rounding one.
--
-- ⚠⚠ THE FX JOIN USES MONTH-END WHILE THE OUTPUT IS MONTH-START. That is
-- deliberate, not an inconsistency: FCT_EXCHANGE_RATE_MONTHLY is keyed on the
-- last day of the month. "Aligning" them matches nothing, silently, and every
-- euro column comes back NULL.
--
-- ⚠ HISTORICAL ONLY. Bounded to CURRENT_DATE(), so forward projection months
-- are not returned. A forward view needs a different query.
--
-- ⚠ A ROW WITH NO RATE KEEPS A NULL EURO FIGURE rather than being dropped.
-- HAS_FX_FLAG says which. Filter on it before quoting a euro total.
-- ============================================================================
WITH fx_rates AS (
    -- ⚠ 'EUR', UPPERCASE, IS THE LITERAL IN BOTH TABLES. Lower-case matches
    -- nothing and silently empties this CTE, and with it every euro column.
    SELECT
        quote_currency                                 AS currency_id,
        date_day                                       AS month_end,
        monthly_avg                                    AS rate_flow
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR'
      AND rate_type = 'PMI'
      AND quote_currency <> 'EUR'

    UNION ALL

    -- ⚠ EUR IS NOT A CONVERSION -- rate 1 -- so this leg must not depend on the
    -- FX table, which only starts 2018-01-31. Spine is the fact's own months.
    SELECT DISTINCT
        'EUR',
        period_end_date,
        1
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

servicer_forecast AS (
    -- ⚠ THE SUBQUERY IS NOT DECORATION. QUALIFY runs after GROUP BY, so
    -- snapshot_version has to be filtered before the rows are aggregated.
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast)                 AS forecast_local_currency,
        MAX(version_count)                             AS version_count
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.gross_collection_forecast,
            COUNT(DISTINCT f.snapshot_version) OVER (
                PARTITION BY f.portfolio_sk, f.period_end_date
            )                                          AS version_count
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

accounting_forecast AS (
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast)                 AS forecast_local_currency,
        MAX(version_count)                             AS version_count
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.gross_collection_forecast,
            COUNT(DISTINCT f.snapshot_version) OVER (
                PARTITION BY f.portfolio_sk, f.period_end_date
            )                                          AS version_count
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

underwriting_forecast AS (
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast)                 AS forecast_local_currency,
        MAX(version_count)                             AS version_count
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.gross_collection_forecast,
            COUNT(DISTINCT f.snapshot_version) OVER (
                PARTITION BY f.portfolio_sk, f.period_end_date
            )                                          AS version_count
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

forecast_spine AS (
    -- UNION, not UNION ALL: a portfolio-month-currency that one forecast knows
    -- about and another does not still gets exactly one row.
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id
    FROM servicer_forecast

    UNION

    SELECT
        portfolio_sk,
        period_end_date,
        currency_id
    FROM accounting_forecast

    UNION

    SELECT
        portfolio_sk,
        period_end_date,
        currency_id
    FROM underwriting_forecast
)

SELECT
    -- ---- keys -------------------------------------------------------------
    s.portfolio_sk,
    DATE_TRUNC('MONTH', s.period_end_date)::DATE       AS reporting_month,
    YEAR(s.period_end_date)                            AS reporting_year,
    s.currency_id,

    -- ---- local currency. ⚠ ONLY SUM WITHIN ONE CURRENCY. ------------------
    sf.forecast_local_currency                         AS servicer_forecast_local_currency,
    af.forecast_local_currency                         AS accounting_forecast_local_currency,
    uf.forecast_local_currency                         AS underwriting_forecast_local_currency,

    -- ---- euro. Safe to sum across anything. -------------------------------
    sf.forecast_local_currency * fx.rate_flow          AS servicer_forecast_eur,
    af.forecast_local_currency * fx.rate_flow          AS accounting_forecast_eur,
    uf.forecast_local_currency * fx.rate_flow          AS underwriting_forecast_eur,
    fx.rate_flow,

    -- ---- how many revisions existed. ⚠ MAX, NEVER SUM. --------------------
    sf.version_count                                   AS servicer_forecast_version_count,
    af.version_count                                   AS accounting_forecast_version_count,
    uf.version_count                                   AS underwriting_forecast_version_count,

    -- ---- flags -------------------------------------------------------------
    sf.forecast_local_currency IS NOT NULL             AS have_servicer_forecast_flag,
    af.forecast_local_currency IS NOT NULL             AS have_accounting_forecast_flag,
    uf.forecast_local_currency IS NOT NULL             AS have_underwriting_forecast_flag,
    -- ⚠ FALSE means no rate for that currency-month, so the euro columns above
    -- are NULL. Filter before quoting a euro total.
    fx.rate_flow IS NOT NULL                           AS has_fx_flag
FROM forecast_spine AS s
LEFT JOIN servicer_forecast AS sf
    ON sf.portfolio_sk = s.portfolio_sk
    AND sf.period_end_date = s.period_end_date
    AND sf.currency_id = s.currency_id
LEFT JOIN accounting_forecast AS af
    ON af.portfolio_sk = s.portfolio_sk
    AND af.period_end_date = s.period_end_date
    AND af.currency_id = s.currency_id
LEFT JOIN underwriting_forecast AS uf
    ON uf.portfolio_sk = s.portfolio_sk
    AND uf.period_end_date = s.period_end_date
    AND uf.currency_id = s.currency_id
-- ⚠ THE CONVERSION. Month-END key, month-START output -- see the header.
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = s.currency_id
    AND fx.month_end = s.period_end_date
