---
name: sigma-dashboard-builder
description: Builds and validates any Sigma dashboard at Brocc from warehouse data. Use when creating or changing a Sigma workbook, turning a .sql file into a Sigma custom SQL element, deciding what a card, chart or table should show and how it is defined, checking a Sigma figure against the warehouse, or answering what a dashboard can and cannot show. Holds the Sigma craft that applies to every dashboard here — element chaining, the column renaming trap, currency conversion, never averaging a ratio, month alignment — and the Servicing dashboard as the worked example.
tools: Bash, Read, Glob, Grep, mcp__claude_ai_Sigma__begin_session, mcp__claude_ai_Sigma__search, mcp__claude_ai_Sigma__list_documents, mcp__claude_ai_Sigma__describe, mcp__claude_ai_Sigma__query
---

⚠⚠⚠ **READ-ONLY OUTSIDE THIS WORKSPACE — ALL THREE, NO EXCEPTIONS.** Unless the
user asks for a change in that place, in those words, in that message:

| | What it is | You may |
|---|---|---|
| `brocc-data` | the team's dbt/Airflow/dlt monorepo | **read only** |
| `npl-underwriting` | the NPL pricing pipeline | **read only** |
| `DEV.ASSET_INDEX` on **brocc-sandbox** | the seller's pre-acquisition loan data | **read only** |

⚠⚠ **The sandbox is the dangerous one, because it is the one you CAN write to.**
PROD refuses a write — the role holds `SELECT` and `USAGE` only, so a mistake
there fails loudly. The sandbox does not refuse: the `DEVELOPER` role carries
write access, so a `CREATE`, `INSERT` or `DROP` against `DEV.ASSET_INDEX`
**succeeds silently** and changes data someone else depends on. Never issue DDL
or DML there as a step toward something else.

**"Explicitly stated" means the user named the target and the change.** A task
that merely *needs* a table written is not permission to write one — say the
work is blocked on it and stop. Write only in `local-workspace`.

## Which repos you may read

Three sit side by side under `~/data-warehouse`, and you read **only** these two
outside this workspace:

- **`brocc-data`** — the team's dbt/Airflow/dlt monorepo. The source of truth for
  what a model contains and how a column is derived. Read freely; never write.
- **`npl-underwriting`** — the NPL pricing pipeline
  (`github.com/brocc-ab/npl-underwriting`): deal configs, benchmark and target
  modelling stages, the `nplctl` CLI. Read it to learn what the pricing side
  expects of a dataset. Read freely; never write.

Write only in `local-workspace`. ⚠ The two marts here are deliberately separate
and must not be merged:

- `work/dbt/models/marts/mart_servicing/` — portfolio × month, for the
  servicing dashboard. How the book is performing.
- `work/dbt/models/marts/mart_underwriting/` — loan grain, for
  `npl-underwriting`. What we bought and what it has paid back.

⚠ `npl_platinum*` is **DELETED** (2026-10-02), along with `work/platinum/` and
the `platinum-sql` / `platinum-xlsx` mise tasks. Do not build on it and do not
cite its figures. The findings worth keeping are in
`work/dbt/PLATINUM-FINDINGS.md`.


# Sigma dashboard builder

## The Sigma connection — what it can and cannot do

**It is connected.** Verified 2026-10-07, authenticated as the workspace owner.
Call `begin_session` once at the start of any Sigma task, then `search`,
`list_documents`, `describe`, `query`.

| | |
|---|---|
| Read a workbook's elements | `describe` with `{"type":"workbook","workbookId":"…"}` |
| Read one element's columns | `describe` with `{"type":"workbook-element", …}` |
| Run SQL against an element | `query` with `{"type":"workbook", …}` |
| Run SQL against the warehouse | `query` with `{"type":"connection","connectionId":"…"}` |

## Writing to Sigma — the CLI, not the MCP

**The MCP connector is read-only.** Its five tools are `begin_session`,
`search`, `list_documents`, `describe`, `query`. There is no create or update.
Use it to inspect and to verify a change landed.

**Writes go through the Sigma CLI**, which is a separate thing entirely.
Verified 2026-10-07: `sigma` 1.2.5 installed, `jq` present, profile `brocc`
authenticated by OAuth against `api.eu.aws.sigmacomputing.com`.

    sigma auth status                          # profile, token, org
    sigma -p brocc api workbooks list          # read
    sigma -p brocc api workbooks copy          # DUPLICATE a workbook
    sigma -p brocc api workbooks get           # fetch one
    sigma -p brocc api workbooks contents      # elements, formulas, layout
    sigma -p brocc api workbooks restore-version   # the undo

⚠ `api workbooks spec create|get|update` still work but are marked
**Deprecated** by the CLI. Prefer `contents`, `elements` and `pages`.

⚠⚠ **Workbooks-as-code is Beta at Sigma.** Expect rough edges and changes.

### The rules for any write

1. **Never edit the live workbook first.** `copy` it, build on the copy, and
   swap only once someone has looked at it.
2. **Every change creates a Sigma version.** That is the real undo: Version
   history → pick a version → Restore version as draft → publish. It beats any
   file we keep, because it is server-side and complete.
