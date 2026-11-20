-- ============================================================================
-- base_data_quality — DATA QUALITY & COVERAGE: what is missing or wrong.
-- GRAIN: one row per check that currently fires.
-- ============================================================================
-- Run this BEFORE trusting a number out of any other file. One row per check, with a
-- live measurement — so it stays true as the warehouse changes rather than
-- repeating what was found on 2026-09-09.
--
--   Terminal : mise run sql -- work/servicing/prod/base_data_quality.sql
--   Notebook : datalake.q("servicing/prod/base_data_quality")
--
-- SEVERITY:
--   BLOCKER  — a number built on this will be wrong. Do not ship it.
--   WARNING  — usable with a stated caveat.
--   INFO     — context worth knowing.
--
-- These are findings to REPORT to the data team, not to fix here. Per the
-- workspace rules a data-quality bug is a conversation, not a quiet model
-- edit; nothing in this workspace writes to Snowflake.
--
-- Checks 10 and 11 are metadata-only and cost nothing. Checks 1–9 scan real
-- data and are bounded to $months_back months to stay cheap.
-- ============================================================================

set month_end   = '2026-07-31';   -- last complete month
set months_back = 12;


with w as (
    select $month_end::date                                   as end_date,
           dateadd(month, -1 * $months_back, $month_end::date) as start_date
),

-- 1. Is the newest portfolio-level month actually loaded?
latest_load as (
    select period_end_date,
           count(*)                     as n_rows,
           count(distinct portfolio_sk) as n_portfolios
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    group by 1
    qualify row_number() over (order by period_end_date desc) <= 2
),
load_check as (
    select
        max(iff(rn = 1, period_end_date, null))  as newest_period,
        max(iff(rn = 1, n_portfolios, null))     as newest_portfolios,
        max(iff(rn = 2, period_end_date, null))  as prior_period,
        max(iff(rn = 2, n_portfolios, null))     as prior_portfolios
    from (select l.*, row_number() over (order by period_end_date desc) rn
          from latest_load l)
),

-- 2/3. Loan-level vs portfolio-level collection coverage, latest complete month.
cov as (
    select
        count(*)                                            as n_portfolios,
        sum(iff(cl.amt is null, 1, 0))                      as n_no_loan_detail,
        sum(pm.gcr)                                         as portfolio_gcr,
        sum(coalesce(cl.amt, 0))                            as case_gcr,
        sum(iff(cl.amt is not null
                and abs(pm.gcr - cl.amt) > 0.01 * abs(nullif(pm.gcr, 0)), 1, 0))
                                                            as n_differ_gt_1pct
    from (select portfolio_sk, sum(gross_cash_recoveries) gcr
          from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY, w
          where period_end_date = w.end_date group by 1) pm
    left join (select portfolio_sk, sum(amount) amt
               from PROD.NPL_COMMON.FCT_CASE_COLLECTION, w
               where collection_date > dateadd(month, -1, w.end_date)
                 and collection_date <= w.end_date
               group by 1) cl on cl.portfolio_sk = pm.portfolio_sk
),

-- 4. Impossible collection dates.
bad_dates as (
    select count(*) as n_future,
           sum(amount) as amt_future,
           max(collection_date) as worst_date
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION
    where collection_date > current_date()
),

