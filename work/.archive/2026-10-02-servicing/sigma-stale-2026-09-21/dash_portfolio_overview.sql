-- ============================================================================
-- GENERATED FILE — DO NOT EDIT.
--   source : work/servicing/prod/dash_portfolio_overview.sql
--   make   : mise run sigma-sql
--
-- Paste-ready for a Sigma Custom SQL element (Snowflake - PROD):
--   · `set` lines removed, every $variable replaced with a literal
--   · trailing `order by` and `;` removed — Sigma wraps this in a subquery
--
-- Edit the SOURCE and regenerate. Editing this copy is how the two drift.
-- ============================================================================


-- ============================================================================
-- dash_portfolio_overview — the PORTFOLIO-LEVEL Sigma dataset. PROD only.
-- GRAIN: one row per (PORTFOLIO_NAME, REPORTING_MONTH). EUR. Sums only.
-- ============================================================================
--   Terminal : mise run sql -- work/servicing/prod/dash_portfolio_overview.sql
--   Notebook : datalake.q("servicing/prod/dash_portfolio_overview")
--   PAIRS    nothing. This is the ONLY Sigma dataset.
--
-- THE SPLIT WAS UNDONE 2026-09-17. dash_portfolio_diagnostics.sql was deleted
-- and its payer counts folded in here, so Sigma reads one dataset.
--   Why: the amicable/legal split it carried comes from GROUP_CASE_PHASE,
--   whose codes Intrum has never documented and the business does not trust.
--   It also put an unmodelled 346m-row RAW table on a published dashboard.
--   NOTHING HERE READS RAW. The phase, secured and debt-age mix did not come
--   across — ask for them back only with a phase dictionary from Intrum.
--
-- ⚠⚠ PAYER COUNTS DO NOT RECONCILE TO THE MONEY ON THIS ROW, by design.
--   COLLECTIONS_SUM is the servicer's PORTFOLIO report; payer counts come from
--   the LOAN feed, which covers about half of it in EUR.
--   Some portfolios arrive as aggregates with no loan detail at all, so every
--   payer count is a FLOOR and a portfolio can show cash beside zero payers.
--   ⚠ A PORTFOLIO-MONTH WITH NO SERVICER REPORT HAS NO ROW, so its payers go
--   uncounted. Every row is driven by an ACTUALS row — that is what makes the
--   money right, but it hides loan payments in unreported months. Measured
--   2026-09-17: ORG-UK26003-U01/2606 and ORG-UK26002-U01/2606 only, hiding
--   ~31-33k payers a month over 2026-01..05, about 14% of the monthly count.
--   ⚠ NO LOAN-LEVEL MONEY IS RETURNED. The loan feed is in local currency and
--   this dataset is EUR; exposing it unconverted invites a mixed-currency sum.
--
-- NO RATIOS ARE RETURNED. Every money and count column is a plain sum, so
-- Sigma can filter to any slice and re-divide after filtering.
--   Performance = SUM(COLLECTIONS_SUM) / SUM(SERVICER_FORECAST_SUM). A stored
--   per-row ratio is wrong the moment anyone regroups.
--
-- ⚠⚠ CURRENCY IS NOT IN THE GRAIN, and that is a correctness fix. 24 of 6,840
--   portfolio-months carry TWO currencies (0.351%).
--   The scorecard leg was per-portfolio-month while actuals were per-currency,
--   so a per-currency join DOUBLE-COUNTED commission on those 24. Everything
--   converts to EUR before the collapse, so no money moves.
--
-- ⚠⚠ ALL THREE FORECASTS ARE RETURNED (restored 2026-09-21). They answer
--   different questions and must never be averaged or swapped for each other.
--     UNDERWRITING  what we assumed when we BOUGHT. Frozen, one vintage.
--                   The benchmark for "was the purchase a good one?"
--     ACCOUNTING    our CURRENT view, revised as we learn. THIS IS THE ONE
--                   FINANCE TRACKS in flash and revaluations (Simon, 2026-09-21).
--     SERVICER      Intrum's own projection, 3,078,580 rows and 66x finer.
--                   Answers "is the servicer hitting the plan?" only.
--   ⚠ ACCOUNTING IS BORN AS A COPY OF UNDERWRITING — 91.3% of portfolio-months
--   are still identical. Where they differ, WE have marked the book.
--   ⚠ A REPORT THAT WILL NOT TIE TO FLASH IS PROBABLY ON THE SERVICER'S PLAN.
--   Measured 2026-09-21: servicer and accounting agree on 79.3% of
--   portfolio-months; of the rest servicer is LOWER on 13.9% and higher on 6.2%.
--   ⚠ The since-inception chart and L3M ratio were built on the UNDERWRITING
--   plan. Pick one deliberately and caption the tile with which.
--
-- ⚠⚠ THE SERVICER FORECAST DOUBLE-COUNTS IF YOU JUST SUM IT. It carries
--   successive REVISIONS of a month — 1,172 of 43,302 hold more than one.
--   Guarded below by keeping the newest SNAPSHOT_VERSION per portfolio-month.
--   SERVICER_FORECAST_VERSION_COUNT shows how many existed. Do not sum it.
--   ⚠ HISTORICAL ONLY HERE: every row is driven by an ACTUALS row and bounded
--   to CURRENT_DATE(), so future projection months are not returned.
--   For forward months use prod/monthly_portfolio_forecast.sql ($months_ahead).
--
-- ⚠ L1M IS A LAG, NOT A ONE-MONTH WINDOW. COLLECTIONS_L1M_SUM and
--   SERVICER_FORECAST_L1M_SUM are the PRIOR month via lag(), NULL on month one.
--   L3M/L6M/L12M sum 3/6/12 calendar months EXCLUDING the current one, so L1M
--   is a COMPONENT of L3M, never a period beside it. Do not add them together.
--
-- ⚠⚠ THIS DATASET IS BROCC'S OWN COLLECTIONS AND NOTHING ELSE (2026-09-18).
--   Each portfolio starts at ITS OWN capex month — the month Brocc bought it.
--   Every book was bought 2025-12..2026-08, so the dataset runs 2025-12 onward
--   however much history the source holds. Earlier months are the seller's.
--   Including them overstated collections ~11x: EUR 3.57bn of seller cash
--   against EUR 347m of Brocc's.
--   ⚠ A PORTFOLIO WITH NO CAPEX DATE IS KEPT IN FULL, deliberately — its
--   window cannot be cut when nobody knows when the window opens.
--   Today that is one, the Guard 1 sentinel: 24 months from 2024-09 and
--   EUR 23,675,055.80, of which 11.2m predates every other acquisition.
--   It is the only PORTFOLIO_NAME starting '(Unknown Portfolio' — that is how
--   you find or exclude it. There is no flag; the name says it.
--   ⚠ To see seller history again, drop the capex predicate in
--   `portfolio_metrics`. A rolling 120-month bounds CTE and a 2000-01-01 floor
--   both lived here and both were removed; neither ever bound on anything.
--
-- ⚠ NOTHING IS DROPPED FOR WANT OF A RATE (changed 2026-09-18). An
--   unconvertible month is RETAINED with NULL in every EUR column.
--   Read it via COLLECTIONS_LOCAL_CURRENCY / BALANCE_LOCAL_CURRENCY beside
--   ORIGINAL_CURRENCY. A missing rate is not a reason to delete a month.
--   ⚠⚠ THERE IS NO HAS_FX_FLAG. Removed 2026-09-18: in Brocc's window it was
--   TRUE on every row, because FX starts 2018-01-31 and nothing predates 2025.
--   ⚠ IF YOU WIDEN THE WINDOW BACK INTO SELLER HISTORY, PUT IT BACK, or months
--   with NULL money look identical to months with none:
--       MIN(IFF(w.rate_flow IS NOT NULL AND w.rate_stock IS NOT NULL, 1, 0)) = 1
--
-- ⚠ PROD only. Read-only. Nothing may follow the final semicolon.
-- ============================================================================



