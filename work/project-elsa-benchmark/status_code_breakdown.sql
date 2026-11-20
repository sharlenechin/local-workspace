-- ============================================================================
-- status_code_breakdown — loans per MAIN_STATUS_CODE, decoded, with a workout
-- track. Portugal / Millennium (Project Elsa), Intrum instance 4050.
--
--   RUN      mise run sql -- work/project-elsa-benchmark/status_code_breakdown.sql
--            datalake.q("project-elsa-benchmark/status_code_breakdown")
--   GRAIN    one row per STATUS_CODE, plus explicit rows for loans with no
--            code and no PROD row. Nothing is dropped.
--   RUNTIME  ~40s.  Money is EUR, unconverted (the book is EUR throughout).
--   SOURCE   raw CAT feed for the scope, PROD.DIM_CASE for the code.
--
-- ============================================================================
-- THE DICTIONARY — provenance matters, read this before quoting a label
-- ============================================================================
-- 103 codes, supplied by Sharlene on 2026-09-15 from Intrum's own CAT lookup
-- (`lookup.main_status_code`, kept at ~/Downloads/main_status_code.sql). It is
-- INTRUM'S OWN mapping, not a guess: all 25 codes present on this book resolve,
-- so decoding is 100% and no code falls through to "unmapped".
--   → It is inlined below rather than referenced, so this file runs standalone.
--   → It belongs in `brocc-data` as a dbt SEED so every model can use it. That
--     is a separate Rule 1 request; do not add it from here.
--
-- ⚠ THE WORKOUT TRACK IS OURS, THE DESCRIPTIONS ARE INTRUM'S. `description`
--   is quotable as Intrum's own wording. `workout_track` is a grouping WE
--   applied to those descriptions — defensible, but not blessed by Intrum, and
--   some calls are judgement (code 69 "Collection with threat of bankruptcy"
--   is a threat, not a filed insolvency; code 49 "Instalment from enforcement"
--   is money arriving out of a legal process). Say which is which when asked.
--
-- ⚠ "On-going" (code 64) IS 59.864% OF THE BOOK AND SAYS NOTHING ABOUT TRACK.
--   Decoding the dictionary does NOT deliver an amicable/legal split: the
--   dominant code means only "active". See the note under Other below.
--
-- ⚠ STATUS_CODE IS A CURRENT VALUE, NOT A HISTORY. It cannot say what a case
--   was doing at an earlier date. CASE_STATUS_CHANGE_HISTORY would, and
--   delivers ZERO rows for instance 4050 (measured 2026-09-14).
--
-- ⚠ STATUS_DATE is returned so staleness is visible. Code 64 is 100% dated and
--   the newest is 2017-01-10; Brocc acquired the book 2025-12-01, so the
--   dominant code was last touched eight years before we owned it.
--
-- GUARDS
--   G1 CASES is a change-history feed (17.8m rows for 120,713 loans) —
--      deduped to the latest version per CASE_ID, or counts multiply ~147x.
--   G2 The batch filter runs BEFORE the qualify, so a loan whose newest
--      version left the scope keeps its last in-scope batch.
--   G3 CASE_ID is unique only within a source system — _file_path pinned to
--      instance 4050 as a LITERAL PREFIX (no leading %, or pruning is lost).
--   G4 All extracts are read: the newest is a delta.
--   G5 Container cases (hyphenated CASE_ID) dropped.
--   G6 LEFT join to DIM_CASE, so loans absent from PROD are counted, not lost.
--   G7 IS_CURRENT_FLAG, joined on CASE_BK. ⚠ NOT on CASE_SK — CASE_SK is a
--      VERSION key (11,592,311 versions for 1,156,733 cases on 4050, 10.02
--      each). Joining a fact on case_sk AND is_current_flag drops ~95% of rows
--      silently. CASE_BK + is_current_flag is one row per case; asserted.
--   G8 STATUS_CODE IS TRIMMED — a data-quality workaround, not cosmetics.
--      Some values carry a TRAILING SPACE, so one code arrives as two strings:
--      '2' on 3,227 cases and '2 ' on 170, '38' on 69 and '38 ' on 5.
--      Ungrouped, codes 2 and 38 appear twice and every share is understated.
--      → Report to the data team: the trim belongs in staging, not here.
--
-- ⚠ PROD + RAW. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set country       = 'PT';
set seller        = 'MILLENNIUM';   -- case-insensitive; both casings exist
set source_system = '4050';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


