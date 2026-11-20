-- ============================================================================
-- monthly_borrower_collections — BORROWER × MONTH: what each customer paid.
-- GRAIN: one row per (BORROWER_ID, MONTH_END), paying months only.
-- ============================================================================
-- The payment-behaviour view. One row per borrower per month in which they
-- paid anything, with a running lifetime total and the gap since their
-- previous payment — enough to classify payers, sporadic payers and
-- one-off settlers.
--
--   Terminal : mise run sql -- work/servicing/prod/monthly_borrower_collections.sql
--   Notebook : datalake.q("servicing/prod/monthly_borrower_collections")
--
-- ---------------------------------------------------------------------------
-- GRAIN: one row per (BORROWER_ID, MONTH_END), and only for months with at
-- least one payment. Months with no payment are absent, not zero — if you
-- need a dense monthly series, reindex in pandas or cross join
-- COMMON.DIM_MONTH.
--
-- ⚠ THIS QUERY CAN DOUBLE COUNT MONEY, BY DESIGN. READ THIS.
-- A collection is recorded against a LOAN, not a borrower. Where a loan has
-- several borrowers (8.2M of 22.5M loans do), the bridge attributes the FULL
-- payment to EACH of them — there is no split or primary-borrower flag in
-- BRG_CASE_BORROWER to apportion it with.
--   * PER BORROWER the number is right: "this customer's loans received X".
--   * SUMMED ACROSS BORROWERS it overstates, because a joint loan's payment
--     is counted once per borrower.
-- COLLECTED_SOLE_BORROWER_ONLY is provided as the conservative alternative:
-- it counts only payments on loans with exactly one borrower, so it is
-- additive but incomplete. For a total that foots, use
-- monthly_portfolio_performance.sql, which never goes through the bridge.
-- The scale of the issue is exposed per row as N_JOINT_LOANS.
-- ---------------------------------------------------------------------------
-- ⚠ UPPER DATE BOUND is deliberate: 841 collection rows are dated in the
-- future (741 in 2099, one in 4570). Unbounded they invent future months.
-- ⚠ Negative amounts (1.5% of rows) are reversals and are kept, so COLLECTED
-- is net of refunds and charge-backs. A borrower can show a negative month.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY — CHECK IT BEFORE YOU AGGREGATE.
-- The cap exists so an accidental '%' filter cannot pull tens of millions of
-- rows into pandas. But a truncated result still sums, averages and charts
-- perfectly happily, and the total is simply wrong. If the row count comes
-- back exactly equal to $row_limit, assume it was cut: narrow
-- $portfolio_filter, shorten the window, or raise the cap deliberately.
-- ============================================================================

set month_end        = '2026-07-31';
set months_back      = 24;
set portfolio_filter = 'LOK-DE24016-U01/2512';
set row_limit        = 200000;


with portfolio_scope as (
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
),

window_bounds as (
    select $month_end::date                                   as end_date,
           dateadd(month, -1 * $months_back, $month_end::date) as start_date
),

case_borrower_count as (
    -- How many borrowers share each loan — needed to flag, and to isolate,
    -- the double-counting described in the header.
    select case_sk, count(distinct borrower_sk) as n_borrowers_on_loan
    from PROD.NPL_COMMON.BRG_CASE_BORROWER
    group by 1
),

scoped_collections as (
    select
        c.case_sk,
        last_day(c.collection_date) as month_end,
        c.amount,
        c.currency_id,
        c.portfolio_sk
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join portfolio_scope as p on p.portfolio_sk = c.portfolio_sk
    cross join window_bounds as w
    where c.collection_date >  w.start_date
      and c.collection_date <= w.end_date
),

borrower_month as (
    select
        bo.borrower_id,
        sc.month_end,
        sum(sc.amount)                                as collected,
        sum(iff(sc.amount > 0, sc.amount, 0))         as gross_receipts,
        sum(iff(sc.amount < 0, sc.amount, 0))         as reversals,
        count(*)                                      as n_payments,
        count(distinct sc.case_sk)                    as n_loans_paying,
        count(distinct sc.portfolio_sk)               as n_portfolios,
        count(distinct iff(cbc.n_borrowers_on_loan > 1, sc.case_sk, null))
                                                      as n_joint_loans,
        -- Additive but incomplete: sole-borrower loans only.
        sum(iff(coalesce(cbc.n_borrowers_on_loan, 1) = 1, sc.amount, 0))
                                                      as collected_sole_borrower_only,
        listagg(distinct sc.currency_id, ',')
            within group (order by sc.currency_id)    as currencies
    from scoped_collections as sc
    inner join PROD.NPL_COMMON.BRG_CASE_BORROWER as b  on b.case_sk = sc.case_sk
    inner join PROD.NPL_COMMON.DIM_BORROWER      as bo on bo.borrower_sk = b.borrower_sk
    left  join case_borrower_count               as cbc on cbc.case_sk = sc.case_sk
    group by 1, 2
),

borrower_attrs as (
    select borrower_id, legal_eba_type, gender, country_id
    from PROD.NPL_COMMON.DIM_BORROWER
    where is_current
      and borrower_id in (select borrower_id from borrower_month)
    qualify row_number() over (
        partition by borrower_id order by record_update_date desc nulls last
    ) = 1
)

select
    bm.borrower_id,
    bm.month_end,
    ba.legal_eba_type,
    ba.gender,
    ba.country_id                       as borrower_country_id,
    bm.currencies,                      -- ⚠ mixed currencies possible

    bm.collected,                       -- net of reversals; may double count
                                        -- joint loans across borrowers
    bm.collected_sole_borrower_only,    -- additive, but excludes joint loans
    bm.gross_receipts,
    bm.reversals,
    bm.n_payments,
    bm.n_loans_paying,
    bm.n_joint_loans,                   -- >0 means this row is affected by
                                        -- the double-count described above
    bm.n_portfolios,

    -- ---- behaviour over time --------------------------------------------
    sum(bm.collected) over (
        partition by bm.borrower_id order by bm.month_end
        rows between unbounded preceding and current row
    )                                   as collected_cumulative,
    row_number() over (
        partition by bm.borrower_id order by bm.month_end
    )                                   as paying_month_seq,
    lag(bm.month_end) over (
        partition by bm.borrower_id order by bm.month_end
    )                                   as previous_paying_month,
    -- NULL on a borrower's first paying month in the window — a window edge,
    -- not a data gap.
    datediff(month, lag(bm.month_end) over (
        partition by bm.borrower_id order by bm.month_end
    ), bm.month_end)                    as months_since_previous_payment

from borrower_month as bm
left join borrower_attrs as ba on ba.borrower_id = bm.borrower_id
order by bm.borrower_id, bm.month_end
limit $row_limit
