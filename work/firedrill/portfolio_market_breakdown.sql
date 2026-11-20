-- Every market we can see, what it holds, and whether the two sides agree.
--
--   GRAIN   one row per market = country x seller type x borrower type
--   LEFT    RAW.HYPERION_INTRUM_PAM.PAM -- the portfolio feed
--   RIGHT   PROD.NPL_COMMON case layer, joined portfolio-to-portfolio
--   AS AT   2026-10-14
--
-- Guards:
--   * forecast FILES are excluded on _file_path, and whole files also carry
--     forward ROWS out to 2041 -- acqcases repeats on them while remaining
--     cases and collections sit at zero -- so everything past today is cut too.
--   * 95.7% of portfolio-months are restated later; newest row per month wins.
--   * remaining cases is blank in the most recent months, so it is read at the
--     latest month where it is actually positive.
--   * never join PAM to the case side via deal_id: one deal spans a whole
--     country's book and fans the count out by two to three orders of magnitude.
WITH whole_files AS (
    SELECT portfolioid, country, branch_desc, customer_type,
           TRY_TO_DATE(LEFT(period_start_date,10)) AS period,
           acqcases, rp_remaining_cases, colltotal
    FROM raw.hyperion_intrum_pam.pam
    WHERE _file_path NOT ILIKE '%forecast%'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY portfolioid, period_start_date
                               ORDER BY _file_last_modified DESC) = 1
),
actual AS (
    SELECT * FROM whole_files WHERE period IS NOT NULL AND period <= CURRENT_DATE()
),
bridge AS (
    SELECT DISTINCT a.portfolioid, d.portfolio_sk
    FROM actual AS a
    INNER JOIN prod.npl_common.dim_portfolio AS d
            ON d.portfolio_bk LIKE '%' || a.portfolioid || '%'
),
bounds AS (
    SELECT portfolioid,
           MIN(period)                                      AS first_month,
           MAX(IFF(rp_remaining_cases > 0, period, NULL))   AS last_live_month
    FROM actual GROUP BY 1
),
portfolios AS (
    SELECT
        a.portfolioid,
        MAX(a.country)                                                  AS country,
        MAX(IFF(a.branch_desc IN ('Bank Loan','Credit Card','Finance'),
                'Financial Service','Non-Financial Service'))           AS seller_type,
        COALESCE(MAX(a.customer_type), 'Unknown')                       AS borrower_type,
        MAX(IFF(a.period = b.first_month,
                COALESCE(a.rp_remaining_cases, a.acqcases), NULL))      AS accounts_at_reg,
        MAX(IFF(a.period = b.last_live_month, a.rp_remaining_cases, NULL)) AS pam_remaining,
        COUNT(DISTINCT IFF(a.colltotal > 0, a.period, NULL))            AS months,
        MAX(IFF(br.portfolioid IS NOT NULL, 1, 0))                      AS is_ours
    FROM actual AS a
    INNER JOIN bounds AS b  ON b.portfolioid = a.portfolioid
    LEFT  JOIN (SELECT DISTINCT portfolioid FROM bridge) AS br
                            ON br.portfolioid = a.portfolioid
    GROUP BY 1
),
case_side AS (
    SELECT br.portfolioid, COUNT(*) AS prod_cases
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN (SELECT MAX(date_day) AS d
                FROM prod.npl_common.fct_case_snapshot_daily) AS lm ON s.date_day = lm.d
    INNER JOIN bridge AS br ON br.portfolio_sk = s.portfolio_sk
    GROUP BY 1
)
SELECT
    p.country,
    p.seller_type,
    p.borrower_type,
    -- every count below is OUR portfolios only; the market also reports how
    -- many portfolios sit in it altogether, ours and everyone else's.
    COUNT(DISTINCT p.portfolioid)                                      AS portfolios_in_market,
    COUNT(DISTINCT IFF(p.is_ours = 1, p.portfolioid, NULL))            AS deals,
    COUNT(DISTINCT IFF(p.is_ours = 1 AND p.accounts_at_reg > 0,
                       p.portfolioid, NULL))                           AS deals_with_accounts,
    COUNT(DISTINCT IFF(p.is_ours = 1 AND p.months > 0,
                       p.portfolioid, NULL))                           AS deals_collecting,
    COUNT(DISTINCT IFF(p.is_ours = 1 AND c.prod_cases IS NOT NULL,
                       p.portfolioid, NULL))                           AS deals_with_case_data,
    SUM(IFF(p.is_ours = 1, p.accounts_at_reg,  NULL))                  AS accounts_at_registration,
    SUM(IFF(p.is_ours = 1, p.pam_remaining,    NULL))                  AS pam_remaining_cases,
    SUM(IFF(p.is_ours = 1, c.prod_cases,       NULL))                  AS prod_cases,
    ROUND(SUM(IFF(p.is_ours = 1, c.prod_cases, NULL))
          / NULLIF(SUM(IFF(p.is_ours = 1, p.pam_remaining, NULL)), 0), 2) AS prod_over_pam
FROM portfolios AS p
LEFT JOIN case_side AS c ON c.portfolioid = p.portfolioid
GROUP BY 1,2,3
HAVING deals > 0
ORDER BY deals DESC, accounts_at_registration DESC NULLS LAST;
