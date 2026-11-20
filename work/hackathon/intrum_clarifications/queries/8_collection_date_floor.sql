-- Where does FCT_CASE_COLLECTION start, and what sits before that in the raw feed?
-- GRAIN   one row per source. The mart is bounded by the SCD inner join in
--         int_npl_case_collection_conformed, which keeps a payment only when
--         transaction_date >= the case's valid_from. A case cannot be valid before the
--         feed first saw it, so early payments are dropped with no filter saying so.
-- RUN     mise run sql -- work/data-issues/intrum/queries/collection_date_floor.sql \
--             --connection dev --warehouse DEV_WH --lower
-- ⚠ CAT transaction dates run to the year 2121 on this feed; sentinel years sit on
--   superseded versions. The counts below are not date-bounded at the top end.

SELECT
    1 AS n,
    'dbt mart FCT_CASE_COLLECTION' AS source,
    MIN(collection_date)::string AS earliest,
    MAX(collection_date)::string AS latest,
    COUNT(*) AS rows_held,
    COUNT_IF(collection_date < '2014-01-01') AS before_2014
FROM prod_npl_common.npl_common.fct_case_collection
UNION ALL
SELECT
    2,
    'case dimension effective_from_date',
    MIN(effective_from_date)::string,
    MAX(effective_from_date)::string,
    COUNT(*),
    COUNT_IF(effective_from_date < '2014-01-01')
FROM prod_npl_common.npl_common.dim_case
UNION ALL
SELECT
    3,
    'raw CAT transactions, payments only',
    MIN(transaction_date)::string,
    MAX(transaction_date)::string,
    COUNT(*),
    COUNT_IF(transaction_date < '2014-01-01')
FROM prod_raw.hyperion_intrum_cat.transactions
WHERE payment_cost_ind = 'P'
    AND amount IS NOT NULL
ORDER BY 1
