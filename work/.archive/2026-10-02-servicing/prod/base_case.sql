-- ============================================================================
-- base_case — BASE: one row per loan per month-end, every dimension joined.
-- GRAIN: one row per (CASE_BK, MONTH_END).
-- ============================================================================
-- The case table the rest of the chain hangs off: who the loan is, where it
-- sits (portfolio, batch, deal, SPV, servicer, country), what it owed at the
-- month-end, in the book's own currency and in EUR. One place, all dimensions
-- resolved to readable names, no per-analysis re-derivation.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/base_case.sql
--   Notebook  : datalake.q("servicing/prod/base_case")
--
-- ---------------------------------------------------------------------------
-- WHERE IT SITS IN THE CHAIN
--
--   base_case   <- YOU ARE HERE        loan x month-end   (who / where / owes)
--        |
--   base_case_collection               loan x day         (what it paid)
--        |
--        +-- agg_portfolio_collection_monthly
--        +-- agg_deal_collection_monthly
--        +-- agg_vehicle_collection_monthly
--        +-- agg_servicer_collection_monthly
--
-- The two base files share the same dimension block, resolved the same way
-- from the same dimensions, so joining a collection to its loan on
-- (CASE_BK, MONTH_END) never disagrees about which portfolio or SPV it is in.
--
-- In dbt this is one model; base_case_collection and the four aggregates are
-- separate models, and only the aggregates need `ref()` back to this one.
--
-- HOW IT RELATES TO ref_loan.sql: ref_loan is the older exploration file and
-- stays. It is a single month-end and carries extras this file leaves out —
-- borrower counts, forbearance history, lifetime/12m collection history
-- pre-joined. base_case is the chain's spine: a month RANGE, EUR-converted
-- balances, the servicer rule applied identically to the rest of the folder,
-- and no pre-joined collection history (that is base_case_collection's job,
-- and duplicating it is how two files start disagreeing). Use ref_loan to
-- look at one month of loans; use base_case when the answer has to foot to
-- the aggregates.
--
-- ---------------------------------------------------------------------------
-- GRAIN. FCT_CASE_SNAPSHOT_DAILY is one row per CASE_SK per date_day, and a
-- loan never has two CASE_SK versions on book at the same month-end —
-- verified across 97,232 loan-months, max 1 (finding 2.8). So (CASE_BK,
-- MONTH_END) is unique and the dimension joins cannot fan out. Counting on
-- CASE_BK rather than CASE_SK is what makes the count correct the moment you
-- span two months: CASE_SK identifies a VERSION, and 40% of loans change
-- version within a 12-month window, so a distinct count on it double-counts.
-- Both keys are returned; CASE_SK is there to join to other facts.
--
-- ⚠ "DAILY" IS A MISNOMER. The fact holds 147 dates, 2014-06-30 .. 2026-08-31,
-- and every one is a month-end. There is no intra-month history to be had.
--
-- ⚠ THE SPINE IS THE SNAPSHOT, NOT DIM_CASE, AND THAT HAS A CONSEQUENCE.
-- DIM_CASE carries no portfolio, batch, deal or segment key — every dimension
-- except reporting system lives on the fact. So a loan can only be placed in
-- a portfolio AS AT A DATE. A loan that closed and dropped off the book
-- before $month_from is not in this result at all. Widen the window to see it.
--
-- ⚠ 2026-08-31 EXISTS BUT IS NOT FULLY LOADED. Loan level looks more complete
-- than portfolio level, where only 7 of 250 portfolios had arrived at
-- 2026-09-09. The default window ends at 2026-07-31, the latest month that is
-- complete on both. Do not compare August against earlier months until the
-- portfolio-level load catches up.
--
-- ---------------------------------------------------------------------------
-- KNOWN NULLS on DIM_CASE, measured on the 22.5m current loans. These are
-- properties of the warehouse; no query fixes them.
--   ORIGINATION_DATE     95.4% null   -- origination vintage is NOT available
--   BACKSTOP_DATE        98.4% null
--   ORIGINAL_PRINCIPAL   85.5% null   -- no recovery-on-original
--   SECURED_FLAG         68.5% null   -- use SECURITY_CLASS_NAME instead
--   CLOSING_DATE         58.9% null   -- expected: only closed cases have one
--   REGISTRATION_DATE    10.4% null
--   DEFAULT_DATE          2.4% null   -- DERIVED_DEFAULT_DATE is 0.7% null
--   STATUS_CODE           0.4% null
-- And 100% NULL on all 22.5m rows: STATUS_DESCRIPTION, CLOSING_CODE,
-- CLOSING_DESCRIPTION, CLOSING_CATEGORY — so legal / amicable / insolvency
-- STAGE CANNOT BE REPORTED from this warehouse at all. Do not promise it.
--
-- ============================================================================
-- GUARDS
-- ============================================================================
-- G1 DIM_CASE IS JOINED ON CASE_SK ALONE — never add `is_current_flag`. It is
--    SCD2 and the fact carries the version in force at the snapshot. Measured
--    at 2026-07-31: all 21,832,423 snapshot rows match a DIM_CASE version but
--    only 21,225,667 match the CURRENT version, so the flag silently discards
--    606,756 loans (2.8%) with no error. Joining on CASE_SK is both complete
--    and point-in-time correct.
-- G2 COUNT LOANS WITH count(distinct CASE_BK). See GRAIN above.
-- G3 LEFT JOIN EVERY DIMENSION, and render a missing one as a label rather
--    than dropping the row. FCT_CASE_SNAPSHOT_DAILY is cleaner than the
--    portfolio fact (which has six keys carrying an orphan '-1', up to
--    EUR 10.67bn on product_sk), but the rule is unconditional.
-- G4 BALANCES ARE STOCKS, SO FX USES ULTIMO_VALUE — the rate AT month-end.
--    MONTHLY_AVG is for flows accumulated over a month and misstates a
--    point-in-time balance. base_case_collection uses MONTHLY_AVG for exactly
--    the opposite reason. Both files say which and why.
-- G5 FX: rate_type 'PMI', MULTIPLIED not inverted, identity row unioned at
--    1.0. 'FIXED' is identity-only and converts nothing; inverting is a 122x
--    error on SEK; without the identity row every EUR balance vanishes.
-- G6 DIM_COUNTRY IS JOINED ON ISO_ALPHA2_CODE, NOT COUNTRY_ID — the latter is
--    a hash key and the join matches ZERO rows with no error. Non-ISO 'UK'
--    (48,784 loans) resolves under neither and is kept as the raw code.
-- G7 BORROWER COUNT IS A SEPARATE CTE, NOT A JOIN. BRG_CASE_BORROWER holds
--    229m rows for 143.6m case versions and 8.2m of 22.5m loans have 2+
--    borrowers; joining the bridge directly inflates the loan count by ~36%.
--    Note it reaches only the version on book, which undercounts distinct
--    borrowers by 1,678 (0.0102%) book-wide and costs EUR 0.00 of money.
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
-- ⚠ BOOK SIZE NEVER RECONCILES BETWEEN THIS LEVEL AND PORTFOLIO LEVEL, and it
-- never will — it is definitional and varies by servicer: ORANGE/HEIMDALL
-- 146.2%, BLUE/LOKI 112.2%, LEGACY 102.9%, GESCOBRO 100.2%, ORGANIC
-- ORIGINATED 87.0%. It is not principal-vs-total either; principal alone runs
-- 51.6%-110.8% depending on currency, so no component matches. Quote book
-- size from ONE level, say which, and never present a cross-level comparison
-- as a control.
--
-- ⚠ ROUGHLY HALF THE PORTFOLIOS HAVE NO LOAN DETAIL AT ALL — they report as
-- portfolio-level aggregates (the Intrum PAM feed). At 2026-07-31 the loan
-- facts covered 138 of the 250 reporting portfolios. A loan-level total is a
-- total of what we can SEE, never of the book. base_case_collection's header
-- has the full measurement and the servicer skew it causes.
--
--
-- RUNTIME on NPL_ANALYST_WH (X-Small), measured 2026-09-11 with the defaults
-- above: 53s. A warm re-run came back in ~20s; the spread is warehouse
-- contention, not the query. One month, one portfolio — widening
-- $portfolio_filter or the month window scales roughly linearly.
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY. 21.8m loans per month-end sit behind this.
-- A truncated result still sums and charts happily and the total is simply
-- wrong. If the row count equals $row_limit exactly, assume it was cut.
-- ============================================================================

