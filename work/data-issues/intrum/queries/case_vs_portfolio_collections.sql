-- Like-for-like: only portfolio-months present on BOTH sides, same currency.
-- Coverage is reported separately rather than mixed into the ratio.
set from_month = '2025-01-01';

WITH case_coll AS (
    SELECT portfolio_sk, currency_id, last_day(collection_date) AS period_end_date,
           sum(amount) AS case_collections
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION
    WHERE collection_date >= $from_month::date
      AND collection_date < date_trunc('month', current_date())
    GROUP BY 1, 2, 3
),

portfolio_coll AS (
    SELECT portfolio_sk, currency_id, period_end_date,
           gross_cash_recoveries AS portfolio_collections
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    WHERE period_end_date >= $from_month::date
      AND period_end_date < date_trunc('month', current_date())
    QUALIFY row_number() OVER (
        PARTITION BY portfolio_sk, period_end_date ORDER BY snapshot_version DESC
    ) = 1
)

SELECT 'A. matched only' AS block, p.currency_id,
       count(*) AS portfolio_months_matched,
       round(sum(c.case_collections), 0) AS case_level,
       round(sum(p.portfolio_collections), 0) AS portfolio_level,
       round(100.0 * sum(c.case_collections) / nullif(sum(p.portfolio_collections), 0), 2) AS pct
FROM portfolio_coll AS p
INNER JOIN case_coll AS c
    ON p.portfolio_sk = c.portfolio_sk
   AND p.period_end_date = c.period_end_date
   AND p.currency_id = c.currency_id
GROUP BY 1, 2
UNION ALL
SELECT 'B. coverage', 'portfolio-months with portfolio data',
       count(*),
       count_if(c.portfolio_sk IS NOT NULL),
       count_if(c.portfolio_sk IS NULL),
       round(100.0 * count_if(c.portfolio_sk IS NOT NULL) / count(*), 2)
FROM portfolio_coll AS p
LEFT JOIN case_coll AS c
    ON p.portfolio_sk = c.portfolio_sk
   AND p.period_end_date = c.period_end_date
   AND p.currency_id = c.currency_id
ORDER BY 1, 5 DESC NULLS LAST;
