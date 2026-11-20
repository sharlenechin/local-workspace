-- ============================================================================
-- agg_loan_detail — the filterable loan-level table for the dashboard.
-- GRAIN: one row per loan (CASE_BK) at $month_end. EVERY MONEY COLUMN IS EUR.
-- ============================================================================
-- The drill-down table: one line per loan, EUR-converted, with the same
-- filter columns as agg_portfolio_summary so the two line up in a BI tool.
--
--   Terminal : mise run sql -- work/servicing/prod/agg_loan_detail.sql
--   Notebook : datalake.q("servicing/prod/agg_loan_detail", portfolio_filter="LOK-DE%")
--
-- ---------------------------------------------------------------------------
-- ⚠ THESE TOTALS DO NOT TIE TO agg_portfolio_summary, AND CANNOT.
-- Loan-level and portfolio-level book size are different measures: measured
-- 2026-09-09 the loan level is 146.2% of portfolio level for ORANGE/HEIMDALL,
-- 112.2% BLUE/LOKI, 102.9% LEGACY, 100.2% GESCOBRO, 87.0% ORGANIC. It is not
-- a bug and it will never close. Separately, ~112 of 250 portfolios report as
-- portfolio aggregates only and have NO loan detail at all, so this table
-- omits them entirely.
--
-- Use this table to inspect and filter individual loans. Use
-- agg_portfolio_summary for any number that has to foot. Do not put a total
-- from each on the same chart.
--
-- ⚠ COUNT LOANS WITH count(distinct CASE_BK). CASE_SK is a version key.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY. 21.8m loans sit behind this, so keep
-- $portfolio_filter narrow. If the row count equals the cap exactly, assume
-- it was cut.
--
-- ⚠ FX: rows outside 2018-01-31 .. 2026-08-31 get a NULL rate and NULL EUR
-- columns. IS_EUR_COMPLETE flags them.
-- ============================================================================

set month_end        = '2026-07-31';
set portfolio_filter = 'LOK-DE24016-U01/2512';
set row_limit        = 100000;


