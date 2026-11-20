-- How much MONEY does the booking_ind guard delete, per Intrum instance, on our books?
-- GRAIN   one row per affected instance. Money, not rows: a row count says nothing
--         about value, and the guard could in principle be removing only small change.
-- RUN     mise run sql -- work/data-issues/intrum/queries/booking_ind_money_by_instance.sql \
--             --connection dev --warehouse DEV_WH --lower
-- OURS ONLY: restricted to deals that appear in DIM_BATCH, which holds only books Brocc
-- has bought. The row-count version of this question is booking_ind_by_instance.sql and
-- covers every deal in the feed, ours or not.
-- ⚠ Amounts are stored sign-flipped in this feed, hence the leading minus.
-- ⚠ NOT DEDUPED. CAT is a change-history feed, so a payment can appear several times and
--   these totals are inflated by that. Both columns are inflated the same way, so the
--   PERCENTAGE is the figure to read; the absolute money is an upper bound.

WITH
    ours AS (

        SELECT DISTINCT
            servicer_parent_portfolio_bk AS deal
        FROM prod_npl_common.npl_common.dim_batch
),

    owned_cases AS (

        SELECT DISTINCT
            PARSE_JSON(c._file_metadata):system::string AS instance,
            c.case_id
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        INNER JOIN ours AS o
            ON o.deal = LEFT(c.long_portfolio_id, 7)
        WHERE PARSE_JSON(c._file_metadata):system::string
            IN ('1062', '2020', '7010', '7006', '4042')
)

SELECT
    t_instance AS instance,
    SUM(amount) AS money_total,
    SUM(IFF(COALESCE(booking_ind, 'N') <> 'Y', amount, 0)) AS money_surviving,
    SUM(IFF(booking_ind = 'Y', amount, 0)) AS money_deleted,
    ROUND(100 * SUM(IFF(booking_ind = 'Y', amount, 0))
        / NULLIF(SUM(amount), 0), 2) AS pct_money_deleted
FROM (
    SELECT
        PARSE_JSON(t._file_metadata):system::string AS t_instance,
        t.booking_ind,
        -t.amount::decimal(38, 2) AS amount
    FROM prod_raw.hyperion_intrum_cat.transactions AS t
    INNER JOIN owned_cases AS oc
        ON oc.case_id = t.case_id
        AND oc.instance = PARSE_JSON(t._file_metadata):system::string
    WHERE t.payment_cost_ind = 'P'
        AND t.amount IS NOT NULL
)
GROUP BY 1
ORDER BY 4 DESC
