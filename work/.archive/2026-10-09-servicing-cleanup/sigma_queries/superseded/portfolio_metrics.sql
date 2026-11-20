-- ============================================================================
-- SIGMA ELEMENT 'Portfolio Metrics'. ONE ROW PER (PORTFOLIO_SK, REPORTING_MONTH).
-- The servicer's own portfolio report -- collections, costs, balance, carrying
-- value -- in EUR. This is the PAM side of the reconciliation.
-- ============================================================================
-- GRAIN     portfolio x month. reporting_month is MONTH-END. 1,860 rows
--           measured 2026-09-29, unique on (portfolio_sk, reporting_month).
-- READS     'Portfolio Information' and 'FX Table' as elements, plus two PROD
--           facts. Stays in Sigma because both facts are portfolio-grain and
--           small -- there is nothing here worth materialising.
--
-- ⚠⚠⚠ REPORTING_MONTH IS MONTH-END IN EVERY ELEMENT ON THIS PAGE, and in the
-- dbt model behind Case Metrics. Changed 2026-10-05 -- it was month-start, and
-- the FX join was already month-end, so the two now agree without conversion.
-- All of them must agree or the joins match nothing, silently and with no
-- error. ⚠ THE FX JOIN STILL USES MONTH-END INTERNALLY, because the FX element
-- is keyed on the last day of the month. The join key and the output grain are
-- different things here -- do not "align" them.
--
-- ⚠⚠⚠ SIGMA RENAMES EVERY COLUMN LEAVING AN ELEMENT: Title Case, spaces,
-- case-sensitive, so it resolves only inside double quotes. Reaching for the
-- source query's own name gives
--     SQL compilation error: invalid identifier 'PORTFOLIO_SK'
-- and the line number in that message counts lines in Sigma's EXPANDED sql,
-- not in this file.
--
-- ⚠⚠ CONVERTED PER CURRENCY, THEN SUMMED. Currency stays in the grain until
-- the FX join, so each row takes its own rate. Converting after the collapse
-- would apply one rate to a mixed total. 24 portfolio-months carry two
-- currencies and become two rows at that stage.
--
-- ⚠ carrying_sum IS NOT TRUSTED. FCT_CARRYING_AMOUNT holds an unexplained EUR
-- closing value of about -19.3 trillion, raised with the data team and still
-- open as at 2026-09-21. Check the portfolio before quoting it.
-- ============================================================================
WITH
portfolio_base AS (
    -- ⚠ DISTINCT, NOT A BARE SELECT. This feeds an INNER JOIN, so a repeated
    -- portfolio_sk would fan the fact rows out and double the money.
    -- ⚠ The drill element IS DIM_PORTFOLIO and carries no sentinel row.
    -- Measured 2026-10-02 that excludes nothing: all 264 portfolio keys in the
    -- fact have a dimension row, so EUR 0.00 is lost. Keep reading the element
    -- rather than the dimension, so every element on the page shares one scope.
    SELECT DISTINCT
        "Portfolio Sk" AS portfolio_sk,
        "Capex Date"   AS capex_date
    FROM sigma_element('Portfolio Information')
),

