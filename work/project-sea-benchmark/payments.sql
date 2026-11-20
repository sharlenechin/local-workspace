-- ============================================================================
-- PROJECT SEA · payments — one row per loan per payment date: the recovery curve.
-- Portugal, instance 4050, FIVE sellers:
--   WIZINK BANK · BARCLAYCARD · MILLENNIUM · ONEY · COFIDIS
--
--   RUN     mise run sql -- work/project-sea-benchmark/payments.sql \
--             --csv work/project-sea-benchmark/project_sea_benchmark_payments.csv
--   GRAIN   one row per (LOAN_ID, PAYMENT_DATE). A loan that paid on 40 days
--           has 40 rows — AGGREGATE TO LOAN LEVEL BEFORE JOINING TO ACCOUNTS,
--           or every balance repeats once per payment row.
--   PAIRS   accounts.sql on (PORTFOLIO_ID, LOAN_ID) — identical population.
--   RUNTIME ~4 min. Every extract of the transaction feed, no date bound.
--   METHOD  ../../work/benchmark-dataset/post-registration-benchmark/METHOD.md, step 3
--   BASED   ../../work/benchmark-dataset/post-registration-benchmark/templates/02_payments.sql
--
-- Every figure below measured 2026-10-01.
-- ============================================================================
-- RETURNS  1,284,551 rows × 7 columns, over 93,692 of the 217,104 loans in
--          accounts.sql — 43.16% of the book has ever paid. 23 batches
--          appear: of the 26 PAM names, two hold no cases in CAT at all and
--          PT070040000000's 2 loans have never paid. Those absences are
--          findings, and reconciliation.sql keeps all 26.
--
--   seller       loans paying   share of its loans      collections
--   MILLENNIUM         52,214             43.25466   160,228,394.35
--   WIZINK BANK        18,262             53.15365    53,647,718.14
--   BARCLAYCARD        14,542             47.54774    43,043,724.86
--   COFIDIS             4,577             54.31996    17,712,591.69
--   ONEY                4,097             17.79448     2,098,860.49
--   TOTAL              93,692             43.15718   276,731,289.53
--
--   ⚠ 4,784 rows carry a NEGATIVE total — reversals and refunds, netted within
--   a (loan, date). They are real and they are kept; EUR −3,138,527.45.
--
-- ============================================================================
-- READ FIRST
-- ============================================================================
-- 1. ⚠ THIS IS NOT "COLLECTIONS TO DATE". It stops where the CAT extract stops
--    (last payment 2026-01-14, measured 2026-10-01) while PAM has actuals to
--    2026-08 — the loan-level feed is SEVEN MONTHS BEHIND. Anything recent must
--    be read from PAM. reconciliation.sql sizes the gap per batch.
-- 2. ⚠ UNDATED CASH IS REAL MONEY AND IT IS KEPT, flagged not dropped.
--    EUR 5,587,796.29 across 6,233 loans — 2.01921% of all collections —
--    carries no TRANSACTION_DATE in ANY version of the transaction. It is
--    almost all MILLENNIUM (5,450,225.84, 3.40154% of that seller's cash) and
--    COFIDIS (137,572.07, 0.77669%); BARCLAYCARD and ONEY have none at all.
--    Filter on PAYMENT_DATE to build a curve and the total falls short by that
--    much — do not then quote the remainder as the book's collections.
-- 3. ⚠ CAT CARRIES THE SERVICER'S WHOLE HISTORY, NOT THE BOOK'S. Payments here
--    run from 2000-01-18 (MILLENNIUM) and 2002-01-28 (BARCLAYCARD) — eleven
--    years before Intrum bought the Barclaycard book — and that is deliberately
--    NOT bounded, because for underwriting it is exactly the borrower behaviour
--    wanted. ⚠ But "pre-acquisition" is ambiguous: this is pre-BROCC history,
--    not pre-originator. CAT begins when INTRUM registered the loan; the
--    originating bank's own payment history is in neither CAT nor the
--    warehouse. ⚠ EUR 4,288,048.76 of the 276,731,289.53 (1.54954%) predates
--    its own batch's capex month — more than half of it on PT15018G000000 and
--    PT18019A000000. PAM structurally cannot hold that cash, so the
--    reconciliation removes it explicitly rather than bounding this file.
-- 4. ⚠ NO PAYMENT COUNT IS RETURNED. Rows with no AMOUNT pass the servicer's
--    own payment filter, so a count would be inflated by them. Money is
--    unaffected — they are excluded here.
--
-- ============================================================================
-- GUARDS
-- ============================================================================
-- P1 C2 · TRANSACTIONS IS A CHANGE-HISTORY FEED (~10.8x on this estate).
--    Deduped on (CASE_ID, ORIG_TR_ID || COALESCE(PKEY,'')), latest
--    RECORD_UPDATED wins. PKEY is in the key because some countries split one
--    transaction across rows. ⚠ CONCAT() returns NULL if any part is NULL, so
--    rows with a null ORIG_TR_ID collapse into one partition — that is the
--    data team's own key and its own weakness, kept so figures agree with PROD.
-- P2 C6 · payments only: PAYMENT_COST_IND = 'P' and BOOKING_IND <> 'Y'.
--    Without it, costs and fees land in the collections total.
-- P3 C7 · AMOUNT IS STORED SIGN-FLIPPED — a collection arrives negative, so it
--    is read as -amount. Right magnitude, wrong sign without it.
-- P4 ⚠ THE DATE IS RECOVERED ACROSS EVERY VERSION of the transaction, not
--    taken from the winning version. Any version may carry a date the winner
--    lacks; on Elsa that rescued EUR 53m. NEVER bound this date instead —
--    sentinel years (1900, 2099) live on superseded versions and non-payment
--    rows and never survive the dedupe, so a bound only deletes real money.
-- P5 C1/C8/C4/C5/C9 · the `batches` and `cases` CTEs are COPIED VERBATIM from
--    accounts.sql and must stay byte-identical, including $seller_list and
--    $exclude_batches. A single stray space in a parameter makes split() yield
--    ' BARCLAYCARD', which matches nothing and drops a whole seller silently.
-- P6 ⚠⚠ THE DEAL-TYPE FILTER IS AT THE FINAL SELECT, NEVER IN `batches` —
--    guard A3 of accounts.sql. Filtering early changes what the C1 dedupe
--    can see and C8 then re-attributes loans: measured 2026-10-01, it moves 365
--    loans from PT19007E021905 (Ongoing) into PT19013A020000 (One-off) and
--    inflates the book from 217,104 loans to 217,469.
-- P7 THE DEBTOR-TYPE GATE IS DELIBERATELY ABSENT. The template drops loans with
--    no identifiable debtor; that filter existed only to make a pricing segment
--    trustworthy, and accounts.sql carries INDIVIDUAL_FLAG = NULL instead.
--    Re-adding it here would drop 177 loans and break the pairing assert.
-- ⚠ Nothing may follow the final semicolon: run_sql.py splits on ';'.
-- ============================================================================

set country         = 'PT';
set seller_list     = 'WIZINK BANK,BARCLAYCARD,MILLENNIUM,ONEY,COFIDIS';  -- = accounts
set deal_type       = 'One-off';   -- = accounts; '' keeps forward flow too
set source_system   = '4050';
set raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set exclude_batches = '';          -- = accounts, byte for byte


-- ⚠ NO DEAL-TYPE FILTER HERE. See P6.
with batches AS (
    SELECT
        UPPER(combined_ref)                 AS combined_ref,
        MAX(TRIM(UPPER(seller_name)))       AS seller,
        MAX(deal_type_desc)                 AS deal_type
    FROM RAW.HYPERION_INTRUM_PAM.PAM
    WHERE _file_path = (
              SELECT MAX(_file_path)
              FROM RAW.HYPERION_INTRUM_PAM.PAM
              WHERE _file_path LIKE '%/pam.pam.pam.2%'
          )
      AND pmode_name = 'Real'
      AND COALESCE(is_ownership_change, 0) = 0
      AND countrycode LIKE $country
      AND ARRAY_CONTAINS(TRIM(UPPER(seller_name))::variant,
                         SPLIT(REPLACE($seller_list, ', ', ','), ','))
    GROUP BY 1
),

-- One row per loan, latest version, batch filter BEFORE the qualify (C8).
cases AS (
    SELECT
        UPPER(c.long_portfolio_id)  AS portfolio_id,
        c.case_id                   AS loan_id
    FROM RAW.HYPERION_INTRUM_CAT.CASES AS c
    WHERE c._file_path LIKE $raw_prefix || $source_system || '.cases.%'
      AND UPPER(c.long_portfolio_id) IN (SELECT combined_ref FROM batches)
      AND c.case_id NOT LIKE '%-%'
      AND NOT ($source_system = '2080' AND COALESCE(c.real_case_ind, '') = '1')
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY c.case_id
        ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
    ) = 1
),

