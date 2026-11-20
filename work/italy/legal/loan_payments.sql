-- ============================================================================
-- loan_payments — payments and customers per loan, Italy (Intrum CAT 4034).
--
--   RUN      mise run sql -- work/italy/legal/loan_payments.sql
--            datalake.q("work/italy/legal/loan_payments", convert=False)
--   GRAIN    one row per LOAN_ID. Pairs with loan_phase_history.sql on LOAN_ID
--            -- same 48,547 loans, same guards, asserted in the notebook.
--   RUNTIME  ~1 min.  EUR; Italy is single-currency.
--
-- WHY A SECOND FILE: loan_phase_history carries phases, not money. This adds
-- the payment and customer side so the funnel can ask "how many of the loans
-- that reached this phase ever paid, and how long did it take".
--
-- ⚠ NOTHING IS CENSORED ON THIS BOOK, which is why the durations are usable.
--   Measured 2026-09-15: registration, first amicable spell and the first
--   transaction ALL begin 2024-07-21, and no loan has an amicable start before
--   the payment feed opens. Contrast Portugal, where the case history starts
--   nine years after acquisition. Do not copy this file to another instance
--   without re-running that check.
--
-- ⚠ FIRST_PAYMENT_AFTER_LEGAL is measured from the loan's own L002 stamp, so
--   a loan bought already in legal is measured from the day it was stamped,
--   not from a servicing decision. Split by ESCALATION_ROUTE before quoting.
--
-- CASH BY PHASE: every payment is attributed to the phase in force ON ITS OWN
--   PAYMENT DATE, not to the loan's current phase. A loan that paid in amicable
--   and later escalated has that cash counted as amicable, where it was earned.
--     amicable  payment_date >= amicable_start and (no L002, or before it)
--     legal     payment_date >= legal_start
--     pre-phase payment_date <  amicable_start  -- kept, never dropped
--   The three are mutually exclusive and sum to TOTAL_COLLECTIONS; asserted
--   in the notebook.
--
-- GUARDS
--   G1 CASES is a change-history feed -- deduped to the latest version per
--      CASE_ID, or every count multiplies.
--   G2 _file_path pinned to instance 4034 as a LITERAL PREFIX (no leading %,
--      or partition pruning is lost). CASE_ID is unique only within a system.
--   G3 PAYMENTS ONLY: payment_cost_ind = 'P' and booking_ind <> 'Y', Intrum's
--      own rule. Without it the total includes costs and fees.
--   G4 Deduped to the latest version per (case_id, PAYMENT_ID).
--      ⚠⚠ DO NOT COPY PORTUGAL'S KEY HERE. That book dedupes on
--      concat(ORIG_TR_ID, coalesce(PKEY,'')). On instance 4034 ORIG_TR_ID is
--      0% FILLED, and Snowflake's concat() is NULL-PROPAGATING -- so the whole
--      key evaluates to NULL on every row, row_number() partitions by a
--      constant, and exactly ONE payment survives per loan. Measured
--      2026-09-15: that silently discarded 3,205 of 5,132 payments and
--      understated collections. PAYMENT_ID is 100% filled and unique here
--      (5,132 distinct over 5,132 rows -- this feed carries no duplicate
--      versions at all), so it is the right key and the dedupe is defensive.
--   G5 AMOUNT IS SIGN-FLIPPED AT SOURCE. Negated here so a payment is positive.
--   G6 DEBTORS is one-to-many AND a change feed -- deduped to distinct
--      DEBTOR_ROW_NUMBER per case, never counted as rows.
--
-- ⚠⚠ DEBTOR_ROW_NUMBER IS NOT UNIQUE PER LOAN. Measured 2026-09-15 on 4034:
--   20,567 distinct customers hold 48,546 loans -- 2.36 loans each. So
--   DEBTOR_ID is returned per loan and customers must be counted as
--   count(distinct DEBTOR_ID) at whatever grain you are reporting.
--   SUMMING N_DEBTORS OVERSTATES CUSTOMERS BY ~2.36x. It is returned only so
--   a joint-debtor loan is visible; exactly one debtor per loan on this book.
--   G7 The phase spells mirror loan_phase_history.sql exactly. If that file's
--      spell logic changes, change it here too.
--
-- ⚠ RAW only. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set source_system = '4034';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


