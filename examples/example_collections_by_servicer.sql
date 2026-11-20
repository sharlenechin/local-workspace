-- EXAMPLE — Monthly NPL collections by servicer, over a rolling window.
--
-- The compact counterpart to example_servicing-dashboard.sql: same shape of
-- question, fewer columns, easy to copy. Queries real tables, so it runs
-- as-is.
--
-- Plain, valid Snowflake SQL with no templating, so it runs three ways
-- without editing:
--
--   1. Snowflake VS Code extension — open this file and Run All
--   2. Terminal — mise run sql -- examples/example_collections_by_servicer.sql
--   3. Notebook — datalake.q("example_collections_by_servicer.sql")
--
-- Override the window without editing the file:
--     mise run sql -- examples/example_collections_by_servicer.sql months=3
--     datalake.q("example_collections_by_servicer.sql", months=3)
--
-- This file used to parameterise the database with a Python str.format
-- placeholder. The extension cannot parse that — it sends the file to
-- Snowflake verbatim, so the braces are a syntax error. That style still
-- exists in `datalake` and is still useful, but it belongs in SQL written
-- inline in Python, not in a `.sql` file: see the last section of
-- example_servicing-dashboard.ipynb. The database is spelled out below
-- instead — NPL_ANALYST can read PROD and RAW only, so there is nothing
-- to switch.
--
-- ⚠ AND DO NOT WRITE THAT PLACEHOLDER IN A COMMENT HERE, EITHER.
-- datalake.placeholder_names() matches the braces with a plain regex that
-- knows nothing about SQL comments, so a file merely *mentioning* the
-- syntax is treated as a placeholder file: `mise run sql` then injects
-- db=PROD and str.format rewrites the comment. Describe it in words.
--
-- SELECT only — nothing in this file writes to Snowflake.
--
-- ⚠ RESULT CACHE, if you change `set months` in a SQL editor and re-run:
-- Snowflake's result cache keys on the query text *before* session variables
-- are resolved, so two runs differing only in `$months` look identical to it
-- and the second returns the first one's rows. To get a true result after
-- changing the value, run this once in the same session:
--     alter session set use_cached_result = false;
-- The terminal and notebook paths substitute a literal, so each value gets
-- its own cache entry and they are unaffected.
--
-- Note the warehouse table names DROP the domain prefix that the dbt model
-- filenames carry: the model `fct_npl_case_collection.sql` lands as
-- PROD.NPL_COMMON.FCT_CASE_COLLECTION. Check with
--     datalake.q("show tables in schema PROD.npl_common")

set months = 12;

select
    date_trunc(month, c.collection_date) as month,
    rs.servicer_name                     as servicer,
    rs.reporting_system_name             as reporting_system,
    sum(c.amount)                        as collected,
    count(*)                             as transactions
from PROD.npl_common.fct_case_collection as c
inner join PROD.npl_common.dim_reporting_system as rs
    on c.reporting_system_sk = rs.reporting_system_sk
-- ⚠ THE UPPER BOUND IS DELIBERATE. FCT_CASE_COLLECTION holds 841 rows dated
-- in the future — 741 in 2099, single rows out to the year 4570. Without it
-- they appear as phantom future months on the time axis. A known warehouse
-- data-quality problem, not something this query introduces.
where c.collection_date >= dateadd(month, -$months, current_date())
  and c.collection_date <= current_date()
group by 1, 2, 3
order by 1, 2
