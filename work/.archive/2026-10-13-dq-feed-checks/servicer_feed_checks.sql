-- Servicer feed checks: one row per combined ref (batch) x reporting month.
--
-- Feeds the shared Servicer Data Quality dashboard. For each combined ref it
-- asks what a servicer can act on:
--   1. did the monthly report arrive          (FCT_PORTFOLIO_SNAPSHOT_MONTHLY)
--   2. is the loan feed connected             (FCT_CASE_SNAPSHOT_DAILY, month-end grain)
--   3. do the loan feed and the report agree  on collections and on balance
--   4. did the servicer forecast arrive       (FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY)
--
-- Combined ref = DIM_BATCH.BATCH_BK, the servicer's own batch reference, so a
-- servicer can look a row up in their own system without our keys.
-- Measured 2026-10-13: 11,624 combined refs reported for Aug 2026 across 264
-- portfolios. Massey's two report rows carry no combined ref at all.
--
-- The portfolio_* columns repeat the loan feed's totals for the WHOLE portfolio
-- on every row of it, under any ref. Group by portfolio with MAX(), never SUM(),
-- to tally a portfolio whose loan feed uses different refs (Massey).
--
-- Everything stays in the batch's own currency. Collections and balance are
-- compared as ratios, so no FX conversion is needed.
--
-- Two places the loan feed does not use the report's combined ref, measured
-- 2026-10-13. Massey's two UK books carry one loan-feed ref per portfolio that
-- is not a report ref, and the servicer forecast for Cerved sits on one
-- portfolio-level ref. So loan_feed_status says "Other ref" when the portfolio
-- has a loan feed under a different ref, and the forecast is checked per portfolio.
--
-- Balance does not tally on most refs, and part of that may be definition, not
-- servicer error: on Aug 2026 the loan feed's OUTSTANDING_TOTAL sums to 144% of
-- the report's TOTAL_BALANCE and OUTSTANDING_PRINCIPAL to 79%. Confirm which
-- balance the report means before showing a servicer they are "off".
--
-- Case count comes from the loan feed only. PROD has no case count from the
-- servicer's report (no count column on any portfolio fact, checked
-- 2026-10-13), so tallying it needs a brocc-data change.
--
-- Servicer comes from the case feed: the servicer its reporting system names
-- (DIM_REPORTING_SYSTEM), per combined ref. Only where a portfolio has no case
-- feed does it fall back to the manager's rule of 2026-10-12, copied from
-- work/servicing/sigma_queries/portfolios_element.sql: the portfolio feed's own
-- REPORTING_SYSTEM_SK is 100% NULL. servicer_source says which applied.

SET months = 12;

WITH report AS (
    -- The servicer's monthly report, one row per combined ref and month.
    SELECT
        batch_sk,
        period_end_date,
        MAX(portfolio_sk)          AS portfolio_sk,
        MAX(deal_source_sk)        AS deal_source_sk,
        MAX(country_id)            AS country_code,
        MAX(currency_id)           AS currency,
        SUM(gross_cash_recoveries) AS report_collections,
        SUM(total_balance)         AS report_balance
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    WHERE period_end_date >= LAST_DAY(DATEADD(MONTH, -$months, CURRENT_DATE()))
      AND period_end_date <= CURRENT_DATE()
    GROUP BY 1, 2
),

month_size AS (
    -- A month is complete once at least half as many portfolios report as the
    -- month before: the Servicing dashboard's rule. Sep 2026 had 12 of 264
    -- portfolios on 2026-10-13, so it reads as still loading.
    SELECT
        period_end_date,
        COUNT(DISTINCT portfolio_sk)                                       AS portfolios,
        LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY period_end_date) AS prev_portfolios
    FROM report
    GROUP BY 1
),

