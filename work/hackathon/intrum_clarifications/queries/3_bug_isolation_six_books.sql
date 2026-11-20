-- Isolating the two defects: one row per deal, five figures for the same cash.
-- GRAIN   one row per deal. Every column is post-acquisition collections on the same
--         deal, same batches, same window, so all five divide against each other.
-- RUN     mise run sql -- work/data-issues/intrum/queries/dbt_vs_ours_vs_pam.sql \
--             --connection dev --warehouse DEV_WH --lower
-- Each OURS_* column differs from OURS by EXACTLY ONE RULE, so the column that moves
-- names the defect:
--   OURS_WITH_BOOKING_GUARD  adds dbt's COALESCE(booking_ind, 'N') != 'Y'. On instance
--                            2080 booking_ind is null on all 341m rows and the guard is
--                            inert; on 1062 every payment row carrying an amount is 'Y',
--                            so the guard deletes that whole instance.
--   OURS_ON_ORIG_TR_ID       swaps our dedupe key for dbt's CONCAT(orig_tr_id, pkey).
--                            On 2080 one payment arrives under many ids -- case
--                            2080-1212023 has 14 rows of exactly 570.00 on 2016-01-27,
--                            each with its own orig_tr_id -- so the key fails to dedupe.
-- PAM is Intrum's own batch report and is the reference. DBT is
-- PROD_NPL_COMMON.NPL_COMMON.FCT_CASE_COLLECTION, the model as it ships today.
-- ⚠ PAM and OURS still disagree on SE15044 and SE16025 for a reason that is NOT either
--   defect: on those two books CAT holds more 2016-2019 cash than PAM reports, and from
--   2020 on the two agree. That is Intrum's own reporting, written up in
--   ../pam-pre-2020-swedish-books.md. Read this table for the dbt columns.
-- ⚠ The acquisition boundary is accurate to the month, not the day: LEGACY_CAPEX_DATE
--   is month-grain (99.49% of the warehouse's batches fall on the 1st).

SET deals      = 'SE15044,SE16025,SE19026,SE20009,SE25018,SE25037';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH
    deals_asked_for AS (

        SELECT
            TRIM(value::string) AS deal
        FROM TABLE(SPLIT_TO_TABLE($deals, ','))
        WHERE TRIM(value::string) <> ''
),

    pam_newest AS (

        SELECT
            portfolioid AS deal,
            combined_ref,
            period_start_date::date AS period,
            colltotal
        FROM prod_raw.hyperion_intrum_pam.pam
        WHERE _file_path = (
                SELECT MAX(_file_path)
                FROM prod_raw.hyperion_intrum_pam.pam
                WHERE _file_path LIKE '%/pam.pam.pam.2%'
            )
            AND pmode_name = 'Real'
            AND COALESCE(is_ownership_change, 0) = 0
            AND portfolioid IN (SELECT deal FROM deals_asked_for)
),

    acquisition AS (

        SELECT
            servicer_parent_portfolio_bk AS deal,
            MIN(legacy_capex_date)::date AS acquisition_date
        FROM prod_npl_common.npl_common.dim_batch
        WHERE servicer_parent_portfolio_bk IN (SELECT deal FROM deals_asked_for)
        GROUP BY 1
),

    pam AS (

        SELECT
            p.deal,
            SUM(p.colltotal) AS pam_collections
        FROM pam_newest AS p
        INNER JOIN acquisition AS a
            ON a.deal = p.deal
        WHERE p.period >= a.acquisition_date
        GROUP BY 1
),

-- The model as it ships. Joined through the batch, which is what carries the
-- servicer's deal id.
    dbt AS (

        SELECT
            b.servicer_parent_portfolio_bk AS deal,
            COUNT(DISTINCT f.currency_id) AS currencies,
            SUM(f.amount) AS dbt_collections
        FROM prod_npl_common.npl_common.fct_case_collection AS f
        INNER JOIN prod_npl_common.npl_common.dim_batch AS b
            ON b.batch_sk = f.batch_sk
        INNER JOIN acquisition AS a
            ON a.deal = b.servicer_parent_portfolio_bk
        WHERE b.servicer_parent_portfolio_bk IN (SELECT deal FROM deals_asked_for)
            AND f.collection_date >= a.acquisition_date
        GROUP BY 1
),

    owned AS (

        SELECT
            LEFT(c.long_portfolio_id, 7) AS deal,
            PARSE_JSON(c._file_metadata):system::string AS source_system,
            c.case_id AS loan_id
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        WHERE (c._file_path LIKE $raw_prefix || '1062.cases.%'
                OR c._file_path LIKE $raw_prefix || '2080.cases.%')
            AND c.long_portfolio_id IN (SELECT DISTINCT combined_ref FROM pam_newest)
            AND c.case_id NOT LIKE '%-%'
            AND COALESCE(c.real_case_ind, '') <> '1'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY PARSE_JSON(c._file_metadata):system::string, c.case_id
            ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
        ) = 1
),

