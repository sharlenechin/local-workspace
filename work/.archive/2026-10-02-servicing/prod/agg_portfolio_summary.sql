-- ============================================================================
-- agg_portfolio_summary — the dashboard dataset. EVERY MONEY COLUMN IS EUR.
-- GRAIN: one row per (PORTFOLIO_BK, PERIOD_END_DATE, CURRENCY_ID).
-- ============================================================================
-- Built for a BI tool to sit on: portfolios acquired, collections, forecast
-- and book value, already converted to EUR, with the columns you filter by
-- (country, currency, servicer, deal, buyer, security class) on every row.
--
-- Currency stays in the grain so you can still filter by the ORIGINAL
-- currency, but every *_EUR column is safe to sum across rows. Never sum the
-- *_LOCAL columns across currencies.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/agg_portfolio_summary.sql
--   Notebook  : datalake.q("servicing/prod/agg_portfolio_summary")
--
-- ---------------------------------------------------------------------------
-- This is an AGGREGATE over the base layer. It inherits every guard those
-- files carry, and they are listed in .claude/agents/query-helper.md (Part 3). The four that
-- are load-bearing HERE:
--
--   1. The '(unknown portfolio -1)' union. PORTFOLIO_SK '-1' is not in
--      DIM_PORTFOLIO, and dropping it loses 2.69% of a month's collections.
--   2. LEFT joins on every dimension. Six keys carry an orphan '-1'; an inner
--      join drops up to EUR 10.67bn.
--   3. FX rate_type = 'PMI', MULTIPLIED not inverted, with the EUR identity
--      row unioned in. 'FIXED' converts nothing; inverting is a 122x error.
--   4. period_end_date <= current_date(), or carrying amount goes negative
--      past the forecast horizon.
--
-- ⚠ FX COVERAGE ENDS 2026-08-31 and starts 2018-01-31. Outside that range the
-- rate is NULL and the *_EUR columns are NULL — not zero. IS_EUR_COMPLETE
-- flags the row. Filter on it before quoting a total, or a missing rate
-- silently shrinks the number.
--
-- ⚠ COLLECTIONS USE THE MONTHLY AVERAGE RATE, BALANCES USE MONTH-END.
-- A month of receipts converted at the closing rate is misstated; a
-- point-in-time balance converted at an average rate is too. This is a
-- deliberate choice, not an inconsistency.
--
-- ⚠ BOOK SIZE IS PORTFOLIO-LEVEL ONLY. Do not add loan-level balances to
-- these figures — the two levels disagree by up to 46% depending on servicer
-- and never reconcile. See agg_loan_detail.sql for the loan view.
--
-- Added 2026-09-09 for the servicing dashboard:
--   UW_FORECAST_EUR / VARIANCE_VS_UNDERWRITING_EUR — the UNDERWRITING plan
--     (what we assumed when we bought), one vintage, 251 portfolios, months
--     from 2025-06-30 only. NULL before that: it is absent, not zero.
--     FORECAST_EUR remains the ACCOUNTING (current live) forecast. The two
--     answer different questions; do not average them.
--   CAPEX_EUR / GBV_EUR / PRICE_GROSS_LOCAL — acquisition economics from
--     DIM_PORTFOLIO, converted at the month-end rate of the capex month
--     (DIM_PORTFOLIO.CURRENCY_ID is the portfolio currency). 10 of 264
--     portfolios have no capex date and stay NULL. These repeat on every
--     month row of a portfolio: filter or threshold on them, never sum them
--     across months.
-- ============================================================================

set months_back = 24;
set portfolio_filter = '%';


with bounds as (
    select least($months_back, 120)                                as n_months,
           dateadd(month, -1 * least($months_back, 120), current_date()) as start_date
),

portfolio_scope as (
    select portfolio_sk, portfolio_bk, capex_date, capex_amount, gbv,
           price_gross, price_percent, flow_type, uw_unlevered_irr,
           currency_id as portfolio_currency
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
    union all
    -- Guard 1. Do not remove: worth 2.69% of collections.
    select f.portfolio_sk, '(unknown portfolio ' || f.portfolio_sk || ')',
           null, null, null, null, null, null, null, null
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    where f.portfolio_sk not in (select portfolio_sk from PROD.NPL_COMMON.DIM_PORTFOLIO)
      and ('(unknown portfolio ' || f.portfolio_sk || ')') like $portfolio_filter
    group by f.portfolio_sk
),

-- Guard 3. PMI only, multiplied, with the EUR identity row unioned in.
fx as (
    select date_day as month_end, quote_currency as ccy,
           monthly_avg  as rate_flow,     -- for collections (a flow)
           ultimo_value as rate_stock     -- for balances (a stock)
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and rate_type = 'PMI' and quote_currency <> 'EUR'
    union all
    select date_day, 'EUR', 1, 1
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and quote_currency = 'EUR'
),

