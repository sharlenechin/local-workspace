-- ============================================================================
-- cerved_settlement_by_age — CERVED Italy. How many open accounts close each
-- month, and what share of their balance they pay, by balance band and by
-- time since last payment.
-- GRAIN: one row per (SNAPSHOT_MONTH, BALANCE_BAND, MONTHS_SINCE_LAST_PAYMENT_BAND).
-- ============================================================================
--   Terminal : mise run sql -- work/italy/settlement/cerved_settlement_by_age.sql
--   PAIRS    intrum_settlement_by_age.sql — SAME metric shape, different book.
--            ⚠ Report them side by side. NEVER add them: see DEFINITIONS.
--
-- "PAID OFF" = CLOSED = we no longer collect from the loan (confirmed
-- 2026-09-15). LOANS_STATUS flips Open -> Closed between two snapshots.
-- ⚠ Closed does NOT mean settled in full. Cerved does not say WHY a loan
--   closed, so a write-off and a full settlement look identical here. Read
--   PERCENT_BALANCE_COLLECTED beside the closure rate — a cohort that closes
--   with little cash collected is being written off, not settling.
--
-- DENOMINATORS, as specified: accounts and balance OPEN AT THE SNAPSHOT.
--   PERCENT_ACCOUNTS_CLOSED  = closed next month / open now
--   PERCENT_BALANCE_CLOSED   = their balance / balance open now
--   PERCENT_BALANCE_COLLECTED= cash collected next month / balance open now
--
-- ⚠⚠ TWO GUARDS ON THE SNAPSHOT FEED, both measured 2026-09-15:
--   G1 OCTOBER 2025 IS DOUBLE-LOADED — 812,857 rows against 394,205 in every
--      other month, and 133,660 "open" loans against ~52,000. Deduped to one
--      row per loan per snapshot, newest file wins.
--   G2 788,410 ROWS HAVE NO UPDATE_DATE and cannot be placed in a month.
--      Excluded. That is two whole deliveries' worth.
--   Without both, October reads as a doubling of the book.
--
-- ⚠ ONLY 12 SNAPSHOTS EXIST: 2025-09-30 to 2026-08-31. There is no history
--   before that, so no cohort can be followed for longer than a year.
--
-- ⚠ AMICABLE IS NOT A FIELD IN THIS FEED — see IS_AMICABLE below. The default
--   here is "open and never reached a legal stage", which is OUR definition
--   and needs confirming before it is presented.
--
-- ⚠ RAW only. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set amicable_only = 'Y';   -- 'Y' = amicable accounts only; 'N' = the whole book


-- ⚠⚠ THE ACCOUNT IS THE **POSITION**, NOT THE LOAN. COLLECTIONS, PPT and PDR
--   are all keyed on (PORTFOLIO, POSITION_ID); only LOANS goes finer. Working
--   at loan grain and joining position-level cash fans that cash out across
--   every loan in the position — it read 49% of balance collected in one
--   month and 92% in another before this was fixed. One row per POSITION.
--   A position is OPEN while any of its loans is open.
with loan_rows as (
    select
        l.portfolio,
        l.position_id,
        l.loan_id,
        l.update_date::date  as snapshot_month,
        l.loans_status,
        l.oustanding_gbv     as outstanding_gbv    -- source spelling, kept
    from RAW.HYPERION_CERVED.LOANS as l
    where l.update_date is not null                                    -- G2
    qualify row_number() over (
        partition by l.portfolio, l.position_id, l.loan_id, l.update_date::date
        order by l._file_last_modified desc nulls last
    ) = 1                                                              -- G1
),

snapshots as (
    select
        portfolio,
        position_id,
        snapshot_month,
        iff(count_if(loans_status = 'Open') > 0, 'Open', 'Closed') as loans_status,
        sum(iff(loans_status = 'Open', outstanding_gbv, 0))        as outstanding_gbv,
        count(*)                                                   as loans_in_position
    from loan_rows
    group by 1, 2, 3
),

-- Every loan that has ever carried a legal-stage marker. Used only to define
-- "amicable" as its complement.
-- ⚠ THIS IS OUR DEFINITION, NOT CERVED'S. A PPT is a pre-legal collection
--   notice; a PDR whose category names an injunction, precetto, sentenza,
--   legal action or salary attachment is post-legal. Everything else is
--   treated as amicable. Confirm before presenting.
legal_ever as (
    select distinct portfolio, position_id
    from RAW.HYPERION_CERVED.PPT
    union
    select distinct portfolio, position_id
    from RAW.HYPERION_CERVED.PDR
    where pdr_category ilike '%injunction%'
       or pdr_category ilike '%precetto%'
       or pdr_category ilike '%enforcement%'
       or pdr_category ilike '%sentenza%'
       or pdr_category ilike '%legal action%'
       or pdr_category ilike '%attachment%'
       or pdr_category ilike '%concorsuale%'
),

