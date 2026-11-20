# Building the Servicing Dashboard in Sigma

> **Draft.** The layout to keep is the one already live — see
> [`LIVE-WORKBOOK.md`](LIVE-WORKBOOK.md). This file currently covers only the
> **data**: which element supplies which figure, and the traps that produce a
> wrong tile. The tile-by-tile build steps will be refined against the live
> workbook rather than invented here.

The previous guide was written for two datasets retired on 2026-10-02 and is
archived in `../.archive/2026-10-06-servicing-build-guide/`. Its **Sigma
mechanics** sections — edit mode, pasting custom SQL, writing calculations,
targeting controls, drill-down, look and feel — are still accurate and far more
detailed than anything here. Read those there.

---

## The format to keep

The live dashboard is **one Custom SQL table element** (`ROIia0oTOr`,
"Portfolios"), and every KPI card, chart and the Breakdown pivot reads from it.
That shape works and is what we are keeping.

What changes is what sits behind it: that single element's SQL is
version-controlled nowhere and has drifted past the file it came from. The six
`sigma_*.sql` files here replace it with a reviewable chain.

---

## The six elements, and the order to paste them

Four read each other, so order matters. Verified end to end against PROD on
**2026-10-06** — each was executed and its rows counted.

| # | Element | Reads | Rows |
|---|---|---|---|
| 1 | **Portfolio Information** | PROD only | 264 |
| 2 | **FX Table** | PROD only | 1,411 |
| 3 | **Portfolio Metrics** | 1 + 2 + PROD | 1,839 |
| 4 | **Forecasts** | 1 + 2 + PROD | 2,104 |
| 5 | **Case Metrics** | the dbt mart | 1,296 |
| 6 | **Reconciliation** | 1 + 2 + 3 + 5 + PROD | 1,839 |

Measured end to end against the live mart on 2026-10-07: 4.3s, 0.3s, 2.5s,
3.1s, 0.5s and 6.8s respectively. The whole page refreshes in under 20 seconds.

Name each element **exactly** as spelled above. `sigma_element()` looks the name
up verbatim, so "FX table" breaks the three elements that depend on it.

**Columns are renamed leaving an element** — Title Case with spaces, and
case-sensitive, so they resolve only inside double quotes: `portfolio_sk`
becomes `"Portfolio Sk"`. The original name gives `invalid identifier`, and the
line number in that error counts Sigma's expanded SQL, not the file.

**All six run.** The mart went live on 2026-10-07; verified the same day that
the table dbt built matches the model exactly — all 19 columns, all 1,296 rows.

---

## Which element answers what

| You want | Element | Column |
|---|---|---|
| Any euro money total | Portfolio Metrics | `collections_sum`, `net_collections_sum`, `balance_sum`, `carrying_sum` |
| Servicer cost | Portfolio Metrics | `servicer_commission_sum`, `servicer_mgmt_fee_sum`, `servicer_passthrough_sum`, `servicer_cost_total_sum` |
| Forecast | Forecasts | `servicer_forecast_sum`, `accounting_forecast_sum`, `underwriting_forecast_sum` |
| Drill path | Portfolio Information | `vehicle`, `project`, `deal`, `servicer`, `seller`, `region`, `country_name` |
| Cases collecting, and how | Case Metrics | `collected_cases_count` and the six transition counts |
| Collection by behaviour | Case Metrics | the seven `collected_amount_local_*` columns |
| Book penetration | Case Metrics | `cases_on_book_count`, `cases_ever_collected_count`, `cases_never_collected_count` |
| Does the feed agree | Reconciliation | `is_reconciled_flag`, `absolute_difference_pct`, `case_month_coverage_pct` |

---

## Six things that will otherwise produce a wrong tile

1. **Never average a ratio.** `Sum(a) / Sum(b)`, never `Avg(a/b)`.
2. **Divide a rolling average by months present, not by the window length.**
   The live dashboard divides by 3; 26.5% of portfolio-months have fewer than
   three months, understated by up to 3x.
3. **Case Metrics amounts are local currency**, not euro, and a portfolio-month
   can hold two currencies. Euro money comes from Portfolio Metrics.
4. **`collected_amount_local_sum` can be negative** — one portfolio-month is
   -896,873.55, net of reversals. That is the data, not a fault.
5. **Do not chart `three_consecutive` + `jitter_in` + `new` as a breakdown of
   `collected_cases_count`.** They do not cover everyone: a case in its second
   consecutive collecting month matches none, 377,028 case-months.
   `first_collection` also overlaps `new` entirely — never add those two.
6. **`jitter_out` and `lost` amounts are a different month's money** — what
   those cases collected in their *last* month, because the month they are
   reported in has no collection by definition.

The three book counts are **as at each month**, so they trend — but within one
month they repeat on every row, so aggregate with `Max`, never `Sum`.

---

## Multiply before you sum

FX gives `rate_flow` (monthly average — for things happening *during* a month:
collections, forecasts, commission) and `rate_stock` (month-end — for things
measured *at* a point: balance, carrying value). Make the calculated column
`[amount_local] * [rate]` and aggregate **that**. Summing locals first applies
one currency's rate to a mixed total. The two rates differ by 0.87% on average
for SEK and up to 1.70% in a month, so the wrong one is wrong, not approximate.

`reporting_month` is **month-end** in all six elements. They must agree or the
joins match nothing, silently and with no error.

---

## Expect reconciliation to look bad

```
is_reconciled_flag   True 466    False 1,373     (25% reconcile)
coverage             median 88.89%
absolute difference  median 46.68%   within 10%: 524 of 1,575
```

Coverage passes comfortably; the money test is what fails. The case feed is
roughly half what the servicer reports, because `FCT_CASE_COLLECTION` is cut
per-case by a join upstream. That is a warehouse problem, not a dashboard one —
put the sentence on the page so nobody reads red as a dashboard fault.
