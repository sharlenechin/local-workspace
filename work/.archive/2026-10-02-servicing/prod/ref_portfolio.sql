-- ============================================================================
-- ref_portfolio — REFERENCE: one row per portfolio we have acquired.
-- GRAIN: one row per PORTFOLIO_BK. Verified genuinely unique.
-- ============================================================================
-- The "what did we buy" sheet. Acquisition economics from DIM_PORTFOLIO, plus
-- the dimensions that only exist on the fact tables, plus revaluation events
-- and current book size — everything that is true of a portfolio as a whole.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/ref_portfolio.sql
--   Notebook  : datalake.q("servicing/prod/ref_portfolio")
--
-- ---------------------------------------------------------------------------
-- GRAIN verified 2026-09-09: DIM_PORTFOLIO has 264 rows, 264 distinct
-- PORTFOLIO_SK and 264 distinct PORTFOLIO_BK. Not an SCD — one row per
-- portfolio, full stop. (264, not the 250 that appear in a given month: the
-- rest have no rows in the reporting month used below.)
--
-- ⚠ DIM_PORTFOLIO CARRIES NO DEAL, BATCH, SEGMENT OR BUYER KEY.
-- Those dimensions live only on the fact tables, so "which deal is this
-- portfolio in" is only answerable *as at a date*. The DEAL_* / BUYER_* /
-- SECURITY_* columns below are resolved from the portfolio-level fact at
-- $month_end, and N_DEALS / N_SECURITY_CLASSES tell you when a portfolio
-- spans more than one — in which case the single name shown is one of
-- several, not the answer. This is the same limitation ref_loan documents
-- for DIM_CASE.
--
-- ⚠ CURRENCY AND COUNTRY ARE NOT ONE PER PORTFOLIO.
-- A portfolio-month can span up to 5 currencies and 11 countries. The counts
-- are exposed rather than a single label. Never total money across
-- portfolios without checking N_CURRENCIES first — see ref_fx_rate.sql to
-- convert.
--
-- ⚠ THE ::number CAST ON REVALUATION IS LOAD-BEARING.
-- FCT_REVALUATION.NEW_CLOSING_VALUE is DECFLOAT, which reaches pandas as a
-- raw exponent/significand dict and breaks the first .sum(). Cast in SQL.
--
-- No row cap: 264 rows is the whole table.
-- ============================================================================

-- The month used to resolve the fact-only dimensions and book size. See
-- ref_loan for why 2026-08-31 is not the default: it exists but only ~3% of
-- portfolios have loaded.
set month_end = '2026-07-31';

set portfolio_filter = '%';


with dims_at_month as (
    -- The fact-only dimensions, as at $month_end. Counts come first so an
    -- ambiguous portfolio is visible rather than silently collapsed.
    select
        f.portfolio_sk,
        count(*)                             as n_batch_rows,
        count(distinct f.batch_sk)           as n_batches,
        count(distinct f.deal_sk)            as n_deals,
        count(distinct f.security_class_sk)  as n_security_classes,
        count(distinct f.currency_id)        as n_currencies,
        count(distinct f.country_id)         as n_countries,
        listagg(distinct f.currency_id, ',')
            within group (order by f.currency_id) as currencies,
        listagg(distinct f.country_id, ',')
            within group (order by f.country_id)  as countries,
        max(f.deal_sk)                       as deal_sk,
        max(f.deal_source_sk)                as deal_source_sk,
        max(f.security_class_sk)             as security_class_sk,
        max(f.legal_buyer_sk)                as legal_buyer_sk,
        max(f.segment_sk)                    as segment_sk,
        sum(f.total_balance)                 as portfolio_total_balance,
        sum(f.gross_cash_recoveries)         as gross_cash_recoveries_in_month
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    where f.period_end_date = $month_end::date
    group by 1
),

book_at_month as (
    -- Loan-level size. Absent for the ~112 portfolios that report only as
    -- aggregates (the Intrum PAM feed) — see base_data_quality.sql.
    select portfolio_sk,
           count(*)               as n_loans_on_book,
           sum(outstanding_total) as loan_level_balance
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
    where date_day = $month_end::date
    group by 1
),

revaluations as (
    -- One row per (PORTFOLIO_SK, REVALUATION_DATE) — verified unique on all
    -- 60 rows, covering 50 portfolios, 2025-12-31 .. 2026-09-30. Reduced to
    -- first/last/count here to stay 1:1 with the portfolio.
    select portfolio_sk,
           count(*)                                   as n_revaluations,
           min(revaluation_date)                      as first_revaluation_date,
           max(revaluation_date)                      as last_revaluation_date,
           max(new_closing_value::number(38, 6))      as latest_new_closing_value
    from PROD.NPL_COMMON.FCT_REVALUATION
    group by 1
),

carrying_at_month as (
    -- Portfolio-level book value at $month_end. Unique on (portfolio,
    -- period) — verified on all 43,773 rows — so no aggregation is needed
    -- beyond the cast. Bounded to today for the same reason
    -- monthly_portfolio_performance is: past the forecast horizon the
    -- recursive CLOSING_VALUE diverges and goes negative.
    select portfolio_sk,
           opening_value::number(38, 6) as carrying_opening,
           closing_value::number(38, 6) as carrying_closing
    from PROD.NPL_COMMON.FCT_CARRYING_AMOUNT
    where period_end_date = $month_end::date
      and period_end_date <= current_date()
)

select
    p.portfolio_bk,
    $month_end::date                     as as_of_month_end,

    -- ---- what it is (as at $month_end; see header) -----------------------
    dd.deal_bk,
    dd.deal_alias,
    dd.seller_name,
    dd.deal_close_date,
    ds.deal_source_name,                 -- use this for servicer attribution
                                         -- at portfolio level; the
                                         -- reporting-system key is all NULL
    sg.segment_name,
    sc.security_class_name,
    lb.legal_buyer_name,
    lb.ownership_share,
    lb.is_on_balance_sheet,
    d.n_deals,                           -- >1 means the name above is one of
    d.n_security_classes,                -- several, not the answer
    p.flow_type,

    -- ---- geography and currency -----------------------------------------
    d.currencies,
    d.n_currencies,                      -- ⚠ >1 means money is not addable
    d.countries,
    d.n_countries,
    p.currency_id                        as dim_currency_id,

    -- ---- acquisition economics ------------------------------------------
    p.capex_date,
    p.capex_amount,
    p.gbv,
    p.principal,
    p.price_gross,
    p.price_net,
    p.price_accounting,
    p.price_percent,
    p.capitalized_costs,
    p.interim_collections,
    p.effective_interest_rate,
    p.uw_unlevered_irr,
    p.pnl,
    p.gmm,
    p.nmm,
    datediff(month, p.capex_date, $month_end::date) as months_since_capex,

    -- ---- size now --------------------------------------------------------
    d.n_batches,
    d.portfolio_total_balance,
    d.gross_cash_recoveries_in_month,
    b.n_loans_on_book,
    b.loan_level_balance,
    b.n_loans_on_book is not null        as has_loan_detail,
    ca.carrying_opening,
    ca.carrying_closing,

    -- ---- revaluation -----------------------------------------------------
    coalesce(r.n_revaluations, 0)        as n_revaluations,
    r.first_revaluation_date,
    r.last_revaluation_date,
    r.latest_new_closing_value

from PROD.NPL_COMMON.DIM_PORTFOLIO as p
left join dims_at_month                        as d  on d.portfolio_sk  = p.portfolio_sk
left join book_at_month                        as b  on b.portfolio_sk  = p.portfolio_sk
left join revaluations                         as r  on r.portfolio_sk  = p.portfolio_sk
left join carrying_at_month                    as ca on ca.portfolio_sk = p.portfolio_sk
left join PROD.NPL_COMMON.DIM_DEAL             as dd on dd.deal_sk           = d.deal_sk
left join PROD.NPL_COMMON.DIM_DEAL_SOURCE      as ds on ds.deal_source_sk    = d.deal_source_sk
left join PROD.NPL_COMMON.DIM_SEGMENT          as sg on sg.segment_sk        = d.segment_sk
left join PROD.NPL_COMMON.DIM_SECURITY_CLASS   as sc on sc.security_class_sk = d.security_class_sk
left join PROD.NPL_COMMON.DIM_LEGAL_BUYER      as lb on lb.legal_buyer_sk    = d.legal_buyer_sk
where p.portfolio_bk like $portfolio_filter
order by p.capex_date desc nulls last, p.portfolio_bk
