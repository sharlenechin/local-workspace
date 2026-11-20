-- ============================================================================
-- portugal_millenium_transactions — first payment date and total collected
-- per batch, from the raw Intrum CAT case/transaction feed.
-- GRAIN: one row per (batch_id, currency_id). Batches with no cases in the
-- feed still appear, with NULLs — see "13 OF 14" below.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/portugal_millenium_transactions.sql
--   Notebook : datalake.q("benchmark/portugal_millenium_transactions", batch='%')
--
-- ⚠ COST. $batch defaults to ONE batch — about 3.5 minutes. The raw feed is
-- 6.4bn case rows and 24.7bn transaction rows (237 GB / 487 GB). Guard 7
-- below is what makes it finishable at all; without it the same query ran
-- 11 minutes and was cancelled by the warehouse. Widen to '%' deliberately.
--
-- SEVEN GUARDS, or the number is wrong (measured 2026-09-10):
--   1. ONE PAM FILE. PAM holds 14 whole monthly deliveries, so an unguarded
--      read repeats every batch 14 times. Six mis-loaded
--      'pam.pam.pam_perimeter.*' files would also win a plain max().
--   2. PMODE_NAME = 'Real'. 'Adjust' rows are internal accounting batches.
--   3. No IS_OWNERSHIP_CHANGE rows: they repeat a batch-month for a legal
--      buyer transfer.
--   4. PAM COLLAPSED TO ONE ROW PER BATCH BEFORE ANY JOIN. PAM is batch ×
--      month × delivery — about 5,000 rows per batch in this scope. Joining
--      it straight to case level multiplies every transaction ~5,000×.
--   5. CASES IS A CHANGE-HISTORY FEED, not a case list. 17,841,296 rows for
--      120,713 cases here — 147× — because every delivery repeats every
--      historical version of every case. Deduped to the latest version per
--      case_id. 84 of those cases carry two different LONG_PORTFOLIO_IDs
--      over their history, so a plain `distinct` would post their cash to
--      two batches at once; latest-version-wins picks one.
--   6. TRANSACTIONS IS THE SAME SHAPE, and carries non-payment rows. Both
--      rules are the data team's own, lifted from
--      brocc-data .../staging/intrum_cat/stg_intrum_cat__transactions.sql
--      and .../conformed/intrum/int_npl_case_collection_intrum.sql:
--        · payments only: payment_cost_ind = 'P' and booking_ind <> 'Y'
--        · unique transaction = (case_id, orig_tr_id || coalesce(pkey,'')),
--          latest record_update wins
--
--   7. CASE_ID IS NOT UNIQUE ACROSS INTRUM INSTANCES. It is only unique
--      within a source system — the data team's own key is
--      source_system_code || '-' || case_id. Joining on case_id alone drags
--      in other countries' transactions: the 120,713 cases in this scope
--      match rows in 601 transaction files, where the instance these books
--      actually live in (4050) has only 11. Both sides are pinned to $system.
--      This is also what makes the query finishable — it cuts the read from
--      24.7bn rows to 404,563,686.
--
-- ⚠ AMOUNT IS STORED SIGN-FLIPPED. The team's staging layer reads it as
-- `-amount`; a collection is negative in RAW. Summing RAW.AMOUNT unnegated
-- returns the right magnitude with the wrong sign. Negated here to match.
--
-- ⚠ 13 OF 14. Portugal/Millennium has 14 batches in PAM; only 13 appear in
-- the CAT case feed. The 14th is kept as a NULL row rather than dropped, so
-- a missing book is visible instead of silently absent.
--
-- ⚠ AMOUNT-LESS PAYMENT ROWS, REPORTED NOT HIDDEN. Batch PT050030000000
-- returns a second row: 11,418 transactions, exactly one per case, dated
-- 2012-10-02 to 2016-08-18, with NULL currency and NULL amount. They pass
-- the data team's own payment filter but carry no money, so they land in
-- their own currency group instead of quietly diluting the EUR row. They
-- add nothing to the total; they have not been explained yet, and are worth
-- raising with the data team before anyone quotes a payment COUNT from
-- here. The money figure is unaffected.
--
-- ⚠ NOT FX-CONVERTED. Grouped by currency so nothing sums across currencies
-- (all EUR in this scope today; the grouping is what keeps that true).
-- ============================================================================

set country = 'PT';                -- matched with like; '%' for the whole feed
set seller  = 'MILLENNIUM';        -- matched case-insensitively; both casings exist
set batch   = 'PT050030000000';    -- '%' for all 14 — read the cost warning first
set system  = '4050';              -- the Intrum instance these books live in (Guard 7)


with newest_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'                             -- Guard 1
),

-- Guard 4: one row per batch, before anything case-level is joined to it.
batches as (
    select distinct p.combined_ref
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    inner join newest_file as nf
        on nf.file_path = p._file_path
    where p.pmode_name = 'Real'                                          -- Guard 2
      and coalesce(p.is_ownership_change, 0) = 0                         -- Guard 3
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
      and p.combined_ref like $batch
),

-- Guard 5: one row per case — its latest version.
cases as (
    select
        case_id,
        long_portfolio_id as combined_ref
    from RAW.HYPERION_INTRUM_CAT.CASES
    where long_portfolio_id in (select combined_ref from batches)
      and _file_path like '%/cat.' || $system || '.cases.%'              -- Guard 7
    qualify row_number() over (
        partition by case_id
        order by coalesce(record_updated::timestamp, update_ts::timestamp) desc nulls last
    ) = 1
),

-- Guard 6: payments only, one row per transaction, sign corrected.
txn as (
    select
        t.case_id,
        t.currency                                        as currency_id,
        t.transaction_date::date                          as transaction_date,
        -t.amount::decimal(38, 2)                         as amount
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    inner join cases as c
        on c.case_id = t.case_id
    where t._file_path like '%/cat.' || $system || '.transactions.%'     -- Guard 7
      and t.payment_cost_ind = 'P'                                       -- Guard 6
      and coalesce(t.booking_ind, 'N') != 'Y'                            -- Guard 6
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated::timestamp, t.update_ts::timestamp) desc nulls last,
                 to_timestamp_ntz(parse_json(t._file_metadata):extract_ts::string,
                                  'YYYYMMDDTHH24MISS') desc
    ) = 1
),

collected as (
    select
        c.combined_ref,
        t.currency_id,
        count(*)                                          as transactions,
        count(distinct t.case_id)                         as paying_cases,
        min(t.transaction_date)                           as min_transaction_date,
        max(t.transaction_date)                           as max_transaction_date,
        sum(t.amount)                                     as total_amount
    from txn as t
    inner join cases as c
        on c.case_id = t.case_id
    group by c.combined_ref, t.currency_id
)

select
    b.combined_ref                                        as batch_id,
    x.currency_id,
    x.transactions,
    x.paying_cases,
    x.min_transaction_date,
    x.max_transaction_date,
    x.total_amount                                        -- not FX-converted
from batches as b
left join collected as x
    on x.combined_ref = b.combined_ref
order by b.combined_ref, x.currency_id
LIMIT 100;
