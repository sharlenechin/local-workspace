-- SE20009 payments before registration: one row per tape payment in the months before the case's registration month with Intrum.
-- Runs on prod: the tape is in the prod asset index, and the matching reads Intrum's raw data on prod.
-- Payments from registration on come from the sandbox build, in payments_post_registration.sql; the two stack.
-- Same cases, model_id and matching as accounts.sql, so the files join on model_id.
-- Only tape rows matched to one of our cases (same_id or borrower_and_balance) bring their payments.
-- Measured 24 Nov 2026: 32,160 rows, SEK 45,164,322.52.

SET portfolio_id = 'SE20009';
SET raw_cat_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.';

WITH

-- One row per case we own, from its latest month-end; see accounts.sql.
cases_owned AS (
    SELECT
        c.case_bk,
        s.case_id AS case_id_hashed,
        s.batch_sk
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = s.batch_sk
    INNER JOIN prod.npl_common.dim_case AS c
        ON c.case_sk = s.case_sk
    WHERE b.servicer_parent_portfolio_bk = $portfolio_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.case_bk ORDER BY s.date_day DESC) = 1
),

current_cases AS (
    SELECT
        case_bk,
        registration_date
    FROM prod.npl_common.dim_case
    WHERE is_current_flag
        AND case_bk IN (SELECT case_bk FROM cases_owned)
),

-- Each case's deal and batch.
cases_batch AS (
    SELECT
        o.case_bk,
        IFF(
            b.deal_source_bk = 'HEI' OR dl.deal_bk IS NULL,
            -- Heimdall books are named vehicle-Intrum id; other deals use their Atlas id.
            b.deal_source_bk || '-' || b.servicer_parent_portfolio_bk,
            dl.deal_bk
        ) AS deal_id,
        b.servicer_parent_portfolio_bk AS intrum_id,
        b.batch_bk,
        b.legal_seller_name AS seller_name
    FROM cases_owned AS o
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = o.batch_sk
    -- Left join, so a batch with an unknown portfolio is not dropped.
    LEFT JOIN prod.npl_common.dim_portfolio AS pf
        ON pf.portfolio_sk = b.portfolio_sk
    LEFT JOIN prod.npl_common.dim_deal AS dl
        ON dl.deal_id = pf.deal_id
),

-- The deal's latest approved asset-index run, from the prod pipeline only.
asset_index_latest_run AS (
    SELECT run_id
    FROM asset_index.approved.runs
    WHERE portfolio_id = $portfolio_id
        AND source_work_uri LIKE 's3://ml-prod-asset-index-work/%'
    QUALIFY ROW_NUMBER() OVER (ORDER BY approved_at DESC) = 1
),

asset_index_case AS (
    SELECT
        a.case_id,
        a.cutoff_date,
        a.currency,
        a.principal_at_cutoff,
        a.legal_balance_at_cutoff,
        a.accrued_interest_at_cutoff,
        a.other_balances_at_cutoff,
        a.default_date,
        a.origination_date,
        a.product_type,
        a.sub_portfolio
    FROM asset_index.approved.cases AS a
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = a._run_id
),

asset_index_counterparty AS (
    SELECT
        l.case_id,
        MIN(p.birth_year) AS birth_year,
        MAX(p.deceased) AS deceased,
        MIN(p.gender) AS gender
    FROM asset_index.approved.case_counterparty AS l
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = l._run_id
    INNER JOIN asset_index.approved.counterparties AS p
        ON p._run_id = l._run_id
        AND p.counterparty_id = l.counterparty_id
    GROUP BY 1
),

asset_index_attribute AS (
    SELECT
        a.entity_id AS case_id,
        MAX(IFF(a.attribute = 'bankruptcy_flag', a.value, NULL)) AS bankruptcy_flag,
        MAX(IFF(a.attribute = 'enforcement_flag', a.value, NULL)) AS enforcement_flag,
        MAX(IFF(a.attribute = 'legal_title_flag', a.value, NULL)) AS legal_title_flag,
        MIN(IFF(a.attribute = 'limitation_date', TRY_TO_DATE(LEFT(a.value, 10)), NULL)) AS limitation_date,
        MIN(IFF(a.attribute = 'verdict_date', TRY_TO_DATE(LEFT(a.value, 10)), NULL)) AS verdict_date,
        MIN(IFF(a.attribute = 'verdict_application_date', TRY_TO_DATE(LEFT(a.value, 10)), NULL))
            AS verdict_application_date
    FROM asset_index.approved.attributes AS a
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = a._run_id
    WHERE a.entity_type = 'case'
    GROUP BY 1
),

