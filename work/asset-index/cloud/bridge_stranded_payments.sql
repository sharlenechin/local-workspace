-- ============================================================================
-- STRANDED PAYMENT HISTORY. One row per asset-index portfolio: how much of the
-- seller's payment history cannot be tied to any Brocc loan, in cases and cash.
-- ============================================================================
-- ⚠⚠ SANDBOX, NOT PROD. Run with the `dev` profile -- see README.md.
--   uv run python scripts/run_sql.py \
--     work/asset-index/bridge_stranded_payments.sql --connection dev
--
-- THE QUESTION THIS ANSWERS: the bridge matches only ~70% of cases on the books
-- it covers, but a case that NEVER PAID loses nothing by going unmatched. This
-- separates "never paid" from "cannot be linked", which is the number that
-- actually matters. Measured 2026-09-22 on the four bridged books:
--     ES25021    631 payers,     0 stranded   0.0% of payers,  0.0% of cash
--     DE25020  4,258 payers, 1,259 stranded  29.6% of payers, 29.6% of cash
--     CH25007  1,237 payers,   401 stranded  32.4% of payers, 33.9% of cash
--     SE25008  7,538 payers, 4,071 stranded  54.0% of payers, 74.2% of cash
--
-- ⚠⚠ ES25021 PROVES THE MATCH RATE OVERSTATES THE DAMAGE. A 70% match on cases
-- cost 0% of the payment history, because every unmatched case was a non-payer.
--
-- ⚠⚠ SE25008 IS THE OUTLIER AND IT IS SERIOUS. It loses 54% of paying accounts
-- but 74% of the cash, so the loans it cannot map are the LARGER payers -- worse
-- than random. The same book also has zero post-acquisition collections in
-- NPL_COMMON. Two independent symptoms of one broken mapping.
--
-- ⚠⚠ ALL 23 PORTFOLIOS ARE RETURNED, not just the four with a bridge. The other
-- 19 have no bridge row at all, so 100% of their history is stranded by
-- definition -- that is the honest figure, and hiding them would understate the
-- problem by 245,599 cases. IS_BRIDGED_FLAG separates the two situations.
--
-- ⚠⚠ THERE IS NO SQL FIX FOR THE STRANDED ROWS. Tested 2026-09-22 and every
-- recovery route returned ZERO hits: the asset-index case_id against
-- DIM_CASE.CASE_ID, the book's own system code prefixed to that case_id, and
-- INTERNAL_CASE_ID against DIM_CASE.CASE_ID. The reason is that unmatched
-- bridge rows carry NO SERVICER_CASE_ID AT ALL -- the column is NULL on every
-- one of the 12,264. `not_in_mapping` is literal: there is nothing to build a
-- key from. This needs the mapping file extended by Intrum, not a better join.
--
-- ⚠ CASH IS LOCAL CURRENCY AND NEVER CONVERTED -- EUR, SEK and CHF all appear,
-- so CASH_STRANDED is not addable across books. The PERCENTAGES are, because
-- each is computed within one book.
--
-- ⚠ 211 payments across the whole feed have an unparseable date. They are
-- INCLUDED here: the question is whether the money can be linked, and a bad
-- date does not stop that. The monthly datasets exclude them, which is why
-- their totals are slightly lower.
-- ============================================================================
WITH asset_index_case AS (
    -- ⚠ DEDUPED. 3 of 278,932 rows repeat their (portfolio_id, case_id) key.
    SELECT
        portfolio_id,
        case_id
    FROM DEV.ASSET_INDEX.CASES
    GROUP BY 1, 2
),

matched_case AS (
    -- ⚠ MATCHED ROWS ONLY. A NULL system_code builds a NULL case_bk, which
    -- joins to nothing -- that is precisely what "stranded" means here.
    SELECT
        b.portfolio_id,
        b.case_id
    FROM DEV.ASSET_INDEX.CASE_BRIDGE AS b
    INNER JOIN PROD_NPL_COMMON.NPL_COMMON.DIM_CASE AS dc
        ON dc.case_bk = b.system_code || '-' || b.servicer_case_id
        AND dc.is_current_flag = TRUE
    GROUP BY 1, 2
),

