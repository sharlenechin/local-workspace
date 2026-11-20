-- ============================================================================
-- PORTUGUESE BOOKS IN RAW INTRUM CAT -- one row per deal per seller.
-- Why: long_portfolio_id splits a book into monthly sub-batches (186 of them
-- for Portugal), so the deal only becomes legible once rolled up to the PTnnnnn
-- stem. PORTFOLIO_SELLERS_NAME is the only name column populated here --
-- REAL_CLIENT_NAME and PORTFOLIO_NAME are NULL throughout.
-- ⚠ CAT CASES is a change-history feed (~147 rows per case); COUNT DISTINCT the
-- case id, never the rows.
-- Run: env SNOWFLAKE_WAREHOUSE=DEV_WH .venv/bin/python scripts/run_sql.py \
--        work/asset-index/cloud/pt_portfolios_in_cat.sql --connection dev
-- ============================================================================
SELECT
    REGEXP_SUBSTR(long_portfolio_id, '^PT[0-9]{5}') AS deal,
    MAX(portfolio_sellers_name) AS seller,
    COUNT(DISTINCT case_id) AS cases,
    COUNT(DISTINCT long_portfolio_id) AS sub_batches,
    COUNT(DISTINCT short_portfolio_id) AS short_ids
FROM prod_raw.hyperion_intrum_cat.cases
WHERE long_portfolio_id ILIKE 'PT%'
    AND REGEXP_SUBSTR(long_portfolio_id, '^PT[0-9]{5}') IS NOT NULL
GROUP BY deal
ORDER BY cases DESC;
