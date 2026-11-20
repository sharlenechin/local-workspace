-- ============================================================================
-- PROJECT SEA · accounts — one row per loan: the valuation base.
-- Portugal, instance 4050, FIVE sellers:
--   WIZINK BANK · BARCLAYCARD · MILLENNIUM · ONEY · COFIDIS
--
--   RUN     mise run sql -- work/project-sea-benchmark/accounts.sql \
--             --csv work/project-sea-benchmark/project_sea_benchmark_accounts.csv
--   GRAIN   one row per LOAN_ID (raw CASE_ID). Uniqueness asserted, see A1.
--   PAIRS   payments.sql on (PORTFOLIO_ID, LOAN_ID) — identical population.
--   RUNTIME ~2 min.  Money is EUR; CURRENCY_ID is returned so that stays checked.
--   METHOD  ../../work/benchmark-dataset/post-registration-benchmark/METHOD.md, step 2
--   BASED   ../../work/benchmark-dataset/post-registration-benchmark/templates/01_accounts.sql
--
-- Every figure below measured 2026-10-01, on this file as it stands.
-- ============================================================================
-- RETURNS  217,104 rows × 15 columns, 5 sellers, all 'One-off'.
--
--   seller       PAM batches  with loans    loans   registration_balance
--   MILLENNIUM            14          12  120,713         912,529,292.37
--   WIZINK BANK            4           4   34,357         170,421,597.18
--   BARCLAYCARD            2           2   30,584         115,967,810.86
--   ONEY                   4           4   23,024          27,449,355.73
--   COFIDIS                2           2    8,426          51,229,593.81
--   TOTAL                 26          24  217,104       1,277,597,649.95
--
--   ⚠ 26 BATCHES IN PAM, 24 WITH LOANS. PT06014B010000 and PT15018A040000
--   (both MILLENNIUM) have no cases in CAT at all. That absence is a FINDING,
--   not a row to drop — reconciliation.sql keeps both with their reason.
--   ⚠ CURRENCY_ID is 'EUR' on every loan but one, which carries NULL (WIZINK).
--   Verified single-valued 2026-10-01, which is why these figures may be
--   summed at all; the column is returned so the check stays visible.
--   ⚠ INDIVIDUAL_FLAG: 204,057 true, 12,870 false (a company debtor is on the
--   loan — 12,844 of them MILLENNIUM), 177 NULL (the debtor rows carry no P
--   and no C, so nobody recorded what kind of borrower this is).
--   ⚠ 7 loans (all MILLENNIUM) have a zero registration balance and 23 have
--   zero or negative capital. They are KEPT; a downstream cleaning rule should
--   drop them deliberately rather than find them by surprise.
--
-- ============================================================================
-- READ FIRST — five things that change a number
-- ============================================================================
-- 1. ⚠⚠ THE BALANCE SIZES A BOOK. IT MUST NEVER RANK TWO BOOKS.
--    REGISTRATION_BALANCE is REGISTRATION_CAPITAL + REGISTRATION_INTEREST, and
--    interest is not delivered the same way by any two of these five sellers.
--    Interest as a share of capital, all registration years, measured on THIS
--    population (one-off only) 2026-10-01:
--        ONEY        67.22189%        MILLENNIUM   0.65904%
--        WIZINK      20.11564%        COFIDIS      0.00000%
--        BARCLAYCARD 12.07480%
--    ⚠ The 19.72313% / 12.47974% quoted elsewhere for WIZINK / BARCLAYCARD are
--    the ALL-BATCHES figures, forward flow included. Those two sellers are the
--    only ones that run forward flow, so they are the only two whose ratio
--    moves with the deal-type filter. Say which population a ratio is on.
--    COFIDIS has NOT ONE loan with positive interest out of 8,426 (8,418 hold
--    an explicit 0.00, 8 hold NULL); 117,490 of MILLENNIUM's 120,713 hold an
--    explicit 0.00. A recovery-over-balance ranking across sellers therefore
--    measures accrual delivery, not performance.
--    ⚠ AND THE AGGREGATE HIDES THE SHAPE. Per-loan interest as % of capital,
--    share of each seller's loans:
--                      zero   0-10%   10-20%  20-100%   >100%
--        BARCLAYCARD   4.39   34.93    53.33     7.14    0.21
--        WIZINK        6.00   15.99    19.44    55.72    2.84
--        ONEY         18.12    4.10     4.21    67.66    5.91
--        MILLENNIUM   99.14    0.64     0.12     0.08    0.02
--        COFIDIS     100.00       -        -        -       -
--    1,361 ONEY and 975 WIZINK loans owe MORE interest than capital.
--    → Compare sellers on RECOVERY (collections over capital, or over PAM's
--      acquisition principal). Within one seller the balance is sound.
--    ⚠ DIVIDE BY REGISTRATION_CAPITAL, never by REGISTRATION_BALANCE, for an
--    interest-to-capital ratio: the balance already contains the interest.
--
-- 2. REGISTRATION_INTEREST ARRIVES NULL, NOT ZERO, WHERE IT WAS NOT DELIVERED,
--    and an explicit zero and a NULL are different facts — "this loan owed no
--    interest" versus "nobody told us". The NULL is preserved on the column,
--    COALESCE is applied only inside the balance sum, and
--    HAS_REGISTRATION_INTEREST says which is which. A NULL silently drops out
--    of an AVG; the flag is what stops that.
--
-- 3. ⚠⚠ DEBT_AGE_YEARS IS GUARDED, AND AN UNGUARDED ONE IS WRONG BY MORE THAN
--    A YEAR. It is (registration_date − default_date) / 365.25 and it is set
--    NULL — never zero, never clipped — on three kinds of unusable date:
--      (a) no default date at all;
--      (b) default before 1990-01-01 — MILLENNIUM 1,907 loans, earliest
--          1977-03-15, a sentinel rather than an event;
--      (c) default AFTER registration, which is arithmetically impossible for
--          an acquired NPL: MILLENNIUM 413, ONEY 344, BARCLAYCARD 137,
--          WIZINK 93, COFIDIS 2. ONEY's include 342 LOANS DATED 2099-12-31,
--          each worth about MINUS 82 YEARS. (On the forward-flow-inclusive
--          population the two flow sellers read 152 and 125 instead.)
--      Measured cost on ONEY: unguarded mean 2.06376 years, guarded 3.33343 —
--      an unguarded average is wrong by more than a year.
--    ⚠ ALWAYS QUOTE THE SURVIVING DENOMINATOR BESIDE THE AVERAGE. Guarded mean
--    and surviving coverage, measured 2026-10-01:
--        MILLENNIUM  4.01957 yrs on 118,393 of 120,713 (98.07809%)
--        ONEY        3.33343 yrs on  22,680 of  23,024 (98.50591%)
--        WIZINK      2.58500 yrs on  34,241 of  34,357 (99.66237%)
--        BARCLAYCARD 2.24751 yrs on  30,447 of  30,584 (99.55205%)
--        COFIDIS     2.08860 yrs on   8,424 of   8,426 (99.97626%)
--        whole book  3.38973 yrs on 214,185 of 217,104 (98.65548%)
--    The three flag columns are returned so that denominator can be rebuilt
--    from this file without going back to the warehouse.
--    ⚠ AND IT IS A DERIVED DATE. RAW CASES.DEFAULT_DATE is 100% NULL on this
--    instance; DIM_CASE.DERIVED_DEFAULT_DATE is back-filled from the latest
--    invoice due date on the case (country rule for PT), so it is biased LATE,
--    which is the likely source of (c). See Elsa FINDINGS.md N3.
--
-- 4. ⚠ PAM'S OWN AVERAGE_DEBT_AGE IS UNUSABLE AND IS NOT SOURCED HERE.
--    Measured 2026-10-01: its units are inconsistent BETWEEN batches — WIZINK
--    median 18 and max 72 (months), BARCLAYCARD 2.8 and COFIDIS 1.67 (years),
--    and ONEY spans 1.4 to 72 within one seller. 13 WIZINK and 1 ONEY batch
--    read above 24. Never quote or average that column; it is carried in
--    reconciliation.sql only so the inconsistency stays visible. This is a
--    finding for Intrum, not something to "fix" by dividing by twelve.
--
-- 5. ⚠ "REGISTRATION CAPITAL" IS AN INFERENCE, RE-EARNED ON THIS BOOK. Nothing
--    in the feed documents what ORIGINAL_CAPITAL means. Four tests, all run
--    2026-10-01 on the deduped population:
--      · vs PAM ACQUISITIONPRINCIPAL, same batches — COFIDIS 100.00%,
--        MILLENNIUM 100.34%, WIZINK 94.59%, BARCLAYCARD 91.56%, ONEY 61.21%.
--        At or near PAM, so this is an OPENING BALANCE and not an origination
--        face value, which would be far larger.
--        ⚠ ONEY'S 61% IS THE ONE TO WATCH, and the likely reading is that PAM's
--        acquisition principal is the WHOLE CLAIM: ONEY's capital + interest
--        comes to 102.35% of it against 61.21% on capital alone, and the same
--        pattern holds on BARCLAYCARD (102.62%) and MILLENNIUM (101.00%). An
--        open question for Intrum; it does not move any loan-level figure.
--      · vs REMAINING_CAPITAL — original is at or above remaining on 216,656
--        of 217,104 loans (99.79%).
--      · interest over time — capital FALLS 1,219,554,121.41 -> 974,014,347.39
--        while interest GROWS 58,043,528.54 -> 261,616,563.74. The right way
--        round; the other way round would mean the wrong field.
--      · registration date vs batch capex month — average gap 0 months on
--        every seller, and 216,322 of 217,104 loans (99.64%) register within
--        one month of capex. Registration and acquisition are the SAME EVENT
--        on this book, so the naming question is moot.
--    ⚠ PRINCIPAL_AT_CUTOFF and INTEREST_AT_CUTOFF are 100% EMPTY on all five
--    books — 0 of 217,104 populated. Do not design around them.
--
-- ============================================================================
-- GUARDS — each one silently changes a total if removed
-- ============================================================================
-- A1 C1 · CASES IS A CHANGE-HISTORY FEED, not a case list. Deduped to the
--    latest version per CASE_ID. Measured 2026-10-01: 44,743,156 version rows
--    behind 217,104 loans, 206x overall, and it is not uniform — BARCLAYCARD
--    367x, WIZINK 282x, COFIDIS 275x, ONEY 160x, MILLENNIUM 148x. Undeduped,
--    every balance multiplies by roughly those factors.
-- A2 C8 · THE BATCH FILTER RUNS BEFORE THE QUALIFY, and that order is
--    load-bearing: ranking happens only among versions naming an in-scope
--    batch, so a loan whose newest version left the scope keeps its last
--    in-scope batch instead of vanishing. Dedupe-then-filter cost Elsa 2,313
--    loans and EUR 6.86m, silently.
-- A3 ⚠⚠ C8's COROLLARY, AND THE MOST IMPORTANT LINE IN THIS FILE:
--    THE DEAL-TYPE FILTER IS AT THE FINAL SELECT, NOT IN `batches`.
--    Filtering deal type early changes what the dedupe can see, and C8 then
--    re-attributes loans across batches. Measured 2026-10-01: filtering early
--    moved 365 loans out of PT19007E021905 (Ongoing, and therefore invisible
--    to the early filter) into PT19013A020000 (One-off), inflating that batch
--    from 544 to 909 loans and the whole one-off book from 217,104 to 217,469.
--    → `batches` keeps the FULL seller scope, DEAL_TYPE rides through as a
--      column, and the filter lands at the end beside $exclude_batches.
--    → Proof it is in the right place: the three sellers that have ONLY
--      one-off batches — MILLENNIUM, ONEY, COFIDIS — return identical loan
--      counts filtered and unfiltered (120,713 / 23,024 / 8,426 both ways).
--      Only WIZINK and BARCLAYCARD, which also run forward flow, can move.
-- A4 ⚠ THE SELLER MATCH IS EXACT NAMES, NOT A SUBSTRING OR A REGEX.
--    'GE MONEY BANK' CONTAINS the substring 'ONEY', so Elsa's regex
--    alternation (safe for MILLENNIUM|WIZINK) would silently pull a sixth
--    seller into this book. ARRAY_CONTAINS on the full TRIM(UPPER()) name
--    cannot. The replace(', ' -> ',') is kept because a single stray space in
--    the parameter makes split() yield ' BARCLAYCARD', which never matches and
--    makes that seller vanish from the whole book with no error.
-- A5 C4/C5 · _file_path pinned to instance 4050 as a LITERAL PREFIX, and every
--    extract of it read. CASE_ID is unique only within an instance, a leading
--    '%' destroys partition pruning, and the extracts are not re-deliveries of
--    one another. ⚠ THE PIN COSTS NOTHING HERE AND THAT IS MEASURED, NOT
--    ASSUMED: asked with NO path filter on 2026-10-01, of the 19 Intrum
--    instances in the feed only 4050 holds any batch ref beginning 'PT'
--    (266 batches, 1,156,769 cases). So a seller reading 0 loans is genuinely
--    absent from CAT, not hidden behind the pin.
-- A6 C9 · container cases (hyphenated CASE_ID) dropped, as dbt does.
-- A7 C3 + C10 · DEBTORS is one-to-many AND a change feed, so it is collapsed
--    to one row per loan before it joins — joined raw it would multiply every
--    balance. ⚠ NO row_number() in that CTE: update timestamps TIE at the
--    latest version, so picking one row makes the flag flip between runs. The
--    max_ts window keeps EVERY row that is current and the flags are OR-ed.
-- A8 PAM guards P1 newest whole delivery ('pam.pam.pam.2' — a plain max()
--    lands on a mis-loaded pam_perimeter file), P2 PMODE_NAME='Real',
--    P3 no ownership-change rows (0 present in this scope, measured).
--    ⚠ VERIFIED SINGLE-VALUED PER BATCH 2026-10-01, which is what makes the
--    max() collapses safe: of the 266 PT batch refs in PAM, ZERO name two
--    sellers and ZERO name two deal types.
--
-- ============================================================================
-- EXCLUSIONS — a parameter, deliberately EMPTY by default
-- ============================================================================
-- $exclude_batches ships as '' so this file measures the WHOLE one-off book.
-- Project Elsa excluded six batches; that is a PRICING decision taken on an
-- overlapping book, not a measurement, so it is documented here and not baked
-- in. reconciliation.sql reports the book both ways.
--   PT06014B010000  MILLENNIUM · no cases in CAT under any instance, while PAM
--                   reports 660,000.00. A feed gap, not an empty book — and
--                   that 660,000 is posted ONCE, in the capex month, equal to
--                   its own ACQUISITIONPRINCIPAL to the cent: an accounting
--                   entry, not cash.
--   PT070040000000  MILLENNIUM · 2 loans holding EUR 4.00 between them against
--                   PAM's 340,000.00, registered 279 days after capex where
--                   every other batch lands within −2 to +40 days.
--   PT15018A040000  MILLENNIUM · its 84 cases resolve to PT16023C000000 under
--                   A2, so the batch carries 18,551,110.00 of acquired
--                   principal with no loans behind it.
--   PT19007D010000  WIZINK · fails Elsa's ±10% collections reconciliation
--   PT19013A020000  WIZINK ·   against PAM over a matched window. Of the four
--   PT19013B010000  WIZINK ·   WiZink one-offs only PT18019A000000 passes.
-- Elsa additionally drops loans with no identifiable debtor type (E1) and
-- WIZINK's company-debtor loans (E3). NEITHER IS APPLIED HERE: INDIVIDUAL_FLAG
-- carries NULL for the first and false for the second, which states the same
-- fact without removing a loan, and keeps this file pairing with payments.
-- ⚠ Nothing may follow the final semicolon: run_sql.py splits on ';'.
-- ============================================================================

