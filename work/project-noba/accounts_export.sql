-- Project NOBA accounts: what we own, with the seller tape filled in where it reaches.
-- GRAIN   one row per loan_id (raw CAT case_id). CASE level, not borrower.
-- RUN     mise run sql -- work/project-noba/accounts_export.sql \
--             --connection dev --warehouse DEV_WH --lower
--         The warehouse has to be named: the workspace default NPL_ANALYST_WH exists on
--         brocc-prod only, and the asset index lives on brocc-sandbox.
-- PAIRS   payments_export.sql on (portfolio_id, loan_id).
-- BASE    raw Intrum CAT instances 1062 and 2080, scoped by the newest PAM file -- the
--         book we own. Both are read because Swedish books are split across them:
--         measured 2026-11-02, of 555 SE deals 285 are on 2080 alone, 4 on 1062 alone
--         and 266 on BOTH. CASE_ID is unique only within one instance, so the instance
--         is read off _file_path and carried into CASE_BK and into every dedupe key.
--         SE15044 and SE16025 are both 2080-only, so this changes nothing for them --
--         it makes the file safe to point at another Swedish deal.
--         The seller tape (ASSET_INDEX.APPROVED, brocc-sandbox) is LEFT joined onto it,
--         so a loan we own but the tape never covered is still a row, with the tape
--         columns null. The tape's case_id is <instance>-<CAT case id>, so it joins
--         directly: measured 2026-11-02, 100% of tape cases match. No bridge.
-- CONFIDENCE  the last three columns compare the two sources on the same loan.
--         SUM(IFF(principal_matches, 1, 0)) over the export is the coverage figure.
-- SCOPE  real_case_ind <> '1'. Against PAM, measured 2026-11-02 by reconciliation.sql:
--        principal 95.4% / 104.8% / 101.0% / 96.2% / 104.2% on five of six deals.
-- ⚠ A HIGH CASE COUNT IS NOT A WRONG BOOK. SE16025 holds 11,836 cases against 4,831
--   acquired, yet 104.8% of the principal -- the extra cases are near-zero-balance
--   fragments of acquired loans, so they inflate any per-case figure and almost no
--   money. Divide by PAM's acqcases, not by the rows here.
-- ⚠ SE25018 is over on both: 142% of cases and 151.6% of principal, with almost no
--   non-'R' cases, so the scope guard does not explain it. Open.
-- ⚠ SE15044 holds 87.2% of cases and 95.4% of principal -- short either way.
-- ⚠ CUSTOMER_TYPE FALLS BACK TO THE WAREHOUSE. The tape states it through its
--   counterparties, which are empty on both these runs, so every value here comes from
--   CAT's debtor feed. The COALESCE is kept so a later run that does carry
--   counterparties is preferred over the feed without the query changing. Measured
--   2026-11-02 it is individual on all but one loan of 10,024 -- almost no signal.
-- ⚠ CASE_PHASE, STATUTE_BARRED_DATE and ORIGINAL_INTEREST are 0% on both books.
--   ORIGINATION_DATE and SUB_PORTFOLIO are null in the tape. Nothing can fill them.
-- ⚠ CUTOFF_DATE IS 100% NULL ON SE16025. This file ships the column, and on SE15044 it
--   is 2015-12-15 on all 6,727 tape cases, but SE16025's 3,297 tape cases state no
--   cut-off at all. Measured 2026-11-03. Do not treat a null here as "same as the
--   acquisition date" -- the tape simply does not say.
-- ⚠ THE TWO TAPES ARE NOT THE SAME KIND OF FILE. A diligence tape is cut before the
--   sale; these are not cut at all, both running to October 2026. On SE15044 that is
--   cosmetic -- 57% of its 423,534 tape payments predate the Dec 2015 purchase, so it
--   does carry real pre-purchase history. On SE16025 only 1,176 of 57,781 (2%) do, so
--   it is a servicing extract and the book has almost NO pre-purchase behaviour to
--   learn from. Measured 2026-11-03.
-- ⚠ THE ACQUISITION DATE IS ACCURATE TO THE MONTH, NOT THE DAY. LEGACY_CAPEX_DATE is
--   month-grain -- 11,733 of the warehouse's 11,793 batches fall on the 1st (99.49%,
--   measured 2026-11-03) -- so 2015-12-01 means December 2015. That is why SE15044 can
--   look as though it was bought two weeks before its own tape cut-off: a cut-off
--   always precedes acquisition, and here it is the capex date that is rounded.

