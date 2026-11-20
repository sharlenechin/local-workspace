# dbt updates — NPL case collections

**For:** the data team · **Measured:** 2026-11-02, revised 2026-11-03, read-only
**Checked against:** PAM, Intrum's own report of what each book collected

Two things in the collections chain, both found while building a valuation dataset.

1. **`int_npl_case_collection_intrum` deletes real payments** — a filter that is correct
   on one Intrum system and destructive on five others. A bug; fix it.
2. **`FCT_CASE_COLLECTION` has a floor on how far back it goes** — not a date filter but
   a side effect of the SCD join. A question, not a bug: should it be extended?

Measured on six Swedish non-performing books Brocc owns. All amounts SEK.

| Deal | Seller | Bought | Cases |
|---|---|---|---|
| SE15044 | Santander Consumer Bank | Dec 2015 | 10,595 |
| SE16025 | Santander Consumer Bank | Dec 2016 | 4,831 |
| SE19026 | Ikano Bank | Dec 2019 | 10,088 |
| SE20009 | Santander Consumer Bank | Jul 2020 | 16,001 |
| SE25018 | Santander Consumer Bank | Jun 2025 | 9,713 |
| SE25037 | Norion Bank | Dec 2025 | 2,341 |

---

## 1. `int_npl_case_collection_intrum` deletes real payments

`models/intermediate/npl_common/conformed/intrum/int_npl_case_collection_intrum.sql:14`

**Current**

```sql
where payment_cost_ind = 'P'
    and coalesce(booking_ind, 'N') != 'Y'
```

**Fixed**

```sql
where payment_cost_ind = 'P'
    and amount is not null
-- booking_ind means the opposite on 1062: every real payment there is 'Y', and every
-- row that is not 'Y' has no amount. Dropping the guard changes nothing on the 14
-- instances where the column is empty. If 'Y' must still exclude rows somewhere, make
-- the rule per instance and name the instance.
```

Why: on instance 1062, `payment_cost_ind = 'P'` splits as

| | rows | of which no amount |
|---|---|---|
| `booking_ind = 'Y'` | 5,910,892 | 0 |
| `booking_ind` null | 1,333,586 | 1,333,586 |

**Impact**

| Layer | Object | What goes wrong | Measured |
|---|---|---|---|
| intermediate | `int_npl_case_collection_intrum` | **origin** — payments filtered out at line 14 | 1062 loses 100% of its cash |
| intermediate | `int_npl_case_collection_conformed` | Intrum branch arrives short | — |
| mart | `fct_npl_case_collection` (`PROD.NPL_COMMON.FCT_CASE_COLLECTION`) | collections understated | SE25018 ships **3,511,619** against PAM's **44,726,096** |
| mart | `mart_npl_servicing_agg_cases_monthly` | inherits it | — |
| BI | Servicing dashboard (Sigma) | reads the above | — |
| Pipeline | asset-index `bridge_scan` (`cli/bridge_scan/queries/collections.sql`) | writes the understated total into every deal's `_meta/bridge.yaml` | `LOK-SE25008` records **3,511,618.92** collected against a real **45,641,660** |

Nothing downstream re-reads raw, so the rows cannot be recovered. Recovery rates suffer
twice over: the cash is cut, the principal is not.

⚠ **The asset-index pipeline reads this table too**, so a deal's `bridge.yaml` reports
the broken figure as if it were the servicer's own. That is not an independent check of
anything — it is the same number quoted twice, and on a 1062-heavy deal it reads as
"the servicer sends almost no payments".

**Proof it is this filter** — SE25018, post-acquisition, four ways
(`queries/mismatch_se25018.sql`):

| | Source | Amount | % of PAM |
|---|---|---|---|
| 1 | dbt model, as it ships today | 3,511,618.92 | **7.9%** |
| 2 | PAM — Intrum's own report | 44,726,096.25 | 100% |
| 3 | our fix | 45,641,660.24 | 102% |
| 4 | control — our rows, dbt's guard put back | 3,511,958.92 | **7.9%** |

Rows 1 and 4 are independent code paths and land 340 kr apart on 3.5m. The guard is the
cause, not a correlate. **SE25018 is missing SEK 41m — 92% of its cash.**

