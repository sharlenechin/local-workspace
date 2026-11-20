/*
PLATINUM. ONE ROW PER (PORTFOLIO_SK, BATCH_SK) -- the level at which a book was
actually bought, twice over: once by whoever owned it before us, and once by
Brocc. 11,999 rows across 264 portfolios.

⚠⚠⚠ THIS IS NOT A REPLACEMENT FOR dim_npl_platinum_portfolio, AND JOINING IT ON
PORTFOLIO_SK ALONE WILL MULTIPLY YOUR MONEY. A portfolio averages 45 batches and
one has 3,238. Join the PORTFOLIO dim to anything keyed on portfolio_sk; join
THIS one only to something that also carries BATCH_SK, or aggregate it first.

⚠⚠ TWO ACQUISITION DATES, AND THEY ARE NOT THE SAME EVENT. This is the whole
reason the model exists:
  BROCC_ACQUISITION_DATE   when BROCC bought the bundle. A PORTFOLIO fact, so it
                           is identical on every batch of a book.
  LEGACY_ACQUISITION_DATE  when the PREVIOUS OWNER bought this batch. A BATCH
                           fact, and it ranges from 1996 to 2023.
A Heimdall book is a single One-off purchase by Brocc in December 2025 of a
bundle the seller had been assembling for nearly three decades. Both dates are
real; quoting either as "the" acquisition date of a loan is wrong without saying
which you mean.

⚠⚠ 21 OF 264 PORTFOLIOS HOLD MORE THAN ONE BATCH, and 17 of those span several
years. The widest is 325 months -- 27 years -- inside one portfolio. Measured
2026-09-24, worst first:
  HEI-CH25001-U01/2512  3,238 batches  21 years  2003-11 .. 2023-09
  HEI-SE25001-U01/2512  2,153 batches  23 years  2001-10 .. 2023-09
  HEI-DE25001-U01/2512  2,018 batches  22 years  2001-01 .. 2023-09
  HEI-FI25001-U01/2512  1,962 batches  28 years  2001-01 .. 2023-09
⚠ A 1996 batch and a 2023 batch inside one portfolio will not behave alike.
Anything that treats a Heimdall book as one vintage is averaging across decades.

⚠ THE OTHER 243 PORTFOLIOS HAVE EXACTLY ONE BATCH, so for most of the estate
this model is just the portfolio dim with a batch key bolted on.

⚠ 3 OF 11,999 BATCHES HAVE NO DIM_NPL_BATCH ROW, so their legacy columns are
NULL. HAS_BATCH_DETAIL_FLAG marks them; they are not dropped.

⚠ TWO SPANS ARE MEASURED IN THIS LAYER AND THEY ARE DIFFERENT THINGS. The 325
months quoted above is the spread of when batches first REPORTED. The portfolio
dim's LEGACY_ACQUISITION_SPAN_MONTHS is the spread of when they were BOUGHT, and
runs to 272 months. A batch can be bought long before it starts reporting.

⚠ A LOAN CAN SIT IN MORE THAN ONE BATCH -- 12,897 of 3,436,320 do (0.38%), up to
three, and 12,204 of those move between batches WITHIN one portfolio. So batch
is NOT an attribute of a case and must never be added to dim_npl_platinum_case,
which is keyed one row per loan. It lives on the collection fact, where it
belongs to the transaction rather than the loan.
*/

WITH batch_activity AS (
    -- When this batch actually reported, from the portfolio fact. The only
    -- source of a batch's reporting window.
    SELECT
        portfolio_sk,
        batch_sk,
        MIN(period_end_date)::DATE                     AS first_reported_month,
        MAX(period_end_date)::DATE                     AS last_reported_month,
        COUNT(DISTINCT period_end_date)                AS months_reported,
        COUNT(DISTINCT currency_id)                    AS currency_count,
        LISTAGG(DISTINCT currency_id, ' + ')
            WITHIN GROUP (ORDER BY currency_id)        AS currencies
    FROM {{ ref('fct_npl_portfolio_snapshot_monthly') }}
    WHERE period_end_date <= CURRENT_DATE()
    GROUP BY 1, 2
)

SELECT
    -- ---- keys. ⚠ BOTH are needed -- see the header on fan-out. -------------
    b.portfolio_sk,
    b.batch_sk,
    d.batch_bk                                         AS batch_name,

    -- ---- the book, denormalised so this model stands on its own ------------
    p.portfolio_name,
    p.vehicle,
    p.project,
    p.deal,
    p.seller_name,
    p.servicer,
    p.region,
    p.country_name,
    p.country_code,
    p.portfolio_currency,
    p.flow_type,

    -- ---- BROCC's purchase. A portfolio fact: same on every batch. ----------
    p.brocc_acquisition_date,
    p.brocc_acquisition_month,
    p.brocc_acquisition_year,

    -- ---- THE PREVIOUS OWNER's purchase. A batch fact. ----------------------
    -- ⚠ This is what varies inside a portfolio, by up to 27 years.
    d.legacy_capex_date                                AS legacy_acquisition_date,
    DATE_TRUNC('MONTH', d.legacy_capex_date)::DATE     AS legacy_acquisition_month,
    YEAR(d.legacy_capex_date)                          AS legacy_acquisition_year,
    d.legacy_capex_amount                              AS legacy_acquisition_amount,
    d.legacy_principal,
    -- How long the seller held this batch before Brocc bought the bundle.
    ROUND(DATEDIFF('DAY', d.legacy_capex_date, p.brocc_acquisition_date) / 365.25, 5)
                                                       AS legacy_held_years_before_brocc,

    -- ---- when the batch actually reported ----------------------------------
    b.first_reported_month,
    b.last_reported_month,
    b.months_reported,
    b.currencies,
    b.currency_count,

    -- ---- flags ---------------------------------------------------------------
    -- ⚠ FALSE on 9 batches with no dimension row; their legacy columns are NULL.
    d.batch_sk IS NOT NULL                             AS has_batch_detail_flag,
    -- ⚠ TRUE where the book is a bundle, so a single vintage is meaningless.
    COUNT(*) OVER (PARTITION BY b.portfolio_sk) > 1    AS is_multi_batch_portfolio_flag,
    COUNT(*) OVER (PARTITION BY b.portfolio_sk)        AS portfolio_batch_count
FROM batch_activity AS b
-- LEFT, always: a batch with no dimension row must keep its reporting history.
LEFT JOIN {{ ref('dim_npl_batch') }} AS d
    ON d.batch_sk = b.batch_sk
LEFT JOIN {{ ref('dim_npl_platinum_portfolio') }} AS p
    ON p.portfolio_sk = b.portfolio_sk
