WITH portfolio_vehicle AS (
    SELECT
        portfolio_sk,
        ANY_VALUE(legal_buyer_sk) AS legal_buyer_sk,
        ANY_VALUE(country_id)     AS fact_country_id
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    GROUP BY 1
),

subservicer_map AS (
    SELECT 'LEG-ES25001-U00/2512' AS portfolio_bk, 'TDX' AS subservicer
    UNION ALL SELECT 'HEI-GR25001-U01/2512', 'QQuant'
    UNION ALL SELECT 'HEI-GR25001-U02/2512', 'QQuant'
)

SELECT
    p.portfolio_sk,
    COALESCE(p.portfolio_bk, 'Unknown')                 AS portfolio_name,
    COALESCE(lb.legal_buyer_name, 'Unknown')            AS vehicle,
    COALESCE(ds.deal_source_name, 'Unknown')            AS project,
    COALESCE(d.deal_alias, d.deal_bk, 'Unknown')        AS deal,
    CASE WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'ES' THEN 'Gescobro'
         WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'IT' THEN 'Cerved'
         ELSE 'Intrum' END                              AS servicer_group,
    COALESCE(sm.subservicer, '')                        AS servicer_sub_group,
    IFF(sm.subservicer IS NOT NULL,
        servicer_group || ' - ' || sm.subservicer,
        servicer_group)                                 AS servicer,
    COALESCE(d.seller_name, 'Unknown')                  AS seller,
    CASE WHEN COALESCE(co.country_name, d.country_id, 'Unknown') = 'UK'
         THEN 'Europe' ELSE co.region END               AS region,
    COALESCE(co.country_name, d.country_id, 'Unknown')  AS country_name,
    COALESCE(d.country_id, pv.fact_country_id, 'Unknown') AS country_code,

    -- ---- Portfolio Attributes --------------------------------------------
    p.flow_type,
    p.currency_id                                       AS portfolio_currency,
    p.capex_date,
    DATE_TRUNC('MONTH', p.capex_date)::DATE             AS capex_month,
    YEAR(p.capex_date)                                  AS capex_year,
    p.capex_amount,
    p.gbv                                               AS gross_book_value,
    p.price_gross,
    p.price_percent
FROM PROD.NPL_COMMON.DIM_PORTFOLIO AS p
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS d
    ON d.deal_id = p.deal_id
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
    ON ds.deal_source_bk = d.deal_source_bk
LEFT JOIN portfolio_vehicle AS pv
    ON pv.portfolio_sk = p.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON lb.legal_buyer_sk = pv.legal_buyer_sk
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = d.country_id
LEFT JOIN subservicer_map AS sm
    ON sm.portfolio_bk = p.portfolio_bk

UNION ALL


SELECT
    f.portfolio_sk,
    '(Unknown Portfolio ' || f.portfolio_sk || ')'      AS portfolio_name,
    'Unknown'                                           AS vehicle,
    'Unknown'                                           AS project,
    'Unknown'                                           AS deal,
    'Unknown'                                           AS servicer_group,
    ''                                                  AS servicer_sub_group,
    'Unknown'                                           AS servicer,
    'Unknown'                                           AS seller,
    'Unknown'                                           AS region,
    'Unknown'                                           AS country_name,
    'Unknown'                                           AS country_code,
    NULL                                                AS flow_type,
    NULL                                                AS portfolio_currency,
    NULL                                                AS capex_date,
    NULL                                                AS capex_month,
    NULL                                                AS capex_year,
    NULL                                                AS capex_amount,
    NULL                                                AS gross_book_value,
    NULL                                                AS price_gross,
    NULL                                                AS price_percent
FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS d
    ON d.portfolio_sk = f.portfolio_sk
WHERE d.portfolio_sk IS NULL
GROUP BY 1