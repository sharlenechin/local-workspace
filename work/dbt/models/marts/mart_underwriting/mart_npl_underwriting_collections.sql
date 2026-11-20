/*
UNDERWRITING. ONE ROW PER (CASE_BK, COLLECTION_MONTH) -- what each loan actually
paid, month by month, in the shape a liquidation curve needs.

THE OTHER HALF OF THE UNDERWRITING MART. mart_npl_underwriting_accounts is the
static picture of what we bought; this is the cash that came back afterwards.
Joined on CASE_BK they give recovery per loan over time, which is what the asset
index work needs and what the servicing marts deliberately do not provide --
those aggregate to portfolio x month and lose the loan.

⚠⚠⚠ SCOPE DIFFERS FROM THE ACCOUNTS MODEL ON PURPOSE. Accounts covers loans ON
BOOK at the latest file. This one covers EVERY loan that has ever paid, including
the ~648k no longer on any file -- closed, sold on, or simply absent. Excluding
them is exactly the bias a liquidation curve must not have: they are the loans
that finished, and dropping them flatters every vintage, worst on the oldest.
⚠ SO A LEFT JOIN FROM ACCOUNTS TO THIS MODEL LOSES PAYMENTS. Join the other way,
or accept that you are measuring only the book we still hold.

⚠⚠⚠ THE SOURCE FACT IS INCOMPLETE AND THIS MODEL CANNOT FIX IT. Measured
2026-10-02 against PROD: FCT_CASE_COLLECTION holds 66.75% of the cash the
servicer reports for HEI-PT25001-U02/2512 (EUR 327,991,889.83 of 491,347,313.75)
and 1.28% for HEI-PT25001-S01/2512. The cause is upstream, in
int_npl_case_collection_conformed:

    inner join cases on transaction_date >= cases.valid_from

A payment made before Brocc's first CAT snapshot of that case is discarded. The
loss is per case, so a recently-registered loan can lose its whole history while
a long-standing one keeps most of it. ⚠⚠ THAT MEANS A LIQUIDATION CURVE BUILT
ON THIS MODEL UNDERSTATES EARLY RECOVERY, and understates it worst on the oldest
vintages -- the same direction as the survivorship bias the scope note above
exists to avoid. Fixing it is a brocc-data change (backdate the Intrum case SCD;
see work/dbt/NPL-UNDERWRITING-DESIGN.md). Until it lands, reconcile against
FCT_PORTFOLIO_SNAPSHOT_MONTHLY per portfolio and quote the coverage beside any
curve.

⚠⚠ UNDATED CASH IS ALREADY GONE, AND THE BACKDATE WILL NOT BRING IT BACK.
FCT_CASE_COLLECTION carries ZERO rows with a null COLLECTION_DATE across all
134,472,689 (measured 2026-10-02) -- a NULL fails the >= comparison above, so
the same inner join drops it whatever valid_from becomes. The raw feed does
carry undated payments: on Project Elsa, after recovering dates across versions,
EUR 5,587,796.29 remained undated (2.02%, 6,233 loans) and the benchmark keeps
it flagged rather than dropped. ⚠ The COLLECTION_DATE IS NOT NULL guard below is
therefore defensive only -- it removes nothing today, and its presence must not
be read as this model having handled the problem.

⚠⚠⚠ MATCHED ON CASE_BK, NEVER CASE_SK. FCT_NPL_CASE_COLLECTION carries the
versioned CASE_SK and DIM_NPL_CASE is an SCD2, so joining collections to any
loan-level attribute on CASE_SK drops every payment made under a superseded
version. Measured 2026-09-09: that understated collections by 20.1% on one book
and EUR 128.2m across 12 months -- 15.01% for ORANGE/HEIMDALL, 8.38% BLUE/LOKI.
The loss is worse at scale than on any single portfolio.

⚠⚠ COLLECTION_BK IS NOT A ROW KEY AND MUST NOT BE DEDUPED ON. 134,472,689 rows
but only ~90.4m distinct values plus ~70k NULLs. 4,141,626 keys are shared
across 47,779,540 rows -- 36% of the table, EUR 10.6bn -- and in ZERO of those
cases are the sharing rows identical: every one differs on (CASE_SK,
COLLECTION_DATE, AMOUNT). They are genuinely different payments. A DISTINCT or a
QUALIFY dedupe on it deletes about a third of real money. There is no column
that uniquely identifies a payment.

⚠⚠ COLLECTION DATES REACH THE YEAR 4570. A known data-quality problem in the
source. This model BOUNDS THEM VISIBLY rather than silently: anything dated
after the current date is excluded and counted in the audit model below, so the
exclusion can be inspected instead of becoming folklore.

⚠ CURRENCY IS NOT CONVERTED HERE. Amounts are in the portfolio's own currency
and COLLECTION_CURRENCY names it. Converting needs FCT_EXCHANGE_RATE_MONTHLY,
where RATE_TYPE='FIXED' is the identity self-pair only and every real cross rate
is 'PMI' -- and despite the BASE/QUOTE column names the value is base per quote,
so a local amount is MULTIPLIED by it. Inverting values SEK 32.2m at EUR 356m
instead of EUR 2.9m. Convert deliberately, downstream, once.

⚠ MONTHLY, NOT DAILY. Collapsed to month-end because a liquidation curve is a
monthly object and the daily grain triples the row count for no gain. The
payment count is kept so an average payment size is still derivable.
*/

