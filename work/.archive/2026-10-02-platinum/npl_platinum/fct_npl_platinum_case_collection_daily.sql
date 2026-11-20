/*
PLATINUM. Every loan-level collection, at the day it landed. ONE ROW PER
(PORTFOLIO_SK, CASE_BK, COLLECTION_DATE, CURRENCY_ID). ~33.5m rows, collapsed
from 134,171,285 raw rows -- a 4x compression, because a loan often has several
postings on one day.

THIS IS THE BASE OF THE LOAN-LEVEL CHAIN:
  fct_npl_platinum_case_collection_daily     <- you are here
    -> agg_npl_platinum_case_collection_monthly   (per loan per month, + flags)
      -> agg_npl_platinum_case_payer_monthly      (per portfolio per month)
Nothing downstream reads the raw fact again, so the 134m-row scan happens once.

⚠⚠ COUNTED AND KEYED ON CASE_BK, NEVER CASE_SK. CASE_SK is an SCD version key --
6.84 versions per loan, one loan has 1,854 -- so keying on it splits a loan's
history across versions and inflates any loan count several-fold.
⚠ THE JOIN TO DIM_NPL_CASE IS ON CASE_SK *WITHOUT* is_current_flag, deliberately:
the fact carries the version in force at the collection, which is point-in-time
correct. Adding the flag would discard every collection made under an older
version of the loan.

⚠⚠ COLLECTION DATES IN THE YEAR 4570 EXIST IN THIS WAREHOUSE. The upper bound
below is not decoration -- without it the date spine runs to the 46th century.
⚠ THE CURRENT MONTH IS EXCLUDED, so a part-month cannot read as a collapse
against a full one. The newest month present is always complete.

⚠⚠⚠ COLLECTIONS_EUR HERE USES THE *DAILY* RATE AND MUST NOT BE SUMMED TO A
MONTH. The monthly model converts from local currency at the MONTHLY AVERAGE,
which is the rate every other platinum aggregate uses, so summing this column
across a month gives a different -- and inconsistent -- answer. For anything at
month grain or coarser, read agg_npl_platinum_case_collection_monthly.

⚠ THE DAILY RATE IS FORWARD-FILLED across weekends and holidays, and starts
2018-01-02. Collections run from 2014-06-24, so the earliest four years have no
daily rate at all and COLLECTIONS_EUR is NULL there. HAS_FX_FLAG says which.

⚠⚠ EUR IS NOT A CONVERSION -- rate 1 -- and must NOT come from the rate table,
which holds no EUR->EUR row and starts 2018 besides. It is hard-coded below.
Leaving EUR to the join nulls the EUR column on the largest currency in the
book, silently.
*/

WITH fx_rates_daily AS (
    -- ⚠ 'EUR', UPPERCASE, IS THE LITERAL. Lower-case matches nothing and
    -- silently empties this CTE, and with it every EUR column.
    SELECT
        quote_currency                                 AS currency_id,
        date_day                                       AS rate_date,
        rate                                           AS rate_daily,
        is_forward_filled
    FROM {{ ref('fct_exchange_rate_daily') }}
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
    FROM {{ ref('fct_npl_case_collection') }} AS c
    INNER JOIN {{ ref('dim_npl_case') }} AS d
        ON d.case_sk = c.case_sk
    -- ⚠ BOTH BOUNDS MATTER -- see the header.
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
    GROUP BY 1, 2, 3, 4
)

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