expected AS (
    -- The months a combined ref should report: from its first report to its
    -- last. A gap inside that span is a missing report. A ref that simply ends
    -- (a closed or fully collected batch) is NOT missing afterwards: over full
    -- history that once flagged decades-old batches as missing every month.
    -- But when the ref's last month is also its portfolio's last month, the
    -- whole portfolio went quiet, so the span runs on to the newest month and
    -- the stop shows as missing.
    SELECT f.batch_sk, f.portfolio_sk, f.deal_source_sk, f.country_code, f.currency, m.period_end_date
    FROM (
        SELECT batch_sk,
               MIN(period_end_date)  AS first_month,
               MAX(period_end_date)  AS last_month,
               MAX(MAX(period_end_date)) OVER (PARTITION BY MAX(portfolio_sk)) AS portfolio_last_month,
               MAX(portfolio_sk)     AS portfolio_sk,
               MAX(deal_source_sk)   AS deal_source_sk,
               MAX(country_code)     AS country_code,
               MAX(currency)         AS currency
        FROM report
        GROUP BY 1
    ) AS f
    INNER JOIN month_size AS m
        ON m.period_end_date >= f.first_month
       AND m.period_end_date <= IFF(f.last_month = f.portfolio_last_month,
                                    (SELECT MAX(period_end_date) FROM month_size),
                                    f.last_month)
),

loan_book AS (
    -- Loans on book at each month-end, from the loan feed, per combined ref.
    -- case_servicer is the servicer the case feed itself names, through its
    -- reporting system: the only servicer field PROD carries.
    SELECT
        s.batch_sk,
        MAX(s.portfolio_sk)          AS portfolio_sk,
        s.date_day                   AS period_end_date,
        COUNT(DISTINCT s.case_sk)    AS loan_cases,
        SUM(s.outstanding_total)     AS loan_balance,
        MAX(INITCAP(rs.servicer_name)) AS case_servicer
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    LEFT JOIN PROD.NPL_COMMON.DIM_REPORTING_SYSTEM AS rs
        ON rs.reporting_system_sk = s.reporting_system_sk
    WHERE s.date_day >= LAST_DAY(DATEADD(MONTH, -$months, CURRENT_DATE()))
    GROUP BY 1, 3
),

case_servicer AS (
    -- The servicer named by the case feed, per combined ref (newest month) and
    -- per portfolio (the ref with the largest balance). Measured 2026-10-13:
    -- this moves two Greek portfolios the rule called Intrum, HEI-GR25001-S01
    -- (all Souq) and HEI-GR25001-U04 (Intrum and Souq refs), to Souq.
    SELECT r.batch_sk, r.portfolio_sk, r.ref_case_servicer, p.portfolio_case_servicer
    FROM (
        SELECT batch_sk,
               MAX(portfolio_sk)                       AS portfolio_sk,
               MAX_BY(case_servicer, period_end_date)  AS ref_case_servicer,
               SUM(loan_balance)                       AS balance
        FROM loan_book
        WHERE case_servicer <> 'Unknown'
        GROUP BY 1
    ) AS r
    LEFT JOIN (
        SELECT portfolio_sk, MAX_BY(ref_case_servicer, balance) AS portfolio_case_servicer
        FROM (
            SELECT MAX(portfolio_sk) AS portfolio_sk,
                   MAX_BY(case_servicer, period_end_date) AS ref_case_servicer,
                   SUM(loan_balance) AS balance
            FROM loan_book
            WHERE case_servicer <> 'Unknown'
            GROUP BY batch_sk
        )
        GROUP BY 1
    ) AS p
        ON p.portfolio_sk = r.portfolio_sk
),

loan_collections AS (
    -- Payments from the loan feed, by month. Bounded at today: FCT_CASE_COLLECTION
    -- holds 841 payments dated in the future, up to the year 4570 (2026-10-13).
    SELECT
        batch_sk,
        MAX(portfolio_sk)          AS portfolio_sk,
        LAST_DAY(collection_date)  AS period_end_date,
        SUM(amount)                AS loan_collections,
        COUNT(DISTINCT case_sk)    AS loan_paying_cases
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION
    WHERE collection_date >= DATEADD(MONTH, -$months, DATE_TRUNC('MONTH', CURRENT_DATE()))
      AND collection_date <= CURRENT_DATE()
    GROUP BY 1, 3
),

