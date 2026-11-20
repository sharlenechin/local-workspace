-- Raw CAT cases vs DIM_CASE: how many raw cases never reach PROD, by instance.
-- Known deliberate drops: container cases (1033), non-real cases (2080), and any
-- case whose batch is absent from the servicer batch feed (inner join in
-- int_npl_case_conformed). This counts the total gap; reasons need the int layer.
set prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.%';
with raw_cases as (
    select split_part(_file_path, '.', 2) as instance,
           split_part(_file_path, '.', 2) || '-' || case_id as case_bk
    from RAW.HYPERION_INTRUM_CAT.CASES
    where _file_path like $prefix
    group by 1, 2
),
dim as (select distinct case_bk from PROD.NPL_COMMON.DIM_CASE)
select r.instance,
       count(*)                    as raw_cases,
       count(d.case_bk)            as in_dim_case,
       count(*) - count(d.case_bk) as missing,
       round(100.0 * (count(*) - count(d.case_bk)) / count(*), 3) as missing_pct
from raw_cases r
left join dim d on d.case_bk = r.case_bk
group by 1
order by missing desc;
