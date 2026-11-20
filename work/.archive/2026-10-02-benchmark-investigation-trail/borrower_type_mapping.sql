-- ============================================================================
-- borrower_type_mapping — what the RAW Intrum CAT feed actually says about
-- borrower type, and what PROD maps each raw value to. Loan counts throughout.
--
-- WHY THIS FILE EXISTS. The SME / Individual split in accounts.sql is driven by
-- one undocumented raw code (DEBTORS.TYPE = 'P' or 'C'). LEGAL_EBA_TYPE in
-- PROD is a MAPPING of that, not an independent opinion, so it cannot be used
-- to check the split — it can only be used to see what the mapping does. This
-- file therefore shows the raw values, the mapping, and the loans that the
-- mapping loses, side by side.
--
-- AT A GLANCE (measured 2026-09-10 over all 120,713 in-scope loans).
--   THE RAW FEED CARRIES NO PRODUCT AND NO SIZE. The only borrower-type value
--   in it is DEBTORS.TYPE, and it is undocumented:
--       TYPE = P   119,075 loans   642,227 debtor slots
--       TYPE = C    12,844 loans    38,400 debtor slots
--       TYPE = NULL 13,234 loans    38,070 debtor slots
--   The counts overlap because a loan carries many debtors. Only 168 loans
--   have NEITHER a P nor a C anywhere; every loan has at least one debtor row.
--
--   THE PROD MAPPING IS ONE-TO-ONE AND HAS NO THIRD VALUE, so LEGAL_EBA_TYPE
--   is a relabel of the same code and adds no information:
--       Private -> Households                   90,341 loans
--       Company -> Non-financial corporations    4,058 loans
--       NULL    -> NULL                          1,208 loans
--
--   ⚠⚠ THE SPLIT IS A TIE-BREAK, NOT A READING. Of the 12,844 loans with a
--   company debtor, only 1,470 (EUR 52,177,435.07) are company-ONLY. The other
--   11,374 (EUR 398,562,465.78) carry a company AND a private debtor, and are
--   SME purely because accounts.sql lets 'C' win over 'P'. So 88% of SME
--   loans, and 88% of SME balance, come from that choice rather than the data.
--   Resolving those 11,374 loans is worth EUR 398.6m — 43.68% of the book:
--       C + P -> Individual   SME  1,470 loans / EUR  52,177,435.07  ( 5.72%)
--       C + P -> SME          SME 12,844 loans / EUR 450,739,900.85  (49.39%)
--       PROD-first (shipped)  SME  5,569 loans / EUR 279,942,246.25  (30.68%)
--   And it is concentrated, so it is really a question about two batches
--   (block F): PT15018G000000 EUR 207,317,079.38 and PT16023C000000
--   EUR 101,785,544.73 — 77.6% of the C + P balance between them.
--
--   ⚠⚠⚠ WHY THE LOANS GO MISSING FROM PROD — AND WHY PROD'S CLASSIFICATION
--   SHOULD NOT BE USED FOR THIS SCOPE AT ALL. Traced 2026-09-10, from the
--   funnel below to the dbt source. This supersedes the gentler reading in
--   accounts.sql that PROD merely "sees less".
--
--   The loans are NOT absent from PROD. Every one of the 120,713 has a current
--   DIM_CASE row AND a BRG_CASE_BORROWER row. They are lost at one filter,
--   `dim_borrower.is_current`:
--       classified                                          91,930 loans
--       bridge -> a borrower with no is_current row          28,533 loans
--       borrower current but ORIGINAL_LEGAL_TYPE null           250 loans
--   For the bridged borrower_sks: 125,011 are present and current, 74,377 are
--   present but on an EXPIRED SCD version, and only 572 are truly absent. So
--   is_current is what discards them, not missing data.
--
--   ⚠⚠ THE ROOT CAUSE IS THE BORROWER KEY, and it makes the surviving 91,930
--   no safer than the 28,533. In int_npl_borrower_intrum.sql:
--       borrower_bk = source_system_code || '-' || debtor_row_number
--   There is NO case in that key, but DEBTOR_ROW_NUMBER is not unique per
--   case. Measured on raw instance 4050: 15,264,217 rows, 1,613,593 distinct
--   (case, slot) pairs, only 1,085,265 distinct DEBTOR_ROW_NUMBERs — and ONE
--   of them is shared by 296,041 different cases. dim_npl_borrower.sql then
--   keeps one row per borrower_sk, ordered by record_update_date, under its
--   own comment "attributes will diff between cases. For now, only take
--   latest". So one "borrower" is a slot number shared across hundreds of
--   thousands of cases, and its legal type is whichever case touched it last.
--   Two consequences, both measured over this scope:
--     · 120,710 of 120,713 loans have a debtor slot whose DEBTOR_ROW_NUMBER
--       is shared by over 100,000 other cases.
--     · 120,711 loans have a slot on a DEBTOR_ROW_NUMBER that carries
--       CONFLICTING types (P and C and null) across the cases sharing it.
--   That also explains the huge SCD version history per borrower_bk, hence why
--   most bridge rows point at an expired version: one current version exists
--   per shared slot, and every other case bridged to it loses the join.
--
--   ⚠⚠ AND THE LOSS IS DIRECTIONAL — IT SYSTEMATICALLY DROPS COMPANIES, so
--   PROD understates SME by construction rather than at random. is_current is
--   flagged per borrower_id (the shared slot) by scd_table.sql, while
--   BRG_CASE_BORROWER references borrower_sk at (borrower, case) grain — so a
--   loan keeps only the slots whose version happens to be the current one, and
--   its PROD legal type is whichever slot survived, not all its debtors.
--   Measured on the 7,204 loans where raw says C+P and PROD says Private only:
--       slot type   slots    median cases sharing the DEBTOR_ROW_NUMBER
--       C          17,559    296,041   <- the most-shared value in the feed;
--                                         ZERO of them on a unique number
--       P          38,668          1   <- 19,600 of them on a unique number
--   The company slots sit on a sentinel row number shared by 296,041 cases, so
--   their SCD version is almost never the current one; the private slots are
--   mostly unique and survive. That is the whole of "PROD sees less, never
--   differently" — the loss is one-directional, not balanced.
--
--   ⚠ SO DO NOT "RECOVER" THE 28,533 BY DROPPING is_current. The expired rows
--   carry the same borrowed values; dropping the filter adds coverage, not
--   correctness. And do NOT read the 7,204 loans where PROD says Private and
--   raw says Company as PROD "missing a co-debtor" — PROD's value there may
--   simply belong to another case that shares the slot number.
--   ⚠ USE THE RAW FEED ALONE FOR THIS SCOPE. DEBTORS.TYPE is per (case, slot),
--   covers 100% of the loans, and is the only per-case borrower type available.
--   That is block D's raw-only split: SME 12,844 loans / EUR 450,739,900.85.
--   accounts.sql's shipped PROD-first split (SME 5,569 / EUR 279,942,246.25)
--   inherits all of the above and should be treated as unreliable until the
--   data team confirms the key.
--   ⚠ THIS IS A REPORT, NOT A FIX. The models above live in brocc-data and are
--   the data team's to change (CLAUDE.md Rules 1, 3 and 6). Raise the
--   borrower_bk grain with them; do not edit the dbt project from here.
--
--   Funnel and key evidence are reproducible from the scratchpad queries in
--   this session; block C below shows the resulting per-class crosstab.
--
--   ⚠ AND PROD SEES LESS THAN RAW, NEVER DIFFERENTLY (block C): on 7,204 loans
--   (EUR 164,109,778.14) raw shows a company debtor and PROD records only the
--   private one; 28,533 loans (EUR 118,047,910.50) have no PROD borrower row
--   at all; 250 loans (EUR 7,672,926.01) have one whose legal type is NULL.
--   PROD never calls a loan private that raw calls corporate.
--   Raw deciding alone:  SME 12,844 loans / EUR 450,739,900.85
--   PROD-first (accounts.sql, 120,376 loans): SME 5,569 / EUR 279,942,246.25
--
-- GRAIN: six report blocks, see the REPORT column. Read them in order.
--   A. raw DEBTORS.TYPE as delivered — debtor slots and loans per value
--   B. the PROD mapping itself — ORIGINAL_LEGAL_TYPE -> LEGAL_EBA_TYPE
--   C. THE ANSWER: raw loan class x PROD loan class, loans and balance
--   D. what accounts.sql's PRICING_SEGMENT rule then produces per raw class
--   E. raw CASES product / industry columns x raw class ("the products")
--   F. where the C + P loans sit by batch — the balance the tie-break moves
--
--   Terminal : mise run sql -- work/benchmark/borrower_type_mapping.sql
--   ⚠ accounts.sql and payments.sql moved 2026-09-11 to
--     work/project-elsa-benchmark/. Bare mentions below mean there.
--
-- ⚠ POPULATION IS THE FULL 120,713 IN-SCOPE LOANS, not accounts.sql's 120,376.
-- accounts.sql drops 335 loans with no borrower type in either source and 2
-- loans on an excluded batch AT ITS FINAL SELECT. Those loans are exactly what
-- block C's 'no type in raw' row is about, so they are kept here on purpose.
--
-- ⚠ LEGAL_EBA_TYPE IS A MAPPING OF THE RAW CODE, SO IT AGREES BY CONSTRUCTION
-- WHEREVER IT HAS A ROW. It is not corroboration of P/C from a second system.
-- Blocks A and B show it agrees; block C shows it covers only part of the book.
--
-- ⚠ NEITHER SIDE ANSWERS 'SME'. SME is a SIZE class. DEBTORS.INCOME is 100%
-- NULL, there is no turnover, employee count or company registration number in
-- the feed, DIM_BORROWER.VAT is 0% filled for this scope, and LEGAL_EBA_TYPE
-- stops at 'Non-financial corporations' with no SME / non-SME split. So the
-- most either source supports is "a corporate debtor is on the loan".
-- See the PRICING_SEGMENT block in accounts.sql and borrower_type.sql.
--
-- ⚠ DEDUPE USES max_ts, NOT row_number(). RECORD_UPDATE is tied at the latest
-- version on 97.4% of in-scope debtor slots and TYPE changes across versions
-- on 33.4%, so row_number() picks arbitrarily and the split flips between
-- runs. Every row tied at the latest version is kept and the flags OR'd
-- across them — accounts.sql Guard 6. Do not reintroduce row_number here.
-- ⚠ borrower_type.sql DOES still use row_number(), which is why its counts sit
-- a few loans away from these. This file follows accounts.sql.
--
-- ⚠ NO PERSONAL DATA LEAVES THIS QUERY. No name, number or date of birth is
-- selected. Keep it that way.
--
-- Guards are those of accounts.sql: CASES and DEBTORS are change-history feeds
-- deduped to the latest version per loan, the source system is pinned on
-- _file_path (CASE_ID is unique only within one), container cases dropped,
-- every extract read, and both one-to-many sources grouped to one row per loan
-- before any join.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment.
-- ============================================================================

