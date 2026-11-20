-- mBank books: Intrum's own monthly collections (PAM), actual months only.
-- GRAIN   one row per (deal, month). Summed across the deal's segments.
-- RUN     mise run sql -- work/project-mbank/queries/05_pam_monthly.sql \
--             --csv work/project-mbank/.cache/05_pam_monthly.csv
-- WHY     The authority the payments extract is tallied against, month by month.
-- ⚠ PMODE_NAME = 'Real' is the actuals SCENARIO, yet it still carries months that have not
--   happened; every month at or after the newest file's own month is dropped.
-- ⚠ Only the newest PAM file is read: each file restates the whole history.
SET deals = 'PL19009,PL19017,PL20015,PL20020,PL21024,PL23003';

WITH
    newest AS (

        SELECT
            MAX(_file_path) AS file_path,
            TO_DATE(REGEXP_SUBSTR(MAX(_file_path), 'pam\\.pam\\.pam\\.(\\d{8})', 1, 1, 'e'), 'YYYYMMDD') AS extracted_on
        FROM raw.hyperion_intrum_pam.pam
        WHERE _file_path LIKE '%/pam.pam.pam.2%'
)

SELECT
    p.portfolioid AS deal,
    p.period_start_date::DATE AS month,
    MAX(n.extracted_on) AS pam_extracted_on,
    SUM(p.colltotal) AS pam_collections,
    MAX(p.currency) AS currency
FROM raw.hyperion_intrum_pam.pam AS p
CROSS JOIN newest AS n
WHERE p._file_path = n.file_path
    AND p.pmode_name = 'Real'
    AND COALESCE(p.is_ownership_change, 0) = 0
    AND p.portfolioid IN (SELECT TRIM(value::STRING) FROM TABLE(SPLIT_TO_TABLE($deals, ',')))
    AND p.period_start_date::DATE < DATE_TRUNC('month', n.extracted_on)
GROUP BY 1, 2
ORDER BY 1, 2;
