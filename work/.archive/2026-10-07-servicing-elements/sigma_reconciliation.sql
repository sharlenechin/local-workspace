-- ============================================================================
-- SIGMA ELEMENT 'Reconciliation'. ONE ROW PER (PORTFOLIO_SK, REPORTING_MONTH).
-- Does the case-by-case feed agree with the servicer's own portfolio report?
-- ============================================================================
-- GRAIN     portfolio x month, driven from the PORTFOLIO side so a book with no
--           case detail still gets a row. reporting_month is MONTH-END.
--
-- ⚠⚠⚠ THE COMPARISON IS IN EUR, AND THAT IS THE WHOLE POINT OF THIS ELEMENT.
-- It used to be done in dbt in local currency. That is meaningless where a
-- portfolio-month carries two currencies, and it is not hypothetical:
-- HEI-PL25001-U02/2512 carries PLN + CHF and HEI-PL25001-S01/2512 carries
-- PLN + EUR + CHF, every month. Summing those gives a number that is not money.
-- ⚠ The old is_multi_currency_flag could not catch it either -- it came from
-- the PORTFOLIO side, which reads one currency for both books, while the
-- collisions are on the CASE side.
--
-- ⚠⚠ MULTIPLY BEFORE YOU SUM. The case leg converts each currency's own total
-- and sums the converted amounts. Summing locals first and multiplying after
-- applies one currency's rate to a mixed total.
--
-- ⚠⚠ A MISSING RATE MAKES A SIDE SHORT, NOT ABSENT, which reads as a mismatch.
-- case_currencies_without_rate counts them -- a non-zero value there means the
-- comparison on that row is not trustworthy, whatever the percentage says.
--
-- ⚠ MEASURED 2026-10-05, the case leg converts to EUR 246,109,514.59 and the
-- only currency-months with no rate are 92 EUR rows in 2026-09-30. That is a
-- scope artefact, not a conversion gap: the portfolio fact stops at 2026-08-31
-- and the FX element's EUR leg is built from its month list, so a month the
-- case feed reaches first has no EUR row. Those rows never appear here anyway,
-- because this element is driven from the portfolio side. Every non-EUR
-- currency in the case feed has a rate.
--
-- ⚠ COST: the case leg aggregates FCT_CASE_COLLECTION (134,472,689 rows) by
-- portfolio, month and currency. Measured 2026-10-05: 1,269 rows out, a few
-- seconds. Group only, no window functions -- the expensive case work is the
-- collecting-case behaviour, which the dbt model pre-builds and 'Case Metrics'
-- reads.
--
-- ⚠⚠ TWO TESTS, BOTH MUST HOLD, as agreed with the business:
--   1. the month's two totals agree within 10%
--   2. the portfolio's case feed covers at least 80% of its reported months
-- ⚠ Test 2 is PORTFOLIO-level, so a month whose totals agree closely still
-- reads false when that portfolio's feed is thin. On the books measured so far
-- an unreconciled month usually means NO FEED rather than a disagreement.
--
-- ⚠⚠ BOTH MONTH COUNTS ARE DERIVED HERE, NOT READ. They were columns on the dbt
-- model until 2026-10-06 and were dropped: a stored count is wrong the moment
-- anyone filters the months under it, and both month lists are already on this
-- page. Coverage is an INTERSECTION -- of the months the servicer reported,
-- how many the case feed also collected in -- so it needs both sides and
-- belongs here rather than in a model that only sees one.
--
-- ⚠⚠ THE FEED FLAGS COME FROM A PORTFOLIO-LEVEL CTE, JOINED ON portfolio_sk
-- ALONE. Before 2026-10-06 they were read off the per-month 'Case Metrics' row,
-- which made feed_stopped_flag impossible: the only months with a row are the
-- months the feed covers, and on those the test is false by construction. Do
-- not move them back into the per-month join.
--
-- ⚠ A CASE-METRICS MONTH WITH collected_cases_count = 0 DOES NOT COUNT AS
-- COVERED. Those rows exist so a month's stopping cases are not lost (44 of
-- them, measured 2026-10-06), but a month the feed collected nothing in is not
-- a month the feed covers.
--
-- ⚠ MONTH-END THROUGHOUT, like every element on this page.
-- ============================================================================
WITH portfolio_base AS (
    -- ⚠ DISTINCT: this feeds an INNER JOIN onto a 134m-row fact, so a repeated
    -- portfolio_sk would fan it out.
    SELECT DISTINCT
        "Portfolio Sk" AS portfolio_sk,
        "Capex Date"   AS capex_date
    FROM sigma_element('Portfolio Information')
),

fx_rates AS (
    SELECT
        "Currency Id"     AS currency_id,
        "Reporting Month" AS reporting_month,
        "Rate Flow"       AS rate_flow
    FROM sigma_element('FX Table')
),

portfolio_side AS (
    -- Already EUR, already converted per currency before summing.
    SELECT
        "Portfolio Sk"     AS portfolio_sk,
        "Reporting Month"  AS reporting_month,
        "Collections Sum"  AS portfolio_collections_eur,
        "Has Fx Flow Flag" AS portfolio_has_fx_flag
    FROM sigma_element('Portfolio Metrics')
),