-- Intrum's own lookup. Codes are TEXT: '06' and '6' are different codes.
with code_dictionary (code, description) as (
    select * from values
        ('0', 'Registered'),
        ('1', 'Demand action'),
        ('2', 'Legal actions'),
        ('3', 'Enforcement application to bailiff'),
        ('4', 'Solvency assessment'),
        ('5', 'Renewed foreclosure'),
        ('6', 'Completed'),
        ('7', 'Case is locked for invoicing'),
        ('8', 'Invoiced'),
        ('9', 'Case invalid'),
        ('10', 'Reminder case'),
        ('11', 'Legal demand for payment'),
        ('12', 'Bankruptcy or debt adjustment'),
        ('16', 'Transferred to debt collection'),
        ('20', 'Deceased'),
        ('21', 'Debtor abroad'),
        ('22', 'Notice of international collection'),
        ('23', 'Settlement payment plan'),
        ('24', 'Settlement'),
        ('25', 'Execution of enforcement'),
        ('26', 'Partial payment, case at bailiff'),
        ('27', 'Part payment during legal actions'),
        ('28', 'Legal actions'),
        ('29', 'Payment plan'),
        ('30', 'Notice of collection measures'),
        ('31', 'Correspondence'),
        ('32', 'Address missing'),
        ('33', 'Address protected'),
        ('34', 'New address'),
        ('35', 'Debt reconstruction plan'),
        ('36', 'Bankruptcy'),
        ('37', 'Control letter'),
        ('38', 'Call centre collection'),
        ('39', 'Collection letter'),
        ('40', 'SMS campaign'),
        ('41', 'E-mail campaign'),
        ('42', 'Solvency assessment'),
        ('43', 'Collection letter'),
        ('44', 'Collection letter chain'),
        ('45', 'Extend the term of limitation'),
        ('46', 'Enforcement application to court'),
        ('47', 'Reminder letter'),
        ('48', 'Notification of destitution'),
        ('49', 'Instalment from enforcement'),
        ('50', 'Notification of payment summons'),
        ('51', 'Payment plan negotiations'),
        ('52', 'Amortization plan total'),
        ('53', 'Call centre collection'),
        ('54', 'Credit information query'),
        ('55', 'Other measures'),
        ('56', 'Payment plan'),
        ('57', 'Address missing'),
        ('58', 'Evaluation'),
        ('59', 'Bankruptcy'),
        ('60', 'Dispute'),
        ('61', 'Other measures'),
        ('62', 'Debt surveillance'),
        ('63', 'Statute-barred claim (limitation)'),
        ('64', 'On-going'),
        ('65', 'Held by client'),
        ('66', 'D.S.S. Case'),
        ('67', 'Company reorganization'),
        ('68', 'Case on hold'),
        ('69', 'Collection with threat of bankruptcy'),
        ('70', 'Car auction'),
        ('71', 'Recovery of vehicle'),
        ('72', 'Cancellation of instalment payment'),
        ('73', 'Liquidation'),
        ('74', 'Cancellation of contract'),
        ('75', 'Recovery'),
        ('76', 'Request for investigation'),
        ('77', 'Cancellation threat'),
        ('78', 'Eviction'),
        ('79', 'Invoice sent'),
        ('80', 'Debt monitoring'),
        ('81', 'Enforcement advice'),
        ('83', 'Application to bailiff'),
        ('84', 'Reopened due to reversal'),
        ('85', 'Putback'),
        ('300', 'Fraud'),
        ('301', 'Ongoing case that will be closed due to client contract or instructions'),
        ('302', 'Waiting for client input or confirmation'),
        ('303', 'Performing contact information search'),
        ('304', 'Debtor requests additional information'),
        ('305', 'Documentation received'),
        ('306', 'Not possible to collect debt'),
        ('307', 'No grounds for collection'),
        ('308', 'Case handled manually'),
        ('309', 'Case sent to external partner for handling'),
        ('310', 'Debtor claims to have paid'),
        ('311', 'Promise to pay from debtor'),
        ('312', 'Partial payment made'),
        ('313', 'Settlement offer'),
        ('314', 'Debtor does not have phone'),
        ('315', 'Restructuring of debt'),
        ('316', 'Adjustment of payments/cost on case'),
        ('317', 'Case is pending (waiting)'),
        ('318', 'Communication with client'),
        ('700', 'Archive a case'),
        ('701', 'Anonymize and Archive a case'),
        ('703', 'Unlink a case'),
        ('711', 'Anonymize and Archive a case'),
        ('713', 'Unlink a case')
),

