-- Underwriting data depth score.
--
--   GRAIN   one row per market = country x seller type x borrower type
--   AS AT   2026-10-15
--
-- Three counts per portfolio, rolled to the market, then one geometric mean:
--   accounts    acquired cases -- the account count at registration
--   portfolios  how many portfolios make up the market
--   months      months since registration in which the portfolio collected
--
-- Every one of our 74 portfolios is in scope. Where Intrum's PAM feed covers a
-- portfolio it supplies everything; where it does not (Gescobro, organic, and
-- the Heimdall legs that do not bridge) the same three counts and the two
-- market axes are rebuilt from PROD.
--
-- Guards:
--   * PAM holds forecast FILES (cut on _file_path) and whole files that also
--     carry forward ROWS out to 2041 where every figure is blank; everything
--     past today is cut too.
--   * 95.7% of portfolio-months are restated later, so the newest row per
--     (portfolio, period) wins.
--   * acqcases repeats on every month row of a portfolio -- it is a static, so
--     it is read with MAX and never summed across months.
--   * PAM covers Intrum's whole managed book; ours are the portfolio ids that
--     appear inside a PROD portfolio key. Exact joins on portfolioid,
--     combined_ref and seller_name each match on ZERO rows.
WITH pam_rows AS (
    SELECT
        portfolioid,
        branch_desc,
        customer_type,
        TRY_TO_DATE(LEFT(period_start_date, 10)) AS period,
        acqcases,
        colltotal
    FROM raw.hyperion_intrum_pam.pam
    WHERE _file_path NOT ILIKE '%forecast%'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY portfolioid, period_start_date
        ORDER BY _file_last_modified DESC) = 1
),

pam_actual AS (
    SELECT * FROM pam_rows
    WHERE period IS NOT NULL AND period <= CURRENT_DATE()
),

-- Our portfolios: the stem of the PROD key, one per purchase. The tranche
-- suffix (-U01/2512, -S02/2606) is stripped so tranches of one purchase are
-- not counted as separate portfolios.
our_portfolios AS (
    SELECT
        SPLIT_PART(d.portfolio_bk, '-U', 1)  AS portfolio_stem,
        MAX(d.deal_id)                       AS deal_id
    FROM prod.npl_common.dim_portfolio AS d
    GROUP BY 1
),

-- Which PAM portfolio, if any, covers each of ours.
bridge AS (
    SELECT op.portfolio_stem, op.deal_id, MIN(p.portfolioid) AS portfolioid
    FROM our_portfolios AS op
    LEFT JOIN (SELECT DISTINCT portfolioid FROM pam_actual) AS p
           ON op.portfolio_stem LIKE '%' || p.portfolioid || '%'
    GROUP BY 1, 2
),

-- ---------- the three counts, from PAM where we have it ----------
pam_counts AS (
    SELECT
        a.portfolioid,
        MAX(a.acqcases)                                        AS accounts,
        COUNT(DISTINCT IFF(a.colltotal > 0, a.period, NULL))   AS months,
        MAX(IFF(a.branch_desc IN ('Bank Loan', 'Credit Card', 'Finance'),
                'Financial', 'Non-financial'))                 AS seller_type,
        MAX(a.customer_type)                                   AS customer_type
    FROM pam_actual AS a
    GROUP BY 1
),

-- ---------- and from PROD for everything PAM does not reach ----------
-- Accounts: live cases on the portfolio. Months: portfolio-months with a
-- recovery. Both at the portfolio stem, so they line up with PAM's grain.
prod_counts AS (
    SELECT
        SPLIT_PART(dp.portfolio_bk, '-U', 1)                           AS portfolio_stem,
        COUNT(DISTINCT s.case_id)                                      AS accounts
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN (SELECT MAX(date_day) AS d
                FROM prod.npl_common.fct_case_snapshot_daily) AS lm ON s.date_day = lm.d
    INNER JOIN prod.npl_common.dim_portfolio AS dp ON dp.portfolio_sk = s.portfolio_sk
    GROUP BY 1
),

-- Months must be counted FROM REGISTRATION, not over all history. The
-- portfolio feed carries months inherited from before we bought the book --
-- unbounded, that gives 309 months on Austria, which is 25 years of a
-- portfolio we have owned since 2025. capex_date is the anchor.
prod_months AS (
    SELECT
        SPLIT_PART(dp.portfolio_bk, '-U', 1)                           AS portfolio_stem,
        COUNT(DISTINCT IFF(f.gross_cash_recoveries > 0,
                           f.period_end_date, NULL))                   AS months
    FROM prod.npl_common.fct_portfolio_snapshot_monthly AS f
    INNER JOIN prod.npl_common.dim_portfolio AS dp ON dp.portfolio_sk = f.portfolio_sk
    WHERE f.period_end_date >= dp.capex_date
      AND f.period_end_date <= CURRENT_DATE()
    GROUP BY 1
),

-- Borrower type from the case layer: a portfolio is SME/corporate when more
-- than half its borrowers are non-financial corporations, else individual.
prod_borrower AS (
    SELECT
        portfolio_stem,
        IFF(corporates / NULLIF(borrowers, 0) > 0.5, 'SME', 'Consumer') AS borrower_type
    FROM (
        SELECT
            SPLIT_PART(dp.portfolio_bk, '-U', 1)                                   AS portfolio_stem,
            COUNT(*)                                                               AS borrowers,
            SUM(IFF(b.legal_eba_type = 'Non-financial corporations', 1, 0))        AS corporates
        FROM prod.npl_common.dim_borrower AS b
        INNER JOIN prod.npl_common.fct_case_snapshot_daily AS s ON s.case_id = b.case_id
        INNER JOIN (SELECT MAX(date_day) AS d
                    FROM prod.npl_common.fct_case_snapshot_daily) AS lm ON s.date_day = lm.d
        INNER JOIN prod.npl_common.dim_portfolio AS dp ON dp.portfolio_sk = s.portfolio_sk
        WHERE b.is_current
        GROUP BY 1
    )
),

-- Seller type from the seller's own name, for portfolios PAM does not classify.
-- The non-financial sellers are few and named explicitly so the rule is
-- auditable: telecoms, utilities and fuel. Everything else is a lender.
prod_seller AS (
    SELECT
        dd.deal_id,
        IFF(TRIM(SPLIT_PART(dd.deal_alias, ' - ', 1)) IN
                ('DNA', 'Elisa', 'Moi Mobiili', 'Salt Mobile',
                 'Electrabel', 'Luminus', 'St1 Suomi'),
            'Non-financial', 'Financial')                               AS seller_type
    FROM prod.npl_common.dim_deal AS dd
),

-- ---------- one row per portfolio, whichever source filled it ----------
portfolios AS (
    SELECT
        br.portfolio_stem,
        dd.country_id                                                   AS country,
        COALESCE(pc.seller_type, ps.seller_type)                        AS seller_type,
        COALESCE(pc.customer_type, pb.borrower_type, 'Consumer')        AS borrower_type,
        COALESCE(pc.accounts, prc.accounts)                             AS accounts,
        COALESCE(NULLIF(pc.months, 0), prm.months, 0)                   AS months,
        IFF(br.portfolioid IS NOT NULL, 'PAM', 'PROD')                  AS source
    FROM bridge              AS br
    INNER JOIN prod.npl_common.dim_deal AS dd  ON dd.deal_id = br.deal_id
    LEFT  JOIN pam_counts    AS pc  ON pc.portfolioid    = br.portfolioid
    LEFT  JOIN prod_counts   AS prc ON prc.portfolio_stem = br.portfolio_stem
    LEFT  JOIN prod_months   AS prm ON prm.portfolio_stem = br.portfolio_stem
    LEFT  JOIN prod_borrower AS pb  ON pb.portfolio_stem  = br.portfolio_stem
    LEFT  JOIN prod_seller   AS ps  ON ps.deal_id         = br.deal_id
),

markets AS (
    SELECT
        country,
        seller_type,
        borrower_type,
        SUM(accounts)                                  AS accounts,
        COUNT(DISTINCT portfolio_stem)                 AS portfolios,
        MEDIAN(months)                                 AS months,
        COUNT(DISTINCT IFF(source = 'PAM',
                           portfolio_stem, NULL))      AS portfolios_from_pam
    FROM portfolios
    WHERE accounts > 0
    GROUP BY 1, 2, 3
),

-- ln is monotonic, so LN(1 + MAX(x)) and MAX(LN(1 + x)) are the same number.
-- Each leg reads as "how close is this market to the best any market reaches".
scored AS (
    SELECT *,
        LN(1 + accounts)   / LN(1 + MAX(accounts)   OVER ()) AS f_accounts,
        LN(1 + portfolios) / LN(1 + MAX(portfolios) OVER ()) AS f_portfolios,
        LN(1 + months)     / LN(1 + MAX(months)     OVER ()) AS f_months
    FROM markets
)

SELECT
    country,
    seller_type,
    borrower_type,
    accounts,
    portfolios,
    months,
    portfolios_from_pam,
    ROUND(f_accounts, 4)                                         AS f_accounts,
    ROUND(f_portfolios, 4)                                       AS f_portfolios,
    ROUND(f_months, 4)                                           AS f_months,
    ROUND(POWER(f_accounts * f_portfolios * f_months, 1.0/3), 4) AS depth_score,
    CASE LEAST(f_accounts, f_portfolios, f_months)
         WHEN f_accounts   THEN 'accounts'
         WHEN f_portfolios THEN 'portfolios'
         ELSE 'months' END                                       AS binding_input
FROM scored
ORDER BY depth_score DESC;
