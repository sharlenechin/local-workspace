-- Data Quality dashboard: one row per portfolio x servicer x reporting month.
--
-- What it answers, per portfolio and month: did the servicer send its two feeds,
-- and do they agree? Every tile and the By Portfolio table read this element.
--
--   Portfolio Feed   the servicer's monthly portfolio report   FCT_PORTFOLIO_SNAPSHOT_MONTHLY
--   Case Feed        one row per case per month-end            FCT_CASE_SNAPSHOT_DAILY
--                    and the payments on those cases            FCT_CASE_COLLECTION
--   Forecast         the servicer's own forecast                FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY
--
-- Servicer is decided per combined ref (DIM_BATCH.BATCH_BK): the servicer the
-- case feed names for that ref. No ref has ever had two (checked 2026-10-13),
-- so a portfolio serviced by two firms splits cleanly into one row each: today
-- only HEI-GR25001-U04 (2 Intrum refs, 1 Souq ref). A ref with no case feed
-- takes its portfolio's servicer, and a portfolio with no case feed at all
-- takes the manager's business rule (2026-10-12), as the Servicing dashboard.
--
-- Rows: every month from the first month either feed has, to the newest month
-- in PROD, so a portfolio that stops reporting still has a row and reads
-- "Not Received" instead of vanishing. Amounts stay in the portfolio's own
-- currency (no portfolio reports two currencies in one month, checked
-- 2026-10-13); the checks compare ratios, so no exchange rate is needed.
--
-- Scope (the manager, 2026-10-13): portfolios in DIM_PORTFOLIO only, from
-- Jun 2014, the first month PROD holds a case feed. Earlier portfolio-feed
-- months would read as missing case feeds the servicer never owed us.
-- Case-feed rows on portfolio_sk '-1' (no portfolio: 3 Intrum refs, 7,694
-- case-months, and 1 Gescobro ref, 30, on 2026-10-13) fall outside it.
--
-- Where the Servicing dashboard shows the same figure, this is built to match
-- it: case feed collections and cases are the sums its dbt mart
-- (MART_NPL_SERVICING_AGG_CASES_MONTHLY) holds, and collections_reconciled_flag
-- is its month_reconciled_flag rule. tests/run.py checks both.
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

portfolio_feed AS (
    -- The Portfolio Feed, summed to the portfolio and servicer. refs_reported
    -- counts the combined refs the report carried this month.
    SELECT
        f.portfolio_sk,
        r.servicer,
        f.period_end_date              AS reporting_month,
        MAX(f.country_id)              AS country_code,
        MAX(f.currency_id)             AS currency,
        COUNT(DISTINCT f.batch_sk)     AS refs_reported,
        SUM(f.gross_cash_recoveries)   AS portfolio_feed_collections,
        SUM(f.total_balance)           AS portfolio_feed_balance
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    INNER JOIN ref_servicer AS r
        ON r.batch_sk = f.batch_sk
    WHERE f.period_end_date BETWEEN '2014-06-30' AND CURRENT_DATE()
    GROUP BY 1, 2, 3
),

case_book AS (
    -- The Case Feed's book, per portfolio and servicer. refs_matched counts the
    -- refs that are in BOTH feeds this month: Massey's case feed uses refs its
    -- report does not.
    SELECT
        c.portfolio_sk,
        r.servicer,
        c.reporting_month,
        SUM(c.case_feed_rows)          AS case_feed_rows,
        -- Every case listed, open or closed: the Servicing dashboard's cases on book.
        SUM(c.case_feed_rows)                             AS case_feed_cases,
        -- Open cases only, and their balance, the figures compared with the report (case_book_by_ref says why).
        SUM(c.case_feed_rows - c.closed_cases)            AS case_feed_open_cases,
        SUM(c.listed_balance - c.closed_cases_balance)    AS case_feed_balance,
        SUM(c.closed_cases_balance)                       AS closed_cases_balance,
        COUNT(DISTINCT pf.batch_sk)    AS refs_matched
    FROM case_book_by_ref AS c
    INNER JOIN ref_servicer AS r
        ON r.batch_sk = c.batch_sk
    LEFT JOIN (SELECT DISTINCT batch_sk, period_end_date
               FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY) AS pf
        ON pf.batch_sk = c.batch_sk AND pf.period_end_date = c.reporting_month
    GROUP BY 1, 2, 3
),

