-- The live 'Portfolios' Custom SQL, extracted from the workbook spec
-- 2026-10-07. This existed nowhere outside Sigma before today.

WITH portfolio_base AS (
    SELECT
        portfolio_sk,
        portfolio_bk,
        capex_date,
        capex_amount,
        gbv AS gross_book_value,
        price_gross,
        price_percent,
        flow_type,
        currency_id AS portfolio_currency
    FROM PROD.NPL_COMMON.DIM_PORTFOLIO
    WHERE portfolio_bk LIKE '%'

    UNION ALL

    SELECT
        f.portfolio_sk,
        '(Unknown Portfolio ' || f.portfolio_sk || ')',
        NULL,                                  -- capex_date
        NULL,                                  -- capex_amount
        NULL,                                  -- gross_book_value
        NULL,                                  -- price_gross
        NULL,                                  -- price_percent
        NULL,                                  -- flow_type
        NULL                                   -- portfolio_currency
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS d
        ON d.portfolio_sk = f.portfolio_sk
    WHERE d.portfolio_sk IS NULL
      AND ('(Unknown Portfolio ' || f.portfolio_sk || ')') LIKE '%'
    GROUP BY f.portfolio_sk
),

fx_rates AS (
    SELECT
        date_day      AS month_end,
        quote_currency AS ccy,
        monthly_avg   AS rate_flow,        -- Flows: collections, forecasts
        ultimo_value  AS rate_stock        -- Stocks: balance, carrying
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR' AND rate_type = 'PMI' AND quote_currency <> 'EUR'

    UNION ALL

    SELECT DISTINCT period_end_date, 'EUR', 1, 1
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

fx_base AS (
    SELECT
        MIN(month_end) AS fx_start_date,
        MAX(month_end) AS fx_end_date
    FROM fx_rates
    WHERE rate_flow IS NOT NULL AND rate_stock IS NOT NULL
),

portfolio_metrics AS (
    SELECT
        f.portfolio_sk,
        f.period_end_date,
        f.currency_id,
        MAX(f.country_id)             AS country_code,
        MAX(f.deal_sk)                AS deal_sk,
        MAX(f.deal_source_sk)         AS deal_source_sk,
        MAX(f.legal_buyer_sk)         AS legal_buyer_sk,
        COUNT(DISTINCT f.batch_sk)    AS batch_count,
        SUM(f.gross_cash_recoveries)  AS collections_local_currency,
        SUM(f.net_cash_recoveries)    AS net_collections_local_currency,
        SUM(f.total_balance)          AS balance_local_currency,
        SUM(f.commission)             AS commission_local,
        SUM(f.portfolio_mgmt_fee)     AS portfolio_mgmt_fee_local,
        SUM(f.passthrough_cost)       AS passthrough_cost_local
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    INNER JOIN portfolio_base AS p
        ON p.portfolio_sk = f.portfolio_sk
    WHERE (p.capex_date IS NULL
           OR f.period_end_date >= DATE_TRUNC('MONTH', p.capex_date))
      AND f.period_end_date <= CURRENT_DATE()                          
    GROUP BY 1, 2, 3
),

servicer_forecast AS (
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast) AS servicer_forecast_local,
           MAX(n_versions_available)      AS servicer_forecast_version_count
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.snapshot_version,
            f.gross_collection_forecast,
               COUNT(DISTINCT f.snapshot_version) OVER (
                   PARTITION BY f.portfolio_sk, f.period_end_date
               ) AS n_versions_available
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

carrying_amount_base AS (
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        closing_value::NUMBER(38, 6) AS carrying_local
    FROM PROD.NPL_COMMON.FCT_CARRYING_AMOUNT
    WHERE period_end_date <= CURRENT_DATE()                           
),

last_complete_month AS (
    SELECT MAX(m.period_end_date) AS month_end
    FROM (SELECT period_end_date,
                 COUNT(DISTINCT portfolio_sk) AS n,
                 LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY period_end_date) AS prev_n
          FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
          WHERE period_end_date <= CURRENT_DATE()
          GROUP BY 1) m
    WHERE m.prev_n IS NULL OR m.n >= 0.5 * m.prev_n
),

case_metrics_base AS (
    SELECT
        c.portfolio_sk,
        c.case_id,
        c.currency_id,
        DATE_TRUNC('MONTH', c.collection_date) AS collection_month,
        SUM(c.amount)                          AS amount
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN portfolio_base AS ps
        ON ps.portfolio_sk = c.portfolio_sk
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
      -- Same floor as portfolio_metrics: no capex date means keep everything.
      AND (ps.capex_date IS NULL
           OR c.collection_date >= DATE_TRUNC('MONTH', ps.capex_date))
    GROUP BY 1, 2, 3, 4
),

