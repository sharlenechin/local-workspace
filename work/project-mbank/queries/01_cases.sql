-- mBank books: every case Intrum holds, as it first arrived and as it stands now.
-- GRAIN   one row per (deal, case_id, version_kind): 'first' = the case's earliest record,
--         'latest' = its newest. Two rows per case.
-- RUN     mise run sql -- work/project-mbank/queries/01_cases.sql \
--             --csv work/project-mbank/.cache/01_cases.csv
-- WHY     The spec wants Table 1 "as at purchase". CASES is a change history, so its
--         earliest version is the purchase-time record and its latest is today's. Both are
--         kept so build_extract.py can show which fields moved, and check PL23003's first
--         version against mBank's own tape.
-- GUARDS  C1 change history, ranked by record time; C4 instance 2020 pinned as a literal
--         prefix (all six deals sit on 2020 alone, measured 2026-11-05 by 00_scope.sql);
--         C5 every extract read; C9 container (hyphenated) cases dropped.
-- ⚠ Personal fields (names, addresses, client references) are deliberately not selected.
SET deals      = 'PL19009,PL19017,PL20015,PL20020,PL21024,PL23003';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.2020.cases.%';

WITH
    versions AS (

        SELECT
            LEFT(c.long_portfolio_id, 7) AS deal,
            c.long_portfolio_id AS batch,
            c.case_id,
            COALESCE(c.record_updated, c.update_ts)::TIMESTAMP AS recorded_at,
            c.registration_date::DATE AS registration_date,
            c.default_date::DATE AS default_date,
            c.original_capital,
            c.original_interest,
            c.accrued_interest_reg_date,
            c.principal_at_cutoff,
            c.interest_at_cutoff,
            c.expenses_at_cutoff,
            c.face_value_at_cutoff,
            c.remaining_capital,
            c.remaining_interest,
            c.remaining_debtor_fee,
            c.remaining_debtor_outlay,
            c.currency_cap_interest AS currency,
            c.product_id,
            c.orig_product_id,
            c.orig_product_name,
            c.receivable_type,
            c.is_titled,
            c.judgement_date::DATE AS judgement_date,
            c.court_procedure,
            c.debt_enforcement_number IS NOT NULL AS has_enforcement_number,
            c.statute_barred_date::DATE AS statute_barred_date,
            TRIM(c.main_status_code) AS main_status_code,
            c.case_phase,
            c.closing_date::DATE AS closing_date,
            TRIM(c.closing_code) AS closing_code,
            c.origination_date_at_client::DATE AS origination_date,
            c.original_balance_at_client,
            c.ownership_transfer_date::DATE AS ownership_transfer_date
        FROM raw.hyperion_intrum_cat.cases AS c
        WHERE c._file_path LIKE $raw_prefix
            AND LEFT(c.long_portfolio_id, 7) IN (SELECT TRIM(value::STRING) FROM TABLE(SPLIT_TO_TABLE($deals, ',')))
            AND c.case_id NOT LIKE '%-%'
)

SELECT 'first' AS version_kind, *
FROM versions
QUALIFY ROW_NUMBER() OVER (PARTITION BY case_id ORDER BY recorded_at ASC NULLS LAST) = 1

UNION ALL

SELECT 'latest' AS version_kind, *
FROM versions
QUALIFY ROW_NUMBER() OVER (PARTITION BY case_id ORDER BY recorded_at DESC NULLS LAST) = 1;
