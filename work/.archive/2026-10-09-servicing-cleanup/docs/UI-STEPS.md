# What to click in Sigma, and why I cannot do it for you

**Workbook:** [Servicing Dashboard](https://app.sigmacomputing.com/brocc/workbook/Servicing-Dashboard-3E2KNssZ3EtlbA7RrRNyMt) · v41 · 2026-10-08

> ⚠ **Out of date as of 2026-10-08:** `bar-chart` is now accepted by
> `contents update` (see README §7). The probe below was true when written.

## Why this is a UI job

The only write API is `workbooks contents update`, and its body comes from
`spec get`. **That format does not contain bar charts.** Measured on a throwaway
copy: the workbook had 43 elements and 2 bar charts; a push of a one-character
text edit returned 41 elements and **0 bar charts**. The push rebuilds the
workbook from what it was given, and charts are never in what it is given.

Nor can they be re-added. Thirteen kind names were rejected with `Invalid kind`:
`bar`, `visualization`, `chart`, `column`, `line`, `area`, `bar-chart`,
`column-chart`, `line-chart`, `combo-chart`, `area-chart`, `pie-chart`,
`scatter-chart`. The only creatable kinds are `table`, `pivot-table`,
`kpi-chart`, `region-map`, `text`, `control`, `container`.

So any push from me deletes both charts, and setting a chart's axes is UI-only
anyway. Doing it yourself is strictly less work.

---

## Step 1 — Rename the six toggles

Right-click each control → **Change control display name**.

| Tab | Control | Now | Change to |
|---|---|---|---|
| Collections Overview | `coGrain` | Sort by grain | **Focus by grain** |
| Collections Overview | `coBeh` | Sort by behaviour | **Focus by behaviour** |
| Cases Overview | `caGrain` | Sort by grain | **Focus by grain** |
| Cases Overview | `caBeh` | Sort by behaviour | **Focus by behaviour** |
| Geographic Coverage | `geGrain` | Sort by grain | **Focus by grain** |
| Geographic Coverage | `geBeh` | Sort by behaviour | **Focus by behaviour** |

⚠ Change the **display name** only. The underlying control id (`co-Grain`,
`ge-Behaviour`, …) is what every Switch formula references — rename that and
each sort key silently returns `Unknown column` as *text*, not an error.

## Step 2 — The two bar charts

### `dNeeD3xo1g` — "Behaviour sort key by Grain sort key"

Reads **Coverage detail** (`geoTable`), and already carries both key columns.
Sigma names charts "⟨value⟩ by ⟨category⟩", so by its own name it is already
wired. Just confirm:

- Category / Y axis → **Grain sort key**
- Value / X axis → **Sum of Behaviour sort key**

Then rename it something readable — "Focus" or "Coverage by focus".

### `zt5MkNrgKV` — "New Bar Chart"

Unconfigured, and pointed at the raw `Portfolios` source rather than a table, so
it has no Grain or Behaviour sort key to use. Either:

- **delete it**, or
- change its source to **Coverage detail** and set the same two axes.

## Step 3 — Clear the sort on the three tables

`Collections by portfolio`, `Cases by portfolio`, `Coverage detail`.

Each is currently sorted `[Grain sort key ascending, Behaviour sort key
descending]`. Clear that so people sort by clicking a column header.

**Keep both key columns on the element** — hidden is fine. The charts read them.

## Step 4 — Trim the behaviour options to things that can be summed

A bar chart sums the value axis. Three behaviour options are **ratios computed
per row**, so summing them is meaningless — it is the "never average a ratio"
rule from the Data & Definitions page:

| Safe to sum | Do NOT offer on a chart |
|---|---|
| Collections, Net collections, Servicer cost | % of forecast |
| Payers, Cases ever collected, Cases on book | Cost % of gross |
| Collected cases, New, Lost, First collection | Penetration |

Remove those three from the **chart's** behaviour control. They are fine as
table columns, where each row shows its own ratio.

To rank by penetration visually it needs an aggregate-level formula rather than
a summed row ratio:

    Sum([Cases Ever Collected]) / Sum([Cases on Book])

## Step 5 — Re-run the checks

    cd work/servicing && uv run python tests/dashboard_tests.py

31 cases, 30 exact to the cent. The one at 0.053% is the country map, which is
FX rounding across six currencies. Results append to `tests/results.csv`.

---

## Two things worth knowing while you are in there

**The Reporting Month filter reaches everything except three map options.**
Every element reads `ROIia0oTOr` and the control filters that source. But
Balance, Cases on book and Cases ever collected on the map use
`[F] Is Current Month Flag`, which compares against `latest_reporting_month` —
a SQL window computed before Sigma's filter. Those three always mean August.
Filter to Jan–Jun and they read zero.

**`[F] Is Current Month Flag` is used in exactly one formula** — the map's
`Selected metric`. Five other elements only inherit it.
