# Servicer Data Quality dashboard

A Sigma dashboard, built to be shared with each servicer (Intrum and the others), that answers **"did
you send us your feeds, and do they agree?"**, per portfolio and per combined ref. It reads Snowflake
PROD `NPL_COMMON` only: portfolios in `DIM_PORTFOLIO`, from Jun 2014.

| | |
|---|---|
| **Workbook** | [Servicer Data Quality (staging)](https://app.sigmacomputing.com/brocc/workbook/4BLpoS2CGnEgQ0m7SeHolH) · built by `sigma_build/build_workbook.py` · id in `sigma_build/workbook.json` |
| **Design** | [Data Quality Dashboard canvas](https://claude.ai/artifact/7PxNnqHAYXTjMEjya6TcAv) · source in `design/project/Servicer.dc.html` · how it maps to Sigma in [`docs/DESIGN.md`](docs/DESIGN.md) |
| **Tests** | `uv run python work/data-quality/tests/run.py`: 47 checks (~15 min; `--no-live` skips Sigma, 30 checks) · every run appended to `tests/results.csv` · 2026-10-14: the 30 SQL checks pass; the live ones wait for the nightly copy |
| **Retired** | `../.archive/2026-10-13-dq-feed-checks/` (the canvas's first query), `../.archive/2026-10-13-dq-internal-scorecard/` |

## 1. Files

```
work/data-quality/
├─ README.md                             start here
├─ docs/DESIGN.md                        what each part of the page shows, which months, each check, the Sigma build
├─ sigma_queries/
│  ├─ portfolio_months_element.sql       one row per portfolio x servicer x month: tiles and By Portfolio
│  └─ combined_refs_element.sql          one row per combined ref x month: By Combined Ref
├─ sigma_build/
│  ├─ build_workbook.py                  builds the whole workbook from the two queries
│  ├─ contents.json                      what was sent (generated)
│  └─ workbook.json                      which workbook the build and the tests point at
├─ tests/run.py                          every check: query, warehouse, Servicing, live
├─ queries/servicer_presence_check.sql   where one servicer appears in PROD (SET servicer = 'cerved')
└─ design/                               the reviewed canvas, its data file and the Sigma theme
```

## 2. The figures (Intrum)

The page opens on last month. Live Sigma export, 2026-10-14 (v8), Sep 2026: Intrum's September report is due by 15 Oct.

| Tile | Intrum, Sep 2026 |
|---|---|
| Portfolio Feed Received | Not Yet Due |
| Case Feed Received | 183 / 249 |
| Months Overlap (both feeds every month since Jun 2014) | 58 / 249 |
| Collections Reconciled | Not Yet Due |
| Balance Reconciled | Not Yet Due |
| Forecast Received | 249 / 249 |

Aug 2026 (query, 2026-10-14): Balance within 10% on 109 of 177 Intrum portfolios with both feeds, once closed cases
are left out (65 before).

## 3. Same number as the Servicing dashboard

**Collections Reconciled is the Servicing dashboard's own flag**, so a portfolio that is Reconciled (or not) there reads
the same here, in every month. Over several months, Reconciled here means every month was.


Where both dashboards show the same figure, it is the same number, checked on every portfolio-month the
Servicing dashboard covers (Dec 2025 – Aug 2026, 1,839):

| Figure | Result |
|---|---|
| Portfolios reporting | identical |
| Collections reconciled | identical (the same rule: within 10%, and case payments in 80% of months since acquisition) |
| Case feed collections, cases on book | identical to the Servicing mart |
| **Has a case feed** | **differs by definition**: Servicing counts a case feed only once payments arrive (its dbt mart is built from payments); this dashboard counts the monthly case list. 332 portfolio-months differ: 330 have a case list but no payments (Cerved 27, Gescobro 37 and Souq 9, whose payments are not in PROD; Intrum 257), and 2 have payments but no case list (LOK-BE25013-U02, Apr–May 2026) |
| **Case feed stopped** | **differs by definition**: Servicing says stopped when payments stop; here, when the case list stops. 28 portfolio-months, e.g. HEI-PT25001-U02 sends its case list but no payments since Feb 2026 |

## 4. Not the servicer's fault

Shown on the page, in grey, so no servicer is chased for Brocc's side:

- **Cerved, Gescobro and Intrum Italy collections are not loaded by Brocc.** Intrum Italy (CAT 4034) has no
  transaction ID, so PROD keeps one payment per case; Italy is never reconciled, as on the Servicing dashboard (2026-10-14).
  Cerved and Gescobro: brocc-data's `int_npl_case_collection_conformed`
  unions only Intrum and Massey; RAW holds both servicers' payments. Their collections read "Not Loaded by Brocc".
- **Closed cases are left out of the case feed.** PROD's case table keeps closed cases on the list with their last
  balance (Intrum, Aug 2026: 9.0m of 19.5m, 20.2bn). Balance counts open cases; Closed Cases Balance shows the rest. No case count is shown: the report's is not in PROD. Collections include payments on closed cases (0.4–0.9% a month).
- **Massey's case feed uses other refs** ("Under Another Ref"): the cases are there, under different IDs.
- **Not Yet Received**: last month's report is not due until the 15th; until then it is amber, not an issue.
- **Servicer from the business rule** where a portfolio has no case feed (PROD has no other servicer field).
- **When brocc-data loads Cerved's and Gescobro's payments**, remove the `case_payments_loaded_flag` line from both
  queries, or their collections stay grey.
- Outside the dashboard: 4 case-feed refs on `portfolio_sk = '-1'` (no portfolio in PROD: 3 Intrum, 1 Gescobro).

## 5. Changing it

1. Edit a query or the builder, then `build_workbook.py --dry-run` (Sigma's verify; sends nothing).
2. `build_workbook.py --update <id>` from `workbook.json`, then `tests/run.py`.
3. A new copy: `--create --name "..."`. Undo is Sigma's Version history.

**Speed.** Each query scans the 1.5bn-row case snapshot and, since 2026-10-14, joins it to `DIM_CASE` to leave closed
cases out: 140–240s in a notebook, about 155s per tile in Sigma (limit 120s). It needs a nightly copy (Sigma
materialisation, or a dbt table from the data team) before viewers use it.
