-- SE17039 (SevenDay, HEI) payments: one row per FCT_CASE_COLLECTION row, for every case we own.
--
-- Column names say where each value comes from, as in accounts.sql: warehouse_ is Brocc's data
-- warehouse, warehouse_vs_pam_ compares it with Intrum's own monthly report, and identifiers and
-- the month have no prefix.
--
-- The base is the same as accounts.sql: cases whose month-end balance row carries an SE17039
-- batch (2,702), not the asset index. Payments are matched on the case's hashed CASE_ID, so a
-- version change never drops one. All rows are on instance 2080 (see below).
--
-- ⚠ This source is INCOMPLETE on this deal. Against Intrum's own benchmark payments file
-- (SE26043_SE26044_NOBA_BMK_payments_v2.csv), post-registration, to 2026-05-31:
--   instance 1062: warehouse SEK 0.00 of 45,259,942.34 (0%). Every 1062 payment is dropped by
--                  the BOOKING_IND filter in int_npl_case_collection_intrum.
--   instance 2080: warehouse SEK 64,670,481.16 of 87,751,977.72 (73.697%). SEK 24.15m of
--                  benchmark payments on 362 cases fall before the case's first DIM_CASE version
--                  and are dropped by the case-history inner join in int_npl_case_collection_conformed.
-- Both are dbt bugs to report, not to filter around here. accounts.sql flags each case's coverage.
--
-- RECONCILIATION against PAM, Intrum's own monthly batch report, is carried on every row as a
-- deal-level verdict. Both sides are cut the same way so they can be divided:
--   · post-acquisition only, because PAM counts only cash collected since the book was bought
--     (LEGACY_CAPEX_DATE, which is accurate to the month, not the day);
--   · the whole deal on both sides, by batch, not only the asset-index cases, so the test is of
--     the source and not of how much of the deal the tape reaches;
--   · PAM from its newest extract, actual months only. PMODE_NAME = 'Real' still carries future
--     months, so the extract's own month is the cut, as in work/project-noba/reconciliation.sql;
--   · months up to the earlier of the two sources' last month.
-- warehouse_reconciles_with_pam is TRUE when the total is less than 10% from PAM's AND the warehouse has cash
-- in more than 80% of the months in which PAM has cash.
-- Measured 2026-11-20, PAM extract 2026-11-12, months 2018-12 to 2026-10: total -50.909%,
-- month coverage 100%, so FALSE. Coverage is deal-wide, so instance 2080's cash fills every
-- month and it cannot see that instance 1062 is missing entirely; the deviation does.
-- 36,047 rows on 785 cases, SEK 68,638,546.63.

SET portfolio_id = 'SE17039';
SET max_total_deviation_pct = 10;
SET min_month_coverage_pct = 80;

WITH

-- Prod only; see accounts.sql. NF61585 is brocc-prod.
prod_guard AS (
    SELECT IFF(
        CURRENT_ACCOUNT() = 'NF61585',
        'brocc-prod',
        TO_NUMBER('This query reads prod only: run it on the prod connection')::VARCHAR
    ) AS snowflake_account
),

-- One row per owned case, from its latest month-end row; see accounts.sql.
deal_case AS (
    SELECT
        c.case_bk AS model_id,
        s.case_id AS case_id_hashed
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = s.batch_sk
    INNER JOIN prod.npl_common.dim_case AS c
        ON c.case_sk = s.case_sk
    WHERE b.servicer_parent_portfolio_bk = $portfolio_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.case_bk ORDER BY s.date_day DESC) = 1
),

registration AS (
    SELECT
        case_bk AS model_id,
        registration_date
    FROM prod.npl_common.dim_case
    WHERE is_current_flag
        AND case_bk IN (SELECT model_id FROM deal_case)
),

deal_batch AS (
    SELECT
        batch_sk,
        legacy_capex_date
    FROM prod.npl_common.dim_batch
    WHERE servicer_parent_portfolio_bk = $portfolio_id
),

acquisition AS (
    SELECT MIN(legacy_capex_date) AS acquisition_date
    FROM deal_batch
),

