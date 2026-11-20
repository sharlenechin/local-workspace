-- ============================================================================
-- monthly_loan_performance — LOAN × MONTH: collections and balance per month.
-- GRAIN: one row per (CASE_SK, MONTH_END).
-- ============================================================================
-- One row per loan per month-end. Balance from the snapshot, collections
-- aggregated to the month, plus a roll-forward (opening → collections →
-- closing) so you can see amortisation and recovery per loan over time.
--
--   Terminal : mise run sql -- work/servicing/prod/monthly_loan_performance.sql
--   Notebook : datalake.q("servicing/prod/monthly_loan_performance")
--
-- ---------------------------------------------------------------------------
-- GRAIN: one row per (CASE_SK, MONTH_END). Guaranteed, not hoped for:
-- FCT_CASE_SNAPSHOT_DAILY is unique on (case_sk, date_day) — verified on
-- every month-end (row count == count(distinct case_sk) exactly), and the
-- collections CTE is pre-aggregated to (case_sk, month) before it is joined.
-- Nothing here can fan out. Aggregating this table needs no distinct.
--
-- ⚠ THE TABLE IS NAMED "DAILY" BUT IS MONTH-END ONLY.
-- FCT_CASE_SNAPSHOT_DAILY holds 147 distinct dates, every one a true
-- month-end (2014-06-30 .. 2026-08-31); zero non-month-end dates. Do not
-- write a BETWEEN over arbitrary days expecting daily granularity — you get
-- month-ends or nothing. 1.47bn rows, so always bound the date range.
--
-- ⚠ COLLECTIONS AND BALANCES ARE NOT THE SAME POPULATION.
-- A loan can collect in a month and have no snapshot row (it closed), or
-- have a balance and never collect. This query is a LEFT JOIN from the
-- snapshot, so it answers "of the loans on book, what did each collect".
-- Money collected by loans that had already left the book is NOT here — see
-- monthly_portfolio_performance.sql for the complete money view.
-- ---------------------------------------------------------------------------
-- ⚠ OPENING_BALANCE IS NULL IN A LOAN'S FIRST MONTH IN THE WINDOW.
-- It is lag() over the months returned, so the earliest month has nothing
-- before it. That is a window-edge artefact, not missing data — widen
-- $months_back and the earlier month fills in. Do not read it as a gap.
--
-- ⚠ THE WINDOWS PARTITION BY CASE_BK, NOT CASE_SK. DO NOT CHANGE THEM BACK.
-- DIM_CASE is SCD2 and the snapshot carries the versioned CASE_SK, so
-- partitioning the roll-forward on CASE_SK restarts it every time a loan's
-- attributes change. Measured 2026-09-09 on the default portfolio: that hit
-- 5,843 loan-months — 6.0% of rows — where the loan HAS a prior month but
-- OPENING_BALANCE came back NULL, taking BALANCE_MOVEMENT,
-- UNEXPLAINED_MOVEMENT and RECOVERY_RATE_ON_OPENING with it. EUR 989,932 of
-- collections and EUR 110.6m of closing balance sat on those rows. That is
-- not the window edge described above; it was a partition bug, and calling
-- it an edge artefact hid it. CASE_BK is safe here because a loan never has
-- two versions on book at the same month-end (verified, max 1).
--
-- ⚠ BALANCE_MOVEMENT WILL NOT EQUAL -COLLECTED.
-- Balances also move on interest accrual, fees, write-offs, FX and servicer
-- restatements, none of which are collections. The residual is expected and
-- is exposed as UNEXPLAINED_MOVEMENT so you can size it rather than assume
-- it away.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY — CHECK IT BEFORE YOU AGGREGATE.
-- The cap exists so an accidental '%' filter cannot pull tens of millions of
-- rows into pandas. But a truncated result still sums, averages and charts
-- perfectly happily, and the total is simply wrong. If the row count comes
-- back exactly equal to $row_limit, assume it was cut: narrow
-- $portfolio_filter, shorten the window, or raise the cap deliberately.
-- ============================================================================

