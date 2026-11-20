-- ============================================================================
-- SIGMA ELEMENT 'Servicing'. ONE ROW PER (PORTFOLIO_SK, REPORTING_MONTH).
-- The one wide element every tile reads. EVERYTHING IS IN EUR.
-- ============================================================================
-- GRAIN     portfolio x month, month-END. ~1,840 rows.
-- READS     Portfolio Information, Portfolio Metrics, Forecasts and FX Table as
--           elements, plus the dbt mart and the case fact.
--
-- ⚠⚠⚠ THIS IS THE ONLY ELEMENT A TILE SHOULD READ. The four it reads are
-- plumbing: they exist because the money, the forecasts and the drill path are
-- each non-trivial and already proven. Do not point a chart at them directly --
-- one source for every tile is what keeps two cards from disagreeing.
--
-- ⚠⚠⚠ EVERY MONEY COLUMN IS EUR. No local-currency column leaves this element.
-- A portfolio-month can hold two currencies: only 1.6% of months do, but they
-- carry 35.67% of gross value, so taking the rate from the portfolio's own
-- currency would mis-convert a third of the money. Portfolio Metrics and
-- Forecasts already convert per currency; the case side is converted below at
-- the grain where a row has exactly one currency.
--
-- ⚠⚠ THE BEHAVIOUR SPLITS USE AN EFFECTIVE RATE. The mart holds them in local
-- currency and carries no currency column, so each is converted at that
-- portfolio-month's own realised rate:
--     effective_rate = case collections EUR / case collections local
-- Exact on a single-currency month; a value-weighted blend on a two-currency
-- one, which keeps the parts summing to the EUR total. Two portfolios affected.
-- ⚠ It assumes the currency mix is the same across behaviours.
-- ============================================================================
WITH portfolio_information AS (
    SELECT
        "Portfolio Sk"       AS portfolio_sk,
        "Portfolio Name"     AS portfolio_name,
        "Vehicle"            AS vehicle,
        "Project"            AS project,
        "Deal"               AS deal,
        "Servicer"           AS servicer,
        "Servicer Group"     AS servicer_group,
        "Country Name"       AS country_name,
        "Region"             AS region,
        "Seller"             AS seller,
        "Portfolio Currency" AS portfolio_currency,
        "Capex Date"         AS capex_date,
        "Gross Book Value"   AS gross_book_value
    FROM sigma_element('Portfolio Information')
),

portfolio_metrics AS (
    SELECT
        "Portfolio Sk"             AS portfolio_sk,
        "Reporting Month"          AS reporting_month,
        "Collections Sum"          AS collections_eur,
        "Net Collections Sum"      AS net_collections_eur,
        "Servicer Commission Sum"  AS servicer_commission_eur,
        "Servicer Mgmt Fee Sum"    AS servicer_mgmt_fee_eur,
        "Servicer Cost Total Sum"  AS servicer_cost_total_eur,
        "Balance Sum"              AS balance_eur,
        "Portfolio Currency Count" AS portfolio_currency_count,
        "Has Fx Flow Flag"         AS has_fx_flow_flag
    FROM sigma_element('Portfolio Metrics')
),

forecasts AS (
    SELECT
        "Portfolio Sk"               AS portfolio_sk,
        "Reporting Month"            AS reporting_month,
        "Servicer Forecast Sum"      AS servicer_forecast_eur,
        "Accounting Forecast Sum"    AS accounting_forecast_eur,
        "Underwriting Forecast Sum"  AS underwriting_forecast_eur
    FROM sigma_element('Forecasts')
),

fx_rates AS (
    SELECT
        "Currency Id"     AS currency_id,
        "Reporting Month" AS reporting_month,
        "Rate Flow"       AS rate_flow
    FROM sigma_element('FX Table')
),

case_money AS (
    -- ⚠ Converted per currency, then summed. Also yields the effective rate
    -- the behaviour splits are converted at.
    SELECT
        c.portfolio_sk,
        LAST_DAY(c.collection_date)      AS reporting_month,
        SUM(c.amount * fx.rate_flow)     AS case_collections_eur,
        SUM(c.amount)                    AS case_collections_local,
        COUNT(DISTINCT c.currency_id)    AS case_currency_count,
        COUNT_IF(fx.rate_flow IS NULL)   AS case_currencies_without_rate
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN portfolio_information AS p
        ON c.portfolio_sk = p.portfolio_sk
    LEFT JOIN fx_rates AS fx
        ON fx.currency_id = c.currency_id
        AND fx.reporting_month = LAST_DAY(c.collection_date)
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
      AND (p.capex_date IS NULL
           OR c.collection_date >= DATE_TRUNC('MONTH', p.capex_date))
    GROUP BY 1, 2
),

month_coverage AS (
    -- Of the months the SERVICER reported, how many the case feed collected in.
    -- ⚠ One value per portfolio, repeated on every month row below.
    SELECT
        reported.portfolio_sk,
        COUNT(*)                                       AS portfolio_reported_months,
        COUNT_IF(covered.reporting_month IS NOT NULL)  AS case_covered_months
    FROM (SELECT DISTINCT portfolio_sk, reporting_month FROM portfolio_metrics) AS reported
    LEFT JOIN (
        SELECT portfolio_sk, period_end_date AS reporting_month
        FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY
        WHERE collected_cases_count > 0
    ) AS covered
        ON reported.portfolio_sk = covered.portfolio_sk
        AND reported.reporting_month = covered.reporting_month
    GROUP BY 1
),

effective_rate AS (
    SELECT
        portfolio_sk,
        reporting_month,
        IFF(case_collections_local = 0, NULL,
            case_collections_eur / case_collections_local) AS rate
    FROM case_money
)

SELECT
    p.portfolio_sk,
    p.portfolio_name,
    p.vehicle,
    p.project,
    p.deal,
    p.servicer,
    p.servicer_group,
    p.seller,
    p.region,
    p.country_name,
    p.portfolio_currency,
    p.capex_date,
    p.gross_book_value,
    m.reporting_month,
    YEAR(m.reporting_month)                     AS reporting_year,

    -- ---- money, all EUR ---------------------------------------------------
    m.collections_eur,
    m.net_collections_eur,
    m.servicer_commission_eur,
    m.servicer_mgmt_fee_eur,
    m.servicer_cost_total_eur,
    m.balance_eur,
    f.servicer_forecast_eur,
    f.accounting_forecast_eur,
    f.underwriting_forecast_eur,

    -- ---- case behaviour, counts -------------------------------------------
    c.collected_cases_count,
    c.collected_cases_first_collection_count,
    c.collected_cases_three_consecutive_months_count,
    c.collected_cases_jitter_in_count,
    c.collected_cases_jitter_out_count,
    c.collected_cases_new_count,
    c.collected_cases_lost_count,
    c.cases_on_book_count,
    c.cases_ever_collected_count,
    c.cases_never_collected_count,

    -- ---- case money, EUR --------------------------------------------------
    cm.case_collections_eur,
    c.collected_amount_local_first_collection_sum * er.rate
                                                AS first_collection_eur,
    c.collected_amount_local_three_consecutive_months_sum * er.rate
                                                AS three_consecutive_months_eur,
    c.collected_amount_local_jitter_in_sum * er.rate
                                                AS jitter_in_eur,
    c.collected_amount_local_new_sum * er.rate  AS new_collection_eur,
    -- ⚠ A DIFFERENT MONTH'S money: what those cases collected in their LAST
    -- month, because the month they are reported in has no collection.
    c.collected_amount_local_jitter_out_last_month_sum * er.rate
                                                AS jitter_out_last_month_eur,
    c.collected_amount_local_lost_last_month_sum * er.rate
                                                AS lost_last_month_eur,

    -- ---- trust ------------------------------------------------------------
    m.portfolio_currency_count,
    cm.case_currency_count,
    cm.case_currencies_without_rate,
    m.has_fx_flow_flag,
    mc.portfolio_reported_months,
    mc.case_covered_months,
    ROUND(100.0 * mc.case_covered_months
          / NULLIF(mc.portfolio_reported_months, 0), 5) AS case_month_coverage_pct,
    ROUND(ABS(m.collections_eur - COALESCE(cm.case_collections_eur, 0))
          * 100.0 / NULLIF(ABS(m.collections_eur), 0), 5)
                                                AS absolute_difference_pct,
    c.portfolio_sk IS NOT NULL                  AS have_case_detail_flag,
    -- ⚠ THREE STATES. NULL means "not comparable" -- there is no case row for
    -- this month -- and must never render as "not reconciled".
    CASE
        WHEN c.portfolio_sk IS NULL THEN NULL
        ELSE ABS(m.collections_eur - COALESCE(cm.case_collections_eur, 0))
             <= 0.10 * ABS(NULLIF(m.collections_eur, 0))
             AND mc.case_covered_months >= 0.80 * mc.portfolio_reported_months
    END                                         AS is_reconciled_flag
FROM portfolio_metrics AS m
INNER JOIN portfolio_information AS p
    ON m.portfolio_sk = p.portfolio_sk
LEFT JOIN forecasts AS f
    ON m.portfolio_sk = f.portfolio_sk AND m.reporting_month = f.reporting_month
LEFT JOIN PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS c
    ON m.portfolio_sk = c.portfolio_sk AND m.reporting_month = c.period_end_date
LEFT JOIN case_money AS cm
    ON m.portfolio_sk = cm.portfolio_sk AND m.reporting_month = cm.reporting_month
LEFT JOIN effective_rate AS er
    ON m.portfolio_sk = er.portfolio_sk AND m.reporting_month = er.reporting_month
LEFT JOIN month_coverage AS mc
    ON m.portfolio_sk = mc.portfolio_sk
