-- PL23003 (mBank 2023): every case Intrum holds for the deal, with its phase history.
-- GRAIN   one row per (case_bk, group_phase_code, start_date): one phase spell of one case.
--         A case with no spell at all is still one row, with the phase columns null.
-- RUN     mise run sql -- work/project-mbank/queries/pl23003_case_phases.sql \
--             --csv work/project-mbank/.cache/pl23003_case_phases.csv
-- WHY     mBank's tape (mBank_2023.xlsx) ids are L_BMK_<Intrum case id>, so stripping the
--         prefix joins it to CAT. The tape's Stage is one snapshot; this gives the path.
-- PHASES  first letter of GROUP_PHASE_CODE: A = Amicable, L = Legal, E = Execution
--         (enforcement, after a ruling). Only the letter is confirmed, not full codes.
-- ⚠ CASES and GROUP_CASE_PHASE are change histories, so both are DISTINCT'd. case_id is
--   unique only within one CAT instance, so the instance is read off _file_path and kept.
-- ⚠ START_DATE holds 1900-01-01 and far-future junk rows; dates after today are dropped
--   here, and 1900 rows are kept but show as a spell starting before default.
SET deal       = 'PL23003';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.%';

WITH
    deal_cases AS (

        SELECT DISTINCT
            SPLIT_PART(_file_path, '.', 2) AS instance,
            case_id
        FROM raw.hyperion_intrum_cat.cases
        WHERE _file_path LIKE $raw_prefix
            AND LEFT(long_portfolio_id, 7) = $deal
),

    spells AS (

        SELECT DISTINCT
            SPLIT_PART(g._file_path, '.', 2) AS instance,
            g.case_id,
            g.group_phase_code,
            g.custom_code,
            g.start_date::DATE AS start_date
        FROM raw.hyperion_intrum_cat.group_case_phase AS g
        WHERE g._file_path LIKE $raw_prefix
            AND g.group_phase_code IS NOT NULL
            AND g.start_date IS NOT NULL
            AND g.start_date::DATE <= CURRENT_DATE
            AND COALESCE(g.deleted, 0) = 0
            AND COALESCE(g.archived, 0) = 0
            AND COALESCE(g.unlinked, 0) = 0
            AND (g.case_id, SPLIT_PART(g._file_path, '.', 2)) IN (SELECT case_id, instance FROM deal_cases)
)

SELECT
    c.instance,
    c.case_id,
    c.instance || '-' || c.case_id AS case_bk,
    s.group_phase_code,
    LEFT(s.group_phase_code, 1) AS phase_letter,
    s.custom_code,
    s.start_date
FROM deal_cases AS c
LEFT JOIN spells AS s
    ON s.case_id = c.case_id
    AND s.instance = c.instance
ORDER BY case_bk, s.start_date;
