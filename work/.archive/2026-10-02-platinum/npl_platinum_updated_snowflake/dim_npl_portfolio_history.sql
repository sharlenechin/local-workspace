-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/dim_npl_portfolio_history.sql
--   this   : the same model with every {{ ref() }} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/dim_npl_portfolio_history.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
-- ⚠⚠ dim_npl_platinum_portfolio IS INLINED AS A CTE BELOW, because it is not a table yet.
-- Inlined ONCE however many times the model refs it, so the scan is not
-- repeated -- but this still runs slower than the dbt version, which
-- reads it as a materialised table. Expected, not a bug.
-- ============================================================================

/*
PLATINUM (updated). ONE ROW PER (PORTFOLIO_SK, PHASE_TYPE, PHASE_ENTITY_SK) --
every party that has held a book, and every purchase of it, as rows.

SAME SHAPE AS dim_npl_case_history, on purpose. Every event is a PHASE with a
start, an end and an entity, so one query answers "who had this book in March
2026" and another "when did Brocc buy it" without either needing its own column.

  LEGACY_ACQUISITION  the previous owner assembled the book  -- batch dates
  BROCC_ACQUISITION   Brocc bought it                        -- capex date
  SERVICER            a servicer system held the loans       -- window
  LEGAL_BUYER         a Brocc vehicle owned them             -- window

⚠⚠ THREE COLUMNS DESCRIBE A PHASE, AND THEY ANSWER DIFFERENT QUESTIONS.
  PHASE_ENTITY  WHO did it     -- 'Brocc', 'Intrum', a vehicle, a seller
  PHASE_STATUS  WHAT KIND      -- ACQUISITION / REGISTRATION / SERVICING / ...
  PHASE_TYPE    WHICH ONE      -- the specific event, e.g. BROCC_ACQUISITION
⚠ PHASE_STATUS IS THE ONE TO FILTER ON for "every purchase", because it groups
events of the same kind whoever did them:
BROCC_ACQUISITION and LEGACY_ACQUISITION are both ACQUISITION. PHASE_TYPE stays
because the two are NOT interchangeable -- they are different purchases by
different parties, and a filter on status alone would sum them together.

⚠⚠ EVERY ACTIVITY IS A ROW. Nothing that happens to a book is a column here.
An earlier build had PHASE_ENTITY_FIRST_REGISTRATION_DATE hanging off the
SERVICER row and PORTFOLIO_BROCC_ACQUISITION_DATE repeated on all of them --
both meant a consumer had to know which column held which event. Now you filter
PHASE_TYPE and read PHASE_START_DATE, whatever the event is.

⚠⚠ THIS REPLACED A DESIGN WITH PORTFOLIO_* DATE COLUMNS REPEATED ON EVERY ROW.
Brocc's purchase used to sit as PORTFOLIO_BROCC_ACQUISITION_DATE on all four
rows of a book, which read as though it belonged to the row's entity and did
not. It is now its own phase: filter PHASE_TYPE = 'BROCC_ACQUISITION' and read
PHASE_START_DATE. Nothing is repeated and nothing can be misread.

⚠ ADDING A PARTY OR AN EVENT ADDS ROWS, NOT COLUMNS. That is the whole point of
the long shape -- a wide table needs a new column and every consumer changes.

⚠⚠ PHASE_ORDER IS CHRONOLOGICAL, and it is the only ordering emitted. A
declared "expected order" column was dropped on 2026-09-27: it was a guess about
how life should go, and life disagrees routinely -- on every Spanish book
measured, registration happens AFTER the previous owner bought the loans, never
before. An order nobody can rely on is worse than no order.
⚠ PHASE_ORDER IS NULL WHERE THE PHASE HAS NO DATE, rather than being given a
position at the end. An undated phase has no place in a sequence, and numbering
it would invent one.
⚠ A FIXED ORDER IS STILL USED INTERNALLY as the tie-break when two phases share
a date, so the numbering is deterministic between runs. It is not emitted.

⚠⚠ TWO KINDS OF PHASE LIVE HERE AND IS_POINT_EVENT_FLAG SAYS WHICH.
  A WINDOW  (SERVICER, LEGAL_BUYER) has a real start and end: the months that
            party actually held loans.
  A POINT   (BROCC_ACQUISITION) happened on one day. Its PHASE_END_DATE is NULL
            because we still own the book, not because the end is unknown.
  LEGACY_ACQUISITION is a window too, but of a different kind: the first and
            last dates the seller bought batches into this book. A Heimdall
            bundle spans decades; a single-batch book has start = end.

⚠⚠ THE PARTY WINDOWS ARE NOT A SINGLE TIMELINE. 544 portfolio-months carry TWO
reporting systems AT ONCE, across all 34 portfolios that have more than one. An
earlier build assumed one at a time and opened a spell on every change: the two
interleaved and it produced 1,273 spells where only 231 real pairs exist.
⚠ SO A SECOND SERVICER ROW IS NOT A HANDOVER. It usually means parallel running.
IS_CONCURRENT_FLAG separates "they overlapped" from "one replaced the other".

⚠⚠⚠ A SECOND LEGAL_BUYER ROW IS NEITHER -- IT IS THE SAME COMPANY TWICE.
LEGAL_BUYER_SK is keyed on the vehicle's NAME PLUS the date its ownership share
began, so when Brocc's stake changes the same vehicle is issued a new key and
this model opens a second window for it. Measured in PROD 2026-09-27: 14
portfolios carry two LEGAL_BUYER_SK values and IN ALL 14 THE NAME IS IDENTICAL.
No portfolio anywhere carries two different vehicle names -- so every split is a
stake change, and a vehicle change has never happened in this data.
  Intrum Debt Finance AG             0.65 -> 1.00 on 2026-07-01  (10 portfolios)
  Intrum Justitia Debt Fund 1 FIZNF  0.65 -> 1.00 on 2026-07-01  (2)
  Intrum Hellas DAC                  0.65 -> 1.00 on 2026-07-01  (1)
  Danubio S.r.l.                     0.95 -> 1.00 on 2026-01-01  (1)
⚠ IS_CONCURRENT_FLAG IS TRUE ON BOTH ROWS AND IS MISLEADING THERE. The two keys
really do share 2026-07 and 2026-08, but they are one company, so it is neither
parallel running nor a handover. GROUP BY PHASE_ENTITY, NOT PHASE_ENTITY_SK,
whenever the question is "which vehicle", or the vehicle is counted twice.
⚠⚠ AND THE OLD KEY DOES NOT STOP, on 13 of the 14. On HEI-ES25001-U01/2512 at
2026-08-31 the split is exactly the platform split below: 3,480,727 CAT Scale
loans still carry the 0.65 key while 3,228,479 CAT Fenix loans carry the 1.00
one. The migrated platform picked up the new share; the legacy one did not.
SO OWNERSHIP_SHARE IS STALE ON THE LEGACY-PLATFORM LOANS -- a data-quality
problem in the upstream fact, not something to patch here.
LEG-IT25001-U01/2512 is the only clean changeover.

⚠ THE PARTY WINDOWS ARE INFERRED FROM WHICH MONTHS LOANS ARE PRESENT, because
nothing records a mandate, a transfer or a contract date. PHASE_START_DATE is
the first month-end that party appears, not the day anything was signed. The
ACQUISITION phases are different: those dates are stored, not inferred.

⚠ A GAP INSIDE A WINDOW IS NOT A SECOND ROW. MONTHS_ACTIVE counts months present
and MONTHS_SPANNED the calendar width; HAS_GAP_FLAG shows where they disagree.
A late file looks exactly like a gap.

⚠⚠ A SERVICER CHANGE DOES NOT CREATE A NEW PORTFOLIO -- IT CREATES NEW LOANS.
CASE_BK is '<servicer system>-<their case id>', e.g. '4042-4605327', and every
prefix maps to one system. A transfer leaves PORTFOLIO_SK and BATCH_SK untouched
while every CASE_SK is replaced, with nothing linking old to new. Portfolio
money survives a transfer; loan-level continuity does not.
⚠ If one is planned, ask for a CASE BRIDGE (old case_bk -> new case_bk) BEFORE
it happens. The asset index's bridge reaches 7.55% because nobody built one.

⚠ FCT_NPL_CASE_SNAPSHOT_DAILY IS MONTH-END GRAIN DESPITE THE NAME (147 dates,
all EOM), so every inferred date here is a month end.
*/

