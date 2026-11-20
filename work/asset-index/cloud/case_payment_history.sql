-- ============================================================================
-- One continuous payment history per loan: what the SELLER reported before we
-- bought it, and what CAT has recorded since. ONE ROW PER PAYMENT, labelled by
-- which side it came from. Only the 21,066 loans the bridge maps appear here.
-- ============================================================================
-- ⚠⚠ SANDBOX, NOT PROD. Run with the `dev` profile -- see README.md.
--
-- THIS IS THE JOIN THE ASSET INDEX EXISTS FOR. Everything hangs off CASE_SK,
-- which only exists where CASE_BRIDGE.MATCH_STATUS = 'matched'.
--
-- ⚠⚠ SCOPED TO MAPPED LOANS ON PURPOSE. 245,602 asset-index cases on 19
-- portfolios have no bridge row, and 12,264 bridge rows carry no system_code.
-- None of them can appear. This file therefore says nothing about the size of
-- the book -- it is a like-for-like history for the loans we CAN follow, and
-- nothing else. Measured 2026-09-21.
--
-- ⚠⚠ THE TWO SIDES ARE NOT THE SAME KIND OF NUMBER. The pre-acquisition side
-- is the seller's own reporting, taken on trust at diligence and never
-- reconciled. The CAT side is our servicer's. A step change at the boundary is
-- as likely to be a definition change as a behaviour change.
--
-- ⚠⚠⚠ THE MAPPING IS MANY-TO-ONE AND THAT IS THE TRAP IN THIS FILE. The 21,066
-- matched bridge rows resolve to only 20,456 distinct CASE_SK -- 569 CAT cases
-- are claimed by several asset-index cases, one by 7. Joining CAT's 134m-row
-- collection fact straight to the bridge would repeat those collections once
-- per claimant. CAT is therefore joined to CAT_CASE_SCOPE, which is collapsed
-- to ONE ROW PER CASE_SK first. IS_SHARED_CASE_SK_FLAG marks the affected
-- loans; on those, PORTFOLIO_ID and CASE_ID on the CAT rows are one of several
-- possible answers and must not be trusted. Measured 2026-09-21.
--
-- ⚠ The bridge itself is unique on (portfolio_id, case_id) -- 33,330 rows,
-- 33,330 keys -- so the pre-acquisition side cannot fan out.
--
-- ⚠ LOCAL CURRENCY THROUGHOUT, and the two sides can disagree on it: the asset
-- index carries the portfolio's currency, CAT carries the collection's. Both
-- are emitted. Do not add across currencies.
--
-- ⚠ CAT's collection fact is 134m rows. The INNER JOIN to the bridge is applied
-- inside the CTE so the scan is cut before anything else touches it.
-- ============================================================================
WITH case_bridge AS (
    -- ⚠ MATCHED ROWS ONLY. A NULL system_code builds a NULL case_bk, which
    -- joins to nothing and would just carry dead rows through the union.
    SELECT
        b.portfolio_id,
        b.case_id,
        b.servicer,
        dc.case_sk,
        dc.case_bk
    FROM DEV.ASSET_INDEX.CASE_BRIDGE AS b
    INNER JOIN PROD_NPL_COMMON.NPL_COMMON.DIM_CASE AS dc
        ON dc.case_bk = b.system_code || '-' || b.servicer_case_id
        AND dc.is_current_flag = TRUE
),

cat_case_scope AS (
    -- ⚠⚠ ONE ROW PER CASE_SK. This is the guard described in the header: CAT
    -- must never see the bridge at its own grain.
    SELECT
        case_sk,
        ANY_VALUE(case_bk)                                 AS case_bk,
        ANY_VALUE(portfolio_id)                            AS portfolio_id,
        ANY_VALUE(case_id)                                 AS case_id,
        COUNT(*)                                           AS case_sk_share_count
    FROM case_bridge
    GROUP BY 1
),

portfolio_context AS (
    SELECT
        portfolio_id,
        seller,
        country,
        currency
    FROM DEV.ASSET_INDEX.PORTFOLIO
),

preacquisition_payments AS (
    -- The seller's history. Dated with TRY_TO_DATE: 211 payment_date strings in
    -- the whole feed do not parse, and are kept with a NULL date.
    SELECT
        b.case_sk,
        b.case_bk,
        b.portfolio_id,
        b.case_id,
        'ASSET_INDEX'                                      AS payment_source,
        TRY_TO_DATE(p.payment_date)                        AS payment_date,
        p.payment_amount                                   AS payment_amount,
        pc.currency                                        AS currency_id,
        p.type_of_collection                               AS payment_type,
        FALSE                                              AS is_shared_case_sk_flag
    FROM DEV.ASSET_INDEX.PAYMENTS AS p
    INNER JOIN case_bridge AS b
        ON b.portfolio_id = p.portfolio_id
        AND b.case_id = p.case_id
    LEFT JOIN portfolio_context AS pc
        ON pc.portfolio_id = p.portfolio_id
),

cat_payments AS (
    -- What the loan has paid under Brocc. CASE_SK is CAT's own key here, so no
    -- construction is involved on this side.
    SELECT
        c.case_sk,
        ANY_VALUE(b.case_bk)                               AS case_bk,
        ANY_VALUE(b.portfolio_id)                          AS portfolio_id,
        ANY_VALUE(b.case_id)                               AS case_id,
        'CAT'                                              AS payment_source,
        c.collection_date                                  AS payment_date,
        SUM(c.amount)                                      AS payment_amount,
        c.currency_id,
        NULL                                               AS payment_type,
        ANY_VALUE(b.case_sk_share_count) > 1               AS is_shared_case_sk_flag
    FROM PROD_NPL_COMMON.NPL_COMMON.FCT_CASE_COLLECTION AS c
    -- ⚠⚠ CAT_CASE_SCOPE, NOT CASE_BRIDGE. One row per case_sk; see the header.
    INNER JOIN cat_case_scope AS b
        ON b.case_sk = c.case_sk
    -- ⚠ Collection dates in the year 4570 exist in this warehouse. Bound it.
    WHERE c.collection_date <= CURRENT_DATE()
    GROUP BY c.case_sk, c.collection_date, c.currency_id
)

SELECT
    case_sk,
    case_bk,
    portfolio_id,
    case_id,
    payment_source,
    payment_date,
    DATE_TRUNC('MONTH', payment_date)::DATE                AS payment_month,
    payment_amount,
    currency_id,
    payment_type,
    -- ⚠ TRUE on CAT rows whose case_sk is claimed by several asset-index cases.
    -- Their portfolio_id and case_id are one of several possible answers.
    is_shared_case_sk_flag
FROM preacquisition_payments

UNION ALL

SELECT
    case_sk,
    case_bk,
    portfolio_id,
    case_id,
    payment_source,
    payment_date,
    DATE_TRUNC('MONTH', payment_date)::DATE                AS payment_month,
    payment_amount,
    currency_id,
    payment_type,
    is_shared_case_sk_flag
FROM cat_payments
