-- ============================================================================
-- GIVEN A BORROWER ID FROM THE SELLER TAPE, FIND ITS CASE IN CAT
--
-- One row per (borrower_id, case_id). Type your ids into BORROWERS below and
-- run. Nothing else to edit.
--
-- Worked on Millennium PT06002, where the tape's "ID A" is the borrower and
-- "ID B" the loan. Measured 2026-10-23: 1,473 of 1,487 tape borrowers resolve
-- to a case (99.1%), with ZERO cross-borrower collisions across 2,248 loan ids.
-- ============================================================================
--
-- WHY client_ref_1 AND NOT A MODEL
--   PT06002 is NOT in PROD: 0 of its 11,141 CAT cases appear in DIM_CASE, and
--   DIM_BORROWER is no help either -- its CASE_ID is a 32-char hash, and VAT
--   (the NIF) is 0% filled on all 931,266 Portuguese rows. Raw CAT is the only
--   route for this deal.
--
-- WHY EVERY VERSION IS READ, NOT JUST THE LATEST
--   CASES is a change-history feed and client_ref_1 CHANGES: a case carries one
--   reference early and another later. Deduping to the latest version first
--   drops the borrower match from 99.1% to 18.0%.
--   ⚠ THIS APPLIES TO ID MATCHING ONLY. For any BALANCE or amount, dedupe to
--   the latest version per case (the C1 guard in the benchmark templates) --
--   reading a figure off a historical row gives a superseded number.
--
-- WHAT YOU GET BACK
--   The case id, plus the OTHER reference that case carries. On PT06002 that
--   other reference is the borrower's own loan id 66% of the time and their own
--   sub-account id 8% of the time; the rest are loans absent from our tape.
--   It is NEVER another borrower's id -- measured 0 of 1,473.
--
-- ONE CASE = ONE BORROWER on this deal (11,141 cases, 11,141 borrowers), so
--   there is no borrower-vs-case choice to make. Collections hang off case_id
--   and carry NO loan key, so nothing here reaches loan level.
--
-- ⚠ COLLECTED IS NOT A RECOVERY RATE AND DOES NOT RECONCILE HERE.
--   Measured on borrower 639: the tape's loans sum to 7,880.60 and CAT's
--   ORIGINAL_CAPITAL is 7,880.60 -- an exact match, which validates the bridge.
--   But collections across all amount types come to 15,963, about 2x that, and
--   on borrower 360 it is 3.9x. Splitting by AMOUNT_TYPE_CODE does not close it
--   either. Whether that is interest and costs on a long-running case, or a
--   dedupe artefact from the NULL ORIG_TR_ID partitions, is NOT SETTLED.
--   For a figure you can defend, use 02_payments.sql in the benchmark
--   templates and its roll-forward check, not this column.
--
-- ⚠ Container cases (a hyphen in CASE_ID) are dropped, as dbt does.
-- ============================================================================

SET portfolio = 'PT06002B000000';   -- CAT long_portfolio_id for the deal

WITH borrowers AS (
    SELECT column1 AS borrower_id
    FROM VALUES
        ('360'),
        ('639')
        -- add more here, one per line
),

-- Every version is kept on purpose; see the note above.
refs AS (
    SELECT DISTINCT
        TRIM(client_ref_1) AS client_ref,
        case_id
    FROM prod_raw.hyperion_intrum_cat.cases
    WHERE long_portfolio_id = $portfolio
        AND client_ref_1 IS NOT NULL
        AND case_id NOT LIKE '%-%'
),

-- The case each borrower sits on.
hits AS (
    SELECT
        b.borrower_id,
        r.case_id
    FROM borrowers AS b
    INNER JOIN refs AS r
        ON r.client_ref = b.borrower_id
),

-- The other reference on that same case: the borrower's loan or sub-account id.
other_ref AS (
    SELECT
        h.borrower_id,
        h.case_id,
        LISTAGG(DISTINCT r.client_ref, ', ') WITHIN GROUP (ORDER BY r.client_ref)
            AS other_references
    FROM hits AS h
    INNER JOIN refs AS r
        ON r.case_id = h.case_id
        AND r.client_ref <> h.borrower_id
    GROUP BY h.borrower_id, h.case_id
),

