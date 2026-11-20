-- ============================================================================
-- monthly_portfolio_restatement — has a reported month CHANGED since we
-- first reported it?
-- GRAIN: one row per (PORTFOLIO_BK, PERIOD_END_DATE, SNAPSHOT_VERSION).
-- ============================================================================
-- monthly_portfolio_performance.sql shows the CURRENT view of each month.
-- This shows every version of it. Servicers restate: a month reported in
-- March can be reported differently in April. Use this to size restatements
-- before explaining a movement as business performance.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/monthly_portfolio_restatement.sql
--   Notebook  : datalake.q("servicing/prod/monthly_portfolio_restatement")
--
-- ---------------------------------------------------------------------------
-- GRAIN verified 2026-09-09 on FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED:
-- 20,697,455 rows, unique on (PORTFOLIO_SK, PERIOD_END_DATE, BATCH_SK,
-- SNAPSHOT_VERSION) — zero duplicate keys. This query rolls the batch grain
-- up to the portfolio, so its own grain is portfolio × month × version.
--
-- 4 rows carry a NULL BATCH_SK. They survive the roll-up (it groups on
-- portfolio, not batch) but would vanish from any batch-level analysis.
--
-- ⚠ THIS TABLE HAS FAR MORE HISTORY THAN THE COLLAPSED ONE.
-- It spans 1996-08-31 .. 2026-08-31 across 15 snapshot versions, against
-- 1,544,877 rows in FCT_PORTFOLIO_SNAPSHOT_MONTHLY. Do not read the extra
-- history as extra business: pre-acquisition months are seller-supplied
-- context, and a portfolio's own data starts at its capex date (see
-- ref_portfolio.sql).
--
-- ⚠ NEVER SUM ACROSS SNAPSHOT_VERSION. That is the whole point of the file.
-- Two versions of the same month are the same money reported twice. Summing
-- them inflates by roughly the version count. Either filter to one version,
-- or use the IS_LATEST_VERSION flag, or compare versions side by side — but
-- never aggregate over them. monthly_portfolio_performance.sql is the file
-- that already collapses this correctly.
--
-- ⚠ RESTATEMENT IS THE NORM HERE, NOT THE EXCEPTION. Measured 2026-09-09:
--   all history      6,582 portfolio-months, 6,301 restated — 95.7%
--   last 12 months   2,033 portfolio-months, 1,752 restated — 86.2%
--   up to 15 versions of a single month
-- Only 281 portfolio-months in the whole table have ever had exactly one
-- version. So "the number changed" is the default state of this data, and
-- any month-on-month movement read off a single vintage is partly
-- restatement rather than performance. That is the reason this file exists.
--
-- N_VERSIONS_FOR_MONTH tells you how many versions a row's month has;
-- RESTATEMENT_VS_PREVIOUS is NULL on a month's first version, which is a
-- window edge and not a data gap.
--
-- ⚠ CURRENCY IS PART OF THE GRAIN of the source but is rolled up here, so
-- N_CURRENCIES exposes when a row mixes them. See ref_fx_rate.sql.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY — CHECK IT BEFORE YOU AGGREGATE.
-- ============================================================================

set month_end        = '2026-07-31';
set months_back      = 12;
set portfolio_filter = '%';
set row_limit        = 200000;


with bounds as (
    select $month_end::date                                    as end_date,
           dateadd(month, -1 * $months_back, $month_end::date)  as start_date
),

portfolio_scope as (
    -- ⚠ THE UNION RETAINS THE UNKNOWN PORTFOLIO. DO NOT REMOVE IT.
    -- FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED carries PORTFOLIO_SK = '-1',
    -- the Unknown sentinel, which does not exist in DIM_PORTFOLIO (that
    -- dimension is keyed by hash, so -1 matches nothing). Measured
    -- 2026-09-09: 13,707 rows holding EUR 153.61bn of balance. An inner join
    -- through DIM_PORTFOLIO silently drops all of it. Labelled rather than
    -- hidden; it matches $portfolio_filter = '%' and any narrower filter
    -- excludes it.
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter

    union all

    select f.portfolio_sk,
           '(unknown portfolio ' || f.portfolio_sk || ')' as portfolio_bk
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED as f
    where f.portfolio_sk not in (select portfolio_sk from PROD.NPL_COMMON.DIM_PORTFOLIO)
      and ('(unknown portfolio ' || f.portfolio_sk || ')') like $portfolio_filter
    group by f.portfolio_sk
),

by_version as (
    -- Roll the batch grain up to portfolio × month × version.
    select
        v.portfolio_sk,
        v.period_end_date,
        v.snapshot_version,
        count(*)                                as n_batch_rows,
        count(distinct v.batch_sk)              as n_batches,
        count(distinct v.currency_id)           as n_currencies,
        listagg(distinct v.currency_id, ',')
            within group (order by v.currency_id) as currencies,
        max(v.deal_sk)                          as deal_sk,
        max(v.deal_source_sk)                   as deal_source_sk,
        sum(v.total_balance)                    as total_balance,
        sum(v.gross_cash_recoveries)            as gross_cash_recoveries,
        sum(v.net_cash_recoveries)              as net_cash_recoveries,
        sum(v.portfolio_mgmt_fee)               as portfolio_mgmt_fee,
        sum(v.commission)                       as commission,
        sum(v.passthrough_cost)                 as passthrough_cost,
        sum(v.unremitted_collections)           as unremitted_collections
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED as v
    cross join bounds as b
    where v.period_end_date >  b.start_date
      and v.period_end_date <= b.end_date
    group by 1, 2, 3
)

select
    ps.portfolio_bk,
    v.period_end_date,
    v.snapshot_version,

    -- ---- how many versions this month has, and is this the newest --------
    count(*) over (partition by v.portfolio_sk, v.period_end_date)
                                            as n_versions_for_month,
    v.snapshot_version = max(v.snapshot_version) over (
        partition by v.portfolio_sk, v.period_end_date
    )                                       as is_latest_version,

    ds.deal_source_name,
    dd.deal_bk,
    v.currencies,
    v.n_currencies,                         -- ⚠ >1 means money was mixed
    v.n_batches,

    -- ---- the numbers as at this version ---------------------------------
    v.gross_cash_recoveries,
    v.net_cash_recoveries,
    v.total_balance,
    v.portfolio_mgmt_fee,
    v.commission,
    v.passthrough_cost,
    v.unremitted_collections,

    -- ---- the restatement -------------------------------------------------
    -- NULL on a month's first version: nothing precedes it. A window edge,
    -- not missing data.
    lag(v.gross_cash_recoveries) over (
        partition by v.portfolio_sk, v.period_end_date order by v.snapshot_version
    )                                       as gross_previous_version,
    v.gross_cash_recoveries - lag(v.gross_cash_recoveries) over (
        partition by v.portfolio_sk, v.period_end_date order by v.snapshot_version
    )                                       as restatement_vs_previous,
    div0null(
        v.gross_cash_recoveries - lag(v.gross_cash_recoveries) over (
            partition by v.portfolio_sk, v.period_end_date order by v.snapshot_version
        ),
        abs(lag(v.gross_cash_recoveries) over (
            partition by v.portfolio_sk, v.period_end_date order by v.snapshot_version
        ))
    )                                       as restatement_pct

from by_version as v
inner join portfolio_scope                 as ps on ps.portfolio_sk   = v.portfolio_sk
left  join PROD.NPL_COMMON.DIM_DEAL        as dd on dd.deal_sk        = v.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE as ds on ds.deal_source_sk = v.deal_source_sk
order by ps.portfolio_bk, v.period_end_date desc, v.snapshot_version
limit $row_limit