-- The month window. Both must be month-ends present in the fact (147 of them,
-- 2014-06-30 .. 2026-08-31). Equal values give a single month.
set month_from = '2026-07-31';
set month_to   = '2026-07-31';

-- '%' is all 250 portfolios / ~21.8m loans PER MONTH, far too much for
-- pandas. Keep a filter or the cap will bite. Examples: 'GCB-ES26%' 'IT25%'
set portfolio_filter = 'LOK-DE24016-U01/2512';

set row_limit = 50000;


with fx as (
    -- G4 / G5. ULTIMO_VALUE because balances are stocks. Multiply, never
    -- invert. The identity row is what keeps EUR balances in the result.
    select date_day as month_end, quote_currency as ccy, ultimo_value as rate_stock
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and rate_type = 'PMI' and quote_currency <> 'EUR'
    union all
    select date_day, 'EUR', 1
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and quote_currency = 'EUR'
),

book as (
    -- One row per loan per month-end. Pruned on PORTFOLIO_SK first so the
    -- 1.47bn-row fact is cut before any dimension is touched.
    select
        s.case_sk, s.case_id, s.date_day as month_end,
        s.portfolio_sk, s.batch_sk, s.deal_sk, s.segment_sk,
        s.security_class_sk, s.deal_source_sk, s.legal_buyer_sk,
        s.reporting_system_sk, s.product_sk,
        s.country_id, s.currency_id,
        s.forbearance_flag,
        s.outstanding_principal, s.outstanding_interest,
        s.outstanding_fees, s.outstanding_total
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    inner join PROD.NPL_COMMON.DIM_PORTFOLIO as p
            on p.portfolio_sk = s.portfolio_sk
           and p.portfolio_bk like $portfolio_filter
    where s.date_day >= $month_from::date
      and s.date_day <= $month_to::date
),

