# Proposed `brocc-data` models — the NPL **platinum** layer

**What this is.** Three dbt models that read the golden NPL marts and produce the tables
Sigma consumes directly. Written in `brocc-data`'s conventions and laid out in its folder
structure, so approving it is a drag-and-drop plus one commit. Nothing here has been added
to `brocc-data`, and nothing here runs from this workspace — dbt models only build from the
tracked repo.

**Why it exists.** The Servicing dashboard was one 900-line Sigma custom-SQL element doing
its own joins, FX conversion, window functions and reconciliation on every refresh. That
put the logic outside version control, outside dbt's tests, and outside anyone's review.
These models move it into the warehouse and leave Sigma doing what Sigma is good at:
grouping and filtering.

```
work/dbt/                      → maps onto brocc-data/transformation/dbt/
└── models/marts/
    ├── npl_platinum/                    the general-purpose layer
    │   ├── dim_npl_platinum_portfolio.sql
    │   ├── dim_npl_platinum_case.sql
    │   ├── fct_npl_platinum_case_status.sql
    │   ├── agg_npl_platinum_portfolio_monthly.sql
    │   ├── agg_npl_platinum_forecast_monthly.sql
    │   ├── agg_npl_platinum_case_payer_monthly.sql
    │   └── models.yml
    ├── npl_platinum_snowflake/          GENERATED. Runnable copies, see below.
    └── servicing_dashboard/             the three models Sigma reads
        ├── agg_npl_portfolio_monthly.sql
        ├── agg_npl_case_payer_monthly.sql
        ├── agg_npl_reconciliation_monthly.sql
        └── models.yml
```

## Running the platinum models without dbt

`{{ ref('x') }}` means nothing to Snowflake, so the dbt models cannot be run from
here. `npl_platinum_snowflake/` holds the same six models with every ref resolved
to its PROD object:

```sh
mise run platinum-sql        # regenerate after changing a model
mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/dim_npl_platinum_portfolio.sql
```

All eight were run on 2026-09-24 and return exactly what the dbt versions do.

⚠ **CTE names must be unique across the layer, not just within a file.** A name the
generator inlines twice resolves to the outer CTE and fails as an *invalid recursive
CTE* — dbt never sees this, because there the refs are real tables. The generator now
asserts on it.

## The Excel extract

```sh
mise run platinum-xlsx       # work/npl_platinum_extract.xlsx
```

Four models fit; four are far past Excel's 1,048,576-row limit and are **not
truncated** — a million-row slice of a 33m-row table looks complete and is badly
wrong. The `INDEX` sheet is first and names every model with its real row count, so
the file cannot be mistaken for the whole layer.

⚠ **These counts move.** They were 265 and 6,908 a day earlier: `DIM_PORTFOLIO`
lost a row and the portfolio fact lost three, with no change to the fact's
`as_of_ts` (2026-09-18 14:22). Treat any row count in this repo as a reading,
not a constant, and re-measure before quoting one.

⚠⚠ **Never edit those files, and never move that folder into `brocc-data`.** The
filenames duplicate the originals, and two models with the same name break
`dbt parse` outright. Edit the dbt model and regenerate.

⚠ `dim_npl_platinum_case` inlines `dim_npl_platinum_portfolio` as a subquery,
because the sibling is not a table yet. That file is 306 lines and runs slower
than the dbt version would — expected, not a bug.

**The two folders are shaped for different jobs, and that is the point.**
`servicing_dashboard` is Sigma-shaped: currency summed away, the acquisition floor
baked in, the drill path denormalised onto every row. Right for a dashboard, wrong
for anything else. `npl_platinum` keeps currency in the grain, applies no floor, and
carries EUR beside local currency, so a consumer chooses both deliberately.

dbt resolves `ref()` by **model name, not path**, so splitting the folders broke
nothing — `agg_npl_reconciliation_monthly` still refs the other two across folders.

## The general-purpose layer (added 2026-09-24)

