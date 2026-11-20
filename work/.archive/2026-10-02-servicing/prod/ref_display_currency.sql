-- ============================================================================
-- ref_display_currency — REFERENCE: EUR per unit of each DISPLAY currency,
-- one row per (MONTH_END, DISPLAY_CURRENCY).
-- ============================================================================
-- The dashboard computes everything in EUR (the agg_* files) and only at the
-- last step re-expresses a figure in the currency the reader picked. This is
-- the table it divides by. Only four display currencies are offered, by
-- decision (2026-09-09): EUR, USD, GBP, SEK.
--
--   Terminal : mise run sql -- work/servicing/prod/ref_display_currency.sql
--   Notebook : datalake.q("servicing/prod/ref_display_currency")
--
-- ⚠ DIVIDE, DO NOT MULTIPLY. The stored rate is EUR per ONE unit of the
-- display currency (see ref_fx_rate.sql: the "base/quote" names are the
-- other way round from market convention). So
--     amount_usd = amount_eur / eur_per_unit
-- Multiplying values USD 1m at USD 0.86m when it should be USD 1.16m.
--
-- ⚠ FLOWS AND STOCKS USE DIFFERENT COLUMNS, same rule as everywhere else:
--     collections, forecasts, variances -> EUR_PER_UNIT_FLOW  (monthly avg)
--     balances, carrying, capex, GBV    -> EUR_PER_UNIT_STOCK (month-end)
--
-- ⚠ COVERAGE 2018-01-31 .. 2026-08-31, monthly. A month outside it has no
-- row; a join yields NULL and the displayed figure vanishes rather than
-- silently staying in EUR. That is intended: check for NULL, do not coalesce
-- to 1.
--
-- The EUR identity row is unioned in at 1.0 so one join covers every choice.
-- ============================================================================

set date_from = '2018-01-31';

select date_day       as month_end,
       quote_currency as display_currency,
       monthly_avg    as eur_per_unit_flow,
       ultimo_value   as eur_per_unit_stock
from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
where base_currency = 'EUR'
  and rate_type     = 'PMI'
  and quote_currency in ('USD', 'GBP', 'SEK')
  and date_day     >= $date_from::date

union all

select distinct date_day, 'EUR', 1, 1
from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
where base_currency = 'EUR' and rate_type = 'PMI'
  and date_day >= $date_from::date

order by 1, 2
