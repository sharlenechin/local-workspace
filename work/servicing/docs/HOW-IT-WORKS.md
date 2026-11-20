# The Servicing dashboard — how it is built, and how to debug it

For whoever picks this up next: a data engineer changing a model, an architect
reviewing the shape, an analyst asked why a number looks wrong.

Everything below was verified against PROD on **2026-10-07**; paths and the test commands updated 2026-10-09.

---

## 1. Where things are

| | |
|---|---|
| **Servicing Dashboard** | `031548ab-54d6-437f-b452-e728c30cfb5b` — [open](https://app.sigmacomputing.com/brocc/workbook/5OHD9y2g5PaMr3pJqvLV9) · promoted 2026-10-09 |
| Servicing Dashboard (retired 2026-10-09) | `77cac618-7b47-46cb-9171-95ad9976f36d` — the previous design, kept as the fallback |
| Servicing Dashboard (retired 2026-10-08) | `65a9392f-8dcd-4723-83e8-bc01b6d6eab7` — the old one, superseded 2026-10-08 |
| The query | `sigma_queries/portfolios_element.sql` — what the live dashboard runs since 2026-10-09 · `sigma_queries/retired/portfolios_element_v1.sql` — the retired workbook's |
| The dbt model | `brocc-data` → `models/marts/npl_common/marts/mart_npl_servicing_agg_cases_monthly.sql` |
| The tests | `tests/run.py` — suites in `tests/suites/`, catalogue in `tests/TEST-CASES.md` |
| The redesign | `design/` (the reviewed mock) · `docs/DESIGN.md` (how it maps to Sigma) |
| Retired files | `../.archive/2026-10-09-servicing-cleanup/` — Sigma version history is the real undo |

⚠ Both workbooks sit in **`My Documents` of a personal account**, not a shared
folder. Fine for a draft, wrong for a dashboard executives rely on.

### Why the name moved on 2026-10-08

The old workbook kept returning **43 rows / EUR 37,391,206.56** against the
rebuild's **1,839 rows / EUR 347,398,071.67**, even after its document was
pushed six times. Comparing both documents element by element proved them
**byte-identical** — same elements, same layout, same pages.

That led to the wrong conclusion — "saved state no API can reach" — and six
fruitless pushes. **The real cause was found later the same day**, see §1b. The
rebuilt workbook took the name **Servicing Dashboard** and the old one became
**Servicing Dashboard (retired 2026-10-08)**. The rebuild reconciles 14/14 and
runs in 4.6s cold.

⚠ **The URL changed.** An old bookmark still opens the retired workbook — the
name says so, but it still shows the wrong numbers, so anyone holding the old
link needs the new one. The rename is reversible through
`sigma -p brocc api files update`, passing `inodeId` and a new `name`.

## 1b. ⚠⚠⚠ A push materialises control defaults. This is the 43-row bug.

A `contents update` push **applies the document's control default values to the
live view**. A control carrying a `value` alongside a `filters` block sits inert
until a push lands, then filters every element reading its source.

Proved 2026-10-08: a push that only *added a column* took the page from 1,839
rows / EUR 347,398,071.67 to 43 rows / EUR 37,391,206.56 — the retired
workbook's exact figure. Three guardrail controls each held `value: false`:

| Control | Column |
|---|---|
| Has been Reconciled | `IS_RECONCILED_FLAG` |
| Have Case Level Data | `HAVE_LOAN_DETAIL_FLAG` |
| Has Servicer Forecast | `HAVE_SERVICER_FORECAST_FLAG` |

**Delete the `value` key entirely.** Setting it to `null` does not work — the
server coerces that back to `false`. With the key gone, nothing is filtered by
default and all 14 tiles reconcile.

⚠⚠ **You must strip it on every push, not once.** The server writes
`value: false` back into the stored document afterwards, so the next
`spec get` hands it to you again, and a push built from that spec re-arms the
filter. Any script that edits this workbook must drop the key from
`LcKpZBABof`, `k62yyrfMWv` and `dBs8WWglWu` as its last step before sending.

⚠ **Re-run `tests/run.py` after every push.** A materialised default
fails silently: no error, no warning, just smaller numbers that look like a data
problem.

### Two further API limits, same day

- **`Max()` takes one argument.** There is no `Max([x], [group])` — it returns
  the text `Max expected 1 argument, got 2` into every cell rather than erroring.
  A per-group watermark must be a SQL window function surfaced as a Custom SQL
  column, which is how `latest_reporting_month` is built.
- **A text element's `{{...}}` reference resolves only to a raw Custom SQL
  column**, never to a calculated one. `Max([Portfolios/Latest Reporting Month])`
  returned `Dependency not found` while the column was calculated, and was
  accepted the moment the same name came from the SQL. The error names the
  column, which reads like it is missing — it is not; it is the wrong *kind*.

## 2. How data reaches a tile

```
Snowflake PROD
  FCT_PORTFOLIO_SNAPSHOT_MONTHLY   money, by portfolio x month x currency
  FCT_CASE_COLLECTION              134m payment rows
  FCT_CASE_SNAPSHOT_DAILY          1.5bn rows, month-end despite the name
  FCT_EXCHANGE_RATE_MONTHLY        the only source of EUR rates
         |
         v
  MART_NPL_SERVICING_AGG_CASES_MONTHLY     <- dbt, nightly. 1,296 rows.
         |                                    The expensive case work,
         v                                    done once instead of per refresh.
Sigma elements
  Portfolio Information  ---+
  FX Table  ----------------+--> Portfolio Metrics --+
                            +--> Forecasts ----------+--> Servicing  <- every tile
                                 Case Metrics -------+
  Feed Status (independent)
         |
         v
  KPI cards, league table, payer page, downloads
```

**The rule: one element every tile reads.** Two cards reading different
elements is how two numbers on one page come to disagree.

## 3. The five things that make this domain hard

1. **Currency.** A portfolio-month can hold two currencies. Only 1.6% of months
   do — but they carry **35.67% of gross value**, so taking the rate from the
   portfolio's own currency mis-converts a third of the money. Convert at the
   grain where a row has one currency, then sum.
2. **One rate for every month (since 2026-10-14).** Every euro figure converts at each currency's month-end rate
   at the latest complete reporting month, as the NPL Portfolio Dashboard (v2) does, so past months move only when
   collections do and the two dashboards differ only by ownership share (`tests/npl_crosscheck.py`). Until then flows
   used each month's average rate and stocks its month-end rate (they differ by 0.87% on average for SEK, up to 1.70%
   in a month); the switch moved Dec 2025 – Sep 2026 collections by −€3.07M in total.
