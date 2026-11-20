-- Each deal we own, the Intrum ids its batches carry, and whether raw PAM reports it.
-- GRAIN  one row per (deal, Intrum id). deal_id is VEHICLE-ID, as in deals_we_own.sql.
-- RUN    mise run sql -- work/workshop/queries/deal_servicer_ids.sql
-- SOURCE PROD NPL_COMMON for the ids; RAW PAM for whether the servicer reports the deal.
WITH
    deal_intrum_id AS (

        SELECT DISTINCT
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) || '-' || IFF(
                COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
                b.servicer_parent_portfolio_bk,
                SUBSTR(p.portfolio_bk, 5, 7)
            ) AS deal_id,
            b.servicer_parent_portfolio_bk AS intrum_id
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
        WHERE b.servicer_name = 'intrum'
),

-- Real months only. Every PAM row says pmode 'Real', forecasts included (they run to
-- 2040), so the file's own extract month is the only actual/forecast boundary.
    pam_actual AS (

        SELECT DISTINCT
            REGEXP_SUBSTR(a.combined_ref, '^[A-Z]{2}[0-9]{5}') AS intrum_id
        FROM raw.hyperion_intrum_pam.pam AS a
        WHERE a.pmode_name = 'Real'
            AND LEFT(a.period_start_date, 10)::date < DATE_TRUNC('month', TO_TIMESTAMP_NTZ(
                PARSE_JSON(a._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'))::date
)

SELECT
    d.deal_id,
    d.intrum_id,
    p.intrum_id IS NOT NULL AS in_raw_pam
FROM deal_intrum_id AS d
LEFT JOIN pam_actual AS p
    ON p.intrum_id = d.intrum_id
WHERE d.deal_id IS NOT NULL
ORDER BY 1, 2;
