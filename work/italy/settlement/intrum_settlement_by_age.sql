-- ============================================================================
-- intrum_settlement_by_age — INTRUM Italy (CAT instance 4034). How many open
-- amicable accounts close each month, and what share of their balance they
-- pay, by balance band and by time since last payment.
-- GRAIN: one row per (SNAPSHOT_MONTH, BALANCE_BAND, LAST_PAYMENT_BAND).
-- ============================================================================
--   Terminal : mise run sql -- work/italy/settlement/intrum_settlement_by_age.sql
--   PAIRS    cerved_settlement_by_age.sql — SAME metric shape, different book.
--            ⚠ Report them side by side. NEVER add them: see DEFINITIONS.
--   RUNTIME  ~2 minutes. Money is EUR.
--
-- "PAID OFF" = CLOSED = we no longer collect from the loan (confirmed
-- 2026-09-15). Here that is CASES.CLOSING_DATE falling in the month after the
-- snapshot.
-- ⚠ Closed does NOT mean settled in full. CLOSING_CODE is NOT decoded for
--   this instance — CLOSING_TEXT is 100% NULL — so a write-off and a payment
--   in full look identical. Read PERCENT_BALANCE_COLLECTED beside the closure
--   rate. The code mix is in closing_code_mix.sql; code 9 is 68% of closures.
--
-- DENOMINATORS, as specified: accounts and balance OPEN AT THE SNAPSHOT.
--   PERCENT_ACCOUNTS_CLOSED  = closed next month / open now
--   PERCENT_BALANCE_CLOSED   = their balance / balance open now
--   PERCENT_BALANCE_COLLECTED= cash collected next month / balance open now
--
-- ============================================================================
-- ⚠⚠ THIS BOOK HAS NO MONTHLY SNAPSHOT. THE SNAPSHOT IS RECONSTRUCTED.
-- ============================================================================
-- Cerved re-delivers a full loan tape every month, so its snapshot is given.
-- Intrum does not. Every month-end state below is DERIVED:
--   open      CLOSING_DATE is null or later than the month-end
--   amicable  first A002 on or before the month-end, and first L002 after it
--             (or never) — so a case leaves the cohort when it turns legal
--   balance   the running TRANSACTIONS ledger to the month-end (see G3)
--   last paid the newest `cashin` on or before the month-end
-- ⚠ That makes the Intrum balance a LEDGER POSITION, not a servicer-reported
--   outstanding. REMAINING_CAPITAL cannot be used: it is 100% NULL on
--   CASE_STATUS_CHANGE_HISTORY for this instance, and CASES carries only one
--   current value with no history.
--
-- ============================================================================
-- ⚠⚠ FOUR GUARDS, ALL MEASURED 2026-09-15
-- ============================================================================
--   G1 CASES AND TRANSACTIONS ARE CHANGE-HISTORY FEEDS. CASES is deduped to
--      the latest version per CASE_ID.
--   G2 _file_path matched as a LITERAL PREFIX (no leading %) or Snowflake
--      cannot prune and the query scans the whole 6.4bn-row table.
--   G3 ⚠⚠ TRANSACTIONS FANS OUT 2.2x — 289,788 rows for 130,802 distinct
--      PKEY — AND THE FAN-OUT IS ENTIRELY IN `adjustment`: 207,533 rows for
--      48,547 distinct PKEY, a 4.3x repeat. Summing AMOUNT unguarded turns
--      the adjustment total from -EUR 1,574,790 into +EUR 209,782,200 and so
--      inflates the whole book's balance by ~EUR 211m. Deduped on PKEY,
--      newest version wins.
--   G4 CASE_ID is unique only within an instance, so 4034 is pinned in the
--      path. G5 container cases (hyphenated CASE_ID) dropped.
--   G6 ⚠⚠ TWO MONTHS OF PAYMENTS ARE MISSING FROM THE FEED ENTIRELY.
--      There is not one `cashin` row dated OCTOBER 2025 or MAY 2026 — the
--      months are absent, not zero, and every neighbouring month carries
--      280-410 payments. Those two months are NOT silently dropped: they are
--      returned with COLLECTED_EUR = 0 and flagged by
--      CASH_MONTH_HAS_DATA = FALSE so the gap stays visible. ⚠ EXCLUDE THEM
--      from any average of PERCENT_BALANCE_COLLECTED, or the book looks 9%
--      worse at collecting than it is. Report to the data team.
--
-- ⚠ THE LEDGER RECONCILES TO THE BOOK. After G3, `load` is 48,546 rows and
--   EUR 1,058,690,235.15 — exactly the original capital in
--   ../italy-legal/FINDINGS.md. That is the check that the dedupe is right.
--
-- ⚠ A QUARTER OF THE ROWS ARE COST LINES, NOT LOANS. SPESE / SPESE LEGALI and
--   friends: 13,020 of 48,547. They are excluded by default — leaving them in
--   roughly halves every per-account rate. Set EXCLUDE_EXPENSE_LINES to 'N'
--   to see them. The classification text is truncated to 10 chars at source.
--
-- ⚠ ONLY 1,927 OF 48,547 CASES HAVE EVER PAID ANYTHING (3.968%). This book is
--   far less active than Cerved's, so "never paid" dominates even harder.
--
-- ⚠ THE AMICABLE COHORT HALVES ACROSS THE WINDOW — 29,094 accounts in March
--   2025 to 19,767 in June 2026 — AND CLOSURES ARE NOT THE REASON. Cases
--   leave by turning legal: 17,003 enter L002, in batch stamps of up to
--   3,917 in a single month (July 2025). So the denominator moves for
--   loading reasons, not behaviour. Read each month on its own; do not read
--   the fall in accounts as accounts being resolved.
--
-- ============================================================================
-- ⚠⚠ DEFINITIONS THAT DIFFER FROM THE CERVED FILE — DO NOT ADD THE TWO
-- ============================================================================
--   the account  Intrum: a CASE, which here is one LOAN.
--                Cerved: a POSITION, which is a debtor's whole set of loans.
--   amicable     Intrum: phase code A002 and not yet L002 — Intrum's own
--                field, and it is TIME-VARYING.
--                Cerved: our derived "never reached a legal stage", fixed.
--   balance      Intrum: reconstructed ledger. Cerved: reported OUSTANDING_GBV.
--   window       Intrum: 2024-08 .. 2026-06. Cerved: 2025-09 .. 2026-07.
--   A combined Italian settlement rate would average four different things.
--
-- ⚠ RAW only. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set source_system          = '4034';
set raw_prefix             = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set amicable_only          = 'Y';   -- 'Y' = amicable only; 'N' = the whole book
set exclude_expense_lines  = 'Y';   -- 'Y' = drop SPESE cost lines (see header)