WITH portfolio_vehicle AS (
    -- ANY_VALUE because both keys are 1:1 to the portfolio on this fact.
    SELECT
        portfolio_sk,
        ANY_VALUE(legal_buyer_sk)                      AS legal_buyer_sk,
        ANY_VALUE(country_id)                          AS fact_country_id
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
    GROUP BY 1
),

portfolio_batch_vintage AS (
    -- ⚠ THE SELLER'S VINTAGE SPREAD, collapsed to one row so the portfolio dim
    -- keeps its grain. DIM_NPL_BATCH is the only place LEGACY_CAPEX_DATE lives.
    SELECT
        b.portfolio_sk,
        COUNT(*)                                       AS batch_count,
        MIN(d.legacy_capex_date)::DATE                 AS legacy_acquisition_first_date,
        MAX(d.legacy_capex_date)::DATE                 AS legacy_acquisition_last_date,
        COUNT(DISTINCT YEAR(d.legacy_capex_date))      AS legacy_acquisition_year_count,
        SUM(d.legacy_capex_amount)                     AS legacy_acquisition_amount
    FROM (
        SELECT
            portfolio_sk,
            batch_sk
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        WHERE period_end_date <= CURRENT_DATE()
        GROUP BY 1, 2
    ) AS b
    LEFT JOIN PROD.NPL_COMMON.DIM_BATCH AS d
        ON d.batch_sk = b.batch_sk
    GROUP BY 1
),

