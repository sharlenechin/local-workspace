-- ============================================================================
-- PROJECT SEA · exclusions — what the scope filters removed, and why.
-- Portugal, instance 4050, FIVE sellers:
--   WIZINK BANK · BARCLAYCARD · MILLENNIUM · ONEY · COFIDIS
--
--   RUN     mise run sql -- work/project-sea-benchmark/exclusions.sql \
--             --csv work/project-sea-benchmark/project_sea_exclusions.csv
--   GRAIN   one row per (seller, reason). 11 rows, measured 2026-10-01.
--   RUNTIME ~2 min — one pass over CASES for the loan counts.
--
-- ⚠⚠ THE USER CANNOT SEE WHAT IS MISSING FROM A DATASET. Every scope filter
-- removes real batches carrying real money; this table is the only place that
-- is visible. It is part of the deliverable, not a diagnostic.
--
-- The population here is EVERY batch PAM names for this country and these five
-- sellers, before any benchmark filter — 167 batches on 2026-10-01. Each is
-- then assigned the FIRST reason that excludes it, so the rows sum back to the
-- full starting population and a reader can see where all 167 went.
--
-- ⚠⚠ THIS IS A ROLLUP, NOT A SECOND OPINION. project_sea_batch_ledger.csv
-- (reconciliation.sql) is the per-batch detail and it is AUTHORITATIVE; this
-- file is its summary and must agree with it, batch for batch and euro for
-- euro. If the two ever disagree, the ledger is right and this is stale. The
-- tie, measured 2026-10-01:
--     167 batches total   =  141 forward flow excluded  +  26 in scope
--     collections         =   66,825,631.20 excluded    +  282,841,324.30 in scope
--     loans in CAT        =       44,809 excluded       +     217,104 in scope
-- ⚠ COLLECTIONS_EUR IS PAM'S NUMBER, NOT OURS — lifetime actuals to 2026-08,
-- the same measure as the ledger's PAM_COLLECTIONS_LIFETIME. The loan-level
-- total in project_sea_benchmark_payments.csv is 276,731,289.53 against the
-- 282,841,324.30 in scope here, because the CAT extract stops seven months
-- earlier. Do not read the two as the same quantity.
--
-- ============================================================================
-- HOW TO READ THE THREE KINDS OF ROW
-- ============================================================================
-- · IN SCOPE  — what the benchmark kept. Should equal accounts.sql.
-- · EXCLUDED  — real batches, real money, removed by a named filter.
-- · CHECKED / NOT APPLIED — a filter that removed NOTHING. These rows carry
--   zero and they are here on purpose: a filter that was checked and caught
--   nothing is information, and a group with no rows would simply disappear
--   from a GROUP BY. They are reported against ALL FIVE SELLERS rather than
--   per seller, because there is no batch behind them to attribute.
--
-- ============================================================================
-- GUARDS — the same ones accounts.sql uses, so the populations agree
-- ============================================================================
-- X1 P1 newest WHOLE PAM delivery ('pam.pam.pam.2'); a plain max() lands on a
--    mis-loaded pam_perimeter file.
-- X2 ⚠ THE BATCH POPULATION IS DELIBERATELY UNFILTERED — no deal type, no
--    portfolio type, no ownership-change test. That is the point of the file:
--    the filters are applied as LABELS in `classified`, not as predicates, so
--    nothing can leave the table without saying why.
-- X3 THE MONEY MEASURE IS FILTERED, THOUGH, and identically to the ledger:
--    PMODE_NAME='Real' (P2), no ownership-change rows (P3), and actual months
--    only (P4 — PAM's plan horizon runs past 2039, so an unbounded sum can
--    include forecast). Without X3 the collections here would not tie.
-- X4 ⚠ THE SELLER MATCH IS EXACT NAMES, NOT A SUBSTRING OR REGEX.
--    'GE MONEY BANK' CONTAINS 'ONEY', so a LIKE or an alternation would pull a
--    sixth seller into the denominator. The REPLACE(', ' -> ',') stays because
--    one stray space makes SPLIT yield ' BARCLAYCARD', which never matches and
--    drops a whole seller with no error.
-- X5 CAT loan counts carry C1 (change-history dedupe), C8 (batch filter before
--    the qualify), C4/C5 (instance 4050 as a literal prefix, every extract) and
--    C9 (container cases dropped) — so they equal the ledger's CAT_LOANS.
-- ⚠ Nothing may follow the final semicolon: run_sql.py splits on ';'.
-- ============================================================================

set country = 'PT';
set seller_list = 'WIZINK BANK,BARCLAYCARD,MILLENNIUM,ONEY,COFIDIS';
set deal_type = 'One-off';
set source_system = '4050';
set raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set exclude_batches = '';


-- Everything PAM names for the scope, with NO benchmark filter applied (X2).
with all_batches AS (
    SELECT
        UPPER(p.combined_ref)                       AS batch_ref,
        MAX(TRIM(UPPER(p.seller_name)))             AS seller,
        MAX(p.deal_type_desc)                       AS deal_type,
        MAX(p.portfoliotype)                        AS portfolio_type,
        MAX(COALESCE(p.is_ownership_change, 0))     AS any_ownership_change,
        -- X3: the measure is filtered even though the population is not.
        SUM(IFF(p.pmode_name = 'Real'
                AND COALESCE(p.is_ownership_change, 0) = 0
                AND p.period_start_date::date < DATE_TRUNC('MONTH', TO_TIMESTAMP_NTZ(
                        PARSE_JSON(p._file_metadata):extract_ts::string,
                        'YYYYMMDDTHH24MISS'))::date,
                p.colltotal, 0))                    AS collections
    FROM RAW.HYPERION_INTRUM_PAM.PAM AS p
    CROSS JOIN (
        SELECT MAX(_file_path) AS file_path
        FROM RAW.HYPERION_INTRUM_PAM.PAM
        WHERE _file_path LIKE '%/pam.pam.pam.2%'                          -- X1
    ) AS nf
    WHERE p._file_path = nf.file_path                                     -- X1
      AND p.countrycode LIKE $country
      AND ARRAY_CONTAINS(TRIM(UPPER(p.seller_name))::variant,
                         SPLIT(REPLACE($seller_list, ', ', ','), ','))    -- X4
    GROUP BY 1
),