| Model | Grain | Rows | What it carries |
|---|---|---|---|
| `dim_npl_platinum_portfolio` | portfolio | 264 | the whole drill path resolved once — seller, vehicle, project, deal, servicer, region, country — plus purchase economics and the derived Intrum registration window |
| `dim_npl_platinum_case` | case | 22,530,117 | static loan attributes and today's status, collapsed from 154,077,844 versions |
| `fct_npl_platinum_case_status` | case × spell | 81,602,905 | every status change, with the date it changed and the date it changed again |
| `fct_npl_platinum_case_collection_daily` | portfolio × case × day × currency | 33,526,856 | every collection at the day it landed |
| `agg_npl_platinum_case_collection_monthly` | portfolio × case × month × currency | 27,886,553 | the same, per month, with the payer flags per loan |
| `agg_npl_platinum_portfolio_monthly` | portfolio × month × currency | 6,905 | the servicer's report — the authoritative cash figure |
| `agg_npl_platinum_forecast_monthly` | portfolio × month × currency | 6,570 | all three forecasts side by side |
| `agg_npl_platinum_case_payer_monthly` | portfolio × month × currency | 3,074 | the case-monthly model counted up |

### The loan-level chain

```
fct_npl_platinum_case_collection_daily        one row per loan per DAY
  → agg_npl_platinum_case_collection_monthly  per loan per MONTH, + payer flags
    → agg_npl_platinum_case_payer_monthly     per portfolio per month
```

The 134,171,285-row collection fact is scanned **once**, at the bottom. Local-currency
totals agree to the cent across all three: **21,056,695,069.46**.

The flags live on the middle model, one row per loan-month, so a loan's behaviour is
inspectable rather than only ever appearing as a portfolio count. `is_activated_flag`
fires once per loan ever; `is_new_flag` fires on every return after a two-month gap —
they are not the same thing. `lost_at_month` is forward-dated onto the last paying
row, because a month a loan did not pay has no row to flag.

All six run and verified against PROD on 2026-09-24.

### Three things this layer decides once, so nobody re-decides them badly

**`case_sk` is a version key, `case_bk` is the loan** — 6.84 versions each, one loan
has 1,854. Counting `case_sk` inflates any loan count several-fold. The dimension is
keyed on `case_bk`; the collection fact is still joined on `case_sk` *without*
`is_current_flag`, because it carries the version in force at the collection and that
is point-in-time correct.

**Status history is its own model.** Status changes on 52.6% of loans, so folding it
into the dimension would repeat every static column on every change.

**⚠ `intrum_registration_date` is not stable.** It moves across versions on 4,476,245
cases (19.9%), by an average of 1,142.7 days; only 3,856 move within a month, so this
is re-dating rather than drift. A vintage cut built on it shifts between runs unless
you pin which version you mean — `intrum_registration_date_first` and
`registration_date_moved_flag` exist for exactly that. `brocc_registration_date` is a
different thing entirely: the portfolio's capex date, derived, because nothing on the
case records when Brocc acquired it.

## The three tables

| Model | Grain | What it carries |
|---|---|---|
| `agg_npl_portfolio_monthly` | portfolio × month | Money and all three forecasts in EUR, plus the full drill path. The table Sigma groups by. |
| `agg_npl_case_payer_monthly` | portfolio × month | Loan-level payer behaviour, already aggregated up. No case, deal or currency drill — join to the portfolio model for those. |
| `agg_npl_reconciliation_monthly` | portfolio × month | Every flag in one place. Reads the other two and nothing else. |

All three join on **`(portfolio_sk, reporting_month)`**, and `reporting_month` is
**month-end** in all three.

## Two decisions worth knowing

**No rolling windows, no cumulative columns.** The Sigma dataset carried L1M/L3M/L6M/L12M
and since-inception totals for collections and every forecast. They are gone. A stored
window is wrong the moment anyone regroups, and a running total summed across months
silently multiplies. Sigma computes those after filtering.

**Flags live in their own table.** The money models carry no flags and the flag model
carries no money — read `collections_sum` from the portfolio model, never the local-currency
column in the reconciliation model.

## Verified against the dataset it replaces

Run 2026-09-21 against PROD, compared row for row with the Sigma dataset:

| | Platinum | Sigma dataset |
|---|---|---|
| Collections | 371,073,127.47 | 371,073,127.47 |
| Net collections | 271,863,250.85 | 271,863,250.85 |
| Servicer forecast | 314,714,103.69 | 314,714,103.69 |
| Accounting forecast | 326,096,979.47 | 326,096,979.47 |
| Underwriting forecast | 329,017,121.49 | 329,017,121.49 |
| Servicer cost | 99,209,876.62 | 99,209,876.62 |
| Payer counts (1,099 months) | zero difference | — |
| `feed_stopped_flag` | 54 | 54 |
| `have_loan_detail_flag` | 1,320 | 1,320 |
| `is_multi_currency_flag` | 24 | 24 |
| `is_reconciled_flag` | **448** | 446 |