-- Last month-end to report. See ref_loan for why 2026-08-31 is not the default:
-- it is present but only partly loaded.
set month_end = '2026-07-31';

-- How many months of history, counting back from $month_end.
set months_back = 12;

-- Narrow the loan population. '%' is all 250 portfolios — with 12 months of
-- history that is hundreds of millions of rows. Keep this tight.
set portfolio_filter = 'LOK-DE24016-U01/2512';

set row_limit = 200000;


with portfolio_scope as (
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
),

window_bounds as (
    select
        $month_end::date                                          as end_date,
        dateadd(month, -1 * $months_back, $month_end::date)        as start_date
),

balances as (
    -- The spine: loan × month-end balance.
    select
        s.case_sk, s.case_id, s.date_day as month_end,
        s.portfolio_sk, s.batch_sk, s.reporting_system_sk,
        s.security_class_sk, s.segment_sk, s.legal_buyer_sk,
        s.country_id, s.currency_id, s.forbearance_flag,
        s.outstanding_principal, s.outstanding_interest,
        s.outstanding_fees, s.outstanding_total
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    inner join portfolio_scope as p on p.portfolio_sk = s.portfolio_sk
    cross join window_bounds as w
    where s.date_day > w.start_date
      and s.date_day <= w.end_date
),

monthly_collections as (
    -- ⚠ MATCHED ON CASE_BK, NOT CASE_SK. THIS IS THE FIX FOR A REAL LOSS.
    -- An earlier version of this file joined collections on CASE_SK, the
    -- SCD2 *versioned* key. Measured 2026-09-09 on the default portfolio
    -- (LOK-DE24016-U01/2512, 12 months): 3,243 of 8,104 loans (40%) have
    -- more than one CASE_SK version on book in the window, and 140 of the
    -- versions that received payments never appear in the snapshot at all.
    -- Those payments — EUR 279,459.82 — were silently dropped, and the loan
    -- month row still looked perfectly normal, just with COLLECTED too low.
    -- A wrong number that looks right is worse than a missing row.
    --
    -- Matching on the durable CASE_BK captures every version's payments.
    -- This CANNOT fan out: verified that a loan never has two CASE_SK
    -- versions on book at the same month-end (max 1 across all 97,232
    -- loan-months), so (CASE_BK, MONTH_END) is unique.
    --
    -- Pruned on PORTFOLIO_SK first so the 134M-row fact is cut before
    -- DIM_CASE (153.7M versions) is touched.
    --
    -- ⚠ UPPER BOUND ON COLLECTION_DATE IS DELIBERATE — 841 rows are dated
    -- in the future (741 in 2099, one in the year 4570). Without the bound
    -- they create phantom months at the end of every time series.
    --
    -- ⚠ Negative amounts (1.5% of rows) are reversals and are kept, so
    -- COLLECTED is net. GROSS_RECEIPTS / REVERSALS split them out.
    select
        dcc.case_bk,
        last_day(c.collection_date)                    as month_end,
        sum(c.amount)                                  as collected,
        sum(iff(c.amount > 0, c.amount, 0))            as gross_receipts,
        sum(iff(c.amount < 0, c.amount, 0))            as reversals,
        count(*)                                       as n_payments,
        count(distinct c.case_sk)                      as n_case_versions_paying,
        max(c.collection_date)                         as last_payment_date
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join portfolio_scope as p on p.portfolio_sk = c.portfolio_sk
    inner join PROD.NPL_COMMON.DIM_CASE as dcc on dcc.case_sk = c.case_sk
    cross join window_bounds as w
    where c.collection_date >  w.start_date
      and c.collection_date <= w.end_date
    group by 1, 2
),

collections_this_version_only as (
    -- What the old CASE_SK join would have returned, kept so the difference
    -- is auditable rather than a claim in a comment. COLLECTED minus this is
    -- money that belongs to the loan but sits on another version.
    select
        c.case_sk,
        last_day(c.collection_date)                    as month_end,
        sum(c.amount)                                  as collected_this_version
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join (select distinct case_sk from balances) as b on b.case_sk = c.case_sk
    cross join window_bounds as w
    where c.collection_date >  w.start_date
      and c.collection_date <= w.end_date
    group by 1, 2
)

select
    dc.case_bk,                              -- durable loan key
    b.case_id,
    b.case_sk,
    b.month_end,

    ps.portfolio_bk,
    db.batch_bk,
    rs.servicer_name,
    sc.security_class_name,
    sg.segment_name,
    lb.legal_buyer_name,
    b.country_id,
    b.currency_id,                           -- ⚠ mixed: do not sum across
                                             -- currencies unconverted
    b.forbearance_flag,

    -- ---- balance roll-forward -------------------------------------------
    lag(b.outstanding_total) over (
        partition by dc.case_bk order by b.month_end
    )                                        as opening_balance,
    b.outstanding_total                      as closing_balance,
    b.outstanding_principal,
    b.outstanding_interest,
    b.outstanding_fees,
    b.outstanding_total - lag(b.outstanding_total) over (
        partition by dc.case_bk order by b.month_end
    )                                        as balance_movement,

    -- ---- collections in the month ---------------------------------------
    coalesce(mc.collected, 0)                as collected,
    -- Transparency on the fix above: what a CASE_SK-only match would have
    -- seen, and the money it would have missed. Non-zero
    -- COLLECTED_ON_OTHER_VERSIONS means this loan changed version mid-window.
    coalesce(cv.collected_this_version, 0)   as collected_this_version_only,
    coalesce(mc.collected, 0) - coalesce(cv.collected_this_version, 0)
                                             as collected_on_other_versions,
    coalesce(mc.n_case_versions_paying, 0)   as n_case_versions_paying,
    coalesce(mc.gross_receipts, 0)           as gross_receipts,
    coalesce(mc.reversals, 0)                as reversals,
    coalesce(mc.n_payments, 0)               as n_payments,
    mc.last_payment_date,
    iff(coalesce(mc.n_payments, 0) > 0, true, false)  as paid_this_month,

    -- What the balance move does NOT explain via collections: interest,
    -- fees, write-offs, FX, servicer restatement. Sized here on purpose.
    (b.outstanding_total - lag(b.outstanding_total) over (
        partition by dc.case_bk order by b.month_end
    )) + coalesce(mc.collected, 0)           as unexplained_movement,

    -- Monthly recovery rate on opening balance. nullif guards the very
    -- common zero-balance case; expect NULL in the first month of the window.
    coalesce(mc.collected, 0) / nullif(lag(b.outstanding_total) over (
        partition by dc.case_bk order by b.month_end
    ), 0)                                    as recovery_rate_on_opening

from balances as b
inner join PROD.NPL_COMMON.DIM_CASE             as dc on dc.case_sk = b.case_sk
inner join portfolio_scope                      as ps on ps.portfolio_sk = b.portfolio_sk
left  join monthly_collections                  as mc on mc.case_bk = dc.case_bk
                                                     and mc.month_end = b.month_end
left  join collections_this_version_only        as cv on cv.case_sk = b.case_sk
                                                     and cv.month_end = b.month_end
left  join PROD.NPL_COMMON.DIM_BATCH            as db on db.batch_sk = b.batch_sk
left  join PROD.NPL_COMMON.DIM_REPORTING_SYSTEM as rs on rs.reporting_system_sk = b.reporting_system_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS   as sc on sc.security_class_sk = b.security_class_sk
left  join PROD.NPL_COMMON.DIM_SEGMENT          as sg on sg.segment_sk = b.segment_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER      as lb on lb.legal_buyer_sk = b.legal_buyer_sk
order by dc.case_bk, b.month_end
limit $row_limit
