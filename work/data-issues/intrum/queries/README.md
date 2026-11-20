# The queries behind the findings

Run with `mise run sql -- work/data-issues/intrum/queries/<file>.sql` from the
workspace root, or `datalake.q("data-issues/intrum/queries/<file>")`.

| File | Answers |
|---|---|
| `phase_code_custom_labels.sql` | Where the feed's own `CUSTOM_CODE` carries a free-text label for a phase code — the only **solid** evidence in `phase-codes.md` |
| `phase_code_sequence.sql` | Where a code sits in a case's life: first spell, latest spell, what precedes it — the **inferred** evidence |
| `status_vs_phase.sql` | Whether the decoded case status agrees with the servicer's phase. It does not: 5.4% agreement overall, **0% on Portugal** |
| `l005_vs_insolvency.sql` | Whether phase `L005` ("Insolvency" per one instance's label) lines up with the two insolvency sources we already have |
| `raw_vs_dim_case_coverage.sql` | How many raw CAT cases never reach `DIM_CASE`, by instance |
| `pam_vs_cat_by_portfolio.sql` | Where the two feeds start and stop, per portfolio |
| `case_vs_portfolio_collections.sql` | Like-for-like collections: only portfolio-months present on **both** sides, same currency. Coverage is reported separately rather than mixed into the ratio |
| `dash_phase_collections.sql` | The amicable / legal collections split itself — ⚠ **retired from the dashboard 2026-09-17**, kept as the prototype should a dictionary ever arrive. One pass over a 346m-row RAW feed |