pam_extract AS (
    SELECT
        MAX(_file_path) AS file_path,
        TO_DATE(REGEXP_SUBSTR(MAX(_file_path), 'pam\\.pam\\.pam\\.(\\d{8})', 1, 1, 'e'), 'YYYYMMDD')
            AS extracted_on
    FROM raw.hyperion_intrum_pam.pam
    WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

pam_monthly AS (
    SELECT
        DATE_TRUNC(MONTH, p.period_start_date::DATE) AS collection_month,
        SUM(p.colltotal) AS pam_collected
    FROM raw.hyperion_intrum_pam.pam AS p
    CROSS JOIN pam_extract AS e
    CROSS JOIN acquisition AS q
    WHERE p._file_path = e.file_path
        AND p.pmode_name = 'Real'
        AND COALESCE(p.is_ownership_change, 0) = 0
        AND p.portfolioid = $portfolio_id
        AND p.period_start_date::DATE < DATE_TRUNC(MONTH, e.extracted_on)
        AND p.period_start_date::DATE >= DATE_TRUNC(MONTH, q.acquisition_date)
    GROUP BY DATE_TRUNC(MONTH, p.period_start_date::DATE)
),

warehouse_monthly AS (
    SELECT
        DATE_TRUNC(MONTH, f.collection_date) AS collection_month,
        SUM(f.amount) AS warehouse_collected
    FROM prod.npl_common.fct_case_collection AS f
    INNER JOIN deal_batch AS b
        ON b.batch_sk = f.batch_sk
    CROSS JOIN acquisition AS q
    WHERE f.collection_date >= DATE_TRUNC(MONTH, q.acquisition_date)
    GROUP BY DATE_TRUNC(MONTH, f.collection_date)
),

-- Both sides stop at whichever source ends first, so neither is short only for being older.
compared_month AS (
    SELECT
        p.collection_month,
        p.pam_collected,
        COALESCE(w.warehouse_collected, 0) AS warehouse_collected
    FROM pam_monthly AS p
    LEFT JOIN warehouse_monthly AS w
        ON w.collection_month = p.collection_month
    WHERE p.collection_month <= (SELECT MAX(collection_month) FROM warehouse_monthly)
),

pam_reconciliation AS (
    SELECT
        SUM(pam_collected) AS pam_collected,
        SUM(warehouse_collected) AS warehouse_collected,
        -- Percentages: the warehouse's total above (+) or below (-) PAM's, and the share of PAM's
        -- cash months in which the warehouse has cash too.
        (SUM(warehouse_collected) / NULLIF(SUM(pam_collected), 0) - 1) * 100
            AS collection_reconciliation_total_pct,
        COUNT_IF(pam_collected <> 0 AND warehouse_collected <> 0)
            / NULLIF(COUNT_IF(pam_collected <> 0), 0) * 100 AS collection_month_coverage_pct,
        MIN(collection_month) AS compared_from,
        MAX(collection_month) AS compared_to
    FROM compared_month
)

-- No dedupe: COLLECTION_BK is not a row key, and rows sharing one are different payments.
SELECT
    d.model_id,
    SPLIT_PART(d.model_id, '-', 1) AS instance,
    -- Heimdall (HEI) is one Atlas deal, HEI-SE25001, over 2,612 Intrum books, so its books are
    -- named vehicle-Intrum id. Every other vehicle has its own Atlas deal, whose DEAL_BK already
    -- reads vehicle-Atlas id (LOK-SE25008 is the book Intrum calls SE25018).
    IFF(
        b.deal_source_bk = 'HEI' OR dl.deal_bk IS NULL,
        b.deal_source_bk || '-' || b.servicer_parent_portfolio_bk,
        dl.deal_bk
    ) AS deal_id,
    b.servicer_parent_portfolio_bk AS intrum_id,
    LAST_DAY(f.collection_date) AS month_end,
    DATEDIFF(MONTH, r.registration_date, f.collection_date) AS months_since_registration,

    -- warehouse_: the payment as the warehouse records it
    b.batch_bk AS warehouse_batch_bk,
    f.collection_bk AS warehouse_collection_bk,
    f.collection_date AS warehouse_collection_date,
    r.registration_date AS warehouse_registration_date,
    f.amount AS warehouse_amount,
    f.currency_id AS warehouse_currency,

    -- warehouse_vs_pam_: the warehouse's collections checked against Intrum's own monthly report,
    -- for the whole deal; the same on every row
    ROUND(p.collection_reconciliation_total_pct, 5) AS warehouse_vs_pam_collection_total_pct,
    ROUND(p.collection_month_coverage_pct, 5) AS warehouse_vs_pam_month_coverage_pct,
    p.compared_from AS warehouse_vs_pam_compared_from,
    p.compared_to AS warehouse_vs_pam_compared_to,
    COALESCE(
        ABS(p.collection_reconciliation_total_pct) < $max_total_deviation_pct
            AND p.collection_month_coverage_pct > $min_month_coverage_pct,
        FALSE
    ) AS warehouse_reconciles_with_pam
FROM deal_case AS d
CROSS JOIN prod_guard AS g
CROSS JOIN pam_reconciliation AS p
INNER JOIN prod.npl_common.fct_case_collection AS f
    ON f.case_id = d.case_id_hashed
LEFT JOIN registration AS r
    ON r.model_id = d.model_id
LEFT JOIN prod.npl_common.dim_batch AS b
    ON b.batch_sk = f.batch_sk
-- LEFT: the Unknown portfolio sentinel is not in DIM_PORTFOLIO and would drop the row.
LEFT JOIN prod.npl_common.dim_portfolio AS pf
    ON pf.portfolio_sk = b.portfolio_sk
LEFT JOIN prod.npl_common.dim_deal AS dl
    ON dl.deal_id = pf.deal_id
-- Referencing the guard is what makes it run; it errors off prod and is always true on it.
WHERE g.snowflake_account = 'brocc-prod'
ORDER BY d.model_id, f.collection_date;
