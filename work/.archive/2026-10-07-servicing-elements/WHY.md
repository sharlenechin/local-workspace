# Retired 2026-10-07 — absorbed into `sigma_servicing.sql`

`sigma_case_metrics.sql` and `sigma_reconciliation.sql` were separate elements.
Both are portfolio x month, as are Portfolio Metrics and Forecasts, so a tile
had to join four elements to answer one question — and two cards reading
different elements could disagree.

`Servicing` now carries all four, in EUR. Verified 2026-10-07: 1,839 rows,
51 columns, 16.8s, no local-currency column leaving the element.

Two things changed in the move, both deliberate:

- **Everything is EUR.** The mart's amounts are local currency with no currency
  column. Converting at the portfolio's own currency would be wrong on the 1.6%
  of months holding two currencies — which carry **35.67% of gross value**. The
  case total is converted per currency from the fact; the behaviour splits use
  that month's realised effective rate.
- **`is_reconciled_flag` has three states.** NULL now means *not comparable* —
  no case row for that month — where before it collapsed into `false`.