set country         = 'PT';
set seller_list     = 'WIZINK BANK,BARCLAYCARD,MILLENNIUM,ONEY,COFIDIS';  -- A4
set deal_type       = 'One-off';   -- '' keeps forward flow too; see A3
set source_system   = '4050';      -- the only instance holding PT, see A5
set raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set exclude_batches = '';          -- comma-separated refs; '' keeps all


-- Scope: PAM collapsed to one row per batch before anything joins to it.
-- ⚠ NO DEAL-TYPE FILTER HERE. See guard A3 — it belongs at the final select.
with batches AS (
    SELECT
        UPPER(combined_ref)                 AS combined_ref,
        MAX(TRIM(UPPER(seller_name)))       AS seller,      -- single-valued, A8
        MAX(deal_type_desc)                 AS deal_type    -- single-valued, A8
    FROM RAW.HYPERION_INTRUM_PAM.PAM
    WHERE _file_path = (
              SELECT MAX(_file_path)
              FROM RAW.HYPERION_INTRUM_PAM.PAM
              WHERE _file_path LIKE '%/pam.pam.pam.2%'                      -- P1
          )
      AND pmode_name = 'Real'                                              -- P2
      AND COALESCE(is_ownership_change, 0) = 0                             -- P3
      AND countrycode LIKE $country
      AND ARRAY_CONTAINS(TRIM(UPPER(seller_name))::variant,
                         SPLIT(REPLACE($seller_list, ', ', ','), ','))      -- A4
    GROUP BY 1
),