WITH portfolio_base AS (
    -- ⚠ THE SOURCE COLUMN IS gbv. gross_book_value is our name for it, so it
    -- must be aliased here; a bare reference does not compile.
    SELECT
        portfolio_sk,
        portfolio_bk,
        capex_date,
        capex_amount,
        gbv AS gross_book_value,
        price_gross,
        price_percent,
        flow_type,
        currency_id AS portfolio_currency
    FROM PROD.NPL_COMMON.DIM_PORTFOLIO
    WHERE portfolio_bk LIKE '%'

    UNION ALL

    -- Guard 1. Fact rows with no dimension row. Do not remove: 2.69% of cash.
    -- ⚠⚠ ANTI-JOIN: TEST THE RIGHT SIDE FOR NULL, d.portfolio_sk IS NULL.
    --
    -- Testing f (the left side) instead matches nothing and silently drops the
    -- sentinel. LEFT JOIN is preferred over NOT IN, which returns NO ROWS AT
    -- ALL if the subquery yields one NULL.
    SELECT
        f.portfolio_sk,
        '(Unknown Portfolio ' || f.portfolio_sk || ')',
        NULL,                                  -- capex_date
        NULL,                                  -- capex_amount
        NULL,                                  -- gross_book_value
        NULL,                                  -- price_gross
        NULL,                                  -- price_percent
        NULL,                                  -- flow_type
        NULL                                   -- portfolio_currency
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS d
        ON d.portfolio_sk = f.portfolio_sk
    WHERE d.portfolio_sk IS NULL
      AND ('(Unknown Portfolio ' || f.portfolio_sk || ')') LIKE '%'
    GROUP BY f.portfolio_sk
),

fx_rates AS (
    -- ⚠ 'EUR', UPPERCASE, IS THE LITERAL IN BOTH TABLES. Lower-case matches
    -- nothing and silently empties this CTE, and with it every EUR column.
    SELECT
        date_day      AS month_end,
        quote_currency AS ccy,
        monthly_avg   AS rate_flow,        -- flows: collections, forecasts
        ultimo_value  AS rate_stock        -- stocks: balance, carrying
    FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR' AND rate_type = 'PMI' AND quote_currency <> 'EUR'

    UNION ALL

    -- ⚠ EUR IS NOT A CONVERSION — rate 1, so this leg must not depend on the
    -- FX table (it starts 2018-01-31). Spine is the fact's own months.
    SELECT DISTINCT period_end_date, 'EUR', 1, 1
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
),

fx_base AS (
    -- Banner values only: the span of usable rates.
    SELECT
        MIN(month_end) AS fx_start_date,
        MAX(month_end) AS fx_end_date
    FROM fx_rates
    WHERE rate_flow IS NOT NULL AND rate_stock IS NOT NULL
),

