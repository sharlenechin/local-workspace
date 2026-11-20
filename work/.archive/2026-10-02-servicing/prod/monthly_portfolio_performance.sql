-- ============================================================================
-- monthly_portfolio_performance — PORTFOLIO × MONTH: the money view that foots.
-- GRAIN: one row per (PORTFOLIO_BK, PERIOD_END_DATE, CURRENCY_ID).
-- ============================================================================
-- Portfolio-level actual collections, servicer costs, net recoveries and
-- carrying amount, month by month — reconciled against what the loan-level
-- data can see. This is the table to trust for totals; the loan- and
-- borrower-grained files go through
-- the case and borrower grain and cannot cover every portfolio.
--
--   Terminal : mise run sql -- work/servicing/prod/monthly_portfolio_performance.sql
--   Notebook : datalake.q("servicing/prod/monthly_portfolio_performance")
--
-- ---------------------------------------------------------------------------
-- GRAIN: one row per (PORTFOLIO_BK, PERIOD_END_DATE, CURRENCY_ID).
--
-- The source fact FCT_PORTFOLIO_SNAPSHOT_MONTHLY is one row per
-- (BATCH_SK, PERIOD_END_DATE) — verified genuinely unique on all 1,544,877
-- rows, so it needs no dedupe. This query rolls those batches up to the
-- portfolio, because that is the grain the loan-level collections, the
-- carrying amount and the loan book can all be compared against. A portfolio
-- can carry up to 3,238 batches in one month, so joining anything
-- portfolio-grained onto the batch grain multiplies its value by the batch
-- count — measured at ~800x before this was regrained. If you need batch
-- detail, drop the roll-up, but then do NOT join CASE_LEVEL, CARRYING or
-- BOOK_SIZE.
--
-- ⚠ CURRENCY IS PART OF THE GRAIN, DELIBERATELY.
-- A single portfolio-month can span up to 5 currencies and 11 countries.
-- Rolling up to the portfolio alone would add EUR to DKK to PLN and produce
-- a meaningless total. Splitting by currency keeps every money column
-- internally consistent. To total across currencies, convert first via
-- COMMON.FCT_EXCHANGE_RATE_MONTHLY — do not just sum.
--
-- Deal, deal source, legal buyer, segment and security class are constant
-- within a portfolio-month (verified) so they survive the roll-up intact.
-- Country and product are not, and are returned as counts plus a list.
--
-- SNAPSHOT_VERSION is NOT a duplicate. It records which reporting vintage a
-- row came from (15 values). The table is already reduced to one row per
-- batch-month; do NOT add a "latest version" filter, which would delete real
-- months. FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED (20.7M rows) is the one
-- that holds every restatement, if you need the audit trail.
-- ---------------------------------------------------------------------------
-- ⚠⚠ THE BIG ONE — 45% OF PORTFOLIOS HAVE NO LOAN-LEVEL DETAIL.
-- Measured for July 2026: of 250 portfolios reporting collections,
--     138 have loan-level collections  ..... EUR 81,992,369 portfolio-level
--     112 have NONE — portfolio only  ...... EUR 14,005,622 portfolio-level
-- That is the Intrum PAM feed (portfolio-level aggregates) versus the CAT
-- feed (loan-level). Any analysis built only on FCT_CASE_COLLECTION silently
-- omits those 112 portfolios. HAS_LOAN_DETAIL below flags each row.
--
-- ⚠⚠ EVEN WHERE BOTH EXIST, THEY DISAGREE.
-- Of the 138 portfolios with both, only 48 reconcile within 1%; 90 differ by
-- more than 1%. In aggregate for July 2026 the loan level sees
-- EUR 73,629,314 against EUR 81,992,369 reported at portfolio level — a
-- shortfall of EUR 8,363,055, or 10.2%. Loan-level collections capture
-- roughly 77% of the money. RECONCILIATION_DIFF and
-- CASE_COVERAGE_PCT below expose this per portfolio-month; do not report a
-- loan-level collection total as "collections" without saying which it is.
--
-- ⚠ REPORTING_SYSTEM_SK IS 100% NULL HERE — all 1,544,877 rows.
-- You cannot attribute portfolio-level collections to a servicer through it,
-- and a join to DIM_REPORTING_SYSTEM returns nothing. DEAL_SOURCE_NAME is
-- the working substitute (LEGACY / ORANGE-HEIMDALL / BLUE-LOKI / GESCOBRO /
-- ORGANIC ORIGINATED) and is fully populated. Servicer proper is only
-- available at loan level, via FCT_CASE_COLLECTION.REPORTING_SYSTEM_SK.
--
-- ⚠ COMMISSION, PASSTHROUGH_COST, UNREMITTED_COLLECTIONS AND
-- NET_CASH_RECOVERIES ARE INTRUM-ONLY. Per the column comments in Snowflake,
-- they are zero for every other servicer — not because those servicers cost
-- nothing, but because the data is not supplied. So NET_CASH_RECOVERIES
-- equals GROSS_CASH_RECOVERIES for non-Intrum portfolios and a cross-servicer
-- net-margin comparison is invalid. IS_NET_MEANINGFUL flags the rows.
--
-- ⚠ THE LATEST MONTH IS PARTIAL. 2026-08-31 has 55 rows across 7 portfolios
-- against 11,812 rows across 250 for 2026-07-31 — about 3% loaded. Default
-- $month_end is 2026-07-31, the last complete month. Moving it forward
-- produces a collapse in every series that is a load lag, not a business
-- event.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY — CHECK IT BEFORE YOU AGGREGATE.
-- The cap exists so an accidental '%' filter cannot pull tens of millions of
-- rows into pandas. But a truncated result still sums, averages and charts
-- perfectly happily, and the total is simply wrong. If the row count comes
-- back exactly equal to $row_limit, assume it was cut: narrow
-- $portfolio_filter, shorten the window, or raise the cap deliberately.
-- ============================================================================

