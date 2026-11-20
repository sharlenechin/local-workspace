-- ============================================================================
-- EXAMPLE, NOT A MODEL. Benchmark accounts for a country's deals, as at one
-- phase of the loan's life. Written for Spain; change the country and the
-- phase and it answers the same question of any book.
-- ============================================================================
-- Run it against the generated Snowflake copies, or swap the two CTEs for
-- {{ ref() }} to make it a model.
--
-- ⚠⚠⚠ YOU CANNOT BUILD A PRE-LEGACY-ACQUISITION BENCHMARK FROM THIS WAREHOUSE.
-- Measured 2026-09-27 on all 8,973,495 Spanish loans: ZERO were registered
-- before the previous owner bought them. Every one of the 7,177,822 with a
-- registration date was registered AFTER. The servicer opens a file when it
-- starts collecting, which is after the sale -- so the loan does not exist in
-- any system we hold until the acquisition has already happened.
--   registered BEFORE the legacy purchase        0
--   registered AFTER  the legacy purchase    7,177,822
-- The earliest view of a loan we have is REGISTRATION, and that is already
-- post-sale. Anything genuinely pre-acquisition has to come from the seller --
-- which is what the asset index is, and it reaches 7.55% of its own cases.
--
-- ⚠⚠ THE PHASE THAT LOOKS EARLIEST IS NOT THE ONE WITH THE MOST DATA. At
-- REGISTRATION only 229,094 of 8.97m Spanish loans (2.6%) have a balance,
-- because the case snapshot starts 2014-06-30 and most registrations predate
-- it. Use BROCC_ACQUISITION or LATEST if you need balances.
--
-- ⚠⚠ STATUS IS ALL BUT ABSENT AT REGISTRATION -- 175 loans of 8.97m. The status
-- spell in force at a 2009 registration date simply does not exist, because
-- DIM_NPL_CASE's history does not reach back that far. Do not read the near-zero
-- as "nobody had a status"; read it as "we were not watching yet".
--
-- ⚠ ORIGINAL_PRINCIPAL IS 20% POPULATED IN SPAIN and 0% in Finland, Sweden,
-- Poland, Portugal, France, Greece and Germany. It is the servicer's recorded
-- figure, not a priced amount, and it is NOT a balance as at any date.
-- ============================================================================
WITH spanish_book AS (
    -- ⚠ THE SERVICER LEG ONLY. Without the filter every portfolio appears
    -- twice, once per phase type, and the loan count doubles.
    SELECT
        portfolio_sk,
        ANY_VALUE(portfolio_name)                      AS portfolio_name,
        ANY_VALUE(seller_name)                         AS seller_name,
        -- A book can be run by two servicers at once -- 34 are.
        LISTAGG(DISTINCT phase_entity_name, ' + ')     AS servicers,
        MIN(portfolio_legacy_acquisition_first_date)   AS legacy_acquisition_date
    FROM {{ ref('dim_npl_portfolio_history') }}
    WHERE phase_type = 'SERVICER'
      AND country_name = 'Spain'
    GROUP BY 1
),

at_registration AS (
    -- The loan as the servicer first recorded it. One row per loan: the phase
    -- filter is what keeps this at case grain rather than case x phase.
    SELECT
        case_bk,
        portfolio_sk,
        batch_sk,
        phase_entity_name                              AS registering_servicer,
        phase_date                                     AS registration_date,
        balance_total                                  AS balance_at_registration,
        original_principal,
        status_description                             AS status_at_registration,
        is_forbearance_flag                            AS in_forbearance_at_registration,
        has_snapshot_flag                              AS has_balance_flag
    FROM {{ ref('dim_npl_case_history') }}
    WHERE phase_type = 'REGISTRATION'
),

at_legacy_acquisition AS (
    SELECT
        case_bk,
        phase_date                                     AS legacy_acquisition_date
    FROM {{ ref('dim_npl_case_history') }}
    WHERE phase_type = 'LEGACY_ACQUISITION'
)

SELECT
    -- ---- the book ------------------------------------------------------------
    b.portfolio_name,
    b.seller_name,
    b.servicers,

    -- ---- the loan, as at registration ---------------------------------------
    r.case_bk,
    r.batch_sk,
    r.registering_servicer,
    r.registration_date,
    YEAR(r.registration_date)                          AS registration_vintage,

    -- ---- non-collection attributes at that moment ----------------------------
    r.balance_at_registration,
    r.original_principal,
    r.status_at_registration,
    r.in_forbearance_at_registration,

    -- ---- the purchase this loan was part of ---------------------------------
    l.legacy_acquisition_date,
    -- ⚠ MEASURED AT ZERO ON EVERY SPANISH LOAN -- see the header. Kept so the
    -- day it stops being zero is visible rather than assumed.
    r.registration_date < l.legacy_acquisition_date    AS registered_before_purchase_flag,
    DATEDIFF('DAY', l.legacy_acquisition_date, r.registration_date)
                                                       AS days_purchase_to_registration,

    -- ---- provenance ----------------------------------------------------------
    -- ⚠ FALSE means the registration predates the case snapshot (2014-06-30),
    -- so BALANCE_AT_REGISTRATION is NULL for a structural reason.
    r.has_balance_flag
FROM spanish_book AS b
INNER JOIN at_registration AS r
    ON r.portfolio_sk = b.portfolio_sk
LEFT JOIN at_legacy_acquisition AS l
    ON l.case_bk = r.case_bk