portfolio_loan_feed AS (
    -- The loan feed summed over the whole portfolio, under any combined ref.
    SELECT
        b.portfolio_sk,
        b.period_end_date,
        SUM(b.loan_cases)          AS portfolio_loan_cases,
        SUM(b.loan_balance)        AS portfolio_loan_balance,
        MAX(c.loan_collections)    AS portfolio_loan_collections
    FROM loan_book AS b
    LEFT JOIN (
        SELECT portfolio_sk, period_end_date, SUM(loan_collections) AS loan_collections
        FROM loan_collections
        GROUP BY 1, 2
    ) AS c
        ON c.portfolio_sk = b.portfolio_sk AND c.period_end_date = b.period_end_date
    GROUP BY 1, 2
),

portfolio_report AS (
    SELECT portfolio_sk, period_end_date,
           SUM(report_collections) AS portfolio_report_collections,
           SUM(report_balance)     AS portfolio_report_balance
    FROM report
    GROUP BY 1, 2
),

portfolio_history AS (
    -- The same reconciliation-over-time measures for the whole portfolio, so a
    -- loan feed under other refs (Massey) still counts as overlapping.
    SELECT
        portfolio_sk,
        period_end_date,
        MAX(IFF(has_report, period_end_date, NULL)) OVER (PARTITION BY portfolio_sk ORDER BY period_end_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)   AS portfolio_last_report_month,
        MAX(IFF(has_loan, period_end_date, NULL)) OVER (PARTITION BY portfolio_sk ORDER BY period_end_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)   AS portfolio_last_loan_month,
        SUM(IFF(has_report AND period_end_date >= '2014-06-30', 1, 0)) OVER (PARTITION BY portfolio_sk ORDER BY period_end_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)   AS portfolio_months_reported_run,
        SUM(IFF(has_report AND has_loan AND period_end_date >= '2014-06-30', 1, 0)) OVER (PARTITION BY portfolio_sk ORDER BY period_end_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)   AS portfolio_months_overlap_run
    FROM (
        SELECT DISTINCT
            e.portfolio_sk,
            e.period_end_date,
            pr.portfolio_sk IS NOT NULL AS has_report,
            pl.portfolio_sk IS NOT NULL AS has_loan
        FROM expected AS e
        LEFT JOIN portfolio_report AS pr
            ON pr.portfolio_sk = e.portfolio_sk AND pr.period_end_date = e.period_end_date
        LEFT JOIN portfolio_loan_feed AS pl
            ON pl.portfolio_sk = e.portfolio_sk AND pl.period_end_date = e.period_end_date
    ) AS portfolio_months
),

first_months AS (
    -- When each feed first sent this combined ref, over ALL history, so the
    -- dashboard can show a feed's date range and not just the 12-month window.
    -- Two cheap scans: both group to one row per ref.
    SELECT
        COALESCE(pf.batch_sk, cf.batch_sk)          AS batch_sk,
        COALESCE(pf.portfolio_sk, cf.portfolio_sk)  AS portfolio_sk,
        pf.first_month                              AS ref_portfolio_feed_first_month,
        cf.first_month                              AS ref_case_feed_first_month
    FROM (
        SELECT batch_sk, MAX(portfolio_sk) AS portfolio_sk, MIN(period_end_date) AS first_month
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        GROUP BY 1
    ) AS pf
    FULL OUTER JOIN (
        SELECT batch_sk, MAX(portfolio_sk) AS portfolio_sk, MIN(date_day) AS first_month
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
        GROUP BY 1
    ) AS cf
        ON cf.batch_sk = pf.batch_sk
),

