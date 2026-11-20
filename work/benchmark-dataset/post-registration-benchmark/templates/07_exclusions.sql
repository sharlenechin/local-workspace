-- ============================================================================
-- 07_exclusions — step 8 of METHOD.md. What the scope filters removed, and why.
--
--   RUN     mise run sql -- work/benchmark-dataset/post-registration-benchmark/templates/07_exclusions.sql
--           datalake.q("benchmark/templates/07_exclusions", convert=False)
--   GRAIN   one row per (seller, reason). Rows SUM BACK to the starting
--           population — that is the whole design.
--   RUNTIME ~2 min — one pass over CASES for the loan counts.
--   PAIRS   03_reconcile_cat_pam.sql — that is the per-batch detail and it is
--           AUTHORITATIVE; this is its rollup and must agree with it.
--   WORKED  ../../../work/project-sea-benchmark/exclusions.sql (11 rows, five
--           sellers, 167 batches, 2026-10-01)
--
-- ⚠⚠ WHY THIS STEP EXISTS. A READER CANNOT SEE WHAT IS MISSING FROM A CSV.
-- Every scope filter removes real batches carrying real money, and once the
-- file is exported there is nothing in it that says so. A recipient opens
-- accounts.csv, sees a seller they recognise, and reasonably assumes it is that
-- seller's whole book. On Project Sea that assumption would have been wrong by
-- 141 batches and 44,809 loans. This table is the only place that is visible.
-- IT IS PART OF THE DELIVERABLE, NOT A DIAGNOSTIC — ship it with the data.
--
-- ⚠⚠ THE POPULATION IS DELIBERATELY UNFILTERED, and that inverts how every
-- other file here works. The benchmark queries APPLY the filters; this one
-- applies them as LABELS instead, so nothing can leave the table without
-- saying why. Each batch is assigned the FIRST reason that excludes it, so it
-- is counted exactly once and the rows reconcile to the starting population.
--
-- ⚠⚠ THIS IS A ROLLUP, NOT A SECOND OPINION. If it ever disagrees with the
-- batch ledger, THE LEDGER IS RIGHT AND THIS IS STALE. Assert the tie before
-- shipping: batches in + out = total, and the in-scope loan count must equal
-- the row count of accounts.csv. On Project Sea, 2026-10-01:
--     167 batches = 141 excluded + 26 in scope
--     217,104 loans in scope = accounts.csv row count, exactly
--
-- ⚠⚠ THE ZERO ROWS ARE THE POINT, NOT PADDING. A filter that was checked and
-- caught nothing is information: it tells the reader the question was asked.
-- COUNT THEM FROM THE DATA, NEVER HARD-CODE A ZERO — a future delivery that
-- does trip one must appear here rather than silently contradict a literal.
-- A group with no rows simply vanishes from a GROUP BY, which is why they are
-- UNION-ed in explicitly.
--
-- ⚠ COLLECTIONS_EUR IS PAM'S NUMBER, NOT THE LOAN-LEVEL TOTAL. It is lifetime
-- actuals to PAM's newest month; the payments deliverable stops at the CAT
-- extract date, which is typically months earlier. On Project Sea the gap was
-- 282,841,324.30 here against 276,731,289.53 in payments.csv. State it in the
-- header of whatever you ship, or the two will be read as the same quantity.
--
-- ============================================================================
-- HOW TO READ THE THREE KINDS OF ROW
-- ============================================================================
-- · IN SCOPE  — what the benchmark kept. Must equal accounts.sql.
-- · EXCLUDED  — real batches, real money, removed by a named filter.
-- · CHECKED / NOT APPLIED — a filter that removed NOTHING. Zero rows, on
--   purpose. Reported against all sellers rather than per seller, because
--   there is no batch behind them to attribute.
--
-- ============================================================================
-- GUARDS — the same ones 01_accounts.sql uses, so the populations agree
-- ============================================================================
-- X1 P1 newest WHOLE PAM delivery ('pam.pam.pam.2'); a plain max() lands on a
--    mis-loaded pam_perimeter file.
-- X2 ⚠ THE BATCH POPULATION IS UNFILTERED — no deal type, no portfolio type,
--    no ownership-change test. See above: the filters are labels here.
-- X3 THE MONEY MEASURE IS FILTERED, THOUGH, and identically to the ledger:
--    PMODE_NAME='Real' (P2), no ownership-change rows (P3), and actual months
--    only (P4 — PAM's plan horizon runs years past the last actual, so an
--    unbounded sum silently includes forecast). Without X3 this cannot tie.
-- X4 ⚠ THE SELLER MATCH IS EXACT NAMES, NOT A SUBSTRING OR REGEX. On Portugal
--    'GE MONEY BANK' CONTAINS 'ONEY', so a LIKE or an alternation pulls an
--    extra seller into the denominator and every share below is wrong. The
--    REPLACE(', ' -> ',') stays because one stray space makes SPLIT yield
--    ' BARCLAYCARD', which never matches and drops a whole seller with no error.
-- X5 CAT loan counts carry C1 (change-history dedupe), C8 (batch filter before
--    the qualify), C4/C5 (instance as a literal prefix, every extract) and C9
--    (container cases dropped), so they equal the ledger's loan counts.
--
-- ⚠ ADAPTING THIS TO A NEW BOOK: the CASE arms below are the filters THIS
-- method applies. If your book applies another one, it needs an arm here too —
-- an exclusion with no row is exactly the failure this file exists to prevent.
-- ⚠ Nothing may follow the final semicolon: run_sql.py splits on ';'.
-- ============================================================================

SET country         = 'PT';
SET seller_list     = 'MILLENNIUM';          -- exact names, comma separated. See X4
SET deal_type       = 'One-off';             -- the type KEPT; everything else is labelled out
SET source_system   = '4050';                -- from 00_scope.sql block B
SET raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
SET exclude_batches = '';                    -- comma-separated refs; '' keeps all
SET all_label       = 'ALL SELLERS IN SCOPE';  -- label for rows with no batch behind them


-- Everything PAM names for the scope, with NO benchmark filter applied (X2).
WITH all_batches AS (
    SELECT
        UPPER(p.combined_ref)                   AS batch_ref,
        MAX(TRIM(UPPER(p.seller_name)))         AS seller,
        MAX(p.deal_type_desc)                   AS deal_type,
        MAX(p.portfoliotype)                    AS portfolio_type,
        MAX(COALESCE(p.is_ownership_change, 0)) AS any_ownership_change,
        -- X3: the measure is filtered even though the population is not.
        SUM(IFF(p.pmode_name = 'Real'
                AND COALESCE(p.is_ownership_change, 0) = 0
                AND p.period_start_date::DATE < DATE_TRUNC('MONTH', TO_TIMESTAMP_NTZ(
                        PARSE_JSON(p._file_metadata):extract_ts::STRING,
                        'YYYYMMDDTHH24MISS'))::DATE,
                p.colltotal, 0))                AS collections
    FROM RAW.HYPERION_INTRUM_PAM.PAM AS p
    CROSS JOIN (
        SELECT MAX(_file_path) AS file_path
        FROM RAW.HYPERION_INTRUM_PAM.PAM
        WHERE _file_path LIKE '%/pam.pam.pam.2%'                          -- X1
    ) AS nf
    WHERE p._file_path = nf.file_path                                     -- X1
      AND p.countrycode LIKE $country
      AND ARRAY_CONTAINS(TRIM(UPPER(p.seller_name))::VARIANT,
                         SPLIT(REPLACE($seller_list, ', ', ','), ','))    -- X4
    GROUP BY 1
),

-- Loans behind each batch, so an exclusion can be sized in loans and not only
-- in euros. "141 batches" is abstract; "44,809 loans" is not. Guards per X5.
loans_per_batch AS (
    SELECT
        batch_ref,
        COUNT(*) AS loans
    FROM (
        SELECT UPPER(c.long_portfolio_id) AS batch_ref
        FROM RAW.HYPERION_INTRUM_CAT.CASES AS c
        WHERE c._file_path LIKE $raw_prefix || $source_system || '.cases.%'
          AND UPPER(c.long_portfolio_id) IN (SELECT batch_ref FROM all_batches)
          AND c.case_id NOT LIKE '%-%'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY c.case_id
            ORDER BY COALESCE(c.record_updated, c.update_ts)::TIMESTAMP DESC NULLS LAST
        ) = 1
    )
    GROUP BY batch_ref
),