-- One row per loan: its latest version, across every extract of 4050.
cases AS (
    SELECT
        UPPER(c.long_portfolio_id)      AS portfolio_id,
        c.case_id                       AS loan_id,
        c.registration_date::date       AS registration_date,
        c.original_capital              AS registration_capital,
        c.original_interest             AS registration_interest,
        c.currency_cap_interest         AS currency_id
    FROM RAW.HYPERION_INTRUM_CAT.CASES AS c
    WHERE c._file_path LIKE $raw_prefix || $source_system || '.cases.%'     -- A5
      AND UPPER(c.long_portfolio_id) IN (SELECT combined_ref FROM batches)  -- A2
      AND c.case_id NOT LIKE '%-%'                                         -- A6
      AND NOT ($source_system = '2080' AND COALESCE(c.real_case_ind, '') = '1')
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY c.case_id
        ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
    ) = 1                                                              -- A1, A2
),

-- Borrower type, one row per loan: the latest version of EVERY debtor slot,
-- flags OR-ed. ⚠ No row_number() — see guard A7.
debtor_type AS (
    SELECT
        d.case_id,
        MAX(IFF(d.type = 'C', 1, 0))    AS has_company_debtor,
        MAX(IFF(d.type = 'P', 1, 0))    AS has_private_debtor
    FROM (
        SELECT
            b.case_id,
            b.type,
            COALESCE(b.record_updated, b.update_ts)::timestamp AS ts,
            MAX(COALESCE(b.record_updated, b.update_ts)::timestamp) OVER (
                PARTITION BY b.case_id, b.debtor_row_number
            ) AS max_ts
        FROM RAW.HYPERION_INTRUM_CAT.DEBTORS AS b
        WHERE b._file_path LIKE $raw_prefix || $source_system || '.debtors.%'
          AND b.case_id IN (SELECT loan_id FROM cases)
          AND COALESCE(b.deleted, 0)  = 0
          AND COALESCE(b.archived, 0) = 0
          AND COALESCE(b.unlinked, 0) = 0
    ) AS d
    WHERE d.ts = d.max_ts                                                  -- A7
    GROUP BY d.case_id
),

