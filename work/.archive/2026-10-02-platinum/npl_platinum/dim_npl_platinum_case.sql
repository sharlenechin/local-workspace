/*
PLATINUM. ONE ROW PER CASE_BK -- the loan -- carrying only what is STATIC, plus
the status it holds today. 22,530,117 rows.

STATUS HISTORY IS A SEPARATE MODEL, and it has to be: status changes on
11,850,345 cases (52.6%), so putting it here would either repeat every static
column on every change or force this table off its grain. Read
fct_npl_platinum_case_status for the history; read this for the loan.

⚠⚠ CASE_SK IS A VERSION KEY, CASE_BK IS THE LOAN. DIM_NPL_CASE holds
154,077,844 rows for 22,530,117 loans -- 6.84 versions each, one loan has 1,854.
IS_CURRENT_FLAG collapses it to exactly one row per CASE_BK (verified
22,530,117 = 22,530,117). CASE_SK here is the CURRENT version; a fact carrying a
historical CASE_SK will not match it, so join those on CASE_BK.

⚠⚠⚠ SERVICER_REGISTRATION_DATE IS NOT STABLE, AND THAT IS A REAL FINDING, NOT
ROUNDING. It moves across versions on 4,476,245 cases (19.9%), by an average of
1,142.7 days and a maximum of 44,088. Only 3,856 of those move within a month --
4,408,898 move by more than a year. So this is re-dating, not clock drift.
  SERVICER_REGISTRATION_DATE        the CURRENT version's value
  SERVICER_REGISTRATION_DATE_FIRST  the earliest value ever recorded
  REGISTRATION_DATE_MOVED_FLAG    TRUE where the two differ
  REGISTRATION_DATE_SPREAD_DAYS   how far it moved
⚠ A VINTAGE CUT BUILT ON THIS WILL SHIFT BETWEEN RUNS on a fifth of the book.
Decide which version you mean and say so; do not let the default decide.

⚠⚠ THE TWO REGISTRATION DATES MEAN DIFFERENT THINGS AND ARE NOT SUBSTITUTES.
  SERVICER_REGISTRATION_DATE  when the SERVICER opened the case. Not origination.
  ⚠ NAMED FOR THE ROLE, NOT THE FIRM. It was INTRUM_REGISTRATION_DATE until
  2026-09-27, which was wrong on every book Gescobro or Cerved services -- and
  5 distinct servicers appear on the REGISTRATION phase. To know WHICH servicer
  registered a given loan, read PHASE_ENTITY_NAME on dim_npl_case_history.
  BROCC_REGISTRATION_DATE   when BROCC bought the book -- the portfolio's capex
                            date. It is a PORTFOLIO fact, identical on every
                            loan in a book, and is the only Brocc-side date that
                            exists: nothing on the case records when we acquired
                            it. Derived, not stored.

⚠⚠ PORTFOLIO_SK COMES FROM THE CASE SNAPSHOT (1.47bn rows), because no case
dimension carries it. Each portfolio's own latest snapshot day is used, not one
global date -- portfolios report on different calendars and a single cut-off
would empty the ones that had not reported. ⚠ FCT_NPL_CASE_SNAPSHOT_DAILY IS
MONTH-END GRAIN DESPITE THE NAME.
⚠ A case can sit under TWO portfolios; 2,321 do. ANY_VALUE picks one so this
table keeps its grain. Use dim_npl_platinum_portfolio_case if you need the pair.

⚠⚠ BATCH_SK IS SAFE HERE, AND ONLY BECAUSE IT IS A POINT-IN-TIME ANSWER.
At each portfolio's latest snapshot day every one of 21,885,911 loans has
EXACTLY ONE batch -- zero exceptions. Across the whole history 12,897 loans
(0.38%) move between batches, so batch is an attribute of a PAYMENT, not of a
loan; the collection fact keeps its own BATCH_SK for that reason. What is
carried here is "the batch this loan sits in NOW", which is unambiguous.
⚠ So do NOT use this column to attribute historical collections. A loan that
moved batches would have its earlier payments credited to the wrong one -- and
if the two differ in vintage, to the wrong vintage year.

⚠⚠ LEGACY_ACQUISITION_YEAR IS THE BATCH'S VINTAGE, NOT THE LOAN'S. It is when
the PREVIOUS OWNER bought the bundle this loan sits in, so it is identical for
every loan in that batch. SERVICER_REGISTRATION_YEAR is the loan's own. They
answer different questions.

⚠⚠ BATCH_LEGACY_CAPEX_AMOUNT IS THE WHOLE BATCH'S PRICE, repeated on every loan
in it. NEVER SUM IT ACROSS LOANS -- that multiplies it by the loan count. Sum it
at batch grain, from dim_npl_platinum_portfolio_batch.
⚠ And it does NOT reliably equal Brocc's own capex. Measured 2026-09-27: of 263
portfolios, the portfolio's CAPEX_AMOUNT equals the sum of its batches'
LEGACY_CAPEX_AMOUNT on only 128 -- every one of them single-batch -- and differs
on the other 115 single-batch books and on all the bundles. Across the estate
Brocc capex is 3.18bn against legacy 9.31bn. Treat the two as different
transactions, because on most books they are.

⚠ STATUS CANNOT BE DECODED. STATUS_DESCRIPTION, CLOSING_CODE,
CLOSING_DESCRIPTION and CLOSING_CATEGORY are 100% NULL on all 22.5m rows, so
legal / amicable / insolvency STAGE cannot be reported from this warehouse at
all. The bare numeric code is everything there is. Do not promise a decode.

⚠ ORIGINAL_PRINCIPAL IS NOT THE OPENING BALANCE OF A PURCHASE. It is what the
servicer recorded on the case. It moves across versions on only 13,021 cases
(0.06%), so it is safe to treat as static -- but it is the servicer's figure,
not a priced acquisition principal.
*/

