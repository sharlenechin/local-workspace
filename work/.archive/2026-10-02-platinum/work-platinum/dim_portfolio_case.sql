-- ============================================================================
-- PLATINUM. THE ONE-STOP DIMENSION: one row per (PORTFOLIO_SK, CASE_BK), with
-- every portfolio attribute and every case attribute already attached.
-- GRAIN: 21,885,911 rows, 21,883,446 cases, 196 portfolios. PROD, EUR-free.
-- ============================================================================
-- WHY THIS EXISTS: every query in work/ rebuilds the same four joins
-- to answer "which book is this loan in, and who sold it to us?". This is that
-- answer, once. Join anything to it on (PORTFOLIO_SK, CASE_BK) -- or on
-- CASE_SK if you are joining a fact that carries the version key.
--
-- ⚠⚠ A CASE CAN APPEAR UNDER TWO PORTFOLIOS AND THAT IS NOT AN ERROR. 2,465 of
-- 21,883,446 do. The grain is the PAIR; counting loans means
-- COUNT(DISTINCT case_bk), never COUNT(*). Measured 2026-09-22.
--
-- ⚠⚠ CASE_SK IS A VERSION KEY, CASE_BK IS THE LOAN. DIM_CASE holds 154,077,844
-- rows for 22,530,117 loans -- 6.8 versions each. IS_CURRENT_FLAG collapses it
-- to exactly one row per CASE_BK (verified: 22,530,117 = 22,530,117).
-- ⚠ CASE_SK here is the CURRENT version. A fact carrying a historical CASE_SK
-- will NOT match it -- join those on CASE_BK, or on CASE_SK without the flag.
--
-- ⚠⚠ THE BOOK IS AS AT EACH PORTFOLIO'S OWN LATEST SNAPSHOT DAY, not a single
-- global date. Portfolios report on different calendars, so one cut-off would
-- empty the ones that had not reported yet.
-- ⚠ FCT_CASE_SNAPSHOT_DAILY IS MONTH-END GRAIN DESPITE THE NAME.
--
-- ⚠ 196 PORTFOLIOS, NOT 264. DIM_PORTFOLIO has 264; the other 68 have never
-- had a case in the loan-level snapshot. They are portfolio-level aggregates.
-- An INNER join to this dimension silently drops them -- LEFT join from the
-- portfolio side if you need all 264.
--
-- ⚠ NO MONEY AND NO DATES-BY-MONTH HERE, deliberately. This is a dimension.
-- Collections live in agg_case_collection_monthly / agg_portfolio_collection_
-- monthly, forecasts in agg_portfolio_forecast_monthly.
-- ============================================================================
WITH portfolio_vehicle AS (
    -- The ONLY reason the portfolio fact appears: legal_buyer_sk is on no
    -- dimension. ANY_VALUE because both keys are 1:1 to the portfolio.
    SELECT
        portfolio_sk,
        ANY_VALUE(legal_buyer_sk)                      AS legal_buyer_sk,
        ANY_VALUE(country_id)                          AS fact_country_id
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    GROUP BY 1
),

portfolio_attributes AS (
    -- The drill path, resolved once. Every join is LEFT: an orphan key must
    -- read 'Unknown', never drop the portfolio.
    SELECT
        p.portfolio_sk,
        p.portfolio_bk                                 AS portfolio_name,
        COALESCE(lb.legal_buyer_name, 'Unknown')       AS vehicle,
        COALESCE(ds.deal_source_name, 'Unknown')       AS project,
        COALESCE(d.deal_alias, d.deal_bk, 'Unknown')   AS deal,
        COALESCE(d.seller_name, 'Unknown')             AS seller_name,
        -- ⚠ SERVICER_GROUP IS DEFINED FIRST because SERVICER references it. A
        -- Snowflake alias can only be reused by a LATER expression in the list.
        CASE WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'ES' THEN 'Gescobro'
             WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'IT' THEN 'Cerved'
             ELSE 'Intrum' END                         AS servicer,
        -- UK is not in DIM_COUNTRY's region map; everything else takes its own.
        CASE WHEN COALESCE(co.country_name, d.country_id, 'Unknown') = 'UK'
             THEN 'Europe' ELSE co.region END          AS region,
        COALESCE(co.country_name, d.country_id, 'Unknown') AS country_name,
        COALESCE(d.country_id, pv.fact_country_id, 'Unknown') AS country_code,
        p.currency_id                                  AS portfolio_currency,
        p.flow_type,
        p.capex_date,
        DATE_TRUNC('MONTH', p.capex_date)::DATE        AS capex_month,
        YEAR(p.capex_date)                             AS capex_year,
        p.capex_amount,
        p.gbv                                          AS gross_book_value,
        p.price_gross,
        -- Cents on the euro, already x100. ⚠ Reads 0.00 where GBV is zero.
        p.price_percent
    FROM PROD.NPL_COMMON.DIM_PORTFOLIO AS p
    LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS d
        ON d.deal_id = p.deal_id
    LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
        ON ds.deal_source_bk = d.deal_source_bk
    LEFT JOIN portfolio_vehicle AS pv
        ON pv.portfolio_sk = p.portfolio_sk
    -- DIM_LEGAL_BUYER is an SCD, but legal_buyer_sk is the VERSION key and
    -- unique (26 rows, 26 keys), so this returns one row. No filter needed.
    LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
        ON lb.legal_buyer_sk = pv.legal_buyer_sk
    LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
        ON co.iso_alpha2_code = d.country_id
),

