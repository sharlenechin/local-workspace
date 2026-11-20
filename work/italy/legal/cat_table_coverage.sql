-- ============================================================================
-- cat_table_coverage — which Intrum CAT tables actually hold data for an
-- instance. Run this FIRST for any new book, before designing an analysis
-- around a table that turns out to be empty.
--
--   RUN      mise run sql -- work/italy/legal/cat_table_coverage.sql
--            mise run sql -- work/italy/legal/cat_table_coverage.sql source_system=4050
--            datalake.q("work/italy/legal/cat_table_coverage")
--   GRAIN    one row per CAT table. RUNTIME ~4 minutes (it counts a 6.4bn-row
--            and a 24.7bn-row table; prefix pruning is what makes it possible).
--
-- WHY THIS FILE EXISTS: for Italy (4034) eleven of the fifteen tables below
-- return ZERO rows, including every legal and insolvency table. An empty
-- table and a table you forgot to join look identical in a result set, so
-- the absence is recorded here rather than remembered.
--
-- ⚠ _file_path is matched as a LITERAL PREFIX. A leading % loses partition
--   pruning and this query then scans ~700 GiB and does not finish.
--
-- ⚠ RAW only. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set source_system = '4034';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

with counts as (
    select 'CASES' as table_name, count(*) as n_rows, count(distinct case_id) as n_cases
    from RAW.HYPERION_INTRUM_CAT.CASES where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'TRANSACTIONS', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'GROUP_CASE_PHASE', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'CASE_STATUS_CHANGE_HISTORY', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.CASE_STATUS_CHANGE_HISTORY where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'INSTALLMENT', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.INSTALLMENT where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'LEGAL_INFO', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.LEGAL_INFO where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'LEGAL_STEPS', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.LEGAL_STEPS where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'LEGAL_RESULT_INFO', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.LEGAL_RESULT_INFO where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'LEGAL_STEP_PARTIES', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.LEGAL_STEP_PARTIES where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'BANKRUPTCY_RECORD', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.BANKRUPTCY_RECORD where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'ASSIGNMENT', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.ASSIGNMENT where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'SETTLEMENT', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.SETTLEMENT where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'DEBT_CHARGES', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.DEBT_CHARGES where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'CASE_PRODUCT', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.CASE_PRODUCT where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'PRODUCT_HISTORY', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.PRODUCT_HISTORY where _file_path like $raw_prefix || $source_system || '.%'
    union all select 'CASE_EXTENSION', count(*), count(distinct case_id)
    from RAW.HYPERION_INTRUM_CAT.CASE_EXTENSION where _file_path like $raw_prefix || $source_system || '.%'
)
select
    table_name,
    n_rows,
    n_cases,
    iff(n_rows = 0, 'EMPTY for this instance', 'has data') as verdict,
    case table_name
        when 'LEGAL_INFO'         then 'judgement/summons dates, verdict amounts, legal process code'
        when 'LEGAL_STEPS'        then 'LEGAL_STEP with START_DATE and END_DATE — per-step durations'
        when 'LEGAL_RESULT_INFO'  then 'outcome of each legal step, and the next step'
        when 'BANKRUPTCY_RECORD'  then 'INSOLVENCY_OPEN_DATE, BANKRUPTCY_END_DATE, affidavit, arrest warrant'
        when 'ASSIGNMENT'         then 'external lawyer/bailiff assigned, and why de-assigned'
        when 'SETTLEMENT'         then 'settlement amounts agreed'
        when 'GROUP_CASE_PHASE'   then 'the phase spells this analysis is built on'
        else null
    end as what_it_would_have_given_us
from counts
order by n_rows desc, table_name;
