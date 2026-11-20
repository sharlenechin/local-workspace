-- EXAMPLE — Servicing performance by servicer, by month.
--
-- A worked example, kept runnable on purpose: it queries real tables, so
-- you can run it as-is and then copy the parts you need. Demonstrates a
-- Snowflake session variable for the reporting window, and one file that
-- runs in three places without editing.
--
-- One row per month per servicer: what was collected, across how many
-- cases, and how big the typical payment was.
--
-- This file is plain, valid Snowflake SQL with no templating, so it runs
-- three ways without editing:
--
--   1. Snowflake VS Code extension — open this file and Run All. Results
--      appear in the panel, sortable and exportable.
--   2. Terminal — mise run sql -- examples/example_servicing-dashboard.sql
--   3. Notebook — datalake.q("example_servicing-dashboard.sql")
--
-- CHANGE THE REPORTING WINDOW on the next line. It is a Snowflake session
-- variable, which is why this file works in a plain SQL editor: no Python
-- string substitution is involved.
--
-- From the terminal or a notebook, override it without editing the file:
--     mise run sql -- examples/example_servicing-dashboard.sql months=3
--     datalake.q("example_servicing-dashboard.sql", months=3)
-- Those substitute the number into the SQL text, which matters — see below.
--
-- ⚠ RESULT CACHE, if you change `set months` in a SQL editor and re-run:
-- Snowflake's result cache keys on the query text *before* session variables
-- are resolved. Two runs differing only in `$months` look identical to the
-- cache, so the second silently returns the first one's rows. Verified: with
-- the cache on, months=1 returned the 12-month result. To get a true result
-- after changing the value, run this once in the same session:
--     alter session set use_cached_result = false;
-- The terminal and notebook paths are not affected: they replace `$months`
-- with a literal, so each value has its own cache entry.

set months = 12;

-- The database is spelled out rather than templated, for the same reason.
-- NPL_ANALYST can read PROD and RAW only, so there is nothing to switch.
--
-- SELECT only — nothing in this file writes to Snowflake.
--
-- Two things worth knowing about the source table:
--
--   * FCT_CASE_COLLECTION is one row per collection transaction
--     (~134M rows), so always filter by date before aggregating.
--   * It contains a few hundred rows dated in the future — up to the year
--     4570 — which is why there is an upper bound on collection_date as
--     well as a lower one. Without it you get phantom future months.
--
-- Servicer attribution comes from DIM_REPORTING_SYSTEM. Note this join
-- does NOT work on FCT_PORTFOLIO_SNAPSHOT_MONTHLY, whose
-- REPORTING_SYSTEM_SK column is entirely NULL.

select
    date_trunc(month, c.collection_date)    as month,
    rs.servicer_name                        as servicer,

    -- Volume
    sum(c.amount)                           as collected,
    count(*)                                as transactions,
    count(distinct c.case_id)               as cases,
    count(distinct c.portfolio_sk)          as portfolios,

    -- Shape of a typical payment. Median is far more informative than the
    -- mean here: collections are heavily skewed by a few large payments.
    avg(c.amount)                           as avg_payment,
    median(c.amount)                        as median_payment,

    -- Recovery per case, the headline servicing efficiency number
    div0null(sum(c.amount), count(distinct c.case_id)) as collected_per_case

from PROD.npl_common.fct_case_collection as c
inner join PROD.npl_common.dim_reporting_system as rs
    on c.reporting_system_sk = rs.reporting_system_sk
where c.collection_date >= dateadd(month, -$months, current_date())
  and c.collection_date <= current_date()
group by 1, 2
order by 1 desc, collected desc
