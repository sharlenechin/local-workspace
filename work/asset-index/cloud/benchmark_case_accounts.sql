-- ============================================================================
-- BENCHMARK ACCOUNTS. One row per loan: the static picture at acquisition.
-- The partner of benchmark_case_payments_monthly.sql -- same key, same books.
-- GRAIN: one row per CASE_SK. 20,456 loans across 4 portfolios.
-- ============================================================================
-- ⚠⚠ SANDBOX, NOT PROD. Run with the `dev` profile -- see README.md.
--   uv run python scripts/run_sql.py \
--     work/asset-index/benchmark_case_accounts.sql --connection dev
-- `mise run sql` sends this to brocc-prod, where none of these tables exist.
--
-- ⚠⚠ THE KEY IS CASE_SK, NOT THE ASSET-INDEX CASE ID, and it must stay that
-- way: the payments half is keyed on (CASE_SK, PAYMENT_MONTH), so this is what
-- lets the population assert be written --
--     set(payments.case_sk) <= set(accounts.case_sk)
-- 610 asset-index cases share a CAT loan with another (one has seven, all on
-- DE25020). Keying on the asset-index case id would emit that loan several
-- times and break the assert. ASSET_INDEX_CASE_COUNT says how many fed a row.
--
-- ============================================================================
-- THE MONEY COLUMN
-- ============================================================================
-- ⚠⚠⚠ CUTOFF_CAPITAL IS THE BENCHMARK MONEY COLUMN AND IT IS CAPITAL ONLY.
-- This mirrors Project Elsa, which removed registration_interest and
-- registration_balance on 2026-09-16 once a second seller was added: the two
-- books did not deliver interest the same way, so a balance summed across them
-- added two standards together. The same risk is here and worse -- four
-- sellers, and the delivery is measurably uneven.
--
-- ⚠⚠ CH25007 HAS NO CAPITAL FIGURE AT ALL. Measured 2026-09-22:
--     principal_at_cutoff        CH 0/4,439   DE 12,685   ES 4,046   SE 12,160
--     accrued_interest_at_cutoff CH 0/4,439   DE 12,685   ES 4,046   SE 12,160
--     legal_balance_at_cutoff    CH 4,439     DE 12,685   ES 4,046   SE 12,160
-- So CUTOFF_CAPITAL is NULL on every CH25007 loan and that book CANNOT be
-- valued from this dataset. HAS_CUTOFF_CAPITAL_FLAG marks it. Its only figures
-- are LEGAL_BALANCE_AT_CUTOFF (CHF 38,460,146.44, interest-inclusive) and
-- principal_at_origination, which is a different point in time and is NOT a
-- substitute. Ask the seller for principal at cutoff before pricing it.
--
-- ⚠⚠ CUTOFF_INTEREST AND CUTOFF_TOTAL_BALANCE ARE NOT THE BENCHMARK MONEY.
-- They are emitted so the Elsa delivery test can be re-run without re-reading
-- source, and for the one book that has nothing else. NEVER add CUTOFF_CAPITAL
-- and CUTOFF_INTEREST together across sellers, and never quote
-- CUTOFF_TOTAL_BALANCE as "owed" -- verified 2026-09-22 it is exactly
-- principal + accrued interest + other balances (12,685/12,685 on DE25020,
-- 12,160/12,160 on SE25008, 4,027/4,046 on ES25021 within a cent).
--
-- ⚠⚠ THREE CURRENCIES, NEVER CONVERTED. EUR (DE25020, ES25021), SEK (SE25008),
-- CHF (CH25007). CURRENCY_ID is in the output because it is in the grain of the
-- payments half; without it a recovery rate divides SEK by EUR. Join FX on
-- (CURRENCY_ID, FX_JOIN_MONTH) from the payments file -- and note the modelled
-- rate table is NOT shared into the sandbox, see that file's header.
--
-- ⚠⚠ PORTFOLIO_SK IS RESOLVED PER LOAN, NOT PER BOOK. An asset-index
-- portfolio_id can span two NPL_COMMON portfolios -- CH25007 maps to
-- LOK-CH25007-U01/2512 and U02, DE25020 likewise -- so a book-level lookup
-- would put half the loans under the wrong one. It comes from
-- FCT_CASE_SNAPSHOT_DAILY (18,930 of 20,456 loans) with the collection fact as
-- fallback, and is NULL on the loans neither knows. CAPEX_DATE follows it, so
-- it is the acquiring portfolio's own date.
--
-- ============================================================================
-- DATES
-- ============================================================================
-- ⚠⚠ REGISTRATION_DATE COMES FROM NPL_COMMON, NOT THE ASSET INDEX. The asset
-- index's own registration_date column is 100% EMPTY on all four books.
-- DIM_CASE has it on 100% of matched loans, so it is the only source.
--
-- ⚠⚠⚠ THE TWO SOURCES DISAGREE ON DEFAULT DATE, SOMETIMES BY YEARS. Both are
-- emitted; neither is declared correct. Measured 2026-09-22 on matched loans:
--     CH25007      5 agree,  3,059 differ, mean gap 1,273.7 days (~3.5 years)
--     DE25020  5,915 agree,  2,988 differ, mean gap   119.7 days
--     ES25021      0 agree,  2,832 differ, mean gap   249.0 days
--     SE25008      0 agree,  6,267 differ, mean gap     8.3 days
-- SE25008's 8 days looks like a date convention (month-end vs exact day).
-- CH25007's 3.5 years is a different definition of default. DEFAULT_DATE is the
-- SELLER'S, NPL_COMMON_DEFAULT_DATE is ours, DEFAULT_DATE_GAP_DAYS is the gap.
-- ⚠ Decide which the deal was priced on BEFORE using either for seasoning.
--
-- ============================================================================
-- WHAT IS NOT HERE, AND WHY
-- ============================================================================
-- ⚠ 100% EMPTY on all four books, so not emitted: registration_date (asset
-- index's own), stage_of_legal_proceedings, legal_restricted, status,
-- days_in_past_due, registration_balance, purchase_price, pricing_reference_
-- basis, overdue_interest_rate (SE only), beginning/end_payment_history_date,
-- last_payment_amount, insolvency_restructuring, bankruptcy_date,
-- insolvency_proceeding_name, status_of_legal_proceedings, enforcement_outcome.
-- The columns exist in the source. Nothing is in them.
--
-- ⚠ NO SECURED EXCLUSION, AND NONE IS NEEDED -- but it is ASSERTED, not
-- assumed: COLLATERAL holds ZERO rows for all four books, consistent with
-- unsecured consumer lending. IS_SECURED_FLAG comes from DIM_CASE where it
-- exists (ES25021 only) so a future delivery cannot quietly introduce
-- collateral into a book priced as unsecured.
--
-- ⚠ NO FORWARD-FLOW PREDICATE. Elsa needed one because PAM carries
-- deal_type_desc and 129 of 133 WiZink batches were monthly flow deliveries.
-- DEV.ASSET_INDEX has no equivalent column -- checked, PORTFOLIO carries only
-- country, currency, seller, security_class, product, deal_type. DEAL_TYPE is
-- 'OO' on all four, which reads as one-off. Stated rather than filtered.
--
-- ⚠ NO SME EXCLUSION APPLIED. It is a per-book instruction, not a rule. The
-- population is reported instead: a corporate holder is on 75 DE25020 loans
-- (49 JURISTISCHE_PERSON, 14 PERSONENGESELLSCHAFT, 12 EINZELUNTERNEHMEN).
-- Exclude at the FINAL SELECT if asked, so every figure above stays re-derivable.
--
-- ⚠⚠ NO PRICING SEGMENT IS EMITTED (changed 2026-10-02), matching
-- work/benchmark-dataset/post-registration-benchmark/templates/01_accounts.sql. What counts as a pricing segment
-- changes with every deal, and 'SME' is a size class this feed cannot answer.
-- Three FACTS ship instead, and more than one can be true:
--   LOAN_HOLDER_CORPORATE_FLAG / LOAN_HOLDER_INDIVIDUAL_FLAG, plus
--   LOAN_HOLDER_UNKNOWN_FLAG -- which is NOT the same as individual. CH25007
--   delivers no borrower type at all, so all 3,064 of its loans read unknown.
--
-- ⚠ LOAN_LEGAL_STATUS IS RAW AND MEANS A DIFFERENT THING PER SELLER -- CH25007
-- uses 1/2, DE25020 none/legal_proceedings, ES25021 NO/None, SE25008 Yes/No.
-- It is passed through untouched. DO NOT GROUP ACROSS BOOKS ON IT.
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
    -- ⚠⚠ ONE ROW PER CASE_SK. Everything below joins through this, so nothing
    -- downstream can fan out.
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

asset_index_case AS (
    -- ⚠ DEDUPED ON (portfolio_id, case_id). 3 of 278,932 rows repeat their key
    -- -- 2 on UK26002, 1 on DE25010. None is on a bridged book today, but an
    -- un-guarded join would double that loan's capital the moment one is.
    -- ⚠ CASES carries no update timestamp, so there is no "latest version" to
    -- pick; the duplicates are collapsed rather than ranked.
    SELECT
        portfolio_id,
        case_id,
        ANY_VALUE(principal_at_cutoff)                     AS cutoff_capital,
        ANY_VALUE(accrued_interest_at_cutoff)              AS cutoff_interest,
        ANY_VALUE(other_balances_at_cutoff)                AS cutoff_other_balance,
        ANY_VALUE(legal_balance_at_cutoff)                 AS cutoff_total_balance,
        ANY_VALUE(principal_at_default)                    AS default_capital,
        ANY_VALUE(principal_at_origination)                AS origination_capital,
        ANY_VALUE(TRY_TO_DATE(default_date))               AS default_date,
        ANY_VALUE(TRY_TO_DATE(inception_date))             AS inception_date,
        ANY_VALUE(TRY_TO_DATE(cutoff_date))                AS seller_cutoff_date,
        ANY_VALUE(TRY_TO_DATE(statute_of_limitations_date)) AS statute_of_limitations_date,
        ANY_VALUE(TRY_TO_DATE(date_of_legal_proceedings))  AS legal_proceedings_date,
        ANY_VALUE(type_of_instrument)                      AS type_of_instrument,
        ANY_VALUE(loan_legal_status)                       AS loan_legal_status,
        ANY_VALUE(sub_portfolio)                           AS sub_portfolio,
        ANY_VALUE(currency)                                AS case_currency
    FROM DEV.ASSET_INDEX.CASES
    GROUP BY 1, 2
),

case_counterparty AS (
    -- ⚠⚠ GROUPED TO ONE ROW PER CASE BEFORE IT JOINS. 383 SE25008 cases and 1
    -- ES25021 case carry two counterparties (co-debtors), so a bare join would
    -- emit those loans twice and double their capital.
    -- ⚠ FLAGS ARE OR'd ACROSS COUNTERPARTIES: a loan where either borrower is
    -- bankrupt is a bankrupt loan. MAX over 1/0 is that OR.
    SELECT
        r.portfolio_id,
        r.case_id,
        COUNT(*)                                           AS counterparty_count,
        MAX(IFF(c.bankruptcy, 1, 0)) = 1                   AS bankruptcy_flag,
        MAX(IFF(c.debt_restructuring, 1, 0)) = 1           AS debt_restructuring_flag,
        MAX(IFF(c.debt_settlement, 1, 0)) = 1              AS debt_settlement_flag,
        MAX(IFF(c.forbearance, 1, 0)) = 1                  AS forbearance_flag,
        MAX(IFF(c.deceased, 1, 0)) = 1                     AS deceased_flag,
        -- ⚠ COMPANY WINS, as on Elsa: a loan with any non-individual borrower
        -- is priced as SME. The opposite rule would move 75 DE25020 loans.
        MAX(IFF(c.legal_type_of_counterparty IN (
                    'JURISTISCHE_PERSON', 'PERSONENGESELLSCHAFT',
                    'EINZELUNTERNEHMEN'), 1, 0))           AS is_company,
        MAX(IFF(c.legal_type_of_counterparty IN (
                    'NATUERLICHE_PERSON', 'Consumer', 'Individual'), 1, 0))
                                                           AS is_individual,
        ANY_VALUE(c.country_of_counterparty)               AS counterparty_country,
        LISTAGG(DISTINCT r.role, ' + ')
            WITHIN GROUP (ORDER BY r.role)                 AS counterparty_roles
    FROM DEV.ASSET_INDEX.RELATIONSHIP AS r
    LEFT JOIN DEV.ASSET_INDEX.COUNTERPARTIES AS c
        ON c.portfolio_id = r.portfolio_id
        AND c.counterparty_id = r.counterparty_id
    WHERE r.link_type = 'case_counterparty'
    GROUP BY 1, 2
),

npl_common_case AS (
    -- What NPL_COMMON knows that the asset index does not. REGISTRATION_DATE is
    -- the whole reason this join exists -- see the header.
    -- ⚠ is_current_flag is applied in case_bridge, so this is one row per key.
    SELECT
        dc.case_sk,
        dc.registration_date::DATE                         AS registration_date,
        COALESCE(dc.derived_default_date, dc.default_date)::DATE
                                                           AS npl_common_default_date,
        dc.original_principal                              AS npl_common_original_principal,
        dc.secured_flag                                    AS is_secured_flag,
        dc.status_code                                     AS npl_common_status_code
    FROM PROD_NPL_COMMON.NPL_COMMON.DIM_CASE AS dc
    INNER JOIN case_scope AS s
        ON s.case_sk = dc.case_sk
    WHERE dc.is_current_flag = TRUE
),

case_portfolio_from_snapshot AS (
    -- ⚠⚠ PORTFOLIO_SK IS NOT ON DIM_CASE. Only two tables in NPL_COMMON carry
    -- case_sk and portfolio_sk together, and this is the one with coverage:
    -- FCT_CASE_SNAPSHOT_DAILY reaches 18,930 of 20,456 loans (92.5%) against
    -- 1,415 for the collection fact, which only knows loans that have paid.
    -- ⚠ ANY_VALUE IS SAFE HERE, VERIFIED. Measured 2026-09-22: not one loan in
    -- scope maps to more than one portfolio_sk, so there is nothing to choose
    -- between. Re-check that before reusing this pattern on another book.
    -- ⚠ 1.47bn rows, so the INNER JOIN to case_scope does the pruning.
    SELECT
        d.case_sk,
        ANY_VALUE(d.portfolio_sk)                          AS portfolio_sk
    FROM PROD_NPL_COMMON.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS d
    INNER JOIN case_scope AS s
        ON s.case_sk = d.case_sk
    GROUP BY 1
),

case_portfolio_from_collection AS (
    -- Fallback for loans absent from the snapshot. Free: this scan has to
    -- happen anyway for the capex date below.
    SELECT
        c.case_sk,
        ANY_VALUE(c.portfolio_sk)                          AS portfolio_sk
    FROM PROD_NPL_COMMON.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN case_scope AS s
        ON s.case_sk = c.case_sk
    -- ⚠ Collection dates in the year 4570 exist in this warehouse. Bound it.
    WHERE c.collection_date <= CURRENT_DATE()
    GROUP BY 1
),

case_portfolio AS (
    -- Snapshot first, collection second. ⚠ STILL NULL on loans neither knows.
    SELECT
        s.case_sk,
        COALESCE(sn.portfolio_sk, cl.portfolio_sk)         AS portfolio_sk
    FROM case_scope AS s
    LEFT JOIN case_portfolio_from_snapshot AS sn
        ON sn.case_sk = s.case_sk
    LEFT JOIN case_portfolio_from_collection AS cl
        ON cl.case_sk = s.case_sk
)

SELECT
    -- ---- keys. Mirrors the payments half exactly. -------------------------
    s.case_sk,
    s.case_bk,
    s.portfolio_id,
    s.case_id,
    s.servicer,
    -- ⚠ ABOVE 1 MEANS SEVERAL ASSET-INDEX CASES ARE THIS ONE LOAN.
    s.asset_index_case_count,

    -- ---- the book ---------------------------------------------------------
    pf.seller                                              AS seller_name,
    pf.country                                             AS country_name,
    pf.currency                                            AS currency_id,
    pf.deal_type,
    ai.sub_portfolio,
    -- ⚠⚠ NPL_COMMON'S PORTFOLIO KEY, resolved per loan -- see the header.
    -- NULL where neither the case snapshot nor the collection fact knows the
    -- loan. Do NOT infer it from PORTFOLIO_ID: an asset-index book can split
    -- across two NPL_COMMON portfolios (CH25007 and DE25020 each do).
    cp.portfolio_sk,
    dp.portfolio_bk                                        AS portfolio_name,
    -- Capex now comes from the loan's OWN portfolio, not a book-level minimum.
    dp.capex_date,
    ai.seller_cutoff_date,

    -- ---- dates ------------------------------------------------------------
    -- ⚠ FROM NPL_COMMON. The asset index's own column is 100% empty.
    nc.registration_date,
    ai.inception_date,
    -- ⚠ THE SELLER'S VIEW OF DEFAULT.
    ai.default_date,
    -- ⚠ OURS. The two disagree by years on some books -- see the header.
    nc.npl_common_default_date,
    DATEDIFF('DAY', nc.npl_common_default_date, ai.default_date)
                                                           AS default_date_gap_days,
    -- ⚠ TRUE where the two sources are more than a year apart. Not an error in
    -- itself; a signal that they mean different things on that book.
    ABS(DATEDIFF('DAY', nc.npl_common_default_date, ai.default_date)) > 365
                                                           AS default_date_suspect_flag,
    ai.legal_proceedings_date,
    ai.statute_of_limitations_date,

    -- ---- money at cutoff. ⚠⚠ CUTOFF_CAPITAL IS THE BENCHMARK COLUMN. -----
    ai.cutoff_capital,
    -- ⚠ FALSE on every CH25007 loan. That book cannot be valued here.
    ai.cutoff_capital IS NOT NULL                          AS has_cutoff_capital_flag,
    -- ⚠⚠ NOT THE BENCHMARK MONEY. For the delivery test only -- see header.
    ai.cutoff_interest,
    ai.cutoff_other_balance,
    -- ⚠⚠ INTEREST-INCLUSIVE. Never quote as "owed"; never sum with the above.
    ai.cutoff_total_balance,
    -- Other points in time, for completeness. Different dates, not substitutes.
    ai.default_capital,
    ai.origination_capital,
    nc.npl_common_original_principal,

    -- ---- borrower and segment ---------------------------------------------
    cc.counterparty_count,
    cc.counterparty_roles,
    cc.counterparty_country,
    -- ⚠ 'Unknown' where no borrower type was delivered, NOT 'Individual'.
    -- CH25007 delivers none at all. Unclassifiable is not the same as retail.
    -- ⚠ FACTS, NOT A SEGMENT. More than one can be true; unknown is its own
    -- flag because "no borrower type delivered" is not "individual".
    cc.is_company = 1                                      AS loan_holder_corporate_flag,
    cc.is_individual = 1                                   AS loan_holder_individual_flag,
    COALESCE(cc.is_company, 0) = 0
        AND COALESCE(cc.is_individual, 0) = 0              AS loan_holder_unknown_flag,

    -- ---- distress flags. ⚠ PATCHY BY BOOK -- see the header. -------------
    cc.bankruptcy_flag,
    cc.debt_restructuring_flag,
    cc.debt_settlement_flag,
    cc.forbearance_flag,
    cc.deceased_flag,
    -- ⚠ Asserted, not filtered: COLLATERAL is empty on all four books.
    nc.is_secured_flag,

    -- ---- passed through raw. ⚠ MEANS A DIFFERENT THING PER SELLER. -------
    ai.type_of_instrument,
    ai.loan_legal_status,
    nc.npl_common_status_code
FROM case_scope AS s
LEFT JOIN asset_index_case AS ai
    ON ai.portfolio_id = s.portfolio_id
    AND ai.case_id = s.case_id
LEFT JOIN npl_common_case AS nc
    ON nc.case_sk = s.case_sk
LEFT JOIN case_counterparty AS cc
    ON cc.portfolio_id = s.portfolio_id
    AND cc.case_id = s.case_id
LEFT JOIN DEV.ASSET_INDEX.PORTFOLIO AS pf
    ON pf.portfolio_id = s.portfolio_id
LEFT JOIN case_portfolio AS cp
    ON cp.case_sk = s.case_sk
LEFT JOIN PROD_NPL_COMMON.NPL_COMMON.DIM_PORTFOLIO AS dp
    ON dp.portfolio_sk = cp.portfolio_sk
