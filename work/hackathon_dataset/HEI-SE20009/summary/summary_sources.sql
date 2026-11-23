-- SE20009: total payments since purchase from each source, one row per source; read by summary.py.
-- Sources: FCT_PORTFOLIO_SNAPSHOT_MONTHLY (from PAM), FCT_CASE_COLLECTION (from CAT) and the asset index.
-- Every source uses the same months: from the purchase month to the snapshot's last month.
-- The tape's payments end in May 2020, before purchase, so the asset index shows nothing in this window.

SET portfolio_id = 'SE20009';

WITH

deal_batch AS (
    SELECT
        batch_sk,
        legacy_capex_date
    FROM prod.npl_common.dim_batch
    WHERE servicer_parent_portfolio_bk = $portfolio_id
),

portfolio_month AS (
    SELECT
        s.period_end_date,
        s.gross_cash_recoveries
    FROM prod.npl_common.fct_portfolio_snapshot_monthly AS s
    INNER JOIN deal_batch AS b
        ON b.batch_sk = s.batch_sk
),

window_months AS (
    SELECT
        DATE_TRUNC(MONTH, (SELECT MIN(legacy_capex_date) FROM deal_batch)) AS window_start,
        (SELECT MAX(period_end_date) FROM portfolio_month) AS window_end
),

npl_common_portfolio_snapshot AS (
    SELECT
        'npl_common_portfolio_snapshot' AS source,
        SUM(p.gross_cash_recoveries) AS paid_in_window,
        -- The deal has two batches, so count each month once.
        COUNT(DISTINCT IFF(p.gross_cash_recoveries <> 0, p.period_end_date, NULL)) AS months_with_payments,
        NULL AS cases_with_payments
    FROM portfolio_month AS p
    CROSS JOIN window_months AS w
    WHERE p.period_end_date BETWEEN w.window_start AND w.window_end
),

npl_common_case_collection AS (
    SELECT
        'npl_common_case_collection' AS source,
        SUM(f.amount) AS paid_in_window,
        COUNT(DISTINCT LAST_DAY(f.collection_date)) AS months_with_payments,
        COUNT(DISTINCT f.case_id) AS cases_with_payments
    FROM prod.npl_common.fct_case_collection AS f
    INNER JOIN deal_batch AS b
        ON b.batch_sk = f.batch_sk
    CROSS JOIN window_months AS w
    WHERE f.collection_date BETWEEN w.window_start AND w.window_end
),

asset_index_run AS (
    SELECT run_id
    FROM asset_index.approved.runs
    WHERE portfolio_id = $portfolio_id
        AND source_work_uri LIKE 's3://ml-prod-asset-index-work/%'
    QUALIFY ROW_NUMBER() OVER (ORDER BY approved_at DESC) = 1
),

asset_index AS (
    SELECT
        'asset_index' AS source,
        SUM(p.payment_amount) AS paid_in_window,
        COUNT(DISTINCT LAST_DAY(p.payment_date)) AS months_with_payments,
        COUNT(DISTINCT p.case_id) AS cases_with_payments
    FROM asset_index.approved.payments AS p
    INNER JOIN asset_index_run AS r
        ON r.run_id = p._run_id
    CROSS JOIN window_months AS w
    WHERE p.payment_date BETWEEN w.window_start AND w.window_end
)

SELECT
    s.source,
    s.paid_in_window,
    s.months_with_payments,
    s.cases_with_payments,
    w.window_start,
    w.window_end
FROM (
    SELECT * FROM npl_common_portfolio_snapshot
    UNION ALL
    SELECT * FROM npl_common_case_collection
    UNION ALL
    SELECT * FROM asset_index
) AS s
CROSS JOIN window_months AS w;
