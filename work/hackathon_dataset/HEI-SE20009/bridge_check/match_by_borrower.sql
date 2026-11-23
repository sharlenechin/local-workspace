-- SE20009: pairs a tape loan with no usable case id to a case we own, using the borrower and the balances.
-- Grain: one row per matched pair (tape case id, our case_bk).
-- Rule: same borrower birth year and gender, then points; the pair must be each other's single best at 2 points or more.
-- Points: principal = Intrum's original capital 3, other balances = client costs 1, interest = remaining interest 1,
--   verdict month = judgement month 1, verdict on one side only -1.
-- Blind test on the 10,755 cases whose tape id is already our case id: right on 99.815% of 9,704 it paired.
-- The same rule as MATCHING in accounts.sql and payments.sql, run alone to see each pair's points; keep all three the same.
-- Measured 23 Nov 2026: 2,832 pairs, the same as accounts.sql; takes about 1 minute.

SET portfolio_id = 'SE20009';
SET raw_cat_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.';

WITH

cases_owned AS (
    SELECT DISTINCT c.case_bk
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = s.batch_sk
    INNER JOIN prod.npl_common.dim_case AS c
        ON c.case_sk = s.case_sk
    WHERE b.servicer_parent_portfolio_bk = $portfolio_id
),

asset_index_latest_run AS (
    SELECT run_id
    FROM asset_index.approved.runs
    WHERE portfolio_id = $portfolio_id
        AND source_work_uri LIKE 's3://ml-prod-asset-index-work/%'
    QUALIFY ROW_NUMBER() OVER (ORDER BY approved_at DESC) = 1
),

-- Tape loans whose case id is not one of our cases.
tape AS (
    SELECT
        a.case_id AS tape_case_id,
        ROUND(a.principal_at_cutoff, 2) AS principal,
        ROUND(a.other_balances_at_cutoff, 2) AS other_balances,
        ROUND(a.accrued_interest_at_cutoff, 2) AS interest
    FROM asset_index.approved.cases AS a
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = a._run_id
    WHERE a.case_id NOT IN (SELECT case_bk FROM cases_owned)
),

tape_borrower AS (
    SELECT
        l.case_id AS tape_case_id,
        MIN(p.birth_year) AS birth_year,
        -- The tape says male/female; Intrum says M/F.
        MIN(IFF(p.gender = 'male', 'M', IFF(p.gender = 'female', 'F', NULL))) AS gender
    FROM asset_index.approved.case_counterparty AS l
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = l._run_id
    INNER JOIN asset_index.approved.counterparties AS p
        ON p._run_id = l._run_id
        AND p.counterparty_id = l.counterparty_id
    GROUP BY 1
),

tape_verdict AS (
    SELECT
        a.entity_id AS tape_case_id,
        DATE_TRUNC(MONTH, MIN(TRY_TO_DATE(LEFT(a.value, 10)))) AS verdict_month
    FROM asset_index.approved.attributes AS a
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = a._run_id
    WHERE a.entity_type = 'case'
        AND a.attribute = 'verdict_date'
    GROUP BY 1
),

-- Our cases whose case_bk is not a tape case id.
raw_case AS (
    SELECT
        '2080-' || case_id AS case_bk,
        case_id,
        _file_path,
        original_capital,
        remaining_client_costs,
        remaining_interest,
        judgement_date
    FROM raw.hyperion_intrum_cat.cases
    WHERE _file_path LIKE $raw_cat_prefix || 'cases.%'
        AND LEFT(long_portfolio_id, 7) = $portfolio_id
        AND '2080-' || case_id IN (SELECT case_bk FROM cases_owned)
        AND '2080-' || case_id NOT IN (
            SELECT a.case_id
            FROM asset_index.approved.cases AS a
            INNER JOIN asset_index_latest_run AS r
                ON r.run_id = a._run_id
        )
),

