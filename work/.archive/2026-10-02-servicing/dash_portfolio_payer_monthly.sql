/*
dash_portfolio_payer_monthly - ONE table for Sigma: portfolio x month, carrying
the PAM/CAT reconciliation metrics we already had plus paying-loan dynamics.

GRAIN: one row per portfolio per month. 2,999 rows x 35 columns over 157
portfolios, 2014-06 to 2026-08. Runs in ~70 seconds (measured 2026-09-17).

WHAT IT ANSWERS that the portfolio-level query could not: how many loans are
paying each month, how many just started, how many pay reliably, and how many
stopped - beside the money, on one grain Sigma can pivot without a join.

L0 is the row's own month, L1 the month before, L2 two months before.
  N_PAYING_LOANS    loans with any collection in L0
  N_ACTIVATED       first payment EVER on that loan, in L0
  N_CONSISTENT_3M   paid in L0 and L1 and L2
  N_NEW_VS_L2M      paid L0, did not pay L2 - the mirror of lost
  N_NEW_L0M_ONLY    paid L0, did not pay L1 or L2 - the strict reading
  N_LOST_VS_L2M     paid L2, did not pay L0, counted at L0
  N_NON_PAYING_LOANS  static: loans on book at the portfolio's latest snapshot
                      day that have NEVER paid. 21.9m loans on book overall and
                      only 15.557% have ever paid.

⚠ READ FEED_STOPPED_FLAG BEFORE QUOTING N_LOST_VS_L2M. A portfolio whose file
  stops arriving shows every payer as lost. 35 rows are flagged; the worst is
  ORG-UK26003-U01/2606 reading 24,531 loans lost in 2026-07 having last
  delivered in 2026-06. That is a missing file, not customers leaving.

⚠ IS_NEWEST_DATA_MONTH marks 2026-08, which is still filling and is already
  distorted: HEI-FI25001-U01/2512 jumps from 38,180 payers to 128,165 while its
  average payment falls from EUR 72.23 to EUR 45.18, and HEI-DK25001-U01/2512
  goes from 15,195 payers and EUR 11.6m to zero. Exclude the month or expect
  both effects. Raised with the data team, unexplained as at 2026-09-17.

⚠ LOAN-LEVEL COLLECTIONS ARE NOT COMPLETE. FCT_CASE_COLLECTION covers roughly
  half of what PAM reports in EUR, because some portfolios arrive as
  portfolio-level aggregates with no loan detail. Every payer count here is
  therefore a floor, not a total. ABSOLUTE_DIFFERENCE_PCT and DIFFERENCE_ALERT
  size that gap per portfolio - a portfolio alerting there has payer counts you
  should not quote.

⚠ Counts are on CASE_ID, never CASE_SK: CASE_SK is an SCD version key and would
  count one loan once per version.
*/
WITH 
    CAT AS (
        SELECT 
            portfolio_sk, 
            DATE_TRUNC('MONTH', MIN(collection_date)) AS earliest_collection_month, 
            LAST_DAY(MAX(collection_date)) AS latest_collection_month, 
            COUNT(DISTINCT currency_id) AS n_currencies_CAT, 
            SUM(amount) AS total_collections
        FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION
        WHERE collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
        GROUP BY 1 
), 
    PAM_ALL AS (
        SELECT 
            portfolio_sk, 
            COUNT(DISTINCT period_end_date) AS months_PAM
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        GROUP BY 1
), 
    PAM_MONTH AS (
        SELECT 
            PAM.portfolio_sk, 
            PAM.period_end_date, 
            MAX(PAM.deal_source_sk) AS deal_source_sk, 
            SUM(PAM.gross_cash_recoveries) AS gross_cash_recoveries, 
            SUM(PAM.total_balance) AS total_balance, 
            COUNT(DISTINCT PAM.currency_id) AS n_currencies
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS PAM 
        INNER JOIN CAT AS cases
            ON PAM.portfolio_sk = cases.portfolio_sk
        WHERE PAM.period_end_date BETWEEN cases.earliest_collection_month AND cases.latest_collection_month
        GROUP BY 1, 2
), 
    PAM AS (
        SELECT 
            portfolio_sk, 
            MAX(deal_source_sk) AS deal_source_sk, 
            SUM(gross_cash_recoveries) AS total_collections, 
            MIN_BY(total_balance, period_end_date) AS balance_first, 
            MAX_BY(total_balance, period_end_date) AS balance_last, 
            MIN_BY(total_balance, period_end_date) - MAX_BY(total_balance, period_end_date) AS balance_reduction, 
            MAX(n_currencies) AS n_currencies_PAM, 
            COUNT(DISTINCT DATE_TRUNC('MONTH', period_end_date)) AS overlap_months
        FROM PAM_MONTH
        GROUP BY 1
), 
    -- Servicer batch refs, collapsed to ONE ROW PER PORTFOLIO before the join:
    -- 11,783 batches against 264 portfolios, so a raw join multiplies money.
    BATCH_MAP AS (
        SELECT 
            internal_portfolio_bk, 
            COUNT(DISTINCT batch_bk) AS n_servicer_batches, 
            MAX(batch_bk) AS single_batch_ref, 
            LISTAGG(DISTINCT batch_bk, ', ') WITHIN GROUP (ORDER BY batch_bk) AS all_batch_refs
        FROM RAW.NPL_INTERNAL_SHAREPOINT.NPL_SERVICER_BATCHES
        GROUP BY 1
), 
    -- One row per loan per month in which it paid anything. COUNT on CASE_ID,
    -- never CASE_SK: CASE_SK is an SCD version key and would count a loan once
    -- per version.
    PAID AS (
        SELECT 
            portfolio_sk, 
            case_id, 
            DATE_TRUNC('MONTH', collection_date) AS collection_month, 
            SUM(amount) AS amount
        FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION
        WHERE collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
        GROUP BY 1, 2, 3
), 
    -- L0 is the row's own month, L1 the month before, L2 two months before.
    -- prev1/prev2 are the loan's previous PAYING months, so "paid in L2" is
    -- true when EITHER lands on L2 - a loan can skip L1 and still have paid L2.
    PAID_SEQ AS (
        SELECT 
            portfolio_sk, 
            case_id, 
            collection_month, 
            amount, 
            LAG(collection_month, 1) OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS prev1, 
            LAG(collection_month, 2) OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS prev2, 
            LEAD(collection_month, 1) OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS next1, 
            LEAD(collection_month, 2) OVER (PARTITION BY portfolio_sk, case_id ORDER BY collection_month) AS next2
        FROM PAID
), 
    -- The last month any loan paid. A "lost" count for a month later than this
    -- would be an artefact of the data ending, not a loan that stopped paying.
    MAX_MONTH AS (
        SELECT MAX(collection_month) AS max_month FROM PAID
), 
    MONTH_FLAGS AS (
        SELECT 
            s.portfolio_sk, 
            s.collection_month, 
            s.amount, 
            IFF(s.prev1 IS NULL, 1, 0) AS is_activated, 
            IFF(s.prev1 = DATEADD('MONTH', -1, s.collection_month)
                AND s.prev2 = DATEADD('MONTH', -2, s.collection_month), 1, 0) AS is_consistent_3m, 
            IFF(COALESCE(s.prev1 = DATEADD('MONTH', -2, s.collection_month), FALSE)
                OR COALESCE(s.prev2 = DATEADD('MONTH', -2, s.collection_month), FALSE), 0, 1) AS is_new_vs_l2m, 
            IFF(COALESCE(s.prev1 = DATEADD('MONTH', -1, s.collection_month), FALSE)
                OR COALESCE(s.prev1 = DATEADD('MONTH', -2, s.collection_month), FALSE)
                OR COALESCE(s.prev2 = DATEADD('MONTH', -2, s.collection_month), FALSE), 0, 1) AS is_new_l0m_only
        FROM PAID_SEQ AS s
), 
    MONTHLY_PAYERS AS (
        SELECT 
            portfolio_sk, 
            collection_month, 
            COUNT(*) AS n_paying_loans, 
            SUM(amount) AS cat_collections, 
            SUM(is_activated) AS n_activated, 
            SUM(is_consistent_3m) AS n_consistent_3m, 
            SUM(is_new_vs_l2m) AS n_new_vs_l2m, 
            SUM(is_new_l0m_only) AS n_new_l0m_only
        FROM MONTH_FLAGS
        GROUP BY 1, 2
), 
    -- A loan that paid in L2 and not in L0 is counted as lost AT L0, so the
    -- row is anchored two months after the payment that ends the run.
    MONTHLY_LOST AS (
        SELECT 
            s.portfolio_sk, 
            DATEADD('MONTH', 2, s.collection_month) AS collection_month, 
            COUNT(*) AS n_lost_vs_l2m
        FROM PAID_SEQ AS s
        CROSS JOIN MAX_MONTH AS m
        WHERE DATEADD('MONTH', 2, s.collection_month) <= m.max_month
          AND NOT COALESCE(s.next1 = DATEADD('MONTH', 2, s.collection_month), FALSE)
          AND NOT COALESCE(s.next2 = DATEADD('MONTH', 2, s.collection_month), FALSE)
        GROUP BY 1, 2
), 
    -- Static per portfolio: the loans we hold at the portfolio's own latest
    -- snapshot day, and how many of them have never paid anything.
    BOOK AS (
        SELECT s.portfolio_sk, s.case_id
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        INNER JOIN (
            SELECT portfolio_sk, MAX(date_day) AS latest_day
            FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
            GROUP BY 1
        ) AS l
            ON l.portfolio_sk = s.portfolio_sk AND l.latest_day = s.date_day
        GROUP BY 1, 2
), 
    EVER_PAID AS (
        SELECT portfolio_sk, case_id FROM PAID GROUP BY 1, 2
), 
    -- The last month this portfolio delivered ANY payment. A month after it is
    -- a feed that stopped, not customers who stopped - see FEED_STOPPED_FLAG.
    PORTFOLIO_LAST AS (
        SELECT portfolio_sk, MAX(collection_month) AS last_payment_month
        FROM PAID
        GROUP BY 1
), 
    BOOK_STATS AS (
        SELECT 
            b.portfolio_sk, 
            COUNT(*) AS n_loans_on_book, 
            COUNT_IF(e.case_id IS NOT NULL) AS n_loans_ever_paid, 
            COUNT_IF(e.case_id IS NULL) AS n_non_paying_loans
        FROM BOOK AS b
        LEFT JOIN EVER_PAID AS e
            ON e.portfolio_sk = b.portfolio_sk AND e.case_id = b.case_id
        GROUP BY 1
), 
    -- Every portfolio-month the table needs a row for: PAM's months, the
    -- months loans paid, and the lost anchors that fall after the last payment.
    SPINE AS (
        SELECT portfolio_sk, DATE_TRUNC('MONTH', period_end_date) AS collection_month FROM PAM_MONTH
        UNION
        SELECT portfolio_sk, collection_month FROM MONTHLY_PAYERS
        UNION
        SELECT portfolio_sk, collection_month FROM MONTHLY_LOST
)
SELECT 
    -- ---- portfolio identity, repeated on every month ----------------------
    sp.portfolio_sk, 
    portfolio.portfolio_bk, 
    COALESCE(deal_source.deal_source_name, 'Unknown') AS deal_source_name, 
    IFF(batch_map.n_servicer_batches = 1, batch_map.single_batch_ref, NULL) AS pam_combined_ref, 
    IFF(batch_map.n_servicer_batches BETWEEN 2 AND 10, batch_map.all_batch_refs, NULL) 
        AS pam_combined_ref_list, 
    COALESCE(batch_map.n_servicer_batches, 0) AS n_servicer_batches, 
    CASE WHEN batch_map.n_servicer_batches = 1 THEN 0 ELSE 1 END AS batch_ref_alert, 

    -- ---- the month this row describes -------------------------------------
    sp.collection_month, 
    LAST_DAY(sp.collection_month) AS month_end_date, 

    -- ---- monthly, from PAM ------------------------------------------------
    pam_month.gross_cash_recoveries AS collections_PAM_month, 
    pam_month.total_balance AS total_balance_PAM_month, 

    -- ---- monthly, from loan-level collections -----------------------------
    COALESCE(payers.cat_collections, 0) AS collections_CAT_month, 
    COALESCE(payers.n_paying_loans, 0) AS n_paying_loans, 
    COALESCE(payers.n_activated, 0) AS n_activated, 
    COALESCE(payers.n_consistent_3m, 0) AS n_consistent_3m, 
    COALESCE(payers.n_new_vs_l2m, 0) AS n_new_vs_l2m, 
    COALESCE(payers.n_new_l0m_only, 0) AS n_new_l0m_only, 
    COALESCE(lost.n_lost_vs_l2m, 0) AS n_lost_vs_l2m, 

    -- ---- guards: read these before trusting a month ------------------------
    -- 1 where the portfolio has delivered nothing since an earlier month. Every
    -- loan then reads as lost, which is a missing file, not customer behaviour.
    -- Measured 2026-09-17: HEI-DK25001-U01/2512 went 15,195 payers and EUR
    -- 11.6m in July to zero in August.
    IFF(sp.collection_month > portfolio_last.last_payment_month, 1, 0) AS feed_stopped_flag, 
    -- 1 on the newest month in the warehouse, which is routinely still filling.
    IFF(sp.collection_month = max_month.max_month, 1, 0) AS is_newest_data_month, 
    portfolio_last.last_payment_month AS portfolio_last_payment_month, 

    -- ---- static per portfolio ---------------------------------------------
    book_stats.n_loans_on_book, 
    book_stats.n_non_paying_loans, 
    book_stats.n_loans_ever_paid, 

    -- ---- the reconciliation metrics, unchanged ----------------------------
    CASE WHEN ROUND(ABS(PAM.total_collections - CAT.total_collections) * 100.0 / NULLIF(PAM.total_collections, 0), 2) > 10 THEN 1 ELSE 0 END AS difference_alert, 
    CASE WHEN PAM.overlap_months / PAM_ALL.months_PAM < 0.8 THEN 1 ELSE 0 END AS overlap_alert, 
    ROUND(ABS(PAM.total_collections - CAT.total_collections) * 100.0 / NULLIF(PAM.total_collections, 0), 2) 
        AS absolute_difference_pct, 
    ROUND(ABS(PAM.total_collections - CAT.total_collections), 2) AS absolute_difference, 
    PAM_ALL.months_PAM, 
    PAM.overlap_months, 
    PAM.total_collections AS total_collections_PAM, 
    CAT.total_collections AS total_collections_CAT, 
    PAM.balance_reduction AS balance_reduction_PAM, 
    PAM.n_currencies_PAM, 
    CAT.n_currencies_CAT
