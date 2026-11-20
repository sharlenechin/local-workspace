# Retired 2026-10-06 — `BUILD-GUIDE.md`

The old guide was written for the **two-dataset** architecture:
`prod/dash_portfolio_overview.sql` and `raw/dash_portfolio_diagnostics.sql`.
Both were retired on 2026-10-02 and replaced by the six `sigma_*.sql` elements.

Measured before retiring it:

- it instructed loading two datasets that no longer exist;
- it named **one** of the six current elements, once;
- every column it placed on a tile — `percent_accounts_paying`,
  `cumulative_collections_eur`, `servicer_forecast_eur`, `snapshot_date`,
  `cumulative_collections_in_servicer_window_eur` — exists in **none** of them.

Anyone following it today builds nothing, so it was replaced rather than patched.

**Kept because** its Sigma mechanics sections (edit mode, pasting custom SQL,
writing calculations, control targeting, drill-down, the look-and-feel notes)
are still accurate and far more detailed than the replacement. Read those here;
read the new `servicing/BUILD-GUIDE.md` for what to build and from what.
