# Local workspace

A place to write Jupyter notebooks that query Brocc's Snowflake data
warehouse, using Python and pandas.

New machine? Start with [SETUP.md](SETUP.md). If your notebooks already run, skip to
[Everyday use](#everyday-use).

### Contents

| Section | Read it when |
|---|---|
| [What this is, in plain terms](#what-this-is-in-plain-terms) | You want to know what mise, uv and `datalake` are for |
| [Setting up](#setting-up) | Nothing works yet, or you are on a new machine |
| [SETUP.md](SETUP.md) | Replicating this workspace on a machine that has nothing. **A separate file** — read once |
| [Everyday use](#everyday-use) | Writing queries, running `.sql` files, exporting |
| [Things that will confuse you](#things-that-will-confuse-you) | A query ran but the result looks wrong |
| [Precision](#precision) | You're reporting money, rates or ratios |
| [Where things are](#where-things-are) | Looking for a file, task or `datalake` call |
| [When something breaks](#when-something-breaks) | An error message you want translated |

---

## What this is, in plain terms

You want to pull data out of Snowflake and look at it in a notebook. Three
pieces make that work:

| Piece | What it does | Why you care |
|---|---|---|
| **mise** | Installs the right Python (3.12) and manages settings per folder | You never install Python by hand, and everyone gets the same version |
| **uv** | Installs Python packages, very fast | Replaces `pip`; keeps a lockfile so installs are reproducible |
| **`datalake`** | A small helper written for this workspace | Turns one line of Python into a Snowflake query and a pandas table |

The point of `datalake` is that this:

```python
import datalake
df = datalake.q("select current_date() as today")
```

replaces roughly thirty lines of connection, cursor and DataFrame handling.
`df` is an ordinary pandas DataFrame.

This workspace is deliberately **separate from `brocc-data`**. That repo
runs dbt with an exact, pinned set of packages; adding notebook packages
there can break dbt builds and CI. Experiment here instead.

---

## Setting up

New machine: follow [SETUP.md](SETUP.md). The quick start at the top takes about 15 minutes if
you already have GitHub and Snowflake access. The full steps behind it cover dbt and anything
that goes wrong.

Ask for your Snowflake roles first. Nothing works without them and they depend on someone else.

To check an existing setup, run `mise run check`. If it prints `CONNECTED`, you're done.

## Everyday use

`cd` into the workspace and mise activates the environment for you — no
`source .venv/bin/activate`.

```python
import datalake

datalake.session_info()            # who am I and what am I connected to?
df = datalake.q("select 1 as x")   # run a query -> pandas DataFrame
```

### Writing queries

Short ones inline:

```python
df = datalake.q("select count(*) as n from PROD.npl_common.fct_case_collection")
```

Longer ones belong in a `.sql` file — you get proper SQL highlighting and
readable diffs. Pass the file name instead of the query:

```python
df = datalake.q("general_queries/data_dictionary")        # work/general_queries/*.sql
print(datalake.read_sql("general_queries/data_dictionary"))  # just look
df = datalake.q("general_queries/data_dictionary", target_schema="NPL_COMMON")  # override a `set`
```

The name is found, with `.sql` optional, in this order:

1. **next to your notebook** — for a query only that notebook uses
2. **[work/](work/)** — shared between notebooks
3. the workspace root

### What is in `work/servicing/`

[work/servicing/](work/servicing/) is the **Servicing dashboard in Sigma**, and
only that: six `.sql` files, one per Sigma Custom SQL element, plus the build
guide and the caveats. [work/servicing/README.md](work/servicing/README.md) is
the map and the paste order.

They are not run from this workspace in the normal way — they are pasted into
Sigma. Two of the six read a dbt table that **is not in PROD yet**
(`MART_NPL_SERVICING_AGG_CASES_MONTHLY`, raised on `brocc-data` branch
`add/servicing-mart`, not merged), so four of the six are the live dashboard
today.

⚠ **The 30-file servicing base layer that used to live here was retired on
2026-10-02.** It was built to a coverage goal — one grain-checked view per PROD
object, 29 of 32 covered — and nothing read it. The files are in
`work/.archive/2026-10-02-servicing/`, which nothing depends on and which can be
deleted. `.claude/agents/query-helper.md` still records every grain, join key
and trap that layer encoded; read it before writing a query from scratch.

The prefixes it used, in case you meet one in an old notebook:

| Prefix | Means | Example |
|---|---|---|
| `ref_` | a reference list, one row per thing | `ref_loan`, `ref_portfolio` |
| `base_` | the lowest grain available | `base_case`, `base_case_collection` |
| `monthly_` | one row per month | `monthly_portfolio_performance` |
| `agg_` | a rollup built on the base layer | `agg_portfolio_collection_monthly` |

#### ⚠ The one trap that outlived the base layer

The retired chain carried **two** collection figures side by side, and the
lesson generalises to any query you write:

| | |
|---|---|
| **Reported collections** | from the portfolio fact. All portfolios, all servicers. **Chart this.** |
| **Case collections** | the loan-level sum. Drillable to the loan, and structurally incomplete. |

The loan-level feed is **60.18%** of reported collections (July 2026:
EUR 24,842,484.52 against EUR 41,282,117.95) and reaches 138 of 250 portfolios.
Worse, **all of it is Intrum** — a "by servicer" chart built on the case column
shows Intrum at 100% and silently deletes Gescobro and Cerved, with no error.

Never mix the two in one figure, and say which one a number came from.
`.claude/agents/query-helper.md` has the full measurement and the other traps.

### Filling in values

Table and database names can't be passed as query parameters (a Snowflake
rule, not ours). In a `.sql` file, use a **Snowflake session variable** — it
is ordinary SQL, so the file still runs in the extension:

```sql
set target_schema = 'NPL_COMMON';
select * from PROD.information_schema.columns where table_schema = $target_schema;
```

`datalake` and `mise run sql` rewrite both the `set` line and every `$name`
use, so `q("file", target_schema="COMMON")` works and each value gets its own
result-cache entry.

For a *database or schema name*, spell it out rather than parameterising it:
`NPL_ANALYST` can read `PROD` and `RAW` only, so there is nothing to switch.

`datalake` also supports Python `str.format` placeholders (`{db}`-style) for
object names, but **only use them in SQL written inline in Python** — see the
last section of
[examples/example_servicing-dashboard.ipynb](examples/example_servicing-dashboard.ipynb).
A `.sql` file containing them cannot run in the extension, which sends the
file to Snowflake verbatim.

⚠ Don't write that brace syntax in a `.sql` file's *comments* either.
`placeholder_names()` matches it with a plain regex that knows nothing about
SQL comments, so a file merely mentioning it is treated as a placeholder file
and `str.format` rewrites the comment.

Actual *values* should be real parameters — safer and faster:

```python
datalake.q("select * from t where dt >= %s", ["2026-01-01"])
```

### Running a `.sql` file from the terminal

You don't need a notebook to see a query's output:

```bash
mise run sql -- examples/example_servicing-dashboard.sql
mise run sql -- examples/example_servicing-dashboard.sql months=3
mise run sql -- collections_by_servicer months=6 --csv out.csv
```

The `--` matters: it tells mise the rest belongs to the script, not to mise.

`key=value` pairs drive the file whichever style it uses: they rewrite a
matching `set name = ...;` line, or fill a `{placeholder}`. A name that
matches neither raises, and the error lists the names the file does accept.
Useful flags:

| Flag | What it does |
|---|---|
| `--show` | Print the finished SQL and exit, without running it |
| `--limit N` | Print only the first N rows |
| `--csv PATH` | Also write the full result to CSV |
| `--connection sandbox` | Use `brocc-sandbox` instead of prod |

`--show` is the one to reach for when a query misbehaves — it shows exactly
what was sent to Snowflake after substitution.

### Running a `.sql` file in VS Code, with a results panel

The Snowflake extension gives you a Run button on a `.sql` file and a
sortable, exportable results grid — the nicest of the three views.

It's installed and pointed at your config already. To use it:

1. Open the Snowflake icon in the VS Code sidebar and sign in — pick the
   `prod` connection. This is the same browser SSO as everything else.
2. Open [examples/example_servicing-dashboard.sql](examples/example_servicing-dashboard.sql)
   and hit **Run All** (or ⌘⏎).

If no connections are listed, reload the window
(Command Palette → *Developer: Reload Window*) — the setting pointing it at
`~/.snowflake/config.toml` is applied on load.

**The one rule for `.sql` files here.** The extension sends the file to
Snowflake *verbatim* — it does no Python substitution. So every `.sql` file
in this workspace parameterises itself with **Snowflake session variables**
(`set months = 12;` and `$months`), never with Python `str.format`
placeholders, which would fail with a syntax error.

That is checked, not assumed: every `.sql` file here was verified against
the warehouse on 2026-09-09 by sending it verbatim and compiling it. All of
them pass, so any of them can be opened and run in the extension.

Session variables are ordinary SQL, so Snowflake understands them wherever
the file is run, and `datalake` / `mise run sql` additionally rewrite the
`set` line so a value can be overridden per call. Change the window either
by editing the `set` line or by passing `months=3`.

If you need a Python placeholder — to vary a database or schema name from
Python — keep that SQL **inline in the notebook**, not in a `.sql` file. See
the last section of
[examples/example_servicing-dashboard.ipynb](examples/example_servicing-dashboard.ipynb).

### Data dictionaries

Every NPL table carries its description **inside Snowflake**. The dbt project
sets `persist_docs` for relations and columns, so each build pushes the model
docs down as native `COMMENT`s — Snowflake itself is the dictionary, there's
no separate catalog to check.

```python
datalake.tables()                            # all NPL tables + descriptions
datalake.dictionary("fct_case_collection")   # columns, types, descriptions
datalake.describe_column("reporting_system_sk")  # which tables have this column?
datalake.find_columns("servicer")            # where does this concept live?
```

`describe_column()` is the one to reach for when you have an exact column
name and need to know **where it lives**. It returns one row per table
carrying that column, with the *table's* description alongside the
*column's*, so you can see when the same name means something different in
two places, or has a different type. Pass `exact=False` to match on part of
a name. `find_columns()` is the fuzzier sibling — it searches descriptions
too, for when you know the concept but not the name.

Or in the results panel / terminal:

```bash
mise run sql -- work/general_queries/data_dictionary.sql table_filter='FCT_%'
```

Coverage is partial — **22 of 26** tables and **217 of 331** columns
(66%) are documented. An empty description means the dbt model has no doc for
that column, not that it's unimportant. Least documented, worth knowing before
you rely on them: `DIM_PORTFOLIO` (2 of 19 columns, and it holds GBV and
pricing), `DIM_SEGMENT`, `DIM_DEAL_SOURCE` and `DIM_FORECAST_SOURCE` (no docs
at all).

### Saving results

```python
df.to_csv("2026-09-09-collections.csv", index=False)
df.to_excel("2026-09-09-collections.xlsx", index=False)
```

### Adding a package

```bash
uv add duckdb        # then restart the notebook kernel
uv remove duckdb
uv sync              # after someone else changes pyproject.toml
```

---

## Things that will confuse you

Three of these, and every one of them has caught someone out.

### 1. Column names come back SHOUTING

Snowflake upper-cases them, so it's `df["COLLECTED"]`, not
`df["collected"]`. If you'd rather have lower-case:

```python
df = datalake.q(sql, lower=True)
```

### 2. Table names in Snowflake don't match the dbt filenames

The model file `fct_npl_case_collection.sql` in `brocc-data` becomes
`PROD.NPL_COMMON.FCT_CASE_COLLECTION` — the `npl_` prefix is dropped. So
never copy a table name straight from the repo. Check the real one:

```python
datalake.q("show tables in schema PROD.NPL_COMMON")[["name"]]
```

### 3. Numbers and dates are converted for you

Snowflake hands back `Decimal` and `date` objects, which break `.dt`
accessors, number formatting and plotly. So `q()` maps them to `float64`
and `datetime64` by default.

That is the right default for charting and slicing, and the wrong one for
money you intend to add up exactly — see [Precision](#precision) below.
Pass `convert=False` to keep the original `Decimal` values.

---

## Precision

Results are displayed to **up to 5 decimal places**. Two is too few: it
hides real differences in rates, ratios and per-unit figures.

This is display formatting only — the values themselves keep full
precision:

```python
pd.set_option(
    "display.float_format",
    lambda v: f"{v:,.5f}".rstrip("0").rstrip("."),
)
```

Two rules follow from that:

- **Never `df.round(n)` to tidy up output.** Rounding mutates the
  DataFrame and permanently discards data. Format on display instead.
- **For exact decimal arithmetic, pass `convert=False`** to `q()`. You keep
  Snowflake's `Decimal` values rather than float64, which is what you want
  before summing money or deriving a rate you'll report.

---

## Where things are

```
~/data-warehouse/
├─ CLAUDE.md                    # which workspace a change belongs in
├─ data-warehouse.code-workspace  # open THIS in VS Code — see Step 3
├─ brocc-data/                  # the team's dbt repo — sibling, read-only
└─ local-workspace/             # this workspace
```

The two directories are siblings, not nested. `local-workspace` appears
first in the VS Code sidebar only because the `.code-workspace` file lists
it first; the order carries no meaning.

```
local-workspace/
├─ README.md                    # this file — orientation + everyday use
├─ SETUP.md                     # first-time setup. Read once
├─ mise.toml                    # Python version, env vars, tasks
├─ pyproject.toml, uv.lock      # the Python packages, pinned
├─ .gitignore                   # keeps every data file out of git
├─ .pre-commit-config.yaml      # refuses data files, big files and keys at commit
├─ .vscode/settings.json        # interpreter + Snowflake extension config
├─ .claude/agents/              # six agents, all generic — deal-specific
│                               # knowledge lives in content files, not here
├─ packages/datalake/           # the importable query helper
├─ bootstrap/                   # machine-local files brocc-data gitignores,
│                               # installed by SETUP.md
├─ scripts/                     # what the mise tasks run: check_connection.py,
│                               # run_sql.py (the engine behind `mise run sql`)
├─ examples/                    # worked examples — copy or delete freely
│  ├─ example_servicing-dashboard.ipynb / .sql
│  ├─ example_collections_by_servicer.sql
│  ├─ asset-index-sharepoint-example/  # sorting a seller delivery, on synthetic data
│  ├─ snowflake-config.toml.example    # template for ~/.snowflake/config.toml
│  └─ Template.pptx             # slide template
└─ work/                        # all analysis. `datalake.q("name")` and
   │                            # `mise run sql -- name` resolve bare names here
   ├─ general_queries/          # queries used by more than one thing
   ├─ data-issues/intrum/       # feed gaps, undocumented codes, escalations
   ├─ servicing/                # the Sigma servicing dashboard
   ├─ data-quality/             # the Sigma servicer data-quality dashboard
   ├─ benchmark-dataset/        # how to build a benchmark for ANY book:
   │                            # pre- and post-registration, bridge, stitched
   ├─ project-<slug>-benchmark/ # one finished benchmark book each (elsa, sea)
   ├─ project-<slug>/           # one deal-level piece of work each (iron, mbank, noba)
   ├─ asset-index/              # everything about seller tapes in the asset index
   │  ├─ cloud/                 # bridging tapes to CAT, CASE-BRIDGING.md
   │  ├─ cloud-agent-check/     # cleaned approved Portuguese tapes, for the agent
   │  └─ sharepoint/            # SharePoint deliveries (data, gitignored) + checks/
   ├─ workshop/                 # the Data Landscape notebook and its queries
   ├─ hackathon/                # Sweden status notebook + intrum_clarifications/
   ├─ firedrill/                # which markets we can price
   ├─ average_balance/          # Heimdall reference-data check
   ├─ portugal/, italy/         # country work
   ├─ dbt/                      # models staged for promotion into brocc-data
   └─ .archive/<date>-<topic>/  # retired material, each with a README
```

### Commands

| Command | What it does |
|---|---|
| `mise install` | Install Python + create the venv |
| `uv sync` | Install/update packages |
| `mise run kernel` | Register the Jupyter kernel for VS Code |
| `mise run sql -- <file>` | Run a `.sql` file and print the result |
| `mise run check` | Test the Snowflake connection |
| `mise run lab` | Open JupyterLab instead of VS Code |
| `mise tasks` | List all available tasks |

### `datalake` reference

| Call | What it does |
|---|---|
| `q(sql)` | Run a query → pandas DataFrame |
| `q("name")` | Run `work/name.sql` |
| `q(sql, lower=True)` | Lower-case the column names |
| `q(sql, convert=False)` | Keep exact `Decimal` values instead of float |
| `q(sql, params)` | Run with bound parameters |
| `read_sql("name")` | Read a `.sql` file without running it |
| `execute(sql)` | Run a statement, ignore the result |
| `session_info()` | Account, user, role, warehouse, database |
| `warehouses()` | Warehouses your role can use |
| `q(sql, connection="sandbox")` | Query `brocc-sandbox` instead of prod |
| `reset()` | Reconnect after your login token expires |

### The two connections

| Name | Account | Role | Use for |
|---|---|---|---|
| `prod` *(default)* | brocc-prod | NPL_ANALYST | Reading production data |
| `sandbox` | brocc-sandbox | PUBLIC | Scratch work, dbt dev schemas |

`prod` is the default, set by `SNOWFLAKE_CONNECTION` in
[mise.toml](mise.toml).

---

## When something breaks

| Symptom | Cause and fix |
|---|---|
| `No active warehouse selected` | `SNOWFLAKE_WAREHOUSE` isn't set in [mise.toml](mise.toml). Should be `NPL_ANALYST_WH`. |
| `Object '...' does not exist or not authorized` | Usually the wrong table name — check with `show tables in schema PROD.NPL_COMMON` (see above). |
| `ModuleNotFoundError: datalake` | Wrong kernel. Pick **Python (local-workspace)** in the top-right of the notebook. |
| Kernel not in the list | Run `mise run kernel`, then reload the VS Code window. |
| "Running cells requires the ipykernel package" | It's already installed — VS Code probed the wrong interpreter. Pick **Python (local-workspace)** and reload the window. [Details](#running-cells-requires-the-ipykernel-package--and-then-it-asks-for-pip). |
| VS Code then complains about `pip` | Expected — `uv` builds venvs without pip, and you don't need it. Ignore the Install button; use `uv add` / `uv sync`. |
| Keychain box every single run | You clicked *Allow*. Click **Always Allow**. |
| `Config files ... are not trusted` | Run `mise trust` in this folder. Expected on first use. |
| Login token expired mid-session | `datalake.reset()`, then re-run your query. |
| `mise: command not found` | [Step 5](SETUP.md#step-5--install-mise) isn't finished — add `mise activate` to `~/.zshrc` and restart the terminal. |
| No interpreter offered, and the Snowflake extension sees no connections | You opened the `~/data-warehouse` folder instead of the `.code-workspace` file. See [Step 3](SETUP.md#step-3--open-the-workspace-file-not-the-folder). |

Still stuck? Ask Claude Code: *"my workspace setup is broken, help me fix
it"* — the setup agent diagnoses this list for you.

---

## A note on pandas

`brocc-data`'s `analytics-wizard` agent doc says to always use polars and
never pandas, for memory reasons. This workspace uses **pandas** by
choice. That convention governs code committed to `brocc-data`; local
exploration is your own call. If you move a notebook into that repo, expect
to convert it.
