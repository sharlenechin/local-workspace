-- ============================================================================
-- undated_payments_diagnosis — how many loans per batch are hit by payments
-- with no TRANSACTION_DATE, and whether those payments can be dated from any
-- other column on the row.
-- GRAIN: one row per PAM COMBINED_REF that has payments.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/undated_payments_diagnosis.sql
--   ⚠ accounts.sql and payments.sql moved 2026-09-11 to
--     work/project-elsa-benchmark/. Bare mentions below mean there.
--
-- TWO QUESTIONS, ONE SCAN.
--   1. HOW MANY LOANS ARE AFFECTED, per batch — not just how much money. A
--      batch where 3% of the cash is undated but 60% of the loans are touched
--      is a different problem from one where a handful of loans carry it all.
--   2. ARE THEY PRE-ACQUISITION PAYMENTS? The obvious guess, since PAM's
--      lifetime starts at capex and cannot hold them. TRANSACTION_DATE is
--      null in every version by definition here, but the row carries three
--      other dates — BANKING_DATE, REGISTRATION_DATE, BOOKING_DATE — and if
--      any is populated the undated cash can be placed after all.
--
-- ⚠ THE VINTAGE SPLIT ALREADY ARGUES AGAINST PRE-ACQUISITION. Every pre-2010
-- batch carries 3-10% of its collections undated; both 2016 batches carry
-- EXACTLY ZERO (batch_impact_matrix.sql, 2026-09-10). Yet the only batch with
-- material pre-acquisition payments is PT15018G000000 — EUR 1,571,494.31 of
-- them, dated, up to five years before its capex month — and it has no
-- undated cash at all. If undated meant "before we bought it", those two
-- columns would coincide; they are mutually exclusive instead.
-- The competing explanation is MIGRATION: Intrum's CAT platform took these
-- books on 2014-10-10, nine years after the pre-2010 registrations, so that
-- history had to be loaded from an older system and may have arrived without
-- dates. UNDATED_BEFORE_ONBOARDING_EUR is the column that tests it — against
-- $cat_onboarding, not against capex.
--
-- ⚠ EVERY DATE IS RECOVERED ACROSS VERSIONS, all four of them, the same way
-- payments.sql recovers TRANSACTION_DATE: a transaction is delivered many
-- times and any version may carry a date the winning version lacks. Taking a
-- date off the winning row alone understates all four columns.
--
-- ⚠ A FALLBACK DATE IS NOT A PAYMENT DATE. BANKING_DATE is when the cash
-- cleared, REGISTRATION_DATE when the transaction was keyed, BOOKING_DATE
-- when it was posted. They answer "roughly when did this happen", which is
-- enough to test the pre-acquisition hypothesis, and are NOT a substitute for
-- TRANSACTION_DATE in a collections curve. Do not backfill payments.sql from
-- them without agreeing that with the data team first.
--
-- Guards are those of payments.sql: one PAM file, PMODE_NAME='Real', no
-- ownership-change rows, CASE_ID pinned to one source system, TRANSACTIONS
-- deduped to latest version on the team's key, payments only, AMOUNT negated.
--
-- ⚠ COST. One pass over the transaction feed: about 9 minutes.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment.
-- ============================================================================

set country        = 'PT';
set seller         = 'MILLENNIUM';
set source_system  = '4050';
set raw_prefix     = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
-- The date Intrum's CAT platform took these books on, from accounts.sql. The
-- migration hypothesis lives or dies on this date, so it is a variable.
set cat_onboarding = '2014-10-10';


with newest_pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'
),

batches as (
    select p.combined_ref, max(p.capex_date_m::date) as capex_month
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    inner join newest_pam_file as nf on nf.file_path = p._file_path
    where p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
    group by p.combined_ref
),

cases as (
    select c.long_portfolio_id as portfolio_id, c.case_id as loan_id
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- One row per real payment, with all four dates recovered across versions.
payments as (
    select
        c.portfolio_id,
        c.loan_id,
        max(t.transaction_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                         as payment_date,
        max(t.banking_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                         as banking_date,
        max(t.registration_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                         as registration_date,
        max(t.booking_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                         as booking_date,
        -t.amount::decimal(38, 2) as amount
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    inner join cases as c
        on c.loan_id = t.case_id
    where t._file_path like $raw_prefix || $source_system || '.transactions.%'
      and t.payment_cost_ind = 'P'
      and coalesce(t.booking_ind, 'N') != 'Y'
      and t.amount is not null
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1
),

flagged as (
    select
        p.*,
        p.payment_date is null                                     as is_undated,
        coalesce(p.banking_date, p.registration_date,
                 p.booking_date)                                   as fallback_date
    from payments as p
)

select
    f.portfolio_id,
    b.capex_month,

    -- ---- question 1: how many LOANS, not just how much money -------------
    count(distinct f.loan_id)                                      as loans_that_paid,
    count(distinct iff(f.is_undated, f.loan_id, null))              as loans_undated,
    div0(count(distinct iff(f.is_undated, f.loan_id, null)),
         nullif(count(distinct f.loan_id), 0))                      as pct_loans_undated,
    count(iff(f.is_undated, 1, null))                               as undated_payments,
    sum(iff(f.is_undated, f.amount, 0))                             as undated_eur,
    sum(f.amount)                                                   as total_eur,
    div0(sum(iff(f.is_undated, f.amount, 0)),
         nullif(sum(f.amount), 0))                                  as pct_eur_undated,

    -- ---- question 2: can the undated cash be dated another way? ----------
    count(iff(f.is_undated and f.banking_date is not null, 1, null))      as undated_with_banking,
    count(iff(f.is_undated and f.registration_date is not null, 1, null)) as undated_with_registration,
    count(iff(f.is_undated and f.booking_date is not null, 1, null))      as undated_with_booking,
    sum(iff(f.is_undated and f.fallback_date is not null, f.amount, 0))   as undated_datable_eur,
    min(iff(f.is_undated, f.fallback_date, null))                         as undated_fallback_earliest,
    max(iff(f.is_undated, f.fallback_date, null))                         as undated_fallback_latest,

    -- ---- and the two hypotheses, side by side ----------------------------
    -- pre-acquisition: does the undated cash sit before the batch was bought?
    sum(iff(f.is_undated and f.fallback_date < b.capex_month,
            f.amount, 0))                                           as undated_before_capex_eur,
    -- migration: or before Intrum's CAT platform took the book on?
    sum(iff(f.is_undated and f.fallback_date < $cat_onboarding::date,
            f.amount, 0))                                           as undated_before_onboarding_eur,
    -- and the same cut on the DATED cash, as the control
    sum(iff(not f.is_undated and f.payment_date < $cat_onboarding::date,
            f.amount, 0))                                           as dated_before_onboarding_eur
from flagged as f
inner join batches as b on b.combined_ref = f.portfolio_id
group by f.portfolio_id, b.capex_month
order by b.capex_month, f.portfolio_id;