portfolio_registration AS (
    -- ⚠⚠ THE SERVICER'S OWN WINDOW, derived because nothing stores it. The
    -- case snapshot is the only link from a loan to its portfolio, and it is
    -- 1.47bn rows -- each portfolio's OWN latest day is used, not one global
    -- date, because portfolios report on different calendars.
    -- ⚠ FCT_NPL_CASE_SNAPSHOT_DAILY IS MONTH-END GRAIN DESPITE THE NAME.
    SELECT
        b.portfolio_sk,
        MIN(d.registration_date)::DATE                 AS servicer_first_registration_date,
        MAX(d.registration_date)::DATE                 AS servicer_last_registration_date,
        COUNT(DISTINCT b.case_sk)                       AS case_count
    FROM (
        SELECT
            s.portfolio_sk,
            s.case_sk
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        INNER JOIN (
            SELECT
                portfolio_sk,
                MAX(date_day)                          AS latest_day
            FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
            GROUP BY 1
        ) AS l
            ON l.portfolio_sk = s.portfolio_sk
            AND l.latest_day = s.date_day
        GROUP BY 1, 2
    ) AS b
    INNER JOIN PROD.NPL_COMMON.DIM_CASE AS d
        ON d.case_sk = b.case_sk
    GROUP BY 1
),

portfolio_base AS (
    SELECT
        p.portfolio_sk,
        p.portfolio_bk,
        p.deal_id,
        p.currency_id,
        p.flow_type,
        p.capex_date,
        p.capex_amount,
        p.gbv,
        p.principal,
        p.price_gross,
        p.price_net,
        p.price_accounting,
        p.price_percent,
        p.effective_interest_rate,
        p.uw_unlevered_irr,
        p.capitalized_costs,
        p.interim_collections,
        p.pnl,
        p.gmm,
        p.nmm,
        pv.legal_buyer_sk,
        pv.fact_country_id
    FROM PROD.NPL_COMMON.DIM_PORTFOLIO AS p
    LEFT JOIN portfolio_vehicle AS pv
        ON pv.portfolio_sk = p.portfolio_sk
),

orphan_portfolio AS (
    -- Guard. Fact rows with no dimension row -- see the header.
    -- ⚠⚠ ANTI-JOIN: TEST THE RIGHT SIDE FOR NULL. Testing f matches nothing.
    SELECT
        f.portfolio_sk,
        '(Unknown Portfolio ' || f.portfolio_sk || ')' AS portfolio_bk,
        NULL                                           AS deal_id,
        NULL                                           AS currency_id,
        NULL                                           AS flow_type,
        NULL                                           AS capex_date,
        NULL                                           AS capex_amount,
        NULL                                           AS gbv,
        NULL                                           AS principal,
        NULL                                           AS price_gross,
        NULL                                           AS price_net,
        NULL                                           AS price_accounting,
        NULL                                           AS price_percent,
        NULL                                           AS effective_interest_rate,
        NULL                                           AS uw_unlevered_irr,
        NULL                                           AS capitalized_costs,
        NULL                                           AS interim_collections,
        NULL                                           AS pnl,
        NULL                                           AS gmm,
        NULL                                           AS nmm,
        NULL                                           AS legal_buyer_sk,
        ANY_VALUE(f.country_id)                        AS fact_country_id
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS d
        ON d.portfolio_sk = f.portfolio_sk
    WHERE d.portfolio_sk IS NULL
    GROUP BY f.portfolio_sk
),

portfolio_all AS (
    SELECT * FROM portfolio_base

    UNION ALL

    SELECT * FROM orphan_portfolio
),

