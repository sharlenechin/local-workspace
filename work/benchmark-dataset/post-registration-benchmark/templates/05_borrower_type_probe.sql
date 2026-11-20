-- ============================================================================
-- 05_borrower_type_probe — step 6 of METHOD.md. What the RAW feed actually says
-- about borrower type, what PROD maps it to, and how far apart they are.
-- Run it BEFORE committing to a segmentation, not after.
--
--   RUN     mise run sql -- work/benchmark-dataset/post-registration-benchmark/templates/05_borrower_type_probe.sql
--   GRAIN   four report blocks — read them in order, see the REPORT column
--             A. raw DEBTORS.TYPE as delivered: slots and loans per value
--             B. the PROD mapping itself: ORIGINAL_LEGAL_TYPE -> LEGAL_EBA_TYPE
--             C. THE ANSWER: raw loan class x PROD loan class, loans + balance
--             D. what a company-wins rule WOULD produce — a what-if, not output
--   COST    ~1 min
--   WORKED  FINDINGS.md §7 (Portugal: the split was a tie-break worth EUR 398.6m)
--
-- ⚠ A PROD MAPPING IS NOT A SECOND OPINION. If LEGAL_EBA_TYPE is a one-to-one
--   relabel of the same raw code it agrees by construction and corroborates
--   nothing. Block B is there to show you whether that is the case.
-- ⚠ CHECK PROD'S BORROWER KEY BEFORE TRUSTING BLOCK C's PROD SIDE. On Intrum it
--   is source_system_code || '-' || debtor_row_number — no case in the key, and
--   one row number shared by 296,041 cases. The resulting loss is DIRECTIONAL
--   (it drops companies), so PROD understates the corporate segment by
--   construction. Report it to the data team; never fix it in dbt from here.
-- ⚠ 'SME' IS A SIZE CLASS AND THIS FEED CANNOT ANSWER IT. Check INCOME,
--   turnover, headcount, VAT and company-number columns first — on Portugal all
--   were empty, so the most the data supports is "a corporate debtor is on the
--   loan".
-- ⚠⚠ BLOCK D IS A WHAT-IF, NOT THE SHIPPED SHAPE (changed 2026-10-02).
--   01_accounts.sql no longer emits a segment at all: it ships
--   LOAN_HOLDER_CORPORATE_FLAG and LOAN_HOLDER_INDIVIDUAL_FLAG, both of which
--   can be true on one loan, and leaves the pricing rule to the deal. Block D
--   stays because the balance a company-wins rule WOULD move is exactly what
--   you need to see before choosing a rule — read the 'raw C + P' row.
-- ⚠ DEDUPE ON max_ts, NOT row_number(). Update timestamps tie at the latest
--   version on most debtor slots and TYPE changes across versions on a third of
--   them, so row_number() picks arbitrarily and the split flips between runs.
-- ⚠ NO PERSONAL DATA LEAVES THIS QUERY. No name, number or date of birth is
--   selected. Keep it that way.
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

set country       = 'PT';
set seller        = 'MILLENNIUM';
set source_system = '4050';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


with newest_pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'
),

batches as (
    select distinct p.combined_ref
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    inner join newest_pam_file as nf on nf.file_path = p._file_path
    where p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
),

