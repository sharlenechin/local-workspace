-- Post-registration data in PROD NPL_COMMON, per deal: what is filled, and whether the
-- case-level collections (from CAT) reconcile with the portfolio ones (from PAM).
-- GRAIN  one row per deal, keyed VEHICLE-ID as in deals_we_own.sql. Measured 2026-11-03.
-- RUN    mise run sql -- work/workshop/queries/post_registration_quality.sql
-- SOURCE PROD NPL_COMMON only. Every *_fill column is a share (0-1) of the deal's cases, or
--        of its batches / collection rows / PAM months where the column lives there.
-- DQ     FCT_CASE_COLLECTION holds 841 rows dated after today, out to 4570-07-07; they are
--        bounded out below. Its history also starts where each case's first SCD version
--        does (a CAT migration date, 2014-10-10 for the oldest books), so old books
--        reconcile low by construction. That is a dbt finding, reported, not fixed here.
WITH
    batch AS (

        SELECT
            b.batch_sk,
            -- Same id rule as deals_we_own.sql: Heimdall under Intrum's id, the rest Atlas.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) || '-' || IFF(
                COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
                b.servicer_parent_portfolio_bk,
                SUBSTR(p.portfolio_bk, 5, 7)
            ) AS deal_id,
            b.legal_seller_name,
            b.deal_type,
            b.servicer_name,
            b.legacy_capex_date,
            b.legacy_capex_amount,
            b.legacy_case_count,
            p.price_gross
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
),

-- Each case's latest month-end in the snapshot: its deal, product, currency, country and
-- forbearance as last reported. MAX_BY keeps it to one pass over 1.5bn rows.
    case_latest AS (

        SELECT
            s.case_id,
            MAX_BY(s.batch_sk, s.date_day) AS batch_sk,
            MAX_BY(NULLIF(s.product_sk, '-1'), s.date_day) AS product_sk,
            MAX_BY(NULLIF(s.segment_sk, '-1'), s.date_day) AS segment_sk,
            MAX_BY(s.currency_id, s.date_day) AS currency_id,
            MAX_BY(s.country_id, s.date_day) AS country_id,
            MAX_BY(s.forbearance_flag, s.date_day) AS forbearance_flag,
            MAX_BY(s.outstanding_total, s.date_day) AS outstanding_total
        FROM prod.npl_common.fct_case_snapshot_daily AS s
        GROUP BY 1
),

-- A case's current borrower attributes; "filled" if any of its borrowers has the value.
    case_borrower AS (

        SELECT
            case_id,
            COUNT(*) AS borrowers,
            MAX(gender) AS gender,
            MAX(legal_eba_type) AS legal_eba_type,
            MAX(credit_rating) AS credit_rating
        FROM prod.npl_common.dim_borrower
        WHERE is_current
        GROUP BY 1
),

    case_fill AS (

        SELECT
            b.deal_id,
            COUNT(*) AS npl_cases,
            AVG(IFF(c.origination_date IS NOT NULL, 1, 0)) AS origination_date_fill,
            -- The raw dates, not dbt's derived_* back-fills, which are filled by design.
            AVG(IFF(c.default_date IS NOT NULL, 1, 0)) AS default_date_fill,
            AVG(IFF(c.registration_date IS NOT NULL, 1, 0)) AS registration_date_fill,
            AVG(IFF(c.original_principal IS NOT NULL, 1, 0)) AS original_principal_fill,
            AVG(IFF(c.status_code IS NOT NULL, 1, 0)) AS status_code_fill,
            AVG(IFF(c.backstop_date IS NOT NULL, 1, 0)) AS backstop_date_fill,
            AVG(IFF(c.secured_flag IS NOT NULL, 1, 0)) AS secured_flag_fill,
            AVG(IFF(l.product_sk IS NOT NULL, 1, 0)) AS product_fill,
            AVG(IFF(l.segment_sk IS NOT NULL, 1, 0)) AS segment_fill,
            AVG(IFF(l.currency_id IS NOT NULL, 1, 0)) AS currency_fill,
            AVG(IFF(l.country_id IS NOT NULL, 1, 0)) AS country_fill,
            AVG(IFF(l.forbearance_flag IS NOT NULL, 1, 0)) AS forbearance_fill,
            AVG(IFF(r.borrowers IS NOT NULL, 1, 0)) AS borrower_fill,
            AVG(IFF(r.gender IS NOT NULL, 1, 0)) AS gender_fill,
            AVG(IFF(r.legal_eba_type IS NOT NULL, 1, 0)) AS legal_type_fill,
            AVG(IFF(r.credit_rating IS NOT NULL, 1, 0)) AS credit_rating_fill
        FROM case_latest AS l
        INNER JOIN batch AS b
            ON b.batch_sk = l.batch_sk
        LEFT JOIN prod.npl_common.dim_case AS c
            ON c.case_id = l.case_id
            AND c.is_current_flag
        LEFT JOIN case_borrower AS r
            ON r.case_id = l.case_id
        WHERE b.deal_id IS NOT NULL
        GROUP BY 1
),

    batch_fill AS (

        SELECT
            deal_id,
            AVG(IFF(legal_seller_name IS NOT NULL, 1, 0)) AS seller_fill,
            AVG(IFF(deal_type IS NOT NULL, 1, 0)) AS deal_type_fill,
            AVG(IFF(servicer_name IS NOT NULL, 1, 0)) AS servicer_fill,
            AVG(IFF(legacy_capex_date IS NOT NULL, 1, 0)) AS legacy_capex_date_fill,
            AVG(IFF(legacy_capex_amount IS NOT NULL, 1, 0)) AS legacy_capex_amount_fill,
            AVG(IFF(legacy_case_count IS NOT NULL, 1, 0)) AS legacy_case_count_fill,
            AVG(IFF(price_gross IS NOT NULL, 1, 0)) AS price_fill,
            -- The window both feeds are compared over starts at the earliest capex.
            DATE_TRUNC('month', MIN(legacy_capex_date)) AS capex_month
        FROM batch
        WHERE deal_id IS NOT NULL
        GROUP BY 1
),

