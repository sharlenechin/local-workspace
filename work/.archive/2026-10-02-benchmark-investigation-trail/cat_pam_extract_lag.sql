-- ============================================================================
-- cat_pam_extract_lag — how far behind Intrum's portfolio report (PAM) the
-- loan-level CAT feed runs, for EVERY Intrum system, not just Portugal.
-- GRAIN: one row per CAT source system, with the batches and countries it
-- serves and the collections PAM has already reported that CAT cannot yet see.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/cat_pam_extract_lag.sql
--
-- WHY THIS IS CHEAP, AND WHY IT LOOKS LIKE IT SHOULDN'T BE.
-- The obvious way to ask "how current is the loan-level feed" is to join cases
-- to transactions per portfolio, which means the 24.7bn-row table joined to the
-- 6.4bn-row one — the query that takes ten minutes elsewhere in this folder.
-- None of that is needed. The extract date is a property of the SOURCE SYSTEM,
-- not of the portfolio, so this reads:
--   · TRANSACTIONS: two metadata columns, no join, one grouped scan
--   · CASES:        two columns, distinct pairs, to map batch -> system
--   · PAM:          one delivery, small
-- No case-to-transaction join anywhere. Minutes, not tens of minutes.
--
-- ⚠ LAST_PAYMENT_DATE, NOT THE EXTRACT TIMESTAMP, IS THE HONEST MEASURE.
-- A delivery's filename timestamp says when Intrum cut the file; it does not
-- say how far the data inside it reaches, and the two differ. What matters for
-- coverage is the newest payment actually present, so that is what is reported.
-- TRANSACTION_DATE carries 2099 sentinels, so it is bounded at today.
--
-- ⚠ PAM IS GLOBAL, CAT IS PER SYSTEM. One PAM delivery covers every country;
-- the CAT feed arrives as a separate stream per Intrum instance. So a lag on
-- one system says nothing about another, which is exactly the question here.
--
-- ⚠ A LAGGING SYSTEM IS USUALLY A DECOMMISSIONED ONE — CHECK COVERAGE BEFORE
-- RAISING IT. Intrum retires platforms and moves books to a successor, and the
-- retired system keeps its old rows in RAW forever. Read the lag alone and the
-- retired platform looks like a catastrophic gap. Measured 2026-09-10:
--     1062 SE  last payment 2016-01-29, 126 months behind, EUR 1.51bn "missing"
--              -> 348 of its 352 batches are ALSO served by 2080, which is
--                 current. Only 4 are stranded, worth EUR 116,974.70. Not a gap.
--     7006 ES  last payment 2025-11-07, 8 months behind, EUR 18.04m "missing"
--              -> all 79 batches also served by 4042, current. Zero stranded.
--     4050 PT  last payment 2026-01-14, 6 months behind, EUR 11.05m
--              -> 251 of 251 batches stranded. NO other system serves them.
--                 THE ONLY REAL GAP IN THE ESTATE.
-- BATCHES_STRANDED and TRULY_UNDELIVERED below apply that test. Use those two
-- columns, never COLLECTIONS_NOT_YET_DELIVERED on its own.
--
-- ⚠ COLLECTIONS_NOT_YET_DELIVERED is PAM's own reported cash for months after
-- the last payment CAT holds. It is not missing money — it is money reported
-- at batch level that has not yet arrived at loan level. Read it as the size
-- of the blind spot, and note it grows every month the feed is not refreshed.
--
-- PAM guards as elsewhere: newest file matching 'pam.pam.pam.2', PMODE_NAME
-- 'Real', no ownership-change rows, actual months only.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment.
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
    inner join newest_pam_file as nf
        on nf.file_path = p._file_path
    where p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'))::date
),

-- Scan 1: transaction metadata only. No join, no case list.
tx_reach as (
    select
        split_part(_file_path, '.', 2)                as system_code,
        max(split_part(_file_path, '.', 4))           as newest_extract,
        max(case when transaction_date::date <= current_date()
                 then transaction_date::date end)     as last_payment_date
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS
    where payment_cost_ind = 'P'
      and coalesce(booking_ind, 'N') != 'Y'
    group by 1
),

-- Scan 2: two columns, to map each batch to the system that serves it.
batch_system as (
    select distinct
        split_part(_file_path, '.', 2) as system_code,
        long_portfolio_id              as combined_ref
    from RAW.HYPERION_INTRUM_CAT.CASES
    where long_portfolio_id is not null
),

-- A batch is stranded only if NO system serving it is current.
covered as (
    select
        bs.combined_ref,
        max(case when t.last_payment_date >= dateadd(month, -3, current_date())
                 then 1 else 0 end) as has_current_system
    from batch_system as bs
    left join tx_reach as t on t.system_code = bs.system_code
    group by bs.combined_ref
),

joined as (
    select
        bs.system_code,
        pr.combined_ref,
        pr.countrycode,
        pr.reporting_month,
        pr.collections,
        t.last_payment_date,
        t.newest_extract,
        cv.has_current_system
    from pam_rows as pr
    inner join batch_system as bs
        on bs.combined_ref = pr.combined_ref
    inner join covered as cv
        on cv.combined_ref = pr.combined_ref
    left join tx_reach as t
        on t.system_code = bs.system_code
)

select
    system_code,
    count(distinct combined_ref)                                as batches,
    listagg(distinct countrycode, ' ') within group (order by countrycode) as countries,
    max(last_payment_date)                                      as cat_last_payment,
    max(newest_extract)                                         as cat_newest_extract,
    max(reporting_month)                                        as pam_last_month,
    datediff(month, max(last_payment_date), max(reporting_month)) as lag_months,
    count(distinct case when has_current_system = 0 then combined_ref end) as batches_stranded,
    sum(case when reporting_month > date_trunc('month', last_payment_date)
             then collections else 0 end)                       as collections_not_yet_delivered,
    -- the honest number: only batches no current system serves
    sum(case when has_current_system = 0
              and reporting_month > date_trunc('month', last_payment_date)
             then collections else 0 end)                       as truly_undelivered,
    sum(collections)                                            as pam_lifetime_collections
from joined
group by system_code
order by truly_undelivered desc, lag_months desc nulls last;
