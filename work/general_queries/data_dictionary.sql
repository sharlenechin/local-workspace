-- Data dictionary for the NPL marts.
--
-- Descriptions come from the dbt models in brocc-data: dbt_project.yml sets
-- `persist_docs` for relations and columns, so every build pushes the model
-- docs into Snowflake as native COMMENTs. Snowflake itself is therefore the
-- dictionary — there is no separate catalog to consult.
--
-- Plain SQL with session variables, so this runs in the Snowflake VS Code
-- extension, in `mise run sql`, and from a notebook.
--
--   Extension : open and Run All, then read the results panel
--   Terminal  : mise run sql -- work/general_queries/data_dictionary.sql --open
--   Notebook  : datalake.q("general_queries/data_dictionary")
--                 ...or just datalake.dictionary("fct_case_collection")
--
-- Set TABLE_FILTER to '%' for the whole schema, or a LIKE pattern such as
-- 'FCT_%' or '%COLLECTION%' to narrow it.
set target_schema = 'NPL_COMMON';
set table_filter  = '%';

select 
    c.table_name,
    c.ordinal_position                                  as position,
    c.column_name,
    c.data_type,
    coalesce(nullif(trim(t.comment), ''), '(no table description)')
                                                        as table_description,
    coalesce(nullif(trim(c.comment), ''), '(undocumented)')
                                                        as column_description
from PROD.information_schema.columns as c
inner join PROD.information_schema.tables as t
    on  t.table_schema = c.table_schema
    and t.table_name   = c.table_name
where c.table_schema = $target_schema
  and c.table_name like $table_filter
  and t.table_type = 'BASE TABLE'
order by c.table_name, c.ordinal_position