-- Case-level collections (CAT, cleaned by dbt), per deal and month.
    cat_month AS (

        SELECT
            b.deal_id,
            DATE_TRUNC('month', c.collection_date) AS month,
            SUM(c.amount) AS collected,
            COUNT(*) AS rows_all,
            COUNT_IF(c.amount IS NOT NULL AND c.collection_date IS NOT NULL) AS rows_filled
        FROM prod.npl_common.fct_case_collection AS c
        INNER JOIN batch AS b
            ON b.batch_sk = c.batch_sk
        -- DQ guard: 841 rows are dated in the future (to 4570), see the header.
        WHERE c.collection_date <= CURRENT_DATE
            OR c.collection_date IS NULL
        GROUP BY 1, 2
),

-- Portfolio-level collections (PAM, cleaned by dbt), per deal and month. Actual months
-- only: dbt keeps months before each file's extract month and drops the forecast ones
-- (int_npl_portfolio_monthly_intrum.sql). One row per batch and month (verified unique).
    pam_month AS (

        SELECT
            b.deal_id,
            DATE_TRUNC('month', p.period_end_date) AS month,
            SUM(p.gross_cash_recoveries) AS collected,
            COUNT(*) AS rows_all,
            COUNT_IF(p.gross_cash_recoveries IS NOT NULL) AS rows_filled
        FROM prod.npl_common.fct_portfolio_snapshot_monthly AS p
        INNER JOIN batch AS b
            ON b.batch_sk = p.batch_sk
        GROUP BY 1, 2
),

    cat_span AS (

        SELECT
            deal_id,
            MIN(month) AS first_month,
            MAX(month) AS last_month,
            SUM(rows_filled) / NULLIF(SUM(rows_all), 0) AS cat_collection_fill
        FROM cat_month
        GROUP BY 1
),

    pam_span AS (

        SELECT
            deal_id,
            MIN(month) AS first_month,
            MAX(month) AS last_month,
            SUM(rows_filled) / NULLIF(SUM(rows_all), 0) AS pam_collection_fill
        FROM pam_month
        GROUP BY 1
),

-- The months both feeds can speak for: from the later first month to the earlier last.
-- Whole histories would credit CAT with months PAM has not reported yet, and PAM with the
-- years before CAT's floor.
    window_per_deal AS (

        SELECT
            c.deal_id,
            GREATEST(c.first_month, p.first_month) AS window_start,
            LEAST(c.last_month, p.last_month) AS window_end
        FROM cat_span AS c
        INNER JOIN pam_span AS p
            ON p.deal_id = c.deal_id
),

    cat_in_window AS (

        SELECT
            c.deal_id,
            COUNT_IF(c.collected <> 0) AS cat_months,
            SUM(c.collected) AS cat_collected
        FROM cat_month AS c
        INNER JOIN window_per_deal AS w
            ON w.deal_id = c.deal_id
            AND c.month BETWEEN w.window_start AND w.window_end
        GROUP BY 1
),

    pam_in_window AS (

        SELECT
            p.deal_id,
            COUNT_IF(p.collected <> 0) AS pam_months,
            SUM(p.collected) AS pam_collected
        FROM pam_month AS p
        INNER JOIN window_per_deal AS w
            ON w.deal_id = p.deal_id
            AND p.month BETWEEN w.window_start AND w.window_end
        GROUP BY 1
)

SELECT
    bf.deal_id,
    cf.npl_cases,
    cf.* EXCLUDE (deal_id, npl_cases),
    bf.* EXCLUDE (deal_id, capex_month),
    cs.cat_collection_fill,
    ps.pam_collection_fill,
    w.window_start,
    w.window_end,
    ci.cat_months,
    pi.pam_months,
    ci.cat_collected,
    pi.pam_collected,
    ci.cat_months / NULLIF(pi.pam_months, 0) AS months_ratio_cat_to_pam,
    ci.cat_collected / NULLIF(pi.pam_collected, 0) AS collections_ratio_cat_to_pam,
    -- The reconciliation test: CAT has at least 80% of PAM's collecting months, and its
    -- collections are within 10% of PAM's, over the months both cover.
    COALESCE(
        months_ratio_cat_to_pam >= 0.8
        AND collections_ratio_cat_to_pam BETWEEN 0.9 AND 1.1,
        FALSE
    ) AS reconciliation_flag
FROM batch_fill AS bf
LEFT JOIN case_fill AS cf
    ON cf.deal_id = bf.deal_id
LEFT JOIN cat_span AS cs
    ON cs.deal_id = bf.deal_id
LEFT JOIN pam_span AS ps
    ON ps.deal_id = bf.deal_id
LEFT JOIN window_per_deal AS w
    ON w.deal_id = bf.deal_id
LEFT JOIN cat_in_window AS ci
    ON ci.deal_id = bf.deal_id
LEFT JOIN pam_in_window AS pi
    ON pi.deal_id = bf.deal_id
ORDER BY 1;