overlap_before AS (
    -- Months Overlap covers ALL observed history, not a 12-month window (user,
    -- 2026-10-13). The run itself only holds $months months, so the months
    -- before it are counted here and added on. Counting starts Jun 2014: PROD
    -- holds no case feed before then, and earlier months would read as gaps
    -- the servicer never caused.
    SELECT 'batch' AS grain, r.batch_sk AS sk,
           COUNT(*)                         AS months_reported,
           COUNT_IF(c.batch_sk IS NOT NULL) AS months_overlap
    FROM (
        SELECT DISTINCT batch_sk, period_end_date
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        WHERE period_end_date >= '2014-06-30'
          AND period_end_date <  LAST_DAY(DATEADD(MONTH, -$months, CURRENT_DATE()))
    ) AS r
    LEFT JOIN (
        SELECT DISTINCT batch_sk, date_day AS period_end_date
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
        WHERE date_day < LAST_DAY(DATEADD(MONTH, -$months, CURRENT_DATE()))
    ) AS c
        ON c.batch_sk = r.batch_sk AND c.period_end_date = r.period_end_date
    GROUP BY 2

    UNION ALL
    -- Per portfolio, under any ref, so Massey's other-ref case feed still overlaps.
    SELECT 'portfolio', r.portfolio_sk,
           COUNT(*), COUNT_IF(c.portfolio_sk IS NOT NULL)
    FROM (
        SELECT DISTINCT portfolio_sk, period_end_date
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        WHERE period_end_date >= '2014-06-30'
          AND period_end_date <  LAST_DAY(DATEADD(MONTH, -$months, CURRENT_DATE()))
    ) AS r
    LEFT JOIN (
        SELECT DISTINCT portfolio_sk, date_day AS period_end_date
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
        WHERE date_day < LAST_DAY(DATEADD(MONTH, -$months, CURRENT_DATE()))
    ) AS c
        ON c.portfolio_sk = r.portfolio_sk AND c.period_end_date = r.period_end_date
    GROUP BY 2
),

servicer_forecast AS (
    SELECT DISTINCT portfolio_sk, period_end_date
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY
    WHERE period_end_date >= LAST_DAY(DATEADD(MONTH, -$months, CURRENT_DATE()))
)

