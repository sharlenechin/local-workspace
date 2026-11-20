-- ============================================================================
-- CLIENT_REF MATCH FEASIBILITY, ONE ROW PER ASSET-INDEX PORTFOLIO.
-- Measured 2026-10-19. The route that bridges the German books with no
-- servicer file: DE25010 scores 8,871 here, exactly its existing bridged loan
-- count, so this reproduces the bridge rather than approximating it.
-- Actionable: UK24020 1,617 on ref_1 (64%), UK26004 1,060 on ref_2 (90%) --
-- both currently unbridged. Note UK26004 needs client_ref_2, not _1.
-- Everything else scores under 4% and is not a viable route.
-- Run: env SNOWFLAKE_WAREHOUSE=DEV_WH .venv/bin/python scripts/run_sql.py \
--        work/asset-index/cloud/clientref_match_feasibility.sql --connection dev
-- ============================================================================
-- Grain: one row per asset-index portfolio.
-- Why: the Portuguese bridge matched on raw CAT client_ref_1. Test both
-- client_ref columns against every book's case_id, to see which unbridged
-- portfolios could be bridged with no new servicer file.
-- ⚠ HYPERION_INTRUM_CAT.CASES is a change-history feed (~147 rows per case),
-- so match against DISTINCT reference values, never the raw rows.
WITH ref1 AS (
    SELECT DISTINCT client_ref_1 AS ref FROM prod_raw.hyperion_intrum_cat.cases
    WHERE client_ref_1 IS NOT NULL
),

ref2 AS (
    SELECT DISTINCT client_ref_2 AS ref FROM prod_raw.hyperion_intrum_cat.cases
    WHERE client_ref_2 IS NOT NULL
),

ai AS (
    SELECT DISTINCT portfolio_id, case_id FROM dev.asset_index.cases
)

SELECT
    ai.portfolio_id,
    COUNT(*) AS ai_cases,
    COUNT(r1.ref) AS hits_client_ref_1,
    COUNT(r2.ref) AS hits_client_ref_2,
    ROUND(100 * COUNT(r1.ref) / NULLIF(COUNT(*), 0), 2) AS pct_ref1,
    ROUND(100 * COUNT(r2.ref) / NULLIF(COUNT(*), 0), 2) AS pct_ref2
FROM ai
LEFT JOIN ref1 AS r1 ON r1.ref = ai.case_id
LEFT JOIN ref2 AS r2 ON r2.ref = ai.case_id
GROUP BY ai.portfolio_id
ORDER BY hits_client_ref_1 DESC, hits_client_ref_2 DESC;
