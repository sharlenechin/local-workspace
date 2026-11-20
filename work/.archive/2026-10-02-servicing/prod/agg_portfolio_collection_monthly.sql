-- ============================================================================
-- agg_portfolio_collection_monthly — AGG: collections per portfolio per month.
-- GRAIN: one row per (PORTFOLIO_BK, MONTH_END, CURRENCY).
-- ============================================================================
-- First level up from the loan. Two collection figures on every row — the
-- REPORTED one (portfolio fact, the headline) and the DRILL-DOWN one (the sum
-- of base_case_collection) — plus the coverage ratio between them, so the
-- difference is on the row rather than in somebody's head.
--
--   Terminal : mise run sql -- work/servicing/prod/agg_portfolio_collection_monthly.sql
--   Notebook : datalake.q("servicing/prod/agg_portfolio_collection_monthly")
--
-- ---------------------------------------------------------------------------
-- THE CHAIN
--
--   base_case                 loan x month-end
--   base_case_collection      loan x day
--        |
--        +-- agg_portfolio_collection_monthly   <- YOU ARE HERE
--        +-- agg_deal_collection_monthly
--        +-- agg_vehicle_collection_monthly
--        +-- agg_servicer_collection_monthly
--
-- All four are the SAME two legs grouped by a different key, so they foot to
-- each other exactly by construction: sum COLLECTIONS_REPORTED_EUR over any of
-- them for a given month and you get the same number. Drill from any of them
-- down to base_case_collection on (the key, MONTH_END) and to base_case on
-- (CASE_BK, MONTH_END).
--
-- In dbt: the case leg is `ref('base_case_collection')`, the reported leg is
-- `ref('fct_npl_portfolio_snapshot_monthly')`. They are deliberately NOT
-- unioned into one column — see below.
--
-- ---------------------------------------------------------------------------
-- ⚠⚠ WHICH COLUMN GOES ON THE TILE ⚠⚠
--
--   COLLECTIONS_REPORTED_EUR   the headline. Every portfolio, every servicer.
--                              This is the number that equals the published
--                              figure. USE THIS unless you are drilling.
--   COLLECTIONS_CASE_EUR       the loan-level sum. Drillable to the loan,
--                              and INCOMPLETE — see below.
--
-- They are not two estimates of one thing to be averaged or reconciled to
-- zero. They are two different measurements at two grains, and the gap is
-- structural. Measured 2026-09-11 for July 2026, the latest complete month:
--
--   Reported (portfolio fact)   EUR 41,282,117.95   250 portfolios
--   Case level                  EUR 24,842,484.52   138 portfolios   60.18%
--
--   both feeds            138 pf   24,842,484.52 vs 27,255,688.96  = 91.15%
--   portfolio fact only   112 pf            0.00 vs 14,026,428.99  =  0.00%
--
-- Two separate shortfalls:
--   1. 112 portfolios report NO loan detail at all (the Intrum PAM feed
--      arrives as portfolio aggregates). They are not zero-collecting.
--      HAS_CASE_DETAIL is false on those rows — filter on it before you quote
--      a coverage average, or the 112 zeros drag it down meaninglessly.
--   2. On the 138 that do report both, loan level is 91.15% of portfolio
--      level. That is finding 2.12: the two levels are definitionally
--      different, the ratio varies by servicer (87%-146% on balances), and it
--      will never close. Do not open a ticket for it.
--
-- ⚠ COVERAGE_PCT IS A DATA-COMPLETENESS RATIO, NOT A BUSINESS METRIC. It says
-- how much of a month we can drill into. It is not "collection efficiency"
-- and must never be charted as performance.
--
-- ---------------------------------------------------------------------------
-- PERIOD FLAGS, so no date logic is needed in the BI tool. "LM" is the latest
-- COMPLETE month, not the latest calendar month.
--   IS_LM  IS_LM_1  IS_IN_L3M  IS_IN_L6M  IS_LM_12  IS_LM_13  MONTHS_BEFORE_LM
-- To show "Avg L3M", filter IS_IN_L3M and take the AVERAGE of the monthly
-- totals — not the sum over 3, which differs whenever a month is missing.
--
-- ============================================================================
-- GUARDS
-- ============================================================================
-- G1 INCOMPLETE MONTHS ARE EXCLUDED ENTIRELY. The newest month is routinely
--    part-loaded: at 2026-09-09, 2026-08-31 held 7 portfolios and EUR 3.06m
--    against July's 250 and EUR 41.28m — a 93% "collapse" that is purely a
--    load lag. A month counts as complete if it has at least half the
--    previous month's portfolio count.
-- G2 FULL OUTER JOIN BETWEEN THE LEGS, never inner and never left-from-
--    reported. A portfolio-month present in only one leg must still produce a
--    row: inner drops the 112 aggregate-only portfolios (EUR 14.03m in July
--    alone), and left-from-reported would hide a case-only row, which is the
--    signal that the two feeds disagree about scope.
-- G3 PORTFOLIO_SK = '-1' IS NOT IN DIM_PORTFOLIO and is worth 2.69% of a
--    month's collections (EUR 2,579,774.05 and EUR 1.15bn of balance at
--    2026-07-31). The dimension is keyed by hash, so the sentinel matches
--    nothing and an inner join drops it silently. It is LEFT joined and
--    labelled '(unknown portfolio -1)' — visible, countable, and excluded by
--    any narrower $portfolio_filter. Worse than the size: the actuals fact
--    carries it and the forecasts do NOT, so dropping it distorts
--    actual-vs-forecast in one direction only.
-- G4 THE KEY KEEPS ITS SK WHEN THE DIMENSION HAS NO ROW. Collapsing every
--    orphan to one 'Unknown' label breaks the grain — that exact mistake gave
--    3 duplicate rows per batch-month in agg_collections_monthly, caught by a
--    grain check and not by eye.
-- G5 FX: 'PMI', MULTIPLIED not inverted, identity row at 1.0. Flows at
--    MONTHLY_AVG, stocks at ULTIMO_VALUE. Inverting is a 122x error on SEK;
--    'FIXED' converts nothing; without the identity row every EUR row — the
--    largest block — joins to NULL and vanishes.
-- G6 CURRENCY IS IN THE GRAIN. A portfolio-month can span up to 5 currencies.
--    _LOCAL columns are unconverted and must never be summed across rows;
--    _EUR columns are safe. This is also why this file disagrees with
--    MART_NPL_FLASH_REPORT, which collapses currency with any_value() on 13
--    portfolio-months — that disagreement IS the explanation, not a bug.
-- G7 PAYING LOANS COUNTED ON CASE_BK, not CASE_SK. The versioned key loses
--    EUR 128.2m of collections a year book-wide (15.01% on ORANGE/HEIMDALL)
--    and double-counts loans the moment two months are unioned.
-- G8 collection_date <= current_date(). 841 rows are future-dated, out to the
--    year 4570, and create phantom months on any time axis.
-- G9 Every '(unknown ...)' label coalesce's the surrogate key itself: || is
--    NULL-propagating, so a NULL sk would strip the label off a row that
--    keeps its money. Rare but real (1 NULL DEAL_SK on the collection fact at
--    2026-07-31). base_case_collection G9 has the full measurement.
--
-- ⚠ FX COVERAGE STARTS 2018-01-31. Before it every _EUR column is NULL, not
-- zero — IS_EUR_COMPLETE flags it. 231 portfolio-months fall outside.
-- Filter IS_EUR_COMPLETE on every tile.
--
--
-- RUNTIME on NPL_ANALYST_WH (X-Small), measured 2026-09-11 with the defaults
-- above: 17s, 3,203 rows over 26 months, all 250 portfolios. Interactive enough to sit behind a BI extract.
-- No row cap: this aggregates inside Snowflake and returns a few thousand
-- rows. Raise $months_back rather than reaching for base_case_collection.
-- ============================================================================

