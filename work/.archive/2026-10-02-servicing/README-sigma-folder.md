# `sigma/` — six Custom SQL elements, pasted into the workbook

None of these is a dbt model. Each is the SQL body of one Sigma element, kept
here so the workbook's logic is reviewable and version-controlled. They re-run
on every dashboard refresh.

| File | Sigma element | Reads |
|---|---|---|
| `sigma_portfolio_information.sql` | Portfolio Information | PROD only — 264 rows, the drill path |
| `sigma_fx_table.sql` | FX Table | PROD only — ⚠ **display** conversion, not measure-building |
| `sigma_portfolio_metrics.sql` | Portfolio Metrics | PROD only — portfolio × month |
| `sigma_forecasts.sql` | Forecasts | PROD only — all three forecasts |
| `sigma_case_metrics.sql` | Case Metrics | thin read of `AGG_NPL_CASE_PAYER_MONTHLY` |
| `sigma_reconciliation.sql` | Reconciliation | thin read of the **same** table |

⚠ **The last two read one table and can never disagree.** They are separate
elements for the workbook's sake, not because the data differs.

⚠ **`sigma_fx_table` is not redundant.** The dashboard computes in EUR and
re-expresses at the last step in whatever currency the reader picked. It is the
join key for that, not for building the measures.

## Order to paste

`Portfolio Information` and `FX Table` first — `Portfolio Metrics` and
`Forecasts` join to both. The two thin reads are independent of all four, but
**cannot run until `agg_npl_case_payer_monthly` is deployed**; no `AGG_NPL_*`
table exists in PROD as at 2026-09-29.

## ⚠ Two gotchas when pasting

**Column names come back quoted Title Case.** A Sigma custom SQL element exposes
`portfolio_sk` as `"Portfolio Sk"`. Reference it that way downstream.

**Sigma's error line numbers count its own expanded SQL**, not the file here, so
a reported line 40 is not line 40 of these files.

## ⚠ A stale second copy exists

`work/servicing/sigma/` holds the same six plus
`dash_portfolio_overview.sql`, last touched **2026-09-21** and drifted — Case
Metrics by 274 lines, Reconciliation 186, Portfolio Metrics 77, FX Table 64.
**These files are canonical.** Retire that folder.
