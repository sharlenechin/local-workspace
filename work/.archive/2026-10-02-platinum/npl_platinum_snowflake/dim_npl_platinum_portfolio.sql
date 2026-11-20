-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/dim_npl_platinum_portfolio.sql
--   this   : the same model with every {{ ref() }} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/dim_npl_platinum_portfolio.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
-- ============================================================================

/*
PLATINUM. ONE ROW PER PORTFOLIO, deduped, with the whole drill path resolved:
seller, legal buyer (vehicle), project, deal, servicer, region and country, plus
the purchase economics. 264 rows -- 263 real, 1 sentinel, as at 2026-09-24.

⚠ THE ROW COUNT MOVES. It read 265 on 2026-09-23. DIM_NPL_PORTFOLIO is rebuilt
and loses rows as well as gaining them, so do not assert on a literal count.

THIS IS THE TABLE TO JOIN TO. Every other query in this layer carries
PORTFOLIO_SK and nothing else; this resolves it. Nobody should be joining
DIM_NPL_DEAL and DIM_NPL_LEGAL_BUYER by hand again.

⚠⚠ ONE MORE ROW THAN DIM_NPL_PORTFOLIO HAS. The last is a sentinel for fact rows whose PORTFOLIO_SK
has no dimension row -- 2,068 fact rows over 24 months in 5 currencies, 6.38% of
collections. Its deal, deal source and legal buyer keys all resolve to nothing,
so every drill column reads the literal 'Unknown' rather than a NULL: that way
it groups into one visible bucket instead of scattering into a null one, and an
INNER join cannot silently drop it. Its PORTFOLIO_NAME starts '(Unknown
Portfolio' -- that is how you find or exclude it. There is no flag; the name
says it.

⚠⚠ LEGAL_BUYER_SK IS ON NO DIMENSION. It exists only on the portfolio fact,
which is the sole reason FCT_NPL_PORTFOLIO_SNAPSHOT_MONTHLY is read here.
Drop VEHICLE and the fact CTE and DIM_NPL_LEGAL_BUYER go with it.

⚠⚠ THERE IS NO INTRUM-SIDE DATE ON THE PORTFOLIO. DIM_NPL_PORTFOLIO carries
exactly one date, CAPEX_DATE, and it is Brocc's: when we bought the book. The
servicer's side has to be DERIVED from the loans, which is what
SERVICER_FIRST_REGISTRATION_DATE and SERVICER_LAST_REGISTRATION_DATE are -- the
earliest and latest date Intrum opened a case in this book.
  BROCC_ACQUISITION_DATE          stored. When Brocc bought the book.
  SERVICER_FIRST_REGISTRATION_DATE  derived. When the servicer opened the first
                                    case. ⚠ A book can have TWO servicers at
                                    once -- 34 portfolios do -- so this window
                                    spans whichever were active. For the split
                                    by servicer, read dim_npl_portfolio_history.
  SERVICER_LAST_REGISTRATION_DATE   derived. When the last case was opened.
⚠ THE INTRUM DATES ARE A RANGE, NOT AN EVENT. A book registered over years has a
wide span; SERVICER_REGISTRATION_SPAN_DAYS says how wide. Do not treat the first
date as "the" registration date of the book.
⚠ AND THEY INHERIT THE INSTABILITY of the underlying column: the case-level
registration date moves across versions on 19.9% of loans. See
dim_npl_platinum_case.

⚠⚠ A PORTFOLIO IS OFTEN A BUNDLE OF BATCHES BOUGHT DECADES APART. 21 of 264
hold more than one batch, 17 of those span several years, and the widest spans
27. BROCC_ACQUISITION_DATE is when WE bought the bundle -- one date, correct --
but the batches inside it were acquired by the previous owner between 1996 and
2023. The LEGACY_ACQUISITION_* columns below summarise that spread so a
one-row-per-portfolio join still tells you the book is a bundle.
⚠ FOR THE BATCHES THEMSELVES, read dim_npl_platinum_portfolio_batch. Do NOT
join that model on PORTFOLIO_SK alone -- a portfolio averages 45 batches and one
has 3,238, so it multiplies money.

⚠ SERVICER IS DERIVED, NOT STORED. Nothing in the warehouse carries it: it is
inferred from deal source and country. Sub-servicer is not modelled at all.

⚠ NO MONEY BY MONTH HERE. This is a dimension. Collections and balances live in
agg_npl_platinum_portfolio_monthly, forecasts in
agg_npl_platinum_forecast_monthly.
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
)

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
