-- ============================================================================
-- add_portugal_millennium_cases — one row per case for the Portugal /
-- Millennium books, with the collections split either side of the case's own
-- registration date.
-- GRAIN: one row per CASE_ID. Amounts in the case currency (EUR throughout
-- this scope) and NOT FX-converted.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/add_portugal_millennium_cases.sql
--   Notebook : datalake.q("benchmark/add_portugal_millennium_cases")
--
-- WHAT THIS REPLACES, AND WHY IT IS FASTER.
-- The findings behind every guard below were established in
-- portugal_millenium.sql, portugal_millenium_case_collections.sql,
-- portugal_millenium_transactions.sql and intrum_case_collection_raw.sql
-- (all measured 2026-09-10). Those files stay as the audit trail; this one is
-- the consolidated, cheap version, so nothing here is a new claim about the
-- data. Six things were changed, and together they are the whole speed-up:
--
--   1. _FILE_PATH IS MATCHED AS A LITERAL PREFIX, with no leading wildcard.
--      That is the single biggest win. Snowflake prunes micro-partitions on a
--      prefix; it cannot prune on a pattern beginning with a wildcard.
--      portugal_millenium.sql matched a pattern in the middle of the path and
--      got no pruning at all — its own explain, 2026-09-10, assigned 53,398 of
--      55,653 micro-partitions and 673 GiB, i.e. 96% of the feed. Do not put
--      a wildcard in front of $raw_prefix or the timeout comes back.
--   2. ONE SOURCE SYSTEM. CASE_ID is unique only inside an Intrum instance,
--      so the join has to be pinned to one anyway (Guard 6). Pinning it also
--      cuts the transaction read from 24.7bn rows to roughly 404m.
--   3. ONE EXTRACT of that system, all of its part files. RAW is full-file
--      re-delivery, not a change feed, so one extract already holds the whole
--      history and the others are copies of it (Guard 5).
--   4. THE CASE LIST IS APPLIED BEFORE THE DEDUPE WINDOW, not after. The
--      window in Guard 7 runs over the cases in scope instead of over every
--      case in the instance.
--   5. NO PAM MONTH ROWS. PAM contributes the scope filter and nothing else,
--      so it is collapsed to one row per batch before anything touches it.
--      portugal_millenium.sql hung the CAT aggregate off batch x month x 14
--      deliveries.
--   6. THE PROD JOIN IS ONE DIMENSION LOOKUP, not a snapshot scan.
--      portugal_millenium.sql reached DEFAULT_DATE through DIM_BATCH ->
--      FCT_CASE_SNAPSHOT_DAILY -> DIM_CASE, which both costs more and
--      restricts the answer to loans still on book. Here DIM_CASE is joined
--      straight on CASE_BK, one current row per loan, and
--      FCT_CASE_SNAPSHOT_DAILY is gone. REGISTRATION_DATE stays on RAW.
--      This is a correctness fix as much as a cost one — see DEFAULT_DATE.
--
-- ---------------------------------------------------------------------------
-- THE COLUMN NAMES ARE THE ONES ASKED FOR, AND TWO OF THEM ARE RISKY.
--
-- ⚠ PORTFOLIO_ID here is PAM's COMBINED_REF — the BATCH ref, e.g.
--   PT050030000000. It is neither of the two other things that carry that
--   name: Intrum's own PORTFOLIOID (PT05003, 7 characters, one per several
--   batches) nor Brocc's PORTFOLIO_BK in PROD (HEI-PT25001-U02/2512 for this
--   scope). Do not join this column to either of them.
--
-- ⚠ CASE_ID is the loan identifier, and it is the RAW servicer id, not the
--   warehouse key. PROD's key is CASE_BK = source_system_code || '-' ||
--   case_id, so joining this column straight to PROD matches nothing. Prefix
--   it with $source_system first. There is also no CASE_SK here: that is a
--   version key, and this file is one row per loan, not per version.
--
-- ---------------------------------------------------------------------------
-- ⚠⚠ DEFAULT_DATE COMES FROM PROD, BECAUSE THE RAW COLUMN IS EMPTY.
-- RAW.HYPERION_INTRUM_CAT.CASES.DEFAULT_DATE is NULL for 120,713 of 120,713
-- cases in this scope — 100%, measured 2026-09-10. Reading it from RAW returns
-- a column of nothing, which is why this file joins PROD.NPL_COMMON.DIM_CASE
-- for that one field and nothing else. Every other column is still RAW.
--
-- ⚠ AND IT IS A DERIVED DATE, NOT AN OBSERVED ONE. Because the raw value is
-- null, PROD's number is entirely back-fill. The chain, from the team's models:
--   int_npl_case_intrum   default_date_adjusted =
--       coalesce(raw default_date, invoices.max_due_date)   <- Portugal branch
--   dim_npl_case          derived_default_date  =
--       coalesce(that, add_months(origination_date, 36))
-- So DEFAULT_DATE below is the invoice-derived date (max invoice due date for
-- Portugal), never a servicer-stated default date. DIM_CASE also exposes
-- DERIVED_DEFAULT_DATE, which fills the remainder from origination + 36
-- months; swap the column in the final select if you want that instead, and
-- know that the extra coverage is synthetic. For instance 4050 the two agree
-- on all but one loan anyway (1,156,732 populated of 1,156,733).
--
-- ⚠ DEFAULT_DATE CARRIES JUNK SENTINELS, AND THEY ARE RETURNED AS-IS.
-- Across instance 4050 in DIM_CASE the column runs 1900-01-01 to 2099-12-31;
-- those are placeholders, not dates. Within this scope, measured 2026-09-10:
--   120,713 of 120,713 cases get a DEFAULT_DATE, so the PROD join loses none
--   1,907 of them (1.58%) are at or below 1990-01-01 — the low sentinel
--   0 are future-dated, so the 2099 end of the range does not reach this scope
--   real dates run 1990-01-15 to 2017-01-10
-- They are NOT nulled here, so the problem stays visible rather than becoming
-- folklore. Bound the column yourself before computing a debt age off it: a
-- 1900 row turns into a ~125-year-old debt and will drag any average with it.
--
-- ⚠ 413 CASES DEFAULT AFTER THEY WERE REGISTERED (0.34%). A servicer normally
-- takes on a case that has already defaulted, so DEFAULT_DATE > REGISTRATION_
-- DATE is the wrong way round. It is a small enough slice to leave in place,
-- but it means DEFAULT_DATE and REGISTRATION_DATE cannot be assumed ordered —
-- do not compute a debt age as a positive quantity without checking the sign.
-- Worth raising with the data team rather than fixing here: the back-fill uses
-- the max invoice due date, which can legitimately postdate registration, so
-- this may be the derivation showing through rather than bad source data.
--
-- The alternative default date, PROD DIM_CASE.DERIVED_DEFAULT_DATE restricted
-- to loans on the latest daily snapshot, is what portugal_millenium.sql used.
-- It is survivors-only: that snapshot starts 2024-06, so it describes the
-- loans not yet collected out rather than the book as purchased. Joining
-- DIM_CASE on CASE_BK, as here, has no such restriction.
--
-- ⚠ REGISTRATION_DATE IS NOT ORIGINATION. It is when Intrum opened the case in
-- its servicing system. The feed also carries ORIGINATION_DATE_AT_CLIENT, when
-- the original lender wrote the loan, which is years earlier and a different
-- question. Registration is what the split below uses, as asked.
--
-- ⚠ THE SPLIT IS NULL, NOT ZERO, WHEN REGISTRATION_DATE IS MISSING. A case
-- with no registration date cannot be put on either side of it. Its cash is
-- reported in neither column, and both come back NULL so the gap is visible.
-- Dumping it into the "on or after" bucket would have been the silent version.
-- Consequence: the two columns do not sum to the case's total collections
-- across the whole file. If you need that total, add sum(amount) beside them.
--
-- ⚠ COLLECTIONS_PRE_REGISTRATION IS NOT "BEFORE BROCC OWNED IT", AND NOT
-- "BEFORE INTRUM OWNED IT" EITHER. Three dates are in play and they do not
-- nest. Measured across PROD, 4,624,399 loans — 24% of those on book — are
-- registered before their batch's capex month, so the servicer routinely holds
-- a case before the purchase completes. A payment can therefore be before
-- capex but after registration. If the question is the pre-acquisition gap
-- rather than the pre-registration one, compare against CAPEX_DATE_M instead;
-- portugal_millenium.sql reports both boundaries side by side.
--
-- ---------------------------------------------------------------------------
-- SEVEN GUARDS, or the number is wrong. Every one was measured 2026-09-10 and
-- every one inflates the total, most by a large multiple.
--
--   1. ONE PAM FILE. PAM holds 14 whole monthly deliveries, so an unguarded
--      read repeats every batch 14 times. The name pattern matters: six
--      mis-loaded 'pam.pam.pam_perimeter.*' files (93,306 rows) would win a
--      plain max of the path.
--   2. PMODE_NAME = 'Real'. 'Adjust' rows are internal accounting batches, not
--      the real book. And SELLER_NAME is inconsistently cased in the feed
--      ('MILLENNIUM' and 'Millennium' both exist in Portugal), so it is
--      matched with upper() or two portfolios go missing. IS_OWNERSHIP_CHANGE
--      rows repeat a batch-month for a legal buyer transfer and are dropped.
--   3. PAM COLLAPSED TO ONE ROW PER BATCH BEFORE ANY JOIN — about 5,000
--      batch x month x delivery rows per batch in this scope, so joining it
--      to case level multiplies every case by that.
--   4. AN EXTRACT IS SPLIT ACROSS PART FILES, ON BOTH TABLES:
--      cat.4050.cases.20251214T120032.1.parquet through .4.parquet, and
--      cat.4050.transactions.20251214T120032.1.parquet and .2.parquet. So the
--      extract is matched on its <ts> segment with every part kept. Taking
--      the max of the whole path would return ONE part and undercount with no
--      error at all. (intrum_case_collection_raw.sql's header says a CASES
--      extract is never split. That is not true of this instance — measured
--      2026-09-10 — so the same <ts> match is applied to both tables here.)
--   5. CASES AND TRANSACTIONS ARE BOTH CHANGE-HISTORY FEEDS, not lists. CASES
--      holds 17,841,296 rows for the 120,713 cases in this scope — 147x —
--      because every delivery repeats every historical version of every case.
--      Deduped to the latest version per CASE_ID. 84 of those cases carry two
--      different LONG_PORTFOLIO_IDs over their history, so a plain distinct
--      would post their cash to two batches at once; latest-version-wins
--      picks one.
--   6. CASE_ID IS NOT UNIQUE ACROSS INTRUM INSTANCES, only within a source
--      system — the data team's key is source_system_code || '-' || case_id.
--      Joining on CASE_ID alone drags in other countries' transactions: the
--      cases in this scope match rows in 601 transaction files, while the
--      instance these books actually live in has 11. Both sides are pinned to
--      $source_system.
--   7. PAYMENTS ONLY, DEDUPED ON THE TEAM'S OWN KEY. Both rules are lifted
--      from brocc-data stg_intrum_cat__transactions and
--      int_npl_case_collection_intrum:
--        · payment_cost_ind = 'P' and booking_ind <> 'Y' — otherwise the sum
--          includes costs and fees, not collections;
--        · a transaction is unique on (case_id, orig_tr_id || coalesce(pkey,
--          '')), latest record_update wins. Denmark splits one transaction
--          across rows with different pkeys, which is why pkey is in the key.
--      The container-case rules come from int_npl_case_intrum: hyphenated ids
--      are 1033 sub-cases and are dropped for every system, as the model does
--      it, and 2080 marks its own sub-cases real_case_ind = '1'. Neither
--      fires on 4050 — measured 2026-09-10, the hyphen rule changes nothing
--      here: 120,713 cases and 13 batches with it and without it. They are
--      kept so that changing $source_system stays correct.
--
-- ⚠⚠ THE NEWEST EXTRACT IS A DELTA, NOT A FULL FILE, AND 'latest' WALKS
-- STRAIGHT INTO IT. Every extract of instance 4050 is a complete re-delivery
-- except the newest, which is a tiny top-up. Measured 2026-09-10:
--
--     table         extract_ts        rows        distinct case_ids
--     cases         20251214T120032   85,199,725          1,156,768
--     cases         20260114T171703   85,386,136          1,156,768
--     cases         20260115T071911        1,178              1,166   <- delta
--     transactions  20251009T115213   77,475,485          1,137,985
--     transactions  20251027T151127   81,404,436          1,156,768
--     transactions  20251110T160253   81,523,585          1,156,768
--     transactions  20251214T120032   81,934,316          1,156,768
--     transactions  20260114T171703   82,223,378          1,156,768
--     transactions  20260115T071911        2,486                122   <- delta
--
-- $extract_ts = 'latest' takes the max <ts>, which is the delta on both
-- tables, so the query would come back with a handful of rows and NO ERROR.
-- That is why the default below is a pinned full extract, 20260114T171703 —
-- the newest complete one, and only 13 hours older than the delta.
-- Re-derive it with the query above's shape when this ages:
--   select split_part(_file_path, '.', 4) as extract_ts, count(*)
--   from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS
--   where _file_path like 'data-prod-data-raw-sftp-071269be/intrum/cat.4050.transactions.%'
--   group by 1 order by 1;
-- and take the newest ts whose count is in line with the others, not the
-- newest ts. If this file returns zero rows, the pinned extract has aged out
-- of the table — that is the symptom, and this is the fix.
--
-- The pin is also the second-biggest saving after the prefix pruning: one full
-- extract is 82,223,378 rows against 404,563,686 for all six, and 0.33% of the
-- 24.7bn-row table. It costs nothing in correctness, because a full extract
-- already contains the instance's whole history — the four complete extracts
-- above all carry the same 1,156,768 cases.
--
-- ⚠ THE TRANSACTION KEY IS THE TEAM'S, INCLUDING ITS WEAKNESS. Snowflake's
-- concat returns NULL if any argument is NULL, so a payment with a NULL
-- ORIG_TR_ID lands in a single NULL partition and all but one of those rows is
-- dropped by Guard 7. int_npl_case_collection_intrum has the same shape, so
-- this file agrees with PROD; it is not a safe key in its own right. If a
-- pre-registration total here looks low, count the NULL-ORIG_TR_ID rows for
-- the scope before assuming the data is thin.
--
-- ⚠ AMOUNT IS STORED SIGN-FLIPPED. Intrum sends a collection as a negative;
-- stg_intrum_cat__transactions reads it as -AMOUNT and so does this file. A
-- plain sum of the raw column returns the right magnitude with the wrong sign.
--
-- ⚠ TRANSACTION_DATE CARRIES JUNK. 1900-01-01 and 2099-12-30 sentinels are in
-- the column, so it is bounded before the before/after test. This DROPS those
-- payments rather than bucketing them: a 1900-01-01 row would otherwise land
-- in COLLECTIONS_PRE_REGISTRATION for almost every case and is the single
-- easiest way to invent a large pre-registration figure.
--
-- ⚠ 12 OF 14, AND THE TWO MISSING BOOKS GO MISSING FOR DIFFERENT REASONS.
-- Portugal/Millennium has 14 batches in PAM. 13 appear anywhere in the CAT
-- case feed, and only 12 survive. Measured 2026-09-10:
--   PT06014B010000 — no rows in CASES at all, so it has no cases to report.
--   PT15018A040000 — 84 cases in earlier versions, ZERO in the latest one.
--       These are exactly the 84 reassigned cases named in Guard 5: every one
--       of them now carries a different LONG_PORTFOLIO_ID, so the batch
--       disappears the moment latest-version-wins is applied. Its cash is not
--       lost, it is posted to whichever batch the cases moved to — which is
--       the right answer, and also the reason a plain distinct would have
--       double-counted it.
-- The other twelve are unaffected: cases-any-version equals
-- cases-latest-version on all of them, and they sum to 120,713 exactly.
-- portugal_millenium_transactions.sql's header says 13, counted before the
-- dedupe. Either way a missing book is invisible in this output, so check the
-- distinct PORTFOLIO_ID count and run portugal_millenium_batch_audit.sql
-- before reporting a scope total.
--
-- ---------------------------------------------------------------------------
-- WHAT ONE RUN RETURNS, measured 2026-09-10 on the defaults below, so a rerun
-- can be sanity-checked against it:
--   120,713 cases across 12 batches. 8m17s cold on NPL_ANALYST_WH (X-Small),
--     4m01s on a warm rerun. For contrast, portugal_millenium.sql's CAT join
--     never finished at all: a single-batch probe was still running at 13
--     minutes and queued everything else on the warehouse behind it.
--   registration_date populated on 120,713 of 120,713 (100%), 2005-06-29 to
--     2017-01-10, so the NULL-registration case below does not arise here yet
--   default_date populated on 120,713 of 120,713 via the PROD join
--   46,547 cases took at least one payment; the other 74,166 report 0 and 0
--   898 cases have any pre-registration cash at all
--   EUR 1,924,553.93 pre-registration, EUR 152,845,574.72 on or after — so
--     the pre-registration slice is 1.24% of the total
-- The old route never produced these numbers: portugal_millenium.sql's CAT
-- columns were shipped unverified because the query would not finish.
--
-- ⚠ COST, EVEN AFTER ALL OF THAT. This still reads one whole extract of a
-- 24.7bn-row table with no date bound, on an X-Small warehouse other people
-- share. It is minutes, not seconds. Widen $country, $seller or
-- $source_system deliberately rather than by habit.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment. run_sql.py
-- sends the file through execute_string(), which splits on ';', and a
-- trailing comment-only chunk fails with "Empty SQL statement".
-- ============================================================================