case_payments AS (
    -- The Case Feed's payments, by the month they were paid. Bounded at today:
    -- the table holds payments dated up to the year 4570 (2026-10-13).
    -- Payments in a month with no feed row are not shown: the current month,
    -- and payments dated before a portfolio's first feed month (Massey's
    -- ORG-UK26002 pays from 2021; its case list starts Jan 2026).
    -- Cerved and Gescobro have none in PROD: brocc-data does not load their
    -- payments yet (int_npl_case_collection_conformed unions Intrum and Massey).
    SELECT
        p.portfolio_sk,
        r.servicer,
        LAST_DAY(p.collection_date)    AS reporting_month,
        SUM(p.amount)                  AS case_feed_collections,
        COUNT_IF(p.amount > 0)         AS case_feed_payments
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS p
    INNER JOIN ref_servicer AS r
        ON r.batch_sk = p.batch_sk
    WHERE p.collection_date BETWEEN '2014-06-01' AND CURRENT_DATE()
    GROUP BY 1, 2, 3
),

servicer_forecast AS (
    -- Checked per portfolio: Cerved's forecast sits on one portfolio-level ref.
    SELECT DISTINCT portfolio_sk, period_end_date AS reporting_month
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY
    WHERE period_end_date >= '2014-06-30'
),

months AS (
    -- Every month either feed has, up to today.
    SELECT reporting_month FROM portfolio_feed
    UNION
    SELECT reporting_month FROM case_book
),

month_status AS (
    -- A month is Complete once at least half as many portfolios report as the
    -- month before: the Servicing dashboard's rule. Sep 2026 had 12 of 264 on
    -- 2026-10-13, so it read Loading. The dashboard opens on the latest
    -- Complete month.
    SELECT
        reporting_month,
        IFF(LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY reporting_month) IS NULL
            OR COUNT(DISTINCT portfolio_sk) >= 0.5 * LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY reporting_month),
            'Complete', 'Loading')                          AS month_status
    FROM portfolio_feed
    GROUP BY 1
),

grid AS (
    -- One row per portfolio and servicer for every month from its first feed
    -- month on.
    SELECT s.portfolio_sk, s.servicer, m.reporting_month
    FROM (SELECT portfolio_sk, servicer, MIN(reporting_month) AS first_month
          FROM (SELECT portfolio_sk, servicer, reporting_month FROM portfolio_feed
                UNION ALL
                SELECT portfolio_sk, servicer, reporting_month FROM case_book)
          GROUP BY 1, 2) AS s
    INNER JOIN months AS m
        ON m.reporting_month >= s.first_month
),

