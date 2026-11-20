-- The source of the Cases chart's three tabs, Count / Collections / Average Collection per Case (the user,
-- 2026-10-12 and 2026-10-13): bars coloured by behaviour, with a legend that highlights. Sigma pins a
-- colour to a value only when the chart is coloured by one category column, so the behaviours become rows here.
-- Grain: one row per portfolio x reporting month x behaviour, for portfolio-months with a case feed
-- (1,150 portfolio-months x 7 behaviours = 8,050 rows on 2026-10-13; totals equal the live query's).
--
-- sigma_build/build_workbook.py prepends the live query as the CTE `main`, so every figure is the
-- dashboard's own to the case and the cent. This file is the rest of the statement and does not run on
-- its own.
--
-- The four paying groups split the month's collected cases with nothing left over and nothing counted
-- twice (the user, 2026-10-13: the bars must tally to the Cases total). A paying case is in exactly one,
-- by what it did in the two months before:
--
--   group                       2 months ago   last month   this month
--   New                              -             -          paid      first payment ever
--   Fresh                           no            no          paid      back after two quiet months, paid before
--   Two of Three Months         one of the two, not both      paid      (dbt's jitter in, plus second month running)
--   Three Consecutive Months       paid          paid         paid
--
-- dbt counts all but the third; it is collected cases minus dbt "new" (New plus Fresh) minus Three
-- Consecutive Months. 0 of 1,150 portfolio-months come out below zero (2026-10-13).
--
-- Euro tallies to the month's collections from cases the same way. One caveat, said in the definitions: dbt's
-- collections also hold cases whose month netted to zero or below (refunds, reversals), which belong to no
-- paying group. They land in Two of Three Months' euro, since that is the remainder (20 of 1,150 portfolio-months
-- leave it below zero there; -€23k in December 2025, the first month, when no case can yet be in the group).
--
-- Lost is a negative bar (the user, 2026-10-13): those cases did not pay this month, so they are not part of the
-- month's collected cases. Their euro is what they paid in their last paying month, also negative.
-- All Collected Cases is the month's total, for the Average Collection per Case tab only; the two stacked tabs filter
-- it out. The Average tab filters out the spacer (' ', below).

behaviours AS (
    -- Title Case: these values are the chart's legend. Sigma stacks and lists them alphabetically, the last at the
    -- bottom of the stack. Zero-width spaces (CHR(8203), invisible) sort after every letter, so more of them sorts
    -- later: Three Consecutive Months is the base of every bar, then Two of Three Months, Fresh, New on top; Lost
    -- sorts last in the legend. VALUES takes only literals.
    SELECT 'All Collected Cases' AS behaviour, 0 AS behaviour_order
    UNION ALL SELECT 'New', 1
    UNION ALL SELECT CHR(8203) || 'Fresh', 2
    UNION ALL SELECT REPEAT(CHR(8203), 2) || 'Two of Three Months', 3
    UNION ALL SELECT REPEAT(CHR(8203), 3) || 'Three Consecutive Months', 4
    UNION ALL SELECT REPEAT(CHR(8203), 4) || 'Lost', 5
    -- An invisible spacer worth Lost (the user, 2026-10-13: the number over each bar is the month's total). Sigma's
    -- bar total adds every segment, so it would net Lost off (August read 283,090, not 311,201); this cancels it.
    -- Named a single space: Sigma's legend leaves a blank value out, so it never shows (the user, 2026-10-13: a
    -- named "(Ignore - Formatting)" entry showed in the legend and looked bad). A space sorts before every letter,
    -- so it sits on top of the stack; the chart colours it white.
    UNION ALL SELECT ' ', 6
)

SELECT
    m.portfolio_name,
    m.country_name,
    m.servicer_group,
    m.seller,
    m.deal,   -- so the header's Deal filter reaches the chart (2026-10-12)
    m.reconciliation_status,
    m.is_reconciled_flag,
    m.reporting_month,
    b.behaviour,
    b.behaviour_order,
    CASE b.behaviour_order
        WHEN 0 THEN m.collected_cases_count
        WHEN 1 THEN m.collected_cases_first_collection_count
        WHEN 2 THEN m.collected_cases_new_count - m.collected_cases_first_collection_count
        WHEN 3 THEN m.collected_cases_count - m.collected_cases_new_count - m.collected_cases_consistent_3m_count
        WHEN 4 THEN m.collected_cases_consistent_3m_count
        WHEN 5 THEN -m.collected_cases_lost_count
        WHEN 6 THEN m.collected_cases_lost_count
    END                                 AS case_count,
    CASE b.behaviour_order
        WHEN 0 THEN m.collected_cases_amount_sum
        WHEN 1 THEN m.collected_cases_first_collection_amount_sum
        WHEN 2 THEN m.collected_cases_new_amount_sum - m.collected_cases_first_collection_amount_sum
        WHEN 3 THEN m.collected_cases_amount_sum - m.collected_cases_new_amount_sum
                    - m.collected_cases_three_consecutive_months_amount_sum
        WHEN 4 THEN m.collected_cases_three_consecutive_months_amount_sum
        WHEN 5 THEN -m.collected_cases_lost_last_month_amount_sum
        WHEN 6 THEN m.collected_cases_lost_last_month_amount_sum
    END                                 AS case_amount
FROM main AS m
CROSS JOIN behaviours AS b
-- A portfolio without a case feed reads blank on the Cases page, never zero: leave it out here too.
WHERE m.collected_cases_count IS NOT NULL
