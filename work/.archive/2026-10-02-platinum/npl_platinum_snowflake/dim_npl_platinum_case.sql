-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/dim_npl_platinum_case.sql
--   this   : the same model with every {{ ref() }} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/dim_npl_platinum_case.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
-- ⚠⚠ dim_npl_platinum_portfolio IS INLINED AS A CTE BELOW, because it is not a table yet.
-- Inlined ONCE however many times the model refs it, so the scan is not
-- repeated -- but this still runs slower than the dbt version, which
-- reads it as a materialised table. Expected, not a bug.
-- ============================================================================

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

WITH portfolio_vehicle AS (
    -- ANY_VALUE because both keys are 1:1 to the portfolio on this fact.
    SELECT
        portfolio_sk,
        ANY_VALUE(legal_buyer_sk)                      AS legal_buyer_sk,
        ANY_VALUE(country_id)                          AS fact_country_id
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    GROUP BY 1
),

portfolio_batch_vintage AS (
    -- ⚠ THE SELLER'S VINTAGE SPREAD, collapsed to one row so the portfolio dim
    -- keeps its grain. DIM_NPL_BATCH is the only place LEGACY_CAPEX_DATE lives.
    SELECT
        b.portfolio_sk,
        COUNT(*)                                       AS batch_count,
        MIN(d.legacy_capex_date)::DATE                 AS legacy_acquisition_first_date,
        MAX(d.legacy_capex_date)::DATE                 AS legacy_acquisition_last_date,
        COUNT(DISTINCT YEAR(d.legacy_capex_date))      AS legacy_acquisition_year_count,
        SUM(d.legacy_capex_amount)                     AS legacy_acquisition_amount
    FROM (
        SELECT
            portfolio_sk,
            batch_sk
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        WHERE period_end_date <= CURRENT_DATE()
        GROUP BY 1, 2
    ) AS b
    LEFT JOIN PROD.NPL_COMMON.DIM_BATCH AS d
        ON d.batch_sk = b.batch_sk
    GROUP BY 1
),

portfolio_registration AS (
    -- ⚠⚠ THE SERVICER'S OWN WINDOW, derived because nothing stores it. The
    -- case snapshot is the only link from a loan to its portfolio, and it is
    -- 1.47bn rows -- each portfolio's OWN latest day is used, not one global
    -- date, because portfolios report on different calendars.
    -- ⚠ FCT_NPL_CASE_SNAPSHOT_DAILY IS MONTH-END GRAIN DESPITE THE NAME.
    SELECT
        b.portfolio_sk,
        MIN(d.registration_date)::DATE                 AS servicer_first_registration_date,
        MAX(d.registration_date)::DATE                 AS servicer_last_registration_date,
        COUNT(DISTINCT b.case_sk)                       AS case_count
    FROM (
        SELECT
            s.portfolio_sk,
            s.case_sk
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        INNER JOIN (
            SELECT
                portfolio_sk,
                MAX(date_day)                          AS latest_day
            FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
            GROUP BY 1
        ) AS l
            ON l.portfolio_sk = s.portfolio_sk
            AND l.latest_day = s.date_day
        GROUP BY 1, 2
    ) AS b
    INNER JOIN PROD.NPL_COMMON.DIM_CASE AS d
        ON d.case_sk = b.case_sk
    GROUP BY 1
),

portfolio_base AS (
    SELECT
        p.portfolio_sk,
        p.portfolio_bk,
        p.deal_id,
        p.currency_id,
        p.flow_type,
        p.capex_date,
        p.capex_amount,
        p.gbv,
        p.principal,
        p.price_gross,
        p.price_net,
        p.price_accounting,
        p.price_percent,
        p.effective_interest_rate,
        p.uw_unlevered_irr,
        p.capitalized_costs,
        p.interim_collections,
        p.pnl,
        p.gmm,
        p.nmm,
        pv.legal_buyer_sk,
        pv.fact_country_id
    FROM PROD.NPL_COMMON.DIM_PORTFOLIO AS p
    LEFT JOIN portfolio_vehicle AS pv
        ON pv.portfolio_sk = p.portfolio_sk
),

orphan_portfolio AS (
    -- Guard. Fact rows with no dimension row -- see the header.
    -- ⚠⚠ ANTI-JOIN: TEST THE RIGHT SIDE FOR NULL. Testing f matches nothing.
    SELECT
        f.portfolio_sk,
        '(Unknown Portfolio ' || f.portfolio_sk || ')' AS portfolio_bk,
        NULL                                           AS deal_id,
        NULL                                           AS currency_id,
        NULL                                           AS flow_type,
        NULL                                           AS capex_date,
        NULL                                           AS capex_amount,
        NULL                                           AS gbv,
        NULL                                           AS principal,
        NULL                                           AS price_gross,
        NULL                                           AS price_net,
        NULL                                           AS price_accounting,
        NULL                                           AS price_percent,
        NULL                                           AS effective_interest_rate,
        NULL                                           AS uw_unlevered_irr,
        NULL                                           AS capitalized_costs,
        NULL                                           AS interim_collections,
        NULL                                           AS pnl,
        NULL                                           AS gmm,
        NULL                                           AS nmm,
        NULL                                           AS legal_buyer_sk,
        ANY_VALUE(f.country_id)                        AS fact_country_id
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS d
        ON d.portfolio_sk = f.portfolio_sk
    WHERE d.portfolio_sk IS NULL
    GROUP BY f.portfolio_sk
),

portfolio_all AS (
    SELECT * FROM portfolio_base

    UNION ALL

    SELECT * FROM orphan_portfolio
),

