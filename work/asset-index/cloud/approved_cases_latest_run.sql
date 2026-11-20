-- Approved cases from each deal's newest run.
-- GRAIN  one row per case, within the latest approved run of its deal.
-- RUN    mise run sql -- work/asset-index/cloud/approved_cases_latest_run.sql
-- NOTE   measured 2026-11-02: approved.runs holds ONE run -- LOK-DE25015, approved
--        2026-10-30. HEI-SE16025 and HEI-SE15044 have no approved run, so this returns
--        nothing until they are run and approved.
WITH 
    latest_run AS (

        SELECT 
            deal_key,
            run_id
        FROM ASSET_INDEX.APPROVED.RUNS
        -- Not MAX(_run_id): run_id is a UUID, so MAX is alphabetical, not newest.
        QUALIFY ROW_NUMBER() OVER (PARTITION BY deal_key ORDER BY approved_at DESC) = 1
    )
SELECT 
    c.*
FROM ASSET_INDEX.APPROVED.CASES AS c
INNER JOIN latest_run AS r
    ON c._deal_key = r.deal_key
    AND c._run_id = r.run_id
WHERE c._deal_key IN ('HEI-SE16025', 'HEI-SE15044')
LIMIT 10
