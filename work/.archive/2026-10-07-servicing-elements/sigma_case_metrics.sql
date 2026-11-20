-- ============================================================================
-- SIGMA ELEMENT 'Case Metrics'. ONE ROW PER (PORTFOLIO_SK, REPORTING_MONTH).
-- How the cases on each book collected, already aggregated. The CASE side of
-- the reconciliation.
-- ============================================================================
-- GRAIN     portfolio x month. reporting_month is MONTH-END. 1,296 rows across
--           164 of the 264 portfolios, measured 2026-10-06 against PROD.
--           The 100 missing are books whose cases have never collected; they
--           are supplied by the portfolio side, which LEFT JOINs this.
--
-- ⚠⚠⚠ A THIN READ OF A dbt TABLE, AND THAT IS THE POINT. Everything else on
-- this page is computed in Sigma. This is not, because the work behind it is an
-- inner join onto FCT_CASE_COLLECTION (134,472,689 rows), five window functions
-- and a scan of FCT_CASE_SNAPSHOT_DAILY (1,495,141,431 rows).
--
-- ⚠ LIVE SINCE 2026-10-07. Verified that day: the built table matches the model
-- exactly, all 19 columns across 1,296 rows. As a thin read this now returns in
-- 0.5s, against 51s when the model had to be computed inline.
--
-- ⚠⚠ MONTHS ARE MONTH-END, AND NO CONVERSION IS NEEDED ANY MORE. The model was
-- month-start until 2026-10-02 and this file used to DATE_TRUNC it back. It now
-- emits month-end, matching PERIOD_END_DATE on every upstream fact and the rest
-- of this page. Do not reintroduce a conversion: two different month bases on
-- one page join to nothing, silently and with no error.
--
-- ⚠⚠ THE SIX TRANSITION MEASURES ARE STATED AS THREE MONTHS, x-2 / x-1 / x,
-- where x is the row's own month:
--     first_collection       -  /  -  / yes   nothing before it at all
--     three_consecutive     yes / yes / yes
--     jitter_in             yes /  no / yes   back after one quiet month
--     new                    no /  no / yes   back after a longer gap
--     jitter_out             no / yes /  no   one isolated month, then quiet
--     lost                  yes / yes /  no   was collecting, has stopped
-- ⚠ jitter_out and lost END IN A MONTH WITH NO COLLECTION, so they are counted
-- on that quiet month, not on the last month the case collected. The other four
-- describe a month the case did collect in.
-- ⚠ NEW AND FIRST_COLLECTION OVERLAP -- a case's first collection in scope
-- satisfies both. Never add them together.
--
-- ⚠⚠ EVERY COUNT IS A FLOOR, NEVER A TOTAL. The case feed covers roughly half
-- of what the servicer reports. Read have_loan_detail_flag on 'Reconciliation'
-- before dividing by any of these.
--
-- ⚠⚠ THE THREE BOOK COUNTS ARE NOW AS AT EACH MONTH, NOT AS AT TODAY.
-- Changed 2026-10-06: cases_on_book_count, cases_ever_collected_count and
-- cases_never_collected_count move month to month, so a trend line over them
-- is meaningful and ever-collected reads as a penetration curve. They are no
-- longer portfolio constants -- the old advice to take MAX is now WRONG and
-- would report the last month on every row.
-- ⚠ portfolio_latest_collection_month was dropped from the model on 2026-10-06.
-- It is MAX(reporting_month) over the rows here where collected_cases_count > 0,
-- and 'Reconciliation' derives it. A stored portfolio-level value is wrong the
-- moment anyone filters the months under it.
-- ⚠ cases_on_book_count IS NULL, NOT ZERO, where the snapshot has no row for
-- that month. 2 rows, measured 2026-10-06, on a book whose snapshot stops
-- before its collections do. Filter them out before charting a book size.

-- ⚠⚠ THE TWO AMOUNT COLUMNS ARE LOCAL CURRENCY AND ARE NOT MONEY. 20 of 1,252
-- portfolio-months hold two currencies, on 2 Polish books. Convert with the FX
-- element per currency BEFORE summing, exactly as 'Portfolio Metrics' does.
-- ⚠ They are NET OF REVERSALS and can be negative: one portfolio-month nets
-- -896,873.55, being 6,070,595.83 collected against -6,967,469.38 reversed,
-- measured 2026-10-06. A "total collections" tile reading negative is the data,
-- not a bug -- but say so rather than letting it look like one.
--
-- ⚠ COLLECTED_CASES_COUNT CAN BE 0. A month where the portfolio collected from
-- nobody still appears, because cases are recorded as stopping in it. Do not
-- read a 0 as a missing month -- 44 such rows exist, measured 2026-10-06.
--
-- ⚠ THE MONTH COUNT BEHIND THE 80% COVERAGE TEST IS NO LONGER A COLUMN.
-- It is COUNT(DISTINCT reporting_month) over the rows here, and
-- 'Reconciliation' derives it. A stored count is wrong the moment anyone
-- filters the months under it.
-- ============================================================================
SELECT
    portfolio_sk,
    period_end_date       AS reporting_month,
    YEAR(period_end_date) AS reporting_year,

    -- ---- how the book collected this month ---------------------------------
    collected_cases_count,
    collected_cases_first_collection_count,
    collected_cases_three_consecutive_months_count,
    collected_cases_jitter_in_count,
    collected_cases_jitter_out_count,
    collected_cases_new_count,
    -- ⚠ Read feed_stopped_flag on 'Reconciliation' first: when a feed stops,
    -- every collecting case reads lost in the month after it stopped.
    collected_cases_lost_count,

    -- ---- how much came in. ⚠ LOCAL CURRENCY -- convert before summing. ------
    collected_amount_local_sum,
    collected_amount_local_first_collection_sum,
    collected_amount_local_three_consecutive_months_sum,
    collected_amount_local_jitter_in_sum,
    collected_amount_local_new_sum,
    -- ⚠ These two are a DIFFERENT MONTH'S money: the month they are reported in
    -- has no collection by definition, so they carry what those cases collected
    -- in their LAST month. Never add them to the four above.
    collected_amount_local_jitter_out_last_month_sum,
    collected_amount_local_lost_last_month_sum,

    -- ---- the book AS AT THIS MONTH ------------------------------------------
    cases_on_book_count,
    cases_ever_collected_count,
    -- ⚠ NEVER MEANS NOT AS AT THIS MONTH, not never-in-the-end -- a case
    -- counted here in May may collect in June and leave this count. The capex
    -- floor is applied upstream, so it is also only since Brocc bought the book.
    cases_never_collected_count

FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY
