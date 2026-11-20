-- Data Quality dashboard: one row per combined ref x reporting month.
--
-- The By Combined Ref (Intrum) / By Portfolio ID (other servicers) table reads
-- this element. A combined ref is DIM_BATCH.BATCH_BK, the servicer's own
-- reference, so a servicer can look a row up in its own system.
--
-- Rows: every ref-month that is in either feed. A ref missing from BOTH feeds
-- in a month has no row; the portfolio view (portfolio_months_element.sql)
-- shows that portfolio as Not Received. Gaps inside a ref's life are rare: 2
-- portfolio-months since Jun 2014 had some refs reported and others not
-- (2026-10-13).
--
-- Same sources, scope and rules as portfolio_months_element.sql: portfolios in
-- DIM_PORTFOLIO, from Jun 2014. The first six CTEs (scope, the case book per
-- ref and the servicer of each ref) are copied
-- from it word for word; tests/run.py fails if they ever differ, and checks
-- that a portfolio's refs add up to its row there.
--
-- Measured 2026-10-13: (filled in by tests/run.py --doc)

WITH portfolios_in_scope AS (
    SELECT portfolio_sk, portfolio_bk, capex_date, capex_amount, currency_id
    FROM PROD.NPL_COMMON.DIM_PORTFOLIO
),

case_book_by_ref AS (
    -- The Case Feed's book at each month-end, per combined ref. The table holds
    -- one row per case per month (1,495,141,394 rows, all unique, 2026-10-13),
    -- so COUNT(*) is the number of cases listed. Counting distinct cases
    -- instead took 9 minutes. case_feed_rows counts every listed case, open or
    -- closed: whether the case feed came at all.
    --
    -- Data-quality guard: the snapshot keeps a closed case on the list every
    -- month after it closed, with its last balance. On 31 Aug 2026 9.0m of
    -- Intrum's 19.5m listed cases were already closed, carrying 20.2bn, while
    -- Intrum's own report counts 8.8m open cases. So the cases and balance
    -- compared with the report leave closed cases out (case_book and
    -- ref_months subtract closed_cases), and their balance is shown on its own
    -- (closed_cases_balance). The Servicing dashboard's cases on book still
    -- count them.
    --
    -- DIM_CASE has one row per version of a case (154,663,197 versions of
    -- 22,486,377 cases, 2026-10-14) and the snapshot points at the version
    -- valid at each month-end, so a case is closed at a month-end when that
    -- version's closing date is on or before it. One read of the snapshot:
    -- 474s against 823s for two (X-Small, 2026-10-14, same totals).
    SELECT
        s.batch_sk,
        s.date_day                     AS reporting_month,
        MAX(s.portfolio_sk)            AS portfolio_sk,
        MAX(s.reporting_system_sk)     AS reporting_system_sk,
        COUNT(*)                       AS case_feed_rows,
        SUM(s.outstanding_total)       AS listed_balance,
        COUNT(dc.case_sk)              AS closed_cases,
        SUM(IFF(dc.case_sk IS NULL, 0, s.outstanding_total)) AS closed_cases_balance
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    LEFT JOIN PROD.NPL_COMMON.DIM_CASE AS dc
        ON dc.case_sk = s.case_sk AND dc.closing_date <= s.date_day
    WHERE s.date_day BETWEEN '2014-06-30' AND CURRENT_DATE()
      AND s.portfolio_sk IN (SELECT portfolio_sk FROM portfolios_in_scope)
    GROUP BY 1, 2
),

ref_case_servicer AS (
    -- The servicer the case feed names for each ref ('Unknown' is no answer).
    SELECT c.batch_sk, MAX(c.portfolio_sk) AS portfolio_sk, MAX(INITCAP(rs.servicer_name)) AS servicer,
           SUM(c.case_feed_rows) AS case_months
    FROM case_book_by_ref AS c
    INNER JOIN PROD.NPL_COMMON.DIM_REPORTING_SYSTEM AS rs
        ON rs.reporting_system_sk = c.reporting_system_sk
    WHERE rs.servicer_name <> 'Unknown'
    GROUP BY 1
),

