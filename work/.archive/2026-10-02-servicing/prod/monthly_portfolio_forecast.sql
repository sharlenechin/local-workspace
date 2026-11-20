-- ============================================================================
-- monthly_portfolio_forecast — PORTFOLIO × MONTH × FORECAST TYPE.
-- GRAIN: one row per (PORTFOLIO_BK, PERIOD_END_DATE, FORECAST_TYPE).
-- ============================================================================
-- What we EXPECT to collect, from all three forecasts the warehouse holds,
-- stacked in one shape so they can be compared with each other and with
-- actuals from monthly_portfolio_performance.sql.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/monthly_portfolio_forecast.sql
--   Notebook  : datalake.q("servicing/prod/monthly_portfolio_forecast")
--
-- ---------------------------------------------------------------------------
-- THE THREE FORECASTS ARE DIFFERENT QUESTIONS. Do not average them.
--
--   UNDERWRITING — what we assumed when we BOUGHT the portfolio. The
--                  original investment case. One vintage only
--                  (REPORTING_PERIOD_END_DATE = 2026-08-31), i.e. restated
--                  as at one date, not a series of revisions.
--   ACCOUNTING   — the CURRENT live forecast, the one carrying amount is
--                  built from. 8 vintages, 2025-12-31 .. 2026-09-30.
--   SERVICER     — what the SERVICER themselves project. The finest grain in
--                  the warehouse and the only forecast carrying SEGMENT_SK.
--                  12 snapshot versions, 27 vintages, back to 2015-01-31.
--
-- Underwriting vs accounting is "are we on plan"; accounting vs actual is
-- "are we on the current forecast"; servicer vs accounting is "do we and the
-- servicer agree". They are not interchangeable.
--
-- ---------------------------------------------------------------------------
-- GRAINS, verified 2026-09-09:
--   UNDERWRITING  44,092 rows, unique on (portfolio_sk, period_end_date)
--   ACCOUNTING    44,392 rows, unique on (portfolio_sk, period_end_date)
--   SERVICER   1,917,510 rows, unique on (portfolio_sk, period_end_date,
--              batch_sk, segment_sk) — 44x finer than the other two
--
-- ⚠ THE SERVICER FORECAST WILL DOUBLE COUNT IF YOU JUST SUM IT. GUARDED BELOW.
-- Of its 43,302 portfolio-months, 1,172 carry MORE THAN ONE snapshot_version
-- (up to 12) and 201 carry more than one vintage (up to 24). Those are
-- successive revisions of the same month, not additional money: summing them
-- adds a forecast to its own replacement. The CTE below keeps only the
-- highest SNAPSHOT_VERSION per portfolio-month and exposes
-- N_VERSIONS_AVAILABLE so you can see the 1,172 rows where it mattered.
--
-- A consequence worth knowing: a batch or segment that appears only in an
-- older version is dropped by that filter. That is the right call for a
-- portfolio total — the newest version is the current view — but it means
-- this file is not a complete audit trail of every batch ever forecast. For
-- that, query the table directly at its own grain.
--
-- ⚠ ACCOUNTING MIXES VINTAGES ACROSS MONTHS.
-- Each portfolio-month is unique, but different months come from different
-- vintages (8 of them). So one portfolio's forecast series is not
-- necessarily a single coherent forecast run. REPORTING_PERIOD_END_DATE is
-- carried through so you can see which vintage each month came from.
--
-- ⚠ THESE RUN TO 2041-06-30. Almost all of it is the future.
-- Only months <= today are comparable to actuals. Everything after is
-- projection. IS_ACTUAL_PERIOD flags it; do not put a forecast total and an
-- actual total in the same column without filtering.
--
-- ⚠ CURRENCY IS NOT AGGREGATED AWAY, but it is not part of the grain either
-- — a portfolio-month can span currencies and these tables carry one
-- CURRENCY_ID per row. N_CURRENCIES exposes when the roll-up mixed them; see
-- ref_fx_rate.sql to convert.
--
-- ⚠ REPORTING_SYSTEM_SK IS UNUSABLE HERE. In the servicer forecast every row
-- is -1 (Unknown), and its type differs between tables (NUMBER here, TEXT in
-- DIM_REPORTING_SYSTEM). Use DEAL_SOURCE_NAME for attribution.
-- ============================================================================

