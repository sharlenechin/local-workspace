-- ============================================================================
-- agg_servicer_collection_monthly — AGG: collections per servicer per month.
-- GRAIN: one row per (SERVICER_FULL, MONTH_END, CURRENCY).
-- ============================================================================
-- The same two legs as the portfolio, deal and vehicle files, grouped by who
-- services the book. All four foot to each other exactly for any month.
--
--   Terminal : mise run sql -- work/servicing/prod/agg_servicer_collection_monthly.sql
--   Notebook : datalake.q("servicing/prod/agg_servicer_collection_monthly")
--
-- ---------------------------------------------------------------------------
-- THE CHAIN
--
--   base_case                 loan x month-end
--   base_case_collection      loan x day
--        +-- agg_portfolio_collection_monthly
--        +-- agg_deal_collection_monthly
--        +-- agg_vehicle_collection_monthly
--        +-- agg_servicer_collection_monthly    <- YOU ARE HERE
--
-- Drill: filter agg_portfolio_collection_monthly on SERVICER, then
-- base_case_collection on PORTFOLIO_BK + MONTH_END, then base_case.
--
-- ============================================================================
-- ⚠⚠⚠ THIS IS THE ONE LEVEL WHERE THE DRILL-DOWN LEG IS ACTIVELY MISLEADING
-- ============================================================================
-- Measured 2026-09-11 for July 2026: EVERY euro in the loan-level feed has
-- REPORTING_SYSTEM = 'intrum', across exactly two deal sources
-- (ORANGE/HEIMDALL and BLUE/LOKI). There are ZERO loan-level rows for LEGACY,
-- GESCOBRO or ORGANIC ORIGINATED.
--
-- So COLLECTIONS_CASE_EUR grouped by servicer reports:
--     Intrum     EUR 24,842,484.52     (100.0% of the case leg)
--     Gescobro   nothing
--     Cerved     nothing
--
-- while the reported leg — the truth — is (measured 2026-09-11, July 2026):
--     Intrum            EUR 33,793,793.82   143 portfolios   case leg 73.51%
--     Gescobro          EUR  4,849,865.85     3 portfolios   case leg    none
--     Cerved            EUR  2,133,298.86     3 portfolios   case leg    none
--     Intrum - QQuant   EUR    505,159.42     1 portfolio    case leg    none
--     total             EUR 41,282,117.95   250 portfolios
--
-- Note the 73.51% on the Intrum row: even the one servicer the loan feed DOES
-- cover is only three-quarters drillable, because 112 portfolios report no
-- loan detail and most of them are Intrum's.
--
-- A "collections by servicer" chart built on the case leg therefore shows
-- Intrum at 100% and silently deletes every other servicer. It does not look
-- broken. It looks like Intrum services everything.
--
-- ⚠ THEREFORE: ON THIS FILE, ALWAYS CHART COLLECTIONS_REPORTED_EUR.
-- COLLECTIONS_CASE_EUR is kept only so the gap stays visible and auditable,
-- and so a drill-down from an Intrum row still works. It is NOT a servicer
-- comparison. HAS_CASE_DETAIL is false on every non-Intrum row.
--
-- ⚠ AND COST TO SERVE CANNOT BE COMPARED ACROSS SERVICERS AT ALL. Commission,
-- passthrough and net recoveries are Intrum-only — ABSENT, not zero, for
-- everyone else. Any net-margin or efficiency-per-servicer number is invalid,
-- and it is invalid in Intrum's favour. Not a query problem; the data is not
-- supplied. Raise it rather than working around it.
--
-- ---------------------------------------------------------------------------
-- WHAT "SERVICER" MEANS HERE — three different things, routinely conflated
--
--   SERVICER / SERVICER_FULL   who services the book. THE column for any "by
--                              servicer" chart. The data engineer's rule,
--                              received 2026-09-10 and applied verbatim and
--                              identically across this folder.
--   DEAL_SOURCE                the ACQUISITION CHANNEL (ORANGE/HEIMDALL,
--                              BLUE/LOKI, LEGACY, GESCOBRO, ORGANIC
--                              ORIGINATED). Its historical column name
--                              elsewhere is SERVICER_GROUP — do not read that
--                              as the servicer. Kept here as a filter.
--   REPORTING_SYSTEM           the servicer's platform (intrum, cerved,
--                              gescobro, souq, massey). Loan level only, so
--                              it is on base_case / base_case_collection and
--                              not on this file.
--
-- The rule, verbatim:
--   LEGACY + ES -> Gescobro;  LEGACY + IT -> Cerved;  everything else Intrum
--   sub-servicer by portfolio: LEG-ES25001-U00/2512 -> TDX,
--                              HEI-GR25001-U01/2512 and U02 -> QQuant
-- At July 2026: Gescobro 3 portfolios, Cerved 3, Intrum - QQuant 1, Intrum
-- the rest.
--
-- ⚠⚠ TWO KNOWN DEFECTS IN THE RULE ITSELF, BOTH WITH THE DATA ENGINEER.
-- They are applied as written rather than silently patched here, because
-- changing a business rule is the engineer's call, not this file's:
--   1. Deal source GESCOBRO — 3 Spanish portfolios, 35,739 loans whose
--      reporting system IS 'gescobro' — maps to INTRUM under the rule,
--      because only LEGACY + ES maps to Gescobro. Almost certainly an
--      omission. Measured for July 2026: deal source GESCOBRO is EUR
--      1,044,951.74 across 3 portfolios, and the rule puts all of it on the
--      Intrum row. Do not confuse that figure with SERVICER Gescobro (EUR
--      4,849,865.85), which is the LEGACY + ES books and is labelled
--      correctly — they are different sets. If the rule is corrected, Intrum
--      falls to ~EUR 32.75m and Gescobro rises to ~EUR 5.89m.
--      SERVICER_RULE_SUSPECT below flags exactly the affected rows.
--   2. Two of the three sub-servicer portfolio keys DO NOT EXIST in
--      DIM_PORTFOLIO: LEG-ES25001-U00/2512 (the dimension has U01) and
--      HEI-GR25001-U01/2512 (it has U02 and U04). So 'Intrum - TDX' never
--      appears at all and 'Intrum - QQuant' covers one portfolio instead of
--      two. Also 57,781 Greek loans report through 'souq', which may be
--      QQuant's platform.
-- Do not present a servicer split as final until both are resolved.
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
-- G1 Incomplete months excluded.
-- G2 FULL OUTER JOIN between the legs. Load-bearing here more than anywhere:
--    an inner join would drop every non-Intrum servicer entirely, since none
--    of them has a case leg at all.
-- G3 The '-1' sentinel keys are LEFT joined, never filtered. DEAL_SOURCE_SK
--    '-1' resolves to no name, so those rows land in 'Intrum' by the rule's
--    else branch — flagged by SERVICER_RULE_SUSPECT rather than hidden.
-- G4 The servicer label is derived INSIDE each leg, before the group by, from
--    that leg's own dimension keys. Deriving it after the join would make one
--    leg's label depend on the other leg having a row.
-- G5 FX: 'PMI', multiplied not inverted, identity row at 1.0; flows at
--    MONTHLY_AVG, stocks at ULTIMO_VALUE.
-- G6 Currency is in the grain. _LOCAL never sums across rows; _EUR does.
-- G7 Paying loans counted on CASE_BK, not CASE_SK.
-- G8 collection_date <= current_date().
--
--
-- RUNTIME on NPL_ANALYST_WH (X-Small), measured 2026-09-11: 16s, 235 rows
-- over 26 months. Interactive.
-- ⚠ FX coverage starts 2018-01-31; before it every _EUR column is NULL, not
-- zero. Filter IS_EUR_COMPLETE on every tile.
-- ============================================================================

