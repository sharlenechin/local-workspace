/*
PLATINUM. Payer behaviour and loan-level cash, per portfolio per month. ONE ROW
PER (PORTFOLIO_SK, REPORTING_MONTH, CURRENCY_ID).

This is agg_npl_platinum_case_collection_monthly counted up, and nothing more.
The whole chain is:
  fct_npl_platinum_case_collection_daily        one row per loan per DAY
    -> agg_npl_platinum_case_collection_monthly one row per loan per MONTH, + flags
      -> agg_npl_platinum_case_payer_monthly    <- you are here
The 134m-row raw fact is read once, at the bottom. Nothing here touches it.

⚠⚠ THESE COUNTS ARE A FLOOR, NEVER A TOTAL. The loan feed covers roughly half of
what the servicer's portfolio report shows in EUR, because some portfolios
arrive as portfolio-level aggregates with no loan detail at all. A portfolio can
legitimately show real collections beside zero payers. Reconcile against
agg_npl_platinum_portfolio_monthly before dividing by anything here.

⚠⚠ EVERY COUNT IS COUNT(DISTINCT CASE_BK), NOT SUM OF A FLAG. The upstream flags
sit on a loan-MONTH and carry no currency, so on a month where a loan paid in
two currencies they appear on both rows. Summing them double-counts that loan;
counting distinct loans does not. This is the single easiest way to get a wrong
payer number, and it looks right.

⚠ LOST IS COUNTED AT THE MONTH IT IS OBSERVED, not the month of the last
payment. Upstream, LOST_AT_MONTH is the last paying month + 2; this model
aggregates on that column, which is why the lost leg is a separate join rather
than another flag. It is NULL near the end of the feed, where every loan would
otherwise read as lost because the data stops.

⚠ NO ACQUISITION FLOOR. Months before Brocc owned the book are included, so
"activated" means first payment EVER, not first under Brocc. Cut with
dim_npl_platinum_portfolio.BROCC_ACQUISITION_MONTH in the consumer -- knowing it
changes every activation and consistency count.

⚠ THE EUR FIGURE IS SUMMED FROM THE MONTHLY MODEL, which converts at the monthly
average. Do not rebuild it from the daily model's EUR column, which uses the
daily rate and will not agree.
*/

WITH case_collection_month AS (
    -- ⚠ NOT NAMED case_month ON PURPOSE. The model below defines a CTE of that
    -- name, and the generated Snowflake copy inlines it -- a shared name there
    -- resolves to this CTE and fails as an invalid recursive CTE. CTE names
    -- must be unique ACROSS this layer, not just within a file.
    SELECT
        portfolio_sk,
        case_bk,
        reporting_month,
        currency_id,
        collections_local_currency,
        collections_eur,
        rate_flow,
        collection_count,
        paying_days_count,
        is_activated_flag,
        is_consistent_3m_flag,
        is_new_flag,
        has_fx_flag
    FROM {{ ref('agg_npl_platinum_case_collection_monthly') }}
),

monthly_lost AS (
    -- ⚠ GROUPED ON LOST_AT_MONTH, not on the paying month -- see the header.
    -- ⚠ Currency dropped first: a loan is lost once, whatever it paid in.
    SELECT
        portfolio_sk,
        lost_at_month                                  AS reporting_month,
        COUNT(DISTINCT case_bk)                        AS paying_loans_lost_count
    FROM {{ ref('agg_npl_platinum_case_collection_monthly') }}
    WHERE lost_at_month IS NOT NULL
    GROUP BY 1, 2
),

monthly_payers AS (
    -- ⚠⚠ COUNT(DISTINCT case_bk) THROUGHOUT -- see the header on why SUM of a
    -- flag is wrong here.
    SELECT
        portfolio_sk,
        reporting_month,
        COUNT(DISTINCT case_bk)                        AS paying_loans_count,
        COUNT(DISTINCT IFF(is_activated_flag, case_bk, NULL))
                                                       AS paying_loans_activated_count,
        COUNT(DISTINCT IFF(is_consistent_3m_flag, case_bk, NULL))
                                                       AS paying_loans_consistent_3m_count,
        COUNT(DISTINCT IFF(is_new_flag, case_bk, NULL))
                                                       AS paying_loans_new_count
    FROM case_collection_month
    GROUP BY 1, 2
),

monthly_currency AS (
    -- Money, kept at currency grain so only the EUR column crosses currencies.
    SELECT
        portfolio_sk,
        reporting_month,
        currency_id,
        SUM(collections_local_currency)                AS collections_local_currency,
        SUM(collections_eur)                           AS collections_eur,
        ANY_VALUE(rate_flow)                           AS rate_flow,
        SUM(collection_count)                          AS collection_count,
        SUM(paying_days_count)                         AS paying_days_count,
        COUNT(DISTINCT case_bk)                        AS paying_loans_in_currency_count,
        BOOLAND_AGG(has_fx_flag)                       AS has_fx_flag
    FROM case_collection_month
    GROUP BY 1, 2, 3
)

SELECT
    -- ---- keys ---------------------------------------------------------------
    c.portfolio_sk,
    c.reporting_month,
    YEAR(c.reporting_month)                            AS reporting_year,
    c.currency_id,

    -- ---- money ---------------------------------------------------------------
    -- ⚠ ONLY SUM WITHIN ONE CURRENCY.
    c.collections_local_currency,
    c.collections_eur,
    c.rate_flow,
    c.collection_count,
    c.paying_days_count,
    -- Per currency, so safe to sum across the rows of one month.
    c.paying_loans_in_currency_count,

    -- ---- payer behaviour. ⚠⚠ PER PORTFOLIO-MONTH, so these REPEAT across the
    -- rows of a two-currency month. MAX them, never SUM. ----------------------
    mp.paying_loans_count,
    mp.paying_loans_activated_count,
    mp.paying_loans_consistent_3m_count,
    mp.paying_loans_new_count,
    COALESCE(ml.paying_loans_lost_count, 0)            AS paying_loans_lost_count,

    -- ⚠ FALSE means at least one currency in this month had no rate, so
    -- COLLECTIONS_EUR is short by that much.
    c.has_fx_flag
FROM monthly_currency AS c
LEFT JOIN monthly_payers AS mp
    ON mp.portfolio_sk = c.portfolio_sk
    AND mp.reporting_month = c.reporting_month
LEFT JOIN monthly_lost AS ml
    ON ml.portfolio_sk = c.portfolio_sk
    AND ml.reporting_month = c.reporting_month
