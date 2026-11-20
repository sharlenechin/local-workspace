-- ============================================================================
-- reconciliation — what each guard actually removes, one step at a time.
--
-- Each step adds exactly ONE rule, so every movement has a named cause.
-- Step 5 is where the original extract stopped. Step 6 is reference_data.sql,
-- the corrected extract. Step 7 is NOT the extract — it is the de-repeated
-- figure you need only if you aggregate across rows (see README.md).
--
--   RUN     mise run sql -- work/average_balance/reconciliation.sql
--   GRAIN   one row per step (7 steps), SE / PI Unsecured / Ongoing throughout
--   COST    a minute — step 1 deliberately reads all 15 monthly files
--   WORKED  README.md §"The reconciliation"
--
-- MEASURED 2026-10-05. Expected output:
--
--   step                                      rows        accounts        total SEK     average SEK
--   1 raw file, no rules              5,568,315   1,768,067,460  12,445,827,592,123.65   7,039.22665
--   2 + one month's file only           371,881     117,874,140     830,001,773,326.07   7,041.42379
--   3 + no internal accounting          371,881     117,874,140     830,001,773,326.07   7,041.42379
--   4 + no ownership-transfer rows      371,881     117,874,140     830,001,773,326.07   7,041.42379
--   5 ORIGINAL EXTRACT STOPPED HERE     151,756      51,192,712     348,974,232,215.44   6,816.87331
--   6 CORRECTED EXTRACT (reference_data) 150,199      50,723,018     345,574,282,722.61   6,812.96769
--   7 for reference: de-repeated          1,557         469,694       3,399,949,492.83   7,238.64791
--
-- WHAT EACH MOVEMENT MEANS
--   1->2  14.97x  Intrum sends this file monthly and we keep every copy, so the
--                 whole book sits in the table 15 times over. The original query
--                 already picked one copy -- but by newest timestamp, which is
--                 right only by luck. See rule 1 in average_balance_detail.sql.
--   2->4  nothing Internal accounting entries and ownership-transfer duplicates
--                 do not exist in the Swedish book. ⚠ Both rules are still
--                 required: ownership transfers alone duplicate 3,075 rows in
--                 Switzerland and 131 in Poland IN THIS SAME FILE. A rule that
--                 does nothing here is not a rule you may drop.
--   4->5  2.45x   Removing forecast months. ⚠ The file mixes Intrum's forecasts
--                 in with its history, out to 2040-11-01, and NOTHING IN THE DATA
--                 MARKS WHICH IS WHICH -- the cut-off date is the only separator.
--   5->6  1,557   The original cuts at TODAY's month end. The file was produced
--         rows    2026-09-10 and runs about a month behind, so one forecast month
--                 slips through as history. It holds zero accounts, so any
--                 average-per-account that reaches it divides by zero.
--   6->7  108.00x NOT A BUG IN THE EXTRACT. A batch's size is fixed when we buy
--         101.65x it, and the file repeats it on every monthly line (10 to 231,
--                 median 84) -- which is exactly what the modelling pipeline
--                 wants, since it reads one row at a time. Step 7 matters ONLY
--                 if someone adds the rows up; then they must count each
--                 purchase once first.
--   Effect on the average, step 5 against step 7: +5.83% (SEK 6,816.87331 ->
--   SEK 7,238.64791). The repetition weights the book by how long we have held
--   each batch rather than by how big it is, and the batches held longest have
--   smaller accounts.
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

SET country     = 'SE';
SET serviceline = 'PI Unsecured';
SET deal_type   = 'Ongoing';


