-- Every deal id Brocc holds, in either dimension table.
-- GRAIN  one row per deal id.
-- USED BY summarise_sorted.py, to say whether a sorted/ folder whose deal is not in
--        PAM is still a deal we own ("In warehouse").
--
-- Both tables, because plenty of deals are in one and not the other -- the same
-- two sources pam_overlay.sql reads the vehicle from.
--
-- Written for the brocc-sandbox share. On PROD swap
--   PROD_NPL_COMMON.NPL_COMMON   ->   PROD.NPL_COMMON
SELECT DISTINCT servicer_parent_portfolio_bk AS deal
FROM PROD_NPL_COMMON.NPL_COMMON.DIM_BATCH
WHERE servicer_parent_portfolio_bk IS NOT NULL

UNION

SELECT DISTINCT SUBSTR(portfolio_bk, 5, 7) AS deal
FROM PROD_NPL_COMMON.NPL_COMMON.DIM_PORTFOLIO;
