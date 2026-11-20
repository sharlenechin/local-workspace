-- ============================================================================
-- PROJECT SEA · reconciliation — THE BATCH LEDGER. One row per batch Intrum's
-- own report names for these five sellers: in or out, and WHY, in words.
-- Portugal, instance 4050.
--   WIZINK BANK · BARCLAYCARD · MILLENNIUM · ONEY · COFIDIS
--
--   RUN     mise run sql -- work/project-sea-benchmark/reconciliation.sql \
--             --csv work/project-sea-benchmark/project_sea_batch_ledger.csv
--   GRAIN   one row per PAM COMBINED_REF — 167 rows (26 one-off + 141 forward
--           flow), measured 2026-10-01. ⚠ EVERY batch stays in, including the
--           ones with no loans in CAT: that absence is the finding.
--   RUNTIME ~6 min — one pass over CASES and one over TRANSACTIONS.
--   METHOD  ../../work/benchmark-dataset/post-registration-benchmark/METHOD.md, steps 1, 4, 5
--
-- ============================================================================
-- HOW TO READ IT
-- ============================================================================
-- · STATUS / REASON is the column this file exists for. It is a sentence, not
--   a flag, and it is recomputed here rather than quoted from a previous run.
-- · THE COMPARISON IS WINDOW-MATCHED, because the two sources measure
--   different things:
--     — PAM's lifetime starts at each batch's CAPEX MONTH; CAT carries the
--       servicer's WHOLE history (BARCLAYCARD payments run back to 2002).
--       So CAT is cut at the capex month for the comparison only.
--     — CAT's extract stops at its last payment (2026-01-14) while PAM has
--       actuals to 2026-08. BOTH sides therefore close at the LAST COMPLETE
--       CAT MONTH, derived in `window_end`, never hard-coded.
--   ⚠ ALIGNING THE WINDOW HIDES THE LAG RATHER THAN FIXING IT. PAM_AFTER_WINDOW
--   is what the loan-level feed cannot yet see; read it beside the match.
-- · ⚠ QUOTE RESIDUAL_AFTER_UNDATED, NOT MATCH_RATIO. The residual credits back
--   cash CAT holds with no date in any version, which cannot be placed in a
--   month and so depresses every ratio. On Elsa the worst batch by ratio had
--   the smallest residual.
-- · A whole-against-whole ratio is worthless — two large opposite errors cancel
--   in it. Read this per batch.
--
-- ============================================================================
-- WHAT THE LEDGER SAYS, measured 2026-10-01
-- ============================================================================
-- 141 of the 167 batches are EXCLUDED as forward flow (DEAL_TYPE_DESC =
-- 'Ongoing') — 129 WIZINK and 12 BARCLAYCARD, carrying EUR 66,825,631.20 of
-- PAM collections and EUR 215,677,210.71 of acquired principal. They are not a
-- benchmark: new loans arrive every month, so the population is not fixed,
-- capex is not a single event, and loans added after the CAT extract look
-- exactly like a feed gap.
-- Of the 26 one-off batches that remain, 12 reconcile within 1% after undated
-- cash, 12 do not, and 2 hold no loans in CAT at all:
--   PT06014B010000  MILLENNIUM · PAM reports 660,000.00 — posted ONCE, in the
--                   capex month, equal to its own ACQUISITIONPRINCIPAL to the
--                   cent. Measured here across all 26 one-off batches, only
--                   this batch and PT070040000000 ever do that, against 3,906
--                   collecting months elsewhere: an accounting entry, not cash.
--   PT15018A040000  MILLENNIUM · 18,551,110.00 of acquired principal with no
--                   loans behind it; its 84 cases resolve to PT16023C000000
--                   under C8, so PAM bills the money to a batch our loan level
--                   cannot see.
-- Whole-book arithmetic over the matched window: PAM 276,475,500.90, CAT
-- 266,588,362.63 + 5,587,796.29 undated, NET residual −4,299,341.98 (−1.55505%)
-- and GROSS 7,093,665.66 (2.56575%). ⚠ Quote both: the net hides two large
-- opposite errors, which is exactly how Elsa's 99.88% was a coincidence.
--
-- ⚠⚠ PAM_AVERAGE_DEBT_AGE IS RETURNED AND MUST NOT BE QUOTED OR AVERAGED. Its
-- UNITS ARE INCONSISTENT BETWEEN BATCHES: WIZINK reads a median of 18 and a max
-- of 72 (months), BARCLAYCARD 2.8 and COFIDIS 1.67 (years), and ONEY spans 1.4
-- to 72 WITHIN ONE SELLER. 13 WIZINK and 1 ONEY batch read above 24. It is
-- carried here only so the defect stays visible and can be escalated — the
-- usable figure is DEBT_AGE_YEARS in accounts.sql, built from registration
-- and default dates with its own three guards. Do not "fix" this by dividing
-- by twelve.
--
-- ============================================================================
-- GUARDS
-- ============================================================================
-- R1 PAM · P1 newest whole delivery ('pam.pam.pam.2'), P2 PMODE_NAME='Real',
--    P3 no ownership-change rows, P4 actual months only (period_start_date
--    before the extraction month — PAM's plan horizon runs to 2039).
-- R2 CAT · C1 CASES and C2 TRANSACTIONS both deduped to latest version, C4/C5
--    instance 4050 pinned as a literal prefix with every extract read, C9
--    container cases dropped, C6 payments only, C7 AMOUNT negated, and the
--    payment date recovered across versions (never bounded).
-- R3 ⚠⚠ NO DEAL-TYPE FILTER ANYWHERE IN THE CAT PATH, exactly as in
--    accounts.sql guard A3. The ledger needs the forward-flow batches in
--    the scope anyway, and filtering them out early would re-attribute 365
--    loans into PT19013A020000 and change the one-off book.
-- R4 ⚠⚠ THE TWO CAT AGGREGATES ARE BUILT SEPARATELY AND THEN JOINED. Joining
--    `cases` and `payments` to the same batch in one FROM is a CARTESIAN
--    PRODUCT — every loan paired with every payment in its batch. It does not
--    error, it multiplies the money: measured when this was got wrong on Sea, a
--    batch of 29,976 loans reported EUR 1.3 TRILLION against a real 44m.
-- R5 PAM is collapsed to ONE ROW PER BATCH before anything joins to it. It is
--    batch x month x delivery; joined raw it multiplies every case by thousands.
-- ⚠ Nothing may follow the final semicolon: run_sql.py splits on ';'.
-- ============================================================================

set country         = 'PT';
set seller_list     = 'WIZINK BANK,BARCLAYCARD,MILLENNIUM,ONEY,COFIDIS';
set deal_type       = 'One-off';   -- what the BENCHMARK keeps; everything is reported
set source_system   = '4050';
set raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set exclude_batches = '';          -- = accounts.sql; '' keeps all


with newest_pam_file AS (
    SELECT MAX(_file_path) AS file_path
    FROM RAW.HYPERION_INTRUM_PAM.PAM
    WHERE _file_path LIKE '%/pam.pam.pam.2%'                             -- R1
),

-- Actual months only, one row per batch-month, for the five sellers.
pam_rows AS (
    SELECT
        UPPER(p.combined_ref)       AS batch_ref,
        TRIM(UPPER(p.seller_name))  AS seller,
        p.deal_type_desc            AS deal_type,
        p.portfoliotype             AS portfolio_type,
        p.capex_date_m::date        AS capex_month,
        p.period_start_date::date   AS reporting_month,
        p.colltotal                 AS collections,
        p.acquisitionprincipal      AS acquisition_principal,
        p.rp_purchase_price         AS purchase_price,
        p.acqcases                  AS acq_cases,
        p.average_debt_age          AS average_debt_age
    FROM RAW.HYPERION_INTRUM_PAM.PAM AS p
    INNER JOIN newest_pam_file AS nf
        ON nf.file_path = p._file_path                                   -- R1
    WHERE p.pmode_name = 'Real'                                          -- R1
      AND COALESCE(p.is_ownership_change, 0) = 0                         -- R1
      AND p.countrycode LIKE $country
      AND ARRAY_CONTAINS(TRIM(UPPER(p.seller_name))::variant,
                         SPLIT(REPLACE($seller_list, ', ', ','), ','))
      -- P4: plan months run past 2039; without this a "last collecting month"
      -- silently returns a forecast.
      AND p.period_start_date::date < DATE_TRUNC('MONTH', TO_TIMESTAMP_NTZ(
              PARSE_JSON(p._file_metadata):extract_ts::string,
              'YYYYMMDDTHH24MISS'))::date
),

-- CAT loans, latest version, batch filter before the qualify. No deal-type
-- filter — R3.
cases AS (
    SELECT
        UPPER(c.long_portfolio_id)  AS batch_ref,
        c.case_id                   AS loan_id,
        c.original_capital          AS registration_capital,
        c.original_capital + COALESCE(c.original_interest, 0)
                                    AS registration_balance
    FROM RAW.HYPERION_INTRUM_CAT.CASES AS c
    WHERE c._file_path LIKE $raw_prefix || $source_system || '.cases.%'
      AND UPPER(c.long_portfolio_id) IN (SELECT DISTINCT batch_ref FROM pam_rows)
      AND c.case_id NOT LIKE '%-%'
      AND NOT ($source_system = '2080' AND COALESCE(c.real_case_ind, '') = '1')
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY c.case_id
        ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
    ) = 1
),

