# `work/general_queries/` — queries shared across the whole workspace

Per `~/data-warehouse/CLAUDE.md`: a query belongs **beside the notebook** that
uses it, or **here** if more than one thing uses it. Everything else lives with
the analysis it serves.

| File | Answers |
|---|---|
| `data_dictionary.sql` | Every column in a PROD schema with the dbt model's own description, straight from Snowflake's native `COMMENT`s. Set `table_filter` to narrow it |

```
Terminal  : mise run sql -- work/general_queries/data_dictionary.sql table_filter='FCT_%'
Notebook  : datalake.q("general_queries/data_dictionary")
```

⚠ `datalake` also has **built-ins that need no file** and are usually what you
want: `datalake.dictionary("fct_npl_case_collection")` for one table,
`datalake.describe_column("reporting_system_sk")` for one column across every
table, and `datalake.find_columns("collection")` to search names and
descriptions. The `.sql` file is the whole-schema dump.

**Moved here 2026-10-02** from `work/data_dictionary.sql`, so
`datalake.q("data_dictionary")` is now
`datalake.q("general_queries/data_dictionary")`.
