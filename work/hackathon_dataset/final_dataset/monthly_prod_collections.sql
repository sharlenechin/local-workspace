-- One deal's case payments by month on prod today, before the two collection fixes, for comparison only.
-- Grain: one row per month-end; the whole deal, every batch, FCT_CASE_COLLECTION as prod builds it.
-- Runs on prod; plot_payments.py sets portfolio_id to each deal's Intrum id.
-- The current month is not complete yet, so it is left out.

SET portfolio_id = 'SE17039';

SELECT
    LAST_DAY(f.collection_date) AS month_end,
    SUM(f.amount) AS collected
FROM prod.npl_common.fct_case_collection AS f
INNER JOIN prod.npl_common.dim_batch AS b
    ON b.batch_sk = f.batch_sk
WHERE b.servicer_parent_portfolio_bk = $portfolio_id
    AND f.collection_date < DATE_TRUNC(MONTH, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;
