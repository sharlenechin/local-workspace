-- ============================================================================
-- TIERED CASCADE FEASIBILITY. Measured 2026-10-19.
-- Only UK26004 gains: 368 on ref_1 -> 1,095 with ref_2 (31% -> 93%).
-- UK24020 gains nothing -- its 324 ref_2 hits are already covered by ref_1.
-- ⚠ TRUST ORDER IS PER-BOOK, NOT GLOBAL. UK26004 needs client_ref_2 FIRST;
-- a fixed ref_1-then-ref_2 order still works here but ranking ref_1 as the
-- "primary" key is wrong for that book.
-- ⚠ BOTH_AGREE counts loans hitting BOTH refs. Those need a conflict rule --
-- confirm the two resolve to the same CAT case before trusting either.
-- ============================================================================
-- Grain: one row per asset-index portfolio.
-- Why: test a trust-ordered waterfall (client_ref_1, then client_ref_2 for what
-- is left) rather than one rule. Measures the INCREMENT each tier adds, since a
-- second rule is only worth having if it hits loans the first one missed.
-- ⚠ CAT CASES is a change-history feed; match on DISTINCT reference values.
WITH ref1 AS (
    SELECT DISTINCT client_ref_1 AS ref FROM prod_raw.hyperion_intrum_cat.cases
    WHERE client_ref_1 IS NOT NULL
),

ref2 AS (
    SELECT DISTINCT client_ref_2 AS ref FROM prod_raw.hyperion_intrum_cat.cases
    WHERE client_ref_2 IS NOT NULL
),

ai AS (
    SELECT DISTINCT portfolio_id, case_id FROM dev.asset_index.cases
),

tiered AS (
    SELECT
        ai.portfolio_id,
        ai.case_id,
        r1.ref IS NOT NULL AS hit1,
        r2.ref IS NOT NULL AS hit2
    FROM ai
    LEFT JOIN ref1 AS r1 ON r1.ref = ai.case_id
    LEFT JOIN ref2 AS r2 ON r2.ref = ai.case_id
)

SELECT
    portfolio_id,
    COUNT(*) AS ai_cases,
    SUM(CASE WHEN hit1 THEN 1 ELSE 0 END) AS tier1_ref1,
    -- The increment: only loans tier 1 did not already cover.
    SUM(CASE WHEN NOT hit1 AND hit2 THEN 1 ELSE 0 END) AS tier2_adds,
    SUM(CASE WHEN hit1 OR hit2 THEN 1 ELSE 0 END) AS cascade_total,
    ROUND(100 * SUM(CASE WHEN hit1 OR hit2 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 2) AS pct_cascade,
    SUM(CASE WHEN hit1 AND hit2 THEN 1 ELSE 0 END) AS both_agree
FROM tiered
GROUP BY portfolio_id
HAVING SUM(CASE WHEN hit1 OR hit2 THEN 1 ELSE 0 END) > 0
ORDER BY cascade_total DESC;