set country       = 'PT';
set seller        = 'MILLENNIUM';   -- matched case-insensitively; both casings exist
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

-- One row per loan: its latest version across every extract.
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

-- Every debtor slot at its latest version. NOT one row per slot: ties at the
-- latest version are all kept, deliberately (see the header).
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
          -- Scope first, then the window: the partition is per
          -- (CASE_ID, DEBTOR_ROW_NUMBER) so this cannot change a surviving row.
          and b.case_id in (select loan_id from cases)
          and coalesce(b.deleted, 0) = 0
          and coalesce(b.archived, 0) = 0
          and coalesce(b.unlinked, 0) = 0
    ) as d
    where d.ts = d.max_ts
),

-- One row per loan. Flags OR'd, so an ambiguous slot sets both.
raw_class as (
    select
        case_id,
        max(iff(type = 'C', 1, 0)) as has_company,
        max(iff(type = 'P', 1, 0)) as has_private,
        max(iff(type is null, 1, 0)) as has_null_type,
        max(iff(type not in ('C', 'P'), 1, 0)) as has_other_type
    from debtor_slots
    group by case_id
),

-- PROD's mapped version. One row per CASE_BK: BRG_CASE_BORROWER is a bridge
-- and a case can carry several borrowers, so it is grouped before it joins.
-- ⚠ JOIN ON CASE_BK. DIM_CASE.CASE_ID is NOT the raw servicer CASE_ID and
-- joining on it silently returns nothing.
prod_class as (
    select
        dc.case_bk,
        max(iff(b.original_legal_type = 'Company', 1, 0)) as prod_company,
        max(iff(b.original_legal_type = 'Private', 1, 0)) as prod_private,
        -- Sorted, so a loan carrying both never appears under two labels.
        -- ⚠ nullif is load-bearing: listagg over rows whose value is NULL
        -- throughout returns an EMPTY STRING, not NULL, so the coalesce in
        -- `loans` never fires and 250 real loans label as blank. This is the
        -- PROD-Unknown population; it must read '(null)', not ''.
        nullif(listagg(distinct b.original_legal_type, ' + ')
            within group (order by b.original_legal_type), '') as prod_legal_types,
        nullif(listagg(distinct b.legal_eba_type, ' + ')
            within group (order by b.legal_eba_type), '')      as prod_eba_types,
        count(distinct b.borrower_sk)                     as borrowers
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
        c.portfolio_id,
        c.loan_id,
        c.registration_balance,
        c.product_id,
        c.orig_product_id,
        c.industry_code,
        case when r.has_company = 1 and r.has_private = 1 then 'raw C + P (company and private)'
             when r.has_company = 1                       then 'raw C only (company)'
             when r.has_private = 1                       then 'raw P only (private)'
             when r.case_id is null                       then 'raw: no debtor row at all'
             else                                              'raw: debtor rows but TYPE null' end
                                                          as raw_loan_class,
        case when p.case_bk is null then '(absent from PROD)'
             else coalesce(p.prod_legal_types, '(null)') end as prod_legal_types,
        case when p.case_bk is null then '(absent from PROD)'
             else coalesce(p.prod_eba_types, '(null)') end   as prod_eba_types,
        iff(coalesce(r.has_company, 0) = 1, 'SME', 'Individual') as pricing_segment
    from cases as c
    left join raw_class  as r on r.case_id = c.loan_id
    left join prod_class as p on p.case_bk = $source_system || '-' || c.loan_id
)

