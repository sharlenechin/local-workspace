-- ============================================================================
-- borrower_type — is a loan in these books a consumer or a business? The CAT
-- feed has no column that says so, but DEBTORS.TYPE splits P from C, and this
-- file tests that reading before relying on it.
-- GRAIN: two report blocks, see REPORT column. Block A is one row per
-- (batch, borrower class); block B is the validation.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/borrower_type.sql
--   ⚠ accounts.sql and payments.sql moved 2026-09-11 to
--     work/project-elsa-benchmark/. Bare mentions below mean there.
--
-- WHAT WAS LOOKED FOR AND WHAT IS ACTUALLY THERE (measured 2026-09-10 over the
-- 120,713 in-scope loans). There is NO consumer/SME/segment column anywhere:
--   · CASES.CASE_CLASSIFICATION, CLAIM_CONCERN, RECEIVABLE_TYPE,
--     ORIG_PRODUCT_NAME, GGCV, DATA_EXCL_CLASSIF — all 100% NULL here.
--   · CASES.IJ_INDUSTRY_CODE is the single value 'Other' on every loan.
--   · CASES.INDUSTRY_CODE has two values, K and Z, on all 120,713.
--   · CASES.PRODUCT_ID has two values, 2 and 4, on all 120,713;
--     ORIG_PRODUCT_ID has 15 and 21 on 74,405 (61.6%). Neither is decoded
--     anywhere in RAW or PROD — there is no product lookup table.
--   · PRODUCT_HISTORY is useless for this: 31,368 loans (26%), PRODUCT_ID = 7
--     on every one of them, ORIG_PRODUCT_NAME 100% NULL.
--   · PROD.NPL_COMMON.DIM_CASE has SECURED_FLAG but no segment or product.
--   · DEBTORS.LEGAL_TYPE, ORIG_LEGAL_TYPE, OCCUPATION, INCOME and
--     DEBTOR_FIRST_NAME are 100% NULL. GENDER is filled on 6,860 loans (5.7%).
--
-- SO THE ONLY CANDIDATE IS DEBTORS.TYPE: 'P' on 119,071 loans, 'C' on 12,796,
-- NULL on 13,219 — and the counts overlap because a loan can have several
-- debtors. P for private, C for company is the obvious reading.
--
-- ⚠⚠ AND IT CANNOT BE VALIDATED FROM THIS FEED — MEASURED, NOT ASSUMED.
-- BLOCK C tries: it counts how often each type's name takes a Portuguese
-- company form (LDA, UNIPESSOAL, SOCIEDADE, COMERCIAL, S.A.). It returns ZERO
-- matches for every type, because every name field is empty. Across all
-- 15,264,217 debtor rows on instance 4050, DEBTOR_NAME1, DEBTOR_NAME2 and
-- DEBTOR_LAST_NAME are 100% NULL — and so are OCR_NUMBER and DEBTOR_NUMBER,
-- which would have been the other way to tell a company from a person.
-- PERSONAL_DATA_DELETED is 'N' on 12.3m of those rows, so the names were
-- never delivered rather than erased under GDPR.
-- BLOCK B offers no help either: every class sits under PRODUCT_ID 2, and
-- PRODUCT_ID 4 has three loans in total. Nothing in the feed corroborates
-- P/C, so it stays an undocumented code and only Intrum can confirm it.
--
-- ⚠⚠ AND 'SME' IS NOT ANSWERABLE AT ALL, EVEN IF C MEANS COMPANY. SME is a
-- SIZE class. DEBTORS.INCOME is 100% NULL, there is no turnover, no employee
-- count and no company registration number anywhere in the feed, so a corner
-- shop and a large corporate are indistinguishable here. Do not label anything
-- in these books SME.
--
-- ⚠ BORROWER_CLASS IS DERIVED, NOT DELIVERED. It is this file's construct:
-- COMPANY where any debtor on the loan is C and none is P, MIXED where both
-- appear (a company with a personal guarantor, or the reverse), CONSUMER where
-- only P appears, UNKNOWN where TYPE is NULL throughout. Do not present it as
-- an Intrum field, and do not use it for regulatory segmentation without
-- Intrum confirming what P and C mean.
--
-- ⚠⚠ MIXED IS ALMOST HALF THE BOOK BY MONEY, so any consumer/business split
-- is a decision about MIXED rather than a fact read off the data (measured
-- 2026-09-10):
--     CONSUMER  107,744 loans (89.3%)   EUR 462,690,047.83  (50.6%)
--     MIXED      11,324 loans ( 9.4%)   EUR 397,424,562.40  (43.4%)
--     COMPANY     1,473 loans ( 1.2%)   EUR  52,207,500.86  ( 5.7%)
--     UNKNOWN       169 loans ( 0.1%)   EUR     199,166.89  ( 0.0%)
-- A personal guarantor beside a corporate debtor is normal on an NPL book, so
-- MIXED loans are genuinely both. Push them to CONSUMER and the consumer share
-- is 94% of balance; push them to COMPANY and it is 51%. State which you did.
-- PT15018G000000 and PT16023C000000 carry nearly all of it: MIXED is EUR
-- 207.3m and EUR 101.7m of their registration balance respectively.
--
-- ⚠ NO PERSONAL DATA LEAVES THIS QUERY. Names are read only to pattern-match
-- a company suffix and are never returned. Keep it that way.
--
-- Guards are those of accounts.sql, plus DEBTORS' own DELETED / ARCHIVED /
-- UNLINKED flags and a dedupe to the latest version per (CASE_ID,
-- DEBTOR_ROW_NUMBER) — DEBTORS is a 3.5bn-row change-history feed and one
-- loan carries many debtors, so both are needed.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment.
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
        c.original_capital + coalesce(c.original_interest, 0) as registration_balance,
        c.product_id,
        c.orig_product_id,
        c.industry_code
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- One row per debtor per loan, latest version.
debtors as (
    select
        d.case_id,
        d.type,
        upper(coalesce(d.debtor_name1, '')) as name_upper
    from RAW.HYPERION_INTRUM_CAT.DEBTORS as d
    where d._file_path like $raw_prefix || $source_system || '.debtors.%'
      and d.case_id in (select loan_id from cases)
      and coalesce(d.deleted, 0) = 0
      and coalesce(d.archived, 0) = 0
      and coalesce(d.unlinked, 0) = 0
    qualify row_number() over (
        partition by d.case_id, d.debtor_row_number
        order by coalesce(d.record_updated, d.update_ts)::timestamp desc nulls last
    ) = 1
),

