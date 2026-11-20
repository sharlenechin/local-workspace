-- ============================================================================
-- BENCHMARK DATASET. One continuous monthly payment history per loan, taking
-- the asset index where it has data and NPL_COMMON where it does not.
-- GRAIN: one row per (CASE_SK, PAYMENT_MONTH). 68,417 rows, 20,456 loans.
-- ============================================================================
-- ⚠⚠ SANDBOX, NOT PROD. Run with the `dev` profile -- see README.md.
--   uv run python scripts/run_sql.py \
--     work/asset-index/benchmark_case_payments_monthly.sql --connection dev
--
-- ⚠⚠ THE GRAIN IS CASE_SK, NOT (PORTFOLIO_ID, CASE_ID), and that is the whole
-- reason this reconciles. 569 CAT loans are claimed by several asset-index
-- cases -- one by seven -- so keying on the asset-index case id would split one
-- loan's history across rows and attribute CAT's side of it arbitrarily.
-- Aggregating the asset index UP to CASE_SK is correct: those cases ARE the
-- same CAT loan. ASSET_INDEX_CASE_COUNT says how many fed each row.
--
-- ⚠⚠ THE SOURCE RULE: ASSET INDEX WINS. A (case, month) present in the asset
-- index is taken from the asset index and NPL_COMMON is not consulted for it.
-- NPL_COMMON supplies only the months the asset index says nothing about.
-- PRE_ACQUISITION_SOURCE records which, per row:
--     'ASSET_INDEX'      the seller's own history, given at diligence
--     'CASE_NPL_COMMON'  our servicer's feed (FCT_CASE_COLLECTION)
--
-- ⚠⚠ THE TWO SOURCES DO NOT OVERLAP AT ALL TODAY. Measured 2026-09-22: 62,764
-- asset-index case-months, 5,653 NPL_COMMON case-months, and ZERO in both. The
-- preference rule therefore changes nothing right now -- it exists so that the
-- day they do overlap, the answer is decided here and not by whoever runs it.
-- bridge_overlap_by_portfolio.sql is the standing check on that.
--
-- ⚠⚠ THERE IS A HOLE BETWEEN THE TWO SOURCES, NOT A SEAM. Per portfolio:
--     CH25007  asset index ends 2025-10, NPL_COMMON starts 2026-01  (2 months)
--     DE25020  asset index ends 2025-08, NPL_COMMON starts 2026-01  (4 months)
--     ES25021  asset index ends 2025-09, NPL_COMMON starts 2026-03  (5 months)
--     SE25008  asset index ends 2025-04, NPL_COMMON has NOTHING
-- Those months have no payments from either side. A cumulative curve drawn
-- across the gap will read as a collapse that did not happen.
--
-- ⚠⚠ NONE OF THE FOUR BRIDGED BOOKS HAS PRE-ACQUISITION DATA IN NPL_COMMON.
-- Checked 2026-09-22: 0 of 4. Every NPL_COMMON collection on these loans falls
-- AFTER the capex month, with not one row and not one unit of currency before
-- it -- capex is 2025-12-01 on all three that reach NPL_COMMON, and their first
-- collection is 2026-01 or later. So the seller's history is the ONLY source of
-- pre-acquisition payments here, and 'CASE_NPL_COMMON' never appears on a row
-- flagged IS_PRE_ACQUISITION_FLAG. That is why the source rule has never yet
-- had to decide anything.
--
-- ⚠⚠ SE25008 HAS NO NPL_COMMON SIDE AT ALL. 6,267 matched loans, not one
-- collection. Either the book has not started reporting into CAT or its
-- mapping is wrong. Do not read its history as "collections stopped".
--
-- ⚠ MONTHS_TO_CAPEX IS THE BENCHMARK AXIS. 0 is the month Brocc bought the
-- book, negative is the seller's history, positive is ours. It is NULL where
-- no capex date is known -- today that is SE25008, because capex comes from the
-- NPL_COMMON portfolio the loan maps to and SE25008 reaches none.
--
-- ⚠⚠ LOCAL CURRENCY, NEVER CONVERTED. EUR, SEK and CHF all appear, so a total
-- across books is meaningless until converted.
--   CURRENCY_ID is the FX join key and it is SOUND. Checked 2026-09-22: each
--   book is single-currency and the two sources AGREE on it -- CH25007 CHF,
--   DE25020 EUR, ES25021 EUR, SE25008 SEK, identical on the asset-index and
--   NPL_COMMON sides. An earlier version of this header warned they might
--   disagree; they do not.
--
-- ⚠⚠ FX_JOIN_MONTH EXISTS BECAUSE THE RATE TABLE IS KEYED MONTH-END AND THIS
-- DATASET IS MONTH-START. Joining PAYMENT_MONTH to the rate table matches
-- NOTHING -- silently, with every converted figure NULL. Join on
-- (CURRENCY_ID, FX_JOIN_MONTH) instead.
--
-- ⚠⚠⚠ THE MODELLED FX TABLE IS NOT REACHABLE FROM THE SANDBOX. Rates live in
-- PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY, and the share into brocc-sandbox is
-- PROD_NPL_COMMON -- the NPL_COMMON schema only. PROD.COMMON is not in it, so
-- there is no rate table to join here today. Three ways out, best first:
--   1. ask the data team to add PROD.COMMON (or just that one table) to the
--      share. Then the join is two lines and matches production exactly.
--   2. convert outside: run this with the dev profile, run ref_fx_monthly.sql
--      against PROD, and join the two in pandas on (currency_id, fx_join_month).
--   3. PROD_RAW.RIKSBANK.EXCHANGE_RATES is shared (21,898 rows, daily, series
--      like SEKEURPMI/SEKCHFPMI from 2018-01-02). It is RAW and SEK-based;
--      re-deriving the EUR-base monthly average and month-end close from it is
--      real work and will not necessarily tie to production. Last resort.
--
-- ⚠ 211 asset-index payment_date strings in the whole feed do not parse and are
-- EXCLUDED here, because a row with no month cannot sit on a monthly grain.
-- They are kept in case_preacquisition_payments.sql -- the money is real.
-- ============================================================================
WITH case_bridge AS (
    -- ⚠ MATCHED ROWS ONLY. A NULL system_code builds a NULL case_bk, which
    -- joins to nothing and would only carry dead rows downstream.
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

case_scope AS (
    -- ⚠⚠ ONE ROW PER CASE_SK. This is the collapse described in the header;
    -- everything below joins through it, so nothing can fan out.
    SELECT
        case_sk,
        ANY_VALUE(case_bk)                                 AS case_bk,
        ANY_VALUE(portfolio_id)                            AS portfolio_id,
        ANY_VALUE(case_id)                                 AS case_id,
        ANY_VALUE(servicer)                                AS servicer,
        COUNT(*)                                           AS asset_index_case_count
    FROM case_bridge
    GROUP BY 1
),

cat_payments AS (
    -- NPL_COMMON's own feed. CASE_SK is its key, so nothing is constructed.
    -- This read also supplies the portfolio each loan belongs to, which is the
    -- only route to a capex date -- FCT_CASE_COLLECTION is the lightest table
    -- carrying both (134m rows, against 1.47bn for the case snapshot).
    SELECT
        c.case_sk,
        DATE_TRUNC('MONTH', c.collection_date)::DATE       AS payment_month,
        c.currency_id,
        SUM(c.amount)                                      AS payment_amount,
        COUNT(*)                                           AS payment_count,
        ANY_VALUE(c.portfolio_sk)                          AS portfolio_sk
    FROM PROD_NPL_COMMON.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN case_scope AS s
        ON s.case_sk = c.case_sk
    -- ⚠ Collection dates in the year 4570 exist in this warehouse. Bound it.
    WHERE c.collection_date <= CURRENT_DATE()
    GROUP BY 1, 2, 3
),

asset_index_payments AS (
    -- The seller's history, aggregated UP to case_sk -- see the header.
    SELECT
        b.case_sk,
        DATE_TRUNC('MONTH', TRY_TO_DATE(p.payment_date))::DATE AS payment_month,
        ANY_VALUE(pf.currency)                             AS currency_id,
        SUM(p.payment_amount)                              AS payment_amount,
        COUNT(*)                                           AS payment_count
    FROM DEV.ASSET_INDEX.PAYMENTS AS p
    INNER JOIN case_bridge AS b
        ON b.portfolio_id = p.portfolio_id
        AND b.case_id = p.case_id
    LEFT JOIN DEV.ASSET_INDEX.PORTFOLIO AS pf
        ON pf.portfolio_id = p.portfolio_id
    -- ⚠ A payment with no parseable month cannot sit on a monthly grain.
    WHERE TRY_TO_DATE(p.payment_date) IS NOT NULL
    GROUP BY 1, 2
),

portfolio_capex AS (
    -- Capex per ASSET-INDEX portfolio, taken from the NPL_COMMON portfolios its
    -- loans map to. MIN because a book can split across two (CH25007 and
    -- DE25020 each map to a U01 and a U02); both share a capex date today.
    SELECT
        s.portfolio_id,
        MIN(dp.capex_date)                                 AS capex_date
    FROM cat_payments AS c
    INNER JOIN case_scope AS s
        ON s.case_sk = c.case_sk
    LEFT JOIN PROD_NPL_COMMON.NPL_COMMON.DIM_PORTFOLIO AS dp
        ON dp.portfolio_sk = c.portfolio_sk
    GROUP BY 1
),

seller_cutoff AS (
    -- The seller's own cutoff, for context only. NULL on DE25020 and CH25007.
    SELECT
        portfolio_id,
        MAX(TRY_TO_DATE(cutoff_date))                      AS cutoff_date
    FROM DEV.ASSET_INDEX.CASES
    GROUP BY 1
),

combined AS (
    -- ---- the asset index, taken in full ----------------------------------
    SELECT
        case_sk,
        payment_month,
        currency_id,
        payment_amount,
        payment_count,
        'ASSET_INDEX'                                      AS pre_acquisition_source
    FROM asset_index_payments

    UNION ALL

    -- ---- NPL_COMMON, only where the asset index is silent ----------------
    -- ⚠⚠ ANTI-JOIN: TEST THE RIGHT SIDE FOR NULL. Testing c matches nothing
    -- and would let every NPL_COMMON row through, duplicating the months the
    -- asset index already covers. This is the "asset index wins" rule.
    SELECT
        c.case_sk,
        c.payment_month,
        c.currency_id,
        c.payment_amount,
        c.payment_count,
        'CASE_NPL_COMMON'                                  AS pre_acquisition_source
    FROM cat_payments AS c
    LEFT JOIN asset_index_payments AS a
        ON a.case_sk = c.case_sk
        AND a.payment_month = c.payment_month
    WHERE a.case_sk IS NULL
)

SELECT
    -- ---- keys -------------------------------------------------------------
    k.case_sk,
    s.case_bk,
    s.portfolio_id,
    s.case_id,
    s.servicer,
    -- ⚠ ABOVE 1 MEANS SEVERAL ASSET-INDEX CASES FEED THIS LOAN. Their payments
    -- are summed together, which is right, but PORTFOLIO_ID and CASE_ID above
    -- are then one of several possible answers.
    s.asset_index_case_count,

    -- ---- the month --------------------------------------------------------
    k.payment_month,
    YEAR(k.payment_month)                                  AS payment_year,
    -- ⚠ THE BENCHMARK AXIS. 0 = the month Brocc bought the book, negative =
    -- the seller's history. NULL where no capex date is known.
    DATEDIFF('MONTH', DATE_TRUNC('MONTH', cx.capex_date), k.payment_month)
                                                           AS months_to_capex,
    cx.capex_date,
    sc.cutoff_date                                         AS seller_cutoff_date,

    -- ---- the money. LOCAL CURRENCY -- see the header. ---------------------
    k.payment_amount,
    k.payment_count,
    -- ⚠ THE FX JOIN KEY. Single-currency per book and the two sources agree.
    k.currency_id,
    -- ⚠⚠ JOIN THE RATE TABLE ON THIS, NOT ON PAYMENT_MONTH. Rates are keyed on
    -- the LAST day of the month; payment_month is the FIRST. See the header.
    LAST_DAY(k.payment_month)                              AS fx_join_month,

    -- ---- provenance -------------------------------------------------------
    k.pre_acquisition_source,
    -- ⚠ TRUE for months before Brocc owned the book. NULL, not FALSE, where no
    -- capex date is known -- an unknown boundary is not a boundary of zero.
    IFF(cx.capex_date IS NULL, NULL,
        k.payment_month < DATE_TRUNC('MONTH', cx.capex_date))
                                                           AS is_pre_acquisition_flag
FROM combined AS k
INNER JOIN case_scope AS s
    ON s.case_sk = k.case_sk
LEFT JOIN portfolio_capex AS cx
    ON cx.portfolio_id = s.portfolio_id
LEFT JOIN seller_cutoff AS sc
    ON sc.portfolio_id = s.portfolio_id
ORDER BY 1, 7
