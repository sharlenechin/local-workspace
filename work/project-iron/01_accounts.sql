-- Asset index accounts at one row per bridged model_id, matching the model_ids 02 reports. The bridge runs loan to counterparty to CAT.CASES.CLIENT_REF_1, and never on the loan identifier.

WITH latest_asset_index_run AS (
    SELECT
        deal_key,
        portfolio_id,
        run_id
    FROM asset_index.approved.runs
    WHERE portfolio_id IN ('PT06002', 'PT06014', 'PT08018', 'PT09006', 'PT15018', 'PT16023', 'PT18019')
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY deal_key ORDER BY approved_at DESC
    ) = 1
),

warehouse_ids AS (
    SELECT DISTINCT
        LEFT(a.long_portfolio_id, 7) AS portfolio_id,
        -- Leading zeros are padding, not part of the reference: PT18019's tape carries 16 digits against
        -- CAT's 19. Stripping both sides matches 94.37% of that deal and changes no other, and merges no
        -- two distinct references on any of them.
        LTRIM(TRIM(a.client_ref_1), '0') AS client_ref_1,
        a.case_id AS model_id
    FROM prod_raw.hyperion_intrum_cat.cases AS a
    INNER JOIN latest_asset_index_run AS b
        ON LEFT(a.long_portfolio_id, 7) = b.portfolio_id
    -- C4: CASE_ID is unique only within an Intrum instance, so the feed is pinned to one.
    WHERE a._file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.4050.cases.%'
        AND a.case_id NOT LIKE '%-%'
        AND a.client_ref_1 IS NOT NULL
),

asset_index_ids AS (
    SELECT DISTINCT
        a.portfolio_id,
        b.case_id,
        b.counterparty_id
    FROM latest_asset_index_run AS a
    INNER JOIN asset_index.approved.case_counterparty AS b
        ON a.run_id = b._run_id
),

asset_index_bridge_pairs AS (
    SELECT
        a.portfolio_id,
        a.case_id,
        a.counterparty_id,
        b.model_id
    FROM asset_index_ids AS a
    LEFT JOIN warehouse_ids AS b
        ON b.client_ref_1 = LTRIM(a.counterparty_id, '0')
        AND b.portfolio_id = a.portfolio_id
),

asset_index_bridge_counts AS (
    SELECT
        portfolio_id,
        case_id,
        COUNT(DISTINCT counterparty_id) AS bridging_parties_on_loan,
        COUNT(DISTINCT model_id) AS bridging_cases_on_loan
    FROM asset_index_bridge_pairs
    WHERE model_id IS NOT NULL
    GROUP BY portfolio_id, case_id
),

-- One row per loan, carrying the bridging party together with that same party's model_id. Selecting each by an independent MIN pairs a counterparty with another party's case.
asset_index_bridge AS (
    SELECT
        a.portfolio_id,
        a.case_id,
        a.counterparty_id,
        a.model_id,
        COALESCE(b.bridging_parties_on_loan, 0) AS bridging_parties_on_loan,
        COALESCE(b.bridging_cases_on_loan, 0) AS bridging_cases_on_loan
    FROM asset_index_bridge_pairs AS a
    LEFT JOIN asset_index_bridge_counts AS b
        ON b.portfolio_id = a.portfolio_id
        AND b.case_id = a.case_id
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY a.portfolio_id, a.case_id
        ORDER BY a.model_id NULLS LAST, a.counterparty_id
    ) = 1
),

-- Every case the deal bridges to, which is the grain of this query and of the payment series in 02.
bridged_model_ids AS (
    SELECT DISTINCT
        portfolio_id,
        model_id
    FROM asset_index_bridge_pairs
    WHERE model_id IS NOT NULL
),

