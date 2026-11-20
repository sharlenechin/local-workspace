-- ============================================================================
-- portugal_seller_profile — one row per Portuguese seller: size, price shape,
-- debt age, and whether the book was bought as a spot purchase or on forward
-- flow. The reference table to open before scoping any new Portugal benchmark.
--
--   RUN     mise run sql -- work/portugal/portugal_seller_profile.sql \
--                          --csv work/portugal/portugal_seller_profile.csv
--   GRAIN   one row per SELLER_NAME. 30 expected.
--   GUARDS  Project Elsa's, carried unchanged — see below.
--   BUILT   2026-10-01.
--
-- ⚠⚠ ELSA'S GUARDS ARE APPLIED; ELSA'S EXCLUSIONS ARE NOT. That distinction is
-- the whole design of this file and Elsa's own header draws it too.
--   · GUARDS (C1, C4, C5, C8, C9 and the PAM scope) are measurement
--     correctness. They apply to every book and are applied here.
--   · EXCLUSIONS (Elsa's E1 unclassifiable debtors, E3 WiZink's 5 company
--     loans, and its six named $exclude_batches) are decisions about what
--     belongs in ONE priced book. Applying them to a country-wide census would
--     silently delete real loans from sellers Elsa never looked at.
-- ⚠ SO THIS IS A CENSUS, NOT A VALUATION BASE. To price a book, scope it with
-- work/project-elsa-benchmark/accounts.sql or the templates beside this file
-- and take their exclusions too.
--
-- ⚠⚠ ELSA'S G8 IS A COLUMN HERE, NOT A FILTER. Elsa sets
-- DEAL_TYPE_DESC = 'One-off' because a forward-flow book priced as a spot
-- purchase is wrong; its header says that without the predicate "the benchmark
-- silently becomes a forward-flow book". This file must show every seller, so
-- it REPORTS the split instead of cutting on it. Measured 2026-10-01 across
-- all 266 Portuguese batches:
--     One-off    61 batches, spread across all 30 sellers
--     Ongoing   198 batches, concentrated in just 4 sellers
-- ⚠ FOUR SELLERS CARRY FORWARD FLOW AND 26 DO NOT. FLOW_TYPE says which, and
-- 'Mixed' means the seller has both — read ONE_OFF_BATCHES and ONGOING_BATCHES
-- before comparing such a seller with a pure one-off book.
-- ⚠ NO BATCH CARRIES BOTH DEAL TYPES anywhere in Portugal (0 of 266, measured
-- 2026-10-01), so the MAX() collapse below cannot hide a mixed batch.
--
-- ⚠⚠⚠ OUTSTANDING IS ORIGINAL_CAPITAL + ORIGINAL_INTEREST AND IT DOES NOT MEAN
-- THE SAME THING ON EVERY ROW. Interest is delivered on some books and not
-- others, so AVG_OUTSTANDING_PER_LOAN silently shifts between "capital and
-- accrued interest" and "capital alone". Measured 2026-10-01: Oney 67.22189%
-- of capital, WiZink 19.72313%, Barclaycard 12.47974%, Millennium 0.65904%,
-- Cofidis 0.00000% — not one of Cofidis's 8,426 loans carries any interest.
-- READ INTEREST_PCT_OF_CAPITAL BEFORE RANKING TWO SELLERS ON OUTSTANDING.
-- Size a book with it; never rank two books on it.
-- ⚠ DIVIDE BY REGISTRATION CAPITAL, NEVER BY OUTSTANDING, for that ratio: the
-- balance already contains the interest, so the second always reads lower.
--
-- ⚠⚠ AVERAGE DEBT AGE IS OURS, NOT INTRUM'S. PAM ships AVERAGE_DEBT_AGE and it
-- CANNOT BE USED — the units are inconsistent between batches. Measured
-- 2026-10-01: WiZink median 18 and max 72 (months), Barclaycard 2.8 and
-- Cofidis 1.67 (years), and Oney spans 1.4 to 72 within one seller. Nothing in
-- the feed says which unit a row carries. REPORTED, NOT FIXED — that is a
-- conversation with the data team, not a silent correction here.
--
-- ⚠ DEBT AGE IS REGISTRATION MINUS DEFAULT — Intrum's own definition, the one
-- Elsa and debt_age_bands.sql use. It is how long the debt had ALREADY been in
-- default when Intrum opened the case, NOT how long we have held it.
-- ⚠ DEBT_AGE_COVERAGE_PCT IS NOT DECORATION. Unusable default dates are set to
-- NULL and drop out of the AVG, so the average has a smaller denominator than
-- LOANS. Three kinds are excluded and all are real: no default date at all; a
-- default before 1990 (Millennium 1,907, earliest 1977-03-15); and a default
-- AFTER registration, which is impossible under the definition and which
-- includes ONEY'S 342 LOANS DATED 2099-12-31 — each worth about MINUS 82
-- YEARS. Left in, Oney averages 2.06376 years; guarded, 3.33343.
--
-- GUARDS, carried from Elsa unchanged:
--   C1  CASES is a CHANGE-HISTORY feed — deduped to the latest version per
--       CASE_ID. About 340 versions per loan on the Portuguese books.
--   C4  _file_path pinned to ONE instance as a LITERAL PREFIX. CASE_ID is
--       unique only within an instance, and a leading % kills partition
--       pruning. ⚠ PROVEN SOLE PT INSTANCE: of the 19 instances in the feed,
--       asked with no path filter on 2026-10-01, only 4050 carries any batch
--       ref beginning 'PT' — 266 batches, 1,156,769 cases. Re-measure before
--       pointing this file at another country.
--   C5  every extract read; they are not copies of one another.
--   C8  the batch filter runs BEFORE the qualify, so a loan whose newest
--       version left the scope keeps its last in-scope batch.
--   C9  container cases (hyphenated CASE_ID) dropped, as dbt does.
--   PAM newest whole file only, PMODE_NAME = 'Real', no ownership-change rows.
-- ⚠ C3 and C10 are NOT needed here: they guard the DEBTORS join, and this file
-- carries no borrower type. Add them with it if that column is ever wanted.
--
-- ⚠ A SELLER WITH LOANS = 0 IS REAL, NOT A BUG. The join from PAM to the loan
-- feed is LEFT, so a seller whose batches hold no cases still gets a row. Given
-- C4 is proven above, a zero means genuinely absent from the loan feed.
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

