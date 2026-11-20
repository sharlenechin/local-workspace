/*
PLATINUM. Loan-level collections rolled to the month, WITH the payer-behaviour
flags attached per loan. ONE ROW PER (PORTFOLIO_SK, CASE_BK, COLLECTION_MONTH,
CURRENCY_ID).

Reads fct_npl_platinum_case_collection_daily and nothing else -- the 134m-row
raw fact is scanned once, at the bottom of the chain, never here.
Feeds agg_npl_platinum_case_payer_monthly, which is just this counted up.

⚠⚠ A ROW EXISTS ONLY WHERE THE LOAN PAID. There is no row for a month a loan
was silent, so "did not pay" is an ABSENCE, not a zero. That is why LOST is
expressed as LOST_AT_MONTH -- a forward-dated label on the last paying row --
rather than as a flag on a row that does not exist.

⚠⚠ THE FLAGS ARE PER LOAN-MONTH AND CARRY NO CURRENCY, so on a month where a
loan paid in two currencies they REPEAT across both rows. Count them with
COUNT(DISTINCT case_bk), never SUM. Only the money columns are per currency.

⚠⚠ PREVIOUS AND NEXT ARE *PAYING* MONTHS, NOT CALENDAR MONTHS. Only 55.7% of
loan-months sit one calendar month after the last, so every flag below compares
DATES, never window positions. Rewriting any of these as a bare LAG position is
wrong and will look right.

THE FLAGS, precisely:
  IS_ACTIVATED_FLAG      first paying month this loan has ever had
  IS_CONSISTENT_3M_FLAG  paid this month, the month before, AND two before
  IS_NEW_FLAG            paid this month, and in NEITHER of the previous two
  LOST_AT_MONTH          collection_month + 2, where the loan paid in neither
                         of the next two months. NULL otherwise. Counted at
                         that month, not at this one.

⚠ IS_NEW_FLAG AND IS_ACTIVATED_FLAG ARE NOT THE SAME THING. Activated fires once
per loan, ever. New fires on every return after a two-month gap, so a loan that
stops and restarts four times is new four times and activated once.

⚠⚠ LOST_AT_MONTH IS SUPPRESSED NEAR THE END OF THE DATA. Two months after the
last month ANY loan paid, every loan would read as lost -- that is the feed
ending, not behaviour. NULL is returned there instead.

⚠⚠ THE EUR FIGURE IS RECOMPUTED FROM LOCAL CURRENCY AT THE MONTHLY AVERAGE
RATE, not summed from the daily model's EUR column. Every other platinum
aggregate uses the monthly average for flows, so this keeps them comparable.
Summing the daily EUR instead gives a different answer -- neither wrong, but
mixing them in one report is.
*/

WITH fx_rates AS (
    -- ⚠ 'EUR', UPPERCASE, IS THE LITERAL IN BOTH TABLES.
    SELECT
        quote_currency                                 AS currency_id,
        date_day                                       AS month_end,
        monthly_avg                                    AS rate_flow
    FROM {{ ref('fct_exchange_rate_monthly') }}
    WHERE base_currency = 'EUR'
      AND rate_type = 'PMI'
      AND quote_currency <> 'EUR'

    UNION ALL

    -- ⚠ EUR IS NOT A CONVERSION -- rate 1 -- so it must not depend on the FX
    -- table's coverage, which only starts 2018-01-31.
    SELECT DISTINCT
        'EUR',
        period_end_date,
        1
    FROM {{ ref('fct_npl_portfolio_snapshot_monthly') }}
),

case_month_currency AS (
    -- Money, at currency grain so each rate applies to a single-currency row.
    SELECT
        portfolio_sk,
        case_bk,
        collection_month,
        currency_id,
        SUM(collections_local_currency)                AS collections_local_currency,
        SUM(collection_count)                          AS collection_count,
        COUNT(*)                                       AS paying_days_count,
        MIN(collection_date)                           AS first_collection_date,
        MAX(collection_date)                           AS last_collection_date
    FROM {{ ref('fct_npl_platinum_case_collection_daily') }}
    GROUP BY 1, 2, 3, 4
),

case_month AS (
    -- ⚠ CURRENCY DROPPED. A loan that paid is a loan that paid; keeping currency
    -- here would make a two-currency loan look like two payers.
    SELECT
        portfolio_sk,
        case_bk,
        collection_month
    FROM {{ ref('fct_npl_platinum_case_collection_daily') }}
    GROUP BY 1, 2, 3
),