-- The tape read at borrower level. A loan counts once, against the case it was allocated to in the bridge.
asset_index_borrower AS (
    SELECT
        b.portfolio_id,
        b.model_id,
        MAX(a.cutoff_date) AS cutoff_date,
        MAX(a.currency) AS currency,
        SUM(a.principal_at_cutoff) AS principal_at_cutoff,
        SUM(a.legal_balance_at_cutoff) AS balance_at_cutoff,
        SUM(a.accrued_interest_at_cutoff) AS accrued_interest_at_cutoff,
        MIN(a.default_date) AS default_date,
        MAX(a.product_type) AS product_type,
        MAX(a.sub_portfolio) AS sub_portfolio,
        MAX(b.bridging_parties_on_loan) AS bridging_parties_on_loan,
        MAX(b.bridging_cases_on_loan) AS bridging_cases_on_loan
    FROM latest_asset_index_run AS c
    INNER JOIN asset_index.approved.cases AS a
        ON a._run_id = c.run_id
    INNER JOIN asset_index_bridge AS b
        ON b.portfolio_id = c.portfolio_id
        AND b.case_id = a.case_id
    WHERE b.model_id IS NOT NULL
    GROUP BY b.portfolio_id, b.model_id
),

-- Read through every bridged pair, not the one case kept per loan, so a borrower's other cases are typed too.
asset_index_entity_type AS (
    SELECT
        a.model_id,
        MAX(c.counterparty_type) AS entity_type
    FROM asset_index_bridge_pairs AS a
    INNER JOIN latest_asset_index_run AS b
        ON b.portfolio_id = a.portfolio_id
    INNER JOIN asset_index.approved.counterparties AS c
        ON c._run_id = b.run_id
        AND c.counterparty_id = a.counterparty_id
    WHERE a.model_id IS NOT NULL
    GROUP BY a.model_id
),

asset_index_attributes AS (
    SELECT
        model_id,
        MAX(insolvency_flag) AS insolvency_flag,
        MAX(insolvency_start_date) AS insolvency_start_date,
        MAX(insolvency_end_date) AS insolvency_end_date,
        MAX(judicialised_flag) AS judicialised_flag
    FROM (
        -- Attributes mapped at case level
        SELECT
            c.model_id,
            MAX(CASE WHEN b.attribute = 'insolvency_flag' THEN b.value END) AS insolvency_flag,
            MAX(CASE WHEN b.attribute = 'insolvency_start_date' THEN b.value END) AS insolvency_start_date,
            MAX(CASE WHEN b.attribute = 'insolvency_end_date' THEN b.value END) AS insolvency_end_date,
            MAX(CASE WHEN b.attribute = 'judicialised_flag' THEN b.value END) AS judicialised_flag
        FROM latest_asset_index_run AS a
        INNER JOIN (SELECT *, SPLIT_PART(_deal_key, '-', 2) AS _deal_key_portfolio
                        FROM asset_index.approved.attributes) AS b
            ON b._run_id = a.run_id
        INNER JOIN asset_index_bridge AS c
            ON c.case_id = b.entity_id
            AND c.portfolio_id = b._deal_key_portfolio
        WHERE b.entity_type = 'case'
        GROUP BY c.model_id

        UNION ALL

        -- Attributes mapped at counterparty level
        SELECT
            c.model_id,
            MAX(CASE WHEN b.attribute = 'insolvency_flag' THEN b.value END),
            MAX(CASE WHEN b.attribute = 'insolvency_start_date' THEN b.value END),
            MAX(CASE WHEN b.attribute = 'insolvency_end_date' THEN b.value END),
            MAX(CASE WHEN b.attribute = 'judicialised_flag' THEN b.value END)
        FROM latest_asset_index_run AS a
        INNER JOIN (SELECT *, SPLIT_PART(_deal_key, '-', 2) AS _deal_key_portfolio
                        FROM asset_index.approved.attributes) AS b
            ON b._run_id = a.run_id
        INNER JOIN asset_index_bridge_pairs AS c
            ON c.counterparty_id = b.entity_id
            AND c.portfolio_id = b._deal_key_portfolio
        WHERE b.entity_type = 'counterparty'
            AND c.model_id IS NOT NULL
        GROUP BY c.model_id
    )
    GROUP BY model_id
),

