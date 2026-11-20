-- The three forecasts for the 12 months after the newest complete month, for
-- the design mock's Portfolio chart (forecast lines run a year past the actuals).
-- Grain: one row per forecast month (period_end_date), all portfolios summed.
--
-- Why a separate query: the live element (portfolios_element.sql) cuts every
-- forecast at CURRENT_DATE and joins it to portfolio-months that have actuals,
-- so it holds no future forecast months at all.
--
-- Every month converts at each currency's newest month-end rate, the same single rate the live query uses for all
-- months (the user, 2026-10-14, matching the NPL dashboard); future months have no rate of their own anyway.
-- Latest snapshot_version per portfolio-month, as the live query does: the
-- forecast facts are not deduped upstream.
-- Scope: portfolios that have ever sent a servicer report, so the book matches
-- the dashboard's.

WITH fx_latest AS (
    SELECT
        quote_currency AS ccy,
        ultimo_value   AS rate_flow
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR' AND rate_type = 'PMI' AND quote_currency <> 'EUR'
    QUALIFY date_day = MAX(date_day) OVER (PARTITION BY quote_currency)
),

in_book AS (
    SELECT DISTINCT portfolio_sk
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

forecasts AS (
    SELECT 'servicer' AS benchmark, portfolio_sk, period_end_date, currency_id, gross_collection_forecast
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY
    WHERE period_end_date BETWEEN $start_month AND $end_month
    QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY portfolio_sk, period_end_date)

    UNION ALL

    SELECT 'accounting', portfolio_sk, period_end_date, currency_id, gross_collection_forecast
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY
    WHERE period_end_date BETWEEN $start_month AND $end_month
    QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY portfolio_sk, period_end_date)

    UNION ALL

    SELECT 'underwriting', portfolio_sk, period_end_date, currency_id, gross_collection_forecast
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY
    WHERE period_end_date BETWEEN $start_month AND $end_month
    QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY portfolio_sk, period_end_date)
)

SELECT
    TO_CHAR(DATE_TRUNC('MONTH', f.period_end_date), 'YYYY-MM') AS forecast_month,
    f.benchmark,
    SUM(f.gross_collection_forecast * IFF(f.currency_id = 'EUR', 1, fx.rate_flow)) AS forecast_euro,
    COUNT(DISTINCT f.portfolio_sk) AS portfolio_count,
    -- A currency with no rate would drop out of the sum silently; count it instead.
    COUNT_IF(f.currency_id <> 'EUR' AND fx.rate_flow IS NULL) AS rows_without_rate
FROM forecasts AS f
INNER JOIN in_book AS b
    ON f.portfolio_sk = b.portfolio_sk
LEFT JOIN fx_latest AS fx
    ON f.currency_id = fx.ccy
GROUP BY 1, 2
ORDER BY 1, 2