SELECT
    e.period_end_date                                   AS reporting_month,
    IFF(ms.prev_portfolios IS NULL OR ms.portfolios >= 0.5 * ms.prev_portfolios,
        'Complete', 'Loading')                          AS month_status,
    -- Servicer: what the case feed names for this ref, else for its portfolio,
    -- else the manager's rule (2026-10-12), which is all a portfolio with no
    -- case feed has (Fire, and Intrum books without loan data).
    COALESCE(
        cs.ref_case_servicer,
        pcs.portfolio_case_servicer,
        CASE
            WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND e.country_code = 'UK' THEN 'Massey'
            WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND e.country_code = 'IT' THEN 'Fire'
            WHEN ds.deal_source_name IN ('ORGANIC ORIGINATED', 'LEGACY', 'GESCOBRO')
                 AND e.country_code = 'ES'                                      THEN 'Gescobro'
            WHEN ds.deal_source_name = 'LEGACY' AND e.country_code = 'IT'       THEN 'Cerved'
            ELSE 'Intrum'
        END)                                            AS servicer,
    IFF(cs.ref_case_servicer IS NOT NULL
        OR pcs.portfolio_case_servicer IS NOT NULL,
        'Case feed', 'Business rule')                   AS servicer_source,
    p.portfolio_bk                                      AS portfolio_name,
    b.batch_bk                                          AS combined_ref,
    e.country_code,
    e.currency,

    IFF(r.batch_sk IS NOT NULL, 'Received', 'Missing')  AS report_status,
    CASE
        WHEN lb.batch_sk IS NOT NULL                    THEN 'Connected'
        WHEN pl.portfolio_sk IS NOT NULL                THEN 'Other ref'
        -- Stopped = sent before this month, not now. The frame stops at this
        -- row: a feed that starts LATER must not mark earlier months stopped.
        WHEN MAX(lb.period_end_date) OVER (PARTITION BY e.batch_sk ORDER BY e.period_end_date
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) IS NOT NULL
                                                        THEN 'Stopped'
        ELSE 'Not connected'
    END                                                 AS loan_feed_status,

    -- Reconciliation over time, as of this month: every month since Jun 2014
    -- (overlap_before adds the months older than this run).
    MAX(r.period_end_date) OVER (PARTITION BY e.batch_sk ORDER BY e.period_end_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)       AS ref_last_report_month,
    MAX(lb.period_end_date) OVER (PARTITION BY e.batch_sk ORDER BY e.period_end_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)       AS ref_last_loan_month,
    COALESCE(obb.months_reported, 0)
        + SUM(IFF(r.batch_sk IS NOT NULL AND e.period_end_date >= '2014-06-30', 1, 0)) OVER (
              PARTITION BY e.batch_sk ORDER BY e.period_end_date
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ref_months_reported,
    COALESCE(obb.months_overlap, 0)
        + SUM(IFF(r.batch_sk IS NOT NULL AND lb.batch_sk IS NOT NULL AND e.period_end_date >= '2014-06-30', 1, 0)) OVER (
              PARTITION BY e.batch_sk ORDER BY e.period_end_date
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ref_months_overlap,
    fm.ref_portfolio_feed_first_month,
    fm.ref_case_feed_first_month,
    MIN(fm.ref_portfolio_feed_first_month) OVER (PARTITION BY e.portfolio_sk) AS portfolio_feed_first_month,
    pcf.case_feed_first_month                           AS portfolio_case_feed_first_month,
    ph.portfolio_last_report_month,
    ph.portfolio_last_loan_month,
    COALESCE(obp.months_reported, 0) + ph.portfolio_months_reported_run AS portfolio_months_reported,
    COALESCE(obp.months_overlap, 0) + ph.portfolio_months_overlap_run   AS portfolio_months_overlap,

    r.report_collections,
    lc.loan_collections,
    lc.loan_collections / NULLIF(r.report_collections, 0) AS collections_ratio,

    r.report_balance,
    lb.loan_balance,
    lb.loan_balance / NULLIF(r.report_balance, 0)       AS balance_ratio,

    lb.loan_cases,
    lc.loan_paying_cases,

    pr.portfolio_report_collections,
    pl.portfolio_loan_collections,
    pr.portfolio_report_balance,
    pl.portfolio_loan_balance,
    pl.portfolio_loan_cases,
    sf.portfolio_sk IS NOT NULL                         AS servicer_forecast_received

FROM expected AS e
LEFT JOIN report AS r
    ON r.batch_sk = e.batch_sk AND r.period_end_date = e.period_end_date
LEFT JOIN month_size AS ms
    ON ms.period_end_date = e.period_end_date
LEFT JOIN loan_book AS lb
    ON lb.batch_sk = e.batch_sk AND lb.period_end_date = e.period_end_date
LEFT JOIN loan_collections AS lc
    ON lc.batch_sk = e.batch_sk AND lc.period_end_date = e.period_end_date
LEFT JOIN portfolio_loan_feed AS pl
    ON pl.portfolio_sk = e.portfolio_sk AND pl.period_end_date = e.period_end_date
LEFT JOIN portfolio_report AS pr
    ON pr.portfolio_sk = e.portfolio_sk AND pr.period_end_date = e.period_end_date
LEFT JOIN servicer_forecast AS sf
    ON sf.portfolio_sk = e.portfolio_sk AND sf.period_end_date = e.period_end_date
LEFT JOIN case_servicer AS cs
    ON cs.batch_sk = e.batch_sk
LEFT JOIN (SELECT DISTINCT portfolio_sk, portfolio_case_servicer FROM case_servicer) AS pcs
    ON pcs.portfolio_sk = e.portfolio_sk
LEFT JOIN first_months AS fm
    ON fm.batch_sk = e.batch_sk
LEFT JOIN (
    -- Portfolio-level first case month, under ANY ref (Massey's case refs are not report refs).
    SELECT portfolio_sk, MIN(ref_case_feed_first_month) AS case_feed_first_month
    FROM first_months
    GROUP BY 1
) AS pcf
    ON pcf.portfolio_sk = e.portfolio_sk
LEFT JOIN portfolio_history AS ph
    ON ph.portfolio_sk = e.portfolio_sk AND ph.period_end_date = e.period_end_date
LEFT JOIN overlap_before AS obb
    ON obb.grain = 'batch' AND obb.sk = e.batch_sk
LEFT JOIN overlap_before AS obp
    ON obp.grain = 'portfolio' AND obp.sk = e.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_BATCH AS b
    ON b.batch_sk = e.batch_sk
LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p
    ON p.portfolio_sk = e.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
    ON ds.deal_source_sk = e.deal_source_sk
ORDER BY reporting_month, servicer, portfolio_name, combined_ref;