-- One row per real payment, already carrying its batch. The join to `cases`
-- sits INSIDE this CTE on purpose: it cuts the scan to the scope before the
-- dedupe window runs AND attaches PORTFOLIO_ID in the same read.
payments AS (
    SELECT
        c.portfolio_id,
        c.loan_id,
        -- Latest non-null date across EVERY version of this transaction (P4).
        MAX(t.transaction_date::date) OVER (
            PARTITION BY t.case_id, CONCAT(t.orig_tr_id, COALESCE(t.pkey, ''))
        )                           AS payment_date,
        -t.amount::decimal(38, 2)   AS amount                           -- P3
    FROM RAW.HYPERION_INTRUM_CAT.TRANSACTIONS AS t
    INNER JOIN cases AS c
        ON c.loan_id = t.case_id
    WHERE t._file_path LIKE $raw_prefix || $source_system || '.transactions.%'
      AND t.payment_cost_ind = 'P'                                      -- P2
      AND COALESCE(t.booking_ind, 'N') != 'Y'                           -- P2
      AND t.amount IS NOT NULL                     -- amount-less rows, READ FIRST 4
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY t.case_id, CONCAT(t.orig_tr_id, COALESCE(t.pkey, ''))
        ORDER BY COALESCE(t.record_updated, t.update_ts)::timestamp DESC NULLS LAST
    ) = 1                                                               -- P1
)

SELECT
    -- ids
    b.seller,
    b.deal_type,
    p.portfolio_id,
    p.loan_id,
    -- dates
    p.payment_date,                     -- TRANSACTION_DATE, not banking/booking
    -- booleans
    p.payment_date IS NULL              AS missing_payment_date_flag,
    -- amounts
    SUM(p.amount)                       AS total_collections
FROM payments AS p
JOIN batches AS b
    ON b.combined_ref = p.portfolio_id
-- ⚠⚠ BOTH FILTERS LAND HERE, AND THE DEAL-TYPE ONE MUST — see P6.
-- ⚠ WHERE comes after the join, not between FROM and JOIN.
WHERE ($deal_type = '' OR b.deal_type = $deal_type)
  AND ($exclude_batches = ''
       OR NOT ARRAY_CONTAINS(p.portfolio_id::variant,
                             SPLIT(REPLACE($exclude_batches, ', ', ','), ',')))
GROUP BY b.seller, b.deal_type, p.portfolio_id, p.loan_id, p.payment_date
ORDER BY b.seller, p.portfolio_id, p.loan_id, p.payment_date NULLS LAST;