**Beyond Sweden.** No country filter exists, so the guard runs on every Intrum book.
Five instances lose payments. Measured in **money, on our own cases only**
(`queries/booking_ind_money_by_instance.sql`, 2026-11-03):

| Instance | Country | Money deleted | % of that instance's cash | Deals on it, ours |
|---|---|---|---|---|
| 2020 | Poland | 114,345,870,538 | **49.2%** | 185 of 187 |
| 7010 | Greece | 22,310,837,334 | **92.3%** | 3 of 4 |
| 1062 | Sweden | 1,560,779,157 | **100%** | all |
| 4042 | Spain | 1,306,437,774 | **84.3%** | 49 of 50 |
| 7006 | Spain + Greece | 214,050,861 | **40.5%** | 47 of 53 |

**Poland loses half of its collections and Greece loses nine tenths.** Sweden, where this
was found, is the smallest of the five by value.

⚠ Two things about those amounts. They are in **each book's own currency** — PLN, EUR,
SEK — so the column does not add up to anything. And they are **not deduped**: CAT is a
change-history feed, so a payment can appear several times. Both sides of each percentage
inflate equally, so **read the percentage, treat the absolute as an upper bound.**

⚠ By row count these looked far milder — Poland 16.8% rather than 49.2%. The deleted
rows carry more money than the surviving ones, so a row-based reading understates the
damage everywhere except Sweden.

---

## 2. `FCT_CASE_COLLECTION` starts at 2014 — should it go further back?

A question, not a bug. There is no date filter anywhere in the chain; the floor is a
side effect of the SCD join in `int_npl_case_collection_conformed`:

```sql
inner join cases
    on combined.case_dk = cases.case_dk
    and combined.transaction_date >= cases.valid_from
    and (combined.transaction_date < cases.valid_to or cases.valid_to is null)
```

A payment dated before its case became valid is dropped, silently, with nothing in the
code naming a cut-off.

**What's there now** (`queries/collection_date_floor.sql`):

| Source | Earliest | Latest | Rows | Before 2014 |
|---|---|---|---|---|
| `FCT_CASE_COLLECTION` | **2014-06-24** | 4570-07-07 | 63,861,928 | **0** |
| `DIM_CASE.effective_from_date` | 2003-05-12 | 2026-11-02 | 155,231,281 | 10,862 |
| raw CAT payments | 1733-02-01 | 2159-12-11 | 3,274,831,305 | 266,902,575 |

**The cause is Intrum's own platform migration.** The CAT *case* feed begins
**2014-05-23** and holds nothing earlier; the mart's first collection is 2014-06-24, a
month later. A case's `valid_from` cannot predate the feed it is built from, so every
Intrum case is valid from 2014 at the earliest and every older payment fails the join.
Nobody wrote a 2014 filter — there is none to find.

**They are our payments, and they are real.** Of the 266,902,575 pre-2014 payment rows,
**266,863,474 sit on cases we own and carry plausible dates** (1990 or later); only
39,101 — 0.015% — are sentinels like 1733. An earlier version of this note called the
whole 266.9m an upper bound full of junk dates. That was wrong.

⚠ They are raw change-history rows, so the number of distinct payments is lower than the
row count. The point stands: this is our own cash, dated, excluded by a join condition.

⚠ The floor is enforced while the ceiling is not — the mart holds a collection dated
**year 4570**.

**Our view on extending it.** For valuation we do not want this cash: anything before we
bought a book is the seller's, not ours, and including it would overstate lifetime
recovery. On SE15044, 57% of the payment history belongs to Santander rather than Brocc.
So the floor is not hurting us today.

But the cut is not deliberate, and that is the problem. A payment vanishes because of a
join condition, with no filter saying so and no test catching it. Two ways to settle it:

- **If pre-acquisition history should be excluded**, exclude it explicitly, on the
  acquisition date, rather than relying on when the feed happened to start.
- **If it should not be**, open the earliest version of each case backwards so the first
  `valid_from` is an open lower bound. That is the standard SCD treatment and it is what
  would admit the 266.9m rows.

Either way the behaviour becomes something someone chose. Today it is an accident of
Intrum's 2014 migration date.
