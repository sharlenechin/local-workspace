-- ============================================================================
-- agg_collections_monthly — SERVICING DASHBOARD: collections and payers.
-- GRAIN: one row per (BATCH_SK, MONTH_END, CURRENCY_ID). ALL MONEY IN EUR.
-- BATCH_BK is equally unique — orphan keys keep their sk in the label.
-- ============================================================================
-- Deliberately the simplest useful dataset: what was collected, who paid, and
-- nothing that needs new logic. Built at BATCH grain because batch is one of
-- the requested filters and the portfolio-level rollup destroys it.
--
--   Terminal : mise run sql -- work/servicing/prod/agg_collections_monthly.sql
--   Notebook : datalake.q("servicing/prod/agg_collections_monthly")
--
-- FILTERS on every row: DEAL_SOURCE, COUNTRY_NAME, DEAL, BATCH_BK
--                       (plus currency, seller, security class, legal buyer)
--
-- PERIOD FLAGS, so no date logic is needed in the BI tool. "LM" is the latest
-- COMPLETE month, not the latest calendar month — see the warning below.
--   IS_LM        the last complete month
--   IS_LM_1      the month before it
--   IS_IN_L3M    the last 3 complete months   -> average these
--   IS_IN_L6M    the last 6 complete months   -> average these
--   IS_LM_12     same month one year before LM
--   IS_LM_13     the month before that
--   MONTHS_BEFORE_LM  0 = LM, 1 = LM-1, ... for anything else
--
-- To show "Avg L3M", filter IS_IN_L3M and take the AVERAGE of the monthly
-- totals — not the sum divided by 3, which differs whenever a month is
-- missing for a batch.
--
-- ---------------------------------------------------------------------------
-- ⚠ "LM" IS THE LAST COMPLETE MONTH, AND THAT IS NOT THE NEWEST ONE.
-- The newest month is routinely part-loaded. At 2026-09-09, 2026-08-31 held
-- 7 portfolios and EUR 3.06m against July's 250 and EUR 41.28m — a 93%
-- "collapse" that is purely a load lag. Incomplete months are EXCLUDED from
-- this dataset entirely so they cannot reach a chart.
--
-- ⚠ COLLECTIONS AND PAYERS COME FROM DIFFERENT FEEDS. READ THIS.
-- COLLECTIONS_EUR is the authoritative figure, from the portfolio fact, and
-- covers every batch. PAYER columns come from the loan-level fact, which
-- roughly half of portfolios do not report at all (the Intrum PAM feed).
-- HAS_PAYER_DETAIL says whether a row has them. A payer count is therefore a
-- count of what we can SEE paying, never the whole book — and
-- COLLECTIONS_PER_PAYER is only meaningful where HAS_PAYER_DETAIL is true.
-- Do not divide total collections by total payers across a mixed set.
--
-- ⚠ EUR ONLY. Sum the *_EUR columns. COLLECTIONS_LOCAL is unconverted and
-- must never be summed across currencies. FX covers 2018-01-31 .. 2026-08-31;
-- outside it the EUR columns are NULL, not zero — IS_EUR_COMPLETE flags it.
--
-- Inherits every guard in .claude/agents/query-helper.md (Part 3). Load-bearing here: LEFT joins on all
-- dimensions, FX rate_type 'PMI' multiplied not inverted with the EUR
-- identity row, payers matched on CASE_BK not CASE_SK, and the exclusion of
-- incomplete months.
-- ============================================================================

set months_back = 26;   -- 26 so LM-13 is always present


with complete_months as (
    -- A month counts as complete if it has at least half the previous
    -- month's portfolio count. Same heuristic as base_data_quality.
    select period_end_date
    from (select period_end_date,
                 count(distinct portfolio_sk) as n,
                 lag(count(distinct portfolio_sk)) over (order by period_end_date) as prev_n
          from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
          where period_end_date <= current_date()
          group by 1)
    where prev_n is null or n >= 0.5 * prev_n
),

anchor as (
    select max(period_end_date) as lm from complete_months
),