case_base AS (
    SELECT
        portfolio_sk,
        case_id,
        collection_month
    FROM case_metrics_base
    GROUP BY 1, 2, 3
),

cat_monthly AS (
    SELECT
        portfolio_sk,
        collection_month,
        currency_id,
        SUM(amount) AS cat_collections_local_currency
    FROM case_metrics_base
    GROUP BY 1, 2, 3
),

case_metrics_window AS (
    SELECT
        portfolio_sk,
        case_id,
        collection_month,
           LAG(collection_month, 1)  OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS previous_1_month,
           LAG(collection_month, 2)  OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS previous_2_months,
           LEAD(collection_month, 1) OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS next_1_month,
           LEAD(collection_month, 2) OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS next_2_months
    FROM case_base
),

monthly_payers AS (
    SELECT
        portfolio_sk,
        collection_month,
           COUNT(*) AS paying_loan_count,
           SUM(IFF(previous_1_month IS NULL, 1, 0)) AS paying_loans_activated_count,
           SUM(IFF(previous_1_month = DATEADD('MONTH', -1, collection_month)
                   AND previous_2_months = DATEADD('MONTH', -2, collection_month), 1, 0)) AS paying_loans_consistent_3m_count,
           SUM(IFF(COALESCE(previous_1_month = DATEADD('MONTH', -2, collection_month), FALSE)
                   OR COALESCE(previous_2_months = DATEADD('MONTH', -2, collection_month), FALSE),
                   0, 1)) AS payment_loans_jitter_count,
           SUM(IFF(COALESCE(previous_1_month = DATEADD('MONTH', -1, collection_month), FALSE)
                   OR COALESCE(previous_1_month = DATEADD('MONTH', -2, collection_month), FALSE)
                   OR COALESCE(previous_2_months = DATEADD('MONTH', -2, collection_month), FALSE),
                   0, 1)) AS payment_loans_new_count
    FROM case_metrics_window
    GROUP BY 1, 2
),

max_paid_month AS (
    SELECT
        MAX(collection_month) AS max_month
    FROM case_base
),

monthly_lost AS (
    SELECT
        s.portfolio_sk,
        DATEADD('MONTH', 2, s.collection_month) AS collection_month,
        COUNT(*)                                AS payment_loans_lost_count
    FROM case_metrics_window AS s
    CROSS JOIN max_paid_month AS m
    WHERE DATEADD('MONTH', 2, s.collection_month) <= m.max_month
      AND NOT COALESCE(s.next_1_month  = DATEADD('MONTH', 2, s.collection_month), FALSE)
      AND NOT COALESCE(s.next_2_months = DATEADD('MONTH', 2, s.collection_month), FALSE)
    GROUP BY 1, 2
),

portfolio_loan_detail AS (
    SELECT
        portfolio_sk,
        MAX(paying_loan_count) AS max_payers
    FROM monthly_payers
    GROUP BY 1
),

portfolio_month_coverage AS (
    SELECT
        a.portfolio_sk,
        COUNT(DISTINCT a.period_end_date)   AS months_pam,
        COUNT(DISTINCT cm.collection_month) AS months_cat
    FROM portfolio_metrics AS a
    LEFT JOIN cat_monthly AS cm
        ON cm.portfolio_sk = a.portfolio_sk
        AND cm.collection_month = DATE_TRUNC('MONTH', a.period_end_date)
    GROUP BY 1
),

portfolio_last_payment AS (
    SELECT
        portfolio_sk,
        MAX(collection_month) AS last_payment_month
    FROM case_base
    GROUP BY 1
),

book AS (
    SELECT
        s.portfolio_sk,
        s.case_id
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    INNER JOIN (SELECT portfolio_sk, MAX(date_day) AS latest_day
                FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
                GROUP BY 1) AS l
        ON l.portfolio_sk = s.portfolio_sk
        AND l.latest_day = s.date_day
    GROUP BY 1, 2
),

