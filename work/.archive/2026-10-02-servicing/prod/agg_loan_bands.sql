-- ============================================================================
-- agg_loan_bands — SERVICING DASHBOARD: performance by segment and band.
-- GRAIN: one row per (PORTFOLIO, MONTH_END, ORIGINAL_CURRENCY, SEGMENT,
--        BORROWER_TYPE, BALANCE_BAND, AGE_BAND) at ONE month-end. The
--        servicer columns are functions of portfolio and do not widen it.
-- EVERY MONEY COLUMN IS EUR.
-- ============================================================================
-- Answers "how do the different kinds of debt perform" — individuals vs
-- companies, small vs large balances, young vs old debt — from the loan
-- level, as at $month_end, with the collections of the 12 months up to it.
--
--   Terminal : mise run sql -- work/servicing/prod/agg_loan_bands.sql
--   Notebook : datalake.q("servicing/prod/agg_loan_bands", month_end="2026-07-31")
--
-- Measured 2026-09-09 on NPL_ANALYST_WH (X-Small): about 60-90 s for all
-- portfolios at one month-end, a few thousand rows. It is loaded on demand.
--
-- ---------------------------------------------------------------------------
-- ⚠ LOAN-LEVEL COVERAGE IS PARTIAL. At 2026-07-31 the loan fact holds 187
-- portfolios against 250 reporting at portfolio level, and loan-level book
-- is 87%..146% of portfolio-level depending on servicer (see
-- agg_loan_detail.sql). Use this file for the MIX and RELATIVE performance
-- of segments. Never quote its totals as the book.
--
-- ⚠ THE FOUR DIMENSIONS, AND WHERE THEY COME FROM (verified 2026-09-09):
--   SEGMENT       DIM_SEGMENT via the loan snapshot. Servicer-defined labels;
--                 21m of 21.8m loans sit in bare codes '01'/'02'/'04' (the
--                 Intrum PAM feed), while the Spanish portfolios carry
--                 'SMEs - Gescobro', 'Individuals - Intrum Servicing', etc.
--                 It is what the servicer chose to call things, not a
--                 taxonomy. Shown as-is.
--   BORROWER_TYPE DIM_BORROWER.LEGAL_EBA_TYPE via BRG_CASE_BORROWER. The
--                 one consistent individuals-vs-companies split across all
--                 servicers: Households 73.8% of loans, Non-financial
--                 corporations 4.7%, no borrower row 21.3%, 'P' 0.2%.
--                 A joint loan takes the corporate type if ANY borrower is
--                 corporate (max() over the case's borrowers).
--   BALANCE_BAND  outstanding_total converted to EUR at month-end, then
--                 banded, so bands are comparable across currencies.
--   AGE_BAND      years since DIM_CASE.DERIVED_DEFAULT_DATE (99.3% filled).
--                 247k loans carry a default date before 1990 and 4.6k one
--                 after the month-end; both are implausible and go to
--                 'Unknown' rather than into a band.
--
-- ⚠ NOT AVAILABLE, so not here: legal / amicable / insolvency stage
-- (DIM_CASE.STATUS_* and CLOSING_* are 100% NULL), instalment amounts,
-- borrower age, contact or collector activity. See the dashboard's data
-- page. A segment-split business plan does not exist either: the servicer
-- forecast carries exactly one segment per portfolio (241 of 241).
--
-- Inherits the guards in .claude/agents/query-helper.md (Part 3). Load-bearing here: collections
-- matched on CASE_BK (#1), PMI rate multiplied with the EUR identity row
-- (#6, #7), collection_date <= current_date() (#8), country joined on
-- iso_alpha2_code (#10), LEFT joins on every dimension (#4).
-- ============================================================================

set month_end        = '2026-07-31';
set portfolio_filter = '%';


with fx as (
    select date_day as month_end, quote_currency as ccy,
           monthly_avg as rate_flow, ultimo_value as rate_stock
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and rate_type = 'PMI' and quote_currency <> 'EUR'
    union all
    select date_day, 'EUR', 1, 1
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency = 'EUR' and quote_currency = 'EUR'
),

portfolio_scope as (
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
),

book as (
    select s.case_sk, s.portfolio_sk, s.currency_id, s.country_id,
           s.segment_sk, s.deal_sk, s.deal_source_sk,
           s.outstanding_total
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    inner join portfolio_scope p on p.portfolio_sk = s.portfolio_sk
    where s.date_day = $month_end::date
),

-- CASE_BK and the default date, one row per case_sk (guard #1).
loan_keys as (
    select b.case_sk, dc.case_bk, dc.derived_default_date
    from book b
    inner join PROD.NPL_COMMON.DIM_CASE dc on dc.case_sk = b.case_sk
),

borrower as (
    select br.case_sk,
           max(bo.legal_eba_type) as legal_eba_type   -- any corporate borrower wins
    from PROD.NPL_COMMON.BRG_CASE_BORROWER br
    inner join PROD.NPL_COMMON.DIM_BORROWER bo on bo.borrower_sk = br.borrower_sk and bo.is_current
    inner join book b on b.case_sk = br.case_sk
    group by 1
),

collections_12m as (
    select dcc.case_bk,
           sum(c.amount) as collected_12m_local
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join portfolio_scope p on p.portfolio_sk = c.portfolio_sk
    inner join PROD.NPL_COMMON.DIM_CASE dcc on dcc.case_sk = c.case_sk
    where c.collection_date >  dateadd(month, -12, $month_end::date)
      and c.collection_date <= least($month_end::date, current_date())
    group by 1
),

loans as (
    select
        b.portfolio_sk, b.currency_id, b.country_id, b.segment_sk, b.deal_sk, b.deal_source_sk,
        lk.case_bk,
        case bo.legal_eba_type
            when 'Households'                 then 'Individuals'
            when 'Non-financial corporations' then 'Companies'
            else 'Unknown' end                                   as borrower_type,
        b.outstanding_total * f.rate_stock                       as outstanding_eur,
        coalesce(cl.collected_12m_local, 0) * f.rate_flow        as collected_12m_eur,
        case when f.rate_stock is null                                    then 'Unknown'
             when b.outstanding_total * f.rate_stock <     1000           then 'a. under 1k'
             when b.outstanding_total * f.rate_stock <     5000           then 'b. 1k to 5k'
             when b.outstanding_total * f.rate_stock <    20000           then 'c. 5k to 20k'
             when b.outstanding_total * f.rate_stock <   100000           then 'd. 20k to 100k'
             else                                                              'e. over 100k' end as balance_band,
        case when lk.derived_default_date is null
               or lk.derived_default_date < '1990-01-01'
               or lk.derived_default_date > $month_end::date                then 'Unknown'
             when datediff(year, lk.derived_default_date, $month_end::date) <  2 then 'a. under 2 years'
             when datediff(year, lk.derived_default_date, $month_end::date) <  5 then 'b. 2 to 5 years'
             when datediff(year, lk.derived_default_date, $month_end::date) < 10 then 'c. 5 to 10 years'
             else                                                                  'd. over 10 years' end as age_band,
        f.rate_stock is not null and f.rate_flow is not null     as is_eur_complete
    from book as b
    inner join loan_keys        as lk on lk.case_sk = b.case_sk
    left  join borrower         as bo on bo.case_sk = b.case_sk
    left  join collections_12m  as cl on cl.case_bk = lk.case_bk
    left  join fx               as f  on f.ccy = b.currency_id and f.month_end = $month_end::date
)

select
    $month_end::date                                 as month_end,
    coalesce(ps.portfolio_bk, '(unknown portfolio ' || l.portfolio_sk || ')') as portfolio,
    l.currency_id                                    as original_currency,
    coalesce(co.country_name, l.country_id, 'Unknown') as country_name,
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
    case when ds.deal_source_name = 'LEGACY' and l.country_id = 'ES' then 'Gescobro'
         when ds.deal_source_name = 'LEGACY' and l.country_id = 'IT' then 'Cerved'
         else 'Intrum' end                                as servicer,
    case coalesce(ps.portfolio_bk, '')
         when 'LEG-ES25001-U00/2512' then 'TDX'
         when 'HEI-GR25001-U01/2512' then 'QQuant'
         when 'HEI-GR25001-U02/2512' then 'QQuant'
         else '' end                                      as subservicer,
    case when coalesce(ps.portfolio_bk, '') in ('LEG-ES25001-U00/2512', 'HEI-GR25001-U01/2512', 'HEI-GR25001-U02/2512')
         then concat(case when ds.deal_source_name = 'LEGACY' and l.country_id = 'ES' then 'Gescobro'
                          when ds.deal_source_name = 'LEGACY' and l.country_id = 'IT' then 'Cerved'
                          else 'Intrum' end,
                     ' - ',
                     case coalesce(ps.portfolio_bk, '') when 'LEG-ES25001-U00/2512' then 'TDX' else 'QQuant' end)
         else case when ds.deal_source_name = 'LEGACY' and l.country_id = 'ES' then 'Gescobro'
                   when ds.deal_source_name = 'LEGACY' and l.country_id = 'IT' then 'Cerved'
                   else 'Intrum' end end                  as servicer_full,
    coalesce(dd.deal_alias, dd.deal_bk, 'Unknown')   as deal,
    coalesce(sg.segment_name, 'Unknown')             as segment,
    l.borrower_type,
    l.balance_band,
    l.age_band,

    count(distinct l.case_bk)                        as loans,
    count(distinct case when l.collected_12m_eur > 0 then l.case_bk end)
                                                     as paying_loans_12m,
    sum(l.outstanding_eur)                           as outstanding_eur,
    sum(l.collected_12m_eur)                         as collected_12m_eur,
    -- collections over the year per unit of balance held at the end of it.
    -- A crude recovery yield, comparable across bands; not an IRR.
    div0null(sum(l.collected_12m_eur), sum(l.outstanding_eur))
                                                     as yield_12m,
    min(l.is_eur_complete)                           as is_eur_complete

from loans as l
left join PROD.NPL_COMMON.DIM_PORTFOLIO   as ps on ps.portfolio_sk = l.portfolio_sk
left join PROD.NPL_COMMON.DIM_SEGMENT     as sg on sg.segment_sk = l.segment_sk
left join PROD.NPL_COMMON.DIM_DEAL        as dd on dd.deal_sk = l.deal_sk
left join PROD.NPL_COMMON.DIM_DEAL_SOURCE as ds on ds.deal_source_sk = l.deal_source_sk
-- Guard #10: iso_alpha2_code, not country_id.
left join PROD.COMMON.DIM_COUNTRY         as co on co.iso_alpha2_code = l.country_id
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
order by outstanding_eur desc nulls last
