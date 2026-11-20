-- ============================================================================
-- MARKET READINESS. ONE ROW PER MARKET.
-- A market = country x loan-holder type x product type.
--
--   RUN    mise run sql -- work/firedrill/market_readiness.sql
--   GRAIN  one row per (country, individual flag, corporate flag, product type)
--   WHY    README.md -- can we price this market from what the warehouse has?
--
-- Every metric ships as a COUNT and a PERCENT of the market's loans.
--
-- ⚠⚠ THE REFERENCE DATE IS THE WHOLE ANSWER: registration where we have it,
--    our Atlas capex where we do not. Verified 2026-10-14:
--      - Heimdall registration dates are genuinely Intrum's own, spread over
--        1900-2026, and ZERO of 18,560,149 equal our capex date. The median
--        gap to our purchase is 88 months, so using registration recovers
--        seven extra years of history on 85% of the book.
--      - LEGACY (2,153,407 loans) and GESCOBRO (36,475) carry NO registration
--        date at all, so capex is the only zero available there.
--      - BLUE/LOKI registration sits a median 1 month from our capex, so the
--        two agree anyway.
--    ⚠ 1900-01-01 appears as a registration date and is junk -- excluded.
--
-- ⚠⚠ THE "BEFORE" COLUMNS ARE A FLOOR. The warehouse drops every payment made
--    before Brocc's first file of that case (an inner join on the case SCD,
--    worth 42-58% on the Portuguese books) -- exactly what they measure.
--
-- ⚠⚠ BALANCE AT REGISTRATION IS OFTEN A STAND-IN. The case snapshot starts
--    2014-06-30, so a loan registered before then has no row at its own
--    registration month and the balance below is the earliest we hold -- a
--    later, LOWER figure, because an NPL amortises. balance_at_reg_exact_n
--    counts how often the month is genuinely the registration month (median
--    24.1% of loans across markets).
--
-- ⚠ PRODUCT comes from a hand-kept seed, npl_product_mappings (46 rows:
--   intrum 28, gescobro 17, cerved 1, souq 1, massey 0). Where a loan carries
--   a product key the mapping ALWAYS resolves -- so 'not stated' means the
--   servicer sent no product code, never a failed lookup. Intrum sends one on
--   62.25% of loans; Massey on none.
--
-- ⚠ CASE_ID is the loan, CASE_SK a version of it. DIM_CASE needs
--   IS_CURRENT_FLAG. Never sum money across currencies -- there is no
--   converted measure, which is why reconciliation runs inside one currency.
-- ============================================================================

WITH loans AS (
    -- One row per loan. The snapshot is month-end despite its name, and one
    -- month holds the whole book (21,854,824 loans at 2026-09-30).
    --
    -- THE THREE AGREED DEFINITIONS:
    --   ref_date   the TRUE registration date -- the servicer's own where we
    --              have it, our Atlas capex where we do not.
    --   debt_age   months from default to ref_date. Fixed once set.
    --   acq_capital_eur  the capital at acquisition -- a ONE-TIME STATIC
    --              figure, converted to EUR at the ref month's rate. Not the
    --              moving snapshot balance.
    --
    -- ⚠⚠ ACQUISITION CAPITAL IS MISSING ON 85% OF THE BOOK TODAY.
    --    original_principal is populated on LEGACY (100%), ORGANIC ORIGINATED
    --    (100%) and GESCOBRO (100%) but only 4.81% of ORANGE/HEIMDALL and
    --    8.37% of BLUE/LOKI. The value EXISTS in raw -- CAT's ORIGINAL_CAPITAL
    --    is populated on 1,156,768 of 1,156,768 Portuguese cases -- it is just
    --    never selected into staging. That is change B1 + A5 on the pipeline
    --    change map. Until it lands, acq_capital_eur is NULL on most Heimdall
    --    loans and has_acq_capital says so.
    --
    -- ⚠ FX JOINS ON LAST_DAY, NOT DATE_TRUNC. date_day on the rate table is
    --   month-END; truncating to month-start returns NULL for every non-EUR
    --   currency, silently. The rate converts LOCAL -> EUR (SEK 0.0890), so
    --   multiply.
    SELECT
        s.case_id,
        s.country_id,
        s.portfolio_sk,
        s.currency_id,
        s.deal_sk,
        COALESCE(pr.product_eba_type, 'not stated') AS product_type,
        COALESCE(NULLIF(c.registration_date, '1900-01-01'), p.capex_date) AS ref_date,
        DATEDIFF(MONTH, c.default_date,
                 COALESCE(NULLIF(c.registration_date, '1900-01-01'), p.capex_date)) AS debt_age_months,
        c.original_principal
            * COALESCE(fx.monthly_avg, IFF(s.currency_id = 'EUR', 1, NULL)) AS acq_capital_eur,
        c.original_principal IS NOT NULL                                   AS has_acq_capital,
        c.default_date
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN (SELECT MAX(date_day) AS date_day
                FROM prod.npl_common.fct_case_snapshot_daily) AS lm
            ON s.date_day = lm.date_day
    LEFT JOIN prod.npl_common.dim_case      AS c  ON c.case_id = s.case_id
                                                 AND c.is_current_flag
    LEFT JOIN prod.npl_common.dim_product   AS pr ON pr.product_sk = s.product_sk
    LEFT JOIN prod.npl_common.dim_portfolio AS p  ON p.portfolio_sk = s.portfolio_sk
    LEFT JOIN prod.common.fct_exchange_rate_monthly AS fx
           ON fx.date_day       = LAST_DAY(COALESCE(NULLIF(c.registration_date, '1900-01-01'), p.capex_date))
          AND fx.quote_currency = s.currency_id
          AND fx.base_currency  = 'EUR'
          AND fx.rate_type      = 'PMI'
),

