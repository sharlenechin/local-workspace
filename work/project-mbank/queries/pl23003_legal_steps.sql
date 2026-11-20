-- PL23003 (mBank 2023): Intrum's legal record per case, a second view beside the phase feed.
-- GRAIN   one row per (case_id, source, step, start_date): one legal step, or one legal
--         file (LEGAL_INFO) with its registration date, of one case.
-- RUN     mise run sql -- work/project-mbank/queries/pl23003_legal_steps.sql \
--             --csv work/project-mbank/.cache/pl23003_legal_steps.csv
-- WHY     The phase feed (pl23003_case_phases.sql) covers only 3,509 of 8,814 cases,
--         measured 2026-11-04, and no deleted/archived/unlinked filter explains the rest.
--         LEGAL_STEPS and LEGAL_INFO record court and bailiff work independently of it.
-- ⚠ Party columns (PARTY_NAME, PARTY_BANK_ACCOUNT, LAWYER_NAME) are personal or third-party
--   data and are deliberately not selected.
-- ⚠ Both tables are change histories, so rows are DISTINCT'd. PL23003 sits on instance
--   2020 only, so the prefix names it and case_id alone is unique.
SET deal       = 'PL23003';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.2020%';

WITH
    deal_cases AS (

        SELECT DISTINCT
            case_id
        FROM raw.hyperion_intrum_cat.cases
        WHERE _file_path LIKE $raw_prefix
            AND LEFT(long_portfolio_id, 7) = $deal
)

SELECT DISTINCT
    s.case_id,
    'LEGAL_STEPS' AS source,
    s.legal_step AS step,
    s.legal_step_text AS step_text,
    s.start_date::DATE AS start_date,
    s.end_date::DATE AS end_date,
    NULL::NUMBER(38, 2) AS amount_paid_to_bailiff
FROM raw.hyperion_intrum_cat.legal_steps AS s
WHERE s._file_path LIKE $raw_prefix
    AND s.case_id IN (SELECT case_id FROM deal_cases)
    AND COALESCE(s.deleted, 0) = 0
    AND COALESCE(s.archived, 0) = 0
    AND COALESCE(s.unlinked, 0) = 0

UNION ALL

SELECT DISTINCT
    i.case_id,
    'LEGAL_INFO' AS source,
    i.legal_process_code AS step,
    NULL AS step_text,
    i.legal_registration_date::DATE AS start_date,
    i.legal_end_date::DATE AS end_date,
    i.amount_paid_to_bailiff
FROM raw.hyperion_intrum_cat.legal_info AS i
WHERE i._file_path LIKE $raw_prefix
    AND i.case_id IN (SELECT case_id FROM deal_cases)
    AND COALESCE(i.deleted, 0) = 0
    AND COALESCE(i.archived, 0) = 0
    AND COALESCE(i.unlinked, 0) = 0;