set months_back = 24;    -- history to include, counting back from today
set months_ahead = 24;   -- how far into the projection to return
set portfolio_filter = '%';
set row_limit = 200000;


with bounds as (
    select dateadd(month, -1 * $months_back, current_date())  as start_date,
           dateadd(month, $months_ahead, current_date())      as end_date
),

portfolio_scope as (
    -- ⚠ THE UNION RETAINS THE UNKNOWN PORTFOLIO. DO NOT REMOVE IT.
    -- FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY carries PORTFOLIO_SK = '-1',
    -- the Unknown sentinel, which does not exist in DIM_PORTFOLIO (that
    -- dimension is keyed by hash, so -1 matches nothing). Measured
    -- 2026-09-09: 36,852 rows holding EUR 450.59m of gross forecast
    -- (the accounting and underwriting forecasts are clean). An inner join
    -- through DIM_PORTFOLIO silently drops all of it. Labelled rather than
    -- hidden; it matches $portfolio_filter = '%' and any narrower filter
    -- excludes it.
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter

    union all

    select f.portfolio_sk,
           '(unknown portfolio ' || f.portfolio_sk || ')' as portfolio_bk
    from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY as f
    where f.portfolio_sk not in (select portfolio_sk from PROD.NPL_COMMON.DIM_PORTFOLIO)
      and ('(unknown portfolio ' || f.portfolio_sk || ')') like $portfolio_filter
    group by f.portfolio_sk
),

underwriting as (
    select
        f.portfolio_sk, f.period_end_date,
        'UNDERWRITING'                          as forecast_type,
        max(f.reporting_period_end_date)         as vintage,
        1                                        as n_versions_available,
        count(distinct f.currency_id)            as n_currencies,
        listagg(distinct f.currency_id, ',')
            within group (order by f.currency_id) as currencies,
        max(f.deal_sk)                           as deal_sk,
        max(f.deal_source_sk)                    as deal_source_sk,
        max(f.security_class_sk)                 as security_class_sk,
        max(f.legal_buyer_sk)                    as legal_buyer_sk,
        null                                     as segment_sk,
        sum(f.gross_collection_forecast)         as gross_collection_forecast,
        sum(f.net_collection_forecast)           as net_collection_forecast,
        sum(f.servicing_comission)               as servicing_commission,
        sum(f.passthrough_cost)                  as passthrough_cost,
        sum(f.portfolio_management_fee)          as portfolio_management_fee,
        sum(f.performance_fee)                   as performance_fee,
        sum(f.execution_fee)                     as execution_fee
    from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY as f
    cross join bounds as b
    where f.period_end_date > b.start_date and f.period_end_date <= b.end_date
    group by 1, 2
),

accounting as (
    select
        f.portfolio_sk, f.period_end_date,
        'ACCOUNTING'                             as forecast_type,
        max(f.reporting_period_end_date)         as vintage,
        count(distinct f.snapshot_version)       as n_versions_available,
        count(distinct f.currency_id)            as n_currencies,
        listagg(distinct f.currency_id, ',')
            within group (order by f.currency_id) as currencies,
        max(f.deal_sk)                           as deal_sk,
        max(f.deal_source_sk)                    as deal_source_sk,
        max(f.security_class_sk)                 as security_class_sk,
        max(f.legal_buyer_sk)                    as legal_buyer_sk,
        null                                     as segment_sk,
        sum(f.gross_collection_forecast)         as gross_collection_forecast,
        sum(f.net_collection_forecast)           as net_collection_forecast,
        sum(f.servicing_comission)               as servicing_commission,
        sum(f.passthrough_cost)                  as passthrough_cost,
        sum(f.portfolio_management_fee)          as portfolio_management_fee,
        sum(f.performance_fee)                   as performance_fee,
        sum(f.execution_fee)                     as execution_fee
    from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY as f
    cross join bounds as b
    where f.period_end_date > b.start_date and f.period_end_date <= b.end_date
    group by 1, 2
),