actuals as (
    select f.portfolio_sk, f.period_end_date, f.currency_id,
           max(f.country_id)             as country_id,
           max(f.deal_sk)                as deal_sk,
           max(f.deal_source_sk)         as deal_source_sk,
           max(f.security_class_sk)      as security_class_sk,
           max(f.legal_buyer_sk)         as legal_buyer_sk,
           count(distinct f.batch_sk)    as n_batches,
           sum(f.gross_cash_recoveries)  as collections_local,
           sum(f.net_cash_recoveries)    as net_collections_local,
           sum(f.total_balance)          as balance_local
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    inner join portfolio_scope p on p.portfolio_sk = f.portfolio_sk
    cross join bounds b
    where f.period_end_date >  b.start_date
      and f.period_end_date <= current_date()      -- Guard 4
    group by 1, 2, 3
),

forecast as (
    select f.portfolio_sk, f.period_end_date, f.currency_id,
           sum(f.gross_collection_forecast) as forecast_local
    from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY as f
    inner join portfolio_scope p on p.portfolio_sk = f.portfolio_sk
    cross join bounds b
    where f.period_end_date >  b.start_date
      and f.period_end_date <= current_date()
    group by 1, 2, 3
),

underwriting as (
    -- The original investment case. 44,092 rows, unique on (portfolio_sk,
    -- period_end_date), one vintage (reporting_period_end_date 2026-08-31),
    -- months from 2025-06-30. Joined on currency like the accounting leg.
    select f.portfolio_sk, f.period_end_date, f.currency_id,
           sum(f.gross_collection_forecast) as uw_forecast_local
    from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY as f
    inner join portfolio_scope p on p.portfolio_sk = f.portfolio_sk
    cross join bounds b
    where f.period_end_date >  b.start_date
      and f.period_end_date <= current_date()
    group by 1, 2, 3
),

carrying as (
    -- Unique on (portfolio, period) AND on (portfolio, period, currency) —
    -- re-verified 2026-09-09 on 1,827 rows. Currency is carried through so
    -- the join below cannot repeat a stock across the currency rows of the
    -- 23 two-currency portfolio-months (none of which have carrying today),
    -- and so it converts at the carrying row's own currency.
    select portfolio_sk, period_end_date, currency_id,
           closing_value::number(38, 6) as carrying_local
    from PROD.NPL_COMMON.FCT_CARRYING_AMOUNT
    where period_end_date <= current_date()        -- Guard 4
)