case_month_window AS (
    -- ⚠ PAYING months, not calendar months -- see the header.
    SELECT
        portfolio_sk,
        case_bk,
        collection_month,
        LAG(collection_month, 1) OVER (
            PARTITION BY portfolio_sk, case_bk ORDER BY collection_month)
                                                       AS previous_1_month,
        LAG(collection_month, 2) OVER (
            PARTITION BY portfolio_sk, case_bk ORDER BY collection_month)
                                                       AS previous_2_months,
        LEAD(collection_month, 1) OVER (
            PARTITION BY portfolio_sk, case_bk ORDER BY collection_month)
                                                       AS next_1_month,
        LEAD(collection_month, 2) OVER (
            PARTITION BY portfolio_sk, case_bk ORDER BY collection_month)
                                                       AS next_2_months
    FROM case_month
),

max_paid_month AS (
    -- The last month ANY loan paid, anywhere. See the header on suppression.
    SELECT
        MAX(collection_month)                          AS max_month
    FROM case_month
),

case_month_flags AS (
    SELECT
        w.portfolio_sk,
        w.case_bk,
        w.collection_month,
        w.previous_1_month,
        w.next_1_month,

        -- First paying month this loan has ever had.
        w.previous_1_month IS NULL                     AS is_activated_flag,

        -- Paid this month, last month AND the month before.
        COALESCE(w.previous_1_month  = DATEADD('MONTH', -1, w.collection_month), FALSE)
            AND COALESCE(w.previous_2_months = DATEADD('MONTH', -2, w.collection_month), FALSE)
                                                       AS is_consistent_3m_flag,

        -- Paid this month and in NEITHER of the previous two.
        NOT (COALESCE(w.previous_1_month  = DATEADD('MONTH', -1, w.collection_month), FALSE)
             OR COALESCE(w.previous_1_month  = DATEADD('MONTH', -2, w.collection_month), FALSE)
             OR COALESCE(w.previous_2_months = DATEADD('MONTH', -2, w.collection_month), FALSE))
                                                       AS is_new_flag,

        -- ⚠ FORWARD-DATED, and NULL near the end of the feed -- see the header.
        IFF(DATEADD('MONTH', 2, w.collection_month) <= m.max_month
            AND NOT COALESCE(w.next_1_month  = DATEADD('MONTH', 2, w.collection_month), FALSE)
            AND NOT COALESCE(w.next_2_months = DATEADD('MONTH', 2, w.collection_month), FALSE),
            DATEADD('MONTH', 2, w.collection_month)::DATE,
            NULL)                                      AS lost_at_month
    FROM case_month_window AS w
    CROSS JOIN max_paid_month AS m
)

SELECT
    -- ---- keys ---------------------------------------------------------------
    c.portfolio_sk,
    c.case_bk,
    c.collection_month                                 AS reporting_month,
    YEAR(c.collection_month)                           AS reporting_year,
    c.currency_id,

    -- ---- money. Per currency. -----------------------------------------------
    -- ⚠ ONLY SUM WITHIN ONE CURRENCY.
    c.collections_local_currency,
    -- ⚠ MONTHLY AVERAGE RATE, recomputed -- not the daily model's EUR summed.
    c.collections_local_currency * fx.rate_flow        AS collections_eur,
    fx.rate_flow,
    c.collection_count,
    c.paying_days_count,
    c.first_collection_date,
    c.last_collection_date,

    -- ---- payer behaviour. ⚠⚠ PER LOAN-MONTH: these REPEAT across the rows of
    -- a two-currency month. COUNT(DISTINCT case_bk), never SUM. ---------------
    f.is_activated_flag,
    f.is_consistent_3m_flag,
    f.is_new_flag,
    f.lost_at_month,
    f.previous_1_month                                 AS previous_paying_month,
    f.next_1_month                                     AS next_paying_month,

    -- ⚠ FALSE means no rate for that currency-month, so COLLECTIONS_EUR is
    -- NULL, not zero.
    fx.rate_flow IS NOT NULL                           AS has_fx_flag
FROM case_month_currency AS c
INNER JOIN case_month_flags AS f
    ON f.portfolio_sk = c.portfolio_sk
    AND f.case_bk = c.case_bk
    AND f.collection_month = c.collection_month
LEFT JOIN fx_rates AS fx
    ON fx.currency_id = c.currency_id
    AND fx.month_end = LAST_DAY(c.collection_month)
