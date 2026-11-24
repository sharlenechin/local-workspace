-- Per Swedish deal: cases in the hackathon build, and the first and last month with payments in CAT
-- (fct_case_collection, after purchase) and PAM (portfolio snapshot). Rolled up by group in RESULTS.md.
-- GRAIN   one row per Intrum deal. Months stop at the last complete month (drops placeholder dates).

WITH batches AS (
    SELECT batch_sk, servicer_parent_portfolio_bk AS intrum_id, legacy_capex_date
    FROM dev.hackathon.dim_npl_batch
    WHERE country_id = 'SE' AND servicer_name = 'intrum'
),

deals AS (
    SELECT intrum_id, MIN(legacy_capex_date) AS acquisition_date
    FROM batches GROUP BY 1
),

cases AS (
    SELECT b.intrum_id, COUNT(DISTINCT c.case_bk) AS cases
    FROM dev.hackathon.dim_npl_case AS c
    INNER JOIN batches AS b ON b.batch_sk = c.batch_sk
    GROUP BY 1
),

cat AS (
    SELECT b.intrum_id, MIN(LAST_DAY(f.collection_date)) AS cat_first, MAX(LAST_DAY(f.collection_date)) AS cat_last
    FROM dev.hackathon.fct_npl_case_collection AS f
    INNER JOIN batches AS b ON b.batch_sk = f.batch_sk
    INNER JOIN deals AS d ON d.intrum_id = b.intrum_id
    WHERE f.collection_date >= d.acquisition_date
        AND f.collection_date < DATE_TRUNC('month', CURRENT_DATE())
    GROUP BY 1
),

pam AS (
    SELECT b.intrum_id, MIN(s.period_end_date) AS pam_first, MAX(s.period_end_date) AS pam_last
    FROM dev.hackathon.fct_npl_portfolio_snapshot_monthly AS s
    INNER JOIN batches AS b ON b.batch_sk = s.batch_sk
    INNER JOIN deals AS d ON d.intrum_id = b.intrum_id
    WHERE s.gross_cash_recoveries_unlevelled <> 0
        AND s.period_end_date >= LAST_DAY(d.acquisition_date)
        AND s.period_end_date < DATE_TRUNC('month', CURRENT_DATE())
    GROUP BY 1
)

SELECT d.intrum_id, COALESCE(c.cases, 0) AS cases, cat.cat_first, cat.cat_last, pam.pam_first, pam.pam_last
FROM deals AS d
LEFT JOIN cases AS c ON c.intrum_id = d.intrum_id
LEFT JOIN cat ON cat.intrum_id = d.intrum_id
LEFT JOIN pam ON pam.intrum_id = d.intrum_id;