-- 5. Servicer attribution on the portfolio-level fact.
repsys_null as (
    select count(*) as n_rows,
           sum(iff(reporting_system_sk is null, 1, 0)) as n_null
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

-- 6. DIM_CASE attribute completeness, current versions only.
case_nulls as (
    select count(*) as n,
           avg(iff(origination_date   is null, 1, 0)) as p_orig,
           avg(iff(original_principal is null, 1, 0)) as p_prin,
           avg(iff(secured_flag       is null, 1, 0)) as p_sec,
           avg(iff(default_date       is null, 1, 0)) as p_def,
           avg(iff(backstop_date      is null, 1, 0)) as p_backstop
    from PROD.NPL_COMMON.DIM_CASE
    where is_current_flag
),

-- 7. Borrower fan-out and identity completeness.
borr as (
    select count(*) as n_rows,
           count(distinct borrower_id) as n_borrowers,
           avg(iff(vat is null, 1, 0)) as p_vat,
           avg(iff(credit_rating is null, 1, 0)) as p_rating,
           avg(iff(country_id is null, 1, 0)) as p_country
    from PROD.NPL_COMMON.DIM_BORROWER
),
bridge as (
    select count(*) as n_links,
           count(distinct case_sk) as n_cases,
           count(distinct borrower_sk) as n_borrowers
    from PROD.NPL_COMMON.BRG_CASE_BORROWER
),

-- 8. Months where loan-level collections collapse — a load gap, not a trend.
monthly as (
    select last_day(collection_date) as m, sum(amount) as amt
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION, w
    where collection_date >  w.start_date
      and collection_date <= w.end_date
    group by 1
),
gaps as (
    select count(*) as n_thin_months,
           listagg(to_varchar(m, 'YYYY-MM'), ', ')
               within group (order by m) as thin_months
    from (select m, amt, median(amt) over () as med from monthly)
    where amt < 0.5 * med
),

-- 9. Loans on book with no borrower attached at all.
orphan as (
    -- The loans on book at the reporting date, isolated first: a comma-join
    -- to `w` here would bind the LEFT JOIN to `w` rather than the snapshot.
    select count(*) as n_loans,
           sum(iff(b.case_sk is null, 1, 0)) as n_no_borrower
    from (select s.case_sk
          from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
          cross join w
          where s.date_day = w.end_date) as s
    left join (select distinct case_sk from PROD.NPL_COMMON.BRG_CASE_BORROWER) as b
           on b.case_sk = s.case_sk
),

-- 10/11. Metadata-only checks: no data scanned.
type_mismatch as (
    select count(*) as n_number_typed
    from PROD.information_schema.columns
    where table_schema = 'NPL_COMMON'
      and column_name  = 'REPORTING_SYSTEM_SK'
      and data_type    = 'NUMBER'
),
undocumented as (
    select count(*) as n_cols,
           sum(iff(coalesce(trim(comment), '') = '', 1, 0)) as n_undocumented
    from PROD.information_schema.columns
    where table_schema = 'NPL_COMMON'
),

-- 12. DECFLOAT columns reach pandas as dicts, not numbers.
decfloat as (
    select count(*) as n_cols,
           listagg(table_name || '.' || column_name, ', ')
               within group (order by table_name, column_name) as cols
    from PROD.information_schema.columns
    where table_schema = 'NPL_COMMON'
      and data_type = 'DECFLOAT'
),

-- 13. Carrying amount diverges past the forecast horizon.
carrying_divergence as (
    -- Measured at row level, and split past vs future: the recursion is only
    -- unstable beyond the forecast horizon, so "is it broken today" and "is
    -- it broken somewhere in the table" are different questions.
    select
        count(*)                                                as n_rows,
        sum(iff(cv < 0, 1, 0))                                  as n_negative,
        sum(iff(cv < 0 and period_end_date <= current_date(), 1, 0))
                                                                as n_negative_in_actuals,
        min(iff(cv < 0, period_end_date, null))                 as first_negative_period,
        min(cv)                                                 as worst_value,
        max(period_end_date)                                    as horizon_end
    from (select period_end_date, closing_value::number(38, 6) as cv
          from PROD.NPL_COMMON.FCT_CARRYING_AMOUNT)
)

select * from (
    select 1 as id, 'BLOCKER' as severity, 'Latest month not fully loaded' as check_name,
           'FCT_PORTFOLIO_SNAPSHOT_MONTHLY' as object_name,
           to_varchar(newest_portfolios) || ' portfolios at ' || to_varchar(newest_period)
             || ' vs ' || to_varchar(prior_portfolios) || ' at ' || to_varchar(prior_period) as measured,
           'Use ' || to_varchar(prior_period) || ' as the last complete month. The newest '
             || 'month looks like a collapse in collections but is a load lag.' as what_to_do
    from load_check
    where newest_portfolios < 0.5 * prior_portfolios

    union all
    select 2, 'BLOCKER', 'Portfolios with no loan-level detail',
           'FCT_CASE_COLLECTION vs FCT_PORTFOLIO_SNAPSHOT_MONTHLY',
           to_varchar(n_no_loan_detail) || ' of ' || to_varchar(n_portfolios)
             || ' portfolios have zero loan-level collections in the month',
           'Anything built only on FCT_CASE_COLLECTION omits these portfolios '
             || 'entirely. This is the Intrum PAM (portfolio-aggregate) feed vs the '
             || 'CAT (loan-level) feed. Use monthly_portfolio_performance.sql for totals.'
    from cov where n_no_loan_detail > 0

    union all
    select 3, 'BLOCKER', 'Loan level does not reconcile to portfolio level',
           'FCT_CASE_COLLECTION vs FCT_PORTFOLIO_SNAPSHOT_MONTHLY',
           'loan level sees ' || to_varchar(round(100 * div0(case_gcr, portfolio_gcr), 1))
             || '% of portfolio-level collections; ' || to_varchar(n_differ_gt_1pct)
             || ' portfolios differ by more than 1%',
           'State which basis a collections figure is on. They are not '
             || 'interchangeable and the gap is material.'
    from cov where div0(case_gcr, portfolio_gcr) < 0.99

    union all
    select 4, 'WARNING', 'Collection dates in the future',
           'FCT_CASE_COLLECTION.COLLECTION_DATE',
           to_varchar(n_future) || ' rows, worst is ' || to_varchar(worst_date)
             || ', totalling ' || to_varchar(round(amt_future, 2)),
           'Always bound collection_date <= current_date(). Unbounded these '
             || 'create phantom future months on every time axis. Money impact is small.'
    from bad_dates where n_future > 0

    union all
    select 5, 'BLOCKER', 'Servicer cannot be identified at portfolio level',
           'FCT_PORTFOLIO_SNAPSHOT_MONTHLY.REPORTING_SYSTEM_SK',
           to_varchar(round(100.0 * n_null / nullif(n_rows, 0), 1)) || '% NULL ('
             || to_varchar(n_null) || ' of ' || to_varchar(n_rows) || ' rows)',
           'A join to DIM_REPORTING_SYSTEM returns nothing. Use DEAL_SOURCE_NAME '
             || 'instead, or get servicer from FCT_CASE_COLLECTION at loan level.'
    from repsys_null where n_null > 0

    union all
    select 6, 'WARNING', 'Loan origination data is mostly absent',
           'DIM_CASE (current versions)',
           'origination_date ' || to_varchar(round(100 * p_orig, 1))
             || '% null, original_principal ' || to_varchar(round(100 * p_prin, 1))
             || '% null, secured_flag ' || to_varchar(round(100 * p_sec, 1))
             || '% null, backstop_date ' || to_varchar(round(100 * p_backstop, 1)) || '% null',
           'No vintage analysis and no recovery-on-original-balance is possible '
             || 'across the book. Use DERIVED_DEFAULT_DATE for ageing and '
             || 'SECURITY_CLASS_NAME instead of SECURED_FLAG.'
    from case_nulls where p_orig > 0.5

    union all
    select 7, 'WARNING', 'Borrower join fans out and identity is thin',
           'BRG_CASE_BORROWER + DIM_BORROWER',
           to_varchar(b.n_links) || ' links over ' || to_varchar(b.n_cases)
             || ' case versions (x' || to_varchar(round(b.n_links / nullif(b.n_cases, 0), 2))
             || '); VAT ' || to_varchar(round(100 * d.p_vat, 1)) || '% null, credit_rating '
             || to_varchar(round(100 * d.p_rating, 1)) || '% null, country '
             || to_varchar(round(100 * d.p_country, 1)) || '% null',
           'Joining borrowers to loans multiplies the loan count. Aggregate the '
             || 'bridge before joining, group by BORROWER_ID not BORROWER_SK, and '
             || 'never sum balances across borrowers. DIM_BORROWER holds no name, '
             || 'address or contact field at all.'
    from bridge b cross join borr d

    union all
    select 8, 'WARNING', 'Months with abnormally low loan-level collections',
           'FCT_CASE_COLLECTION',
           to_varchar(n_thin_months) || ' month(s) below half the median: ' || thin_months,
           'Check whether the servicer file for those months landed before '
             || 'reading them as a drop in recovery performance.'
    from gaps where n_thin_months > 0

    union all
    select 9, 'INFO', 'Loans on book with no borrower linked',
           'FCT_CASE_SNAPSHOT_DAILY vs BRG_CASE_BORROWER',
           to_varchar(n_no_borrower) || ' of ' || to_varchar(n_loans)
             || ' loans (' || to_varchar(round(100.0 * n_no_borrower / nullif(n_loans, 0), 2)) || '%)',
           'These loans drop out of any borrower-level analysis. Size the gap '
             || 'before reporting customer counts.'
    from orphan where n_no_borrower > 0

    union all
    select 10, 'WARNING', 'REPORTING_SYSTEM_SK has inconsistent types',
           'NPL_COMMON (schema-wide)',
           to_varchar(n_number_typed) || ' tables type it NUMBER, the rest TEXT',
           'DIM_REPORTING_SYSTEM keys it as TEXT, so the NUMBER-typed forecast '
             || 'tables need an explicit cast to join — and in '
             || 'FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY every row is -1 '
             || '(Unknown) anyway, so servicer attribution is unavailable there.'
    from type_mismatch where n_number_typed > 0

    union all
    select 11, 'INFO', 'Undocumented columns',
           'NPL_COMMON (schema-wide)',
           to_varchar(n_undocumented) || ' of ' || to_varchar(n_cols)
             || ' columns have no description',
           'An empty description means the dbt model has no doc for it, not that '
             || 'it is unimportant. DIM_PORTFOLIO holds GBV and pricing and is '
             || 'almost entirely undocumented.'
    from undocumented where n_undocumented > 0

    union all
    select 12, 'WARNING', 'DECFLOAT columns arrive as dicts, not numbers',
           'NPL_COMMON (schema-wide)',
           to_varchar(n_cols) || ' DECFLOAT columns: ' || cols,
           'pandas receives these as raw exponent/significand dicts in an '
             || 'object column, and the first .sum() fails with "unsupported operand '
             || 'type(s) for +". Cast in SQL — closing_value::number(38,6) — before '
             || 'returning them. datalake''s converter maps Decimal and date only.'
    from decfloat where n_cols > 0

    union all
    select 13, 'WARNING', 'Carrying amount diverges beyond the forecast horizon',
           'FCT_CARRYING_AMOUNT.CLOSING_VALUE',
           to_varchar(n_negative) || ' of ' || to_varchar(n_rows)
             || ' rows have a negative carrying amount, first at '
             || to_varchar(first_negative_period) || ', worst '
             || to_varchar(round(worst_value, 0)) || ' (table projects to '
             || to_varchar(horizon_end) || '); on or before today: '
             || to_varchar(n_negative_in_actuals) || ' rows',
           'CLOSING_VALUE is computed recursively (opening + interest - forecast) '
             || 'and compounds away once the forecast runs out — the table projects '
             || 'to 2041. Actuals are clean. Bound period_end_date <= current_date() '
             || 'and never chart carrying amount to the end of the table.'
    from carrying_divergence where n_negative > 0
)
order by case severity when 'BLOCKER' then 1 when 'WARNING' then 2 else 3 end, id