warehouse_registration_information AS (
    SELECT
        SPLIT_PART(a.case_bk, '-', 2) AS model_id,
        a.case_id AS case_sk_hashed,            -- Key on which FCT_CASE_COLLECTION joins
        a.registration_date,
        -- DERIVED_DEFAULT_DATE is identical to DEFAULT_DATE on this book, so only one is carried.
        a.default_date AS warehouse_default_date,
        a.secured_flag
    FROM PROD_NPL_COMMON.NPL_COMMON.DIM_CASE AS a
    WHERE a.case_bk LIKE '4050-%'               -- Portugal, Intrum reporting system 4050
        AND a.is_current_flag
),

-- Principal and balance at registration. DIM_CASE.ORIGINAL_PRINCIPAL is unpopulated on this book, so the
-- figures are taken from the first case snapshot falling on or after the registration date. That table is
-- month-end grain, so REGISTRATION_BALANCE_DATE records how far after registration the reading actually sits.
warehouse_registration_balance AS (
    SELECT
        SPLIT_PART(a.case_bk, '-', 2) AS model_id,
        b.date_day AS registration_balance_date,
        b.outstanding_principal AS principal_at_registration,
        b.outstanding_total AS balance_at_registration
    FROM PROD_NPL_COMMON.NPL_COMMON.DIM_CASE AS a
    INNER JOIN PROD_NPL_COMMON.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS b
        ON b.case_id = a.case_id
    WHERE a.case_bk LIKE '4050-%'
        AND a.is_current_flag
        AND b.date_day >= a.registration_date
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY a.case_bk ORDER BY b.date_day
    ) = 1
),

warehouse_acquisition_information AS (
    SELECT
        a.servicer_parent_portfolio_bk AS portfolio_id,
        MIN(a.legacy_capex_date) AS acquisition_date,
        MAX(a.legal_seller_name) AS seller_name,
        MAX(a.deal_source_bk) AS vehicle
    FROM PROD_NPL_COMMON.NPL_COMMON.DIM_BATCH AS a
    WHERE a.servicer_parent_portfolio_bk IN (SELECT portfolio_id FROM latest_asset_index_run)
    GROUP BY 1
),

warehouse_capital AS (
    SELECT
        case_id AS model_id,
        original_capital,
        remaining_capital
    FROM (
        SELECT
            case_id,
            original_capital,
            remaining_capital,
            ROW_NUMBER() OVER (
                -- The same pick dbt makes in int_npl_case_intrum: COALESCE(record_updated, update_ts)
                -- ordered first, extracted_at breaking the tie. Ordering on update_ts alone chose a
                -- different version on 833 cases, understating capital by EUR 13.9m.
                PARTITION BY case_id
                ORDER BY COALESCE(record_updated, update_ts)::timestamp DESC,
                    TO_TIMESTAMP_NTZ(PARSE_JSON(_file_metadata):extract_ts::string,
                        'YYYYMMDDTHH24MISS') DESC
            ) AS rn
        FROM prod_raw.hyperion_intrum_cat.cases
        WHERE _file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.4050.cases.%'
            AND LEFT(long_portfolio_id, 7) IN (
                SELECT portfolio_id FROM latest_asset_index_run
            )
            AND case_id NOT LIKE '%-%'
    )
    WHERE rn = 1
),