-- ⚠⚠ G3: COLLECTIONS IS RE-DELIVERED WHOLE EVERY MONTH. 20,687,484 rows for
--   1,483,527 distinct EVENTO_ID — a 13.9x fan-out across 12 deliveries.
--   Summing AMOUNT_COLLECTED unguarded multiplies the cash by ~14.
--   Deduped to one row per EVENTO_ID, newest delivery wins.
-- ⚠ ACCOUNTING_DATE is used, not VALUE_DATE: VALUE_DATE's maximum does not
--   resolve to a real date (sentinels), while ACCOUNTING_DATE is populated on
--   all 20,687,484 rows and is when the cash was booked.
collections_deduped as (
    select
        c.portfolio,
        c.position_id,
        c.evento_id,
        c.accounting_date::date as accounting_date,
        c.amount_collected
    from RAW.HYPERION_CERVED.COLLECTIONS as c
    where c.accounting_date is not null
    qualify row_number() over (
        partition by c.evento_id
        order by c._file_last_modified desc nulls last
    ) = 1                                                              -- G3
),

collections_monthly as (
    select
        portfolio,
        position_id,
        last_day(accounting_date) as collection_month,
        sum(amount_collected)     as collected
    from collections_deduped
    group by 1, 2, 3
),

-- The latest payment on or before each snapshot, per loan.
last_payment as (
    select
        s.portfolio, s.position_id, s.snapshot_month,
        max(cm.collection_month) as last_payment_month
    from snapshots as s
    left join collections_monthly as cm
           on cm.portfolio    = s.portfolio
          and cm.position_id  = s.position_id
          and cm.collection_month <= s.snapshot_month
    group by 1, 2, 3
),

-- One row per loan per snapshot, with next month's state beside it. The
-- transition Open -> Closed is what "paid off" means.
positioned as (
    select
        s.portfolio,
        s.position_id,
        s.snapshot_month,
        s.loans_status,
        s.outstanding_gbv,
        s.loans_in_position,
        lead(s.loans_status) over (
            partition by s.portfolio, s.position_id
            order by s.snapshot_month)                 as status_next_month,
        lp.last_payment_month,
        le.position_id is null                         as is_amicable,
        datediff(month, lp.last_payment_month, s.snapshot_month) as months_since_last_payment
    from snapshots as s
    left join last_payment as lp
           on lp.portfolio   = s.portfolio
          and lp.position_id = s.position_id
          and lp.snapshot_month = s.snapshot_month
    left join legal_ever as le
           on le.portfolio   = s.portfolio
          and le.position_id = s.position_id
),

banded as (
    select
        p.*,
        case when p.outstanding_gbv <      1000 then '1. under 1k'
             when p.outstanding_gbv <      5000 then '2. 1k-5k'
             when p.outstanding_gbv <     20000 then '3. 5k-20k'
             when p.outstanding_gbv <    100000 then '4. 20k-100k'
             else                                    '5. over 100k' end as balance_band,
        case when p.last_payment_month is null           then '9. never paid'
             when p.months_since_last_payment <=  3      then '1. 0-3 months'
             when p.months_since_last_payment <=  6      then '2. 4-6 months'
             when p.months_since_last_payment <= 12      then '3. 7-12 months'
             when p.months_since_last_payment <= 24      then '4. 13-24 months'
             else                                             '5. over 24 months'
        end                                                as last_payment_band
    from positioned as p
    where p.loans_status = 'Open'                 -- the cohort: open at snapshot
      and ($amicable_only = 'N' or p.is_amicable)
      and p.status_next_month is not null         -- drop the final snapshot:
                                                  -- it has no next month to
                                                  -- observe a closure in
)

select
    b.snapshot_month,
    b.balance_band,
    b.last_payment_band,

    -- ---- denominators: open AT THE SNAPSHOT --------------------------------
    count(*)                                            as accounts_open,
    sum(b.outstanding_gbv)                              as balance_open_eur,

    -- ---- numerators: closed by the NEXT snapshot --------------------------
    count_if(b.status_next_month = 'Closed')            as accounts_closed,
    sum(iff(b.status_next_month = 'Closed', b.outstanding_gbv, 0))
                                                        as balance_closed_eur,

    -- ---- cash they paid in the month after the snapshot -------------------
    sum(coalesce(cm.collected, 0))                      as collected_eur,

    -- ---- the rates asked for ---------------------------------------------
    div0null(count_if(b.status_next_month = 'Closed'), count(*))
                                                        as percent_accounts_closed,
    div0null(sum(iff(b.status_next_month = 'Closed', b.outstanding_gbv, 0)),
             sum(b.outstanding_gbv))                    as percent_balance_closed,
    div0null(sum(coalesce(cm.collected, 0)), sum(b.outstanding_gbv))
                                                        as percent_balance_collected
from banded as b
left join collections_monthly as cm
       on cm.portfolio       = b.portfolio
      and cm.position_id     = b.position_id
      and cm.collection_month = last_day(dateadd(month, 1, b.snapshot_month))
group by 1, 2, 3
order by 1, 2, 3;
