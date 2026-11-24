-- SE25018: old 1062 case and new 2080 case that are one moved loan, matched on principal.
-- A pair is an old case closed with code 9 within a day of the new one opening, with equal principal.
-- Measured 24 Nov 2026: 4,039 pairs. Paste them into the three dataset queries (moved_loans.csv has the same list).

SET portfolio_id = 'SE25018';

WITH

deal_month AS (
    SELECT
        c.case_bk,
        s.date_day AS month_end,
        s.outstanding_principal
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = s.batch_sk
    INNER JOIN prod.npl_common.dim_case AS c
        ON c.case_sk = s.case_sk
    WHERE b.servicer_parent_portfolio_bk = $portfolio_id
),

current_cases AS (
    SELECT
        case_bk,
        registration_date,
        closing_date,
        closing_code
    FROM prod.npl_common.dim_case
    WHERE is_current_flag
        AND case_bk IN (SELECT case_bk FROM deal_month)
),

old_case AS (
    SELECT
        c.case_bk,
        c.closing_date,
        m.outstanding_principal AS principal_at_close
    FROM current_cases AS c
    INNER JOIN deal_month AS m
        ON m.case_bk = c.case_bk
    WHERE LEFT(c.case_bk, 4) = '1062'
        AND c.closing_code = '9'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY c.case_bk ORDER BY ABS(DATEDIFF(DAY, m.month_end, c.closing_date))
    ) = 1
),

new_case AS (
    SELECT
        c.case_bk,
        c.registration_date,
        m.outstanding_principal AS principal_at_open
    FROM current_cases AS c
    INNER JOIN deal_month AS m
        ON m.case_bk = c.case_bk
    WHERE LEFT(c.case_bk, 4) = '2080'
        AND m.month_end >= c.registration_date
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.case_bk ORDER BY m.month_end) = 1
),

pair AS (
    SELECT
        o.case_bk AS old_case,
        n.case_bk AS new_case
    FROM old_case AS o
    INNER JOIN new_case AS n
        ON o.closing_date BETWEEN n.registration_date AND n.registration_date + 1
        AND ROUND(o.principal_at_close, 2) = ROUND(n.principal_at_open, 2)
)

SELECT
    old_case,
    new_case
FROM pair
QUALIFY COUNT(*) OVER (PARTITION BY old_case) = 1
    AND COUNT(*) OVER (PARTITION BY new_case) = 1;
