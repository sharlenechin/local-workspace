-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/dim_npl_case_history.sql
--   this   : the same model with every {{ ref() }} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/dim_npl_case_history.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
-- ⚠⚠ fct_npl_platinum_case_status IS INLINED AS A CTE BELOW, because it is not a table yet.
-- Inlined ONCE however many times the model refs it, so the scan is not
-- repeated -- but this still runs slower than the dbt version, which
-- reads it as a materialised table. Expected, not a bug.
-- ⚠⚠ dim_npl_platinum_portfolio IS INLINED AS A CTE BELOW, because it is not a table yet.
-- Inlined ONCE however many times the model refs it, so the scan is not
-- repeated -- but this still runs slower than the dbt version, which
-- reads it as a materialised table. Expected, not a bug.
-- ============================================================================

/*
PLATINUM (updated). ONE ROW PER (CASE_BK, PHASE) -- a loan's life told as the
handful of moments that matter, with what was true of it AT each moment.

LONG, NOT WIDE, AND THAT IS THE POINT. A phase with no date still gets a row, so
"we do not know when this loan was registered" is visible rather than inferred
from a missing column. It is also what lets the asset index slot in later
without a redesign: SELLER_CUTOFF already exists as a phase and returns NULLs.

THE PHASES, in the order they happen:
  ORIGINATION          the loan was written            -- asset index only, NULL today
  REGISTRATION  the servicer opened a file      -- DIM_NPL_CASE
  SELLER_CUTOFF        the seller's diligence cut      -- asset index only, NULL today
  LEGACY_ACQUISITION   the previous owner bought the batch
  BROCC_ACQUISITION    Brocc bought the portfolio
  LATEST               the most recent snapshot        -- the anchor for "now"

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

⚠⚠ THREE COLUMNS DESCRIBE A PHASE, AND THEY ANSWER DIFFERENT QUESTIONS.
  PHASE_ENTITY  WHO did it     -- 'Brocc', 'Intrum', a vehicle, a seller
  PHASE_STATUS  WHAT KIND      -- ACQUISITION / REGISTRATION / SERVICING / ...
  PHASE_TYPE    WHICH ONE      -- the specific event, e.g. BROCC_ACQUISITION
⚠ PHASE_STATUS IS THE ONE TO FILTER ON for "every purchase" or "every
registration", because it groups events of the same kind whoever did them:
BROCC_ACQUISITION and LEGACY_ACQUISITION are both ACQUISITION. PHASE_TYPE stays
because the two are NOT interchangeable -- they are different purchases by
different parties, and a filter on status alone would sum them together.

⚠⚠ phase_status = 'ACQUISITION' MATCHES TWO PHASES, not one: LEGACY_ACQUISITION
(the previous owner's purchase) and BROCC_ACQUISITION (ours). Filtering on the
status alone therefore returns TWO ROWS PER LOAN, and summing a balance across
them double-counts every loan. Filter on phase_type when you want one event.

⚠⚠⚠ THIS COVERS LOANS ON BOOK AT THE LATEST SNAPSHOT, NOT EVERY LOAN.
21,883,446 of the 22,530,117 in DIM_NPL_CASE. The other 925,003 (4.1%) are not
on any portfolio's newest file -- closed, sold on, or simply absent -- and get
NO ROWS AT ALL, not rows with NULLs.
⚠ SO A LEFT JOIN FROM dim_npl_platinum_case SILENTLY DROPS 4.1% OF LOANS. That
is the right behaviour for "what is true of this loan now", and the wrong
behaviour for "every loan we have ever held". Check which question you are
asking before joining.

⚠⚠ ONLY REGISTRATION BELONGS TO THE LOAN. The other dates are INHERITED: nobody
buys one loan, they buy a batch or a bundle. LEGACY_ACQUISITION is its batch's
date and BROCC_ACQUISITION is its portfolio's, repeated onto every loan inside.
PHASE_GRAIN says which, so a reader cannot mistake an inherited date for a fact
about that loan.

⚠⚠ THE BALANCE AT A PHASE IS ONLY AVAILABLE WHERE A SNAPSHOT EXISTS.
FCT_NPL_CASE_SNAPSHOT_DAILY starts 2014-06-30 (147 month-ends, all EOM).
Registration is usually years earlier, so at REGISTRATION there is no
dated balance at all -- only ORIGINAL_PRINCIPAL, which is the servicer's
recorded figure and NOT a balance as at that day. HAS_SNAPSHOT_FLAG separates
the two cases. Brocc acquisitions all fall 2025-12..2026-08, so those phases are
always covered.

⚠⚠ THERE IS NO INSOLVENCY STAGE IN THIS WAREHOUSE. STATUS_DESCRIPTION,
CLOSING_CODE, CLOSING_DESCRIPTION and CLOSING_CATEGORY are 100% NULL on all
22.5m rows. What DOES exist, and is point-in-time, is FORBEARANCE_FLAG on the
snapshot -- 5,498,592 loans carry it at the latest day. So IS_FORBEARANCE_FLAG
is real and IS_INSOLVENCY_FLAG is a reserved NULL until the asset index lands.
⚠ STATUS_CODE is decoded from Intrum's own 103-code list and names the ACTION
the servicer recorded. It is not a legal stage. Do not present it as one.

⚠ THE STATUS IS THE VERSION IN FORCE AT THE PHASE DATE, not today's. DIM_NPL_CASE
is an SCD; the row whose effective window contains the phase date is used.

⚠ REGISTRATION_DATE IS NOT STABLE. It moves across versions on 4,476,245 cases
(19.9%) by an average of 1,142 days, and every one of those moves happens WITHIN
the same reporting system -- so it is one servicer restating its own date, not a
second servicer registering the loan. A vintage cut on this phase will shift
between runs.
*/