set country       = 'PT';           -- matched with like; '%' for the whole feed
set seller        = 'MILLENNIUM';   -- matched case-insensitively with like
set source_system = '4050';         -- the Intrum instance these books live in
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set extract_ts    = '20260114T171703';  -- ⚠ a FULL extract; read the guard above
                                       --   'latest' resolves to a delta and
                                       --   returns almost nothing
set row_limit     = 200000;         -- ~120,700 cases in the default scope


-- ── scope: the batches, from PAM, one row each (Guards 1-3) ────────────────
with newest_pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'                             -- Guard 1
),

batches as (
    select distinct p.combined_ref                                       -- Guard 3
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    cross join newest_pam_file as nf
    where p._file_path = nf.file_path                                    -- Guard 1
      and p.pmode_name = 'Real'                                          -- Guard 2
      and coalesce(p.is_ownership_change, 0) = 0                         -- Guard 2
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)                       -- Guard 2
),

-- ── which extract to read: its <ts> segment, so every part file is kept ────
-- split_part on the max path is safe because <ts> is YYYYMMDDTHHMMSS, so
-- lexical order is chronological order.
case_extract as (
    select
        case
            when $extract_ts != 'latest' then $extract_ts
            else split_part(max(_file_path), '.', 4)
        end as extract_ts
    from RAW.HYPERION_INTRUM_CAT.CASES
    where _file_path like $raw_prefix || $source_system || '.cases.%'     -- Guard 6
),

