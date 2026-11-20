-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/agg_npl_platinum_case_payer_monthly.sql
--   this   : the same model with every {{ ref() }} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/agg_npl_platinum_case_payer_monthly.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
-- ⚠⚠ fct_npl_platinum_case_collection_daily IS INLINED AS A CTE BELOW, because it is not a table yet.
-- Inlined ONCE however many times the model refs it, so the scan is not
-- repeated -- but this still runs slower than the dbt version, which
-- reads it as a materialised table. Expected, not a bug.
-- ⚠⚠ agg_npl_platinum_case_collection_monthly IS INLINED AS A CTE BELOW, because it is not a table yet.
-- Inlined ONCE however many times the model refs it, so the scan is not
-- repeated -- but this still runs slower than the dbt version, which
-- reads it as a materialised table. Expected, not a bug.
-- ============================================================================

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

WITH fx_rates_daily AS (
    -- ⚠ 'EUR', UPPERCASE, IS THE LITERAL. Lower-case matches nothing and
    -- silently empties this CTE, and with it every EUR column.
    SELECT
        quote_currency                                 AS currency_id,
        date_day                                       AS rate_date,
        rate                                           AS rate_daily,
        is_forward_filled
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_DAILY
    WHERE base_currency = 'EUR'
      AND rate_type = 'PMI'
      AND quote_currency <> 'EUR'
),

case_collection AS (
    -- The ONLY read of the 134m-row collection fact in this whole layer.
    SELECT
        c.portfolio_sk,
        d.case_bk,
        c.collection_date::DATE                        AS collection_date,
        c.currency_id,
        SUM(c.amount)                                  AS collections_local_currency,
        COUNT(*)                                       AS collection_count,
        -- The version in force on the day. Kept for lineage, never for counting.
        ANY_VALUE(c.case_sk)                           AS case_sk
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN PROD.NPL_COMMON.DIM_CASE AS d
        ON d.case_sk = c.case_sk
    -- ⚠ BOTH BOUNDS MATTER -- see the header.
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
    GROUP BY 1, 2, 3, 4
),

fct_npl_platinum_case_collection_daily AS (
SELECT
    -- ---- keys ---------------------------------------------------------------
    c.portfolio_sk,
    c.case_bk,
    c.collection_date,
    c.currency_id,
    DATE_TRUNC('MONTH', c.collection_date)::DATE       AS collection_month,

    -- ---- money ---------------------------------------------------------------
    -- ⚠ ONLY SUM WITHIN ONE CURRENCY.
    c.collections_local_currency,
    -- ⚠⚠ DAILY RATE. DO NOT SUM THIS TO A MONTH -- see the header.
    -- ⚠ EUR TAKES 1, not a lookup -- see the header.
    c.collections_local_currency
        * IFF(c.currency_id = 'EUR', 1, fx.rate_daily) AS collections_eur,
    IFF(c.currency_id = 'EUR', 1, fx.rate_daily)       AS rate_daily,
    c.collection_count,

    -- ---- lineage ---------------------------------------------------------------
    c.case_sk,

    -- ---- flags -----------------------------------------------------------------
    -- ⚠ FALSE before 2018-01-02, where no daily rate exists at all. Always TRUE
    -- on EUR, which needs no rate.
    c.currency_id = 'EUR' OR fx.rate_daily IS NOT NULL AS has_fx_flag,
    -- ⚠ TRUE where the rate was carried over a weekend or holiday rather than
    -- quoted that day. Normal; worth knowing before quoting a single day.
    COALESCE(fx.is_forward_filled, FALSE)              AS is_forward_filled_rate_flag
FROM case_collection AS c
LEFT JOIN fx_rates_daily AS fx
    ON fx.currency_id = c.currency_id
    AND fx.rate_date = c.collection_date

),

fx_rates AS (
    -- ⚠ 'EUR', UPPERCASE, IS THE LITERAL IN BOTH TABLES.
    SELECT
        quote_currency                                 AS currency_id,
        date_day                                       AS month_end,
        monthly_avg                                    AS rate_flow
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
        1
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
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
    FROM fct_npl_platinum_case_collection_daily
    GROUP BY 1, 2, 3, 4
),

case_month AS (
    -- ⚠ CURRENCY DROPPED. A loan that paid is a loan that paid; keeping currency
    -- here would make a two-currency loan look like two payers.
    SELECT
        portfolio_sk,
        case_bk,
        collection_month
    FROM fct_npl_platinum_case_collection_daily
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
),

agg_npl_platinum_case_collection_monthly AS (
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

),

case_collection_month AS (
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
    FROM agg_npl_platinum_case_collection_monthly
),

monthly_lost AS (
    -- ⚠ GROUPED ON LOST_AT_MONTH, not on the paying month -- see the header.
    -- ⚠ Currency dropped first: a loan is lost once, whatever it paid in.
    SELECT
        portfolio_sk,
        lost_at_month                                  AS reporting_month,
        COUNT(DISTINCT case_bk)                        AS paying_loans_lost_count
    FROM agg_npl_platinum_case_collection_monthly
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
