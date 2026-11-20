-- ============================================================================
-- promissory_notes — is there anything about promissory notes (Portuguese
-- "livranca") in the Project Elsa raw data, and on how much of the book?
--
--   RUN     mise run sql -- work/project-elsa-benchmark/promissory_notes.sql
--   GRAIN   one row per report block
--   COST    ~3 minutes (one INVOICES scan, pruned to instance 4050)
--   READ    FINDINGS.md §7 first: there is NO product column on CASES. This
--           file is the one place in the feed where an instrument type exists.
--
-- WHERE THE ANSWER LIVES
--   INVOICES.CLAIM_REASON is free text typed per invoice, in a mix of
--   Portuguese and English, and it is the ONLY field in the whole CAT feed
--   that names a credit instrument. Two of its codes are the ones asked about:
--     LIV = livranca   = promissory note
--     LET = letra      = bill of exchange (related, NOT the same instrument)
--   Both appear spelled out, abbreviated, and mixed ("LIV -LETRAS E
--   LIVRANCAS"), so the classification below matches on text, not on a code
--   list, and reports the raw values it matched in block C so the reader can
--   audit them.
--
-- ⚠ DATA-QUALITY GUARD, visible on purpose (CLAUDE.md Rule 6)
--   CLAIM_REASON is NOT a controlled vocabulary. 79 distinct values for what
--   is maybe 20 real instruments, differing only by spacing, language and
--   typos ("Connsummer", "Consummer"). Any total built on it is a floor.
--   Block A measures how much of the book even has an invoice to read.
--
-- GUARDS from 01_accounts.sql, unchanged:
--   C4 _file_path pinned to instance 4050 as a literal prefix
--   C8 batch filter before the qualify   C9 container cases dropped
--   C1 CASES deduped to the latest version per case
-- CHECKED AND EMPTY — do not re-probe (measured 2026-09-14, this scope):
--   INVOICES.SECURITY_CODE1/2/3  100% NULL over all 7,262,100 invoice rows
--   CASES.ORIG_PRODUCT_NAME, CLAIM_CONCERN, LEGAL_CLAIM_REASON  100% NULL
--   CASE_EXTENSION  no rows at all for any of these 120,713 loans
--   DEBTORS.LEGAL_TYPE / ORIG_LEGAL_TYPE  100% NULL (so no "avalista" role)
--   PROD.NPL_COMMON.DIM_PRODUCT  has no note-type category in its vocabulary
-- Every loan HAS invoices; 39.8% of them just have no CLAIM_REASON typed.
--
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

set country       = 'PT';
set seller        = 'MILLENNIUM';
set source_system = '4050';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


with batches as (
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

-- The valuation base, same population and same guards as accounts.sql.
cases as (
    select
        c.case_id,
        c.long_portfolio_id as portfolio_id,
        c.original_capital
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'   -- C4
      and c.long_portfolio_id in (select combined_ref from batches)       -- C8
      and c.case_id not like '%-%'                                        -- C9
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1                                                                 -- C1
),

-- Every distinct instrument label ever typed against a loan. DISTINCT rather
-- than a version pick: INVOICES is a change feed, and a loan legitimately has
-- several invoices with several instruments, so "latest" would lose real ones.
claims as (
    select distinct
        i.case_id,
        upper(trim(i.claim_reason))                              as claim_reason,
        upper(trim(i.claim_reason)) like '%LIVRAN%'
            or upper(trim(i.claim_reason)) like '%PROMISSORY%'
            or upper(trim(i.claim_reason)) like 'LIV%'
            or upper(trim(i.claim_reason)) like '%/LIV%'
            or upper(trim(i.claim_reason)) like '%BILL/%NOTE%'   as is_promissory_note,
        upper(trim(i.claim_reason)) like 'LET%'
            or upper(trim(i.claim_reason)) like '%BILL OF EXCHANGE%'
            or upper(trim(i.claim_reason)) like '%DISCOUNTED BILL%' as is_bill_of_exchange
    from RAW.HYPERION_INTRUM_CAT.INVOICES as i
    where i._file_path like $raw_prefix || $source_system || '.invoices.%'
      and i.case_id in (select case_id from cases)
      and i.claim_reason is not null
),

-- One row per loan: does any of its invoices name a note-type instrument?
loans as (
    select
        c.case_id,
        c.portfolio_id,
        c.original_capital,
        max(iff(cl.is_promissory_note, 1, 0))  as has_promissory_note,
        max(iff(cl.is_bill_of_exchange, 1, 0)) as has_bill_of_exchange,
        count(cl.claim_reason)                 as labels_seen
    from cases as c
    left join claims as cl on cl.case_id = c.case_id
    group by c.case_id, c.portfolio_id, c.original_capital
)

-- A. how much of the book can this question even be asked of? ----------------
select
    'A. coverage'                                        as block,
    case
        when labels_seen = 0 then 'no instrument label at all'
        else 'has at least one instrument label'
    end                                                  as item,
    null                                                 as detail,
    count(*)                                             as loans,
    sum(original_capital)                                as original_capital,
    round(100 * count(*)
          / sum(count(*)) over (), 5)                    as pct_of_loans
from loans
group by 1, 2, 3

union all

-- B. of the labelled loans, which instrument ---------------------------------
select
    'B. instrument (labelled loans only)',
    case
        when has_promissory_note = 1 and has_bill_of_exchange = 1 then 'promissory note AND bill of exchange'
        when has_promissory_note = 1 then 'promissory note (livranca)'
        when has_bill_of_exchange = 1 then 'bill of exchange (letra) only'
        else 'labelled, but neither'
    end,
    null,
    count(*),
    sum(original_capital),
    round(100 * count(*) / sum(count(*)) over (), 5)
from loans
where labels_seen > 0
group by 1, 2, 3

union all

-- C. the raw text that drove the promissory-note bucket, for audit -----------
select
    'C. matched raw values',
    cl.claim_reason,
    iff(cl.is_bill_of_exchange, 'also reads as bill of exchange', null),
    count(distinct cl.case_id),
    null,
    null
from claims as cl
where cl.is_promissory_note
group by 1, 2, 3

union all

-- D. where the promissory-note loans sit ------------------------------------
select
    'D. by batch',
    portfolio_id,
    to_char(count_if(labels_seen > 0)) || ' of ' || to_char(count(*))
        || ' loans in the batch carry any label',
    count_if(has_promissory_note = 1),
    sum(iff(has_promissory_note = 1, original_capital, 0)),
    round(100 * count_if(has_promissory_note = 1) / count(*), 5)
from loans
group by 1, 2
having count_if(has_promissory_note = 1) > 0

order by block, loans desc, item;
