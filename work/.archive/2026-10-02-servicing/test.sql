
WITH
    book AS (
        SELECT
            s.case_sk,
            s.portfolio_sk,
            s.deal_sk,
            s.deal_source_sk,
            s.legal_buyer_sk, s.country_id, s.currency_id,
            s.forbearance_flag,
            s.outstanding_total
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        INNER JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p
                ON p.portfolio_sk = s.portfolio_sk
            AND p.portfolio_bk LIKE '%'
)
SELECT 
*
FROM book
LIMIT 10

agg_cases

SELECT 
    case_sk,
    case_id, 
    status_code, 
    status_description,
    derived_origination_date AS origination_date, 
    derived_default_date AS default_date, 
    closing_date, 
    status_date, 
    secured_flag, 
    is_current_flag
FROM PROD.NPL_COMMON.DIM_CASE 
ORDER BY 1 LIMIT 10

