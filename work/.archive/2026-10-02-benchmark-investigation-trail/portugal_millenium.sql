-- ============================================================================
-- portugal_millenium — reported collections per batch per month, from the
-- month INTRUM acquired the batch to the latest reported month.
-- GRAIN: one row per (COMBINED_REF, REPORTING_MONTH). Batch × month.
-- Money is in the batch currency (EUR for all of these); not FX-converted,
-- so do not sum across rows of different currencies.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/portugal_millenium.sql
--   Notebook : datalake.q("benchmark/portugal_millenium", country="PT", seller="MILLENNIUM")
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
-- Portugal/Millennium has none; the earliest month here is month 0.
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
-- ⚠ Two batches here report 0 (PT06014B010000, PT070040000000) — both are
-- single-case batches whose face value only ever appears in
-- PRINCIPAL_AT_ACQUISITION, which is carried beside it for that reason. Read
-- the two together rather than trusting a lone zero.
--
-- ⚠ DEFAULT DATE IS NOT IN PAM, AND WHAT IS HERE IS SURVIVORS ONLY.
-- PAM is batch grain and holds no default date (only AVERAGE_DEBT_AGE, 4.17
-- years for this scope). The dates below are aggregated from PROD's loan
-- level — DIM_CASE.DERIVED_DEFAULT_DATE for the loans still on book at the
-- latest loan snapshot — so they describe the loans that had NOT been
-- collected out by then, not the book as purchased. The loan snapshot only
-- covers 2024-06 onward, so there is no way to see the original population.
-- 12 of these 14 batches have loans there (118,400 loans, 100% with a
-- derived default date, medians 2000-2010); the other two return NULL.
-- The raw case feed RAW.HYPERION_INTRUM_CAT.CASES holds the full history but
-- is 6.4bn rows / 237 GB, too heavy to join here.
--
-- ---------------------------------------------------------------------------
-- ⚠ PRE-ACQUISITION COLLECTIONS COME FROM THE CAT FEED, AND THEY COST.
-- PAM structurally cannot show cash collected before Intrum bought a batch:
-- the batch enters the file in its capex month, so the series starts at
-- acquisition by construction. The servicer's own ledger,
-- RAW.HYPERION_INTRUM_CAT.CASES + TRANSACTIONS, reaches further back, and the
-- CAT_* columns below read it.
--
-- ⚠ RUNTIME, AND IT IS THE WHOLE STORY HERE. TRANSACTIONS is 24.7bn rows /
-- 454 GB and CASES 6.4bn / 221 GB, neither with a clustering key, so the
-- CASE_ID join reads both end to end. `explain` on this file, 2026-09-10,
-- assigns 53,398 of 55,653 micro-partitions and 673 GiB — 96% of the data,
-- i.e. effectively no pruning. It does NOT get cheaper by narrowing to one
-- batch: a single-batch probe was still running at 13 minutes on
-- NPL_ANALYST_WH (an X-Small) and queued everything else on that warehouse
-- behind it. Nothing filters on a column either table is sorted by, so
-- narrowing $country or $seller changes nothing.
--
-- Everything above the CAT_* columns returns in seconds; these columns are
-- the entire cost. Delete the CAT_BY_BATCH join to get the fast query back.
-- Before running it, know that it will occupy NPL_ANALYST_WH for minutes,
-- and other people share that warehouse.
--
-- WHICH BOUNDARY. Two different "before" dates are reported, because they
-- answer different questions:
--   CAT_COLLECTIONS_BEFORE_CAPEX        — cash dated before the batch's
--       CAPEX_DATE_M, i.e. before Intrum owned it. This is the gap PAM
--       cannot show.
--   CAT_COLLECTIONS_BEFORE_REGISTRATION — cash dated before that case's own
--       REGISTRATION_DATE in CAT, i.e. before the servicer opened the case.
-- They are not nested: the servicer often holds a case before the purchase
-- completes (measured across PROD: 4,624,399 loans, 24% of those on book,
-- register before their batch's capex month), so a payment can be before
-- capex but after registration.
--
-- ⚠ THE CAT_* FIGURES ARE UNVERIFIED. Every other number in this header was
-- measured; these columns were written from the data team's own models
-- (brocc-data stg_intrum_cat__transactions + int_npl_case_collection_intrum)
-- but the query has not been run to completion, because of the runtime above.
-- Treat the first result as a measurement, not a confirmation, and check
-- CAT_COLLECTIONS_TOTAL against PAM's summed COLLECTIONS before trusting the
-- pre-capex slice.
-- ---------------------------------------------------------------------------
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
-- FOUR MORE GUARDS ON THE CAT SIDE, and these are the easy ones to miss
-- because both tables look like fact tables and are not:
--   5. CASES IS A CHANGE FEED. It carries one row per case per update —
--      2,726,688 rows for 28,444 cases on PT050030000000, a ~96x fan-out
--      (measured 2026-09-10). Joined raw to TRANSACTIONS it multiplies every
--      payment by that factor, so it is reduced to one row per case first.
--   6. PAYMENTS ONLY. PAYMENT_COST_IND = 'P' and BOOKING_IND <> 'Y' are
--      Intrum's own filters, lifted from int_npl_case_collection_intrum;
--      without them the sum includes costs and fees, not collections.
--   7. TRANSACTIONS IS A CHANGE FEED TOO, deduped on
--      (CASE_ID, ORIG_TR_ID || PKEY) keeping the latest RECORD_UPDATE —
--      again the data team's key, not one invented here.
--   8. JUNK DATES. TRANSACTION_DATE carries 1900-01-01 and 2099-12-30
--      sentinels, so it is bounded before any min() or before/after test.
--      Without the lower bound CAT_FIRST_PAYMENT_DATE is 1900-01-01 for
--      most batches.
--   Plus: AMOUNT IS SIGN-FLIPPED IN RAW. A collection is stored negative;
--   stg_intrum_cat__transactions reads it as -AMOUNT, and so does this file.
--   A plain sum(amount) returns collections as a negative number.
--
-- ⚠ COLLECTIONS for a past month is restated by later deliveries as late
-- cash lands (batch PT050030000000, January 2026: 0.00 in the first seven
-- files, 5,441.40 from the eighth on). Always read the newest file, which is
-- what Guard 1 does.
-- ============================================================================

set country = 'PT';           -- matched with like; '%' for the whole feed
set seller  = 'MILLENNIUM';   -- matched case-insensitively with like


with newest_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'                             -- Guard 1
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
),