-- Every join is LEFT onto a right side that is one row per loan, so the row
-- count cannot move. DIM_CASE supplies the default date and nothing else.
enriched AS (
    SELECT
        b.seller,
        b.deal_type,
        c.portfolio_id,
        c.loan_id,
        c.currency_id,
        c.registration_date,
        c.registration_capital,
        c.registration_interest,
        -- ⚠ COALESCE inside the sum only: a bare + would make the whole
        -- balance NULL wherever interest was not delivered.
        c.registration_capital + COALESCE(c.registration_interest, 0)
                                                    AS registration_balance,
        c.registration_interest IS NOT NULL         AS has_registration_interest,
        dc.derived_default_date::date               AS default_date,
        dc.derived_default_date::date < '1990-01-01'
                                                    AS default_date_suspect_flag,
        dc.derived_default_date::date > c.registration_date
                                                    AS default_after_registration_flag,
        -- ⚠ COMPANY WINS on a mixed loan, and NULL where no type was recorded.
        -- That is a POLICY, matching Elsa, not a reading of the data.
        CASE
            WHEN dt.has_company_debtor = 1 THEN false
            WHEN dt.has_private_debtor = 1 THEN true
        END                                         AS individual_flag
    FROM cases AS c
    JOIN batches AS b
        ON b.combined_ref = c.portfolio_id
    LEFT JOIN PROD.NPL_COMMON.DIM_CASE AS dc
        ON dc.case_bk = $source_system || '-' || c.loan_id   -- CASE_BK, not CASE_ID
        AND dc.is_current_flag
    LEFT JOIN debtor_type AS dt
        ON dt.case_id = c.loan_id
)

