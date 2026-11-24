-- SE20009 payments after registration: one row per payment for every loan we own, from the sandbox build.
-- The sandbox build (DEV.HACKATHON) has the two collection fixes prod does not have yet; run with connection dev.
-- Only payments from the first day of the loan's registration month with Intrum; earlier months are in payments_pre_registration.sql.
-- Same columns as payments_pre_registration.sql, so the two stack; deal_dataset.py does that.
-- The PAM check: the warehouse total within 10% of Intrum's report (PAM) and payments in at least 80% of PAM's months,
--   from purchase to PAM's last complete month; payments made before purchase are left out of the check only.
-- Measured 24 Nov 2026: 256,566 rows, SEK 280,663,029.73; 97.81675% of PAM, payments in 100% of PAM's months.

SET portfolio_id = 'SE20009';
SET max_total_deviation_pct = 10;
SET min_month_coverage_pct = 80;

WITH
deal_batch AS (
    SELECT
        b.batch_sk,
        b.batch_bk,
        b.legacy_capex_date,
        IFF(
            b.deal_source_bk = 'HEI' OR dl.deal_bk IS NULL,
            -- Heimdall books are named vehicle-Intrum id; other deals use their Atlas id.
            b.deal_source_bk || '-' || b.servicer_parent_portfolio_bk,
            dl.deal_bk
        ) AS deal_id
    FROM dev.hackathon.dim_npl_batch AS b
    -- Left join, so a batch with an unknown portfolio is not dropped.
    LEFT JOIN dev.hackathon.dim_npl_portfolio AS pf
        ON pf.portfolio_sk = b.portfolio_sk
    LEFT JOIN dev.hackathon.dim_npl_deal AS dl
        ON dl.deal_id = pf.deal_id
    WHERE b.servicer_parent_portfolio_bk = $portfolio_id
),

-- Every case in the deal, with its registration date.
deal_cases AS (
    SELECT
        case_bk,
        registration_date
    FROM dev.hackathon.dim_npl_case
    WHERE is_current_flag
        AND batch_sk IN (SELECT batch_sk FROM deal_batch)
),

-- No loan on this deal moved between Intrum's systems, so each case is its own loan.
case_to_loan AS (
    SELECT
        case_bk,
        case_bk AS model_id
    FROM deal_cases
),

-- When the loan first reached Intrum: the earliest of its cases' registration dates.
loan_registration AS (
    SELECT
        l.model_id,
        MIN(c.registration_date) AS registration_date
    FROM case_to_loan AS l
    INNER JOIN deal_cases AS c
        ON c.case_bk = l.case_bk
    GROUP BY l.model_id
),

-- No de-duplication: rows sharing a COLLECTION_BK are different payments.
payment_from_registration AS (
    SELECT
        l.model_id,
        f.collection_date AS payment_date,
        f.amount,
        f.currency_id AS currency,
        c.case_bk AS paid_on_case,
        b.batch_bk,
        b.deal_id,
        f.collection_bk,
        r.registration_date
    FROM dev.hackathon.fct_npl_case_collection AS f
    INNER JOIN deal_batch AS b
        ON b.batch_sk = f.batch_sk
    INNER JOIN dev.hackathon.dim_npl_case AS c
        ON c.case_sk = f.case_sk
    INNER JOIN case_to_loan AS l
        ON l.case_bk = c.case_bk
    INNER JOIN loan_registration AS r
        ON r.model_id = l.model_id
    -- From the first day of the registration month; earlier months use the tape's payments.
    WHERE f.collection_date >= DATE_TRUNC(MONTH, r.registration_date)
),

acquisition AS (
    SELECT MIN(legacy_capex_date) AS acquisition_date
    FROM deal_batch
),

-- PAM as Intrum reports the batch; the current month is not complete yet, so it is left out.
pam_month AS (
    SELECT
        p.period_end_date AS month_end,
        SUM(p.gross_cash_recoveries_unlevelled) AS pam
    FROM dev.hackathon.fct_npl_portfolio_snapshot_monthly AS p
    INNER JOIN deal_batch AS b
        ON b.batch_sk = p.batch_sk
    CROSS JOIN acquisition AS q
    WHERE p.period_end_date >= LAST_DAY(q.acquisition_date)
        AND p.period_end_date < DATE_TRUNC(MONTH, CURRENT_DATE())
    GROUP BY 1
),

-- Also drops placeholder dates far in the future (2099-12-30 seen elsewhere in the build).
cat_month AS (
    SELECT
        LAST_DAY(f.collection_date) AS month_end,
        SUM(f.amount) AS cat
    FROM dev.hackathon.fct_npl_case_collection AS f
    INNER JOIN deal_batch AS b
        ON b.batch_sk = f.batch_sk
    CROSS JOIN acquisition AS q
    WHERE f.collection_date >= q.acquisition_date
        AND NOT f.is_before_acquisition
        AND f.collection_date < DATE_TRUNC(MONTH, CURRENT_DATE())
    GROUP BY 1
),

-- Both sides end at PAM's last month, so a month PAM has not reported yet is not counted.
compared_month AS (
    SELECT
        p.month_end,
        p.pam,
        COALESCE(c.cat, 0) AS cat
    FROM pam_month AS p
    LEFT JOIN cat_month AS c
        ON c.month_end = p.month_end
),

pam_reconciliation AS (
    SELECT
        -- Warehouse total above (+) or below (-) PAM's, in %, and the share of PAM's paying months it also has.
        (SUM(cat) / NULLIF(SUM(pam), 0) - 1) * 100 AS collection_total_pct,
        COUNT_IF(pam > 0 AND cat > 0) / NULLIF(COUNT_IF(pam > 0), 0) * 100 AS month_coverage_pct,
        MIN(month_end) AS compared_from,
        MAX(month_end) AS compared_to
    FROM compared_month
)

SELECT
    -- Identifiers and the month; no prefix
    y.model_id,
    SPLIT_PART(y.model_id, '-', 1) AS instance,
    y.deal_id,
    $portfolio_id AS intrum_id,
    LAST_DAY(y.payment_date) AS month_end,
    DATEDIFF(MONTH, y.registration_date, y.payment_date) AS months_since_registration,

    -- The payment, and which source it comes from
    'warehouse' AS payment_source,
    y.payment_date,
    y.amount AS payment_amount,
    y.currency AS payment_currency,
    y.registration_date AS warehouse_registration_date,

    -- Source details; empty for the other source
    NULL AS asset_index_case_id,
    NULL AS asset_index_match_method,
    y.paid_on_case AS warehouse_paid_on_case,
    y.batch_bk AS warehouse_batch_bk,
    y.collection_bk AS warehouse_collection_bk,

    -- warehouse_vs_pam_: deal-wide check of the sandbox build's payments against Intrum's monthly report
    ROUND(p.collection_total_pct, 5) AS warehouse_vs_pam_collection_total_pct,
    ROUND(p.month_coverage_pct, 5) AS warehouse_vs_pam_month_coverage_pct,
    p.compared_from AS warehouse_vs_pam_compared_from,
    p.compared_to AS warehouse_vs_pam_compared_to,
    COALESCE(
        ABS(p.collection_total_pct) <= $max_total_deviation_pct
            AND p.month_coverage_pct >= $min_month_coverage_pct,
        FALSE
    ) AS warehouse_reconciles_with_pam
FROM payment_from_registration AS y
CROSS JOIN pam_reconciliation AS p
ORDER BY y.model_id, y.payment_date;