-- MATCHING. A tape row whose id is not one of our cases is paired by borrower and balances:
--   1. Only a tape row and a case with the same borrower birth year and gender can pair.
--   2. Points: principal at cut-off = Intrum's original capital 3; other balances = Intrum's client costs 1;
--      interest = Intrum's remaining interest 1; verdict month = Intrum's judgement month 1;
--      a verdict date on one side only -1. Amounts count only above zero, except principal.
--   3. A pair is kept only at 2 points or more, and only if each is the other's single best, with no tie.
-- Tested blind on the 10,755 cases matched by same_id: it picked the right case 99.815% of the time.
tape_unmatched AS (
    SELECT
        case_id AS tape_case_id,
        ROUND(principal_at_cutoff, 2) AS principal,
        ROUND(other_balances_at_cutoff, 2) AS other_balances,
        ROUND(accrued_interest_at_cutoff, 2) AS interest
    FROM asset_index_case
    WHERE case_id NOT IN (SELECT case_bk FROM cases_owned)
),

tape_borrower AS (
    SELECT
        case_id AS tape_case_id,
        birth_year,
        -- The tape says male/female; Intrum says M/F.
        IFF(gender = 'male', 'M', IFF(gender = 'female', 'F', NULL)) AS gender
    FROM asset_index_counterparty
),

-- Our cases with no tape row under their own id, as Intrum recorded them.
intrum_unmatched_raw AS (
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
        AND '2080-' || case_id NOT IN (SELECT case_id FROM asset_index_case)
),

-- Intrum's first filled-in value of each field; the oldest file alone is blank for 8% of cases.
intrum_unmatched AS (
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
    FROM intrum_unmatched_raw
),

intrum_gender AS (
    SELECT
        case_id,
        MIN(gender) AS gender
    FROM raw.hyperion_intrum_cat.debtors
    WHERE _file_path LIKE $raw_cat_prefix || 'debtors.%'
        AND case_id IN (SELECT case_id FROM intrum_unmatched)
    GROUP BY 1
),

intrum_birth_year AS (
    SELECT
        case_id,
        MIN(COALESCE(birthyear::NUMBER, YEAR(TRY_TO_DATE(birthdate::STRING)))) AS birth_year
    FROM raw.hyperion_intrum_cat.debtor_additional_info
    WHERE _file_path LIKE $raw_cat_prefix || 'debtor_additional_info.%'
        AND case_id IN (SELECT case_id FROM intrum_unmatched)
    GROUP BY 1
),

-- Every tape row and case with the same borrower birth year and gender, with its points.
match_candidate AS (
    SELECT
        t.tape_case_id,
        i.case_bk,
        IFF(t.principal = i.principal, 1, 0) AS principal_equal,
        IFF(t.other_balances = i.other_balances AND t.other_balances > 0, 1, 0) AS other_balances_equal,
        IFF(t.interest = i.interest AND t.interest > 0, 1, 0) AS interest_equal,
        CASE
            WHEN x.verdict_date IS NULL AND i.verdict_month IS NULL THEN 0
            WHEN DATE_TRUNC(MONTH, x.verdict_date) = i.verdict_month THEN 1
            WHEN x.verdict_date IS NOT NULL AND i.verdict_month IS NOT NULL THEN 0
            ELSE -1
        END AS verdict_points,
        3 * principal_equal + other_balances_equal + interest_equal + verdict_points AS points
    FROM tape_unmatched AS t
    INNER JOIN tape_borrower AS tb
        ON tb.tape_case_id = t.tape_case_id
    LEFT JOIN asset_index_attribute AS x
        ON x.case_id = t.tape_case_id
    INNER JOIN intrum_birth_year AS ib
        ON ib.birth_year = tb.birth_year
    INNER JOIN intrum_gender AS ig
        ON ig.case_id = ib.case_id
        AND ig.gender = tb.gender
    INNER JOIN intrum_unmatched AS i
        ON i.case_id = ib.case_id
),

