-- HEI-SE17039, HEI-SE20009, HEI-SE19026, LOK-SE25008 (SE25018), LOK-SE25013 (SE25037) BEFORE the hackathon-test fixes: prod NPL_COMMON, same definitions as
-- ../individual_deal_dataset/HEI-SE17039/summary/summary_sources.sql. GRAIN one row per deal x source (x Intrum system for CAT).
-- WINDOW  purchase month to the portfolio snapshot's last month, per deal.
-- MONTHS  counted as distinct months: a deal with several batches has several rows per month.

WITH deal_batch AS (
    SELECT batch_sk, servicer_parent_portfolio_bk AS intrum_id, legacy_capex_date
    FROM prod.npl_common.dim_batch
    WHERE servicer_parent_portfolio_bk IN ('SE17039', 'SE20009', 'SE19026', 'SE25018', 'SE25037')
),

portfolio_month AS (
    SELECT b.intrum_id, s.period_end_date, s.gross_cash_recoveries
    FROM prod.npl_common.fct_portfolio_snapshot_monthly AS s
    INNER JOIN deal_batch AS b ON b.batch_sk = s.batch_sk
),

window_months AS (
    SELECT
        b.intrum_id,
        DATE_TRUNC(MONTH, MIN(b.legacy_capex_date)) AS window_start,
        MAX(p.period_end_date) AS window_end
    FROM deal_batch AS b
    INNER JOIN portfolio_month AS p ON p.intrum_id = b.intrum_id
    GROUP BY 1
),

collections AS (
    SELECT b.intrum_id, f.case_id, f.collection_date, f.amount, r.reporting_system_code
    FROM prod.npl_common.fct_case_collection AS f
    INNER JOIN deal_batch AS b ON b.batch_sk = f.batch_sk
    INNER JOIN window_months AS w ON w.intrum_id = b.intrum_id
    LEFT JOIN prod.npl_common.dim_reporting_system AS r ON r.reporting_system_sk = f.reporting_system_sk
    WHERE f.collection_date BETWEEN w.window_start AND w.window_end
)

SELECT p.intrum_id, 'PAM (portfolio snapshot)' AS source, SUM(p.gross_cash_recoveries) AS paid,
       COUNT(DISTINCT IFF(p.gross_cash_recoveries <> 0, p.period_end_date, NULL)) AS months_with_payments, NULL AS cases_with_payments
FROM portfolio_month AS p
INNER JOIN window_months AS w ON w.intrum_id = p.intrum_id
WHERE p.period_end_date BETWEEN w.window_start AND w.window_end
GROUP BY 1
UNION ALL
SELECT intrum_id, 'CAT (case collection)', SUM(amount), COUNT(DISTINCT LAST_DAY(collection_date)), COUNT(DISTINCT case_id)
FROM collections GROUP BY 1
UNION ALL
SELECT intrum_id, 'CAT system ' || reporting_system_code, SUM(amount), COUNT(DISTINCT LAST_DAY(collection_date)), COUNT(DISTINCT case_id)
FROM collections GROUP BY 1, reporting_system_code
ORDER BY 1, 2;
