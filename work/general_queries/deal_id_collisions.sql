-- Ids that name more than one of our deals: an Intrum id (DIM_BATCH) that is also another
-- deal's Atlas id (DIM_PORTFOLIO), or one Intrum id behind two of our deals. A delivery
-- file or row carrying such an id cannot say on its own which deal it belongs to, and
-- asset-index-cloud's deal-sort resolves it by rule (see docs/sorting-a-delivery.md).
--
--   RUN    mise run sql -- work/general_queries/deal_id_collisions.sql
--   GRAIN  one row per (id, deal it names, role). Only colliding ids are returned.
--
-- Measured 2026-11-20 on PROD: 2,672 deals with an Intrum id; 60 are outside Heimdall and
-- 45 of those carry an Intrum id different from ours. Two ids collide, 4 rows:
--   ES25001  our LEG-ES25001, and Intrum's id for LOK-ES24013
--   IGNIS    Intrum's id for both ORG-ES26101 and ORG-ES26106
--
-- Our id is the Atlas id, except on Heimdall, whose Atlas portfolio is a whole country's
-- umbrella (HEI-SE25001 holds every Swedish Heimdall deal), so a Heimdall deal is named by
-- Intrum's id: the same rule as deal-sort's our_ids.sql.
-- ⚠ Only our own batches are in DIM_BATCH. Intrum's purchases that we don't hold (Intrum's
--   own SE25008, unrelated to our SE25008) are invisible here, so this is a floor on the
--   risk, not all of it.

WITH
    batch AS (

        SELECT DISTINCT
            -- ORG batches carry no deal source of their own; the Atlas key starts with it.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle,
            SUBSTR(p.portfolio_bk, 5, 7) AS atlas_id,
            b.servicer_parent_portfolio_bk AS intrum_id
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
        WHERE b.servicer_parent_portfolio_bk IS NOT NULL
),

    deal AS (

        SELECT DISTINCT
            vehicle,
            IFF(vehicle = 'HEI', intrum_id, atlas_id) AS our_id,
            intrum_id
        FROM batch
),

    id_role AS (

        SELECT DISTINCT
            our_id AS id,
            vehicle || '-' || our_id AS deal_key,
            'our id' AS role
        FROM deal
        UNION
        SELECT DISTINCT
            intrum_id,
            vehicle || '-' || our_id,
            'Intrum id'
        FROM deal
        -- A Heimdall deal's Intrum id is its own id: one role, not two.
        WHERE vehicle <> 'HEI'
)

SELECT
    id,
    deal_key,
    role,
    COUNT(DISTINCT deal_key) OVER (PARTITION BY id) AS deals_named
FROM id_role
QUALIFY deals_named > 1
ORDER BY id, role DESC, deal_key;
