-- ============================================================================
-- 06_feed_lag — step 7 of METHOD.md. How current is the loan-level feed, for
-- EVERY Intrum instance — so you know what your benchmark dataset cannot see.
--
--   RUN     mise run sql -- work/benchmark-dataset/post-registration-benchmark/templates/06_feed_lag.sql
--   GRAIN   one row per CAT source system
--   COST    minutes — and cheap ON PURPOSE: no case-to-transaction join
--           anywhere. The extract date is a property of the SOURCE SYSTEM, not
--           of a portfolio, so this reads transaction metadata, a distinct
--           batch->system map, and one PAM delivery. Do not "improve" it by
--           joining CASES to TRANSACTIONS; that is the ten-minute query.
--   WORKED  FINDINGS.md §10, last block
--
-- ⚠ LAST_PAYMENT_DATE, NOT THE EXTRACT TIMESTAMP, IS THE HONEST MEASURE. A
--   filename says when the servicer cut the file, not how far the data inside
--   reaches. TRANSACTION_DATE carries far-future sentinels, so it is bounded at
--   today HERE — this is an undeduped metadata scan, the one place a bound is
--   correct. ⚠ Never bound it in a money query (see 02_payments.sql).
-- ⚠ A LAGGING SYSTEM IS USUALLY A DECOMMISSIONED ONE. The servicer retires
--   platforms and moves books to a successor; the retired instance keeps its
--   rows in RAW forever, so read alone it looks like a catastrophe. On the
--   Portugal build, SE/1062 looked 126 months and EUR 1.51bn behind — and 348
--   of its 352 batches were also served by a current instance.
--   → USE BATCHES_STRANDED AND STRANDED_COLLECTIONS, never
--     COLLECTIONS_NOT_YET_DELIVERED on its own.
-- ⚠ PAM IS GLOBAL, CAT IS PER SYSTEM. One PAM delivery covers every country;
--   CAT arrives as a separate stream per instance. A lag on one system says
--   nothing about another.
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

set raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


with newest_pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'
),

pam_rows as (
    select
        p.combined_ref,
        p.countrycode,
        p.period_start_date::date as reporting_month,
        p.colltotal               as collections
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    inner join newest_pam_file as nf on nf.file_path = p._file_path
    where p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string,
              'YYYYMMDDTHH24MISS'))::date
),

-- Scan 1: transaction metadata only. No join, no case list.
system_lag as (
    select
        split_part(t._file_path, '.', 2)                as source_system,
        max(t.transaction_date::date)                   as last_payment_date
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    where t._file_path like $raw_prefix || '%'
      and t.payment_cost_ind = 'P'
      and t.transaction_date::date <= current_date()    -- sentinel guard
    group by 1
),

-- Scan 2: which system serves which batch. Distinct pairs only.
batch_system as (
    select distinct
        c.long_portfolio_id              as combined_ref,
        split_part(c._file_path, '.', 2) as source_system
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || '%'
      and c.long_portfolio_id is not null
),

-- A batch is STRANDED if the only systems serving it are all behind. Measured
-- against the newest last_payment_date of ANY system serving that batch.
batch_currency as (
    select
        bs.combined_ref,
        max(sl.last_payment_date) as best_last_payment_date
    from batch_system as bs
    inner join system_lag as sl on sl.source_system = bs.source_system
    group by bs.combined_ref
),

pam_by_batch as (
    select
        pr.combined_ref,
        max(pr.countrycode)      as countrycode,
        max(pr.reporting_month)  as pam_last_month,
        sum(pr.collections)      as pam_lifetime
    from pam_rows as pr
    group by pr.combined_ref
),

-- Collections PAM reports for months the system's own extract cannot see.
not_yet_delivered as (
    select
        bs.source_system,
        count(distinct bs.combined_ref)                                as batches_served,
        count(distinct iff(bc.best_last_payment_date = sl.last_payment_date,
                           bs.combined_ref, null))                     as batches_stranded,
        listagg(distinct pb.countrycode, ',')
            within group (order by pb.countrycode)                     as countries,
        sum(iff(pr.reporting_month > sl.last_payment_date, pr.collections, 0))
                                                                       as collections_not_yet_delivered,
        sum(iff(pr.reporting_month > sl.last_payment_date
                and bc.best_last_payment_date = sl.last_payment_date,
                pr.collections, 0))                                    as stranded_collections
    from batch_system    as bs
    inner join system_lag     as sl on sl.source_system = bs.source_system
    inner join batch_currency as bc on bc.combined_ref  = bs.combined_ref
    inner join pam_by_batch   as pb on pb.combined_ref  = bs.combined_ref
    inner join pam_rows       as pr on pr.combined_ref  = bs.combined_ref
    group by bs.source_system
)

select
    sl.source_system,
    n.countries,
    sl.last_payment_date,                                   -- the honest measure
    datediff(month, sl.last_payment_date, current_date())   as months_behind,
    n.batches_served,
    n.batches_stranded,                                     -- no current system serves these
    n.collections_not_yet_delivered,                        -- ⚠ never quote this alone
    n.stranded_collections                                  -- the real blind spot
from system_lag as sl
left join not_yet_delivered as n on n.source_system = sl.source_system
order by n.stranded_collections desc nulls last, sl.source_system;
