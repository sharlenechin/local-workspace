-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/agg_npl_platinum_forecast_monthly.sql
--   this   : the same model with every {{ ref() }} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/agg_npl_platinum_forecast_monthly.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
-- ============================================================================

/*
PLATINUM. All three forecasts side by side. ONE ROW PER (PORTFOLIO_SK,
REPORTING_MONTH, CURRENCY_ID), in EUR and in local currency.
REPORTING_MONTH is MONTH-START.

THE THREE ANSWER DIFFERENT QUESTIONS. Never average them, never swap one for
another:
  UNDERWRITING  what we assumed when we BOUGHT. Frozen, one vintage today.
                The benchmark for "was the purchase a good one?"
  ACCOUNTING    our CURRENT view, revised as we learn. THE ONE FINANCE TRACKS
                in the flash report and revaluations.
  SERVICER      the servicer's own projection, and 66x finer. Answers "is the
                servicer hitting the plan?" and nothing else.

⚠⚠ ACCOUNTING IS BORN AS A COPY OF UNDERWRITING -- 91.3% of portfolio-months are
still identical to it. Where they differ, WE have marked the book. A report that
will not tie to the flash is probably on the servicer's plan by mistake.

⚠⚠ THE FORECAST FACTS ARE NOT DEDUPED UPSTREAM, unlike the portfolio snapshot.
Each revision is a new SNAPSHOT_VERSION, so without the QUALIFY every
restatement is counted again. VERSION_COUNT records how many existed.
⚠ DO NOT SUM A VERSION_COUNT. It counts revisions, not anything real.

⚠⚠ RATE_FLOW, NOT RATE_STOCK. A forecast is a flow -- money expected to arrive
DURING the month -- so it takes the monthly average, not the month-end close.
The two differ by 0.87% on average for SEK and up to 1.70% in a single month.

⚠⚠ THE FX JOIN USES MONTH-END WHILE THE OUTPUT IS MONTH-START. Deliberate --
see agg_npl_platinum_portfolio_monthly for the same note.

⚠⚠ CURRENCY IS IN THE GRAIN, so only the _EUR columns may be summed across
currencies. NEVER SUM A _LOCAL_CURRENCY COLUMN ACROSS DIFFERENT CURRENCIES.

⚠ HISTORICAL ONLY. Bounded to CURRENT_DATE(), so forward projection months are
not returned. A forward view is a different model.

⚠ THIS IS FORECAST-DRIVEN, NOT ACTUALS-DRIVEN. Every portfolio-month any of the
three knows about gets a row, including months with no actuals at all. Totals
are therefore HIGHER than an actuals-driven view, deliberately.
*/

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
    -- table's coverage, which only starts 2018-01-31.
    SELECT DISTINCT
        'EUR',
        period_end_date,
        1
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

servicer_forecast AS (
    -- ⚠ THE SUBQUERY IS NOT DECORATION. QUALIFY runs after GROUP BY, so
    -- SNAPSHOT_VERSION has to be filtered before the rows are aggregated.
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
    -- ⚠ ONE VINTAGE TODAY, so the version guard is insurance rather than a live
    -- filter. Keep it: a second vintage would silently double the plan.
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
    -- ---- keys ---------------------------------------------------------------
    s.portfolio_sk,
    DATE_TRUNC('MONTH', s.period_end_date)::DATE       AS reporting_month,
    YEAR(s.period_end_date)                            AS reporting_year,
    s.currency_id,

    -- ---- local currency. ⚠ ONLY SUM WITHIN ONE CURRENCY. --------------------
    sf.forecast_local_currency                         AS servicer_forecast_local_currency,
    af.forecast_local_currency                         AS accounting_forecast_local_currency,
    uf.forecast_local_currency                         AS underwriting_forecast_local_currency,

    -- ---- EUR. Safe to sum across anything. ----------------------------------
    sf.forecast_local_currency * fx.rate_flow          AS servicer_forecast_eur,
    af.forecast_local_currency * fx.rate_flow          AS accounting_forecast_eur,
    uf.forecast_local_currency * fx.rate_flow          AS underwriting_forecast_eur,
    fx.rate_flow,

    -- ---- how many revisions existed. ⚠ NEVER SUM THESE. ---------------------
    sf.version_count                                   AS servicer_forecast_version_count,
    af.version_count                                   AS accounting_forecast_version_count,
    uf.version_count                                   AS underwriting_forecast_version_count,

    -- ---- flags ----------------------------------------------------------------
    sf.forecast_local_currency IS NOT NULL             AS have_servicer_forecast_flag,
    af.forecast_local_currency IS NOT NULL             AS have_accounting_forecast_flag,
    uf.forecast_local_currency IS NOT NULL             AS have_underwriting_forecast_flag,
    -- ⚠ FALSE means no rate for that currency-month, so the EUR columns above
    -- are NULL, not zero.
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