-- Balances come from the LATEST version only -- the C1 guard.
latest_case AS (
    SELECT
        case_id,
        main_status_code,
        remaining_capital,
        original_capital
    FROM (
        SELECT
            case_id,
            main_status_code,
            remaining_capital,
            original_capital,
            ROW_NUMBER() OVER (
                PARTITION BY case_id ORDER BY update_ts DESC, cat_seq DESC
            ) AS rn
        FROM prod_raw.hyperion_intrum_cat.cases
        WHERE long_portfolio_id = $portfolio
            AND case_id NOT LIKE '%-%'
    )
    WHERE rn = 1
),

-- Collections hang off the case. No loan key exists on a transaction.
-- Guards lifted verbatim from 02_payments.sql in the benchmark templates --
-- do NOT sum this table without them:
--   C2  change-history feed (10.8x). Dedupe on
--       (case_id, orig_tr_id || coalesce(pkey,'')), latest record_update wins.
--       ⚠ CONCAT returns NULL if any part is NULL, so rows with a null
--       orig_tr_id collapse into one partition. That is the team's own key and
--       its own weakness, kept so figures agree with PROD. On PT06002,
--       orig_tr_id is NULL on 350 of 1,181 rows for one sampled case.
--   C6  payments only: payment_cost_ind = 'P' and booking_ind <> 'Y'
--   C7  AMOUNT IS STORED SIGN-FLIPPED -- a collection arrives NEGATIVE, so it
--       is negated here to read as a positive collection.
collections AS (
    SELECT
        t.case_id,
        COUNT(*) AS payments,
        -- ⚠ AMOUNT_TYPE_CODE splits a collection into components. Summing them
        -- together gives a figure LARGER than original capital and is NOT a
        -- recovery rate. Kept apart so the denominator is a choice, not an
        -- accident. Codes seen on PT06002: 1, 20, 4.
        ROUND(SUM(-t.amount), 5) AS collected_all_types,
        ROUND(SUM(CASE WHEN t.amount_type_code = '1' THEN -t.amount ELSE 0 END), 5) AS collected_type_1,
        ROUND(SUM(CASE WHEN t.amount_type_code = '20' THEN -t.amount ELSE 0 END), 5) AS collected_type_20,
        ROUND(SUM(CASE WHEN t.amount_type_code = '4' THEN -t.amount ELSE 0 END), 5) AS collected_type_4,
        MIN(t.transaction_date) AS first_payment,
        MAX(t.transaction_date) AS last_payment,
        SUM(CASE WHEN t.transaction_date IS NULL THEN 1 ELSE 0 END) AS undated_payments
    FROM (
        SELECT
            x.*,
            ROW_NUMBER() OVER (
                PARTITION BY x.case_id, x.orig_tr_id || COALESCE(x.pkey, '')
                ORDER BY x.record_update DESC
            ) AS rn
        FROM prod_raw.hyperion_intrum_cat.transactions AS x
        INNER JOIN hits AS h2 ON h2.case_id = x.case_id
        WHERE x.payment_cost_ind = 'P'
            AND COALESCE(x.booking_ind, '') <> 'Y'
            AND x.amount IS NOT NULL
    ) AS t
    WHERE t.rn = 1
    GROUP BY t.case_id
)

SELECT
    b.borrower_id,
    h.case_id,
    o.other_references,                        -- the loan / sub-account id
    lc.main_status_code AS status_code,
    ROUND(lc.original_capital, 5) AS original_capital,
    ROUND(lc.remaining_capital, 5) AS remaining_capital,
    c.payments,
    c.undated_payments,
    c.collected_all_types,
    c.collected_type_1,
    c.collected_type_20,
    c.collected_type_4,
    c.first_payment,
    c.last_payment,
    CASE WHEN h.case_id IS NULL THEN 'NOT FOUND' ELSE 'FOUND' END AS verdict
FROM borrowers AS b
LEFT JOIN hits AS h ON h.borrower_id = b.borrower_id
LEFT JOIN other_ref AS o ON o.case_id = h.case_id AND o.borrower_id = b.borrower_id
LEFT JOIN latest_case AS lc ON lc.case_id = h.case_id
LEFT JOIN collections AS c ON c.case_id = h.case_id
ORDER BY verdict, b.borrower_id;
