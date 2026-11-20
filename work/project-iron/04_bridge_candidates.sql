-- Grain: one row per deal and candidate column in RAW CAT's CASES table.
--
-- Answers the question asked before a tape is mapped: which Intrum column should the asset
-- index's case_id be matched to, and which its counterparty_id? The bridge is only as good as
-- that choice, and the choice is measurable rather than a matter of taste. A column holding one
-- value per case can carry a case key; a column whose values genuinely repeat across cases can
-- carry a party key; a column under half filled can carry neither.
--
-- Measured 2026-10-28 on PT15018, PT16023 and PT18019. Two things came out of it:
--
--   CLIENT_REF_1 is the only column filled on 100% of cases on all three, which is why the live
--   bridge uses it. It is the *seller's* reference, so its shape changes by deal: 3-9 characters
--   on the Millennium deals, 19 zero-padded digits on PT18019.
--
--   No column in CASES is party-grained on any of the three. Every usable one holds about one
--   value per case. So a counterparty key is not something Intrum supplies -- the party grain
--   comes from the tape, and CLIENT_REF_1 is matched against whatever the tape calls its
--   counterparty id. Read a 'counterparty_id' verdict below as rare and worth checking by hand.
--
-- How to read a row: take the best-covered column whose grain matches the tape column you are
-- mapping, prefer one with no COLLISIONS_IF_UNPADDED, and use an amount marked Verifier to prove
-- the match cent-exact afterwards. Ignore anything marked 'Not an entity key'.
--
-- This profiles the Intrum side only. Whether a tape column actually hits these values is
-- measured by the bridge itself in 01_accounts.sql, once the tape is loaded.
--
-- To use: put the deal ids in $deals and the Intrum instance in $cat_instance. Nothing else to
-- edit. The instance matters because CASE_ID is unique only within one (guard C4).

SET deals = 'PT15018,PT16023,PT18019';
SET cat_instance = '4050';

WITH deal_list AS (
    SELECT TRIM(value::string) AS portfolio_id
    FROM TABLE(SPLIT_TO_TABLE($deals, ','))
),

-- Every version of every case, not the latest one. A client reference changes over a case's
-- life, and deduplicating to the newest row first drops PT06002 from 99% matched to 18%.
case_versions AS (
    SELECT
        LEFT(a.long_portfolio_id, 7) AS portfolio_id,
        a.case_id,
        a.client_ref_1,
        a.client_ref_2,
        a.client_ref_extra,
        a.ref_case_id,
        a.main_debtor,
        a.client_number,
        a.master_cl_number,
        a.debt_enforcement_number,
        a.original_capital,
        a.remaining_capital,
        a.principal_at_cutoff,
        a.original_balance_at_client
    FROM prod_raw.hyperion_intrum_cat.cases AS a
    INNER JOIN deal_list AS b
        ON b.portfolio_id = LEFT(a.long_portfolio_id, 7)
    WHERE a._file_path LIKE
            'data-prod-data-raw-sftp-071269be/intrum/cat.' || $cat_instance || '.cases.%'
        AND a.case_id NOT LIKE '%-%'        -- C9: hyphenated ids are not real cases
),

deal_size AS (
    SELECT
        portfolio_id,
        COUNT(DISTINCT case_id) AS cases_in_deal
    FROM case_versions
    GROUP BY portfolio_id
),

-- Each candidate as (case, value). Amounts are cast to text and profiled the same way, because
-- the question about them is the same one: how many cases share a value. An amount shared by
-- dozens of cases cannot verify a bridge; one that is near-unique can.
candidates AS (
    SELECT portfolio_id, case_id, 'reference' AS kind, 'client_ref_1' AS candidate,
        NULLIF(TRIM(client_ref_1), '') AS value FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'reference', 'client_ref_2',
        NULLIF(TRIM(client_ref_2), '') FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'reference', 'client_ref_extra',
        NULLIF(TRIM(client_ref_extra), '') FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'reference', 'ref_case_id',
        NULLIF(TRIM(ref_case_id), '') FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'reference', 'main_debtor',
        NULLIF(TRIM(main_debtor), '') FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'reference', 'client_number',
        NULLIF(TRIM(client_number), '') FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'reference', 'master_cl_number',
        NULLIF(TRIM(master_cl_number), '') FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'reference', 'debt_enforcement_number',
        NULLIF(TRIM(debt_enforcement_number), '') FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'amount', 'original_capital',
        TO_VARCHAR(NULLIF(original_capital, 0)) FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'amount', 'remaining_capital',
        TO_VARCHAR(NULLIF(remaining_capital, 0)) FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'amount', 'principal_at_cutoff',
        TO_VARCHAR(NULLIF(principal_at_cutoff, 0)) FROM case_versions
    UNION ALL SELECT portfolio_id, case_id, 'amount', 'original_balance_at_client',
        TO_VARCHAR(NULLIF(original_balance_at_client, 0)) FROM case_versions
),

-- Every deal crossed with every candidate, so a column no deal populates still reports a row.
-- A column that silently disappears from the output reads as untested rather than as empty.
candidate_inventory AS (
    SELECT DISTINCT a.portfolio_id, b.kind, b.candidate
    FROM deal_list AS a
    CROSS JOIN (SELECT DISTINCT kind, candidate FROM candidates) AS b
),

