-- Project NOBA reconciliation: CAT against PAM, one row per deal.
-- GRAIN   one row per deal. Both sides on the same basis, so they can be divided.
-- RUN     mise run sql -- work/project-noba/reconciliation.sql \
--             --connection dev --warehouse DEV_WH --lower
-- PAIRS   accounts_export.sql and payments_export.sql use the same scope and guards.
-- PAM is Intrum's own batch-level report and is the authority on what we bought and
-- what has been collected since. CAT is the loan-level feed the two exports are built
-- from. Where they disagree, PAM is right about the book and CAT is right about a loan.
-- ⚠ PAM's statics repeat on every month row of every segment, so ACQCASES and
--   ACQUISITIONPRINCIPAL are MAX per segment and only then summed across segments.
--   Taking MAX across the deal understates a multi-segment book: SE20009 reads 8,497
--   acquired that way and 16,001 correctly.
-- ⚠ COLLECTIONS ARE COMPARED POST-ACQUISITION. PAM only ever counts cash collected
--   since we bought the book; CAT holds the servicer's whole history on the case. On a
--   2015 book those nearly coincide, on a 2025 book they do not -- SE25018 reads 385%
--   of PAM on a post-registration basis and 102% on this one.
-- ⚠ THE ACQUISITION BOUNDARY IS ACCURATE TO THE MONTH, NOT THE DAY. LEGACY_CAPEX_DATE
--   is month-grain: 11,733 of the warehouse's 11,793 batches fall on the 1st (99.49%,
--   294 distinct dates, measured 2026-11-03), so 2015-12-01 means December 2015. That is
--   why SE15044 looks like it was bought before its own tape cut-off of 2015-12-15 -- a
--   cut-off always precedes acquisition, and here the capex date is the rounded one.
-- ⚠ SE15044 AND SE16025 READ 128% AND 121% HERE, AND ALL OF IT IS PRE-2020. Measured by
--   year, 2026-11-02: both run 150-180% of PAM across 2016-2018, fall to ~121-123% in
--   2019, and then sit between 98.5% and 104.7% every year from 2020 on. Those early
--   years hold 54.9m of SE15044's 53.7m gap and 22.3m of SE16025's 22.7m. SE19026 and
--   SE20009 were bought after 2019 and never show it. Two unrelated books and two
--   sellers peaking in the same year and snapping to parity in the same year is a change
--   in Intrum's batch reporting, not something this query can fix. Ruled out by
--   measurement the same day: payment type, duplicated histories across split cases, and
--   REF_CASE_ID as a parent-case link (100% NULL). Cash from 2020 on is quotable on every
--   book here; a lifetime recovery rate on the two old ones is not.

SET deals      = 'SE15044,SE16025,SE19026,SE20009,SE25018,SE25037';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH
    deals_asked_for AS (

        SELECT
            TRIM(value::string) AS deal
        FROM TABLE(SPLIT_TO_TABLE($deals, ','))
        WHERE TRIM(value::string) <> ''
),