set months_back = 26;


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

-- LEG 1: base_case_collection, labelled and grouped to the servicer.
-- G4: the label is derived here, from this leg's own keys.
case_leg as (
    select
        case when ds.deal_source_name = 'LEGACY' and c.country_id = 'ES' then 'Gescobro'
             when ds.deal_source_name = 'LEGACY' and c.country_id = 'IT' then 'Cerved'
             else 'Intrum' end                as servicer,
        case dp.portfolio_bk
             when 'LEG-ES25001-U00/2512' then 'TDX'
             when 'HEI-GR25001-U01/2512' then 'QQuant'
             when 'HEI-GR25001-U02/2512' then 'QQuant'
             else '' end                      as subservicer,
        last_day(c.collection_date)           as month_end,
        c.currency_id                         as currency,
        sum(c.amount)                         as collections_case_local,
        sum(iff(c.amount > 0, c.amount, 0))   as receipts_case_local,
        sum(iff(c.amount < 0, c.amount, 0))   as reversals_case_local,
        count(distinct dc.case_bk)            as n_paying_loans,   -- G7
        count(*)                              as n_payments,
        count(distinct c.portfolio_sk)        as n_portfolios_case
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join PROD.NPL_COMMON.DIM_CASE as dc on dc.case_sk = c.case_sk
    inner join window_months as w on w.month_end = last_day(c.collection_date)
    -- G3: left, always. A missing deal source must not remove the money.
    left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE as ds on ds.deal_source_sk = c.deal_source_sk
    left  join PROD.NPL_COMMON.DIM_PORTFOLIO   as dp on dp.portfolio_sk   = c.portfolio_sk
    where c.collection_date <= current_date()        -- G8
    group by 1, 2, 3, 4
),