payments AS (
    SELECT
        c.batch_ref,
        MAX(t.transaction_date::date) OVER (
            PARTITION BY t.case_id, CONCAT(t.orig_tr_id, COALESCE(t.pkey, ''))
        )                           AS payment_date,
        -t.amount::decimal(38, 2)   AS amount
    FROM RAW.HYPERION_INTRUM_CAT.TRANSACTIONS AS t
    INNER JOIN cases AS c
        ON c.loan_id = t.case_id
    WHERE t._file_path LIKE $raw_prefix || $source_system || '.transactions.%'
      AND t.payment_cost_ind = 'P'
      AND COALESCE(t.booking_ind, 'N') != 'Y'
      AND t.amount IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY t.case_id, CONCAT(t.orig_tr_id, COALESCE(t.pkey, ''))
        ORDER BY COALESCE(t.record_updated, t.update_ts)::timestamp DESC NULLS LAST
    ) = 1
),

-- The window closes at the last COMPLETE month in the CAT feed. Derived, never
-- hard-coded: the extract moves, and a partial final month would depress every
-- match for no reason.
window_end AS (
    SELECT DATEADD('DAY', -1, DATE_TRUNC('MONTH', MAX(payment_date)))::date
                                    AS last_complete_day
    FROM payments
),

-- One row per batch. ⚠ Built separately from `collected` — see R4.
loan_count AS (
    SELECT
        batch_ref,
        COUNT(*)                            AS cat_loans,
        SUM(registration_capital)           AS cat_registration_capital,
        SUM(registration_balance)           AS cat_registration_balance
    FROM cases
    GROUP BY batch_ref
),