-- G1, G2, G5. One row per case: its latest version across every extract.
with cases as (
    select
        c.case_id                                     as case_id,
        c.long_portfolio_id                           as portfolio_id,
        upper(trim(c.case_classification))            as loan_type_raw,
        c.registration_date::date                     as registration_date,
        c.closing_date::date                          as closing_date,
        c.closing_code                                as closing_code
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'   -- G2
      and c.case_id not like '%-%'                                       -- G5
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1                                                                -- G1
),

-- The amicable/legal journey. A002 is the onboarding stamp, L002 the first
-- legal action; the repeats on L002 are batch stamps, so only the FIRST
-- counts (../italy-legal/loan_phase_history.sql G8).
phase_dates as (
    select
        g.case_id                                              as case_id,
        min(iff(g.group_phase_code = 'A002', g.start_date::date, null)) as amicable_start,
        min(iff(g.group_phase_code = 'L002', g.start_date::date, null)) as legal_start
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE as g
    where g._file_path like $raw_prefix || $source_system || '.%'         -- G2
      and g.group_phase_code is not null
      and g.start_date is not null
      and coalesce(g.deleted,  0) = 0
      and coalesce(g.archived, 0) = 0
      and coalesce(g.unlinked, 0) = 0
    group by 1
),

-- ⚠⚠ G3. One row per PKEY, newest version. Without this the `adjustment`
--   lines repeat 4.3x and the book gains EUR 211m of balance that was never
--   there. AMOUNT is signed as a ledger: `load` and `expense` positive,
--   `cashin` negative because money in reduces what is owed.
ledger as (
    select
        t.case_id                    as case_id,
        t.transaction_type_code      as transaction_type_code,
        t.transaction_date::date     as transaction_date,
        t.amount                     as amount
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    where t._file_path like $raw_prefix || $source_system || '.%'         -- G2
      and t.transaction_date is not null
    qualify row_number() over (
        partition by t.pkey
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1                                                                -- G3
),

ledger_monthly as (
    select
        case_id,
        last_day(transaction_date)                                    as ledger_month,
        sum(amount)                                                   as balance_delta,
        -- money in is negative in the feed; flipped here so COLLECTED is positive
        -sum(iff(transaction_type_code in ('cashin', 'cashin revert'), amount, 0))
                                                                      as collected,
        count_if(transaction_type_code = 'cashin')                    as payment_count
    from ledger
    group by 1, 2
),

-- The month-end spine, derived from the feed rather than hardcoded. The
-- newest month is dropped at the end: it has no following month in which a
-- closure could be observed.
horizon as (
    select
        last_day(min(transaction_date)) as first_month,
        last_day(max(transaction_date)) as observation_end
    from ledger
),

month_spine as (
    select last_day(dateadd(month, row_number() over (order by null) - 1,
                            h.first_month))                           as snapshot_month
    from horizon as h
    cross join table(generator(rowcount => 120))
    qualify snapshot_month <= (select observation_end from horizon)
),

-- One row per case per month from the month its balance first appears. The
-- cross join is 48,547 x 24; the running sums below are what make a month-end
-- balance possible without a self-join.
case_month as (
    select
        c.case_id                                                     as case_id,
        c.portfolio_id                                                as portfolio_id,
        m.snapshot_month                                              as snapshot_month,
        c.closing_date                                                as closing_date,
        p.amicable_start                                              as amicable_start,
        p.legal_start                                                 as legal_start,
        c.loan_type_raw                                               as loan_type_raw,
        sum(coalesce(lm.balance_delta, 0)) over (
            partition by c.case_id order by m.snapshot_month
            rows between unbounded preceding and current row)         as balance_open_eur,
        max(iff(coalesce(lm.payment_count, 0) > 0, m.snapshot_month, null)) over (
            partition by c.case_id order by m.snapshot_month
            rows between unbounded preceding and current row)         as last_payment_month
    from cases as c
    cross join month_spine as m
    left join phase_dates as p
           on p.case_id = c.case_id
    left join ledger_monthly as lm
           on lm.case_id = c.case_id
          and lm.ledger_month = m.snapshot_month
    where m.snapshot_month >= coalesce(p.amicable_start, c.registration_date)
),

banded as (
    select
        cm.case_id                                                    as case_id,
        cm.snapshot_month                                             as snapshot_month,
        cm.balance_open_eur                                           as balance_open_eur,
        -- closed in the month AFTER the snapshot: the Intrum equivalent of
        -- Cerved's Open -> Closed transition between two tapes
        cm.closing_date > cm.snapshot_month
            and cm.closing_date <= last_day(dateadd(month, 1, cm.snapshot_month))
                                                                      as closed_next_month,
        case when cm.balance_open_eur <      1000 then '1. under 1k'
             when cm.balance_open_eur <      5000 then '2. 1k-5k'
             when cm.balance_open_eur <     20000 then '3. 5k-20k'
             when cm.balance_open_eur <    100000 then '4. 20k-100k'
             else                                      '5. over 100k' end as balance_band,
        case when cm.last_payment_month is null then '9. never paid'
             when datediff(month, cm.last_payment_month, cm.snapshot_month) <=  3
                                                then '1. 0-3 months'
             when datediff(month, cm.last_payment_month, cm.snapshot_month) <=  6
                                                then '2. 4-6 months'
             when datediff(month, cm.last_payment_month, cm.snapshot_month) <= 12
                                                then '3. 7-12 months'
             when datediff(month, cm.last_payment_month, cm.snapshot_month) <= 24
                                                then '4. 13-24 months'
             else                                    '5. over 24 months'
        end                                                           as last_payment_band
    from case_month as cm
    where (cm.closing_date is null or cm.closing_date > cm.snapshot_month)  -- open now
      and cm.balance_open_eur > 0                 -- a nil ledger is not an open account
      and ($amicable_only = 'N'
           or (cm.amicable_start <= cm.snapshot_month
               and (cm.legal_start is null or cm.legal_start > cm.snapshot_month)))
      and ($exclude_expense_lines = 'N'
           or not (cm.loan_type_raw like 'SPESE%'
                or cm.loan_type_raw like '%- SPE%'
                or cm.loan_type_raw like '9996%'
                or cm.loan_type_raw in ('PREMI ASSI', 'SOPRAVVENI')))
      and cm.snapshot_month < (select observation_end from horizon)
)

select
    b.snapshot_month,
    b.balance_band,
    b.last_payment_band,

    -- ---- denominators: open AT THE SNAPSHOT --------------------------------
    count(*)                                            as accounts_open,
    sum(b.balance_open_eur)                             as balance_open_eur,

    -- G6. FALSE = the feed holds no payments at all for the month being
    -- measured, so COLLECTED_EUR below is a gap, not a zero.
    last_day(dateadd(month, 1, b.snapshot_month))
        not in ('2025-10-31'::date, '2026-05-31'::date) as cash_month_has_data,

    -- ---- numerators: closed by the NEXT snapshot --------------------------
    count_if(b.closed_next_month)                       as accounts_closed,
    sum(iff(b.closed_next_month, b.balance_open_eur, 0)) as balance_closed_eur,

    -- ---- cash they paid in the month after the snapshot -------------------
    sum(coalesce(lm.collected, 0))                      as collected_eur,

    -- ---- the rates asked for ---------------------------------------------
    div0null(count_if(b.closed_next_month), count(*))   as percent_accounts_closed,
    div0null(sum(iff(b.closed_next_month, b.balance_open_eur, 0)),
             sum(b.balance_open_eur))                   as percent_balance_closed,
    div0null(sum(coalesce(lm.collected, 0)), sum(b.balance_open_eur))
                                                        as percent_balance_collected
from banded as b
left join ledger_monthly as lm
       on lm.case_id     = b.case_id
      and lm.ledger_month = last_day(dateadd(month, 1, b.snapshot_month))
group by 1, 2, 3
order by 1, 2, 3;
