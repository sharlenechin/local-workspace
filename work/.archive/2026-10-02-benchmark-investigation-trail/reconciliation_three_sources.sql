-- ============================================================================
-- Collections per batch from all three sources, side by side.
--
--   ⚠ accounts.sql and payments.sql moved 2026-09-11 to
--     work/project-elsa-benchmark/. Bare mentions below mean there.
--
--   PAM   Intrum's portfolio report      RAW.HYPERION_INTRUM_PAM.PAM
--   CAT   Intrum's loan-level feed       RAW.HYPERION_INTRUM_CAT.*
--   PROD  our warehouse                  PROD.NPL_COMMON.FCT_CASE_COLLECTION
--
-- PAM and CAT agree. PROD does not, and PROD_MIN_DATE shows why: our
-- collections start at each loan's first case-SCD version, not at its first
-- payment. Everything earlier is dropped by the inner join in
-- int_npl_case_collection_conformed.sql.
--
-- CAT_UNDATED is a SECOND and separate loss, and it is Intrum's not ours:
-- payments delivered with no transaction date at all. They are included in
-- CAT_COLLECTIONS (the money is real) but they are dropped from PROD one
-- layer earlier than the SCD join — stg_intrum_cat__transactions filters
-- `transaction_date >= dateadd(month,-1,current_date())`, and NULL fails that
-- comparison, so they never reach the join. Verified: FCT_CASE_COLLECTION
-- holds zero rows with a null COLLECTION_DATE out of 134,097,608.
-- Fixing the SCD join will NOT recover this portion — there is no date to
-- place it on.
--
-- Runtime ~4 min, nearly all of it the CAT transaction scan.
-- Scope is set below; '%' widens it. Nothing may follow the final semicolon.
-- ============================================================================

set country       = 'PT';
set seller        = 'MILLENNIUM';
set source_system = '4050';                                  -- Intrum instance
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


-- 1. PAM — one row per batch. Newest delivery, real batches, actual months.
with pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'
),

pam as (
    select
        p.combined_ref               as batch_id,
        sum(p.colltotal)             as pam_collections,
        max(p.period_start_date::date) as pam_last_month
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    inner join pam_file as f
        on f.file_path = p._file_path
    where p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'))::date
    group by p.combined_ref
),

-- 2. CAT — one row per loan, then one row per payment.
--    Both feeds repeat every historical version of every record, so both
--    are reduced to the latest version before anything is summed.
cat_loans as (
    select
        c.long_portfolio_id as batch_id,
        c.case_id           as loan_id
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select batch_id from pam)
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

cat_payments as (
    select
        l.batch_id,
        -t.amount::decimal(38, 2)     as amount,             -- RAW stores it negative
        -- The winning version often has no date while an earlier version of
        -- the same transaction does, so take it across every version. Without
        -- this, CAT_UNDATED reads EUR 58.5m instead of EUR 5.45m and
        -- contradicts payments.sql. Same rule as that file uses.
        max(t.transaction_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                             as payment_date
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    inner join cat_loans as l
        on l.loan_id = t.case_id
    where t._file_path like $raw_prefix || $source_system || '.transactions.%'
      and t.payment_cost_ind = 'P'                           -- payments, not fees
      and coalesce(t.booking_ind, 'N') != 'Y'
      and t.amount is not null
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1
),

cat as (
    select
        batch_id,
        sum(amount)                                                   as cat_collections,
        sum(case when payment_date is null then amount else 0 end)    as cat_undated,
        min(payment_date)                                             as cat_min_date,
        max(payment_date)                                             as cat_max_date
    from cat_payments
    group by batch_id
),

-- 3. PROD — the same collections after our own transformation.
prod as (
    select
        b.batch_bk             as batch_id,
        sum(c.amount)          as prod_collections,
        min(c.collection_date) as prod_min_date
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join PROD.NPL_COMMON.DIM_BATCH as b
        on b.batch_sk = c.batch_sk
    where b.batch_bk in (select batch_id from pam)
    group by b.batch_bk
)

select
    pam.batch_id,
    pam.pam_collections,
    cat.cat_collections,
    prod.prod_collections,

    div0(cat.cat_collections,  pam.pam_collections) as cat_vs_pam,
    div0(prod.prod_collections, pam.pam_collections) as prod_vs_pam,   -- the finding

    cat.cat_undated,                                 -- Intrum sent no date; unrecoverable
    cat.cat_min_date,                                -- first payment Intrum sent us
    prod.prod_min_date,                              -- first payment we kept
    datediff(year, cat.cat_min_date, prod.prod_min_date) as years_lost
from pam
left join cat  on cat.batch_id  = pam.batch_id
left join prod on prod.batch_id = pam.batch_id
order by prod_vs_pam nulls first;
