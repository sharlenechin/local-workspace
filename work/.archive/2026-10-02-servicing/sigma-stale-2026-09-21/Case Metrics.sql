WITH portfolio_base AS (
    -- ⚠⚠ DISTINCT, NOT A BARE SELECT. This feeds the INNER JOIN onto the 134m-row
    -- collection fact, so a repeated portfolio_sk would fan every collection row
    -- out and double CASE_COLLECTIONS_SUM.
    -- The drill element carries the sentinel row for fact rows with no dimension
    -- row -- 6.38% of collections. Do not swap it for DIM_PORTFOLIO.
    SELECT DISTINCT
        "Portfolio Sk" AS portfolio_sk,
        "Capex Date"   AS capex_date
    FROM sigma_element('Portfolio Information')
),

fx_rates AS (
    SELECT
        "Currency Id"     AS currency_id,
        "Reporting Month" AS reporting_month,
        "Rate Flow"       AS rate_flow
    FROM sigma_element('FX Table')
),

case_collection_base AS (
    -- The ONLY read of the 134m-row collection fact.
    SELECT
        c.portfolio_sk,
        c.case_id,
        c.currency_id,
        DATE_TRUNC('MONTH', c.collection_date) AS collection_month,
        SUM(c.amount)                          AS amount
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
    INNER JOIN portfolio_base AS p
        ON p.portfolio_sk = c.portfolio_sk
    -- Part-months would read as a collapse in payers.
    WHERE c.collection_date < DATE_TRUNC('MONTH', CURRENT_DATE())
      AND (p.capex_date IS NULL
           OR c.collection_date >= DATE_TRUNC('MONTH', p.capex_date))
    GROUP BY 1, 2, 3, 4
),

case_base AS (
    SELECT
        portfolio_sk,
        case_id,
        collection_month
    FROM case_collection_base
    GROUP BY 1, 2, 3
),

case_month_cash AS (
    -- ⚠⚠ CONVERTED PER CURRENCY, THEN SUMMED. case_collection_base still carries
    -- currency, so each row takes its own rate. Summing first would apply one
    -- rate to a mixed total. RATE_FLOW because a collection is a flow.
    -- ⚠⚠ LAST_DAY IS NOT OPTIONAL HERE. collection_month is a month START; the
    -- FX element is keyed on month END. Joining them raw matches nothing and
    -- every rate comes back NULL. The output grain stays month-start.
    SELECT
        b.portfolio_sk,
        b.collection_month,
        SUM(b.amount * fx.rate_flow)                 AS case_collections_sum,
        COUNT(DISTINCT b.currency_id)                AS case_currency_count,
        -- FALSE means a currency had no rate that month, so the sum is short by
        -- that row and the reconciliation must not use it.
        MIN(IFF(fx.rate_flow IS NOT NULL, 1, 0)) = 1 AS case_has_fx_flag
    FROM case_collection_base AS b
    LEFT JOIN fx_rates AS fx
        ON fx.currency_id = b.currency_id
        AND fx.reporting_month = LAST_DAY(b.collection_month)
    GROUP BY 1, 2
),

case_payment_window AS (
    -- ⚠ PREVIOUS/NEXT *PAYING* MONTHS, NOT CALENDAR MONTHS -- only 55.7% sit one
    -- month apart. Always test the date, never the slot.
    SELECT
        portfolio_sk,
        case_id,
        collection_month,
        LAG(collection_month, 1) OVER (
            PARTITION BY portfolio_sk, case_id ORDER BY collection_month)
                                    AS previous_1_month,
        LAG(collection_month, 2) OVER (
            PARTITION BY portfolio_sk, case_id ORDER BY collection_month)
                                    AS previous_2_months,
        LEAD(collection_month, 1) OVER (
            PARTITION BY portfolio_sk, case_id ORDER BY collection_month)
                                    AS next_1_month,
        LEAD(collection_month, 2) OVER (
            PARTITION BY portfolio_sk, case_id ORDER BY collection_month)
                                    AS next_2_months
    FROM case_base
),