set month_end        = '2026-07-31';
set months_back      = 24;
set portfolio_filter = '%';
set row_limit        = 100000;


with window_bounds as (
    select $month_end::date                                   as end_date,
           dateadd(month, -1 * $months_back, $month_end::date) as start_date
),

portfolio_scope as (
    -- ⚠ THE UNION IS NOT OPTIONAL. IT IS WORTH 2.69% OF COLLECTIONS.
    -- FCT_PORTFOLIO_SNAPSHOT_MONTHLY carries PORTFOLIO_SK = '-1' (the Unknown
    -- sentinel) which does NOT exist in DIM_PORTFOLIO — that dimension is
    -- keyed by hash, so -1 matches nothing. Measured 2026-09-09: 1,853 rows
    -- across 24 months (2024-09-30 .. 2026-08-31) holding EUR 16.92bn of
    -- balance and EUR 38.11m of collections. At 2026-07-31 alone that is
    -- 203 rows, EUR 1.15bn of balance (1.53% of the month) and EUR 2.58m of
    -- collections — 2.69% OF THE MONTH'S COLLECTIONS.
    --
    -- Scoping through DIM_PORTFOLIO with an inner join therefore silently
    -- understated this file, the one that is supposed to foot. Worse, the
    -- forecast facts have ZERO orphan rows, so actual-vs-forecast variance
    -- was distorted in one direction only.
    --
    -- The orphan is essentially portfolio-level: the loan facts carry just
    -- 2 snapshot rows (EUR 29,755) and 1 collection row (EUR 10) for it, and
    -- FCT_CARRYING_AMOUNT and the forecasts carry none.
    --
    -- Labelled rather than hidden. It matches $portfolio_filter = '%' and is
    -- excluded by any narrower filter, which is the behaviour you want.
    select portfolio_sk, portfolio_bk, capex_date, capex_amount, gbv,
           principal, price_gross, price_net, price_percent, flow_type,
           effective_interest_rate, uw_unlevered_irr
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter

    union all

    select f.portfolio_sk,
           '(unknown portfolio ' || f.portfolio_sk || ')' as portfolio_bk,
           null, null, null, null, null, null, null, null, null, null
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    where f.portfolio_sk not in (select portfolio_sk from PROD.NPL_COMMON.DIM_PORTFOLIO)
      and ('(unknown portfolio ' || f.portfolio_sk || ')') like $portfolio_filter
    group by f.portfolio_sk
),