case_side_months AS (
    -- The case feed's month list, from the dbt model.
    -- ⚠ collected_cases_count > 0: see the header.
    SELECT
        "Portfolio Sk"    AS portfolio_sk,
        "Reporting Month" AS reporting_month
    FROM sigma_element('Case Metrics')
    WHERE "Collected Cases Count" > 0
),

portfolio_feed_extent AS (
    -- ⚠ ONE ROW PER PORTFOLIO, joined on portfolio_sk alone below. This is what
    -- makes feed_stopped_flag answerable on a month the feed does not reach.
    SELECT
        portfolio_sk,
        -- ⚠ Derived here since 2026-10-06. case_side_months is already filtered
        -- to months that collected, so its MAX is the portfolio's last one.
        MAX(reporting_month) AS portfolio_latest_collection_month
    FROM case_side_months
    GROUP BY 1
),

month_coverage AS (
    -- Test 2's two counts. ⚠ LEFT JOIN from the portfolio side: the denominator
    -- is months the SERVICER reported, so a case-feed month the servicer never
    -- reported must not inflate either count.
    SELECT
        reported.portfolio_sk,
        COUNT(*)                                     AS portfolio_reported_months,
        COUNT_IF(covered.reporting_month IS NOT NULL) AS case_covered_months
    FROM (SELECT DISTINCT portfolio_sk, reporting_month FROM portfolio_side) AS reported
    LEFT JOIN case_side_months AS covered
        ON reported.portfolio_sk = covered.portfolio_sk
        AND reported.reporting_month = covered.reporting_month
    GROUP BY 1
),

case_by_currency AS (
    -- ⚠ THE CAPEX FLOOR, matching the portfolio side. Without it the previous
    -- owner's collections land in Brocc's comparison.
    SELECT
        c.portfolio_sk,
        LAST_DAY(c.collection_date) AS reporting_month,
        c.currency_id,
        SUM(c.amount)               AS amount_local
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN portfolio_base AS p
        ON c.portfolio_sk = p.portfolio_sk
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
      AND (
          p.capex_date IS NULL
          OR c.collection_date >= DATE_TRUNC('MONTH', p.capex_date)
      )
    GROUP BY 1, 2, 3
),

case_side AS (
    SELECT
        cbc.portfolio_sk,
        cbc.reporting_month,
        -- ⚠ Converted per currency, then summed. See the header.
        SUM(cbc.amount_local * fx.rate_flow) AS case_collections_eur,
        COUNT(DISTINCT cbc.currency_id)      AS case_currency_count,
        COUNT_IF(fx.rate_flow IS NULL)       AS case_currencies_without_rate
    FROM case_by_currency AS cbc
    LEFT JOIN fx_rates AS fx
        ON cbc.currency_id = fx.currency_id
        AND cbc.reporting_month = fx.reporting_month
    GROUP BY 1, 2
)

SELECT
    p.portfolio_sk,
    p.reporting_month,

    -- ---- the comparison, both sides EUR -------------------------------------
    p.portfolio_collections_eur,
    s.case_collections_eur,
    -- ⚠ POSITIVE MEANS THE CASE FEED IS SHORT.
    p.portfolio_collections_eur - COALESCE(s.case_collections_eur, 0)
                                                    AS difference_eur,
    ROUND(ABS(p.portfolio_collections_eur - COALESCE(s.case_collections_eur, 0))
          * 100.0 / NULLIF(ABS(p.portfolio_collections_eur), 0), 5)
                                                    AS absolute_difference_pct,

    -- ---- coverage. ⚠ A PORTFOLIO ATTRIBUTE repeated on every month row, so
    -- ---- SUM across months multiplies it by the number of months. Use MAX.
    mc.portfolio_reported_months,
    mc.case_covered_months,
    ROUND(100.0 * mc.case_covered_months
          / NULLIF(mc.portfolio_reported_months, 0), 5)
                                                    AS case_month_coverage_pct,

    -- ---- what the comparison can and cannot be trusted on --------------------
    s.case_currency_count,
    -- ⚠ NON-ZERO MEANS THE CASE SIDE IS SHORT BY AN UNCONVERTED CURRENCY.
    s.case_currencies_without_rate,
    p.portfolio_has_fx_flag,
    -- ⚠ Both read the portfolio-level extent, never the per-month row.
    fe.portfolio_latest_collection_month IS NOT NULL AS have_loan_detail_flag,
    COALESCE(p.reporting_month > fe.portfolio_latest_collection_month, FALSE)
                                                    AS feed_stopped_flag,

    -- ---- the agreed rule: within 10% AND 80% month coverage ------------------
    COALESCE(
        ABS(p.portfolio_collections_eur - s.case_collections_eur)
        <= 0.10 * ABS(NULLIF(p.portfolio_collections_eur, 0))
        AND mc.case_covered_months >= 0.80 * mc.portfolio_reported_months,
        FALSE
    )                                               AS is_reconciled_flag
FROM portfolio_side AS p
LEFT JOIN case_side AS s
    ON p.portfolio_sk = s.portfolio_sk
    AND p.reporting_month = s.reporting_month
LEFT JOIN month_coverage AS mc
    ON p.portfolio_sk = mc.portfolio_sk
LEFT JOIN portfolio_feed_extent AS fe
    ON p.portfolio_sk = fe.portfolio_sk
