-- What we own against what we can actually use, one row per deal.
-- GRAIN  one row per deal. Heimdall deals are shown under Intrum's id, every other
--        vehicle under its Atlas id, which is the id each source knows the deal by.
-- RUN    mise run sql -- work/workshop/deal_data_coverage.sql
-- SOURCE prod NPL_COMMON dims and facts (what we can use); raw Intrum PAM (what we own).
-- MONEY  every amount twice: _local in the deal's own currency, _eur converted at the
--        month-end PMI rate. Only the _eur columns may be added up.
-- GUARDS PAM pinned to one file, forecast months cut, statics de-repeated. Commented below.
WITH
    deal_from_dim_batch AS (

        SELECT
            b.servicer_parent_portfolio_bk AS servicer_id,
            MAX(b.deal_source_bk) AS vehicle,
            MAX(b.country_id) AS country,
            MAX(b.legal_seller_name) AS seller_name
        FROM prod.npl_common.dim_batch AS b
        WHERE b.servicer_parent_portfolio_bk IS NOT NULL
        GROUP BY 1
),

    deal_from_dim_portfolio AS (

        SELECT
            SUBSTR(p.portfolio_bk, 5, 7) AS atlas_id,
            MAX(COALESCE(d.deal_source_bk, LEFT(p.portfolio_bk, 3))) AS vehicle,
            MAX(d.country_id) AS country,
            MAX(d.seller_name) AS seller_name
        FROM prod.npl_common.dim_portfolio AS p
        LEFT JOIN prod.npl_common.dim_deal AS d
            ON d.deal_id = p.deal_id
        GROUP BY 1
),

-- Our Atlas id is not always the servicer's: SE25008 is Intrum's SE25018, SE25013 theirs
-- SE25037. Both feeds below are keyed on the servicer's, so carry the pair.
    atlas_to_servicer AS (

        SELECT
            SUBSTR(p.portfolio_bk, 5, 7) AS atlas_id,
            MAX(b.servicer_parent_portfolio_bk) AS servicer_id
        FROM prod.npl_common.dim_portfolio AS p
        INNER JOIN prod.npl_common.dim_batch AS b
            ON b.portfolio_sk = p.portfolio_sk
        WHERE b.servicer_parent_portfolio_bk IS NOT NULL
        GROUP BY 1
),

-- One row per deal we own, under the id its own vehicle knows it by. The QUALIFY is load
-- bearing: several Atlas ids can share one servicer id, which otherwise repeats the deal.
    deals_we_own AS (

        SELECT
            CASE WHEN COALESCE(a.vehicle, b.vehicle) = 'HEI'
                THEN COALESCE(c.servicer_id, b.servicer_id, a.atlas_id)
                ELSE COALESCE(a.atlas_id, b.servicer_id)
            END AS deal_id,
            COALESCE(a.atlas_id, b.servicer_id) AS atlas_id,
            COALESCE(c.servicer_id, b.servicer_id, a.atlas_id) AS servicer_id,
            COALESCE(a.vehicle, b.vehicle) AS vehicle,
            COALESCE(a.country, b.country) AS country,
            COALESCE(a.seller_name, b.seller_name) AS seller_name
        FROM deal_from_dim_portfolio AS a
        FULL OUTER JOIN deal_from_dim_batch AS b
            ON b.servicer_id = a.atlas_id
        LEFT JOIN atlas_to_servicer AS c
            ON c.atlas_id = a.atlas_id
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY CASE WHEN COALESCE(a.vehicle, b.vehicle) = 'HEI'
                    THEN COALESCE(c.servicer_id, b.servicer_id, a.atlas_id)
                    ELSE COALESCE(a.atlas_id, b.servicer_id) END
            ORDER BY a.atlas_id NULLS LAST
        ) = 1
),

-- Both facts are keyed on whichever id their own source knows, so every id a deal answers
-- to is resolved to one deal_id BEFORE aggregating. Joining on two ids with OR instead
-- matched one deal to two rows and counted its collections twice.
    id_to_deal AS (

        SELECT
            id,
            deal_id
        FROM (
            SELECT atlas_id AS id, deal_id FROM deals_we_own
            UNION
            SELECT servicer_id, deal_id FROM deals_we_own
        )
        QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY deal_id) = 1
),