checks AS (
    SELECT
        g.reporting_month,
        g.portfolio_sk,
        g.servicer,
        LAST_DAY(d.capex_date)                              AS acquisition_month,
        pf.portfolio_sk IS NOT NULL                         AS portfolio_feed_received_flag,
        pf.refs_reported,
        cb.refs_matched,
        CASE
            WHEN cb.case_feed_rows > 0 AND (pf.portfolio_sk IS NULL OR cb.refs_matched = pf.refs_reported)
                                                  THEN 'Received'
            WHEN cb.refs_matched > 0              THEN 'Partly Received'
            WHEN cb.case_feed_rows > 0            THEN 'Under Another Ref'
            -- Stopped: sent in an earlier month, not this one.
            WHEN MAX(cb.reporting_month) OVER (PARTITION BY g.portfolio_sk, g.servicer ORDER BY g.reporting_month
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) IS NOT NULL
                                                  THEN 'Stopped'
            ELSE 'Not Received'
        END                                                 AS case_feed_status,
        pf.portfolio_feed_collections,
        cp.case_feed_collections,
        cp.case_feed_payments,
        pf.portfolio_feed_balance,
        cb.case_feed_balance,
        cb.closed_cases_balance,
        cb.case_feed_cases,
        cb.case_feed_open_cases,
        cb.portfolio_sk IS NOT NULL                         AS in_case_feed_flag,
        sf.portfolio_sk IS NOT NULL                         AS forecast_received_flag
    FROM grid AS g
    LEFT JOIN portfolio_feed AS pf
        ON pf.portfolio_sk = g.portfolio_sk AND pf.servicer = g.servicer AND pf.reporting_month = g.reporting_month
    LEFT JOIN case_book AS cb
        ON cb.portfolio_sk = g.portfolio_sk AND cb.servicer = g.servicer AND cb.reporting_month = g.reporting_month
    LEFT JOIN case_payments AS cp
        ON cp.portfolio_sk = g.portfolio_sk AND cp.servicer = g.servicer AND cp.reporting_month = g.reporting_month
    LEFT JOIN servicer_forecast AS sf
        ON sf.portfolio_sk = g.portfolio_sk AND sf.reporting_month = g.reporting_month
    LEFT JOIN portfolios_in_scope AS d
        ON d.portfolio_sk = g.portfolio_sk
),

