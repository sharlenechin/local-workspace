# `work/servicing/`

Split into two folders on 2026-09-14, so it is obvious which queries are
**candidates for dbt models** and which already sit on modelled data.

```
servicing/
├─ prod/    30 files — read PROD.NPL_COMMON / PROD.COMMON only
├─ raw/      3 files — also read RAW.HYPERION_INTRUM_CAT, NOT modelled in PROD
└─ sigma/    5 files — GENERATED, paste-ready. Never edit; `mise run sigma-sql`
```

## `raw/` — the queries that should become dbt models

**These are the hand-off set.** Each one reads a RAW table that PROD does not
model and, in most cases, that is **not even declared as a dbt source** — only
6 of the 35 Intrum CAT tables are (`cases`, `invoices`, `transactions`,
`debtors`, `installment`, `settlement`).

| File | Reads | Gives you |
|---|---|---|
| `dash_phase_collections.sql` | `GROUP_CASE_PHASE` + PROD collections | the per-payment split by month — reference / dbt prototype, no longer pasted into Sigma |
| `dash_phase_collections_wide.sql` | same | the split as joinable columns — reference only since 2026-09-15 |

⚠ **Every file here carries change-history traps.** RAW Intrum tables repeat
every version of every record: dedupe to the latest version, pin the source
system (`CASE_ID` is unique only within an instance), match `_file_path` as a
**literal prefix** with no leading `%`, and read every extract. The full list
is in `work/benchmark/METHOD.md`.

⚠ **Codes in RAW are mostly undecoded.** The phase codes have a readable
prefix and are usable with a caveat; `ACTIONS` codes (`G_1`, `G_16`, …) are
not usable at all. Keep every unconfirmed label marked as unconfirmed — the
phase file returns `'A (amicable?)'` on purpose.

→ What to build, in what order: `work/servicing-dashboard/DBT-HANDOFF.md`.

## `prod/` — queries on already-modelled data

31 files reading conformed PROD tables. One feeds the Sigma dashboard:

| File | Grain | Feeds |
|---|---|---|
| `dash_portfolio_overview.sql` | portfolio × month, EUR, sums only | Overview, Performance, Scorecard — the servicer-cost columns were merged in 2026-09-15 |

`dash_servicer_scorecard.sql` is kept as the reference the merge was built
from; it is no longer generated for Sigma.

⚠ `dash_portfolio_diagnostics.sql` **was deleted on 2026-09-17.** The business
does not trust the legal/amicable split it existed to carry — the phase codes
come from `GROUP_CASE_PHASE` and Intrum has never sent a dictionary for them.
Its useful half, the loan-level **payer counts**, moved into
`prod/dash_portfolio_overview.sql`, which is now the **only** Sigma dataset and
reads no RAW table at all. The phase split, secured and debt-age mix went with
it; ask for them back only with a dictionary from Intrum in hand.

The other 28 are the base layer, the aggregates, three check suites and the
analysis files the notebook runs. **Most are not dbt models** — about four
earn a materialised table, three are test suites, and the rest are views,
dimension wrappers or one-off analysis. `DBT-HANDOFF.md` Part A has the
file-by-file verdict.

## Paths changed

`datalake.q()` and `mise run sql` now need the subfolder:

```
datalake.q("servicing/prod/dash_portfolio_overview")
mise run sql -- work/servicing/prod/dash_portfolio_overview.sql
```

Every reference in the notebook, the docs and the agents was repointed at the
same time.

## Conventions

- Snowflake **session variables** (`set x = ...;` / `$x`), never Python braces
- **Nothing may follow the final semicolon**, not even a comment
- Completeness guards are **enforced in the SQL**, not left to the dashboard;
  the boundaries come back as `data_as_at` / `fx_from` / `fx_to` for a banner
- Money and ratios to up to 5 decimals; never `round()` a DataFrame
- A filter that works around a data-quality problem gets a comment naming it
