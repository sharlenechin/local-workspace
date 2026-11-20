-- Status codes in use: distinct cases per servicer and status code over six month ends.
-- GRAIN: one row per (servicer, status code). A case that changed code is counted under each code it held,
-- so a servicer's rows add to more than its distinct cases.
-- Measured 2026-10-15 for 2026-04-30..2026-09-30: Intrum 67 codes in use, the top four (64, 6, 0, 55) cover 79.8%.
-- Result with the seed's labels: status_code_usage_2026-04_to_2026-09.csv.
--
-- cases_open_by_date counts cases with no closing date on or before that month end. It disagrees with the code
-- often enough to matter: Intrum's 0 "Registered" and 55 "Other measures" are 95% closed by date, and Cerved's
-- "Closed" has no closing dates at all. That is why the proposed is_open_flag reads both.

SET period_from = '2026-04-30';
SET period_to   = '2026-09-30';

SELECT
    LOWER(COALESCE(rs.servicer_name, rs.reporting_system_name, 'unknown'))    AS servicer,
    -- Some codes arrive with a trailing space, so '2' and '2 ' would split
    COALESCE(TRIM(c.status_code), '(blank)')                                  AS code,
    COUNT(DISTINCT s.case_id)                                                 AS cases_6m,
    COUNT(DISTINCT IFF(c.closing_date IS NULL OR c.closing_date > s.date_day, s.case_id, NULL))
                                                                              AS cases_open_by_date_6m,
    COUNT(DISTINCT IFF(s.date_day = $period_to, s.case_id, NULL))             AS cases_sep
FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
-- case_sk is the version valid at that month end, so the code is as at the month end, not today
INNER JOIN PROD.NPL_COMMON.DIM_CASE AS c
    ON c.case_sk = s.case_sk
LEFT JOIN PROD.NPL_COMMON.DIM_REPORTING_SYSTEM AS rs
    ON rs.reporting_system_sk = s.reporting_system_sk
WHERE s.date_day BETWEEN $period_from AND $period_to
GROUP BY 1, 2
ORDER BY 1, 3 DESC;