borrower_count as (
    -- G7: counted, never joined.
    select b.case_sk, count(distinct b.borrower_sk) as n_borrowers
    from PROD.NPL_COMMON.BRG_CASE_BORROWER as b
    inner join book on book.case_sk = b.case_sk
    group by 1
)

select
    -- ---- identity --------------------------------------------------------
    dc.case_bk,                          -- durable loan key: COUNT ON THIS
    k.case_id,                           -- what the servicer calls it
    k.case_sk,                           -- one VERSION: joins to facts only
    k.month_end,

    -- ---- where the loan sits ---------------------------------------------
    coalesce(dp.portfolio_bk, '(unknown portfolio ' || coalesce(k.portfolio_sk, 'null key') || ')')
                                         as portfolio_bk,
    coalesce(db.batch_bk, '(unknown batch ' || coalesce(k.batch_sk, 'null key') || ')')
                                         as batch_bk,
    coalesce(dd.deal_bk, '(unknown deal ' || coalesce(k.deal_sk, 'null key') || ')')
                                         as deal_bk,
    dd.deal_name,
    dd.deal_alias,
    dd.seller_name,
    dd.deal_close_date,

    -- ---- the SPV / vehicle that owns it ----------------------------------
    coalesce(lb.legal_buyer_bk, '(unknown vehicle ' || coalesce(k.legal_buyer_sk, 'null key') || ')')
                                         as vehicle_bk,
    lb.legal_buyer_name                  as vehicle_name,
    lb.ownership_share                   as vehicle_ownership_share,
    lb.is_on_balance_sheet               as vehicle_on_balance_sheet,

    -- ---- who services it -------------------------------------------------
    -- ⚠ THREE DIFFERENT THINGS. DEAL_SOURCE is the acquisition channel;
    -- SERVICER is the data engineer's rule (received 2026-09-10), applied
    -- verbatim and identically across this folder; REPORTING_SYSTEM is the
    -- servicer's platform and is the only one taken from the loan row itself.
    -- Never read DEAL_SOURCE as the servicer — the historical column name
    -- SERVICER_GROUP invites exactly that.
    coalesce(ds.deal_source_name, 'Unknown') as deal_source,
    case when ds.deal_source_name = 'LEGACY' and k.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and k.country_id = 'IT' then 'Cerved'
         else 'Intrum' end               as servicer,
    case dp.portfolio_bk
         when 'LEG-ES25001-U00/2512' then 'TDX'
         when 'HEI-GR25001-U01/2512' then 'QQuant'
         when 'HEI-GR25001-U02/2512' then 'QQuant'
         else '' end                     as subservicer,
    rs.reporting_system_name,
    rs.servicer_name                     as reporting_system_servicer,

    -- ---- classification --------------------------------------------------
    sg.segment_name,                     -- servicer-defined labels, NOT a
                                         -- taxonomy: 21m of 21.8m loans sit
                                         -- in bare codes 01/02/04
    dpr.product_eba_type,
    dpr.original_product_name,
    sc.security_class_name,              -- Secured / Unsecured. Secured is
                                         -- 0.02% of the book (4,031 loans) —
                                         -- sanity-check before presenting a
                                         -- secured/unsecured split
    k.country_id,
    coalesce(co.country_name, k.country_id, 'Unknown') as country_name,
    k.currency_id                        as currency,

    -- ---- loan attributes (null rates in the header) ----------------------
    dc.status_code,
    dc.status_date,
    dc.default_date,
    dc.derived_default_date,             -- prefer this: 0.7% null vs 2.4%
    dc.registration_date,
    dc.closing_date,
    dc.original_principal,               -- 85.5% null
    dc.secured_flag,                     -- 68.5% null
    dc.is_current_flag                   as case_version_is_current,

    -- ---- what it owed at the month-end, in the book's own currency -------
    -- ⚠ Never sum a _LOCAL column across currencies.
    k.outstanding_principal              as outstanding_principal_local,
    k.outstanding_interest               as outstanding_interest_local,
    k.outstanding_fees                   as outstanding_fees_local,
    k.outstanding_total                  as outstanding_total_local,

    -- ---- the same, in EUR. These columns are safe to sum. ----------------
    -- NULL, not zero, where no rate exists (FX starts 2018-01-31).
    k.outstanding_principal * f.rate_stock as outstanding_principal_eur,
    k.outstanding_interest  * f.rate_stock as outstanding_interest_eur,
    k.outstanding_fees      * f.rate_stock as outstanding_fees_eur,
    k.outstanding_total     * f.rate_stock as outstanding_total_eur,

    -- ---- state -----------------------------------------------------------
    k.forbearance_flag,                  -- ⚠ disagrees with
                                         -- FCT_CASE_FORBEARANCE on ~141k
                                         -- loans; pick one source per number
                                         -- and say which. Duration, cure and
                                         -- re-default are NOT measurable —
                                         -- that table has no end date.
    coalesce(bc.n_borrowers, 0)          as n_borrowers,

    -- ---- trust flag ------------------------------------------------------
    f.rate_stock is not null             as is_eur_complete

