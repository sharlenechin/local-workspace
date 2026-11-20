-- Intrum CASES.CASE_PHASE against the phase feed's letter (A amicable, L legal, E execution), per instance.
-- GRAIN: one row per (instance, case_phase, phase letter). Latest CASE_PHASE per case, latest phase spell per case.
-- Measured 2026-10-15 on 23,064,286 Intrum cases (all, open and closed): result in case_phase_vs_phase_feed_2026-10-15.csv.
--   CASE_PHASE usable (not blank, not 4000): 41.7%; phase feed gives A/L/E: 62.3%; either: 65.4%; neither: 34.6%.
--   ⚠ CASE_PHASE codes are instance-specific: 3000 is amicable on 4042/7006/7010 and execution on 2020.
--   ⚠ 4000 splits A/L on every instance (58-97%), so it is not a phase; read open/closed from the status instead.
-- Runs several minutes: CASES is a change-history feed (~147 rows per case).
--
-- Raw tables are read by prefix so Snowflake prunes files; case_id is unique only within an instance, so the
-- instance is in every key.

SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH cases AS (
    SELECT
        SPLIT_PART(_file_path, '.', 2)      AS instance,
        case_id,
        TRIM(case_phase::STRING)            AS case_phase
    FROM RAW.HYPERION_INTRUM_CAT.CASES
    WHERE _file_path LIKE $raw_prefix || '%'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY instance, case_id ORDER BY record_update DESC NULLS LAST, _file_path DESC) = 1
),

-- Aggregate to one row per case before the join: windowing the 347m-row feed first costs several times more
phase_feed AS (
    SELECT
        SPLIT_PART(_file_path, '.', 2)      AS instance,
        case_id,
        MAX_BY(group_phase_code, start_date) AS group_phase_code
    FROM RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE
    WHERE _file_path LIKE $raw_prefix || '%'
      AND COALESCE(deleted, 0) = 0
      AND COALESCE(archived, 0) = 0
      AND COALESCE(unlinked, 0) = 0
    GROUP BY 1, 2
)

SELECT
    c.instance                                  AS inst,
    c.case_phase,
    COALESCE(LEFT(f.group_phase_code, 1), '-')  AS letter,
    COUNT(*)                                    AS cases
FROM cases AS c
LEFT JOIN phase_feed AS f
    ON f.instance = c.instance
   AND f.case_id = c.case_id
GROUP BY 1, 2, 3;
