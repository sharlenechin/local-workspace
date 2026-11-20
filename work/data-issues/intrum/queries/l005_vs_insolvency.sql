-- Does phase code L005 ("Insolvency" per the CUSTOM_CODE label on instance
-- 1137, see work/data-issues/intrum/phase-codes.md) line up with the two
-- insolvency date sources we already have?
--   (1) RAW BANKRUPTCY_RECORD.INSOLVENCY_OPEN_DATE  — not modelled in PROD
--   (2) DIM_CASE versions whose STATUS_CODE is in the insolvency group
--       (12/35/36/59/67/69/73/315 — OUR grouping of Intrum's descriptions),
--       dated by EFFECTIVE_FROM_DATE (the only reliable status date in PROD).
--
-- Guards: phase feed filtered to deleted/archived/unlinked = 0; start_date
-- bounded to <= current_date because the feed carries 1900-01-01 and 2202
-- values (phase-codes.md, data-quality notes). BANKRUPTCY_RECORD has no
-- usable record key (Elsa FINDINGS §8) so it is collapsed to min/max open
-- date per case; its soft-delete flags, if any, are NOT applied here.
-- DIM_CASE is joined on CASE_BK, all versions (CASE_SK is a version key).
set prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.%';

with l005 as (
    select split_part(g._file_path, '.', 2)                        as instance,
           split_part(g._file_path, '.', 2) || '-' || g.case_id    as case_bk,
           min(g.start_date::date)                                 as l005_first_on
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE as g
    where g._file_path like $prefix
      and g.group_phase_code = 'L005'
      and g.start_date is not null and g.start_date::date <= current_date
      and coalesce(g.deleted, 0) = 0 and coalesce(g.archived, 0) = 0
      and coalesce(g.unlinked, 0) = 0
    group by 1, 2
),

bk_record as (
    select split_part(b._file_path, '.', 2)                        as instance,
           split_part(b._file_path, '.', 2) || '-' || b.case_id    as case_bk,
           min(b.insolvency_open_date::date)                       as bk_open_on
    from RAW.HYPERION_INTRUM_CAT.BANKRUPTCY_RECORD as b
    where b._file_path like $prefix
    group by 1, 2
),

insolvency_status as (
    select c.case_bk,
           split_part(c.case_bk, '-', 1)                           as instance,
           min(c.effective_from_date)                              as status_first_on
    from PROD.NPL_COMMON.DIM_CASE as c
    where c.status_code in ('12','35','36','59','67','69','73','315')
    group by 1, 2
),

-- one row per case that appears in ANY of the three sources
universe as (
    select instance, case_bk from l005
    union select instance, case_bk from bk_record
    union select instance, case_bk from insolvency_status
),

joined as (
    select u.instance, u.case_bk,
           l.l005_first_on, b.bk_open_on, s.status_first_on
    from universe as u
    left join l005              as l on l.case_bk = u.case_bk
    left join bk_record         as b on b.case_bk = u.case_bk
    left join insolvency_status as s on s.case_bk = u.case_bk
)

-- A. per instance: how many cases each source marks, and the overlaps
select 'A. coverage' as block, instance,
       count_if(l005_first_on is not null)                                     as n_l005,
       count_if(bk_open_on is not null)                                        as n_bk_record,
       count_if(status_first_on is not null)                                   as n_status_insolv,
       count_if(l005_first_on is not null and bk_open_on is not null)          as l005_and_bk,
       count_if(l005_first_on is not null and status_first_on is not null)     as l005_and_status,
       count_if(bk_open_on is not null and status_first_on is not null)        as bk_and_status,
       null::number                                                            as median_days,
       null::number                                                            as pct_within_30d
from joined
group by 1, 2
union all
-- B. where both dates exist: how far apart are they (L005 start minus other date)
select 'B. L005 vs BK_RECORD date', instance,
       count(*), null, null, null, null, null,
       median(datediff('day', bk_open_on, l005_first_on)),
       round(100.0 * count_if(abs(datediff('day', bk_open_on, l005_first_on)) <= 30) / count(*), 3)
from joined
where l005_first_on is not null and bk_open_on is not null
group by 1, 2
union all
select 'C. L005 vs status date', instance,
       count(*), null, null, null, null, null,
       median(datediff('day', status_first_on, l005_first_on)),
       round(100.0 * count_if(abs(datediff('day', status_first_on, l005_first_on)) <= 30) / count(*), 3)
from joined
where l005_first_on is not null and status_first_on is not null
group by 1, 2
union all
select 'D. BK_RECORD vs status date', instance,
       count(*), null, null, null, null, null,
       median(datediff('day', status_first_on, bk_open_on)),
       round(100.0 * count_if(abs(datediff('day', status_first_on, bk_open_on)) <= 30) / count(*), 3)
from joined
where bk_open_on is not null and status_first_on is not null
group by 1, 2
order by 1, 3 desc;
