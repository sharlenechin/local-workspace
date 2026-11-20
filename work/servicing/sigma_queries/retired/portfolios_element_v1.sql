-- The Custom SQL behind element ROIia0oTOr "Portfolios" on the Servicing
-- Dashboard (77cac618-7b47-46cb-9171-95ad9976f36d). Every tile reads this.
-- Grain: one row per portfolio x reporting month. 1,839 rows at 2026-10-08.
--
-- All money is euro, converted per currency at that month rate before summing:
-- rate_flow (monthly average) for collections, forecast and commission;
-- rate_stock (month end) for balance and carrying value.
--
-- Case columns are deliberately NOT coalesced to zero. 698 of 1,839
-- portfolio-months have no case feed, and a blank there means "no data",
-- never "nobody paid". The mart carries genuine zero-collecting months as
-- real rows, so those still read zero.
--
-- The rolling L1M/L3M/L6M/L12M windows belong here rather than in Sigma: a
-- Sigma aggregate recomputes over the rows currently visible, so under a date
-- filter an L12M would silently mean "the last 12 visible months". The frame
-- RANGE BETWEEN n PRECEDING AND 1 PRECEDING is the n months BEFORE the current
-- one, excluding it.
--
-- Edit in Sigma, not here; this file is the record, because the query is
-- version-controlled nowhere else.


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
),

fx_rates AS (
    -- 2026-10-14: converted the way the live query now does (one rate for every month: each currency's month-end
    -- rate at the latest complete reporting month), so tests/s1's row-by-row comparison with v1 still isolates
    -- everything except the currency rule. The retired workbook itself used monthly averages.
    SELECT
        r.date_day      AS month_end,
        r.quote_currency AS ccy,
        l.ultimo_value  AS rate_flow,
        l.ultimo_value  AS rate_stock
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY AS r
    INNER JOIN PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY AS l
        ON l.quote_currency = r.quote_currency AND l.base_currency = 'EUR' AND l.rate_type = 'PMI'
        AND l.date_day = (SELECT MAX(m.period_end_date) FROM (
              SELECT period_end_date, COUNT(DISTINCT portfolio_sk) AS n,
                     LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY period_end_date) AS prev_n
              FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY WHERE period_end_date <= CURRENT_DATE() GROUP BY 1) m
            WHERE m.prev_n IS NULL OR m.n >= 0.5 * m.prev_n)
    WHERE r.base_currency = 'EUR' AND r.rate_type = 'PMI' AND r.quote_currency <> 'EUR'

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














mart_cases AS (
    -- The dbt mart, keyed the way this query keys portfolios. Replaces the
    -- twelve CTEs that used to re-derive this from FCT_CASE_COLLECTION and
    -- FCT_CASE_SNAPSHOT_DAILY on every single refresh.
    SELECT
        portfolio_sk,
        period_end_date                                   AS month_end,
        collected_cases_count,
        collected_cases_first_collection_count,
        collected_cases_three_consecutive_months_count,
        collected_cases_jitter_in_count,
        collected_cases_jitter_out_count,
        collected_cases_new_count,
        collected_cases_lost_count,
        cases_on_book_count,
        cases_ever_collected_count,
        cases_never_collected_count,
        collected_amount_local_sum                        AS case_collections_local,
        collected_amount_local_lost_last_month_sum        AS case_lost_value_local
    FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY
),

mart_portfolio AS (
    -- Portfolio-level facts the old CTEs supplied: how far the case feed
    -- reaches, whether it exists at all, and how many months it covers.
    SELECT
        portfolio_sk,
        MAX(IFF(collected_cases_count > 0, period_end_date, NULL)) AS last_collecting_month,
        COUNT_IF(collected_cases_count > 0)                        AS months_with_collections
    FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY
    GROUP BY 1
),

portfolio_reported_months AS (
    -- The denominator of the coverage test: months the SERVICER reported.
    SELECT portfolio_sk, COUNT(DISTINCT period_end_date) AS months_pam
    FROM portfolio_metrics
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
        mc.collected_cases_count                             AS collected_cases_count,
        mc.collected_cases_first_collection_count            AS collected_cases_first_collection_count,
        mc.collected_cases_three_consecutive_months_count    AS collected_cases_consistent_3m_count,
        mc.collected_cases_jitter_in_count                   AS collected_cases_jitter_in_count,
        mc.collected_cases_new_count                         AS collected_cases_new_count,
        mc.collected_cases_lost_count                        AS collected_cases_lost_count,
        mc.cases_on_book_count                               AS cases_on_book_count,
        mc.cases_never_collected_count                       AS cases_never_collected_count,
        mc.cases_ever_collected_count                        AS cases_ever_collected_count,
        mpf.last_collecting_month                            AS portfolio_last_payment_month,
        DATEDIFF(MONTH, DATE_TRUNC('MONTH', ps.capex_date),
                        DATE_TRUNC('MONTH', a.period_end_date))
                                                       AS months_since_acquisition,
        IFF(mpf.portfolio_sk IS NOT NULL, 1, 0)        AS have_loan_detail_flag,
        IFF(a.period_end_date > mpf.last_collecting_month, 1, 0)
                                                       AS feed_stopped_flag,
        ROUND(100.0 * COALESCE(mpf.months_with_collections, 0)
              / NULLIF(prm.months_pam, 0), 2)          AS cat_month_coverage_pct,
        IFF(mc.case_collections_local IS NOT NULL
            AND ABS(a.collections_local_currency - mc.case_collections_local)
                <= 0.10 * ABS(NULLIF(a.collections_local_currency, 0))
            AND COALESCE(mpf.months_with_collections, 0) >= 0.80 * prm.months_pam, 1, 0)
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
    LEFT JOIN mart_cases AS mc
        ON mc.portfolio_sk = a.portfolio_sk
        AND mc.month_end = a.period_end_date
    LEFT JOIN mart_portfolio AS mpf
        ON mpf.portfolio_sk = a.portfolio_sk
    LEFT JOIN portfolio_reported_months AS prm
        ON prm.portfolio_sk = a.portfolio_sk
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

    MAX(w.collected_cases_count)                            AS collected_cases_count,
    MAX(w.collected_cases_first_collection_count)                 AS collected_cases_first_collection_count,
    MAX(w.collected_cases_consistent_3m_count)             AS collected_cases_consistent_3m_count,
    MAX(w.collected_cases_jitter_in_count)                   AS collected_cases_jitter_in_count,
    MAX(w.collected_cases_new_count)                      AS collected_cases_new_count,
    MAX(w.collected_cases_lost_count)                     AS collected_cases_lost_count,

    MAX(w.cases_on_book_count)                          AS cases_on_book_count,
    MAX(w.cases_never_collected_count)                 AS cases_never_collected_count,
    MAX(w.cases_ever_collected_count)                AS cases_ever_collected_count,

    MAX(w.months_since_acquisition)                     AS months_since_capex,


    MAX(w.month_end) OVER (PARTITION BY w.portfolio)     AS latest_reporting_month,

    MAX(IFF(w.servicer_forecast_euro IS NOT NULL, 1, 0)) = 1   AS have_servicer_forecast_flag,
    MAX(w.feed_stopped_flag) = 1                               AS feed_stopped_flag,
    MAX(w.have_loan_detail_flag) = 1                           AS have_loan_detail_flag,
    COUNT(DISTINCT w.original_currency) > 1                    AS is_multi_currency_flag,
    MAX(w.cat_month_coverage_pct)                              AS case_month_coverage_pct,
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