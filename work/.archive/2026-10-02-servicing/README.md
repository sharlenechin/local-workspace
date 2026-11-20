# Retired 2026-10-02 — the servicing base layer and the stale Sigma copy

**This folder is safe to delete.** Nothing in the workspace reads it. It exists
only because `local-workspace` is not under git, so there is no other way back
if something here turns out to be wanted.

The servicing work was consolidated into one folder,
[`work/servicing/`](../../servicing/) — six Sigma elements and their two
documents — plus [`work/data-issues/intrum/`](../../data-issues/intrum/) for the
feed problems. This is everything that did not earn a place in either.

| Here | Was | Why it went |
|---|---|---|
| `prod/` | `work/servicing/prod/` — 30 `.sql` | The base layer: one grain-checked view per PROD object, built to a coverage goal (29 of 32 objects). **Nothing read it.** Every dashboard figure now comes from the six elements, which go straight to the facts. |
| `raw/` | `work/servicing/raw/dash_phase_collections_wide.sql` | A column-shaped reshape of the phase split. The split itself was retired from the dashboard on 2026-09-17; the long-form prototype was kept, in `data-issues/intrum/queries/`. This reshape was not. |
| `sigma-stale-2026-09-21/` | `work/servicing/sigma/` — 7 `.sql` | A second, **drifted** copy of the six elements plus the retired 900-line `dash_portfolio_overview.sql`. Case Metrics differed by 274 lines, Reconciliation 186, Portfolio Metrics 77, FX Table 64. Keeping two copies is how the wrong one gets pasted into Sigma. |
| `dashboard.ipynb` | `work/servicing-dashboard/` | 41 cells touring the `prod/` base layer. Every cell calls `datalake.q("servicing/prod/…")`, so it cannot run without the folder above. |
| `dash_portfolio_payer_monthly.sql` | `work/servicing-dashboard/` | 300 lines, portfolio × month payer dynamics. Superseded by the dbt model `mart_npl_servicing_agg_cases_monthly`, which does the same work once instead of on every refresh. |
| `test.sql` | `work/servicing-dashboard/` | 37 lines, no header, scratch. `DBT-HANDOFF.md` model 2 cites it as the `lag()` pattern, which is the only reason it is here. |
| `make_sigma_sql.py` | `setup-scripts/` | Generated paste-ready Sigma SQL from the `prod/` sources by stripping `set` lines and substituting `$variables`. Its only input was `prod/dash_portfolio_overview.sql`. The six elements are now written directly in Sigma's dialect, so there is nothing to generate. The `mise run sigma-sql` task went with it. |
| `README-old-servicing.md` | `work/servicing/README.md` | Described the three-folder `prod/` `raw/` `sigma/` split. |
| `README-sigma-folder.md` | `work/dbt/models/marts/mart_servicing/sigma/README.md` | Its content is folded into `work/servicing/README.md`. |

## ⚠ One thing in here is not reproducible from PROD

`prod/base_data_quality.sql` and its two sibling check suites measured live
rather than repeating what was true when they were written. If you want those
checks back, they are worth reading before rewriting them — they encode which
PROD objects were worth checking and what "bad" looked like on each.