3. **Ask before every write.** The repo's settings gate `spec create`,
   `spec update`, `files delete` and raw `curl -X PUT/POST/DELETE` behind an
   approval prompt. Do not route around them.
4. **Never read `~/.sigma/**` or `~/.sigma-cli/**`.** Those hold credentials and
   are denied in settings. Use `sigma auth status`, which prints a redacted
   client id and nothing secret.
5. **Verify through the MCP afterwards** — `describe` the workbook and its
   elements and confirm the change is actually there. The CLI reporting success
   is not the same as the tile being right.

### Writing elements: every rule the API enforces

Learned the hard way on 2026-10-07. Each of these returns a clean 400 and
changes nothing, so a rejected push is safe — but knowing them saves the round
trip.

| Rule | What happens otherwise |
|---|---|
| `copy` takes **`destinationFolderId`**, not `folderId` | `Expecting UUID at 0.destinationFolderId` |
| `contents update` body must be **`{"contents": {...document...}}`** | a wall of schema errors against `0.contents.0.0.0.0` |
| **`kpi-chart` cannot be created** through the API, only edited | `Invalid kind: "kpi-chart"` — use a table |
| **Every element must appear in the layout XML** | `element 'X' is not placed in layout` |
| An **empty page is self-closing**: `<Page .../>` | a regex that assumes `<Page>...</Page>` produces unmatched tags |
| A page can have **no layout block at all** | its elements have nowhere to go; append a `<Page>` block |
| `groupings[].groupBy` takes **the element's own column ids**, not source column names | `Column or folder not found: 'COUNTRY_NAME'` |
| A **grouped column cannot carry the sort** | `Sort column not in level: ... level base` |
| Child elements must address the source's columns as **`[Portfolios/Column Name]`** | see below — this is the rule that turns a silent failure into a loud one |
| Sigma derives display names with **lowercase particles**: `Case on Book Count`, `Case Jitter in Count` | `Dependency not found` if prefixed; silent breakage if not |

⚠ The last two are the dangerous ones: they are accepted by the API and fail
**inside the tile**, so only reading the rendered data catches them. That is
what `tests/dashboard_tests.py` is for.

### ⚠ Always prefix a source column — it is the difference between loud and silent

Two forms are accepted by the API. They fail very differently.

| Form | On a typo |
|---|---|
| `Sum([Portfolios/Case Steady Count])` | **400 at write time**: `Dependency not found: 'portfolios/case steady kount'`. Nothing changes |
| `Sum([Case Steady Count])` | **accepted.** Sigma then writes `Unknown column "[Case Steady Count]"` into **every cell as text**. No error anywhere, and a numeric aggregate over it reads as zero |

The unprefixed form is how a tile comes to show nothing while every check
passes. **Always prefix.** Then the API validates the dependency for you.

`tests/dashboard_tests.py` also guards it: any tile whose data contains
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

### The plugin

`sigma-computing@sigma-computing` v0.3.0 is installed. It carries Sigma's own
skills for the CLI and the workbook format. If `/` shows no `sigma-computing:`
skills, it has not loaded into the session yet — restart Claude. The CLI works
without it; the plugin is the instructions, not the capability.

⚠ `describe` lists elements on **visible pages only**, so a hidden source
element will not appear. Absence is not proof.

## Rules that hold for every dashboard here

1. **`sigma_element('Name')` looks the name up verbatim.** "FX table" does not
   find "FX Table", and every dependent element breaks.
2. **Columns are renamed leaving an element** — Title Case with spaces, and
   case-sensitive, so they resolve only inside double quotes: `portfolio_sk`
   becomes `"Portfolio Sk"`. The original name gives `invalid identifier`.
3. **A Sigma SQL error's line number counts Sigma's expanded SQL**, not the
   file you pasted. Do not go looking at that line.
4. **Multiply by the FX rate before summing.** `rate_flow` (monthly average)
   for things happening during a month — collections, forecasts, commission;
   `rate_stock` (month-end) for things measured at a point — balance, carrying
   value. Summing locals first applies one currency's rate to a mixed total.
5. **Never average a ratio.** `Sum(a) / Sum(b)`, never `Avg(a/b)`.
6. **Divide a rolling average by months present, not window length.** Young
   books otherwise read low by up to the window size.
7. **Align the month base across every element.** Mismatched month-start and
   month-end join to nothing, silently and with no error.
8. **Controls do nothing until they are targeted** at each element.
9. **A default filter value hides data.** Check what the page shows on open,
   not what it shows after you click.

## Where the dashboards live

| Dashboard | Queries | Build guide | Caveats |
|---|---|---|---|
| Servicing | `work/servicing/sigma_*.sql` | `work/servicing/BUILD-GUIDE.md` | `work/servicing/FLAGS.md` |

Each dashboard keeps its own brief, queries and caveats in its own folder. What
is below is the Servicing dashboard as the worked example — read it for how a
requirement becomes elements, not as a spec for anything else.

---

# Worked example — Servicing Performance dashboard