collected AS (
    SELECT
        pay.batch_ref,
        SUM(pay.amount)                                                  AS cat_collections_all,
        SUM(IFF(pay.payment_date IS NULL, pay.amount, 0))                AS cat_undated,
        SUM(IFF(pay.payment_date < b.capex_month, pay.amount, 0))        AS cat_pre_capex,
        SUM(IFF(pay.payment_date >= b.capex_month
                AND pay.payment_date <= w.last_complete_day,
                pay.amount, 0))                                          AS cat_matched
    FROM payments AS pay
    JOIN (SELECT batch_ref, MIN(capex_month) AS capex_month
          FROM pam_rows GROUP BY batch_ref) AS b
        ON b.batch_ref = pay.batch_ref
    CROSS JOIN window_end AS w
    GROUP BY pay.batch_ref
),

-- PAM collapsed to one row per batch (R5), on three windows: the matched one,
-- lifetime actuals, and what the loan-level feed cannot yet see.
pam AS (
    SELECT
        pr.batch_ref,
        MAX(pr.seller)                                                   AS seller,
        MAX(pr.deal_type)                                                AS deal_type,
        MAX(pr.portfolio_type)                                           AS portfolio_type,
        MIN(pr.capex_month)                                              AS capex_month,
        MAX(pr.acquisition_principal)                                    AS acq_principal,
        SUM(pr.purchase_price)                                           AS capex_amount,
        MAX(pr.acq_cases)                                                AS acq_cases,
        MAX(pr.average_debt_age)                                         AS pam_average_debt_age,
        SUM(pr.collections)                                              AS pam_collections_lifetime,
        SUM(IFF(pr.reporting_month <= DATE_TRUNC('MONTH', w.last_complete_day),
                pr.collections, 0))                                      AS pam_matched,
        SUM(IFF(pr.reporting_month > DATE_TRUNC('MONTH', w.last_complete_day),
                pr.collections, 0))                                      AS pam_after_window,
        MAX(IFF(pr.collections <> 0, pr.reporting_month, NULL))          AS pam_last_collecting_month
    FROM pam_rows AS pr
    CROSS JOIN window_end AS w
    GROUP BY pr.batch_ref
)

SELECT
    -- ids
    pam.seller,
    pam.batch_ref,
    pam.deal_type,
    pam.portfolio_type,
    -- acquisition side: INTRUM'S OWN REPORT, never a roll-up of our loans
    pam.capex_month,
    pam.capex_amount,                                   -- RP_PURCHASE_PRICE, what was paid
    pam.acq_principal,                                  -- ACQUISITIONPRINCIPAL
    pam.acq_cases,                                      -- ⚠ NOT our loan count; see below
    pam.pam_average_debt_age,                           -- ⚠⚠ UNITS INCONSISTENT — do not quote
    -- our side
    COALESCE(lc.cat_loans, 0)                           AS cat_loans,
    COALESCE(lc.cat_registration_capital, 0)            AS cat_registration_capital,
    COALESCE(lc.cat_registration_balance, 0)            AS cat_registration_balance,
    -- the window-matched pair
    pam.pam_matched,
    COALESCE(cl.cat_matched, 0)                         AS cat_matched,
    COALESCE(cl.cat_matched, 0) - pam.pam_matched       AS variance,
    DIV0(COALESCE(cl.cat_matched, 0), NULLIF(pam.pam_matched, 0))
                                                        AS match_ratio,
    -- ⚠ THE FIGURE TO QUOTE: undated cash credited back.
    COALESCE(cl.cat_matched, 0) + COALESCE(cl.cat_undated, 0) - pam.pam_matched
                                                        AS residual_after_undated,
    DIV0(COALESCE(cl.cat_matched, 0) + COALESCE(cl.cat_undated, 0),
         NULLIF(pam.pam_matched, 0))                    AS residual_ratio,
    -- the differences, each broken out
    COALESCE(cl.cat_undated, 0)                         AS cat_undated,      -- CAT under
    COALESCE(cl.cat_pre_capex, 0)                       AS cat_pre_capex,    -- CAT over
    pam.pam_after_window,                               -- the seven-month feed lag
    COALESCE(cl.cat_collections_all, 0)                 AS cat_collections_all,
    pam.pam_collections_lifetime,
    pam.pam_last_collecting_month,
    -- ⚠ THE REASON, IN WORDS. The column the ledger exists for.
    CASE
        WHEN pam.deal_type <> $deal_type
            THEN 'EXCLUDED, whole batch — forward flow (DEAL_TYPE_DESC = '''
                 || pam.deal_type || '''): new loans arrive every month, so the '
                 || 'population is not fixed, capex is not a single event, and a '
                 || 'vintage curve has no cohort'
        WHEN pam.portfolio_type <> 'Non-Performing'
            THEN 'EXCLUDED, whole batch — ' || pam.portfolio_type
                 || ' book, a different asset and not comparable'
        WHEN $exclude_batches <> ''
             AND ARRAY_CONTAINS(pam.batch_ref::variant,
                                SPLIT(REPLACE($exclude_batches, ', ', ','), ','))
            THEN 'EXCLUDED, whole batch — named in $exclude_batches'
        WHEN COALESCE(lc.cat_loans, 0) = 0
            THEN 'IN SCOPE but NO LOANS IN CAT — PAM reports this batch and the '
                 || 'loan-level feed holds nothing for it. A feed gap, not an '
                 || 'empty book: it contributes 0 loans and 0 collections'
        WHEN pam.pam_matched = 0 AND COALESCE(cl.cat_matched, 0) <> 0
            THEN 'IN SCOPE, does not reconcile — CAT holds cash in the matched '
                 || 'window and PAM reports none'
        WHEN ABS(COALESCE(cl.cat_matched, 0) + COALESCE(cl.cat_undated, 0)
                 - pam.pam_matched)
             <= GREATEST(1000, 0.01 * ABS(pam.pam_matched))
            THEN 'IN SCOPE, reconciles — within 1% of PAM over the matched '
                 || 'window after crediting undated cash'
        WHEN COALESCE(cl.cat_matched, 0) + COALESCE(cl.cat_undated, 0) < pam.pam_matched
            THEN 'IN SCOPE, does not reconcile — CAT SHORT of PAM over the '
                 || 'matched window; hypothesis needed before this batch is quoted'
        ELSE 'IN SCOPE, does not reconcile — CAT OVER PAM over the matched '
             || 'window; check pre-capex cash and batch re-attribution'
    END                                                 AS status_reason,
    -- ⚠ Elsa's own exclusions, DOCUMENTED NOT APPLIED. They are a pricing
    -- decision taken on an overlapping book, not a measurement.
    CASE
        WHEN pam.batch_ref = 'PT06014B010000' THEN 'Elsa excludes — no cases in CAT; PAM''s 660,000.00 is one capex-month posting equal to ACQUISITIONPRINCIPAL'
        WHEN pam.batch_ref = 'PT070040000000' THEN 'Elsa excludes — 2 loans holding EUR 4.00 against PAM''s 340,000.00, registered 279 days after capex'
        WHEN pam.batch_ref = 'PT15018A040000' THEN 'Elsa excludes — its 84 cases resolve to PT16023C000000, so 18,551,110.00 of acquired principal has no loans'
        WHEN pam.batch_ref = 'PT19007D010000' THEN 'Elsa excludes — fails its +/-10% CAT-vs-PAM collections test'
        WHEN pam.batch_ref = 'PT19013A020000' THEN 'Elsa excludes — fails its +/-10% CAT-vs-PAM collections test'
        WHEN pam.batch_ref = 'PT19013B010000' THEN 'Elsa excludes — fails its +/-10% CAT-vs-PAM collections test'
    END                                                 AS elsa_treatment
FROM pam
LEFT JOIN loan_count AS lc
    ON lc.batch_ref = pam.batch_ref
LEFT JOIN collected AS cl
    ON cl.batch_ref = pam.batch_ref
ORDER BY
    IFF(pam.deal_type = $deal_type, 0, 1),
    pam.seller,
    pam.capex_month,
    pam.batch_ref;