-- One row per batch, so the CAT side can be scoped and dated without
-- re-reading PAM.
batches as (
    select
        combined_ref,
        min(intrum_acquired) as intrum_acquired
    from pam
    group by combined_ref
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
    where db.batch_bk in (select combined_ref from batches)
    group by db.batch_bk
),

-- ---------------------------------------------------------------------------
-- The CAT side. Everything below is the slow part — see the RUNTIME warning.
-- ---------------------------------------------------------------------------

-- CASES collapsed to one row per case (Guard 5). REGISTRATION_DATE is taken
-- as min() across the case's updates: it is meant to be fixed, and min()
-- costs one pass where picking the latest version costs a window.
cat_cases as (
    select
        c.long_portfolio_id              as combined_ref,
        c.case_id,
        min(c.registration_date)::date   as case_registered
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c.long_portfolio_id in (select combined_ref from batches)
    group by c.long_portfolio_id, c.case_id
),

-- One row per payment, on the data team's own terms.
cat_payments as (
    select
        c.combined_ref,
        c.case_id,
        c.case_registered,
        -- Raw AMOUNT is negative for a collection; negated exactly as
        -- stg_intrum_cat__transactions does it.
        -t.amount::decimal(38, 2)        as amount,
        t.transaction_date::date         as transaction_date,
        t.currency                       as cat_currency_id
    from cat_cases as c
    inner join RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
        on t.case_id = c.case_id
    where t.payment_cost_ind = 'P'                                       -- Guard 6
      and coalesce(t.booking_ind, 'N') != 'Y'                            -- Guard 6
      and t.transaction_date::date between '1990-01-01' and current_date()
                                                                         -- Guard 8
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1                                                                -- Guard 7
),

-- One row per batch, to hang beside the monthly PAM rows.
cat_by_batch as (
    select
        x.combined_ref,
        count(distinct x.case_id)                     as cat_cases_with_payments,
        max(x.cat_currency_id)                        as cat_currency_id,
        min(x.transaction_date)                       as cat_first_payment_date,
        min(case when x.transaction_date < b.intrum_acquired
                 then x.transaction_date end)         as cat_first_payment_before_capex,
        sum(case when x.transaction_date < b.intrum_acquired
                 then x.amount else 0 end)            as cat_collections_before_capex,
        sum(case when x.case_registered is not null
                  and x.transaction_date < x.case_registered
                 then x.amount else 0 end)            as cat_collections_before_registration,
        sum(x.amount)                                 as cat_collections_total
    from cat_payments as x
    inner join batches as b on b.combined_ref = x.combined_ref
    group by x.combined_ref
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
    d.loans_on_book                                   as loans_behind_default_dates,

    -- ---- pre-acquisition cash from CAT (constant per batch) -------------
    -- LEFT JOIN: a batch with no CAT cases keeps its PAM rows and returns
    -- NULL here. PT06014B010000 is one — it has no rows in CASES at all.
    cat.cat_first_payment_date,                       -- earliest payment, any date
    cat.cat_first_payment_before_capex,               -- NULL if none predates capex
    cat.cat_collections_before_capex,                 -- before Intrum owned it
    cat.cat_collections_before_registration,          -- before the case was opened
    cat.cat_collections_total,                        -- whole CAT life of the batch
    cat.cat_cases_with_payments,
    cat.cat_currency_id                               -- check it matches CURRENCY_ID

from pam as p
left join at_capex       as c on c.combined_ref = p.combined_ref
left join default_dates  as d on d.combined_ref = p.combined_ref
left join cat_by_batch   as cat on cat.combined_ref = p.combined_ref
where p.reporting_month < p.extraction_month                             -- Guard 4
order by p.portfolioid, p.combined_ref, p.reporting_month
limit 100;