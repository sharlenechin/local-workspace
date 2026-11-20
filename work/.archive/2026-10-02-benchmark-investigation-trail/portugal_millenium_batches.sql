-- ============================================================================
-- portugal_millenium_batches — portugal_millenium, narrowed to a named list of
-- PAM batches. Reported collections per batch per month, from the month INTRUM
-- acquired the batch to the latest reported month.
-- GRAIN: one row per (COMBINED_REF, REPORTING_MONTH). Batch × month.
-- Money is in the batch currency (EUR for all of these); not FX-converted,
-- so do not sum across rows of different currencies.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/portugal_millenium_batches.sql
--   Notebook : datalake.q("benchmark/portugal_millenium_batches",
--                         batch_list="PT050030000000,PT06014B010000")
--
-- ⚠ HOW TO SET THE BATCH LIST. $batch_list takes COMBINED_REF values —
-- batch-level refs like PT050030000000, comma-separated, whitespace tolerated,
-- matched case-insensitively. '%' (the default) means every batch in scope,
-- which reproduces portugal_millenium exactly. This is the batch grain, not
-- Intrum's PORTFOLIOID and not Brocc's portfolio_bk: one PORTFOLIOID covers
-- several COMBINED_REFs, so passing a PORTFOLIOID here matches nothing.
--
-- ⚠ THE COUNTRY AND SELLER FILTERS ARE STILL ACTIVE, AND THEY SUBTRACT.
-- $country = 'PT' and $seller = 'MILLENNIUM' are applied ON TOP of the batch
-- list. A ref that is real but sits outside Portugal/Millennium comes back
-- with NO ROWS AND NO WARNING — indistinguishable from a typo. The
-- BATCH_LIST_AUDIT block below exists for exactly this reason: run it and it
-- names every requested ref that returned nothing, and says whether the ref
-- is absent from the feed entirely or merely outside PT/MILLENNIUM. Do not
-- report a total from this file without looking at it.
--
-- WHAT REPORTING_MONTH IS. PAM reports one row per batch per calendar month,
-- and stores that month as its FIRST DAY (PERIOD_START_DATE, described by the
-- data team as "first day of the reporting month"). So 2005-06-01 means "the
-- month of June 2005", not the 1st of June. COLLECTIONS on that row is
-- everything collected during June. It is stored as VARCHAR, so cast before
-- comparing it to a date.
--
-- ACTUALS ONLY. Each delivery also carries plan months out to 2041 in the
-- same shape; those are cut here (see Guard 4), so the series ends at the
-- last reported month — the month before the file's extraction month,
-- 2026-07 in the current delivery. MONTHS_SINCE_ACQUISITION is 0 in the
-- capex month and runs up from there. It CAN be negative: 40 batches in the
-- feed report months before their own capex date (all with capex 2001-01-01,
-- which looks like a system go-live rather than a purchase). Those months
-- are kept, not hidden — a negative value means the capex date is
-- untrustworthy for that batch, not that cash arrived before purchase.
-- Portugal/Millennium has none; the earliest month there is month 0.
--
-- ---------------------------------------------------------------------------
-- WHICH ACQUISITION DATE. INTRUM_ACQUIRED is CAPEX_DATE_M, when INTRUM bought
-- the batch from the seller (2005-2016 here). Brocc bought the same book from
-- Intrum much later — PROD DIM_PORTFOLIO.CAPEX_DATE is 2025-12-01 for the
-- portfolio these batches roll into, HEI-PT25001-U02/2512. This file is
-- anchored on Intrum's date, which is the one that makes a lifetime curve
-- meaningful.
--
-- BALANCE_AT_CAPEX is the batch's balance on its capex-month row, built the
-- same way PROD builds TOTAL_BALANCE: remaining principal + interest + fees.
-- ⚠ Two batches report 0 (PT06014B010000, PT070040000000) — both are
-- single-case batches whose face value only ever appears in
-- PRINCIPAL_AT_ACQUISITION, which is carried beside it for that reason. Read
-- the two together rather than trusting a lone zero.
--
-- ⚠ DEFAULT DATE IS NOT IN PAM, AND WHAT IS HERE IS SURVIVORS ONLY.
-- PAM is batch grain and holds no default date (only AVERAGE_DEBT_AGE, 4.17
-- years for the full PT/MILLENNIUM scope). The dates below are aggregated
-- from PROD's loan level — DIM_CASE.DERIVED_DEFAULT_DATE for the loans still
-- on book at the latest loan snapshot — so they describe the loans that had
-- NOT been collected out by then, not the book as purchased. The loan
-- snapshot only covers 2024-06 onward, so there is no way to see the original
-- population. 12 of the 14 PT/MILLENNIUM batches have loans there (118,400
-- loans, 100% with a derived default date, medians 2000-2010); the other two
-- return NULL. The raw case feed RAW.HYPERION_INTRUM_CAT.CASES holds the full
-- history but is 6.4bn rows / 237 GB, too heavy to join here.
--
-- ⚠ THE PER-BATCH COUNTS IN THIS HEADER DESCRIBE THE FULL PT/MILLENNIUM
-- SCOPE (14 batches), measured 2026-09-10. Once $batch_list narrows the
-- scope they no longer describe what you get back.
--
-- FOUR GUARDS, or the number is wrong (measured 2026-09-10):
--   1. ONE FILE. The table holds 14 whole monthly deliveries; the same
--      batch-month is in all of them, so an unfiltered sum is ~14x too high.
--      The name pattern matters: six mis-loaded 'pam.pam.pam_perimeter.*'
--      files (93,306 rows) would win a plain max(_file_path).
--   2. PMODE_NAME = 'Real'. 'Adjust' rows are internal accounting batches
--      (the data team's own description), not the real book.
--   3. No IS_OWNERSHIP_CHANGE rows: they repeat a batch-month for a legal
--      buyer transfer, with zero balance.
--   4. Actual months only — plan months carry no collections and would
--      stretch the series into the 2030s.
--   Plus: SELLER_NAME is inconsistently cased ('MILLENNIUM' and 'Millennium'
--   both exist in Portugal), so it is matched with upper() or two portfolios
--   go missing.
--
-- ⚠ COLLECTIONS for a past month is restated by later deliveries as late
-- cash lands (batch PT050030000000, January 2026: 0.00 in the first seven
-- files, 5,441.40 from the eighth on). Always read the newest file, which is
-- what Guard 1 does.
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment. run_sql.py
-- sends the file through execute_string(), which splits on ';' — a trailing
-- comment-only chunk is sent as its own statement and fails with
-- "Empty SQL statement". This is why the audit lives in its own file:
--   mise run sql -- work/benchmark/portugal_millenium_batch_audit.sql
-- ============================================================================

set batch_list = '%';         -- COMBINED_REF values, comma-separated; '%' = all
set country    = 'PT';        -- matched with like; '%' for the whole feed
set seller     = 'MILLENNIUM';-- matched case-insensitively with like
set row_limit  = 100000;      -- batch x month: ~250 months per batch


with requested_batches as (
    -- one row per ref the caller asked for, trimmed and upper-cased
    select distinct upper(trim(value::string)) as combined_ref
    from table(split_to_table($batch_list, ','))
),

newest_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'                             -- Guard 1
),

