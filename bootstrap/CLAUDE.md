# Working rules for ~/data-warehouse

This file sits at the root of `~/data-warehouse`, so it applies to work in
**either** workspace below, whichever directory the session started in.

There are two workspaces here, with different owners, different rules, and
different consequences for getting it wrong. They sit **side by side**:

```
~/data-warehouse/
├─ brocc-data/         git clone https://github.com/brocc-ab/brocc-data.git
└─ local-workspace/    this workspace
```

Every path in this file is relative to `~/data-warehouse`, this file's own
directory. If `brocc-data/` is missing, say so and offer to clone it — do
not silently skip the reading list in Rule 1, and do not substitute guesses
about the team's conventions.

| | `brocc-data/` | `local-workspace/` |
|---|---|---|
| What it is | The team's dbt/Airflow/dlt monorepo | Personal notebooks and ad-hoc analysis |
| Git | Tracked, CODEOWNERS, CI, PR review | Not tracked |
| Who it affects | Everyone; builds production tables | Only this laptop |
| Governed by | `AGENTS.md` files + `.claude/agents/` written by the data team | This file |

**Before making any change, decide which workspace it belongs to, and say
so.** If the request is ambiguous, ask — do not guess.

---

## Rule 1 — Changing how data is *modelled* → `brocc-data`

Anything that creates or alters a warehouse table belongs in the dbt
project: new models, changed models, new sources, tests, macros, YAML
config, exposures.

**You must read the data team's instructions before writing anything.**
They are not loaded automatically unless Claude Code was started inside
that directory, so read them explicitly, in this order:

1. `brocc-data/AGENTS.md` — monorepo layout, domain context, agent conduct
2. `brocc-data/transformation/dbt/AGENTS.md` — the four model layers
   (staging → intermediate → marts → exports), naming, database structure,
   business abbreviations
3. `brocc-data/transformation/dbt/.claude/agents/dbt-agent.md` — the
   authority on how to write a model: folder structure, `stg_<source>__<entity>s`
   naming, the two-CTE staging pattern, which transformations belong in
   which layer

Then follow them over anything in this file, and over your own instincts.
Their conventions are specific and enforced by CI.

Also true of that repo, and easy to get wrong:

- Finish with `mise :lint` and `mise :format`, run from
  `brocc-data/transformation/dbt`.
  SQLFluff gates CI, and its dbt templater compiles the project — so it
  needs the Snowflake env vars set even though it only lints.
- **Never add Python dependencies to
  `brocc-data/transformation/dbt/pyproject.toml`.**
  It pins an exact `dbt-snowflake` tree; extra packages break dbt builds
  and CI. Notebook dependencies go in `local-workspace/pyproject.toml`.
- Two prerequisites are easy to miss. **Check them, don't assume** — the
  state below was true on 2026-09-09 and will age:
  `brocc-data/transformation/dbt/.venv` must exist (`mise run install`), and
  `brocc-data/transformation/dbt/mise.local.toml` must hold real values
  rather than `CHANGE_ME` for `DBT_SNOWFLAKE_USER` and
  `DBT_SNOWFLAKE_DEV_SCHEMA`. dbt and sqlfluff fail without both. If either
  is missing, say so rather than working around it.
- Prefer the team's own subagents (`dbt-agent` for models,
  `analytics-wizard` for exploration) when the session can reach them.

## Rule 2 — Exploring, analysing, reporting → `local-workspace`

Notebooks, `.sql` query files, charts, exports, one-off investigations.

**Read from `brocc-data` freely; write only here.** Reading that repo is
usually necessary — it is the source of truth for what a model contains and
how a column is derived. But a question asked in this workspace is answered
with changes in this workspace.

Concretely: if answering needs a model changed, do not change the model.
Say that the analysis is blocked on a modelling change, and let the user
decide whether to open that work under Rule 1.

Conventions here:

- Queries longer than a couple of lines go in a `.sql` file — beside the
  notebook if it belongs to that notebook, in `queries/` if shared.
- Use the `broccnb` helper rather than hand-rolling a connection.
- pandas, not polars. This workspace deliberately differs from
  `brocc-data`'s `analytics-wizard` doc; see `local-workspace/README.md`.
