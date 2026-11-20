-- What does each GROUP_PHASE_CODE mean?  No dictionary in the feed, so infer
-- from (1) CUSTOM_CODE if it carries a label, (2) where the code sits in a
-- case's phase sequence: share that is a case's first spell, share that is
-- its latest, and the most common code that precedes it.
set prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.%';
with spells as (
    select distinct
           split_part(_file_path, '.', 2) || '-' || case_id as case_bk,
           group_phase_code, custom_code, start_date::date as start_date
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE
    where _file_path like $prefix
      and group_phase_code is not null and start_date is not null
      and coalesce(deleted,0)=0 and coalesce(archived,0)=0 and coalesce(unlinked,0)=0
),
ordered as (
    select case_bk, group_phase_code, custom_code, start_date,
           row_number() over (partition by case_bk order by start_date, group_phase_code) as pos,
           count(*)     over (partition by case_bk)                                         as n_spells,
           lag(group_phase_code) over (partition by case_bk order by start_date, group_phase_code) as prev_code,
           lead(group_phase_code) over (partition by case_bk order by start_date, group_phase_code) as next_code
    from spells
)
select group_phase_code,
       count(*)                                                    as n_spells,
       count(distinct case_bk)                                     as n_cases,
       round(100.0 * count_if(pos = 1) / count(*), 2)              as pct_first_spell,
       round(100.0 * count_if(pos = n_spells) / count(*), 2)       as pct_latest_spell,
       mode(prev_code)                                             as usual_previous,
       mode(next_code)                                             as usual_next,
       mode(custom_code)                                           as usual_custom_code,
       count(distinct custom_code)                                 as n_custom_codes,
       min(start_date)                                             as first_seen,
       max(start_date)                                             as last_seen
from ordered
group by 1
order by n_spells desc;
