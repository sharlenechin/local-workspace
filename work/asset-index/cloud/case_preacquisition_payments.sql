-- ============================================================================
-- Pre-acquisition payments, LOAN LEVEL, carrying the CAT key. ONE ROW PER
-- PAYMENT as the seller reported it. 2,156,237 payments across 23 portfolios;
-- 165,000-ish sit on the 4 portfolios that can reach CAT. Measured 2026-09-21.
-- ============================================================================
-- ⚠⚠ SANDBOX, NOT PROD. Run with the `dev` profile -- see README.md.
--
-- WHAT THIS IS FOR: the asset index holds the payment history the SELLER gave
-- us at diligence. CAT holds what the loan has paid SINCE we bought it. Joining
-- them on CASE_SK gives one continuous history per loan. This query is the
-- pre-acquisition half, already keyed so the join is a one-liner.
--
-- ⚠⚠ PAYMENT_DATE IS TEXT IN THE SOURCE. 211 of 2,156,237 values do not parse
-- as a date and come back NULL rather than being dropped -- they are still real
-- money. TRY_TO_DATE, never TO_DATE: one bad string would fail the whole query.
--
-- ⚠⚠ "PRE-ACQUISITION" CANNOT BE DERIVED FOR TWO OF THE FOUR BRIDGED
-- PORTFOLIOS. CUTOFF_DATE is populated on SE25008 (2025-02-28) and ES25021
-- (2025-07-31) and is NULL on DE25020 and CH25007. IS_BEFORE_CUTOFF_FLAG is
-- therefore NULL, not FALSE, on those two -- an unknown boundary is not the
-- same as a payment after it. Where it is known, a few percent of rows sit
-- AFTER the cutoff (6,916 of 119,494 on SE25008; 272 of 5,685 on ES25021), so
-- this file is not purely pre-acquisition and must not be assumed to be.
--
-- ⚠ CASES IS DEDUPED ON THE WAY IN. 3 of 278,932 rows repeat their
-- (portfolio_id, case_id) key -- 2 on UK26002, 1 on DE25010. None are on a
-- bridged portfolio today, but an un-guarded join would double those payments
-- the moment one is.
--
-- ⚠ EVERY AMOUNT IS IN THE PORTFOLIO'S OWN CURRENCY (EUR, SEK, CHF here).
-- Nothing is converted. Do not add across portfolios without a rate.
-- ============================================================================
WITH case_scope AS (
    -- ⚠ ONE ROW PER (portfolio_id, case_id). See the header on duplicates.
    SELECT
        portfolio_id,
        case_id,
        ANY_VALUE(TRY_TO_DATE(cutoff_date))                AS cutoff_date,
        ANY_VALUE(currency)                                AS case_currency,
        ANY_VALUE(TRY_TO_DATE(default_date))               AS default_date,
        ANY_VALUE(TRY_TO_DATE(registration_date))          AS registration_date,
        ANY_VALUE(registration_balance)                    AS registration_balance
    FROM DEV.ASSET_INDEX.CASES
    GROUP BY 1, 2
),

case_bridge AS (
    -- ref_case_bridge.sql, inlined so this file runs on its own.
    SELECT
        b.portfolio_id,
        b.case_id,
        b.match_status,
        dc.case_sk,
        dc.case_bk
    FROM DEV.ASSET_INDEX.CASE_BRIDGE AS b
    LEFT JOIN PROD_NPL_COMMON.NPL_COMMON.DIM_CASE AS dc
        ON dc.case_bk = b.system_code || '-' || b.servicer_case_id
        AND dc.is_current_flag = TRUE
)

SELECT
    -- ---- asset-index keys -------------------------------------------------
    p.portfolio_id,
    p.case_id,
    pf.seller,
    pf.country,
    pf.currency                                            AS portfolio_currency,

    -- ---- CAT keys. NULL where the loan cannot be followed into CAT. -------
    b.case_sk,
    b.case_bk,
    b.case_sk IS NOT NULL                                  AS is_mapped_to_cat_flag,
    COALESCE(b.match_status, 'no_bridge_row')              AS match_status,

    -- ---- the payment ------------------------------------------------------
    TRY_TO_DATE(p.payment_date)                            AS payment_date,
    DATE_TRUNC('MONTH', TRY_TO_DATE(p.payment_date))::DATE AS payment_month,
    p.payment_amount,
    p.payment_allocation,
    p.payment_method,
    p.type_of_collection,

    -- ---- case context, repeated on every payment of that case ------------
    c.cutoff_date,
    c.default_date,
    c.registration_date,
    c.registration_balance,

    -- ⚠ NULL, NOT FALSE, where the portfolio has no cutoff date. See header.
    IFF(c.cutoff_date IS NULL, NULL,
        TRY_TO_DATE(p.payment_date) <= c.cutoff_date)      AS is_before_cutoff_flag,
    -- ⚠ FALSE on 211 rows whose date string does not parse. The money is real;
    -- only the date is unusable, so do not filter these away silently.
    TRY_TO_DATE(p.payment_date) IS NOT NULL                AS has_payment_date_flag
FROM DEV.ASSET_INDEX.PAYMENTS AS p
LEFT JOIN case_scope AS c
    ON c.portfolio_id = p.portfolio_id
    AND c.case_id = p.case_id
LEFT JOIN case_bridge AS b
    ON b.portfolio_id = p.portfolio_id
    AND b.case_id = p.case_id
LEFT JOIN DEV.ASSET_INDEX.PORTFOLIO AS pf
    ON pf.portfolio_id = p.portfolio_id
