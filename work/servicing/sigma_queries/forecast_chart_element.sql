-- PROPOSED, NOT LIVE. The source of the Portfolio chart "Collections vs forecasts"
-- (the user, 2026-10-11): collections plus all three forecasts, the forecasts
-- running 12 months past the selected month.
-- Deal is carried (2026-10-12) so the header's Deal filter reaches the chart.
-- Grain: one row per portfolio x anchor month x chart month x series, long
-- format so the chart can colour each series by name.
--
-- sigma_build/build_workbook.py prepends the live query as the CTE `main`,
-- so past months are the dashboard's own figures to the cent. This file is
-- the rest of the statement and does not run on its own.
--
-- Two kinds of row:
--   Actual  anchor month = chart month: what the portfolio collected that month
--           and what each forecast said, exactly as the live query has them.
--   Ahead   for every anchor month, the 12 months after it, forecasts only.
--           A month the dashboard already has reads the live query's forecast;
--           a month no portfolio has reported yet reads the forecast facts.
-- The Reporting month filter targets anchor_month. The chart keeps Actual rows
-- in the range, and the Ahead rows of the newest anchor month in it, so the
-- forecast always starts the month after the one selected.
--
-- Every month converts at each currency's newest month-end rate, the one rate the live query uses for all months
-- (the user, 2026-10-14, as the NPL dashboard); future months have no rate of their own anyway.
-- Latest snapshot_version per portfolio-month, as the live query does: the
-- forecast facts are not deduped upstream.
--
-- compare_sum is the collections a forecast is measured against, so the
-- tooltip's % needs no other row: like-for-like for the servicer forecast,
-- all collections for the other two, and NULL on Ahead rows.

anchors AS (
    SELECT
        portfolio_name,
        country_name,
        servicer_group,
        seller,
        deal,
        reconciliation_status,
        reporting_month,
        data_as_of_month,
        collections_sum,
        collections_servicer_lfl_sum,
        servicer_forecast_sum,
        accounting_forecast_sum,
        underwriting_forecast_sum
    FROM main
),

as_of AS (
    SELECT MAX(data_as_of_month) AS month_end
    FROM anchors
),

fx_latest AS (
    SELECT
        quote_currency AS ccy,
        ultimo_value   AS rate_flow
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR' AND rate_type = 'PMI' AND quote_currency <> 'EUR'
    QUALIFY date_day = MAX(date_day) OVER (PARTITION BY quote_currency)
),

forecast_facts AS (
    -- Latest version per benchmark x portfolio-month, filtered here because a
    -- QUALIFY cannot sit beside the GROUP BY in future.
    SELECT *
    FROM (
    SELECT 'servicer' AS benchmark, portfolio_sk, period_end_date, currency_id, gross_collection_forecast, snapshot_version
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY
    UNION ALL
    SELECT 'accounting', portfolio_sk, period_end_date, currency_id, gross_collection_forecast, snapshot_version
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY
    UNION ALL
    SELECT 'underwriting', portfolio_sk, period_end_date, currency_id, gross_collection_forecast, snapshot_version
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY
    )
    QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY benchmark, portfolio_sk, period_end_date)
),

future AS (
    -- The 12 months after the newest complete month, per portfolio, in euro.
    SELECT
        p.portfolio_bk                                       AS portfolio_name,
        LAST_DAY(f.period_end_date)                          AS month_end,
        SUM(IFF(f.benchmark = 'servicer', f.gross_collection_forecast * IFF(f.currency_id = 'EUR', 1, fx.rate_flow), NULL))     AS servicer_forecast_sum,
        SUM(IFF(f.benchmark = 'accounting', f.gross_collection_forecast * IFF(f.currency_id = 'EUR', 1, fx.rate_flow), NULL))   AS accounting_forecast_sum,
        SUM(IFF(f.benchmark = 'underwriting', f.gross_collection_forecast * IFF(f.currency_id = 'EUR', 1, fx.rate_flow), NULL)) AS underwriting_forecast_sum
    FROM forecast_facts AS f
    CROSS JOIN as_of AS a
    INNER JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p
        ON p.portfolio_sk = f.portfolio_sk
    LEFT JOIN fx_latest AS fx
        ON fx.ccy = f.currency_id
    WHERE LAST_DAY(f.period_end_date) > a.month_end
      AND LAST_DAY(f.period_end_date) <= LAST_DAY(DATEADD('MONTH', 12, a.month_end))
    GROUP BY 1, 2
),

