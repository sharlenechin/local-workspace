# Servicer Data Quality — what the page shows and how each part is built

For whoever changes the dashboard next. The reviewed design is the canvas
(`design/project/Servicer.dc.html`); this says how each part of it became Sigma.

## 1. The page

One page, for one servicer at a time, so it can be shared with that servicer.

| Part | What it shows |
|---|---|
| **Header** | As the Servicing dashboard's: title, **Servicer** toggle (default Intrum), **Quick Filter Months** toggle (Latest Month · L3M · L6M · L12M · All Time), then one row of filters: **Month Filter** (from – to), Country, Deal, Portfolio, **Purchase Price** (a range, so "more than 10m" works) and **Clear Filters** (clears those five) |
| **Dark band** | Six tiles, each "passing / applicable": Portfolio Feed Received · Case Feed Received · Months Overlap · Collections Reconciled · Balance Reconciled · Forecast Received |
| **Tables** | **Show By** toggle: By Portfolio, or By Combined Ref (`DIM_BATCH.BATCH_BK`; other servicers call it their Portfolio ID). **Show** filters to Needs Action or Healthy. Columns: the names (Portfolio Name, Combined Ref, Deal, Country, Currency), then **Status** and **Issues**, then the coloured checks (Portfolio Feed, Case Feed, Months Overlap %, Collections, Balance, Forecast), then the figures behind them (Purchase Price, Combined Ref Count, Months Overlap as months, feed dates, Collections and Balance per feed with Difference %, Not in Case Feed, Balance Case Feed (Open Cases) with its Difference % and (All Cases) beside it, Cases (Open) and (All)). **The three comparisons** (the user, 2026-10-14): collections against every payment (as Servicing); balance against open cases, all-cases shown beside; cases open against all, not checked because the report's case count is not in PROD. Biggest purchase price first; any header sorts |
| **Not the Servicer's Fault** | What is on Brocc's side, so nobody chases a servicer for it. Those cells are grey, never red |

## 2. Which months a figure covers

- **To month** = the newest month left in view (`GrandTotal(Max(...))` over the rows the filters keep):
  **last month**, since both queries stop at today. It shows even while it is still arriving (the user,
  2026-10-13). A report is **due by the 15th of the month after** (every Intrum report since Feb 2026 reached the
  warehouse between the 10th and the 14th); until then a missing one reads **Not Yet Received** in amber, is not an
  issue, and is left out of the tiles. A tile none of whose portfolios is due reads **Not Yet Due**.
  The query still labels each month Complete or Loading (the Servicing rule) for anyone who needs it.
- **Quick Filter Months** counts back from the To month. **Month Filter** narrows the rows first, so it can move
  the To month back, and with All Time it shows exactly the chosen range.
- **Flows add up** over the months shown: collections. **Stocks are read at the To month**: balance, cases,
  case feed status, forecast, feed dates, Months Overlap. Portfolio Feed counts the months missing.
- Everything starts **Jun 2014** (the manager, 2026-10-13), the first month PROD holds a case feed.

## 3. Each check

| Check | Passes when | Source |
|---|---|---|
| Portfolio Feed | the report came in every month shown | `FCT_PORTFOLIO_SNAPSHOT_MONTHLY` |
| Case Feed | at the To month, every ref the report carries is also in the case list | `FCT_CASE_SNAPSHOT_DAILY` |
| Months Overlap | every month the report came, the case list came too (Jun 2014 to the To month) | both |
| Collections | **the Servicing dashboard's own flag, month by month** (case-feed payments within 10% of the report's, payments in at least 80% of the months reported since acquisition, never Italy), so a portfolio reads Reconciled here exactly when it does there. Over several months: Reconciled only if every month reported was. A combined ref has no such flag and is checked on the 10% alone | `FCT_CASE_COLLECTION` |
| Balance | case-feed outstanding total of **open** cases within 10% of the report's total balance, at the To month. The report is the figure trusted (the user, 2026-10-14) | both |
| Forecast | a servicer forecast exists for the To month | `FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY` |