book_stats AS (
    SELECT
        b.portfolio_sk,
        COUNT(*)                        AS loans_on_book_count,
           COUNT_IF(e.case_id IS NOT NULL) AS payment_loans_ever_paid_count,
           COUNT_IF(e.case_id IS NULL)     AS payment_loans_nopaying_count
    FROM book AS b
    LEFT JOIN (SELECT portfolio_sk, case_id FROM case_base GROUP BY 1, 2) AS e
        ON e.portfolio_sk = b.portfolio_sk
        AND e.case_id = b.case_id
    GROUP BY 1
),

subservicer_map AS (
    SELECT 'LEG-ES25001-U00/2512' AS portfolio_bk, 'TDX' AS subservicer
    UNION ALL SELECT 'HEI-GR25001-U01/2512', 'QQuant'
    UNION ALL SELECT 'HEI-GR25001-U02/2512', 'QQuant'
),

standardised_metrics AS (
    SELECT
        ps.portfolio_sk,
        ps.portfolio_bk                                AS portfolio,
        a.period_end_date                              AS month_end,
        DATEDIFF(MONTH, '1900-01-01', a.period_end_date) AS month_index,
        a.currency_id                                  AS original_currency,
        a.country_code,
        a.deal_sk,
        a.deal_source_sk,
        a.legal_buyer_sk,
        a.batch_count,
        ps.capex_date,
        ps.flow_type,
        ps.price_percent,
        ps.portfolio_currency,
        ps.capex_amount     * cfx.rate_stock           AS capex_euro,
        ps.gross_book_value * cfx.rate_stock           AS gross_book_value_euro,

        a.collections_local_currency     * f.rate_flow  AS collections_euro,
        a.net_collections_local_currency * f.rate_flow  AS net_collections_euro,
        sf.servicer_forecast_local       * f.rate_flow  AS servicer_forecast_euro,
        sf.servicer_forecast_version_count,
        a.balance_local_currency         * f.rate_stock AS balance_euro,
        ca.carrying_local                * f.rate_stock AS carrying_amount_euro,
        -a.commission_local         * f.rate_flow      AS commission_euro,
        -a.portfolio_mgmt_fee_local * f.rate_flow      AS portfolio_mgmt_fee_euro,
        -a.passthrough_cost_local   * f.rate_flow      AS passthrough_cost_euro,
        (a.collections_local_currency - a.net_collections_local_currency) * f.rate_flow
                                                       AS servicer_cost_total_euro,
        a.collections_local_currency,
        a.balance_local_currency,
        f.rate_flow,
        f.rate_stock,
        COALESCE(mp.paying_loan_count, 0)                    AS paying_loan_count,
        COALESCE(mp.paying_loans_activated_count, 0)         AS paying_loans_activated_count,
        COALESCE(mp.paying_loans_consistent_3m_count, 0)     AS paying_loans_consistent_3m_count,
        COALESCE(mp.payment_loans_jitter_count, 0)           AS payment_loans_jitter_count,
        COALESCE(mp.payment_loans_new_count, 0)              AS payment_loans_new_count,
        COALESCE(ml.payment_loans_lost_count, 0)             AS payment_loans_lost_count,
        bs.loans_on_book_count,
        COALESCE(bs.payment_loans_nopaying_count, 0)         AS payment_loans_nopaying_count,
        COALESCE(bs.payment_loans_ever_paid_count, 0)        AS payment_loans_ever_paid_count,
        plp.last_payment_month                               AS portfolio_last_payment_month,
        DATEDIFF(MONTH, DATE_TRUNC('MONTH', ps.capex_date),
                        DATE_TRUNC('MONTH', a.period_end_date))
                                                       AS months_since_acquisition,
        IFF(COALESCE(pld.max_payers, 0) > 0, 1, 0)     AS have_loan_detail_flag,
        IFF(DATE_TRUNC('MONTH', a.period_end_date) > plp.last_payment_month, 1, 0)
                                                       AS feed_stopped_flag,
        ROUND(100.0 * COALESCE(pmc.months_cat, 0)
              / NULLIF(pmc.months_pam, 0), 2)          AS cat_month_coverage_pct,
        IFF(cm.cat_collections_local_currency IS NOT NULL
            AND ABS(a.collections_local_currency - cm.cat_collections_local_currency)
                <= 0.10 * ABS(NULLIF(a.collections_local_currency, 0))
            AND COALESCE(pmc.months_cat, 0) >= 0.80 * pmc.months_pam, 1, 0)
                                                       AS month_reconciled_flag
    FROM portfolio_metrics AS a
    INNER JOIN portfolio_base AS ps
        ON ps.portfolio_sk = a.portfolio_sk
    LEFT JOIN fx_rates AS f
        ON f.ccy = a.currency_id
        AND f.month_end = a.period_end_date
    LEFT JOIN fx_rates AS cfx
        ON cfx.ccy = ps.portfolio_currency
        AND cfx.month_end = LAST_DAY(ps.capex_date)
    LEFT JOIN servicer_forecast AS sf
        ON sf.portfolio_sk = a.portfolio_sk
        AND sf.period_end_date = a.period_end_date
        AND sf.currency_id = a.currency_id
    LEFT JOIN carrying_amount_base AS ca
        ON ca.portfolio_sk = a.portfolio_sk
        AND ca.period_end_date = a.period_end_date
        AND ca.currency_id = a.currency_id
    LEFT JOIN monthly_payers AS mp
        ON mp.portfolio_sk = a.portfolio_sk
        AND mp.collection_month = DATE_TRUNC('MONTH', a.period_end_date)
    LEFT JOIN monthly_lost AS ml
        ON ml.portfolio_sk = a.portfolio_sk
        AND ml.collection_month = DATE_TRUNC('MONTH', a.period_end_date)
    LEFT JOIN book_stats AS bs
        ON bs.portfolio_sk = a.portfolio_sk
    LEFT JOIN portfolio_last_payment AS plp
        ON plp.portfolio_sk = a.portfolio_sk
    LEFT JOIN portfolio_loan_detail AS pld
        ON pld.portfolio_sk = a.portfolio_sk
    LEFT JOIN portfolio_month_coverage AS pmc
        ON pmc.portfolio_sk = a.portfolio_sk
    LEFT JOIN cat_monthly AS cm
        ON cm.portfolio_sk = a.portfolio_sk
        AND cm.collection_month = DATE_TRUNC('MONTH', a.period_end_date)
        AND cm.currency_id = a.currency_id
),

