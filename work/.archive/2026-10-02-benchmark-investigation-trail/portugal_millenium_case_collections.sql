-- ============================================================================
-- portugal_millenium_case_collections — first collection date, all-time
-- collected amount, and the case registration span per batch, from the RAW
-- Intrum case/transaction feed.
-- GRAIN: one row per COMBINED_REF (batch). Amounts in the case currency.
--
--   Terminal : mise run sql -- work/benchmark/portugal_millenium_case_collections.sql
--   Notebook : datalake.q("benchmark/portugal_millenium_case_collections")
--
-- This is the case-level counterpart to portugal_millenium.sql, which reads
-- collections from PAM at batch x month grain. Use that one for a monthly
-- curve; use this one when the question is about the underlying cases.
--
-- ---------------------------------------------------------------------------
-- THE TWO DATES, AND WHY THEY ARE DIFFERENT SHAPES.
--
-- INTRUM_ACQUIRED is PAM's CAPEX_DATE_M, when INTRUM bought the batch from
-- the seller (2005-2016 for this scope). It is a batch attribute, so it is
-- one date per row. ⚠ It is NOT when Brocc bought the book: Brocc bought the
-- same portfolio from Intrum much later, and PROD DIM_PORTFOLIO.CAPEX_DATE is
-- 2025-12-01 for the portfolio these batches roll into, HEI-PT25001-U02/2512.
-- Intrum's date is the one that makes a lifetime curve meaningful, which is
-- also what portugal_millenium.sql anchors on.
--
-- REGISTRATION_DATE is Intrum's own registration of the case — when the case
-- was set up in the servicing system, which is close to but not the same as
-- the batch capex date. It lives at CASE grain, so at this query's batch
-- grain it can only be summarised — the earliest of the batch's cases here.
-- min() skips nulls, so CASES_WITH_REGISTRATION_DATE says how many cases
-- actually carry one: read the date against that, not against the CASES
-- count.
-- To get one row per case instead, drop the aggregate select and group by
-- and return c.case_id, c.registration_date beside the transaction columns.
--
-- ⚠ REGISTRATION_DATE IS NOT ORIGINATION. The feed also carries
-- ORIGINATION_DATE_AT_CLIENT, which is when the original lender opened the
-- loan — years earlier, and a different question. This file reports
-- registration only, as asked.
--
-- ---------------------------------------------------------------------------
-- ⚠ FIVE THINGS THE OBVIOUS VERSION OF THIS QUERY GETS WRONG. Each one
-- inflates the total, most of them by a large multiple.
--
--   1. PAM LIVES IN ITS OWN SCHEMA. The batch table is
--      RAW.HYPERION_INTRUM_PAM.PAM, not RAW.HYPERION_INTRUM_CAT.PAM. CAT
--      holds CASES and TRANSACTIONS only.
--   2. PAM IS BATCH x MONTH x 14 DELIVERIES. Joining it straight to CASES
--      repeats every case once per batch-month row in the feed — hundreds of
--      times over. It is collapsed to one row per batch below and contributes
--      nothing but the scope filter and the capex date.
--      Guard: newest file only, PMODE_NAME = 'Real', no ownership-change rows.
--   3. RAW IS FULL-FILE RE-DELIVERY, NOT A CHANGE FEED. CASES and
--      TRANSACTIONS re-send the whole history of a source system on every
--      extract (24.7bn transaction rows for far fewer real ones). Exactly one
--      extract per source system is pinned below. Without that the total is
--      multiplied by the number of deliveries held.
--   4. CASE_ID IS ONLY UNIQUE WITHIN A SOURCE SYSTEM, so the case-to-
--      transaction join carries the system code as well as the id.
--   5. AMOUNT ARRIVES NEGATED. Intrum sends a collection as a negative and
--      stg_intrum_cat__transactions flips it; the same flip is applied here,
--      so a plain SUM(AMOUNT) on the raw column would come out negative.
--
-- And one more that only bites once a case attribute is selected: CASES is a
-- daily snapshot, so a single extract holds one row per case PER UPDATE DAY.
-- A plain distinct on case_id is enough while only the id is read, but the
-- moment REGISTRATION_DATE comes along, any case whose value was ever
-- corrected returns twice and its transactions are counted twice with it.
-- The latest version of each case is picked below, not distinct.
--
-- Also reproduced from the model, because dropping either double-counts:
-- payments only (PAYMENT_COST_IND = 'P', unbooked excluded), and the
-- container-case rules (1033 sub-cases are the hyphenated ids; 2080 marks
-- them REAL_CASE_IND = '1').
--
-- SELLER_NAME is inconsistently cased in the feed ('MILLENNIUM' and
-- 'Millennium' both exist in Portugal), so it is matched case-insensitively
-- or two portfolios go missing.
--
-- ⚠ COST. This scans one whole extract of TRANSACTIONS per source system with
-- no date bound — minutes, not seconds. Narrow $extract_from, or pin a single
-- source system, if it needs to be cheaper.
-- ============================================================================