FROM SPINE AS sp
INNER JOIN PAM
    ON PAM.portfolio_sk = sp.portfolio_sk
INNER JOIN CAT
    ON CAT.portfolio_sk = sp.portfolio_sk
INNER JOIN PAM_ALL
    ON PAM_ALL.portfolio_sk = sp.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS portfolio
    ON portfolio.portfolio_sk = sp.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS deal_source
    ON deal_source.deal_source_sk = PAM.deal_source_sk
LEFT JOIN BATCH_MAP AS batch_map
    ON batch_map.internal_portfolio_bk = portfolio.portfolio_bk
LEFT JOIN PAM_MONTH AS pam_month
    ON pam_month.portfolio_sk = sp.portfolio_sk
   AND DATE_TRUNC('MONTH', pam_month.period_end_date) = sp.collection_month
LEFT JOIN MONTHLY_PAYERS AS payers
    ON payers.portfolio_sk = sp.portfolio_sk AND payers.collection_month = sp.collection_month
LEFT JOIN MONTHLY_LOST AS lost
    ON lost.portfolio_sk = sp.portfolio_sk AND lost.collection_month = sp.collection_month
LEFT JOIN BOOK_STATS AS book_stats
    ON book_stats.portfolio_sk = sp.portfolio_sk
LEFT JOIN PORTFOLIO_LAST AS portfolio_last
    ON portfolio_last.portfolio_sk = sp.portfolio_sk
CROSS JOIN MAX_MONTH AS max_month
ORDER BY sp.portfolio_sk, sp.collection_month
