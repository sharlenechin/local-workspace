-- When the cases of the six Swedish deals with a seller tape registered with Intrum, against when we bought each deal.
-- Grain: one row per deal (Intrum id). Runs on the sandbox build (connection dev, warehouse DEV_WH).
-- Registration date is DIM_NPL_CASE.REGISTRATION_DATE on the current case row: the day Intrum took the case on.
-- It is per case, so a deal has a spread of dates, not one. Cases, not loans: on SE17039 a loan that moved
--   from system 1062 to 2080 has two cases and counts twice here.

WITH

deal_batch AS (
    SELECT
        batch_sk,
        servicer_parent_portfolio_bk AS intrum_id,
        legacy_capex_date
    FROM dev.hackathon.dim_npl_batch
    WHERE servicer_parent_portfolio_bk IN ('SE17039', 'SE19026', 'SE20009', 'SE25018', 'SE25037', 'SE25022')
),

deal_case AS (
    SELECT
        b.intrum_id,
        c.case_bk,
        c.registration_date
    FROM dev.hackathon.dim_npl_case AS c
    INNER JOIN deal_batch AS b
        ON b.batch_sk = c.batch_sk
    WHERE c.is_current_flag
),

-- The month the most cases registered, so a deal's spread has a single headline month.
busiest_month AS (
    SELECT
        intrum_id,
        DATE_TRUNC(MONTH, registration_date) AS registration_month,
        COUNT(*) AS cases_in_month
    FROM deal_case
    GROUP BY 1, 2
    QUALIFY ROW_NUMBER() OVER (PARTITION BY intrum_id ORDER BY cases_in_month DESC, registration_month) = 1
),

purchase AS (
    SELECT
        intrum_id,
        MIN(legacy_capex_date) AS purchase_date
    FROM deal_batch
    GROUP BY 1
)

SELECT
    c.intrum_id,
    p.purchase_date,
    COUNT(*) AS cases,
    MIN(c.registration_date) AS first_registration,
    m.registration_month AS busiest_registration_month,
    m.cases_in_month,
    MAX(c.registration_date) AS last_registration,
    -- Cases Intrum already held for the seller before we bought the deal.
    COUNT_IF(c.registration_date < p.purchase_date) AS cases_registered_before_purchase,
    COUNT_IF(c.registration_date IS NULL) AS cases_without_registration_date
FROM deal_case AS c
INNER JOIN purchase AS p
    ON p.intrum_id = c.intrum_id
INNER JOIN busiest_month AS m
    ON m.intrum_id = c.intrum_id
GROUP BY c.intrum_id, p.purchase_date, m.registration_month, m.cases_in_month
ORDER BY p.purchase_date;
