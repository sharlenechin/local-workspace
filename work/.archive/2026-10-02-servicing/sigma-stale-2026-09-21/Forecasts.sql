-- ============================================================================
-- Portfolio forecasts in EUR. ONE ROW PER (PORTFOLIO_SK, REPORTING_MONTH).
-- 1,980 rows, 265 portfolios. Verified 2026-09-21.
-- ============================================================================
-- THIS IS THE FILE THAT RUNS IN SIGMA. It reads two elements already on the
-- page instead of rebuilding them:
--   'Portfolio Information'  ->  ref_portfolio_drill.sql   (265 rows)
--   'FX Table'               ->  ref_fx_monthly.sql        (1,401 rows)
-- Both names must match the workbook exactly.
--
-- ⚠⚠⚠ REPORTING_MONTH IS MONTH-START (the 1st) IN EVERY DATASET ON THIS PAGE.
-- All four must agree or the joins match nothing, silently and with no error.
-- ⚠ THE FX JOIN STILL USES MONTH-END INTERNALLY, because the FX element is
-- keyed on the last day of the month. That is deliberate: the join key and the
-- output grain are different things here. Do not "align" them.
--
-- ⚠⚠⚠ SIGMA RENAMES EVERY COLUMN ON THE WAY OUT OF AN ELEMENT: Title Case,
-- spaces, case-sensitive, so it resolves only inside double quotes. Reaching
-- for the source query's own name gives
--     SQL compilation error: invalid identifier 'PORTFOLIO_SK'
-- and the line number in that message counts lines in Sigma's expanded SQL,
-- not in this file.
--
-- ⚠⚠ EVERY MONEY COLUMN IS EUR. Forecasts are FLOWS, so they take RATE_FLOW --
-- the monthly average, not the month-end RATE_STOCK. The two differ by 0.87% on
-- average for SEK and up to 1.70% in a month, so this is a real choice.
-- Conversion happens per currency BEFORE the collapse to the month; converting
-- after would apply one rate to a mixed-currency total. No local-currency
-- columns are emitted -- they could only be summed within one currency, and in
-- a dashboard nobody remembers that.
--
-- ⚠⚠ THE FORECAST FACTS ARE NOT DEDUPED UPSTREAM, unlike the portfolio
-- snapshot. Each revision is a new snapshot_version, so without the QUALIFY
-- every restatement would be counted again.
--
-- ⚠⚠ FORECAST-DRIVEN, NOT ACTUALS-DRIVEN. Every portfolio-month any of the
-- three forecasts knows about gets a row, including 117 with no actuals at all.
-- Totals here are therefore HIGHER than an actuals-driven view, deliberately.
-- This element is the widest key set on the page and is what the Dashboard Base
-- should be driven from.
--
-- ⚠ NO PORTFOLIO NAME OR DRILL PATH HERE ON PURPOSE. The drill element is
-- already on the page with all of it -- join to it on PORTFOLIO_SK.
--
-- ⚠ ROWS WITH NO RATE KEEP A NULL, they are not dropped. HAS_FX_FLAG says which.
-- ============================================================================
WITH
portfolio_base AS (
    -- ⚠ DISTINCT, NOT A BARE SELECT. This feeds an INNER JOIN, so a repeated
    -- portfolio_sk would fan the forecast rows out and double the money.
    -- The drill element carries the sentinel row for fact rows with no
    -- dimension row -- do not swap it for DIM_PORTFOLIO.
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

servicer_forecast AS (
    -- ⚠ THE SUBQUERY IS NOT DECORATION. QUALIFY runs after GROUP BY, so
    -- snapshot_version has to be filtered before the rows are aggregated.
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
    -- UNION, not UNION ALL: a portfolio-month that one forecast knows about and
    -- another does not still gets exactly one row.
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
    s.portfolio_sk,
    -- ⚠ MONTH-START. See the header. The FX join below still uses month-end.
    DATE_TRUNC('MONTH', s.period_end_date)::DATE   AS reporting_month,
    YEAR(s.period_end_date)                        AS reporting_year,

    -- 'EUR', or 'EUR + SEK' where a portfolio-month carries two.
    LISTAGG(DISTINCT s.currency_id, ' + ')
        WITHIN GROUP (ORDER BY s.currency_id)      AS forecast_original_currency,
    COUNT(DISTINCT s.currency_id)                  AS forecast_currency_count,

    -- ---- EUR. Converted per currency, then summed. ------------------------
    SUM(sf.servicer_forecast_local     * fx.rate_flow)
                                                   AS servicer_forecast_sum,
    SUM(af.accounting_forecast_local   * fx.rate_flow)
                                                   AS accounting_forecast_sum,
    SUM(uf.underwriting_forecast_local * fx.rate_flow)
                                                   AS underwriting_forecast_sum,

    -- ---- which of the three exists for this portfolio-month ---------------
    -- ⚠ COUNT of the LOCAL column, not the EUR one: a row with a forecast but
    -- no FX rate still HAS a forecast, and must not read as missing.
    COUNT(sf.servicer_forecast_local)     > 0      AS have_servicer_forecast_flag,
    COUNT(af.accounting_forecast_local)   > 0      AS have_accounting_forecast_flag,
    COUNT(uf.underwriting_forecast_local) > 0      AS have_underwriting_forecast_flag,

    -- FALSE means a currency had no rate that month, so the EUR columns above
    -- are short by that row. Filter on it before quoting a total.
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
-- ⚠ THE CONVERSION. rate_flow because a forecast is a flow.
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = s.currency_id
    AND fx.reporting_month = s.period_end_date
-- ⚠ NO CAPEX DATE MEANS KEEP IT. The sentinel portfolio has a NULL capex_date
-- and a NULL fails the test, which would drop it entirely.
WHERE (p.capex_date IS NULL
       OR s.period_end_date >= DATE_TRUNC('MONTH', p.capex_date))
GROUP BY 1, 2, 3
