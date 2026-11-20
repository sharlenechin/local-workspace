-- ============================================================================
-- collection_window_vs_capex — when did each batch actually start and stop
-- collecting, relative to the month Intrum bought it?
-- GRAIN: one row per COMBINED_REF (batch). PORTFOLIOID is its first 7 chars,
-- so a portfolio with several batches appears on several rows.
-- Money is in the batch currency; not FX-converted, so do not sum the
-- COLLECTIONS_* columns across rows of different currencies.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/collection_window_vs_capex.sql
--   Notebook : datalake.q("benchmark/collection_window_vs_capex", country="FI")
--
-- Written to answer: do batches report collections BEFORE their capex date,
-- and if so which ones? Measured across the whole feed 2026-09-10: 40 of
-- 11,906 batches do, all sharing capex date 2001-01-01 (38 Finnish, 1 Spanish,
-- 1 German), 1,233 months, EUR 7.52m. In every one of those rows COLLECTIONS
-- equals BUSINESS_PLAN to the cent, while after capex the two agree on only
-- half the rows — so the pre-capex figures are reconstructed history, not
-- observed cash, and the 2001-01-01 capex date is almost certainly a system
-- go-live rather than a purchase. Treat a negative
-- FIRST_COLLECTION_VS_CAPEX_MONTHS as "this batch's capex date is wrong",
-- not as "we collected before we bought it".
--
-- A COLLECTION MONTH IS A MONTH WITH MONEY IN IT. Every batch has a row for
-- every month from its capex date onward, most of them zero, so
-- min(period_start_date) is the reporting start, not the first payment. The
-- FIRST_/LAST_COLLECTION_MONTH columns below use months where COLLECTIONS
-- is non-zero; FIRST_REPORTED_MONTH is kept beside them for the contrast.
--
-- Negative months are possible: COLLECTIONS is net of reversals, so a month
-- of refunds can be below zero. Those still count as collection months.
--
-- Four guards, or the number is wrong — the same ones as
-- portugal_millenium.sql, and the reasoning is written out there:
--   1. one delivery only (the table holds 14, and six mis-loaded
--      'pam_perimeter' files that would win a plain max(_file_path));
--   2. PMODE_NAME = 'Real';
--   3. no IS_OWNERSHIP_CHANGE rows;
--   4. actual months only — forecast months carry BUSINESS_PLAN, never
--      COLLECTIONS, so they would drag LAST_COLLECTION_MONTH into the 2030s.
-- PERIOD_START_DATE is VARCHAR: cast before comparing it to a date.
--
-- The loan-level route cannot answer this. PROD.NPL_COMMON.FCT_CASE_COLLECTION
-- starts 2014-06-24, fourteen years after the pre-capex months in question,
-- and covers 29 of the 40 affected batches only from that date on. The raw
-- case feed RAW.HYPERION_INTRUM_CAT.TRANSACTIONS is the only other candidate.
-- ============================================================================

set country = '%';   -- e.g. 'PT'; matched with like
set seller  = '%';   -- e.g. 'MILLENNIUM'; matched case-insensitively with like


with newest_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'          -- Guard 1
),

months as (
    select
        p.portfolioid,
        p.combined_ref,
        p.countrycode,
        p.seller_name,
        p.currency                                    as currency_id,
        p.capex_date_m::date                          as capex_month,
        p.period_start_date::date                     as month_start,
        p.colltotal                                   as collections,
        p.fc_total                                    as business_plan,
        date_trunc('month', to_timestamp_ntz(
            parse_json(p._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'
        ))::date                                      as extraction_month
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    cross join newest_file as nf
    where p._file_path = nf.file_path                                    -- Guard 1
      and p.pmode_name = 'Real'                                          -- Guard 2
      and coalesce(p.is_ownership_change, 0) = 0                         -- Guard 3
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
),

actuals as (
    select * from months
    where month_start < extraction_month                                 -- Guard 4
)

select
    a.portfolioid,
    a.combined_ref                                        as batch_ref,
    a.countrycode                                         as country_id,
    max(a.seller_name)                                    as seller_name,
    a.currency_id,
    min(a.capex_month)                                    as capex_month,

    -- ---- the reporting window (rows exist whether or not money moved) ---
    min(a.month_start)                                    as first_reported_month,
    max(a.month_start)                                    as last_reported_month,
    count(*)                                              as reported_months,

    -- ---- the collection window (months with money) ----------------------
    min(case when a.collections <> 0 then a.month_start end)
                                                          as first_collection_month,
    max(case when a.collections <> 0 then a.month_start end)
                                                          as last_collection_month,
    count(case when a.collections <> 0 then 1 end)        as months_with_collections,

    -- ---- where the first payment sits against the capex month -----------
    datediff(month, min(a.capex_month),
             min(case when a.collections <> 0 then a.month_start end))
                                                          as first_collection_vs_capex_months,
    case
        when count(case when a.collections <> 0 then 1 end) = 0 then 'no collections'
        when min(case when a.collections <> 0 then a.month_start end) <  min(a.capex_month)
            then 'before capex'
        when min(case when a.collections <> 0 then a.month_start end) =  min(a.capex_month)
            then 'capex month'
        else 'after capex'
    end                                                   as first_collection_timing,

    -- ---- and how much sits on the wrong side of the capex date ----------
    sum(case when a.month_start < a.capex_month then a.collections else 0 end)
                                                          as collections_before_capex,
    sum(a.collections)                                    as collections_total,
    -- In the suspect rows these two are identical, which is the tell that
    -- the history was reconstructed rather than observed.
    sum(case when a.month_start < a.capex_month then a.business_plan else 0 end)
                                                          as business_plan_before_capex

from actuals as a
group by a.portfolioid, a.combined_ref, a.countrycode, a.currency_id
order by first_collection_vs_capex_months nulls last, a.portfolioid, a.combined_ref
