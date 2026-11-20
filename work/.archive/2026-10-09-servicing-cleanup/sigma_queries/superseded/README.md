# Superseded — these do NOT run

An earlier intended rebuild of the Servicing dashboard as six chained Sigma
elements. **None of it is live.** The dashboard runs one Custom SQL element,
`../live/portfolios_element.sql`, and every tile reads that.

Splitting the work across chained elements was measured and is **slower**:
10.8s cold against 4.6s for the single query, because each element re-runs its
parent rather than reusing a materialised result.

Kept for the derivations, which are still correct and still readable — the FX
month-key handling in `fx_table.sql` especially. Never quote a figure from
these files as something the dashboard shows.
