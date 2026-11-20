# Moved out of `work/benchmark/` on 2026-10-02

This is the **Project Elsa investigation trail** — 18 `.sql` files and 2 CSV
exports from 2026-09-09 to 2026-09-11. It was living inside `work/benchmark/`,
where it read as working material. It is not: it is the audit trail behind a
finished book.

**Everything reusable has been lifted out already:**

| Went to | What |
|---|---|
| `work/benchmark/templates/` | the reusable *shape* of each query — 00 … 07 |
| `work/benchmark/GUARDS.md` | the measurement rules these files established, as one list |
| `work/project-elsa-benchmark/FINDINGS.md` | every figure and every escalation |

**Open a file here only when you want the working, not the answer** — to re-run
a measurement, to check how a figure was derived, or to see a hypothesis being
tested and killed. `README.md` beside this note says what each file was for.

⚠ **`accounts.csv` and `payments.csv` here are an OLD SCHEMA**, not copies of
the Elsa exports. 120,713 rows against the shipped 120,543, and different
columns (`DEFAULT_DATE_IS_SUSPECT`, `DERIVED_DEFAULT_DATE`,
`REMAINING_CAPITAL_NOW`, `CASE_BK`). They predate the exclusions. Never quote
them.

⚠ **Figures in these headers are as at 2026-09-10.** Where one disagrees with
`FINDINGS.md`, `FINDINGS.md` is the corrected version.

⚠ **Some of these are expensive.** Anything touching `TRANSACTIONS` without an
instance pin occupies the shared X-Small warehouse for minutes.
