-- ============================================================================
-- dash_phase_collections — collections split by WORKOUT PHASE (amicable /
-- legal / other), the metric the servicer pack is built around.
-- GRAIN: one row per (PORTFOLIO_BK, MONTH_END, PHASE_GROUP). EUR columns.
-- ============================================================================
--   Terminal : mise run sql -- work/data-issues/intrum/queries/dash_phase_collections.sql
--   Notebook : datalake.q("data-issues/intrum/queries/dash_phase_collections")
--   COST     one pass over a 346m-row RAW feed joined to 134m PROD
--            collections. Minutes. Bounded by $months_back — widen with care.
--
-- ⚠⚠⚠ THE PHASE LABELS ARE UNCONFIRMED. DO NOT PUBLISH THEM YET.
--   GROUP_PHASE_CODE has a readable prefix — A000/A001/A002/A006,
--   L000/L002/L003, E002/E003/E005/E006, NA — and "A = Amicable, L = Legal"
--   is a READING OF THE PREFIX, not a documented mapping. `E` is genuinely
--   unknown: enforcement, insolvency or something else.
--   → PHASE_GROUP returns 'A (amicable?)' etc. ON PURPOSE. The question mark
--     stays until Intrum confirms. Strip it only when they have.
--   → The mapping lives in ONE case expression below so confirmation is a
--     one-line change. In dbt it should become a seed.
--
-- WHY THIS IS THE RIGHT SHAPE: phases are a TIMELINE, not a label. Measured
-- 2026-09-14 on instance 7006: 3,490,869 of 3,736,842 cases carry TWO phase
-- spells, consistent with amicable-then-legal escalation. So each payment is
-- attributed to the phase in force ON ITS PAYMENT DATE — which a current-state
-- flag could never do.
--
-- WHERE EACH SIDE COMES FROM, and why it is split that way:
--   MONEY  PROD.FCT_CASE_COLLECTION — already conformed, so totals foot to
--          the rest of the dashboard.
--   PHASE  RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE — not modelled in PROD,
--          not even declared as a dbt source.
--   Joined on CASE_BK = <source system>-<case id>, the team's own key.
--
-- ⚠ COVERAGE IS THE LOAN FEED'S, NOT THE BOOK'S. This inherits the limit in
--   FLAGS.md §6: PROD loan-level collections cover 135 of 250 portfolios.
--   A portfolio absent here is absent from the feed, NOT at zero. Read
--   percent_of_reported_phased before quoting any split.
--
-- ⚠ INSTANCE 4050 (PORTUGAL) HAS ONLY ONE PHASE CODE (A000), so it returns a
--   single group and no split at all. That is the feed, not a bug.
--
-- GUARDS:
--   G1 GROUP_CASE_PHASE is a CHANGE-HISTORY FEED — deduped to the latest
--      version per (case_id, phase code, start date).
--   G2 DELETED / ARCHIVED / UNLINKED rows dropped, as DEBTORS requires.
--   G3 _file_path matched as a LITERAL PREFIX — no leading %, or partition
--      pruning is lost.
--   G4 CASE_ID is unique only within an instance, so the source system is in
--      the join key, never case_id alone.
--   G5 A spell runs to the day before the next spell starts; the last spell
--      runs to 9999-12-31. Payments before the first spell get 'unassigned'
--      rather than being dropped.
--
-- ⚠ PROD + RAW. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set months_back = 24;
set raw_prefix  = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


with bounds as (
    select dateadd(month, -1 * least($months_back, 120), current_date()) as start_date
),

-- G1-G4. One row per phase spell per case, with the instance in the key.
phase_spells as (
    select
        split_part(g._file_path, '.', 2) || '-' || g.case_id as case_bk,
        g.group_phase_code,
        g.start_date::date                                   as valid_from
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE as g
    where g._file_path like $raw_prefix || '%'                      -- G3
      and g.group_phase_code is not null
      and g.start_date is not null
      and coalesce(g.deleted, 0)  = 0                               -- G2
      and coalesce(g.archived, 0) = 0
      and coalesce(g.unlinked, 0) = 0
    qualify row_number() over (
        partition by split_part(g._file_path, '.', 2), g.case_id,
                     g.group_phase_code, g.start_date
        order by coalesce(g.record_update, g.update_ts)::timestamp desc nulls last
    ) = 1                                                           -- G1
),

-- G5. The spell ends the day before the next one starts.
phase_ranges as (
    select
        case_bk,
        group_phase_code,
        valid_from,
        coalesce(
            dateadd(day, -1, lead(valid_from) over (
                partition by case_bk order by valid_from)),
            '9999-12-31'::date
        ) as valid_to
    from phase_spells
),