-- ⚠ STATE OF THE SIX DEALS, measured 2026-11-02. Every one is in PAM, but:
--   · FIVE of the six now have an approved asset-index run -- all but SE25018. Measured
--     2026-11-03, the share of the loans we own that the tape actually reaches is
--     SE19026 92.3%, SE25037 90.6%, SE15044 72.8%, SE16025 27.9%, and SE20009 0%:
--     SE20009 HAS a run, but none of its tape ids join to a CAT case, so its tape
--     columns come back NULL exactly as SE25018's do. A loan the tape never reached is
--     still a row -- the base is what we own, not what the seller sent.
--   · SIX DEALS, NOT EIGHT. SE25008 and SE25013 are OUR Atlas ids for two books Intrum
--     knows as SE25018 and SE25037, so listing all four would name two books twice.
--     Confirmed 2026-11-02: DIM_BATCH, which is keyed on the servicer's id, holds only
--     SE25018 (Santander Consumer Bank, capex 2025-06-01, 9,713 cases) and SE25037
--     (Norion Bank, 2025-12-01, 2,341 cases); SE25008 and SE25013 exist only in
--     DIM_PORTFOLIO, which is keyed on ours. CAT and PAM both go by the servicer's id,
--     so that is what this file asks for.
--   · SE19026, SE25018 and SE25037 span instances 1062 AND 2080; the rest are 2080 only.
SET deals      = 'SE15044,SE16025,SE19026,SE20009,SE25018,SE25037';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH
    deals_asked_for AS (

        SELECT
            TRIM(value::string) AS deal
        FROM TABLE(SPLIT_TO_TABLE($deals, ','))
        WHERE TRIM(value::string) <> ''
),

    batches AS (

        SELECT DISTINCT
            combined_ref
        FROM prod_raw.hyperion_intrum_pam.pam
        WHERE _file_path = (
                SELECT MAX(_file_path)
                FROM prod_raw.hyperion_intrum_pam.pam
                WHERE _file_path LIKE '%/pam.pam.pam.2%'
            )
            AND pmode_name = 'Real'
            AND COALESCE(is_ownership_change, 0) = 0
            AND portfolioid IN (SELECT deal FROM deals_asked_for)
),

-- The spine: one row per loan we own, its latest version across every extract.
    owned AS (

        SELECT
            LEFT(c.long_portfolio_id, 7) AS portfolio_id,
            PARSE_JSON(c._file_metadata):system::string AS source_system,
            c.case_id AS loan_id,
            PARSE_JSON(c._file_metadata):system::string
                || '-' || c.case_id AS case_bk,
            c.registration_date::date AS registration_date,
            c.original_capital,
            c.remaining_capital
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        -- C4/C5: literal prefixes, one per instance, so partition pruning still works.
        WHERE (c._file_path LIKE $raw_prefix || '1062.cases.%'
                OR c._file_path LIKE $raw_prefix || '2080.cases.%')
            -- C8: scope filter before the qualify, so a loan whose newest version left
            -- the scope keeps its last in-scope batch instead of vanishing.
            AND c.long_portfolio_id IN (SELECT combined_ref FROM batches)
            AND c.case_id NOT LIKE '%-%'                        -- C9: container cases
            -- Everything but '1'. real_case_ind = 'R' looks like the acquired case and
            -- fixes SE16025's count (245% -> 94.6%), but it costs principal where it
            -- matters: SE15044 drops to 78.4% of the principal we bought, against 95.4%
            -- here. Measured both ways 2026-11-02 with reconciliation.sql.
            AND COALESCE(c.real_case_ind, '') <> '1'
        -- C1: CASES is a change-history feed, deduped to its latest version. Partitioned
        -- by instance as well: case_id repeats across the two.
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY PARSE_JSON(c._file_metadata):system::string,
                c.case_id
            ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
        ) = 1
),