-- ⚠ FIRST REASON WINS, so a batch is counted exactly once and the rows
-- reconcile back to the starting population. Order the arms most-structural
-- first: a performing forward-flow batch should read as forward flow only if
-- that is the reason you want reported. Changing the order changes the answer.
classified AS (
    SELECT
        b.seller,
        b.batch_ref,
        b.collections,
        COALESCE(l.loans, 0) AS loans,
        CASE
            WHEN b.any_ownership_change = 1
                THEN 'EXCLUDED · ownership-change rows restate a batch for a legal-buyer '
                     || 'transfer, so keeping them would report the same batch twice'
            WHEN b.deal_type <> $deal_type
                THEN 'EXCLUDED · forward flow (DEAL_TYPE_DESC = ' || b.deal_type
                     || ') — newly defaulted accounts arrive every month, so the population '
                     || 'is not fixed, capex is not a single event, and the batch cannot '
                     || 'carry a vintage or a stable denominator'
            WHEN b.portfolio_type <> 'Non-Performing'
                THEN 'EXCLUDED · performing book (PORTFOLIOTYPE = ' || b.portfolio_type
                     || ') — a different asset, not comparable with a non-performing purchase'
            WHEN $exclude_batches <> ''
                 AND ARRAY_CONTAINS(b.batch_ref::VARIANT,
                                    SPLIT(REPLACE($exclude_batches, ', ', ','), ','))
                THEN 'EXCLUDED · named in $exclude_batches, a pricing decision rather than '
                     || 'a measurement — see the README'
            ELSE 'IN SCOPE · one-off non-performing purchase — this is the benchmark'
        END AS reason
    FROM all_batches AS b
    LEFT JOIN loans_per_batch AS l
        ON l.batch_ref = b.batch_ref
),

-- Filters checked that caught nothing. COUNTED FROM THE DATA (see header), so a
-- future delivery that DOES trip one appears here instead of contradicting a
-- hard-coded zero.
nothing_removed AS (
    SELECT
        $all_label                                  AS seller,
        'CHECKED, REMOVED NOTHING · ownership-change rows (IS_OWNERSHIP_CHANGE = 1): '
            || 'none present in this scope'         AS reason,
        COUNT_IF(any_ownership_change = 1)          AS batches,
        0                                           AS loans,
        0                                           AS collections_eur
    FROM all_batches

    UNION ALL

    SELECT
        $all_label,
        'CHECKED, REMOVED NOTHING · performing portfolios (PORTFOLIOTYPE <> '
            || '''Non-Performing''): every batch in this scope is non-performing',
        COUNT_IF(portfolio_type <> 'Non-Performing'),
        0,
        0
    FROM all_batches

    UNION ALL

    SELECT
        $all_label,
        'CHECKED, REMOVED NOTHING · $exclude_batches ships EMPTY unless the book has a '
            || 'stated reason to drop a batch. A named exclusion is a pricing decision, '
            || 'not a measurement, so it belongs in the README as well as here',
        COUNT_IF($exclude_batches <> ''
                 AND ARRAY_CONTAINS(batch_ref::VARIANT,
                                    SPLIT(REPLACE($exclude_batches, ', ', ','), ','))),
        0,
        0
    FROM all_batches

    UNION ALL

    -- ⚠ NO PREDICATE EXISTS FOR THIS ONE, which is exactly why it is stated. A
    -- gate the method offers and this book declined is invisible everywhere
    -- else. Replace the count with a real measurement if your book applies it.
    SELECT
        $all_label,
        'NOT APPLIED · debtor-type gate. 01_accounts.sql drops loans with no identifiable '
            || 'debtor as unpriceable. Not carried: the borrower flag carries NULL on those '
            || 'loans instead, which states the same fact without removing a loan and keeps '
            || 'accounts and payments pairing exactly',
        0,
        0,
        0
)

SELECT
    seller,
    reason,
    batches,
    loans,
    collections_eur,
    batch_refs
FROM (
    SELECT
        seller,
        reason,
        COUNT(*)                            AS batches,
        SUM(loans)                          AS loans,
        SUM(collections)                    AS collections_eur,
        -- The refs themselves, so a reader can go straight to the ledger for
        -- any row without writing a query of their own.
        LISTAGG(batch_ref, ', ')
            WITHIN GROUP (ORDER BY batch_ref) AS batch_refs
    FROM classified
    GROUP BY seller, reason

    UNION ALL

    SELECT seller, reason, batches, loans, collections_eur, NULL
    FROM nothing_removed
)
-- IN SCOPE first, then the real exclusions by size, then the zero rows last:
-- a reader should meet what they HAVE before what they do not.
ORDER BY
    CASE
        WHEN reason LIKE 'IN SCOPE%'  THEN 1
        WHEN reason LIKE 'EXCLUDED%'  THEN 2
        ELSE 3
    END,
    batches DESC,
    seller;
