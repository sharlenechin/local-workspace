-- ============================================================================
-- base_case_collection — BASE: what each loan paid, on each day it paid.
-- GRAIN: one row per (CASE_BK, COLLECTION_DATE, DEAL_BK). See GRAIN below.
-- ============================================================================
-- The drill-down spine of the collections chain. `base_collection` is one row
-- per fact row (every individual payment and reversal); this is that rolled up
-- to "what did this loan collect, net, on this date", in the book's own
-- currency AND in EUR, with the keys every aggregate above it groups by.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/base_case_collection.sql
--   Notebook  : datalake.q("servicing/prod/base_case_collection")
--
-- ---------------------------------------------------------------------------
-- WHERE IT SITS IN THE CHAIN (this is the point of the file)
--
--   base_case                         one row per loan per month-end, all dims
--        |
--   base_case_collection   <- YOU ARE HERE      loan x day
--        |
--        +-- agg_portfolio_collection_monthly   portfolio x month x currency
--        +-- agg_deal_collection_monthly        deal      x month x currency
--        +-- agg_vehicle_collection_monthly     SPV       x month x currency
--        +-- agg_servicer_collection_monthly    servicer  x month x currency
--
-- The four aggregates are a plain `group by` of THIS file — no re-join, no
-- second read of the fact — which is what makes them foot to each other and
-- to this file exactly. That is also why the dimension keys are carried here
-- rather than left to the aggregates to look up: a rollup that re-derives its
-- own dimensions is a rollup that can disagree with the level below it.
--
-- In dbt this is one model; the aggregates are `ref('base_case_collection')`.
--
-- ---------------------------------------------------------------------------
-- ⚠⚠ READ THIS BEFORE PUTTING A NUMBER FROM THIS CHAIN ON A SLIDE ⚠⚠
--
-- THIS FEED IS NOT THE WHOLE BOOK. It is the loan-level (CAT) feed, and about
-- half of the portfolios do not report at loan level at all — they arrive as
-- portfolio-level aggregates (the Intrum PAM feed). Measured 2026-09-11 for
-- July 2026, the latest complete month:
--
--   Portfolio fact (the reported, headline figure)  EUR 41,282,117.95  250 pf
--   This chain (loan level)                         EUR 24,842,484.52  138 pf
--   -> this chain is 60.18% of the reported figure
--
--   Split by whether the portfolio reports loan detail:
--     both feeds            138 portfolios   case 24,842,484.52 vs 27,255,688.96 = 91.15%
--     portfolio fact only   112 portfolios   case          0.00 vs 14,026,428.99 =  0.00%
--
-- So there are TWO different shortfalls and they are not the same thing:
--   1. 112 portfolios contribute nothing here. They are not zero-collecting;
--      they are not reported at this grain. EUR 14.03m in July alone.
--   2. Even on the 138 that do report, loan level is 91.15% of portfolio
--      level. Finding 2.12 in .claude/agents/query-helper.md: the two levels
--      are definitionally different and never reconcile. Not a bug to chase.
--
-- ⚠ AND THE GAP IS NOT RANDOM — IT IS ENTIRELY ONE SERVICER. Every euro in
-- this feed for July 2026 has REPORTING_SYSTEM = 'intrum', across exactly two
-- deal sources (ORANGE/HEIMDALL and BLUE/LOKI). ZERO rows for LEGACY,
-- GESCOBRO or ORGANIC ORIGINATED. So a servicer breakdown built from this
-- file alone shows 100% Intrum and silently hides Gescobro (EUR 1.04m) and
-- Cerved (inside LEGACY's EUR 6.98m). That is why every agg_ file above
-- carries the portfolio-fact figure ALONGSIDE this one and a coverage ratio
-- on every row, and why agg_servicer_collection_monthly leads with the
-- reported figure rather than this one.
--
-- Use this chain for: drill-down, per-loan behaviour, payer counts, payment
-- timing, "which loans drove the month".
-- Do NOT use it for: the headline collections number, anything by servicer,
-- or any total presented as the book's collections.
--
-- ---------------------------------------------------------------------------
-- GRAIN, measured 2026-09-11 over the 24 months to 2026-07-31 (6,510,392
-- loan-days): a loan-day NEVER spans two portfolios, buyers, batches,
-- countries, currencies, deal sources or reporting systems — all exactly 0.
-- DEAL_SK is the single exception: 4,202 loan-days (0.065%) carry two deals.
--
-- DEAL_BK is therefore IN THE GRAIN rather than collapsed with any_value().
-- On 99.935% of rows (CASE_BK, COLLECTION_DATE, DEAL_BK) and (CASE_BK,
-- COLLECTION_DATE) are the same thing. Collapsing deal instead would be
-- exactly the mistake finding 2.4 records in MART_NPL_FLASH_REPORT — a label
-- that is silently one of several. Money is identical either way; only the
-- row count differs.
--
-- CASE_ID IS SAFE AS THE LOAN KEY HERE, verified 2026-09-11 on the 12 months
-- to 2026-07-31: 677,169 distinct CASE_ID, 677,169 distinct CASE_BK, 677,169
-- pairs — a perfect 1:1, with 0 CASE_IDs on two CASE_BKs and 0 the reverse.
-- Both are returned. Prefer CASE_BK when joining to anything else in the
-- warehouse; CASE_ID is what the servicer calls the loan.
--
-- ============================================================================
-- GUARDS — each one is load-bearing; the cost of removing it is measured
-- ============================================================================
-- G1 NEVER DEDUPE ON COLLECTION_BK. It is not a row key: 4,141,626 keys are
--    shared by 47,779,540 rows (36% of the table, EUR 10.64bn) and in ZERO of
--    those cases are the sharing rows identical. A `distinct` or a
--    qualify-dedupe on it deletes about a third of real collections and the
--    result still sums and charts happily. The fact row is the grain; this
--    file aggregates it, it does not deduplicate it.
-- G2 NEGATIVE AMOUNTS ARE REAL AND ARE KEPT. 1,967,954 rows (1.5%) are
--    reversals, refunds and charge-backs. TOTAL_COLLECTED_LOCAL is therefore
--    NET, which is the right basis for recovery. Do not filter them and do
--    not use abs(). RECEIPTS_/REVERSALS_ below give the split if you need it.
--    A day whose reversals exceed its receipts nets negative — that is a real
--    row, not an error.
-- G3 collection_date <= current_date(). 841 rows are future-dated — 741 in
--    2099, single rows out to the year 4570. ~EUR 72k in total, so the guard
--    costs nothing real and stops a nonsense date axis. A known warehouse
--    problem, not one this file introduces.
-- G4 DIM_CASE IS JOINED ON CASE_SK ALONE — no `is_current_flag`. It is SCD2
--    (153.7m version rows for 22.5m loans) and the fact carries the VERSIONED
--    key, i.e. the version in force when the payment landed. Adding the flag
--    silently drops 2.8% of rows. Starting FROM the collection fact, as this
--    file does, reaches every payment; the CASE_BK it resolves is the durable
--    loan, which is why the grain is safe. (The opposite direction — starting
--    from a loan and joining collections on CASE_SK — loses EUR 128.2m over
--    12 months; see finding 2.8. This file is not exposed to that.)
-- G5 FX: rate_type 'PMI', MULTIPLIED not inverted, with the EUR identity row
--    unioned in at 1.0. 'FIXED' is identity-only and converts nothing;
--    inverting is a 122x error on SEK; without the identity row every EUR
--    payment — the largest block — joins to NULL and vanishes.
-- G6 FLOWS USE MONTHLY_AVG, not ULTIMO_VALUE. A month of receipts converted
--    at the closing rate is misstated. (Stocks — balances, carrying — use
--    ULTIMO_VALUE; that is base_case's problem, not this file's.)
-- G7 LEFT JOIN EVERY DIMENSION. Six keys on the portfolio fact carry an
--    orphan '-1' and DIM_PORTFOLIO has no '-1' row at all. The loan facts are
--    far cleaner, but the rule is unconditional: an inner join here would
--    drop rows with no error, and an unknown dimension must render as a
--    label, never remove the money.
-- G8 DIM_COUNTRY IS JOINED ON ISO_ALPHA2_CODE, NOT COUNTRY_ID. Its
--    COUNTRY_ID is a 32-char hash while every fact carries the ISO code
--    ('ES', 'PT'), so the natural-looking join matches ZERO rows and
--    COUNTRY_NAME is NULL everywhere with no error. Non-ISO 'UK' (1,542,738
--    rows) resolves under neither and is kept as the raw code rather than
--    folded into 'Unknown' — merging it with 'GB' is a data-team decision.
-- G9 EVERY '(unknown ...)' LABEL coalesce's THE SURROGATE KEY ITSELF, and it
--    has to. Snowflake's || returns NULL if ANY argument is NULL, so
--    `'(unknown deal ' || deal_sk || ')'` collapses to NULL on a row whose
--    DEAL_SK is NULL — the row keeps its money and loses its label, which is
--    the exact failure G7's left joins exist to prevent, arriving by the back
--    door. Found 2026-09-11 by check 2 of base_collection_reconciliation
--    coming up one row short: a NULL label makes count(distinct) skip the row
--    and reads as a phantom duplicate.
--    NULL keys are rare but real, measured at 2026-07-31:
--      FCT_CASE_COLLECTION              1 NULL DEAL_SK (EUR 10), 1 NULL
--                                       LEGAL_BUYER_SK, of 384,821 rows
--      FCT_CASE_SNAPSHOT_DAILY          2 NULL DEAL_SK, 2 NULL
--                                       LEGAL_BUYER_SK, of 21,832,423 rows
--      FCT_PORTFOLIO_SNAPSHOT_MONTHLY   1 NULL BATCH_SK of 11,812 (the known
--                                       4-NULL-batch finding in the versioned
--                                       sibling)
--    Immaterial in money, fatal to a grain check, and it would silently strip
--    the label off a row in any BI tool. They render as
--    '(unknown deal null key)'.
--
-- ⚠ FX COVERAGE STARTS 2018-01-31 AND THIS FACT STARTS 2014-06-24.
-- 52,042,048 rows (38.8% of the table) predate the rates. Their EUR columns
-- are NULL, not zero, and IS_EUR_COMPLETE says so. Do not coalesce it to the
-- local amount — that mixes currencies into a column labelled EUR. The
-- default window below sits inside FX coverage.
--
--
-- RUNTIME on NPL_ANALYST_WH (X-Small), measured 2026-09-11 with the defaults
-- above: 103s. THE SLOWEST FILE IN THE CHAIN, and a warm re-run
-- came back in ~20s, so treat 103s as the cold case. It reads the
-- 134m-row collection fact at loan-day grain. If you want a total
-- rather than the detail, an agg_ file answers in ~15s.
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY. 134,097,608 fact rows sit behind this. A
-- truncated result still sums, averages and charts perfectly happily, and the
-- total is simply wrong. If the row count comes back exactly equal to
-- $row_limit, assume it was cut: narrow $portfolio_filter, shorten the
-- window, or raise the cap deliberately. The agg_ files aggregate inside
-- Snowflake and return a few thousand rows, so they need no cap — reach for
-- one of those before raising this.
-- ============================================================================

-- Window. Keep it tight; this is the 134m-row fact at loan-day grain.
set date_from = '2026-01-01';
set date_to   = '2026-07-31';

-- '%' is all 250 portfolios and roughly 7m loan-days over 26 months, which
-- is far more than pandas wants. Keep a filter, or use an agg_ file.
set portfolio_filter = 'LOK-DE24016-U01/2512';

set row_limit = 200000;


with portfolio_scope as (
    -- Resolve the filter to surrogate keys first so the fact is pruned on
    -- PORTFOLIO_SK before anything else touches it.
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
),

fx as (
    -- G5. Multiply by this; do not invert it. The identity row is what keeps
    -- EUR payments in the result.
    select date_day as month_end, quote_currency as ccy, monthly_avg as rate_flow
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and rate_type = 'PMI' and quote_currency <> 'EUR'
    union all
    select date_day, 'EUR', 1
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and quote_currency = 'EUR'
),

-- The aggregation itself: every payment and reversal on a loan on a day,
-- netted. Dimension keys are carried through the group by rather than
-- collapsed, so no column here is "one of several" (see GRAIN).
collected as (
    select
        dc.case_bk,
        c.case_id,
        c.portfolio_sk,
        c.batch_sk,
        c.deal_sk,
        c.deal_source_sk,
        c.legal_buyer_sk,
        c.segment_sk,
        c.security_class_sk,
        c.reporting_system_sk,
        c.country_id,
        c.currency_id,
        c.collection_date,

        sum(c.amount)                        as total_collected_local,
        sum(iff(c.amount > 0, c.amount, 0))  as receipts_local,
        sum(iff(c.amount < 0, c.amount, 0))  as reversals_local,
        count(*)                             as n_transactions,
        sum(iff(c.amount < 0, 1, 0))         as n_reversals

    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join portfolio_scope as ps on ps.portfolio_sk = c.portfolio_sk
    -- G4: CASE_SK only, no is_current_flag.
    left  join PROD.NPL_COMMON.DIM_CASE as dc on dc.case_sk = c.case_sk
    where c.collection_date >= $date_from::date
      and c.collection_date <= $date_to::date
      and c.collection_date <= current_date()     -- G3
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
)

select
    -- ---- the loan --------------------------------------------------------
    k.case_bk,                                   -- durable key: join on this
    k.case_id,                                   -- what the servicer calls it

    -- ---- when ------------------------------------------------------------
    k.collection_date,
    date_trunc(month, k.collection_date)::date   as collection_month,
    last_day(k.collection_date)                  as month_end,

    -- ---- how much, in the book's own currency ----------------------------
    -- Net of reversals (G2). Never sum this across currencies.
    k.total_collected_local,
    k.currency_id                                as currency,

    -- ---- how much, in EUR. This column is safe to sum. -------------------
    -- NULL, not zero, where no rate exists (before 2018-01-31). Check
    -- IS_EUR_COMPLETE rather than coalescing.
    k.total_collected_local * f.rate_flow        as total_collected_eur,

    -- ---- the split, if you need it ---------------------------------------
    k.receipts_local,
    k.reversals_local,
    k.receipts_local  * f.rate_flow              as receipts_eur,
    k.reversals_local * f.rate_flow              as reversals_eur,
    k.n_transactions,
    k.n_reversals,

    -- ---- the keys the aggregates group by --------------------------------
    -- Carried here so each agg_ file is a pure group by of this file.
    coalesce(dp.portfolio_bk, '(unknown portfolio ' || coalesce(k.portfolio_sk, 'null key') || ')')
                                                 as portfolio_bk,
    coalesce(db.batch_bk, '(unknown batch ' || coalesce(k.batch_sk, 'null key') || ')')
                                                 as batch_bk,
    coalesce(dd.deal_bk, '(unknown deal ' || coalesce(k.deal_sk, 'null key') || ')')
                                                 as deal_bk,     -- in the grain
    dd.deal_alias,
    dd.seller_name,
    -- The SPV / vehicle. DIM_LEGAL_BUYER is the legal entity that owns the
    -- book; agg_vehicle_collection_monthly rolls up on exactly this.
    coalesce(lb.legal_buyer_bk, '(unknown vehicle ' || coalesce(k.legal_buyer_sk, 'null key') || ')')
                                                 as vehicle_bk,
    lb.legal_buyer_name                          as vehicle_name,
    lb.ownership_share                           as vehicle_ownership_share,
    lb.is_on_balance_sheet                       as vehicle_on_balance_sheet,

    -- ---- who services it -------------------------------------------------
    -- ⚠ Two different things, do not read either as the other.
    -- DEAL_SOURCE is the acquisition channel. SERVICER is the engineer's
    -- rule (received 2026-09-10), applied verbatim and identically in every
    -- file in this folder. REPORTING_SYSTEM is the servicer's platform and is
    -- the only one of the three sourced from the loan row itself.
    coalesce(ds.deal_source_name, 'Unknown')     as deal_source,
    case when ds.deal_source_name = 'LEGACY' and k.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and k.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                       as servicer,
    case dp.portfolio_bk
         when 'LEG-ES25001-U00/2512' then 'TDX'
         when 'HEI-GR25001-U01/2512' then 'QQuant'
         when 'HEI-GR25001-U02/2512' then 'QQuant'
         else '' end                             as subservicer,
    rs.reporting_system_name,
    rs.servicer_name                             as reporting_system_servicer,

    -- ---- where -----------------------------------------------------------
    k.country_id,
    coalesce(co.country_name, k.country_id, 'Unknown') as country_name,
    sg.segment_name,
    sc.security_class_name,

    -- ---- trust flag ------------------------------------------------------
    -- false = no FX rate for this month, so every _EUR column above is NULL.
    f.rate_flow is not null                      as is_eur_complete

from collected as k
left join fx as f
       on f.ccy = k.currency_id
      and f.month_end = last_day(k.collection_date)
-- G7: left, always.
left join PROD.NPL_COMMON.DIM_PORTFOLIO        as dp on dp.portfolio_sk      = k.portfolio_sk
left join PROD.NPL_COMMON.DIM_BATCH            as db on db.batch_sk          = k.batch_sk
left join PROD.NPL_COMMON.DIM_DEAL             as dd on dd.deal_sk           = k.deal_sk
left join PROD.NPL_COMMON.DIM_DEAL_SOURCE      as ds on ds.deal_source_sk    = k.deal_source_sk
left join PROD.NPL_COMMON.DIM_LEGAL_BUYER      as lb on lb.legal_buyer_sk    = k.legal_buyer_sk
left join PROD.NPL_COMMON.DIM_SEGMENT          as sg on sg.segment_sk        = k.segment_sk
left join PROD.NPL_COMMON.DIM_SECURITY_CLASS   as sc on sc.security_class_sk = k.security_class_sk
left join PROD.NPL_COMMON.DIM_REPORTING_SYSTEM as rs on rs.reporting_system_sk = k.reporting_system_sk
-- G8: ISO code, not the hash key.
left join PROD.COMMON.DIM_COUNTRY              as co on co.iso_alpha2_code   = k.country_id
order by k.collection_date desc, k.total_collected_local desc
limit $row_limit