from book as k
-- G1: CASE_SK only, no is_current_flag.
inner join PROD.NPL_COMMON.DIM_CASE            as dc  on dc.case_sk  = k.case_sk
left  join fx                                  as f   on f.ccy       = k.currency_id
                                                     and f.month_end = k.month_end
-- G3: left, always.
left  join PROD.NPL_COMMON.DIM_PORTFOLIO       as dp  on dp.portfolio_sk      = k.portfolio_sk
left  join PROD.NPL_COMMON.DIM_BATCH           as db  on db.batch_sk          = k.batch_sk
left  join PROD.NPL_COMMON.DIM_DEAL            as dd  on dd.deal_sk           = k.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE     as ds  on ds.deal_source_sk    = k.deal_source_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER     as lb  on lb.legal_buyer_sk    = k.legal_buyer_sk
left  join PROD.NPL_COMMON.DIM_SEGMENT         as sg  on sg.segment_sk        = k.segment_sk
left  join PROD.NPL_COMMON.DIM_PRODUCT         as dpr on dpr.product_sk       = k.product_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS  as sc  on sc.security_class_sk = k.security_class_sk
left  join PROD.NPL_COMMON.DIM_REPORTING_SYSTEM as rs on rs.reporting_system_sk = k.reporting_system_sk
-- G6: ISO code, not the hash key.
left  join PROD.COMMON.DIM_COUNTRY             as co  on co.iso_alpha2_code   = k.country_id
left  join borrower_count                      as bc  on bc.case_sk           = k.case_sk
order by k.month_end desc, k.outstanding_total desc nulls last
limit $row_limit
