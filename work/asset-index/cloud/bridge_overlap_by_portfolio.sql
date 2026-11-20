-- ============================================================================
-- BRIDGE AND OVERLAP, ONE ROW PER ASSET-INDEX PORTFOLIO. Two questions:
--   1. how does this portfolio connect to NPL_COMMON, and how well?
--   2. do its pre-acquisition payments overlap NPL_COMMON's, and if so by how
--      much do the two disagree?
-- ============================================================================
-- ⚠⚠ SANDBOX, NOT PROD. Run with the `dev` profile -- see README.md.
--
-- THIS IS THE STANDING CHECK BEHIND benchmark_case_payments_monthly.sql. That
-- dataset's rule is "asset index wins where both have a month". The rule only
-- matters if both ever do. Today neither side shares a single case-month with
-- the other, so the rule is dormant -- run this after any reload to find out
-- whether it has woken up.
--
-- ⚠⚠ ALL 23 ASSET-INDEX PORTFOLIOS APPEAR, including the 19 with no bridge at
-- all. Showing only the connected ones would hide that 245,602 of 278,932
-- cases cannot be connected. A portfolio with BRIDGE_ROWS = 0 is not a failed
-- match, it is a book nobody has mapped yet.
--
-- ⚠⚠ THE OVERLAP COLUMNS ARE COMPARED IN LOCAL CURRENCY AND NEVER CONVERTED.
-- Both sides of a given loan are in that book's own currency, so the
-- comparison is like-for-like; the DIFFERENCE column is not addable across
-- portfolios.
--
-- ⚠ THE GAP IS THE FINDING, NOT THE OVERLAP. Measured 2026-09-22 the two
-- sources are disjoint, and between them sits a hole of 2 to 5 months where
-- neither reports. GAP_MONTHS counts it. A cumulative curve drawn across that
-- hole reads as a collapse that did not happen.
-- ============================================================================
WITH case_bridge AS (
    -- Every bridge row, matched or not, with the CAT key where it resolves.
    SELECT
        b.portfolio_id,
        b.case_id,
        b.servicer,
        b.system_code,
        b.match_status,
        dc.case_sk
    FROM DEV.ASSET_INDEX.CASE_BRIDGE AS b
    LEFT JOIN PROD_NPL_COMMON.NPL_COMMON.DIM_CASE AS dc
        ON dc.case_bk = b.system_code || '-' || b.servicer_case_id
        AND dc.is_current_flag = TRUE
),

case_scope AS (
    -- ⚠ ONE ROW PER CASE_SK, so the NPL_COMMON reads below cannot fan out.
    SELECT
        case_sk,
        ANY_VALUE(portfolio_id)                            AS portfolio_id,
        COUNT(*)                                           AS asset_index_case_count
    FROM case_bridge
    WHERE case_sk IS NOT NULL
    GROUP BY 1
),

bridge_shape AS (
    -- How this portfolio connects: which servicer system, and how far the
    -- mapping got. LISTAGG so one row can show a book spanning two systems.
    SELECT
        portfolio_id,
        COUNT(*)                                           AS bridge_rows,
        COUNT_IF(case_sk IS NOT NULL)                      AS matched_rows,
        COUNT(DISTINCT case_sk)                            AS distinct_case_sk,
        LISTAGG(DISTINCT system_code, ' + ')
            WITHIN GROUP (ORDER BY system_code)            AS system_codes,
        LISTAGG(DISTINCT servicer, ' + ')
            WITHIN GROUP (ORDER BY servicer)               AS servicers,
        LISTAGG(DISTINCT match_status, ' + ')
            WITHIN GROUP (ORDER BY match_status)           AS match_statuses
    FROM case_bridge
    GROUP BY 1
),

asset_index_months AS (
    -- The seller's side, at the grain the comparison needs.
    SELECT
        b.case_sk,
        DATE_TRUNC('MONTH', TRY_TO_DATE(p.payment_date))::DATE AS payment_month,
        SUM(p.payment_amount)                              AS payment_amount
    FROM DEV.ASSET_INDEX.PAYMENTS AS p
    INNER JOIN case_bridge AS b
        ON b.portfolio_id = p.portfolio_id
        AND b.case_id = p.case_id
    WHERE b.case_sk IS NOT NULL
      AND TRY_TO_DATE(p.payment_date) IS NOT NULL
    GROUP BY 1, 2
),

cat_months AS (
    SELECT
        c.case_sk,
        DATE_TRUNC('MONTH', c.collection_date)::DATE       AS payment_month,
        SUM(c.amount)                                      AS payment_amount
    FROM PROD_NPL_COMMON.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN case_scope AS s
        ON s.case_sk = c.case_sk
    -- ⚠ Collection dates in the year 4570 exist in this warehouse. Bound it.
    WHERE c.collection_date <= CURRENT_DATE()
    GROUP BY 1, 2
),

asset_index_shape AS (
    SELECT
        s.portfolio_id,
        COUNT(*)                                           AS asset_index_case_months,
        SUM(a.payment_amount)                              AS asset_index_amount,
        MIN(a.payment_month)                               AS asset_index_first_month,
        MAX(a.payment_month)                               AS asset_index_last_month
    FROM asset_index_months AS a
    INNER JOIN case_scope AS s
        ON s.case_sk = a.case_sk
    GROUP BY 1
),

