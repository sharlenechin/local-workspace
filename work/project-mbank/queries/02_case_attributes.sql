-- mBank books: per-case facts from CAT's side tables, for Table 1 and Table 3.
-- GRAIN   one row per case_id (instance 2020). Every side table is aggregated to one row per
--         case BEFORE it joins, so no join can fan a case out.
-- RUN     mise run sql -- work/project-mbank/queries/02_case_attributes.sql \
--             --csv work/project-mbank/.cache/02_case_attributes.csv
-- WHY     CASES on this instance holds no product, stage, title or status at purchase
--         (is_titled 0, case_phase 1000 and main_status_code 0 on every PL23003 case, measured
--         2026-11-05). These are the only other places such facts live; build_extract.py
--         checks each against mBank's own tape before using it on the older books.
-- GUARDS  C3/C10 DEBTORS is one-to-many and a change feed: aggregated per case, no
--         row_number(); every table pinned to instance 2020 as a literal prefix (C4).
-- ⚠ The first CAT record is not always the purchase record: PL19009's comes a median 552
--   days after registration, PL19017's 403 (00_scope / 01_cases). A status first seen in
--   the feed after registration may have been true at purchase already.
-- ⚠ Personal fields (names, addresses, ids, birth dates) are deliberately not selected.
SET deals = 'PL19009,PL19017,PL20015,PL20020,PL21024,PL23003';
SET p     = 'data-prod-data-raw-sftp-071269be/intrum/cat.2020.';

WITH
    ids AS (

        SELECT DISTINCT
            case_id,
            LEFT(long_portfolio_id, 7) AS deal
        FROM raw.hyperion_intrum_cat.cases
        WHERE _file_path LIKE $p || 'cases.%'
            AND LEFT(long_portfolio_id, 7) IN (SELECT TRIM(value::STRING) FROM TABLE(SPLIT_TO_TABLE($deals, ',')))
            AND case_id NOT LIKE '%-%'
),

    debtors AS (

        SELECT
            case_id,
            COUNT(DISTINCT debtor_row_number) AS debtor_count,
            MAX(IFF(type = 'P', 1, 0)) AS any_private,
            MAX(IFF(type = 'C', 1, 0)) AS any_company,
            LISTAGG(DISTINCT debtor_type, '') WITHIN GROUP (ORDER BY debtor_type) AS debtor_types,
            LISTAGG(DISTINCT legal_type, '') WITHIN GROUP (ORDER BY legal_type) AS legal_types,
            -- D and I are DEBTOR_STATUS codes; read here as deceased / insolvent, checked
            -- against the tape's Status_Code in build_extract.py.
            MIN(IFF(debtor_status = 'D', COALESCE(record_updated, update_ts)::DATE, NULL)) AS first_seen_d,
            MIN(IFF(debtor_status = 'I', COALESCE(record_updated, update_ts)::DATE, NULL)) AS first_seen_i
        FROM raw.hyperion_intrum_cat.debtors
        WHERE _file_path LIKE $p || 'debtors.%'
            AND case_id IN (SELECT case_id FROM ids)
            AND COALESCE(deleted, 0) = 0
            AND COALESCE(archived, 0) = 0
            AND COALESCE(unlinked, 0) = 0
        GROUP BY 1
),

    -- Invoices are versioned too: the latest version of each invoice, then summed per case.
    invoices AS (

        SELECT
            case_id,
            COUNT(*) AS invoice_count,
            SUM(original_principal) AS invoice_principal,
            SUM(original_interest) AS invoice_interest,
            SUM(original_fees) AS invoice_fees,
            SUM(original_outlays) AS invoice_outlays,
            SUM(original_capital) AS invoice_capital,
            MIN(invoice_date::DATE) AS first_invoice_date,
            MIN(due_date::DATE) AS first_due_date
        FROM (
            SELECT *
            FROM raw.hyperion_intrum_cat.invoices
            WHERE _file_path LIKE $p || 'invoices.%'
                AND case_id IN (SELECT case_id FROM ids)
                AND invoice_type = 'ORG'
                AND COALESCE(deleted, 0) = 0
                AND COALESCE(archived, 0) = 0
                AND COALESCE(unlinked, 0) = 0
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY case_id, invoice_number
                ORDER BY COALESCE(record_updated, update_ts)::TIMESTAMP DESC NULLS LAST
            ) = 1
        )
        GROUP BY 1
),

    bankruptcy AS (

        SELECT
            case_id,
            MIN(insolvency_open_date::DATE) AS insolvency_open_date,
            MAX(bankruptcy_end_date::DATE) AS bankruptcy_end_date
        FROM raw.hyperion_intrum_cat.bankruptcy_record
        WHERE _file_path LIKE $p || 'bankruptcy_record.%'
            AND case_id IN (SELECT case_id FROM ids)
            AND COALESCE(deleted, 0) = 0
            AND COALESCE(archived, 0) = 0
            AND COALESCE(unlinked, 0) = 0
        GROUP BY 1
)

SELECT
    i.deal,
    i.case_id,
    d.debtor_count,
    d.any_private,
    d.any_company,
    d.debtor_types,
    d.legal_types,
    d.first_seen_d,
    d.first_seen_i,
    v.invoice_count,
    v.invoice_principal,
    v.invoice_interest,
    v.invoice_fees,
    v.invoice_outlays,
    v.invoice_capital,
    v.first_invoice_date,
    v.first_due_date,
    b.insolvency_open_date,
    b.bankruptcy_end_date
FROM ids AS i
LEFT JOIN debtors AS d
    ON d.case_id = i.case_id
LEFT JOIN invoices AS v
    ON v.case_id = i.case_id
LEFT JOIN bankruptcy AS b
    ON b.case_id = i.case_id;