set months_back = 26;   -- 26 so LM-13 is always present

-- '%' is all portfolios and is the intended default here — the result is
-- small. Narrow it to drill: 'LOK-DE%'
set portfolio_filter = '%';


with complete_months as (
    -- G1.
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
    -- G5. Both rates: flows at monthly_avg, stocks at ultimo_value.
    select date_day as month_end, quote_currency as ccy,
           monthly_avg as rate_flow, ultimo_value as rate_stock
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and rate_type = 'PMI' and quote_currency <> 'EUR'
    union all
    select date_day, 'EUR', 1, 1
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and quote_currency = 'EUR'
),

-- ---- LEG 1: the drill-down leg ------------------------------------------
-- This is base_case_collection grouped to the portfolio. It is deliberately
-- the same expression, not a similar one: in dbt it becomes
-- `select ... from {{ ref('base_case_collection') }} group by 1,2,3`.
case_leg as (
    select
        c.portfolio_sk,
        last_day(c.collection_date)          as month_end,
        c.currency_id                        as currency,
        sum(c.amount)                        as collections_case_local,
        sum(iff(c.amount > 0, c.amount, 0))  as receipts_case_local,
        sum(iff(c.amount < 0, c.amount, 0))  as reversals_case_local,
        count(distinct dc.case_bk)           as n_paying_loans,   -- G7
        count(*)                             as n_payments
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join PROD.NPL_COMMON.DIM_CASE as dc on dc.case_sk = c.case_sk
    inner join window_months as w on w.month_end = last_day(c.collection_date)
    where c.collection_date <= current_date()        -- G8
    group by 1, 2, 3
),