offsets AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS k
    FROM TABLE(GENERATOR(ROWCOUNT => 12))
),

ahead AS (
    SELECT
        a.portfolio_name,
        a.country_name,
        a.servicer_group,
        a.seller,
        a.deal,
        a.reconciliation_status,
        a.reporting_month                                    AS anchor_month,
        LAST_DAY(DATEADD('MONTH', o.k, a.reporting_month))   AS chart_month,
        -- A month the dashboard has reads its own figure; a later one the facts.
        IFF(chart_month <= s.month_end, m.servicer_forecast_sum, fu.servicer_forecast_sum)         AS servicer_forecast_sum,
        IFF(chart_month <= s.month_end, m.accounting_forecast_sum, fu.accounting_forecast_sum)     AS accounting_forecast_sum,
        IFF(chart_month <= s.month_end, m.underwriting_forecast_sum, fu.underwriting_forecast_sum) AS underwriting_forecast_sum
    FROM anchors AS a
    CROSS JOIN offsets AS o
    CROSS JOIN as_of AS s
    LEFT JOIN anchors AS m
        ON m.portfolio_name = a.portfolio_name
       AND m.reporting_month = LAST_DAY(DATEADD('MONTH', o.k, a.reporting_month))
    LEFT JOIN future AS fu
        ON fu.portfolio_name = a.portfolio_name
       AND fu.month_end = LAST_DAY(DATEADD('MONTH', o.k, a.reporting_month))
),

wide AS (
    SELECT
        'Actual' AS row_kind, portfolio_name, country_name, servicer_group, seller, deal, reconciliation_status,
        reporting_month AS anchor_month, reporting_month AS chart_month,
        collections_sum, collections_servicer_lfl_sum,
        servicer_forecast_sum, accounting_forecast_sum, underwriting_forecast_sum
    FROM anchors

    UNION ALL

    SELECT
        'Ahead', portfolio_name, country_name, servicer_group, seller, deal, reconciliation_status,
        anchor_month, chart_month,
        NULL, NULL,
        servicer_forecast_sum, accounting_forecast_sum, underwriting_forecast_sum
    FROM ahead
)

-- Long format: the series name is a column, so the chart can pin a colour to each.
SELECT row_kind, portfolio_name, country_name, servicer_group, seller, deal, reconciliation_status,
       anchor_month, chart_month, 'Collections' AS series, collections_sum AS value_sum, NULL AS compare_sum
FROM wide
WHERE row_kind = 'Actual'
UNION ALL
SELECT row_kind, portfolio_name, country_name, servicer_group, seller, deal, reconciliation_status,
       anchor_month, chart_month, 'Servicer forecast', servicer_forecast_sum,
       collections_servicer_lfl_sum   -- the live query's like-for-like collections
FROM wide
UNION ALL
SELECT row_kind, portfolio_name, country_name, servicer_group, seller, deal, reconciliation_status,
       anchor_month, chart_month, 'Accounting forecast', accounting_forecast_sum,
       IFF(row_kind = 'Actual', collections_sum, NULL)
FROM wide
UNION ALL
SELECT row_kind, portfolio_name, country_name, servicer_group, seller, deal, reconciliation_status,
       anchor_month, chart_month, 'Underwriting forecast', underwriting_forecast_sum,
       IFF(row_kind = 'Actual', collections_sum, NULL)
FROM wide