tx_extract as (
    select
        case
            when $extract_ts != 'latest' then $extract_ts
            else split_part(max(_file_path), '.', 4)
        end as extract_ts
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS
    where _file_path like $raw_prefix || $source_system || '.transactions.%'
),                                                                       -- Guard 6

-- ── one row per case: its latest version (Guards 4-6) ──────────────────────
cases as (
    select
        c.long_portfolio_id            as portfolio_id,
        c.case_id,
        c.registration_date::date      as registration_date
        -- c.default_date is deliberately NOT read: it is NULL on 100% of this
        -- scope. DEFAULT_DATE comes from PROD below.
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.'
                           || (select extract_ts from case_extract) || '.%'
                                                                         -- Guards 4, 6
      and c.long_portfolio_id in (select combined_ref from batches)
      -- container cases: hyphenated ids are 1033 sub-cases, dropped for every
      -- system as int_npl_case_intrum does it; 2080 flags its own
      and c.case_id not like '%-%'
      and not ($source_system = '2080' and coalesce(c.real_case_ind, '') = '1')
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1                                                                -- Guard 5
),

-- ── the one PROD lookup: DEFAULT_DATE, which RAW does not populate ────────
-- PROD's key is CASE_BK = source_system_code || '-' || case_id, so the raw id
-- is prefixed to join. Restricting to this instance first keeps the scan off
-- the other 21m loans in the dimension.
prod_case as (
    select
        d.case_bk,
        d.default_date                 as default_date
    from PROD.NPL_COMMON.DIM_CASE as d
    where d.case_bk like $source_system || '-%'
      and d.is_current_flag
    -- DIM_CASE is SCD2. is_current_flag already yields exactly one row per
    -- CASE_BK for this instance (1,156,733 rows, 1,156,733 distinct keys,
    -- measured 2026-09-10), so this qualify is a no-op today — but a
    -- claimed-unique grain that turns out to fan out is a standing trap in
    -- this warehouse, and a silent 2x on a case is not worth the saving.
    qualify row_number() over (
        partition by d.case_bk
        order by d.effective_from_date desc nulls last
    ) = 1
),

