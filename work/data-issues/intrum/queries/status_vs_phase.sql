-- Does the decoded case status (DIM_CASE.STATUS_CODE, current version) agree
-- with the servicer's legal phase (GROUP_CASE_PHASE.GROUP_PHASE_CODE, latest
-- start_date per case)?  Two independent columns from the same servicer; if
-- they line up, either can drive the amicable/legal split.
--
-- Guards: phase feed filtered to deleted/archived/unlinked = 0 (soft-deleted
-- rows are still in the feed); DIM_CASE joined on CASE_BK + is_current_flag
-- (CASE_SK is a version key).  Instances with no phase feed are absent here by
-- construction; see dash_portfolio_diagnostics `has_phase_feed`.
set prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.%';

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


latest_phase as (
    select split_part(g._file_path, '.', 2)                            as instance,
           split_part(g._file_path, '.', 2) || '-' || g.case_id        as case_bk,
           max_by(g.group_phase_code, g.start_date::date)              as group_phase_code
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE as g
    where g._file_path like $prefix
      and g.group_phase_code is not null and g.start_date is not null
      and coalesce(g.deleted, 0) = 0 and coalesce(g.archived, 0) = 0
      and coalesce(g.unlinked, 0) = 0
    group by 1, 2
),

current_case as (
    select case_bk, status_code
    from PROD.NPL_COMMON.DIM_CASE
    where is_current_flag
),

joined as (
    select p.instance,
           case left(p.group_phase_code, 1)
                when 'A' then 'Amicable' when 'L' then 'Legal' when 'E' then 'Execution'
                else 'Other phase' end                             as phase,
           c.status_code,
           cd.description,
           -- OURS, not Intrum's: grouping of their descriptions (same as
           -- work/project-elsa-benchmark/status_code_breakdown.sql).
           case
               when c.case_bk is null or c.status_code is null then 'Unknown'
               when c.status_code in ('2','3','5','11','25','26','27','28','46','49',
                                      '50','78','81','83')          then 'Legal / enforcement'
               when c.status_code in ('12','35','36','59','67','69','73','315')
                                                                    then 'Insolvency'
               when c.status_code in ('23','24','29','51','52','56','311','312','313')
                                                                    then 'Amicable / arrangement'
               when c.status_code in ('6','9','63','85','300','306','307','700','701',
                                      '703','711','713')            then 'Closed / terminal'
               else                                                      'Other / administrative'
           end                                                       as workout_track
    from latest_phase as p
    left join current_case     as c  on c.case_bk = p.case_bk
    left join code_dictionary  as cd on cd.code   = c.status_code
)

-- 1. crosstab: phase x our status grouping
select 'A. phase x track' as block, phase, workout_track as status_group, null as description,
       count(*) as n_cases
from joined group by 1, 2, 3
union all
-- 2. top raw status codes inside each phase (what "Other / administrative" really is)
select 'B. top codes per phase', phase, status_code, description, n
from (
    select phase, status_code, description, count(*) as n,
           row_number() over (partition by phase order by count(*) desc) as rn
    from joined group by 1, 2, 3
) where rn <= 6
union all
-- 3. per instance: share of legal/execution-phase cases whose status says legal or insolvency
select 'C. per instance', instance,
       'legal-phase cases: ' || count_if(phase in ('Legal','Execution')),
       'of which status legal/insolvency: '
           || count_if(phase in ('Legal','Execution') and workout_track in ('Legal / enforcement','Insolvency')),
       round(100.0 * count_if(phase in ('Legal','Execution') and workout_track in ('Legal / enforcement','Insolvency'))
             / nullif(count_if(phase in ('Legal','Execution')), 0), 3)
from joined group by 1, 2
order by 1, 2, 5 desc;
