# Retired 2026-10-02 — the platinum layer, entire

**Safe to delete.** Nothing in the workspace reads it. Kept only because
`local-workspace` is not under git.

The durable findings were lifted out before this moved, into
[`../../dbt/PLATINUM-FINDINGS.md`](../../dbt/PLATINUM-FINDINGS.md). Read that
first — it is the reason any of this mattered.

| Here | Was | What it was |
|---|---|---|
| `work-platinum/` | `work/platinum/` | 4 standalone queries (`dim_portfolio_case`, `agg_case_collection_monthly`, `agg_portfolio_collection_monthly`, `agg_portfolio_forecast_monthly`) plus the two dated forecast-variance CSVs that had no stored query |
| `npl_platinum/` | `work/dbt/models/marts/` | 9 dbt models + `models.yml` — the general-purpose layer |
| `npl_platinum_snowflake/` | same | GENERATED runnable copies of those 9, siblings inlined as subqueries |
| `npl_platinum_updated/` | same | 2 dimension models telling a loan's and a portfolio's history as dense event rows, + a long README |
| `npl_platinum_updated_snowflake/` | same | GENERATED copies of those 2 |
| `make_platinum_sql.py` | `setup-scripts/` | regenerated both `*_snowflake` folders. The `mise run platinum-sql` task went with it |
| `make_platinum_xlsx.py` | `setup-scripts/` | ran every model into one Excel workbook, a sheet each. `mise run platinum-xlsx` went with it |

**Why:** nothing consumed the layer. The one model genuinely needed was built
directly as `mart_npl_servicing_agg_cases_monthly` and raised to `brocc-data`.
Keeping nine models in two dialects each, for no consumer, was eighteen things
to keep true for nothing.