-- Newest approved run per deal. Not MAX(run_id): it is a UUID, so MAX is alphabetical.
-- The asset index does NOT file every book under the id CAT and PAM use. SE25018's tape
-- is filed under SE25008, our own Atlas id for the same Santander book; SE25037's is
-- filed under Intrum's number. Measured 2026-11-03: without this mapping SE25018 reports
-- "no seller tape" while its tape sits in the index, approved and unread.
    tape_alias AS (

        SELECT
            d.deal,
            COALESCE(a.index_id, d.deal) AS index_id
        FROM deals_asked_for AS d
        LEFT JOIN (
            SELECT 'SE25018' AS deal, 'SE25008' AS index_id
        ) AS a
            ON a.deal = d.deal
),

    latest_run AS (

        SELECT
            r.deal_key,
            t.deal AS portfolio_id,          -- mapped back to the id CAT and PAM use
            r.run_id,
            r.approved_at
        FROM asset_index.approved.runs AS r
        INNER JOIN tape_alias AS t
            ON t.index_id = r.portfolio_id
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY r.deal_key
            ORDER BY r.approved_at DESC
        ) = 1
),

    tape AS (

        SELECT
            r.deal_key,
            r.run_id,
            r.approved_at,
            c.case_id AS case_bk,
            c.cutoff_date,
            c.currency,
            c.principal_at_cutoff,
            c.legal_balance_at_cutoff,
            c.accrued_interest_at_cutoff,
            c.other_balances_at_cutoff,
            c.default_date,
            c.origination_date,
            c.product_type,
            c.sub_portfolio
        FROM latest_run AS r
        INNER JOIN asset_index.approved.cases AS c
            ON c._run_id = r.run_id
),

-- Stored as the strings 'true'/'false'; a loan with no row stays NULL, which means not
-- stated and is not the same as false. The only attribute these runs carry.
    restructuring AS (

        SELECT
            a.entity_id AS case_bk,
            a._run_id AS run_id,
            TRY_TO_BOOLEAN(MAX(a.value)) AS debt_restructuring_flag
        FROM asset_index.approved.attributes AS a
        INNER JOIN latest_run AS r
            ON r.run_id = a._run_id
        WHERE a.entity_type = 'case'
            AND a.attribute = 'debt_restructuring_flag'
        GROUP BY 1, 2
),

-- Customer type as the tape states it. Empty on these two runs, so it resolves to the
-- warehouse below; kept because a run that does carry counterparties should win.
    tape_customer_type AS (

        SELECT
            cc.case_id AS case_bk,
            cc._run_id AS run_id,
            MAX(cp.counterparty_type) AS customer_type
        FROM latest_run AS r
        INNER JOIN asset_index.approved.case_counterparty AS cc
            ON cc._run_id = r.run_id
        INNER JOIN asset_index.approved.counterparties AS cp
            ON cp._run_id = cc._run_id
            AND cp.counterparty_id = cc.counterparty_id
        GROUP BY 1, 2
),

-- Customer type from the debtor feed: 'C' is a company, 'P' a private individual. No
-- row_number -- update timestamps tie at the latest version, so picking one row makes
-- the type flip between runs. Every tied row is kept and the flags OR-ed. It is NOT a
-- size class: the feed carries no turnover, headcount or VAT, so it cannot say SME.
    warehouse_customer_type AS (

        SELECT
            d.case_bk,
            CASE
                WHEN MAX(IFF(d.type = 'C', 1, 0)) = 1 THEN 'company'
                WHEN MAX(IFF(d.type = 'P', 1, 0)) = 1 THEN 'individual'
            END AS customer_type
        FROM (
            SELECT
                PARSE_JSON(b._file_metadata):system::string
                    || '-' || b.case_id AS case_bk,
                b.type,
                COALESCE(b.record_updated, b.update_ts)::timestamp AS ts,
                MAX(COALESCE(b.record_updated, b.update_ts)::timestamp) OVER (
                    PARTITION BY b._file_path, b.case_id, b.debtor_row_number
                ) AS max_ts
            FROM prod_raw.hyperion_intrum_cat.debtors AS b
            WHERE (b._file_path LIKE $raw_prefix || '1062.debtors.%'
                    OR b._file_path LIKE $raw_prefix || '2080.debtors.%')
                AND COALESCE(b.deleted, 0) = 0
                AND COALESCE(b.archived, 0) = 0
                AND COALESCE(b.unlinked, 0) = 0
        ) AS d
        WHERE d.ts = d.max_ts
        GROUP BY 1
),

