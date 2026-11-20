-- ============================================================================
-- FX reference. ONE ROW PER (CURRENCY, REPORTING_MONTH). Join key for every
-- local-currency amount in the other datasets.
-- ============================================================================
-- ⚠⚠ TWO RATES, AND THEY ARE NOT INTERCHANGEABLE.
--   RATE_FLOW   monthly average. For things that HAPPEN DURING the month:
--               collections, forecasts, commission, fees.
--   RATE_STOCK  month-end. For things MEASURED AT a point: balance, carrying
--               value, capex, gross book value.
--   They differ by 0.87% on average for SEK and up to 1.70% in a month, so
--   picking the wrong one is wrong, not approximate.
--
-- ⚠⚠ MULTIPLY BEFORE YOU SUM. In Sigma make a calculated column
--   [amount_local] * [rate_flow] and aggregate THAT. Summing the local amounts
--   first and multiplying after applies one currency's rate to a mixed total.
--
-- ⚠ EUR IS PRESENT WITH RATE 1 so every row joins. Its months come from the
-- portfolio fact, not the FX table, which only starts 2018-01-31.
-- Key verified unique: 1,040 rows, 1,040 (currency, month) pairs.
-- ============================================================================
SELECT
    quote_currency AS currency_id,
    DATE_TRUNC('MONTH', date_day) AS reporting_month,
    monthly_avg    AS rate_flow,
    ultimo_value   AS rate_stock
FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
WHERE base_currency = 'EUR'
  AND rate_type = 'PMI'
  AND quote_currency <> 'EUR'

UNION ALL

SELECT DISTINCT
    'EUR',
    period_end_date,
    1,
    1
FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY