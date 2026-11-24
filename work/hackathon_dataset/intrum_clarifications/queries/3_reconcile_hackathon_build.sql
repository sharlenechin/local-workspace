-- Do the hackathon-test fixes make Swedish deals reconcile? CAT (fct_npl_case_collection) vs PAM
-- (fct_npl_portfolio_snapshot_monthly), both from the sandbox build in DEV.HACKATHON.
-- GRAIN   one row per Intrum deal (servicer_parent_portfolio_bk, e.g. SE16025).
-- RULE    same as ../README.md: from the acquisition month, CAT has payments in at least 80% of the months
--         PAM has collections, and CAT's total is within 10% of PAM's.
-- NOTE    PAM side is gross_cash_recoveries_unlevelled (collections + sales proceeds, as Intrum reports the
--         batch), not COLLTOTAL; deals with sales proceeds will read slightly low on CAT.
-- RUN     mise run sql -- work/hackathon_dataset/intrum_clarifications/queries/3_reconcile_hackathon_build.sql \
--             --connection dev --warehouse DEV_WH --lower

WITH batches AS (

    SELECT
        b.batch_sk,
        b.servicer_parent_portfolio_bk AS intrum_id,
        b.legacy_capex_date,
        d.deal_bk
    FROM dev.hackathon.dim_npl_batch AS b
    LEFT JOIN dev.hackathon.dim_npl_portfolio AS p
        ON p.portfolio_sk = b.portfolio_sk
    LEFT JOIN dev.hackathon.dim_npl_deal AS d
        ON d.deal_id = p.deal_id
    WHERE b.country_id = 'SE'
        AND b.servicer_name = 'intrum'
),

deals AS (

    SELECT
        intrum_id,
        -- Atlas holds all 636 Heimdall books as one deal (HEI-SE25001), so a Heimdall book is named
        -- HEI-<intrum id>; each Lokki book is its own Atlas deal (LOK-SE25008 = Intrum SE25018)
        IFF(MAX(deal_bk) LIKE 'HEI-%', 'HEI-' || intrum_id, MAX(deal_bk)) AS deal_bk,
        MIN(legacy_capex_date) AS acquisition_date
    FROM batches
    GROUP BY 1
),

-- PAM by deal and month; the current month is incomplete, so it is left out
pam_month AS (

    SELECT
        b.intrum_id,
        p.period_end_date AS month_end,
        SUM(p.gross_cash_recoveries_unlevelled) AS pam
    FROM dev.hackathon.fct_npl_portfolio_snapshot_monthly AS p
    INNER JOIN batches AS b
        ON b.batch_sk = p.batch_sk
    INNER JOIN deals AS d
        ON d.intrum_id = b.intrum_id
    WHERE p.period_end_date >= LAST_DAY(d.acquisition_date)
        AND p.period_end_date < DATE_TRUNC('month', CURRENT_DATE())
    GROUP BY 1, 2
),

-- CAT by deal and month, payments after acquisition only
cat_month AS (

    SELECT
        b.intrum_id,
        LAST_DAY(c.collection_date) AS month_end,
        SUM(c.amount) AS cat
    FROM dev.hackathon.fct_npl_case_collection AS c
    INNER JOIN batches AS b
        ON b.batch_sk = c.batch_sk
    INNER JOIN deals AS d
        ON d.intrum_id = b.intrum_id
    WHERE c.collection_date >= d.acquisition_date
        AND NOT c.is_before_acquisition
        -- also drops placeholder dates (2099-12-30 seen on 2026-11-23); the reply reports them separately
        AND c.collection_date < DATE_TRUNC('month', CURRENT_DATE())
    GROUP BY 1, 2
),

-- both sides end at the deal's last PAM month, so a CAT month PAM has not reported yet is not counted
months AS (

    SELECT
        p.intrum_id,
        p.month_end,
        p.pam,
        COALESCE(c.cat, 0) AS cat
    FROM pam_month AS p
    LEFT JOIN cat_month AS c
        ON c.intrum_id = p.intrum_id
        AND c.month_end = p.month_end
),

per_deal AS (

    SELECT
        intrum_id,
        SUM(cat) AS cat_total,
        SUM(pam) AS pam_total,
        COUNT_IF(pam > 0) AS pam_months,
        COUNT_IF(pam > 0 AND cat > 0) AS months_with_both
    FROM months
    GROUP BY 1
)

SELECT
    d.deal_bk,
    d.intrum_id,
    d.acquisition_date,
    ROUND(p.cat_total, 2) AS cat_total,
    ROUND(p.pam_total, 2) AS pam_total,
    ROUND(p.cat_total / NULLIF(p.pam_total, 0), 5) AS cat_vs_pam,
    ROUND(p.months_with_both / NULLIF(p.pam_months, 0), 5) AS months_share,
    COALESCE(
        ABS(p.cat_total / NULLIF(p.pam_total, 0) - 1) <= 0.1
        AND p.months_with_both / NULLIF(p.pam_months, 0) >= 0.8,
        FALSE
    ) AS reconciles
FROM deals AS d
LEFT JOIN per_deal AS p
    ON p.intrum_id = d.intrum_id
ORDER BY reconciles DESC, cat_vs_pam DESC NULLS LAST;