-- The comparator for the date check. Raw CAT does not populate a default date on this
-- instance, so DIM_CASE is the only one; it is not emitted, only compared against.
    warehouse_default AS (

        SELECT
            d.case_bk,
            d.default_date AS warehouse_default_date
        FROM prod_npl_common.npl_common.dim_case AS d
        WHERE d.is_current_flag
            AND (d.case_bk LIKE '1062-%' OR d.case_bk LIKE '2080-%')
),

    acquisition AS (

        SELECT
            b.servicer_parent_portfolio_bk AS portfolio_id,
            MIN(b.legacy_capex_date) AS acquisition_date,
            MAX(b.legal_seller_name) AS seller_name
        FROM prod_npl_common.npl_common.dim_batch AS b
        WHERE b.servicer_parent_portfolio_bk IN (SELECT deal FROM deals_asked_for)
        GROUP BY 1
)

SELECT
    COALESCE(t.deal_key, 'HEI-' || o.portfolio_id) AS deal_key,
    o.portfolio_id,
    o.source_system,
    o.loan_id,
    a.seller_name,
    a.acquisition_date,
    -- From CAT: the servicer's own book.
    o.registration_date,
    o.original_capital,
    o.remaining_capital,
    -- From the seller tape, null on a loan it never covered.
    t.cutoff_date,
    t.currency,
    t.principal_at_cutoff,
    t.legal_balance_at_cutoff,
    t.accrued_interest_at_cutoff,
    t.other_balances_at_cutoff,
    t.default_date,
    t.origination_date,
    t.product_type,
    t.sub_portfolio,
    -- The tape's own word where it has one, the servicer's feed otherwise.
    COALESCE(tc.customer_type, wc.customer_type) AS customer_type,
    s.debt_restructuring_flag,
    t.run_id,
    t.approved_at AS run_approved_at,
    -- Confidence: the two sources on the same loan. FALSE rather than NULL where the
    -- tape is absent, so the column sums to a count without a COALESCE at the call site.
    COALESCE(ABS(t.principal_at_cutoff - o.original_capital) <= 0.01, FALSE)
        AS principal_matches,
    COALESCE(t.default_date = w.warehouse_default_date, FALSE) AS default_date_matches,
    CASE
        WHEN t.case_bk IS NULL THEN 'Not in the seller tape'
        WHEN ABS(t.principal_at_cutoff - o.original_capital) <= 0.01
            AND t.default_date = w.warehouse_default_date THEN 'Confirmed - money and date'
        WHEN ABS(t.principal_at_cutoff - o.original_capital) <= 0.01 THEN 'Confirmed - money'
        WHEN t.default_date = w.warehouse_default_date THEN 'Confirmed - date'
        -- A tape figure ABOVE the servicer's cannot come from holding part of a loan.
        WHEN t.principal_at_cutoff > o.original_capital * 1.01 THEN 'Suspect - tape above CAT'
        ELSE 'Differs'
    END AS match_confidence
FROM owned AS o
LEFT JOIN tape AS t
    ON t.case_bk = o.case_bk
LEFT JOIN restructuring AS s
    ON s.case_bk = o.case_bk
    AND s.run_id = t.run_id
LEFT JOIN tape_customer_type AS tc
    ON tc.case_bk = o.case_bk
    AND tc.run_id = t.run_id
LEFT JOIN warehouse_customer_type AS wc
    ON wc.case_bk = o.case_bk
LEFT JOIN warehouse_default AS w
    ON w.case_bk = o.case_bk
LEFT JOIN acquisition AS a
    ON a.portfolio_id = o.portfolio_id
ORDER BY 2, 3;