-- G1, G2. One row per loan.
with cases as (
    select c.case_id as loan_id
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- G7. Same spell rules as loan_phase_history.sql.
phase_dates as (
    select
        g.case_id                                                    as loan_id,
        min(iff(g.group_phase_code = 'A002', g.start_date::date, null)) as amicable_start,
        min(iff(g.group_phase_code = 'L002', g.start_date::date, null)) as legal_start
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE as g
    where g._file_path like $raw_prefix || $source_system || '.%'
      and g.group_phase_code is not null
      and g.start_date is not null
      and coalesce(g.deleted,  0) = 0
      and coalesce(g.archived, 0) = 0
      and coalesce(g.unlinked, 0) = 0
    group by 1
),

-- G2-G5. One row per real payment.
payments as (
    select
        t.case_id                 as loan_id,
        t.transaction_date::date  as payment_date,
        -t.amount::decimal(38, 2) as amount              -- G5
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    where t._file_path like $raw_prefix || $source_system || '.transactions.%'
      and t.payment_cost_ind = 'P'                       -- G3
      and coalesce(t.booking_ind, 'N') != 'Y'            -- G3
      and t.amount is not null
      and t.transaction_date is not null
    qualify row_number() over (
        partition by t.case_id, t.payment_id              -- G4, never ORIG_TR_ID
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1
),

-- G6. Customers per loan.
debtors as (
    select case_id                                    as loan_id,
           min(debtor_row_number)                     as debtor_id,
           count(distinct debtor_row_number)          as n_debtors
    from RAW.HYPERION_INTRUM_CAT.DEBTORS
    where _file_path like $raw_prefix || $source_system || '.%'
      and coalesce(deleted,  0) = 0
      and coalesce(archived, 0) = 0
      and coalesce(unlinked, 0) = 0
    group by 1
)

select
    c.loan_id,
    -- Count customers as count(distinct DEBTOR_ID). See G6.
    d.debtor_id                                                as debtor_id,
    coalesce(d.n_debtors, 0)                                   as n_debtors,
    count(p.payment_date)                                      as n_payments,
    coalesce(sum(p.amount), 0)                                 as total_collections,
    min(p.payment_date)                                        as first_payment_date,
    max(p.payment_date)                                        as last_payment_date,
    -- Only payments landing on or after the loan's own L002 stamp.
    min(iff(pd.legal_start is not null and p.payment_date >= pd.legal_start,
            p.payment_date, null))                             as first_payment_after_legal,
    count(iff(pd.legal_start is not null and p.payment_date >= pd.legal_start,
              1, null))                                        as n_payments_after_legal,

    -- ---- cash by the phase in force on the payment date ------------------
    min(iff(p.payment_date >= pd.amicable_start
            and (pd.legal_start is null or p.payment_date < pd.legal_start),
            p.payment_date, null))                             as first_payment_in_amicable,
    count(iff(p.payment_date >= pd.amicable_start
              and (pd.legal_start is null or p.payment_date < pd.legal_start),
              1, null))                                        as n_payments_amicable,
    coalesce(sum(iff(p.payment_date >= pd.amicable_start
              and (pd.legal_start is null or p.payment_date < pd.legal_start),
              p.amount, 0)), 0)                                as collections_amicable,

    count(iff(pd.legal_start is not null and p.payment_date >= pd.legal_start,
              1, null))                                        as n_payments_legal,
    coalesce(sum(iff(pd.legal_start is not null and p.payment_date >= pd.legal_start,
              p.amount, 0)), 0)                                as collections_legal,

    -- Payments before the first phase spell. Kept and labelled, never dropped.
    count(iff(p.payment_date < pd.amicable_start, 1, null))     as n_payments_prephase,
    coalesce(sum(iff(p.payment_date < pd.amicable_start, p.amount, 0)), 0)
                                                               as collections_prephase
from cases as c
left join phase_dates as pd on pd.loan_id = c.loan_id
left join debtors     as d  on d.loan_id  = c.loan_id
left join payments    as p  on p.loan_id  = c.loan_id
group by 1, 2, 3
order by 1;