dim_npl_platinum_portfolio AS (
SELECT
    -- ---- key --------------------------------------------------------------
    p.portfolio_sk,
    p.portfolio_bk                                     AS portfolio_name,

    -- ---- drill path, outermost first ---------------------------------------
    COALESCE(lb.legal_buyer_name, 'Unknown')           AS vehicle,
    COALESCE(ds.deal_source_name, 'Unknown')           AS project,
    COALESCE(d.deal_alias, d.deal_bk, 'Unknown')       AS deal,
    COALESCE(d.seller_name, 'Unknown')                 AS seller_name,
    -- ⚠ DERIVED. Nothing in the warehouse stores the servicer.
    CASE WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'ES' THEN 'Gescobro'
         WHEN ds.deal_source_name = 'LEGACY' AND d.country_id = 'IT' THEN 'Cerved'
         ELSE 'Intrum' END                             AS servicer,
    -- UK is not in DIM_COUNTRY's region map; everything else takes its own.
    CASE WHEN COALESCE(co.country_name, d.country_id, 'Unknown') = 'UK'
         THEN 'Europe' ELSE co.region END              AS region,
    COALESCE(co.country_name, d.country_id, 'Unknown') AS country_name,
    COALESCE(d.country_id, p.fact_country_id, 'Unknown') AS country_code,

    -- ---- purchase economics ------------------------------------------------
    p.currency_id                                      AS portfolio_currency,
    p.flow_type,
    -- ⚠ THE DATE BROCC BOUGHT THE BOOK. Everything before it is the seller's.
    p.capex_date                                       AS brocc_acquisition_date,
    DATE_TRUNC('MONTH', p.capex_date)::DATE            AS brocc_acquisition_month,
    YEAR(p.capex_date)                                 AS brocc_acquisition_year,
    p.capex_amount,
    p.gbv                                              AS gross_book_value,
    p.principal,
    p.price_gross,
    p.price_net,
    p.price_accounting,
    -- Cents on the euro, already x100. ⚠ Reads 0.00 where GBV is zero.
    p.price_percent,
    p.effective_interest_rate,
    p.uw_unlevered_irr,
    p.capitalized_costs,
    p.interim_collections,
    p.pnl,
    p.gmm,
    p.nmm,

    -- ---- the seller's vintage spread. ⚠ A BUNDLE, NOT AN EVENT. -----------
    bv.batch_count,
    bv.legacy_acquisition_first_date,
    bv.legacy_acquisition_last_date,
    bv.legacy_acquisition_year_count,
    bv.legacy_acquisition_amount,
    DATEDIFF('MONTH', bv.legacy_acquisition_first_date, bv.legacy_acquisition_last_date)
                                                       AS legacy_acquisition_span_months,
    -- ⚠ TRUE where the book bundles batches bought in different years, so one
    -- vintage for the whole portfolio averages across them.
    COALESCE(bv.legacy_acquisition_year_count > 1, FALSE)
                                                       AS is_multi_vintage_flag,

    -- ---- the servicer's own window. DERIVED -- see the header. -------------
    pr.servicer_first_registration_date,
    pr.servicer_last_registration_date,
    DATEDIFF('DAY', pr.servicer_first_registration_date,
             pr.servicer_last_registration_date)         AS servicer_registration_span_days,
    -- ⚠ Negative where Intrum opened cases BEFORE Brocc bought the book, which
    -- is the normal shape of a purchased book.
    DATEDIFF('MONTH', DATE_TRUNC('MONTH', p.capex_date),
             DATE_TRUNC('MONTH', pr.servicer_first_registration_date))
                                                       AS servicer_first_registration_months_to_acquisition,
    pr.case_count                                      AS loans_on_book_count,

    -- ---- flags --------------------------------------------------------------
    -- ⚠ TRUE on the sentinel only. Filter it out deliberately, never silently.
    p.portfolio_bk LIKE '(Unknown Portfolio%'          AS is_unknown_portfolio_flag,
    p.capex_date IS NOT NULL                           AS has_acquisition_date_flag,
    -- ⚠ FALSE where no loan of this book appears in the case snapshot, so the
    -- Intrum dates are unknowable rather than absent.
    pr.portfolio_sk IS NOT NULL                        AS has_loan_detail_flag
FROM portfolio_all AS p
LEFT JOIN portfolio_registration AS pr
    ON pr.portfolio_sk = p.portfolio_sk
LEFT JOIN portfolio_batch_vintage AS bv
    ON bv.portfolio_sk = p.portfolio_sk
-- Every dimension LEFT joined: an orphan key must read 'Unknown', never drop
-- the portfolio.
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS d
    ON d.deal_id = p.deal_id
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds
    ON ds.deal_source_bk = d.deal_source_bk
-- DIM_NPL_LEGAL_BUYER is an SCD, but LEGAL_BUYER_SK is the VERSION key and
-- unique (26 rows, 26 keys), so this returns one row. No is_current filter.
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON lb.legal_buyer_sk = p.legal_buyer_sk
LEFT JOIN PROD.COMMON.DIM_COUNTRY AS co
    ON co.iso_alpha2_code = COALESCE(d.country_id, p.fact_country_id)

),

