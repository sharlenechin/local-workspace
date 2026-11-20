-- ============================================================================
-- 00_scope — step 1 of METHOD.md. Two questions in one pass:
--   A. which batches is this country/seller in scope for, and what does PAM
--      say about each?  Now carries DEAL_TYPE so forward flow is visible.
--   B. which Intrum instance actually holds them? (asked with NO instance
--      filter, so it cannot beg its own question)
--   C. FILTER ATTRITION — what each guard removed, in batches and in money.
--      Added 2026-10-02: the guards used to be applied silently, so nobody
--      could see which one did the work on their book.
--
--   RUN     mise run sql -- work/benchmark-dataset/post-registration-benchmark/templates/00_scope.sql country=ES seller=SANTANDER
--   GRAIN   one row per batch (A), per source system (B), per filter stage (C)
--   COST    block A seconds; block B one CASES scan, minutes
--   NEXT    put block B's SOURCE_SYSTEM into $source_system everywhere else
--
-- GUARDS  P1 newest PAM delivery only ('pam.pam.pam.2' — 'pam_perimeter' files
--            would win a plain max)   · P2 PMODE_NAME='Real'
--         P3 no ownership-change rows · P4 actual months only, not plan
--         P5 upper() on seller — casing is inconsistent
-- Drop any one and the answer is wrong, not merely noisy. Why: METHOD.md §1.
--
-- ⚠ If block B returns MORE THAN ONE system, CASE_ID is ambiguous across them
--   and every downstream join needs the system in the key, not just in a file
--   filter. If it returns none, the batches have no loan-level feed at all.
-- ⚠⚠ THIS FILE DOES NOT EXCLUDE FORWARD FLOW, AND THAT IS DELIBERATE. A
--   benchmark is built on one-off purchases, so the exclusion belongs in the
--   scope block you copy into 01/02/03 -- but you cannot decide it before you
--   have SEEN it. Block C measures it: on Portugal, 198 of 259 batches are
--   forward flow, the single largest filter in the whole method. Read block A's
--   DEAL_TYPE, then carry `and deal_type_desc = 'One-off'` forward yourself.
-- ⚠ PERIOD_START_DATE is VARCHAR and means the FIRST DAY OF that month.
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

set country = 'PT';         -- matched with like; '%' for everything
set seller  = 'MILLENNIUM'; -- matched case-insensitively with like


with newest_pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'                          -- P1
),

pam_rows as (
    select
        p.portfolioid,
        p.combined_ref,
        p.currency,
        p.capex_date_m::date      as capex_month,
        p.period_start_date::date as reporting_month,
        p.colltotal               as collections,
        p.acquisitionprincipal    as acquisition_principal,
        -- ⚠ One-off vs forward flow. The benchmark wants one-off only; this is
        -- reported rather than filtered, so the choice is visible. See block C.
        COALESCE(p.deal_type_desc, '(not stated)') as deal_type
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    inner join newest_pam_file as nf on nf.file_path = p._file_path   -- P1
    where p.pmode_name = 'Real'                                       -- P2
      and coalesce(p.is_ownership_change, 0) = 0                      -- P3
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)                    -- P5
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string,
              'YYYYMMDDTHH24MISS'))::date                             -- P4
),

batches as (
    select
        combined_ref,
        max(portfolioid)                                        as portfolioid,
        max(currency)                                           as currency,
        max(capex_month)                                        as capex_month,
        count(*)                                                as reported_months,
        count_if(collections <> 0)                              as collecting_months,
        min(iff(collections <> 0, reporting_month, null))       as first_collecting_month,
        max(iff(collections <> 0, reporting_month, null))       as last_collecting_month,
        sum(collections)                                        as lifetime_collections,
        max(acquisition_principal)                              as acquisition_principal,
        max(deal_type)                                          as deal_type
    from pam_rows
    group by combined_ref
),

-- Same scope as pam_rows but with the guards peeled back one at a time, so
-- block C can say what each removed instead of asserting that it mattered.
unguarded as (
    select
        p.combined_ref,
        p.colltotal                                             as collections,
        p.pmode_name,
        COALESCE(p.is_ownership_change, 0)                      as is_ownership_change,
        COALESCE(p.deal_type_desc, '(not stated)')              as deal_type,
        p.period_start_date::date                               as reporting_month,
        date_trunc('month', to_timestamp_ntz(
            parse_json(p._file_metadata):extract_ts::string,
            'YYYYMMDDTHH24MISS'))::date                         as extract_month
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    inner join newest_pam_file as nf on nf.file_path = p._file_path   -- P1
    where p.countrycode like $country
      and upper(p.seller_name) like upper($seller)                    -- P5
),

attrition as (
    select 1 as ord, 'P1+P5 newest file, country+seller' as stage,
           'the baseline every later number is a share of'    as effect,
           combined_ref, collections from unguarded
    union all
    select 2, 'P2 PMODE_NAME = Real',
           'drops internal accounting batches',
           combined_ref, collections from unguarded
     where pmode_name = 'Real'
    union all
    select 3, 'P3 + no ownership-change rows',
           'a legal-buyer transfer repeats a batch-month',
           combined_ref, collections from unguarded
     where pmode_name = 'Real' and is_ownership_change = 0
    union all
    select 4, 'P4 + actual months only',
           'plan months run past 2040 and read as real cash',
           combined_ref, collections from unguarded
     where pmode_name = 'Real' and is_ownership_change = 0
       and reporting_month < extract_month
    union all
    -- ⚠ NOT APPLIED ABOVE. Shown so the decision is informed, not inherited.
    select 5, 'then One-off only (YOU must apply this)',
           'forward flow has no fixed population, so no vintage',
           combined_ref, collections from unguarded
     where pmode_name = 'Real' and is_ownership_change = 0
       and reporting_month < extract_month
       and deal_type = 'One-off'
)

-- A. the scope itself ---------------------------------------------------------
select
    'A. batch in scope'                                         as report,
    combined_ref                                                as item,
    portfolioid || ' · ' || currency || ' · capex ' || capex_month
        || ' · ' || deal_type                                   as detail,
    null                                                        as loans,
    reported_months                                             as months,
    collecting_months,
    first_collecting_month,
    last_collecting_month,
    lifetime_collections,
    acquisition_principal,
    -- ⚠ a batch whose whole lifetime is ONE collecting month equal to its own
    -- acquisition principal is almost certainly an opening posting, not cash.
    (collecting_months = 1 and lifetime_collections = acquisition_principal)
                                                                as looks_like_opening_posting
from batches

union all

-- B. which Intrum instance holds these batch refs? ----------------------------
-- NO _file_path prefix filter here, deliberately: the batch-ref filter is what
-- keeps it affordable, and adding an instance filter would beg the question.
select
    'B. instance holding them',
    split_part(c._file_path, '.', 2)                            as item,
    'CASES history rows: ' || to_char(count(*), '999,999,999,999'),
    count(distinct c.case_id),
    count(distinct c.long_portfolio_id),
    null, null, null, null, null, null
from RAW.HYPERION_INTRUM_CAT.CASES as c
where c.long_portfolio_id in (select combined_ref from batches)
group by 1, 2

union all

-- C. what each guard removed ---------------------------------------------------
-- ⚠ READ THIS BEFORE QUOTING ANY TOTAL. A guard that removes nothing on your
-- book still has to be carried -- it removes a great deal on another.
select
    'C. filter attrition',
    stage,
    effect,
    COUNT(distinct combined_ref),
    null,
    null, null, null,
    SUM(collections),
    null,
    null
from attrition
group by ord, stage, effect

order by report, lifetime_collections desc nulls last, item;