Case Feed values: Received · Partly Received (some refs) · Under Another Ref (cases there, under refs the
report does not use: Massey) · Stopped (sent before, not now) · Not Received.
Collections values: Reconciled · Not Reconciled · Payments in Under 80% of Months · No Payments ·
Not Loaded by Brocc (Cerved, Gescobro) · No Portfolio Feed.

Balance, both sides, read at month-end:

| Servicer | Report (`TOTAL_BALANCE`) | Case feed (`OUTSTANDING_TOTAL`) |
|---|---|---|
| Intrum | remaining principal + interest + fees (dbt adds the three PAM fields) | principal + interest + fees per case; which fields depends on the Intrum system |
| Cerved, Gescobro | one total field | one total field (no split) |
| Massey, Fire | one total field | Massey's under other refs; Fire sends none |
| Souq | from Intrum's report | total claim; one file of Sep 2025, carried forward every month since |

**Closed cases are left out of the case feed** (`case_book_by_ref`, one read of the snapshot). The snapshot keeps a case on the list after
it closes, with its last balance: on 31 Aug 2026, 9.0m of Intrum's 19.5m listed cases were closed (20.2bn), against
8.8m open cases in Intrum's own report. Leaving them out took Intrum refs within 10% from 1,335 to 9,590 of 11,130.
`DIM_CASE` is one row per case version; the snapshot points at the version valid at each month-end, so a case is
closed when that version's closing date is on or before the month-end. Their balance shows as Closed Cases Balance.
Cases still counts every case listed, so it equals the Servicing dashboard's cases on book; Open Cases is the open ones. Collections count every payment, closed cases included: 0.4–0.9% of the money a month, Dec 2025 – Aug 2026. The right fix is in
`FCT_CASE_SNAPSHOT_DAILY` (data team).

## 4. Servicer

Per combined ref: the servicer the case feed names (`DIM_REPORTING_SYSTEM.servicer_name`). No ref has ever
had two. A ref with no case feed takes its portfolio's main servicer; a portfolio with no case feed at all
takes the manager's business rule (as Servicing). So HEI-GR25001-U04, with 2 Intrum refs and 1 Souq ref, is
one row under each (the user, 2026-10-13).

## 5. How it is built in Sigma

| Element | What it is |
|---|---|
| `src` "Portfolio Months" | `sigma_queries/portfolio_months_element.sql`, one row per portfolio x servicer x month |
| `ref_src` "Combined Refs" | `sigma_queries/combined_refs_element.sql`, one row per combined ref x month |
| `pm_by_port`, `ref_by_ref` | hidden helpers on the Model page, grouped per portfolio / per ref; every check is a formula here |
| `t_port`, `t_ref` | the visible tables: one flat row per group (`source.groupingId`), colours (the user, 2026-10-14): a check in words colours its **text** (`single` rules: grey ours, green, amber, red); Months Overlap % fills its **cell** on a scale, red 0% → amber 50% → green 100% (`backgroundScale`); Collections and Balance Difference % likewise, green at 0% and red at ±50% and beyond, in `tabs`, a tabbed container with its tab bar hidden |
| `f_showby` | the Show By toggle: one on-change action per value selects that tab (`select-tab`; the JSON shape read back from a probe workbook, 2026-10-14) |
| `t_tiles` | a hidden copy of the portfolio rows for the tiles, so the Show filter never changes a tile |
| `k_*` | the tiles: KPI elements whose value is text, `Text(passing) & " / " & Text(applicable)` |

Rules carried over from Servicing (`work/servicing/docs/HOW-IT-WORKS.md`): always prefix a source column
(`[Portfolio Months/x]`); a single-select list control takes `value`, not `values`; a text `{{ }}` reads only
raw SQL columns; a group with no row in the months shown is filtered out by its hidden **In View** column.

## 6. Speed

Both queries scan the 1.5bn-row case snapshot. Measured 2026-10-13: 66–82s for the portfolio query and
82–100s for the ref query in a notebook; each tile exported from Sigma in about 50s. Leaving closed cases out
(2026-10-14) joins the snapshot to `DIM_CASE`: 140–240s per query in a notebook, about 155s per tile in Sigma.
**Too slow for viewers without a nightly copy.** The fix is a nightly copy: Sigma materialisation of `src` and `ref_src` (the PROD
connection supports it), or a dbt table from the data team, as Servicing has.