-- Every candidate payment row, before any dedupe. The three variants below differ only
-- in what they do with these same rows.
    tx AS (

        SELECT
            o.deal,
            o.source_system,
            o.loan_id,
            t.transaction_date::date AS payment_date,
            t.amount_type_code,
            t.booking_ind,
            CONCAT(t.orig_tr_id, COALESCE(t.pkey, '')) AS dbt_transaction_id,
            -t.amount::decimal(38, 2) AS amount,
            COALESCE(t.record_updated, t.update_ts)::timestamp AS record_update,
            TO_TIMESTAMP_NTZ(PARSE_JSON(t._file_metadata):extract_ts::string,
                'YYYYMMDDTHH24MISS') AS extracted_at
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
            AND t.transaction_date::date >= a.acquisition_date
),

-- What the two exports use.
    ours AS (

        SELECT
            deal,
            SUM(amount) AS ours
        FROM (
            SELECT
                deal,
                amount
            FROM tx
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY source_system, loan_id, payment_date, amount_type_code,
                    amount
                ORDER BY record_update DESC NULLS LAST, extracted_at DESC
            ) = 1
        )
        GROUP BY 1
),

-- DEFECT 1 in isolation: our key, plus dbt's booking_ind guard.
    ours_with_booking_guard AS (

        SELECT
            deal,
            SUM(amount) AS ours_with_booking_guard
        FROM (
            SELECT
                deal,
                amount
            FROM tx
            WHERE COALESCE(booking_ind, 'N') <> 'Y'
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY source_system, loan_id, payment_date, amount_type_code,
                    amount
                ORDER BY record_update DESC NULLS LAST, extracted_at DESC
            ) = 1
        )
        GROUP BY 1
),

-- DEFECT 2 in isolation: no guard, but dbt's transaction id as the dedupe key.
    ours_on_orig_tr_id AS (

        SELECT
            deal,
            SUM(amount) AS ours_on_orig_tr_id
        FROM (
            SELECT
                deal,
                amount
            FROM tx
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY source_system, loan_id, dbt_transaction_id
                ORDER BY record_update DESC NULLS LAST, extracted_at DESC
            ) = 1
        )
        GROUP BY 1
)

SELECT
    p.deal,
    p.pam_collections,
    o.ours,
    ROUND(100 * o.ours / NULLIF(p.pam_collections, 0), 1) AS ours_pct,
    d.dbt_collections,
    ROUND(100 * d.dbt_collections / NULLIF(p.pam_collections, 0), 1) AS dbt_pct,
    g.ours_with_booking_guard,
    ROUND(100 * g.ours_with_booking_guard / NULLIF(o.ours, 0), 1)
        AS guard_pct_of_ours,
    k.ours_on_orig_tr_id,
    ROUND(100 * k.ours_on_orig_tr_id / NULLIF(o.ours, 0), 1) AS key_pct_of_ours
FROM pam AS p
LEFT JOIN ours AS o
    ON o.deal = p.deal
LEFT JOIN dbt AS d
    ON d.deal = p.deal
LEFT JOIN ours_with_booking_guard AS g
    ON g.deal = p.deal
LEFT JOIN ours_on_orig_tr_id AS k
    ON k.deal = p.deal
ORDER BY 1
