-- ============================================================================
-- DOES THIS DEAL EXIST IN THE WAREHOUSE, AND WHAT IS IT?
--
-- One row per (deal, source). Returns the vehicle, seller, flow type and the
-- folder name a delivery for that deal should be sorted into.
--
-- To use: put your deal ids in CANDIDATES below and run. Nothing else to edit.
--
-- Written for PROD. On brocc-sandbox the database is a share, so swap
--   PROD.NPL_COMMON   ->   PROD_NPL_COMMON.NPL_COMMON
-- ============================================================================
--
-- WHY TWO SOURCES
--   DIM_BATCH      keyed on SERVICER_PARENT_PORTFOLIO_BK, the servicer's own
--                  parent id. A high batch count means a forward flow.
--   DIM_PORTFOLIO  keyed on the Atlas id inside PORTFOLIO_BK, which is shaped
--                  '<deal_bk>-U01/2512' -- so the deal id is SUBSTR(.,5,7) and
--                  deal_bk is LEFT(.,11). A high segment count means a flow.
--
--   RUN BOTH. Plenty of deals are in one and not the other: SE25008 and
--   SE25013 return nothing from DIM_BATCH and are real DIM_PORTFOLIO deals.
--   Checking only the first silently drops live books.
--
-- THREE THINGS THAT WILL BITE
--   1. Do not hardcode the vehicle. DIM_BATCH.DEAL_SOURCE_BK is 'HEI' on
--      11,485 batches but 'LOK' on 248, 'LEG' on 60 and 'GCB' on 10, with 5
--      nulls. SE25008 and SE25037 are LOK, not HEI.
--   2. Seller sits in a different column per source: LEGAL_SELLER_NAME on
--      DIM_BATCH, SELLER_NAME on DIM_DEAL. DIM_PORTFOLIO has neither seller
--      nor vehicle of its own, hence the join.
--   3. Flow type is spelled differently per source and is normalised here:
--      DIM_BATCH says 'Ongoing', DIM_PORTFOLIO says 'Forward'. Same thing.
--
-- READING THE RESULT
--   FOUND in both sources      normal; the two rows should agree on vehicle
--   two sellers for one deal   also normal -- IT24013 is 'Gruppo Banca Popolare
--                              dell'Emilia Romagna' in one and 'BPER Banca' in
--                              the other. Do not group on seller across sources.
--   NOT FOUND                  the warehouse has no such deal id. That is not
--                              proof we do not own it: our id and the
--                              servicer's can differ (our SE25008 is Intrum's
--                              SE25018). Check the seller by name before
--                              concluding anything.
-- ============================================================================
WITH candidates AS (
    -- The ids the example delivery in raw/ produces. Replace with your own.
    SELECT column1 AS deal FROM VALUES
        ('PT15018'),
        ('PT16023'),
        ('SE16004'),
        ('SE25008'),
        ('SE25016')
),

batch_dim AS (
    SELECT
        b.servicer_parent_portfolio_bk AS deal,
        COALESCE(b.deal_source_bk, '(no vehicle)') AS vehicle,
        MAX(b.legal_seller_name) AS seller,
        CASE
            WHEN MAX(b.deal_type) = 'Ongoing' THEN 'Forward'
            ELSE MAX(b.deal_type)
        END AS flow_type,
        COUNT(DISTINCT b.batch_bk) AS unit_count,
        SUM(b.legacy_case_count) AS cases
    FROM PROD.NPL_COMMON.DIM_BATCH AS b
    WHERE b.servicer_parent_portfolio_bk IN (SELECT deal FROM candidates)
    GROUP BY b.servicer_parent_portfolio_bk, b.deal_source_bk
),

portfolio_dim AS (
    SELECT
        SUBSTR(p.portfolio_bk, 5, 7) AS deal,
        COALESCE(d.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle,
        MAX(d.seller_name) AS seller,
        MAX(p.flow_type) AS flow_type,
        COUNT(DISTINCT p.segment_sk) AS unit_count,
        NULL AS cases
    FROM PROD.NPL_COMMON.DIM_PORTFOLIO AS p
    LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS d
        ON d.deal_id = p.deal_id
    WHERE SUBSTR(p.portfolio_bk, 5, 7) IN (SELECT deal FROM candidates)
    GROUP BY
        SUBSTR(p.portfolio_bk, 5, 7),
        COALESCE(d.deal_source_bk, LEFT(p.portfolio_bk, 3))
),

found AS (
    SELECT 'DIM_BATCH' AS source, deal, vehicle, seller, flow_type, unit_count, cases
    FROM batch_dim
    UNION ALL
    SELECT 'DIM_PORTFOLIO', deal, vehicle, seller, flow_type, unit_count, cases
    FROM portfolio_dim
)

SELECT
    c.deal,
    f.source,
    f.vehicle,
    f.vehicle || '-' || c.deal AS sort_folder,
    f.seller,
    f.flow_type,
    f.unit_count,                                  -- batches, or segments
    f.cases,                                       -- DIM_BATCH only
    CASE WHEN f.deal IS NULL THEN 'NOT FOUND' ELSE 'FOUND' END AS verdict
FROM candidates AS c
LEFT JOIN found AS f
    ON f.deal = c.deal
ORDER BY verdict, c.deal, f.source;