cat_shape AS (
    SELECT
        s.portfolio_id,
        COUNT(*)                                           AS npl_common_case_months,
        SUM(c.payment_amount)                              AS npl_common_amount,
        MIN(c.payment_month)                               AS npl_common_first_month,
        MAX(c.payment_month)                               AS npl_common_last_month
    FROM cat_months AS c
    INNER JOIN case_scope AS s
        ON s.case_sk = c.case_sk
    GROUP BY 1
),

overlap AS (
    -- ⚠⚠ THE QUESTION THIS FILE EXISTS FOR. A case-month both sources report.
    -- INNER JOIN on (case_sk, payment_month): only rows in both survive.
    SELECT
        s.portfolio_id,
        COUNT(*)                                           AS overlapping_case_months,
        SUM(a.payment_amount)                              AS overlap_asset_index_amount,
        SUM(c.payment_amount)                              AS overlap_npl_common_amount,
        SUM(a.payment_amount - c.payment_amount)           AS overlap_difference,
        SUM(ABS(a.payment_amount - c.payment_amount))      AS overlap_absolute_difference,
        COUNT_IF(ABS(a.payment_amount - c.payment_amount) < 0.01)
                                                           AS overlap_identical_case_months,
        MIN(a.payment_month)                               AS overlap_first_month,
        MAX(a.payment_month)                               AS overlap_last_month
    FROM asset_index_months AS a
    INNER JOIN cat_months AS c
        ON c.case_sk = a.case_sk
        AND c.payment_month = a.payment_month
    INNER JOIN case_scope AS s
        ON s.case_sk = a.case_sk
    GROUP BY 1
)

SELECT
    -- ---- the portfolio ----------------------------------------------------
    pf.portfolio_id,
    pf.seller,
    pf.country,
    pf.currency,

    -- ---- how it connects to NPL_COMMON ------------------------------------
    -- ⚠ 0 BRIDGE ROWS IS AN ABSENCE, NOT A FAILURE. 19 of 23 books are here.
    COALESCE(bs.bridge_rows, 0)                            AS bridge_rows,
    COALESCE(bs.matched_rows, 0)                           AS matched_rows,
    COALESCE(bs.distinct_case_sk, 0)                       AS distinct_case_sk,
    -- ⚠ BELOW MATCHED_ROWS MEANS SEVERAL ASSET-INDEX CASES SHARE ONE CAT LOAN.
    COALESCE(bs.matched_rows, 0) - COALESCE(bs.distinct_case_sk, 0)
                                                           AS surplus_case_rows,
    ROUND(100.0 * bs.matched_rows / NULLIF(bs.bridge_rows, 0), 2)
                                                           AS matched_pct,
    bs.system_codes,
    bs.servicers,
    bs.match_statuses,

    -- ---- what each side reports -------------------------------------------
    COALESCE(ais.asset_index_case_months, 0)               AS asset_index_case_months,
    ais.asset_index_amount,
    ais.asset_index_first_month,
    ais.asset_index_last_month,
    COALESCE(cs.npl_common_case_months, 0)                 AS npl_common_case_months,
    cs.npl_common_amount,
    cs.npl_common_first_month,
    cs.npl_common_last_month,

    -- ---- ⚠ THE HOLE BETWEEN THEM. Months neither source reports. ----------
    -- NULL where one side is missing entirely, because a gap needs two edges.
    GREATEST(
        DATEDIFF('MONTH', ais.asset_index_last_month, cs.npl_common_first_month) - 1,
        0)                                                 AS gap_months,

    -- ---- ⚠⚠ DO THEY OVERLAP, AND BY HOW MUCH DO THEY DISAGREE? -----------
    COALESCE(ov.overlapping_case_months, 0)                AS overlapping_case_months,
    ov.overlap_asset_index_amount,
    ov.overlap_npl_common_amount,
    -- Positive = the seller reported MORE than our servicer did.
    ov.overlap_difference,
    ov.overlap_absolute_difference,
    ROUND(100.0 * ov.overlap_absolute_difference
          / NULLIF(ABS(ov.overlap_asset_index_amount), 0), 2)
                                                           AS overlap_absolute_difference_pct,
    ov.overlap_identical_case_months,
    ov.overlap_first_month,
    ov.overlap_last_month,

    -- ---- flags -------------------------------------------------------------
    COALESCE(bs.matched_rows, 0) > 0                       AS is_bridged_flag,
    COALESCE(cs.npl_common_case_months, 0) > 0             AS has_npl_common_flag,
    -- ⚠ FALSE means the two sources are disjoint and the "asset index wins"
    -- rule in the benchmark dataset is dormant for this book.
    COALESCE(ov.overlapping_case_months, 0) > 0            AS has_overlap_flag
FROM DEV.ASSET_INDEX.PORTFOLIO AS pf
LEFT JOIN bridge_shape AS bs
    ON bs.portfolio_id = pf.portfolio_id
LEFT JOIN asset_index_shape AS ais
    ON ais.portfolio_id = pf.portfolio_id
LEFT JOIN cat_shape AS cs
    ON cs.portfolio_id = pf.portfolio_id
LEFT JOIN overlap AS ov
    ON ov.portfolio_id = pf.portfolio_id