portfolio_metrics AS (
    SELECT
        f.portfolio_sk,
        f.period_end_date,
        f.currency_id,
        MAX(f.country_id)             AS country_code,
        MAX(f.deal_sk)                AS deal_sk,
        MAX(f.deal_source_sk)         AS deal_source_sk,
        MAX(f.legal_buyer_sk)         AS legal_buyer_sk,
        COUNT(DISTINCT f.batch_sk)    AS batch_count,
        SUM(f.gross_cash_recoveries)  AS collections_local_currency,
        SUM(f.net_cash_recoveries)    AS net_collections_local_currency,
        SUM(f.total_balance)          AS balance_local_currency,
        -- The servicer's cut, itemised, from the SAME scan. Was a second full
        -- read of the fact (portfolio_leg); folded in 2026-09-15.
        SUM(f.commission)             AS commission_local,
        SUM(f.portfolio_mgmt_fee)     AS portfolio_mgmt_fee_local,
        SUM(f.passthrough_cost)       AS passthrough_cost_local
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    INNER JOIN portfolio_base AS p
        ON p.portfolio_sk = f.portfolio_sk
    -- ⚠⚠ FLOOR = BROCC'S ACQUISITION MONTH, PER PORTFOLIO. Earlier months are
    -- the SELLER'S. Applied here only; every output row hangs off this.
    --
    -- ⚠ NO CAPEX DATE MEANS KEEP IT: a NULL fails the test and would take the
    -- whole portfolio with it.
    WHERE (p.capex_date IS NULL
           OR f.period_end_date >= DATE_TRUNC('MONTH', p.capex_date))
      AND f.period_end_date <= CURRENT_DATE()                          -- Guard 4
    GROUP BY 1, 2, 3
),

servicer_forecast AS (
    -- ⚠ THE DOUBLE-COUNT GUARD. Newest snapshot_version per portfolio-month;
    -- n_versions counted BEFORE the filter so the roll-up reports what it drop
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast) AS servicer_forecast_local,
           MAX(n_versions_available)      AS servicer_forecast_version_count
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.snapshot_version,
            f.gross_collection_forecast,
               COUNT(DISTINCT f.snapshot_version) OVER (
                   PARTITION BY f.portfolio_sk, f.period_end_date
               ) AS n_versions_available
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

accounting_forecast AS (
    -- Our CURRENT view, revised as we learn. THIS IS THE ONE FINANCE TRACKS in
    -- the flash and revaluations (confirmed with Simon, 2026-09-21).
    -- ⚠ Born as a copy of underwriting: 91.3% of portfolio-months are still
    -- identical to it. Where they differ, we have marked the book.
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast) AS accounting_forecast_local,
        MAX(n_versions_available)      AS accounting_forecast_version_count
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.snapshot_version,
            f.gross_collection_forecast,
            COUNT(DISTINCT f.snapshot_version) OVER (
                PARTITION BY f.portfolio_sk, f.period_end_date
            ) AS n_versions_available
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

underwriting_forecast AS (
    -- What we assumed when we BOUGHT. Restored 2026-09-21 beside the servicer's
    -- plan; see the header for how the three differ.
    -- ⚠ Same version guard as the servicer. Underwriting has ONE vintage today,
    -- so it is insurance, not a live filter -- keep it if a second ever lands.
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        SUM(gross_collection_forecast) AS underwriting_forecast_local,
        MAX(n_versions_available)      AS underwriting_forecast_version_count
    FROM (
        SELECT
            f.portfolio_sk,
            f.period_end_date,
            f.currency_id,
            f.snapshot_version,
            f.gross_collection_forecast,
            COUNT(DISTINCT f.snapshot_version) OVER (
                PARTITION BY f.portfolio_sk, f.period_end_date
            ) AS n_versions_available
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (
            PARTITION BY f.portfolio_sk, f.period_end_date
        )
    )
    GROUP BY 1, 2, 3
),

carrying_amount_base AS (
    SELECT
        portfolio_sk,
        period_end_date,
        currency_id,
        closing_value::NUMBER(38, 6) AS carrying_local
    FROM PROD.NPL_COMMON.FCT_CARRYING_AMOUNT
    WHERE period_end_date <= CURRENT_DATE()                            -- Guard 4
),

last_complete_month AS (
    -- Newest month whose portfolio count has not collapsed against the prior
    -- month — i.e. the last month the servicers have actually reported.
    SELECT MAX(m.period_end_date) AS month_end
    FROM (SELECT period_end_date,
                 COUNT(DISTINCT portfolio_sk) AS n,
                 LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY period_end_date) AS prev_n
          FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
          WHERE period_end_date <= CURRENT_DATE()
          GROUP BY 1) m
    WHERE m.prev_n IS NULL OR m.n >= 0.5 * m.prev_n
),

-- LOAN-LEVEL PAYER DYNAMICS. One row per loan per month in which it paid.
-- ⚠ COUNT ON CASE_ID, NEVER CASE_SK — CASE_SK is an SCD version key.
--
-- ⚠⚠ CUT TO BROCC'S WINDOW LIKE EVERYTHING ELSE (2026-09-18). The LAG/LEAD
-- below used to see the SELLER'S months, which made the early months lie.
--
--   In the first Brocc month 114,908 loans read as "paying consistently for
--   three months" on a book Brocc had owned for one.
--
--   "First payment" now means first payment UNDER BROCC, and
--   PAYMENT_LOANS_NOPAYING_COUNT means "has not paid SINCE ACQUISITION".
case_metrics_base AS (
    -- The ONLY read of the 134m-row collection fact. Payer logic and the
    -- monthly reconciliation both hang off this, so it is not scanned twice.
    SELECT
        c.portfolio_sk,
        c.case_id,
        c.currency_id,
        DATE_TRUNC('MONTH', c.collection_date) AS collection_month,
        SUM(c.amount)                          AS amount
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN portfolio_base AS ps
        ON ps.portfolio_sk = c.portfolio_sk
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
      -- Same floor as portfolio_metrics: no capex date means keep everything.
      AND (ps.capex_date IS NULL
           OR c.collection_date >= DATE_TRUNC('MONTH', ps.capex_date))
    GROUP BY 1, 2, 3, 4
),

case_base AS (
    -- Currency dropped: a loan that paid is a loan that paid, and keeping it
    -- would count a two-currency loan twice as a payer.
    SELECT
        portfolio_sk,
        case_id,
        collection_month
    FROM case_metrics_base
    GROUP BY 1, 2, 3
),