-- The six-by-six grid the depth score is scored on.
banded AS (
    SELECT l.*,
        CASE WHEN acq_capital_eur IS NULL     THEN 'no capital'
             WHEN acq_capital_eur <    100    THEN '1 · 0-100'
             WHEN acq_capital_eur <    500    THEN '2 · 100-500'
             WHEN acq_capital_eur <   3000    THEN '3 · 500-3k'
             WHEN acq_capital_eur <  20000    THEN '4 · 3k-20k'
             WHEN acq_capital_eur < 100000    THEN '5 · 20k-100k'
             ELSE                                  '6 · 100k+' END AS balance_band,
        CASE WHEN debt_age_months IS NULL OR debt_age_months < 0 THEN 'no debt age'
             WHEN debt_age_months <  3 THEN '1 · 0-3m'
             WHEN debt_age_months <  6 THEN '2 · 3-6m'
             WHEN debt_age_months < 12 THEN '3 · 6-12m'
             WHEN debt_age_months < 24 THEN '4 · 12-24m'
             WHEN debt_age_months < 60 THEN '5 · 24-60m'
             ELSE                           '6 · 60m+' END        AS age_band
    FROM loans AS l
),

-- ⚠ A loan can have several borrowers, so these are flags, not a type.
--   BOTH true is normal: a company and a person on one agreement.
holder AS (
    SELECT case_id,
           MAX(IFF(legal_eba_type = 'Households', 1, 0))                 AS individual,
           MAX(IFF(legal_eba_type = 'Non-financial corporations', 1, 0)) AS corporate
    FROM prod.npl_common.dim_borrower
    WHERE is_current
    GROUP BY 1
),

-- Payment history either side of the reference date, in months.
history AS (
    SELECT
        f.case_id,
        DATEDIFF(MONTH, MIN(IFF(f.collection_date <  l.ref_date, f.collection_date, NULL)),
                        MAX(l.ref_date))                                   AS months_before,
        DATEDIFF(MONTH, MIN(l.ref_date),
                        MAX(IFF(f.collection_date >= l.ref_date, f.collection_date, NULL))) AS months_after
    FROM prod.npl_common.fct_case_collection AS f
    INNER JOIN banded AS l ON l.case_id = f.case_id
    WHERE f.collection_date BETWEEN '1990-01-01' AND CURRENT_DATE()
      AND l.ref_date IS NOT NULL
    GROUP BY 1
),