per_loan as (
    select
        d.case_id,
        count(*)                                        as debtors_on_loan,
        max(iff(d.type = 'C', 1, 0))                    as has_company,
        max(iff(d.type = 'P', 1, 0))                    as has_private
    from debtors as d
    group by d.case_id
),

classified as (
    select
        c.portfolio_id,
        c.loan_id,
        c.registration_balance,
        c.product_id,
        c.orig_product_id,
        c.industry_code,
        case when l.has_company = 1 and l.has_private = 1 then 'MIXED'
             when l.has_company = 1                       then 'COMPANY'
             when l.has_private = 1                       then 'CONSUMER'
             else 'UNKNOWN' end                          as borrower_class
    from cases as c
    left join per_loan as l on l.case_id = c.loan_id
)

-- BLOCK A: how the book splits, and whether PRODUCT_ID tracks the split.
select
    'A. class by batch'                     as report,
    portfolio_id                            as dimension,
    borrower_class                          as value,
    count(*)                                as loans,
    sum(registration_balance)               as registration_balance,
    listagg(distinct product_id::string, '/')      as product_ids,
    listagg(distinct orig_product_id::string, '/') as orig_product_ids,
    listagg(distinct industry_code::string, '/')   as industry_codes
from classified
group by 1, 2, 3

union all

select
    'B. does PRODUCT_ID track class'        as report,
    'product_id ' || coalesce(product_id::string, '(null)'),
    borrower_class,
    count(*),
    sum(registration_balance),
    '', '', ''
from classified
group by 1, 2, 3

union all

-- BLOCK C: the validation. Does a C-type debtor's name look like a company?
select
    'C. name matches company form'          as report,
    'TYPE ' || coalesce(d.type::string, '(null)'),
    iff(d.name_upper rlike '.*(LDA|UNIPESSOAL|SOCIEDADE|COMERCIAL|, *S\\.?A\\.?| S\\.?A\\.?$|IMOBILIARIA|CONSTRUCOES).*',
        'looks like a company', 'does not'),
    count(*),
    null,
    '', '', ''
from debtors as d
group by 1, 2, 3
order by 1, 2, 3;