-- The newest extract, and the month it was taken. PMODE_NAME = 'Real' picks the actuals
-- SCENARIO, not the actual MONTHS: inside it PAM still carries rows for months that have
-- not happened yet. Comparing our collected-to-date against that makes every young book
-- look short -- it is why SE25037 read 87.6%. The extract month is the cut.
    newest_extract AS (

        SELECT
            MAX(_file_path) AS file_path,
            TO_DATE(REGEXP_SUBSTR(MAX(_file_path), 'pam\\.pam\\.pam\\.(\\d{8})', 1, 1, 'e'),
                'YYYYMMDD') AS extracted_on
        FROM prod_raw.hyperion_intrum_pam.pam
        WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

    pam_newest AS (

        SELECT
            p.portfolioid AS deal,
            p.combined_ref,
            MAX(p.acqcases) AS acq_cases,
            MAX(p.acquisitionprincipal) AS acq_principal,
            SUM(p.colltotal) AS collections
        FROM prod_raw.hyperion_intrum_pam.pam AS p
        CROSS JOIN newest_extract AS n
        WHERE p._file_path = n.file_path
            AND p.pmode_name = 'Real'
            AND COALESCE(p.is_ownership_change, 0) = 0
            AND p.portfolioid IN (SELECT deal FROM deals_asked_for)
            -- ACTUALS ONLY: drop every month at or after the extract's own month.
            AND p.period_start_date::date < DATE_TRUNC('month', n.extracted_on)
        GROUP BY 1, 2
),

    pam AS (

        SELECT
            deal,
            COUNT(*) AS segments,
            SUM(acq_cases) AS pam_cases,
            SUM(acq_principal) AS pam_principal,
            SUM(collections) AS pam_collections
        FROM pam_newest
        GROUP BY 1
),

    batches AS (

        SELECT DISTINCT
            combined_ref
        FROM pam_newest
),

-- The same spine both exports use.
    owned AS (

        SELECT
            LEFT(c.long_portfolio_id, 7) AS deal,
            PARSE_JSON(c._file_metadata):system::string AS source_system,
            c.case_id AS loan_id,
            c.registration_date::date AS registration_date,
            c.original_capital
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        WHERE (c._file_path LIKE $raw_prefix || '1062.cases.%'
                OR c._file_path LIKE $raw_prefix || '2080.cases.%')
            AND c.long_portfolio_id IN (SELECT combined_ref FROM batches)
            AND c.case_id NOT LIKE '%-%'
            AND COALESCE(c.real_case_ind, '') <> '1'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY PARSE_JSON(c._file_metadata):system::string, c.case_id
            ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
        ) = 1
),

    acquisition AS (

        SELECT
            b.servicer_parent_portfolio_bk AS deal,
            MIN(b.legacy_capex_date) AS acquisition_date
        FROM prod_npl_common.npl_common.dim_batch AS b
        WHERE b.servicer_parent_portfolio_bk IN (SELECT deal FROM deals_asked_for)
        GROUP BY 1
),

-- Keyed on what identifies a real payment, NOT on orig_tr_id, and with no booking_ind
-- guard. Both are explained in the payments_export.sql header.
    cat_payments AS (

        SELECT
            deal,
            SUM(IFF(payment_date >= acquisition_date, amount, 0)) AS collections_post_acq,
            SUM(amount) AS collections_all
        FROM (
            SELECT
                o.deal,
                a.acquisition_date,
                t.transaction_date::date AS payment_date,
                -t.amount::decimal(38, 2) AS amount
            FROM prod_raw.hyperion_intrum_cat.transactions AS t
            INNER JOIN owned AS o
                ON o.loan_id = t.case_id
                AND o.source_system = PARSE_JSON(t._file_metadata):system::string
            INNER JOIN acquisition AS a
                ON a.deal = o.deal
            WHERE (t._file_path LIKE $raw_prefix || '1062.transactions.%'
                    OR t._file_path LIKE $raw_prefix || '2080.transactions.%')
                AND t.payment_cost_ind = 'P'
                AND t.amount IS NOT NULL
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY o.source_system, t.case_id, t.transaction_date::date,
                    t.amount_type_code, t.amount
                ORDER BY COALESCE(t.record_updated, t.update_ts)::timestamp DESC NULLS LAST,
                    TO_TIMESTAMP_NTZ(PARSE_JSON(t._file_metadata):extract_ts::string,
                        'YYYYMMDDTHH24MISS') DESC
            ) = 1
        )
        GROUP BY 1
),

    cat AS (

        SELECT
            deal,
            COUNT(DISTINCT source_system || '-' || loan_id) AS cat_cases,
            SUM(original_capital) AS cat_principal
        FROM owned
        GROUP BY 1
)

SELECT
    p.deal,
    c.cat_cases,
    p.pam_cases,
    ROUND(c.cat_cases / NULLIF(p.pam_cases, 0) * 100, 1) AS cases_pct,
    y.collections_post_acq AS cat_collections_post_acq,
    p.pam_collections,
    ROUND(y.collections_post_acq / NULLIF(p.pam_collections, 0) * 100, 1)
        AS collections_pct,
    c.cat_principal,
    p.pam_principal,
    ROUND(c.cat_principal / NULLIF(p.pam_principal, 0) * 100, 1) AS principal_pct
FROM pam AS p
LEFT JOIN cat AS c
    ON c.deal = p.deal
LEFT JOIN cat_payments AS y
    ON y.deal = p.deal
ORDER BY 1;
