-- Payment history from before the servicer registered the case, per deal.
-- GRAIN  one row per deal, keyed VEHICLE-ID as in deals_we_own.sql. Measured 2026-11-03:
--        2,276 deals have case collections at all.
-- RUN    mise run sql -- work/workshop/queries/pre_registration_collections.sql
-- SOURCE PROD NPL_COMMON only: FCT_CASE_COLLECTION, DIM_CASE, and the case snapshot for
--        the case-to-deal link, which DIM_CASE does not carry.
--
-- WHY THIS EXISTS. The seller's tape is not the only place pre-purchase payment history
-- can sit: Intrum serviced a quarter of Heimdall's cases before it bought them, so its own
-- feed reaches back behind registration on those. The D and E grids cannot tell us --
-- there, the pre- and post-registration collection attributes are scored with the same
-- fill metric, which only asks whether collections exist at all, not when they fall.
--
-- UNDERSTATES ON OLD BOOKS. FCT_CASE_COLLECTION begins in 2014: dbt joins collections to
-- each case's first SCD version and the CAT case feed starts 2014-05-23. A case registered
-- before then cannot show a payment behind its registration date here even if one
-- happened. Reported to the data team (work/data-issues/intrum/dbt-updates.md), not
-- worked around.
WITH
    batch AS (

        SELECT
            b.batch_sk,
            -- Same id rule as deals_we_own.sql: Heimdall under Intrum's id, the rest Atlas.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) || '-' || IFF(
                COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
                b.servicer_parent_portfolio_bk,
                SUBSTR(p.portfolio_bk, 5, 7)
            ) AS deal_id
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
),

-- One pass over the collections fact, so nothing downstream touches it row by row.
    first_collection AS (

        SELECT
            case_id,
            MIN(collection_date) AS first_collection_date
        FROM prod.npl_common.fct_case_collection
        -- 841 rows are dated out to the year 4570. None can be a first payment, but the
        -- bound is here so the column means what its name says.
        WHERE collection_date <= CURRENT_DATE
        GROUP BY 1
),

    case_deal AS (

        SELECT DISTINCT
            s.case_id,
            b.deal_id
        FROM prod.npl_common.fct_case_snapshot_daily AS s
        INNER JOIN batch AS b
            ON b.batch_sk = s.batch_sk
)

SELECT
    d.deal_id,
    COUNT(*) AS cases_with_collections,
    -- A NULL registration date never counts: we cannot call a payment early without one.
    COUNT_IF(f.first_collection_date < c.registration_date) AS cases_paid_before_registration,
    MIN(f.first_collection_date) AS earliest_collection_date
FROM case_deal AS d
INNER JOIN first_collection AS f
    ON f.case_id = d.case_id
INNER JOIN prod.npl_common.dim_case AS c
    ON c.case_id = d.case_id
    AND c.is_current_flag
GROUP BY 1
ORDER BY 1;
