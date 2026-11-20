# Servicing clean-up, 2026-10-09

Moved here from `work/servicing/` when the folder was prepared for data-engineer
and UI review. Nothing here runs or is read by the dashboard.

| Was | Why retired |
|---|---|
| `.before/` | Pre-change snapshots of the RETIRED workbook (65a9392f). Sigma version history is the real undo |
| `docs/BUILD-GUIDE.md`, `docs/DASHBOARD-DESIGN.md`, `docs/UI-STEPS.md` | Earlier designs; superseded by `work/servicing/design/` and `docs/DESIGN.md` |
| `docs/LIVE-WORKBOOK.md`, `docs/WORKBOOK-BASELINE-2026-10-07.md` | Describe the retired workbook |
| `docs/FINDINGS-EXEC.md` | Findings measured 2026-10-06; the dashboard's own headlines replace them |
| `docs/FLAGS.md` | Half stale (its Diagnostics page was deleted 2026-09-17). The caveats that still stand are in `work/servicing/README.md` §3 |
| `sigma_queries/superseded/` | The six-element design, measured slower (10.8s vs 4.6s). Still a readable record of the derivations |
| `scripts/add_bar_charts.py` | Pushed the v50 bar charts; the redesign uses line charts |
| `tests/dashboard_tests.py` | Replaced by `work/servicing/tests/run.py` and its suites, which keep every one of its checks |

## Added later on 2026-10-09

- `CaseBehaviour.csv`: the case behaviour key the user uploaded to Sigma by hand. Its six rows are now built from code (`sigma_build/user_edits.json`, a VALUES table), because Sigma's verify cannot resolve an uploaded CSV source.
- `servicing/tests/results.csv` was rotated to `tests/history/results-to-2026-10-09.csv` when suite 9 (controls) was added.
- `sigma_queries/live/` and `sigma_queries/proposed/` were renamed: the query the dashboard runs is now `sigma_queries/portfolios_element.sql`; the retired dashboard's is `sigma_queries/retired/portfolios_element_v1.sql`.
