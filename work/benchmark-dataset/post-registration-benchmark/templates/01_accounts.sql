-- ============================================================================
-- 01_accounts — step 2 of METHOD.md. One row per loan: the valuation base.
--
--   RUN     mise run sql -- work/benchmark-dataset/post-registration-benchmark/templates/01_accounts.sql
--           datalake.q("benchmark/templates/01_accounts", convert=False)
--   GRAIN   one row per LOAN_ID (raw CASE_ID). Assert uniqueness.
--   PAIRS   02_payments.sql on (PORTFOLIO_ID, LOAN_ID) — same population.
--   COST    ~30s once $source_system is pinned.
--   WORKED  ../../project-elsa-benchmark/accounts.sql + FINDINGS.md §1, §5-§8
--
-- GUARDS, each measured on the Portugal build (FINDINGS.md §5):
--   C1  CASES is a CHANGE-HISTORY feed (147x) — deduped to latest per CASE_ID
--   C8  batch filter runs BEFORE the qualify, so a loan whose newest version
--       left the scope keeps its last in-scope batch instead of vanishing
--   C4  _file_path pinned to one instance as a LITERAL PREFIX (CASE_ID is
--       unique only within one; and a leading % kills partition pruning)
--   C5  all extracts read — they are not copies of each other
--   C9  container cases (hyphenated CASE_ID) dropped, as dbt does
--   C3  DEBTORS is one-to-many AND a change feed — grouped before it joins
--   C10 NO row_number() on DEBTORS: update timestamps tie at the latest
--       version, so picking one row makes the segment flip between runs.
--       Every tied row is kept and the flags OR-ed.
--
-- ⚠ CHECK BEFORE YOU TRUST A TOTAL, on every new book:
--   · is ORIGINAL_INTEREST actually delivered, or is it zero on loans that
--     defaulted years before registration? (Portugal: 97.7% non-delivery)
--   · is there more than one CURRENCY_CAP_INTEREST? if so, currency belongs
--     in the grain and nothing may be summed across it
--   · does the roll-forward close? opening capital ~= remaining + collections
-- ⚠⚠ NO PRICING SEGMENT IS EMITTED, AND THAT IS THE POINT (changed 2026-10-02).
--   This file used to collapse the two debtor flags into PRICING_SEGMENT
--   ('SME' / 'Individual') with a company-wins tie-break. Two things were
--   wrong with that:
--     · WHAT COUNTS AS A PRICING SEGMENT CHANGES WITH EVERY DEAL. Baking one
--       deal's policy into the shared template made every later book inherit
--       a rule nobody had agreed for it.
--     · 'SME' IS A SIZE CLASS AND THIS FEED CANNOT ANSWER IT. No income,
--       turnover, headcount, VAT or company-number column is populated. The
--       most the data supports is "a corporate debtor is on the loan".
--   So the template now ships the FACTS and leaves the POLICY to the deal:
--     LOAN_HOLDER_CORPORATE_FLAG   a corporate debtor is on the loan
--     LOAN_HOLDER_INDIVIDUAL_FLAG  a private debtor is on the loan
--   ⚠ BOTH CAN BE TRUE. That is not a defect — it is the case the tie-break
--   used to hide. Apply the deal's own rule downstream and say what it was.
-- ⚠ DEFAULT_DATE from PROD may be 100% derived — trace it before using it for
--   anything vintage-shaped. See FINDINGS.md §8.
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

set country         = 'PT';
set seller          = 'MILLENNIUM';   -- case-insensitive
set source_system   = '4050';         -- from 00_scope.sql block B
set raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set exclude_batches = '';             -- comma-separated refs; '' keeps all


-- Scope: PAM collapsed to one row per batch before anything joins to it.
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

-- One row per loan: its latest version, across every extract.
cases as (
    select
        c.long_portfolio_id              as portfolio_id,
        c.case_id                        as loan_id,
        c.registration_date::date        as registration_date,
        c.original_capital               as registration_capital,
        coalesce(c.original_interest, 0) as registration_interest,
        c.currency_cap_interest          as currency_id
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'  -- C4, C5
      and c.long_portfolio_id in (select combined_ref from batches)      -- C8
      and c.case_id not like '%-%'                                       -- C9
      and not ($source_system = '2080' and coalesce(c.real_case_ind, '') = '1')
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1                                                                -- C1, C8
),

-- Borrower type, one row per loan. Scope first, then the window.
debtor_type as (
    select
        d.case_id,
        max(iff(d.type = 'C', 1, 0)) as has_company_debtor,
        max(iff(d.type = 'P', 1, 0)) as has_private_debtor
    from (
        select
            b.case_id,
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
    where d.ts = d.max_ts   -- EVERY row at the latest version, not one of them  C10
    group by d.case_id
),

-- Both joins are LEFT and both right sides are one row per loan, so the row
-- count cannot move. DIM_CASE supplies the default date and nothing else.
enriched as (
    select
        c.portfolio_id,
        c.loan_id,
        c.currency_id,
        c.registration_date,
        c.registration_capital,
        c.registration_interest,
        c.registration_capital + c.registration_interest as registration_balance,
        dc.derived_default_date::date                    as default_date,
        dc.derived_default_date < '1990-01-01'           as default_date_suspect_flag,
        dt.has_company_debtor                            as is_company,
        dt.has_private_debtor                            as is_private
    from cases as c
    left join PROD.NPL_COMMON.DIM_CASE as dc
        on  dc.case_bk = $source_system || '-' || c.loan_id  -- CASE_BK, not CASE_ID
        and dc.is_current_flag
    left join debtor_type as dt
        on dt.case_id = c.loan_id
)

select
    portfolio_id,                             -- PAM COMBINED_REF = the BATCH ref
    loan_id,                                  -- raw CASE_ID; PROD key is <system>-<id>
    currency_id,                              -- drop only after proving it is single-valued
    registration_date,                        -- when the servicer OPENED the case
    registration_capital,                     -- principal; the PAM comparable
    registration_interest,                    -- at registration; check delivery first
    registration_balance,                     -- capital + interest, NOT accrued interest
    default_date,
    default_date_suspect_flag,
    -- ⚠ FACTS, NOT A SEGMENT. Both can be true on one loan. The deal applies
    -- its own pricing rule to these; the template does not choose for it.
    is_company = 1                          as loan_holder_corporate_flag,
    is_private = 1                          as loan_holder_individual_flag
from enriched
where (is_company = 1 or is_private = 1)      -- unclassifiable = unpriceable
  and ($exclude_batches = ''
       or not array_contains(portfolio_id::variant, split($exclude_batches, ',')))
order by portfolio_id, loan_id;
