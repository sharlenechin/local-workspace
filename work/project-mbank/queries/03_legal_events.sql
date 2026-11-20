-- mBank books: every dated legal, insolvency, plan and closing record per case, raw.
-- GRAIN   one row per (case_id, source, code, start_date, end_date): one record as Intrum
--         sent it. build_extract.py maps these to the spec's event_type values.
-- RUN     mise run sql -- work/project-mbank/queries/03_legal_events.sql \
--             --csv work/project-mbank/.cache/03_legal_events.csv
-- SOURCES LEGAL_STEPS  court and bailiff steps; LEGAL_STEP letters A/V/Z/B/O are INFERRED
--                      (filed / verdict / enforceability clause / bailiff / objection) from
--                      the Polish court numbers they carry, not confirmed by Intrum
--         LEGAL_RESULT_INFO  the outcome Intrum recorded against a step, with its date
--         LEGAL_INFO   one legal file per process: LS = lawsuit, EXE = enforcement
--         BANKRUPTCY_RECORD, INSTALLMENT (payment plans), CASES (closing date and code)
-- GUARDS  every table is a change history: DISTINCT on the selected columns, and deleted /
--         archived / unlinked rows dropped; instance 2020 pinned as a literal prefix (C4).
-- ⚠ START_DATE carries junk years elsewhere in the feed; dates after today are dropped.
-- ⚠ Party, lawyer and court-number text are not selected: they are not needed to count events.
SET deals = 'PL19009,PL19017,PL20015,PL20020,PL21024,PL23003';
SET p     = 'data-prod-data-raw-sftp-071269be/intrum/cat.2020.';

WITH
    ids AS (

        SELECT DISTINCT
            case_id
        FROM raw.hyperion_intrum_cat.cases
        WHERE _file_path LIKE $p || 'cases.%'
            AND LEFT(long_portfolio_id, 7) IN (SELECT TRIM(value::STRING) FROM TABLE(SPLIT_TO_TABLE($deals, ',')))
            AND case_id NOT LIKE '%-%'
),

    results AS (

        SELECT DISTINCT
            case_id,
            legal_steps_pkey,
            legal_result,
            result_date::DATE AS result_date
        FROM raw.hyperion_intrum_cat.legal_result_info
        WHERE _file_path LIKE $p || 'legal_result_info.%'
            AND case_id IN (SELECT case_id FROM ids)
            AND COALESCE(deleted, 0) = 0
            AND COALESCE(archived, 0) = 0
            AND COALESCE(unlinked, 0) = 0
)

-- Each step is versioned under its own PKEY; the latest version carries its end date.
SELECT
    s.case_id,
    'LEGAL_STEPS' AS source,
    s.legal_step AS code,
    s.pkey AS record_key,
    s.start_date::DATE AS start_date,
    s.end_date::DATE AS end_date,
    TRIM(s.status) AS status,
    r.legal_result AS result,
    r.result_date
FROM raw.hyperion_intrum_cat.legal_steps AS s
LEFT JOIN results AS r
    ON r.case_id = s.case_id
    AND r.legal_steps_pkey = s.pkey
WHERE s._file_path LIKE $p || 'legal_steps.%'
    AND s.case_id IN (SELECT case_id FROM ids)
    AND COALESCE(s.deleted, 0) = 0
    AND COALESCE(s.archived, 0) = 0
    AND COALESCE(s.unlinked, 0) = 0
    AND s.start_date::DATE <= CURRENT_DATE
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY s.case_id, s.pkey, r.legal_result
    ORDER BY COALESCE(s.record_update, s.update_ts)::TIMESTAMP DESC NULLS LAST
) = 1

UNION ALL

SELECT
    i.case_id,
    'LEGAL_INFO',
    i.legal_process_code,
    i.pkey,
    i.legal_registration_date::DATE,
    i.legal_end_date::DATE,
    i.legal_status_open::STRING,
    NULL,
    NULL
FROM raw.hyperion_intrum_cat.legal_info AS i
WHERE i._file_path LIKE $p || 'legal_info.%'
    AND i.case_id IN (SELECT case_id FROM ids)
    AND COALESCE(i.deleted, 0) = 0
    AND COALESCE(i.archived, 0) = 0
    AND COALESCE(i.unlinked, 0) = 0
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY i.case_id, i.pkey
    ORDER BY COALESCE(i.record_update, i.update_ts)::TIMESTAMP DESC NULLS LAST
) = 1

UNION ALL

SELECT DISTINCT
    b.case_id,
    'BANKRUPTCY_RECORD',
    'insolvency',
    b.pkey,
    b.insolvency_open_date::DATE,
    b.bankruptcy_end_date::DATE,
    NULL,
    NULL,
    NULL
FROM raw.hyperion_intrum_cat.bankruptcy_record AS b
WHERE b._file_path LIKE $p || 'bankruptcy_record.%'
    AND b.case_id IN (SELECT case_id FROM ids)
    AND COALESCE(b.deleted, 0) = 0
    AND COALESCE(b.archived, 0) = 0
    AND COALESCE(b.unlinked, 0) = 0
    AND b.insolvency_open_date IS NOT NULL

UNION ALL

-- A plan is versioned under its INSTALLMENT_ID; its creation date is when it was agreed.
SELECT
    n.case_id,
    'INSTALLMENT',
    TRIM(n.status),
    n.installment_id,
    COALESCE(n.plan_creation_date, n.creation_date, n.start_date)::DATE,
    COALESCE(n.cancel_date, n.end_date)::DATE,
    TRIM(n.status),
    n.num_of_installments::STRING,
    NULL
FROM raw.hyperion_intrum_cat.installment AS n
WHERE n._file_path LIKE $p || 'installment.%'
    AND n.case_id IN (SELECT case_id FROM ids)
    AND COALESCE(n.deleted, 0) = 0
    AND COALESCE(n.archived, 0) = 0
    AND COALESCE(n.unlinked, 0) = 0
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY n.case_id, n.installment_id
    ORDER BY COALESCE(n.record_update, n.update_ts)::TIMESTAMP DESC NULLS LAST
) = 1

UNION ALL

-- The latest version of the case says whether, when and why it closed.
SELECT
    c.case_id,
    'CASES',
    TRIM(c.closing_code),
    NULL,
    c.closing_date::DATE,
    NULL,
    TRIM(c.main_status_code),
    NULL,
    NULL
FROM raw.hyperion_intrum_cat.cases AS c
WHERE c._file_path LIKE $p || 'cases.%'
    AND c.case_id IN (SELECT case_id FROM ids)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY c.case_id
    ORDER BY COALESCE(c.record_updated, c.update_ts)::TIMESTAMP DESC NULLS LAST
) = 1;
