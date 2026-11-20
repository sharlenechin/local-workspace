-- ============================================================================
-- promissory_notes_recovery — of the loans whose invoices name a promissory
-- note (livranca), how many ever paid, and did they pay better than the rest?
--
--   RUN      mise run sql -- work/project-elsa-benchmark/promissory_notes_recovery.sql
--   GRAIN    one row per segment (block A), one per batch (block B)
--   RUNTIME  ~12 min. One INVOICES scan plus the full TRANSACTIONS scan.
--   PAIRS    promissory_notes.sql — same classification, narrower population.
--
-- ⚠ POPULATION IS payments.sql's, NOT promissory_notes.sql's. Two filters that
--   file applies are applied here so the collections are comparable:
--     · $exclude_batches — the three batches with no cases or no cash in CAT
--     · priceable_loans  — loans with any P or C debtor in the raw feed
--   So the promissory-note count here is BELOW the 3,089 in promissory_notes.sql.
--   Block A reports the survivors explicitly; do not difference the two files
--   without reading this note.
--
-- ⚠ "PAID" MEANS LIFETIME COLLECTIONS > 0, to the CAT extract (last payment
--   2026-01-14), INCLUDING undated cash. It is not "paid recently" and not
--   "still paying". PAM holds six months this cannot see — payments.sql
--   READ FIRST 1. A loan that paid once in 2011 and never again counts as paid.
--
-- ⚠ THE COMPARISON IS THE POINT, NOT THE RATE. A note loan's pay rate means
--   nothing on its own; it is only informative beside the two control groups
--   in block A — loans labelled with a different instrument, and loans with no
--   label at all. Quote all three or none.
--
-- ⚠ SELECTION BIAS, UNFIXABLE FROM THIS DATA (CLAUDE.md Rule 6). CLAIM_REASON
--   is typed by a collector working the case. A loan that was actively worked
--   is more likely BOTH to be labelled AND to have paid, so the labelled
--   groups are not a random sample of the book. This is why the "no label at
--   all" row is reported rather than folded into the comparison: it is the
--   size of the bias, not a third instrument.
--
-- GUARDS  inherited unchanged from accounts.sql and payments.sql:
--   G1 TRANSACTIONS deduped on (CASE_ID, ORIG_TR_ID || PKEY), latest wins
--   G2 payment_cost_ind='P' and booking_ind<>'Y', and amount is not null
--   G3/G4 _file_path pinned to instance 4050, every extract read
--   G5 CASES batch filter BEFORE the dedupe   C9 container cases dropped
--   N2 amount is stored sign-flipped and is negated here
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

set country         = 'PT';
set seller          = 'MILLENNIUM';
set source_system   = '4050';
set raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set exclude_batches = 'PT06014B010000,PT070040000000,PT15018A040000';


with batches as (
    select distinct combined_ref
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path = (
              select max(_file_path)
              from RAW.HYPERION_INTRUM_PAM.PAM
              where _file_path like '%/pam.pam.pam.2%'
          )
      and pmode_name = 'Real'
      and coalesce(is_ownership_change, 0) = 0
      and countrycode like $country
      and upper(seller_name) like upper($seller)
),

cases as (
    select
        c.long_portfolio_id as portfolio_id,
        c.case_id           as loan_id,
        c.original_capital
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
      and not array_contains(c.long_portfolio_id::variant, split($exclude_batches, ','))
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

priceable_loans as (
    select d.case_id as loan_id
    from (
        select
            b.case_id,
            b.type,
            coalesce(b.record_updated, b.update_ts)::timestamp as ts,
            max(coalesce(b.record_updated, b.update_ts)::timestamp) over (
                partition by b.case_id, b.debtor_row_number
            ) as max_ts
        from RAW.HYPERION_INTRUM_CAT.DEBTORS as b
        where b._file_path like $raw_prefix || $source_system || '.debtors.%'
          and b.case_id in (select loan_id from cases)
          and coalesce(b.deleted, 0)  = 0
          and coalesce(b.archived, 0) = 0
          and coalesce(b.unlinked, 0) = 0
    ) as d
    where d.ts = d.max_ts
    group by d.case_id
    having max(iff(d.type in ('C', 'P'), 1, 0)) = 1
),

-- Instrument labels, identical matching to promissory_notes.sql.
labels as (
    select
        i.case_id,
        max(iff(upper(trim(i.claim_reason)) like '%LIVRAN%'
             or upper(trim(i.claim_reason)) like '%PROMISSORY%'
             or upper(trim(i.claim_reason)) like 'LIV%'
             or upper(trim(i.claim_reason)) like '%/LIV%'
             or upper(trim(i.claim_reason)) like '%BILL/%NOTE%', 1, 0)) as has_note,
        count(*)                                                        as labels_seen
    from RAW.HYPERION_INTRUM_CAT.INVOICES as i
    where i._file_path like $raw_prefix || $source_system || '.invoices.%'
      and i.case_id in (select loan_id from cases)
      and i.claim_reason is not null
    group by i.case_id
),

-- Lifetime cash per loan, built exactly as payments.sql builds it (G1-G4, N2)
-- and then collapsed from (loan, date) straight to loan.
collections as (
    select
        p.loan_id,
        sum(p.amount) as total_collections
    from (
        select
            c.loan_id,
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
    ) as p
    group by p.loan_id
),

-- One row per loan: its instrument class, its capital, its lifetime cash.
loans as (
    select
        c.portfolio_id,
        c.loan_id,
        c.original_capital,
        coalesce(col.total_collections, 0)  as total_collections,
        coalesce(col.total_collections, 0) > 0 as ever_paid,
        case
            when coalesce(l.has_note, 0) = 1        then '1. promissory note named'
            when coalesce(l.labels_seen, 0) > 0     then '2. labelled, a different instrument'
            else                                         '3. no instrument label at all'
        end                                 as segment
    from cases as c
    inner join priceable_loans as pl on pl.loan_id = c.loan_id
    left  join labels          as l  on l.case_id  = c.loan_id
    left  join collections     as col on col.loan_id = c.loan_id
)

-- A. the comparison. Read all three rows or none. -----------------------------
select
    'A. did they pay?'                                   as block,
    segment                                              as item,
    count(*)                                             as loans,
    count_if(ever_paid)                                  as loans_that_paid,
    round(100 * count_if(ever_paid) / count(*), 5)       as pct_that_paid,
    sum(original_capital)                                as original_capital,
    sum(total_collections)                               as collections,
    round(100 * sum(total_collections)
          / nullif(sum(original_capital), 0), 5)         as recovery_pct
from loans
group by 1, 2

union all

-- B. the note loans by batch, so a single batch cannot carry the headline -----
select
    'B. note loans by batch',
    portfolio_id,
    count(*),
    count_if(ever_paid),
    round(100 * count_if(ever_paid) / count(*), 5),
    sum(original_capital),
    sum(total_collections),
    round(100 * sum(total_collections) / nullif(sum(original_capital), 0), 5)
from loans
where segment = '1. promissory note named'
group by 1, 2

union all

-- C. segment x batch. The block A comparison is only meaningful if the three
--    segments are mixed WITHIN batches. If instead the unlabelled loans sit in
--    different batches from the labelled ones, block A is measuring the batch,
--    not the instrument, and must not be quoted.
select
    'C. segment x batch',
    portfolio_id || ' — ' || segment,
    count(*),
    count_if(ever_paid),
    round(100 * count_if(ever_paid) / count(*), 5),
    sum(original_capital),
    sum(total_collections),
    round(100 * sum(total_collections) / nullif(sum(original_capital), 0), 5)
from loans
group by 1, 2

order by block, item, loans desc;
