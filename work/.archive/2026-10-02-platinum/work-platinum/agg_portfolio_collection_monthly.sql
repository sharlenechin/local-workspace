-- ============================================================================
-- PLATINUM. The servicer's own portfolio report, rolled to the month. One row
-- per (PORTFOLIO_SK, REPORTING_MONTH, CURRENCY_ID), euro and local currency.
-- GRAIN: reporting_month is MONTH-START. PROD.
-- ============================================================================
-- THIS IS THE AUTHORITATIVE CASH FIGURE. agg_case_collection_monthly is the
-- loan-by-loan view of the same money and covers only about half of it in euro,
-- because some portfolios arrive as portfolio-level aggregates. When the two
-- disagree, THIS one is the money and the other is the detail.
--
-- ⚠⚠ CURRENCY IS IN THE GRAIN. 24 portfolio-months carry two currencies; each
-- becomes its own row so its rate applies cleanly. NEVER SUM A
-- _LOCAL_CURRENCY COLUMN across rows of different currency.
--
-- ⚠⚠ TWO RATES, AND THEY ARE NOT INTERCHANGEABLE.
--   RATE_FLOW   monthly average -- collections, commission, fees, passthrough.
--   RATE_STOCK  month-end close -- balance, carrying amount.
-- They differ by 0.87% on average for SEK and up to 1.70% in a single month, so
-- using the wrong one is wrong, not approximate.
--
-- ⚠ THE FX JOIN USES MONTH-END WHILE THE OUTPUT IS MONTH-START. Deliberate --
-- see agg_case_collection_monthly's header for the same note.
--
-- ⚠⚠ ALREADY DEDUPED UPSTREAM. The golden model keeps the newest
-- SNAPSHOT_VERSION per (period_end_date, batch_sk), so summing batches is
-- additive and no QUALIFY is needed here -- unlike the forecast facts, which
-- are not deduped and do need one.
--
-- ⚠⚠ COSTS ARE SIGN-FLIPPED AT SOURCE and are negated here so a cost reads
-- POSITIVE. SERVICER_COST_TOTAL is gross minus net, NOT the sum of commission,
-- management fee and passthrough -- rebuilding it that way lands about EUR 6.0m
-- high across the book, because execution fee, performance fee and VAT come off
-- too. Do not "simplify" it into a sum of parts.
--
-- ⚠ CARRYING AMOUNT IS NOT TRUSTED. FCT_CARRYING_AMOUNT holds an unexplained
-- EUR closing value of about -19.3 trillion somewhere in it, raised with the
-- data team and open as at 2026-09-22. Carried for completeness; check the
-- portfolio before quoting it.
--
-- ⚠ NO CAPEX FLOOR HERE. This is the full servicer history, including months
-- before Brocc owned the book -- which is roughly eleven times the cash. Cut it
-- with DIM_PORTFOLIO.CAPEX_DATE (or dim_portfolio_case.CAPEX_MONTH) in the
-- consumer, deliberately, rather than having it cut invisibly here.
-- ============================================================================
WITH fx_rates AS (
    -- ⚠ 'EUR', UPPERCASE, IS THE LITERAL IN BOTH TABLES.
    SELECT
        quote_currency                                 AS currency_id,
        date_day                                       AS month_end,
        monthly_avg                                    AS rate_flow,
        ultimo_value                                   AS rate_stock
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR'
      AND rate_type = 'PMI'
      AND quote_currency <> 'EUR'

    UNION ALL

    -- ⚠ EUR IS NOT A CONVERSION -- rate 1 -- so it must not depend on the FX
    -- table's coverage, which only starts 2018-01-31.
    SELECT DISTINCT
        'EUR',
        period_end_date,
        1,
        1
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

carrying_amount AS (
    -- Grouped so the join cannot fan out if the grain ever changes.
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(closing_value)::NUMBER(38, 6)              AS carrying_local_currency
    FROM PROD.NPL_COMMON.FCT_CARRYING_AMOUNT
    WHERE period_end_date <= CURRENT_DATE()
    GROUP BY 1, 2, 3
),

portfolio_monthly AS (
    SELECT
        f.portfolio_sk,
        f.period_end_date,
        f.currency_id,
        COUNT(DISTINCT f.batch_sk)                     AS batch_count,

        -- ---- flows. Take RATE_FLOW. ----------------------------------------
        SUM(f.gross_cash_recoveries)                   AS collections_local_currency,
        SUM(f.net_cash_recoveries)                     AS net_collections_local_currency,
        -- ⚠ Sign-flipped at source; negated so a cost reads positive.
        -SUM(f.commission)                             AS servicer_commission_local_currency,
        -SUM(f.portfolio_mgmt_fee)                     AS servicer_mgmt_fee_local_currency,
        -SUM(f.passthrough_cost)                       AS servicer_passthrough_local_currency,
        SUM(f.gross_cash_recoveries - f.net_cash_recoveries)
                                                       AS servicer_cost_total_local_currency,

        -- ---- stocks. Take RATE_STOCK. --------------------------------------
        SUM(f.total_balance)                           AS balance_local_currency
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    -- ⚠ Guards against future-dated rows only. No capex floor -- see header.
    WHERE f.period_end_date <= CURRENT_DATE()
    GROUP BY 1, 2, 3
)

SELECT
    -- ---- keys -------------------------------------------------------------
    p.portfolio_sk,
    DATE_TRUNC('MONTH', p.period_end_date)::DATE       AS reporting_month,
    YEAR(p.period_end_date)                            AS reporting_year,
    p.currency_id,
    p.batch_count,

    -- ---- local currency. ⚠ ONLY SUM WITHIN ONE CURRENCY. ------------------
    p.collections_local_currency,
    p.net_collections_local_currency,
    p.servicer_commission_local_currency,
    p.servicer_mgmt_fee_local_currency,
    p.servicer_passthrough_local_currency,
    p.servicer_cost_total_local_currency,
    p.balance_local_currency,
    ca.carrying_local_currency,

    -- ---- euro. Flows take RATE_FLOW. --------------------------------------
    p.collections_local_currency          * fx.rate_flow  AS collections_eur,
    p.net_collections_local_currency      * fx.rate_flow  AS net_collections_eur,
    p.servicer_commission_local_currency  * fx.rate_flow  AS servicer_commission_eur,
    p.servicer_mgmt_fee_local_currency    * fx.rate_flow  AS servicer_mgmt_fee_eur,
    p.servicer_passthrough_local_currency * fx.rate_flow  AS servicer_passthrough_eur,
    p.servicer_cost_total_local_currency  * fx.rate_flow  AS servicer_cost_total_eur,

    -- ---- euro. Stocks take RATE_STOCK, never RATE_FLOW. -------------------
    p.balance_local_currency              * fx.rate_stock AS balance_eur,
    -- ⚠ NOT TRUSTED -- see the header before quoting this.
    ca.carrying_local_currency            * fx.rate_stock AS carrying_eur,

    fx.rate_flow,
    fx.rate_stock,

    -- ⚠ Two flags because the two rates can differ in coverage. FALSE means
    -- the matching euro columns are NULL.
    fx.rate_flow IS NOT NULL                           AS has_fx_flow_flag,
    fx.rate_stock IS NOT NULL                          AS has_fx_stock_flag
FROM portfolio_monthly AS p
LEFT JOIN carrying_amount AS ca
    ON ca.portfolio_sk = p.portfolio_sk
    AND ca.period_end_date = p.period_end_date
    AND ca.currency_id = p.currency_id
-- ⚠ THE CONVERSION. Month-END key, month-START output -- see the header.
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = p.currency_id
    AND fx.month_end = p.period_end_date