-- RECONCILED, per portfolio x currency: the loan feed covers >=80% of the
-- months the servicer reported, AND the totals are within 10%.
-- 34 of 251 pairs passed on 2026-10-14; 82 have no loan feed at all, because
-- Gescobro, Cerved and Souq send loans and no money.
reconciled AS (
    SELECT
        p.portfolio_sk,
        p.currency_id,
        IFF(c.months >= 0.8 * p.months
            AND ABS(c.total - p.total) <= 0.10 * ABS(NULLIF(p.total, 0)), 1, 0) AS ok
    FROM (SELECT portfolio_sk, currency_id,
                 COUNT(DISTINCT period_end_date) AS months,
                 SUM(gross_cash_recoveries)      AS total
          FROM prod.npl_common.fct_portfolio_snapshot_monthly
          WHERE gross_cash_recoveries > 0 AND period_end_date <= CURRENT_DATE()
          GROUP BY 1, 2) AS p
    LEFT JOIN (SELECT portfolio_sk, currency_id,
                      COUNT(DISTINCT LAST_DAY(collection_date)) AS months,
                      SUM(amount)                               AS total
               FROM prod.npl_common.fct_case_collection
               WHERE collection_date BETWEEN '1990-01-01' AND CURRENT_DATE()
               GROUP BY 1, 2) AS c
           ON c.portfolio_sk = p.portfolio_sk AND c.currency_id = p.currency_id
)

SELECT
    l.country_id                             AS country,
    COALESCE(h.individual, 0)                AS loan_holder_individual,
    COALESCE(h.corporate, 0)                 AS loan_holder_corporate,
    l.product_type,

    COUNT(*)                                 AS loans,
    COUNT(DISTINCT l.deal_sk)                AS deals,
    -- this market's deals as a share of every deal in the book. Markets share
    -- deals, so this column does NOT add to 100 -- one deal spans several
    -- countries and products.
    ROUND(100 * COUNT(DISTINCT l.deal_sk)
          / (SELECT COUNT(DISTINCT deal_sk) FROM banded), 2) AS pct_of_all_deals,

    -- history BEFORE the reference date, in a portfolio that reconciles
    COUNT_IF(hi.months_before >= 24 AND r.ok = 1)                  AS before_2y_recon_n,
    ROUND(100 * COUNT_IF(hi.months_before >= 24 AND r.ok = 1) / COUNT(*), 2) AS before_2y_recon_pct,
    COUNT_IF(hi.months_before >= 12 AND r.ok = 1)                  AS before_1y_recon_n,
    ROUND(100 * COUNT_IF(hi.months_before >= 12 AND r.ok = 1) / COUNT(*), 2) AS before_1y_recon_pct,

    -- history AFTER the reference date: how long we have watched it pay
    COUNT_IF(hi.months_after >= 60)                                AS after_5y_n,
    ROUND(100 * COUNT_IF(hi.months_after >= 60)  / COUNT(*), 2)    AS after_5y_pct,
    COUNT_IF(hi.months_after >= 120)                               AS after_10y_n,
    ROUND(100 * COUNT_IF(hi.months_after >= 120) / COUNT(*), 2)    AS after_10y_pct,
    COUNT_IF(hi.months_after >= 180)                               AS after_15y_n,
    ROUND(100 * COUNT_IF(hi.months_after >= 180) / COUNT(*), 2)    AS after_15y_pct,

    COUNT_IF(l.has_acq_capital)                                    AS acq_capital_n,
    ROUND(100 * COUNT_IF(l.has_acq_capital)      / COUNT(*), 2)    AS acq_capital_pct,
    COUNT_IF(l.acq_capital_eur IS NOT NULL)                        AS acq_capital_eur_n,
    ROUND(100 * COUNT_IF(l.acq_capital_eur IS NOT NULL) / COUNT(*), 2) AS acq_capital_eur_pct,
    ROUND(MEDIAN(l.acq_capital_eur), 2)                            AS median_acq_capital_eur,

    ROUND(MEDIAN(l.debt_age_months), 1)                            AS median_debt_age_months,
    COUNT(l.default_date)                                          AS debt_age_n,
    ROUND(100 * COUNT(l.default_date)            / COUNT(*), 2)    AS debt_age_pct

FROM banded AS l
LEFT JOIN holder     AS h  ON h.case_id = l.case_id
LEFT JOIN history    AS hi ON hi.case_id = l.case_id
LEFT JOIN reconciled AS r  ON r.portfolio_sk = l.portfolio_sk
                          AND r.currency_id  = l.currency_id
GROUP BY 1, 2, 3, 4
HAVING COUNT(*) >= 100
ORDER BY loans DESC;