**The two extra reconciled months are deliberate.** The Sigma dataset matched the loan feed
to the servicer report on currency as well as month, so a month whose loan feed carried a
different currency code read as unreconciled even where the money agreed. Two months on
`HEI-PL25001-S01/2512` now reconcile at 0.4% and 0.6%. Single-currency months are unaffected.

All three models are unique on `(portfolio_sk, reporting_month)`, asserted in `models.yml`.

## SQLFluff audit — what CI will say

Read from `transformation/dbt/.sqlfluff`. The linter cannot be run from here: it uses the
dbt templater, which compiles the whole project, so the models would have to sit inside
`brocc-data` first — and putting them there is the PR, not a check. What follows is the
config read against the files.

| Rule | Config | These models |
|---|---|---|
| `aliasing.table` | explicit | **pass** — every table alias uses `AS`, 0 bare |
| `aliasing.column` | explicit | **pass** — every column alias uses `AS` |
| `max_line_length` | 120 | **pass** — 2 violations found and wrapped |
| `indent_unit` / `tab_space_size` | space / 4 | **pass** |
| `capitalisation.keywords` | **lower** | **fail by design** — ~138 uppercase keywords |
| `capitalisation.functions` | **lower** | **fail by design** |
| `capitalisation.identifiers` | **lower** | pass — identifiers are already lowercase |
| `capitalisation.literals` | **lower** | **fail by design** — 46 `TRUE`/`FALSE`/`NULL` |
| `ST06` column order, `AL07` alias forbid, `RF04` keywords | excluded | n/a |

The capitalisation failures are the known house-style conflict below, and `mise :format`
resolves them by rewriting to lowercase.

## ⚠ House style vs the CI lint gate — read before opening the PR

These are written in **Sharlene's style: SQL keywords AND function names UPPERCASE,
identifiers lowercase**, one column per line, `ON` and each `AND` on their own indented
line, explicit `AS` on every table alias, anti-joins as `LEFT JOIN … IS NULL` rather than
`NOT IN`. `brocc-data` itself is lowercase and SQLFluff gates CI.

**Run `mise :lint` and `mise :format` from `brocc-data/transformation/dbt` after moving
these**, and expect the formatter to lowercase them. That is the repo's call, not ours —
do not fight it.

## What was checked against the data team's own standards

Read from `brocc-data/transformation/dbt/.claude/agents/dbt-agent.md`:

- **Config lives in `models.yml`, not in the SQL.** Matches `mart_npl_flash_report`, the
  repo's existing mart-built-on-marts. No `{{ config() }}` block in any of the three.
- **`alias` equals the model name**, same as `mart_npl_flash_report`.
- **Materialization is inherited** — `dbt_project.yml` already defaults marts to `table`,
  so it is not restated. The agent doc says start simple and add complexity only as needed.
- **`ANY_VALUE` for fields that are 1:1 to the grain**, which is the repo's idiom, rather
  than `MAX` standing in for it.
- **`models.yml`**, not `_npl_platinum__models.yml` — the agent doc suggests the latter but
  every existing marts folder in the repo uses the former. The repo wins.
- **Common dimensions are reused**, not rebuilt: `dim_country` for region and country name.

**One standard is knowingly not met.** The agent doc says *"don't create marts with
aggregated time dimensions — these move beyond marts into metrics"*. These models are
portfolio × month by design. The precedent is the repo's own `mart_npl_flash_report`, which
is also portfolio × month and also built on marts; and the alternative is leaving the
aggregation in a Sigma text box. Worth raising with the data team rather than assuming.

**`gbv` vs `gross_book_value`.** `transformation/dbt/AGENTS.md` lists `gbv` as the house
abbreviation for Gross Book Value, and the source column is `gbv`. These models alias it to
`gross_book_value` and emit `gross_book_value_sum`, which follows this workspace's
"spell names out" rule but departs from the repo's documented vocabulary. One-line change
either way — the data team should pick.

**One to discuss.** `agg_npl_portfolio_monthly` brings together nine concepts, above the
"4-5" the agent doc suggests before reaching for intermediate models. Splitting the three
forecast CTEs into one intermediate model would bring it down and remove the repetition.
Left as is for now because the three forecasts differ in ways the header documents, and
folding them together hides that — but it is the obvious next refactor if the data team
would rather.