select
    -- ---- what you slice by --------------------------------------------
    ps.portfolio_bk                                  as portfolio,
    a.period_end_date                                as month_end,
    year(a.period_end_date)                          as year,
    a.currency_id                                    as original_currency,
    a.country_id,
    coalesce(co.country_name, a.country_id, 'Unknown') as country_name,
    co.region,
    coalesce(ds.deal_source_name, 'Unknown')         as servicer_group,
    -- ---- servicer, per the data engineer's rule (received 2026-09-10) -------
    -- The deal source (ORANGE/HEIMDALL, BLUE/LOKI, LEGACY, ...) is the
    -- acquisition channel, not who services the book. Everything is serviced
    -- by Intrum except the LEGACY books in Spain (Gescobro) and Italy
    -- (Cerved); three portfolios carry a named sub-servicer. Applied verbatim.
    -- Two things are with the engineer (see query-helper, Part 2): the deal
    -- source 'GESCOBRO' maps to Intrum under this rule although its loans
    -- report through gescobro, and two of the three sub-servicer keys do not
    -- exist in DIM_PORTFOLIO as written.
    case when ds.deal_source_name = 'LEGACY' and a.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and a.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                                as servicer,
    case ps.portfolio_bk
         when 'LEG-ES25001-U00/2512' then 'TDX'
         when 'HEI-GR25001-U01/2512' then 'QQuant'
         when 'HEI-GR25001-U02/2512' then 'QQuant'
         else '' end                                      as subservicer,
    case when ps.portfolio_bk in ('LEG-ES25001-U00/2512', 'HEI-GR25001-U01/2512', 'HEI-GR25001-U02/2512')
         then concat(case when ds.deal_source_name = 'LEGACY' and a.country_id = 'ES' then 'Gescobro'
                          when ds.deal_source_name = 'LEGACY' and a.country_id = 'IT' then 'Cerved'
                          else 'Intrum' end,
                     ' - ',
                     case ps.portfolio_bk when 'LEG-ES25001-U00/2512' then 'TDX' else 'QQuant' end)
         else case when ds.deal_source_name = 'LEGACY' and a.country_id = 'ES' then 'Gescobro'
                   when ds.deal_source_name = 'LEGACY' and a.country_id = 'IT' then 'Cerved'
                   else 'Intrum' end end                  as servicer_full,
    coalesce(dd.deal_alias, dd.deal_bk, 'Unknown')   as deal,
    coalesce(dd.seller_name, 'Unknown')              as seller,
    coalesce(sc.security_class_name, 'Unknown')      as security_class,
    coalesce(lb.legal_buyer_name, 'Unknown')         as legal_buyer,
    ps.flow_type,

    -- ---- acquisition, for "portfolios we have acquired" ----------------
    ps.capex_date,
    year(ps.capex_date)                              as acquisition_year,
    ps.capex_amount                                  as capex_amount_local,
    ps.gbv                                           as gbv_local,
    ps.price_gross                                   as price_gross_local,
    ps.portfolio_currency,
    -- Converted at the month-end rate of the capex month (a stock, at a
    -- point in time). NULL when capex_date is NULL (10 portfolios) or the
    -- capex month has no rate. Repeats on every month row: never sum it.
    ps.capex_amount * cfx.rate_stock                 as capex_eur,
    ps.gbv         * cfx.rate_stock                  as gbv_eur,
    ps.price_percent,
    ps.uw_unlevered_irr,
    a.n_batches,

    -- ---- money, in EUR. These are the ones to sum. ---------------------
    a.collections_local     * f.rate_flow            as collections_eur,
    a.net_collections_local * f.rate_flow            as net_collections_eur,
    fc.forecast_local       * f.rate_flow            as forecast_eur,
    uw.uw_forecast_local    * f.rate_flow            as uw_forecast_eur,
    a.balance_local         * f.rate_stock           as balance_eur,
    ca.carrying_local       * f.rate_stock           as carrying_eur,
    (a.collections_local - coalesce(fc.forecast_local, 0)) * f.rate_flow
                                                     as variance_vs_forecast_eur,
    -- NULL when there is no underwriting row: absent is not zero here.
    case when uw.uw_forecast_local is not null
         then (a.collections_local - uw.uw_forecast_local) * f.rate_flow end
                                                     as variance_vs_underwriting_eur,

    -- ---- the same figures unconverted. Never sum these across rows. ----
    a.collections_local,
    a.balance_local,
    fc.forecast_local,
    uw.uw_forecast_local,

    -- ---- trust flags ----------------------------------------------------
    -- ⚠ EXCLUDE INCOMPLETE MONTHS OR THE DASHBOARD LIES.
    -- The newest month is routinely only part-loaded. Measured 2026-09-09:
    -- 2026-08-31 held 7 portfolios and EUR 3.06m against July's 250 and
    -- EUR 41.28m — which reads as a 93% collapse and is purely a load lag.
    -- This flags a month whose portfolio count is under half the previous
    -- month's. DEFAULT EVERY TILE AND CHART TO is_complete_month = true.
    a.period_end_date <= (
        select max(m.period_end_date)
        from (select period_end_date, count(distinct portfolio_sk) n,
                     lag(count(distinct portfolio_sk))
                         over (order by period_end_date) prev_n
              from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
              where period_end_date <= current_date()
              group by 1) m
        where m.prev_n is null or m.n >= 0.5 * m.prev_n
    )                                                as is_complete_month,
    f.rate_flow is not null and f.rate_stock is not null
                                                     as is_eur_complete,
    f.rate_flow                                      as fx_rate_flow_used,
    f.rate_stock                                     as fx_rate_stock_used,
    ps.portfolio_bk like '(unknown%'                 as is_unknown_portfolio

from actuals as a
inner join portfolio_scope                     as ps on ps.portfolio_sk = a.portfolio_sk
left  join fx                                  as f  on f.ccy = a.currency_id
                                                    and f.month_end = a.period_end_date
left  join forecast                            as fc on fc.portfolio_sk = a.portfolio_sk
                                                    and fc.period_end_date = a.period_end_date
                                                    and fc.currency_id = a.currency_id
left  join underwriting                        as uw on uw.portfolio_sk = a.portfolio_sk
                                                    and uw.period_end_date = a.period_end_date
                                                    and uw.currency_id = a.currency_id
left  join carrying                            as ca on ca.portfolio_sk = a.portfolio_sk
                                                    and ca.period_end_date = a.period_end_date
                                                    and ca.currency_id = a.currency_id
-- Acquisition FX: the portfolio's own currency at the end of its capex month.
left  join fx                                  as cfx on cfx.ccy = ps.portfolio_currency
                                                    and cfx.month_end = last_day(ps.capex_date)
-- Guard 2. LEFT, always. An inner join here drops up to EUR 10.67bn.
left  join PROD.NPL_COMMON.DIM_DEAL            as dd on dd.deal_sk = a.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE     as ds on ds.deal_source_sk = a.deal_source_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS  as sc on sc.security_class_sk = a.security_class_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER     as lb on lb.legal_buyer_sk = a.legal_buyer_sk
-- ⚠ COUNTRY: join on ISO_ALPHA2_CODE, NOT country_id. Found 2026-09-09:
-- DIM_COUNTRY.COUNTRY_ID is a hash key while the facts carry ISO alpha-2
-- codes ('ES', 'FI'), so the natural-looking join on country_id matches zero
-- rows and country_name comes back NULL everywhere. The loan fact also
-- carries a non-ISO 'UK' on 48,784 loans that matches nothing; it is kept as
-- the raw code so it stays visible rather than collapsing into 'Unknown'.
left  join PROD.COMMON.DIM_COUNTRY             as co on co.iso_alpha2_code = a.country_id
order by a.period_end_date desc, collections_eur desc nulls last