cat_monthly AS (
    -- Loan-level cash per portfolio-month-currency, for IS_RECONCILED_FLAG
    -- only. Kept LOCAL and compared local, so the check needs no FX.
    SELECT
        portfolio_sk,
        collection_month,
        currency_id,
        SUM(amount) AS cat_collections_local_currency
    FROM case_metrics_base
    GROUP BY 1, 2, 3
),

case_metrics_window AS (
    -- ⚠ THESE ARE PREVIOUS/NEXT *PAYING* MONTHS, NOT CALENDAR MONTHS — only
    -- 55.7% of loan-months sit one month after the last. Always test the date.
    SELECT
        portfolio_sk,
        case_id,
        collection_month,
           LAG(collection_month, 1)  OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS previous_1_month,
           LAG(collection_month, 2)  OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS previous_2_months,
           LEAD(collection_month, 1) OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS next_1_month,
           LEAD(collection_month, 2) OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS next_2_months
    FROM case_base
),

monthly_payers AS (
    -- L0 is the row's month, L1 the one before, L2 two before. Both prev slots
    -- are tested because a loan can skip L1 and still have paid L2.
    SELECT
        portfolio_sk,
        collection_month,
           COUNT(*) AS paying_loan_count,
           SUM(IFF(previous_1_month IS NULL, 1, 0)) AS paying_loans_activated_count,
           SUM(IFF(previous_1_month = DATEADD('MONTH', -1, collection_month)
                   AND previous_2_months = DATEADD('MONTH', -2, collection_month), 1, 0)) AS paying_loans_consistent_3m_count,
           SUM(IFF(COALESCE(previous_1_month = DATEADD('MONTH', -2, collection_month), FALSE)
                   OR COALESCE(previous_2_months = DATEADD('MONTH', -2, collection_month), FALSE),
                   0, 1)) AS payment_loans_jitter_count,
           SUM(IFF(COALESCE(previous_1_month = DATEADD('MONTH', -1, collection_month), FALSE)
                   OR COALESCE(previous_1_month = DATEADD('MONTH', -2, collection_month), FALSE)
                   OR COALESCE(previous_2_months = DATEADD('MONTH', -2, collection_month), FALSE),
                   0, 1)) AS payment_loans_new_count
    FROM case_metrics_window
    GROUP BY 1, 2
),

max_paid_month AS (
    -- The last month ANY loan paid. A "lost" count after it would be the data
    -- ending, not a loan stopping.
    SELECT
        MAX(collection_month) AS max_month
    FROM case_base
),

monthly_lost AS (
    -- Paid in L2, not in L0, counted AT L0 — anchored two months after the
    -- payment that ends the run.
    SELECT
        s.portfolio_sk,
        DATEADD('MONTH', 2, s.collection_month) AS collection_month,
        COUNT(*)                                AS payment_loans_lost_count
    FROM case_metrics_window AS s
    CROSS JOIN max_paid_month AS m
    WHERE DATEADD('MONTH', 2, s.collection_month) <= m.max_month
      AND NOT COALESCE(s.next_1_month  = DATEADD('MONTH', 2, s.collection_month), FALSE)
      AND NOT COALESCE(s.next_2_months = DATEADD('MONTH', 2, s.collection_month), FALSE)
    GROUP BY 1, 2
),

portfolio_loan_detail AS (
    -- Does the LOAN feed cover this portfolio at all? 84 of 265 report cash
    -- and never a payer, arriving as portfolio-level aggregates.
    SELECT
        portfolio_sk,
        MAX(paying_loan_count) AS max_payers
    FROM monthly_payers
    GROUP BY 1
),

portfolio_month_coverage AS (
    -- How many servicer months the loan feed also covers. One month agreeing
    -- proves little if the feed is absent from the rest.
    SELECT
        a.portfolio_sk,
        COUNT(DISTINCT a.period_end_date)   AS months_pam,
        COUNT(DISTINCT cm.collection_month) AS months_cat
    FROM portfolio_metrics AS a
    LEFT JOIN cat_monthly AS cm
        ON cm.portfolio_sk = a.portfolio_sk
        AND cm.collection_month = DATE_TRUNC('MONTH', a.period_end_date)
    GROUP BY 1
),

portfolio_last_payment AS (
    SELECT
        portfolio_sk,
        MAX(collection_month) AS last_payment_month
    FROM case_base
    GROUP BY 1
),

book AS (
    -- Loans held at that portfolio's own latest snapshot day. FCT_CASE_
    -- SNAPSHOT_DAILY is month-end grain despite the name: 147 dates, all EOM.
    SELECT
        s.portfolio_sk,
        s.case_id
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    INNER JOIN (SELECT portfolio_sk, MAX(date_day) AS latest_day
                FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
                GROUP BY 1) AS l
        ON l.portfolio_sk = s.portfolio_sk
        AND l.latest_day = s.date_day
    GROUP BY 1, 2
),

book_stats AS (
    -- Static per portfolio. 21.9m loans on book, 15.557% ever paid.
    SELECT
        b.portfolio_sk,
        COUNT(*)                        AS loans_on_book_count,
           COUNT_IF(e.case_id IS NOT NULL) AS payment_loans_ever_paid_count,
           COUNT_IF(e.case_id IS NULL)     AS payment_loans_nopaying_count
    FROM book AS b
    LEFT JOIN (SELECT portfolio_sk, case_id FROM case_base GROUP BY 1, 2) AS e
        ON e.portfolio_sk = b.portfolio_sk
        AND e.case_id = b.case_id
    GROUP BY 1
),

