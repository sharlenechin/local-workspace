-- ============================================================================
-- UNDERWRITING DATA DEPTH SCORE. ONE ROW PER MARKET.
-- A market = country x loan-holder type x product type.
--
--   RUN    mise run sql -- work/firedrill/depth_score.sql
--   GRAIN  one row per market, plus its 36-cell breakdown rolled up.
--   WHY    README.md. Companion to market_readiness.sql, which holds the raw
--          building blocks; this turns them into the 0-1 score.
--
-- THE CALCULATION
--   1  registration_date = COALESCE(the servicer's own, our Atlas capex)
--   2  debt_age_months   = DATEDIFF(MONTH, default_date, registration_date)
--   3  capital_eur       = capital at acquisition, converted to EUR
--   4  every loan falls in one of 36 cells (6 capital bands x 6 age bands)
--   5  per cell: accounts, effective deals, median months of collections
--   6  f(x; T) = min(1, ln(1+x) / ln(1+T))
--   7  cell score = (f_accounts * f_deals * f_months) ^ (1/3)
--   8  market score = SUM(w * s) / SUM(w), w = 1/36, every cell counted
--
-- ⚠⚠ CAPITAL IS A STAND-IN UNTIL CHANGE B1 LANDS. The real figure is CAT's
--    ORIGINAL_CAPITAL -- populated on 1,156,768 of 1,156,768 Portuguese cases
--    -- but it is never selected into staging, so PROD carries it on only
--    4.81% of Heimdall loans. Below, outstanding_total stands in where
--    original_principal is absent, and capital_is_proxy says which. Band
--    placement is therefore indicative, not final.
--
-- ⚠⚠ USE CAPITAL, NOT BALANCE. Balance = capital + interest + fees, and the
--    sellers deliver interest four different ways: measured on Project Sea,
--    interest as a share of capital is Oney 67.22%, WiZink 20.12%,
--    Barclaycard 12.07%, Millennium 0.66%, Cofidis 0.00%. A balance banded
--    across sellers bands four accrual standards. Project Elsa dropped
--    registration_interest and registration_balance for exactly this reason.
--    In raw, interest is present on 99.3% of PT cases but POSITIVE on only
--    14.7% -- so balance equals capital on most loans anyway.
--
-- ⚠ FX IS CONSTANT-RATE, NOT CUT-OFF-RATE, AND THAT IS DELIBERATE. The rate
--   table starts 2018-01-31 -- verified across every base currency (EUR, SEK)
--   and rate type (PMI, FIXED) in both the monthly and daily tables; the daily
--   one starts 2018-01-02. Heimdall registrations run back past 2013, so a
--   cut-off rate does not exist for them. One constant rate also makes markets
--   comparable with each other instead of mixing FX eras.
--
-- ⚠ FX joins on currency only here. If you ever go back to a dated join, use
--   LAST_DAY -- date_day is month-END, and a month-start join returns NULL for
--   every non-EUR currency, silently. The rate converts LOCAL -> EUR
--   (SEK 0.0890), so multiply.
-- ============================================================================

WITH fx AS (
    -- One rate per currency, the most recent month. Constant currency.
    SELECT quote_currency AS currency_id, monthly_avg AS to_eur
    FROM prod.common.fct_exchange_rate_monthly
    WHERE base_currency = 'EUR' AND rate_type = 'PMI'
      AND date_day = (SELECT MAX(date_day) FROM prod.common.fct_exchange_rate_monthly)
    UNION ALL
    SELECT 'EUR', 1
),

loans AS (
    SELECT
        s.case_id,
        s.country_id,
        s.deal_sk,
        COALESCE(pr.product_eba_type, 'not stated')                       AS product_type,
        COALESCE(NULLIF(c.registration_date, '1900-01-01'), p.capex_date) AS registration_date,
        DATEDIFF(MONTH, c.default_date,
                 COALESCE(NULLIF(c.registration_date, '1900-01-01'), p.capex_date)) AS debt_age_months,
        COALESCE(c.original_principal, s.outstanding_total) * fx.to_eur   AS capital_eur,
        c.original_principal IS NULL                                      AS capital_is_proxy
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN (SELECT MAX(date_day) AS date_day
                FROM prod.npl_common.fct_case_snapshot_daily) AS lm ON s.date_day = lm.date_day
    LEFT JOIN prod.npl_common.dim_case      AS c  ON c.case_id = s.case_id AND c.is_current_flag
    LEFT JOIN prod.npl_common.dim_product   AS pr ON pr.product_sk = s.product_sk
    LEFT JOIN prod.npl_common.dim_portfolio AS p  ON p.portfolio_sk = s.portfolio_sk
    LEFT JOIN fx ON fx.currency_id = s.currency_id
),

-- Product type is a MARKET axis, not a score input: it decides which grid a
-- loan belongs to. Same for country and holder type.
market_loans AS (
    SELECT
        l.*,
        COALESCE(h.individual, 0) AS loan_holder_individual,
        COALESCE(h.corporate, 0)  AS loan_holder_corporate,
        CASE WHEN l.capital_eur <    100 THEN 1 WHEN l.capital_eur <    500 THEN 2
             WHEN l.capital_eur <   3000 THEN 3 WHEN l.capital_eur <  20000 THEN 4
             WHEN l.capital_eur < 100000 THEN 5 ELSE 6 END AS balance_band,
        CASE WHEN l.debt_age_months <  3 THEN 1 WHEN l.debt_age_months <  6 THEN 2
             WHEN l.debt_age_months < 12 THEN 3 WHEN l.debt_age_months < 24 THEN 4
             WHEN l.debt_age_months < 60 THEN 5 ELSE 6 END AS age_band
    FROM loans AS l
    LEFT JOIN (SELECT case_id,
                      MAX(IFF(legal_eba_type = 'Households', 1, 0))                 AS individual,
                      MAX(IFF(legal_eba_type = 'Non-financial corporations', 1, 0)) AS corporate
               FROM prod.npl_common.dim_borrower WHERE is_current GROUP BY 1) AS h
           ON h.case_id = l.case_id
    WHERE l.capital_eur IS NOT NULL AND l.debt_age_months >= 0
),

-- Months of collections observed after registration, per loan.
months_per_loan AS (
    SELECT f.case_id,
           DATEDIFF(MONTH, MIN(m.registration_date), MAX(f.collection_date)) AS months
    FROM prod.npl_common.fct_case_collection AS f
    INNER JOIN market_loans AS m ON m.case_id = f.case_id
    WHERE f.collection_date BETWEEN '1990-01-01' AND CURRENT_DATE()
      AND f.collection_date >= m.registration_date
    GROUP BY 1
),

-- Deal shares inside each cell, for the effective-deals measure.
deal_shares AS (
    SELECT
        m.country_id, m.loan_holder_individual, m.loan_holder_corporate, m.product_type,
        m.balance_band, m.age_band, m.deal_sk,
        COUNT(*) AS loans_from_deal
    FROM market_loans AS m
    GROUP BY 1,2,3,4,5,6,7
),

-- Cell totals first: a window function cannot sit inside an aggregate.
cell_totals AS (
    SELECT country_id, loan_holder_individual, loan_holder_corporate, product_type,
           balance_band, age_band, SUM(loans_from_deal) AS accounts
    FROM deal_shares
    GROUP BY 1,2,3,4,5,6
),

-- One row per market x cell: accounts, and effective deals as the inverse
-- Herfindahl of the deal shares inside that cell.
cells AS (
    SELECT
        d.country_id, d.loan_holder_individual, d.loan_holder_corporate, d.product_type,
        d.balance_band, d.age_band,
        MAX(t.accounts)                                                  AS accounts,
        1 / SUM(POWER(d.loans_from_deal / t.accounts, 2))                AS eff_deals
    FROM deal_shares AS d
    INNER JOIN cell_totals AS t
       ON  t.country_id = d.country_id
       AND t.loan_holder_individual = d.loan_holder_individual
       AND t.loan_holder_corporate  = d.loan_holder_corporate
       AND t.product_type = d.product_type
       AND t.balance_band = d.balance_band AND t.age_band = d.age_band
    GROUP BY 1,2,3,4,5,6
),

cell_months AS (
    SELECT m.country_id, m.loan_holder_individual, m.loan_holder_corporate, m.product_type,
           m.balance_band, m.age_band,
           -- TWO definitions, side by side. The spec asks for the median over
           -- ALL loans, but in an NPL book the median loan never pays, so that
           -- median is 0 almost everywhere. MEDIAN ignores NULLs, so the second
           -- form is automatically the median over PAYING loans only.
           MEDIAN(COALESCE(mp.months, 0))                       AS median_months_all,
           COALESCE(MEDIAN(mp.months), 0)                       AS median_months_paying,
           ROUND(100.0 * COUNT(mp.case_id) / COUNT(*), 2)       AS pct_paying
    FROM market_loans AS m
    LEFT JOIN months_per_loan AS mp ON mp.case_id = m.case_id
    GROUP BY 1,2,3,4,5,6
),

scored AS (
    SELECT
        c.country_id, c.loan_holder_individual, c.loan_holder_corporate, c.product_type,
        c.accounts, c.eff_deals,
        cm.median_months_all, cm.median_months_paying, cm.pct_paying,
        LEAST(1, LN(1 + c.accounts)                  / LN(1 + 10000)) AS f_accounts,
        LEAST(1, LN(1 + c.eff_deals)                 / LN(1 + 10))    AS f_deals,
        LEAST(1, LN(1 + cm.median_months_all)        / LN(1 + 60))    AS f_months_all,
        LEAST(1, LN(1 + cm.median_months_paying)     / LN(1 + 60))    AS f_months_paying
    FROM cells AS c
    INNER JOIN cell_months AS cm
       ON  cm.country_id = c.country_id
       AND cm.loan_holder_individual = c.loan_holder_individual
       AND cm.loan_holder_corporate  = c.loan_holder_corporate
       AND cm.product_type = c.product_type
       AND cm.balance_band = c.balance_band AND cm.age_band = c.age_band
)

SELECT
    country_id                                AS country,
    loan_holder_individual,
    loan_holder_corporate,
    product_type,
    SUM(accounts)                             AS loans,
    COUNT(*)                                  AS cells_populated,
    -- every one of the 36 cells counts; the empty ones score zero.
    -- AS SPECIFIED: median months over all loans.
    ROUND(SUM(POWER(f_accounts * f_deals * f_months_all,    1.0/3)) / 36, 4) AS depth_score,
    -- PROPOSED: median months over paying loans only.
    ROUND(SUM(POWER(f_accounts * f_deals * f_months_paying, 1.0/3)) / 36, 4) AS depth_score_paying,
    ROUND(AVG(f_accounts), 3)                 AS avg_f_accounts,
    ROUND(AVG(f_deals), 3)                    AS avg_f_deals,
    ROUND(AVG(f_months_all), 3)               AS avg_f_months,
    ROUND(AVG(f_months_paying), 3)            AS avg_f_months_paying,
    ROUND(MEDIAN(eff_deals), 2)               AS median_eff_deals,
    ROUND(MEDIAN(median_months_all), 1)       AS median_months,
    ROUND(MEDIAN(median_months_paying), 1)    AS median_months_paying,
    ROUND(AVG(pct_paying), 2)                 AS pct_paying
FROM scored
GROUP BY 1,2,3,4
HAVING SUM(accounts) >= 100
ORDER BY depth_score DESC;
