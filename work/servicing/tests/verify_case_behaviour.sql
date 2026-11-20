-- Independent recompute of MART_NPL_SERVICING_AGG_CASES_MONTHLY's behaviour counts and euros, to check the mart's
-- window-frame logic (RANGE BETWEEN INTERVAL '1 month' PRECEDING ...) without using a window frame at all: each
-- case-month is joined to the same case one and two months earlier by date arithmetic.
-- Grain of the output: one row per portfolio x month, the mart's figure beside this file's, plus the difference.
-- Same scope as the mart (owned portfolios, from the capex month, before the current month) because scope is a
-- definition, not the logic under test. Written 2026-10-13 after the user asked whether the mart is correct.

WITH scope AS (
    SELECT portfolio_sk, capex_date
    FROM PROD.NPL_COMMON.DIM_PORTFOLIO
),

case_month AS (
    -- One row per case per month: what the case netted that month (month-start date).
    SELECT
        c.portfolio_sk,
        c.case_id,
        DATE_TRUNC('MONTH', c.collection_date) AS m,
        SUM(c.amount)                          AS amt
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN scope AS s
        ON s.portfolio_sk = c.portfolio_sk
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
      AND (s.capex_date IS NULL OR c.collection_date >= DATE_TRUNC('MONTH', s.capex_date))
    GROUP BY 1, 2, 3
),

classified AS (
    -- Each paying case-month, with what the same case did one and two calendar months before (no row = nothing).
    SELECT
        cur.portfolio_sk,
        cur.m,
        cur.amt,
        COALESCE(p1.amt, 0) > 0 AS paid_1,
        COALESCE(p2.amt, 0) > 0 AS paid_2,
        NOT EXISTS (
            SELECT 1 FROM case_month AS e
            WHERE e.portfolio_sk = cur.portfolio_sk AND e.case_id = cur.case_id AND e.m < cur.m AND e.amt > 0
        )                       AS first_ever
    FROM case_month AS cur
    LEFT JOIN case_month AS p1
        ON p1.portfolio_sk = cur.portfolio_sk AND p1.case_id = cur.case_id AND p1.m = DATEADD('MONTH', -1, cur.m)
    LEFT JOIN case_month AS p2
        ON p2.portfolio_sk = cur.portfolio_sk AND p2.case_id = cur.case_id AND p2.m = DATEADD('MONTH', -2, cur.m)
),

paying AS (
    SELECT
        portfolio_sk,
        m,
        COUNT_IF(amt > 0)                                     AS collected,
        COUNT_IF(amt > 0 AND first_ever)                      AS first_collection,
        COUNT_IF(amt > 0 AND paid_1 AND paid_2)               AS three,
        COUNT_IF(amt > 0 AND NOT paid_1 AND paid_2)           AS jitter_in,
        COUNT_IF(amt > 0 AND NOT paid_1 AND NOT paid_2)       AS new_after_quiet,
        SUM(amt)                                              AS amount_all,
        SUM(IFF(amt > 0 AND paid_1 AND paid_2, amt, 0))       AS amount_three
    FROM classified
    GROUP BY 1, 2
),

lost AS (
    -- Lost in month m: paid in m-1 and m-2, nothing (or nothing positive) in m. Counted only up to the latest month
    -- anything was collected, as the mart does.
    SELECT
        p1.portfolio_sk,
        DATEADD('MONTH', 1, p1.m) AS m,
        COUNT(*)                  AS lost
    FROM case_month AS p1
    INNER JOIN case_month AS p2
        ON p2.portfolio_sk = p1.portfolio_sk AND p2.case_id = p1.case_id AND p2.m = DATEADD('MONTH', -1, p1.m) AND p2.amt > 0
    LEFT JOIN case_month AS nx
        ON nx.portfolio_sk = p1.portfolio_sk AND nx.case_id = p1.case_id AND nx.m = DATEADD('MONTH', 1, p1.m)
    WHERE p1.amt > 0
      AND COALESCE(nx.amt, 0) <= 0
      AND DATEADD('MONTH', 1, p1.m) <= (SELECT MAX(m) FROM case_month)
    GROUP BY 1, 2
),

mine AS (
    SELECT
        COALESCE(p.portfolio_sk, l.portfolio_sk) AS portfolio_sk,
        LAST_DAY(COALESCE(p.m, l.m))             AS period_end_date,
        COALESCE(p.collected, 0) AS collected, COALESCE(p.first_collection, 0) AS first_collection,
        COALESCE(p.three, 0) AS three, COALESCE(p.jitter_in, 0) AS jitter_in, COALESCE(p.new_after_quiet, 0) AS new_after_quiet,
        COALESCE(l.lost, 0) AS lost, COALESCE(p.amount_all, 0) AS amount_all, COALESCE(p.amount_three, 0) AS amount_three
    FROM paying AS p
    FULL OUTER JOIN lost AS l
        ON l.portfolio_sk = p.portfolio_sk AND l.m = p.m
)

SELECT
    COALESCE(x.portfolio_sk, y.portfolio_sk)       AS portfolio_sk,
    COALESCE(x.period_end_date, y.period_end_date) AS period_end_date,
    COALESCE(y.collected, 0)        - COALESCE(x.collected_cases_count, 0)                          AS d_collected,
    COALESCE(y.first_collection, 0) - COALESCE(x.collected_cases_first_collection_count, 0)         AS d_first,
    COALESCE(y.three, 0)            - COALESCE(x.collected_cases_three_consecutive_months_count, 0) AS d_three,
    COALESCE(y.jitter_in, 0)        - COALESCE(x.collected_cases_jitter_in_count, 0)                AS d_jitter_in,
    COALESCE(y.new_after_quiet, 0)  - COALESCE(x.collected_cases_new_count, 0)                      AS d_new,
    COALESCE(y.lost, 0)             - COALESCE(x.collected_cases_lost_count, 0)                     AS d_lost,
    COALESCE(y.amount_all, 0)       - COALESCE(x.collected_amount_local_sum, 0)                     AS d_amount,
    COALESCE(y.amount_three, 0)     - COALESCE(x.collected_amount_local_three_consecutive_months_sum, 0) AS d_amount_three,
    COALESCE(x.collected_cases_count, 0)                                                            AS mart_collected
FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS x
FULL OUTER JOIN mine AS y
    ON y.portfolio_sk = x.portfolio_sk AND y.period_end_date = x.period_end_date