-- ── one row per payment, sign corrected, junk dates bounded (Guard 7) ──────
-- The case list is applied here, BEFORE the dedupe window, so the window runs
-- over the cases in scope rather than over the whole instance.
payments as (
    select
        t.case_id,
        t.transaction_date::date       as transaction_date,
        -t.amount::decimal(38, 2)      as amount
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    where t._file_path like $raw_prefix || $source_system || '.transactions.'
                           || (select extract_ts from tx_extract) || '.%'
                                                                         -- Guards 4, 6
      and t.case_id in (select case_id from cases)
      and t.payment_cost_ind = 'P'                                       -- Guard 7
      and coalesce(t.booking_ind, 'N') != 'Y'                            -- Guard 7
      -- 1900-01-01 / 2099-12-30 sentinels: bounded, not bucketed
      and t.transaction_date::date between '1990-01-01' and current_date()
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1                                                                -- Guard 7
),

-- ── the split, at case grain ───────────────────────────────────────────────
collected as (
    select
        c.case_id,
        sum(case when p.transaction_date < c.registration_date
                 then p.amount else 0 end)  as collections_pre_registration,
        sum(case when p.transaction_date >= c.registration_date
                 then p.amount else 0 end)  as collections_on_or_after_registration
    from cases as c
    inner join payments as p
        on p.case_id = c.case_id
    where c.registration_date is not null
    group by c.case_id
)

select
    c.portfolio_id,                        -- PAM COMBINED_REF: the BATCH ref
    c.case_id,                             -- raw servicer id, not PROD's CASE_BK
    d.default_date,                        -- PROD, invoice-derived; RAW is empty
    c.registration_date,                   -- Intrum opened the case, not origination

    -- NULL, not 0, when there is no registration date to split on: the cash
    -- exists but cannot be placed on either side of it.
    case when c.registration_date is null then null
         else coalesce(x.collections_pre_registration, 0) end
                                           as collections_pre_registration,
    case when c.registration_date is null then null
         else coalesce(x.collections_on_or_after_registration, 0) end
                                           as collections_on_or_after_registration

from cases as c
-- LEFT JOIN: a case that never took a payment keeps its row and reports 0.
left join collected as x
    on x.case_id = c.case_id
-- LEFT JOIN: a case absent from PROD keeps its row with a NULL default date,
-- rather than being dropped from a RAW-scoped answer by a PROD gap.
left join prod_case as d
    on d.case_bk = $source_system || '-' || c.case_id
order by c.portfolio_id, c.case_id
limit $row_limit;