set country      = 'PT';           -- matched with like; '%' for the whole feed
set seller       = 'MILLENNIUM';   -- matched case-insensitively with like
set extract_from = '2026-08-01';   -- latest extract at/after this date, per system


-- ── batches in scope: PAM collapsed to one row per batch (trap 2) ──────────
with newest_pam as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'                             -- Guard 1
),

batches as (
    select
        p.combined_ref,
        -- constant across the batch's monthly rows; max() only guards the join
        max(p.capex_date_m::date)                          as intrum_acquired
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    cross join newest_pam as nf
    where p._file_path = nf.file_path                                    -- Guard 1
      and p.pmode_name = 'Real'                                          -- Guard 2
      and coalesce(p.is_ownership_change, 0) = 0                         -- Guard 3
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
    group by p.combined_ref
),

-- ── one extract per source system (trap 3) ──────────────────────────────────
case_extract as (
    select
        parse_json(_file_metadata):system::string          as source_system_code,
        max(parse_json(_file_metadata):extract_ts::string) as extract_ts
    from RAW.HYPERION_INTRUM_CAT.CASES
    where parse_json(_file_metadata):extract_ts::string
          >= to_char($extract_from::date, 'YYYYMMDD')
    group by 1
),

tx_extract as (
    select
        parse_json(_file_metadata):system::string          as source_system_code,
        max(parse_json(_file_metadata):extract_ts::string) as extract_ts
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS
    where parse_json(_file_metadata):extract_ts::string
          >= to_char($extract_from::date, 'YYYYMMDD')
    group by 1
),

-- ── the cases belonging to those batches, latest version of each ───────────
cases as (
    select
        c.case_id,
        c.long_portfolio_id                                as combined_ref,
        parse_json(c._file_metadata):system::string        as source_system_code,
        c.registration_date::date                          as registration_date
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    inner join case_extract as e
        on  e.source_system_code = parse_json(c._file_metadata):system::string
        and e.extract_ts         = parse_json(c._file_metadata):extract_ts::string
    inner join batches as b
        on b.combined_ref = c.long_portfolio_id
    -- container cases: 1033 sub-cases are hyphenated, 2080 flags its own
    where c.case_id not like '%-%'
      and not (parse_json(c._file_metadata):system::string = '2080'
               and c.real_case_ind = '1')
    -- one row per case: the daily snapshot holds one per update day
    qualify
        row_number() over (
            partition by
                parse_json(c._file_metadata):system::string,
                c.case_id
            order by
                coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
        ) = 1
),

-- ── payments, deduplicated to one row per transaction ───────────────────────
transactions as (
    select
        t.case_id,
        parse_json(t._file_metadata):system::string        as source_system_code,
        t.transaction_date::date                           as transaction_date,
        -t.amount::decimal(38, 2)                          as amount              -- trap 5
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    inner join tx_extract as e
        on  e.source_system_code = parse_json(t._file_metadata):system::string
        and e.extract_ts         = parse_json(t._file_metadata):extract_ts::string
    where t.payment_cost_ind = 'P'
      and coalesce(t.booking_ind, 'N') != 'Y'
    -- DK splits one transaction across rows with different pkeys, so the id
    -- is unique only once pkey is concatenated on
    qualify
        row_number() over (
            partition by
                parse_json(t._file_metadata):system::string,
                t.case_id,
                concat(t.orig_tr_id, coalesce(t.pkey, ''))
            order by
                coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
        ) = 1
)

select
    c.combined_ref,
    count(distinct c.case_id)                              as cases,

    -- ---- when Intrum bought the batch (batch grain, one date) ------------
    b.intrum_acquired,                                     -- NOT Brocc's capex

    -- ---- when Intrum registered the cases (case grain, earliest) --------
    min(c.registration_date)                               as earliest_registration_date,
    count(c.registration_date)                             as cases_with_registration_date,

    -- ---- the cash --------------------------------------------------------
    count(t.transaction_date)                              as payments,
    min(t.transaction_date)                                as min_transaction_date,
    max(t.transaction_date)                                as max_transaction_date,
    sum(t.amount)                                          as total_amount

from cases as c
inner join batches as b
    on b.combined_ref = c.combined_ref
left join transactions as t
    on  t.case_id            = c.case_id
    and t.source_system_code = c.source_system_code                      -- trap 4
group by c.combined_ref, b.intrum_acquired
order by c.combined_ref
LIMIT 100;
