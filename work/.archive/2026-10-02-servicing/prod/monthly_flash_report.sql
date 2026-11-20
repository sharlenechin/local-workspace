-- ============================================================================
-- monthly_flash_report — PORTFOLIO × MONTH: actual vs forecast, as published.
-- GRAIN: one row per (PORTFOLIO_BK, MONTH_END_DATE). Verified unique.
-- ============================================================================
-- The stakeholder-facing comparison, read straight from the warehouse mart
-- MART_NPL_FLASH_REPORT rather than rebuilt. Use this when the question is
-- "what does the flash report say", so your number matches theirs exactly.
--
-- For your own analysis prefer monthly_portfolio_performance.sql (actuals)
-- and monthly_portfolio_forecast.sql (forecasts) — the two caveats below are
-- why.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/monthly_flash_report.sql
--   Notebook  : datalake.q("servicing/prod/monthly_flash_report")
--
-- ---------------------------------------------------------------------------
-- GRAIN verified 2026-09-09: 44,313 rows, 44,313 distinct
-- (PORTFOLIO_BK, MONTH_END_DATE). Unique, no dedupe needed.
--
-- WHAT IT IS BUILT FROM. Read from the dbt model
-- brocc-data/transformation/dbt/models/marts/npl_common/marts/mart_npl_flash_report.sql
-- on 2026-09-09 — it is a full outer join of three sources onto one spine:
--   GCF/NCF_ACTUAL        FCT_PORTFOLIO_SNAPSHOT_MONTHLY
--   GCF/NCF_UNDERWRITING  FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY
--   GCF/NCF_ACTIVE        FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY
--   CARRYING_AMOUNT       FCT_CARRYING_AMOUNT.CLOSING_VALUE
-- plus six dimensions. It does NOT use the servicer forecast, and it does
-- not touch loan-level data at all.
--
-- Because it is a full outer join, a row can exist with only a forecast and
-- no actual, or the reverse. A NULL in GCF_ACTUAL means "no actual for this
-- portfolio-month", not zero — coalesce it deliberately, or a variance
-- becomes the forecast itself.
--
-- ⚠ CURRENCY IS COLLAPSED WITH any_value(). THE LABEL CAN BE WRONG.
-- The model groups to portfolio × month and picks CURRENCY_ID with
-- any_value(), so a portfolio spanning several currencies gets ONE
-- arbitrary label while GCF/NCF are summed across all of them underneath.
-- monthly_portfolio_performance.sql keeps currency in the grain on purpose,
-- which is why the two disagree for multi-currency portfolios — and why it
-- is the safer basis for anything that has to foot. Do not "reconcile" the
-- difference; it is this.
--
-- ⚠ IT EXTENDS TO 2041-06-30 AND CARRYING_AMOUNT GOES NEGATIVE.
-- CARRYING_AMOUNT is FCT_CARRYING_AMOUNT.CLOSING_VALUE, computed recursively
-- (opening + interest - gross forecast). Past the forecast horizon that
-- recursion compounds and diverges: 792 of 43,773 source rows are negative,
-- the first as soon as 2026-11-30, worst around -EUR 2.88tn. On or before
-- today there are ZERO negative rows. $to_month below defaults to today for
-- exactly this reason. Never chart carrying amount to the end of the table.
--
-- ⚠ HISTORY STARTS 2025-07-31. The model filters period_end_date >
-- '2025-06-30', so there is no flash history before that even though the
-- underlying actuals go back to 2014. Use
-- monthly_portfolio_performance.sql for longer series.
--
-- ⚠ THE ::number CAST ON CARRYING_AMOUNT IS LOAD-BEARING.
-- It is DECFLOAT, which reaches pandas as a raw exponent/significand dict
-- and breaks the first .sum(). Cast in SQL.
-- ============================================================================

-- Window. $to_month defaults to today so the divergent projection is
-- excluded; move it out deliberately if you want the forecast tail.
set from_month = '2025-07-31';
set to_month   = '2026-07-31';

set portfolio_filter = '%';
set row_limit = 100000;


select
    f.portfolio_bk,
    f.month_end_date,
    f.month_end_date <= current_date()      as is_actual_period,

    -- ---- dimensions, as the flash report labels them ---------------------
    f.deal_bk,
    f.deal_name,
    f.seller_name,
    f.deal_source_name,
    f.legal_buyer_name,
    f.ownership_share,
    f.security_class_name,
    f.batch_bk,
    f.country_id,
    f.currency_id,                          -- ⚠ arbitrary if the portfolio
                                            -- spans currencies; see header

    -- ---- actual ----------------------------------------------------------
    f.gcf_actual,                           -- NULL = no actual, not zero
    f.ncf_actual,

    -- ---- forecasts -------------------------------------------------------
    f.gcf_underwriting,                     -- the original investment case
    f.ncf_underwriting,
    f.gcf_active,                           -- the current accounting forecast
    f.ncf_active,

    -- ---- variances, on gross ---------------------------------------------
    -- Left NULL rather than coalesced to zero: a missing actual and a true
    -- zero are different facts, and averaging them together is how a
    -- reporting gap turns into an apparent shortfall.
    f.gcf_actual - f.gcf_active             as variance_vs_active,
    f.gcf_actual - f.gcf_underwriting       as variance_vs_underwriting,
    div0null(f.gcf_actual, f.gcf_active)    as actual_pct_of_active,
    div0null(f.gcf_actual, f.gcf_underwriting)
                                            as actual_pct_of_underwriting,

    -- ---- book value and acquisition -------------------------------------
    f.carrying_amount::number(38, 6)        as carrying_amount,
    f.capex_amount,
    f.capex_date,
    f.legacy_capex_date,
    datediff(month, f.capex_date, f.month_end_date) as months_since_capex

from PROD.NPL_COMMON.MART_NPL_FLASH_REPORT as f
where f.month_end_date >= $from_month::date
  and f.month_end_date <= $to_month::date
  -- Keeps the divergent carrying-amount projection out even if $to_month is
  -- moved past today. Remove this only if you understand the warning above.
  and f.month_end_date <= current_date()
  and f.portfolio_bk like $portfolio_filter
order by f.portfolio_bk, f.month_end_date
limit $row_limit