3. **Stocks must not be summed across months.** Balance summed over nine months
   is nine times the balance. Take the latest month.
4. **The feeds end on different months.** The case feed runs ahead of the
   portfolio report. Anything comparing them must cap at the last **complete**
   month or it reports a collapse that is really a delivery delay.
5. **Case counts are a floor.** The case feed covers 164 of 264 portfolios;
   **22.9% of collections have no case detail behind them.** A book with no feed
   must read blank, never zero.

## 4. Debugging: a number looks wrong

Work down this list. Each step is a command, not a guess.

**Step 1 — run the tests.**

    uv run python work/servicing/tests/run.py              # all suites, ~30s
    uv run python work/servicing/tests/run.py --suite live # just the Sigma tiles

Each case reads the **tile's own rendered data** out of Sigma and compares it
against SQL written here from the source facts. ⚠ The expectations are never
taken from the dashboard's own query — if both sides came from the same SQL the
test would prove nothing.

**Step 2 — is it the query, or Sigma?** Run the element's SQL straight against
Snowflake. If the SQL is right and the tile is wrong, the loss is inside Sigma:

    sigma -p brocc api workbooks spec get --params '{"workbookId":"<id>"}' \
      | jq -r '.document.elements[] | select(.id=="<elementId>") | .source.statement'