-- ── A. the raw values as delivered ───────────────────────────────────────
select
    'A. raw DEBTORS.TYPE'                        as report,
    'TYPE = ' || coalesce(type, '(null)')        as raw_value,
    ''                                           as mapped_to,
    count(*)                                     as debtor_slots,
    count(distinct case_id)                       as loans,
    null                                          as registration_balance
from debtor_slots
group by 1, 2, 3

union all

-- ── B. the PROD mapping itself, at borrower level ────────────────────────
-- This is the mapping the EBA vocabulary comes from. It has no third value.
select
    'B. PROD mapping',
    'ORIGINAL_LEGAL_TYPE = ' || coalesce(b.original_legal_type, '(null)'),
    'LEGAL_EBA_TYPE = ' || coalesce(b.legal_eba_type, '(null)'),
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

-- ── C. THE ANSWER: raw class x what PROD maps it to, per loan ────────────
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

-- ── D. what the SME / Individual rule then produces ──────────────────────
-- accounts.sql's rule is company-wins, applied to the RAW flags: a corporate
-- debtor with a personal guarantor prices as SME. This block is that rule.
select
    'D. PRICING_SEGMENT (company wins, raw)',
    raw_loan_class,
    pricing_segment,
    null,
    count(*),
    sum(registration_balance)
