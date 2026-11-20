-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/agg_npl_platinum_portfolio_monthly.sql
--   this   : the same model with every {{ ref() }} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/agg_npl_platinum_portfolio_monthly.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
-- ============================================================================

/*
WHAT THIS IS. The servicer's own monthly report on each portfolio, added up to
ONE ROW PER PORTFOLIO, PER MONTH, PER CURRENCY. Every money figure appears
twice: in the currency the country reports in, and converted to euros. The month
is labelled with its FIRST day.

⚠ THIS IS THE CASH FIGURE OF RECORD. A second model,
agg_npl_platinum_case_payer_monthly, builds the same money up loan by loan. It
only reaches about half the euro total, because some portfolios are delivered as
a single portfolio-level number with no loan detail behind them. Where the two
disagree, THIS is the money and that one is the detail.

⚠⚠ CURRENCY IS PART OF WHAT MAKES A ROW, ON PURPOSE. 24 portfolio-months are
reported in two currencies at once. Splitting those into separate rows means
each row has exactly one exchange rate applied to it, which is the only way the
conversion can be correct. Adding the rows back together is the reader's job,
and ONLY the euro columns may be added across currencies.
⚠⚠ NEVER ADD UP A LOCAL-CURRENCY COLUMN ACROSS DIFFERENT CURRENCIES -- that is
adding kronor to zloty. Six appear here: SEK, EUR, PLN, DKK, CHF and GBP.

⚠⚠ THERE ARE TWO EXCHANGE RATES AND USING THE WRONG ONE IS AN ERROR, NOT A
ROUNDING DIFFERENCE.
  RATE_FLOW   the AVERAGE rate across the month. For money that MOVED during the
              month: collections, commission, fees, passthrough costs.
  RATE_STOCK  the rate on the LAST DAY of the month. For money SITTING there at
              month end: balance, carrying amount.
For Swedish kronor the two differ by 0.87% on average, and by as much as 1.70%
in a single month.

⚠⚠ THE RATE TABLE IS KEYED ON THE LAST DAY OF THE MONTH WHILE THIS MODEL OUTPUTS
THE FIRST. The join at the bottom deliberately uses the last day. If anyone
"tidies" it so both sides use the same day, nothing matches, NO ERROR IS RAISED,
and every euro column silently comes back empty.

⚠⚠ REPEATED MONTHS ARE ALREADY REMOVED UPSTREAM. The servicer re-sends a month
whenever it revises it, so the same month can arrive several times over. The
model feeding this one keeps only the newest version of each month, which is why
the batches here can simply be added up. The FORECAST models are not cleaned
that way and still need that step -- do not copy this model's approach into them.

⚠⚠ COSTS ARRIVE FROM THE SERVICER AS NEGATIVE NUMBERS, and are flipped here so
that a cost reads as a positive amount.
⚠ SERVICER_COST_TOTAL IS GROSS MINUS NET -- NOT commission plus management fee
plus passthrough. Rebuilding it by adding those three together lands about
EUR 6.0m too high across the book, because execution fee, performance fee and
VAT are also deducted and are not itemised here. Do not "simplify" it into a sum
of its parts.

⚠ THE CARRYING AMOUNT IS NOT TRUSTED. Its source table holds an unexplained
closing value of roughly MINUS EUR 19.3 TRILLION somewhere in it. Raised with the
data team and still open as at 2026-09-24. The column is carried so the model is
complete, not because the number can be quoted.

⚠ THERE IS NO CUT-OFF AT THE PURCHASE DATE. This is the servicer's FULL history,
including the months before Brocc owned the book -- roughly eleven times as much
cash as Brocc's own. That is deliberate. Cut it in whatever reads this model,
using BROCC_ACQUISITION_MONTH on dim_npl_platinum_portfolio, so the decision is
visible to the reader rather than buried in here.
*/

