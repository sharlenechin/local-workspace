-- ============================================================================
-- SIGMA ELEMENT 'Portfolio Information'. ONE ROW PER PORTFOLIO_SK.
-- The drill path -- vehicle, project, deal, servicer, seller, region, country --
-- resolved once so no other element has to join a dimension.
-- ============================================================================
-- GRAIN     portfolio, one row each, straight from DIM_PORTFOLIO. 264 rows
--           measured 2026-10-02. ⚠ Re-measure before quoting -- it drifts.
-- READS     PROD only. Bottom of the chain, alongside sigma_fx_table.
-- FEEDS     sigma_portfolio_metrics, sigma_forecasts -- both INNER JOIN it for
--           the capex floor, and read its capex_date.
--
-- ⚠⚠ DIM_PORTFOLIO IS THE BASELINE AND NOTHING UNKNOWN IS SHOWN. There is no
-- sentinel leg: a fact key with no dimension row is bad data from Intrum, not a
-- book we own, and the dashboard must not show it. See the note at the bottom
-- for what was removed and when.
-- ⚠ MEASURED 2026-10-02 AND IT NOW COSTS NOTHING: all 264 portfolio keys in
-- FCT_PORTFOLIO_SNAPSHOT_MONTHLY have a DIM_PORTFOLIO row, so 0 portfolios and
-- EUR 0.00 of EUR 16,823,372,633.30 are excluded. The orphan was cleaned
-- upstream. The older 6.38% and 0.24159% figures in this workspace are history,
-- not the current state.
-- ⚠⚠ EVERY ELEMENT ON THIS PAGE MUST USE THE SAME BASELINE, and the dbt model
-- mart_npl_servicing_agg_cases_monthly does too -- it INNER JOINs
-- dim_npl_portfolio. If one element admits unknown portfolios and another does
-- not, the reconciliation reports a gap that is only a scope difference.
--
-- ⚠⚠ CONSUMERS MUST SELECT DISTINCT portfolio_sk BEFORE JOINING. This element
-- is one row per portfolio today, but it feeds INNER JOINs onto facts with
-- millions of rows; a duplicate here would fan those out and double the money.
--
-- ⚠ servicer_sub_group IS HARDCODED. Nothing in the warehouse carries a
-- sub-servicer. Two of the three mapped keys matched no portfolio as at
-- 2026-09-18 -- they are kept so the mapping is visible rather than lost.
--
-- ⚠ THE SERVICER RULE IS A BUSINESS DECISION, not a warehouse fact: LEGACY in
-- Spain is Gescobro, LEGACY in Italy is Cerved, everything else is Intrum.
-- It is pasted into 13 files across this workspace. If it changes, it changes
-- in all of them -- which is the argument for making it a dbt macro.
--
-- ⚠ COUNTRY JOINS ON iso_alpha2_code, NOT country_id. The facts carry 'ES',
-- 'FI', 'GB' while DIM_COUNTRY.country_id is a hash key, so the natural join
-- matches zero rows and leaves every country name NULL with no error.
-- ============================================================================
WITH portfolio_vehicle AS (
    -- ANY_VALUE: both columns are 1:1 to the portfolio in this fact.
    SELECT
        portfolio_sk,
        ANY_VALUE(legal_buyer_sk) AS legal_buyer_sk,
        ANY_VALUE(country_id)     AS fact_country_id
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    GROUP BY 1
),

subservicer_map AS (
    SELECT 'LEG-ES25001-U00/2512' AS portfolio_bk, 'TDX' AS subservicer
    UNION ALL SELECT 'HEI-GR25001-U01/2512', 'QQuant'
    UNION ALL SELECT 'HEI-GR25001-U02/2512', 'QQuant'
)

SELECT
    p.portfolio_sk,
    COALESCE(p.portfolio_bk, 'Unknown')                   AS portfolio_name,
    COALESCE(lb.legal_buyer_name, 'Unknown')              AS vehicle,
    COALESCE(ds.deal_source_name, 'Unknown')              AS project,
    COALESCE(d.deal_alias, d.deal_bk, 'Unknown')          AS deal,
    CASE WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'ES' THEN 'Gescobro'
         WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'IT' THEN 'Cerved'
         ELSE 'Intrum' END                                AS servicer_group,
    COALESCE(sm.subservicer, '')                          AS servicer_sub_group,
    IFF(sm.subservicer IS NOT NULL,
        servicer_group || ' - ' || sm.subservicer,
        servicer_group)                                   AS servicer,
    COALESCE(d.seller_name, 'Unknown')                    AS seller,
    -- ⚠ UK IS ABSENT FROM THE DIMENSION'S REGION MAP and is placed explicitly.
    CASE WHEN COALESCE(co.country_name, d.country_id, 'Unknown') = 'UK'
         THEN 'Europe' ELSE co.region END                 AS region,
    COALESCE(co.country_name, d.country_id, 'Unknown')    AS country_name,
    COALESCE(d.country_id, pv.fact_country_id, 'Unknown') AS country_code,

    -- ---- purchase economics ------------------------------------------------
    p.flow_type,
    p.currency_id                                         AS portfolio_currency,
    -- ⚠ THE CAPEX FLOOR. Consumers cut their facts at this month so the
    -- dashboard shows Brocc's own collections, not the previous owner's.
    p.capex_date,
    DATE_TRUNC('MONTH', p.capex_date)::DATE               AS capex_month,
    YEAR(p.capex_date)                                    AS capex_year,
    p.capex_amount,
    p.gbv                                                 AS gross_book_value,
    p.price_gross,
    -- ⚠ READS 0.00 WHERE GBV IS ZERO, not where the price was zero.
    p.price_percent
FROM PROD.NPL_COMMON.DIM_PORTFOLIO AS p
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS d
    ON d.deal_id = p.deal_id
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
    ON ds.deal_source_bk = d.deal_source_bk
LEFT JOIN portfolio_vehicle AS pv
    ON pv.portfolio_sk = p.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON lb.legal_buyer_sk = pv.legal_buyer_sk
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = d.country_id
LEFT JOIN subservicer_map AS sm
    ON sm.portfolio_bk = p.portfolio_bk

-- ⚠⚠⚠ THE SENTINEL LEG WAS HERE AND IS DELIBERATELY GONE (2026-09-30).
-- It UNIONed in fact portfolio keys with no dimension row as
-- '(Unknown Portfolio -1)' with every attribute set to 'Unknown'. The business
-- position is that these are BAD DATA FROM INTRUM -- rows that never mapped to
-- a book we own -- so the dashboard must not show them and nobody should have
-- to filter them out by hand.
-- ⚠ SIZED BEFORE REMOVAL: all of it is PORTFOLIO_SK '-1', 2,071 fact rows over
-- 24 months (2024-09-30 .. 2026-08-31), 218 batch keys, EUR 40,741,423.54 of
-- GROSS_CASH_RECOVERIES = 0.24159% of the fact's EUR 16,864,114,056.84 lifetime
-- collections.
-- ⚠ THE OLD COMMENT HERE SAID 6.38% and the one in agg_npl_portfolio_monthly
-- said 2.69%. Both were single-month shares measured on different months; the
-- lifetime figure is 0.24159%. Quote that unless the question is about a month.
-- ⚠⚠ agg_npl_portfolio_monthly AND agg_npl_case_payer_monthly DROPPED IT AT THE
-- SAME TIME. All three must agree, or the reconciliation element compares two
-- different scopes and reports a gap that is really a definition difference.