- Add packages with `uv add`, from the workspace root.
- **SQL house style**: UPPERCASE keywords and functions, lowercase identifiers,
  a header giving the grain and any measured figure with its date, and comments
  that say *why*. The worked example is
  `local-workspace/work/dbt/models/staging/intrum_cat/stg_intrum_cat__case_phases.sql`.
  It applies to **every** `.sql` file here, not only new ones: convert a file
  when you are already changing it. The one exception is the analyst's own
  query handed over to fix — there, change only what is broken.

## Rule 3 — Never edit `brocc-data` as a side effect

A local analysis task must not leave changes in the tracked repo — no
"while I was there" tidy-ups, no reformatting, no fixing a model you
noticed was odd. Report it instead and let the user choose.

The one exception is an explicit Rule 1 request, which follows Rule 1's
reading list first.

## Rule 4 — Read-only against production

The `NPL_ANALYST` role holds `SELECT` and `USAGE` only. Do not attempt DDL
or DML against Snowflake from a notebook or script in `local-workspace`,
and do not propose granting write access as a fix for an analysis problem.
Tables are created by dbt in `brocc-data`, never from a notebook.

## Rule 5 — Never commit or push

Do not run `git commit`, `git push`, `git merge`, `git rebase`, or open a
pull request — in either workspace, and not when the work is finished and
obviously correct. Do not stage files or create branches on your own
initiative either. The user commits manually and verifies the branch
themselves.

When a change is ready, say what changed and which files it touched, then
stop. If you believe a commit is warranted, say so and let the user decide.

This is narrower than any general permission to commit, and it wins. The
only thing that overrides it is the user explicitly asking for a commit in
that moment.

## Rule 6 — When you find a data-quality problem

Exploration turns these up regularly. Real examples found in this
warehouse: a join key that is 100% NULL on one fact table
(`FCT_PORTFOLIO_SNAPSHOT_MONTHLY.REPORTING_SYSTEM_SK`), collection dates in
the year 4570, and duplicate rows in a grain the model claims to dedupe.

- **Work around it visibly.** If a query needs a guard — a date upper
  bound, a version filter — say so in a comment in the `.sql`, naming what
  the problem is. A silent filter becomes folklore nobody can audit.
- **Never work around it invisibly**, and never hide it by reporting only
  the clean subset.
- **Never "fix" it in a dbt model unasked.** A data-quality bug is a
  conversation with the data team, not a quiet model edit. Report the
  finding; if a model change is the answer, that is a fresh Rule 1 request.
- **Say it in the answer, not just the code.** If a number the user is
  about to rely on is affected, that belongs in the reply.

---

## Explaining findings

**Write for an intern or a product manager who understands data but not this
warehouse.** They know what a table, a join and an average are. They do not
know our models, our servicers, or which of our numbers are safe to quote.

- **Lead with the plain-English answer**, then the evidence. Not the reverse.
- **Keep it short.** A few sentences and one small table beats a page. Cut by
  leaving things out, not by packing them in denser.
- **No jargon without a gloss.** Say "the two 2016 purchases" before
  `PT15018G000000`. Spell out what a ratio divides by. Vintage, grain,
  denominator, semi-join, fan-out and SCD each need a clause explaining them,
  or a plainer word instead.
- **One concrete example beats a table.** "Ten loans owe 21.3m and have paid
  back 77k" lands; a decile reweight does not.
- **Say what is solid and what is shaky, in those words**, so they know which
  parts survive being challenged.
- **Always say where the number came from** — a live query, or an old export,
  and how old. Never let a stale CSV pass as a fresh figure.
- **Do not narrate your method unless asked.** Which CTE you wrote and which
  join you tried first is not the finding.
- Keep the full working underneath for whoever wants it, but never make it
  the answer.

## Precision

Money and ratios are shown to **up to 5 decimal places**. Two is too few:
it hides real differences in rates, ratios and per-unit figures.

Never `round()` a DataFrame to make it look tidy — that discards data.
Control decimals with display formatting (`display.float_format`), which
changes only what is printed. Where exact decimal arithmetic matters, pass
`convert=False` to `broccnb.q()` to keep Snowflake's `Decimal` values
instead of float64.

## When the two workspaces disagree

`brocc-data`'s instructions win for anything inside `brocc-data`. This file
wins inside `local-workspace`. Where a convention differs between them
(pandas vs polars is the live example), that is deliberate, not an error to
reconcile — note it and move on.
