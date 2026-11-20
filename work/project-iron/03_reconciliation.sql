-- Audit of 02 against PAM at one row per deal. PAM is pinned to a single extract, and the verdict accounts for the share of the deal the tape covers.

WITH latest_asset_index_run AS (
    SELECT
        deal_key,
        portfolio_id,
        run_id
    FROM asset_index.approved.runs
    WHERE portfolio_id IN ('PT06002', 'PT06014', 'PT08018', 'PT09006', 'PT15018', 'PT16023', 'PT18019')
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY deal_key ORDER BY approved_at DESC
    ) = 1
),

warehouse_ids AS (
    SELECT DISTINCT
        LEFT(a.long_portfolio_id, 7) AS portfolio_id,
        -- Leading zeros are padding, not part of the reference: PT18019's tape carries 16 digits against
        -- CAT's 19. Stripping both sides matches 94.37% of that deal and changes no other, and merges no
        -- two distinct references on any of them.
        LTRIM(TRIM(a.client_ref_1), '0') AS client_ref_1,
        a.case_id AS model_id
    FROM prod_raw.hyperion_intrum_cat.cases AS a
    INNER JOIN latest_asset_index_run AS b
        ON LEFT(a.long_portfolio_id, 7) = b.portfolio_id
    WHERE a.case_id NOT LIKE '%-%'
        AND a.client_ref_1 IS NOT NULL
),

asset_index_bridge AS (
    SELECT DISTINCT
        a.portfolio_id,
        b.model_id
    FROM (
        SELECT DISTINCT
            a.portfolio_id,
            b.counterparty_id
        FROM latest_asset_index_run AS a
        INNER JOIN asset_index.approved.case_counterparty AS b
            ON b._run_id = a.run_id
    ) AS a
    INNER JOIN warehouse_ids AS b
        ON b.portfolio_id = a.portfolio_id
        AND b.client_ref_1 = LTRIM(a.counterparty_id, '0')
),

warehouse_registration_information AS (
    SELECT
        SPLIT_PART(case_bk, '-', 2) AS model_id,
        case_id AS case_sk_hashed,              -- Key on which FCT_CASE_COLLECTION joins
        registration_date
    FROM PROD_NPL_COMMON.NPL_COMMON.DIM_CASE
    WHERE case_bk LIKE '4050-%'                 -- Portugal, Intrum reporting system 4050
        AND is_current_flag
),

asset_index_cutoff AS (
    SELECT
        a.portfolio_id,
        MAX(b.cutoff_date) AS cutoff_date
    FROM latest_asset_index_run AS a
    INNER JOIN asset_index.approved.cases AS b
        ON b._run_id = a.run_id
    GROUP BY a.portfolio_id
),

-- The boundary between the seller's history and the servicer's: the tape's own last payment, not the
-- cut-off it states. A seller can stop reporting before its cut-off, and the cash collected in between
-- belongs to the servicer's leg. Where the tape reports up to its cut-off the two dates are the same.
payment_boundary AS (
    SELECT
        a.portfolio_id,
        COALESCE(MAX(b.payment_date), MAX(a.cutoff_date)) AS boundary_date
    FROM asset_index_cutoff AS a
    LEFT JOIN latest_asset_index_run AS c
        ON c.portfolio_id = a.portfolio_id
    LEFT JOIN asset_index.approved.payments AS b
        ON b._run_id = c.run_id
        AND b.payment_date <= a.cutoff_date
    GROUP BY a.portfolio_id
),

pam_latest_file AS (
    SELECT MAX(_file_path) AS file_path
    FROM prod_raw.hyperion_intrum_pam.pam
    WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

pam_monthly AS (
    SELECT
        REGEXP_SUBSTR(a.combined_ref, '^[A-Z]{2}[0-9]{5}') AS portfolio_id,
        DATE_TRUNC('month', TRY_TO_DATE(a.period_start_date::string)) AS collection_month,
        SUM(a.colltotal) AS pam_collected
    FROM prod_raw.hyperion_intrum_pam.pam AS a
    WHERE a.pmode_name = 'Real'
        AND a._file_path = (SELECT file_path FROM pam_latest_file)
        AND COALESCE(a.is_ownership_change, 0) = 0
        AND REGEXP_SUBSTR(a.combined_ref, '^[A-Z]{2}[0-9]{5}') IN
            (SELECT portfolio_id FROM latest_asset_index_run)
    GROUP BY 1, 2
),

warehouse_monthly AS (
    SELECT
        a.portfolio_id,
        DATE_TRUNC('month', c.collection_date) AS collection_month,
        SUM(c.amount) AS warehouse_collected
    FROM asset_index_bridge AS a
    INNER JOIN warehouse_registration_information AS b
        ON b.model_id = a.model_id
    INNER JOIN PROD_NPL_COMMON.NPL_COMMON.FCT_CASE_COLLECTION AS c
        ON c.case_id = b.case_sk_hashed
    INNER JOIN payment_boundary AS d
        ON d.portfolio_id = a.portfolio_id
    WHERE c.collection_date > d.boundary_date
    GROUP BY 1, 2
),

-- Guards C2, C4, C6 and C7: deduplicate the change history, pin the Intrum instance because CASE_ID is unique
-- only within one, payment rows only, and correct the sign.
raw_cat_monthly AS (
    SELECT
        a.portfolio_id,
        DATE_TRUNC('month', c.transaction_date)::date AS collection_month,
        SUM(c.amount) AS raw_cat_collected
    FROM asset_index_bridge AS a
    INNER JOIN warehouse_registration_information AS b
        ON b.model_id = a.model_id
    -- The date is recovered across versions before the dedupe, as 02 does: any version may carry a date the
    -- winning one lacks, and taking only the winner's date dropped EUR 1.69m on PT18019.
    INNER JOIN (
        SELECT
            x.case_id,
            -x.amount::decimal(38, 2) AS amount,
            MAX(x.transaction_date::date) OVER (
                PARTITION BY x.case_id, CONCAT(x.orig_tr_id, COALESCE(x.pkey, ''))
            ) AS transaction_date
        FROM prod_raw.hyperion_intrum_cat.transactions AS x
        WHERE x._file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.4050.transactions.%'
            AND x.payment_cost_ind = 'P'
            AND COALESCE(x.booking_ind, 'N') <> 'Y'
            AND x.amount IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY x.case_id, CONCAT(x.orig_tr_id, COALESCE(x.pkey, ''))
            ORDER BY COALESCE(x.record_updated, x.update_ts)::timestamp DESC NULLS LAST,
                TO_TIMESTAMP_NTZ(PARSE_JSON(x._file_metadata):extract_ts::string,
                    'YYYYMMDDTHH24MISS') DESC
        ) = 1
    ) AS c
        ON c.case_id = a.model_id
    INNER JOIN payment_boundary AS d
        ON d.portfolio_id = a.portfolio_id
    WHERE c.transaction_date > d.boundary_date
    GROUP BY 1, 2
),

last_complete_month AS (
    SELECT
        portfolio_id,
        MAX(collection_month) AS cut_month
    FROM warehouse_monthly
    GROUP BY 1
),

-- Share of the deal the tape covers, without which the ratios below read as a data quality failure rather than a sample size.
deal_coverage AS (
    SELECT
        a.portfolio_id,
        a.cases_in_deal,
        b.cases_we_bridge,
        ROUND(100.0 * b.cases_we_bridge / a.cases_in_deal, 5) AS pct_of_deal_we_hold
    FROM (
        SELECT
            LEFT(long_portfolio_id, 7) AS portfolio_id,
            COUNT(DISTINCT case_id) AS cases_in_deal
        FROM prod_raw.hyperion_intrum_cat.cases
        WHERE LEFT(long_portfolio_id, 7) IN
            (SELECT portfolio_id FROM latest_asset_index_run)
            AND case_id NOT LIKE '%-%'
        GROUP BY 1
    ) AS a
    INNER JOIN (
        SELECT
            portfolio_id,
            COUNT(DISTINCT model_id) AS cases_we_bridge
        FROM asset_index_bridge
        GROUP BY 1
    ) AS b
        ON b.portfolio_id = a.portfolio_id
)

SELECT
    a.portfolio_id,
    a.cut_month,
    c.cases_in_deal,
    c.cases_we_bridge,
    c.pct_of_deal_we_hold,
    COUNT(DISTINCT p.collection_month) AS pam_months,
    COUNT(DISTINCT w.collection_month) AS warehouse_months,
    COUNT(DISTINCT r.collection_month) AS raw_cat_months,
    ROUND(SUM(p.pam_collected), 2) AS pam_collected,
    ROUND(SUM(w.warehouse_collected), 2) AS warehouse_collected,
    ROUND(SUM(r.raw_cat_collected), 2) AS raw_cat_collected,
    ROUND(100.0 * SUM(w.warehouse_collected) / NULLIF(SUM(p.pam_collected), 0), 5)
        AS warehouse_pct_of_pam,
    ROUND(100.0 * SUM(r.raw_cat_collected) / NULLIF(SUM(p.pam_collected), 0), 5)
        AS raw_cat_pct_of_pam,
    CASE
        WHEN c.pct_of_deal_we_hold < 90 THEN 'Not Reconcilable - Sample Tape'
        WHEN ABS(100.0 * SUM(w.warehouse_collected)
                 / NULLIF(SUM(p.pam_collected), 0) - 100) <= 10 THEN 'Pass'
        ELSE 'Fail'
    END AS warehouse_within_10_pct,
    CASE
        WHEN c.pct_of_deal_we_hold < 90 THEN 'Not Reconcilable - Sample Tape'
        WHEN ABS(100.0 * SUM(r.raw_cat_collected)
                 / NULLIF(SUM(p.pam_collected), 0) - 100) <= 10 THEN 'Pass'
        ELSE 'Fail'
    END AS raw_cat_within_10_pct
FROM last_complete_month AS a
LEFT JOIN pam_monthly AS p
    ON p.portfolio_id = a.portfolio_id
    AND p.collection_month <= a.cut_month
LEFT JOIN warehouse_monthly AS w
    ON w.portfolio_id = a.portfolio_id
    AND w.collection_month = p.collection_month
LEFT JOIN raw_cat_monthly AS r
    ON r.portfolio_id = a.portfolio_id
    AND r.collection_month = p.collection_month
INNER JOIN deal_coverage AS c
    ON c.portfolio_id = a.portfolio_id
GROUP BY a.portfolio_id, a.cut_month, c.cases_in_deal, c.cases_we_bridge,
    c.pct_of_deal_we_hold
ORDER BY a.portfolio_id;