-- Confirms the bridged borrower is the same party. ORIGINAL_CAPITAL is the comparator, as REMAINING_CAPITAL is stated net of collections.
bridge_checks AS (
    SELECT
        a.model_id,
        a.principal_at_cutoff AS asset_index_principal,
        b.original_capital AS warehouse_capital,
        a.default_date AS asset_index_earliest_default_date,
        c.warehouse_default_date,
        CASE
            WHEN b.original_capital IS NULL OR b.original_capital = 0 THEN 'No Warehouse Figure'
            WHEN ABS(a.principal_at_cutoff - b.original_capital) <= 0.01 THEN 'Exact'
            WHEN ABS(a.principal_at_cutoff - b.original_capital) / b.original_capital <= 0.01 THEN 'Within 1% of Warehouse'
            WHEN a.principal_at_cutoff < b.original_capital THEN 'Asset Index holds Less'
            ELSE 'Differs'
        END AS bridge_principal_check,
        CASE
            WHEN c.warehouse_default_date IS NULL
                OR a.default_date IS NULL THEN 'No Date'
            WHEN a.default_date = c.warehouse_default_date THEN 'Exact'
            WHEN ABS(DATEDIFF('day', a.default_date, c.warehouse_default_date)) <= 31 THEN 'Within a Month'
            WHEN ABS(DATEDIFF('day', a.default_date, c.warehouse_default_date)) <= 366 THEN 'Within a Year'
            ELSE 'Differs More than a Year'
        END AS bridge_default_date_check,
        ROUND(a.principal_at_cutoff / NULLIF(b.original_capital, 0), 5) AS bridge_principal_ratio,
        -- One verdict per borrower. A tape figure ABOVE the warehouse cannot come from holding part of a
        -- borrower's debt, so it is called out rather than folded in with the merely unconfirmed.
        CASE
            WHEN ABS(a.principal_at_cutoff - b.original_capital) <= 0.01
                AND a.default_date = c.warehouse_default_date THEN 'Confirmed - Money and Date'
            WHEN ABS(a.principal_at_cutoff - b.original_capital) <= 0.01 THEN 'Confirmed - Money'
            WHEN a.default_date = c.warehouse_default_date THEN 'Confirmed - Date'
            WHEN a.principal_at_cutoff > b.original_capital * 1.01 THEN 'Suspect - Tape Above Warehouse'
            WHEN ABS(DATEDIFF('day', a.default_date, c.warehouse_default_date)) <= 31 THEN 'Weak - Date Within a Month'
            WHEN a.principal_at_cutoff < b.original_capital THEN 'Unconfirmed - Partial Coverage'
            ELSE 'Unconfirmed'
        END AS bridge_confidence
    FROM asset_index_borrower AS a
    LEFT JOIN warehouse_capital AS b
        ON b.model_id = a.model_id
    -- DEFAULT_DATE is entirely unpopulated in raw CAT on these deals, so DIM_CASE is the only source
    LEFT JOIN warehouse_registration_information AS c
        ON c.model_id = a.model_id
)

SELECT
    g.model_id,
    g.portfolio_id,
    e.seller_name,
    e.vehicle,

    -- Dates
    e.acquisition_date,                         -- Date Intrum acquired the book, the earliest where a deal has several
    d.registration_date,                        -- Date Intrum opened the case
    a.cutoff_date,                              -- Date the seller drew the tape
    DATEDIFF('day', a.cutoff_date, d.registration_date) AS days_cutoff_to_registration,

    -- Balances as reported by the seller at the tape cut-off date
    a.currency,
    a.principal_at_cutoff,
    a.balance_at_cutoff,
    a.accrued_interest_at_cutoff,

    -- Balances as reported by the warehouse at registration
    i.registration_balance_date,                -- Month-end reading nearest to registration_date
    i.principal_at_registration,
    i.balance_at_registration,

    a.default_date,                             -- Seller's date; the warehouse's equivalent appears below
    a.product_type,
    a.sub_portfolio,
    j.entity_type,
    b.insolvency_flag,
    b.insolvency_start_date,
    b.insolvency_end_date,
    b.judicialised_flag,

    -- Bridge quality
    h.bridge_principal_check,
    h.asset_index_principal,
    h.warehouse_capital,
    h.bridge_default_date_check,
    h.bridge_principal_ratio,
    h.bridge_confidence,
    h.asset_index_earliest_default_date,
    h.warehouse_default_date,
    a.bridging_parties_on_loan,
    a.bridging_cases_on_loan                    -- Above 1, a loan of this borrower reaches several cases
FROM bridged_model_ids AS g
LEFT JOIN asset_index_borrower AS a
    ON a.portfolio_id = g.portfolio_id
    AND a.model_id = g.model_id
LEFT JOIN asset_index_attributes AS b
    ON b.model_id = g.model_id
LEFT JOIN asset_index_entity_type AS j
    ON j.model_id = g.model_id
LEFT JOIN warehouse_registration_information AS d
    ON d.model_id = g.model_id
LEFT JOIN warehouse_registration_balance AS i
    ON i.model_id = g.model_id
LEFT JOIN warehouse_acquisition_information AS e
    ON e.portfolio_id = g.portfolio_id
LEFT JOIN bridge_checks AS h
    ON h.model_id = g.model_id
ORDER BY g.portfolio_id, g.model_id;