filled AS (
    SELECT * FROM candidates WHERE value IS NOT NULL
),

-- How many cases each value covers. This is the whole signal: 1.0 says case grain, and anything
-- meaningfully above says the value is shared, which is what a borrower reference looks like.
value_spread AS (
    SELECT
        portfolio_id,
        candidate,
        value,
        COUNT(DISTINCT case_id) AS cases_on_value
    FROM filled
    GROUP BY portfolio_id, candidate, value
),

shape AS (
    SELECT
        portfolio_id,
        candidate,
        COUNT(DISTINCT case_id) AS cases_with_value,
        COUNT(DISTINCT value) AS distinct_values,
        -- Leading zeros are padding, not part of a reference: PT18019's tape carries 16 digits
        -- against CAT's 19 and bridges at 0% until both sides are stripped. If the two counts
        -- below differ, stripping would merge references that are genuinely distinct, and the
        -- deal has to be matched on the padded form instead.
        COUNT(DISTINCT LTRIM(value, '0')) AS distinct_values_unpadded,
        COUNT(DISTINCT CASE WHEN value LIKE '0%' THEN value END) AS values_zero_padded,
        MIN(LENGTH(value)) AS min_length,
        MAX(LENGTH(value)) AS max_length
    FROM filled
    GROUP BY portfolio_id, candidate
),

spread AS (
    SELECT
        portfolio_id,
        candidate,
        MAX(cases_on_value) AS max_cases_per_value,
        ROUND(AVG(cases_on_value), 5) AS avg_cases_per_value,
        ROUND(100.0 * COUNT_IF(cases_on_value = 1) / COUNT(*), 5) AS pct_values_on_one_case
    FROM value_spread
    GROUP BY portfolio_id, candidate
),

measured AS (
    SELECT
        a.portfolio_id,
        a.kind,
        a.candidate,
        d.cases_in_deal,
        COALESCE(b.cases_with_value, 0) AS cases_with_value,
        ROUND(100.0 * COALESCE(b.cases_with_value, 0) / d.cases_in_deal, 5) AS coverage_pct,
        COALESCE(b.distinct_values, 0) AS distinct_values,
        c.avg_cases_per_value,
        c.max_cases_per_value,
        c.pct_values_on_one_case,
        b.min_length,
        b.max_length,
        COALESCE(b.values_zero_padded, 0) AS values_zero_padded,
        -- Non-zero means stripping the padding would collide two real references.
        COALESCE(b.distinct_values - b.distinct_values_unpadded, 0) AS collisions_if_unpadded,
        -- The share of the book sitting on the single commonest value. A column where one value
        -- covers half the deal is a flag or a client code, whatever its cardinality elsewhere:
        -- MAIN_DEBTOR looks party-like on its average and is a debtor row number, with '1' on
        -- every case in the book.
        ROUND(100.0 * c.max_cases_per_value / d.cases_in_deal, 5) AS pct_on_commonest_value
    FROM candidate_inventory AS a
    INNER JOIN deal_size AS d
        ON d.portfolio_id = a.portfolio_id
    LEFT JOIN shape AS b
        ON b.portfolio_id = a.portfolio_id AND b.candidate = a.candidate
    LEFT JOIN spread AS c
        ON c.portfolio_id = a.portfolio_id AND c.candidate = a.candidate
)

SELECT
    portfolio_id,
    kind,
    candidate,
    cases_in_deal,
    cases_with_value,
    coverage_pct,
    distinct_values,
    avg_cases_per_value,
    max_cases_per_value,
    pct_values_on_one_case,
    pct_on_commonest_value,
    min_length,
    max_length,
    values_zero_padded,
    collisions_if_unpadded,
    -- Ordered so the disqualifying facts are tested before the grain is read. A column can look
    -- party-grained on its average and still be a flag, so dominance is checked first.
    CASE
        WHEN cases_with_value = 0
            THEN 'Empty - this deal does not send it'
        WHEN distinct_values <= 2 OR pct_on_commonest_value >= 50
            THEN 'Not an entity key - a client code or a flag, one value covers the book'
        WHEN coverage_pct < 50
            THEN 'Unusable - under half the cases carry it'
        WHEN kind = 'amount' AND pct_values_on_one_case >= 95
            THEN 'Verifier - near-unique, can confirm a bridge cent-exact'
        WHEN kind = 'amount'
            THEN 'Weak verifier - too many cases share a value'
        WHEN avg_cases_per_value < 1.02 AND distinct_values = cases_with_value
            THEN 'case_id - exactly one value per case'
        WHEN avg_cases_per_value < 1.02
            THEN 'case_id (near) - one per case, a few cases carry two'
        WHEN pct_values_on_one_case < 90
            THEN 'counterparty_id - values genuinely repeat across cases'
        ELSE 'Check by hand - mostly one per case, a few values cover many'
    END AS suggested_role
FROM measured
ORDER BY portfolio_id, kind, coverage_pct DESC, candidate;
