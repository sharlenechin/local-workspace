-- ============================================================================
-- Reconciliation. ONE ROW PER (PORTFOLIO_SK, REPORTING_MONTH): every flag in
-- one place, so no money element has to carry a flag column.
-- ============================================================================
-- Reads two elements and no warehouse table. Each .sql file beside this one is
-- named for the element it produces:
--   'Portfolio Metrics'  'Case Metrics'
-- ⚠ NOT 'Portfolios (old)'. Superseded; do not read it.
--
-- ⚠ GRAIN FOLLOWS PORTFOLIO METRICS, 1,863 rows. The forecast element has 117
-- more portfolio-months, and they are deliberately absent here: a month with no
-- actuals has nothing to reconcile. In the Dashboard Base they arrive as no row,
-- which says the same thing a FALSE flag would.
--
-- ⚠⚠ BOTH SIDES ARE EUR, each converted per currency before being summed. The
-- old local comparison added SEK to euros, so a two-currency month could not be
-- compared at all and had to be forced FALSE. IS_MULTI_CURRENCY_FLAG is now
-- information, not a veto.
--
-- ⚠⚠ THE TEST IS ONLY VALID WHERE BOTH SIDES HAVE A RATE. A missing rate makes
-- one side short rather than absent, which reads as a mismatch.
--
-- ⚠ NO REPORTING_YEAR, NO CURRENCY COLUMNS, NO IS_MULTI_CURRENCY_FLAG HERE.
-- The forecast element carries REPORTING_YEAR for the page, and Portfolio
-- Metrics owns the currency columns and the multi-currency flag. A name emitted
-- by two elements collides in the Dashboard Base join.
--
-- ⚠ A PORTFOLIO WITH NO LOAN FEED IS NOT A MISMATCH, IT IS AN ABSENCE. Only 154
-- of 265 portfolios ever report a payer. HAVE_LOAN_DETAIL_FLAG separates "we
-- looked and they disagree" from "there was nothing to look at".
-- ============================================================================
WITH
portfolio_metrics AS (
    SELECT
        "Portfolio Sk"                AS portfolio_sk,
        "Reporting Month"             AS reporting_month,
        "Collections Sum"             AS portfolio_collections_sum,
        "Has Fx Flow Flag"            AS portfolio_has_fx_flag
    FROM sigma_element('Portfolio Metrics')
),

case_metrics AS (
    SELECT
        "Portfolio Sk"                 AS portfolio_sk,
        "Reporting Month"              AS reporting_month,
        "Paying Loans Count"           AS paying_loans_count,
        "Case Collections Sum"         AS case_collections_sum,
        "Case Has Fx Flag"             AS case_has_fx_flag,
        "Portfolio Last Payment Month" AS portfolio_last_payment_month
    FROM sigma_element('Case Metrics')
),

portfolio_loan_detail AS (
    -- Does the loan feed cover this portfolio AT ALL, in any month?
    SELECT
        portfolio_sk,
        MAX(paying_loans_count)           AS max_payers,
        MAX(portfolio_last_payment_month) AS portfolio_last_payment_month
    FROM case_metrics
    GROUP BY 1
),

month_coverage AS (
    -- How many of a portfolio's servicer-reported months the loan feed also
    -- covers. One month agreeing proves little if the feed is absent from the
    -- rest.
    SELECT
        p.portfolio_sk,
        COUNT(DISTINCT p.reporting_month) AS months_portfolios,
        COUNT(DISTINCT c.reporting_month) AS months_cases
    FROM portfolio_metrics AS p
    LEFT JOIN case_metrics AS c
        ON c.portfolio_sk = p.portfolio_sk
        AND c.reporting_month = p.reporting_month
    GROUP BY 1
)

SELECT
    -- ---- keys. Join the drill element on PORTFOLIO_SK for the drill path. --
    p.portfolio_sk,
    p.reporting_month,

    -- ---- the gap between the two sides, EUR --------------------------------
    -- ⚠ THE TWO RAW FIGURES ARE NOT REPEATED HERE. COLLECTIONS_SUM lives on
    -- Portfolio Metrics and CASE_COLLECTIONS_SUM on Case Metrics; emitting them
    -- again would collide on name in the Dashboard Base join.
    p.portfolio_collections_sum - COALESCE(c.case_collections_sum, 0)
                                                   AS difference_sum,
    ROUND(ABS(p.portfolio_collections_sum - COALESCE(c.case_collections_sum, 0))
          * 100.0 / NULLIF(ABS(p.portfolio_collections_sum), 0), 2)
                                                   AS absolute_difference_pct,

    -- ---- how much of this portfolio the loan feed covers at all ------------
    mc.months_portfolios,
    mc.months_cases,
    ROUND(100.0 * mc.months_cases / NULLIF(mc.months_portfolios, 0), 2)
                                                   AS case_month_coverage_pct,

    -- ---- FLAGS. These are what the dashboard filters on. -------------------
    -- ⚠ FALSE means the loan feed says NOTHING about this portfolio, so a zero
    -- payer count is an absence of detail, not an absence of payers.
    COALESCE(pld.max_payers, 0) > 0                AS have_loan_detail_flag,
    -- ⚠ TRUE where the portfolio has delivered nothing since an earlier month:
    -- a missing file, not customer behaviour. Filter before quoting lost payers.
    COALESCE(p.reporting_month > pld.portfolio_last_payment_month, FALSE)
                                                   AS feed_stopped_flag,
    -- TRUE only where BOTH sides had a rate for every row they summed.
    COALESCE(p.portfolio_has_fx_flag, FALSE)
        AND COALESCE(c.case_has_fx_flag, FALSE)    AS has_fx_both_sides_flag,

    -- ⚠ RECONCILED NEEDS ALL FOUR TESTS. 1: loan cash exists for this month.
    -- 2: it lands within 10% of the servicer's figure. 3: the portfolio's feed
    -- covers at least 80% of its servicer months -- a thin feed can match by
    -- luck. 4: both sides had a complete rate, or one is short and the gap is
    -- FX rather than disagreement.
    -- ⚠ COALESCED TO FALSE. A NULL collections figure makes the comparison NULL,
    -- and a three-state flag becomes its own bucket in Sigma.
    COALESCE(
        c.case_collections_sum IS NOT NULL
        AND ABS(p.portfolio_collections_sum - c.case_collections_sum)
            <= 0.10 * ABS(NULLIF(p.portfolio_collections_sum, 0))
        AND COALESCE(mc.months_cases, 0) >= 0.80 * mc.months_portfolios
        AND p.portfolio_has_fx_flag
        AND c.case_has_fx_flag, FALSE)             AS is_reconciled_flag
FROM portfolio_metrics AS p
LEFT JOIN case_metrics AS c
    ON c.portfolio_sk = p.portfolio_sk
    AND c.reporting_month = p.reporting_month
LEFT JOIN portfolio_loan_detail AS pld
    ON pld.portfolio_sk = p.portfolio_sk
LEFT JOIN month_coverage AS mc
    ON mc.portfolio_sk = p.portfolio_sk
