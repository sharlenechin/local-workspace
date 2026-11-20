-- PROPOSED, NOT LIVE. The live element is live/portfolios_element.sql.
-- This is that query plus the accounting and underwriting forecasts, so the
-- redesigned dashboard can offer all three as the benchmark, plus case EUR by
-- behaviour, jitter out and rolling case windows for the Cases KPI. Push it to
-- element ROIia0oTOr only with the redesign.
-- Grain: one row per portfolio x reporting month, the same as live.
-- Measured 2026-10-09: 1,839 rows, no duplicates; collections EUR 347,398,071.67
-- and servicer forecast EUR 292,206,245.90, both identical to live to the cent.
--
-- The two new forecasts join exactly as the servicer one does: on the
-- portfolio-months that have actuals, in the same currency, converted at
-- rate_flow. So each is like-for-like with collections by construction.
--
-- All money is euro, converted per currency before summing, at ONE rate for every month: each currency's month-end
-- rate at the latest complete reporting month, as the NPL Portfolio Dashboard (v2) does (the user, 2026-10-14). Past
-- months then move only when collections move, not when the euro does, and the two dashboards differ only by
-- ownership share (tests/npl_crosscheck.py). rate_flow and rate_stock are kept as names and now hold the same rate.
-- Until 2026-10-14: monthly average for flows, month end for stocks, each month at its own rate.
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

fx_latest AS (
    -- Each currency's month-end rate at the latest complete reporting month: the one rate every month converts at.
    SELECT x.quote_currency AS ccy, x.ultimo_value AS rate
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY AS x
    INNER JOIN last_complete_month AS l ON x.date_day = l.month_end
    WHERE x.base_currency = 'EUR' AND x.rate_type = 'PMI' AND x.quote_currency <> 'EUR'
),

