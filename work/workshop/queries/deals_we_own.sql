-- Every deal we own today, and what it looked like when it was first bought.
-- GRAIN  one row per deal, keyed VEHICLE-ID (HEI-PT13982, LOK-SE25008). Heimdall deals
--        take Intrum's id (DIM_BATCH's SERVICER_PARENT_PORTFOLIO_BK), every other vehicle
--        our Atlas id (DIM_PORTFOLIO's PORTFOLIO_BK, characters 5-11). Measured
--        2026-11-03: 2,674 deals.
-- RUN    mise run sql -- work/workshop/queries/deals_we_own.sql
-- SOURCE PROD NPL_COMMON only: DIM_BATCH, DIM_PORTFOLIO, DIM_DEAL, DIM_CASE and the case
--        snapshot, plus COMMON's FX table.
--
-- ONE PURCHASE PER ROW: the first time the book was bought. acquired_by says by whom:
--   Intrum          Heimdall: Intrum's own purchase, from PAM. Brocc bought Heimdall in
--                   December 2025.
--   Brocc (Lokki)   Lokki is Brocc's vehicle, so PAM's figures are our own purchase.
--   previous owner  the legacy Spanish and Italian books, from the servicers' seeds.
--   Brocc           GCB and ORG: Brocc bought first, so the figures are Atlas's.
-- Where the servicer gives a capex date (DIM_BATCH's legacy_* columns) those figures win
-- over Atlas. Atlas dates every pre-2026 Lokki deal 2025-12-01, the day it moved onto
-- Atlas, not the day it was bought; its GBV is 0 on 13 of 50 Lokki deals; and UK25032's
-- principal reads 55.8bn against a 7.2m price (measured 2026-11-03). The two sources are
-- never mixed on one row, so price / balance is always one purchase's ratio. A figure the
-- chosen source lacks stays NULL rather than being borrowed from the other.
--
-- MARKET. A market is country x sector ('SE · Financial Services'). The sector comes from
-- PAM's product, below, so every deal lands in one and nothing drops out: the 745 'Other'
-- deals and the 12 PAM never reported both sit in Unclassified, which is the honest
-- answer for them. product_type keeps the finer grain beside it. Measured 2026-11-03.
--
-- SECTOR. The 14 products collapse to two: Financial Services is everything bank-like,
-- where the debt began as credit (bank loans, credit cards, consumer finance, real
-- estate); Non-Financial Services is everything else, where the debt began as an unpaid
-- bill (telecom, utilities, mail order, insurance, VAT). Insurance sits on the
-- non-financial side deliberately: the claim is an unpaid premium, not a loan.
-- PAM's own catch-all 'Other' is 745 deals and cannot be read either way, so it is
-- Unclassified rather than guessed at. Measured 2026-11-03.
--
-- BALANCE. From PAM and the seeds it is principal only: neither carries interest, fees or
-- costs at acquisition. From Atlas it is GBV (principal + interest + fees), falling back to
-- principal where GBV is 0. balance_basis says which.
WITH
    batch AS (

        SELECT
            b.batch_sk,
            -- ORG batches carry no deal source of their own; the Atlas key starts with it.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle,
            -- Heimdall's Atlas portfolio is a whole country's umbrella (HEI-SE25001 holds
            -- every Swedish Heimdall deal), so only Intrum's id names the deal there.
            IFF(
                COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
                b.servicer_parent_portfolio_bk,
                SUBSTR(p.portfolio_bk, 5, 7)
            ) AS deal_id,
            b.country_id,
            b.currency_id,
            -- PAM's BRANCH_DESC. The product half of the market.
            b.original_product_name AS product_type,
            -- The capex this batch's registration is measured from: the earlier buyer's,
            -- else Brocc's own.
            COALESCE(b.legacy_capex_date, p.capex_date) AS reference_capex_date,
            -- PAM's 'Ongoing' is Intrum buying new defaults every period: forward flow.
            IFF(b.deal_type = 'Ongoing', 'Forward', b.deal_type) AS flow_type,
            b.legacy_capex_date,
            b.legacy_capex_amount,
            b.legacy_case_count,
            b.legacy_principal
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
),

-- Registration per batch: the first case registered ON OR AFTER the capex month. The plain
-- first date is wrong: 25.9% of Heimdall cases were registered with Intrum before
-- Intrum bought them (it serviced them first), so on 1,041 of 2,337 deals the earliest
-- date is over 3 months before capex. A deal whose cases ALL predate capex (428 Heimdall,
-- 5 Lokki) comes back NULL rather than with that earlier date. Measured 2026-11-03.
-- DIM_CASE has no batch key, so the snapshot supplies the case-to-batch link (38 s).
-- LEG and GCB cases carry no registration date at all, so those deals are NULL too.
    batch_registration AS (

        SELECT
            s.batch_sk,
            MIN(c.registration_date) AS first_registration_date
        FROM (
            SELECT DISTINCT batch_sk, case_id
            FROM prod.npl_common.fct_case_snapshot_daily
        ) AS s
        INNER JOIN batch AS b
            ON b.batch_sk = s.batch_sk
        INNER JOIN prod.npl_common.dim_case AS c
            ON c.case_id = s.case_id
            AND c.is_current_flag
        -- Also drops the 8,577 Heimdall cases dated 1900-01-01, a placeholder.
        WHERE c.registration_date >= DATE_TRUNC('month', b.reference_capex_date)
        GROUP BY 1
),

-- One product per deal, so a market is one row. 13 of 2,674 deals were bought across two
-- products -- SE19012 is 356m of bank loans and 105m of credit cards -- and each takes the
-- product holding the most principal, which is a clear majority on 12 of the 13. AT03004
-- splits 50k/50k and is settled alphabetically. Measured 2026-11-03.
    deal_product AS (

        SELECT
            deal_id,
            product_type
        FROM (
            SELECT
                b.deal_id,
                b.product_type,
                SUM(b.legacy_principal) AS principal
            FROM batch AS b
            WHERE b.deal_id IS NOT NULL
                AND b.product_type IS NOT NULL
            GROUP BY 1, 2
        )
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY deal_id
            ORDER BY principal DESC NULLS LAST, product_type
        ) = 1
),

    from_batches AS (

        SELECT
            b.deal_id,
            MAX(b.vehicle) AS vehicle,
            -- DIM_BATCH says GB, DIM_DEAL says UK: one code, so a filter finds both.
            MAX(IFF(b.country_id = 'UK', 'GB', b.country_id)) AS country,
            MAX(b.currency_id) AS currency,
            MAX(b.flow_type) AS flow_type,
            MIN(r.first_registration_date) AS registration_date,
            MIN(b.legacy_capex_date) AS capex_date,
            -- DIM_BATCH is one row per batch already (dbt takes the price from the batch's
            -- first PAM month), so these sum across batches without PAM's 109x repeat.
            SUM(b.legacy_capex_amount) AS purchase_price,
            SUM(b.legacy_case_count) AS cases_acquired,
            SUM(b.legacy_principal) AS principal,
            COUNT(*) AS batches
        FROM batch AS b
        LEFT JOIN batch_registration AS r
            ON r.batch_sk = b.batch_sk
        -- One Gescobro batch (MILAN_MILAN_Z) maps to no Atlas portfolio, so it has no id
        -- to sit under. It carries no figures; MILAN's real batches are under ES26004.
        WHERE b.deal_id IS NOT NULL
        GROUP BY 1
),

-- Brocc's own purchase, per Atlas deal. Heimdall is left out: its Atlas rows are country
-- umbrellas, not deals.
    from_atlas AS (

        SELECT
            SUBSTR(p.portfolio_bk, 5, 7) AS deal_id,
            MAX(LEFT(p.portfolio_bk, 3)) AS vehicle,
            MAX(IFF(d.country_id = 'UK', 'GB', d.country_id)) AS country,
            MAX(p.currency_id) AS currency,
            MAX(p.flow_type) AS flow_type,
            MIN(p.capex_date) AS capex_date,
            SUM(p.price_gross) AS purchase_price,
            SUM(p.gbv) AS gbv,
            SUM(p.principal) AS principal
        FROM prod.npl_common.dim_portfolio AS p
        LEFT JOIN prod.npl_common.dim_deal AS d
            ON d.deal_id = p.deal_id
        WHERE LEFT(p.portfolio_bk, 3) <> 'HEI'
        GROUP BY 1
),

-- Latest month-end PMI rate per currency, so the _eur columns can be added up.
    fx_to_eur AS (

        SELECT
            x.quote_currency AS currency,
            x.ultimo_value AS rate_to_eur
        FROM prod.common.fct_exchange_rate_monthly AS x
        WHERE x.base_currency = 'EUR'
            AND x.rate_type = 'PMI'
            AND x.quote_currency <> 'EUR'
        -- The key is the month END: truncating it to month-start finds no non-EUR rate.
        QUALIFY x.date_day = MAX(x.date_day) OVER ()

        UNION ALL

        -- EUR has no row of its own; without this every EUR deal converts to NULL.
        SELECT 'EUR', 1
),

    deal AS (

        SELECT
            COALESCE(b.deal_id, a.deal_id) AS deal_id,
            COALESCE(b.vehicle, a.vehicle) AS vehicle,
            COALESCE(b.country, a.country) AS country,
            COALESCE(b.currency, a.currency) AS currency,
            -- The servicer's figures are used whenever it gave a capex date.
            b.capex_date IS NOT NULL AS earlier_buyer,
            b.registration_date,
            b.batches,
            b.flow_type AS earlier_flow_type,
            b.capex_date AS earlier_capex_date,
            b.purchase_price AS earlier_purchase_price,
            b.cases_acquired AS earlier_cases_acquired,
            b.principal AS earlier_principal,
            a.flow_type AS brocc_flow_type,
            a.capex_date AS brocc_capex_date,
            a.purchase_price AS brocc_purchase_price,
            a.gbv AS brocc_gbv,
            a.principal AS brocc_principal
        FROM from_batches AS b
        FULL OUTER JOIN from_atlas AS a
            ON a.deal_id = b.deal_id
), 
temp AS (
SELECT
    d.vehicle || '-' || d.deal_id AS deal_id,
    d.vehicle,
    d.country,
    pr.product_type,
    CASE
        WHEN pr.product_type IN ('Bank Loan', 'Credit Card', 'Finance', 'Real Estate')
            THEN 'Financial Services'
        WHEN pr.product_type IS NULL OR pr.product_type = 'Other' THEN 'Unclassified'
        ELSE 'Non-Financial Services'
    END AS sector,
    d.country || ' · ' || sector AS market,
    CASE
        WHEN NOT d.earlier_buyer THEN 'Brocc'
        WHEN d.vehicle = 'HEI' THEN 'Intrum'
        WHEN d.vehicle = 'LOK' THEN 'Brocc (Lokki)'
        ELSE 'previous owner'
    END AS acquired_by,
    COALESCE(d.earlier_flow_type, d.brocc_flow_type) AS deal_flow_type,
    d.registration_date,
    IFF(d.earlier_buyer, d.earlier_capex_date, d.brocc_capex_date) AS capex_date,
    d.currency,
    IFF(d.earlier_buyer, d.earlier_purchase_price, d.brocc_purchase_price) AS purchase_price_local,
    -- Atlas holds no case count, so a deal Brocc bought first has none.
    IFF(d.earlier_buyer, d.earlier_cases_acquired, NULL) AS cases_acquired,
    CASE
        WHEN d.earlier_buyer THEN d.earlier_principal
        ELSE COALESCE(NULLIF(d.brocc_gbv, 0), NULLIF(d.brocc_principal, 0))
    END AS balance_at_acquisition_local,
    CASE
        WHEN d.earlier_buyer AND d.earlier_principal IS NOT NULL THEN 'principal'
        WHEN d.earlier_buyer THEN NULL
        WHEN NULLIF(d.brocc_gbv, 0) IS NOT NULL THEN 'gbv: principal + interest + fees'
        WHEN NULLIF(d.brocc_principal, 0) IS NOT NULL THEN 'principal'
    END AS balance_basis,
    fx.rate_to_eur,
    purchase_price_local * fx.rate_to_eur AS purchase_price_eur,
    balance_at_acquisition_local * fx.rate_to_eur AS balance_at_acquisition_eur,
    d.batches
FROM deal AS d
LEFT JOIN deal_product AS pr
    ON pr.deal_id = d.deal_id
LEFT JOIN fx_to_eur AS fx
    ON fx.currency = d.currency
ORDER BY d.vehicle, d.country, d.deal_id)
SELECT COUNT(DISTINCT deal_id) FROM temp