-- Does a deal reconcile if we only ask it to reconcile its FIRST FIVE YEARS?
-- GRAIN  one row per deal, keyed VEHICLE-ID as in post_registration_quality.sql.
-- WHY    the headline gate (1,047 of 2,674 deals, 39.2%, measured 2026-11-04) compares
--        every month both feeds cover — a median of 8.4 years and up to 12.3. Alex asked
--        whether that length is what makes the number low. This re-runs the identical
--        test over a 60-month window and over the most recent 60 months, so the three
--        can be read side by side.
-- RUN    mise run sql -- work/workshop/queries/reconciliation_five_year.sql
-- SOURCE PROD NPL_COMMON only. Same test as post_registration_quality.sql: CAT has at
--        least 80% of PAM's collecting months AND lands within +/-10% of PAM on cash.
-- DQ     FCT_CASE_COLLECTION holds 841 rows dated after today, out to the year 4570;
--        they are bounded out below, exactly as the headline query does.
-- DQ     CAT history starts at each case's first SCD version (a CAT migration date,
--        2014-10-10 on the oldest books), so books bought before then reconcile low by
--        construction. Capping the window does not cure that — it is the same floor.
WITH
    batch AS (

        SELECT
            b.batch_sk,
            -- Same id rule as deals_we_own.sql: Heimdall under Intrum's id, the rest Atlas.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) || '-' || IFF(
                COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
                b.servicer_parent_portfolio_bk,
                SUBSTR(p.portfolio_bk, 5, 7)
            ) AS deal_id
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
),

    cat_month AS (

        SELECT
            b.deal_id,
            DATE_TRUNC('month', c.collection_date) AS month,
            SUM(c.amount) AS collected
        FROM prod.npl_common.fct_case_collection AS c
        INNER JOIN batch AS b
            ON b.batch_sk = c.batch_sk
        -- DQ guard: the future-dated rows named in the header.
        WHERE c.collection_date <= CURRENT_DATE
        GROUP BY 1, 2
),

-- dbt already drops PAM's forecast months, keeping actuals only, so no cut is needed here.
    pam_month AS (

        SELECT
            b.deal_id,
            DATE_TRUNC('month', p.period_end_date) AS month,
            SUM(p.gross_cash_recoveries) AS collected
        FROM prod.npl_common.fct_portfolio_snapshot_monthly AS p
        INNER JOIN batch AS b
            ON b.batch_sk = p.batch_sk
        GROUP BY 1, 2
),

-- The months both feeds can speak for, then the two five-year cuts of it.
    windows AS (

        SELECT
            c.deal_id,
            GREATEST(MIN(c.month), MIN(p.month)) AS window_start,
            LEAST(MAX(c.month), MAX(p.month)) AS window_end
        FROM cat_month AS c
        INNER JOIN pam_month AS p
            ON p.deal_id = c.deal_id
        GROUP BY 1
),

    cuts AS (

        SELECT
            deal_id,
            window_start,
            window_end,
            DATEDIFF('month', window_start, window_end) + 1 AS window_months,
            -- First five years: the 60 months from the start of the overlap.
            LEAST(window_end, DATEADD('month', 59, window_start)) AS first5_end,
            -- Most recent five years: the 60 months ending at the overlap's last month.
            GREATEST(window_start, DATEADD('month', -59, window_end)) AS last5_start
        FROM windows
),

    scored AS (

        SELECT
            w.deal_id,
            w.window_months,
            COUNT_IF(c.collected <> 0 AND c.month BETWEEN w.window_start AND w.window_end) AS cat_m_all,
            COUNT_IF(p.collected <> 0 AND p.month BETWEEN w.window_start AND w.window_end) AS pam_m_all,
            SUM(IFF(c.month BETWEEN w.window_start AND w.window_end, c.collected, 0)) AS cat_c_all,
            SUM(IFF(p.month BETWEEN w.window_start AND w.window_end, p.collected, 0)) AS pam_c_all,
            COUNT_IF(c.collected <> 0 AND c.month BETWEEN w.window_start AND w.first5_end) AS cat_m_f5,
            COUNT_IF(p.collected <> 0 AND p.month BETWEEN w.window_start AND w.first5_end) AS pam_m_f5,
            SUM(IFF(c.month BETWEEN w.window_start AND w.first5_end, c.collected, 0)) AS cat_c_f5,
            SUM(IFF(p.month BETWEEN w.window_start AND w.first5_end, p.collected, 0)) AS pam_c_f5,
            COUNT_IF(c.collected <> 0 AND c.month BETWEEN w.last5_start AND w.window_end) AS cat_m_l5,
            COUNT_IF(p.collected <> 0 AND p.month BETWEEN w.last5_start AND w.window_end) AS pam_m_l5,
            SUM(IFF(c.month BETWEEN w.last5_start AND w.window_end, c.collected, 0)) AS cat_c_l5,
            SUM(IFF(p.month BETWEEN w.last5_start AND w.window_end, p.collected, 0)) AS pam_c_l5
        FROM cuts AS w
        -- FULL OUTER so a month present in one feed and absent from the other still counts
        -- against the months ratio, which is what makes the 80% test meaningful.
        LEFT JOIN cat_month AS c
            ON c.deal_id = w.deal_id
        FULL OUTER JOIN pam_month AS p
            ON p.deal_id = w.deal_id
            AND p.month = c.month
        GROUP BY 1, 2
)

SELECT
    deal_id,
    window_months,
    COALESCE(cat_m_all / NULLIF(pam_m_all, 0) >= 0.8
        AND cat_c_all / NULLIF(pam_c_all, 0) BETWEEN 0.9 AND 1.1, FALSE) AS reconciles_all,
    COALESCE(cat_m_f5 / NULLIF(pam_m_f5, 0) >= 0.8
        AND cat_c_f5 / NULLIF(pam_c_f5, 0) BETWEEN 0.9 AND 1.1, FALSE) AS reconciles_first5,
    COALESCE(cat_m_l5 / NULLIF(pam_m_l5, 0) >= 0.8
        AND cat_c_l5 / NULLIF(pam_c_l5, 0) BETWEEN 0.9 AND 1.1, FALSE) AS reconciles_last5
FROM scored
ORDER BY 1;
