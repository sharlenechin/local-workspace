-- Grain: one row per deal id, for SE/PT/FI/GE.
-- The vehicle each deal sits under, so a deal id can be written as
-- <VEHICLE>-<DEALID> rather than bare. Measured 2026-10-22:
-- 1,652 deals, of which 1 (FI25001) sits under two vehicles.
--
-- Read the vehicle from DEAL_SOURCE_BK, never from which table the deal
-- appears in: DIM_BATCH holds Lokk deals too (all 7 German ones), so the
-- table is not a proxy for the vehicle.
WITH ours AS (
    SELECT
        b.servicer_parent_portfolio_bk AS deal,
        COALESCE(b.deal_source_bk, '(none)') AS vehicle
    FROM PROD_NPL_COMMON.NPL_COMMON.DIM_BATCH AS b
    WHERE LEFT(b.servicer_parent_portfolio_bk, 2) IN ('SE', 'PT', 'FI', 'GE')

    UNION

    SELECT
        SUBSTR(p.portfolio_bk, 5, 7) AS deal,
        COALESCE(d.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle
    FROM PROD_NPL_COMMON.NPL_COMMON.DIM_PORTFOLIO AS p
    LEFT JOIN PROD_NPL_COMMON.NPL_COMMON.DIM_DEAL AS d
        ON d.deal_id = p.deal_id
    WHERE SUBSTR(p.portfolio_bk, 5, 2) IN ('SE', 'PT', 'FI', 'GE')
)

-- A deal under two vehicles keeps both, joined, rather than silently
-- picking one.
SELECT
    deal,
    LISTAGG(DISTINCT vehicle, '/') WITHIN GROUP (ORDER BY vehicle) AS vehicle
FROM ours
GROUP BY deal
ORDER BY deal;
