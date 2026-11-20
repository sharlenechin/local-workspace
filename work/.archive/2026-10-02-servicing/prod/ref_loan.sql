-- ============================================================================
-- ref_loan — REFERENCE: one row per loan, all dimensions joined.
-- GRAIN: one row per CASE_SK per $month_end.
-- ============================================================================
-- The spine of the servicing analysis. One row per case (loan) that was on
-- book at $month_end, with every dimension resolved to readable names, the
-- month-end balance, borrower count, and collection history.
--
-- Runs three ways without editing:
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/ref_loan.sql
--   Notebook  : datalake.q("servicing/prod/ref_loan")
--
-- ---------------------------------------------------------------------------
-- GRAIN: exactly one row per CASE_SK per $month_end. Verified unique —
-- FCT_CASE_SNAPSHOT_DAILY has row count == count(distinct case_sk) on every
-- month-end tested. No dedupe needed, no fan-out from the dimension joins.
--
-- ⚠ WHY THE SPINE IS THE SNAPSHOT, NOT DIM_CASE.
-- DIM_CASE carries no portfolio, batch, deal or segment key — only
-- REPORTING_SYSTEM_SK. Every other dimension lives on the fact tables. So a
-- loan can only be placed in a portfolio *as at a date*, which is what this
-- query does. The consequence: a loan that had already closed and dropped
-- off the book before $month_end is NOT in this result. Move $month_end back
-- to see the book as it was then.
--
-- ⚠ DO NOT ADD `and c.is_current_flag` TO THE DIM_CASE JOIN.
-- DIM_CASE is SCD Type 2: 153.7M version rows for 22.5M real loans, and the
-- fact tables carry the *versioned* CASE_SK, i.e. the version in force at the
-- snapshot date. Measured at 2026-07-31: all 21,832,423 snapshot rows match a
-- DIM_CASE version, but only 21,225,667 match the *current* version. Filtering
-- on is_current_flag silently discards 606,756 loans (2.8%) with no error.
-- Joining on CASE_SK alone is both complete and point-in-time correct.
--
-- ⚠ COUNT LOANS WITH count(distinct case_bk), NOT case_sk.
-- CASE_BK is the durable key for a loan; CASE_SK identifies one *version* of
-- it. Within a single $month_end they are 1:1, but the moment you union two
-- months, CASE_SK double-counts any loan whose attributes changed.
-- ---------------------------------------------------------------------------
-- KNOWN NULLS on the 22.5M current loans — measured, not guessed:
--   ORIGINATION_DATE     95.4% null   -- effectively unusable
--   BACKSTOP_DATE        98.4% null   -- effectively unusable
--   ORIGINAL_PRINCIPAL   85.5% null   -- cannot compute recovery-on-original
--   SECURED_FLAG         68.5% null   -- use SECURITY_CLASS_NAME instead,
--                                     -- which is populated from the servicer
--   CLOSING_DATE         58.9% null   -- expected: only closed cases have one
--   REGISTRATION_DATE    10.4% null
--   DEFAULT_DATE          2.4% null   -- DERIVED_DEFAULT_DATE fills most of
--                                     -- the gap and is only 0.7% null
--   STATUS_CODE           0.4% null
-- Prefer DERIVED_DEFAULT_DATE over DEFAULT_DATE for any vintage analysis.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY — CHECK IT BEFORE YOU AGGREGATE.
-- The cap exists so an accidental '%' filter cannot pull tens of millions of
-- rows into pandas. But a truncated result still sums, averages and charts
-- perfectly happily, and the total is simply wrong. If the row count comes
-- back exactly equal to $row_limit, assume it was cut: narrow
-- $portfolio_filter, shorten the window, or raise the cap deliberately.
-- ============================================================================

-- The reporting month-end. Must be an actual month-end date present in
-- FCT_CASE_SNAPSHOT_DAILY (147 of them, 2014-06-30 .. 2026-08-31).
--
-- ⚠ 2026-08-31 is the newest month-end but it is NOT fully loaded: only
-- 7 portfolios have portfolio-level rows for it vs 250 for 2026-07-31.
-- Loan-level data looks more complete, but do not compare August against
-- earlier months until the portfolio-level load catches up.
set month_end = '2026-07-31';

-- Narrow the result. '%' is all 250 portfolios / ~21.8M loans, which is far
-- too much to pull into pandas — keep a filter or a row cap in place.
-- Examples: 'GCB-ES26%'  'IT25%'
set portfolio_filter = 'LOK-DE24016-U01/2512';

-- Safety cap on rows returned. Raise deliberately.
set row_limit = 50000;


