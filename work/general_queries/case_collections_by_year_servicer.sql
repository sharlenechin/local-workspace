-- ============================================================================
-- Collections coverage. ONE ROW PER (YEAR, SERVICER).
--
--   RUN    mise run sql -- work/general_queries/case_collections_by_year_servicer.sql
--   GRAIN  one row per calendar year of COLLECTION_DATE x reporting servicer.
--   WHY    "how many distinct loans has each servicer collected from, by year"
--
-- ⚠⚠ THERE IS NO period_end_date ON THIS FACT. FCT_CASE_COLLECTION is one row
--    per payment, dated by COLLECTION_DATE. The only month-grain case fact is
--    FCT_CASE_SNAPSHOT_DAILY (DATE_DAY, and despite the name it is month-end),
--    which carries balances, not collections.
--
-- ⚠⚠ NO AMOUNT IS SUMMED HERE. The fact carries CURRENCY_ID and no converted
--    measure, so SUM(amount) across currencies compiles and is wrong. Counts
--    are currency-safe; money needs a rate first.
--
-- ⚠ SERVICER_NAME is hardcoded one per feed on DIM_REPORTING_SYSTEM, so this
--   reads as "whose system reported the payment", not "who was contracted at
--   the time". A servicer handover is invisible here.
--
-- ⚠ CASE_ID is the durable key (case_dk) -- correct for counting loans across
--   their SCD versions. Counting CASE_SK instead would count versions.
-- ============================================================================

SELECT
    YEAR(c.collection_date)      AS collection_year,
    rs.servicer_name,
    COUNT(DISTINCT c.case_id)    AS distinct_cases,
    COUNT(*)                     AS payment_rows,
    MIN(c.collection_date)       AS first_payment,
    MAX(c.collection_date)       AS last_payment
FROM prod.npl_common.fct_case_collection AS c
LEFT JOIN prod.npl_common.dim_reporting_system AS rs
       ON rs.reporting_system_sk = c.reporting_system_sk
GROUP BY ALL
ORDER BY collection_year, distinct_cases DESC;