cases as (
    select
        c.long_portfolio_id as portfolio_id,
        c.case_id           as loan_id,
        c.original_capital + coalesce(c.original_interest, 0) as registration_balance
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- Every debtor slot at its latest version. NOT one row per slot: ties at the
-- latest version are all kept, deliberately.
debtor_slots as (
    select d.case_id, d.debtor_row_number, d.type
    from (
        select
            b.case_id,
            b.debtor_row_number,
            b.type,
            coalesce(b.record_updated, b.update_ts)::timestamp as ts,
            max(coalesce(b.record_updated, b.update_ts)::timestamp) over (
                partition by b.case_id, b.debtor_row_number
            ) as max_ts
        from RAW.HYPERION_INTRUM_CAT.DEBTORS as b
        where b._file_path like $raw_prefix || $source_system || '.debtors.%'
          and b.case_id in (select loan_id from cases)
          and coalesce(b.deleted, 0)  = 0
          and coalesce(b.archived, 0) = 0
          and coalesce(b.unlinked, 0) = 0
    ) as d
    where d.ts = d.max_ts
),

raw_class as (
    select
        case_id,
        max(iff(type = 'C', 1, 0))    as has_company,
        max(iff(type = 'P', 1, 0))    as has_private,
        max(iff(type is null, 1, 0))  as has_null_type
    from debtor_slots
    group by case_id
),

-- PROD's mapped version, grouped to one row per CASE_BK: BRG_CASE_BORROWER is
-- a bridge and a case can carry several borrowers.
-- ⚠ Join on CASE_BK. DIM_CASE.CASE_ID is NOT the raw servicer id.
prod_class as (
    select
        dc.case_bk,
        -- ⚠ nullif is load-bearing: listagg over rows whose value is NULL
        -- throughout returns an EMPTY STRING, not NULL, so a coalesce below
        -- would never fire and real loans would label as blank.
        nullif(listagg(distinct b.original_legal_type, ' + ')
            within group (order by b.original_legal_type), '') as prod_legal_types,
        nullif(listagg(distinct b.legal_eba_type, ' + ')
            within group (order by b.legal_eba_type), '')      as prod_eba_types
    from PROD.NPL_COMMON.DIM_CASE as dc
    inner join PROD.NPL_COMMON.BRG_CASE_BORROWER as br
        on br.case_sk = dc.case_sk
    inner join PROD.NPL_COMMON.DIM_BORROWER as b
        on b.borrower_sk = br.borrower_sk
       and b.is_current
    where dc.is_current_flag
      and dc.case_bk in (select $source_system || '-' || loan_id from cases)
    group by dc.case_bk
),

loans as (
    select
        c.loan_id,
        c.registration_balance,
        case when r.has_company = 1 and r.has_private = 1 then 'raw C + P (company and private)'
             when r.has_company = 1                       then 'raw C only (company)'
             when r.has_private = 1                       then 'raw P only (private)'
             when r.case_id is null                       then 'raw: no debtor row at all'
             else                                              'raw: debtor rows but TYPE null' end
                                                              as raw_loan_class,
        case when p.case_bk is null then '(absent from PROD)'
             else coalesce(p.prod_legal_types, '(null)') end  as prod_legal_types,
        case when p.case_bk is null then '(absent from PROD)'
             else coalesce(p.prod_eba_types, '(null)') end    as prod_eba_types,
        iff(coalesce(r.has_company, 0) = 1, 'SME', 'Individual') as would_be_segment  -- WHAT-IF only; nothing ships this
    from cases as c
    left join raw_class  as r on r.case_id = c.loan_id
    left join prod_class as p on p.case_bk = $source_system || '-' || c.loan_id
)

-- A. the raw values as delivered ---------------------------------------------
select
    'A. raw DEBTORS.TYPE'                  as report,
    'TYPE = ' || coalesce(type, '(null)')  as raw_value,
    ''                                     as mapped_to,
    count(*)                               as debtor_slots,
    count(distinct case_id)                as loans,
    null                                   as registration_balance
from debtor_slots
group by 1, 2, 3

union all

-- B. the PROD mapping itself, at borrower level -------------------------------
select
    'B. PROD mapping',
    'ORIGINAL_LEGAL_TYPE = ' || coalesce(b.original_legal_type, '(null)'),
    'LEGAL_EBA_TYPE = '      || coalesce(b.legal_eba_type, '(null)'),
    count(distinct b.borrower_sk),
    count(distinct dc.case_bk),
    null
from PROD.NPL_COMMON.DIM_CASE as dc
inner join PROD.NPL_COMMON.BRG_CASE_BORROWER as br on br.case_sk = dc.case_sk
inner join PROD.NPL_COMMON.DIM_BORROWER as b
    on b.borrower_sk = br.borrower_sk and b.is_current
where dc.is_current_flag
  and dc.case_bk in (select $source_system || '-' || loan_id from cases)
group by 1, 2, 3

union all

-- C. THE ANSWER: raw class x what PROD maps it to, per loan -------------------
select
    'C. raw class -> PROD class',
    raw_loan_class,
    prod_legal_types || '  ->  ' || prod_eba_types,
    null,
    count(*),
    sum(registration_balance)
from loans
group by 1, 2, 3

union all

-- D. what a company-wins rule WOULD produce ----------------------------------
-- ⚠ A WHAT-IF. Nothing downstream emits this. A corporate debtor with a
-- personal guarantor would price as SME under this rule. Read the 'raw C + P'
-- row: that is the balance the TIE-BREAK moves, not the data. If it is large,
-- the deal needs an explicit decision, not a default.
select
    'D. company-wins rule, IF APPLIED (what-if)',
    raw_loan_class,
    would_be_segment,
    null,
    count(*),
    sum(registration_balance)
from loans
group by 1, 2, 3

order by 1, 6 desc nulls last, 2, 3;