servicer_latest as (
    -- ⚠ THE DOUBLE-COUNT GUARD. Keep only the newest snapshot_version per
    -- portfolio-month before aggregating; see the header. n_versions is
    -- counted BEFORE the filter so the roll-up can report what was dropped.
    select f.*,
           count(distinct f.snapshot_version) over (
               partition by f.portfolio_sk, f.period_end_date
           ) as n_versions_available
    from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY as f
    cross join bounds as b
    where f.period_end_date > b.start_date and f.period_end_date <= b.end_date
    qualify f.snapshot_version = max(f.snapshot_version) over (
        partition by f.portfolio_sk, f.period_end_date
    )
),

servicer as (
    select
        s.portfolio_sk, s.period_end_date,
        'SERVICER'                               as forecast_type,
        max(s.reporting_period_end_date)         as vintage,
        max(s.n_versions_available)              as n_versions_available,
        count(distinct s.currency_id)            as n_currencies,
        listagg(distinct s.currency_id, ',')
            within group (order by s.currency_id) as currencies,
        max(s.deal_sk)                           as deal_sk,
        max(s.deal_source_sk)                    as deal_source_sk,
        max(s.security_class_sk)                 as security_class_sk,
        max(s.legal_buyer_sk)                    as legal_buyer_sk,
        max(s.segment_sk)                        as segment_sk,
        sum(s.gross_collection_forecast)         as gross_collection_forecast,
        sum(s.net_collection_forecast)           as net_collection_forecast,
        sum(s.servicing_comission)               as servicing_commission,
        sum(s.passthrough_cost)                  as passthrough_cost,
        sum(s.portfolio_management_fee)          as portfolio_management_fee,
        sum(s.performance_fee)                   as performance_fee,
        sum(s.execution_fee)                     as execution_fee
    from servicer_latest as s
    group by 1, 2
),

stacked as (
    select * from underwriting
    union all select * from accounting
    union all select * from servicer
)

select
    ps.portfolio_bk,
    f.period_end_date,
    f.forecast_type,                        -- UNDERWRITING / ACCOUNTING / SERVICER
    f.vintage                               as reporting_period_end_date,
    f.n_versions_available,                 -- >1 means revisions existed and
                                            -- only the newest was kept
    f.period_end_date <= current_date()     as is_actual_period,

    dd.deal_bk,
    dd.deal_alias,
    ds.deal_source_name,                    -- use this, not reporting system
    sg.segment_name,                        -- SERVICER rows only
    sc.security_class_name,
    lb.legal_buyer_name,
    f.currencies,
    f.n_currencies,                         -- ⚠ >1 means money was mixed

    -- ---- the forecast ----------------------------------------------------
    f.gross_collection_forecast,
    f.net_collection_forecast,
    f.gross_collection_forecast - f.net_collection_forecast
                                            as forecast_servicing_cost,

    -- ---- cost breakdown --------------------------------------------------
    f.servicing_commission,
    f.passthrough_cost,
    f.portfolio_management_fee,
    f.performance_fee,
    f.execution_fee

from stacked as f
inner join portfolio_scope                     as ps on ps.portfolio_sk      = f.portfolio_sk
left  join PROD.NPL_COMMON.DIM_DEAL            as dd on dd.deal_sk           = f.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE     as ds on ds.deal_source_sk    = f.deal_source_sk
left  join PROD.NPL_COMMON.DIM_SEGMENT         as sg on sg.segment_sk        = f.segment_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS  as sc on sc.security_class_sk = f.security_class_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER     as lb on lb.legal_buyer_sk    = f.legal_buyer_sk
order by ps.portfolio_bk, f.period_end_date, f.forecast_type
limit $row_limit
