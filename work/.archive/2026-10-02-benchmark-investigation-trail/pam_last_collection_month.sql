-- ============================================================================
-- pam_last_collection_month — the PAM answer to "when did each batch last
-- collect?", which is the closest PAM can get to CAT's max PAYMENT_DATE.
-- GRAIN: one row per PAM COMBINED_REF. All 14 batches, including the three
-- with no CAT loans.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/pam_last_collection_month.sql
--
-- ⚠ PAM HAS NO PAYMENT DATE, AND NO LOAN. Its finest grain is batch × month:
-- "PT050030000000, June 2005, EUR 12,345". So there is no PAM column that
-- corresponds to CAT's PAYMENT_DATE and no query can produce one. What PAM can
-- answer is the last MONTH a batch reported collections in, which is what
-- LAST_COLLECTION_MONTH is. Comparing it with a CAT payment date compares a
-- month to a day — LAST_COLLECTION_MONTH_END is returned so the comparison is
-- at least like-for-like at the coarser grain.
--
-- ⚠ THE FORECAST GUARD IS THE WHOLE QUERY. PAM carries servicer FORECAST rows
-- alongside actuals, and they run years into the future. Without the
-- PERIOD_START_DATE < extract-month bound below, LAST_COLLECTION_MONTH returns
-- a forecast month and the answer is silently nonsense — the mistake looks
-- exactly like a healthy book still collecting. Two more guards ride with it:
-- one PAM file (the newest), and PMODE_NAME = 'Real'.
--
-- MEASURED 2026-09-10. Every batch that collects at all last collected in
-- 2026-07, the newest actuals month in the newest delivery — so PAM is current
-- and uniform, and the batch-by-batch variation visible in CAT's max payment
-- date (2026-01-09 to 2026-01-14) is an artefact of CAT's extract, not of the
-- books. The two batches that never collect never appear.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment.
-- ============================================================================

set country = 'PT';
set seller  = 'MILLENNIUM';


with newest_pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'
),

-- Actuals only. The extract timestamp on the file is the cut: anything dated
-- in or after the extract month is forecast.
pam_rows as (
    select
        p.combined_ref,
        p.period_start_date::date as reporting_month,
        p.colltotal               as collections
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    cross join newest_pam_file as nf
    where p._file_path = nf.file_path
      and p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'))::date
),

-- The amount in that last collecting month, for context: a batch whose final
-- month is a rounding error is not really still collecting.
last_month as (
    select combined_ref, reporting_month, collections
    from pam_rows
    where collections <> 0
    qualify row_number() over (
        partition by combined_ref
        order by reporting_month desc
    ) = 1
)

select
    p.combined_ref                                       as portfolio_id,
    l.reporting_month                                    as last_collection_month,
    last_day(l.reporting_month)                          as last_collection_month_end,
    l.collections                                        as last_month_collections,
    max(p.reporting_month)                               as last_reported_month,
    count(distinct iff(p.collections <> 0,
                       p.reporting_month, null))         as months_with_collections,
    sum(p.collections)                                   as total_collections
from pam_rows as p
left join last_month as l on l.combined_ref = p.combined_ref
group by p.combined_ref, l.reporting_month, l.collections
order by p.combined_ref;
