-- ============================================================================
-- SIGMA ELEMENT 'Feed Status'. ONE ROW PER FEED. Top right of the dashboard,
-- ABOVE the reconciliation figure.
-- ============================================================================
-- GRAIN     one row per source feed. 4 rows.
-- READS     PROD only. Independent of every other element, so it still renders
--           when a feed is missing -- which is exactly when it is needed.
--
-- ⚠⚠⚠ WHY THIS SITS ABOVE RECONCILIATION. A stale feed CAUSES a reconciliation
-- failure. If the portfolio report has not arrived for a month, every case row
-- in that month reads "not reconciled" when the truth is "not comparable".
-- Reading the reconciliation figure without first reading this strip leads to
-- blaming the case feed for a month the servicer simply has not sent.
--
-- ⚠⚠ THREE DATES, NOT ONE. "Last updated" is the number that misleads: our
-- tables rebuild nightly, so it always says today, whatever the data does.
--   reaches       how far the data goes        -> what the dashboard can show
--   source_as_of  when the source captured it  -> whether the SERVICER is late
--   rebuilt_at    when our pipeline last ran   -> whether WE are late
--
-- ⚠ Measured 2026-10-07: the portfolio report rebuilt at 17:54 the same day,
-- but its data was captured 2026-09-18 and still stops at 2026-08-31. Our
-- pipeline is fine; the servicer's September report has not arrived. Without
-- this strip that reads as a collapse in collections.
--
-- ⚠ A month absent from a feed must render as ABSENT, never as zero. Zero says
-- "they collected nothing"; absent says "we do not know".
-- ============================================================================
WITH feeds AS (
    SELECT
        'Portfolio report (money)'    AS feed_name,
        1                             AS feed_order,
        MAX(period_end_date)          AS reaches,
        MAX(as_of_ts)::DATE           AS source_as_of
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY

    UNION ALL
    -- ⚠ The current month is excluded, matching every other element, so a
    -- part-loaded today never reads as the newest complete month.
    SELECT
        'Case collections', 2,
        MAX(IFF(collection_date < DATE_TRUNC('MONTH', CURRENT_DATE()),
                LAST_DAY(collection_date), NULL)),
        MAX(as_of_ts)::DATE
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION

    UNION ALL
    SELECT 'Case book (snapshot)', 3, MAX(date_day), MAX(as_of_ts)::DATE
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY

    UNION ALL
    -- ⚠ No as_of_ts on the rate table, so a stale FX feed can only be told from
    -- how far it reaches.
    SELECT 'FX rates', 4, MAX(date_day), NULL
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR'
)

SELECT
    feed_name,
    feed_order,
    reaches,
    source_as_of,
    DATEDIFF('MONTH', reaches, DATE_TRUNC('MONTH', CURRENT_DATE()))
                                                       AS months_behind,
    DATEDIFF('DAY', source_as_of, CURRENT_DATE())      AS source_age_days,

    -- One month behind is normal: a month closes before it can be reported.
    DATEDIFF('MONTH', reaches, DATE_TRUNC('MONTH', CURRENT_DATE())) <= 1
                                                       AS is_fresh_flag,

    -- ⚠ The action, not just the state. Who has to do something about it.
    CASE
        WHEN DATEDIFF('MONTH', reaches, DATE_TRUNC('MONTH', CURRENT_DATE())) <= 1
            THEN 'Fresh'
        WHEN source_as_of IS NULL
            THEN 'Stale - no source timestamp, check the feed'
        WHEN DATEDIFF('DAY', source_as_of, CURRENT_DATE()) > 14
            THEN 'Stale - chase the servicer'
        ELSE 'Stale - our pipeline ran but the data did not move'
    END                                                AS feed_status
FROM feeds
ORDER BY feed_order