portfolio_case_servicer AS (
    -- For refs the case feed does not name: the portfolio's main servicer.
    SELECT portfolio_sk, MAX_BY(servicer, case_months) AS servicer
    FROM ref_case_servicer
    GROUP BY 1
),

portfolio_rule AS (
    -- The manager's business rule (2026-10-12), copied from the Servicing
    -- dashboard's portfolios_element.sql, for portfolios with no case feed.
    SELECT
        f.portfolio_sk,
        CASE
            WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND f.country_code = 'UK' THEN 'Massey'
            WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND f.country_code = 'IT' THEN 'Fire'
            WHEN ds.deal_source_name IN ('ORGANIC ORIGINATED', 'LEGACY', 'GESCOBRO')
                 AND f.country_code = 'ES'                                          THEN 'Gescobro'
            WHEN ds.deal_source_name = 'LEGACY' AND f.country_code = 'IT'           THEN 'Cerved'
            ELSE 'Intrum'
        END                                                 AS servicer
    FROM (SELECT portfolio_sk,
                 MAX_BY(deal_source_sk, period_end_date)    AS deal_source_sk,
                 MAX(country_id)                            AS country_code
          FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
          WHERE portfolio_sk IN (SELECT portfolio_sk FROM portfolios_in_scope)
          GROUP BY 1) AS f
    LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
        ON ds.deal_source_sk = f.deal_source_sk
),

ref_servicer AS (
    -- One servicer per ref, from either feed, and where it came from.
    SELECT
        refs.batch_sk,
        refs.portfolio_sk,
        COALESCE(rcs.servicer, pcs.servicer, pr.servicer)   AS servicer,
        IFF(rcs.servicer IS NOT NULL OR pcs.servicer IS NOT NULL,
            'Case Feed', 'Business Rule')                   AS servicer_source
    FROM (SELECT batch_sk, MAX(portfolio_sk) AS portfolio_sk
          FROM (SELECT batch_sk, portfolio_sk FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
                WHERE portfolio_sk IN (SELECT portfolio_sk FROM portfolios_in_scope)
                UNION
                SELECT batch_sk, portfolio_sk FROM case_book_by_ref)
          GROUP BY 1) AS refs
    LEFT JOIN ref_case_servicer AS rcs
        ON rcs.batch_sk = refs.batch_sk
    LEFT JOIN portfolio_case_servicer AS pcs
        ON pcs.portfolio_sk = refs.portfolio_sk
    LEFT JOIN portfolio_rule AS pr
        ON pr.portfolio_sk = refs.portfolio_sk
),

ref_portfolio_feed AS (
    -- The Portfolio Feed, per combined ref and month.
    SELECT
        batch_sk,
        period_end_date                AS reporting_month,
        MAX(portfolio_sk)              AS portfolio_sk,
        SUM(gross_cash_recoveries)     AS portfolio_feed_collections,
        SUM(total_balance)             AS portfolio_feed_balance
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    WHERE period_end_date BETWEEN '2014-06-30' AND CURRENT_DATE()
      AND portfolio_sk IN (SELECT portfolio_sk FROM portfolios_in_scope)
    GROUP BY 1, 2
),

ref_case_payments AS (
    -- Payments by the month they were paid, bounded at today (dates run to 4570).
    SELECT
        batch_sk,
        LAST_DAY(collection_date)      AS reporting_month,
        SUM(amount)                    AS case_feed_collections
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION
    WHERE collection_date BETWEEN '2014-06-01' AND CURRENT_DATE()
    GROUP BY 1, 2
),

month_status AS (
    -- Complete or Loading, the same rule as portfolio_months_element.sql.
    SELECT
        reporting_month,
        IFF(LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY reporting_month) IS NULL
            OR COUNT(DISTINCT portfolio_sk) >= 0.5 * LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY reporting_month),
            'Complete', 'Loading')                          AS month_status
    FROM ref_portfolio_feed
    GROUP BY 1
),

