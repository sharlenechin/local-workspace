-- SE20009 accounts: one row per case per month-end, from the tape cut-off (Feb 2020) to the latest month.
-- Column prefixes: asset_index_ = seller's tape, warehouse_ = our warehouse, warehouse_vs_pam_ = check against Intrum's report.
-- A case is ours if the warehouse puts it in an SE20009 batch; all are on Intrum's system 2080, and no loan moved system.
-- Each case is one loan, so model_id is the case_bk.
-- A case finds its tape row in one of two ways, named in asset_index_match_method:
--   same_id: the tape's case id is our case_bk.
--   borrower_and_balance: the tape row has another id, so it is matched by the rule in the matching section below.
-- Warehouse payments may be incomplete, so check warehouse_reconciles_with_pam before using them.
-- Measured 23 Nov 2026: 15,514 cases, 13,587 with a tape row (10,755 same_id, 2,832 borrower_and_balance).

SET portfolio_id = 'SE20009';
SET raw_cat_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.';
SET max_total_deviation_pct = 10;
SET min_month_coverage_pct = 80;

WITH

-- Every month-end balance the warehouse holds for the deal's cases.
monthly_cases AS (
    SELECT
        c.case_bk,
        s.case_id AS case_id_hashed,
        s.case_sk,
        s.batch_sk,
        s.date_day AS month_end,
        s.outstanding_principal,
        s.outstanding_interest,
        s.outstanding_fees,
        s.outstanding_total,
        s.forbearance_flag
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = s.batch_sk
    INNER JOIN prod.npl_common.dim_case AS c
        ON c.case_sk = s.case_sk
    WHERE b.servicer_parent_portfolio_bk = $portfolio_id
),

-- One row per case we own, from its latest month-end.
cases_owned AS (
    SELECT
        case_bk,
        case_id_hashed,
        batch_sk
    FROM monthly_cases
    QUALIFY ROW_NUMBER() OVER (PARTITION BY case_bk ORDER BY month_end DESC) = 1
),

