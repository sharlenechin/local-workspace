-- Proof that the proposed models in work/dbt/ are buildable Snowflake SQL.
--
-- The dbt models read int_npl_case_scd_conformed, which lives in the STAGING database that
-- NPL_ANALYST cannot see (only PROD and RAW are visible to this role). PROD.DIM_CASE is built
-- straight from that model and carries the same rows, so this runs the identical logic against
-- the published equivalent:
--     valid_from -> effective_from_date, valid_to -> effective_to_date,
--     case_dk    -> case_id,             is_current -> is_current_flag
--
-- Scoped to instance 4034 (Italy, 48,547 cases) so it returns in seconds. This proves the
-- syntax, the window functions and the output shape -- it does NOT prove build time on the
-- full 153.9m-row dimension.
set instance = '4034';

WITH case_versions AS (
    SELECT
        case_sk,
        case_bk,
        case_id,
        status_code,
        closing_date,
        registration_date,
        default_date,
        effective_from_date,
        effective_to_date,
        is_current_flag
    FROM PROD.NPL_COMMON.DIM_CASE
    WHERE case_bk LIKE $instance || '-%'
),

-- exactly the `sequenced` CTE of int_npl_case_status_change_conformed
sequenced AS (
    SELECT
        *,
        row_number() OVER (PARTITION BY case_id ORDER BY effective_from_date) AS transition_seq,
        count(*) OVER (PARTITION BY case_id) AS n_versions,
        lag(status_code) OVER (PARTITION BY case_id ORDER BY effective_from_date) AS prev_status_code,
        lag(closing_date) OVER (PARTITION BY case_id ORDER BY effective_from_date) AS prev_closing_date,
        lag(registration_date) OVER (PARTITION BY case_id ORDER BY effective_from_date) AS prev_registration_date,
        lag(default_date) OVER (PARTITION BY case_id ORDER BY effective_from_date) AS prev_default_date
    FROM case_versions
),

status_codes AS (
    SELECT
        column1 AS status_code,
        column2 AS workout_track
    FROM values
        ('2','legal'), ('3','legal'), ('5','legal'), ('11','legal'), ('25','legal'), ('26','legal'),
        ('27','legal'), ('28','legal'), ('46','legal'), ('49','legal'), ('50','legal'), ('78','legal'),
        ('81','legal'), ('83','legal'),
        ('12','insolvency'), ('35','insolvency'), ('36','insolvency'), ('59','insolvency'),
        ('67','insolvency'), ('69','insolvency'), ('73','insolvency'), ('315','insolvency'),
        ('23','amicable'), ('24','amicable'), ('29','amicable'), ('51','amicable'), ('52','amicable'),
        ('56','amicable'), ('311','amicable'), ('312','amicable'), ('313','amicable'),
        ('6','closed'), ('9','closed'), ('63','closed'), ('85','closed'), ('300','closed'),
        ('306','closed'), ('307','closed'), ('700','closed'), ('701','closed'), ('703','closed'),
        ('711','closed'), ('713','closed')
),

-- exactly the flag block of the model's `final` CTE
transitions AS (
    SELECT
        sequenced.case_id,
        sequenced.transition_seq,
        sequenced.status_code,
        sequenced.prev_status_code,
        coalesce(sc.workout_track, 'other') AS workout_track,
        coalesce(psc.workout_track, 'other') AS prev_workout_track,
        sequenced.effective_from_date AS changed_on,
        nullif(sequenced.effective_to_date, '9999-12-31'::date) AS ended_on,
        datediff('day', sequenced.effective_from_date,
                 least(sequenced.effective_to_date, current_date())) AS days_in_status,
        sequenced.transition_seq > 1
        AND sequenced.status_code IS DISTINCT FROM sequenced.prev_status_code AS is_status_change,
        sequenced.prev_closing_date IS NULL AND sequenced.closing_date IS NOT NULL AS is_closure,
        sequenced.prev_closing_date IS NOT NULL AND sequenced.closing_date IS NULL AS is_reopen,
        sequenced.transition_seq > 1
        AND sequenced.registration_date IS DISTINCT FROM sequenced.prev_registration_date
            AS is_registration_date_revision,
        coalesce(sc.workout_track = 'insolvency', FALSE)
        AND NOT coalesce(psc.workout_track = 'insolvency', FALSE) AS is_insolvency_entry
    FROM sequenced
    LEFT JOIN status_codes AS sc ON sequenced.status_code = sc.status_code
    LEFT JOIN status_codes AS psc ON sequenced.prev_status_code = psc.status_code
),

-- exactly the spell logic of int_npl_case_phase_intrum
phase_spells AS (
    SELECT
        split_part(_file_path, '.', 2) || '-' || case_id AS case_bk,
        group_phase_code,
        start_date::date AS phase_start_date,
        lead(start_date::date) OVER (
            PARTITION BY split_part(_file_path, '.', 2) || '-' || case_id
            ORDER BY start_date::date
        ) AS phase_end_date,
        lead(group_phase_code) OVER (
            PARTITION BY split_part(_file_path, '.', 2) || '-' || case_id
            ORDER BY start_date::date
        ) AS next_group_phase_code,
        row_number() OVER (
            PARTITION BY split_part(_file_path, '.', 2) || '-' || case_id
            ORDER BY start_date::date
        ) AS phase_seq
    FROM RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE
    WHERE _file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.' || $instance || '.%'
      AND group_phase_code IS NOT NULL
      AND start_date IS NOT NULL
      AND coalesce(deleted, 0) = 0 AND coalesce(archived, 0) = 0 AND coalesce(unlinked, 0) = 0
      AND start_date::date >= '1990-01-01'::date
      AND start_date::date <= current_date()
    QUALIFY row_number() OVER (
        PARTITION BY split_part(_file_path, '.', 2) || '-' || case_id, start_date::date
        ORDER BY record_update DESC NULLS LAST
    ) = 1
)

SELECT 'A. fct_case_status_change' AS block,
       count(*)                                  AS n_rows,
       count(DISTINCT case_id)                   AS n_cases,
       count_if(is_status_change)                AS n_status_changes,
       count_if(is_closure)                      AS n_closures,
       count_if(is_reopen)                       AS n_reopens,
       count_if(is_registration_date_revision)   AS n_reg_date_revisions,
       count_if(is_insolvency_entry)             AS n_insolvency_entries,
       median(days_in_status)                    AS median_days_in_status
FROM transitions
UNION ALL
SELECT 'B. fct_case_phase',
       count(*),
       count(DISTINCT case_bk),
       count_if(left(group_phase_code, 1) = 'A'),
       count_if(left(group_phase_code, 1) = 'L'),
       count_if(phase_end_date IS NULL),
       count_if(left(group_phase_code, 1) = 'A' AND left(next_group_phase_code, 1) IN ('L', 'E')),
       count_if(phase_seq > 1),
       median(datediff('day', phase_start_date, coalesce(phase_end_date, current_date())))
FROM phase_spells;