-- Loans behind each batch, so an exclusion can be sized in loans and not only
-- in euros. Same guards as accounts.sql, so these equal the ledger (X5).
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
            ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
        ) = 1
    )
    GROUP BY batch_ref
),

-- ⚠ FIRST reason wins, so a batch is counted exactly once and the rows
-- reconcile back to the starting population.
classified AS (
    SELECT
        b.seller,
        b.batch_ref,
        b.collections,
        COALESCE(l.loans, 0)                        AS loans,
        CASE
            WHEN b.any_ownership_change = 1
                THEN 'EXCLUDED · ownership-change rows restate a batch for a legal-buyer '
                     || 'transfer, so keeping them would report the same batch twice'
            WHEN b.deal_type <> $deal_type
                THEN 'EXCLUDED · forward flow (DEAL_TYPE_DESC = Ongoing) — newly defaulted '
                     || 'accounts arrive every month, so the population is not fixed, capex '
                     || 'is not a single event, and the batch cannot carry a vintage or a '
                     || 'stable denominator'
            WHEN b.portfolio_type <> 'Non-Performing'
                THEN 'EXCLUDED · performing book — a different asset, not comparable with a '
                     || 'non-performing purchase'
            WHEN $exclude_batches <> ''
                 AND ARRAY_CONTAINS(b.batch_ref::variant,
                                    SPLIT(REPLACE($exclude_batches, ', ', ','), ','))
                THEN 'EXCLUDED · named in $exclude_batches, a pricing decision rather than a '
                     || 'measurement — see the README'
            ELSE 'IN SCOPE · one-off non-performing purchase — this is the benchmark'
        END                                         AS reason
    FROM all_batches AS b
    LEFT JOIN loans_per_batch AS l
        ON l.batch_ref = b.batch_ref
),

-- Filters that were checked and caught nothing. Counted from the data rather
-- than asserted, so a future delivery that DOES trip one shows up here.
nothing_removed AS (
    SELECT
        'ALL FIVE SELLERS'                          AS seller,
        'CHECKED, REMOVED NOTHING · ownership-change rows (IS_OWNERSHIP_CHANGE = 1): '
            || 'none present in this scope'         AS reason,
        COUNT_IF(any_ownership_change = 1)          AS batches,
        0                                           AS loans,
        0                                           AS collections_eur
    FROM all_batches

    UNION ALL

    SELECT
        'ALL FIVE SELLERS',
        'CHECKED, REMOVED NOTHING · performing portfolios (PORTFOLIOTYPE <> '
            || '''Non-Performing''): every batch in this scope is non-performing',
        COUNT_IF(portfolio_type <> 'Non-Performing'),
        0,
        0
    FROM all_batches

    UNION ALL

    SELECT
        'ALL FIVE SELLERS',
        'CHECKED, REMOVED NOTHING · $exclude_batches ships EMPTY on purpose. Project '
            || 'Elsa drops six batches; that is a pricing decision taken on an '
            || 'overlapping book, so it is documented in the README and not baked in',
        COUNT_IF($exclude_batches <> ''
                 AND ARRAY_CONTAINS(batch_ref::variant,
                                    SPLIT(REPLACE($exclude_batches, ', ', ','), ','))),
        0,
        0
    FROM all_batches

    UNION ALL

    -- No predicate exists for this one, which is exactly why it is stated: the
    -- template's debtor-type gate was deliberately NOT carried over.
    SELECT
        'ALL FIVE SELLERS',
        'NOT APPLIED · debtor-type gate. The template drops loans with no identifiable '
            || 'debtor; 177 loans here carry neither a private nor a company debtor and '
            || 'they are KEPT, with INDIVIDUAL_FLAG = NULL saying so. Applying the gate '
            || 'would drop those 177 and break the accounts/payments pairing',
        0,
        0,
        0
)

SELECT
    seller,
    reason,
    batches,
    loans,                                          -- CAT loans behind them (X5)
    collections_eur,                                -- PAM actuals, ledger definition (X3)
    -- ⚠ The refs themselves, so an excluded batch can be traced rather than
    -- merely counted. The forward-flow cells are long by design.
    batch_refs
FROM (
    SELECT
        seller,
        reason,
        COUNT(*)                                    AS batches,
        SUM(loans)                                  AS loans,
        SUM(collections)                            AS collections_eur,
        LISTAGG(batch_ref, ', ') WITHIN GROUP (ORDER BY batch_ref) AS batch_refs
    FROM classified
    GROUP BY seller, reason

    UNION ALL

    SELECT
        seller,
        reason,
        batches,
        loans,
        collections_eur,
        NULL
    FROM nothing_removed
)
ORDER BY
    CASE
        WHEN reason LIKE 'IN SCOPE%' THEN 1
        WHEN reason LIKE 'EXCLUDED%' THEN 2
        ELSE 3
    END,
    batches DESC,
    seller;
