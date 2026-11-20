# Servicing dashboard — the one model dbt has to build

**The six Sigma elements moved out on 2026-10-02** to
[`work/servicing/`](../../../../servicing/), which is now the single home for
the dashboard's SQL. What is left here is what **dbt** builds:
[`dbt/`](dbt/) — one model, one table. Its README says where the model goes in
`brocc-data` and what to check before a PR.

## The rule

**Sigma does everything it can.** Portfolio-grain facts are 6,839
portfolio-months and a few thousand rows more — re-running them on each refresh
costs nothing, and nothing pre-built can drift from them.

**dbt pre-builds only the one thing Sigma cannot.** That is the loan feed: an
inner join onto `FCT_NPL_CASE_COLLECTION` (134,472,689 rows), five window
functions, and a scan of `FCT_CASE_SNAPSHOT_DAILY` (1.47bn rows).

## What changed on 2026-09-30

Three `agg_` models became one.

| Retired | Why |
|---|---|
| `agg_npl_portfolio_monthly` | Portfolio grain, so Sigma can do it — and `sigma_portfolio_metrics` already did, in parallel. Keeping both meant the FX conversion, the dimension joins and the forecast unions were each defined twice, in two languages. |
| `agg_npl_reconciliation_monthly` | 149 lines that **scanned nothing** — pure comparison over two pre-aggregated inputs, at the same grain as the payer model. Merging cost no extra read. |

Both are now inside **`agg_npl_case_payer_monthly`**, which emits payer
behaviour *and* the reconciliation flags at one row per (portfolio, month).

### ⚠ Three things the merge had to get right

**The portfolio side drives.** The old payer model was driven by payers, so a
portfolio with no loan feed produced no row. **110 of 263 portfolios report cash
and never a payer** — 96 have no loan collection at any date, and 14 have some
but all of it before their capex date. Drive this from the payer side again and
those 110 vanish.

**No drill path.** The retired reconciliation model carried
vehicle/project/deal/servicer/country so Sigma could slice without a join.
`sigma_portfolio_information` already holds all of it, one row per portfolio —
join on `PORTFOLIO_SK` rather than pulling five dimension joins into the
expensive model.

**Forecast flags need existence, not amounts.** Which is why they carry no
version guard. The servicer forecast double-counts if *summed*; "is there a row"
is unaffected. If anyone ever wants forecast money here, the newest-version
`QUALIFY` has to come with it.

## The element chain

```
sigma_portfolio_information ──┐        (PROD only, 264 rows)
sigma_fx_table ───────────────┤        (PROD only — DISPLAY conversion, not
                              │         measure-building. Do not delete as
                              ├──> sigma_portfolio_metrics    redundant.)
                              └──> sigma_forecasts

agg_npl_case_payer_monthly ──┬──> sigma_case_metrics      (thin read)
                             └──> sigma_reconciliation    (thin read)
```

⚠ The last two now read the **same table** and can never disagree. They stay
separate elements for the workbook's sake, not because the data differs.

## ⚠ Raised, not merged, not built

The model went to `brocc-data` on 2026-09-30 as
**`mart_npl_servicing_agg_cases_monthly`**, on branch `add/servicing-mart`. It
is **not merged**, and `PROD.INFORMATION_SCHEMA.TABLES` still has no table of
that name (checked 2026-10-02). The two thin-read elements cannot run until the
data team merges it and dbt builds it.

⚠ **The merge into `brocc-data` renamed five columns.** `agg_npl_case_payer_monthly`
here still uses the old `pam_` / `cat_` names; the shipped model uses
`portfolio_` / `case_`, drops `currency_count`, and emits month-**start**
instead of month-end. The Sigma elements in
[`work/servicing/`](../../../../servicing/) follow the shipped model. **Treat
`brocc-data` as the source of truth from here** — the copy in `dbt/` is the
working draft that produced the PR, not the live definition.

## ⚠ The orphan portfolio is excluded

`PORTFOLIO_SK = '-1'` is not in `DIM_NPL_PORTFOLIO` and is bad data from Intrum:
2,071 fact rows over 24 months, 218 batches, **EUR 40,741,423.54** = 0.24159% of
lifetime collections. Removed 2026-09-30 from every model here.

Two consequences worth knowing:

- **The dashboard total drops by EUR 40.7m** against any earlier run. If Finance
  reconciles against `FCT_PORTFOLIO_SNAPSHOT_MONTHLY` directly, the two now
  differ by exactly that.
- **`IS_MULTI_CURRENCY_FLAG` fires on nothing any more**, and that is correct.
  The fact holds 24 multi-currency portfolio-months out of 6,839 and **all 24
  belong to the orphan**. The flag is kept for the next book bought in two
  currencies, not because it marks anything today.
