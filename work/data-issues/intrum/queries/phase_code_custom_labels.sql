set prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.%';
select group_phase_code, coalesce(custom_code, '(null)') as custom_code,
       listagg(distinct split_part(_file_path, '.', 2), ',') within group (order by split_part(_file_path, '.', 2)) as instances,
       count(distinct split_part(_file_path, '.', 2) || '-' || case_id) as n_cases
from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE
where _file_path like $prefix and group_phase_code is not null
  and coalesce(deleted,0)=0 and coalesce(archived,0)=0 and coalesce(unlinked,0)=0
group by 1, 2
qualify row_number() over (partition by group_phase_code order by n_cases desc) <= 6
order by 1, 4 desc;
