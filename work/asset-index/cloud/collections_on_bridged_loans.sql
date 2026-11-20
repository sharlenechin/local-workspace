-- ============================================================================
-- COLLECTIONS ON BRIDGED LOANS, ONE ROW PER PORTFOLIO.
-- Measured 2026-10-19: 7 portfolios bridged, 35,023 loans reach CAT, 3,925 of
-- them have any collection. SE25008 still has zero, a month after it was first
-- flagged in README.md.
-- Run: env SNOWFLAKE_WAREHOUSE=DEV_WH .venv/bin/python scripts/run_sql.py \
--        work/asset-index/cloud/collections_on_bridged_loans.sql --connection dev
-- ============================================================================
-- Grain: one row per bridged asset-index portfolio.
-- Why: matched to DIM_CASE is not the same as having collections. The README
-- (2026-09-22) found SE25008 matched 6,267 loans and had zero CAT collections.
WITH matched AS (
    -- Collapse to one row per CAT loan FIRST. The mapping is many-to-one, so
    -- joining collections to the raw bridge repeats them once per claimant.
    SELECT DISTINCT
        b.portfolio_id,
        dc.case_sk
    FROM dev.asset_index.case_bridge AS b
    INNER JOIN prod_npl_common.npl_common.dim_case AS dc
        ON dc.case_bk = b.system_code || '-' || b.servicer_case_id
        AND dc.is_current_flag = TRUE
),

collections AS (
    -- Upper-bounded on purpose: this fact carries collection dates in the year
    -- 4570, which drag MAX() and any recency window with them.
    SELECT
        case_sk,
        collection_date,
        amount
    FROM prod_npl_common.npl_common.fct_case_collection
    WHERE collection_date <= CURRENT_DATE()
)

SELECT
    m.portfolio_id,
    COUNT(DISTINCT m.case_sk) AS loans_in_cat,
    COUNT(DISTINCT c.case_sk) AS loans_with_collections,
    COUNT(c.case_sk) AS collection_rows,
    ROUND(SUM(c.amount), 5) AS collected_local_ccy,
    MIN(c.collection_date) AS first_collection,
    MAX(c.collection_date) AS last_collection
FROM matched AS m
LEFT JOIN collections AS c
    ON c.case_sk = m.case_sk
GROUP BY m.portfolio_id
ORDER BY loans_with_collections DESC;
