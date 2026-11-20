-- ============================================================================
-- SIGMA ELEMENT 'FX Table'. ONE ROW PER (CURRENCY_ID, REPORTING_MONTH).
-- The join key every other element uses to turn a local amount into EUR.
-- ============================================================================
-- GRAIN     currency x month-end. 1,040 PMI rows + one EUR row per portfolio
--           month. Verified unique on (currency_id, reporting_month).
-- READS     PROD only. No sigma_element() call -- this is the bottom of the
--           chain and everything else reads it.
--
-- ⚠⚠⚠ FIXED 2026-09-29 -- A REAL BUG, MEASURED. The previous version wrote
--   DATE_TRUNC('MONTH', date_day) AS reporting_month
-- which turned a month-END key into a month-START one. Every consumer joins on
-- month-end (`= period_end_date`, or `= LAST_DAY(collection_month)`), so the
-- non-EUR leg matched NOTHING and every SEK / PLN / CHF / DKK / GBP rate came
-- back NULL. Only the EUR leg, which was already month-end, ever matched.
--
-- Measured 2026-09-29 on case collections inside the dashboard's own scope
-- (post-capex, whole months only):
--     as the broken element computed it   EUR 124,258,976.86   EUR rows only
--     with this fix                       EUR 235,929,191.93
--     understated by                      EUR 111,670,215.07   = 47.3%
-- FCT_EXCHANGE_RATE_MONTHLY.date_day is month-end on all 1,040 rows, so it is
-- used RAW here. The dbt models beside this file always did this correctly --
-- the truncation was introduced when the query was adapted for Sigma.
-- ⚠ DO NOT "TIDY" date_day BACK INTO A DATE_TRUNC.
--
-- ⚠⚠ TWO RATES, AND THEY ARE NOT INTERCHANGEABLE.
--   rate_flow   monthly average. For things that HAPPEN DURING the month:
--               collections, forecasts, commission, fees.
--   rate_stock  month-end close. For things MEASURED AT a point: balance,
--               carrying value, capex, gross book value.
--   They differ by 0.87% on average for SEK and up to 1.70% in a month, so
--   picking the wrong one is wrong, not approximate.
--
-- ⚠⚠ MULTIPLY BEFORE YOU SUM. In Sigma build a calculated column
-- [amount_local] * [rate_flow] and aggregate THAT. Summing the local amounts
-- first and multiplying after applies one currency's rate to a mixed total.
--
-- ⚠ EUR IS CARRIED AT RATE 1 so every row finds a match. Its months come from
-- the portfolio fact, NOT from the FX table, which only starts 2018-01-31 --
-- otherwise EUR would inherit a coverage limit it does not have.
--
-- ⚠ COVERAGE IS NOT COMPLETE EVEN AFTER THE FIX, and that is the source's
-- limit rather than a defect here: the PMI feed starts 2018-01-31, so SEK
-- resolves 104 of 137 collection months and CHF 104 of 147. The consumers'
-- has_fx_*_flag columns are what say so on a given row.
-- ============================================================================
SELECT
    quote_currency AS currency_id,
    -- ⚠ RAW, NOT TRUNCATED. See the header -- this is the whole bug.
    date_day       AS reporting_month,
    monthly_avg    AS rate_flow,
    ultimo_value   AS rate_stock
FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
WHERE base_currency = 'EUR'
  AND rate_type = 'PMI'
  AND quote_currency <> 'EUR'

UNION ALL

-- ⚠ EUR IS NOT A CONVERSION -- rate 1 -- so this leg must not depend on the FX
-- table's own coverage. The portfolio fact's months are the spine instead.
SELECT DISTINCT
    'EUR'            AS currency_id,
    period_end_date  AS reporting_month,
    1                AS rate_flow,
    1                AS rate_stock
FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