portfolio_party_month AS (
    -- ⚠ BOTH KEYS ARE ON THE SNAPSHOT ITSELF, so neither leg joins to
    -- DIM_NPL_CASE. The snapshot is 1.47bn rows and the case dimension 154m;
    -- joining them merely to learn the servicer would be the most expensive
    -- read in this layer. One pass covers both party types.
    SELECT
        portfolio_sk,
        'SERVICER'                                     AS phase_type,
        reporting_system_sk                            AS phase_entity_sk,
        date_day
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
    GROUP BY 1, 2, 3, 4

    UNION ALL

    SELECT
        portfolio_sk,
        'LEGAL_BUYER'                                  AS phase_type,
        legal_buyer_sk                                 AS phase_entity_sk,
        date_day
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
    GROUP BY 1, 2, 3, 4
),

latest_snapshot AS (
    -- The newest month in the warehouse. A window reaching it is still open.
    SELECT
        MAX(date_day)                                  AS latest_day
    FROM portfolio_party_month
),

servicer_registration AS (
    -- ⚠ PER (PORTFOLIO, SERVICER), not per portfolio. This is what makes the
    -- registration window belong to the row's own entity: on a book run by two
    -- servicers, each gets its own first and last case.
    -- ⚠ Built from the LATEST snapshot day per portfolio -- 21.9m rows -- and
    -- NOT from the full 1.47bn-row history, which would be the same answer at
    -- seventy times the cost.
    SELECT
        b.portfolio_sk,
        d.reporting_system_sk,
        MIN(d.registration_date)::DATE                 AS first_registration_date,
        MAX(d.registration_date)::DATE                 AS last_registration_date,
        COUNT(DISTINCT b.case_sk)                      AS loans_on_book_count
    FROM (
        SELECT
            s.portfolio_sk,
            s.case_sk
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        INNER JOIN (
            SELECT
                portfolio_sk,
                MAX(date_day)                          AS latest_day
            FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
            GROUP BY 1
        ) AS l
            ON l.portfolio_sk = s.portfolio_sk
            AND l.latest_day = s.date_day
        GROUP BY 1, 2
    ) AS b
    INNER JOIN PROD.NPL_COMMON.DIM_CASE AS d
        ON d.case_sk = b.case_sk
    GROUP BY 1, 2
),

party_phase AS (
    -- The two WINDOW phases: a party held loans between these months.
    SELECT
        w.portfolio_sk,
        w.phase_type,
        w.phase_entity_sk,
        w.phase_start_date,
        IFF(w.last_seen_date = l.latest_day, NULL, w.last_seen_date)
                                                       AS phase_end_date,
        w.last_seen_date,
        w.months_active,
        FALSE                                          AS is_point_event_flag,
        w.last_seen_date = l.latest_day                AS is_current_phase_flag
    FROM (
        SELECT
            portfolio_sk,
            phase_type,
            phase_entity_sk,
            MIN(date_day)                              AS phase_start_date,
            MAX(date_day)                              AS last_seen_date,
            COUNT(DISTINCT date_day)                   AS months_active
        FROM portfolio_party_month
        GROUP BY 1, 2, 3
    ) AS w
    CROSS JOIN latest_snapshot AS l
),

-- ⚠⚠⚠ THE REGISTRATION PHASE WAS HERE AND IS DELIBERATELY GONE (2026-09-29).
-- Registration is a fact about a LOAN, not about a book: DIM_NPL_CASE stores
-- REGISTRATION_DATE per case, so anything at portfolio level was a MIN/MAX
-- across the children -- an aggregate wearing an event's clothes, which is
-- exactly what PHASE_DATE_TYPE = 'SPREAD' meant and why it read as a window.
-- ⚠ NOTHING IS LOST. Measured 2026-09-28: all 32 portfolios that carried two
-- REGISTRATION rows also carry two SERVICER rows, so the platform migration is
-- still visible -- and SERVICER catches TWO MORE books that registration misses.
-- The spread itself is one GROUP BY on dim_npl_case_history, where the fact
-- actually lives:
--   SELECT portfolio_sk, MIN(phase_date), MAX(phase_date)
--   FROM dim_npl_case_history WHERE phase_type = 'REGISTRATION' GROUP BY 1
-- ⚠ SERVICER_REGISTRATION IS STILL BUILT ABOVE -- it feeds
-- PHASE_ENTITY_LOANS_ON_BOOK_COUNT on the SERVICER rows. Only the phase is gone.