with portfolio_scope as (
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
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

book as (
    select s.case_sk, s.case_id, s.portfolio_sk, s.currency_id, s.country_id,
           s.security_class_sk, s.segment_sk, s.reporting_system_sk,
           s.deal_sk, s.deal_source_sk, s.legal_buyer_sk, s.forbearance_flag,
           s.outstanding_principal, s.outstanding_interest, s.outstanding_total
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    inner join portfolio_scope p on p.portfolio_sk = s.portfolio_sk
    where s.date_day = $month_end::date
),

-- Matched on CASE_BK, not CASE_SK: the versioned key loses EUR 128.2m a year
-- book-wide. See .claude/agents/query-helper.md, Part 3, guard #1.
loan_keys as (
    select b.case_sk, dc.case_bk
    from book b
    inner join PROD.NPL_COMMON.DIM_CASE dc on dc.case_sk = b.case_sk
),

collections as (
    select dcc.case_bk,
           sum(c.amount)          as collected_life_local,
           sum(iff(c.collection_date > dateadd(month, -12, $month_end::date),
                   c.amount, 0))  as collected_12m_local,
           max(c.collection_date) as last_payment_date
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join portfolio_scope p on p.portfolio_sk = c.portfolio_sk
    inner join PROD.NPL_COMMON.DIM_CASE dcc on dcc.case_sk = c.case_sk
    where c.collection_date <= least($month_end::date, current_date())
    group by 1
),

carrying as (
    select case_bk, sum(allocated_carrying_amount::number(38, 6)) as carrying_local
    from PROD.NPL_COMMON.MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION
    where date_day = $month_end::date
    group by 1
)

select
    lk.case_bk                                       as loan,
    b.case_id,
    $month_end::date                                 as month_end,

    -- ---- filters, matching agg_portfolio_summary ------------------------
    ps.portfolio_bk                                  as portfolio,
    b.country_id,
    coalesce(co.country_name, b.country_id, 'Unknown') as country_name,
    b.currency_id                                    as original_currency,
    -- servicer_group is the DEAL SOURCE, the same dimension as
    -- agg_portfolio_summary.servicer_group and agg_collections_monthly.deal_source,
    -- so one BI filter spans all files. reporting_system is the servicer's
    -- platform (intrum, cerved, gescobro, souq, massey), a third thing.
    coalesce(ds.deal_source_name, 'Unknown')         as servicer_group,
    coalesce(rs.servicer_name, 'Unknown')            as reporting_system,
    -- ---- servicer, per the data engineer's rule (received 2026-09-10) -------
    -- The deal source (ORANGE/HEIMDALL, BLUE/LOKI, LEGACY, ...) is the
    -- acquisition channel, not who services the book. Everything is serviced
    -- by Intrum except the LEGACY books in Spain (Gescobro) and Italy
    -- (Cerved); three portfolios carry a named sub-servicer. Applied verbatim.
    -- Two things are with the engineer (see query-helper, Part 2): the deal
    -- source 'GESCOBRO' maps to Intrum under this rule although its loans
    -- report through gescobro, and two of the three sub-servicer keys do not
    -- exist in DIM_PORTFOLIO as written.
    case when ds.deal_source_name = 'LEGACY' and b.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and b.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                                as servicer,
    case ps.portfolio_bk
         when 'LEG-ES25001-U00/2512' then 'TDX'
         when 'HEI-GR25001-U01/2512' then 'QQuant'
         when 'HEI-GR25001-U02/2512' then 'QQuant'
         else '' end                                      as subservicer,
    case when ps.portfolio_bk in ('LEG-ES25001-U00/2512', 'HEI-GR25001-U01/2512', 'HEI-GR25001-U02/2512')
         then concat(case when ds.deal_source_name = 'LEGACY' and b.country_id = 'ES' then 'Gescobro'
                          when ds.deal_source_name = 'LEGACY' and b.country_id = 'IT' then 'Cerved'
                          else 'Intrum' end,
                     ' - ',
                     case ps.portfolio_bk when 'LEG-ES25001-U00/2512' then 'TDX' else 'QQuant' end)
         else case when ds.deal_source_name = 'LEGACY' and b.country_id = 'ES' then 'Gescobro'
                   when ds.deal_source_name = 'LEGACY' and b.country_id = 'IT' then 'Cerved'
                   else 'Intrum' end end                  as servicer_full,
    coalesce(dd.deal_alias, dd.deal_bk, 'Unknown')   as deal,
    coalesce(sc.security_class_name, 'Unknown')      as security_class,
    coalesce(sg.segment_name, 'Unknown')             as segment,
    coalesce(lb.legal_buyer_name, 'Unknown')         as legal_buyer,
    b.forbearance_flag,

    -- ---- money, in EUR --------------------------------------------------
    b.outstanding_total     * f.rate_stock           as outstanding_eur,
    b.outstanding_principal * f.rate_stock           as principal_eur,
    b.outstanding_interest  * f.rate_stock           as interest_eur,
    cy.carrying_local       * f.rate_stock           as carrying_eur,
    coalesce(cl.collected_life_local, 0) * f.rate_flow as collected_lifetime_eur,
    coalesce(cl.collected_12m_local, 0)  * f.rate_flow as collected_12m_eur,

    -- ---- unconverted; never sum across currencies -----------------------
    b.outstanding_total                              as outstanding_local,

    -- ---- behaviour -------------------------------------------------------
    cl.last_payment_date,
    datediff(month, cl.last_payment_date, $month_end::date) as months_since_payment,
    coalesce(cl.collected_12m_local, 0) > 0          as is_paying_12m,

    f.rate_stock is not null                         as is_eur_complete

from book as b
inner join loan_keys                            as lk on lk.case_sk = b.case_sk
inner join portfolio_scope                      as ps on ps.portfolio_sk = b.portfolio_sk
left  join fx                                   as f  on f.ccy = b.currency_id
                                                     and f.month_end = $month_end::date
left  join collections                          as cl on cl.case_bk = lk.case_bk
left  join carrying                             as cy on cy.case_bk = lk.case_bk
left  join PROD.NPL_COMMON.DIM_REPORTING_SYSTEM as rs on rs.reporting_system_sk = b.reporting_system_sk
left  join PROD.NPL_COMMON.DIM_DEAL             as dd on dd.deal_sk = b.deal_sk
left  join PROD.NPL_COMMON.DIM_DEAL_SOURCE      as ds on ds.deal_source_sk = b.deal_source_sk
left  join PROD.NPL_COMMON.DIM_SECURITY_CLASS   as sc on sc.security_class_sk = b.security_class_sk
left  join PROD.NPL_COMMON.DIM_SEGMENT          as sg on sg.segment_sk = b.segment_sk
left  join PROD.NPL_COMMON.DIM_LEGAL_BUYER      as lb on lb.legal_buyer_sk = b.legal_buyer_sk
-- ⚠ COUNTRY: join on ISO_ALPHA2_CODE, NOT country_id. Found 2026-09-09:
-- DIM_COUNTRY.COUNTRY_ID is a hash key while the facts carry ISO alpha-2
-- codes ('ES', 'FI'), so the natural-looking join on country_id matches zero
-- rows and country_name comes back NULL everywhere. The loan fact also
-- carries a non-ISO 'UK' on 48,784 loans that matches nothing; it is kept as
-- the raw code so it stays visible rather than collapsing into 'Unknown'.
left  join PROD.COMMON.DIM_COUNTRY              as co on co.iso_alpha2_code = b.country_id
order by outstanding_eur desc nulls last
limit $row_limit