subservicer_map AS (
    -- Hardcoded: NOTHING IN THE WAREHOUSE CARRIES SUB-SERVICER. Keys are the
    -- analyst's own, verbatim 2026-09-18 and deliberately NOT corrected.
    --
    -- ⚠⚠ TWO OF THREE MATCH NO PORTFOLIO, so they label nothing and TDX never
    -- appears: DIM_PORTFOLIO has LEG-ES25001-U01 (not U00).
    --
    -- The Greek Heimdall books are S01/U02/U03/U04 — there is no U01. Only
    -- HEI-GR25001-U02/2512 resolves; confirm the other two before use.
    SELECT 'LEG-ES25001-U00/2512' AS portfolio_bk, 'TDX' AS subservicer
    UNION ALL SELECT 'HEI-GR25001-U01/2512', 'QQuant'
    UNION ALL SELECT 'HEI-GR25001-U02/2512', 'QQuant'
),

standardised_metrics AS (
    SELECT
        ps.portfolio_sk,
        ps.portfolio_bk                                AS portfolio,
        a.period_end_date                              AS month_end,
        -- A month INDEX, so a rolling window counts months and not rows.
        -- A portfolio with a gap would otherwise roll the wrong three periods.
        DATEDIFF(MONTH, '1900-01-01', a.period_end_date) AS month_index,
        a.currency_id                                  AS original_currency,
        a.country_code,
        a.deal_sk,
        a.deal_source_sk,
        a.legal_buyer_sk,
        a.batch_count,
        ps.capex_date,
        ps.flow_type,
        ps.price_percent,
        ps.portfolio_currency,
        ps.capex_amount     * cfx.rate_stock           AS capex_euro,
        ps.gross_book_value * cfx.rate_stock           AS gross_book_value_euro,

        a.collections_local_currency     * f.rate_flow  AS collections_euro,
        a.net_collections_local_currency * f.rate_flow  AS net_collections_euro,
        sf.servicer_forecast_local       * f.rate_flow  AS servicer_forecast_euro,
        sf.servicer_forecast_version_count,
        uf.underwriting_forecast_local   * f.rate_flow  AS underwriting_forecast_euro,
        uf.underwriting_forecast_version_count,
        af.accounting_forecast_local     * f.rate_flow  AS accounting_forecast_euro,
        af.accounting_forecast_version_count,
        a.balance_local_currency         * f.rate_stock AS balance_euro,
        ca.carrying_local                * f.rate_stock AS carrying_amount_euro,
        -- ⚠ Sign-flipped at source; negated so a cost reads positive.
        -a.commission_local         * f.rate_flow      AS commission_euro,
        -a.portfolio_mgmt_fee_local * f.rate_flow      AS portfolio_mgmt_fee_euro,
        -a.passthrough_cost_local   * f.rate_flow      AS passthrough_cost_euro,
        (a.collections_local_currency - a.net_collections_local_currency) * f.rate_flow
                                                       AS servicer_cost_total_euro,

        a.collections_local_currency,
        a.balance_local_currency,
        f.rate_flow,
        f.rate_stock,

        -- ---- payer dynamics. One value per PORTFOLIO-MONTH, so these repeat
        -- across a two-currency month and are MAX'd, never summed, at the end.
        COALESCE(mp.paying_loan_count, 0)                    AS paying_loan_count,
        COALESCE(mp.paying_loans_activated_count, 0)         AS paying_loans_activated_count,
        COALESCE(mp.paying_loans_consistent_3m_count, 0)     AS paying_loans_consistent_3m_count,
        COALESCE(mp.payment_loans_jitter_count, 0)           AS payment_loans_jitter_count,
        COALESCE(mp.payment_loans_new_count, 0)              AS payment_loans_new_count,
        COALESCE(ml.payment_loans_lost_count, 0)             AS payment_loans_lost_count,
        bs.loans_on_book_count,
        COALESCE(bs.payment_loans_nopaying_count, 0)         AS payment_loans_nopaying_count,
        COALESCE(bs.payment_loans_ever_paid_count, 0)        AS payment_loans_ever_paid_count,
        plp.last_payment_month                               AS portfolio_last_payment_month,
        -- 0 in the month Brocc bought it, 1 the month after. NULL with no
        -- capex date.
        DATEDIFF(MONTH, DATE_TRUNC('MONTH', ps.capex_date),
                        DATE_TRUNC('MONTH', a.period_end_date))
                                                       AS months_since_acquisition,
        IFF(COALESCE(pld.max_payers, 0) > 0, 1, 0)     AS have_loan_detail_flag,
        -- ⚠ 1 where the portfolio stopped delivering: a missing file, not
        -- behaviour. Filter before quoting PAYMENT_LOANS_LOST_COUNT.
        IFF(DATE_TRUNC('MONTH', a.period_end_date) > plp.last_payment_month, 1, 0)
                                                       AS feed_stopped_flag,
        -- Share of this portfolio's servicer months the loan feed also covers.
        ROUND(100.0 * COALESCE(pmc.months_cat, 0)
              / NULLIF(pmc.months_pam, 0), 2)          AS cat_month_coverage_pct,
        -- ⚠ RECONCILED NEEDS BOTH TESTS. 1: loan cash within 10% of the
        -- servicer's, same month and currency, both local.
        --
        -- 2: the feed covers >=80% of the portfolio's servicer months (added
        -- 2026-09-18 — a thin feed can match by luck). No detail fails test 1.
        IFF(cm.cat_collections_local_currency IS NOT NULL
            AND ABS(a.collections_local_currency - cm.cat_collections_local_currency)
                <= 0.10 * ABS(NULLIF(a.collections_local_currency, 0))
            AND COALESCE(pmc.months_cat, 0) >= 0.80 * pmc.months_pam, 1, 0)
                                                       AS month_reconciled_flag
    FROM portfolio_metrics AS a
    INNER JOIN portfolio_base AS ps
        ON ps.portfolio_sk = a.portfolio_sk
    LEFT JOIN fx_rates AS f
        ON f.ccy = a.currency_id
        AND f.month_end = a.period_end_date
    LEFT JOIN fx_rates AS cfx
        ON cfx.ccy = ps.portfolio_currency
        AND cfx.month_end = LAST_DAY(ps.capex_date)
    LEFT JOIN servicer_forecast AS sf
        ON sf.portfolio_sk = a.portfolio_sk
        AND sf.period_end_date = a.period_end_date
        AND sf.currency_id = a.currency_id
    LEFT JOIN underwriting_forecast AS uf
        ON uf.portfolio_sk = a.portfolio_sk
        AND uf.period_end_date = a.period_end_date
        AND uf.currency_id = a.currency_id
    LEFT JOIN accounting_forecast AS af
        ON af.portfolio_sk = a.portfolio_sk
        AND af.period_end_date = a.period_end_date
        AND af.currency_id = a.currency_id
    LEFT JOIN carrying_amount_base AS ca
        ON ca.portfolio_sk = a.portfolio_sk
        AND ca.period_end_date = a.period_end_date
        AND ca.currency_id = a.currency_id
    -- Payer legs join on the MONTH, not the currency: they are per
    -- portfolio-month and carry no currency of their own.
    LEFT JOIN monthly_payers AS mp
        ON mp.portfolio_sk = a.portfolio_sk
        AND mp.collection_month = DATE_TRUNC('MONTH', a.period_end_date)
    LEFT JOIN monthly_lost AS ml
        ON ml.portfolio_sk = a.portfolio_sk
        AND ml.collection_month = DATE_TRUNC('MONTH', a.period_end_date)
    LEFT JOIN book_stats AS bs
        ON bs.portfolio_sk = a.portfolio_sk
    LEFT JOIN portfolio_last_payment AS plp
        ON plp.portfolio_sk = a.portfolio_sk
    LEFT JOIN portfolio_loan_detail AS pld
        ON pld.portfolio_sk = a.portfolio_sk
    LEFT JOIN portfolio_month_coverage AS pmc
        ON pmc.portfolio_sk = a.portfolio_sk
    LEFT JOIN cat_monthly AS cm
        ON cm.portfolio_sk = a.portfolio_sk
        AND cm.collection_month = DATE_TRUNC('MONTH', a.period_end_date)
        AND cm.currency_id = a.currency_id
),

