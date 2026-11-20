-- ============================================================================
-- agg_deal_collection_monthly — AGG: collections per deal per month.
-- GRAIN: one row per (DEAL_BK, MONTH_END, CURRENCY).
-- ============================================================================
-- The same two legs as agg_portfolio_collection_monthly, grouped by deal
-- instead of portfolio. Because it is the same two legs, the two files foot to
-- each other exactly: sum COLLECTIONS_REPORTED_EUR over either for a given
-- month and the total is identical.
--
--   Terminal : mise run sql -- work/servicing/prod/agg_deal_collection_monthly.sql
--   Notebook : datalake.q("servicing/prod/agg_deal_collection_monthly")
--
-- ---------------------------------------------------------------------------
-- THE CHAIN
--
--   base_case                 loan x month-end
--   base_case_collection      loan x day
--        +-- agg_portfolio_collection_monthly
--        +-- agg_deal_collection_monthly        <- YOU ARE HERE
--        +-- agg_vehicle_collection_monthly
--        +-- agg_servicer_collection_monthly
--
-- Drill a deal-month down by filtering agg_portfolio_collection_monthly on
-- DEAL_BK, then base_case_collection on PORTFOLIO_BK + MONTH_END, then
-- base_case on CASE_BK + MONTH_END.
--
-- ---------------------------------------------------------------------------
-- ⚠ DEAL IS NOT A PARENT OF PORTFOLIO — IT IS ANOTHER ATTRIBUTE OF THE FACT.
-- DIM_PORTFOLIO carries no deal key at all; deal lives only on the fact rows,
-- so "which deal is this portfolio in" is only answerable as at a date, and a
-- portfolio can span more than one deal over time. That is why this file is a
-- re-group of the fact rather than a rollup of the portfolio file, and why
-- agg_portfolio_collection_monthly exposes N_DEALS. Rolling portfolio totals
-- up by their "current" deal would assign history to the wrong deal.
--
-- ⚠ WHICH COLUMN GOES ON THE TILE — identical to the portfolio file, and the
-- full measurement lives in base_case_collection's header.
--   COLLECTIONS_REPORTED_EUR   the headline. All deals, all servicers.
--   COLLECTIONS_CASE_EUR       drillable, and incomplete.
-- July 2026: the reported leg covers 72 deals, the case leg only 50. So 22
-- deals show a real reported figure and a NULL drill-down. HAS_CASE_DETAIL
-- says which. Never present the case column as the deal's collections.
--
-- ⚠ COVERAGE_PCT IS COMPLETENESS, NOT PERFORMANCE. Never chart it as
-- collection efficiency.
--
-- ---------------------------------------------------------------------------
-- PERIOD FLAGS: IS_LM  IS_LM_1  IS_IN_L3M  IS_IN_L6M  IS_LM_12  IS_LM_13
-- MONTHS_BEFORE_LM. "LM" is the latest COMPLETE month. For "Avg L3M", filter
-- IS_IN_L3M and AVERAGE the monthly totals.
--
-- ============================================================================
-- GUARDS — the same set as agg_portfolio_collection_monthly; see that file
-- for the measured cost of removing each.
-- ============================================================================
-- G1 Incomplete months excluded (the newest is part-loaded: 2026-08-31 showed
--    7 portfolios and EUR 3.06m against July's 250 and EUR 41.28m).
-- G2 FULL OUTER JOIN between the legs — a deal-month in only one feed must
--    still produce a row.
-- G3 DEAL_SK = '-1' IS NOT IN DIM_DEAL. It shares the 203 orphan rows / EUR
--    1.15bn of balance with four other keys on the portfolio fact. LEFT
--    joined and labelled '(unknown deal -1)'.
-- G4 The key keeps its sk when the dimension has no row — collapsing orphans
--    to one 'Unknown' breaks the grain.
-- G5 FX: 'PMI', multiplied not inverted, identity row at 1.0; flows at
--    MONTHLY_AVG, stocks at ULTIMO_VALUE.
-- G6 Currency is in the grain. _LOCAL never sums across rows; _EUR does.
-- G7 Paying loans counted on CASE_BK, not CASE_SK (EUR 128.2m/year).
-- G8 collection_date <= current_date() — the year-4570 rows.
-- G9 Every '(unknown ...)' label coalesce's the surrogate key itself: || is
--    NULL-propagating, so a NULL sk would strip the label off a row that
--    keeps its money. Rare but real (1 NULL DEAL_SK on the collection fact at
--    2026-07-31). base_case_collection G9 has the full measurement.
--
-- ⚠ FX coverage starts 2018-01-31; before it every _EUR column is NULL, not
-- zero. Filter IS_EUR_COMPLETE on every tile.
--
--
-- RUNTIME on NPL_ANALYST_WH (X-Small), measured 2026-09-11 with the defaults
-- above: 14s, 2,028 rows over 26 months. Interactive.
-- No row cap: this aggregates inside Snowflake.
-- ============================================================================

set months_back = 26;

set deal_filter = '%';


with complete_months as (
    select period_end_date
    from (select period_end_date,
                 count(distinct portfolio_sk) as n,
                 lag(count(distinct portfolio_sk))
                     over (order by period_end_date) as prev_n
          from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
          where period_end_date <= current_date()
          group by 1)
    where prev_n is null or n >= 0.5 * prev_n
),

anchor as (select max(period_end_date) as lm from complete_months),

window_months as (
    select cm.period_end_date as month_end
    from complete_months cm cross join anchor a
    where cm.period_end_date >  dateadd(month, -1 * least($months_back, 120), a.lm)
      and cm.period_end_date <= a.lm
),

fx as (
    select date_day as month_end, quote_currency as ccy,
           monthly_avg as rate_flow, ultimo_value as rate_stock
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and rate_type = 'PMI' and quote_currency <> 'EUR'
    union all
    select date_day, 'EUR', 1, 1
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and quote_currency = 'EUR'
),

-- LEG 1: base_case_collection, grouped to the deal.
case_leg as (
    select
        c.deal_sk,
        last_day(c.collection_date)          as month_end,
        c.currency_id                        as currency,
        sum(c.amount)                        as collections_case_local,
        sum(iff(c.amount > 0, c.amount, 0))  as receipts_case_local,
        sum(iff(c.amount < 0, c.amount, 0))  as reversals_case_local,
        count(distinct dc.case_bk)           as n_paying_loans,   -- G7
        count(*)                             as n_payments,
        count(distinct c.portfolio_sk)       as n_portfolios_case
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join PROD.NPL_COMMON.DIM_CASE as dc on dc.case_sk = c.case_sk
    inner join window_months as w on w.month_end = last_day(c.collection_date)
    where c.collection_date <= current_date()        -- G8
    group by 1, 2, 3
),

-- LEG 2: the portfolio fact, grouped to the deal. The published figure.
reported_leg as (
    select
        f.deal_sk,
        f.period_end_date                    as month_end,
        f.currency_id                        as currency,
        sum(f.gross_cash_recoveries)         as collections_reported_local,
        sum(f.total_balance)                 as balance_reported_local,
        count(distinct f.portfolio_sk)       as n_portfolios,
        count(distinct f.batch_sk)           as n_batches,
        max(f.deal_source_sk)                as deal_source_sk,
        max(f.legal_buyer_sk)                as legal_buyer_sk,
        max(f.country_id)                    as country_id,
        count(distinct f.legal_buyer_sk)     as n_vehicles
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    inner join window_months as w on w.month_end = f.period_end_date
    group by 1, 2, 3
),

joined as (   -- G2
    select
        coalesce(r.deal_sk,   k.deal_sk)   as deal_sk,
        coalesce(r.month_end, k.month_end) as month_end,
        coalesce(r.currency,  k.currency)  as currency,
        r.collections_reported_local, r.balance_reported_local,
        r.n_portfolios, r.n_batches, r.n_vehicles,
        r.deal_source_sk, r.legal_buyer_sk, r.country_id,
        k.collections_case_local, k.receipts_case_local, k.reversals_case_local,
        k.n_paying_loans, k.n_payments, k.n_portfolios_case
    from reported_leg as r
    full outer join case_leg as k
        on  k.deal_sk   = r.deal_sk
        and k.month_end = r.month_end
        and k.currency  = r.currency
)

select
    -- ---- the key ---------------------------------------------------------
    coalesce(dd.deal_bk, '(unknown deal ' || coalesce(j.deal_sk, 'null key') || ')') as deal_bk,  -- G3/G4
    dd.deal_alias,
    dd.deal_name,
    j.month_end,
    j.currency,

    -- ---- time ------------------------------------------------------------
    year(j.month_end)                               as year,
    monthname(j.month_end)                          as month_name,
    datediff(month, j.month_end, a.lm)              as months_before_lm,
    j.month_end =  a.lm                             as is_lm,
    j.month_end =  dateadd(month, -1,  a.lm)        as is_lm_1,
    j.month_end >  dateadd(month, -3,  a.lm)        as is_in_l3m,
    j.month_end >  dateadd(month, -6,  a.lm)        as is_in_l6m,
    j.month_end =  dateadd(month, -12, a.lm)        as is_lm_12,
    j.month_end =  dateadd(month, -13, a.lm)        as is_lm_13,

    -- ---- REPORTED: the headline. Sum this. -------------------------------
    j.collections_reported_local * f.rate_flow      as collections_reported_eur,
    j.balance_reported_local     * f.rate_stock     as balance_reported_eur,

    -- ---- DRILL-DOWN: loan-level, incomplete. -----------------------------
    j.collections_case_local     * f.rate_flow      as collections_case_eur,
    j.receipts_case_local        * f.rate_flow      as receipts_case_eur,
    j.reversals_case_local       * f.rate_flow      as reversals_case_eur,
    j.n_paying_loans,
    j.n_payments,

    -- ---- how much of this row can be drilled into ------------------------
    div0null(j.collections_case_local, j.collections_reported_local)
                                                    as coverage_pct,
    j.collections_case_local is not null            as has_case_detail,

    -- ---- context ---------------------------------------------------------
    dd.seller_name,
    dd.deal_close_date,
    j.n_portfolios,                                 -- reported leg
    j.n_portfolios_case,                            -- case leg; lower
    j.n_batches,
    j.n_vehicles,                                   -- >1 means the vehicle
                                                    -- name below is one of
                                                    -- several
    coalesce(lb.legal_buyer_bk, '(unknown vehicle ' || coalesce(j.legal_buyer_sk, 'null key') || ')')
                                                    as vehicle_bk,
    lb.legal_buyer_name                             as vehicle_name,
    coalesce(ds.deal_source_name, 'Unknown')        as deal_source,
    case when ds.deal_source_name = 'LEGACY' and j.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and j.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                          as servicer,
    j.country_id,
    coalesce(co.country_name, j.country_id, 'Unknown') as country_name,

    -- ---- unconverted; never sum across currencies ------------------------
    j.collections_reported_local,
    j.collections_case_local,
    j.balance_reported_local,

    -- ---- trust flag ------------------------------------------------------
    f.rate_flow is not null and f.rate_stock is not null as is_eur_complete

from joined as j
cross join anchor as a
left join fx as f on f.ccy = j.currency and f.month_end = j.month_end
left join PROD.NPL_COMMON.DIM_DEAL         as dd on dd.deal_sk        = j.deal_sk
left join PROD.NPL_COMMON.DIM_DEAL_SOURCE  as ds on ds.deal_source_sk = j.deal_source_sk
left join PROD.NPL_COMMON.DIM_LEGAL_BUYER  as lb on lb.legal_buyer_sk = j.legal_buyer_sk
left join PROD.COMMON.DIM_COUNTRY          as co on co.iso_alpha2_code = j.country_id
where coalesce(dd.deal_bk, '(unknown deal ' || coalesce(j.deal_sk, 'null key') || ')') like $deal_filter
order by j.month_end desc, collections_reported_eur desc nulls last