aggregated_metrics AS (
    SELECT
        c.*,
        LAG(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collections_l1m_euro,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collections_l3m_euro,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collections_l6m_euro,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collections_l12m_euro,
        LAG(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS servicer_forecast_l1m_euro,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS servicer_forecast_l3m_euro,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS servicer_forecast_l6m_euro,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS servicer_forecast_l12m_euro,
        COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS months_in_l3m_window,
        COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS months_in_l6m_window,
        COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS months_in_l12m_window,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_collections_euro,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_servicer_forecast_euro,
        SUM(IFF(c.servicer_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (
            PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_collections_in_servicer_window_euro
    FROM standardised_metrics AS c
)

SELECT
    COALESCE(lb.legal_buyer_name, 'Unknown')            AS vehicle,
    COALESCE(ds.deal_source_name, 'Unknown')            AS project,
    COALESCE(dd.deal_alias, dd.deal_bk, 'Unknown')      AS deal,
    CASE WHEN ds.deal_source_name = 'LEGACY' AND w.country_code = 'ES' THEN 'Gescobro'
         WHEN ds.deal_source_name = 'LEGACY' AND w.country_code = 'IT' THEN 'Cerved'
         ELSE 'Intrum' END                              AS servicer_group,
    COALESCE(sm.subservicer, '')                        AS servicer_sub_group,
    IFF(sm.subservicer IS NOT NULL,
        servicer_group || ' - ' || sm.subservicer,
        servicer_group)                                 AS servicer,
    COALESCE(dd.seller_name, 'Unknown')                 AS seller,
    CASE WHEN COALESCE(co.country_name, w.country_code, 'Unknown') = 'UK'
         THEN 'Europe' ELSE co.region END               AS region,
    COALESCE(co.country_name, w.country_code, 'Unknown') AS country_name,
    COALESCE(w.country_code, 'Unknown')                 AS country_code,
    w.flow_type,
    w.portfolio                                         AS portfolio_name,
    YEAR(w.capex_date)                                  AS capex_year,
    DATE_TRUNC('MONTH', w.capex_date)::DATE             AS capex_month,
    w.capex_date,
    w.month_end                                         AS reporting_month,
    YEAR(w.month_end)                                   AS reporting_year,
    LISTAGG(DISTINCT w.original_currency, ' + ')
        WITHIN GROUP (ORDER BY w.original_currency)     AS original_currency,
    MAX(w.price_percent)                                AS price_percent,
    MAX(w.batch_count)                                  AS batch_count,
    MAX(w.capex_euro)                                   AS capex_sum,
    MAX(w.gross_book_value_euro)                        AS gross_book_value_sum,
    SUM(w.collections_euro)                             AS collections_sum,
    SUM(w.net_collections_euro)                         AS net_collections_sum,
    SUM(w.servicer_forecast_euro)                       AS servicer_forecast_sum,
    MAX(w.servicer_forecast_version_count)              AS servicer_forecast_version_count,
    SUM(w.balance_euro)                                 AS balance_sum,
    SUM(w.carrying_amount_euro)                         AS carrying_amount_sum,

    -- Rolling Metrics
    SUM(w.collections_l1m_euro)                         AS collections_l1m_sum,
    SUM(w.collections_l3m_euro)                         AS collections_l3m_sum,
    SUM(w.collections_l6m_euro)                         AS collections_l6m_sum,
    SUM(w.collections_l12m_euro)                        AS collections_l12m_sum,
    SUM(w.servicer_forecast_l1m_euro)                   AS servicer_forecast_l1m_sum,
    SUM(w.servicer_forecast_l3m_euro)                   AS servicer_forecast_l3m_sum,
    SUM(w.servicer_forecast_l6m_euro)                   AS servicer_forecast_l6m_sum,
    SUM(w.servicer_forecast_l12m_euro)                  AS servicer_forecast_l12m_sum,
    MAX(w.months_in_l3m_window)                         AS months_in_l3m_window,
    MAX(w.months_in_l6m_window)                         AS months_in_l6m_window,
    MAX(w.months_in_l12m_window)                        AS months_in_l12m_window,
    SUM(w.cumulative_collections_euro)                  AS cumulative_collections_sum,
    SUM(w.cumulative_servicer_forecast_euro)            AS cumulative_servicer_forecast_sum,
    SUM(w.cumulative_collections_in_servicer_window_euro) AS cumulative_collections_in_servicer_window_sum,

    SUM(w.commission_euro)                              AS servicer_commission_sum,
    SUM(w.portfolio_mgmt_fee_euro)                      AS servicer_portfolio_management_fee_sum,
    SUM(w.passthrough_cost_euro)                        AS servicer_passthrough_cost_sum,
    SUM(w.servicer_cost_total_euro)                     AS servicer_cost_total_sum,

    MAX(w.paying_loan_count)                            AS paying_loans_count,
    MAX(w.paying_loans_activated_count)                 AS paying_loans_activated_count,
    MAX(w.paying_loans_consistent_3m_count)             AS paying_loans_consistent_3m_count,
    MAX(w.payment_loans_jitter_count)                   AS payment_loans_jitter_count,
    MAX(w.payment_loans_new_count)                      AS payment_loans_new_count,
    MAX(w.payment_loans_lost_count)                     AS payment_loans_lost_count,

    MAX(w.loans_on_book_count)                          AS loans_on_book_count,
    MAX(w.payment_loans_nopaying_count)                 AS payment_loans_nopaying_count,
    MAX(w.payment_loans_ever_paid_count)                AS payment_loans_ever_paid_count,
    MAX(w.portfolio_last_payment_month)                 AS portfolio_last_payment_month,

    MAX(w.months_since_acquisition)                     AS months_since_capex,

    SUM(w.collections_local_currency)                   AS collections_local_currency,
    SUM(w.balance_local_currency)                       AS balance_local_currency,

    MAX(lcm.month_end)                                  AS snapshot_date,
    MAX(fw.fx_start_date)                               AS fx_start_date,
    MAX(fw.fx_end_date)                                 AS fx_end_date,

    MAX(IFF(w.servicer_forecast_euro IS NOT NULL, 1, 0)) = 1   AS have_servicer_forecast_flag,
    MAX(w.feed_stopped_flag) = 1                               AS feed_stopped_flag,
    MAX(w.have_loan_detail_flag) = 1                           AS have_loan_detail_flag,
    COUNT(DISTINCT w.original_currency) > 1                    AS is_multi_currency_flag,
    MAX(w.cat_month_coverage_pct)                              AS cat_month_coverage_pct,
    MIN(w.month_reconciled_flag) = 1                           AS is_reconciled_flag

FROM aggregated_metrics AS w
CROSS JOIN last_complete_month AS lcm
CROSS JOIN fx_base AS fw
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS dd
    ON dd.deal_sk = w.deal_sk
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
    ON ds.deal_source_sk = w.deal_source_sk
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON lb.legal_buyer_sk = w.legal_buyer_sk
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = w.country_code
LEFT JOIN subservicer_map AS sm
    ON sm.portfolio_bk = w.portfolio
WHERE w.month_end <= lcm.month_end
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17