-- ============================================================================
-- base_collection — BASE: one row per collection transaction.
-- GRAIN: one row per row of FCT_CASE_COLLECTION. See the key warning below.
-- ============================================================================
-- The lowest-grain money table in the warehouse: every individual payment,
-- reversal and charge-back, with all dimensions resolved to readable names.
-- Everything else that reports collections is an aggregate of this.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/base_collection.sql
--   Notebook  : datalake.q("servicing/prod/base_collection")
--
-- ---------------------------------------------------------------------------
-- ⚠ COLLECTION_BK IS NOT A ROW KEY. DO NOT DEDUPE ON IT.
-- Measured 2026-09-09 on all 134,097,608 rows: only 90,390,143 distinct
-- COLLECTION_BK values, and 69,551 rows where it is NULL. 4,141,626 of those
-- keys are shared by 47,779,540 rows — 36% of the table, EUR 10.6bn.
--
-- In ZERO of those 4.1M cases are the sharing rows identical: every one
-- differs on (CASE_SK, COLLECTION_DATE, AMOUNT). They are genuinely
-- different payments that happen to carry the same business key. So
-- `select distinct` or a qualify-dedupe on COLLECTION_BK would silently
-- delete about a third of real collections.
--
-- The grain of this file is therefore the fact row itself. There is no
-- column that uniquely identifies a payment. If you need one, build a
-- surrogate — but treat that as your key, not the warehouse's.
--
-- ⚠ NEGATIVE AMOUNTS ARE REAL AND ARE KEPT. 1,967,954 rows (1.5%) are
-- negative: reversals, refunds and charge-backs. sum(AMOUNT) is therefore
-- NET, which is the right basis for recovery. Do not filter them and do not
-- use abs(). IS_REVERSAL below flags them if you need the split.
--
-- ⚠ UPPER DATE BOUND IS DELIBERATE. 841 rows are dated in the future — 741
-- in 2099, single rows out to the year 4570. Unbounded they create phantom
-- future months on every time axis. ~EUR 72k in total, so the guard costs
-- nothing real. A known warehouse problem, not one this query introduces.
--
-- ⚠ MIXED CURRENCIES. CURRENCY_ID is part of what a row means. Never sum
-- AMOUNT across rows without filtering to one currency or converting first
-- — see ref_fx_rate.sql.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY — CHECK IT BEFORE YOU AGGREGATE.
-- 134M rows sit behind this. A truncated result still sums, averages and
-- charts perfectly happily, and the total is simply wrong. If the row count
-- comes back exactly equal to $row_limit, assume it was cut: narrow
-- $portfolio_filter, shorten the window, or raise the cap deliberately.
-- ============================================================================

-- Window. Keep it tight: this is the 134M-row fact.
set date_from = '2026-01-01';
set date_to   = '2026-07-31';

-- '%' is all 250 portfolios. Keep a filter or the cap will bite.
set portfolio_filter = 'LOK-DE24016-U01/2512';

set row_limit = 200000;


with portfolio_scope as (
    -- Resolve to surrogate keys first so the fact is pruned on PORTFOLIO_SK
    -- before anything else touches it.
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
)

select
    -- ---- what the payment was -------------------------------------------
    c.collection_date,
    c.amount,
    c.currency_id,                       -- ⚠ part of the meaning; see header
    c.amount < 0                         as is_reversal,
    c.collection_bk,                     -- ⚠ NOT unique; never dedupe on it
    date_trunc(month, c.collection_date) as collection_month,
    last_day(c.collection_date)          as month_end,

    -- ---- which loan -----------------------------------------------------
    dc.case_bk,                          -- durable loan key: count on this
    c.case_id,
    c.case_sk,                           -- versioned key: joins to facts only

    -- ---- where it sits --------------------------------------------------
    ps.portfolio_bk,
    db.batch_bk,
    dd.deal_bk,
    dd.deal_alias,
    dd.seller_name,
    ds.deal_source_name,
    sg.segment_name,
    sc.security_class_name,
    dp.product_eba_type,
    lb.legal_buyer_name,
    lb.ownership_share,
    rs.servicer_name,                    -- populated here, unlike at
    rs.reporting_system_name,            -- portfolio level
    c.country_id,
    coalesce(co.country_name, c.country_id, 'Unknown') as country_name,
    cu.currency_name

from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
inner join portfolio_scope                       as ps on ps.portfolio_sk      = c.portfolio_sk
-- DIM_CASE is SCD2 and the fact carries the versioned CASE_SK, so join on
-- CASE_SK alone. Adding `and dc.is_current_flag` would silently drop loans
-- whose attributes changed — measured at 2.8% on the snapshot fact.
left  join PROD.NPL_COMMON.DIM_CASE              as dc on dc.case_sk           = c.case_sk
left  join PROD.NPL_COMMON.DIM_BATCH             as db on db.batch_sk          = c.batch_sk
left  join PROD.NPL_COMMON.DIM_DEAL              as dd on dd.deal_sk           = c.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE       as ds on ds.deal_source_sk    = c.deal_source_sk
left  join PROD.NPL_COMMON.DIM_SEGMENT           as sg on sg.segment_sk        = c.segment_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS    as sc on sc.security_class_sk = c.security_class_sk
left  join PROD.NPL_COMMON.DIM_PRODUCT           as dp on dp.product_sk        = c.product_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER       as lb on lb.legal_buyer_sk    = c.legal_buyer_sk
left  join PROD.NPL_COMMON.DIM_REPORTING_SYSTEM  as rs on rs.reporting_system_sk = c.reporting_system_sk
-- ⚠ COUNTRY: join on ISO_ALPHA2_CODE, NOT country_id. Found 2026-09-09:
-- DIM_COUNTRY.COUNTRY_ID is a hash key while the facts carry ISO alpha-2
-- codes ('ES', 'FI'), so the natural-looking join on country_id matches zero
-- rows and country_name comes back NULL everywhere. The fact also carries a
-- non-ISO 'UK' that matches nothing; it is kept as the raw code so it stays
-- visible rather than collapsing into 'Unknown'.
left  join PROD.COMMON.DIM_COUNTRY               as co on co.iso_alpha2_code   = c.country_id
left  join PROD.COMMON.DIM_CURRENCY              as cu on cu.currency_alpha_code = c.currency_id
where c.collection_date >= $date_from::date
  and c.collection_date <= $date_to::date
  -- Guard against the future-dated rows even if $date_to is moved out.
  and c.collection_date <= current_date()
order by c.collection_date desc, c.amount desc
limit $row_limit