-- Every batch in the current delivery, before country/seller narrowing. Used
-- only by the audit block, to tell "not in the feed" from "not in PT/MILLENNIUM".
all_batches_in_file as (
    select distinct
        upper(p.combined_ref) as combined_ref,
        p.countrycode,
        upper(p.seller_name) as seller
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    cross join newest_file as nf
    where p._file_path = nf.file_path                                    -- Guard 1
      and p.pmode_name = 'Real'                                          -- Guard 2
),

pam as (
    select
        p.portfolioid,
        p.combined_ref,
        p.currency                                    as currency_id,
        p.capex_date_m::date                          as intrum_acquired,
        p.period_start_date::date                     as reporting_month,
        p.colltotal                                   as collections,
        p.salesproceeds                               as sales_proceeds,
        p.rp_remaining_gcv                            as remaining_principal,
        p.rp_remaining_interest                       as remaining_interest,
        p.rp_remaining_cost_fees                      as remaining_fees,
        p.acquisitionprincipal                        as principal_at_acquisition,
        -- The delivery's own extraction month, read exactly as dbt reads it.
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
      -- the batch list; '%' leaves the scope untouched
      and (
          $batch_list = '%'
          or upper(p.combined_ref) in (select combined_ref from requested_batches)
      )
),

-- One row per batch: the balance on its capex-month row.
at_capex as (
    select
        combined_ref,
        max(remaining_principal + remaining_interest + remaining_fees) as balance_at_capex,
        max(principal_at_acquisition)                                  as principal_at_acquisition
    from pam
    where reporting_month = intrum_acquired
    group by combined_ref
),

-- One row per batch: default dates of the loans still on book at the latest
-- loan snapshot. Survivors only — see the warning above.
default_dates as (
    select
        db.batch_bk                                   as combined_ref,
        count(distinct s.case_sk)                     as loans_on_book,
        min(dc.derived_default_date)                  as earliest_default_date,
        dateadd(day, median(datediff(day, '1900-01-01', dc.derived_default_date))::int,
                '1900-01-01'::date)                   as median_default_date,
        max(dc.derived_default_date)                  as latest_default_date
    from PROD.NPL_COMMON.DIM_BATCH as db
    inner join PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
        on s.batch_sk = db.batch_sk
       and s.date_day = (select max(date_day) from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY)
    inner join PROD.NPL_COMMON.DIM_CASE as dc
        on dc.case_sk = s.case_sk
    where db.batch_bk in (select distinct combined_ref from pam)
    group by db.batch_bk
)

select
    p.portfolioid,
    p.combined_ref                                    as batch_ref,
    p.currency_id,
    p.intrum_acquired,
    p.reporting_month,                                -- first day OF that month
    datediff(month, p.intrum_acquired, p.reporting_month)
                                                      as months_since_acquisition,

    -- ---- the month's cash ------------------------------------------------
    p.collections,                                    -- what debtors paid
    p.sales_proceeds,                                 -- what selling assets brought in
    p.collections + p.sales_proceeds                  as gross_cash_recoveries,

    -- ---- constant per batch ----------------------------------------------
    c.balance_at_capex,
    c.principal_at_acquisition,                       -- read with the above
    d.earliest_default_date,
    d.median_default_date,
    d.latest_default_date,
    d.loans_on_book                                   as loans_behind_default_dates

from pam as p
left join at_capex       as c on c.combined_ref = p.combined_ref
left join default_dates  as d on d.combined_ref = p.combined_ref
where p.reporting_month < p.extraction_month                             -- Guard 4
order by p.portfolioid, p.combined_ref, p.reporting_month
limit $row_limit;