acquisition_phase AS (
    -- ⚠ THE TWO PURCHASE PHASES. These dates are STORED, not inferred from
    -- which months loans appear -- see the header.
    -- Brocc's purchase: a point event, still open because we still own it.
    SELECT
        p.portfolio_sk,
        'BROCC_ACQUISITION'                            AS phase_type,
        NULL                                           AS phase_entity_sk,
        p.brocc_acquisition_date                       AS phase_start_date,
        NULL                                           AS phase_end_date,
        p.brocc_acquisition_date                       AS last_seen_date,
        NULL                                           AS months_active,
        TRUE                                           AS is_point_event_flag,
        TRUE                                           AS is_current_phase_flag
    FROM dim_npl_platinum_portfolio AS p
    WHERE p.brocc_acquisition_date IS NOT NULL

    UNION ALL

    -- The seller's own assembly window: first and last batch it bought into
    -- this book. ⚠ A bundle spans decades; a single-batch book has start = end.
    SELECT
        p.portfolio_sk,
        'LEGACY_ACQUISITION'                           AS phase_type,
        NULL                                           AS phase_entity_sk,
        p.legacy_acquisition_first_date                AS phase_start_date,
        p.legacy_acquisition_last_date                 AS phase_end_date,
        p.legacy_acquisition_last_date                 AS last_seen_date,
        NULL                                           AS months_active,
        p.legacy_acquisition_first_date = p.legacy_acquisition_last_date
                                                       AS is_point_event_flag,
        FALSE                                          AS is_current_phase_flag
    FROM dim_npl_platinum_portfolio AS p
    WHERE p.legacy_acquisition_first_date IS NOT NULL
),

all_phases AS (
    SELECT * FROM party_phase

    UNION ALL

    SELECT * FROM acquisition_phase
)