ref_months AS (
    -- Every ref-month in either feed.
    SELECT
        COALESCE(pf.batch_sk, cb.batch_sk)               AS batch_sk,
        COALESCE(pf.reporting_month, cb.reporting_month) AS reporting_month,
        COALESCE(pf.portfolio_sk, cb.portfolio_sk)       AS portfolio_sk,
        rs.servicer,
        pf.batch_sk IS NOT NULL                          AS portfolio_feed_received_flag,
        cb.batch_sk IS NOT NULL                          AS in_case_feed_flag,
        pf.portfolio_feed_collections,
        pf.portfolio_feed_balance,
        -- Every case listed, open or closed: the Servicing dashboard's cases on book.
        cb.case_feed_rows                                   AS case_feed_cases,
        -- Open cases only, and their balance, the figures compared with the report (case_book_by_ref says why).
        cb.case_feed_rows - cb.closed_cases                 AS case_feed_open_cases,
        cb.listed_balance - cb.closed_cases_balance         AS case_feed_balance,
        IFF(cb.batch_sk IS NULL, NULL, cb.closed_cases_balance) AS closed_cases_balance
    FROM ref_portfolio_feed AS pf
    FULL OUTER JOIN case_book_by_ref AS cb
        ON cb.batch_sk = pf.batch_sk AND cb.reporting_month = pf.reporting_month
    INNER JOIN ref_servicer AS rs
        ON rs.batch_sk = COALESCE(pf.batch_sk, cb.batch_sk)
),

portfolio_case_months AS (
    -- Months the same servicer's case feed has ANY ref of the portfolio: a ref
    -- missing from it then reads Under Another Ref (Massey), not Not Received.
    SELECT DISTINCT c.portfolio_sk, rs.servicer, c.reporting_month
    FROM case_book_by_ref AS c
    INNER JOIN ref_servicer AS rs
        ON rs.batch_sk = c.batch_sk
),

