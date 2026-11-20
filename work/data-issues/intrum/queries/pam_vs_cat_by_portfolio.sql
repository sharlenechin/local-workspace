WITH 
    CAT AS (
        SELECT 
            portfolio_sk, 
            DATE_TRUNC('MONTH', MIN(collection_date)) AS earliest_collection_month, 
            LAST_DAY(MAX(collection_date)) AS latest_collection_month, 
            COUNT(DISTINCT currency_id) AS n_currencies_CAT, 
            SUM(amount) AS total_collections
        FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION
        -- was <=, which let a single collection dated the 1st of this month stretch
        -- latest_collection_month to this month end and pull an incomplete PAM month
        -- into the window. < keeps the comparison to complete months only.
        WHERE collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
        GROUP BY 1 
), 
    PAM_ALL AS (
        -- every month PAM reports for the portfolio, ignoring the CAT overlap window,
        -- so months_PAM is the true total rather than the overlap count
        SELECT 
            portfolio_sk, 
            COUNT(DISTINCT period_end_date) AS months_PAM
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        GROUP BY 1
), 
    PAM_MONTH AS (
        SELECT 
            PAM.portfolio_sk, 
            PAM.period_end_date, 
            SUM(PAM.gross_cash_recoveries) AS gross_cash_recoveries, 
            SUM(PAM.total_balance) AS total_balance, 
            COUNT(DISTINCT PAM.currency_id) AS n_currencies
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS PAM 
        INNER JOIN CAT AS cases
            ON PAM.portfolio_sk = cases.portfolio_sk
        WHERE PAM.period_end_date BETWEEN cases.earliest_collection_month AND cases.latest_collection_month
        GROUP BY 1, 2
), 
    PAM AS (
        SELECT 
            portfolio_sk, 
            SUM(gross_cash_recoveries) AS total_collections, 
            MIN_BY(total_balance, period_end_date) AS balance_first, 
            MAX_BY(total_balance, period_end_date) AS balance_last, 
            MIN_BY(total_balance, period_end_date) - MAX_BY(total_balance, period_end_date) AS balance_reduction, 
            MAX(n_currencies) AS n_currencies_PAM, 
            COUNT(DISTINCT DATE_TRUNC('MONTH', period_end_date)) AS overlap_months
        FROM PAM_MONTH
        GROUP BY 1
)
SELECT 
    PAM.portfolio_sk, 
    portfolio.portfolio_bk, 
    ROUND(ABS(PAM.total_collections - CAT.total_collections) * 100.0 / NULLIF(PAM.total_collections, 0), 2) 
        AS absolute_difference_pct, 
    ROUND(ABS(PAM.total_collections - CAT.total_collections), 2) AS absolute_difference, 
    PAM_ALL.months_PAM, 
    PAM.overlap_months, 
    PAM.total_collections AS total_collections_PAM, 
    CAT.total_collections AS total_collections_CAT, 
    PAM.balance_reduction AS balance_reduction_PAM, 
    -- both sides sum across currencies, so anything above 1 makes the comparison meaningless
    PAM.n_currencies_PAM, 
    CAT.n_currencies_CAT
FROM PAM 
INNER JOIN CAT
    ON PAM.portfolio_sk = CAT.portfolio_sk
INNER JOIN PAM_ALL
    ON PAM.portfolio_sk = PAM_ALL.portfolio_sk
-- LEFT, not INNER: portfolio_sk '-1' is the unknown-portfolio sentinel from
-- int_npl_case_conformed and has no row in DIM_PORTFOLIO (264 rows, 264 sk, 264 bk = 1:1)
LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS portfolio
    ON PAM.portfolio_sk = portfolio.portfolio_sk
ORDER BY absolute_difference_pct ASC
