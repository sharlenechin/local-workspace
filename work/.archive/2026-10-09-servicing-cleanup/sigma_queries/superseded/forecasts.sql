-- ============================================================================
-- SIGMA ELEMENT 'Forecasts'. ONE ROW PER (PORTFOLIO_SK, REPORTING_MONTH).
-- All three forecasts side by side in EUR. 2,100 rows measured 2026-09-29,
-- unique on (portfolio_sk, reporting_month).
-- ============================================================================
-- GRAIN     portfolio x month. reporting_month is MONTH-END.
-- READS     'Portfolio Information' and 'FX Table' as elements, plus the three
--           forecast facts. Stays in Sigma: all three are portfolio-grain.
--
-- ⚠⚠ THE THREE FORECASTS ANSWER THREE DIFFERENT QUESTIONS. Never average them
-- and never substitute one for another.
--   UNDERWRITING   what we assumed when we bought. Frozen at purchase, one
--                  vintage. The benchmark for "was the purchase a good one?"
--   ACCOUNTING     our current view. THE ONE FINANCE TRACKS in flash and
--                  revaluations. Use this to tie out to the flash report.
--   SERVICER       Intrum's own projection. Answers "is the servicer hitting
--                  its plan?" and nothing else.
--
-- ⚠⚠ THE FORECAST FACTS ARE NOT DEDUPED UPSTREAM, unlike the portfolio
-- snapshot. Each revision is a new snapshot_version, so without the QUALIFY
-- every restatement is counted again. ⚠ The subquery is not decoration:
-- QUALIFY runs after GROUP BY, so the version has to be filtered before the
-- rows are aggregated.
--
-- ⚠⚠ FORECAST-DRIVEN, NOT ACTUALS-DRIVEN. Every portfolio-month any of the
-- three forecasts knows about gets a row, including 117 with no actuals at
-- all. Totals here are therefore HIGHER than an actuals-driven view, by
-- design. This is the widest key set on the page and what the Dashboard Base
-- should be driven from.
--
-- ⚠ NO DRILL PATH HERE ON PURPOSE -- 'Portfolio Information' already carries
-- all of it. Join to it on portfolio_sk.
--
-- ⚠ ROWS WITH NO RATE KEEP A NULL, they are not dropped. forecast_has_fx_flag
-- says which. Before the 2026-09-29 FX fix that flag was FALSE on every
-- non-EUR row -- see sigma_fx_table.sql.
-- ============================================================================
WITH
portfolio_base AS (
    -- ⚠ DISTINCT, NOT A BARE SELECT. This feeds an INNER JOIN, so a repeated
    -- portfolio_sk would fan the forecast rows out and double the money.
    SELECT DISTINCT
        "Portfolio Sk" AS portfolio_sk,
        "Capex Date"   AS capex_date
    FROM sigma_element('Portfolio Information')
),

fx_rates AS (
    -- Only the flow rate: a forecast is a flow.
    SELECT
        "Currency Id"     AS currency_id,
        "Reporting Month" AS reporting_month,
        "Rate Flow"       AS rate_flow
    FROM sigma_element('FX Table')
),

servicer_forecast AS (
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast) AS servicer_forecast_local
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.gross_collection_forecast
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
        SUM(gross_collection_forecast) AS accounting_forecast_local
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.gross_collection_forecast
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
        SUM(gross_collection_forecast) AS underwriting_forecast_local
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.gross_collection_forecast
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

forecast_spine AS (
    -- ⚠ UNION, NOT UNION ALL: a portfolio-month that one forecast knows about
    -- and another does not still gets exactly one row.
    SELECT portfolio_sk, period_end_date, currency_id FROM servicer_forecast
    UNION
    SELECT portfolio_sk, period_end_date, currency_id FROM accounting_forecast
    UNION
    SELECT portfolio_sk, period_end_date, currency_id FROM underwriting_forecast
)

SELECT
    s.portfolio_sk,
    s.period_end_date                            AS reporting_month,
    YEAR(s.period_end_date)                        AS reporting_year,

    LISTAGG(DISTINCT s.currency_id, ' + ')
        WITHIN GROUP (ORDER BY s.currency_id)      AS forecast_original_currency,
    COUNT(DISTINCT s.currency_id)                  AS forecast_currency_count,

    -- ---- EUR. Converted per currency, then summed. -----------------------
    SUM(sf.servicer_forecast_local     * fx.rate_flow)
                                                   AS servicer_forecast_sum,
    SUM(af.accounting_forecast_local   * fx.rate_flow)
                                                   AS accounting_forecast_sum,
    SUM(uf.underwriting_forecast_local * fx.rate_flow)
                                                   AS underwriting_forecast_sum,

    -- ---- which of the three exists for this portfolio-month --------------
    -- ⚠ COUNT of the LOCAL column, not the EUR one: a row with a forecast but
    -- no FX rate still HAS a forecast, and must not read as missing.
    COUNT(sf.servicer_forecast_local)     > 0      AS have_servicer_forecast_flag,
    COUNT(af.accounting_forecast_local)   > 0      AS have_accounting_forecast_flag,
    COUNT(uf.underwriting_forecast_local) > 0      AS have_underwriting_forecast_flag,

    MIN(IFF(fx.rate_flow IS NOT NULL, 1, 0)) = 1   AS forecast_has_fx_flag
FROM forecast_spine AS s
INNER JOIN portfolio_base AS p
    ON p.portfolio_sk = s.portfolio_sk
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
-- ⚠ THE CONVERSION. rate_flow because a forecast is a flow. MONTH-END key.
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = s.currency_id
    AND fx.reporting_month = s.period_end_date
-- ⚠ NO CAPEX DATE MEANS KEEP IT. A portfolio may have a NULL capex_date
-- and a NULL fails the test, which would drop it entirely.
WHERE (p.capex_date IS NULL
       OR s.period_end_date >= DATE_TRUNC('MONTH', p.capex_date))
GROUP BY 1, 2, 3
