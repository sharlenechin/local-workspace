-- ============================================================================
-- dash_servicer_scorecard — the servicer performance pack, PROD-only.
-- GRAIN: one row per (PORTFOLIO_BK, MONTH_END). EUR columns.
-- ============================================================================
--   Terminal : mise run sql -- work/servicing/prod/dash_servicer_scorecard.sql
--   Notebook : datalake.q("servicing/prod/dash_servicer_scorecard")
--   FEEDS    the Scorecard page. Period columns (LM / M-1 / AVG L3M / L6M /
--            L12) are computed in Sigma from PERIOD FLAGS on each row.
--   FOOTS TO dash_portfolio_overview.sql on COLLECTIONS_EUR.
--
-- ⚠ THIS IS THE BUILDABLE SUBSET OF THE STAKEHOLDER PACK. The amicable /
--   legal / BK split, payment plans, promises and every activity metric
--   (attempts, contacts, SMS, RPC) are NOT in PROD — they sit in RAW and are
--   not modelled. METRICS-AVAILABILITY.md has the line-by-line matrix and
--   what each missing one needs. Do not present this as the whole pack.
--
-- THE SERVICER'S CUT IS RETURNED, itemised: COMMISSION_EUR,
-- PORTFOLIO_MGMT_FEE_EUR, PASSTHROUGH_COST_EUR and the total
-- SERVICER_COST_TOTAL_EUR (= gross - net).
-- ⚠⚠ THE THREE COMPONENTS DO NOT ADD TO THE TOTAL, and the gap is material.
--   Measured for 2026-08-31 across the book:
--       commission        4,135,207.86
--       portfolio mgmt      177,307.22
--       passthrough       2,287,740.62
--       itemised total    6,600,255.70
--       actual (gross-net) 7,816,172.47
--       UNITEMISED        1,215,916.77   = 15.6% of the servicer's cut
--   SERVICER_COST_UNITEMISED_EUR returns that residual so a breakdown foots.
--   ⚠ What that 15.6% is has NOT been established — it is a question for the
--   data team or the servicer, not a rounding difference. Do not present the
--   three components as a complete breakdown without it.
--   ⚠ Cost to collect was 23.45% of gross in that month.
-- ⚠ Cost to collect = SERVICER_COST_TOTAL_EUR / COLLECTIONS_EUR, computed in
--   Sigma over sums — never averaged across portfolios.
--
-- TWO LEGS, AND THEY DO NOT COVER THE SAME BOOK:
--   PORTFOLIO leg  FCT_PORTFOLIO_SNAPSHOT_MONTHLY — the money. Trust it.
--   LOAN leg       FCT_CASE_COLLECTION — payments, payers. ⚠ 54% of
--                  portfolios only. HAS_CASE_DETAIL says which.
--   ⚠ Never divide one leg by the other without checking HAS_CASE_DETAIL:
--   115 of 250 portfolios would return a payer count of 0 while collecting.
--
-- PAYER CLASSIFICATION — the comparison window is the TRAILING 3 MONTHS,
-- not the single prior month (definition confirmed with the business
-- 2026-09-14):
--   PAYERS     paid in month M
--   NEW        paid in M, and NOT in M-1..M-3
--   LOST       paid in M-1..M-3, and NOT in M
--   RECURRENT  paid in M, AND in M-1..M-3
-- ⚠ Why 3 months and not 1: on a lumpy NPL book a payer who skips a single
--   month would otherwise read as LOST and then NEW, inventing churn that did
--   not happen. The 3-month window is the tolerant, and correct, reading.
-- ⚠ IDENTITY THAT MUST HOLD: PAYERS = NEW + RECURRENT, exactly. LOST is a
--   SEPARATE population (it is not in M at all) and must never be added to
--   the other two. Asserted in the notebook; gap was 0 on every month tested.
-- ⚠ THE SCAN REACHES 3 MONTHS FURTHER BACK than the reported range, or the
--   earliest months would classify every payer as NEW for want of history.
-- ⚠⚠ LOST IS NOT ADDITIVE ACROSS MONTHS. A case that paid in M-3 and never
--   again is LOST in M, M+1 AND M+2 — three times, for one departure. That
--   follows from the 3-month window and is not a bug, but it means a "lost
--   payers" total over a period is meaningless. Show it per month only, and
--   never sum the column.
-- ⚠ NEW IS INFLATED WHEN A PORTFOLIO JOINS THE LOAN-LEVEL FEED. Every case
--   looks new for want of history. Measured 2026-09-14: new payers ran 35k
--   (Jun) -> 66k (Jul) -> 108k (Aug) while the loan leg grew from 233 to 249
--   portfolios, and collections FELL 19% over the same months. More new
--   payers alongside less cash is the onboarding artefact, not a change in
--   behaviour. Read NEW against HAS_CASE_DETAIL and the portfolio count.
--
-- GUARDS: the four from agg_portfolio_summary — the '(unknown portfolio)'
-- union, LEFT joins on every dimension, FX PMI multiplied with the EUR
-- identity row, period_end_date <= current_date().
--
-- ⚠⚠ COMPLETENESS IS ENFORCED HERE, NOT LEFT TO THE DASHBOARD. Part-loaded
--   months and months with no FX rate are filtered out in this file, so no
--   tile can forget them. Every row returned is a COMPLETE month with a real
--   FX rate. The boundaries come back as snapshot_date / FX_FROM / FX_TO so the
--   page can state what it excludes — a silent filter is not acceptable.
--
-- ⚠ PROD DATA. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set months_back      = 24;
set portfolio_filter = '%';