WITH status_code_lookup AS (
    -- ⚠⚠ INTRUM'S OWN 103 MAIN STATUS CODES, inlined. There is no status
    -- dictionary in the warehouse: DIM_NPL_CASE.STATUS_DESCRIPTION is 100% NULL
    -- on all 22.5m rows, as are CLOSING_CODE, CLOSING_DESCRIPTION and
    -- CLOSING_CATEGORY. This list came from Intrum and is held at
    -- work/italy-legal/main_status_code.csv.
    -- ⚠ IN brocc-data THIS SHOULD BE A SEED, not a VALUES block. It is inlined
    -- here only so the generated Snowflake copy runs without one.
    SELECT * FROM VALUES
        ('0', 'Registered', 'Case has been registered in system, no action taken yet.'),
        ('1', 'Demand action', 'Demand has been sent/made to debtor.'),
        ('2', 'Legal actions', 'Legal action has been initiated against debtor.'),
        ('3', 'Enforcement application to bailiff', 'Application for enforcement sent to bailiff/court.'),
        ('4', 'Solvency assessment', 'Solvency of debtor being evaluated.'),
        ('5', 'Renewed foreclosure', 'Foreclosure process started again (on case that has previously been in foreclosure).'),
        ('6', 'Completed', 'Case has been completed (closed, withdrawn...), no more actions planned.'),
        ('7', 'Case is �?locked’ for invoicing', 'No invoicing to take place for case.'),
        ('8', 'Invoiced', 'Case has been invoiced.'),
        ('9', 'Case invalid', 'The case has become invalid (will be deleted from the Intrum Web).'),
        ('10', 'Reminder case', 'Case for which reminders will be sent (not yet collection case).'),
        ('11', 'Legal demand for payment', 'Legal demand for payment sent.'),
        ('12', 'Bankruptcy or debt adjustment', 'Debtor is bankrupt or in debt restructuring.'),
        ('16', 'Transferred to debt collection', 'Case transferred to debt collection (from other process, for example, debt surveillance).'),
        ('20', 'Deceased', 'Debtor is dead.'),
        ('21', 'Debtor abroad', 'Debtor has moved abroad.'),
        ('22', 'Notice of international collection', 'Notice sent to debtor about international collection case.'),
        ('23', 'Settlement payment plan', 'Settlement has been made on a payment plan.'),
        ('24', 'Settlement', 'Settlement has been made on a case.'),
        ('25', 'Execution of enforcement', 'Case is being enforced by bailiff.'),
        ('26', 'Partial payment, case at bailiff', 'Case partially paid while at bailiff.'),
        ('27', 'Part payment during legal actions', 'Case partially paid while legal actions are being taken.'),
        ('28', 'Legal actions', 'Legal action has been initiated against debtor.'),
        ('29', 'Payment plan', 'A payment plan is in effect for the case.'),
        ('30', 'Notice of collection measures', 'Demand has been sent/made to debtor.'),
        ('31', 'Correspondence', 'Discussions via letter with debtor regarding debt.'),
        ('32', 'Address missing', 'No address available for debtor.'),
        ('33', 'Address protected', 'Address of debtor has special "protected" status.'),
        ('34', 'New address', 'Debtor has new address.'),
        ('35', 'Debt reconstruction plan', 'Debtor is in debt restructuring.'),
        ('36', 'Bankruptcy', 'Debtor is bankrupt.'),
        ('37', 'Control letter', ''),
        ('38', 'Call centre collection', 'Case being collected by call center.'),
        ('39', 'Collection letter', 'Case being collected by letter.'),
        ('40', 'SMS campaign', 'Case part of SMS campaign.'),
        ('41', 'E-mail campaign', 'Case part of e-mail campaign.'),
        ('42', 'Solvency assessment', 'Solvency of debtor being assessed.'),
        ('43', 'Collection letter', 'Case being collected by letter.'),
        ('44', 'Collection letter chain', 'A sequence of collection letters being sent for case.'),
        ('45', 'Extend the term of limitation', 'Case marked for special action to prevent it from becoming statute barred.'),
        ('46', 'Enforcement application to court', 'Enforcement application sent to the court.'),
        ('47', 'Reminder letter', 'Reminder being sent to debtor.'),
        ('48', 'Notification of destitution', 'Debtor does not have any assets, is officially recognized as without means.'),
        ('49', 'Instalment from enforcement', 'Case receives instalment payments from the enforcement of a legal case.'),
        ('50', 'Notification of payment summons', 'Payment order/summons has been requested from court for the case.'),
        ('51', 'Payment plan negotiations', 'Negotiation of payment plan ongoing with debtor.'),
        ('52', 'Amortization plan total', ''),
        ('53', 'Call centre collection', 'Case being collected by call center.'),
        ('54', 'Credit information query', 'Credit information is being requested for debtor.'),
        ('55', 'Other measures', 'Other collection measures being taken.'),
        ('56', 'Payment plan', 'A payment plan is in effect for the case.'),
        ('57', 'Address missing', 'No address available for debtor.'),
        ('58', 'Evaluation', ''),
        ('59', 'Bankruptcy', 'Debtor is bankrupt.'),
        ('60', 'Dispute', 'Case is disputed by the debtor.'),
        ('61', 'Other measures', 'Other collection measures being taken.'),
        ('62', 'Debt surveillance', 'Case is in debt surveillance.'),
        ('63', 'Statute-barred claim (limitation)', 'The case has been statute barred.'),
        ('64', 'On-going', ''),
        ('65', 'Held by client', ''),
        ('66', 'D.S.S. Case', ''),
        ('67', 'Company reorganization', ''),
        ('68', 'Case on hold', ''),
        ('69', 'Collection with threat of bankruptcy', ''),
        ('70', 'Car auction', ''),
        ('71', 'Recovery of vehicle', ''),
        ('72', 'Cancellation of instalment payment', ''),
        ('73', 'Liquidation', ''),
        ('74', 'Cancellation of contract', ''),
        ('75', 'Recovery', ''),
        ('76', 'Request for investigation', ''),
        ('77', 'Cancellation threat', ''),
        ('78', 'Eviction', ''),
        ('79', 'Invoice sent', ''),
        ('80', 'Debt monitoring', ''),
        ('81', 'Enforcement advice', ''),
        ('83', 'Application to bailiff', ''),
        ('84', 'Reopened due to reversal', ''),
        ('85', 'Putback', 'Cases are returned due to issues, i.e., credit quality issues, non-compliance with agreed upon terms etc.'),
        ('300', 'Fraud', 'Case has been determined to be the result of fraud.'),
        ('301', 'Ongoing case that will be closed due to client contract or instructions', ''),
        ('302', 'Waiting for client input or confirmation', ''),
        ('303', 'Performing contact information search', 'Search for address and/or telephone number.'),
        ('304', 'Debtor requests additional information', ''),
        ('305', 'Documentation received', ''),
        ('306', 'Not possible to collect debt', 'Debt not possible to collect. There could be different reasons.'),
        ('307', 'No grounds for collection', 'Debt is not collectible, for example, because it has been zeroed out by credit notes or expired.'),
        ('308', 'Case handled manually', 'Automatic actions have been completed or case needs to be evaluated by a case handler.'),
        ('309', 'Case sent to external partner for handling', 'External partner could be field collector, attorney, and so forth.'),
        ('310', 'Debtor claims to have paid', 'Verification needed that payment has taken place.'),
        ('311', 'Promise to pay from debtor', ''),
        ('312', 'Partial payment made', ''),
        ('313', 'Settlement offer', ''),
        ('314', 'Debtor does not have phone', ''),
        ('315', 'Restructuring of debt', 'Restructuring or renegotiation of debt (may be a voluntary action as opposed to code 12).'),
        ('316', 'Adjustment of payments/cost on case', ''),
        ('317', 'Case is pending (waiting)', 'Case is waiting for a decision, waiting for a new address, or some other event.'),
        ('318', 'Communication with client', 'Information transmitted to/from the client (letters, e-mails...).'),
        ('700', 'Archive a case', 'The case data will not be considered in any reporting or extraction, but will remain in the database.'),
        ('701', 'Anonymize and Archive a case', 'http://confluence.intrum.net/display/CAT/9000+Service+Action+Record'),
        ('703', 'Unlink a case', 'http://confluence.intrum.net/display/CAT/9000+Service+Action+Record'),
        ('711', 'Anonymize and Archive a case', 'Same as 701, but for internal use only. Introduced to distinguish production system requests and Catalyst internal requests.'),
        ('713', 'Unlink a case', 'Same as 703, but for internal use only. Introduced to distinguish production system requests and Catalyst internal requests.')
    AS t(status_code, status_description, status_comment)
),

