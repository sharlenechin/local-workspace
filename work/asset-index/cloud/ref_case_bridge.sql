-- ============================================================================
-- Asset-index case -> CAT case mapping. ONE ROW PER (PORTFOLIO_ID, CASE_ID)
-- that the bridge knows about. 33,330 rows, of which 21,066 reach CAT.
-- ============================================================================
-- ⚠⚠ THIS READS THE SANDBOX, NOT PROD. Run it with the `dev` profile
-- (brocc-sandbox / DEVELOPER / DEV_WH). See README.md -- `mise run sql` pins
-- SNOWFLAKE_CONNECTION=prod and will silently send this to the wrong account.
--
-- CAT lives in the sandbox as the share PROD_NPL_COMMON, not as PROD.
--
-- ⚠⚠ THE BRIDGE COVERS 4 OF 23 PORTFOLIOS. Measured 2026-09-21:
--   DE25020  Santander Consumer Bank  Germany      12,685 cases,  8,903 matched
--   SE25008  Santander Consumer Bank  Sweden       12,160 cases,  6,267 matched
--   CH25007  Cembra Money Bank AG     Switzerland   4,439 cases,  3,064 matched
--   ES25021  Norwegian bank           Spain         4,046 cases,  2,832 matched
-- The other 19 portfolios (245,602 cases) have no bridge row at all and can
-- never be tied to CAT through this path.
--
-- ⚠⚠ MATCH_STATUS IS THE GATE, NOT THE JOIN. 12,233 bridge rows are
-- 'not_in_mapping' and 31 'interim_dropout'; both carry a NULL system_code, so
-- the CASE_BK they would build is NULL and the join can never hit. Every one of
-- the 21,066 'matched' rows resolves -- the join is clean where it applies.
--
-- ⚠⚠ THE MAPPING IS MANY-TO-ONE, NOT ONE-TO-ONE. The 21,066 matched rows
-- resolve to only 20,456 distinct CASE_SK: 569 CAT cases are claimed by more
-- than one asset-index case, one of them by 7. Anything that joins CAT's own
-- facts through this bridge MUST collapse to CASE_SK first or it multiplies
-- that case's money. CASE_SK_SHARE_COUNT below says how many claim each one.
-- Measured 2026-09-21.
--
-- ⚠ DIM_CASE IS AN SCD. Without IS_CURRENT_FLAG this returns one row per
-- historical version of the case and every downstream sum multiplies.
--
-- ⚠ CASE_BK IS BUILT, NOT STORED: system_code || '-' || servicer_case_id. That
-- construction comes from the engineer who built the asset index; if CAT ever
-- changes how CASE_BK is formed this query goes silently to zero matches.
-- Verified unique: 33,330 bridge rows, 33,330 (portfolio_id, case_id) pairs.
-- ============================================================================
SELECT
    b.portfolio_id,
    b.case_id,
    b.servicer,
    b.servicer_case_id,
    b.system_code,
    b.match_status,

    -- ---- CAT keys. NULL wherever the bridge could not match. --------------
    dc.case_sk,
    dc.case_bk,

    -- ⚠ TRUE only where this asset-index case can be followed into CAT. Filter
    -- on it before any comparison of pre- and post-acquisition cash.
    dc.case_sk IS NOT NULL                                 AS is_mapped_to_cat_flag,
    -- ⚠ HOW MANY ASSET-INDEX CASES POINT AT THIS SAME CAT CASE. 1 is the happy
    -- path; above 1 means CAT's figures for it cannot be attributed to a single
    -- asset-index case, and summing them per case_id double-counts.
    COUNT(*) OVER (PARTITION BY dc.case_sk)                AS case_sk_share_count
FROM DEV.ASSET_INDEX.CASE_BRIDGE AS b
LEFT JOIN PROD_NPL_COMMON.NPL_COMMON.DIM_CASE AS dc
    ON dc.case_bk = b.system_code || '-' || b.servicer_case_id
    AND dc.is_current_flag = TRUE