WITH case_current AS (
    -- ⚠ IS_CURRENT_FLAG gives exactly one row per CASE_BK -- see the header.
    SELECT
        case_bk,
        case_sk,
        case_id,
        registration_date::DATE                        AS servicer_registration_date,
        default_date::DATE                             AS reported_default_date,
        COALESCE(derived_default_date, default_date)::DATE AS default_date,
        origination_date::DATE                         AS origination_date,
        backstop_date::DATE                            AS backstop_date,
        original_principal,
        secured_flag                                   AS is_secured_flag,
        status_code                                    AS current_status_code,
        status_date::DATE                              AS current_status_date,
        reporting_system_sk,
        effective_from_date::DATE                      AS current_version_from_date
    FROM {{ ref('dim_npl_case') }}
    WHERE is_current_flag = TRUE
),

registration_history AS (
    -- ⚠ THE INSTABILITY GUARD. One pass over every version to learn how far
    -- the servicer has moved its own registration date.
    SELECT
        case_bk,
        MIN(registration_date)::DATE                   AS servicer_registration_date_first,
        MAX(registration_date)::DATE                   AS servicer_registration_date_last,
        COUNT(DISTINCT registration_date)              AS registration_date_version_count,
        COUNT(*)                                       AS version_count
    FROM {{ ref('dim_npl_case') }}
    GROUP BY 1
),

portfolio_latest_day AS (
    -- ⚠ PER PORTFOLIO. See the header on why one global date is wrong.
    SELECT
        portfolio_sk,
        MAX(date_day)                                  AS latest_day
    FROM {{ ref('fct_npl_case_snapshot_daily') }}
    GROUP BY 1
),

case_portfolio AS (
    -- ⚠ ANY_VALUE keeps the grain where a case sits under two books -- 2,321
    -- do. This is a deliberate loss of information, not an accident.
    SELECT
        s.case_sk,
        ANY_VALUE(s.portfolio_sk)                      AS portfolio_sk,
        -- ⚠ ONE BATCH PER LOAN AT THIS DAY, verified -- see the header.
        ANY_VALUE(s.batch_sk)                          AS batch_sk,
        COUNT(DISTINCT s.portfolio_sk)                 AS portfolio_count
    FROM {{ ref('fct_npl_case_snapshot_daily') }} AS s
    INNER JOIN portfolio_latest_day AS l
        ON l.portfolio_sk = s.portfolio_sk
        AND l.latest_day = s.date_day
    GROUP BY 1
)

