-- One deal's warehouse payments by month from the sandbox build (DEV.HACKATHON), at any date: the chart's black line.
-- Grain: one row per month-end; the whole deal, every batch, including payments Intrum took before we bought it,
--   so the line overlays the Asset Index bars wherever the warehouse has the same months. The dataset itself
--   uses only the months after each deal's split (payments_post_registration.sql).
-- Runs on the sandbox (connection dev); plot_payments.py sets portfolio_id to each deal's Intrum id.
-- The current month is not complete yet, so it is left out; that also drops placeholder dates such as 2099-12-30.

SET portfolio_id = 'SE17039';

SELECT
    LAST_DAY(f.collection_date) AS month_end,
    SUM(f.amount) AS collected
FROM dev.hackathon.fct_npl_case_collection AS f
INNER JOIN dev.hackathon.dim_npl_batch AS b
    ON b.batch_sk = f.batch_sk
WHERE b.servicer_parent_portfolio_bk = $portfolio_id
    AND f.collection_date < DATE_TRUNC(MONTH, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;