case_version AS (
    SELECT
        case_bk,
        case_sk,
        status_code,
        status_date::DATE                              AS status_date,
        effective_from_date::DATE                      AS effective_from_date,
        is_current_flag
    FROM PROD.NPL_COMMON.DIM_CASE
),

version_with_previous AS (
    -- ⚠ ORDERED BY EFFECTIVE_FROM_DATE, the warehouse's own sequence. Ordering
    -- by STATUS_DATE would reorder spells wherever the servicer backdated one.
    SELECT
        case_bk,
        case_sk,
        status_code,
        status_date,
        effective_from_date,
        is_current_flag,
        -- ⚠ NULLS FIRST IS LOAD-BEARING -- see the header on the 1,466 rows.
        LAG(status_code) OVER (
            PARTITION BY case_bk ORDER BY effective_from_date NULLS FIRST, case_sk
        )                                              AS previous_status_code,
        ROW_NUMBER() OVER (
            PARTITION BY case_bk ORDER BY effective_from_date NULLS FIRST, case_sk
        )                                              AS version_sequence
    FROM case_version
),

spell_start AS (
    -- ⚠ IS DISTINCT FROM, NOT <>. A move from NULL to a code, or a code to
    -- NULL, is a real status change; <> returns NULL on those and drops them.
    SELECT
        case_bk,
        case_sk,
        status_code,
        status_date,
        effective_from_date                            AS spell_start_date,
        previous_status_code,
        is_current_flag
    FROM version_with_previous
    WHERE version_sequence = 1
       OR status_code IS DISTINCT FROM previous_status_code
),

