-- The defect in three numbers: what dbt ships, what Intrum says, what the fix gives.
-- GRAIN   three labelled rows, one deal. All three are post-acquisition collections on
--         SE25018 (Santander Consumer Bank, bought Jun 2025), so they are comparable.
-- RUN     mise run sql -- work/data-issues/intrum/queries/mismatch_se25018.sql \
--             --connection dev --warehouse DEV_WH --lower
-- WHY THIS DEAL: 70% of its loans sit on Intrum instance 1062, where every real payment
-- carries booking_ind = 'Y'. The guard at int_npl_case_collection_intrum.sql:14 removes
-- exactly those rows, so the model loses most of the book.
-- ⚠ PAM reports per batch, not per instance, so it cannot be asked what 1062 collected
--   on its own. Only four Swedish deals we own sit entirely on 1062 and they hold 1 to 3
--   cases each, too small to show anything. A heavily-1062 deal is the closest available
--   like-for-like, and SE25018 is the heaviest.
-- ⚠ Post-ACQUISITION, not post-registration: PAM counts only cash collected since we
--   bought the book. SE25018 reads 385% of PAM the wrong way and 102% the right way.

SET deal       = 'SE25018';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH
    acquisition AS (

        SELECT
            MIN(legacy_capex_date)::date AS acquisition_date
        FROM prod_npl_common.npl_common.dim_batch
        WHERE servicer_parent_portfolio_bk = $deal
),

-- Intrum's own batch report: newest extract, actuals only, no ownership-change rows.
    pam AS (

        SELECT
            SUM(p.colltotal) AS amount
        FROM prod_raw.hyperion_intrum_pam.pam AS p
        CROSS JOIN acquisition AS a
        WHERE p._file_path = (
                SELECT MAX(_file_path)
                FROM prod_raw.hyperion_intrum_pam.pam
                WHERE _file_path LIKE '%/pam.pam.pam.2%'
            )
            AND p.pmode_name = 'Real'
            AND COALESCE(p.is_ownership_change, 0) = 0
            AND p.portfolioid = $deal
            AND p.period_start_date::date >= a.acquisition_date
),

-- The model as it ships, reached through the batch, which carries the servicer's id.
    dbt AS (

        SELECT
            SUM(f.amount) AS amount
        FROM prod_npl_common.npl_common.fct_case_collection AS f
        INNER JOIN prod_npl_common.npl_common.dim_batch AS b
            ON b.batch_sk = f.batch_sk
        CROSS JOIN acquisition AS a
        WHERE b.servicer_parent_portfolio_bk = $deal
            AND f.collection_date >= a.acquisition_date
),

-- The cases we own. CAT is a change-history feed, so the newest version of each wins.
    owned AS (

        SELECT
            PARSE_JSON(c._file_metadata):system::string AS source_system,
            c.case_id AS loan_id
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        WHERE (c._file_path LIKE $raw_prefix || '1062.cases.%'
                OR c._file_path LIKE $raw_prefix || '2080.cases.%')
            AND LEFT(c.long_portfolio_id, 7) = $deal
            AND c.case_id NOT LIKE '%-%'
            AND COALESCE(c.real_case_ind, '') <> '1'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY PARSE_JSON(c._file_metadata):system::string, c.case_id
            ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
        ) = 1
),

-- Every candidate payment row, before any dedupe.
    tx AS (

        SELECT
            o.source_system,
            o.loan_id,
            t.transaction_date::date AS payment_date,
            t.amount_type_code,
            t.booking_ind,
            -t.amount::decimal(38, 2) AS amount,        -- stored sign-flipped
            COALESCE(t.record_updated, t.update_ts)::timestamp AS record_update,
            TO_TIMESTAMP_NTZ(PARSE_JSON(t._file_metadata):extract_ts::string,
                'YYYYMMDDTHH24MISS') AS extracted_at
        FROM prod_raw.hyperion_intrum_cat.transactions AS t
        INNER JOIN owned AS o
            ON o.loan_id = t.case_id
            -- Instance as well as case_id: the id repeats across the two.
            AND o.source_system = PARSE_JSON(t._file_metadata):system::string
        CROSS JOIN acquisition AS a
        WHERE (t._file_path LIKE $raw_prefix || '1062.transactions.%'
                OR t._file_path LIKE $raw_prefix || '2080.transactions.%')
            AND t.payment_cost_ind = 'P'
            AND t.amount IS NOT NULL
            AND t.transaction_date::date >= a.acquisition_date
),

-- The fix: no booking_ind guard, and keyed on what identifies a payment.
    ours AS (

        SELECT
            SUM(amount) AS amount
        FROM (
            SELECT
                amount
            FROM tx
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY source_system, loan_id, payment_date, amount_type_code,
                    amount
                ORDER BY record_update DESC NULLS LAST, extracted_at DESC
            ) = 1
        )
),

-- The same rows with dbt's guard switched back on, to show it is the guard and not
-- something else in the model.
    ours_with_guard AS (

        SELECT
            SUM(amount) AS amount
        FROM (
            SELECT
                amount
            FROM tx
            WHERE COALESCE(booking_ind, 'N') <> 'Y'
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY source_system, loan_id, payment_date, amount_type_code,
                    amount
                ORDER BY record_update DESC NULLS LAST, extracted_at DESC
            ) = 1
        )
)

SELECT 1 AS n, 'dbt model, as it ships today' AS source, amount,
    ROUND(100 * amount / (SELECT amount FROM pam), 1) AS pct_of_pam FROM dbt
UNION ALL
SELECT 2, 'PAM - Intrum''s own report of this book', amount, 100.0 FROM pam
UNION ALL
SELECT 3, 'our fix - guard dropped, keyed on the payment', amount,
    ROUND(100 * amount / (SELECT amount FROM pam), 1) FROM ours
UNION ALL
SELECT 4, 'control - our rows with dbt''s guard put back', amount,
    ROUND(100 * amount / (SELECT amount FROM pam), 1) FROM ours_with_guard
ORDER BY 1