SET country       = 'PT';
-- ⚠⚠ BOTH FILTERS BELOW ARE APPLIED AFTER THE C1/C8 DEDUPE, NEVER BEFORE IT.
-- Narrowing the scope the dedupe sees makes C8 re-attribute loans to whichever
-- batch survives: measured 2026-10-01 on the Project Sea build, filtering a
-- deal type early moved 365 loans into PT19013A020000 and inflated it from 544
-- to 909. Applied here they are pure row filters, so a filtered run returns
-- EXACTLY the census rows — which is the check that they are placed right.
-- SELLERS: empty keeps every seller. Otherwise exact names, comma separated.
-- DEAL_TYPE: empty keeps both. Otherwise 'One-off' or 'Ongoing'.
-- ⚠ NO TRAILING COMMENT ON A SET LINE, and no semicolon inside one anywhere
-- near a statement. run_sql.py splits the file on ';' and a trailing comment
-- carrying one -- or carrying a '' quote pair -- breaks the split with a
-- syntax error pointing at a line far below. Cost 1 failed run on 2026-10-01.
SET sellers       = '';
SET deal_type     = '';
SET source_system = '4050';                     -- proven sole PT instance, see C4
SET raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


-- PAM collapsed to one row per batch BEFORE anything joins to it. PAM is
-- monthly, so without this collapse every loan would fan out across reporting
-- months and every count below would be wrong.
WITH newest_pam_file AS (
    SELECT MAX(_file_path) AS file_path
    FROM RAW.HYPERION_INTRUM_PAM.PAM
    WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

batches AS (
    SELECT
        UPPER(p.combined_ref)           AS batch_ref,
        -- ⚠ MAX() IS SAFE ONLY BECAUSE both are single-valued per batch:
        -- zero batch refs name two sellers (Elsa verified 2026-09-16) and zero
        -- name two deal types (verified 2026-10-01). Re-assert if either the
        -- country or the PAM file changes.
        MAX(TRIM(UPPER(p.seller_name))) AS seller,
        MAX(p.deal_type_desc)           AS deal_type
    FROM RAW.HYPERION_INTRUM_PAM.PAM AS p
    CROSS JOIN newest_pam_file AS nf
    WHERE p._file_path = nf.file_path
      AND p.pmode_name = 'Real'
      AND COALESCE(p.is_ownership_change, 0) = 0
      AND p.countrycode LIKE $country
    GROUP BY 1
),

-- One row per loan: its latest version, across every extract.
cases AS (
    SELECT
        UPPER(c.long_portfolio_id) AS batch_ref,
        c.case_id                  AS loan_id,
        c.registration_date::DATE  AS registration_date,
        c.original_capital         AS capital,
        c.original_interest        AS interest,
        -- ⚠ COALESCE, not a bare sum: without it a missing interest would make
        -- the whole balance NULL rather than falling back to capital.
        c.original_capital + COALESCE(c.original_interest, 0) AS outstanding
    FROM RAW.HYPERION_INTRUM_CAT.CASES AS c
    WHERE c._file_path LIKE $raw_prefix || $source_system || '.cases.%'   -- C4, C5
      AND UPPER(c.long_portfolio_id) IN (SELECT batch_ref FROM batches)   -- C8
      AND c.case_id NOT LIKE '%-%'                                        -- C9
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY c.case_id
        ORDER BY COALESCE(c.record_updated, c.update_ts)::TIMESTAMP DESC NULLS LAST
    ) = 1                                                                 -- C1, C8
),