-- Scope: PAM collapsed to one row per batch before anything joins to it.
batches as (
    select distinct combined_ref
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path = (
              select max(_file_path)
              from RAW.HYPERION_INTRUM_PAM.PAM
              where _file_path like '%/pam.pam.pam.2%'
          )
      and pmode_name = 'Real'
      and coalesce(is_ownership_change, 0) = 0
      and countrycode like $country
      and upper(seller_name) like upper($seller)
),

-- One row per loan: its latest version, across every extract (G1-G5).
cases as (
    select
        c.case_id                          as loan_id,
        c.original_capital                 as registration_capital,
        $source_system || '-' || c.case_id as case_bk
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'   -- G3, G4
      and c.long_portfolio_id in (select combined_ref from batches)       -- G2
      and c.case_id not like '%-%'                                        -- G5
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1                                                                 -- G1
),

-- G6, G7. CASE_BK + is_current_flag, never CASE_SK.
tagged as (
    select
        s.loan_id,
        s.registration_capital,
        d.case_sk,
        trim(d.status_code)  as status_code,                              -- G8
        d.status_date::date  as status_date
    from cases as s
    left join PROD.NPL_COMMON.DIM_CASE as d
           on d.case_bk = s.case_bk
          and d.is_current_flag = true
),

book as (
    select count(*) as n_loans_total, sum(registration_capital) as capital_total
    from tagged
)

select
    case when t.case_sk is null     then '(no PROD case row)'
         when t.status_code is null then '(code is NULL)'
         else t.status_code end                        as status_code,

    -- Intrum's wording. Quotable as theirs.
    coalesce(max(cd.description), '(code not in dictionary)') as description,

    -- OURS, not Intrum's. A grouping of their descriptions. See header.
    case
        when t.case_sk is null or t.status_code is null then 'Unknown'
        when t.status_code in ('2','3','5','11','25','26','27','28','46','49',
                               '50','78','81','83')          then 'Legal / enforcement'
        when t.status_code in ('12','35','36','59','67','69','73','315')
                                                             then 'Insolvency'
        when t.status_code in ('23','24','29','51','52','56','311','312','313')
                                                             then 'Amicable / arrangement'
        when t.status_code in ('6','9','63','85','300','306','307','700','701',
                               '703','711','713')            then 'Closed / terminal'
        -- Includes 64 "On-going" = 59.864% of the book. Active, track unknown.
        else                                                      'Other / administrative'
    end                                                as workout_track,

    count(*)                                           as n_loans,
    count(*) / max(b.n_loans_total)                    as pct_of_loans,
    sum(t.registration_capital)                        as registration_capital_eur,
    sum(t.registration_capital) / max(b.capital_total) as pct_of_capital,

    min(t.status_date)                                 as status_date_first,
    max(t.status_date)                                 as status_date_last,
    count(t.status_date) / count(*)                    as status_date_filled
from tagged as t
cross join book as b
left join code_dictionary as cd on cd.code = t.status_code
group by 1, 3
order by n_loans desc;
