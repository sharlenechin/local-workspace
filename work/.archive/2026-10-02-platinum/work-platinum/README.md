# `work/platinum/` — the platinum layer queries

Four queries that sit on the golden NPL marts and produce the shapes analysis
actually wants: one row per portfolio-month, per case-month, per forecast.

| File | One row per |
|---|---|
| `dim_portfolio_case.sql` | case, with the portfolio drill path resolved |
| `agg_case_collection_monthly.sql` | case × month |
| `agg_portfolio_collection_monthly.sql` | portfolio × month × currency |
| `agg_portfolio_forecast_monthly.sql` | portfolio × month × currency, all three forecasts |

⚠ **The three forecasts answer different questions** and must never be averaged
or swapped: **underwriting** is what we assumed when we bought (frozen),
**accounting** is our current view and the one Finance tracks, **servicer** is
Intrum's own projection. Accounting is born as a copy of underwriting — 91.3% of
portfolio-months are still identical, and where they differ *we* marked the
book. The header of `agg_portfolio_forecast_monthly.sql` has the rest.

## ⚠ Two extracts here have no stored query

| File | What it is |
|---|---|
| `2026-08-forecast-variance-by-deal.csv` | August 2026 actual against all three forecasts, 62 deals |
| `2026-08-forecast-variance-by-project.csv` | the same, rolled to 5 projects |

**Exported 2026-09-21. The SQL that made them was not kept**, so they cannot be
re-run or refreshed as written. Treat them as a **dated snapshot, not a current
figure** — if a number from either is going into anything, say it came from a
September export and re-derive it from
`agg_portfolio_forecast_monthly.sql` first.

Their columns are `ACTUAL`, `SERVICER`, `ACCOUNTING`, `UNDERWRITING`, plus
`SERV_vs_ACC` and `ACC_vs_UW` — differences, not ratios, and EUR throughout.