WITH fx_rates AS (
    -- ⚠ THE CURRENCY CODE IS STORED IN CAPITALS in both tables. Writing 'eur'
    -- here would match nothing, empty this whole block, and with it every euro
    -- column in the output. No error would be raised.
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

    -- ⚠ EUROS DO NOT NEED CONVERTING -- the rate is 1, by definition. So this
    -- part must NOT look the rate up in the exchange-rate table, which only
    -- begins in January 2018. Doing so would discard every euro month before
    -- then for the sake of a number we already know.
    SELECT DISTINCT
        'EUR',
        period_end_date,
        1,
        1
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

carrying_amount AS (
    -- Added up to one row per portfolio, month and currency FIRST. If this
    -- source ever starts holding more than one row per combination, the join
    -- further down would otherwise duplicate the portfolio's money.
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
        portfolio_sk,
        period_end_date,
        currency_id,
        COUNT(DISTINCT batch_sk)                       AS batch_count,

        -- ---- money that MOVED during the month. Converts at RATE_FLOW. ------
        SUM(gross_cash_recoveries)                     AS collections_local_currency,
        SUM(net_cash_recoveries)                       AS net_collections_local_currency,
        -- ⚠ Arrives negative from the servicer; flipped so a cost reads positive.
        -SUM(commission)                               AS servicer_commission_local_currency,
        -SUM(portfolio_mgmt_fee)                       AS servicer_mgmt_fee_local_currency,
        -SUM(passthrough_cost)                         AS servicer_passthrough_local_currency,
        SUM(gross_cash_recoveries - net_cash_recoveries)
                                                       AS servicer_cost_total_local_currency,

        -- ---- money SITTING there at month end. Converts at RATE_STOCK. ------
        SUM(total_balance)                             AS balance_local_currency
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    -- ⚠ This only keeps out months in the FUTURE. It does NOT cut the history
    -- back to when Brocc bought the book -- see the header.
    WHERE period_end_date <= CURRENT_DATE()
    GROUP BY 1, 2, 3
)

SELECT
    -- ---- keys ---------------------------------------------------------------
    p.portfolio_sk,
    DATE_TRUNC('MONTH', p.period_end_date)::DATE       AS reporting_month,
    YEAR(p.period_end_date)                            AS reporting_year,
    p.currency_id,
    p.batch_count,

    -- ---- in the currency the country reports in.
    -- ⚠ ONLY ADD THESE UP WITHIN A SINGLE CURRENCY. -------------------------
    p.collections_local_currency,
    p.net_collections_local_currency,
    p.servicer_commission_local_currency,
    p.servicer_mgmt_fee_local_currency,
    p.servicer_passthrough_local_currency,
    p.servicer_cost_total_local_currency,
    p.balance_local_currency,
    ca.carrying_local_currency,

    -- ---- the same money in euros. Moved-during-the-month, so RATE_FLOW. ----
    p.collections_local_currency          * fx.rate_flow  AS collections_eur,
    p.net_collections_local_currency      * fx.rate_flow  AS net_collections_eur,
    p.servicer_commission_local_currency  * fx.rate_flow  AS servicer_commission_eur,
    p.servicer_mgmt_fee_local_currency    * fx.rate_flow  AS servicer_mgmt_fee_eur,
    p.servicer_passthrough_local_currency * fx.rate_flow  AS servicer_passthrough_eur,
    p.servicer_cost_total_local_currency  * fx.rate_flow  AS servicer_cost_total_eur,

    -- ---- sitting at month end, so RATE_STOCK. Never RATE_FLOW here. --------
    p.balance_local_currency              * fx.rate_stock AS balance_eur,
    -- ⚠ NOT TRUSTED. Read the carrying-amount warning in the header before
    -- quoting this to anyone.
    ca.carrying_local_currency            * fx.rate_stock AS carrying_eur,

    fx.rate_flow,
    fx.rate_stock,

    -- ⚠ TWO SEPARATE FLAGS, BECAUSE THE TWO RATES CAN GO MISSING SEPARATELY.
    -- FALSE means the matching euro columns are EMPTY -- which is NOT the same
    -- as zero. The month is real and its local-currency figures are real; only
    -- the conversion into euros is missing.
    fx.rate_flow IS NOT NULL                           AS has_fx_flow_flag,
    fx.rate_stock IS NOT NULL                          AS has_fx_stock_flag
FROM portfolio_monthly AS p
LEFT JOIN carrying_amount AS ca
    ON ca.portfolio_sk = p.portfolio_sk
    AND ca.period_end_date = p.period_end_date
    AND ca.currency_id = p.currency_id
-- ⚠ THE CONVERSION ITSELF. Joins on the LAST day of the month even though the
-- output is labelled with the first. Read the header before changing this.
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = p.currency_id
    AND fx.month_end = p.period_end_date