dim_npl_platinum_portfolio AS (
SELECT
    -- ---- key --------------------------------------------------------------
    p.portfolio_sk,
    p.portfolio_bk                                     AS portfolio_name,

    -- ---- drill path, outermost first ---------------------------------------
    COALESCE(lb.legal_buyer_name, 'Unknown')           AS vehicle,
    COALESCE(ds.deal_source_name, 'Unknown')           AS project,
    COALESCE(d.deal_alias, d.deal_bk, 'Unknown')       AS deal,
    COALESCE(d.seller_name, 'Unknown')                 AS seller_name,
    -- ⚠ DERIVED. Nothing in the warehouse stores the servicer.
    CASE WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'ES' THEN 'Gescobro'
         WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'IT' THEN 'Cerved'
         ELSE 'Intrum' END                             AS servicer,
    -- UK is not in DIM_COUNTRY's region map; everything else takes its own.
    CASE WHEN COALESCE(co.country_name, d.country_id, 'Unknown') = 'UK'
         THEN 'Europe' ELSE co.region END              AS region,
    COALESCE(co.country_name, d.country_id, 'Unknown') AS country_name,
    COALESCE(d.country_id, p.fact_country_id, 'Unknown') AS country_code,

    -- ---- purchase economics ------------------------------------------------
    p.currency_id                                      AS portfolio_currency,
    p.flow_type,
    -- ⚠ THE DATE BROCC BOUGHT THE BOOK. Everything before it is the seller's.
    p.capex_date                                       AS brocc_acquisition_date,
    DATE_TRUNC('MONTH', p.capex_date)::DATE            AS brocc_acquisition_month,
    YEAR(p.capex_date)                                 AS brocc_acquisition_year,
    p.capex_amount,
    p.gbv                                              AS gross_book_value,
    p.principal,
    p.price_gross,
    p.price_net,
    p.price_accounting,
    -- Cents on the euro, already x100. ⚠ Reads 0.00 where GBV is zero.
    p.price_percent,
    p.effective_interest_rate,
    p.uw_unlevered_irr,
    p.capitalized_costs,
    p.interim_collections,
    p.pnl,
    p.gmm,
    p.nmm,

    -- ---- the seller's vintage spread. ⚠ A BUNDLE, NOT AN EVENT. -----------
    bv.batch_count,
    bv.legacy_acquisition_first_date,
    bv.legacy_acquisition_last_date,
    bv.legacy_acquisition_year_count,
    bv.legacy_acquisition_amount,
    DATEDIFF('MONTH', bv.legacy_acquisition_first_date, bv.legacy_acquisition_last_date)
                                                       AS legacy_acquisition_span_months,
    -- ⚠ TRUE where the book bundles batches bought in different years, so one
    -- vintage for the whole portfolio averages across them.
    COALESCE(bv.legacy_acquisition_year_count > 1, FALSE)
                                                       AS is_multi_vintage_flag,

    -- ---- the servicer's own window. DERIVED -- see the header. -------------
    pr.servicer_first_registration_date,
    pr.servicer_last_registration_date,
    DATEDIFF('DAY', pr.servicer_first_registration_date,
             pr.servicer_last_registration_date)         AS servicer_registration_span_days,
    -- ⚠ Negative where Intrum opened cases BEFORE Brocc bought the book, which
    -- is the normal shape of a purchased book.
    DATEDIFF('MONTH', DATE_TRUNC('MONTH', p.capex_date),
             DATE_TRUNC('MONTH', pr.servicer_first_registration_date))
                                                       AS servicer_first_registration_months_to_acquisition,
    pr.case_count                                      AS loans_on_book_count,

    -- ---- flags --------------------------------------------------------------
    -- ⚠ TRUE on the sentinel only. Filter it out deliberately, never silently.
    p.portfolio_bk LIKE '(Unknown Portfolio%'          AS is_unknown_portfolio_flag,
    p.capex_date IS NOT NULL                           AS has_acquisition_date_flag,
    -- ⚠ FALSE where no loan of this book appears in the case snapshot, so the
    -- Intrum dates are unknowable rather than absent.
    pr.portfolio_sk IS NOT NULL                        AS has_loan_detail_flag
FROM portfolio_all AS p
LEFT JOIN portfolio_registration AS pr
    ON pr.portfolio_sk = p.portfolio_sk
LEFT JOIN portfolio_batch_vintage AS bv
    ON bv.portfolio_sk = p.portfolio_sk
-- Every dimension LEFT joined: an orphan key must read 'Unknown', never drop
-- the portfolio.
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS d
    ON d.deal_id = p.deal_id
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
    ON ds.deal_source_bk = d.deal_source_bk
-- DIM_NPL_LEGAL_BUYER is an SCD, but LEGAL_BUYER_SK is the VERSION key and
-- unique (26 rows, 26 keys), so this returns one row. No is_current filter.
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON lb.legal_buyer_sk = p.legal_buyer_sk
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = COALESCE(d.country_id, p.fact_country_id)

),

case_current AS (
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
    FROM PROD.NPL_COMMON.DIM_CASE
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
    FROM PROD.NPL_COMMON.DIM_CASE
    GROUP BY 1
),

portfolio_latest_day AS (
    -- ⚠ PER PORTFOLIO. See the header on why one global date is wrong.
    SELECT
        portfolio_sk,
        MAX(date_day)                                  AS latest_day
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
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
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
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
LEFT JOIN PROD.NPL_COMMON.DIM_BATCH AS bt
    ON bt.batch_sk = cp.batch_sk
LEFT JOIN dim_npl_platinum_portfolio AS p
    ON p.portfolio_sk = cp.portfolio_sk