-- The money. PROD, so it foots to the rest of the dashboard.
collections as (
    select
        dc.case_bk,
        c.portfolio_sk,
        c.currency_id,
        c.collection_date,
        last_day(c.collection_date) as month_end,
        c.amount
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join PROD.NPL_COMMON.DIM_CASE as dc
            on dc.case_sk = c.case_sk
    cross join bounds b
    where c.collection_date >  b.start_date
      and c.collection_date <= current_date()
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

-- Each payment stamped with the phase in force on its own date. LEFT, so a
-- payment with no phase spell is kept and labelled, never dropped.
phased as (
    select
        c.portfolio_sk,
        c.month_end,
        c.currency_id,
        c.amount,
        p.group_phase_code
    from collections as c
    left join phase_ranges as p
           on p.case_bk = c.case_bk
          and c.collection_date between p.valid_from and p.valid_to
),

-- What the portfolio actually reported, so the split can be sized against it.
-- ⚠ THE HIERARCHY COMES FROM THE FACT, NOT DIM_PORTFOLIO. DIM_PORTFOLIO
-- carries no deal key at all — deal, vehicle and country live on the fact
-- rows — so they are read here, the same way every other dataset reads them.
-- That is what lets one control panel filter all four elements identically.
reported as (
    select f.portfolio_sk, f.period_end_date as month_end, f.currency_id,
           max(f.country_id)            as country_id,
           max(f.deal_sk)               as deal_sk,
           max(f.deal_source_sk)        as deal_source_sk,
           max(f.legal_buyer_sk)        as legal_buyer_sk,
           sum(f.gross_cash_recoveries) as reported_local
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    cross join bounds b
    where f.period_end_date > b.start_date
      and f.period_end_date <= current_date()
    group by 1, 2, 3
)

select
    -- ---- THE SAME DRILL PATH AS THE OTHER DATASETS, so one control panel
    -- ---- filters all of them. Resolved identically; do not re-derive.
    coalesce(lb.legal_buyer_name, 'Unknown')           as vehicle,
    coalesce(dd.deal_alias, dd.deal_bk, 'Unknown')     as deal,
    case when ds.deal_source_name = 'LEGACY' and r.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and r.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                             as servicer,
    coalesce(co.country_name, r.country_id, 'Unknown') as country_name,
    coalesce(ds.deal_source_name, 'Unknown')           as deal_source,
    coalesce(dp.portfolio_bk, '(unknown portfolio ' || p.portfolio_sk || ')') as portfolio_id,
    coalesce(dp.portfolio_bk, '(unknown portfolio ' || p.portfolio_sk || ')') as portfolio_name,
    -- ⚠ Repeat on every row — threshold on them, never sum them.
    dp.capex_amount * cfx.rate_stock                   as capex_eur,
    dp.price_percent,
    date_trunc('month', dp.capex_date)::date           as capex_month,
    year(dp.capex_date)                                as acquisition_year,
    p.month_end,
    p.currency_id                                      as original_currency,

    -- ⚠ THE QUESTION MARKS ARE DELIBERATE. See the header. One place to edit.
    case left(p.group_phase_code, 1)
         when 'A' then 'A (amicable?)'
         when 'L' then 'L (legal?)'
         when 'E' then 'E (execution)'     -- confirmed 2026-09-15
         else          'unassigned'
    end                                                as phase_group,
    p.group_phase_code                                 as phase_code_raw,

    sum(p.amount * f.rate_flow)                        as collections_eur,
    count(*)                                           as n_payments,

    -- Completeness, NOT performance: how much of the portfolio-month's
    -- reported cash this phased view can actually see.
    max(r.reported_local * f.rate_flow)                as reported_eur,
    div0null(sum(p.amount), max(r.reported_local))     as percent_of_reported_phased
from phased as p
left join fx as f on f.ccy = p.currency_id and f.month_end = p.month_end
left join PROD.NPL_COMMON.DIM_PORTFOLIO as dp on dp.portfolio_sk = p.portfolio_sk
left join reported as r on r.portfolio_sk = p.portfolio_sk
                       and r.month_end    = p.month_end
                       and r.currency_id  = p.currency_id
-- LEFT, always — an inner join here drops money with no error.
left join PROD.NPL_COMMON.DIM_DEAL        as dd on dd.deal_sk        = r.deal_sk
left join PROD.NPL_COMMON.DIM_DEAL_SOURCE as ds on ds.deal_source_sk = r.deal_source_sk
left join PROD.NPL_COMMON.DIM_LEGAL_BUYER as lb on lb.legal_buyer_sk = r.legal_buyer_sk
left join PROD.COMMON.DIM_COUNTRY         as co on co.iso_alpha2_code = r.country_id
left join fx as cfx on cfx.ccy = dp.currency_id
                   and cfx.month_end = last_day(dp.capex_date)
where f.rate_flow is not null
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
order by p.month_end desc, collections_eur desc nulls last;