current_cases AS (
    SELECT
        case_bk,
        registration_date,
        default_date
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
        MAX(IFF(a.attribute = 'debt_restructuring_flag', a.value, NULL)) AS debt_restructuring_flag,
        MAX(IFF(a.attribute = 'enforcement_flag', a.value, NULL)) AS enforcement_flag,
        MAX(IFF(a.attribute = 'legal_title_flag', a.value, NULL)) AS legal_title_flag,
        MAX(IFF(a.attribute = 'postal_region', a.value, NULL)) AS postal_region,
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

-- Month-ends from the tape cut-off to the warehouse's latest month-end.
month_base_reference AS (
    SELECT month_end
    FROM (
        SELECT LAST_DAY(DATEADD(
            MONTH,
            ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1,
            DATE_TRUNC(MONTH, (SELECT MIN(cutoff_date) FROM asset_index_case))
        )) AS month_end
        FROM TABLE(GENERATOR(ROWCOUNT => 600))
    )
    WHERE month_end <= (SELECT MAX(month_end) FROM monthly_cases)
),

-- Each case's month-end figures, with its status as at that month.
monthly_cases_status AS (
    SELECT
        d.case_bk,
        d.month_end,
        d.outstanding_principal,
        d.outstanding_interest,
        d.outstanding_fees,
        d.outstanding_total,
        d.forbearance_flag,
        v.status_code,
        v.status_description,
        v.closing_date,
        v.closing_code
    FROM monthly_cases AS d
    INNER JOIN prod.npl_common.dim_case AS v
        ON v.case_sk = d.case_sk
),

-- Balance at the end of the registration month, if the warehouse has that month.
registration_balance AS (
    SELECT
        m.case_bk,
        m.outstanding_principal AS principal_at_registration,
        m.outstanding_total AS balance_at_registration
    FROM monthly_cases_status AS m
    INNER JOIN current_cases AS c
        ON c.case_bk = m.case_bk
    WHERE m.month_end = LAST_DAY(c.registration_date)
),

cases_collection AS (
    SELECT
        o.case_bk,
        LAST_DAY(f.collection_date) AS month_end,
        SUM(f.amount) AS collected_in_month
    FROM cases_owned AS o
    INNER JOIN prod.npl_common.fct_case_collection AS f
        ON f.case_id = o.case_id_hashed
    GROUP BY 1, 2
),

-- Tape payments per tape case and month; the tape's history ends in May 2020, before any case registered.
asset_index_payment AS (
    SELECT
        p.case_id,
        LAST_DAY(p.payment_date) AS month_end,
        SUM(p.payment_amount) AS paid_in_month
    FROM asset_index.approved.payments AS p
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = p._run_id
    GROUP BY p.case_id, LAST_DAY(p.payment_date)
),

deal_batch AS (
    SELECT
        batch_sk,
        legacy_capex_date
    FROM prod.npl_common.dim_batch
    WHERE servicer_parent_portfolio_bk = $portfolio_id
),

acquisition AS (
    SELECT MIN(legacy_capex_date) AS acquisition_date
    FROM deal_batch
),

pam_extract AS (
    SELECT
        MAX(_file_path) AS file_path,
        TO_DATE(REGEXP_SUBSTR(MAX(_file_path), 'pam\\.pam\\.pam\\.(\\d{8})', 1, 1, 'e'), 'YYYYMMDD')
            AS extracted_on
    FROM raw.hyperion_intrum_pam.pam
    WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

-- Only past months: PAM also carries forecast rows into the future.
pam_monthly AS (
    SELECT
        DATE_TRUNC(MONTH, p.period_start_date::DATE) AS collection_month,
        SUM(p.colltotal) AS pam_collected
    FROM raw.hyperion_intrum_pam.pam AS p
    CROSS JOIN pam_extract AS e
    CROSS JOIN acquisition AS q
    WHERE p._file_path = e.file_path
        AND p.pmode_name = 'Real'
        AND COALESCE(p.is_ownership_change, 0) = 0
        AND p.portfolioid = $portfolio_id
        AND p.period_start_date::DATE < DATE_TRUNC(MONTH, e.extracted_on)
        AND p.period_start_date::DATE >= DATE_TRUNC(MONTH, q.acquisition_date)
    GROUP BY 1
),

warehouse_monthly AS (
    SELECT
        DATE_TRUNC(MONTH, f.collection_date) AS collection_month,
        SUM(f.amount) AS warehouse_collected
    FROM prod.npl_common.fct_case_collection AS f
    INNER JOIN deal_batch AS b
        ON b.batch_sk = f.batch_sk
    CROSS JOIN acquisition AS q
    WHERE f.collection_date >= DATE_TRUNC(MONTH, q.acquisition_date)
    GROUP BY 1
),

-- Compare only the months both sources cover.
base_pam_reconciliation AS (
    SELECT
        p.collection_month,
        p.pam_collected,
        COALESCE(w.warehouse_collected, 0) AS warehouse_collected
    FROM pam_monthly AS p
    LEFT JOIN warehouse_monthly AS w
        ON w.collection_month = p.collection_month
    WHERE p.collection_month <= (SELECT MAX(collection_month) FROM warehouse_monthly)
),

pam_reconciliation AS (
    SELECT
        SUM(pam_collected) AS pam_collected,
        SUM(warehouse_collected) AS warehouse_collected,
        -- Warehouse total vs PAM in %, and the share of PAM's paying months the warehouse also has.
        (SUM(warehouse_collected) / NULLIF(SUM(pam_collected), 0) - 1) * 100
            AS collection_reconciliation_total_pct,
        COUNT_IF(pam_collected <> 0 AND warehouse_collected <> 0)
            / NULLIF(COUNT_IF(pam_collected <> 0), 0) * 100 AS collection_month_coverage_pct
    FROM base_pam_reconciliation
)

SELECT
    -- Identifiers and the month; no prefix
    o.case_bk AS model_id,
    SPLIT_PART(o.case_bk, '-', 1) AS instance,
    b.deal_id,
    b.intrum_id,
    t.month_end,
    DATEDIFF(MONTH, c.registration_date, t.month_end) AS months_since_registration,  -- negative before

    -- asset_index_: the seller's tape at its cut-off, the same on every row; empty where a deal's tape lacks it
    lt.tape_case_id IS NOT NULL AS in_asset_index,
    lt.match_method AS asset_index_match_method,  -- how the tape row was found: same_id or borrower_and_balance; see MATCHING
    lt.match_points AS asset_index_match_points,  -- points a borrower_and_balance pair scored
    lt.tape_case_id AS asset_index_case_id,
    a.sub_portfolio AS asset_index_sub_portfolio,
    a.cutoff_date AS asset_index_cutoff_date,
    a.currency AS asset_index_currency,
    a.principal_at_cutoff AS asset_index_principal_at_cutoff,
    a.legal_balance_at_cutoff AS asset_index_legal_balance_at_cutoff,
    a.accrued_interest_at_cutoff AS asset_index_accrued_interest_at_cutoff,
    a.other_balances_at_cutoff AS asset_index_other_balances_at_cutoff,
    a.default_date AS asset_index_default_date,
    a.origination_date AS asset_index_origination_date,
    INITCAP(a.product_type) AS asset_index_product_type,
    p.birth_year AS asset_index_birth_year,
    p.deceased AS asset_index_deceased,
    p.gender AS asset_index_gender,
    x.bankruptcy_flag AS asset_index_bankruptcy_flag,
    x.debt_restructuring_flag AS asset_index_debt_restructuring_flag,
    x.enforcement_flag AS asset_index_enforcement_flag,
    x.legal_title_flag AS asset_index_legal_title_flag,
    x.postal_region AS asset_index_postal_region,
    x.limitation_date AS asset_index_limitation_date,
    x.verdict_date AS asset_index_verdict_date,
    x.verdict_application_date AS asset_index_verdict_application_date,

    -- warehouse_: the deal, registration and default; the same on every row
    b.batch_bk AS warehouse_batch_bk,
    b.seller_name AS warehouse_seller_name,
    c.registration_date AS warehouse_registration_date,
    c.default_date AS warehouse_default_date,
    r.principal_at_registration AS warehouse_principal_at_registration,
    r.balance_at_registration AS warehouse_balance_at_registration,

    -- warehouse_: as at this month-end; empty where the warehouse has no row for the month
    m.case_bk AS warehouse_reported_by_case,
    m.outstanding_principal AS warehouse_outstanding_principal,
    m.outstanding_interest AS warehouse_outstanding_interest,
    m.outstanding_fees AS warehouse_outstanding_fees,
    m.outstanding_total AS warehouse_outstanding_total,
    m.forbearance_flag AS warehouse_forbearance_flag,
    m.status_code AS warehouse_status_code,
    m.status_description AS warehouse_status_description,
    IFF(m.case_bk IS NULL, NULL, COALESCE(m.closing_date <= t.month_end, FALSE)) AS warehouse_is_closed,
    IFF(m.closing_date <= t.month_end, m.closing_code, NULL) AS warehouse_closing_code,
    IFF(m.closing_date <= t.month_end, m.closing_date, NULL) AS warehouse_closing_date,

    -- warehouse_: collections in this month; read warehouse_reconciles_with_pam first
    COALESCE(k.collected_in_month, 0) AS warehouse_collected_in_month,

    -- asset_index_: this month's payments in the asset index
    COALESCE(ap.paid_in_month, 0) AS asset_index_paid_in_month,

    -- asset_index_vs_warehouse_: TRUE if both agree to the öre, empty if neither has a payment
    COALESCE(ap.paid_in_month, 0) - COALESCE(k.collected_in_month, 0)
        AS asset_index_vs_warehouse_paid_difference,
    IFF(
        ap.paid_in_month IS NULL AND k.collected_in_month IS NULL,
        NULL,
        ABS(COALESCE(ap.paid_in_month, 0) - COALESCE(k.collected_in_month, 0)) < 0.01
    ) AS asset_index_vs_warehouse_paid_matches,

    -- warehouse_vs_pam_: deal-wide check of warehouse payments against Intrum's monthly report
    ROUND(q.collection_reconciliation_total_pct, 5) AS warehouse_vs_pam_collection_total_pct,
    ROUND(q.collection_month_coverage_pct, 5) AS warehouse_vs_pam_month_coverage_pct,
    COALESCE(
        ABS(q.collection_reconciliation_total_pct) < $max_total_deviation_pct
            AND q.collection_month_coverage_pct > $min_month_coverage_pct,
        FALSE
    ) AS warehouse_reconciles_with_pam
FROM cases_owned AS o
CROSS JOIN month_base_reference AS t
CROSS JOIN pam_reconciliation AS q
INNER JOIN current_cases AS c
    ON c.case_bk = o.case_bk
LEFT JOIN cases_batch AS b
    ON b.case_bk = o.case_bk
LEFT JOIN cases_tape AS lt
    ON lt.case_bk = o.case_bk
LEFT JOIN asset_index_case AS a
    ON a.case_id = lt.tape_case_id
LEFT JOIN asset_index_counterparty AS p
    ON p.case_id = lt.tape_case_id
LEFT JOIN asset_index_attribute AS x
    ON x.case_id = lt.tape_case_id
LEFT JOIN registration_balance AS r
    ON r.case_bk = o.case_bk
LEFT JOIN monthly_cases_status AS m
    ON m.case_bk = o.case_bk
    AND m.month_end = t.month_end
LEFT JOIN cases_collection AS k
    ON k.case_bk = o.case_bk
    AND k.month_end = t.month_end
LEFT JOIN asset_index_payment AS ap
    ON ap.case_id = lt.tape_case_id
    AND ap.month_end = t.month_end
ORDER BY 1, 5;