SELECT
    -- ---- keys ---------------------------------------------------------------
    c.case_bk,
    c.case_sk,
    c.case_id,
    cp.portfolio_sk,
    -- ⚠ THE BATCH THIS LOAN SITS IN NOW -- see the header before using it for
    -- anything historical.
    cp.batch_sk,
    bt.batch_bk                                        AS batch_name,
    -- ⚠ THE BATCH'S VINTAGE, repeated on every loan in it. Not the loan's own.
    bt.legacy_capex_date::DATE                         AS legacy_acquisition_date,
    YEAR(bt.legacy_capex_date)                         AS legacy_acquisition_year,
    -- ⚠ THE WHOLE BATCH'S PRICE. Never sum across loans -- see the header.
    bt.legacy_capex_amount                             AS batch_legacy_capex_amount,
    bt.legacy_principal                                AS batch_legacy_principal,
    -- ⚠ ABOVE 1 MEANS THE LOAN SITS IN TWO BOOKS and PORTFOLIO_SK is one of
    -- two possible answers.
    COALESCE(cp.portfolio_count, 0)                    AS portfolio_count,

    -- ---- the two registration dates. NOT interchangeable -- see the header.
    c.servicer_registration_date,
    DATE_TRUNC('MONTH', c.servicer_registration_date)::DATE AS servicer_registration_month,
    YEAR(c.servicer_registration_date)                   AS servicer_registration_year,
    rh.servicer_registration_date_first,
    -- ⚠ TRUE on 19.9% of cases. A vintage cut on this book is not reproducible
    -- unless you pin which version you mean.
    rh.servicer_registration_date_first IS DISTINCT FROM c.servicer_registration_date
                                                       AS registration_date_moved_flag,
    DATEDIFF('DAY', rh.servicer_registration_date_first, c.servicer_registration_date)
                                                       AS registration_date_spread_days,
    -- ⚠ A PORTFOLIO FACT, identical on every loan in a book. Derived, not
    -- stored -- nothing on the case records when Brocc acquired it.
    p.brocc_acquisition_date                           AS brocc_registration_date,
    p.brocc_acquisition_month                          AS brocc_registration_month,
    p.brocc_acquisition_year                           AS brocc_registration_year,
    -- Negative where the servicer opened the case BEFORE Brocc bought the book,
    -- which is the normal case. NULL where either date is missing.
    DATEDIFF('MONTH', p.brocc_acquisition_month,
             DATE_TRUNC('MONTH', c.servicer_registration_date))
                                                       AS registration_months_to_acquisition,

    -- ---- other static dates ---------------------------------------------------
    -- ⚠ DERIVED where the servicer reported none; REPORTED_DEFAULT_DATE is the
    -- raw column beside it so the two can be told apart.
    c.default_date,
    DATE_TRUNC('MONTH', c.default_date)::DATE          AS default_month,
    c.reported_default_date,
    c.default_date IS NOT NULL
        AND c.reported_default_date IS NULL            AS default_date_derived_flag,
    c.origination_date,
    c.backstop_date,
    -- Years in default at the point the servicer opened the case.
    ROUND(DATEDIFF('DAY', c.default_date, c.servicer_registration_date) / 365.25, 5)
                                                       AS debt_age_years_at_registration,

    -- ---- static attributes -----------------------------------------------------
    c.original_principal,
    c.is_secured_flag,
    c.reporting_system_sk,

    -- ---- status AS AT TODAY. History is in fct_npl_platinum_case_status. -----
    -- ⚠ THE CODE IS ALL THERE IS. No description exists -- see the header.
    c.current_status_code,
    c.current_status_date,
    c.current_version_from_date,

    -- ---- provenance -------------------------------------------------------------
    rh.version_count,
    rh.registration_date_version_count
FROM case_current AS c
LEFT JOIN registration_history AS rh
    ON rh.case_bk = c.case_bk
LEFT JOIN case_portfolio AS cp
    ON cp.case_sk = c.case_sk
LEFT JOIN {{ ref('dim_npl_batch') }} AS bt
    ON bt.batch_sk = cp.batch_sk
LEFT JOIN {{ ref('dim_npl_platinum_portfolio') }} AS p
    ON p.portfolio_sk = cp.portfolio_sk
