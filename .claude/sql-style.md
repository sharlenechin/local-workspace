# SQL house style — the long version

**Shared by every agent in this workspace.** It used to be copied into five of
them, 115 lines each; it lives here once so it cannot drift. `~/CLAUDE.md` has
the short version and is the authority where the two disagree.

Read this before creating a `.sql` file from scratch. The three rules that
matter most are repeated in each agent, so skipping the read is survivable —
but only those three.

### ⚠ THE USER'S SQL IS THE USER'S. DO NOT RESTYLE IT.

When the analyst hands you a query to fix, extend or debug, change **only what
is wrong**. Keep their CTE names, their aliases, their keyword casing, their
indentation, their column order. A diff that also reformats is a diff nobody
can review -- the real fix disappears into the noise, and it reads as a
correction to their judgement when it is only a difference of taste.

- Keep `CAT` / `PAM` as `CAT` / `PAM`. Do not "normalise" to `cat` / `pam`.
- Keep `SELECT` / `FROM` / `WHERE` uppercase if that is how they wrote it.
- If you must add a CTE, name it the way THEY name things, not the way this
  workspace's files happen to be named.
- State each fix in a comment on the line you changed, so the diff is legible.

**House style applies to files YOU create from scratch.** It does NOT apply to
the analyst's own work, and it is never a reason to rewrite a working query.
The worked example is
`work/benchmark-dataset/post-registration-benchmark/templates/01_accounts.sql`
(⚠ `CLAUDE.md` names `work/dbt/models/staging/intrum_cat/stg_intrum_cat__case_phases.sql`
as the worked example, but that file does not exist in this workspace)
-- read it before writing a new file.

- **Keywords and built-in functions UPPERCASE, identifiers lowercase.**
  `SELECT`, `FROM`, `WITH`, `AS`, `LEFT JOIN`, `COALESCE`, `SUM`. Table and
  column names stay as the warehouse spells them.
- **Open with a header** saying what the file is, its grain in one line, and
  what it answers that the obvious alternative cannot. `--` for a short one,
  `/* */` once it runs to paragraphs.
- **Put measured numbers in the header with the date they were measured**
  (`346m rows`, `measured 2026-09-16`), so a stale figure is visible as stale.
- **Mark caveats with the warning sign**, on their own line, in the header or
  directly above the clause they govern.
- **Comment the WHY above a column or clause, never the what.** A guard, a
  sign flip, a source quirk, a filter that exists because the data is wrong --
  each earns a line. `SUM(amount) AS collected` does not.
- **Date parts in `DATE_TRUNC` / `DATEADD` / `DATEDIFF` are UPPERCASE**:
  `DATE_TRUNC('MONTH', d)`, `DATEADD('MONTH', -2, d)`. They are keywords, not
  data, and lower-case ones hide among the column names.
- **Spell names out; no abbreviations in an alias.** `month_index`, not
  `month_ix`. A reader should not have to guess, and Sigma shows the name.
- **`UNION ALL` sits alone on its own line, with a blank line either side**
  when the branches are multi-line SELECTs, so the seam between them is
  visible at a glance. A short literal list may keep it tight.
- **Align the `AS` aliases into a column** within a select list, so the names
  read as a list. Realign the block when the longest expression changes.
- **`ON` goes on its own line, one indent deeper than its `JOIN`, and every
  extra `AND` lines up under it.** Never trail a join condition off the JOIN
  line, and never right-align the `AND`s to the `ON`.
  ```sql
  LEFT JOIN servicer_forecast AS sf
      ON sf.portfolio_sk = a.portfolio_sk
      AND sf.period_end_date = a.period_end_date
      AND sf.currency_id = a.currency_id
  ```
  Reading down the left edge then tells you what is joined; reading the indent
  tells you on what. Adding a key is one new line at a fixed indent, so it does
  not reflow the block the way right-aligned conditions do.
- **Always alias a table with an explicit `AS`.** `FROM cases AS c`,
  `LEFT JOIN dim_portfolio AS d`, never `FROM cases c`. The bare form reads as
  a typo when a column list wraps, and `AS` makes the alias greppable.
- **Anti-joins are a LEFT JOIN with `IS NULL` on the RIGHT side, never
  `NOT IN (SELECT ...)`.** `NOT IN` returns NO ROWS AT ALL if the subquery
  yields a single NULL, which is a silent wrong answer rather than an error.
  ```sql
  FROM facts AS f
  LEFT JOIN dims AS d
      ON d.id = f.id
  WHERE d.id IS NULL          -- RIGHT side. Testing f.id here matches nothing.
  ```
  ⚠ Test the column from the JOINED table. Putting the `IS NULL` on the driving
  table is the classic inversion and it silently returns an empty set.
  ⚠ THIS IS ABOUT `NOT IN` ONLY. A plain `IN (SELECT ...)` SEMI-join is fine and
  often better -- it cannot fan out where an inner join can. Do not rewrite one.
- **One column per line in every SELECT list.** Never pack two onto a line,
  even short keys: `portfolio_sk, case_id, currency_id` is three lines, not one.
  `SELECT` sits alone on its own line and the first column starts below it.
  The point is diffs and scanning -- a renamed or dropped column should be one
  changed line, and a reader should be able to run an eye down the list.
  This applies to every SELECT in the file, CTEs and subqueries included.
- **Group a long select list** with section comments: `-- ids`, `-- dates`,
  `-- amounts`, `-- booleans`, `-- metadata`.
- **End on the last CTE** -- `SELECT * FROM renamed`, not a re-listing of every
  column.
- Four-space indent, trailing commas.

**This is the workspace's style, not a rule for new files only.** When you are
already making substantive changes to a `.sql` file here, convert it as you go:
a file half in one style and half in another is worse than either. The older
files in `work/` were written with lowercase keywords before this was
settled, and they get converted as they are touched.

The one thing never restyled is **the analyst's own query**, handed to you to
fix or extend. That rule is above and it still wins.

Optimise for the reader first; on this warehouse the two usually agree.

- **A CTE must earn its name.** If a dimension is needed once, for one label,
  LEFT join it in the final `select`. A CTE per dimension turns a query into a
  table of contents you have to read twice.
- **But never nest to avoid one.** A subquery inside a subquery inside a join is
  where bugs hide and where a reviewer stops reading. Once you are two levels
  deep, or the same derived set is needed twice, promote it to a named CTE.
- **The test:** can you describe each CTE's job in one line? If it needs a
  paragraph, split it. If two CTEs share a one-line description, merge them.
- **Name CTEs for what they hold** — `payments`, `priceable_loans`,
  `complete_months` — never for their position (`step2`, `tmp`, `cte1`).
- **One pass over a big fact beats two.** Joining the scope *inside* the CTE that
  already reads the fact prunes and attaches in the same scan. Snowflake does not
  promise to materialise a CTE, so referencing the same fact again later is a
  second read of it.
- **LEFT join every dimension anyway.** That is a correctness rule here, not a
  style one — orphan and sentinel keys are real, and an inner join drops the
  money with no error.
