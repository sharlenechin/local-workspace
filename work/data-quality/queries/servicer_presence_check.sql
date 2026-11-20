-- Where does one servicer appear in PROD? One row per PROD table.
--
-- Grain: one row per table checked. Change $servicer to any servicer_name in
-- DIM_REPORTING_SYSTEM (lower case: cerved, gescobro, intrum, massey, souq).
--
-- PROD has only ONE servicer field: DIM_REPORTING_SYSTEM.servicer_name, reached
-- from the case feed's REPORTING_SYSTEM_SK. The portfolio feed's own
-- REPORTING_SYSTEM_SK is 100% NULL (measured 2026-10-13), so the portfolio-level
-- tables are found through the portfolios the case feed ties to this servicer.
-- A servicer with no case feed at all (Fire) cannot be found this way: it exists
-- only in the dashboard's business rule.
--
-- Measured for cerved on 2026-10-13: listed, case feed on 3 portfolios / 6
-- combined refs to Sep 2026, ZERO payments in FCT_CASE_COLLECTION, portfolio
-- feed and servicer forecast present for all 3.

SET servicer = 'cerved';

WITH servicer_systems AS (
    SELECT reporting_system_sk
    FROM PROD.NPL_COMMON.DIM_REPORTING_SYSTEM
    WHERE LOWER(servicer_name) = $servicer
),

case_book AS (
    -- One scan of the case feed for this servicer; every portfolio check below reuses it.
    SELECT s.portfolio_sk, s.batch_sk, s.date_day
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    INNER JOIN servicer_systems AS ss
        ON ss.reporting_system_sk = s.reporting_system_sk
),

servicer_portfolios AS (
    SELECT DISTINCT portfolio_sk FROM case_book
)

SELECT 1 AS step, 'DIM_REPORTING_SYSTEM' AS prod_table, 'Servicer is listed' AS what_it_shows,
       COUNT(*) AS row_count, NULL AS portfolios, NULL AS combined_refs, NULL AS first_month, NULL AS last_month
FROM servicer_systems

UNION ALL
SELECT 2, 'FCT_CASE_SNAPSHOT_DAILY', 'Case feed: cases and balances',
       COUNT(*), COUNT(DISTINCT portfolio_sk), COUNT(DISTINCT batch_sk), MIN(date_day), MAX(date_day)
FROM case_book

UNION ALL
SELECT 3, 'FCT_CASE_COLLECTION', 'Case feed: payments',
       COUNT(*), COUNT(DISTINCT c.portfolio_sk), COUNT(DISTINCT c.batch_sk),
       LAST_DAY(MIN(c.collection_date)), LAST_DAY(MAX(c.collection_date))
FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
INNER JOIN servicer_systems AS ss
    ON ss.reporting_system_sk = c.reporting_system_sk
-- Bounded at today: the table holds payments dated up to the year 4570.
WHERE c.collection_date <= CURRENT_DATE()

UNION ALL
SELECT 4, 'FCT_PORTFOLIO_SNAPSHOT_MONTHLY', 'Portfolio feed, for the case feed''s portfolios',
       COUNT(*), COUNT(DISTINCT f.portfolio_sk), COUNT(DISTINCT f.batch_sk), MIN(f.period_end_date), MAX(f.period_end_date)
FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
INNER JOIN servicer_portfolios AS sp
    ON sp.portfolio_sk = f.portfolio_sk
WHERE f.period_end_date <= CURRENT_DATE()

UNION ALL
SELECT 5, 'FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY', 'Servicer forecast, same portfolios',
       COUNT(*), COUNT(DISTINCT f.portfolio_sk), COUNT(DISTINCT f.batch_sk), MIN(f.period_end_date), MAX(f.period_end_date)
FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY AS f
INNER JOIN servicer_portfolios AS sp
    ON sp.portfolio_sk = f.portfolio_sk

UNION ALL
SELECT 6, 'MART_NPL_SERVICING_AGG_CASES_MONTHLY', 'Servicing cases mart, same portfolios',
       COUNT(*), COUNT(DISTINCT m.portfolio_sk), NULL, MIN(m.period_end_date), MAX(m.period_end_date)
FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS m
INNER JOIN servicer_portfolios AS sp
    ON sp.portfolio_sk = m.portfolio_sk

ORDER BY step;