SELECT
    -- ids
    seller,                             -- exact PAM SELLER_NAME, upper-cased
    deal_type,                          -- 'One-off' as shipped; see A3
    portfolio_id,                       -- PAM COMBINED_REF = the BATCH ref
    loan_id,                            -- raw CASE_ID; PROD key is '4050-' || this
    currency_id,                        -- drop only after proving single-valued
    -- dates
    registration_date,                  -- when INTRUM opened the case, not origination
    default_date,                       -- DERIVED, and biased late — READ FIRST 3
    -- amounts
    registration_capital,               -- the capital component; the PAM comparable
    registration_interest,              -- ⚠ NULL, not 0, where none delivered
    registration_balance,               -- capital + interest — READ FIRST 1
    -- booleans
    has_registration_interest,          -- false = capital only on this row
    default_date_suspect_flag,          -- pre-1990 default date
    default_after_registration_flag,    -- impossible for an acquired NPL
    individual_flag,                    -- true individual / false company / NULL unknown
    -- derived
    -- ⚠ NULL, never zero, on every unusable default date — READ FIRST 3.
    IFF(default_date IS NULL
            OR default_date < '1990-01-01'
            OR default_date > registration_date,
        NULL,
        DATEDIFF('day', default_date, registration_date) / 365.25)
                                        AS debt_age_years
FROM enriched
-- ⚠⚠ BOTH FILTERS LAND HERE, AND THE DEAL-TYPE ONE MUST — see guard A3.
WHERE ($deal_type = '' OR deal_type = $deal_type)
  AND ($exclude_batches = ''
       OR NOT ARRAY_CONTAINS(portfolio_id::variant,
                             SPLIT(REPLACE($exclude_batches, ', ', ','), ',')))
ORDER BY seller, portfolio_id, loan_id;
