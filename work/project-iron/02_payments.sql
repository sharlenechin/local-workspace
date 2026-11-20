-- Payment timeline at one row per model_id, payment date and source. The series is divided at the tape cut-off date, with the asset index reporting before it and the warehouse on or after it.

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

asset_index_ids AS (
    SELECT DISTINCT
        a.portfolio_id,
        b.case_id,
        b.counterparty_id
    FROM latest_asset_index_run AS a
    INNER JOIN asset_index.approved.case_counterparty AS b
        ON a.run_id = b._run_id
),

asset_index_bridge_pairs AS (
    SELECT
        a.portfolio_id,
        a.case_id,
        a.counterparty_id,
        b.model_id
    FROM asset_index_ids AS a
    LEFT JOIN warehouse_ids AS b
        ON b.client_ref_1 = LTRIM(a.counterparty_id, '0')
        AND b.portfolio_id = a.portfolio_id
),

-- One row per loan, so that each tape payment is labelled once, with the party and its own model_id carried together.
asset_index_bridge AS (
    SELECT
        portfolio_id,
        case_id,
        counterparty_id,
        model_id
    FROM asset_index_bridge_pairs
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY portfolio_id, case_id
        ORDER BY model_id NULLS LAST, counterparty_id
    ) = 1
),

-- Every bridged case rather than the single case retained per loan, since a borrower holding several cases collects on all of them.
bridged_model_ids AS (
    SELECT DISTINCT portfolio_id, model_id
    FROM asset_index_bridge_pairs
    WHERE model_id IS NOT NULL
),

-- The seller's cut-off is constant within a deal and is the point the two sources are joined at.
asset_index_cutoff AS (
    SELECT
        a.portfolio_id,
        MAX(b.cutoff_date) AS cutoff_date
    FROM latest_asset_index_run AS a
    INNER JOIN asset_index.approved.cases AS b
        ON b._run_id = a.run_id
    GROUP BY a.portfolio_id
),

asset_index_payments AS (
    SELECT
        b.model_id,
        a.portfolio_id,
        c.payment_date,
        'Pre - Asset Index' AS payment_source,
        ROUND(SUM(c.payment_amount), 5) AS payment_amount
    FROM latest_asset_index_run AS a
    INNER JOIN asset_index.approved.payments AS c
        ON c._run_id = a.run_id
    LEFT JOIN asset_index_bridge AS b
        ON b.portfolio_id = a.portfolio_id
        AND b.case_id = c.case_id
    INNER JOIN asset_index_cutoff AS d
        ON d.portfolio_id = a.portfolio_id
    WHERE c.payment_date <= d.cutoff_date       -- The seller collects up to the cut-off it reports
    GROUP BY 1, 2, 3, 4
),

-- The boundary between the two legs. It is the tape's own last payment rather than the cut-off, because a
-- seller can stop reporting before the cut-off it states: PT15018's tape ends 2016-02-29 against a cut-off of
-- 2016-07-08, and the EUR 67,651.10 the servicer collected in between belongs to neither leg otherwise. Where
-- the tape reports right up to its cut-off, as PT16023 does, the two are the same date. A deal with no tape
-- payments at all falls back to the cut-off.
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

-- Post cut-off collections read from the raw servicer feed, not FCT_CASE_COLLECTION. The PROD model
-- inner-joins collections to a case history window and drops what falls outside it: 1.91% of PT16023 and
-- 46.63% of PT15018. Guards follow the team's own method in
-- work/benchmark-dataset/post-registration-benchmark/templates/02_payments.sql:
--   C4  _file_path pinned to one Intrum instance as a literal prefix, since CASE_ID is unique only within one
--   C5  every extract read, because the newest file is a delta
--   C6  payments only: payment_cost_ind = 'P' and booking_ind <> 'Y'
--   C7  AMOUNT is stored sign-flipped, so a collection arrives negative
--   C2  deduplicated on the transaction's own key, latest record_updated winning
-- The date is recovered across versions before the dedupe: any version may carry a date the winning one
-- lacks, and on Portugal that rescues real money. A payment still undated after that cannot be placed in
-- time and is dropped here, which the series reports as EUR 947.80 on PT16023 and EUR 10.00 on PT15018.
warehouse_payments AS (
    SELECT
        a.model_id,
        a.portfolio_id,
        c.payment_date,
        'Post - Warehouse' AS payment_source,
        ROUND(SUM(c.amount), 5) AS payment_amount
    FROM bridged_model_ids AS a
    INNER JOIN payment_boundary AS d
        ON d.portfolio_id = a.portfolio_id
    INNER JOIN (
        SELECT
            t.case_id,
            MAX(t.transaction_date::date) OVER (
                PARTITION BY t.case_id, CONCAT(t.orig_tr_id, COALESCE(t.pkey, ''))
            ) AS payment_date,
            -t.amount::decimal(38, 2) AS amount
        FROM prod_raw.hyperion_intrum_cat.transactions AS t
        WHERE t._file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.4050.transactions.%'
            AND t.payment_cost_ind = 'P'
            AND COALESCE(t.booking_ind, 'N') <> 'Y'
            AND t.amount IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY t.case_id, CONCAT(t.orig_tr_id, COALESCE(t.pkey, ''))
            -- The same pick dbt makes in int_npl_case_collection_intrum, extracted_at breaking the tie.
            ORDER BY COALESCE(t.record_updated, t.update_ts)::timestamp DESC NULLS LAST,
                TO_TIMESTAMP_NTZ(PARSE_JSON(t._file_metadata):extract_ts::string,
                    'YYYYMMDDTHH24MISS') DESC
        ) = 1
    ) AS c
        ON c.case_id = a.model_id
    WHERE c.payment_date > d.boundary_date
    GROUP BY 1, 2, 3, 4
)

SELECT
    model_id,
    portfolio_id,
    payment_date,
    payment_source,
    payment_amount
FROM (
    SELECT * FROM asset_index_payments
    UNION ALL
    SELECT * FROM warehouse_payments
)
ORDER BY portfolio_id, model_id, payment_date, payment_source;