WITH newest_delivery AS (
    SELECT MAX(_file_path) AS file_path
    FROM raw.hyperion_intrum_pam.pam
    WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

-- The scope with the rules NOT applied, carried as flags instead, so each step
-- below can switch exactly one on and the movement is attributable to it alone.
unguarded AS (
    SELECT
        p.combined_ref,
        p.acqcases                           AS acq_accounts,
        p.acquisitionprincipal               AS acq_principal_local,
        p.pmode_name,
        COALESCE(p.is_ownership_change, 0)   AS is_ownership_change,
        LEFT(p.period_start_date, 10)::date  AS period_month,
        (p._file_path = nd.file_path)        AS is_newest_delivery,
        DATE_TRUNC('month',
            TO_TIMESTAMP_NTZ(
                PARSE_JSON(p._file_metadata):extract_ts::string,
                'YYYYMMDDTHH24MISS'))::date  AS extract_month
    FROM raw.hyperion_intrum_pam.pam AS p
    CROSS JOIN newest_delivery AS nd
    WHERE p.countrycode    = $country
      AND p.serviceline    = $serviceline
      AND p.deal_type_desc = $deal_type
),

-- Steps 1 to 6 all count one row per batch-month, so they stack.
steps AS (
    SELECT 1 AS ord,
           '1 the raw file, no rules at all'                      AS step,
           'every monthly copy, every month — the starting point' AS what_it_does,
           acq_accounts, acq_principal_local
    FROM unguarded

    UNION ALL
    SELECT 2, '2 + rule 1: one month''s file only',
           'we keep 15 monthly copies; this picks one',
           acq_accounts, acq_principal_local
    FROM unguarded
    WHERE is_newest_delivery

    UNION ALL
    SELECT 3, '3 + rule 2: no internal accounting',
           'bookkeeping adjustments are not real accounts',
           acq_accounts, acq_principal_local
    FROM unguarded
    WHERE is_newest_delivery
      AND pmode_name = 'Real'

    UNION ALL
    SELECT 4, '4 + rule 3: no ownership-transfer rows',
           'a transfer can make one batch appear twice',
           acq_accounts, acq_principal_local
    FROM unguarded
    WHERE is_newest_delivery
      AND pmode_name = 'Real'
      AND is_ownership_change = 0

    UNION ALL
    -- The original query's own cut-off, reproduced exactly: anchored to TODAY
    -- rather than to the file. Kept as its own step so its cost is visible.
    SELECT 5, '5 ORIGINAL EXTRACT STOPPED HERE',
           'cuts forecasts, but using today as the cut-off',
           acq_accounts, acq_principal_local
    FROM unguarded
    WHERE is_newest_delivery
      AND pmode_name = 'Real'
      AND is_ownership_change = 0
      AND period_month <= DATEADD('day', -1, DATE_TRUNC('month', CURRENT_DATE()))

    UNION ALL
    SELECT 6, '6 CORRECTED EXTRACT (reference_data.sql)',
           'cuts forecasts at the file date — 150,199 rows out',
           acq_accounts, acq_principal_local
    FROM unguarded
    WHERE is_newest_delivery
      AND pmode_name = 'Real'
      AND is_ownership_change = 0
      AND period_month < extract_month
),

-- Step 7 counts something different — one row per PURCHASE, not per batch-month.
-- It is NOT what the extract emits; it is what you must do before summing.
step_7 AS (
    SELECT
        combined_ref,
        MAX(acq_accounts)        AS acq_accounts,
        MAX(acq_principal_local) AS acq_principal_local
    FROM unguarded
    WHERE is_newest_delivery
      AND pmode_name = 'Real'
      AND is_ownership_change = 0
      AND period_month < extract_month
    GROUP BY combined_ref
)

SELECT
    ord                      AS step_no,
    step,
    what_it_does,
    COUNT(*)                 AS rows_counted,
    SUM(acq_accounts)        AS accounts,
    SUM(acq_principal_local) AS total_sek,
    SUM(acq_principal_local)
        / NULLIF(SUM(acq_accounts), 0) AS average_per_account_sek
FROM steps
GROUP BY ord, step, what_it_does

UNION ALL

SELECT
    7,
    '7 for reference: each purchase counted once',
    'ONLY for totals across rows — not the extract',
    COUNT(*),
    SUM(acq_accounts),
    SUM(acq_principal_local),
    SUM(acq_principal_local) / NULLIF(SUM(acq_accounts), 0)
FROM step_7

ORDER BY step_no;
