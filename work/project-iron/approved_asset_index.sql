-- ============================================================================
-- WHAT IS APPROVED IN THE ASSET INDEX, AND HOW MUCH OF IT
--
-- One row per deal. Measured 2026-10-26.
--
-- ⚠ EVERY APPROVED VERSION IS KEPT. A deal re-approved after a re-run has more
--   than one row in `runs`, and its old rows are STILL in cases / payments /
--   attributes. Filter to the latest run_id per deal or every figure doubles.
--   That is what `latest` does below; never query the fact tables without it.
-- ============================================================================
WITH latest AS (
    SELECT
        deal_key,
        portfolio_id,
        run_id,
        approved_at
    FROM asset_index.approved.runs
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY deal_key ORDER BY approved_at DESC
    ) = 1
)

SELECT
    l.deal_key,
    l.approved_at::date AS approved,
    COUNT(DISTINCT c.case_id) AS loans,
    COUNT(DISTINCT cc.counterparty_id) AS counterparties,
    ROUND(SUM(c.legal_balance_at_cutoff), 2) AS legal_balance,
    ROUND(SUM(c.principal_at_cutoff), 2) AS principal,
    MIN(c.cutoff_date) AS cutoff_date,
    MIN(c.default_date) AS earliest_default,
    MAX(c.default_date) AS latest_default
FROM latest AS l
INNER JOIN asset_index.approved.cases AS c
    ON c._run_id = l.run_id
LEFT JOIN asset_index.approved.case_counterparty AS cc
    ON cc._run_id = l.run_id
    AND cc.case_id = c.case_id
GROUP BY l.deal_key, l.approved_at
ORDER BY l.deal_key;