**Step 3 — look for a hidden filter.** This is the one that bites. An element
can carry its own filter that appears nowhere on the page:

    sigma -p brocc api workbooks spec get --params '{"workbookId":"<id>"}' \
      | jq '.document.elements[] | select(.filters) | {id, name, filters}'

**Step 4 — look for control defaults.** A control with a `value` filters the
page the moment it opens, before anyone touches anything:

    ... | jq '.document.elements[] | select(.kind=="control" and .value != null) | {id, name, value}'

**Step 5 — check feed freshness before blaming the logic.** Three different
things look identical on a chart: a stale feed, a pipeline that did not run, and
a genuine zero. The `Feed Status` element separates them — see
`sigma_feed_status.sql`.

## 5. What was actually wrong, and what it cost

Found on the live dashboard and fixed on the rebuild:

| Defect | Effect |
|---|---|
| **Hidden filter on the source element**: `[M] Average Forecast L3M >= 3`, nulls excluded | **Dropped EUR 94,182,430 — 27% of all collections — and all of December 2025.** Visible nowhere on the page |
| Three control defaults (`Is Reconciled=false`, `Have Case Level Data=true`, `Has Servicer Forecast=true`) | the page opened showing only books that do **not** reconcile, hiding EUR 110.6m |
| Rolling averages divided by a constant 3/6/12 | understated by up to 3x on young books; Aug L3M read 28.3m instead of **34.6m** |
| L3M forecast series | a bare column reference in an aggregate context — **rendered null, always** |
| Country map | labelled *Balance / Capex*, measuring `Sum([Collections Sum])`, formatted as a **percentage** |
| Balance summed across months | Greece showed **120bn** against a real 15.1bn |

After the fixes, the source element returns **347,398,071.6716887** — the
warehouse figure to seven decimal places.

## 6. Changing the workbook

**The MCP connector cannot write.** It has `begin_session`, `search`,
`list_documents`, `describe`, `query` and nothing else. Use it to verify.

**Writes go through the Sigma CLI.**

    sigma -p brocc api workbooks copy             # ALWAYS copy before editing
    sigma -p brocc api workbooks spec get         # read the whole document
    sigma -p brocc api workbooks contents update  # write it back
    sigma -p brocc api workbooks restore-version  # the undo

⚠ `copy` wants `destinationFolderId`, not `folderId`.
⚠ `contents update` wants the document wrapped: `{"contents": {...}}`.
⚠ Every write creates a Sigma version — **Version history → Restore version as
draft** is the real undo, better than any file kept here.

### Learned building the rebuild, 2026-10-09

