-- ============================================================================
-- BRIDGE COVERAGE, ONE ROW PER ASSET-INDEX PORTFOLIO.
-- Answers: how many approved deals are there, and how many of their loans can
-- be tied to NPL_COMMON (DIM_CASE) at all?
-- ============================================================================
-- ⚠⚠ SANDBOX, NOT PROD. Run with the `dev` profile -- see README.md.
--
-- ⚠⚠ mise pins SNOWFLAKE_WAREHOUSE=NPL_ANALYST_WH, which does not exist in
-- brocc-sandbox, and mise re-applies it inside `uv run`. Bypass both:
--     env SNOWFLAKE_WAREHOUSE=DEV_WH .venv/bin/python \
--         scripts/run_sql.py work/asset-index/cloud/bridge_coverage_by_portfolio.sql \
--         --connection dev
--
-- This is the fast half of bridge_overlap_by_portfolio.sql: coverage only, no
-- collection amounts, so it does not touch the 134m-row collection fact and
-- returns in seconds rather than timing out.
--
-- ⚠ ALL 23 PORTFOLIOS APPEAR, including those with no bridge row. A portfolio
-- with bridge_rows = 0 is not a failed match -- it is a book nobody has mapped.
--
-- ⚠ matched_rows COUNTS BRIDGE ROWS, distinct_case_sk COUNTS LOANS. They differ
-- because the mapping is many-to-one: several asset-index cases can claim one
-- CAT loan. Join a collection fact to the bridge without collapsing to case_sk
-- first and those collections repeat once per claimant.
--
-- Measured 2026-09-21 (README): 33,330 bridge rows, 21,066 matched, 4 of 23
-- portfolios bridged. CASE_BRIDGE has since grown to 54,282 rows
-- (last_altered 2026-10-05), so re-measure rather than quoting those.
-- ============================================================================
WITH case_counts AS (
    SELECT
        portfolio_id,
        COUNT(*) AS cases
    FROM dev.asset_index.cases
    GROUP BY portfolio_id
),

bridge AS (
    -- Every bridge row, matched or not. CAT's CASE_BK is system_code and
    -- servicer_case_id glued together; rows with a NULL system_code build a
    -- NULL key and can never hit, which is why they stay visible here.
    SELECT
        b.portfolio_id,
        b.match_status,
        dc.case_sk
    FROM dev.asset_index.case_bridge AS b
    -- DIM_CASE is a slowly-changing dimension: without is_current_flag you get
    -- one row per historical version and every count multiplies.
    LEFT JOIN prod_npl_common.npl_common.dim_case AS dc
        ON dc.case_bk = b.system_code || '-' || b.servicer_case_id
        AND dc.is_current_flag = TRUE
    GROUP BY b.portfolio_id, b.match_status, dc.case_sk
),

bridge_counts AS (
    SELECT
        portfolio_id,
        COUNT(*) AS bridge_rows,
        COUNT(case_sk) AS matched_rows,
        COUNT(DISTINCT case_sk) AS distinct_case_sk
    FROM bridge
    GROUP BY portfolio_id
)

SELECT
    p.portfolio_id,
    p.country,
    p.currency,
    p.seller,
    p.product,
    COALESCE(cc.cases, 0) AS cases,
    COALESCE(bc.bridge_rows, 0) AS bridge_rows,
    COALESCE(bc.matched_rows, 0) AS matched_rows,
    COALESCE(bc.distinct_case_sk, 0) AS loans_in_cat
FROM dev.asset_index.portfolio AS p
LEFT JOIN case_counts AS cc
    ON cc.portfolio_id = p.portfolio_id
LEFT JOIN bridge_counts AS bc
    ON bc.portfolio_id = p.portfolio_id
ORDER BY loans_in_cat DESC, p.portfolio_id;