portfolio_latest_day AS (
    -- ⚠ PER PORTFOLIO. See the header on why one global date is wrong.
    SELECT
        portfolio_sk,
        MAX(date_day)                                  AS latest_day
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
    GROUP BY 1
),

book AS (
    -- Loans held at each portfolio's own latest snapshot day.
    -- ⚠ GROUPED, so a case appearing twice in one day's file cannot fan out.
    SELECT
        s.portfolio_sk,
        s.case_sk
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    INNER JOIN portfolio_latest_day AS l
        ON l.portfolio_sk = s.portfolio_sk
        AND l.latest_day = s.date_day
    GROUP BY 1, 2
),

case_attributes AS (
    -- ⚠ IS_CURRENT_FLAG gives exactly one row per CASE_BK -- see the header.
    SELECT
        case_sk,
        case_bk,
        case_id,
        registration_date::DATE                        AS registration_date,
        COALESCE(derived_default_date, default_date)::DATE AS default_date,
        default_date::DATE                             AS reported_default_date,
        origination_date::DATE                         AS origination_date,
        backstop_date::DATE                            AS backstop_date,
        original_principal,
        secured_flag                                   AS is_secured_flag,
        -- ⚠ STATUS_DESCRIPTION, CLOSING_CODE, CLOSING_DESCRIPTION and
        -- CLOSING_CATEGORY are 100% NULL on all 22.5m rows, so legal /
        -- amicable / insolvency STAGE cannot be reported from this warehouse.
        -- The bare code is all that survives. Do not promise a decode.
        status_code,
        status_date::DATE                              AS status_date,
        reporting_system_sk
    FROM PROD.NPL_COMMON.DIM_CASE
    WHERE is_current_flag = TRUE
)

SELECT
    -- ---- keys. Join facts on (portfolio_sk, case_bk), or on case_sk. ------
    b.portfolio_sk,
    c.case_bk,
    c.case_sk,
    c.case_id,

    -- ---- the book ---------------------------------------------------------
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
    p.capex_date,
    p.capex_month,
    p.capex_year,
    p.capex_amount,
    p.gross_book_value,
    p.price_gross,
    p.price_percent,

    -- ---- the loan ---------------------------------------------------------
    c.registration_date,
    DATE_TRUNC('MONTH', c.registration_date)::DATE     AS registration_month,
    YEAR(c.registration_date)                          AS registration_year,
    -- ⚠ DERIVED where the servicer reported none. REPORTED_DEFAULT_DATE is the
    -- raw column beside it, so a consumer can tell the two apart.
    c.default_date,
    DATE_TRUNC('MONTH', c.default_date)::DATE          AS default_month,
    c.reported_default_date,
    c.default_date IS NOT NULL
        AND c.reported_default_date IS NULL            AS default_date_derived_flag,
    c.origination_date,
    c.backstop_date,
    c.original_principal,
    c.is_secured_flag,
    c.status_code,
    c.status_date,
    c.reporting_system_sk,

    -- ⚠ Years between default and registration, the usual "debt age". NULL
    -- where either date is missing rather than zero.
    ROUND(DATEDIFF('DAY', c.default_date, c.registration_date) / 365.25, 5)
                                                       AS debt_age_years_at_registration,
    -- ⚠ 0 in the month Brocc bought the book. NULL with no capex date.
    DATEDIFF('MONTH', p.capex_month, DATE_TRUNC('MONTH', c.registration_date))
                                                       AS registration_months_to_capex
FROM book AS b
INNER JOIN case_attributes AS c
    ON c.case_sk = b.case_sk
LEFT JOIN portfolio_attributes AS p
    ON p.portfolio_sk = b.portfolio_sk