monthly_payers AS (
    -- L0 is the row's month, L1 the one before, L2 two before. BOTH previous
    -- slots are tested, because a loan can skip L1 and still have paid L2.
    SELECT
        portfolio_sk,
        collection_month,
        COUNT(*)                                 AS paying_loans_count,
        SUM(IFF(previous_1_month IS NULL, 1, 0)) AS paying_loans_activated_count,
        SUM(IFF(previous_1_month = DATEADD('MONTH', -1, collection_month)
                AND previous_2_months = DATEADD('MONTH', -2, collection_month), 1, 0))
                                                 AS paying_loans_consistent_3m_count,
        SUM(IFF(COALESCE(previous_1_month = DATEADD('MONTH', -2, collection_month), FALSE)
                OR COALESCE(previous_2_months = DATEADD('MONTH', -2, collection_month), FALSE),
                0, 1))                           AS payment_loans_jitter_count,
        SUM(IFF(COALESCE(previous_1_month = DATEADD('MONTH', -1, collection_month), FALSE)
                OR COALESCE(previous_1_month = DATEADD('MONTH', -2, collection_month), FALSE)
                OR COALESCE(previous_2_months = DATEADD('MONTH', -2, collection_month), FALSE),
                0, 1))                           AS payment_loans_new_count
    FROM case_payment_window
    GROUP BY 1, 2
),

max_paid_month AS (
    -- A "lost" count after this would be the data ending, not a loan stopping.
    SELECT MAX(collection_month) AS max_month FROM case_base
),

monthly_lost AS (
    SELECT
        s.portfolio_sk,
        DATEADD('MONTH', 2, s.collection_month) AS collection_month,
        COUNT(*)                                AS payment_loans_lost_count
    FROM case_payment_window AS s
    CROSS JOIN max_paid_month AS m
    WHERE DATEADD('MONTH', 2, s.collection_month) <= m.max_month
      AND NOT COALESCE(s.next_1_month  = DATEADD('MONTH', 2, s.collection_month), FALSE)
      AND NOT COALESCE(s.next_2_months = DATEADD('MONTH', 2, s.collection_month), FALSE)
    GROUP BY 1, 2
),

portfolio_last_payment AS (
    SELECT
        portfolio_sk,
        MAX(collection_month) AS last_payment_month
    FROM case_base
    GROUP BY 1
),

book AS (
    -- ⚠ FCT_CASE_SNAPSHOT_DAILY is MONTH-END grain despite its name.
    SELECT
        s.portfolio_sk,
        s.case_id
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    INNER JOIN (
        SELECT
            portfolio_sk,
            MAX(date_day) AS latest_day
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
        GROUP BY 1
    ) AS l
        ON l.portfolio_sk = s.portfolio_sk
        AND l.latest_day = s.date_day
    GROUP BY 1, 2
),

book_stats AS (
    -- Static per portfolio: identical on every month.
    SELECT
        b.portfolio_sk,
        COUNT(*)                        AS loans_on_book_count,
        COUNT_IF(e.case_id IS NOT NULL) AS payment_loans_ever_paid_count,
        COUNT_IF(e.case_id IS NULL)     AS payment_loans_not_paying_count
    FROM book AS b
    LEFT JOIN (
        SELECT
            portfolio_sk,
            case_id
        FROM case_base
        GROUP BY 1, 2
    ) AS e
        ON e.portfolio_sk = b.portfolio_sk
        AND e.case_id = b.case_id
    GROUP BY 1
)

SELECT
    mp.portfolio_sk,
    -- ⚠ MONTH-START, matching the other three datasets on the page.
    DATE_TRUNC('MONTH', mp.collection_month)::DATE AS reporting_month,
    mp.paying_loans_count,
    mp.paying_loans_activated_count,
    mp.paying_loans_consistent_3m_count,
    mp.payment_loans_jitter_count,
    mp.payment_loans_new_count,
    COALESCE(ml.payment_loans_lost_count, 0)       AS payment_loans_lost_count,
    bs.loans_on_book_count,
    bs.payment_loans_ever_paid_count,
    bs.payment_loans_not_paying_count,
    -- ⚠ MONTH-START TOO. Month-end here compares against a month-start
    -- reporting_month downstream, and feed_stopped_flag fires on every row.
    plp.last_payment_month                         AS portfolio_last_payment_month,
    cmc.case_collections_sum,
    cmc.case_currency_count,
    COALESCE(cmc.case_has_fx_flag, FALSE)          AS case_has_fx_flag
FROM monthly_payers AS mp
-- portfolio_base is NOT re-joined here: it was only ever needed for the name,
-- and the scope and capex floor are already applied in case_collection_base.
LEFT JOIN monthly_lost AS ml
    ON ml.portfolio_sk = mp.portfolio_sk
    AND ml.collection_month = mp.collection_month
LEFT JOIN case_month_cash AS cmc
    ON cmc.portfolio_sk = mp.portfolio_sk
    AND cmc.collection_month = mp.collection_month
LEFT JOIN portfolio_last_payment AS plp
    ON plp.portfolio_sk = mp.portfolio_sk
LEFT JOIN book_stats AS bs
    ON bs.portfolio_sk = mp.portfolio_sk