with portfolio_scope as (
    -- Resolve the filter to surrogate keys first, so the 1.47bn-row snapshot
    -- is pruned on PORTFOLIO_SK before anything else touches it.
    select portfolio_sk, portfolio_bk, capex_date, capex_amount, gbv,
           price_gross, price_net, price_percent, flow_type,
           effective_interest_rate, uw_unlevered_irr
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
),

book as (
    -- One row per loan on book at $month_end.
    select
        s.case_sk, s.case_id, s.date_day,
        s.portfolio_sk, s.batch_sk, s.deal_sk, s.segment_sk,
        s.security_class_sk, s.deal_source_sk, s.legal_buyer_sk,
        s.reporting_system_sk, s.product_sk,
        s.country_id, s.currency_id,
        s.forbearance_flag,
        s.outstanding_principal, s.outstanding_interest,
        s.outstanding_fees, s.outstanding_total
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    inner join portfolio_scope as p on p.portfolio_sk = s.portfolio_sk
    where s.date_day = $month_end::date
),

borrower_count as (
    -- How many borrowers are on each loan. Counted separately rather than
    -- joined in: BRG_CASE_BORROWER holds 229M rows for 143.6M case versions,
    -- and 8.2M of the 22.5M current loans have 2+ borrowers. Joining the
    -- bridge directly would inflate the loan count by ~36%.
    select b.case_sk, count(distinct b.borrower_sk) as n_borrowers
    from PROD.NPL_COMMON.BRG_CASE_BORROWER as b
    inner join book on book.case_sk = b.case_sk
    group by 1
),

collections as (
    -- Collection history to $month_end, per loan.
    --
    -- ⚠ UPPER DATE BOUND IS DELIBERATE. FCT_CASE_COLLECTION contains 841
    -- rows dated in the future — 741 in 2099, and single rows out to the
    -- year 4570. Left unbounded they leak into "lifetime" totals and create
    -- phantom future months. They are ~EUR 72k in total, so the guard costs
    -- nothing real and prevents a nonsense date axis.
    --
    -- ⚠ NEGATIVE AMOUNTS ARE REAL AND ARE KEPT. 1,967,954 rows (1.5%) are
    -- negative — reversals, refunds and charge-backs. sum(amount) is
    -- therefore NET of reversals, which is the right basis for recovery.
    -- Do not filter them out; do not use abs().
    select
        c.case_sk,
        sum(c.amount)                                        as collected_lifetime,
        count(*)                                             as n_payments_lifetime,
        sum(iff(c.amount < 0, c.amount, 0))                  as reversals_lifetime,
        max(c.collection_date)                               as last_collection_date,
        sum(iff(c.collection_date > dateadd(month, -12, $month_end::date),
                c.amount, 0))                                as collected_12m,
        sum(iff(date_trunc(month, c.collection_date)
                = date_trunc(month, $month_end::date),
                c.amount, 0))                                as collected_in_month
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join book on book.case_sk = c.case_sk
    where c.collection_date <= $month_end::date
    group by 1
),

forbearance as (
    -- ⚠ THIS IS ONE ROW PER CASE, NOT PER EVENT. Measured 2026-09-09:
    -- 5,761,218 rows and 5,761,218 distinct CASE_SK, exactly. So
    -- N_FORBEARANCE_EVENTS below is always 1 and FIRST_ = LAST_ always. The
    -- aggregation is kept only so the CTE cannot fan out if the grain ever
    -- changes; do not read the count as an event count.
    --
    -- The table has THREE columns: CASE_SK, FORBEARANCE_START_DATE,
    -- AS_OF_TS. There is no end date, no type and no status, so duration,
    -- cure and re-default cannot be measured from it. Current forbearance
    -- state comes from FCT_CASE_SNAPSHOT_DAILY.FORBEARANCE_FLAG instead.
    --
    -- ⚠ THE FLAG AND THIS TABLE DISAGREE ON ~141k LOANS. At 2026-07-31:
    -- 5,493,364 loans are flagged True but only 5,353,222 have a row here
    -- (140,142 missing), and 955 loans flagged False do have one. Pick one
    -- source per number and say which.
    --
    -- ⚠ DATES ARE NOT ALL PLAUSIBLE: 42,810 rows start before 1990 (earliest
    -- 1967-11-01) and 6 are dated in the future (latest 2026-12-03). Guard
    -- the range before using the date for vintage or ageing.
    select f.case_sk,
           min(f.forbearance_start_date) as first_forbearance_date,
           max(f.forbearance_start_date) as last_forbearance_date,
           count(*)                      as n_forbearance_events
    from PROD.NPL_COMMON.FCT_CASE_FORBEARANCE as f
    inner join book on book.case_sk = f.case_sk
    group by 1
)