-- Intrum's first filled-in value of each field; the oldest file alone is blank for 8% of cases.
intrum AS (
    SELECT DISTINCT
        case_bk,
        case_id,
        ROUND(FIRST_VALUE(original_capital) IGNORE NULLS OVER (
            PARTITION BY case_id ORDER BY _file_path ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ), 2) AS principal,
        ROUND(FIRST_VALUE(remaining_client_costs) IGNORE NULLS OVER (
            PARTITION BY case_id ORDER BY _file_path ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ), 2) AS other_balances,
        ROUND(FIRST_VALUE(remaining_interest) IGNORE NULLS OVER (
            PARTITION BY case_id ORDER BY _file_path ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ), 2) AS interest,
        DATE_TRUNC(MONTH, (FIRST_VALUE(judgement_date) IGNORE NULLS OVER (
            PARTITION BY case_id ORDER BY _file_path ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ))::DATE) AS verdict_month
    FROM raw_case
),

intrum_gender AS (
    SELECT
        d.case_id,
        MIN(d.gender) AS gender
    FROM raw.hyperion_intrum_cat.debtors AS d
    WHERE d._file_path LIKE $raw_cat_prefix || 'debtors.%'
        AND d.case_id IN (SELECT case_id FROM intrum)
    GROUP BY 1
),

intrum_birth_year AS (
    SELECT
        a.case_id,
        MIN(COALESCE(a.birthyear::NUMBER, YEAR(TRY_TO_DATE(a.birthdate::STRING)))) AS birth_year
    FROM raw.hyperion_intrum_cat.debtor_additional_info AS a
    WHERE a._file_path LIKE $raw_cat_prefix || 'debtor_additional_info.%'
        AND a.case_id IN (SELECT case_id FROM intrum)
    GROUP BY 1
),

-- Every tape loan and case with the same borrower birth year and gender, with its points.
candidate AS (
    SELECT
        t.tape_case_id,
        i.case_bk,
        IFF(t.principal = i.principal, 1, 0) AS principal_equal,
        IFF(t.other_balances = i.other_balances AND t.other_balances > 0, 1, 0) AS other_balances_equal,
        IFF(t.interest = i.interest AND t.interest > 0, 1, 0) AS interest_equal,
        CASE
            WHEN v.verdict_month IS NULL AND i.verdict_month IS NULL THEN 0
            WHEN v.verdict_month = i.verdict_month THEN 1
            WHEN v.verdict_month IS NOT NULL AND i.verdict_month IS NOT NULL THEN 0
            ELSE -1
        END AS verdict_points,
        3 * principal_equal + other_balances_equal + interest_equal + verdict_points AS points
    FROM tape AS t
    INNER JOIN tape_borrower AS tb
        ON tb.tape_case_id = t.tape_case_id
    LEFT JOIN tape_verdict AS v
        ON v.tape_case_id = t.tape_case_id
    INNER JOIN intrum_birth_year AS ib
        ON ib.birth_year = tb.birth_year
    INNER JOIN intrum_gender AS ig
        ON ig.case_id = ib.case_id
        AND ig.gender = tb.gender
    INNER JOIN intrum AS i
        ON i.case_id = ib.case_id
),

best AS (
    SELECT
        *,
        MAX(points) OVER (PARTITION BY tape_case_id) AS best_for_tape,
        MAX(points) OVER (PARTITION BY case_bk) AS best_for_case
    FROM candidate
    WHERE points >= 2
),

-- A tie on either side means no match.
best_counted AS (
    SELECT
        *,
        COUNT_IF(points = best_for_tape) OVER (PARTITION BY tape_case_id) AS tied_for_tape,
        COUNT_IF(points = best_for_case) OVER (PARTITION BY case_bk) AS tied_for_case
    FROM best
)

SELECT
    tape_case_id,
    case_bk,
    points,
    principal_equal,
    other_balances_equal,
    interest_equal,
    verdict_points
FROM best_counted
WHERE points = best_for_tape
    AND points = best_for_case
    AND tied_for_tape = 1
    AND tied_for_case = 1
ORDER BY tape_case_id;