spell_bounded AS (
    -- ⚠ THE SPELL'S END IS THE NEXT SPELL'S START. Computed here, not in the
    -- final select, so the flags below can test it -- a Snowflake alias cannot
    -- be reused by another window function in the same SELECT.
    SELECT
        s.*,
        LEAD(s.spell_start_date) OVER (
            PARTITION BY s.case_bk
            ORDER BY s.spell_start_date NULLS FIRST, s.case_sk
        )                                              AS spell_end_date,
        ROW_NUMBER() OVER (
            PARTITION BY s.case_bk
            ORDER BY s.spell_start_date NULLS FIRST, s.case_sk
        )                                              AS spell_sequence
    FROM spell_start AS s
),

fct_npl_platinum_case_status AS (
SELECT
    -- ---- keys ---------------------------------------------------------------
    s.case_bk,
    -- The version in force when the spell opened.
    s.case_sk,
    s.spell_sequence,

    -- ---- the change ----------------------------------------------------------
    -- ⚠ NULL on the first spell: there was nothing before it.
    s.previous_status_code,
    pl.status_description                              AS previous_status_description,
    s.status_code,
    -- ⚠ NULL where Intrum's list does not hold the code -- see the header.
    l.status_description,
    l.status_comment,
    -- ⚠ THE WAREHOUSE'S DATE. Use this to line up with a monthly fact.
    s.spell_start_date,
    -- ⚠ NULL WHILE THE SPELL IS STILL OPEN -- see the header.
    s.spell_end_date,
    DATEDIFF('DAY', s.spell_start_date,
             COALESCE(s.spell_end_date, CURRENT_DATE())) AS spell_days,
    DATE_TRUNC('MONTH', s.spell_start_date)::DATE      AS spell_start_month,
    YEAR(s.spell_start_date)                           AS spell_start_year,

    -- ⚠ THE SERVICER'S OWN DATE. Can predate SPELL_START_DATE where the
    -- servicer backdated the change.
    s.status_date,
    DATEDIFF('DAY', s.status_date, s.spell_start_date) AS reporting_lag_days,

    -- ---- flags ----------------------------------------------------------------
    s.spell_sequence = 1                               AS is_first_spell_flag,
    -- ⚠⚠ TRUE ON THE SPELL THE LOAN IS IN NOW -- EXACTLY ONE PER LOAN. Derived
    -- from the spell having no end, NOT from DIM_NPL_CASE.IS_CURRENT_FLAG: that
    -- flag marks the current VERSION, and a loan's current spell usually opened
    -- several versions ago. Using it marked only 11,999,503 of 22,530,117.
    s.spell_end_date IS NULL                           AS is_current_spell_flag,
    -- ⚠ TRUE on the 1,466 versions with no effective date -- see the header.
    s.spell_start_date IS NULL                         AS undated_version_flag,
    -- ⚠ FALSE on 'Active', 'Closed', 'Open', code 99 and NULL statuses.
    l.status_description IS NOT NULL                   AS is_status_decoded_flag
FROM spell_bounded AS s
-- ⚠ TRIM BOTH SIDES -- see the header. LEFT so an unknown code keeps its spell.
LEFT JOIN status_code_lookup AS l
    ON TRIM(l.status_code) = TRIM(s.status_code)
LEFT JOIN status_code_lookup AS pl
    ON TRIM(pl.status_code) = TRIM(s.previous_status_code)

),

