-- ============================================================================
-- batch_attribution_audit — proves the two scope filters in accounts.sql and
-- payments.sql lose nothing, and shows where CAT has re-pointed a loan since.
-- GRAIN: one row per (batch, attribution class).
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/batch_attribution_audit.sql
--   ⚠ accounts.sql and payments.sql moved 2026-09-11 to
--     work/project-elsa-benchmark/. Bare mentions below mean there.
--
-- WHY THIS FILE EXISTS. accounts.sql pins $source_system and then dedupes
-- CASES with latest-version-wins. Both look like they could silently drop
-- loans, and the guards asserted they do not without ever showing it. This
-- file is the measurement, so the claim can be re-run instead of trusted.
--
-- IT ANSWERS TWO QUESTIONS.
--   1. Does pinning $source_system hide cases held in another Intrum
--      instance? INSTANCE_COVERAGE says no: for these 14 batch refs, asked
--      with NO instance filter at all, 4050 is the only system that returns
--      anything (2026-09-10: 17,841,296 history rows, 120,713 loans, 13 of
--      the 14 batches, one row).
--   2. Does latest-version-wins drop loans whose newest version has moved to
--      another batch? ATTRIBUTION says no, because the batch filter runs
--      BEFORE the qualify — ranking happens only among versions that name an
--      in-scope batch, so such a loan keeps its last in-scope batch. The
--      classes below are what it keeps (measured 2026-09-10):
--        118,400  latest ref unchanged
--          2,174  latest ref NULL, seller name blank. 2,173 of them sit on
--                 PT15018G000000 — 12% of that batch — and 2,172 carry a
--                 CLOSING_DATE. ⚠ CLOSURE IS NOT THE CAUSE: PT050030000000
--                 has 10,332 closed loans and not one loses its ref.
--            139  latest ref PT24004B000000, seller "INTRUM INVESTMENT
--                 SWITZER" — sold on, 138 with a closing date, spread over
--                 11 of the 12 batches
--      Dedupe-then-filter would drop those 2,313 loans and EUR 6,856,071.22
--      of in-window CAT payments PAM still reports, EUR 6,845,160.28 of it on
--      PT15018G000000. The ordering is load-bearing; do not reverse it.
--
-- ⚠ THE TWO CLASSES ARE NOT THE SAME KIND OF THING, AND BOTH ARE QUESTIONS
-- FOR INTRUM. A ref of PT24004B000000 with a Swiss seller name says the loan
-- LEFT the Millennium book — small, spread evenly, and plausibly an onward
-- sale. A NULL ref says nothing at all, and it is concentrated: essentially
-- all of it is PT15018G000000, the one batch whose CAT-vs-PAM match is
-- unexplained. Do not file the NULLs under housekeeping — closed loans on
-- every other batch keep their ref.
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
    cross join newest_pam_file as nf
    where p._file_path = nf.file_path
      and p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
),

-- Question 1. No instance filter anywhere: the whole CAT case feed is asked
-- which systems hold these batch refs. The batch-ref filter is what keeps it
-- affordable, so do not add a _file_path prefix here — that would beg the
-- question this CTE exists to answer.
instance_coverage as (
    select split_part(c._file_path, '.', 2)   as source_system,
           count(*)                           as history_rows,
           count(distinct c.long_portfolio_id) as batches_seen,
           count(distinct c.case_id)          as cases_seen
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c.long_portfolio_id in (select combined_ref from batches)
    group by 1
),

-- The case list exactly as accounts.sql and payments.sql build it.
cases_as_built as (
    select c.long_portfolio_id as portfolio_ref, c.case_id
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
      and not ($source_system = '2080' and coalesce(c.real_case_ind, '') = '1')
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- The same loans' TRUE newest version, with no batch filter, so the two can
-- be compared. This is the only place the unfiltered ref is available.
true_latest as (
    select c.case_id,
           c.long_portfolio_id       as latest_ref,
           c.portfolio_sellers_name  as latest_seller,
           c.closing_date
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.case_id in (select case_id from cases_as_built)
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
)

select
    'instance'                                  as report,
    ic.source_system                             as batch_or_system,
    'n/a'                                        as class,
    ic.cases_seen                                as loans,
    ic.batches_seen                              as batches_or_closed,
    to_varchar(ic.history_rows, '999,999,999')   as detail
from instance_coverage as ic

union all

select
    'attribution'                               as report,
    b.portfolio_ref                              as batch_or_system,
    case when t.latest_ref is null       then '3. latest ref NULL (closed)'
         when t.latest_ref = b.portfolio_ref then '1. latest ref unchanged'
         else '2. latest ref reassigned' end     as class,
    count(*)                                     as loans,
    count(t.closing_date)                        as batches_or_closed,
    coalesce(listagg(distinct t.latest_ref, ' ') || ' / ' ||
             listagg(distinct t.latest_seller, ' '), '—') as detail
from cases_as_built as b
inner join true_latest as t on t.case_id = b.case_id
group by report, b.portfolio_ref, class
order by report, batch_or_system, class;
