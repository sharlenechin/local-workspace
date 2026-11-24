-- One deal's PAM by month from the sandbox build (DEV.HACKATHON): what Intrum reports the deal collected.
-- Grain: one row per month-end; the whole deal, every batch, gross_cash_recoveries_unlevelled as in the PAM check.
-- Runs on the sandbox (connection dev); plot_payments.py sets portfolio_id to each deal's Intrum id.
-- The current month is not complete yet, so it is left out.

SET portfolio_id = 'SE17039';

SELECT
    p.period_end_date AS month_end,
    SUM(p.gross_cash_recoveries_unlevelled) AS pam
FROM dev.hackathon.fct_npl_portfolio_snapshot_monthly AS p
INNER JOIN dev.hackathon.dim_npl_batch AS b
    ON b.batch_sk = p.batch_sk
WHERE b.servicer_parent_portfolio_bk = $portfolio_id
    AND p.period_end_date < DATE_TRUNC(MONTH, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;
