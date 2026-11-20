-- Every Swedish deal we own: its cases, its seller tape, what we need from Intrum, and
-- whether its collections reconcile to PAM today and after the two dbt fixes.
-- GRAIN   one row per deal, keyed VEHICLE-ID: Heimdall deals by Intrum's id, every other
--         vehicle by our Atlas id (LOK-SE25008 is Intrum's SE25018).
-- RUN     mise run sql -- work/hackathon/queries/sweden_raw_cat.sql \
--             --connection dev --warehouse DEV_WH --lower \
--             --csv work/hackathon/.cache/sweden_raw_cat.csv
--         dev (brocc-sandbox, DEVELOPER) because NPL_ANALYST cannot read PROD_RAW; the
--         sandbox sees PROD under PROD_NPL_COMMON / PROD_RAW.
--
-- LIVE vs TYPED IN. Everything is queried live except the seller-tape columns and the
-- Intrum ask (tapes CTE): seller tapes live on a laptop, not in the warehouse. Those were
-- measured 2026-11-16 (NPL Hackathon 2026 deck, tapes slide) and are COUNTS ONLY, never a
-- seller value. Re-measure them when a tape is re-ingested.
--
-- THE THREE COLLECTION FIGURES, all post-acquisition, same deal, same window:
--   PAM    Intrum's own batch report, the reference.
--   DBT    FCT_CASE_COLLECTION as it ships today, with both defects.
--   FIXED  raw CAT with both defects removed, which is what dbt returns once fixed.
-- The two defects each live on one Swedish instance, so the instance names the bug:
--   BUG 1  COALESCE(booking_ind, 'N') <> 'Y'. On 1062 every payment row carrying an amount
--          is 'Y', so the guard deletes that instance's cash.
--   BUG 2  dedupe on CONCAT(orig_tr_id, pkey). On 2080 one payment arrives under many ids
--          (case 2080-1212023: 14 rows of exactly 570.00 on 2016-01-27), so it counts many
--          times. On 2080 booking_ind is null throughout, so bug 1 is inert there.
--   Measured on six books in ../data-issues/intrum/queries/dbt_vs_ours_vs_pam.sql, which
--   isolates each bug separately; this query names the bug by instance instead, to read the
--   raw payment history once rather than three times.
--
-- RECONCILES is the Data Landscape workbook's test, so the two agree on which deals pass:
--   CAT collects in at least 80% of the months PAM collects in, AND
--   CAT's cash lands within +/-10% of PAM's.
-- A collecting month is one whose collections sum above zero, after acquisition.
--
-- ⚠ FCT_CASE_COLLECTION holds rows dated after today, out to the year 4570 (841 rows,
--   measured 2026-11-04); every source is bounded at today so they cannot count a month.
-- ⚠ 35% of raw payment rows have no transaction_date and drop out of FIXED: an undated
--   payment cannot be placed after acquisition. PAM is unaffected.
-- ⚠ The acquisition boundary is month-grain: LEGACY_CAPEX_DATE falls on the 1st for 99.49%
--   of batches. A deal bought mid-month gains or loses up to a month at the edge.
-- ⚠ A pre-2020 deal can fail even when FIXED is right: on SE15044 and SE16025 CAT holds
--   more 2016-2019 cash than PAM reports, which is Intrum's reporting, not ours
--   (work/data-issues/intrum/pam-pre-2020-swedish-books.md). The reason column says
--   "likely" for other pre-2020 deals because only those two were measured.

SET tolerance  = 0.10;  -- cash: within 10% of PAM
SET min_months = 0.80;  -- months: CAT collects in at least 80% of PAM's collecting months
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH
    batch AS (

        SELECT
            b.batch_sk,
            b.servicer_parent_portfolio_bk AS intrum_id,
            -- ORG batches carry no deal source of their own; the Atlas key starts with it.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle,
            SUBSTR(p.portfolio_bk, 5, 7) AS atlas_id,
            b.legacy_capex_date
        FROM prod_npl_common.npl_common.dim_batch AS b
        LEFT JOIN prod_npl_common.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
),

-- Heimdall's Atlas portfolio is a whole country's umbrella (HEI-SE25001 holds every Swedish
-- Heimdall deal), so only Intrum's id names a Heimdall deal.
    deal AS (

        SELECT
            vehicle || '-' || IFF(vehicle = 'HEI', intrum_id, atlas_id) AS deal_key,
            IFF(vehicle = 'HEI', intrum_id, atlas_id) AS our_id,
            intrum_id,
            MIN(legacy_capex_date)::date AS acquisition_date
        FROM batch
        WHERE LEFT(IFF(vehicle = 'HEI', intrum_id, atlas_id), 2) = 'SE'
            AND intrum_id IS NOT NULL
        GROUP BY 1, 2, 3
),

-- Typed in, 2026-11-16. matched_cases is how many CAT cases the tape's id column reaches;
-- the share is computed below against today's CAT case count, across BOTH instances.
    tapes (our_id, seller_tape, matched_cases, bridge_note, intrum_ask) AS (

        SELECT * FROM VALUES
            ('SE17039', 'SevenDay asset index', 1572, 'Aktnr = case_id; never run', NULL),
            ('SE25014', 'Moank forward-flow', 64,
                'via Intrum''s case-mapping file, not the tape; never run', NULL),
            ('SE25008', 'Project Emmy A + B', 6267,
                'Case ID (client); last run stored synthetic ids',
                'Mapping rows for batch SE25018D010000 (3,446 cases), and why CAT holds 152% of the principal PAM says we bought'),
            ('SE20009', 'Project Turing A + B', 0,
                'no column joins; every CAT reference column is empty',
                'The case ids behind the tape'),
            ('SE19026', 'Ikano Bilaga', 8312,
                'tape id joins; approved run built from our CAT extract, not the tape', NULL),
            ('SE25013', 'Norion OffShore', 1582,
                'invoice_number, rejected as weak: undecided; 3 files DRM-protected; approved run built from our CAT extract',
                NULL),
            ('SE15044', NULL, NULL, NULL, 'A seller tape: none exists anywhere we can see'),
            ('SE16025', NULL, NULL, NULL, 'A seller tape: none exists anywhere we can see')
),

    pam_collections AS (

        SELECT
            intrum_id,
            SUM(collected) AS pam,
            COUNT_IF(collected > 0) AS pam_months
        FROM (
            SELECT
                d.intrum_id,
                DATE_TRUNC('month', p.period_start_date::date) AS month,
                SUM(p.colltotal) AS collected
            FROM prod_raw.hyperion_intrum_pam.pam AS p
            INNER JOIN deal AS d
                ON d.intrum_id = p.portfolioid
            -- The newest whole file: each PAM file restates every month.
            WHERE p._file_path = (
                    SELECT MAX(_file_path)
                    FROM prod_raw.hyperion_intrum_pam.pam
                    WHERE _file_path LIKE '%/pam.pam.pam.2%'
                )
                AND p.pmode_name = 'Real'
                -- Forecast rows share the file; ownership-change rows restate a book's past.
                AND COALESCE(p.is_ownership_change, 0) = 0
                AND p.period_start_date::date >= d.acquisition_date
                AND p.period_start_date::date <= CURRENT_DATE
            GROUP BY 1, 2
        )
        GROUP BY 1
),

    dbt_collections AS (

        SELECT
            intrum_id,
            SUM(collected) AS dbt,
            COUNT_IF(collected > 0) AS dbt_months
        FROM (
            SELECT
                d.intrum_id,
                DATE_TRUNC('month', f.collection_date) AS month,
                SUM(f.amount) AS collected
            FROM prod_npl_common.npl_common.fct_case_collection AS f
            INNER JOIN batch AS b
                ON b.batch_sk = f.batch_sk
            INNER JOIN deal AS d
                ON d.intrum_id = b.intrum_id
            WHERE f.collection_date >= d.acquisition_date
                AND f.collection_date <= CURRENT_DATE  -- rows run out to the year 4570
            GROUP BY 1, 2
        )
        GROUP BY 1
),

-- One row per case. DISTINCT rather than ranking every version: CAT resends each case
-- about 147 times, and only the id and its deal are needed here. A case id is unique only
-- within an instance, so the instance is part of the key. Hyphenated ids and
-- real_case_ind = '1' are Intrum's grouping rows, not loans.
    cat_case AS (

        SELECT DISTINCT
            LEFT(c.long_portfolio_id, 7) AS intrum_id,
            PARSE_JSON(c._file_metadata):system::string AS source_system,
            c.case_id
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        -- The file-path prefix is the only thing that prunes this change-history table.
        WHERE (c._file_path LIKE $raw_prefix || '1062.cases.%'
                OR c._file_path LIKE $raw_prefix || '2080.cases.%')
            AND LEFT(c.long_portfolio_id, 7) IN (SELECT intrum_id FROM deal)
            AND c.case_id NOT LIKE '%-%'
            AND COALESCE(c.real_case_ind, '') <> '1'
),

    cat_cases AS (

        SELECT
            intrum_id,
            COUNT(*) AS cat_cases,
            COUNT_IF(source_system = '1062') AS cases_on_1062,
            COUNT_IF(source_system = '2080') AS cases_on_2080
        FROM cat_case
        GROUP BY 1
),

-- FIXED, in one pass over the payment history. One payment = one case, date, amount type
-- and amount; amount is in the key, so GROUP BY keeps exactly one row per payment, as our
-- reconciled exports do. No booking_ind guard.
    payment AS (

        SELECT
            c.intrum_id,
            t.transaction_date::date AS payment_date,
            -t.amount::decimal(38, 2) AS amount  -- raw CAT signs payments negative
        FROM prod_raw.hyperion_intrum_cat.transactions AS t
        INNER JOIN cat_case AS c
            ON c.case_id = t.case_id
            AND c.source_system = PARSE_JSON(t._file_metadata):system::string
        WHERE (t._file_path LIKE $raw_prefix || '1062.transactions.%'
                OR t._file_path LIKE $raw_prefix || '2080.transactions.%')
            AND t.payment_cost_ind = 'P'
            AND t.amount IS NOT NULL
            -- Cut before the join: nothing earlier than the first Swedish purchase counts.
            AND t.transaction_date::date >= (SELECT MIN(acquisition_date) FROM deal)
            AND t.transaction_date::date <= CURRENT_DATE
        GROUP BY c.intrum_id, c.source_system, t.case_id, t.transaction_date::date,
            t.amount_type_code, t.amount
),

    fixed AS (

        SELECT
            intrum_id,
            SUM(collected) AS fixed,
            COUNT_IF(collected > 0) AS fixed_months
        FROM (
            SELECT
                p.intrum_id,
                DATE_TRUNC('month', p.payment_date) AS month,
                SUM(p.amount) AS collected
            FROM payment AS p
            INNER JOIN deal AS d
                ON d.intrum_id = p.intrum_id
            WHERE p.payment_date >= d.acquisition_date
            GROUP BY 1, 2
        )
        GROUP BY 1
),

    measured AS (

        SELECT
            d.deal_key,
            d.our_id,
            d.intrum_id,
            d.acquisition_date,
            c.cat_cases,
            c.cases_on_1062,
            c.cases_on_2080,
            t.seller_tape,
            t.matched_cases,
            t.bridge_note,
            t.intrum_ask,
            p.pam,
            b.dbt,
            f.fixed,
            p.pam_months,
            b.dbt_months,
            f.fixed_months,
            b.dbt / NULLIF(p.pam, 0) AS dbt_vs_pam,
            f.fixed / NULLIF(p.pam, 0) AS fixed_vs_pam,
            b.dbt_months / NULLIF(p.pam_months, 0) AS dbt_months_share,
            f.fixed_months / NULLIF(p.pam_months, 0) AS fixed_months_share,
            -- How far the shipped model sits from the fixed one: 1 means the bugs cost
            -- this deal nothing.
            b.dbt / NULLIF(f.fixed, 0) AS dbt_vs_fixed
        FROM deal AS d
        LEFT JOIN tapes AS t
            ON t.our_id = d.our_id
        LEFT JOIN cat_cases AS c
            ON c.intrum_id = d.intrum_id
        LEFT JOIN pam_collections AS p
            ON p.intrum_id = d.intrum_id
        LEFT JOIN dbt_collections AS b
            ON b.intrum_id = d.intrum_id
        LEFT JOIN fixed AS f
            ON f.intrum_id = d.intrum_id
),

-- The two-part test, once per figure, so the reason below reads it rather than repeating it.
    tested AS (

        SELECT
            *,
            COALESCE(ABS(dbt_vs_pam - 1) <= $tolerance
                AND dbt_months_share >= $min_months, FALSE) AS dbt_passes,
            COALESCE(ABS(fixed_vs_pam - 1) <= $tolerance
                AND fixed_months_share >= $min_months, FALSE) AS fixed_passes,
            COALESCE(ABS(dbt_vs_fixed - 1) > 0.01, FALSE) AS bugs_bite,
            CASE
                WHEN cases_on_1062 > 0 AND cases_on_2080 > 0 THEN 'bugs 1 and 2'
                WHEN cases_on_1062 > 0 THEN 'bug 1 (booking_ind guard drops 1062 cash)'
                WHEN cases_on_2080 > 0 THEN 'bug 2 (orig_tr_id key double-counts 2080)'
            END AS which_bug
        FROM measured
)

SELECT
    deal_key,
    our_id AS atlas_or_heimdall_id,
    intrum_id,
    acquisition_date,
    cat_cases,
    cases_on_1062,
    cases_on_2080,
    seller_tape IS NOT NULL AS has_seller_tape,
    seller_tape,
    matched_cases AS tape_bridged_cases,
    ROUND(matched_cases / NULLIF(cat_cases, 0), 5) AS tape_bridged_share,
    bridge_note,
    intrum_ask IS NOT NULL AS needs_intrum_request,
    intrum_ask,
    ROUND(pam, 2) AS pam_collections,
    pam_months,
    ROUND(dbt, 2) AS dbt_collections,
    dbt_months,
    ROUND(dbt_vs_pam, 5) AS dbt_vs_pam,
    ROUND(dbt_months_share, 5) AS dbt_months_share,
    dbt_passes AS pam_cat_reconciles_today,
    CASE
        WHEN pam IS NULL THEN 'No PAM rows after acquisition'
        WHEN cat_cases IS NULL THEN 'No cases in CAT'
        -- The two bugs push cash in opposite directions, so a deal can pass by accident.
        WHEN dbt_passes AND bugs_bite THEN 'Reconciles by accident: ' || which_bug || ' cancel out'
        WHEN dbt_passes THEN 'Reconciles'
        WHEN fixed_passes THEN 'Our dbt ' || COALESCE(which_bug, 'model')
        -- From here even the fixed figure fails, so the cause is not either bug.
        WHEN ABS(fixed_vs_pam - 1) <= $tolerance
            THEN 'Not our bugs: cash agrees but CAT collects in under 80% of PAM''s months'
        WHEN our_id IN ('SE15044', 'SE16025')
            THEN 'Not our bugs: CAT holds more pre-2020 cash than PAM reports'
        WHEN acquisition_date < '2020-01-01'
            THEN 'Not our bugs: likely Intrum''s pre-2020 PAM reporting (unmeasured)'
        ELSE 'Not our bugs: unexplained'
    END AS pam_cat_reason,
    ROUND(fixed, 2) AS fixed_collections,
    fixed_months,
    ROUND(fixed_vs_pam, 5) AS fixed_vs_pam,
    ROUND(fixed_months_share, 5) AS fixed_months_share,
    fixed_passes AS reconciles_after_bug_fixes,
    ROUND(dbt_vs_fixed, 5) AS dbt_vs_fixed
FROM tested
ORDER BY has_seller_tape DESC, needs_intrum_request DESC, cat_cases DESC NULLS LAST