from loans
group by 1, 2, 3

union all

-- ── E. the raw product / industry columns, per class ─────────────────────
-- Neither PRODUCT_ID nor ORIG_PRODUCT_ID is decoded anywhere in RAW or PROD —
-- there is no product lookup table — so these are codes, not product names.
select
    'E. raw product / industry codes',
    'PRODUCT_ID '      || coalesce(product_id::string, '(null)')
      || ' / ORIG_PRODUCT_ID ' || coalesce(orig_product_id::string, '(null)')
      || ' / INDUSTRY_CODE '   || coalesce(industry_code::string, '(null)'),
    raw_loan_class,
    null,
    count(*),
    sum(registration_balance)
from loans
group by 1, 2, 3

union all

-- ── F. where the C + P loans sit, by batch ───────────────────────────────
-- The tie-break decides these loans, so this is where the SME balance moves.
-- Two batches carry nearly all of it.
select
    'F. C + P loans by batch',
    portfolio_id,
    '',
    null,
    count_if(raw_loan_class = 'raw C + P (company and private)'),
    sum(iff(raw_loan_class = 'raw C + P (company and private)', registration_balance, 0))
from loans
group by 1, 2, 3
having count_if(raw_loan_class = 'raw C + P (company and private)') > 0

order by 1, 6 desc nulls last, 2, 3;
