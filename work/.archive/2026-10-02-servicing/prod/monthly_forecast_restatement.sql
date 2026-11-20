-- ============================================================================
-- monthly_forecast_restatement — how the accounting forecast for a month has
-- been revised, run by run.
-- GRAIN: one row per (PORTFOLIO_BK, PERIOD_END_DATE, REPORTING_DATE).
-- ============================================================================
-- monthly_portfolio_forecast.sql gives the current forecast for each month.
-- This gives the history of that forecast: what we expected for June as at
-- each reporting run. The question it answers is "are we revising our
-- expectations up or down", which a single-vintage view cannot show.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/monthly_forecast_restatement.sql
--   Notebook  : datalake.q("servicing/prod/monthly_forecast_restatement")
--
-- ---------------------------------------------------------------------------
-- GRAIN verified 2026-09-09 on
-- FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY_VERSIONED: 53,352 rows,
-- and 53,352 distinct (PORTFOLIO_SK, PERIOD_END_DATE, REPORTING_DATE).
-- Unique on that, so no dedupe is needed.
--
-- ⚠ REPORTING_DATE IS THE VERSION KEY HERE, NOT SNAPSHOT_VERSION.
-- Easy to get wrong, and the wrong choice silently collapses the history:
--   SNAPSHOT_VERSION           has exactly ONE distinct value in this table
--   REPORTING_PERIOD_END_DATE  gives 53,273 combinations — 79 short of
--                              unique, so grouping on it merges runs
--   REPORTING_DATE             gives 53,352 — the real discriminator, 9
--                              distinct values
-- Both other columns are carried through below so you can see them, but the
-- ordering and the lag() use REPORTING_DATE.
--
-- ⚠ BATCH_SK IS 100% NULL IN THIS TABLE (all 53,352 rows).
-- So there is no batch detail to be had, and any join to DIM_BATCH returns
-- nothing. Portfolio is the finest grain available.
--
-- ⚠ NEVER SUM ACROSS REPORTING_DATE. Two runs' forecasts for the same month
-- are the same expectation restated, not additional money. Filter to one
-- run, use IS_LATEST_RUN, or compare them side by side.
--
-- ⚠ IT RUNS TO 2041-06-30, and almost all of that is projection. Only
-- PERIOD_END_DATE <= today can be compared with actuals; IS_ACTUAL_PERIOD
-- flags it.
-- ============================================================================

set months_back      = 12;   -- forecast months to include, back from today
set months_ahead     = 12;   -- and forward
set portfolio_filter = '%';
set row_limit        = 200000;


with bounds as (
    select dateadd(month, -1 * $months_back, current_date()) as start_date,
           dateadd(month, $months_ahead, current_date())     as end_date
),

portfolio_scope as (
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
),

runs as (
    select
        f.portfolio_sk,
        f.period_end_date,
        f.reporting_date,
        f.reporting_period_end_date,
        f.snapshot_version,
        f.currency_id,
        f.country_id,
        f.deal_sk,
        f.deal_source_sk,
        f.security_class_sk,
        f.legal_buyer_sk,
        f.gross_collection_forecast,
        f.net_collection_forecast,
        f.servicing_comission        as servicing_commission,
        f.passthrough_cost,
        f.portfolio_management_fee,
        f.performance_fee,
        f.execution_fee
    from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY_VERSIONED as f
    cross join bounds as b
    where f.period_end_date >  b.start_date
      and f.period_end_date <= b.end_date
)

select
    ps.portfolio_bk,
    r.period_end_date,                      -- the month being forecast
    r.reporting_date,                       -- the run that produced it
    r.reporting_period_end_date,            -- ⚠ not unique; see header
    r.snapshot_version,                     -- ⚠ single-valued; see header

    count(*) over (partition by r.portfolio_sk, r.period_end_date)
                                            as n_runs_for_month,
    r.reporting_date = max(r.reporting_date) over (
        partition by r.portfolio_sk, r.period_end_date
    )                                       as is_latest_run,
    r.period_end_date <= current_date()     as is_actual_period,

    ds.deal_source_name,
    dd.deal_bk,
    dd.deal_alias,
    sc.security_class_name,
    lb.legal_buyer_name,
    r.country_id,
    r.currency_id,                          -- ⚠ do not sum across currencies

    -- ---- the forecast as at this run ------------------------------------
    r.gross_collection_forecast,
    r.net_collection_forecast,
    r.gross_collection_forecast - r.net_collection_forecast
                                            as forecast_servicing_cost,
    r.servicing_commission,
    r.passthrough_cost,
    r.portfolio_management_fee,
    r.performance_fee,
    r.execution_fee,

    -- ---- the revision ----------------------------------------------------
    -- NULL on a month's first run: nothing precedes it. Window edge, not a gap.
    lag(r.gross_collection_forecast) over (
        partition by r.portfolio_sk, r.period_end_date order by r.reporting_date
    )                                       as gross_previous_run,
    r.gross_collection_forecast - lag(r.gross_collection_forecast) over (
        partition by r.portfolio_sk, r.period_end_date order by r.reporting_date
    )                                       as revision_vs_previous,
    div0null(
        r.gross_collection_forecast - lag(r.gross_collection_forecast) over (
            partition by r.portfolio_sk, r.period_end_date order by r.reporting_date
        ),
        abs(lag(r.gross_collection_forecast) over (
            partition by r.portfolio_sk, r.period_end_date order by r.reporting_date
        ))
    )                                       as revision_pct

from runs as r
inner join portfolio_scope                    as ps on ps.portfolio_sk      = r.portfolio_sk
left  join PROD.NPL_COMMON.DIM_DEAL           as dd on dd.deal_sk           = r.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE    as ds on ds.deal_source_sk    = r.deal_source_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS as sc on sc.security_class_sk = r.security_class_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER    as lb on lb.legal_buyer_sk    = r.legal_buyer_sk
order by ps.portfolio_bk, r.period_end_date, r.reporting_date
limit $row_limit
