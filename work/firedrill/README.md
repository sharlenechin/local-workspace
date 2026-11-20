# firedrill — which markets can we actually price?

**A market is a country, a loan-holder type and a product type.** This folder
answers one question for each of them: *does the warehouse hold enough to
underwrite it?*

Run it, read the table, and the low numbers tell you which markets are not
ready and why.

```sh
cd ~/data-warehouse/local-workspace
mise run sql -- work/firedrill/market_readiness.sql
```

| File | What it is |
|---|---|
| [`market_readiness.sql`](market_readiness.sql) | the whole dataset — one row per market |
| `README.md` | this |

---

## The answer, before you run anything

**103 markets, 21,854,501 loans, 62 deals.** Measured 2026-10-14.
Every metric ships as a count and a percent.

### Static data is good. Observed payment history is the constraint.

Balance, principal and debt age sit at 95–100% in most markets. History does not:

| Country | Holder | Product | Loans | Deals | 5y history | 10y | Balance | **at the true date** |
|---|---|---|---:|---:|---:|---:|---:|---:|
| FI | — | not stated | 3,020,561 | 9 | **807,272** (26.7%) | 369,887 | 89.6% | **6.8%** |
| SE | — | not stated | 1,328,954 | 3 | 303,085 (22.8%) | 93,691 | 96.6% | 29.8% |
| PL | individual | Trade receivables | 1,100,041 | 2 | 165,694 (15.1%) | 111,272 | 93.8% | **4.8%** |
| CH | individual | not stated | 1,794,081 | 3 | 109,975 (6.1%) | 56,233 | 86.8% | 24.8% |
| ES | individual | Other term loans | 2,874,312 | 10 | 12,322 (0.4%) | 0 | 99.1% | 36.6% |
| ES | individual | Trade receivables | 3,179,254 | 2 | **2,857** (0.1%) | 0 | 99.9% | 25.5% |
| IT | individual | Other term loans | 334,282 | 10 | **0** | 0 | **13.7%** | 96.0% |

**Finland is the deepest pool in the book** — 807,272 loans with five years of
history, 369,887 with ten. **Spain is the largest and the thinnest**: 3.2m loans
on Trade receivables yield 2,857.

**No market anywhere has five years of history on even half its loans.**

### ⚠ Read `balance_at_reg_exact_pct` before quoting any balance

`balance_at_reg_pct` looks strong almost everywhere. The *exact* column says how
often that balance was really read at the registration month — **median 24.1%**.
Poland shows 93.8% balance and **4.8% exact**: the rest are later, lower figures
standing in, because an NPL amortises and the case snapshot only starts
2014-06-30. Italy inverts it — 13.7% have a balance, but 96.0% of those are
genuine.

### Pre-reference history is effectively nil

`before_2y_recon_pct` is 0.00 in every market; the one-year column peaks near
1%. Both populations exist — 2.8m loans have pre-purchase payments, 494,274 sit
in a reconciling portfolio — but barely the same loans. These columns measure
exactly what the warehouse discards at the case-SCD left edge, so read them as a
floor.

### Two markets to know about

- **Italy, Other term loans** — 334,282 loans, **zero** history, 13.7% balance,
  4.0% debt age. That is Cerved, which sends cases and no money.
- **A third of the book has no product**: Finland (3,020,561), Switzerland
  (1,794,081), Sweden (1,328,954), Greece (446,289). Those split by country and
  holder type only.

⚠ `pct_of_all_deals` does **not** add to 100 — one deal spans several countries
and products, so a deal is counted in every market it touches.

---

## Where product type comes from — and how far to trust it

**`NPL_COMMON.DIM_PRODUCT.PRODUCT_EBA_TYPE`.** Already conformed, already in the
warehouse, no raw needed. Four values, the same in every country: Credit card
debt · Other term loans · Trade receivables · On demand [call] and short notice.

**It is a hand-kept mapping, and it never fails.** `DIM_PRODUCT` is built from
the seed `data/npl/npl_product_mappings.csv` — 46 rows keyed on
*(servicer, product code)*: intrum 28, gescobro 17, cerved 1, souq 1,
**massey 0**.

Measured 2026-10-14:

| Servicer | Loans | Carry a product key | Key resolves |
|---|---:|---:|---:|
| Intrum | 19,558,362 | 12,176,046 | **12,176,046** |
| Gescobro | 1,795,692 | 1,795,677 | 1,795,677 |
| Cerved | 394,205 | 394,205 | 394,205 |
| Souq | 57,781 | 57,781 | 57,781 |
| Massey | 48,784 | **0** | 0 |