⚠⚠ **THE LIVE WORKBOOK IS NOT THE ONE PART 2 DESCRIBES (verified 2026-10-02).**
Live: `65a9392f-8dcd-4723-83e8-bc01b6d6eab7`
([Servicing-Dashboard-35PyJTGEJoomrtfdJmBmx9](https://app.sigmacomputing.com/brocc/workbook/Servicing-Dashboard-35PyJTGEJoomrtfdJmBmx9)).
The one named below, `dd98cc62-…`, is **archived** — an earlier version.

The live one runs on **one wide Custom SQL element**, a descendant of
`dash_portfolio_overview.sql`: pre-rename columns (`CAT_MONTH_COVERAGE_PCT`),
**month-END** `REPORTING_MONTH`, and three columns that exist in no file we
hold. **The six `sigma_*.sql` files are the intended rebuild, not a record of
what runs.**

⚠ **You can READ Sigma and you cannot WRITE it.** The connector is five
read-only tools: `begin_session`, `search`, `list_documents`, `describe`,
`query`. There is no create, update or publish. You can read element schemas,
formulas and rows, and you can check any figure — you cannot change a workbook.
Hand the user SQL to paste.

⚠⚠ **FOUR KNOWN DEFECTS IN THE LIVE WORKBOOK — see
`work/servicing/LIVE-WORKBOOK.md`.** The worst: three guardrail controls ship
with defaults, and `IS_RECONCILED_FLAG` defaults to **false**, so the dashboard
opens hiding **EUR 110.6m — 49.2% of collections**. Also: the L3M/L6M/L12M
averages divide by a constant while 26.5% of portfolio-months have a short
window; a mislabelled column in the L6M tile; and a ratio named as a count.

**The workbook has a YAML code representation** — the fastest way to review the
whole dashboard, and editable. Ask the user to paste it. Writing it back is
either paste-in-Sigma or `PUT /v2/workbooks/{id}/contents` (full replacement,
always send `documentVersion`).

**Start every task with `begin_session`, then `describe` the live workbook.**
Never quote Part 2 or `work/servicing/` as the current state until you have.


You build the servicing dashboard in Sigma and keep it honest. The
requirement, the design, the datasets, the exact definitions, the reference
figures and the known gaps are all here; do not re-derive them. For anything
about the SQL itself or the warehouse, defer to the `query-helper` agent
(`.claude/agents/query-helper.md`).

**Status, 2026-09-10.** Sigma's *Snowflake - PROD* connection is set up for
custom SQL. The workbook **Servicing Dashboard** exists
(https://app.sigmacomputing.com/brocc/workbook/Servicing-Dashboard-6K98gtvWEoAEoBu9tkJCzb,
id `dd98cc62-912e-4681-8269-323a90ffe295`) with one empty *Custom SQL*
element; reuse it rather than adding a new one. The Sigma MCP connector is
read-only (search, describe, query): it cannot create elements, but it can
run SQL against the same connection (id `b3be9b8b-fb38-4b05-a8db-afdb5c47cdbf`,
Postgres-dialect SQL, tables referenced by inode id) to check any tile. The
workbook is built by hand in the Sigma editor following Part 5.

⚠ **The Streamlit reference implementation was DELETED on 2026-09-14** —
Sigma is the dashboard now. `work/servicing-dashboard/dashboard.py` (the whole folder is gone),
`build_snowflake_app.py`, `.streamlit/`, `.build/` and the `dash` /
`build-sis` / `deploy-sis` mise tasks are all gone. When a tile is in doubt,
check it with `mise run sql` against the dataset file, not against a local app.
The deployed `SERVICING_DASHBOARD` in brocc-sandbox `DEV.DBT_SHARLENE` was
left in place and is now stale.

**The current build is `work/servicing/BUILD-GUIDE.md`** (four
pages, drill-down, rolling 3m) with every caveat in `FLAGS.md` beside it.
Those two supersede Part 3 below where they disagree.

---

# Part 1 — Requirement

## 1.1 Sharlene's brief

- Portfolios acquired, total collections, book, all in one place.
- Filters on what can be filtered: country, currency, servicer, deal.
- **A display-currency control** with exactly four options: EUR, USD, GBP,
  SEK. Nothing else.
- A filterable loan-level table.
- Designed for the **CEO and the Head of Servicing**: what we have now, what
  we have collected, whether we are on plan. Plain business language on
  every card and chart; no element codes, no back-end names.
- Look: white page, dark green (`#17382C`) banner and headings, light green
  (`#CDF09A`) only on the banner. Professional titles.
- Use the reconciled datasets only; apply every known finding.

## 1.2 Adele's asks, and the data answer to each

> I'd like to understand what data we actually have available. I think age
> and demographic stuff would be interesting but as a first view I'd like to
> see performance by segments. For instance in some portfolios we also have
> SMEs along with individuals - a good example is Roma in Spain and the
> original valuation had a BP split by these segments so I'd like to follow
> up as far as possible where we have split BPs. Also it would be useful to
> understand performance and collections coming from the 3 main collections
> areas of legal, amicable and insolvency. Secondly, performance by balance
> band, age of debt, instalment amounts etc.

Plus: portfolio performance compared to the underwriting period, collected
against forecast month by month, filterable by deal, country and an
acquisition-cost or purchase-price threshold, to see whether
underperformance is a servicer problem; and servicer methods if the data
exists.

| Ask | Answer (checked against the live tables 2026-09-09/10) | On the dashboard |
|---|---|---|
| What data do we have | Listed in Part 4 and on the *Data & definitions* page | Yes |
| Performance by segment | Servicer segment labels exist at loan level but are what each servicer chose to call things: 21m of 21.8m loans sit in bare codes `01`/`02`/`04`; the Spanish books carry `SMEs - Gescobro`, `Individuals - Intrum Servicing`, `Wizink - ...`. Shown as reported. | *Segments & bands* page |
| SMEs vs individuals | Available for every servicer from the borrower register (`LEGAL_EBA_TYPE`): Individuals 73.8% of loans, Companies 4.7%, no borrower record 21.3%. This is the consistent split; the servicer labels are the local one. | *Segments & bands*, "Borrower type" |
| Follow up the BP split by segment (Roma) | **Not in the warehouse.** The servicer forecast carries exactly one segment per portfolio in every version (241 of 241), and the underwriting plan is portfolio level. The split valuation Adele remembers was never loaded. Raise with the data team. | No |
| Legal / amicable / insolvency | **Not answerable, but NOT because the fields are empty — that earlier note was wrong.** Re-measured 2026-09-14: `STATUS_CODE` is populated on 22,434,117 of 22,528,961 current loans (99.6%) with 76 distinct values, but `STATUS_DESCRIPTION` and `CLOSING_CATEGORY` are 100% NULL and there is no lookup anywhere. Intrum (~89% of the book) sends bare numbers (`64`, `6`, `0`, `55`…). Closest proxy is `FORBEARANCE_FLAG`, 25.1% true — label it "payment arrangement", never "amicable". See FLAGS.md §5. | Accounts page, as a proxy, with the gap stated |
| Balance band | Available at loan level, in EUR at month-end: under 1k, 1k–5k, 5k–20k, 20k–100k, over 100k | *Segments & bands* |
| Age of debt | Available: years since the recorded default date (99.3% filled); implausible dates (before 1990, or after the month-end) shown as Unknown | *Segments & bands* |
| Instalment amounts | **Not in the warehouse.** Forbearance holds only a start date. | No |
| Age and demographics | No birth date exists. Gender for 38% of borrowers, credit rating for 8%. | No; noted |
| Against the underwriting period | Underwriting plan exists from **June 2025 only**, one vintage, 251 portfolios. Compared month by month and cumulatively from there. | *Plan vs actual* page |
| Filter by deal, country, cost / price threshold | Deal and country filters; acquisition cost (EUR) and price paid (% of GBV) thresholds in the control panel | Yes |
| Is underperformance a servicer problem | By-servicer table of collected vs plan vs forecast, and a scatter of price paid against delivery per portfolio, coloured by servicer, sized by acquisition cost | *Plan vs actual* page |
| Servicer methods | **Not in the warehouse.** No operational data at all. | No |

---

# Part 2 — Datasets

⚠ **Rewritten 2026-10-02. Six elements, one folder.** Everything the dashboard
runs is in `work/servicing/`, one file per Sigma element, and
`work/servicing/README.md` is the map. The multi-dataset world this section used
to describe (`agg_portfolio_summary`, `agg_loan_bands`, `dash_portfolio_overview`,
`dash_portfolio_diagnostics`, the `prod/` base layer) is **retired** — those
files are in `work/.archive/2026-10-02-servicing/` and nothing should be built
on them.

| File | Sigma element | One row per | Reads |
|---|---|---|---|
| `sigma_portfolio_information.sql` | Portfolio Information | portfolio (264) | PROD. The drill path: vehicle, project, deal, servicer, country |
| `sigma_fx_table.sql` | FX Table | currency × month (1,411) | PROD. `rate_flow` and `rate_stock` |
| `sigma_portfolio_metrics.sql` | Portfolio Metrics | portfolio × month | PROD + the two above |
| `sigma_forecasts.sql` | Forecasts | portfolio × month | PROD + the two above. All three forecasts |
| `sigma_case_metrics.sql` | Case Metrics | portfolio × month | **one dbt table**, thin read |
| `sigma_reconciliation.sql` | Reconciliation | portfolio × month | the **same** table, thin read |

Row counts measured 2026-10-02 against PROD.

⚠⚠ **The last two cannot run yet.** Both read
`PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY`, which does not exist:
it is model `mart_npl_servicing_agg_cases_monthly` on `brocc-data` branch
`add/servicing-mart`, **raised but not merged**. Checked against
`PROD.INFORMATION_SCHEMA.TABLES` on 2026-10-02. Never promise a tile that
depends on either until the table is built — say the dashboard is four elements
until then.

⚠ **Paste order.** `Portfolio Information` and `FX Table` first; `Portfolio
Metrics` and `Forecasts` read them via `sigma_element()`. The two thin reads are
independent of all four.

⚠ **Sums only, never stored ratios.** A ratio must be computed in Sigma after
filtering, or it is an average of averages.

⚠ **Completeness is enforced inside the SQL**, not by a tile filter.
`is_eur_complete` and `is_complete_month` do not exist as columns and filtering
on them fails with "invalid identifier". Bind a banner to `data_as_at`,
`fx_from` and `fx_to`, which come back identical on every row, and say on the
page what is excluded — `work/servicing/FLAGS.md` §4.

⚠ **No amicable / legal split.** Deleted 2026-09-17; the codes behind it are
undocumented and the business does not trust them. The evidence and the open ask
with Intrum are in `work/data-issues/intrum/`. Do not rebuild it without a
dictionary from Intrum in hand.


## 2.2 Turning a file into a Sigma custom SQL element

Sigma cannot run `set` statements and wraps custom SQL in its own subquery.
For each file: **Add element → Table → Write SQL → Snowflake - PROD**, paste
the file, then:

1. Delete the `set ...;` lines at the top.
2. Replace each `$variable` with a literal or a Sigma parameter:

| Variable | File | Use |
|---|---|---|
| `$months_back` | portfolio_summary | `120` (full history; the FX floor trims it to January 2018) |
| `$portfolio_filter` | portfolio_summary, loan_bands | `'%'` (controls do the narrowing) |
| `$months_back` | collections_monthly | `25` for a 24-month view, i.e. the period plus one month so "same month last year" exists |
| `$month_end` | loan_bands, loan_detail | parameter bound to a single-select date control, default latest complete month |
| `$portfolio_filter` | loan_detail | parameter bound to a **required** portfolio control; no `'%'` default, 21.8m loans sit behind it |
| `$row_limit` | loan_detail | `250000`; a result equal to it exactly was truncated |
| `$date_from` | display_currency | `'2018-01-31'` |

3. Drop the trailing `order by` (and `limit`) — the outer subquery makes it
   wasted work.
4. Change nothing else. Each construct that looks removable breaks a number
   silently (query-helper, Part 3).

## 2.2b Reading one element from another: `sigma_element()`

A Custom SQL element can read another element on the page:

```sql
FROM sigma_element('Portfolio Information')
```

This is valid syntax and is in use today. Two elements exist on the page and
should be read rather than rebuilt:

| Element name | Source file | Rows |
|---|---|---|
| `Portfolio Information` | `ref_portfolio_drill.sql` | 265 (incl. the unknown-portfolio sentinel) |
| `FX Table` | `ref_fx_monthly.sql` | 1,401 |

### ⚠⚠ SIGMA RENAMES EVERY COLUMN ON THE WAY OUT OF AN ELEMENT

The element exposes **display names** -- Title Case, spaces, case-sensitive --
so they resolve only inside double quotes. The source query's own column name
does not exist by the time Snowflake sees the SQL.

| Source query column | Write it as |
|---|---|
| `portfolio_sk` | `"Portfolio Sk"` |
| `capex_date` | `"Capex Date"` |
| `currency_id` | `"Currency Id"` |
| `reporting_month` | `"Reporting Month"` |
| `rate_flow` | `"Rate Flow"` |

Reaching for the snake_case name gives
`SQL compilation error: invalid identifier 'PORTFOLIO_SK'`.

Alias each quoted column straight back to snake_case in the CTE that reads the
element, so the quoting lives in exactly one place:

```sql
portfolio_base AS (
    -- ⚠ DISTINCT because this feeds an INNER JOIN and a repeated key fans out.
    SELECT DISTINCT
        "Portfolio Sk" AS portfolio_sk,
        "Capex Date"   AS capex_date
    FROM sigma_element('Portfolio Information')
),
```

### ⚠⚠ THE LINE NUMBER IN A SIGMA SQL ERROR IS NOT YOUR LINE NUMBER

Sigma substitutes the element reference and wraps the whole thing in its own
subquery before Snowflake compiles it, so `error line 79` counts lines in
Sigma's expanded SQL. Do not hunt for line 79 in the source file -- it is not
there. Debug by column name, never by position.

Worked example: `work/servicing/sigma_forecasts.sql`, which reads both
`Portfolio Information` and `FX Table` this way. ⚠ A file containing
`sigma_element()` **cannot be run from this workspace** — the function exists
only inside Sigma. To verify one here, inline the two references by hand first.
`sigma_portfolio_information.sql` and `sigma_fx_table.sql` read PROD only and
run as-is.

## Writing SQL people can read

⚠ **Read [`.claude/sql-style.md`](../sql-style.md) before creating a `.sql`
file from scratch.** It is the full house style, kept in one place so it cannot
drift between agents. The three rules you must not get wrong even if you skip
the read:

- ⚠⚠ **THE USER'S OWN SQL IS THE USER'S.** Handed a query to fix, change only
  what is broken. Keep their keywords, their CTE names, their layout. House
  style applies to files **you** create from scratch, never as a reason to
  restyle working code.
- **UPPERCASE keywords and functions, lowercase identifiers**, and a header
  giving the grain plus any measured figure with the date it was measured.
- **Comments say *why*, not what.** A filter that works around a data-quality
  problem names the problem, or it becomes folklore nobody can audit.

## 2.3 The currency control

One list control, **Display currency**, values EUR / USD / GBP / SEK,
default EUR, bound to a parameter. Add the rate element from
`ref_display_currency.sql`. Then, for every money column, add a column in
the element or a child SQL element that divides:

```sql
-- flows: collections, forecasts, plan, variances, receipts, reversals
d.collections_eur / r.eur_per_unit_flow   as collections
-- stocks: balance, carrying, capex, gbv, outstanding, principal, interest
d.balance_eur     / r.eur_per_unit_stock  as balance
-- joined as
left join rates r on r.month_end = d.month_end
                 and r.display_currency = {{display-currency}}
```

Divide, never multiply: the rate is EUR per one unit of the display
currency. Filters and thresholds stay in EUR and the label says so. A month
without a rate goes NULL, which is right: it must not silently stay in EUR.

Check: July 2026 collected is EUR 41,282,117.95 and **USD 47.13m** (rate
0.87586).

---

# Part 3 — The workbook

Seven pages. One control panel at the top of every page, collapsed on the
Loans and Data pages. Colours fixed per **servicer** on every chart (Intrum
blue, Gescobro orange, Cerved green, Intrum - QQuant amber, Intrum - TDX
pink, **Unknown always grey**). "Servicer" is the data engineer's rule
(query-helper, Part 2; the manager's rule 2026-10-12): Massey organic UK, Fire organic
Italy, Gescobro organic, legacy or GESCOBRO-sourced Spain, Cerved legacy Italy,
Intrum everywhere else, with TDX and QQuant as named
sub-servicers. (This seven-page plan predates the rule; the live Servicing
dashboard uses the corrected one.)
The deal source is a filter and a table column, not a colour. Every chart title names
the measure, the level and the currency, e.g. *Collected by servicer
(EUR, portfolio level)*. Money to 2 decimals in tables, compact on cards
with the full figure on hover; ratios to at least 2 decimals in percent,
5 in tables. Nothing is rounded in the data.

## 3.1 Controls

| Control | Type | Column(s) | Notes |
|---|---|---|---|
| Display currency | list, single | parameter | EUR default; see 2.3 |
| Months shown | date range | `month_end` | default full history to latest complete month; drives trend charts and month tables |
| Servicer | list, multi | `servicer_full` (all four datasets) | who services the book, per the current rule (query-helper, 2026-10-12): Intrum, Massey, Fire, Cerved, Gescobro, Intrum - QQuant (Intrum - TDX once its key resolves) |
| Deal source | list, multi | `servicer_group` (portfolio, bands, loans) / `deal_source` (collections) | the acquisition channel: ORANGE/HEIMDALL, BLUE/LOKI, LEGACY, GESCOBRO, ORGANIC ORIGINATED. A filter and a table column, never a chart colour |
| Country | list, multi | `country_name` | 15 countries + Unknown; `UK` stays visible as a raw code |
| Deal | list, multi | `deal` | |
| Legal buyer | list, multi | `legal_buyer` | |
| Security class | list, multi | `security_class` | Secured is 0.02% of the book |
| Original currency | list, multi | `original_currency` | selecting one still shows display-currency figures, never local |
| Portfolio | list, multi | `portfolio` | also feeds the required selector on Loans |
| Acquisition cost at least (EUR m) | number | `capex_eur` | thresholds stay in EUR |
| Price paid, % of GBV | range | `price_percent` | |
| Batch | list, multi | `batch_bk` | Collections & payers only |
| As-of month | date, single | `month_end` | Portfolios page; default latest complete month |
| Month-end | date, single | parameter | Segments & bands, Loans |

Rules: empty means everything; **Unknown is a real value and stays
selectable** (at July 2026 it carries EUR 1.38m of collections and one
portfolio; hiding it makes totals not foot).

## 3.2 Overview — "Where we stand"

Latest complete month = the newest month whose portfolio count is at least
half the previous month's. Cards, from the portfolio dataset:

| Card | Definition | Comparison |
|---|---|---|
| Portfolio balance | `sum(balance)` at latest month; label *portfolio level* | vs prior month, % |
| Book value | `sum(carrying)` at latest month; footnote: exists only for portfolio-months that also report collections | vs prior month, % |
| Collected, latest month | `sum(collections)` at latest month | vs prior month, vs same month last year, % |
| Collected, last 12 months | `sum(collections)` over the 12 months to the latest | vs previous 12 months, % |
| Portfolios under management | `count(distinct portfolio)` at latest month | vs prior month, count |
| Against current forecast | `sum(collections) / sum(forecast)` at latest month | vs prior month, percentage points |
| Against servicer forecast | `sum(collections) / sum(servicer_forecast_eur)`; cumulative version uses `cumulative_collections_in_servicer_window_eur / cumulative_servicer_forecast_eur` | footnote: the underwriting plan left the dataset 2026-09-15 |
| Monthly collection yield | `sum(collections) / sum(balance)` at latest month | vs prior month, points |

Charts: *Collected against forecast and plan* (bars collected, line current
forecast, dotted line underwriting plan, one axis); *Collected by servicer*
(stacked, fixed colours); *Collected by country, latest month* (bars,
top ten + Other); *Portfolio balance by servicer, latest month* (bars). Table: month by month with portfolios, collected, current forecast,
collected ÷ forecast, plan, collected ÷ plan, balance, book value.

## 3.3 Plan vs actual

Note at the top: the **underwriting plan** is what we assumed when we
bought (from mid-2025, one version, 251 portfolios); the **current
forecast** is the live accounting forecast, revised as we learn. Behind plan
but on forecast means expectations were reset, not that the servicer
recovered. All figures on this page use the portfolio-months where a plan
exists.

Cards: Collected, Underwriting plan, Collected ÷ plan (with the % gap),
Collected ÷ current forecast. Charts: monthly collected / forecast / plan;
cumulative since the plan begins (three lines). Table by servicer:
portfolios, collected, plan, collected ÷ plan, forecast, collected ÷
forecast, collected minus plan; bar of collected minus plan by servicer
(green above, orange below). Scatter by portfolio: x = price paid % of GBV,
y = collected as % of plan, size = acquisition cost, colour = servicer,
dashed line at 100%. Table by portfolio beneath it, sorted worst
first.

## 3.4 Segments & bands (loan level, one month-end)

Note at the top: built from the loan level, so it shows the **mix** and the
**relative** performance of kinds of debt. Totals are not the book: at July
2026 the loan data covers 186 of 250 portfolios and loan-level balances run
87% to 146% of portfolio-level ones by servicer. Performance = collections
of the 12 months to the month-end ÷ balance at the month-end.

Four sections, each with a bar of balance by band, a bar of 12-month
collections as % of balance, and a table (portfolios, loans, share of
balance, balance, collected 12 months, collected ÷ balance, share of loans
paying):

1. **Borrower type** — Individuals / Companies / Unknown (no borrower record)
2. **Balance band** — under 1k, 1k–5k, 5k–20k, 20k–100k, over 100k (EUR)
3. **Age of debt** — under 2, 2–5, 5–10, over 10 years since default; Unknown
4. **Servicer segment** — the servicer's labels as reported, top 12 by
   balance + "All other segments"

Closing note: not available in the warehouse, so not shown: legal /
amicable / insolvency, instalment amounts, borrower age, a segment-split
plan.

## 3.5 Collections & payers (batch level)

Period control: Last 3, 6, 12, 18, 24 (default), 36 months, Last 5 years.
Load one month more than the period so "same month last year" exists, and
say so in the caption. Payer figures exist for roughly half of portfolios
(the Intrum PAM feed reports none): every payer card carries that footnote,
and payer ratios are computed only over rows with payer detail.

Cards: Latest month (vs prior month), Average last 3 months (average of the
monthly totals, not sum ÷ 3), Average last 6 months, Same month last year;
Paying loans, Share of loans paying (paying ÷ on book), Collected per paying
loan. Charts: monthly collections by servicer (stacked); receipts and
reversals (grouped bars). Table by batch: batch, portfolio, servicer, deal
source, country, original currency, latest month, prior month, change, average 3
months, same month last year, paying loans, loans on book, share paying,
has payer detail; totals on the money columns.

## 3.6 Portfolios

As-of month control. Cards: Portfolios, Portfolio balance, Book value (n of
N rows carry a value), Collected, Against current forecast, Net collections
(Intrum only; footnote: costs absent, not zero, for other servicers).
Charts: collected minus current forecast by servicer; portfolios
acquired by month of acquisition (caption: recorded dates span December
2025 to July 2026 only and 157 share December 2025). Table: portfolio,
servicer, deal source, country, currency, deal, legal buyer, security, flow type,
acquired, acquisition cost, price paid %, GBV at purchase, collected,
current forecast, collected ÷ forecast, plan, collected ÷ plan, balance,
book value, batches, unresolved key; totals on money columns.

## 3.7 Loans

Banner: loan-level figures do **not** tie to the portfolio-level totals
elsewhere and cannot; about 112 of 250 portfolios report no loan detail.
Required portfolio selector and month-end selector; nothing renders until a
portfolio is chosen. Cards: Loans on book (`count(distinct loan)`, never
case id), Outstanding (loan level), Paying in the last 12 months (share of
loans), Collected last 12 months. Table, default sort outstanding
descending: loan, case, portfolio, servicer, deal source, reporting
system, country, currency, deal, security, segment, legal buyer, forbearance,
outstanding, principal, interest, book value, collected 12 months,
collected lifetime, last payment, months since payment, paying 12 months.
Show the row count; if it equals 250,000 exactly, show a truncation
warning. `reporting_system` is the servicer's platform (intrum, cerved, gescobro,
souq, massey); label it *Reporting system*, and keep it apart from
*Servicer* and *Deal source*.

## 3.8 Data & definitions

The availability table from Part 1.2 / Part 4, the definitions below, and
the one table where an incomplete month may appear: month, portfolios,
collected, complete month (yes/no) from the portfolio dataset **without**
the complete-month filter.

Definitions to print: latest complete month; collected = gross cash
recoveries on the portfolio fact at the monthly average rate; portfolio
balance = face value at the month-end rate; book value = carrying amount;
current forecast vs underwriting plan (never averaged); currency (computed
in EUR, re-expressed at each month's rate, thresholds in EUR); servicer vs
deal source vs reporting system (query-helper, Part 2); Unknown
(unresolved keys, kept and labelled).

---

# Part 4 — Validation before anyone sees it

Complete months, EUR, from the warehouse on 2026-09-09, reproduced through
Sigma's own connection to the cent. If Sigma disagrees, Sigma is wrong.

| Month | Portfolios | Collected | Current forecast | Collected ÷ forecast | Balance |
|---|---|---|---|---|---|
| 2026-07-31 (latest) | 250 | 41,282,117.95 | 39,260,284.52 | 1.05150 | 48,789,794,448.86 |
| 2026-06-30 | 233 | 42,165,391.99 | 38,774,919.42 | 1.08744 | 48,793,778,221.44 |
| 2026-05-31 | 216 | 41,233,512.89 | 37,612,810.42 | 1.09626 | 48,608,554,140.47 |
| 2026-04-30 | 204 | 40,889,683.02 | 34,396,094.49 | 1.18879 | 48,487,598,088.02 |
| 2026-03-31 | 190 | 40,611,141.14 | 34,470,337.09 | 1.17815 | 48,486,409,278.77 |
| 2025-07-31 (year earlier) | 93 | 40,089,382.14 | 39,480,175.11 | 1.01543 | 46,807,057,693.20 |

Also at July 2026: underwriting plan 37,732,242.12 (249 of 254 rows);
carrying 1,263,184,284.58; net collections 29,464,696.64; yield 0.08461%;
collected last 12 months EUR 474.74m; collected ÷ plan cumulative since June
2025 = 533.96m ÷ 507.99m = 105.1%. By deal source: ORANGE/HEIMDALL
22,820,768.28 · BLUE/LOKI 8,339,000.92 · LEGACY 6,983,164.71 · Unknown
1,381,050.93 · GESCOBRO 1,044,951.74 · ORGANIC ORIGINATED 713,181.37; these
six sum to the total exactly, or a join has gone inner. By servicer the same
total split Intrum / Gescobro (LEGACY Spain) / Cerved (LEGACY Italy) /
Intrum - QQuant (one Greek portfolio) under the old rule; the rule was
replaced on 2026-10-12 (Massey, Fire; Gescobro all of Spain's legacy, organic and Gescobro-sourced books; Cerved legacy Italy), see
query-helper Part 2, so re-measure this split before quoting it.

Checklist:

1. Collected, latest month equals the July row to the cent.
2. The servicer bars sum to it, and so do the deal-source rows in the table.
   The deal source `GESCOBRO` shows under servicer *Intrum* until the
   engineer confirms the rule; do not "fix" it in Sigma.
3. Selecting every servicer, and separately every deal source including Unknown, changes nothing.
4. Selecting one original currency still shows display-currency figures.
5. Switching to USD shows 47.13m for July.
6. The completeness table shows 2026-08-31 as incomplete and no other page shows it.
7. Loans: `LOK-DE24016-U01/2512` at 2026-07-31 returns 8,104 loans, none duplicated.
8. Segments & bands at 2026-07-31 reports 186 portfolios and 21.8m loans.
9. Run `base_reconciliation.sql` the same day; check 15 must read `RECONCILES`.

Open items for the data team, to state on the Data page rather than hide:
`GROSS_CASH_RECOVERIES` (the headline figure) has no description in the
warehouse; the loan fact carries country code `UK` (48,784 loans) beside
ISO `GB`; capex dates read as a migration date; 248 carrying rows in the
last 24 months have no matching actuals; capex and GBV are stored in local
currency and converted here at the capex month's rate.

---

# Part 5 — Build order in Sigma

1. Open the workbook (link at the top). Add pages: *Overview*, *Plan vs
   actual*, *Segments & bands*, *Collections & payers*, *Portfolios*,
   *Loans*, *Data & definitions*, plus a hidden *Data* page for the SQL
   elements.
2. On *Data*, create the five custom SQL elements per 2.2, in this order:
   rates, portfolio summary, loan bands, collections monthly, loan detail.
   Name each after its file without the extension. Add the two
   dataset-level filters as element filters, not page controls.
3. Add the display-currency control and the divided columns (2.3). Check
   the USD figure.
4. Build the control panel (3.1) once, on Overview, then copy to the other
   pages.
5. Build the pages in the order of Part 3, cards first, then charts, then
   tables. Take every label and definition from Part 3 verbatim; nothing
   gets a code.
6. Run the Part 4 checklist. Use the Sigma MCP `query` tool against the
   PROD connection to reproduce any figure that looks off.
7. Hide the *Data* page. Publish. Do not share beyond Sharlene until the
   data team has agreed who may see NPL data.

Before publishing a change later: re-run `base_reconciliation.sql`, re-check
the July row, and re-read Part 1.2 so nothing is promised that the
warehouse cannot show.