-- LEG 2: the portfolio fact, labelled the same way. The published figure.
reported_leg as (
    select
        case when ds.deal_source_name = 'LEGACY' and f.country_id = 'ES' then 'Gescobro'
             when ds.deal_source_name = 'LEGACY' and f.country_id = 'IT' then 'Cerved'
             else 'Intrum' end                as servicer,
        case dp.portfolio_bk
             when 'LEG-ES25001-U00/2512' then 'TDX'
             when 'HEI-GR25001-U01/2512' then 'QQuant'
             when 'HEI-GR25001-U02/2512' then 'QQuant'
             else '' end                      as subservicer,
        f.period_end_date                     as month_end,
        f.currency_id                         as currency,
        sum(f.gross_cash_recoveries)          as collections_reported_local,
        sum(f.total_balance)                  as balance_reported_local,
        count(distinct f.portfolio_sk)        as n_portfolios,
        count(distinct f.deal_sk)             as n_deals,
        count(distinct f.batch_sk)            as n_batches,
        count(distinct f.legal_buyer_sk)      as n_vehicles,
        count(distinct f.country_id)          as n_countries,
        listagg(distinct coalesce(ds.deal_source_name, 'Unknown'), ', ')
            within group (order by coalesce(ds.deal_source_name, 'Unknown'))
                                              as deal_sources,
        -- The defect-1 flag: portfolios whose reporting system really is
        -- gescobro but which the rule labels Intrum. See the header.
        max(iff(ds.deal_source_name = 'GESCOBRO', 1, 0)) = 1
                                              as servicer_rule_suspect
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    inner join window_months as w on w.month_end = f.period_end_date
    left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE as ds on ds.deal_source_sk = f.deal_source_sk
    left  join PROD.NPL_COMMON.DIM_PORTFOLIO   as dp on dp.portfolio_sk   = f.portfolio_sk
    group by 1, 2, 3, 4
),

joined as (   -- G2 — without this, every non-Intrum servicer disappears
    select
        coalesce(r.servicer,    k.servicer)    as servicer,
        coalesce(r.subservicer, k.subservicer) as subservicer,
        coalesce(r.month_end,   k.month_end)   as month_end,
        coalesce(r.currency,    k.currency)    as currency,
        r.collections_reported_local, r.balance_reported_local,
        r.n_portfolios, r.n_deals, r.n_batches, r.n_vehicles, r.n_countries,
        r.deal_sources, r.servicer_rule_suspect,
        k.collections_case_local, k.receipts_case_local, k.reversals_case_local,
        k.n_paying_loans, k.n_payments, k.n_portfolios_case
    from reported_leg as r
    full outer join case_leg as k
        on  k.servicer    = r.servicer
        and k.subservicer = r.subservicer
        and k.month_end   = r.month_end
        and k.currency    = r.currency
)

select
    -- ---- the key ---------------------------------------------------------
    j.servicer,
    j.subservicer,
    iff(j.subservicer = '', j.servicer, j.servicer || ' - ' || j.subservicer)
                                                    as servicer_full,
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

    -- ---- REPORTED: ⚠ THE ONLY COLUMN TO CHART ON THIS FILE ---------------
    j.collections_reported_local * f.rate_flow      as collections_reported_eur,
    j.balance_reported_local     * f.rate_stock     as balance_reported_eur,

    -- ---- DRILL-DOWN: Intrum-only. NOT a servicer comparison. -------------
    j.collections_case_local     * f.rate_flow      as collections_case_eur,
    j.receipts_case_local        * f.rate_flow      as receipts_case_eur,
    j.reversals_case_local       * f.rate_flow      as reversals_case_eur,
    j.n_paying_loans,
    j.n_payments,

    -- ---- how much of this row can be drilled into ------------------------
    -- ⚠ completeness, NOT performance, and on this file it is essentially a
    -- proxy for "is this Intrum" — never read it as collection efficiency.
    div0null(j.collections_case_local, j.collections_reported_local)
                                                    as coverage_pct,
    j.collections_case_local is not null            as has_case_detail,

    -- ---- is this row's servicer label trustworthy? -----------------------
    -- true = the row contains GESCOBRO-sourced portfolios that the rule
    -- labels Intrum. See defect 1 in the header.
    coalesce(j.servicer_rule_suspect, false)        as servicer_rule_suspect,

    -- ---- context ---------------------------------------------------------
    j.deal_sources,                                 -- the channels behind
                                                    -- this servicer's books
    j.n_portfolios,                                 -- reported leg
    j.n_portfolios_case,                            -- case leg; lower
    j.n_deals,
    j.n_batches,
    j.n_vehicles,
    j.n_countries,

    -- ---- unconverted; never sum across currencies ------------------------
    j.collections_reported_local,
    j.collections_case_local,
    j.balance_reported_local,

    -- ---- trust flag ------------------------------------------------------
    f.rate_flow is not null and f.rate_stock is not null as is_eur_complete

from joined as j
cross join anchor as a
left join fx as f on f.ccy = j.currency and f.month_end = j.month_end
order by j.month_end desc, collections_reported_eur desc nulls last
