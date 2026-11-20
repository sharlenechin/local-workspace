WITH
portfolio_base AS (
    -- ⚠ DISTINCT, NOT A BARE SELECT. This feeds an INNER JOIN, so a repeated
    -- portfolio_sk would fan the fact rows out and double the money.
    -- The drill element carries the sentinel row for fact rows with no
    -- dimension row -- 6.38% of collections. Do not swap it for DIM_PORTFOLIO.
    SELECT DISTINCT
        "Portfolio Sk" AS portfolio_sk,
        "Capex Date"   AS capex_date
    FROM sigma_element('Portfolio Information')
),

fx_rates AS (
    -- ⚠ BOTH RATES, unlike the forecasts query which only needs the flow rate.
    SELECT
        "Currency Id"     AS currency_id,
        "Reporting Month" AS reporting_month,
        "Rate Flow"       AS rate_flow,
        "Rate Stock"      AS rate_stock
    FROM sigma_element('FX Table')
),

carrying_amount_base AS (
    -- Grouped so the join cannot fan out if the grain ever changes.
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(closing_value)::NUMBER(38, 6) AS carrying_local
    FROM PROD.NPL_COMMON.FCT_CARRYING_AMOUNT
    WHERE period_end_date <= CURRENT_DATE()
    GROUP BY 1, 2, 3
),

financials_by_currency AS (
    -- ⚠ CURRENCY IS STILL IN THE GRAIN HERE. That is the whole point: the FX
    -- join below then applies a rate to a row that has exactly one currency.
    -- 24 portfolio-months carry two and become two rows at this stage.
    SELECT
        f.portfolio_sk,
        f.period_end_date,
        f.currency_id,
        COUNT(DISTINCT f.batch_sk)                     AS batch_count,

        -- ---- flows. Take RATE_FLOW. -------------------------------------
        SUM(f.gross_cash_recoveries)                   AS collections_local,
        SUM(f.net_cash_recoveries)                     AS net_collections_local,
        -- ⚠ Sign-flipped at source; negated so a cost reads positive.
        -SUM(f.commission)                             AS servicer_commission_local,
        -SUM(f.portfolio_mgmt_fee)                     AS servicer_mgmt_fee_local,
        -SUM(f.passthrough_cost)                       AS servicer_passthrough_local,
        SUM(f.gross_cash_recoveries - f.net_cash_recoveries)
                                                       AS servicer_cost_total_local,

        -- ---- stocks. Take RATE_STOCK. -----------------------------------
        SUM(f.total_balance)                           AS balance_local,
        -- ANY_VALUE, not SUM: carrying_amount_base is already 1:1 to this grain,
        -- and the fact has many batch rows per portfolio-month-currency.
        ANY_VALUE(ca.carrying_local)          AS carrying_local
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    INNER JOIN portfolio_base AS p
        ON p.portfolio_sk = f.portfolio_sk
    LEFT JOIN carrying_amount_base AS ca
        ON ca.portfolio_sk = f.portfolio_sk
        AND ca.period_end_date = f.period_end_date
        AND ca.currency_id = f.currency_id
    -- ⚠ NO CAPEX DATE MEANS KEEP IT: a NULL fails the test and would take the
    -- whole portfolio with it, the sentinel included.
    WHERE (p.capex_date IS NULL
           OR f.period_end_date >= DATE_TRUNC('MONTH', p.capex_date))
      AND f.period_end_date <= CURRENT_DATE()
    -- ⚠ THREE KEYS: portfolio, month AND CURRENCY. Dropping currency here would
    -- collapse the two-currency months before the rate is applied.
    GROUP BY 1, 2, 3
)

SELECT
    c.portfolio_sk,
    DATE_TRUNC('MONTH', c.period_end_date)         AS reporting_month,

    -- 'EUR', or 'EUR + SEK' where a portfolio-month carries two.
    LISTAGG(DISTINCT c.currency_id, ' + ')
        WITHIN GROUP (ORDER BY c.currency_id)      AS portfolio_original_currency,
    COUNT(DISTINCT c.currency_id)                  AS portfolio_currency_count,
    -- ⚠ TRUE where the month carries more than one currency. Owned here because
    -- it is a fact about this row; the reconciliation should not have to read a
    -- currency column just to derive it.
    COUNT(DISTINCT c.currency_id) > 1              AS is_multi_currency_flag,
    -- A batch reports in one currency, so summing across them does not
    -- double-count. Would only overstate if one batch ever reported in two.
    SUM(c.batch_count)                             AS batch_count,

    -- ---- EUR flows. RATE_FLOW, applied per currency then summed. ---------
    SUM(c.collections_local          * fx.rate_flow)
                                                   AS collections_sum,
    SUM(c.net_collections_local      * fx.rate_flow)
                                                   AS net_collections_sum,
    SUM(c.servicer_commission_local  * fx.rate_flow)
                                                   AS servicer_commission_sum,
    SUM(c.servicer_mgmt_fee_local    * fx.rate_flow)
                                                   AS servicer_mgmt_fee_sum,
    SUM(c.servicer_passthrough_local * fx.rate_flow)
                                                   AS servicer_passthrough_sum,
    SUM(c.servicer_cost_total_local  * fx.rate_flow)
                                                   AS servicer_cost_total_sum,

    -- ---- EUR stocks. RATE_STOCK, never RATE_FLOW. -----------------------
    SUM(c.balance_local              * fx.rate_stock)
                                                   AS balance_sum,
    -- ⚠ NOT TRUSTED. FCT_CARRYING_AMOUNT holds an unexplained EUR closing value
    -- of about -19.3 trillion, raised with the data team and open as at
    -- 2026-09-21. Check the portfolio before quoting this.
    SUM(c.carrying_local             * fx.rate_stock)
                                                   AS carrying_sum,

    -- FALSE means a currency had no rate that month, so the EUR columns above
    -- are short by that row. Two flags because the two rates can differ in
    -- coverage. Filter before quoting a total.
    MIN(IFF(fx.rate_flow  IS NOT NULL, 1, 0)) = 1  AS has_fx_flow_flag,
    MIN(IFF(fx.rate_stock IS NOT NULL, 1, 0)) = 1  AS has_fx_stock_flag
FROM financials_by_currency AS c
-- ⚠ THE CONVERSION. One rate pair per (currency, month), joined at the grain
-- where a row has exactly one currency.
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = c.currency_id
    AND fx.reporting_month = c.period_end_date
GROUP BY 1, 2