history AS (
    SELECT
        c.*,
        -- Each feed's dates: first month ever, and last month up to this row.
        MIN(IFF(c.portfolio_feed_received_flag, c.reporting_month, NULL)) OVER (PARTITION BY c.portfolio_sk, c.servicer)
                                                            AS portfolio_feed_first_month,
        MIN(IFF(c.in_case_feed_flag, c.reporting_month, NULL)) OVER (PARTITION BY c.portfolio_sk, c.servicer)
                                                            AS case_feed_first_month,
        MAX(IFF(c.portfolio_feed_received_flag, c.reporting_month, NULL)) OVER (
            PARTITION BY c.portfolio_sk, c.servicer ORDER BY c.reporting_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS portfolio_feed_last_month,
        MAX(IFF(c.in_case_feed_flag, c.reporting_month, NULL)) OVER (
            PARTITION BY c.portfolio_sk, c.servicer ORDER BY c.reporting_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS case_feed_last_month,
        -- Months Overlap, up to this row: months the portfolio feed came, and
        -- how many of them also had a case feed.
        SUM(IFF(c.portfolio_feed_received_flag, 1, 0)) OVER (
            PARTITION BY c.portfolio_sk, c.servicer ORDER BY c.reporting_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS months_reported_to_date,
        SUM(IFF(c.portfolio_feed_received_flag AND c.in_case_feed_flag, 1, 0)) OVER (
            PARTITION BY c.portfolio_sk, c.servicer ORDER BY c.reporting_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS months_overlap_to_date,
        -- The Servicing dashboard's coverage test, per portfolio: months with a
        -- case payment, out of months reported, both since acquisition.
        COUNT_IF(c.case_feed_payments > 0 AND c.reporting_month >= c.acquisition_month)
            OVER (PARTITION BY c.portfolio_sk, c.servicer)  AS case_payment_months_since_acquisition,
        COUNT_IF(c.portfolio_feed_received_flag AND c.reporting_month >= c.acquisition_month)
            OVER (PARTITION BY c.portfolio_sk, c.servicer)  AS reported_months_since_acquisition
    FROM checks AS c
)

SELECT
    h.reporting_month,
    COALESCE(ms.month_status, 'Loading')                    AS month_status,
    h.portfolio_sk,
    h.servicer,
    MAX(rs.servicer_source) OVER (PARTITION BY h.portfolio_sk, h.servicer) AS servicer_source,
    d.portfolio_bk                                          AS portfolio_name,
    -- The deal as the Servicing dashboard names it (its portfolios_element.sql).
    COALESCE(dd.deal_alias, dd.deal_bk, 'Unknown')          AS deal,
    COALESCE(co.country_name, pc.country_code)              AS country_name,
    pc.currency,
    d.capex_amount                                          AS purchase_price,
    d.currency_id                                           AS purchase_currency,
    h.acquisition_month,
    h.portfolio_feed_received_flag,
    -- Not Yet Received: a report is due by the 15th of the month after (every
    -- Intrum report since Feb 2026 reached the warehouse between the 10th and
    -- the 14th, 2026-10-14). Before then a missing report is not yet late.
    CURRENT_DATE() >= DATEADD(DAY, 15, h.reporting_month)   AS portfolio_feed_due_flag,
    h.refs_reported,
    h.refs_matched,
    h.case_feed_status,
    -- Not the servicer's fault: brocc-data does not load Cerved's or Gescobro's
    -- case payments into PROD yet (int_npl_case_collection_conformed unions
    -- only Intrum and Massey; RAW holds both servicers' payments, 2026-10-13).
    -- Nor all of Intrum's Italian ones: CAT 4034 has no orig_tr_id, so
    -- int_npl_case_collection_intrum keeps one payment per case (raw 2,850
    -- Dec 2025 - Aug 2026, PROD 1,041). The Servicing dashboard never
    -- reconciles Italy for this (the user, 2026-10-14); same here. Their
    -- collections cannot be compared, so the dashboard says so instead of
    -- flagging them. Turn each off when brocc-data fixes it.
    h.servicer NOT IN ('Cerved', 'Gescobro')
        AND COALESCE(pc.country_code, '') <> 'IT'          AS case_payments_loaded_flag,
    h.portfolio_feed_collections,
    h.case_feed_collections,
    h.portfolio_feed_balance,
    h.case_feed_balance,
    h.closed_cases_balance,
    h.case_feed_cases,
    h.case_feed_open_cases,
    h.forecast_received_flag,
    h.portfolio_feed_first_month,
    h.case_feed_first_month,
    h.portfolio_feed_last_month,
    h.case_feed_last_month,
    h.months_reported_to_date,
    h.months_overlap_to_date,
    h.case_payment_months_since_acquisition,
    h.reported_months_since_acquisition,
    -- Reconciled, the Servicing dashboard's rule: the case feed's collections
    -- are within 10% of the portfolio feed's, and the case feed has payments in
    -- at least 80% of the months reported since acquisition.
    COALESCE(h.case_feed_collections IS NOT NULL
        AND ABS(h.portfolio_feed_collections - h.case_feed_collections)
            <= 0.10 * ABS(NULLIF(h.portfolio_feed_collections, 0))
        AND h.case_payment_months_since_acquisition >= 0.80 * h.reported_months_since_acquisition
        -- Italy: never, as the Servicing dashboard (see case_payments_loaded_flag).
        AND COALESCE(pc.country_code, '') <> 'IT',
        FALSE)                                              AS collections_reconciled_flag
FROM history AS h
LEFT JOIN month_status AS ms
    ON ms.reporting_month = h.reporting_month
LEFT JOIN (SELECT portfolio_sk, servicer, MAX(servicer_source) AS servicer_source
           FROM ref_servicer GROUP BY 1, 2) AS rs
    ON rs.portfolio_sk = h.portfolio_sk AND rs.servicer = h.servicer
LEFT JOIN (SELECT portfolio_sk, MAX(country_id) AS country_code, MAX(currency_id) AS currency,
                  MAX(deal_sk) AS deal_sk
           FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY GROUP BY 1) AS pc
    ON pc.portfolio_sk = h.portfolio_sk
INNER JOIN portfolios_in_scope AS d
    ON d.portfolio_sk = h.portfolio_sk
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = pc.country_code
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS dd
    ON dd.deal_sk = pc.deal_sk
ORDER BY h.reporting_month, h.servicer, portfolio_name
