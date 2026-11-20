-- Seller-tape coverage: how many of the books we own have a tape in the asset index.
-- GRAIN  one row per group, for slide 5 of the data-landscape deck.
-- RUN    mise run sql -- work/workshop/queries/seller_tape_coverage.sql
-- SOURCE PROD NPL_COMMON (DIM_BATCH, DIM_PORTFOLIO) for the books we own; the asset
--        index's own folder names, pasted in below, for the tapes.
--
-- DEAL KEY. The same key the rest of the deck uses, from deals_we_own.sql: vehicle, then
-- Intrum's portfolio id for Heimdall and the Atlas id for everything else. Heimdall's
-- Atlas rows are country umbrellas, so DIM_DEAL's 12 HEI rows are NOT deals: matching the
-- asset index against those finds nothing, which is how the first version of this slide
-- came to say we held no Heimdall tapes. Measured 2026-11-10: 2,674 deals.
--
-- TWO ACQUISITION DATES, and only one of them is usable here.
--   legacy_capex_date  the servicer's own purchase date, per batch. For Heimdall this is
--                      Intrum's purchase, years before Brocc bought the vehicle.
--   capex_date         Atlas's date. It stamps EVERY pre-2026 Lokki deal 2025-12-01, the
--                      day the book moved onto Atlas, not the day it was bought.
-- So "bought since December 2025" is counted on legacy_capex_date, and the Atlas count is
-- printed beside it to show how much that trap inflates the figure.
WITH
    batch AS (

        SELECT
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle,
            IFF(
                COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
                b.servicer_parent_portfolio_bk,
                SUBSTR(p.portfolio_bk, 5, 7)
            ) AS deal_id,
            b.legacy_capex_date,
            p.capex_date AS atlas_capex_date
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
),

    deal AS (

        SELECT
            MAX(vehicle) AS vehicle,
            deal_id,
            MIN(legacy_capex_date) AS servicer_capex_date,
            MIN(atlas_capex_date) AS atlas_capex_date
        FROM batch
        WHERE deal_id IS NOT NULL
        GROUP BY deal_id
),

-- The 60 folders in the asset index's sorted/ directory, read 2026-11-10.
    tape AS (

        SELECT COLUMN1 AS deal_key
        FROM VALUES
            ('HEI-FI21007'), ('HEI-FI21052'), ('HEI-PT06002'), ('HEI-PT06014'),
            ('HEI-PT08018'), ('HEI-PT09006'), ('HEI-PT10002'), ('HEI-PT10012'),
            ('HEI-PT13004'), ('HEI-PT15014'), ('HEI-PT15016'), ('HEI-PT15018'),
            ('HEI-PT15020'), ('HEI-PT17013'), ('HEI-PT18019'), ('HEI-PT19007'),
            ('HEI-PT19013'), ('HEI-PT20006'), ('HEI-PT20008'), ('HEI-PT20014'),
            ('HEI-PT21004'), ('HEI-SE17039'), ('HEI-SE19026'), ('HEI-SE20009'),
            ('LOK-BE25002'), ('LOK-BE25004'), ('LOK-BE25006'), ('LOK-BE25013'),
            ('LOK-CH25007'), ('LOK-CH26005'), ('LOK-DE25010'), ('LOK-DE25015'),
            ('LOK-DE25020'), ('LOK-DE25021'), ('LOK-DE25023'), ('LOK-DK25007'),
            ('LOK-ES24013'), ('LOK-ES25004'), ('LOK-ES25021'), ('LOK-FI25001'),
            ('LOK-FI25016'), ('LOK-FI25023'), ('LOK-FI25024'), ('LOK-FI25026'),
            ('LOK-FR25013'), ('LOK-IT24003'), ('LOK-IT24006'), ('LOK-IT24010'),
            ('LOK-IT24011'), ('LOK-IT24013'), ('LOK-IT24014'), ('LOK-IT25014'),
            ('LOK-NL25004'), ('LOK-NL25005'), ('LOK-PL25021'), ('LOK-SE25008'),
            ('LOK-SE25013'), ('LOK-SE25014'), ('LOK-UK26004'), ('ORG-UK26002')
),

    joined AS (

        SELECT
            d.vehicle,
            d.deal_id,
            d.servicer_capex_date,
            d.atlas_capex_date,
            t.deal_key IS NOT NULL AS has_tape
        FROM deal AS d
        LEFT JOIN tape AS t
            ON t.deal_key = d.vehicle || '-' || d.deal_id
)

SELECT
    'all deals we own' AS cut,
    COUNT(*) AS deals,
    SUM(IFF(has_tape, 1, 0)) AS with_tape
FROM joined

UNION ALL

SELECT 'Heimdall', COUNT(*), SUM(IFF(has_tape, 1, 0))
FROM joined WHERE vehicle = 'HEI'

UNION ALL

SELECT 'not Heimdall', COUNT(*), SUM(IFF(has_tape, 1, 0))
FROM joined WHERE vehicle <> 'HEI'

UNION ALL

SELECT 'servicer capex >= 2025-12-01', COUNT(*), SUM(IFF(has_tape, 1, 0))
FROM joined WHERE servicer_capex_date >= '2025-12-01'

UNION ALL

SELECT 'servicer capex >= 2025-12-01, not HEI', COUNT(*), SUM(IFF(has_tape, 1, 0))
FROM joined WHERE servicer_capex_date >= '2025-12-01' AND vehicle <> 'HEI'

UNION ALL

SELECT 'Atlas capex >= 2025-12-01 (inflated)', COUNT(*), SUM(IFF(has_tape, 1, 0))
FROM joined WHERE atlas_capex_date >= '2025-12-01'

UNION ALL

SELECT 'no acquisition date at all', COUNT(*), SUM(IFF(has_tape, 1, 0))
FROM joined WHERE servicer_capex_date IS NULL AND atlas_capex_date IS NULL

UNION ALL

SELECT 'tape folders matching no deal', COUNT(*), 0
FROM tape
WHERE deal_key NOT IN (SELECT vehicle || '-' || deal_id FROM deal)

UNION ALL

-- "Books we bought ourselves" split by vehicle (Lokki vs Organic), asked for on slide 5.
SELECT 'not Heimdall: ' || vehicle, COUNT(*), SUM(IFF(has_tape, 1, 0))
FROM joined WHERE vehicle <> 'HEI'
GROUP BY vehicle
