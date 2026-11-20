-- ============================================================================
-- Coverage: how many loans we can SEE, against how many we can see a PAYMENT
-- for. ONE ROW PER SERVICER.
--
--   RUN    mise run sql -- work/general_queries/cases_vs_collections_by_servicer.sql
--   GRAIN  one row per servicer. 5 rows, measured 2026-10-12.
--   WHY    "do we get cases from Cerved and Gescobro?" Yes -- and no money.
--
-- Measured 2026-10-12:
--   intrum    20,189,915 cases   3,397,615 with any payment   16.83%
--   gescobro   1,795,692 cases           0                     0.00%
--   cerved       394,205 cases           0                     0.00%
--   souq          57,781 cases           0                     0.00%
--   massey        48,784 cases      48,010                    98.41%
--
-- ⚠⚠ A ZERO HERE IS NOT "NOBODY PAID". Three different things produce it and
--    this query cannot separate them:
--      1 the SCD left edge -- int_npl_case_collection_conformed inner-joins
--        collections to the case SCD, so every payment before Brocc's first
--        CAT snapshot of that case is dropped. A loan whose payments ALL
--        predate it reads as zero. Worth 42-58% of collections on Portugal.
--      2 genuinely never-paid -- real and large; the benchmark work measured
--        59.5% of loans with no payment at all.
--      3 undated cash -- a NULL collection_date fails the >= and is dropped.
--        PROD holds ZERO null-dated rows of 134,472,689.
--    So 16.83% is a fact about a join, not about borrowers.
--
-- ⚠⚠ GESCOBRO, CERVED AND SOUQ HAVE NO COLLECTION MODEL AT ALL -- 2,247,678
--    loans with not one payment row between them. Intrum and Massey are the
--    only sources that reach fct_case_collection. (Massey arrives through the
--    generic_intermediate_case_collection macro, not its own model file,
--    which is why it is easy to miss.)
--
-- ⚠ CASE_ID is the durable key (case_dk), so this counts LOANS. Counting
--   case_sk would count SCD versions -- 20.2m loans are 154m versions.
--
-- ⚠ IS_CURRENT_FLAG is required on dim_case. Without it every loan is counted
--   once per historical version.
--
-- ⚠ SERVICER_NAME is hardcoded one per feed on dim_reporting_system, so this
--   reads as "whose system reported it", not "who was contracted at the time".
-- ============================================================================

WITH cases AS (
    SELECT
        COALESCE(rs.servicer_name, '(unmapped)') AS servicer,
        dc.case_id
    FROM prod.npl_common.dim_case AS dc
    LEFT JOIN prod.npl_common.dim_reporting_system AS rs
           ON rs.reporting_system_sk = dc.reporting_system_sk
    WHERE dc.is_current_flag = TRUE
),

-- Collapsed to one row per loan BEFORE the join, so a loan with 400 payments
-- cannot multiply the case count.
paid AS (
    SELECT DISTINCT case_id
    FROM prod.npl_common.fct_case_collection
)

SELECT
    c.servicer,
    COUNT(DISTINCT c.case_id) AS cases,
    COUNT(DISTINCT CASE WHEN p.case_id IS NOT NULL THEN c.case_id END)
        AS cases_with_any_payment,
    ROUND(
        100 * COUNT(DISTINCT CASE WHEN p.case_id IS NOT NULL THEN c.case_id END)
        / NULLIF(COUNT(DISTINCT c.case_id), 0), 2
    ) AS pct_with_any_payment
FROM cases AS c
LEFT JOIN paid AS p
       ON p.case_id = c.case_id
GROUP BY ALL
ORDER BY cases DESC;