WITH collection_case AS (
    -- ⚠⚠ RESOLVE THE DURABLE KEY FIRST. Every downstream grouping is on
    -- CASE_BK, so the version key is translated exactly once here rather than
    -- in each consumer's query -- which is where the 20.1% loss came from.
    SELECT
        d.case_bk,
        c.collection_date::DATE                        AS collection_date,
        c.amount,
        c.currency_id                                  AS collection_currency
    FROM {{ ref('fct_npl_case_collection') }} AS c
    INNER JOIN {{ ref('dim_npl_case') }} AS d
        ON d.case_sk = c.case_sk
    -- ⚠ THE YEAR-4570 GUARD. Named, not silent -- see the header.
    WHERE c.collection_date IS NOT NULL
      AND c.collection_date <= CURRENT_DATE()
      -- ⚠ 1990 rather than 1900: the earliest real NPL collection in this
      -- warehouse is well after it, and everything below is a sentinel.
      AND c.collection_date >= '1990-01-01'
),

monthly AS (
    SELECT
        case_bk,
        LAST_DAY(collection_date)                      AS collection_month,
        collection_currency,
        SUM(amount)                                    AS collections_amount,
        -- ⚠ A COUNT OF ROWS, NOT OF DISTINCT PAYMENTS. There is no key that
        -- identifies a payment, so this is the best available and it is an
        -- upper bound where the source repeats a row.
        COUNT(*)                                       AS collection_row_count,
        MIN(collection_date)                           AS first_collection_date,
        MAX(collection_date)                           AS last_collection_date
    FROM collection_case
    GROUP BY 1, 2, 3
),

loan_first_payment AS (
    -- Carried so a curve can be indexed off the loan's own first payment rather
    -- than a calendar month, without the consumer re-scanning 134m rows.
    SELECT
        case_bk,
        MIN(collection_month)                          AS first_collection_month
    FROM monthly
    GROUP BY 1
)

SELECT
    -- ---- keys -------------------------------------------------------------
    -- ⚠⚠ JOIN TO mart_npl_underwriting_accounts ON THIS.
    m.case_bk,
    m.collection_month,
    YEAR(m.collection_month)                           AS collection_year,

    -- ---- money -------------------------------------------------------------
    -- ⚠ IN THE PORTFOLIO'S OWN CURRENCY. Not converted -- see the header.
    m.collections_amount,
    m.collection_currency,
    m.collection_row_count,

    -- ---- position in the loan's own history --------------------------------
    f.first_collection_month,
    -- ⚠⚠ MONTHS SINCE THE LOAN'S FIRST PAYMENT, so curves from books bought in
    -- different months line up. 0 is the month of first payment.
    DATEDIFF('MONTH', f.first_collection_month, m.collection_month)
                                                       AS months_since_first_collection,
    m.first_collection_date,
    m.last_collection_date,

    -- ---- flags -------------------------------------------------------------
    m.collection_month = f.first_collection_month      AS is_first_collection_month_flag,
    -- ⚠ TRUE where the month nets to zero or below. Refunds and reversals are
    -- real and are NOT filtered out -- a curve that hides them overstates
    -- recovery. Guard the sum if you need gross.
    m.collections_amount <= 0                          AS is_non_positive_month_flag
FROM monthly AS m
INNER JOIN loan_first_payment AS f
    ON f.case_bk = m.case_bk
