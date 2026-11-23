-- SE17039: payments per case and month from Intrum's raw records and from the asset index.
-- Raw records keep every old version, so only the newest copy of each payment is kept.
-- Takes about 5 minutes; used by find_moved_loans.py.

SET portfolio_id = 'SE17039';
SET raw_cat_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH

cases_owned AS (
    SELECT DISTINCT c.case_bk
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = s.batch_sk
    INNER JOIN prod.npl_common.dim_case AS c
        ON c.case_sk = s.case_sk
    WHERE b.servicer_parent_portfolio_bk = $portfolio_id
),

raw_case AS (
    SELECT DISTINCT
        SPLIT_PART(_file_path, '.', 2) AS instance,
        case_id
    FROM raw.hyperion_intrum_cat.cases
    WHERE (_file_path LIKE $raw_cat_prefix || '1062.cases.%'
            OR _file_path LIKE $raw_cat_prefix || '2080.cases.%')
        AND LEFT(long_portfolio_id, 7) = $portfolio_id
        AND case_id NOT LIKE '%-%'
),

raw_payment AS (
    SELECT
        r.instance || '-' || t.case_id AS case_bk,
        t.transaction_date::DATE AS paid_on,
        -- The feed records a payment as a negative amount.
        -t.amount::DECIMAL(38, 2) AS amount
    FROM raw.hyperion_intrum_cat.transactions AS t
    INNER JOIN raw_case AS r
        ON r.case_id = t.case_id
        AND r.instance = SPLIT_PART(t._file_path, '.', 2)
    WHERE (t._file_path LIKE $raw_cat_prefix || '1062.transactions.%'
            OR t._file_path LIKE $raw_cat_prefix || '2080.transactions.%')
        AND t.payment_cost_ind = 'P'
        AND t.amount IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY r.instance, t.case_id, t.transaction_date::DATE, t.amount_type_code, t.amount
        ORDER BY COALESCE(t.record_updated, t.update_ts)::TIMESTAMP DESC NULLS LAST,
            TO_TIMESTAMP_NTZ(PARSE_JSON(t._file_metadata):extract_ts::STRING, 'YYYYMMDDTHH24MISS') DESC
    ) = 1
),

asset_index_run AS (
    SELECT run_id
    FROM asset_index.approved.runs
    WHERE portfolio_id = $portfolio_id
        AND source_work_uri LIKE 's3://ml-prod-asset-index-work/%'
    QUALIFY ROW_NUMBER() OVER (ORDER BY approved_at DESC) = 1
)

SELECT
    'raw_cat' AS source,
    case_bk,
    DATE_TRUNC(MONTH, paid_on) AS month_start,
    SUM(amount) AS paid
FROM raw_payment
WHERE case_bk IN (SELECT case_bk FROM cases_owned)
    AND paid_on IS NOT NULL
GROUP BY case_bk, DATE_TRUNC(MONTH, paid_on)

UNION ALL

SELECT
    'asset_index',
    p.case_id,
    DATE_TRUNC(MONTH, p.payment_date),
    SUM(p.payment_amount)
FROM asset_index.approved.payments AS p
INNER JOIN asset_index_run AS r
    ON r.run_id = p._run_id
GROUP BY p.case_id, DATE_TRUNC(MONTH, p.payment_date);