-- ---- LEG 2: the reported leg --------------------------------------------
-- The portfolio fact. Unique on (batch, period) and rolled to the portfolio
-- here. This is the published figure.
reported_leg as (
    select
        f.portfolio_sk,
        f.period_end_date                    as month_end,
        f.currency_id                        as currency,
        sum(f.gross_cash_recoveries)         as collections_reported_local,
        sum(f.total_balance)                 as balance_reported_local,
        count(distinct f.batch_sk)           as n_batches,
        max(f.deal_sk)                       as deal_sk,
        max(f.deal_source_sk)                as deal_source_sk,
        max(f.legal_buyer_sk)                as legal_buyer_sk,
        max(f.country_id)                    as country_id,
        count(distinct f.deal_sk)            as n_deals
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    inner join window_months as w on w.month_end = f.period_end_date
    group by 1, 2, 3
),

-- G2: full outer, so a portfolio-month present in only one feed survives.
joined as (
    select
        coalesce(r.portfolio_sk, k.portfolio_sk) as portfolio_sk,
        coalesce(r.month_end,    k.month_end)    as month_end,
        coalesce(r.currency,     k.currency)     as currency,
        r.collections_reported_local,
        r.balance_reported_local,
        r.n_batches,
        r.n_deals,
        r.deal_sk, r.deal_source_sk, r.legal_buyer_sk, r.country_id,
        k.collections_case_local,
        k.receipts_case_local,
        k.reversals_case_local,
        k.n_paying_loans,
        k.n_payments
    from reported_leg as r
    full outer join case_leg as k
        on  k.portfolio_sk = r.portfolio_sk
        and k.month_end    = r.month_end
        and k.currency     = r.currency
)

select
    -- ---- the key ---------------------------------------------------------
    -- G3 / G4: the sentinel and any orphan keep their sk in the label.
    coalesce(dp.portfolio_bk, '(unknown portfolio ' || coalesce(j.portfolio_sk, 'null key') || ')')
                                                    as portfolio_bk,
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

    -- ---- DRILL-DOWN: the loan-level sum. Incomplete — read the header. ---
    j.collections_case_local     * f.rate_flow      as collections_case_eur,
    j.receipts_case_local        * f.rate_flow      as receipts_case_eur,
    j.reversals_case_local       * f.rate_flow      as reversals_case_eur,
    j.n_paying_loans,
    j.n_payments,

    -- ---- how much of this row can be drilled into ------------------------
    -- ⚠ completeness, NOT performance. Meaningless where HAS_CASE_DETAIL is
    -- false, and never equal to 1 even where it is true (see the header).
    div0null(j.collections_case_local, j.collections_reported_local)
                                                    as coverage_pct,
    j.collections_case_local is not null            as has_case_detail,

    -- ---- context ---------------------------------------------------------
    coalesce(dd.deal_bk, '(unknown deal ' || coalesce(j.deal_sk, 'null key') || ')')   as deal_bk,
    dd.deal_alias,
    dd.seller_name,
    j.n_deals,                                      -- >1 means the deal name
                                                    -- above is one of several
    coalesce(lb.legal_buyer_bk, '(unknown vehicle ' || coalesce(j.legal_buyer_sk, 'null key') || ')')
                                                    as vehicle_bk,
    lb.legal_buyer_name                             as vehicle_name,
    coalesce(ds.deal_source_name, 'Unknown')        as deal_source,
    case when ds.deal_source_name = 'LEGACY' and j.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and j.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                          as servicer,
    j.country_id,
    coalesce(co.country_name, j.country_id, 'Unknown') as country_name,
    j.n_batches,
    dp.capex_date,
    dp.flow_type,

    -- ---- unconverted; never sum across currencies ------------------------
    j.collections_reported_local,
    j.collections_case_local,
    j.balance_reported_local,

    -- ---- trust flag ------------------------------------------------------
    f.rate_flow is not null and f.rate_stock is not null as is_eur_complete

from joined as j
cross join anchor as a
left join fx as f on f.ccy = j.currency and f.month_end = j.month_end
-- LEFT, always (G3).
left join PROD.NPL_COMMON.DIM_PORTFOLIO    as dp on dp.portfolio_sk   = j.portfolio_sk
left join PROD.NPL_COMMON.DIM_DEAL         as dd on dd.deal_sk        = j.deal_sk
left join PROD.NPL_COMMON.DIM_DEAL_SOURCE  as ds on ds.deal_source_sk = j.deal_source_sk
left join PROD.NPL_COMMON.DIM_LEGAL_BUYER  as lb on lb.legal_buyer_sk = j.legal_buyer_sk
-- ISO code, not the hash key.
left join PROD.COMMON.DIM_COUNTRY          as co on co.iso_alpha2_code = j.country_id
where coalesce(dp.portfolio_bk, '(unknown portfolio ' || coalesce(j.portfolio_sk, 'null key') || ')')
      like $portfolio_filter
order by j.month_end desc, collections_reported_eur desc nulls last
