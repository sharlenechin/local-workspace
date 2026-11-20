-- Swedish payments that arrive with no transaction date, in RAW and after dbt.
-- GRAIN   one row per deal (six Swedish Intrum books).
-- RUN     mise run sql -- work/data-issues/intrum/queries/se_undated_payments.sql \
--             --connection dev --warehouse DEV_WH
-- WHY     Across all of raw CAT, 35% of payment rows have a NULL transaction_date. A payment
--         with no date cannot be placed on a collection curve. RAW_* counts are de-duplicated
--         on our own payment key so Intrum's resent history does not inflate them; undated
--         rows cannot use the date in that key, so they are de-duplicated on the rest of it.
-- ⚠ No date window here: an undated payment cannot be tested against the acquisition date,
--   so these are lifetime figures, not post-acquisition ones.

SET deals      = 'SE15044,SE16025,SE19026,SE20009,SE25018,SE25037';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH
    owned AS (

        SELECT
            LEFT(c.long_portfolio_id, 7) AS deal,
            PARSE_JSON(c._file_metadata):system::string AS source_system,
            c.case_id AS loan_id
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        WHERE (c._file_path LIKE $raw_prefix || '1062.cases.%'
                OR c._file_path LIKE $raw_prefix || '2080.cases.%')
            AND LEFT(c.long_portfolio_id, 7) IN (
                SELECT TRIM(value::string) FROM TABLE(SPLIT_TO_TABLE($deals, ','))
            )
            AND c.case_id NOT LIKE '%-%'
            AND COALESCE(c.real_case_ind, '') <> '1'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY PARSE_JSON(c._file_metadata):system::string, c.case_id
            ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
        ) = 1
),

    payment AS (

        SELECT DISTINCT
            o.deal,
            o.source_system,
            o.loan_id,
            t.transaction_date::date AS payment_date,
            t.amount_type_code,
            -t.amount::decimal(38, 2) AS amount  -- raw CAT signs payments negative
        FROM prod_raw.hyperion_intrum_cat.transactions AS t
        INNER JOIN owned AS o
            ON o.loan_id = t.case_id
            AND o.source_system = PARSE_JSON(t._file_metadata):system::string
        WHERE (t._file_path LIKE $raw_prefix || '1062.transactions.%'
                OR t._file_path LIKE $raw_prefix || '2080.transactions.%')
            AND t.payment_cost_ind = 'P'
            AND t.amount IS NOT NULL
)

SELECT
    deal,
    COUNT(*) AS raw_payments,
    COUNT_IF(payment_date IS NULL) AS raw_undated,
    ROUND(100 * COUNT_IF(payment_date IS NULL) / COUNT(*), 5) AS raw_undated_pct,
    ROUND(100 * SUM(IFF(payment_date IS NULL, amount, 0)) / NULLIF(SUM(amount), 0), 5)
        AS raw_undated_money_pct
FROM payment
GROUP BY 1
ORDER BY 1