checks AS (
    SELECT
        r.*,
        CASE
            WHEN r.in_case_feed_flag                                  THEN 'Received'
            WHEN pcm.portfolio_sk IS NOT NULL                         THEN 'Under Another Ref'
            -- Stopped: this ref was in the case feed in an earlier month.
            WHEN MAX(IFF(r.in_case_feed_flag, r.reporting_month, NULL)) OVER (
                     PARTITION BY r.batch_sk ORDER BY r.reporting_month
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) IS NOT NULL
                                                                      THEN 'Stopped'
            ELSE 'Not Received'
        END                                                           AS case_feed_status,
        MIN(IFF(r.portfolio_feed_received_flag, r.reporting_month, NULL)) OVER (PARTITION BY r.batch_sk) AS portfolio_feed_first_month,
        MIN(IFF(r.in_case_feed_flag, r.reporting_month, NULL)) OVER (PARTITION BY r.batch_sk)            AS case_feed_first_month,
        MAX(IFF(r.portfolio_feed_received_flag, r.reporting_month, NULL)) OVER (PARTITION BY r.batch_sk ORDER BY r.reporting_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                                            AS portfolio_feed_last_month,
        MAX(IFF(r.in_case_feed_flag, r.reporting_month, NULL)) OVER (PARTITION BY r.batch_sk ORDER BY r.reporting_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                                            AS case_feed_last_month,
        -- Months Overlap, up to this row (as the portfolio element).
        SUM(IFF(r.portfolio_feed_received_flag, 1, 0)) OVER (
            PARTITION BY r.batch_sk ORDER BY r.reporting_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                                            AS months_reported_to_date,
        SUM(IFF(r.portfolio_feed_received_flag AND r.in_case_feed_flag, 1, 0)) OVER (
            PARTITION BY r.batch_sk ORDER BY r.reporting_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                                            AS months_overlap_to_date
    FROM ref_months AS r
    LEFT JOIN portfolio_case_months AS pcm
        ON pcm.portfolio_sk = r.portfolio_sk AND pcm.servicer = r.servicer AND pcm.reporting_month = r.reporting_month
)

SELECT
    c.reporting_month,
    COALESCE(ms.month_status, 'Loading')                    AS month_status,
    c.servicer,
    d.portfolio_bk                                          AS portfolio_name,
    -- The deal as the Servicing dashboard names it (its portfolios_element.sql).
    COALESCE(dd.deal_alias, dd.deal_bk, 'Unknown')          AS deal,
    COALESCE(co.country_name, pc.country_code)              AS country_name,
    pc.currency,
    d.capex_amount                                          AS purchase_price,
    COALESCE(b.batch_bk, 'No Combined Ref')                 AS combined_ref,
    c.portfolio_feed_received_flag,
    -- Not Yet Received: a report is due by the 15th of the month after (every
    -- Intrum report since Feb 2026 reached the warehouse between the 10th and
    -- the 14th, 2026-10-14). Before then a missing report is not yet late.
    CURRENT_DATE() >= DATEADD(DAY, 15, c.reporting_month)   AS portfolio_feed_due_flag,
    c.case_feed_status,
    -- Not the servicer's fault: brocc-data does not load Cerved's or Gescobro's
    -- case payments into PROD yet (int_npl_case_collection_conformed unions
    -- only Intrum and Massey; RAW holds both servicers' payments, 2026-10-13).
    -- Nor all of Intrum's Italian ones: CAT 4034 has no orig_tr_id, so
    -- int_npl_case_collection_intrum keeps one payment per case (raw 2,850
    -- Dec 2025 - Aug 2026, PROD 1,041). The Servicing dashboard never
    -- reconciles Italy for this (the user, 2026-10-14); same here. Their
    -- collections cannot be compared, so the dashboard says so instead of
    -- flagging them. Turn each off when brocc-data fixes it.
    c.servicer NOT IN ('Cerved', 'Gescobro')
        AND COALESCE(pc.country_code, '') <> 'IT'          AS case_payments_loaded_flag,
    c.portfolio_feed_collections,
    cp.case_feed_collections,
    c.portfolio_feed_balance,
    c.case_feed_balance,
    c.closed_cases_balance,
    c.case_feed_cases,
    c.case_feed_open_cases,
    -- The forecast is checked per portfolio: Cerved's sits on one portfolio-level ref.
    sf.portfolio_sk IS NOT NULL                             AS forecast_received_flag,
    c.portfolio_feed_first_month,
    c.case_feed_first_month,
    c.portfolio_feed_last_month,
    c.case_feed_last_month,
    c.months_reported_to_date,
    c.months_overlap_to_date
FROM checks AS c
LEFT JOIN month_status AS ms
    ON ms.reporting_month = c.reporting_month
LEFT JOIN ref_case_payments AS cp
    ON cp.batch_sk = c.batch_sk AND cp.reporting_month = c.reporting_month
LEFT JOIN (SELECT DISTINCT portfolio_sk, period_end_date
           FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY) AS sf
    ON sf.portfolio_sk = c.portfolio_sk AND sf.period_end_date = c.reporting_month
LEFT JOIN (SELECT portfolio_sk, MAX(country_id) AS country_code, MAX(currency_id) AS currency,
                  MAX(deal_sk) AS deal_sk
           FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY GROUP BY 1) AS pc
    ON pc.portfolio_sk = c.portfolio_sk
INNER JOIN portfolios_in_scope AS d
    ON d.portfolio_sk = c.portfolio_sk
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = pc.country_code
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS dd
    ON dd.deal_sk = pc.deal_sk
LEFT JOIN PROD.NPL_COMMON.DIM_BATCH AS b
    ON b.batch_sk = c.batch_sk
ORDER BY c.reporting_month, c.servicer, portfolio_name, combined_ref