portfolio_vehicle AS (
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

phase_list AS (
    -- The catalogue of events that CAN happen to a loan. A row reaches the
    -- output only where the event actually has a date -- see the WHERE at the
    -- bottom. Adding the asset index later fills ORIGINATION and SELLER_CUTOFF;
    -- it does not change this list.
    -- ⚠⚠⚠ 'LATEST' USED TO BE A PHASE HERE AND IS DELIBERATELY GONE. It was
    -- not an event that happened to the loan -- it was CURRENT STATE wearing an
    -- event's clothes, and mixing the two in one table cost three things:
    --   * it forced a FULL REBUILD every run, because LATEST moves for every
    --     loan every month while real events never change once recorded;
    --   * every loan carried a LATEST row whether or not anything had happened;
    --   * "which is most recent" was asserted by a hard-coded name instead of
    --     being read off the dates.
    -- IS_LATEST_PHASE_FLAG now derives it from PHASE_DATE instead.
    SELECT * FROM VALUES
        (1, 'ORIGINATION',         'CASE',      'ASSET_INDEX'),
        (2, 'REGISTRATION',        'CASE',      'WAREHOUSE'),
        (3, 'SELLER_CUTOFF',       'PORTFOLIO', 'ASSET_INDEX'),
        (4, 'LEGACY_ACQUISITION',  'BATCH',     'WAREHOUSE'),
        (5, 'BROCC_ACQUISITION',   'PORTFOLIO', 'WAREHOUSE')
    AS t(phase_sequence, phase_type, phase_grain, phase_source)
),

case_book AS (
    -- The loans on book at each portfolio's own latest snapshot day, with the
    -- batch they sit in. ⚠ VERIFIED 1:1 AT A POINT IN TIME: all 21,885,911
    -- portfolio-case rows have exactly one batch, zero exceptions. Across
    -- history 12,897 loans move between batches, which is why batch is not an
    -- attribute of a loan -- but at a single date it is unambiguous.
    -- ⚠⚠ COLLAPSED TO ONE ROW PER CASE_SK. 2,321 loans sit under TWO portfolios
    -- at the latest day; grouping by (case_sk, portfolio_sk) gave each of them
    -- two rows and therefore TWELVE phase rows instead of six. Measured before
    -- the fix: 131,315,466 rows against 131,300,676 distinct (case_bk,
    -- phase_type) -- 14,790 duplicates, enough to fail the grain test and to
    -- double those loans in any per-phase total.
    -- ⚠ ANY_VALUE picks one portfolio for those 2,321. That is a deliberate
    -- loss: this model is one row per loan per phase, and a loan in two books
    -- has no single answer. Read dim_npl_platinum_portfolio_batch if you need
    -- the pair.
    SELECT
        s.case_sk,
        ANY_VALUE(s.portfolio_sk)                      AS portfolio_sk,
        ANY_VALUE(s.batch_sk)                          AS batch_sk,
        -- ⚠ CARRIED SO THE REGISTRATION PHASE CAN NAME ITS OWN SERVICER.
        ANY_VALUE(s.reporting_system_sk)               AS reporting_system_sk,
        ANY_VALUE(s.legal_buyer_sk)                    AS legal_buyer_sk,
        MAX(s.date_day)                                AS latest_snapshot_day,
        COUNT(DISTINCT s.portfolio_sk)                 AS portfolio_count
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    INNER JOIN (
        SELECT
            portfolio_sk,
            MAX(date_day)                              AS latest_day
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY
        GROUP BY 1
    ) AS l
        ON l.portfolio_sk = s.portfolio_sk
        AND l.latest_day = s.date_day
    GROUP BY 1
),

case_base AS (
    SELECT
        d.case_bk,
        d.case_sk,
        d.case_id,
        b.portfolio_sk,
        b.batch_sk,
        -- ⚠ FALLS BACK TO THE LOAN'S OWN SYSTEM so an off-book loan still names
        -- its servicer. A case never moves reporting system, so the two agree
        -- wherever both exist.
        COALESCE(b.reporting_system_sk, d.reporting_system_sk)
                                                       AS reporting_system_sk,
        b.legal_buyer_sk,
        b.latest_snapshot_day,
        b.portfolio_count,
        b.case_sk IS NOT NULL                          AS is_on_latest_book_flag,
        -- ⚠⚠ CLOSING_DESCRIPTION AND CLOSING_CATEGORY ARE 100% NULL in PROD
        -- (measured 2026-09-27, all 22,530,117 current loans) -- do not reach
        -- for them. CLOSING_CODE is populated on 9,263,268 loans across 47
        -- codes, but nothing in the warehouse decodes it yet.
        d.closing_date,
        d.closing_code,
        -- ⚠ WHEN THE WAREHOUSE LAST TOUCHED THIS LOAN'S RECORD. Not when the
        -- event happened -- PHASE_DATE is that. Use this to spot rows that have
        -- gone stale, and as the watermark for an incremental build.
        d.as_of_ts                                     AS source_updated_at,
        d.registration_date::DATE                      AS registration_date,
        d.original_principal
    -- ⚠⚠⚠ DRIVEN FROM DIM_NPL_CASE, NOT FROM THE BOOK. This was an INNER JOIN
    -- onto the latest snapshot, which silently dropped the 925,003 loans that
    -- no longer appear on any portfolio's newest file -- and those are exactly
    -- the closed and sold-on loans a liquidation-by-vintage curve is measuring.
    -- Excluding them biased every vintage downward, worst on the oldest
    -- vintages, which have had the most time to close.
    -- ⚠ Off-book loans now get their phase rows with NULL balances, the same
    -- way pre-2014 phases already behave. IS_ON_LATEST_BOOK_FLAG tells them
    -- apart; nothing is dropped any more.
    FROM PROD.NPL_COMMON.DIM_CASE AS d
    LEFT JOIN case_book AS b
        ON b.case_sk = d.case_sk
    WHERE d.is_current_flag = TRUE
),

case_phase AS (
    -- ⚠ CROSS JOIN ON PURPOSE. Every loan gets every phase, so an unknown date
    -- is a row with a NULL, not a missing row -- see the header.
    SELECT
        c.case_bk,
        c.case_sk,
        c.case_id,
        c.portfolio_sk,
        c.batch_sk,
        c.reporting_system_sk,
        c.legal_buyer_sk,
        c.portfolio_count,
        c.is_on_latest_book_flag,
        c.closing_date,
        c.closing_code,
        p.phase_sequence,
        p.phase_type,
        p.phase_grain,
        p.phase_source,
        c.original_principal,
        c.source_updated_at,
        c.latest_snapshot_day,
        CASE p.phase_type
            WHEN 'REGISTRATION' THEN c.registration_date
            WHEN 'LEGACY_ACQUISITION'  THEN bt.legacy_capex_date::DATE
            WHEN 'BROCC_ACQUISITION'   THEN po.capex_date::DATE
            -- ORIGINATION and SELLER_CUTOFF are asset-index phases.
            ELSE NULL
        END                                            AS phase_date
    FROM case_base AS c
    CROSS JOIN phase_list AS p
    LEFT JOIN PROD.NPL_COMMON.DIM_BATCH AS bt
        ON bt.batch_sk = c.batch_sk
    LEFT JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS po
        ON po.portfolio_sk = c.portfolio_sk
),

snapshot_at_phase AS (
    -- ⚠ RESTRICTED TO THE MONTH-ENDS THAT ARE ACTUALLY PHASE DATES. The
    -- snapshot is 1.47bn rows; without this predicate every phase lookup would
    -- scan the lot.
    -- ⚠⚠ AGGREGATED TO ONE ROW PER (CASE_BK, DATE_DAY). The snapshot carries one
    -- row per portfolio, and 2,321 loans sit under TWO portfolios on the same
    -- day -- so joining it raw doubled those phase rows and gave each copy only
    -- one book's slice of the balance. Measured: 318 duplicate (case_bk,
    -- phase_type) keys before this GROUP BY.
    -- ⚠ SUM, not ANY_VALUE: a loan split across two books is exposed in both,
    -- so its outstanding is the total of the two, not either one.
    -- ⚠⚠⚠ KEYED ON CASE_BK, NOT CASE_SK -- AND THIS COSTS A JOIN ON PURPOSE.
    -- CASE_SK is the VERSION key. The spine carries the CURRENT version, while
    -- a snapshot row from a past month carries whatever version was current
    -- THEN, so matching on it silently misses every loan restated since.
    -- Measured 2026-09-28 on HEI-ES25001-U01/2512, 3,234,302 loans whose
    -- registration falls inside the book's coverage: joining on CASE_SK found
    -- 1,070 balances, joining on CASE_BK found 1,026,764 -- a 960x undercount
    -- that reads as "we have no history" rather than as an error.
    -- ⚠ IT LOOKED FINE because BROCC_ACQUISITION is recent (Dec 2025): few
    -- loans have been restated since, so the version key still matched there
    -- and only the older phases came back empty.
    -- ⚠ SAFE TO KEY ON CASE_BK: a loan never has two versions on book at the
    -- same month-end (verified, max 1), so (case_bk, date_day) stays unique.
    SELECT
        dv.case_bk,
        s.date_day,
        SUM(s.outstanding_principal)                   AS outstanding_principal,
        SUM(s.outstanding_interest)                    AS outstanding_interest,
        SUM(s.outstanding_fees)                        AS outstanding_fees,
        SUM(s.outstanding_total)                       AS outstanding_total,
        BOOLOR_AGG(s.forbearance_flag)                 AS forbearance_flag,
        -- ⚠⚠ THE VEHICLE KEY AS AT THAT DAY, not the current one. 14
        -- portfolios carry two LEGAL_BUYER_SK values -- but NOT because they
        -- changed vehicle. Measured in PROD 2026-09-27: in all 14 the vehicle
        -- NAME is identical in both, and no portfolio anywhere carries two
        -- different names. LEGAL_BUYER_SK is keyed on name PLUS the date the
        -- ownership share began, so a stake change (0.65 -> 1.00 on
        -- 2026-07-01, 0.95 -> 1.00 on 2026-01-01) mints a new key for the
        -- same company. Resolving as at the phase date gets the SHARE right,
        -- which is the real reason to do it.
        -- ⚠ THE OLD KEY RUNS ON BESIDE THE NEW ONE on 13 of the 14, so a
        -- portfolio holds both in the same month. On HEI-ES25001-U01/2512 at
        -- 2026-08-31 the split is the platform split: 3,480,727 CAT Scale
        -- loans keep the 0.65 key while 3,228,479 CAT Fenix loans carry the
        -- 1.00 one. The legacy platform never picked up the new share, so
        -- OWNERSHIP_SHARE IS STALE ON THOSE LOANS.
        ANY_VALUE(s.legal_buyer_sk)                    AS legal_buyer_sk_at_phase
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
    -- ⚠ THE PRICE OF THE FIX: the snapshot only carries CASE_SK, so resolving
    -- the durable key needs the case dimension. Restricted to phase month-ends
    -- above, which is what keeps it affordable.
    INNER JOIN PROD.NPL_COMMON.DIM_CASE AS dv
        ON dv.case_sk = s.case_sk
    WHERE s.date_day IN (SELECT DISTINCT LAST_DAY(phase_date)
                         FROM case_phase
                         WHERE phase_date IS NOT NULL)
    GROUP BY 1, 2
),

status_at_phase AS (
    -- ⚠ THE STATUS SPELL IN FORCE AT THE PHASE DATE, taken from the spell model
    -- rather than re-deriving it here: that model already collapses consecutive
    -- identical codes and carries Intrum's 103-code decode. Using DIM_NPL_CASE
    -- directly would return one row per SCD version, most of which change
    -- something other than status.
    SELECT
        case_bk,
        status_code,
        status_description,
        spell_start_date,
        spell_end_date
    FROM fct_npl_platinum_case_status
)

SELECT
    -- ---- keys ---------------------------------------------------------------
    cp.case_bk,
    cp.case_sk,
    cp.case_id,
    cp.portfolio_sk,
    -- ⚠ THE BATCH AT THE LATEST SNAPSHOT. Unambiguous at a point in time.
    cp.batch_sk,
    -- ⚠ ABOVE 1 MEANS THE LOAN SITS IN TWO BOOKS and PORTFOLIO_SK above is one
    -- of two possible answers. 2,321 loans.
    cp.portfolio_count,

    -- ---- the phase -----------------------------------------------------------
    -- ⚠ CHRONOLOGICAL, and never NULL: the WHERE at the bottom keeps only rows
    -- that actually have a date, so 1 is always this loan's first known event.
    ROW_NUMBER() OVER (PARTITION BY cp.case_bk
                       ORDER BY cp.phase_date, cp.phase_sequence)
                                                       AS phase_order,
    -- ⚠⚠ THE MOST RECENT THING WE KNOW HAPPENED TO THIS LOAN -- derived from
    -- the dates, not asserted by a phase called 'LATEST'. This is what replaced
    -- that phase; see the note on the spine above.
    ROW_NUMBER() OVER (PARTITION BY cp.case_bk
                       ORDER BY cp.phase_date DESC, cp.phase_sequence DESC) = 1
                                                       AS is_latest_phase_flag,
    -- ⚠ HOW MANY EVENTS WE HOLD FOR THIS LOAN. 1 means the history is a single
    -- point, so treat any trend drawn from it with suspicion.
    COUNT(*) OVER (PARTITION BY cp.case_bk)            AS phase_count,
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
    -- ⚠⚠ RESOLVED PER ROW, NEVER ASSUMED. The servicer on a REGISTRATION row is
    -- whichever one that loan's reporting system belongs to -- Intrum on most
    -- books, Gescobro or Cerved on others. Hard-coding a name into the phase
    -- would make it lie on every other book. NULL on the asset-index phases.
    -- ⚠⚠ TITLE-CASED, BUT ONLY WHERE THE SOURCE IS ALL LOWER CASE. The servicer
    -- names arrive lowercase ('intrum', 'gescobro') while the vehicle names
    -- arrive correctly cased and full of acronyms -- INITCAP would turn
    -- 'Intrum Debt Finance AG' into '... Ag' and 'Rubicon SPV S.r.l' into
    -- '... Spv S.R.L'. So only strings that are entirely lower case are
    -- touched; anything already carrying capitals is left exactly as it is.
    -- ⚠⚠ TITLE-CASED ONLY WHERE THE SOURCE ARRIVES LOWER CASE. Measured
    -- 2026-09-27: 23 of 24 SERVICER_NAME values are all lower ('intrum',
    -- 'gescobro'), but 0 of 26 LEGAL_BUYER_NAME values are -- they are properly
    -- cased and full of acronyms, so INITCAP would turn 'Intrum Debt Finance
    -- AG' into '... Ag' and 'Rubicon SPV S.r.l' into '... Spv S.R.L'.
    -- ⚠ The IFF guard means a name that already carries capitals is never
    -- touched, which also leaves the literal 'Unknown' alone.
    -- ⚠ THE 'LATEST' BRANCH IS GONE WITH THE PHASE -- see the spine note above.
    CASE cp.phase_type
        WHEN 'REGISTRATION'       THEN IFF(rs.servicer_name = LOWER(rs.servicer_name), INITCAP(rs.servicer_name), rs.servicer_name)
        WHEN 'BROCC_ACQUISITION'  THEN lb.legal_buyer_name
        WHEN 'LEGACY_ACQUISITION' THEN 'Legacy'
        WHEN 'SELLER_CUTOFF'      THEN IFF(pf.seller_name = LOWER(pf.seller_name), INITCAP(pf.seller_name), pf.seller_name)
        ELSE NULL
    END                                                AS phase_entity,
    -- ⚠ WHAT KIND. Filter on this for "every purchase" regardless of buyer.
    CASE cp.phase_type
        WHEN 'ORIGINATION'        THEN 'ORIGINATION'
        WHEN 'REGISTRATION'       THEN 'REGISTRATION'
        WHEN 'SELLER_CUTOFF'      THEN 'CUTOFF'
        WHEN 'LEGACY_ACQUISITION' THEN 'ACQUISITION'
        WHEN 'BROCC_ACQUISITION'  THEN 'ACQUISITION'
        WHEN 'LATEST'             THEN 'SNAPSHOT'
    END                                                AS phase_status,
    -- ⚠ WHAT KIND OF PARTY PHASE_ENTITY IS -- shared with the portfolio model.
    CASE cp.phase_type
        WHEN 'REGISTRATION'       THEN 'SERVICER'
        WHEN 'LATEST'             THEN 'SERVICER'
        WHEN 'BROCC_ACQUISITION'  THEN 'VEHICLE'
        WHEN 'LEGACY_ACQUISITION' THEN 'OWNER'
        WHEN 'SELLER_CUTOFF'      THEN 'SELLER'
        ELSE NULL
    END                                                AS phase_entity_type,
    -- ⚠⚠ THE PLATFORM THE LOAN IS REGISTERED ON, e.g. 'CAT Fenix'. It is part
    -- of CASE_BK, so when Intrum migrates a book to a new platform the same
    -- debt is issued a NEW CASE_BK with a NEW registration date and nothing
    -- links the two. See the README on double-counted vintages.
    rs.reporting_system_name                           AS phase_system,
    -- ⚠ 'CASE' means the date belongs to this loan. 'BATCH' and 'PORTFOLIO' mean
    -- it is INHERITED and identical across every loan in that batch or book.
    cp.phase_grain,
    cp.phase_source,
    cp.phase_date,
    DATE_TRUNC('MONTH', cp.phase_date)::DATE           AS phase_month,
    YEAR(cp.phase_date)                                AS phase_year,

    -- ---- what was true at that date. NULL where no snapshot exists. ---------
    sn.outstanding_principal                           AS balance_principal,
    sn.outstanding_interest                            AS balance_interest,
    sn.outstanding_fees                                AS balance_fees,
    sn.outstanding_total                               AS balance_total,
    -- ⚠ NOT A BALANCE AS AT THE PHASE DATE. The servicer's recorded principal,
    -- carried so REGISTRATION has a money figure at all.
    cp.original_principal,

    -- ---- distress at that date ----------------------------------------------
    -- ⚠ REAL AND POINT-IN-TIME. 5,498,592 loans carry it at the latest day.
    COALESCE(sn.forbearance_flag, FALSE)               AS is_forbearance_flag,
    -- ⚠⚠ RESERVED, ALWAYS NULL TODAY. No insolvency stage exists in this
    -- warehouse; the asset index has bankruptcy, debt_restructuring and
    -- insolvency_restructuring and will fill this when it reaches PROD.
    NULL                                               AS is_insolvency_flag,
    NULL                                               AS insolvency_status,

    -- ---- status in force at that date ---------------------------------------
    st.status_code,
    -- ⚠ THE ACTION THE SERVICER RECORDED, not a legal stage.
    st.status_description,

    -- ---- is the loan still live? ---------------------------------------------
    -- ⚠⚠⚠ TWO INDEPENDENT SIGNALS THAT DISAGREE ON 9.77m LOANS. Measured
    -- 2026-09-27 over the 22,530,117 current loans:
    --     on a file + no closing date   12,547,584   unambiguously live
    --     on a file + closing date       9,057,528   marked closed, STILL REPORTED
    --     off the file + closing date      212,471   unambiguously done
    --     off the file + no closing date   712,534   vanished, never marked
    -- ⚠⚠ SO "STILL ON A FILE" IS NOT THE SAME AS "OPEN". The servicers keep
    -- reporting closed cases, which is why CASE_STATUS below is driven by the
    -- servicer's own closing date and NOT by presence on the file.
    -- ⚠ The 712,534 that vanished without a closing date are a real gap: they
    -- read as OPEN here because nothing says otherwise. Treat a count of open
    -- loans as an upper bound, and say so when you quote one.
    CASE WHEN cp.closing_date IS NOT NULL THEN 'CLOSED' ELSE 'OPEN' END
                                                       AS case_status,
    -- ⚠⚠ DIRTY AT BOTH ENDS: the range runs 1947-07-10 to 2026-12-26, so some
    -- dates are in the FUTURE. Bound it before bucketing by close year.
    cp.closing_date,
    -- ⚠ 47 distinct values, undecoded -- see the note in case_base.
    cp.closing_code,
    -- ⚠ FALSE means the loan is on no portfolio's newest file. Report it
    -- alongside CASE_STATUS rather than instead of it: they are different
    -- questions and the table above shows how often they diverge.
    cp.is_on_latest_book_flag,

    -- ---- provenance -----------------------------------------------------------
    -- ⚠ WHEN THE RECORD WAS LAST TOUCHED, not when the event happened.
    cp.source_updated_at,
    -- ⚠ THE NEWEST FILE THIS LOAN APPEARED ON. Kept as an attribute rather than
    -- as a phase row -- appearing on a file is not an event.
    cp.latest_snapshot_day,

    -- ---- flags ----------------------------------------------------------------
    -- ⚠ FALSE where the phase predates the snapshot (2014-06-30), so every
    -- balance above is NULL for a structural reason rather than a data gap.
    sn.case_bk IS NOT NULL                             AS has_snapshot_flag
