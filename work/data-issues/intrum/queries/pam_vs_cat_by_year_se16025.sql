-- SE16025: CAT and PAM collections side by side, one row per year.
-- GRAIN   one row per calendar year of payment. Both sides are the same deal, the same
--         batches and the same post-acquisition window, so the two columns divide.
-- RUN     mise run sql -- work/data-issues/intrum/queries/pam_vs_cat_by_year_se16025.sql \
--             --connection dev --warehouse DEV_WH --lower
-- WHY     SE16025 reads 120.7% of PAM over its life, and the whole of that excess is in
--         2016-2019. From 2020 on the two agree to within a few percent. Measured
--         2026-11-02; SE15044 shows the same shape and the same break year, and SE19026
--         and SE20009, both bought after 2019, never show it at all. Written up in
--         ../pam-pre-2020-swedish-books.md.
-- SE16025 was bought 2016-12-01 and its cases were registered 2016-12-10 to 2017-04-13,
-- so the untrustworthy years are the book's first three -- and its heaviest collecting
-- ones (20.6m in 2017 and 25.7m in 2018, against ~12m a year from 2020).

SET deal       = 'SE16025';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH
    -- Intrum's own batch report, newest extract, actuals only.
    pam_rows AS (

        SELECT
            combined_ref,
            period_start_date::date AS period,
            colltotal
        FROM prod_raw.hyperion_intrum_pam.pam
        WHERE _file_path = (
                SELECT MAX(_file_path)
                FROM prod_raw.hyperion_intrum_pam.pam
                WHERE _file_path LIKE '%/pam.pam.pam.2%'
            )
            AND pmode_name = 'Real'
            AND COALESCE(is_ownership_change, 0) = 0
            AND portfolioid = $deal
),

    pam_year AS (

        SELECT
            YEAR(period) AS yr,
            SUM(colltotal) AS pam_collections
        FROM pam_rows
        GROUP BY 1
),

    acquisition AS (

        SELECT
            MIN(legacy_capex_date)::date AS acquisition_date
        FROM prod_npl_common.npl_common.dim_batch
        WHERE servicer_parent_portfolio_bk = $deal
),

    -- The cases we own, one row each. CAT is a change-history feed, so the newest
    -- version of each case wins.
    owned AS (

        SELECT
            PARSE_JSON(c._file_metadata):system::string AS source_system,
            c.case_id AS loan_id
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        WHERE (c._file_path LIKE $raw_prefix || '1062.cases.%'
                OR c._file_path LIKE $raw_prefix || '2080.cases.%')
            AND c.long_portfolio_id IN (SELECT DISTINCT combined_ref FROM pam_rows)
            AND c.case_id NOT LIKE '%-%'
            AND COALESCE(c.real_case_ind, '') <> '1'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY PARSE_JSON(c._file_metadata):system::string, c.case_id
            ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
        ) = 1
),

    cat_year AS (

        SELECT
            YEAR(payment_date) AS yr,
            SUM(amount) AS cat_collections
        FROM (
            SELECT
                t.transaction_date::date AS payment_date,
                -t.amount::decimal(38, 2) AS amount     -- stored sign-flipped
            FROM prod_raw.hyperion_intrum_cat.transactions AS t
            INNER JOIN owned AS o
                ON o.loan_id = t.case_id
                -- Instance as well as case_id: the id repeats across 1062 and 2080.
                AND o.source_system = PARSE_JSON(t._file_metadata):system::string
            CROSS JOIN acquisition AS a
            WHERE (t._file_path LIKE $raw_prefix || '1062.transactions.%'
                    OR t._file_path LIKE $raw_prefix || '2080.transactions.%')
                AND t.payment_cost_ind = 'P'           -- payments, not costs
                AND t.amount IS NOT NULL
                AND t.transaction_date::date >= a.acquisition_date
            -- Keyed on what identifies a real payment. ORIG_TR_ID does NOT work on this
            -- feed: one payment arrives under many ids, which overstates the book by a
            -- factor of several. AMOUNT_TYPE_CODE stays in the key because a payment is
            -- legitimately split across three of them.
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY o.source_system, t.case_id, t.transaction_date::date,
                    t.amount_type_code, t.amount
                ORDER BY COALESCE(t.record_updated, t.update_ts)::timestamp
                        DESC NULLS LAST,
                    TO_TIMESTAMP_NTZ(PARSE_JSON(t._file_metadata):extract_ts::string,
                        'YYYYMMDDTHH24MISS') DESC
            ) = 1
        )
        GROUP BY 1
)

SELECT
    c.yr,
    c.cat_collections,
    p.pam_collections,
    ROUND(100 * c.cat_collections / NULLIF(p.pam_collections, 0), 1) AS cat_pct_of_pam,
    c.cat_collections - p.pam_collections AS gap
FROM cat_year AS c
INNER JOIN pam_year AS p
    ON p.yr = c.yr
ORDER BY 1
