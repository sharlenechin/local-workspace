-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/dim_npl_platinum_portfolio_batch.sql
--   this   : the same model with every {{ ref() }} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/dim_npl_platinum_portfolio_batch.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
-- ⚠⚠ dim_npl_platinum_portfolio IS INLINED AS A CTE BELOW, because it is not a table yet.
-- Inlined ONCE however many times the model refs it, so the scan is not
-- repeated -- but this still runs slower than the dbt version, which
-- reads it as a materialised table. Expected, not a bug.
-- ============================================================================

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

batch_activity AS (
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
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
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
LEFT JOIN PROD.NPL_COMMON.DIM_BATCH AS d
    ON d.batch_sk = b.batch_sk
LEFT JOIN dim_npl_platinum_portfolio AS p
    ON p.portfolio_sk = b.portfolio_sk
