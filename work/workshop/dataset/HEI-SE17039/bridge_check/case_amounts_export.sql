SET run_id = 'bf8d7c1b-07fe-4d22-b103-fcef2e158ec3';
SELECT 'ai' AS src, case_id AS id, principal_at_cutoff AS principal, legal_balance_at_cutoff AS balance, default_date, NULL AS registration_date
FROM asset_index.approved.cases WHERE _run_id = $run_id
UNION ALL
SELECT 'raw', SPLIT_PART(_file_path, '.', 2) || '-' || case_id, original_capital, remaining_capital, NULL, registration_date::DATE
FROM raw.hyperion_intrum_cat.cases
WHERE (_file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.1062.cases.%' OR _file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.cases.%')
  AND LEFT(long_portfolio_id, 7) = 'SE17039' AND case_id NOT LIKE '%-%'
QUALIFY ROW_NUMBER() OVER (PARTITION BY SPLIT_PART(_file_path, '.', 2), case_id ORDER BY COALESCE(record_updated, update_ts)::TIMESTAMP DESC NULLS LAST,
    TO_TIMESTAMP_NTZ(PARSE_JSON(_file_metadata):extract_ts::STRING, 'YYYYMMDDTHH24MISS') DESC) = 1
