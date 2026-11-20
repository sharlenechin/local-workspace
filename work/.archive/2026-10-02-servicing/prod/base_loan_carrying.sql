-- ============================================================================
-- base_loan_carrying — BASE: book value per loan per month-end.
-- GRAIN: one row per (CASE_SK, DATE_DAY). Verified genuinely unique.
-- ============================================================================
-- The only route to carrying amount BELOW portfolio level. dbt allocates the
-- portfolio's carrying value down to each loan, so this answers "what is this
-- individual loan worth on our books", which FCT_CARRYING_AMOUNT cannot.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/base_loan_carrying.sql
--   Notebook  : datalake.q("servicing/prod/base_loan_carrying")
--
-- ---------------------------------------------------------------------------
-- GRAIN verified 2026-09-09 on all 111,508,917 rows of
-- MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION: row count == count(distinct
-- case_sk || date_day) exactly. No dedupe needed, nothing here can fan out.
--
-- ⚠ ONLY 9 MONTH-ENDS EXIST: 2025-12-31 .. 2026-08-31.
-- This is NOT a long history. The loan-level balance fact
-- (FCT_CASE_SNAPSHOT_DAILY) goes back to 2014, but the carrying allocation
-- starts in December 2025. Any "carrying value over time" series is limited
-- to those nine points, and asking for an earlier month returns nothing
-- rather than an error. Check what you got before charting a trend.
--
-- ⚠ THE ::number CASTS ARE LOAD-BEARING — DO NOT REMOVE THEM.
-- ALLOCATED_CARRYING_AMOUNT and ALLOCATED_REVALUATION_IMPAIRMENT are
-- Snowflake DECFLOAT. The Arrow path hands DECFLOAT to pandas as a raw dict
-- of exponent and significand, not a number, and datalake's type conversion
-- maps only Decimal and date. The column lands as object dtype and the first
-- .sum() fails with "unsupported operand type(s) for +: 'dict' and 'dict'".
-- Casting in SQL is the fix.
--
-- ⚠ THIS MART CARRIES NO CURRENCY COLUMN.
-- Unlike every other money table here it does not expose CURRENCY_ID, so a
-- sum across loans in different currencies is silently mixed. The loan's
-- currency is joined in below from the balance snapshot so you can group or
-- filter on it — do that before totalling.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY — CHECK IT BEFORE YOU AGGREGATE.
-- 111.5M rows sit behind this. If the row count comes back exactly equal to
-- $row_limit, assume it was cut: narrow $portfolio_filter or raise the cap
-- deliberately.
-- ============================================================================

-- Must be one of the nine month-ends listed above.
set month_end = '2026-07-31';

-- '%' is every portfolio — far too much for pandas at this grain.
set portfolio_filter = 'LOK-DE24016-U01/2512';

set row_limit = 200000;


with allocation as (
    -- The mart is already keyed on PORTFOLIO_BK, so it is filtered directly
    -- rather than via DIM_PORTFOLIO.
    select
        case_bk, case_sk, date_day, portfolio_bk, deal_source_name,
        country_id, deal_bk,
        outstanding_total,
        allocated_carrying_amount::number(38, 6)          as carrying_amount,
        allocated_revaluation_impairment::number(38, 6)   as revaluation_impairment
    from PROD.NPL_COMMON.MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION
    where date_day = $month_end::date
      and portfolio_bk like $portfolio_filter
),

loan_currency as (
    -- The mart has no currency, so take it from the balance snapshot at the
    -- same date. Unique on (case_sk, date_day), so this cannot fan out.
    select s.case_sk, s.currency_id, s.forbearance_flag,
           s.outstanding_principal, s.outstanding_interest, s.outstanding_fees
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    where s.date_day = $month_end::date
)

select
    a.case_bk,                              -- durable loan key: count on this
    a.case_sk,                              -- versioned key
    a.date_day                              as as_of_month_end,

    a.portfolio_bk,
    a.deal_bk,
    a.deal_source_name,
    a.country_id,
    coalesce(co.country_name, a.country_id, 'Unknown') as country_name,
    lc.currency_id,                         -- ⚠ joined in; see header
    cu.currency_name,

    -- ---- book value ------------------------------------------------------
    a.carrying_amount,
    a.revaluation_impairment,

    -- ---- balance, for comparison ----------------------------------------
    a.outstanding_total,
    lc.outstanding_principal,
    lc.outstanding_interest,
    lc.outstanding_fees,
    lc.forbearance_flag,

    -- Book value as a fraction of face value — the headline "what is this
    -- loan actually worth" number. nullif guards the very common zero
    -- balance; expect NULL there rather than a divide error.
    a.carrying_amount / nullif(a.outstanding_total, 0)
                                            as carrying_pct_of_outstanding,
    a.outstanding_total - a.carrying_amount as writedown_vs_outstanding

from allocation as a
left join loan_currency        as lc on lc.case_sk = a.case_sk
-- ⚠ COUNTRY: join on ISO_ALPHA2_CODE, NOT country_id. Found 2026-09-09:
-- DIM_COUNTRY.COUNTRY_ID is a hash key while the facts carry ISO alpha-2
-- codes ('ES', 'FI'), so the natural-looking join on country_id matches zero
-- rows and country_name comes back NULL everywhere. The fact also carries a
-- non-ISO 'UK' that matches nothing; it is kept as the raw code so it stays
-- visible rather than collapsing into 'Unknown'.
left join PROD.COMMON.DIM_COUNTRY  as co on co.iso_alpha2_code = a.country_id
left join PROD.COMMON.DIM_CURRENCY as cu on cu.currency_alpha_code = lc.currency_id
order by a.carrying_amount desc nulls last
limit $row_limit