-- G1. One monthly PAM file, pinned BY NAME: picking the newest timestamp returns the
-- perimeter file loaded seconds later, which carries none of these columns and no error.
    pam_newest_file AS (

        SELECT MAX(_file_path) AS file_path
        FROM raw.hyperion_intrum_pam.pam
        WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

    pam_rows AS (

        SELECT
            a.portfolioid AS servicer_id,
            a.combined_ref AS segment_id,
            LEFT(a.period_start_date, 10)::date AS period_month,
            LEFT(a.capex_date_m, 10)::date AS capex_month,
            a.currency,
            a.seller_name,
            a.colltotal,
            a.acqcases,
            a.acquisitionprincipal,
            a.rp_purchase_price,
            -- G4 input: the actual/forecast boundary is this file's own extract month.
            DATE_TRUNC('month', TO_TIMESTAMP_NTZ(
                PARSE_JSON(a._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'))::date
                AS extract_month
        FROM raw.hyperion_intrum_pam.pam AS a
        INNER JOIN pam_newest_file AS n
            ON a._file_path = n.file_path
        -- 'Adjust' rows are internal accounting, not the book.
        WHERE a.pmode_name = 'Real'
            -- G3. An ownership transfer repeats a segment-month and would double collections.
            AND COALESCE(a.is_ownership_change, 0) = 0
),

-- The statics repeat on EVERY month row of a segment, so summing rows overstates them 109x.
    pam_per_segment AS (

        SELECT
            servicer_id,
            segment_id,
            MAX(acqcases) AS cases_acquired,
            MAX(acquisitionprincipal) AS acquisition_principal,
            MAX(rp_purchase_price) AS purchase_price,
            MIN(capex_month) AS capex_month,
            MAX(currency) AS currency,
            MAX(seller_name) AS seller_name
        FROM pam_rows
        GROUP BY 1, 2
),

    pam_book_per_deal AS (

        SELECT
            servicer_id,
            SUM(cases_acquired) AS pam_cases_acquired,
            SUM(acquisition_principal) AS pam_acquisition_principal,
            SUM(purchase_price) AS pam_purchase_price,
            MIN(capex_month) AS pam_capex_date,
            MAX(seller_name) AS pam_seller_name,
            MAX(currency) AS pam_currency,
            COUNT(DISTINCT currency) AS pam_currencies,
            COUNT(*) AS pam_segments
        FROM pam_per_segment
        GROUP BY 1
),

-- G4. Forecast months run out to 2040 and are all flagged 'Real', so the file's own extract
-- month is the only boundary; without it every deal gains trailing zero-payment months.
    pam_collections_per_deal AS (

        SELECT
            servicer_id,
            SUM(colltotal) AS pam_collections_local,
            COUNT(DISTINCT period_month) AS pam_months,
            MAX(period_month) AS pam_latest_month
        FROM pam_rows
        WHERE period_month < extract_month
        GROUP BY 1
),

-- One rate per currency, the month-end PMI rate at the latest month the table covers. A
-- single rate, not each month's own: CAT and PAM put the same payment in different months,
-- and a per-month rate would turn that timing difference into a fake money difference.
    fx_to_eur AS (

        SELECT
            x.quote_currency AS currency,
            x.ultimo_value AS rate_to_eur
        FROM prod.common.fct_exchange_rate_monthly AS x
        INNER JOIN (
            SELECT MAX(date_day) AS latest_month_end
            FROM prod.common.fct_exchange_rate_monthly
            WHERE base_currency = 'EUR' AND rate_type = 'PMI'
        ) AS l
            ON x.date_day = l.latest_month_end
        -- The month key is the month END; truncating it to month-start returns NULL for
        -- every non-EUR currency, which once understated collections by 47.3%.
        WHERE x.base_currency = 'EUR'
            AND x.rate_type = 'PMI'
            AND x.quote_currency <> 'EUR'

        UNION ALL

        -- EUR has no row of its own, and without it every EUR deal converts to NULL.
        SELECT 'EUR', 1
),

-- A deal reaches the collection fact by two ids, as in bridge-scan's collections.sql.
    deal_batches AS (

        SELECT
            DISTINCT
            b.batch_sk,
            b.servicer_parent_portfolio_bk AS servicer_id
        FROM prod.npl_common.dim_batch AS b
        WHERE b.servicer_parent_portfolio_bk IS NOT NULL
),

    deal_portfolios AS (

        SELECT
            DISTINCT
            p.portfolio_sk,
            SUBSTR(p.portfolio_bk, 5, 7) AS atlas_id
        FROM prod.npl_common.dim_portfolio AS p
),

-- UNION, not a side-by-side join: a payment both paths reach is one payment, but two ids
-- that reach the same payment are two answers.
    prod_payments AS (

        SELECT
            DISTINCT
            b.servicer_id AS id,
            c.collection_bk,
            c.case_id,
            c.collection_date,
            c.amount,
            c.currency_id
        FROM prod.npl_common.fct_case_collection AS c
        INNER JOIN deal_batches AS b
            ON b.batch_sk = c.batch_sk

        UNION

        SELECT
            DISTINCT
            p.atlas_id,
            c.collection_bk,
            c.case_id,
            c.collection_date,
            c.amount,
            c.currency_id
        FROM prod.npl_common.fct_case_collection AS c
        INNER JOIN deal_portfolios AS p
            ON p.portfolio_sk = c.portfolio_sk
),

-- PAM stops at its file's extract month while PROD runs to today, so comparing the two
-- totals as they stand credits PROD with months PAM cannot have. This is each deal's PAM
-- cut-off, used below to bound a like-for-like figure beside the full one.
    pam_cutoff_per_deal AS (

        SELECT
            k.deal_id,
            MAX(a.pam_latest_month) AS pam_cutoff
        FROM pam_collections_per_deal AS a
        INNER JOIN id_to_deal AS k
            ON k.id = a.servicer_id
        GROUP BY 1
),

    prod_collections_per_deal AS (

        SELECT
            k.deal_id,
            MAX(a.currency_id) AS prod_currency,
            COUNT(DISTINCT a.currency_id) AS prod_currencies,
            COUNT(DISTINCT a.case_id) AS prod_cases_with_a_payment,
            SUM(a.amount) AS prod_collections_local,
            SUM(a.amount * f.rate_to_eur) AS prod_collections_eur,
            SUM(CASE WHEN cut.pam_cutoff IS NULL
                    OR DATE_TRUNC('month', a.collection_date)::date <= cut.pam_cutoff
                THEN a.amount * f.rate_to_eur END) AS prod_collections_eur_to_pam_month,
            COUNT(DISTINCT DATE_TRUNC('month', a.collection_date)::date) AS prod_months,
            MAX(a.collection_date) AS prod_latest_payment
        FROM prod_payments AS a
        INNER JOIN id_to_deal AS k
            ON k.id = a.id
        LEFT JOIN pam_cutoff_per_deal AS cut
            ON cut.deal_id = k.deal_id
        LEFT JOIN fx_to_eur AS f
            ON f.currency = a.currency_id
        GROUP BY 1
)
SELECT
    -- Heimdall deals are known by Intrum's id, every other vehicle by its Atlas id.
    a.deal_id,
    a.vehicle,
    a.atlas_id,
    a.servicer_id,
    a.country,
    COALESCE(a.seller_name, b.pam_seller_name) AS seller_name,
    b.pam_capex_date AS capex_date,
    -- The deal's own currency, and the rate every _eur column below was converted at.
    COALESCE(b.pam_currency, p.prod_currency) AS currency,
    fx.rate_to_eur,
    b.pam_cases_acquired AS cases_acquired,
    b.pam_acquisition_principal AS capex_amount_local,
    b.pam_acquisition_principal * fx.rate_to_eur AS capex_amount_eur,
    b.pam_purchase_price AS purchase_price_local,
    b.pam_purchase_price * fx.rate_to_eur AS purchase_price_eur,
    -- Left empty on purpose: filled from the asset-index runs, which are not in the warehouse.
    NULL AS in_asset_index,
    NULL AS bridge_account_coverage_pct,
    p.prod_months,
    c.pam_months,
    p.prod_collections_local,
    c.pam_collections_local,
    p.prod_collections_eur,
    -- The only PROD figure that may be compared with PAM: same months on both sides.
    p.prod_collections_eur_to_pam_month,
    c.pam_collections_local * fx.rate_to_eur AS pam_collections_eur,
    p.prod_latest_payment,
    c.pam_latest_month,
    p.prod_cases_with_a_payment,
    b.pam_currencies,
    p.prod_currencies
FROM deals_we_own AS a
LEFT JOIN pam_book_per_deal AS b
    ON b.servicer_id = a.servicer_id
LEFT JOIN pam_collections_per_deal AS c
    ON c.servicer_id = a.servicer_id
LEFT JOIN prod_collections_per_deal AS p
    ON p.deal_id = a.deal_id
LEFT JOIN fx_to_eur AS fx
    ON fx.currency = COALESCE(b.pam_currency, p.prod_currency)
ORDER BY 1;
