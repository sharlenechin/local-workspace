-- Which legal and collections-status fields does the raw Intrum feed carry, per country?
-- GRAIN  one row per (country, field). pct_of_cases is the share of that country's cases
--        carrying a value, so 0 means the column exists but the country never fills it.
-- RUN    mise run sql -- work/workshop/queries/legal_fields_by_country.sql
-- SOURCE raw CAT CASES only. Nothing here is modelled in PROD: the only case-level status
--        dbt carries is DIM_CASE.STATUS_CODE, and no phase, limitation or court field at all.
-- COST   one scan of a 6.5bn-row change history, so counts are APPROX_COUNT_DISTINCT.
WITH
    cat_cases AS (

        SELECT
            LEFT(a.long_portfolio_id, 2) AS country,
            a.case_id,
            a.case_phase,
            a.statute_barred_date,
            a.judgement_date,
            a.court_procedure,
            a.legal_claim_reason,
            a.serving_date,
            a.statutory_date,
            a.restructuring_date,
            a.denouncement_date,
            a.debt_enforcement_number,
            a.is_titled,
            a.is_secured,
            a.receivable_type,
            a.product_id,
            a.main_status_code,
            a.detail_status_code,
            a.closing_code,
            a.case_classification
        FROM raw.hyperion_intrum_cat.cases AS a
        -- A case id with a hyphen is a linked sub-case, not a case the feed counts.
        WHERE a.case_id NOT LIKE '%-%'
            AND a.long_portfolio_id IS NOT NULL
),

-- APPROX_COUNT_DISTINCT, not COUNT(DISTINCT): a case repeats ~147 times in this feed, and
-- the exact count over 6.5bn rows costs far more than a yes/no answer is worth.
    fill_per_country AS (

        SELECT
            country,
            APPROX_COUNT_DISTINCT(case_id) AS cases,
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(case_phase::string), '') IS NOT NULL THEN case_id END) AS "case_phase (amicable/legal/execution stage)",
            APPROX_COUNT_DISTINCT(CASE WHEN statute_barred_date IS NOT NULL THEN case_id END) AS "statute_barred_date (limitation date)",
            APPROX_COUNT_DISTINCT(CASE WHEN judgement_date IS NOT NULL THEN case_id END) AS "judgement_date",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(court_procedure::string), '') IS NOT NULL THEN case_id END) AS "court_procedure",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(legal_claim_reason::string), '') IS NOT NULL THEN case_id END) AS "legal_claim_reason",
            APPROX_COUNT_DISTINCT(CASE WHEN serving_date IS NOT NULL THEN case_id END) AS "serving_date (claim served)",
            APPROX_COUNT_DISTINCT(CASE WHEN statutory_date IS NOT NULL THEN case_id END) AS "statutory_date",
            APPROX_COUNT_DISTINCT(CASE WHEN restructuring_date IS NOT NULL THEN case_id END) AS "restructuring_date (insolvency/plan)",
            APPROX_COUNT_DISTINCT(CASE WHEN denouncement_date IS NOT NULL THEN case_id END) AS "denouncement_date (termination)",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(debt_enforcement_number::string), '') IS NOT NULL THEN case_id END) AS "debt_enforcement_number (bailiff ref)",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(is_titled::string), '') IS NOT NULL THEN case_id END) AS "is_titled (enforceable title held)",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(is_secured::string), '') IS NOT NULL THEN case_id END) AS "is_secured",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(receivable_type::string), '') IS NOT NULL THEN case_id END) AS "receivable_type (promissory note, invoice, loan)",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(product_id::string), '') IS NOT NULL THEN case_id END) AS "product_id (the legal flag in Italy)",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(main_status_code::string), '') IS NOT NULL THEN case_id END) AS "main_status_code (collection status)",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(detail_status_code::string), '') IS NOT NULL THEN case_id END) AS "detail_status_code",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(closing_code::string), '') IS NOT NULL THEN case_id END) AS "closing_code (why it closed)",
            APPROX_COUNT_DISTINCT(CASE WHEN NULLIF(TRIM(case_classification::string), '') IS NOT NULL THEN case_id END) AS "case_classification"
        FROM cat_cases
        GROUP BY 1
),

    one_row_per_field AS (

        SELECT
            country,
            cases,
            field,
            cases_with_a_value
        FROM fill_per_country
        UNPIVOT (cases_with_a_value FOR field IN (
            "case_phase (amicable/legal/execution stage)",
            "statute_barred_date (limitation date)",
            "judgement_date",
            "court_procedure",
            "legal_claim_reason",
            "serving_date (claim served)",
            "statutory_date",
            "restructuring_date (insolvency/plan)",
            "denouncement_date (termination)",
            "debt_enforcement_number (bailiff ref)",
            "is_titled (enforceable title held)",
            "is_secured",
            "receivable_type (promissory note, invoice, loan)",
            "product_id (the legal flag in Italy)",
            "main_status_code (collection status)",
            "detail_status_code",
            "closing_code (why it closed)",
            "case_classification"
        ))
)
SELECT
    country,
    field,
    cases,
    cases_with_a_value,
    ROUND(100.0 * cases_with_a_value / NULLIF(cases, 0), 2) AS pct_of_cases,
    -- Nothing in this list is modelled: DIM_CASE.STATUS_CODE is the only case-level status
    -- dbt carries, and it is the status feed, not any of these columns.
    'raw only' AS in_dbt
FROM one_row_per_field
WHERE cases >= 1000
ORDER BY country, pct_of_cases DESC;
