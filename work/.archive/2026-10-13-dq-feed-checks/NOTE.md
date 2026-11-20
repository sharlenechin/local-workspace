# Retired 2026-10-13: servicer_feed_checks.sql

The first query behind the Data Quality design canvas: one row per combined ref x month,
with a 12-month window (`SET months`) and portfolio totals repeated on every ref row.

Replaced by the two Sigma element queries in `work/data-quality/sigma_queries/`, which are
simpler to read (one grain each), scoped to DIM_PORTFOLIO from Jun 2014 (the manager), take
the servicer per combined ref, and use the Servicing dashboard's reconciled rule.

The canvas data file `work/data-quality/design/data/servicer_dq_2026-10-13.json` was built
from this query; the canvas is the reviewed design, the Sigma workbook is now the dashboard.
