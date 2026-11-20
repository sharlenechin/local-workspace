-- How many Swedish cases carry a debt-age date that DIM_CASE made up rather than received.
-- GRAIN   one row per deal (six Swedish Intrum books), current case version.
-- RUN     mise run sql -- work/data-issues/intrum/queries/se_imputed_case_dates.sql \
--             --connection dev --warehouse DEV_WH
-- WHY     dim_npl_case fills a missing origination_date as default_date - 36 months and a
--         missing default_date as origination_date + 36 months. Debt age and vintage built
--         on the DERIVED_* columns are therefore partly invented; this counts how much.
-- A case is placed in a deal through its newest month-end snapshot row, because DIM_CASE
-- carries no batch or portfolio key of its own.

SET deals = 'SE15044,SE16025,SE19026,SE20009,SE25018,SE25037';

WITH
    case_deal AS (

        SELECT
            c.case_bk,
            b.servicer_parent_portfolio_bk AS deal
        FROM prod_npl_common.npl_common.fct_case_snapshot_daily AS s
        INNER JOIN prod_npl_common.npl_common.dim_batch AS b
            ON b.batch_sk = s.batch_sk
        INNER JOIN prod_npl_common.npl_common.dim_case AS c
            ON c.case_sk = s.case_sk
        WHERE b.servicer_parent_portfolio_bk IN (
                SELECT TRIM(value::string) FROM TABLE(SPLIT_TO_TABLE($deals, ','))
            )
        QUALIFY ROW_NUMBER() OVER (PARTITION BY c.case_bk ORDER BY s.date_day DESC) = 1
),

    current_case AS (

        SELECT
            case_bk,
            origination_date,
            default_date,
            registration_date
        FROM prod_npl_common.npl_common.dim_case
        WHERE is_current_flag
)

SELECT
    d.deal,
    COUNT(*) AS cases,
    ROUND(100 * COUNT_IF(c.origination_date IS NULL) / COUNT(*), 5) AS origination_missing_pct,
    ROUND(100 * COUNT_IF(c.default_date IS NULL) / COUNT(*), 5) AS default_missing_pct,
    -- both missing: the derived columns stay NULL, so debt age cannot be computed at all
    ROUND(100 * COUNT_IF(c.origination_date IS NULL AND c.default_date IS NULL) / COUNT(*), 5)
        AS both_missing_pct,
    ROUND(100 * COUNT_IF(c.registration_date IS NULL) / COUNT(*), 5) AS registration_missing_pct
FROM case_deal AS d
INNER JOIN current_case AS c
    ON c.case_bk = d.case_bk
GROUP BY 1
ORDER BY 1