with bounds as (
    select dateadd(month, -1 * least($months_back, 120), current_date())       as start_date,
           -- 3 extra months so the trailing-3m lookback has history to read
           dateadd(month, -1 * (least($months_back, 120) + 3), current_date()) as lookback_start
),

portfolio_scope as (
    select portfolio_sk, portfolio_bk, capex_date, capex_amount, price_percent,
           currency_id as portfolio_currency
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
    union all
    select f.portfolio_sk, '(unknown portfolio ' || f.portfolio_sk || ')',
           null, null, null, null
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    where f.portfolio_sk not in (select portfolio_sk from PROD.NPL_COMMON.DIM_PORTFOLIO)
      and ('(unknown portfolio ' || f.portfolio_sk || ')') like $portfolio_filter
    group by f.portfolio_sk
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

fx_window as (
    select min(month_end) as fx_from, max(month_end) as fx_to
    from fx where rate_flow is not null and rate_stock is not null
),

-- Leg 1: the money. One row per portfolio-month-currency, rolled to the month.
portfolio_leg as (
    select f.portfolio_sk, f.period_end_date as month_end, f.currency_id,
           max(f.country_id)            as country_id,
           max(f.deal_sk)               as deal_sk,
           max(f.deal_source_sk)        as deal_source_sk,
           max(f.legal_buyer_sk)        as legal_buyer_sk,
           sum(f.gross_cash_recoveries) as collections_local,
           sum(f.net_cash_recoveries)   as net_collections_local,
           -- The servicer's cut, as its three components rather than a
           -- gross-minus-net residual — so a change can be attributed.
           sum(f.commission)            as commission_local,
           sum(f.portfolio_mgmt_fee)    as portfolio_mgmt_fee_local,
           sum(f.passthrough_cost)      as passthrough_cost_local,
           sum(f.total_balance)         as balance_local
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    inner join portfolio_scope p on p.portfolio_sk = f.portfolio_sk
    cross join bounds b
    where f.period_end_date > b.start_date
      and f.period_end_date <= current_date()
    group by 1, 2, 3
),

plans as (
    select portfolio_sk, period_end_date, currency_id,
           sum(gross_collection_forecast) as underwriting_forecast_local
    from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY
    where period_end_date <= current_date()
    group by 1, 2, 3
),

-- Leg 2: payments, at loan level. One row per (portfolio, month, loan).
-- ⚠ Scanned from LOOKBACK_START, three months before the reported range.
loan_payments as (
    select
        s.portfolio_sk,
        last_day(c.collection_date)  as month_end,
        c.case_sk,
        count(*)                     as n_payments,
        sum(c.amount)                as amount_local
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
            on s.case_sk = c.case_sk
           and s.date_day = last_day(c.collection_date)
    cross join bounds b
    where c.collection_date > b.lookback_start
      and c.collection_date <= current_date()
    group by 1, 2, 3
),

-- Payers per portfolio-month: the money and payment counts.
payers as (
    select
        portfolio_sk,
        month_end,
        count(distinct case_sk)  as n_payers,
        sum(n_payments)          as n_payments,
        sum(amount_local)        as case_amount_local
    from loan_payments
    group by 1, 2
),

-- One row per (portfolio, case, month) the case is relevant in: the month it
-- paid, and the three months after it — the second of which is what makes a
-- LOST payer visible in a month it has no payment row for.
payer_flags as (
    select
        portfolio_sk,
        case_sk,
        month_ix,
        max(is_this)  as paid_this_month,
        max(is_prior) as paid_prior_3m
    from (
        select portfolio_sk, case_sk,
               datediff(month, '1900-01-01', month_end) as month_ix,
               1 as is_this, 0 as is_prior
        from loan_payments
        union all
        select lp.portfolio_sk, lp.case_sk,
               datediff(month, '1900-01-01', lp.month_end) + o.n,
               0, 1
        from loan_payments as lp
        cross join (select 1 as n union all select 2 union all select 3) as o
    )
    group by 1, 2, 3
),

payer_movement as (
    select
        portfolio_sk,
        last_day(dateadd(month, month_ix, '1900-01-01'))                       as month_end,
        count(distinct iff(paid_this_month = 1 and paid_prior_3m = 0, case_sk, null)) as new_payers,
        count(distinct iff(paid_this_month = 1 and paid_prior_3m = 1, case_sk, null)) as recurrent_payers,
        count(distinct iff(paid_this_month = 0 and paid_prior_3m = 1, case_sk, null)) as lost_payers
    from payer_flags
    group by 1, 2
),

-- Accounts on book at the month-end.
-- Accounts on book at the month-end.
-- ⚠ THE SNAPSHOT INCLUDES CLOSED CASES (41.4% of rows at 2026-08-31), so the
-- DIM_CASE join is here to separate them. N_ACCOUNTS counts everything;
-- N_ACCOUNTS_OPEN is the one that means "under management".
accounts as (
    select s.portfolio_sk, s.date_day as month_end,
           count(*)                                              as n_accounts,
           count_if(dc.closing_date is null
                    or dc.closing_date > s.date_day)             as n_accounts_open
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    left join PROD.NPL_COMMON.DIM_CASE as dc on dc.case_sk = s.case_sk
    cross join bounds b
    where s.date_day = last_day(s.date_day)
      and s.date_day > b.start_date
      and s.date_day <= current_date()
    group by 1, 2
),

last_complete_month as (
    select max(m.period_end_date) as month_end
    from (select period_end_date,
                 count(distinct portfolio_sk) as n,
                 lag(count(distinct portfolio_sk)) over (order by period_end_date) as prev_n
          from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
          where period_end_date <= current_date()
          group by 1) m
    where m.prev_n is null or m.n >= 0.5 * m.prev_n
)

select
    ps.portfolio_bk                                   as portfolio_id,
    ps.portfolio_bk                                   as portfolio_name,
    coalesce(lb.legal_buyer_name, 'Unknown')          as vehicle,
    coalesce(dd.deal_alias, dd.deal_bk, 'Unknown')    as deal,
    case when ds.deal_source_name = 'LEGACY' and l.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and l.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                            as servicer,
    coalesce(co.country_name, l.country_id, 'Unknown') as country_name,
    coalesce(ds.deal_source_name, 'Unknown')          as deal_source,
    -- Acquisition economics, converted at the month-end rate of the capex
    -- month. ⚠ Repeats on every month row — threshold on it, never sum it.
    ps.capex_amount * cfx.rate_stock                  as capex_eur,
    ps.price_percent,
    ps.capex_date,
    date_trunc('month', ps.capex_date)::date          as capex_month,
    year(ps.capex_date)                               as acquisition_year,
    l.month_end,
    l.currency_id                                     as original_currency,

    -- ---- PERFORMANCE ------------------------------------------------------
    l.collections_local     * f.rate_flow             as collections_eur,
    -- ⚠ NET is after the servicer's cut — about 22% of gross. Show one basis
    -- per page and LABEL it. FLAGS.md §9.
    l.net_collections_local * f.rate_flow             as net_collections_eur,

    -- ---- THE SERVICER'S CUT. Sum these; all POSITIVE costs. --------------
    -- ⚠ The source columns are stored NEGATIVE (they are deductions). Negated
    -- here so every cost column has the same sign as the total — otherwise a
    -- card summing the components returns a negative "cost".
    -l.commission_local         * f.rate_flow         as commission_eur,
    -l.portfolio_mgmt_fee_local * f.rate_flow         as portfolio_mgmt_fee_eur,
    -l.passthrough_cost_local   * f.rate_flow         as passthrough_cost_eur,
    (l.collections_local - l.net_collections_local) * f.rate_flow
                                                      as servicer_cost_total_eur,
    -- ⚠⚠ THE ITEMISED PARTS DO NOT ADD TO THE TOTAL. Measured 2026-08-31:
    -- commission 4,135,207.86 + mgmt 177,307.22 + passthrough 2,287,740.62
    -- = 6,600,255.70 against an actual gross-minus-net cost of 7,816,172.47.
    -- The residual is returned rather than hidden, so a stacked breakdown
    -- foots to the total instead of quietly under-reporting it by ~16%.
    ((l.collections_local - l.net_collections_local)
        + l.commission_local + l.portfolio_mgmt_fee_local
        + l.passthrough_cost_local) * f.rate_flow     as servicer_cost_unitemised_eur,
    pl.underwriting_forecast_local * f.rate_flow                as underwriting_plan_eur,
    -- ⚠ a RATIO on one row. For any group, recompute it in Sigma over sums.
    div0null(l.collections_local, pl.underwriting_forecast_local) as percent_of_plan_row_only,
    l.balance_local * f.rate_stock                    as balance_eur,
    -- Decay: this month against last month, same portfolio.
    lag(l.collections_local * f.rate_flow) over (
        partition by ps.portfolio_bk, l.currency_id order by l.month_end)
                                                      as collections_prior_month_eur,

    -- ---- PAYMENTS (loan leg — check HAS_CASE_DETAIL) ----------------------
    py.n_payments,
    py.case_amount_local * f.rate_flow                as case_collections_eur,
    div0null(py.case_amount_local * f.rate_flow, py.n_payments) as avg_payment_eur,

    -- ---- PAYERS -----------------------------------------------------------
    py.n_payers,
    pm.new_payers,
    pm.recurrent_payers,
    pm.lost_payers,
    ac.n_accounts,
    -- ⚠ N_ACCOUNTS includes CLOSED cases. This is the "under management" one.
    ac.n_accounts_open,
    div0null(py.n_payers, ac.n_accounts_open)         as percent_accounts_paying,

    -- ---- PERIOD FLAGS: Sigma builds LM / M-1 / AVG L3M / L6M / L12 -------
    -- ⚠ L0M IS THIS MONTH AND IS EXCLUDED FROM EVERY L-WINDOW (2026-09-15).
    -- L3M = L1M + L2M + L3M, the three COMPLETED months before the latest.
    l.month_end = lcm.month_end                                   as is_l0m,
    l.month_end = last_day(dateadd(month, -1, lcm.month_end))     as is_l1m,
    l.month_end >  dateadd(month, -4,  lcm.month_end)
        and l.month_end < lcm.month_end                           as is_in_l3m,
    l.month_end >  dateadd(month, -7,  lcm.month_end)
        and l.month_end < lcm.month_end                           as is_in_l6m,
    l.month_end >  dateadd(month, -13, lcm.month_end)
        and l.month_end < lcm.month_end                           as is_in_l12m,
    l.month_end = last_day(dateadd(month, -12, lcm.month_end))    as is_l12m_same_month,

    -- ---- banner values. Identical on every row; show them at the top. ----
    lcm.month_end                                     as snapshot_date,
    fw.fx_from,
    fw.fx_to,

    -- ---- real flags. These still vary and are still yours to filter. -----
    py.n_payers is not null                           as has_case_detail,
    pl.underwriting_forecast_local is not null                  as has_underwriting_plan
from portfolio_leg as l
inner join portfolio_scope as ps on ps.portfolio_sk = l.portfolio_sk
cross join last_complete_month as lcm
cross join fx_window as fw
left  join fx as f on f.ccy = l.currency_id and f.month_end = l.month_end
left  join fx as cfx on cfx.ccy = ps.portfolio_currency
                    and cfx.month_end = last_day(ps.capex_date)
left  join plans as pl on pl.portfolio_sk = l.portfolio_sk
                      and pl.period_end_date = l.month_end
                      and pl.currency_id = l.currency_id
left  join payers        as py on py.portfolio_sk = l.portfolio_sk and py.month_end = l.month_end
left  join payer_movement as pm on pm.portfolio_sk = l.portfolio_sk and pm.month_end = l.month_end
left  join accounts      as ac on ac.portfolio_sk = l.portfolio_sk and ac.month_end = l.month_end
left  join PROD.NPL_COMMON.DIM_DEAL        as dd on dd.deal_sk        = l.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE as ds on ds.deal_source_sk = l.deal_source_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER as lb on lb.legal_buyer_sk = l.legal_buyer_sk
left  join PROD.COMMON.DIM_COUNTRY         as co on co.iso_alpha2_code = l.country_id
-- ⚠ THE TWO GUARDS, ENFORCED. Do not move these to the dashboard.
where l.month_end <= lcm.month_end
  and f.rate_flow is not null
  and f.rate_stock is not null;
