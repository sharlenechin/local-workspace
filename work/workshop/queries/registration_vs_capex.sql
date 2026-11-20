-- How far a case's registration date sits from the batch's prior-capex date.
-- GRAIN  one row per deal, keyed VEHICLE-ID as in deals_we_own.sql.
-- RUN    mise run sql -- work/workshop/queries/registration_vs_capex.sql
-- SOURCE PROD NPL_COMMON only: DIM_BATCH for the capex date, DIM_CASE for the
--        registration date, and the case snapshot for the case-to-batch link, which
--        DIM_CASE does not carry.
--
-- WHY THIS EXISTS. deals_we_own.sql takes a deal's registration date as the first case
-- registered ON OR AFTER the capex month, because the plain earliest date is often years
-- before the book was bought. That guard hides the thing being asked here: how close the
-- two dates actually are. This measures the gap without the guard.
--
-- SIGN. months_gap is registration minus capex, so a NEGATIVE number means the case was
-- registered with the servicer BEFORE the buyer acquired the book — it was being serviced
-- first. Positive means it was loaded after.
--
-- TWO GUARDS, both named rather than silent:
--   1900-01-01 is a placeholder registration date on Heimdall cases, not a real one.
--   A capex date must be a real date, not a future one.
-- Measured 2026-11-09.
WITH
    batch AS (

        SELECT
            b.batch_sk,
            -- Same id rule as deals_we_own.sql: Heimdall under Intrum's id, the rest Atlas.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle,
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) || '-' || IFF(
                COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
                b.servicer_parent_portfolio_bk,
                SUBSTR(p.portfolio_bk, 5, 7)
            ) AS deal_id,
            b.legacy_capex_date
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
        WHERE b.legacy_capex_date IS NOT NULL
            AND b.legacy_capex_date BETWEEN '1990-01-01' AND CURRENT_DATE
),

    case_batch AS (

        SELECT DISTINCT
            batch_sk,
            case_id
        FROM prod.npl_common.fct_case_snapshot_daily
),

    gap AS (

        SELECT
            b.deal_id,
            b.vehicle,
            b.legacy_capex_date,
            DATEDIFF('month', b.legacy_capex_date, c.registration_date) AS months_gap
        FROM case_batch AS s
        INNER JOIN batch AS b
            ON b.batch_sk = s.batch_sk
        INNER JOIN prod.npl_common.dim_case AS c
            ON c.case_id = s.case_id
            AND c.is_current_flag
        WHERE c.registration_date IS NOT NULL
            AND c.registration_date > '1900-01-01'
)

SELECT
    deal_id,
    MAX(vehicle) AS vehicle,
    MIN(legacy_capex_date) AS prior_capex_date,
    COUNT(*) AS cases_with_registration_date,
    -- Median, not mean: a few cases decades out would drag a mean by years.
    MEDIAN(months_gap) AS median_months_gap,
    COUNT_IF(ABS(months_gap) <= 1) AS cases_within_1_month,
    COUNT_IF(ABS(months_gap) <= 3) AS cases_within_3_months,
    COUNT_IF(months_gap < -3) AS cases_registered_before_capex,
    COUNT_IF(months_gap > 3) AS cases_registered_after_capex,
    MIN(months_gap) AS earliest_months_gap,
    MAX(months_gap) AS latest_months_gap
FROM gap
GROUP BY 1
ORDER BY 1;