window_months as (
    select cm.period_end_date as month_end, a.lm
    from complete_months cm cross join anchor a
    -- Ceiling raised 60 -> 120 on 2026-09-09 so a caller can ask for the full
    -- trustable history. It only caps an explicit override; the default of 26
    -- above is unchanged, so this file run as-is returns exactly what it did
    -- before. Going further back than 2018-01-31 is pointless whatever the
    -- value: FX coverage starts there and the EUR columns are NULL before it.
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

-- Authoritative collections. Unique on (batch_sk, period_end_date), verified
-- on all 1,544,877 rows, so batch grain needs no dedupe.
collections as (
    select f.batch_sk, f.period_end_date, f.currency_id,
           max(f.portfolio_sk)          as portfolio_sk,
           max(f.deal_sk)               as deal_sk,
           max(f.deal_source_sk)        as deal_source_sk,
           max(f.security_class_sk)     as security_class_sk,
           max(f.legal_buyer_sk)        as legal_buyer_sk,
           max(f.country_id)            as country_id,
           sum(f.gross_cash_recoveries) as collections_local,
           sum(f.total_balance)         as balance_local
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    inner join window_months w on w.month_end = f.period_end_date
    group by 1, 2, 3
),

-- Payers, from the loan-level fact. CASE_BK, not CASE_SK: the versioned key
-- loses EUR 128.2m a year book-wide.
payers as (
    select c.batch_sk,
           last_day(c.collection_date)   as month_end,
           c.currency_id,
           count(distinct dc.case_bk)    as n_paying_loans,
           count(*)                      as n_payments,
           sum(iff(c.amount > 0, c.amount, 0)) as receipts_local,
           sum(iff(c.amount < 0, c.amount, 0)) as reversals_local
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join PROD.NPL_COMMON.DIM_CASE dc on dc.case_sk = c.case_sk
    inner join window_months w on w.month_end = last_day(c.collection_date)
    where c.collection_date <= current_date()
    group by 1, 2, 3
),

book as (
    select s.batch_sk, s.date_day as month_end, s.currency_id,
           count(distinct dc.case_bk) as n_loans_on_book
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    inner join PROD.NPL_COMMON.DIM_CASE dc on dc.case_sk = s.case_sk
    inner join window_months w on w.month_end = s.date_day
    group by 1, 2, 3
)

select
    -- ---- the four requested filters -------------------------------------
    coalesce(ds.deal_source_name, 'Unknown')        as deal_source,
    -- ---- servicer, per the data engineer's rule (received 2026-09-10) -------
    -- The deal source (ORANGE/HEIMDALL, BLUE/LOKI, LEGACY, ...) is the
    -- acquisition channel, not who services the book. Everything is serviced
    -- by Intrum except the LEGACY books in Spain (Gescobro) and Italy
    -- (Cerved); three portfolios carry a named sub-servicer. Applied verbatim.
    -- Two things are with the engineer (see query-helper, Part 2): the deal
    -- source 'GESCOBRO' maps to Intrum under this rule although its loans
    -- report through gescobro, and two of the three sub-servicer keys do not
    -- exist in DIM_PORTFOLIO as written.
    case when ds.deal_source_name = 'LEGACY' and c.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and c.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                                as servicer,
    case dp.portfolio_bk
         when 'LEG-ES25001-U00/2512' then 'TDX'
         when 'HEI-GR25001-U01/2512' then 'QQuant'
         when 'HEI-GR25001-U02/2512' then 'QQuant'
         else '' end                                      as subservicer,
    case when dp.portfolio_bk in ('LEG-ES25001-U00/2512', 'HEI-GR25001-U01/2512', 'HEI-GR25001-U02/2512')
         then concat(case when ds.deal_source_name = 'LEGACY' and c.country_id = 'ES' then 'Gescobro'
                          when ds.deal_source_name = 'LEGACY' and c.country_id = 'IT' then 'Cerved'
                          else 'Intrum' end,
                     ' - ',
                     case dp.portfolio_bk when 'LEG-ES25001-U00/2512' then 'TDX' else 'QQuant' end)
         else case when ds.deal_source_name = 'LEGACY' and c.country_id = 'ES' then 'Gescobro'
                   when ds.deal_source_name = 'LEGACY' and c.country_id = 'IT' then 'Cerved'
                   else 'Intrum' end end                  as servicer_full,
    coalesce(co.country_name, c.country_id, 'Unknown') as country_name,
    coalesce(dd.deal_alias, dd.deal_bk, 'Unknown')  as deal,
    -- ⚠ NOT coalesce(..., 'Unknown'). THREE batch_sk hashes are orphaned —
    -- they exist in the fact but not in DIM_BATCH (EUR 74.4m of balance).
    -- Collapsing them all to one 'Unknown' label broke the grain: three rows
    -- per (batch, month, currency) instead of one. Keeping the key in the
    -- label keeps them distinct AND visible. Verified 0 duplicates after.
    coalesce(db.batch_bk, '(unknown batch ' || c.batch_sk || ')') as batch_bk,
    c.batch_sk,

    -- ---- extra slicers, free of charge -----------------------------------
    coalesce(dp.portfolio_bk, 'Unknown')            as portfolio,
    c.currency_id                                   as original_currency,
    coalesce(dd.seller_name, 'Unknown')             as seller,
    coalesce(sc.security_class_name, 'Unknown')     as security_class,
    coalesce(lb.legal_buyer_name, 'Unknown')        as legal_buyer,

    -- ---- time ------------------------------------------------------------
    c.period_end_date                               as month_end,
    year(c.period_end_date)                         as year,
    monthname(c.period_end_date)                    as month_name,
    datediff(month, c.period_end_date, w.lm)        as months_before_lm,
    c.period_end_date = w.lm                                        as is_lm,
    c.period_end_date = dateadd(month, -1,  w.lm)                   as is_lm_1,
    c.period_end_date >  dateadd(month, -3,  w.lm)                  as is_in_l3m,
    c.period_end_date >  dateadd(month, -6,  w.lm)                  as is_in_l6m,
    c.period_end_date = dateadd(month, -12, w.lm)                   as is_lm_12,
    c.period_end_date = dateadd(month, -13, w.lm)                   as is_lm_13,

    -- ---- total collections, in EUR. This is the headline. ---------------
    c.collections_local * f.rate_flow               as collections_eur,
    c.balance_local     * f.rate_stock              as balance_eur,

    -- ---- payers ----------------------------------------------------------
    p.n_paying_loans,
    bk.n_loans_on_book,
    p.n_payments,
    p.receipts_local  * f.rate_flow                 as receipts_eur,
    p.reversals_local * f.rate_flow                 as reversals_eur,
    div0null(p.n_paying_loans, bk.n_loans_on_book)  as pct_loans_paying,
    div0null(c.collections_local * f.rate_flow, p.n_paying_loans)
                                                    as collections_per_payer_eur,
    div0null(p.receipts_local * f.rate_flow, p.n_payments)
                                                    as avg_payment_eur,

    -- ---- unconverted; never sum across currencies ------------------------
    c.collections_local,

    -- ---- trust flags ------------------------------------------------------
    p.n_paying_loans is not null                    as has_payer_detail,
    f.rate_flow is not null and f.rate_stock is not null as is_eur_complete

from collections as c
cross join anchor as w
left  join fx    as f  on f.ccy = c.currency_id and f.month_end = c.period_end_date
left  join payers as p on p.batch_sk = c.batch_sk
                      and p.month_end = c.period_end_date
                      and p.currency_id = c.currency_id
left  join book  as bk on bk.batch_sk = c.batch_sk
                      and bk.month_end = c.period_end_date
                      and bk.currency_id = c.currency_id
-- LEFT, always: six dimension keys carry an orphan '-1'.
left  join PROD.NPL_COMMON.DIM_BATCH           as db on db.batch_sk = c.batch_sk
left  join PROD.NPL_COMMON.DIM_PORTFOLIO       as dp on dp.portfolio_sk = c.portfolio_sk
left  join PROD.NPL_COMMON.DIM_DEAL            as dd on dd.deal_sk = c.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE     as ds on ds.deal_source_sk = c.deal_source_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS  as sc on sc.security_class_sk = c.security_class_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER     as lb on lb.legal_buyer_sk = c.legal_buyer_sk
-- ⚠ COUNTRY: join on ISO_ALPHA2_CODE, NOT country_id. Found 2026-09-09:
-- DIM_COUNTRY.COUNTRY_ID is a hash key while the facts carry ISO alpha-2
-- codes ('ES', 'FI'), so the natural-looking join on country_id matches zero
-- rows and country_name comes back NULL everywhere. The loan fact also
-- carries a non-ISO 'UK' on 48,784 loans that matches nothing; it is kept as
-- the raw code so it stays visible rather than collapsing into 'Unknown'.
left  join PROD.COMMON.DIM_COUNTRY             as co on co.iso_alpha2_code = c.country_id
order by c.period_end_date desc, collections_eur desc nulls last
