-- ============================================================================
-- portugal_millennium_reconciliation — collections either side of Intrum's
-- case registration date, from the transaction feed and from PAM, side by side.
-- GRAIN: one row per batch (PAM COMBINED_REF), plus a TOTAL row.
-- Money in the batch currency (EUR throughout this scope), NOT FX-converted.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/portugal_millennium_reconciliation.sql
--
-- ⚠ THE TWO SIDES ARE SPLIT ON DIFFERENT BOUNDARIES, BECAUSE PAM CANNOT DO
-- BETTER. This is the whole caveat of the file, so read it before quoting it.
--   · TRANSACTIONS split on each CASE's own REGISTRATION_DATE. Exact.
--   · PAM has no registration date and no case grain. It reports batch ×
--     month, so the best available boundary is the batch's EARLIEST case
--     registration month, applied to whole months.
-- The two columns therefore answer slightly different questions and small
-- differences at the boundary month are expected, not error.
--
-- ⚠ PAM_PRE_REGISTRATION IS ~ZERO BY CONSTRUCTION, NOT BY MEASUREMENT.
-- PAM's first reported month IS the capex month for all 14 batches here, and
-- registration happens within the first month or two of capex. PAM simply has
-- no months in which pre-registration cash could be reported. Where the
-- transaction feed shows real pre-registration money (PT15018G000000: EUR
-- 1.57m from 2011, five years before Intrum registered the case), PAM shows
-- nothing at all — because that cash predates PAM's own lifetime. A zero in
-- the PAM_PRE column is the absence of a reporting window, not evidence that
-- no money arrived. Do not read the two PRE columns as a disagreement.
--
-- ⚠ EXTRACT PINNED, DELIBERATELY. Taking split_part(max(_file_path), '.', 4)
-- picks 20260115T071911, which holds 1,178 case rows and 2,486 transaction
-- rows — a trailing delta, not a delivery. It would return almost nothing with
-- no error. The full extracts for system 4050 are (measured 2026-09-10):
--     cases        20251214T120032  85,199,725 rows  4 parts
--                  20260114T171703  85,386,136 rows  3 parts   <- pinned
--                  20260115T071911       1,178 rows  1 part
--     transactions 20251009T115213  77,475,485 rows  2 parts
--                  20251027T151127  81,404,436 rows  2 parts
--                  20251110T160253  81,523,585 rows  2 parts
--                  20251214T120032  81,934,316 rows  2 parts
--                  20260114T171703  82,223,378 rows  2 parts   <- pinned
--                  20260115T071911       2,486 rows  1 part
-- Each full extract is a whole re-delivery (they grow, they do not accumulate),
-- so ONE of them is the complete history. Never max() the path to choose it.
--
-- ⚠ UNSPLITTABLE CASH IS REPORTED, NOT BURIED. A case with no
-- REGISTRATION_DATE cannot sit either side of it; its payments go in their own
-- column so PRE + POST + UNSPLITTABLE reconciles to the feed total.
--
-- Guards are those established in portugal_millenium_transactions.sql
-- (measured 2026-09-10): one PAM file; PMODE_NAME = 'Real'; no
-- IS_OWNERSHIP_CHANGE; PAM collapsed to one row per batch before any join;
-- CASES and TRANSACTIONS deduped to latest version; CASE_ID pinned to one
-- source system; payments only (payment_cost_ind = 'P', booking_ind <> 'Y')
-- on the team's key (case_id, orig_tr_id || coalesce(pkey, '')); AMOUNT
-- negated, because RAW stores a collection as a negative.
-- ============================================================================

set country       = 'PT';
set seller        = 'MILLENNIUM';
set source_system = '4050';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set extract_ts    = '20260114T171703';   -- see the extract warning above


with newest_pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'
),

-- PAM actual months only: the plan months out to 2041 carry no collections.
pam_rows as (
    select
        p.combined_ref,
        p.capex_date_m::date      as intrum_acquired,
        p.period_start_date::date as reporting_month,
        p.colltotal               as collections
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    inner join newest_pam_file as nf
        on nf.file_path = p._file_path
    where p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'))::date
),

batches as (
    select combined_ref, max(intrum_acquired) as intrum_acquired
    from pam_rows
    group by combined_ref
),

cases as (
    select
        c.long_portfolio_id       as combined_ref,
        c.case_id,
        c.registration_date::date as registration_date
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.' || $extract_ts || '.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- The batch-level boundary PAM has to use: earliest case registration month.
reg_month as (
    select combined_ref, date_trunc('month', min(registration_date))::date as first_reg_month
    from cases
    group by combined_ref
),

payments as (
    select
        t.case_id,
        t.transaction_date::date  as transaction_date,
        -t.amount::decimal(38, 2) as amount
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    where t._file_path like $raw_prefix || $source_system || '.transactions.' || $extract_ts || '.%'
      and t.case_id in (select case_id from cases)
      and t.payment_cost_ind = 'P'
      and coalesce(t.booking_ind, 'N') != 'Y'
      and t.transaction_date::date between '1990-01-01' and current_date()
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1
),

txn_split as (
    select
        c.combined_ref,
        sum(case when c.registration_date is not null
                  and p.transaction_date <  c.registration_date then p.amount else 0 end) as txn_pre,
        sum(case when c.registration_date is not null
                  and p.transaction_date >= c.registration_date then p.amount else 0 end) as txn_post,
        sum(case when c.registration_date is null then p.amount else 0 end)                as txn_unsplittable
    from cases as c
    inner join payments as p
        on p.case_id = c.case_id
    group by c.combined_ref
),

pam_split as (
    select
        pr.combined_ref,
        sum(case when pr.reporting_month <  rm.first_reg_month then pr.collections else 0 end) as pam_pre,
        sum(case when pr.reporting_month >= rm.first_reg_month then pr.collections else 0 end) as pam_post,
        sum(pr.collections)                                                                    as pam_total
    from pam_rows as pr
    left join reg_month as rm
        on rm.combined_ref = pr.combined_ref
    group by pr.combined_ref
)

select
    b.combined_ref                                  as batch_id,
    b.intrum_acquired,
    rm.first_reg_month                              as first_case_registered,
    coalesce(t.txn_pre, 0)                          as txn_pre_registration,
    coalesce(t.txn_post, 0)                         as txn_post_registration,
    coalesce(t.txn_unsplittable, 0)                 as txn_no_registration_date,
    coalesce(m.pam_pre, 0)                          as pam_pre_registration,
    coalesce(m.pam_post, 0)                         as pam_post_registration,
    coalesce(t.txn_post, 0) - coalesce(m.pam_post, 0)                       as post_gap,
    div0(coalesce(t.txn_post, 0), nullif(coalesce(m.pam_post, 0), 0))       as post_ratio
from batches as b
left join reg_month  as rm on rm.combined_ref = b.combined_ref
left join txn_split  as t  on t.combined_ref  = b.combined_ref
left join pam_split  as m  on m.combined_ref  = b.combined_ref
order by b.intrum_acquired, b.combined_ref;
