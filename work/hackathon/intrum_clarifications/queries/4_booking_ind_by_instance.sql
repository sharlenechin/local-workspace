-- Which Intrum instances does the booking_ind guard delete?
-- GRAIN   one row per Intrum instance (source system), across the whole CAT feed.
-- RUN     mise run sql -- work/data-issues/intrum/queries/booking_ind_by_instance.sql \
--             --connection dev --warehouse DEV_WH --lower
-- The guard in int_npl_case_collection_intrum.sql:14 is
--     and coalesce(booking_ind, 'N') != 'Y'
-- and it applies to EVERY instance, not only the two Swedish ones. An instance is
-- destroyed by it wherever the rows carrying an amount are the rows marked 'Y'.
-- SURVIVING_PCT is the share of payment money the guard leaves behind: 100 means the
-- guard is inert on that instance, 0 means it removes the instance's collections
-- entirely.
-- ⚠ No date bound and no portfolio filter: this is the whole feed, every deal.

SELECT
    PARSE_JSON(_file_metadata):system::string AS instance,
    COUNT(*) AS payment_rows,
    COUNT_IF(amount IS NOT NULL) AS rows_with_amount,
    COUNT_IF(booking_ind = 'Y') AS rows_marked_y,
    COUNT_IF(amount IS NOT NULL AND booking_ind = 'Y') AS with_amount_and_y,
    COUNT_IF(amount IS NOT NULL AND COALESCE(booking_ind, 'N') <> 'Y')
        AS survives_the_guard,
    ROUND(100 * COUNT_IF(amount IS NOT NULL AND COALESCE(booking_ind, 'N') <> 'Y')
        / NULLIF(COUNT_IF(amount IS NOT NULL), 0), 2) AS surviving_pct
FROM prod_raw.hyperion_intrum_cat.transactions
WHERE payment_cost_ind = 'P'
GROUP BY 1
ORDER BY 2 DESC
