SET portfolio_id = 'SE20009';

SELECT c.case_id, c.case_bk, c.case_sk, COUNT(*) AS row_count
FROM PROD.NPL_COMMON.DIM_BATCH b
JOIN PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY s ON s.batch_sk = b.batch_sk
JOIN PROD.NPL_COMMON.DIM_CASE c ON c.case_sk = s.case_sk
WHERE b.servicer_parent_portfolio_bk = $portfolio_id
AND c.case_bk = '2080-1560667'
GROUP BY 1, 2, 3;

SELECT *
FROM PROD.NPL_COMMON.DIM_BATCH b
JOIN PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY s ON s.batch_sk = b.batch_sk
JOIN PROD.NPL_COMMON.DIM_CASE c ON c.case_sk = s.case_sk
WHERE b.servicer_parent_portfolio_bk = $portfolio_id
AND c.case_bk LIKE '%9046862%'
LIMIT 20;

WITH cat_cases AS (
    SELECT
        SPLIT_PART(SPLIT_PART(_file_path, '/intrum/cat.', 2), '.cases', 1) AS instance,
        case_id,
        NULLIF(TRIM(client_ref_1), '') AS client_ref_1,
        NULLIF(TRIM(client_ref_2), '') AS client_ref_2
    FROM raw.hyperion_intrum_cat.cases
    WHERE LEFT(long_portfolio_id, 7) = $portfolio_id
        -- Skips the hyphenated ids, as the bridge tool does.
        AND NOT CONTAINS(case_id, '-')
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY instance, case_id
        ORDER BY _file_path DESC
    ) = 1
)

SELECT
    c.instance,
    c.case_id,
    c.client_ref_1,
    c.client_ref_2,
    d.case_bk AS warehouse_case_bk
FROM cat_cases AS c
LEFT JOIN prod.npl_common.dim_case AS d
    ON d.case_bk = c.instance || '-' || c.case_id
    AND d.is_current_flag
WHERE d.case_bk ='2080-1791122'
LIMIT 20;