FROM case_phase AS cp
LEFT JOIN PROD.NPL_COMMON.DIM_REPORTING_SYSTEM AS rs
    ON rs.reporting_system_sk = cp.reporting_system_sk
LEFT JOIN dim_npl_platinum_portfolio AS pf
    ON pf.portfolio_sk = cp.portfolio_sk
-- ⚠⚠ CASE_BK, NOT CASE_SK -- see the header on snapshot_at_phase. Matching on
-- the version key missed every loan restated since the phase date.
LEFT JOIN snapshot_at_phase AS sn
    ON sn.case_bk = cp.case_bk
    AND sn.date_day = LAST_DAY(cp.phase_date)
-- ⚠ AT-PHASE VEHICLE FIRST, current one only as a fallback for phases with no
-- snapshot (anything before 2014-06-30, and the undated phases).
LEFT JOIN PROD.NPL_COMMON.DIM_LEGAL_BUYER AS lb
    ON lb.legal_buyer_sk = COALESCE(sn.legal_buyer_sk_at_phase, cp.legal_buyer_sk)
-- ⚠ THE SPELL WHOSE WINDOW CONTAINS THE PHASE DATE. An open spell has a NULL
-- end, so it must be tested with IS NULL and not an inequality.
LEFT JOIN status_at_phase AS st
    ON st.case_bk = cp.case_bk
    AND cp.phase_date >= st.spell_start_date
    AND (st.spell_end_date IS NULL OR cp.phase_date < st.spell_end_date)
-- ⚠⚠⚠ DENSE: A ROW MEANS SOMETHING HAPPENED. Phases with no date produce no
-- row at all, rather than a placeholder full of NULLs. That drops roughly 45m
-- empty ORIGINATION and SELLER_CUTOFF rows, which were storing a six-row fact
-- ("these phases exist, we lack the data") twenty-two million times over.
-- ⚠ THE COST: browsing the table no longer shows you what is MISSING. The
-- catalogue of phases that *should* exist lives in the phase_list CTE above and
-- in models.yml -- check there before concluding a loan has no origination.
WHERE cp.phase_date IS NOT NULL
