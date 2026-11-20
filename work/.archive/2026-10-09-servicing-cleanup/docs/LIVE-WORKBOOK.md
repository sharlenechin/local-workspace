# The live Servicing Dashboard — what actually runs, and four defects in it

**Read from Sigma on 2026-10-02**, partly through the connector and partly from
the workbook YAML. This file describes **what is running**. The six
`sigma_*.sql` files beside it are the *intended rebuild* and are not what the
dashboard uses.

| | |
|---|---|
| Workbook | [Servicing-Dashboard-35PyJTGEJoomrtfdJmBmx9](https://app.sigmacomputing.com/brocc/workbook/Servicing-Dashboard-35PyJTGEJoomrtfdJmBmx9) · `65a9392f-8dcd-4723-83e8-bc01b6d6eab7` |
| Superseded | `dd98cc62-…` — **archived**, link dead |
| Data | **One** table element, `ROIia0oTOr` "Portfolios", from a Custom SQL query. Every other element reads it |

**It has a code representation.** Sigma exposes the workbook as YAML — elements,
controls, filters, KPI formulas, formats. That is the fastest way to review the
whole dashboard at once, and it can be edited and pasted back.

## ⚠⚠⚠ 1. The default view hides half the money

Three "Guardrail Filters" ship with **default values set**:

| Control | Column | Default |
|---|---|---|
| Have Case Level Data | `HAVE_LOAN_DETAIL_FLAG` | `true` |
| **Has been Reconciled** | `IS_RECONCILED_FLAG` | **`false`** |
| Has Servicer Forecast | `HAVE_SERVICER_FORECAST_FLAG` | `true` |

So the dashboard opens showing **only portfolios that do NOT reconcile.**
Measured against the live element:

| Slice | Portfolios | Collections EUR |
|---|---|---|
| `IS_RECONCILED_FLAG = false` ← **the default** | 146 | **114,054,675.19** |
| `IS_RECONCILED_FLAG = true` — excluded by default | 92 | **110,575,839.60** |

**EUR 110.6m — 49.2% of the total — is hidden the moment anyone opens the
page**, and the "Total Collections" KPI reports the remainder as if it were the
book. The default looks inverted: the reconciled portfolios are the trustworthy
ones. Either set it to `true`, or clear it and show the flag as a breakdown.

## ⚠⚠ 2. The rolling averages divide by a constant, and the data says not to

`[M] Average Collections L3M = Sum([Collections L 3 M Sum]) / 3`, and the same
`/6` and `/12` for the other two. But the dataset carries
`MONTHS_IN_L3M_WINDOW` for exactly this reason, and **it is not 3 for everyone**:

| Months in the L3M window | Portfolio-months |
|---|---|
| 1 | 147 |
| 2 | 152 |
| 3 | 831 |

**299 of 1,130 portfolio-months (26.5%) have a short window**, so their L3M
average is understated — by **3×** where only one month exists. A young book
looks like it is collecting a third of what it collects. Divide by
`Sum([Months in L 3 M Window])`, not by 3.

## ⚠ 3. A mislabelled leftover column in the L6M tile

In the L6M KPI element, column `V6oCsLO9uw` is **named** "Average Collections
L6M" and its **formula is** `[[M] Average Forecast L6M]`. It is not the
displayed value (that is `GQ62exaT2y`), so no figure is wrong today — but
anyone editing that tile and reaching for the column by name gets the forecast.
The L3M tile has the same column id holding the correct collections formula, so
this is a copy-paste that was half-updated. The L12M tile likewise carries a
stray `Sum([[M] Average Collections L6M])`.

## ⚠ 4. `[M] Total Paying Cases Newly Activated` is a ratio named as a count

```
(Sum(Coalesce([Payment Loans Ever Paid Count], 0))
 - Sum(If([Reporting Month] = [First Reporting Month], …, 1)))
/ Sum(If([Reporting Month] = [First Reporting Month], …, 1))
```

That is a growth **rate**, `(A − B) / B`. It is named "Total … Cases" and
formatted `',d'` — an integer count — in the Breakdown pivot. Either the name
and format are wrong or the formula is. ⚠ The dataset already has
`PAYING_LOANS_ACTIVATED_COUNT`, which is the count this name promises.

## How to change it

### ⚠ SUPERSEDED 2026-10-07 — the Sigma CLI does this, and it is already set up

`sigma` 1.2.5 is installed with profile `brocc` authenticated by OAuth. Writes
go through it, not through the MCP connector (which is read-only) and not
through the script below:

    sigma -p brocc api workbooks copy            # duplicate before editing
    sigma -p brocc api workbooks contents        # elements, formulas, layout
    sigma -p brocc api workbooks restore-version # the undo

Every change creates a Sigma version, so **Version history → Restore version as
draft** is the real revert — better than any file kept here. Workbooks-as-code
is still Beta at Sigma.

The section below describes the REST credential route, which is no longer the
way in. Kept because the permission notes still explain what access is needed.

### The API route — built and waiting on one permission

`scripts/sigma_workbook.py`, run as `mise run sigma -- …`:

```bash
mise run sigma -- token                        # do the credentials work?
mise run sigma -- pull <workbookId> <file>     # save the YAML
mise run sigma -- push <workbookId> <file>     # dry run by default
mise run sigma -- push <workbookId> <file> --document-version <v> --yes
```

**What is blocking it:** creating the credentials needs the **Admin** account
type or the **"Create API keys"** permission — which is why it could not be
done from an ordinary account. Ask an admin for:

> A REST API credential (Administration → Developer access → Create new → REST
> API scope), **owned by someone who has "Create, edit, and publish workbooks"
> and "Can edit" on the Servicing Dashboard.** The credential inherits the
> owner's rights, so an owner without them gets 403 on every push.

The secret is shown **once**. It goes in `mise.local.toml` or `.env` — both
gitignored — as `SIGMA_CLIENT_ID` and `SIGMA_CLIENT_SECRET`. Never in a tracked
file. Tokens last one hour and the script fetches a fresh one per run.

⚠⚠ **The safety rails are in the script because the endpoint has none.**
`push` is a **dry run** unless you pass `--yes`; it writes a timestamped copy of
exactly what it would send; and it **refuses to push without
`--document-version`**, because without one the API is last-write-wins and will
discard whatever someone changed in the UI since you pulled. `--force` exists
for recovering from a bad push, not for saving a step.

⚠ **`PUT /v2/workbooks/{id}/contents` is Beta**, and no GET for workbook
contents is documented — so `pull` may return 404. If it does, copy the YAML out
of Sigma's code view by hand; `push` is the half that matters.

### The route that works today, with no credentials

Copy the YAML out of the code view into a file here, edit, paste back. Slower,
but a human sees every change and nothing is stored. ⚠ Keep the original as
`.before.yaml` — Sigma's editor replaces everything, so that file is the undo.

## ⚠ One baseline: DIM_PORTFOLIO, and nothing unknown

Every element on the page, and the dbt mart, now take `DIM_PORTFOLIO` as the
population. There is no sentinel leg for fact keys with no dimension row: those
are bad data from Intrum rather than a book Brocc owns, and the dashboard must
not show them.

**Measured 2026-10-02, this now costs nothing.** All **264** portfolio keys in
`FCT_PORTFOLIO_SNAPSHOT_MONTHLY` have a `DIM_PORTFOLIO` row, so **0 portfolios
and EUR 0.00** of EUR 16,823,372,633.30 are excluded. The orphan `'-1'` was
cleaned upstream. ⚠ The 6.38% and 0.24159% figures that appear in older comments
in this workspace are history, not the current state.

⚠ **The baseline has to be the same everywhere.** If one element admits unknown
portfolios and another does not, the reconciliation reports a gap that is only a
scope difference.

## ⚠ The Custom SQL behind `ROIia0oTOr` is version-controlled nowhere

It is a descendant of `dash_portfolio_overview.sql` (retired to
`work/.archive/2026-10-02-servicing/`) but has drifted past it —
`MONTHS_IN_L3M_WINDOW`, `CUMULATIVE_COLLECTIONS_IN_SERVICER_WINDOW_SUM` and
`FX_START_DATE` exist in the live element and in no file here. **Paste it into
this folder.** Until then the query behind every figure on the dashboard exists
only inside Sigma.