fx_rates AS (
    -- ⚠ BOTH RATES, unlike sigma_forecasts which only needs the flow rate.
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
    SELECT
        f.portfolio_sk,
        f.period_end_date,
        f.currency_id,
        COUNT(DISTINCT f.batch_sk)                     AS batch_count,

        -- ---- flows. Take rate_flow. --------------------------------------
        SUM(f.gross_cash_recoveries)                   AS collections_local,
        SUM(f.net_cash_recoveries)                     AS net_collections_local,
        -- ⚠ Sign-flipped at source; negated so a cost reads positive.
        -SUM(f.commission)                             AS servicer_commission_local,
        -SUM(f.portfolio_mgmt_fee)                     AS servicer_mgmt_fee_local,
        -SUM(f.passthrough_cost)                       AS servicer_passthrough_local,
        SUM(f.gross_cash_recoveries - f.net_cash_recoveries)
                                                       AS servicer_cost_total_local,

        -- ---- stocks. Take rate_stock. ------------------------------------
        SUM(f.total_balance)                           AS balance_local,
        -- ANY_VALUE, not SUM: carrying_amount_base is already 1:1 to this
        -- grain, and the fact has many batch rows per portfolio-month-currency.
        ANY_VALUE(ca.carrying_local)                   AS carrying_local
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    INNER JOIN portfolio_base AS p
        ON p.portfolio_sk = f.portfolio_sk
    LEFT JOIN carrying_amount_base AS ca
        ON ca.portfolio_sk = f.portfolio_sk
        AND ca.period_end_date = f.period_end_date
        AND ca.currency_id = f.currency_id
    -- ⚠ NO CAPEX DATE MEANS KEEP IT: a NULL fails the test and would take the
    -- whole portfolio with it.
    WHERE (p.capex_date IS NULL
           OR f.period_end_date >= DATE_TRUNC('MONTH', p.capex_date))
      AND f.period_end_date <= CURRENT_DATE()
    -- ⚠ THREE KEYS: portfolio, month AND CURRENCY. Dropping currency here would
    -- collapse the two-currency months before the rate is applied.
    GROUP BY 1, 2, 3
)

SELECT
    c.portfolio_sk,
    c.period_end_date                            AS reporting_month,
    YEAR(c.period_end_date)                        AS reporting_year,

    -- 'EUR', or 'EUR + SEK' where a portfolio-month carries two.
    LISTAGG(DISTINCT c.currency_id, ' + ')
        WITHIN GROUP (ORDER BY c.currency_id)      AS portfolio_original_currency,
    COUNT(DISTINCT c.currency_id)                  AS portfolio_currency_count,
    -- ⚠ Owned here because it is a fact about this row; the reconciliation
    -- should not have to read a currency column just to derive it.
    COUNT(DISTINCT c.currency_id) > 1              AS is_multi_currency_flag,
    -- A batch reports in one currency, so summing across them does not
    -- double-count. Would only overstate if one batch ever reported in two.
    SUM(c.batch_count)                             AS batch_count,

    -- ---- EUR flows. rate_flow, applied per currency then summed. ---------
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

    -- ---- EUR stocks. rate_stock, never rate_flow. -----------------------
    SUM(c.balance_local              * fx.rate_stock)
                                                   AS balance_sum,
    -- ⚠ NOT TRUSTED -- see the header.
    SUM(c.carrying_local             * fx.rate_stock)
                                                   AS carrying_sum,

    -- ---- local currency, for the reconciliation ONLY ---------------------
    -- ⚠ NOT MONEY. Only ever sum these WITHIN ONE CURRENCY: an 'EUR + SEK'
    -- month adds two currencies together. Read collections_sum for money.
    SUM(c.collections_local)                       AS collections_local_currency,
    SUM(c.balance_local)                           AS balance_local_currency,

    -- FALSE means a currency had no rate that month, so the EUR columns above
    -- are short by that row. Two flags because the two rates can differ in
    -- coverage. ⚠ FILTER ON THESE BEFORE QUOTING A TOTAL -- before the
    -- 2026-09-29 FX fix they were FALSE on every non-EUR row.
    MIN(IFF(fx.rate_flow  IS NOT NULL, 1, 0)) = 1  AS has_fx_flow_flag,
    MIN(IFF(fx.rate_stock IS NOT NULL, 1, 0)) = 1  AS has_fx_stock_flag
FROM financials_by_currency AS c
-- ⚠ THE CONVERSION. One rate pair per (currency, month), joined at the grain
-- where a row has exactly one currency. ⚠ MONTH-END on both sides.
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = c.currency_id
    AND fx.reporting_month = c.period_end_date
GROUP BY 1, 2, 3