loans AS (
    SELECT
        b.seller,
        c.loan_id,
        c.capital,
        c.interest,
        c.outstanding,
        -- ⚠ 365.25 so a leap year cannot move a loan across a year boundary.
        -- ⚠ THE CASE IS A VISIBLE GUARD, NOT TIDYING. An unusable default date
        -- becomes NULL and drops out of the AVG instead of poisoning it;
        -- DEBT_AGE_COVERAGE_PCT below reports how much was lost. See the header.
        CASE
            WHEN dc.derived_default_date IS NULL                      THEN NULL
            WHEN dc.derived_default_date::DATE <  '1990-01-01'        THEN NULL
            WHEN dc.derived_default_date::DATE >  c.registration_date THEN NULL
            ELSE DATEDIFF('DAY', dc.derived_default_date::DATE, c.registration_date) / 365.25
        END AS debt_age_years
    FROM cases AS c
    INNER JOIN batches AS b
        ON b.batch_ref = c.batch_ref
    -- ⚠ DIM_CASE IS THE ONLY SOURCE FOR THE DEFAULT DATE: the raw feed's own
    -- DEFAULT_DATE is 100% NULL on these books. Join on CASE_BK, not CASE_ID.
    LEFT JOIN PROD.NPL_COMMON.DIM_CASE AS dc
        ON  dc.case_bk = $source_system || '-' || c.loan_id
        AND dc.is_current_flag
    -- ⚠⚠ EXACT NAMES, NOT A SUBSTRING MATCH, AND THIS IS LOAD-BEARING. Elsa's
    -- G7 matches sellers with a regex alternation, which is safe for
    -- 'MILLENNIUM|WIZINK' but NOT here: 'GE MONEY BANK' CONTAINS the substring
    -- 'ONEY', so a substring match for Oney silently pulls in a second seller.
    -- ARRAY_CONTAINS on the full trimmed name cannot do that.
    -- ⚠ The ', ' -> ',' replace lets the list be written either way; without it
    -- a stray space makes SPLIT() yield ' COFIDIS', which never matches and the
    -- seller vanishes with no error.
    WHERE ($sellers = ''
           OR ARRAY_CONTAINS(b.seller::VARIANT, SPLIT(REPLACE($sellers, ', ', ','), ',')))
      AND ($deal_type = '' OR b.deal_type = $deal_type)
),

pam_side AS (
    SELECT
        seller,
        COUNT(*)                        AS batches,
        COUNT_IF(deal_type = 'One-off') AS one_off_batches,
        COUNT_IF(deal_type = 'Ongoing') AS ongoing_batches
    FROM batches
    WHERE ($sellers = ''
           OR ARRAY_CONTAINS(seller::VARIANT, SPLIT(REPLACE($sellers, ', ', ','), ',')))
      AND ($deal_type = '' OR deal_type = $deal_type)
    GROUP BY seller
),

loan_side AS (
    SELECT
        seller,
        COUNT(*)                                    AS loans,
        SUM(outstanding)                            AS outstanding,
        -- ⚠ COUNT(outstanding), NOT COUNT(*): a loan with no capital at all
        -- contributes nothing to the numerator, so including it in the
        -- denominator would quietly understate the average.
        DIV0(SUM(outstanding), COUNT(outstanding))  AS avg_outstanding_per_loan,
        -- ⚠ RATIO OF THE TOTALS, not an average of per-loan ratios. The two are
        -- different numbers; this is the book-level accrual share, which is what
        -- decides whether OUTSTANDING is comparable between two rows.
        DIV0(SUM(interest), NULLIF(SUM(capital), 0)) * 100 AS interest_pct_of_capital,
        AVG(debt_age_years)                         AS avg_debt_age_years,
        DIV0(COUNT(debt_age_years), COUNT(*)) * 100 AS debt_age_coverage_pct
    FROM loans
    GROUP BY seller
)

SELECT
    p.seller,
    -- ⚠ 'Mixed' IS NOT A ROUNDING CASE. WiZink is 129 Ongoing against 4
    -- One-off; Barclaycard 12 against 2. Read the two counts before treating
    -- such a seller as comparable with a pure one-off book.
    CASE
        WHEN p.ongoing_batches = 0 THEN 'One-off'
        WHEN p.one_off_batches = 0 THEN 'Forward flow'
        ELSE 'Mixed'
    END                               AS flow_type,
    p.batches,
    p.one_off_batches,
    p.ongoing_batches,
    COALESCE(l.loans, 0)              AS loans,          -- 0 = no cases in the loan feed
    COALESCE(l.outstanding, 0)        AS outstanding,    -- ORIGINAL_CAPITAL + ORIGINAL_INTEREST
    l.avg_outstanding_per_loan,
    l.interest_pct_of_capital,        -- ⚠ read before ranking two sellers on outstanding
    l.avg_debt_age_years,             -- years in default BEFORE Intrum opened the case
    l.debt_age_coverage_pct           -- ⚠ below 100% means rows were excluded, see header
FROM pam_side AS p
-- ⚠ LEFT, NEVER INNER: a seller whose batches hold no cases is a finding.
LEFT JOIN loan_side AS l
    ON l.seller = p.seller
ORDER BY loans DESC, p.seller;