aggregated_metrics AS (
    -- ⚠ RANGE, not ROWS, on a month INDEX: a portfolio with a missing month
    -- must roll the previous CALENDAR months, not the previous rows.
    SELECT
        c.*,
        -- ⚠ NO COLLECTIONS_L0M COLUMN, deliberately: one row PER MONTH, so
        -- L0M is simply COLLECTIONS_SUM on that row.
        --
        -- A duplicate would invite someone to sum it and get all-time
        -- collections believing they had this month. L1M is a real lag.
        LAG(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS collections_l1m_euro,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS collections_l3m_euro,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS collections_l6m_euro,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS collections_l12m_euro,
        LAG(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS servicer_forecast_l1m_euro,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS servicer_forecast_l3m_euro,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS servicer_forecast_l6m_euro,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS servicer_forecast_l12m_euro,
        LAG(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS underwriting_forecast_l1m_euro,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS underwriting_forecast_l3m_euro,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS underwriting_forecast_l6m_euro,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS underwriting_forecast_l12m_euro,
        LAG(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index)         AS accounting_forecast_l1m_euro,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS accounting_forecast_l3m_euro,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS accounting_forecast_l6m_euro,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS accounting_forecast_l12m_euro,
        COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)
                                         AS months_in_l3m_window,
        COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 6 PRECEDING AND 1 PRECEDING)
                                         AS months_in_l6m_window,
        COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index RANGE BETWEEN 12 PRECEDING AND 1 PRECEDING)
                                         AS months_in_l12m_window,
        SUM(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_collections_euro,
        SUM(c.servicer_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_servicer_forecast_euro,
        -- Collections restricted to months where a plan exists, so the
        -- since-inception chart compares like with like. See FLAGS.md §3.
        SUM(IFF(c.servicer_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (
            PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_collections_in_servicer_window_euro,
        SUM(c.underwriting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_underwriting_forecast_euro,
        SUM(IFF(c.underwriting_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (
            PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_collections_in_underwriting_window_euro,
        SUM(c.accounting_forecast_euro) OVER (PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_accounting_forecast_euro,
        SUM(IFF(c.accounting_forecast_euro IS NOT NULL, c.collections_euro, 0)) OVER (
            PARTITION BY c.portfolio, c.original_currency
            ORDER BY c.month_index ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_collections_in_accounting_window_euro
    FROM standardised_metrics AS c
)


-- ONE ROW PER PORTFOLIO-MONTH. Currency is summed away; everything is EUR.
-- ============================================================================
SELECT
    -- ---- drill path, outermost first -------------------------------------
    COALESCE(lb.legal_buyer_name, 'Unknown')            AS vehicle,
    COALESCE(ds.deal_source_name, 'Unknown')            AS project,
    COALESCE(dd.deal_alias, dd.deal_bk, 'Unknown')      AS deal,
    -- ⚠ SERVICER_GROUP IS DEFINED FIRST because SERVICER references it. A
    -- Snowflake alias can only be reused by a LATER expression in the list.
    CASE WHEN ds.deal_source_name = 'LEGACY' AND w.country_code = 'ES' THEN 'Gescobro'
         WHEN ds.deal_source_name = 'LEGACY' AND w.country_code = 'IT' THEN 'Cerved'
         ELSE 'Intrum' END                              AS servicer_group,
    -- '' rather than NULL, so Sigma groups the un-sub-serviced rows together
    -- instead of scattering them into a null bucket. See subservicer_map.
    COALESCE(sm.subservicer, '')                        AS servicer_sub_group,
    -- 'Gescobro - TDX' where a sub-servicer exists, plain 'Intrum' where not.
    IFF(sm.subservicer IS NOT NULL,
        servicer_group || ' - ' || sm.subservicer,
        servicer_group)                                 AS servicer,
    COALESCE(dd.seller_name, 'Unknown')                 AS seller,
    -- UK is not in DIM_COUNTRY's region map; everything else takes its region.
    CASE WHEN COALESCE(co.country_name, w.country_code, 'Unknown') = 'UK'
         THEN 'Europe' ELSE co.region END               AS region,
    COALESCE(co.country_name, w.country_code, 'Unknown') AS country_name,
    COALESCE(w.country_code, 'Unknown')                 AS country_code,
    w.flow_type,
    w.portfolio                                         AS portfolio_name,
    YEAR(w.capex_date)                                  AS capex_year,
    DATE_TRUNC('MONTH', w.capex_date)::DATE             AS capex_month,
    w.capex_date,

    -- ---- slicers ---------------------------------------------------------
    w.month_end                                         AS reporting_month,
    YEAR(w.month_end)                                   AS reporting_year,

    -- 'EUR', or 'EUR + SEK' where a portfolio-month carries two. See header.
    LISTAGG(DISTINCT w.original_currency, ' + ')
        WITHIN GROUP (ORDER BY w.original_currency)     AS original_currency,
    MAX(w.price_percent)                                AS price_percent,
    MAX(w.batch_count)                                  AS batch_count,
    MAX(w.capex_euro)                                   AS capex_sum,
    MAX(w.gross_book_value_euro)                        AS gross_book_value_sum,

    -- ---- the month. Sum these. -------------------------------------------
    SUM(w.collections_euro)                             AS collections_sum,
    SUM(w.net_collections_euro)                         AS net_collections_sum,
    -- ⚠ THE SERVICER'S OWN PROJECTION. Accounting and underwriting forecasts
    -- were removed 2026-09-15; the header says how to put one back.
    SUM(w.servicer_forecast_euro)                       AS servicer_forecast_sum,
    MAX(w.servicer_forecast_version_count)              AS servicer_forecast_version_count,
    -- ⚠ WHAT WE ASSUMED WHEN WE BOUGHT, not what the servicer now projects.
    -- The two answer different questions -- see the header before mixing them.
    SUM(w.underwriting_forecast_euro)                   AS underwriting_forecast_sum,
    MAX(w.underwriting_forecast_version_count)          AS underwriting_forecast_version_count,
    -- ⚠ OUR CURRENT VIEW, and the one Finance reports in flash/revaluations.
    -- Use this to tie out to flash; use the servicer's to judge the servicer.
    SUM(w.accounting_forecast_euro)                     AS accounting_forecast_sum,
    MAX(w.accounting_forecast_version_count)            AS accounting_forecast_version_count,
    SUM(w.balance_euro)                                 AS balance_sum,
    SUM(w.carrying_amount_euro)                         AS carrying_amount_sum,

    -- ---- rolling and cumulative. Sums, so they survive any filter. -------
    SUM(w.collections_l1m_euro)                         AS collections_l1m_sum,
    SUM(w.collections_l3m_euro)                         AS collections_l3m_sum,
    SUM(w.collections_l6m_euro)                         AS collections_l6m_sum,
    SUM(w.collections_l12m_euro)                        AS collections_l12m_sum,
    SUM(w.servicer_forecast_l1m_euro)                   AS servicer_forecast_l1m_sum,
    SUM(w.servicer_forecast_l3m_euro)                   AS servicer_forecast_l3m_sum,
    SUM(w.servicer_forecast_l6m_euro)                   AS servicer_forecast_l6m_sum,
    SUM(w.servicer_forecast_l12m_euro)                  AS servicer_forecast_l12m_sum,
    SUM(w.underwriting_forecast_l1m_euro)               AS underwriting_forecast_l1m_sum,
    SUM(w.underwriting_forecast_l3m_euro)               AS underwriting_forecast_l3m_sum,
    SUM(w.underwriting_forecast_l6m_euro)               AS underwriting_forecast_l6m_sum,
    SUM(w.underwriting_forecast_l12m_euro)              AS underwriting_forecast_l12m_sum,
    SUM(w.accounting_forecast_l1m_euro)                 AS accounting_forecast_l1m_sum,
    SUM(w.accounting_forecast_l3m_euro)                 AS accounting_forecast_l3m_sum,
    SUM(w.accounting_forecast_l6m_euro)                 AS accounting_forecast_l6m_sum,
    SUM(w.accounting_forecast_l12m_euro)                AS accounting_forecast_l12m_sum,
    -- 3 / 6 / 12 means a full window. Less means the portfolio is too young
    -- and that period is NOT comparable. Show it or gate on it.
    MAX(w.months_in_l3m_window)                         AS months_in_l3m_window,
    MAX(w.months_in_l6m_window)                         AS months_in_l6m_window,
    MAX(w.months_in_l12m_window)                        AS months_in_l12m_window,
    -- ⚠ RUNNING TOTALS. Filter to one month before summing, or you add nine
    -- running totals together. To total, sum COLLECTIONS_SUM instead.
    SUM(w.cumulative_collections_euro)                  AS cumulative_collections_sum,
    SUM(w.cumulative_servicer_forecast_euro)            AS cumulative_servicer_forecast_sum,
    SUM(w.cumulative_collections_in_servicer_window_euro) AS cumulative_collections_in_servicer_window_sum,
    SUM(w.cumulative_underwriting_forecast_euro)        AS cumulative_underwriting_forecast_sum,
    SUM(w.cumulative_collections_in_underwriting_window_euro) AS cumulative_collections_in_underwriting_window_sum,
    SUM(w.cumulative_accounting_forecast_euro)          AS cumulative_accounting_forecast_sum,
    SUM(w.cumulative_collections_in_accounting_window_euro) AS cumulative_collections_in_accounting_window_sum,

    -- ---- SERVICER COST. Was dash_servicer_scorecard. ---------------------
    SUM(w.commission_euro)                              AS servicer_commission_sum,
    SUM(w.portfolio_mgmt_fee_euro)                      AS servicer_portfolio_management_fee_sum,
    SUM(w.passthrough_cost_euro)                        AS servicer_passthrough_cost_sum,
    SUM(w.servicer_cost_total_euro)                     AS servicer_cost_total_sum,

    -- ---- PAYER DYNAMICS. Was dash_portfolio_diagnostics. -----------------
    -- ⚠ MAX NOT SUM (per portfolio-month). A FLOOR, NOT A TOTAL — see header.
    MAX(w.paying_loan_count)                            AS paying_loans_count,
    MAX(w.paying_loans_activated_count)                 AS paying_loans_activated_count,
    MAX(w.paying_loans_consistent_3m_count)             AS paying_loans_consistent_3m_count,
    MAX(w.payment_loans_jitter_count)                   AS payment_loans_jitter_count,
    MAX(w.payment_loans_new_count)                      AS payment_loans_new_count,
    MAX(w.payment_loans_lost_count)                     AS payment_loans_lost_count,
    -- Static per portfolio, identical on every month.
    MAX(w.loans_on_book_count)                          AS loans_on_book_count,
    MAX(w.payment_loans_nopaying_count)                 AS payment_loans_nopaying_count,
    MAX(w.payment_loans_ever_paid_count)                AS payment_loans_ever_paid_count,
    MAX(w.portfolio_last_payment_month)                 AS portfolio_last_payment_month,
    -- ⚠ SPLIT OR ALIGN ON THIS BEFORE COMPARING PORTFOLIOS. Ages run 0-8
    -- months: 154 books have eight, 13 have one.
    --
    -- A cumulative total, an L12M window or a since-inception chart compares a
    -- mature book against a newborn unless you align on this.
    MAX(w.months_since_acquisition)                     AS months_since_capex,

    -- ---- LOCAL CURRENCY, for months EUR cannot reach. --------------------
    -- ⚠ ONLY SUM WITHIN ONE CURRENCY — 'EUR + SEK' months mean nothing here.
    SUM(w.collections_local_currency)                   AS collections_local_currency,
    SUM(w.balance_local_currency)                       AS balance_local_currency,

    -- ---- banner values. Identical on every row. --------------------------
    MAX(lcm.month_end)                                  AS snapshot_date,
    MAX(fw.fx_start_date)                               AS fx_start_date,
    MAX(fw.fx_end_date)                                 AS fx_end_date,

    -- ---- FLAGS. These are what you filter on. ----------------------------
    MAX(IFF(w.servicer_forecast_euro IS NOT NULL, 1, 0)) = 1   AS have_servicer_forecast_flag,
    MAX(IFF(w.underwriting_forecast_euro IS NOT NULL, 1, 0)) = 1 AS have_underwriting_forecast_flag,
    MAX(IFF(w.accounting_forecast_euro IS NOT NULL, 1, 0)) = 1  AS have_accounting_forecast_flag,
    -- ⚠ Read this before quoting PAYMENT_LOANS_LOST_COUNT.
    MAX(w.feed_stopped_flag) = 1                               AS feed_stopped_flag,
    -- ⚠⚠ FALSE means THE LOAN FEED SAYS NOTHING HERE: every payer count is 0
    -- for want of detail, not because nobody paid.
    --
    -- 84 of 265 portfolios, EUR 79.8m — 21.5% of collections. SPLIT ON THIS or
    -- a per-loan denominator drops a fifth of the book.
    MAX(w.have_loan_detail_flag) = 1                           AS have_loan_detail_flag,
    -- ⚠ TRUE where the month carries more than one currency — 24 rows, up to
    -- five at once. The LOCAL_CURRENCY columns mean nothing on these.
    COUNT(DISTINCT w.original_currency) > 1                    AS is_multi_currency_flag,
    -- ⚠ Why a month failed: below 80 and NO month on this portfolio can
    -- reconcile, however well its money matches. Static per portfolio.
    MAX(w.cat_month_coverage_pct)                              AS cat_month_coverage_pct,
    -- MIN, not MAX: on a two-currency month EVERY currency must reconcile.
    MIN(w.month_reconciled_flag) = 1                           AS is_reconciled_flag
FROM aggregated_metrics AS w
CROSS JOIN last_complete_month AS lcm
CROSS JOIN fx_base AS fw
-- Guard 2. LEFT, always.
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS dd
    ON dd.deal_sk = w.deal_sk
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
    ON ds.deal_source_sk = w.deal_source_sk
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON lb.legal_buyer_sk = w.legal_buyer_sk
-- Guard 5. ISO_ALPHA2_CODE, never country_id.
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = w.country_code
LEFT JOIN subservicer_map AS sm
    ON sm.portfolio_bk = w.portfolio
-- ⚠ ONE GUARD, ENFORCED HERE. Do not move it to the dashboard.
WHERE w.month_end <= lcm.month_end
-- ⚠ 1..17 ARE THE NON-AGGREGATED COLUMNS ONLY. The LISTAGG at 18 is an
-- aggregate and must never appear here.
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17