| Rule | What happens otherwise |
|---|---|
| **Run `workbooks spec verify` first** with `{name, folderId, document: contents}` | a failed create says only "1 schema error in data model spec"; verify names the element and field |
| A KPI with `direction: none` takes **`colorNeutral`**, not `colorGood`/`colorBad` | rejected by verify |
| A combo chart's `color.by: category` needs a **column**; per-series colours come from the theme's `categoricalScheme` order | schema error at `color.1.0.column` |
| A KPI takes **`comparisonColumn` or `periodComparison`, never both** | — design for one |
| With a comparison set, the KPI trend is a **line**; `shape: area` / `areaStyle: gradient` are dropped on readback | silently ignored |
| `area-chart`, `line-chart`, `combo-chart` (area + line series), `pivot-table`, `kpi-chart`, header `panels`, `settings.navigation`, theme `overrides.fonts` and workbook `agents` **are all creatable** | — the 2026-10-07 "charts cannot be created" note is obsolete |
| Sigma **still writes `value: false`** onto a segmented control with a filter, even when none was sent | harmless on create (tested: 1,839 rows reach the page); re-check after every push |
| `workbooks get` hides theme fonts; **`workbooks spec get`** shows `settings.theme.overrides` | how NPL v2's Inter was found |
| A **page header is at most 8 rows**; the dark band and status tiles therefore sit at the top of each page | verify: `a page header is at most 8 rows tall` |
| Text supports **only `#`, `##`, `###`** headings; `###` is the executive size (`#`/`##` look oversized) | verify: `heading level 4 is not supported` |
| **Control labels cannot be recoloured** (no style on controls): never place controls on a dark background | labels vanish — the 2026-10-09 screenshot |
| KPI `description` = the note under a tile; `value.fontSize` sets the figure size | — |
| A boolean segmented control reads **None / False / True** and invites a stuck filter; use a list control on a text column (`reconciliation_status`) | the "True" custom view that halved every figure |
| Sigma keeps a **personal custom view** per viewer; "Close view" resets it. A figure that looks halved may be a saved view, not the data | — |
| **One flat row per group**: a grouped helper table, then a child table with `source {kind: table, elementId, groupingId}`. The child sees one row per group and can sort and carry data bars on any column | a single grouped table repeats the group value on every row and adds subtotals, which a pivot cannot hide either |
| Helper tables live on a page with **`visibility: "hidden"`** (Model) | viewers see the raw grouped table |
| **Gradients exist only in table data bars** (`conditionalFormats: dataBars`, two-colour `scheme`). Area and line charts have none, and a KPI with a comparison loses its gradient | the user asked for gradient chart fills; not possible today |
| **`spec verify` accepts unknown keys** (a made-up `lineAreaStyle.bogus` passes). It cannot prove an option exists: read `~/.sigma-cli/cache/openapi.json`. Checked there 2026-10-09: `lineAreaStyle` offers interpolation, missing, line (style/width/visibility) and points only, with no fill or gradient; `areaStyle: gradient` exists only on a KPI trend | a "valid" verify on a setting Sigma then ignores |
| A column with a **blank name exports under its id** (`vbar`) and may show it: name every column | an internal id as a header |
| `GrandTotal(Max(x))` works **inside** an aggregate in a grouped table and respects filters | probe-tested 2026-10-09; anchors §2's window |
| An element **title** (`name: {text: ...}`) takes `{{formula}}` text and can reference controls; a KPI's **comparison label** cannot (a formula prints raw) | probe-rendered as PNG, 2026-10-09 |
| A KPI's default comparison label is the comparison column's name plus the timeline month; `comparison.label: "hidden"` removes both | "vs Previous Window Aug 2026" on every window |
| `workbooks export` with `format: {type: "png"}` renders a chart or KPI as an image; text elements cannot be exported | how to see a layout without a browser |
| **Solid and dashed lines on one chart**: a `combo-chart` takes `seriesLineAreaStyle: [{columnId, style: {line: {style: "dashed"}}}]`, per series. `lineAreaStyle` is chart-wide. Found in NPL Portfolio Dashboard v2's collections chart (2026-10-11); the line-chart schema does not list it | searching only `line-chart` says it cannot be done |
| **A chart tooltip cannot be coloured** (format offers columnNames, multiSeries, valueFormat only): show ahead/behind as text, `If(r >= 1, "▲ +", "▼ ") & Text(Round((r - 1) * 100, 1)) & "%"`. Only plotted and tooltip columns export; two columns with one name export as `X` and `X (1)` | green/red asked for in a hover |
| **Test only what changed**: `tests/run.py --only GLOB` (repeatable). A chart change: `--only 'live.chart_*' --only 'controls.chart_*' --only live.titles_title_case --only controls.manager_review_applied` (25 checks, 2.5 min). Run all when the query or a shared helper changes, and before a release | a 22-minute full run for a tooltip label |
| A **sticky header**: the header panel's `config.scroll: "sticky"` (the default; `spec get` then omits `scroll`). `borderStyle: "shadow"` works only when sticky. The build had `"none"` until 2026-10-11 | the filters scroll away on a long page |
| **Shared hover vs dashes**: `tooltip.format.multiSeries` (one box for every line at a month) works only on bar, line and area charts; per-series dashes only on a combo chart, and a line chart silently drops `seriesLineAreaStyle` (all solid, nulls drawn as zero). Keep the combo and repeat every line's figure as tooltip columns, and set `tooltip: "hidden"` on the plotted line columns, or the hovered line's figure shows twice | verify refuses multiSeries on a combo; a rendered PNG shows the lost dashes |
| **A header panel is always 24 columns**: `gridTemplateColumns="repeat(28, 1fr)"` is accepted and silently rewritten to 24, pushing elements off the edge. Seven equal filters fit one row at 3 columns each, with a 3-column Clear Filters to fill it | `spec get` reads back repeat(24, 1fr) |
| **Picking a series colour without per-series colour**: list the series so each lands on the theme slot that holds its colour; to skip a slot, give it an empty series (formula `Null`, name a space) with `lineAreaStyle.missing: "hide"`, and hide Sigma's legend (it would show the empty one) in favour of a text key. Checked by rendering a PNG | the Cases chart's five colours (2026-10-12) |
| **Exact colours per value do exist**, for a chart coloured by one category column: `color: {by: "category", column, customColors: [{value, color}]}` (the NPL dashboard colours its bars by category). A wide source (one column per series) cannot use it; there the theme-slot order is the only lever | correcting "no per-series colour" (2026-10-12) |
| A **stacked bar chart** stacks the last-listed series at the bottom and the first on top; the colours still follow list order. Checked by PNG | the Cases chart (2026-10-12) |
| **Totals over stacked bars**: `dataLabel: {labels: "hidden", totals: {display: "shown", labelDisplay: "all"}}`. The total takes the value column's format; Sigma has no format that switches M to K by size (d3 `s` is significant digits, not 2 decimals). `spec verify` accepts unknown keys inside `dataLabel`, so read the OpenAPI schema (`~/.sigma-cli/cache/openapi.json`), not verify. `stacking: "stacked"` is the default and `spec get` omits it. **The total adds every segment, negatives too**: with Lost below zero it read 283,090 for August, not 311,201. A white spacer row worth +Lost, named a single space (sorts first, so on top; white; Sigma's legend leaves a blank value out, where a named one shows and has no per-entry text colour), cancels it. Checked by PNG export (`workbooks export` with `format.type: "png"`) | the Cases chart totals (2026-10-13) |
| **Bracket every formula you splice into another**: §2's change was built as `now / base - 1`, and a ratio's base is `a / b`, so Sigma read `now / a / b - 1` (-100% for every group on Avg Monthly Collection per Case; Net Change's `fresh - lost` base broke the same way). `change()` now brackets both sides, and `controls.cases_perf_change.*` recomputes every cell | the user's screenshot, 2026-10-13 |
| **A container's grid need not be 24 columns**: `gridTemplateColumns="repeat(4, 1fr)"` on a container is kept (unlike the header panel) and gives equal cards. A KPI needs about a quarter of the page: at a fifth Sigma cuts the title to "…" and drops the %'s decimal | the Cases tiles (2026-10-13), rendered by PNG |
| **Never show a % change of a signed number**: Net Change (fresh − lost) and net collections (negative when fees exceed collections) read -3,082% and -1,168%. A % against a zero or negative base is blank (`If(base <= 0, Null, …)`, and the cards' prior the same way), and Net Change is a difference in cases (`display: "delta"` on its card). Found by a 623-export stress test of every toggle and filter (`tests/stress.py`) | the stress test, 2026-10-13 |
| **A hover figure must follow the View**: in Cumulative the lines are running totals, but the 'vs accounting' % was the month's (France Aug −25.2% beside to-date totals −12.1% apart). `fc_vs()` switches on View; `live.chart_hover_signed_cumulative` checks it | presenting the Heimdall insight, 2026-10-13 |
| **A chart can filter its own rows**: `filters: [{id, columnId, kind: "list", mode: "exclude", values: [...]}]` on the chart, on one of its own columns. The Cases chart keeps the All Collected Cases row for the Avg tab and filters it out of the stacked tabs | one source for three tabs (2026-10-13) |
| **A KPI's % comparison loses its decimal on a narrow card**: Sigma shortens it to fit (42.46% showed "42%" at 5 of 24 columns in a box, "42.5%" at 6). The value's format does not control it. Give cards 6+ columns; check with a PNG export | the one-decimal standard (2026-10-12) |
| **A KPI's delta comparison takes the card's own format**: to show a euro change in millions to 2 decimals, the value itself must be in millions (`/ 1000000`, `$,.2f` with suffix M); d3 has no fixed-decimal SI format | Collections Minus Forecast (2026-10-12) |
| **A legend that highlights, with fixed colours**: give the chart a category column (a long source: one row per series value) and colour by it, `color: {by: "category", column, customColors: [...]}`, `legend.position: "right"`. Sigma's legend then highlights one or several values, and orders them alphabetically. The Cases chart does this from `cb_src` | the Cases chart, 2026-10-12 (as the NPL dashboard's carrying-amount chart) |
| **No per-series colour for a chart with one column per series** (see category colours above for the other kind): series take the theme's `categoricalScheme` in `yAxis.columnIds` order (Servicing: violet, green, periwinkle, deep green). Order the columns to pick colours | asking for a colour key that does not exist |
| A chart that must show months **past the data** needs its own source: a source filter (Reporting month) would cut them. `fc_src` repeats 12 forecast-only months after every anchor month and the chart keeps the newest anchor's | the forecast stops where the actuals stop |
| `CumulativeSum` carries the last total across blank months: wrap it `If(IsNull(x), Null, CumulativeSum(x))` to stop a line | a flat collections line across the forecast-only year |
| Date-range control as an export parameter: `"Reporting-Month": "min:2025-12-01,max:2026-04-30"` | tested by controls.chart_range_* |
| **Hand edits in the Sigma editor** go in `sigma_build/user_edits.json` (element fields and extra elements), applied last on every build; layout is copied from live into the builder. Diff live against `contents.json` before every rebuild | a rebuild silently undoes the user's changes |
| Markdown bold cannot start with a space: `## ** 1 · Overview**` is stored escaped and shows the stars. The Sigma editor writes that form; the API must send `## **1 · Overview**` | literal `** 1 · Overview**` on the page |
| A `csv-table` source (an uploaded CSV) fails `spec verify` (`Dependency not found`); rebuild it as a Custom SQL `VALUES` table | verify refuses the whole build |
| A stock KPI follows a window by anchoring its timeline column: `m = DateTrunc(month, DateAdd(month, k, GrandTotal(Max([reporting_month]))))`, value `Sum(If(month = m, x))` | probe-rendered, 2026-10-09 |
| A **text element's background colour** (set in the Sigma editor) is invisible to the API: neither `workbooks get` nor `spec get` returns it, and text takes no `style`. Put the colour on a container around the text (`SECTION_BARS` in the builder) | a rebuild silently drops the colour |
| A **`tabbed-container`** is creatable: `{"kind": "tabbed-container", "tabs": [{"name": ...}]}`, laid out as `<TabbedContainer elementId=".." type="tabbed-container" ...><Tab gridTemplateColumns=".." gridTemplateRows="auto">...</Tab></TabbedContainer>`, tabs matched by position. `<Container type="tabbed">` fails verify | probe-created and read back, 2026-10-09: the Cases Count / Collections chart |
| A chart's **y-axis title** is `yAxis.format.title.text` (static text); a chart title hides with `name: {"visibility": "hidden"}` | the manager's "axis label instead of chart label" |
| A KPI **without a timeline** still takes a `comparisonColumn` and shows the delta | the Data Quality reconciled-share tile |
| Two columns with the **same name** in one element export as `lost` and `lost (1)` | rename one ("Lost cases") |
| A **segmented control collapses to a dropdown** when its cell is narrow; give the Window control a full-width row | a dropdown where a toggle was designed |
| KPI `comparisonColumn` takes any column, so a **previous-window** comparison is a `Switch()` over window totals (L6M − L3M and so on) | the built-in period comparison is only month vs previous month |

### Writing elements: every rule the API enforces

Learned the hard way on 2026-10-07. Each of these returns a clean 400 and
changes nothing, so a rejected push is safe — but knowing them saves the round
trip.

| Rule | What happens otherwise |
|---|---|
| `copy` takes **`destinationFolderId`**, not `folderId` | `Expecting UUID at 0.destinationFolderId` |
| `contents update` body must be **`{"contents": {...document...}}`** | a wall of schema errors against `0.contents.0.0.0.0` |
| ~~`kpi-chart` cannot be created~~ — **outdated 2026-10-08**: `bar-chart` is now accepted by `contents update` and survives readback; re-probe other chart kinds on a copy before relying on either answer | was `Invalid kind` |
| **Every element must appear in the layout XML** | `element 'X' is not placed in layout` |
| An **empty page is self-closing**: `<Page .../>` | a regex that assumes `<Page>...</Page>` produces unmatched tags |
| A page can have **no layout block at all** | its elements have nowhere to go; append a `<Page>` block |
| `groupings[].groupBy` takes **the element's own column ids**, not source column names | `Column or folder not found: 'COUNTRY_NAME'` |
| A **grouped column cannot carry the sort** | `Sort column not in level: ... level base` |
| Child elements must address the source's columns as **`[Portfolios/Column Name]`** | see below — this is the rule that turns a silent failure into a loud one |
| Sigma derives display names with **lowercase particles**: `Case on Book Count`, `Case Jitter in Count` | `Dependency not found` if prefixed; silent breakage if not |

⚠ The last two are the dangerous ones: they are accepted by the API and fail
**inside the tile**, so only reading the rendered data catches them. That is
what the `live` suite in `tests/run.py` is for.

### ⚠ Always prefix a source column — it is the difference between loud and silent

Two forms are accepted by the API. They fail very differently.

| Form | On a typo |
|---|---|
| `Sum([Portfolios/Case Steady Count])` | **400 at write time**: `Dependency not found: 'portfolios/case steady kount'`. Nothing changes |
| `Sum([Case Steady Count])` | **accepted.** Sigma then writes `Unknown column "[Case Steady Count]"` into **every cell as text**. No error anywhere, and a numeric aggregate over it reads as zero |

The unprefixed form is how a tile comes to show nothing while every check
passes. **Always prefix.** Then the API validates the dependency for you.

The test suite also guards it (`tests/_lib.py`, `tile()`): any tile whose data contains
`Unknown column` fails the suite with the column named. That is defence in
depth — the prefix is the actual fix.

### Emphasis cannot survive a write

| Attempt | Result |
|---|---|
| markdown `**bold**` | silently escaped to `\*\*bold\*\*` and rendered literally |
| `<strong>` | rejected: not in the allowed inline-HTML set (`<u> <sub> <sup> <span> <a>`) |
| `<span style="font-weight: 700">` | rejected: `<span style>` allows only colour, background-colour, font-size, font-family |

**There is no way to keep bold through the API.** Strip the markers so nothing
renders as literal junk, and re-apply bold in the UI. Colour, layout, pages and
every other element property survive intact.

### Known limits of the Beta write API

| Limit | Consequence |
|---|---|
| Markdown `**` is escaped to `\*\*` on write | **bold is lost from text elements on every update** |
| `<strong>` is rejected | no HTML workaround |
| `<span style>` allows only colour, background-colour, font-size, font-family | cannot express weight either |

**There is no way to keep bold through the API.** Re-apply it in the UI after a
write, or accept plain headers. Colour, layout, pages and element properties all
survive — only emphasis is lost.