**Every key that exists resolves.** So `not stated` always means *the servicer
sent no product code* — never a failed lookup. Intrum sends one on 62.25% of
loans; Massey sends none and is absent from the seed, which is a feed gap, not a
modelling bug.

**A loan's product key** is `FCT_CASE_SNAPSHOT_DAILY.PRODUCT_SK` — `DIM_CASE`
has none.

⚠ **Do not use `ORIGINAL_PRODUCT_NAME`.** It is the seller's own untranslated
words — `PRESTAMOS PIDE`, `TARJETAS DE CREDITO - RESTO`, bare codes like `110` —
47 values that do not line up across countries.

## What each column means

| Column | Plain English |
|---|---|
| `loans` | how many loans are in this market |
| `pct_2y_history_reconciled` | share with **two years of payment history before we owned them**, in a portfolio whose numbers agree with the servicer's |
| `pct_1y_history_reconciled` | same, but one year |
| `pct_balance_available` | share with a balance we can actually read |
| `pct_principal_available` | share with a principal we can actually read |
| `pct_debt_age_available` | share with a default date, so we can tell how stale the debt was |

### "Reconciled" means two tests, both passed

Per portfolio, per currency:

1. **Months** — the loan-level feed covers at least **80%** of the months the
   servicer reported collections in.
2. **Money** — the two totals are within **10%** of each other.

Measured 2026-10-14: **34 of 251** portfolio-currency pairs pass both. **82 have
no loan-level feed at all** — Gescobro, Cerved and Souq send us loans and no
money, so nothing about them can reconcile.

### "Before we owned them" is measured from different dates

- **Intrum books** → from the date **Intrum** bought the batch
  (`DIM_BATCH.LEGACY_CAPEX_DATE`). Intrum collected for years before we bought,
  so measuring from our date would throw that history away.
- **Everything else** → from the loan's own `REGISTRATION_DATE`. There is no
  prior owner to account for.

---

## ⚠ Three things that will mislead you

**1 · The history numbers are a floor, not a count.** The warehouse drops every
payment made before our first data file for that loan — an inner join on the
case history, worth **42–58%** of collections on the Portuguese books. That is
exactly the history these two columns measure. A low figure may mean the data
was discarded, not that the borrower never paid. Read them as *"at least this
much"*.

**2 · Three of five servicers send no loan-level money.** Gescobro (1,795,692
loans), Cerved (394,205) and Souq (57,781) deliver cases and zero payments.
Their markets will show 0% on both history columns, and that is a feed gap, not
borrower behaviour. Their collections exist only as portfolio totals.

**3 · A loan can be both an individual and a company.** The flags come from the
borrowers on the loan, and a loan can have several. Both flags true is normal —
a company and a person on one agreement. Do not read it as a data error, and do
not treat the two flags as one field.

---

## The warehouse rules this query follows

Everything below was measured, not assumed. Breaking any of them changes the
numbers silently.

| Rule | Why |
|---|---|
| **Count `CASE_ID`, never `CASE_SK`** | `CASE_ID` is the loan; `CASE_SK` is one version of it. 20.2m loans are 154m versions. |
| **`DIM_CASE` needs `IS_CURRENT_FLAG`** | It is a slowly-changing table. Without the filter every loan is counted once per historical version. |
| **Never add money across currencies** | `FCT_CASE_COLLECTION` carries a currency and no converted amount. That is why the reconciliation works inside one currency. |
| **`FCT_CASE_SNAPSHOT_DAILY` is month-end** | Despite the name. One month holds the whole book — 21,854,824 loans at 2026-09-30 — so this reads one month, not 1.47bn rows. |
| **A loan cannot reach its batch directly** | `DIM_CASE` has no batch key. Go through a fact. |
| **`SERVICER_NAME` is a hardcoded label** | On `DIM_REPORTING_SYSTEM` it is a constant typed into each source model. It tells you which **feed** delivered the row, not who was contracted. |
| **The portfolio feed has no servicer key** | `REPORTING_SYSTEM_SK` is 100% NULL there. Route through deal and country instead. |
| **Some collection dates are impossible** | 98 loans, 841 payments dated in the future — 2099, 2112, one in **4570**. Bound the date or they land in every total. |
