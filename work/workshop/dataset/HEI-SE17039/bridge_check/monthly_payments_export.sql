SET run_id = 'bf8d7c1b-07fe-4d22-b103-fcef2e158ec3';
WITH owned AS (
    SELECT c.case_bk
    FROM prod.npl_common.fct_case_snapshot_daily s
    JOIN prod.npl_common.dim_batch b ON b.batch_sk = s.batch_sk
    JOIN prod.npl_common.dim_case c ON c.case_sk = s.case_sk
    WHERE b.servicer_parent_portfolio_bk = 'SE17039'
    GROUP BY 1
),
raw_case AS (
    SELECT SPLIT_PART(_file_path, '.', 2) AS inst, case_id
    FROM raw.hyperion_intrum_cat.cases
    WHERE (_file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.1062.cases.%' OR _file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.cases.%')
      AND LEFT(long_portfolio_id, 7) = 'SE17039' AND case_id NOT LIKE '%-%'
    GROUP BY 1, 2
),
-- Raw CAT is a change history: one row per (case, date, type, amount) kept, latest version wins.
raw_pay AS (
    SELECT r.inst || '-' || t.case_id AS case_bk, t.transaction_date::DATE AS d, -t.amount::DECIMAL(38,2) AS amount
    FROM raw.hyperion_intrum_cat.transactions t
    JOIN raw_case r ON r.case_id = t.case_id AND r.inst = SPLIT_PART(t._file_path, '.', 2)
    WHERE (t._file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.1062.transactions.%' OR t._file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.transactions.%')
      AND t.payment_cost_ind = 'P' AND t.amount IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY r.inst, t.case_id, t.transaction_date::DATE, t.amount_type_code, t.amount
        ORDER BY COALESCE(t.record_updated, t.update_ts)::TIMESTAMP DESC NULLS LAST,
                 TO_TIMESTAMP_NTZ(PARSE_JSON(t._file_metadata):extract_ts::STRING, 'YYYYMMDDTHH24MISS') DESC) = 1
)
SELECT 'raw' AS src, case_bk, DATE_TRUNC(MONTH, d) AS m, SUM(amount) AS amt, COUNT(*) AS n
FROM raw_pay WHERE case_bk IN (SELECT case_bk FROM owned) AND d IS NOT NULL GROUP BY 1,2,3
UNION ALL
SELECT 'ai', case_id, DATE_TRUNC(MONTH, payment_date), SUM(payment_amount), COUNT(*)
FROM asset_index.approved.payments WHERE _run_id = $run_id GROUP BY 1,2,3
