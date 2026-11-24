-- Why each Swedish deal does or doesn't reconcile in the sandbox build, with its deal type and market.
-- Grain: one row per Intrum deal (639). Runs on the sandbox (connection dev); RESULTS.md and reasons_by_market.py read it.
-- Reconciles = CAT within 10% of PAM and CAT paying in at least 80% of PAM's months, as in
--   ../intrum_clarifications/queries/3_reconcile_hackathon_build.sql. A deal that fails from purchase is then judged
--   from Nov 2014 if bought before Oct 2014 (CAT's history starts then), otherwise from purchase again.
-- Deal type: forward flow if any batch is Intrum's 'Ongoing', otherwise one-off.
-- Market: the sector of Intrum's product on the batch (original_product_name). Same group names as
--   work/workshop/queries/deals_seen_by_market.sql, which buckets by seller from Atlas instead, so the two don't mix.
-- Measured 24 Nov 2026: 82 reconcile from purchase; reasons match RESULTS.md's table.

SET cat_start = '2014-11-01';

WITH

batches AS (
    SELECT
        batch_sk,
        servicer_parent_portfolio_bk AS intrum_id,
        legacy_capex_date,
        deal_type,
        CASE original_product_name
            WHEN 'Finance' THEN 'FS'
            WHEN 'Bank Loan' THEN 'FS'
            WHEN 'Credit Card' THEN 'FS'
            WHEN 'Telecom' THEN 'Non-FS'
            WHEN 'Fixed Telephone' THEN 'Non-FS'
            WHEN 'Utility' THEN 'Non-FS'
            WHEN 'Mail Order' THEN 'Non-FS'
            WHEN 'Retail sale' THEN 'Non-FS'
            -- Other, Real Estate, Published, Transport, Insurance and empty: no sector to give.
            ELSE 'Unknown'
        END AS sector
    FROM dev.hackathon.dim_npl_batch
    WHERE country_id = 'SE'
        AND servicer_name = 'intrum'
),

deals AS (
    SELECT
        intrum_id,
        MIN(legacy_capex_date) AS acquisition_date,
        IFF(COUNT_IF(deal_type = 'Ongoing') > 0, 'forward flow', 'one-off') AS deal_type,
        -- A deal whose batches disagree on sector has no single market.
        IFF(COUNT(DISTINCT sector) = 1, MAX(sector), 'Unknown') AS sector
    FROM batches
    GROUP BY 1
),

cases AS (
    SELECT
        b.intrum_id,
        COUNT(DISTINCT c.case_bk) AS cases
    FROM dev.hackathon.dim_npl_case AS c
    INNER JOIN batches AS b
        ON b.batch_sk = c.batch_sk
    GROUP BY 1
),

-- The current month is not complete yet, so it is left out of both sides.
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
        AND p.period_end_date < DATE_TRUNC(MONTH, CURRENT_DATE())
    GROUP BY 1, 2
),

-- Also drops placeholder dates far in the future (2099-12-30 seen in the build).
cat_month AS (
    SELECT
        b.intrum_id,
        LAST_DAY(f.collection_date) AS month_end,
        SUM(f.amount) AS cat
    FROM dev.hackathon.fct_npl_case_collection AS f
    INNER JOIN batches AS b
        ON b.batch_sk = f.batch_sk
    INNER JOIN deals AS d
        ON d.intrum_id = b.intrum_id
    WHERE f.collection_date >= d.acquisition_date
        AND NOT f.is_before_acquisition
        AND f.collection_date < DATE_TRUNC(MONTH, CURRENT_DATE())
    GROUP BY 1, 2
),

-- Both sides end at the deal's last PAM month.
compared_month AS (
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

-- Each deal measured twice: from purchase, and from Nov 2014, CAT's first full month in Sweden.
measured AS (
    SELECT
        intrum_id,
        SUM(cat) / NULLIF(SUM(pam), 0) AS cat_vs_pam,
        COUNT_IF(pam > 0 AND cat > 0) / NULLIF(COUNT_IF(pam > 0), 0) AS months_share,
        SUM(IFF(month_end >= LAST_DAY($cat_start::DATE), cat, 0))
            / NULLIF(SUM(IFF(month_end >= LAST_DAY($cat_start::DATE), pam, 0)), 0) AS cat_vs_pam_from_nov_2014,
        COUNT_IF(month_end >= LAST_DAY($cat_start::DATE) AND pam > 0 AND cat > 0)
            / NULLIF(COUNT_IF(month_end >= LAST_DAY($cat_start::DATE) AND pam > 0), 0) AS months_share_from_nov_2014,
        SUM(cat) AS cat_total,
        SUM(pam) AS pam_total
    FROM compared_month
    GROUP BY 1
),

classified AS (
    SELECT
        d.intrum_id,
        d.acquisition_date,
        d.deal_type,
        d.sector,
        COALESCE(c.cases, 0) AS cases,
        m.cat_vs_pam,
        m.months_share,
        COALESCE(ABS(m.cat_vs_pam - 1) <= 0.1 AND m.months_share >= 0.8, FALSE) AS reconciles,
        -- A deal bought before CAT's history starts is judged from Nov 2014; the rest from purchase.
        d.acquisition_date < '2014-10-01' AS bought_before_cat,
        IFF(bought_before_cat, m.cat_vs_pam_from_nov_2014, m.cat_vs_pam) AS window_cat_vs_pam,
        IFF(bought_before_cat, m.months_share_from_nov_2014, m.months_share) AS window_months_share,
        COALESCE(ABS(window_cat_vs_pam - 1) <= 0.1 AND window_months_share >= 0.8, FALSE) AS reconciles_in_window,
        m.cat_total,
        m.pam_total
    FROM deals AS d
    LEFT JOIN cases AS c
        ON c.intrum_id = d.intrum_id
    LEFT JOIN measured AS m
        ON m.intrum_id = d.intrum_id
)

SELECT
    intrum_id,
    acquisition_date,
    deal_type,
    sector,
    cases,
    ROUND(cat_vs_pam * 100, 5) AS cat_vs_pam_pct,
    ROUND(months_share * 100, 5) AS months_share_pct,
    reconciles,
    -- Checked in this order; a deal takes the first reason that applies.
    CASE
        WHEN reconciles THEN 'Reconcile from purchase'
        WHEN cases = 0 THEN 'No cases in CAT (bought 2001-2010)'
        WHEN COALESCE(cat_total, 0) = 0 THEN 'No CAT payments, though the deal has cases'
        WHEN window_cat_vs_pam IS NULL THEN 'No PAM in the window'
        WHEN window_cat_vs_pam > 1.1 THEN 'CAT above 110%'
        WHEN ABS(window_cat_vs_pam - 1) <= 0.1 AND NOT reconciles_in_window
            THEN 'Within 10%, but CAT missing some months'
        WHEN bought_before_cat AND reconciles_in_window THEN 'Bought before Oct 2014; matches PAM from Nov 2014 on'
        WHEN bought_before_cat THEN 'Bought before Oct 2014; still below 90% from Nov 2014'
        ELSE 'Bought after Oct 2014; CAT below 90%'
    END AS reason
FROM classified
ORDER BY intrum_id;