paying_case AS (
    -- One row per case that ever paid, with its lifetime cash.
    SELECT
        portfolio_id,
        case_id,
        SUM(payment_amount)                            AS payment_amount,
        COUNT(*)                                       AS payment_count
    FROM DEV.ASSET_INDEX.PAYMENTS
    GROUP BY 1, 2
),

per_case AS (
    -- ⚠⚠ DRIVEN FROM EVERY CASE, then LEFT joined to both the bridge and the
    -- payments. An INNER join to either would answer a different question and
    -- hide the books that have no bridge at all.
    SELECT
        c.portfolio_id,
        c.case_id,
        m.case_id IS NOT NULL                          AS is_matched,
        p.case_id IS NOT NULL                          AS is_payer,
        p.payment_amount,
        p.payment_count
    FROM asset_index_case AS c
    LEFT JOIN matched_case AS m
        ON m.portfolio_id = c.portfolio_id
        AND m.case_id = c.case_id
    LEFT JOIN paying_case AS p
        ON p.portfolio_id = c.portfolio_id
        AND p.case_id = c.case_id
)

SELECT
    -- ---- the book ---------------------------------------------------------
    pc.portfolio_id,
    pf.seller,
    pf.country,
    pf.currency                                        AS currency_id,

    -- ---- the population ---------------------------------------------------
    COUNT(*)                                           AS cases,
    COUNT_IF(pc.is_matched)                            AS cases_matched,
    -- ⚠ A CASE THAT NEVER PAID LOSES NOTHING BY GOING UNMATCHED. This is the
    -- denominator that matters, not the case count above.
    COUNT_IF(pc.is_payer)                              AS paying_cases,

    -- ---- what cannot be linked --------------------------------------------
    COUNT_IF(pc.is_payer AND NOT pc.is_matched)        AS paying_cases_stranded,
    ROUND(100.0 * COUNT_IF(pc.is_payer AND NOT pc.is_matched)
          / NULLIF(COUNT_IF(pc.is_payer), 0), 1)       AS paying_cases_stranded_pct,

    -- ⚠ LOCAL CURRENCY. Not addable across books -- see the header.
    SUM(pc.payment_amount)                             AS cash_total_local_currency,
    SUM(IFF(pc.is_matched, 0, pc.payment_amount))      AS cash_stranded_local_currency,
    ROUND(100.0 * SUM(IFF(pc.is_matched, 0, pc.payment_amount))
          / NULLIF(SUM(pc.payment_amount), 0), 1)      AS cash_stranded_pct,

    SUM(pc.payment_count)                              AS payments,
    SUM(IFF(pc.is_matched, 0, pc.payment_count))       AS payments_stranded,

    -- ---- flags -------------------------------------------------------------
    -- ⚠ FALSE means the book has NO bridge at all, so 100% is stranded by
    -- definition. That is an absence of mapping, not a failed match.
    COUNT_IF(pc.is_matched) > 0                        AS is_bridged_flag,
    -- ⚠ TRUE where the stranded loans are the LARGER payers -- the cash lost
    -- exceeds the accounts lost. SE25008 is the one book where this fires.
    ROUND(100.0 * SUM(IFF(pc.is_matched, 0, pc.payment_amount))
          / NULLIF(SUM(pc.payment_amount), 0), 1)
        > ROUND(100.0 * COUNT_IF(pc.is_payer AND NOT pc.is_matched)
          / NULLIF(COUNT_IF(pc.is_payer), 0), 1)       AS stranded_skews_large_flag
FROM per_case AS pc
LEFT JOIN DEV.ASSET_INDEX.PORTFOLIO AS pf
    ON pf.portfolio_id = pc.portfolio_id
GROUP BY 1, 2, 3, 4
