-- Which Intrum deals the raw CAT feed holds any cases for. One row per Intrum id.
-- GRAIN  one row per Intrum id (the first 7 characters of LONG_PORTFOLIO_ID).
-- RUN    mise run sql -- work/workshop/queries/raw_cat_deals.sql   (slow: scans every CASES file)
-- SOURCE RAW.HYPERION_INTRUM_CAT.CASES, all extracts. It is a change history, so case_id
--        counts every version's case, and a case_id is unique only within one CAT instance.
-- COST   CASES is 6.5bn rows with no clustering key. _file_path is matched as a literal
--        prefix, the only pruning Snowflake can use; a leading wildcard scans everything.
SELECT
    LEFT(long_portfolio_id, 7) AS intrum_id,
    COUNT(DISTINCT case_id) AS cases,
    COUNT(DISTINCT long_portfolio_id) AS batches
FROM raw.hyperion_intrum_cat.cases
WHERE _file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.%'
GROUP BY 1;
