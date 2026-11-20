-- Every Swedish deal we own, with its cases and the two collection figures that are fast:
-- PAM (Intrum's own report) and FCT_CASE_COLLECTION (our model as it ships).
-- GRAIN   one row per deal, keyed VEHICLE-ID: Heimdall deals by Intrum's id, every other
--         vehicle by our Atlas id (LOK-SE25008 is Intrum's SE25018). 639 deals, measured
--         2026-11-18.
-- RUN     the hackathon notebook, live; or
--         mise run sql -- work/hackathon/queries/sweden_deals.sql --connection dev \
--             --warehouse DEV_WH --lower
--         dev (brocc-sandbox, DEVELOPER) to match the raw query beside it, which needs
--         PROD_RAW; the sandbox sees PROD under PROD_NPL_COMMON / PROD_RAW.
-- The slow third figure, collections rebuilt from raw CAT with both dbt bugs removed, is
-- sweden_raw_cat.sql beside this, run once and cached by the notebook.
--
-- A collecting month is one whose collections sum above zero, after acquisition; the
-- notebook compares months and cash to PAM.
-- ⚠ FCT_CASE_COLLECTION holds rows dated after today, out to the year 4570 (841 rows,
--   measured 2026-11-04); both sources are bounded at today so they cannot count a month.
-- ⚠ The acquisition boundary is month-grain: LEGACY_CAPEX_DATE falls on the 1st for 99.49%
--   of batches.

WITH
    batch AS (

        SELECT
            b.batch_sk,
            b.servicer_parent_portfolio_bk AS intrum_id,
            -- ORG batches carry no deal source of their own; the Atlas key starts with it.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle,
            SUBSTR(p.portfolio_bk, 5, 7) AS atlas_id,
            b.legacy_capex_date
        FROM prod_npl_common.npl_common.dim_batch AS b
        LEFT JOIN prod_npl_common.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
),

-- Heimdall's Atlas portfolio is a whole country's umbrella (HEI-SE25001 holds every Swedish
-- Heimdall deal), so only Intrum's id names a Heimdall deal.
    deal AS (

        SELECT
            vehicle || '-' || IFF(vehicle = 'HEI', intrum_id, atlas_id) AS deal_key,
            intrum_id,
            MIN(legacy_capex_date)::date AS acquisition_date
        FROM batch
        WHERE LEFT(IFF(vehicle = 'HEI', intrum_id, atlas_id), 2) = 'SE'
            AND intrum_id IS NOT NULL
        GROUP BY 1, 2
),

    deal_batch AS (

        SELECT
            d.deal_key,
            b.batch_sk
        FROM deal AS d
        INNER JOIN batch AS b
            ON b.intrum_id = d.intrum_id
),

-- DIM_CASE carries no batch key, so the month-end snapshot links a case to its deal.
-- Counted on CASE_BK, never CASE_SK: DIM_CASE is slowly-changing and the surrogate counts
-- every version (SE15044 read 43,814 on CASE_SK against 10,595 bought).
    dim_case_cases AS (

        SELECT
            db.deal_key,
            COUNT(DISTINCT c.case_bk) AS dim_case_cases
        FROM (
            SELECT DISTINCT batch_sk, case_id
            FROM prod_npl_common.npl_common.fct_case_snapshot_daily
        ) AS s
        INNER JOIN deal_batch AS db
            ON db.batch_sk = s.batch_sk
        INNER JOIN prod_npl_common.npl_common.dim_case AS c
            ON c.case_id = s.case_id
        GROUP BY 1
),

    pam_month AS (

        SELECT
            d.deal_key,
            DATE_TRUNC('month', p.period_start_date::date) AS month,
            SUM(p.colltotal) AS collected
        FROM prod_raw.hyperion_intrum_pam.pam AS p
        INNER JOIN deal AS d
            ON d.intrum_id = p.portfolioid
        -- The newest whole file: each PAM file restates every month.
        WHERE p._file_path = (
                SELECT MAX(_file_path)
                FROM prod_raw.hyperion_intrum_pam.pam
                WHERE _file_path LIKE '%/pam.pam.pam.2%'
            )
            AND p.pmode_name = 'Real'
            -- Forecast rows share the file; ownership-change rows restate a book's past.
            AND COALESCE(p.is_ownership_change, 0) = 0
            AND p.period_start_date::date >= d.acquisition_date
            AND p.period_start_date::date <= CURRENT_DATE
        GROUP BY 1, 2
),

    cat_month AS (

        SELECT
            db.deal_key,
            DATE_TRUNC('month', f.collection_date) AS month,
            SUM(f.amount) AS collected
        FROM prod_npl_common.npl_common.fct_case_collection AS f
        INNER JOIN deal_batch AS db
            ON db.batch_sk = f.batch_sk
        INNER JOIN deal AS d
            ON d.deal_key = db.deal_key
        WHERE f.collection_date >= d.acquisition_date
            AND f.collection_date <= CURRENT_DATE  -- rows run out to the year 4570
        GROUP BY 1, 2
)

SELECT
    d.deal_key,
    d.intrum_id,
    d.acquisition_date,
    c.dim_case_cases,
    p.pam_collections,
    p.pam_months,
    k.cat_collections,
    k.cat_months
FROM deal AS d
LEFT JOIN dim_case_cases AS c
    ON c.deal_key = d.deal_key
LEFT JOIN (
    SELECT deal_key, SUM(collected) AS pam_collections, COUNT_IF(collected > 0) AS pam_months
    FROM pam_month
    GROUP BY 1
) AS p
    ON p.deal_key = d.deal_key
LEFT JOIN (
    SELECT deal_key, SUM(collected) AS cat_collections, COUNT_IF(collected > 0) AS cat_months
    FROM cat_month
    GROUP BY 1
) AS k
    ON k.deal_key = d.deal_key
ORDER BY d.deal_key