select
    -- ---- identity -------------------------------------------------------
    dc.case_bk,                          -- durable loan key: count on this
    book.case_id,
    book.case_sk,                        -- versioned key: joins to facts only
    book.date_day                        as as_of_month_end,

    -- ---- where the loan sits --------------------------------------------
    ps.portfolio_bk,
    db.batch_bk,
    dd.deal_bk,
    dd.deal_name,
    dd.deal_alias,
    dd.seller_name,
    dd.deal_close_date,
    ds.deal_source_name,                 -- LEGACY / ORANGE-HEIMDALL / BLUE-LOKI
                                         -- / GESCOBRO / ORGANIC ORIGINATED
    sg.segment_name,
    dp.product_eba_type,
    dp.original_product_name,
    sc.security_class_name,              -- Secured / Unsecured — use this
                                         -- rather than the 68% null flag
    lb.legal_buyer_name,
    lb.ownership_share,
    lb.is_on_balance_sheet,
    rs.servicer_name,                    -- cerved / intrum / gescobro / souq
                                         -- / massey / Unknown
    rs.reporting_system_name,
    book.country_id,
    book.currency_id,                    -- ⚠ MIXED CURRENCIES. Never sum
                                         -- money across rows without either
                                         -- filtering to one currency or
                                         -- converting via
                                         -- COMMON.FCT_EXCHANGE_RATE_MONTHLY.

    -- ---- loan attributes (see null rates in the header) ------------------
    dc.status_code,
    dc.status_date,
    dc.closing_code,
    dc.closing_date,
    dc.default_date,
    dc.derived_default_date,             -- prefer this: 0.7% null vs 2.4%
    dc.origination_date,                 -- 95.4% null
    dc.registration_date,
    dc.original_principal,               -- 85.5% null
    dc.secured_flag,                     -- 68.5% null
    dc.is_current_flag                   as case_version_is_current,

    -- ---- balances at $month_end -----------------------------------------
    book.outstanding_principal,
    book.outstanding_interest,
    book.outstanding_fees,
    book.outstanding_total,
    book.forbearance_flag,
    fb.first_forbearance_date,
    fb.n_forbearance_events,

    -- ---- people ----------------------------------------------------------
    coalesce(bc.n_borrowers, 0)          as n_borrowers,

    -- ---- collections -----------------------------------------------------
    coalesce(cl.collected_lifetime, 0)   as collected_lifetime,
    coalesce(cl.collected_12m, 0)        as collected_12m,
    coalesce(cl.collected_in_month, 0)   as collected_in_month,
    coalesce(cl.n_payments_lifetime, 0)  as n_payments_lifetime,
    coalesce(cl.reversals_lifetime, 0)   as reversals_lifetime,
    cl.last_collection_date,
    datediff(month, cl.last_collection_date, $month_end::date)
                                         as months_since_last_payment,
    iff(coalesce(cl.collected_12m, 0) > 0, true, false)
                                         as is_paying_12m,

    -- ---- portfolio economics (context, same for every loan in a folio) ---
    ps.capex_date                        as portfolio_capex_date,
    ps.gbv                               as portfolio_gbv,
    ps.price_gross                       as portfolio_price_gross,
    ps.price_percent                     as portfolio_price_percent,
    ps.flow_type                         as portfolio_flow_type

from book
inner join PROD.NPL_COMMON.DIM_CASE           as dc on dc.case_sk           = book.case_sk
inner join portfolio_scope                    as ps on ps.portfolio_sk      = book.portfolio_sk
left  join PROD.NPL_COMMON.DIM_BATCH          as db on db.batch_sk          = book.batch_sk
left  join PROD.NPL_COMMON.DIM_DEAL           as dd on dd.deal_sk           = book.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE    as ds on ds.deal_source_sk    = book.deal_source_sk
left  join PROD.NPL_COMMON.DIM_SEGMENT        as sg on sg.segment_sk        = book.segment_sk
left  join PROD.NPL_COMMON.DIM_PRODUCT        as dp on dp.product_sk        = book.product_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS as sc on sc.security_class_sk = book.security_class_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER    as lb on lb.legal_buyer_sk    = book.legal_buyer_sk
left  join PROD.NPL_COMMON.DIM_REPORTING_SYSTEM as rs on rs.reporting_system_sk = book.reporting_system_sk
left  join borrower_count as bc on bc.case_sk = book.case_sk
left  join collections    as cl on cl.case_sk = book.case_sk
left  join forbearance    as fb on fb.case_sk = book.case_sk
order by book.outstanding_total desc nulls last
limit $row_limit