SELECT
    -- ---- keys ---------------------------------------------------------------
    a.portfolio_sk,
    -- ⚠⚠⚠ PHASE_TYPE IS DELIBERATELY NOT EMITTED (2026-09-29). It was fully
    -- derivable from PHASE_STATUS + PHASE_ENTITY and carried no information of
    -- its own:
    --   ACQUISITION + 'Brocc'   -> Brocc's purchase
    --   ACQUISITION + 'Legacy'  -> the purchase before ours
    --   SERVICING   + <name>    -> that servicer's spell
    --   OWNERSHIP   + <name>    -> that vehicle's spell
    -- ⚠ IT IS STILL USED INTERNALLY to drive PHASE_STATUS, PHASE_ENTITY,
    -- PHASE_GRAIN, PHASE_SOURCE and the date logic. Only the column is gone.
    -- ⚠ 'Legacy' IS A CATEGORY, NOT A COMPANY, and that is on purpose. The
    -- actual prior acquirer differs by deal source -- Intrum for Heimdall,
    -- Cerberus/Intrum for Loki, Cerberus for Legacy Spain/Italy -- so naming
    -- one company here would be wrong on the other two. Read DEAL/PROJECT for
    -- which.
    -- ⚠ CHRONOLOGICAL, and never NULL: the WHERE at the bottom keeps only rows
    -- that actually have a date.
    ROW_NUMBER() OVER (PARTITION BY a.portfolio_sk
                       ORDER BY a.phase_start_date, a.phase_type)
                                                       AS phase_order,
    -- ⚠⚠ THE MOST RECENT THING WE KNOW HAPPENED TO THIS BOOK -- derived from
    -- the dates, never asserted by a phase named 'LATEST'. Matches
    -- IS_LATEST_PHASE_FLAG on dim_npl_case_history.
    ROW_NUMBER() OVER (PARTITION BY a.portfolio_sk
                       ORDER BY a.phase_start_date DESC, a.phase_type DESC) = 1
                                                       AS is_latest_phase_flag,
    COUNT(*) OVER (PARTITION BY a.portfolio_sk)        AS phase_count,
    -- ⚠ NULL ON THE ACQUISITION PHASES: a purchase has no party dimension to
    -- point at. The buyer is named in PHASE_ENTITY_NAME instead.
    a.phase_entity_sk,
    -- ⚠ WHO. Resolved per row, never assumed -- a book serviced by Gescobro
    -- must not read 'Intrum' because the phase name says so.
    -- ⚠⚠⚠ THE COMPANY, NOT THE PLATFORM. This used to return
    -- REPORTING_SYSTEM_NAME, which is an Intrum PLATFORM ('CAT Fenix', 'CAT
    -- Scale') and not a company at all -- so a portfolio that Intrum migrated
    -- between two of its own systems read as TWO DIFFERENT PARTIES. It is one
    -- servicer throughout. The platform now lives in PHASE_SYSTEM below, and
    -- this column matches PHASE_ENTITY on dim_npl_case_history.
    -- ⚠⚠ TITLE-CASED ONLY WHERE THE SOURCE ARRIVES LOWER CASE. Measured
    -- 2026-09-27: 23 of 24 SERVICER_NAME values are all lower ('intrum',
    -- 'gescobro'), but 0 of 26 LEGAL_BUYER_NAME values are -- they are properly
    -- cased and full of acronyms, so INITCAP would turn 'Intrum Debt Finance
    -- AG' into '... Ag' and 'Rubicon SPV S.r.l' into '... Spv S.R.L'.
    -- ⚠ The IFF guard means a name that already carries capitals is never
    -- touched, which also leaves the literal 'Unknown' alone.
    CASE a.phase_type
        WHEN 'SERVICER'           THEN IFF(rs.servicer_name = LOWER(rs.servicer_name), INITCAP(rs.servicer_name), rs.servicer_name)
        WHEN 'LEGAL_BUYER'        THEN lb.legal_buyer_name
        WHEN 'BROCC_ACQUISITION'  THEN 'Brocc'
        WHEN 'LEGACY_ACQUISITION' THEN 'Legacy'
    END                                                AS phase_entity,
    -- ⚠ WHAT KIND OF PARTY PHASE_ENTITY IS. Shared with the case model, so a
    -- filter written against one table means the same thing on the other.
    CASE a.phase_type
        WHEN 'SERVICER'           THEN 'SERVICER'
        WHEN 'LEGAL_BUYER'        THEN 'VEHICLE'
        WHEN 'BROCC_ACQUISITION'  THEN 'VEHICLE'
        WHEN 'LEGACY_ACQUISITION' THEN 'OWNER'
    END                                                AS phase_entity_type,
    -- ⚠⚠ THE SERVICER'S OWN PLATFORM, e.g. 'CAT Fenix'. A SECOND REGISTRATION
    -- ROW ON A PORTFOLIO IS ALMOST ALWAYS A PLATFORM MIGRATION, not a change of
    -- servicer -- 32 portfolios have two, and in every one the servicer is
    -- unchanged. ⚠ Not unique: codes 7006 and 7010 are both 'CAT Scale'.
    rs.reporting_system_name                           AS phase_system,
    -- ⚠ WHAT KIND. Filter on this for "every purchase" regardless of buyer.
    CASE a.phase_type
        WHEN 'LEGACY_ACQUISITION' THEN 'ACQUISITION'
        WHEN 'BROCC_ACQUISITION'  THEN 'ACQUISITION'
        WHEN 'SERVICER'           THEN 'SERVICING'
        WHEN 'LEGAL_BUYER'        THEN 'OWNERSHIP'
    END                                                AS phase_status,
    -- ⚠ A PROPERTY OF THE VEHICLE, never of the window. NULL elsewhere.
    lb.ownership_share,

    -- ---- the phase -----------------------------------------------------------
    -- ⚠⚠ THE ONE DATE TO TRUST. Shared name with the case model. Whatever the
    -- phase, this is when it STARTED: the first month the party was seen, the
    -- first loan registered, the day of the purchase.
    a.phase_start_date                                 AS phase_date,

    -- ⚠⚠⚠ PHASE_END_DATE USED TO MEAN THREE DIFFERENT THINGS and is now split.
    -- It was: "when the party stopped being seen" on SERVICER and LEGAL_BUYER;
    -- "when the LAST member event happened" on REGISTRATION and
    -- LEGACY_ACQUISITION -- a SPREAD across the loans or batches in the book,
    -- never a period of validity; and simply "not applicable" on
    -- BROCC_ACQUISITION. NULL therefore meant "still open" on some rows and
    -- "no such thing" on others, so no single comparison was safe across the
    -- table. PHASE_DATE_TYPE below says which kind a row is.
    --
    -- ⚠⚠ THE LAST DATE THIS PHASE SHOWS ANY ACTIVITY. One column, because the
    -- question is the same whatever the phase -- what differs is what counts as
    -- activity, and PHASE_DATE_TYPE says which:
    --   OBSERVED_WINDOW  the last month the party was seen. NULL = STILL ACTIVE
    --                    (cross-check IS_CURRENT_PHASE_FLAG).
    --   SPREAD           the last underlying event -- the newest loan
    --                    registered, the last batch bought. Always populated.
    --                    ⚠ The phase did not "stop" here.
    --   POINT_EVENT      NULL, because a single day has no last activity.
    a.phase_end_date                                   AS phase_last_active_date,
    -- ⚠⚠ WHAT KIND OF DATE PHASE_DATE IS -- read this before comparing dates
    -- across phase types.
    --   OBSERVED_WINDOW  inferred from monthly files, so MONTH-END aligned and
    --                    only as precise as the reporting. PHASE_END_DATE
    --                    applies; NULL there means still active.
    --   SPREAD           PHASE_DATE is the FIRST underlying event and
    --                    PHASE_DATE_LAST the last. The gap is how spread out
    --                    the book is, not how long anything lasted.
    --   POINT_EVENT      a single recorded day. Neither end column applies.
    CASE
        WHEN a.phase_type IN ('SERVICER', 'LEGAL_BUYER')            THEN 'OBSERVED_WINDOW'
        WHEN a.phase_type = 'LEGACY_ACQUISITION'                    THEN 'SPREAD'
        ELSE                                                             'POINT_EVENT'
    END                                                AS phase_date_type,
    -- ⚠ HOW MANY LOANS THAT SERVICER HOLDS. NULL on every non-servicer phase.
    sr.loans_on_book_count                             AS phase_entity_loans_on_book_count,

    -- ---- the drill path. Attributes of the book, not dates. -----------------
    p.portfolio_name,
    p.vehicle,
    p.project,
    p.deal,
    p.seller_name,
    -- ⚠ DERIVED from deal source and country, and never changes. For the
    -- servicer that moves, read PHASE_ENTITY on the SERVICER rows.
    p.servicer                                         AS derived_servicer,
    p.region,
    p.country_name,
    p.country_code,
    p.portfolio_currency,
    p.flow_type,
    p.batch_count,
    p.is_multi_vintage_flag,

    -- ---- flags ----------------------------------------------------------------
    -- ⚠ TRUE where the phase is one day, not a window -- see the header.
    a.is_point_event_flag,
    a.is_current_phase_flag,
    -- ⚠⚠⚠ IS_CONCURRENT_FLAG WAS HERE AND IS DELIBERATELY ABSENT. It counted
    -- overlapping windows of a phase type WITHOUT checking that the parties
    -- differed, so the SAME vehicle observed in two stretches of data counted
    -- as "concurrent with itself" and read as two owners where there was one.
    -- Measured 2026-09-27 before removal: 69 SERVICER rows over 34 portfolios
    -- and 26 LEGAL_BUYER rows over 13, with the same-party share unmeasured.
    -- ⚠ A CORRECT DEFINITION NEEDS A PRODUCT DECISION -- does parallel running
    -- mean two DISTINCT parties in one month, and does a gap in the files break
    -- a window or not? Rebuild it once that is settled rather than shipping a
    -- flag that quietly overstates handovers.
    -- ⚠ TRUE where MONTHS_ACTIVE is short of the calendar width: holes in the
    -- window, usually a late file rather than a real absence.
    COALESCE(a.months_active
             < DATEDIFF('MONTH', a.phase_start_date, a.last_seen_date) + 1, FALSE)
                                                       AS has_gap_flag,
    CASE a.phase_type
        WHEN 'LEGACY_ACQUISITION' THEN 'DIM_NPL_BATCH'
        WHEN 'BROCC_ACQUISITION'  THEN 'DIM_NPL_PORTFOLIO'
        ELSE 'FCT_NPL_CASE_SNAPSHOT_DAILY'
    END                                                AS phase_source
FROM all_phases AS a
-- ⚠ EACH JOIN IS GATED ON THE PHASE TYPE. Without the gate a legal_buyer_sk
-- could collide with a reporting_system_sk and resolve to the wrong party.
LEFT JOIN PROD.NPL_COMMON.DIM_REPORTING_SYSTEM AS rs
    ON a.phase_type = 'SERVICER'
    AND rs.reporting_system_sk = a.phase_entity_sk
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON a.phase_type = 'LEGAL_BUYER'
    AND lb.legal_buyer_sk = a.phase_entity_sk
LEFT JOIN servicer_registration AS sr
    ON a.phase_type = 'SERVICER'
    AND sr.portfolio_sk = a.portfolio_sk
    AND sr.reporting_system_sk = a.phase_entity_sk
LEFT JOIN dim_npl_platinum_portfolio AS p
    ON p.portfolio_sk = a.portfolio_sk
-- ⚠⚠⚠ DENSE: A ROW MEANS SOMETHING HAPPENED. A phase with no date produces no
-- row rather than a placeholder full of NULLs -- the same contract as
-- dim_npl_case_history.
WHERE a.phase_start_date IS NOT NULL