match_best AS (
    SELECT
        *,
        MAX(points) OVER (PARTITION BY tape_case_id) AS best_for_tape,
        MAX(points) OVER (PARTITION BY case_bk) AS best_for_case
    FROM match_candidate
    WHERE points >= 2
),

-- A tie on either side means no match.
match_best_counted AS (
    SELECT
        *,
        COUNT_IF(points = best_for_tape) OVER (PARTITION BY tape_case_id) AS tied_for_tape,
        COUNT_IF(points = best_for_case) OVER (PARTITION BY case_bk) AS tied_for_case
    FROM match_best
),

-- Each case's tape row, and how it was found.
cases_tape AS (
    SELECT
        case_id AS case_bk,
        case_id AS tape_case_id,
        'same_id' AS match_method,
        NULL AS match_points
    FROM asset_index_case
    WHERE case_id IN (SELECT case_bk FROM cases_owned)

    UNION ALL

    SELECT
        case_bk,
        tape_case_id,
        'borrower_and_balance',
        points
    FROM match_best_counted
    WHERE points = best_for_tape
        AND points = best_for_case
        AND tied_for_tape = 1
        AND tied_for_case = 1
),

-- Before registration: payments on the seller's tape, under the case they were matched to.
payment_before_registration AS (
    SELECT
        t.case_bk AS model_id,
        'asset_index' AS payment_source,
        p.payment_date,
        p.payment_amount AS amount,
        a.currency,
        p.case_id AS asset_index_case_id,
        t.match_method AS asset_index_match_method,
        NULL AS warehouse_paid_on_case,
        NULL AS warehouse_collection_bk,
        NULL AS warehouse_batch_sk
    FROM asset_index.approved.payments AS p
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = p._run_id
    INNER JOIN asset_index_case AS a
        ON a.case_id = p.case_id
    INNER JOIN cases_tape AS t
        ON t.tape_case_id = p.case_id
    INNER JOIN current_cases AS c
        ON c.case_bk = t.case_bk
    -- Months before the registration month only; from the registration month on, the warehouse's payments are used.
    WHERE p.payment_date < DATE_TRUNC(MONTH, c.registration_date)
)

SELECT
    -- Identifiers and the month; no prefix
    y.model_id,
    SPLIT_PART(y.model_id, '-', 1) AS instance,
    d.deal_id,
    d.intrum_id,
    LAST_DAY(y.payment_date) AS month_end,
    DATEDIFF(MONTH, c.registration_date, y.payment_date) AS months_since_registration,

    -- The payment, and which source it comes from
    y.payment_source,
    y.payment_date,
    y.amount AS payment_amount,
    y.currency AS payment_currency,
    c.registration_date AS warehouse_registration_date,

    -- Source details; empty for the other source
    y.asset_index_case_id,
    y.asset_index_match_method,                 -- same_id or borrower_and_balance; see MATCHING
    NULL AS warehouse_paid_on_case,
    NULL AS warehouse_batch_bk,
    NULL AS warehouse_collection_bk,

    -- warehouse_vs_pam_: empty here; deal_dataset.py fills them from payments_post_registration.sql
    NULL::FLOAT AS warehouse_vs_pam_collection_total_pct,
    NULL::FLOAT AS warehouse_vs_pam_month_coverage_pct,
    NULL::DATE AS warehouse_vs_pam_compared_from,
    NULL::DATE AS warehouse_vs_pam_compared_to,
    NULL::BOOLEAN AS warehouse_reconciles_with_pam
FROM payment_before_registration AS y
INNER JOIN current_cases AS c
    ON c.case_bk = y.model_id
LEFT JOIN cases_batch AS d
    ON d.case_bk = y.model_id
ORDER BY y.model_id, y.payment_date;