actuals as (
    -- Roll the batch grain up to portfolio x month x currency.
    select
        f.portfolio_sk, f.period_end_date, f.currency_id,
        max(f.deal_sk)            as deal_sk,
        max(f.segment_sk)         as segment_sk,
        max(f.security_class_sk)  as security_class_sk,
        max(f.deal_source_sk)     as deal_source_sk,
        max(f.legal_buyer_sk)     as legal_buyer_sk,
        count(distinct f.batch_sk)  as n_batches,
        count(distinct f.country_id) as n_countries,
        listagg(distinct f.country_id, ',')
            within group (order by f.country_id) as countries,
        count(distinct f.product_sk) as n_products,
        sum(f.total_balance)          as total_balance,
        sum(f.gross_cash_recoveries)  as gross_cash_recoveries,
        sum(f.portfolio_mgmt_fee)     as portfolio_mgmt_fee,
        sum(f.commission)             as commission,
        sum(f.passthrough_cost)       as passthrough_cost,
        sum(f.unremitted_collections) as unremitted_collections,
        sum(f.net_cash_recoveries)    as net_cash_recoveries,
        count(distinct f.snapshot_version) as n_snapshot_versions
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    inner join portfolio_scope as p on p.portfolio_sk = f.portfolio_sk
    cross join window_bounds as w
    where f.period_end_date >  w.start_date
      and f.period_end_date <= w.end_date
    group by 1, 2, 3
),

case_level as (
    -- The same money as the loan-level fact sees it, for reconciliation.
    -- Aggregated to portfolio-month BEFORE joining, so it cannot fan out.
    -- Upper bound guards the 841 future-dated rows.
    select
        c.portfolio_sk,
        last_day(c.collection_date)      as period_end_date,
        c.currency_id,
        sum(c.amount)                    as case_level_collections,
        count(*)                         as case_level_payments,
        count(distinct c.case_sk)        as case_level_paying_loans
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join portfolio_scope as p on p.portfolio_sk = c.portfolio_sk
    cross join window_bounds as w
    where c.collection_date >  w.start_date
      and c.collection_date <= w.end_date
    group by 1, 2, 3
),

carrying as (
    -- Carrying amount is held at portfolio-month, not batch-month, so it is
    -- joined on portfolio and will repeat across the batches of a portfolio.
    -- Aggregate it with max() per portfolio-month, never sum() across batches.
    --
    -- ⚠ THE ::number CASTS ARE LOAD-BEARING — DO NOT REMOVE THEM.
    -- OPENING_VALUE, INTEREST_INCOME, REVALUATION_IMPAIRMENT and
    -- CLOSING_VALUE are Snowflake DECFLOAT. The Arrow path hands DECFLOAT to
    -- pandas as a raw dict of exponent and significand, not a number, and
    -- datalake's type conversion only maps Decimal and date. The
    -- column lands as object dtype and the first .sum() fails with
    -- "unsupported operand type(s) for +: 'dict' and 'dict'". Casting in SQL
    -- is the fix. The same applies to
    -- MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION.ALLOCATED_CARRYING_AMOUNT and
    -- MART_NPL_FLASH_REPORT.CARRYING_AMOUNT.
    --
    -- ⚠ CARRYING AMOUNT IS ONLY MEANINGFUL UP TO TODAY — HENCE THE WHERE.
    -- The table projects to 2041-06-30 and CLOSING_VALUE is computed
    -- recursively (opening + interest - gross forecast). Past the forecast
    -- horizon that recursion compounds and diverges: 792 of 43,773 rows carry
    -- a NEGATIVE closing value, the first as soon as 2026-11-30, and the
    -- schema-wide annual total reaches -EUR 16.2tn by 2040 (worst single row
    -- -EUR 2.88tn). On or before the current date there are ZERO negative
    -- rows and the totals are sane. The `where period_end_date <=
    -- current_date()` below is what keeps this query in the sane window —
    -- removing it silently poisons every carrying-amount column. Never chart
    -- carrying amount to the end of the table.
    select portfolio_sk, period_end_date, currency_id,
           sum(opening_value::number(38, 6))          as opening_value,
           sum(interest_income::number(38, 6))        as interest_income,
           sum(revaluation_impairment::number(38, 6)) as revaluation_impairment,
           sum(closing_value::number(38, 6))          as closing_value,
           sum(gross_forecast)                        as gross_forecast_accounting
    from PROD.NPL_COMMON.FCT_CARRYING_AMOUNT
    where period_end_date <= current_date()
    group by 1, 2, 3
),

book_size as (
    -- Loan count and balance from the loan-level snapshot, for context and
    -- to show which portfolio-months have loan detail at all.
    select portfolio_sk, date_day as period_end_date, currency_id,
           count(*)                as n_loans_on_book,
           sum(outstanding_total)  as loan_level_balance
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    where s.date_day > (select start_date from window_bounds)
      and s.date_day <= (select end_date from window_bounds)
      and s.portfolio_sk in (select portfolio_sk from portfolio_scope)
    group by 1, 2, 3
)

select
    ps.portfolio_bk,
    a.period_end_date,
    a.currency_id,                      -- part of the grain; never sum across
                                        -- currencies without converting first
    a.n_batches,                        -- batches rolled up into this row

    dd.deal_bk,
    dd.deal_alias,
    dd.seller_name,
    ds.deal_source_name,                -- use this for attribution; the
                                        -- reporting-system key is all NULL
    sg.segment_name,
    sc.security_class_name,
    lb.legal_buyer_name,
    lb.ownership_share,
    a.countries,                        -- may be several; see grain note
    a.n_countries,
    a.n_products,

    -- ---- actuals ---------------------------------------------------------
    a.total_balance,
    a.gross_cash_recoveries,
    a.portfolio_mgmt_fee,
    a.commission,                       -- Intrum only
    a.passthrough_cost,                 -- Intrum only
    a.unremitted_collections,           -- Intrum only
    a.net_cash_recoveries,              -- Intrum only; == gross elsewhere
    iff(ds.deal_source_name in ('ORANGE/HEIMDALL', 'BLUE/LOKI'), true, false)
                                        as is_net_meaningful,
    a.gross_cash_recoveries - a.net_cash_recoveries
                                        as total_servicing_cost,
    div0(a.gross_cash_recoveries - a.net_cash_recoveries,
         a.gross_cash_recoveries)       as servicing_cost_pct_of_gross,

    -- ---- loan-level reconciliation ---------------------------------------
    cl.case_level_collections,
    cl.case_level_payments,
    cl.case_level_paying_loans,
    bs.n_loans_on_book,
    bs.loan_level_balance,
    iff(cl.case_level_collections is null, false, true) as has_loan_detail,
    a.gross_cash_recoveries - coalesce(cl.case_level_collections, 0)
                                        as reconciliation_diff,
    div0(coalesce(cl.case_level_collections, 0), a.gross_cash_recoveries)
                                        as case_coverage_pct,

    -- ---- carrying amount / accounting ------------------------------------
    ca.opening_value                    as carrying_opening,
    ca.closing_value                    as carrying_closing,
    ca.interest_income,
    ca.revaluation_impairment,
    ca.gross_forecast_accounting,
    a.gross_cash_recoveries - ca.gross_forecast_accounting
                                        as actual_vs_accounting_forecast,

    -- ---- portfolio economics (repeats across the batches of a portfolio) -
    ps.capex_date,
    ps.capex_amount,
    ps.gbv,
    ps.price_gross,
    ps.price_percent,
    ps.flow_type,
    ps.uw_unlevered_irr,
    datediff(month, ps.capex_date, a.period_end_date) as months_since_capex,

    a.n_snapshot_versions               -- reporting vintages rolled up here;
                                        -- vintage is not a duplicate

from actuals as a
inner join portfolio_scope                      as ps on ps.portfolio_sk = a.portfolio_sk
left  join PROD.NPL_COMMON.DIM_DEAL             as dd on dd.deal_sk = a.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE      as ds on ds.deal_source_sk = a.deal_source_sk
left  join PROD.NPL_COMMON.DIM_SEGMENT          as sg on sg.segment_sk = a.segment_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS   as sc on sc.security_class_sk = a.security_class_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER      as lb on lb.legal_buyer_sk = a.legal_buyer_sk
left  join case_level as cl on cl.portfolio_sk    = a.portfolio_sk
                           and cl.period_end_date = a.period_end_date
                           and cl.currency_id     = a.currency_id
left  join carrying   as ca on ca.portfolio_sk    = a.portfolio_sk
                           and ca.period_end_date = a.period_end_date
                           and ca.currency_id     = a.currency_id
left  join book_size  as bs on bs.portfolio_sk    = a.portfolio_sk
                           and bs.period_end_date = a.period_end_date
                           and bs.currency_id     = a.currency_id
order by ps.portfolio_bk, a.period_end_date, a.currency_id
limit $row_limit
