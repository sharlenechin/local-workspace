-- ============================================================================
-- ref_calendar — REFERENCE: one row per month-end, with data-availability flags.
-- GRAIN: one row per MONTH_END_DATE. Verified genuinely unique.
-- ============================================================================
-- The spine for any dense monthly series. monthly_borrower_collections and
-- monthly_loan_performance return only months that HAVE rows, so a customer
-- who paid in January and March has no February row at all. Join or reindex
-- against this to turn "absent" into an explicit zero.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/ref_calendar.sql
--   Notebook  : datalake.q("servicing/prod/ref_calendar")
--
-- ---------------------------------------------------------------------------
-- GRAIN verified 2026-09-09: COMMON.DIM_MONTH has 794 rows and 794 distinct
-- MONTH_END_DATE, spanning 2000-01-31 .. 2066-02-28.
--
-- ⚠ THE CALENDAR IS MUCH WIDER THAN THE DATA. THAT IS THE POINT, AND THE TRAP.
-- DIM_MONTH runs to 2066. Nothing in the warehouse has data anywhere near
-- that. A left join from this table produces a row for every month whether
-- or not anything happened, so an unfiltered chart shows forty years of
-- flat zero and a "total" divided by 794 months is meaningless.
--
-- The HAS_* flags below are measured live against each fact, so filter on
-- them rather than hardcoding a window. Known extents, 2026-09-09:
--   loan balances   FCT_CASE_SNAPSHOT_DAILY     147 month-ends, 2014-06-30+
--   collections     FCT_CASE_COLLECTION         (plus 841 future-dated rows)
--   portfolio month FCT_PORTFOLIO_SNAPSHOT_MONTHLY
--   loan carrying   MART_..._CASE_ALLOCATION    only 9, 2025-12-31 ..
--                                               2026-08-31
--
-- ⚠ IS_COMPLETE_LOAD IS A HEURISTIC, NOT A FACT FROM THE WAREHOUSE.
-- It flags a month whose portfolio count is less than half the previous
-- month's — the signature of the load lag that makes 2026-08-31 look like a
-- collapse in collections. It is the same test base_data_quality runs. Treat
-- a false as "check before reporting", not as proof of a business event.
--
-- No row cap: the filtered calendar is small by construction.
-- ============================================================================

-- Bound the calendar to something useful. Defaults cover the warehouse's
-- real range with a little headroom.
set date_from = '2014-01-31';
set date_to   = '2026-12-31';


with months as (
    select month_id, month_end_date, month_start_date, month_name,
           short_month_name, month, quarter, year
    from PROD.COMMON.DIM_MONTH
    where month_end_date >= $date_from::date
      and month_end_date <= $date_to::date
),

loan_balance_months as (
    select date_day as month_end, count(*) as n_loan_rows,
           count(distinct portfolio_sk) as n_portfolios_loan_level
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
    where date_day >= $date_from::date and date_day <= $date_to::date
    group by 1
),

collection_months as (
    -- Bounded to today as well as to $date_to: 841 rows are dated in the
    -- future (741 in 2099, one in 4570) and would flag phantom months.
    select last_day(collection_date) as month_end,
           count(*) as n_collection_rows, sum(amount) as collected
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION
    where collection_date >= $date_from::date
      and collection_date <= least($date_to::date, current_date())
    group by 1
),

portfolio_months as (
    select period_end_date as month_end,
           count(*) as n_portfolio_rows,
           count(distinct portfolio_sk) as n_portfolios
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    where period_end_date >= $date_from::date and period_end_date <= $date_to::date
    group by 1
),

carrying_months as (
    select date_day as month_end, count(*) as n_carrying_rows
    from PROD.NPL_COMMON.MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION
    where date_day >= $date_from::date and date_day <= $date_to::date
    group by 1
)

select
    m.month_end_date                        as month_end,
    m.month_start_date,
    m.month_id,
    m.year,
    m.quarter,
    m.month,
    m.month_name,
    m.short_month_name,
    m.month_end_date <= current_date()      as is_past,

    -- ---- what actually exists for this month -----------------------------
    coalesce(lb.n_loan_rows, 0)             as n_loan_balance_rows,
    lb.n_portfolios_loan_level,
    coalesce(cm.n_collection_rows, 0)       as n_collection_rows,
    cm.collected,                           -- ⚠ mixes currencies; ratio only
    coalesce(pm.n_portfolio_rows, 0)        as n_portfolio_rows,
    pm.n_portfolios,
    coalesce(cy.n_carrying_rows, 0)         as n_loan_carrying_rows,

    lb.n_loan_rows      is not null         as has_loan_balances,
    cm.n_collection_rows is not null        as has_collections,
    pm.n_portfolio_rows is not null         as has_portfolio_month,
    cy.n_carrying_rows  is not null         as has_loan_carrying,

    -- ---- load-lag heuristic; see header ----------------------------------
    lag(pm.n_portfolios) over (order by m.month_end_date)
                                            as prior_n_portfolios,
    coalesce(
        pm.n_portfolios >= 0.5 * lag(pm.n_portfolios) over (order by m.month_end_date),
        false
    )                                       as is_complete_load

from months as m
left join loan_balance_months as lb on lb.month_end = m.month_end_date
left join collection_months   as cm on cm.month_end = m.month_end_date
left join portfolio_months    as pm on pm.month_end = m.month_end_date
left join carrying_months     as cy on cy.month_end = m.month_end_date
order by m.month_end_date desc
