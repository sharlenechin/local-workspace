/*
PLATINUM. ONE ROW PER STATUS SPELL: every time a loan's status code actually
CHANGED, with the date it changed and the date it changed again.

WHY IT IS SEPARATE FROM dim_npl_platinum_case: status changes on 11,850,345 of
22,530,117 loans (52.6%), so a single table holding both the static attributes
and the history would repeat every static column on every change. The dimension
holds what is true of the loan; this holds what happened to it. Join on CASE_BK.

⚠⚠ ONE ROW PER CHANGE, NOT PER VERSION. DIM_NPL_CASE carries 154,077,844 version
rows -- 6.84 per loan -- but most versions change something other than status.
Consecutive versions holding the SAME status code are collapsed into one spell,
so a loan that was restated forty times without moving status gets one row here,
not forty.

⚠⚠ THE CODE IS DECODED HERE FROM INTRUM'S OWN LIST, not from the warehouse.
DIM_NPL_CASE.STATUS_DESCRIPTION is 100% NULL on all 22.5m rows, as are
CLOSING_CODE, CLOSING_DESCRIPTION and CLOSING_CATEGORY -- so the 103-code
mapping below, supplied by Intrum, is the only thing that gives a code meaning.
  STATUS_DESCRIPTION           e.g. 'Legal actions', 'Demand action'
  PREVIOUS_STATUS_DESCRIPTION  the same for the code it moved from
  STATUS_COMMENT               Intrum's own longer note
⚠ IT DOES NOT DECODE EVERYTHING. 89.86% of current cases match before trimming;
what is left is three word-valued statuses Intrum's list does not contain --
'Active' (1,738,634), 'Closed' (399,640) and 'Open' (51,619) -- plus code '99'
on 3 cases, and 94,590 cases with no status at all.
IS_STATUS_DECODED_FLAG marks the rows where the lookup hit.

⚠⚠ STATUS_CODE CARRIES TRAILING SPACES ON SOME ROWS and the join TRIMS both
sides. Untrimmed, '2 ' and '2' are different codes: that alone left 170 cases of
code 2, 54 of code 32, and a handful of 24, 38 and 40 undecoded, while the same
codes decoded fine on other rows. Do not remove the TRIM.

⚠ A DECODED STATUS IS STILL NOT A LEGAL STAGE. The list names the action Intrum
recorded, not whether a case is amicable, legal or insolvent. Do not present it
as a phase.

⚠ SPELL_END_DATE IS NULL ON THE CURRENT SPELL, not a far-future sentinel. Test
IS NULL for "still in this status", never an equality against a magic date.

⚠ STATUS_DATE IS THE SERVICER'S OWN DATE and does not always agree with the
version's EFFECTIVE_FROM_DATE, which is when the warehouse learned of it. Both
are emitted. Use SPELL_START_DATE (the warehouse's) for anything that has to
line up with a monthly fact; use STATUS_DATE when quoting the servicer.

⚠ A NULL STATUS_CODE IS A REAL STATE, not an absence, and is kept as one. It
counts as a change when a loan moves into or out of it.

⚠⚠ 1,466 VERSION ROWS HAVE NO EFFECTIVE_FROM_DATE, one on each of 1,466 loans.
They are ordered FIRST within their loan and flagged UNDATED_VERSION_FLAG. An
earlier build ordered them last by default, which gave those loans TWO spells
with a NULL end date and broke "one open spell per loan". If you change the
ordering, re-check that COUNT(*) WHERE spell_end_date IS NULL equals the loan
count exactly.
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
    FROM {{ ref('dim_npl_case') }}
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
)

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
