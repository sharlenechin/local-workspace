-- ============================================================================
-- portugal_millenium_batch_audit — companion to portugal_millenium_batches.sql.
-- Answers one question: did every COMBINED_REF I asked for actually return
-- rows, and if not, why not?
-- GRAIN: one row per requested ref.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/portugal_millenium_batch_audit.sql
--   Notebook : datalake.q("benchmark/portugal_millenium_batch_audit",
--                         batch_list="PT050030000000,PT06014B010000")
--
-- ⚠ WHY THIS FILE EXISTS. portugal_millenium_batches.sql applies $country and
-- $seller ON TOP of $batch_list. A ref that is real but sits outside
-- Portugal/Millennium returns NO ROWS AND NO WARNING — indistinguishable from
-- a typo, and it silently shrinks any total you take. Keep $batch_list,
-- $country and $seller here identical to the values in that file, or this
-- audit describes a different question than the one you ran.
--
-- STATUS values:
--   'ok'                      in scope, months returned
--   'outside scope (XX/NAME)' real batch in the current delivery, but excluded
--                             by $country / $seller — the dangerous case
--   'not in current delivery' no such ref in the newest PAM file at all,
--                             i.e. a typo or a batch that has stopped being
--                             reported
--
-- Guards 1-3 match the main file (newest real file, PMODE_NAME = 'Real', no
-- ownership-change rows). Guard 4 (actual months only) is applied to
-- MONTHS_RETURNED so the count agrees with what the main file prints.
-- ============================================================================

set batch_list = '%';         -- COMBINED_REF values, comma-separated; '%' = all
set country    = 'PT';        -- keep identical to portugal_millenium_batches.sql
set seller     = 'MILLENNIUM';


with requested_batches as (
    select distinct upper(trim(value::string)) as combined_ref
    from table(split_to_table($batch_list, ','))
),

newest_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'                             -- Guard 1
),

-- every batch in the delivery, BEFORE country/seller narrowing: this is what
-- separates "wrong scope" from "does not exist"
all_batches_in_file as (
    select distinct
        upper(p.combined_ref)  as combined_ref,
        p.countrycode,
        upper(p.seller_name)   as seller
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    cross join newest_file as nf
    where p._file_path = nf.file_path                                    -- Guard 1
      and p.pmode_name = 'Real'                                          -- Guard 2
      and coalesce(p.is_ownership_change, 0) = 0                         -- Guard 3
),

-- the same rows the main file would return, at batch grain
in_scope as (
    select
        upper(p.combined_ref) as combined_ref,
        count(*)              as months_returned,
        min(p.period_start_date::date) as first_month,
        max(p.period_start_date::date) as last_month
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    cross join newest_file as nf
    where p._file_path = nf.file_path                                    -- Guard 1
      and p.pmode_name = 'Real'                                          -- Guard 2
      and coalesce(p.is_ownership_change, 0) = 0                         -- Guard 3
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
      -- Guard 4: actual months only, so this agrees with the main file
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'
          ))::date
    group by upper(p.combined_ref)
)

select
    r.combined_ref                                as requested_ref,
    case
        when s.combined_ref is not null then 'ok'
        when a.combined_ref is not null
            then 'outside scope (' || a.countrycode || '/' || a.seller || ')'
        else 'not in current delivery'
    end                                           as status,
    coalesce(s.months_returned, 0)                as months_returned,
    s.first_month,
    s.last_month
from requested_batches as r
left join all_batches_in_file as a on a.combined_ref = r.combined_ref
left join in_scope            as s on s.combined_ref = r.combined_ref
-- '%' is the "no list given" sentinel, not a real ref; nothing to audit then
where $batch_list != '%'
order by
    case
        when s.combined_ref is not null then 2
        when a.combined_ref is not null then 1
        else 0
    end,
    r.combined_ref;