fx_rates AS (
    -- Every month the rate table covers, each at the latest month-end rate (see the header).
    SELECT
        r.date_day      AS month_end,
        r.quote_currency AS ccy,
        l.rate          AS rate_flow,
        l.rate          AS rate_stock
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY AS r
    INNER JOIN fx_latest AS l ON l.ccy = r.quote_currency
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

accounting_forecast AS (
    -- Finance's current view, revised each vintage. Latest snapshot_version
    -- only: the forecast facts are not deduped upstream, so without the
    -- QUALIFY every restatement counts again.
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast) AS accounting_forecast_local
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.gross_collection_forecast
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

underwriting_forecast AS (
    -- What we assumed when we bought: one vintage, never revised, and it
    -- starts 2025-06-30, so months before that have no underwriting plan.
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast) AS underwriting_forecast_local
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.gross_collection_forecast
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY AS f
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

month_status AS (
    -- What the dashboard is NOT showing, so the header can say it out loud
    -- instead of a month silently disappearing. On 2026-10-09: data as of
    -- August (264 portfolios); September loading with 4 - held back.
    SELECT
        lcm.month_end                                                  AS data_as_of_month,
        MAX(IFF(m.period_end_date = lcm.month_end, m.n, NULL))         AS data_as_of_portfolio_count,
        MIN(IFF(m.period_end_date > lcm.month_end, m.period_end_date, NULL)) AS loading_month
    FROM last_complete_month AS lcm
    CROSS JOIN (SELECT period_end_date, COUNT(DISTINCT portfolio_sk) AS n
                FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
                WHERE period_end_date <= CURRENT_DATE()
                GROUP BY 1) AS m
    GROUP BY 1
),

loading_month_count AS (
    SELECT ms.loading_month, COUNT(DISTINCT f.portfolio_sk) AS loading_month_portfolio_count
    FROM month_status AS ms
    INNER JOIN PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
        ON f.period_end_date = ms.loading_month
    GROUP BY 1
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
        collected_amount_local_lost_last_month_sum        AS case_lost_value_local,
        -- What each behaviour group collected. Lost is what those cases
        -- collected in their LAST month, since the month they are counted in
        -- has no collection by definition.
        collected_amount_local_first_collection_sum       AS case_first_collection_local,
        collected_amount_local_three_consecutive_months_sum AS case_three_consecutive_local,
        collected_amount_local_jitter_in_sum              AS case_jitter_in_local,
        collected_amount_local_new_sum                    AS case_new_local,
        collected_amount_local_jitter_out_last_month_sum  AS case_jitter_out_last_month_local
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
        af.accounting_forecast_local     * f.rate_flow  AS accounting_forecast_euro,
        uf.underwriting_forecast_local   * f.rate_flow  AS underwriting_forecast_euro,
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
        mc.collected_cases_jitter_out_count                  AS collected_cases_jitter_out_count,
        mc.cases_on_book_count                               AS cases_on_book_count,
        mc.cases_never_collected_count                       AS cases_never_collected_count,
        mc.cases_ever_collected_count                        AS cases_ever_collected_count,
        -- Case amounts at the same rate as the portfolio-month's collections.
        -- Safe because no portfolio reports in two currencies in one month
        -- (is_multi_currency_flag is false on every row, 2026-10-08).
        mc.case_collections_local      * f.rate_flow  AS case_collections_euro,
        mc.case_lost_value_local       * f.rate_flow  AS case_lost_last_month_euro,
        mc.case_first_collection_local * f.rate_flow  AS case_first_collection_euro,
        mc.case_three_consecutive_local * f.rate_flow AS case_three_consecutive_euro,
        mc.case_jitter_in_local        * f.rate_flow  AS case_jitter_in_euro,
        mc.case_new_local              * f.rate_flow  AS case_new_euro,
        mc.case_jitter_out_last_month_local * f.rate_flow AS case_jitter_out_last_month_euro,
        mpf.last_collecting_month                            AS portfolio_last_payment_month,
        DATEDIFF(MONTH, DATE_TRUNC('MONTH', ps.capex_date),
                        DATE_TRUNC('MONTH', a.period_end_date))
                                                       AS months_since_acquisition,
        IFF(mpf.portfolio_sk IS NOT NULL, 1, 0)        AS have_loan_detail_flag,
        IFF(a.period_end_date > mpf.last_collecting_month, 1, 0)
                                                       AS feed_stopped_flag,
        ROUND(100.0 * COALESCE(mpf.months_with_collections, 0)
              / NULLIF(prm.months_pam, 0), 2)          AS cat_month_coverage_pct,
        -- ⚠ Italy is never reconciled, by hand (the user, 2026-10-14), until dbt is fixed. Intrum's Italian file
        -- (CAT 4034) has no orig_tr_id, so int_npl_case_collection_intrum's CONCAT(orig_tr_id, ...) is NULL and its
        -- dedupe keeps ONE payment per case: raw has 2,850 Italian payments Dec 2025 - Aug 2026, PROD keeps 1,041.
        -- The euros can still pass the 10% test (the latest payment survives, so the newest month looks complete), but
        -- every payer reads as New and none as Fresh, Lost or steady. Remove this line once the model is fixed.
        IFF(mc.case_collections_local IS NOT NULL
            AND COALESCE(a.country_code, '') <> 'IT'
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
    LEFT JOIN accounting_forecast AS af
        ON af.portfolio_sk = a.portfolio_sk
        AND af.period_end_date = a.period_end_date
        AND af.currency_id = a.currency_id
    LEFT JOIN underwriting_forecast AS uf
        ON uf.portfolio_sk = a.portfolio_sk
        AND uf.period_end_date = a.period_end_date
        AND uf.currency_id = a.currency_id
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
        LAG(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS accounting_forecast_l1m_euro,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS accounting_forecast_l3m_euro,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS accounting_forecast_l6m_euro,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS accounting_forecast_l12m_euro,
        LAG(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS underwriting_forecast_l1m_euro,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS underwriting_forecast_l3m_euro,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS underwriting_forecast_l6m_euro,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS underwriting_forecast_l12m_euro,
        -- Case windows, for the Cases page KPI. Same frames as collections, but
        -- counted over months WITH case data: some portfolio-months have
        -- collections and no case feed, so the money's month count would be the
        -- wrong divisor here.
        LAG(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collected_cases_l1m,
        SUM(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_l3m,
        SUM(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_l6m,
        SUM(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_l12m,
        LAG(c.collected_cases_first_collection_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collected_cases_first_collection_l1m,
        SUM(c.collected_cases_first_collection_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_first_collection_l3m,
        SUM(c.collected_cases_first_collection_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_first_collection_l6m,
        SUM(c.collected_cases_first_collection_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_first_collection_l12m,
        LAG(c.collected_cases_consistent_3m_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collected_cases_three_consecutive_months_l1m,
        SUM(c.collected_cases_consistent_3m_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_three_consecutive_months_l3m,
        SUM(c.collected_cases_consistent_3m_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_three_consecutive_months_l6m,
        SUM(c.collected_cases_consistent_3m_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_three_consecutive_months_l12m,
        LAG(c.collected_cases_lost_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collected_cases_lost_l1m,
        SUM(c.collected_cases_lost_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_lost_l3m,
        SUM(c.collected_cases_lost_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_lost_l6m,
        SUM(c.collected_cases_lost_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_lost_l12m,
        LAG(c.collected_cases_new_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collected_cases_new_l1m,
        SUM(c.collected_cases_new_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_new_l3m,
        SUM(c.collected_cases_new_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_new_l6m,
        SUM(c.collected_cases_new_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_new_l12m,
        LAG(c.case_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collected_cases_amount_l1m,
        SUM(c.case_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_amount_l3m,
        SUM(c.case_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_amount_l6m,
        SUM(c.case_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_amount_l12m,
        -- Cases on book in the same windows, for Collected Cases % of Book on the Cases page's §2 (the user,
        -- 2026-10-14): the window's collected cases over the window's case-months on book. Counted only in months with
        -- a case feed, so the numerator and the denominator cover the same months.
        LAG(IFF(c.collected_cases_count IS NOT NULL, c.cases_on_book_count, NULL)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS cases_on_book_l1m,
        SUM(IFF(c.collected_cases_count IS NOT NULL, c.cases_on_book_count, NULL)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS cases_on_book_l3m,
        SUM(IFF(c.collected_cases_count IS NOT NULL, c.cases_on_book_count, NULL)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS cases_on_book_l6m,
        SUM(IFF(c.collected_cases_count IS NOT NULL, c.cases_on_book_count, NULL)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS cases_on_book_l12m,
        COUNT(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS months_in_case_l3m_window,
        COUNT(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS months_in_case_l6m_window,
        COUNT(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS months_in_case_l12m_window,
        -- Collections from months that HAVE a servicer forecast, in the same
        -- windows: the KPI's like-for-like value when it is compared with the
        -- servicer forecast.
        LAG(IFF(c.servicer_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collections_servicer_lfl_l1m_euro,
        SUM(IFF(c.servicer_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collections_servicer_lfl_l3m_euro,
        SUM(IFF(c.servicer_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collections_servicer_lfl_l6m_euro,
        SUM(IFF(c.servicer_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collections_servicer_lfl_l12m_euro,
        -- Window sums for the Portfolio tiles, so every tile follows the Window switch:
        -- net collections, servicer cost and reconciled collections, same frames as collections.
        LAG(c.net_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS net_collections_l1m_euro,
        SUM(c.net_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS net_collections_l3m_euro,
        SUM(c.net_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS net_collections_l6m_euro,
        SUM(c.net_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS net_collections_l12m_euro,
        LAG(c.servicer_cost_total_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS servicer_cost_total_l1m_euro,
        SUM(c.servicer_cost_total_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS servicer_cost_total_l3m_euro,
        SUM(c.servicer_cost_total_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS servicer_cost_total_l6m_euro,
        SUM(c.servicer_cost_total_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS servicer_cost_total_l12m_euro,
        LAG(IFF(c.month_reconciled_flag = 1, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collections_reconciled_l1m_euro,
        SUM(IFF(c.month_reconciled_flag = 1, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collections_reconciled_l3m_euro,
        SUM(IFF(c.month_reconciled_flag = 1, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collections_reconciled_l6m_euro,
        SUM(IFF(c.month_reconciled_flag = 1, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collections_reconciled_l12m_euro,
        -- 2- and 24-month windows: with the 1/3/6/12-month ones they give the PREVIOUS window
        -- for every tile (the 3 months before the last 3 = L6M - L3M; before the last 12 = L24M - L12M),
        -- which is what the tiles compare against.
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collections_l2m,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collections_l24m,
        SUM(IFF(c.servicer_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collections_servicer_lfl_l2m,
        SUM(IFF(c.servicer_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collections_servicer_lfl_l24m,
        SUM(c.net_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS net_collections_l2m,
        SUM(c.net_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS net_collections_l24m,
        SUM(c.servicer_cost_total_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS servicer_cost_total_l2m,
        SUM(c.servicer_cost_total_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS servicer_cost_total_l24m,
        SUM(IFF(c.month_reconciled_flag = 1, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collections_reconciled_l2m,
        SUM(IFF(c.month_reconciled_flag = 1, c.collections_euro, 0)) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collections_reconciled_l24m,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS servicer_forecast_l2m,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS servicer_forecast_l24m,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS accounting_forecast_l2m,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS accounting_forecast_l24m,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS underwriting_forecast_l2m,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS underwriting_forecast_l24m,
        SUM(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_l2m,
        SUM(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_l24m,
        SUM(c.case_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_amount_l2m,
        SUM(c.case_collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_amount_l24m,
        SUM(c.collected_cases_first_collection_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_first_collection_l2m,
        SUM(c.collected_cases_first_collection_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_first_collection_l24m,
        SUM(c.collected_cases_new_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_new_l2m,
        SUM(c.collected_cases_new_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_new_l24m,
        SUM(c.collected_cases_lost_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_lost_l2m,
        SUM(c.collected_cases_lost_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_lost_l24m,
        SUM(c.collected_cases_consistent_3m_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_three_consecutive_months_l2m,
        SUM(c.collected_cases_consistent_3m_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS collected_cases_three_consecutive_months_l24m,
        COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS months_in_l2m_window,
        COUNT(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
                                         AS months_in_case_l2m_window,
        COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS months_in_l24m_window,
        COUNT(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 24 PRECEDING AND 1 PRECEDING)
                                         AS months_in_case_l24m_window,
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
    -- Servicer group, the manager's rule (2026-10-12, replacing two earlier versions that day):
    --   Massey   = organic UK          Fire     = organic Italy
    --   Gescobro = organic, legacy or Gescobro-sourced Spain
    --   Cerved   = legacy Italy
    --   Intrum   = everything else
    -- Measured that day: Massey 2 portfolios, Fire 1, Gescobro 8, Cerved 3, Intrum 250. Against the version
    -- before it, the 3 legacy Spanish books moved Cerved -> Gescobro (EUR 35,140,860.15 to date).
    CASE
        -- MASSEY — the two Arrow Global UK books (Equinox I and II). Proven from the case
        -- feed 2026-10-12: ORG-UK26003-U01/2606 (37,731 loans) and ORG-UK26002-U01/2606
        -- (10,279) are both reported by massey.
        WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND w.country_code = 'UK'
            THEN 'Massey'

        -- FIRE — the organic Italian books (Findomestic Spring today). It has no case feed,
        -- so this comes from the business, not the data.
        WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND w.country_code = 'IT'
            THEN 'Fire'

        -- GESCOBRO — the Spanish organic and legacy books.
        WHEN ds.deal_source_name IN ('ORGANIC ORIGINATED', 'LEGACY') AND w.country_code = 'ES'
            THEN 'Gescobro'

        -- CERVED — the Italian legacy books.
        WHEN ds.deal_source_name = 'LEGACY' AND w.country_code = 'IT'
            THEN 'Cerved'

        -- GESCOBRO — the deals sourced through Gescobro itself, in Spain.
        WHEN ds.deal_source_name = 'GESCOBRO' AND w.country_code = 'ES'
            THEN 'Gescobro'

        ELSE 'Intrum'
    END                                                 AS servicer_group,
    -- The hand-typed sub-servicer list (TDX, QQuant) was removed 2026-10-13: two of its three names matched no
    -- portfolio and nothing on the dashboard read it. Servicers from Atlas are being added to dbt instead.
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
    SUM(w.accounting_forecast_euro)                 AS accounting_forecast_sum,
    SUM(w.underwriting_forecast_euro)               AS underwriting_forecast_sum,
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
    -- Like-for-like collections for the servicer comparison.
    SUM(IFF(w.servicer_forecast_euro IS NOT NULL, w.collections_euro, 0))AS collections_servicer_lfl_sum,
    SUM(w.collections_servicer_lfl_l1m_euro)        AS collections_servicer_lfl_l1m_sum,
    SUM(w.collections_servicer_lfl_l3m_euro)        AS collections_servicer_lfl_l3m_sum,
    SUM(w.collections_servicer_lfl_l6m_euro)        AS collections_servicer_lfl_l6m_sum,
    SUM(w.collections_servicer_lfl_l12m_euro)       AS collections_servicer_lfl_l12m_sum,
    -- Window sums behind the Portfolio tiles.
    SUM(IFF(w.month_reconciled_flag = 1, w.collections_euro, 0))AS collections_reconciled_sum,
    SUM(w.net_collections_l1m_euro)                 AS net_collections_l1m_sum,
    SUM(w.net_collections_l3m_euro)                 AS net_collections_l3m_sum,
    SUM(w.net_collections_l6m_euro)                 AS net_collections_l6m_sum,
    SUM(w.net_collections_l12m_euro)                AS net_collections_l12m_sum,
    SUM(w.servicer_cost_total_l1m_euro)             AS servicer_cost_total_l1m_sum,
    SUM(w.servicer_cost_total_l3m_euro)             AS servicer_cost_total_l3m_sum,
    SUM(w.servicer_cost_total_l6m_euro)             AS servicer_cost_total_l6m_sum,
    SUM(w.servicer_cost_total_l12m_euro)            AS servicer_cost_total_l12m_sum,
    SUM(w.collections_reconciled_l1m_euro)          AS collections_reconciled_l1m_sum,
    SUM(w.collections_reconciled_l3m_euro)          AS collections_reconciled_l3m_sum,
    SUM(w.collections_reconciled_l6m_euro)          AS collections_reconciled_l6m_sum,
    SUM(w.collections_reconciled_l12m_euro)         AS collections_reconciled_l12m_sum,
    -- 2- and 24-month windows, for the tiles' previous-window comparison.
    SUM(w.collections_l2m)                          AS collections_l2m_sum,
    SUM(w.collections_l24m)                         AS collections_l24m_sum,
    SUM(w.collections_servicer_lfl_l2m)             AS collections_servicer_lfl_l2m_sum,
    SUM(w.collections_servicer_lfl_l24m)            AS collections_servicer_lfl_l24m_sum,
    SUM(w.net_collections_l2m)                      AS net_collections_l2m_sum,
    SUM(w.net_collections_l24m)                     AS net_collections_l24m_sum,
    SUM(w.servicer_cost_total_l2m)                  AS servicer_cost_total_l2m_sum,
    SUM(w.servicer_cost_total_l24m)                 AS servicer_cost_total_l24m_sum,
    SUM(w.collections_reconciled_l2m)               AS collections_reconciled_l2m_sum,
    SUM(w.collections_reconciled_l24m)              AS collections_reconciled_l24m_sum,
    SUM(w.servicer_forecast_l2m)                    AS servicer_forecast_l2m_sum,
    SUM(w.servicer_forecast_l24m)                   AS servicer_forecast_l24m_sum,
    SUM(w.accounting_forecast_l2m)                  AS accounting_forecast_l2m_sum,
    SUM(w.accounting_forecast_l24m)                 AS accounting_forecast_l24m_sum,
    SUM(w.underwriting_forecast_l2m)                AS underwriting_forecast_l2m_sum,
    SUM(w.underwriting_forecast_l24m)               AS underwriting_forecast_l24m_sum,
    MAX(w.collected_cases_l2m)                      AS collected_cases_l2m_sum,
    MAX(w.collected_cases_l24m)                     AS collected_cases_l24m_sum,
    SUM(w.collected_cases_amount_l2m)               AS collected_cases_amount_l2m_sum,
    SUM(w.collected_cases_amount_l24m)              AS collected_cases_amount_l24m_sum,
    MAX(w.collected_cases_first_collection_l2m)     AS collected_cases_first_collection_l2m_sum,
    MAX(w.collected_cases_first_collection_l24m)    AS collected_cases_first_collection_l24m_sum,
    MAX(w.collected_cases_new_l2m)                  AS collected_cases_new_l2m_sum,
    MAX(w.collected_cases_new_l24m)                 AS collected_cases_new_l24m_sum,
    MAX(w.collected_cases_lost_l2m)                 AS collected_cases_lost_l2m_sum,
    MAX(w.collected_cases_lost_l24m)                AS collected_cases_lost_l24m_sum,
    MAX(w.collected_cases_three_consecutive_months_l2m)AS collected_cases_three_consecutive_months_l2m_sum,
    MAX(w.collected_cases_three_consecutive_months_l24m)AS collected_cases_three_consecutive_months_l24m_sum,
    MAX(w.months_in_l2m_window)                     AS months_in_l2m_window,
    MAX(w.months_in_case_l2m_window)                AS months_in_case_l2m_window,
    MAX(w.months_in_l24m_window)                    AS months_in_l24m_window,
    MAX(w.months_in_case_l24m_window)               AS months_in_case_l24m_window,
    SUM(w.accounting_forecast_l1m_euro)             AS accounting_forecast_l1m_sum,
    SUM(w.accounting_forecast_l3m_euro)             AS accounting_forecast_l3m_sum,
    SUM(w.accounting_forecast_l6m_euro)             AS accounting_forecast_l6m_sum,
    SUM(w.accounting_forecast_l12m_euro)            AS accounting_forecast_l12m_sum,
    SUM(w.underwriting_forecast_l1m_euro)           AS underwriting_forecast_l1m_sum,
    SUM(w.underwriting_forecast_l3m_euro)           AS underwriting_forecast_l3m_sum,
    SUM(w.underwriting_forecast_l6m_euro)           AS underwriting_forecast_l6m_sum,
    SUM(w.underwriting_forecast_l12m_euro)          AS underwriting_forecast_l12m_sum,
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
    -- Jitter out, like lost, is counted on a month with no collection: one
    -- collecting month, then quiet. Its amount is that one month's money.
    MAX(w.collected_cases_jitter_out_count)               AS collected_cases_jitter_out_count,

    MAX(w.cases_on_book_count)                          AS cases_on_book_count,
    MAX(w.cases_never_collected_count)                 AS cases_never_collected_count,
    MAX(w.cases_ever_collected_count)                AS cases_ever_collected_count,
    SUM(w.case_collections_euro)                        AS collected_cases_amount_sum,
    SUM(w.case_first_collection_euro)                   AS collected_cases_first_collection_amount_sum,
    SUM(w.case_three_consecutive_euro)                  AS collected_cases_three_consecutive_months_amount_sum,
    SUM(w.case_jitter_in_euro)                          AS collected_cases_jitter_in_amount_sum,
    SUM(w.case_new_euro)                                AS collected_cases_new_amount_sum,
    SUM(w.case_lost_last_month_euro)                    AS collected_cases_lost_last_month_amount_sum,
    SUM(w.case_jitter_out_last_month_euro)              AS collected_cases_jitter_out_last_month_amount_sum,
    -- Case windows: window sum / months in case window = the KPI's average.
    MAX(w.collected_cases_l1m)                      AS collected_cases_l1m_sum,
    MAX(w.collected_cases_l3m)                      AS collected_cases_l3m_sum,
    MAX(w.collected_cases_l6m)                      AS collected_cases_l6m_sum,
    MAX(w.collected_cases_l12m)                     AS collected_cases_l12m_sum,
    MAX(w.collected_cases_first_collection_l1m)     AS collected_cases_first_collection_l1m_sum,
    MAX(w.collected_cases_first_collection_l3m)     AS collected_cases_first_collection_l3m_sum,
    MAX(w.collected_cases_first_collection_l6m)     AS collected_cases_first_collection_l6m_sum,
    MAX(w.collected_cases_first_collection_l12m)    AS collected_cases_first_collection_l12m_sum,
    MAX(w.collected_cases_three_consecutive_months_l1m)        AS collected_cases_three_consecutive_months_l1m_sum,
    MAX(w.collected_cases_three_consecutive_months_l3m)        AS collected_cases_three_consecutive_months_l3m_sum,
    MAX(w.collected_cases_three_consecutive_months_l6m)        AS collected_cases_three_consecutive_months_l6m_sum,
    MAX(w.collected_cases_three_consecutive_months_l12m)       AS collected_cases_three_consecutive_months_l12m_sum,
    MAX(w.collected_cases_lost_l1m)                 AS collected_cases_lost_l1m_sum,
    MAX(w.collected_cases_lost_l3m)                 AS collected_cases_lost_l3m_sum,
    MAX(w.collected_cases_lost_l6m)                 AS collected_cases_lost_l6m_sum,
    MAX(w.collected_cases_lost_l12m)                AS collected_cases_lost_l12m_sum,
    MAX(w.collected_cases_new_l1m)                  AS collected_cases_new_l1m_sum,
    MAX(w.collected_cases_new_l3m)                  AS collected_cases_new_l3m_sum,
    MAX(w.collected_cases_new_l6m)                  AS collected_cases_new_l6m_sum,
    MAX(w.collected_cases_new_l12m)                 AS collected_cases_new_l12m_sum,
    MAX(w.cases_on_book_l1m)                        AS cases_on_book_l1m_sum,
    MAX(w.cases_on_book_l3m)                        AS cases_on_book_l3m_sum,
    MAX(w.cases_on_book_l6m)                        AS cases_on_book_l6m_sum,
    MAX(w.cases_on_book_l12m)                       AS cases_on_book_l12m_sum,
    SUM(w.collected_cases_amount_l1m)               AS collected_cases_amount_l1m_sum,
    SUM(w.collected_cases_amount_l3m)               AS collected_cases_amount_l3m_sum,
    SUM(w.collected_cases_amount_l6m)               AS collected_cases_amount_l6m_sum,
    SUM(w.collected_cases_amount_l12m)              AS collected_cases_amount_l12m_sum,
    MAX(w.months_in_case_l3m_window)                AS months_in_case_l3m_window,
    MAX(w.months_in_case_l6m_window)                AS months_in_case_l6m_window,
    MAX(w.months_in_case_l12m_window)               AS months_in_case_l12m_window,

    MAX(w.months_since_acquisition)                     AS months_since_capex,


    MAX(w.month_end) OVER (PARTITION BY w.portfolio)     AS latest_reporting_month,

    MAX(IFF(w.servicer_forecast_euro IS NOT NULL, 1, 0)) = 1   AS have_servicer_forecast_flag,
    MAX(IFF(w.accounting_forecast_euro IS NOT NULL, 1, 0)) = 1 AS have_accounting_forecast_flag,
    MAX(IFF(w.underwriting_forecast_euro IS NOT NULL, 1, 0)) = 1 AS have_underwriting_forecast_flag,
    MAX(w.feed_stopped_flag) = 1                               AS feed_stopped_flag,
    MAX(w.have_loan_detail_flag) = 1                           AS have_loan_detail_flag,
    COUNT(DISTINCT w.original_currency) > 1                    AS is_multi_currency_flag,
    MAX(w.cat_month_coverage_pct)                              AS case_month_coverage_pct,
    MIN(w.month_reconciled_flag) = 1                           AS is_reconciled_flag,
    -- The same flag in words, for the Reconciliation control: a viewer reads
    -- 'Reconciled' / 'Not reconciled', never None / False / True.
    IFF(MIN(w.month_reconciled_flag) = 1, 'Reconciled', 'Not reconciled') AS reconciliation_status,

    -- Data status, the same on every row: a text element can show raw SQL
    -- columns, so the header reads these directly.
    MAX(ms.data_as_of_month)                                   AS data_as_of_month,
    MAX(ms.data_as_of_portfolio_count)                         AS data_as_of_portfolio_count,
    MAX(ms.loading_month)                                      AS loading_month,
    COALESCE(MAX(lmc.loading_month_portfolio_count), 0)        AS loading_month_portfolio_count

FROM aggregated_metrics AS w
CROSS JOIN last_complete_month AS lcm
CROSS JOIN fx_base AS fw
CROSS JOIN month_status AS ms
LEFT JOIN loading_month_count AS lmc
    ON lmc.loading_month = ms.loading_month
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS dd
    ON dd.deal_sk = w.deal_sk
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
    ON ds.deal_source_sk = w.deal_source_sk
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON lb.legal_buyer_sk = w.legal_buyer_sk
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = w.country_code
WHERE w.month_end <= lcm.month_end
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15