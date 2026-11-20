# Asset index — what it is, what to trust, and what to build next

**For:** anyone who needs to use this data without having dug through it.
**Measured:** 2026-09-21 and 2026-09-22, live against brocc-sandbox.
**Status:** exploratory. Nothing here is in production, and the asset index is
not a modelled warehouse source — it is a dlt load of spreadsheets sellers gave
us at diligence.

---

## 1. The one-paragraph version

We have two records of what a loan paid. The **asset index** is what the seller
handed us before we bought the book. **NPL_COMMON** is what our servicer reports
now. They use different loan IDs, so a bridge table translates between them.
That bridge reaches **4 of 23 books and 7.55% of all loans**. Where it reaches,
the two sources stitch into one continuous history with no overlap and a small
hole in the middle. The asset index is the only source of pre-acquisition
payments; NPL_COMMON is the only source of registration dates. Neither is
complete on its own.

---

## 2. What is actually in there

`DEV.ASSET_INDEX`, reachable only with the `dev` profile (brocc-sandbox).

| Table | Rows | What it is |
|---|---|---|
| `PORTFOLIO` | 23 | one row per book: seller, country, currency, deal type |
| `CASES` | 278,932 | one row per loan: balances, dates, legal status |
| `PAYMENTS` | 2,156,237 | the seller's payment history |
| `CASE_BRIDGE` | 33,330 | the translation table to our loan IDs |
| `COUNTERPARTIES` | 243,624 | the borrowers — **this is where insolvency lives** |
| `RELATIONSHIP` | 284,555 | which borrower belongs to which loan |
| `COLLATERAL` | 4,037 | security. **Zero rows for the four bridged books.** |

---

## 3. How much of it we can actually use

This is the single most important number in the document.

| | Cases | |
|---|---|---|
| Asset index total | 278,929 | 23 books |
| Have a bridge row | 33,330 | only 4 books are bridged at all |
| Resolve to one of our loans | **21,066** | the rest carry no system code |
| Distinct loans after collapsing | **20,456** | **7.55% of the asset index** |

Two separate losses. **19 of 23 books have no bridge whatsoever** — 245,599
loans that cannot be tied to anything of ours by this route. And inside the four
that are bridged, 12,264 rows carry a NULL `system_code`, so the ID they would
build is NULL and matches nothing.

| Book | Seller | Currency | Cases | Matched |
|---|---|---|---|---|
| DE25020 | Santander Consumer Bank | EUR | 12,685 | 8,903 (70.2%) |
| SE25008 | Santander Consumer Bank | SEK | 12,160 | 6,267 (51.5%) |
| CH25007 | Cembra Money Bank AG | CHF | 4,439 | 3,064 (69.0%) |
| ES25021 | Norwegian bank | EUR | 4,046 | 2,832 (70.0%) |

### The match rate overstates the damage — except on SE25008

A case that never paid loses nothing by going unmatched. Separating "never paid"
from "cannot be linked" changes the picture completely (measured 2026-09-22):

| Book | Paying cases | Stranded | % of payers | Cash stranded | % of cash |
|---|---|---|---|---|---|
| ES25021 | 631 | **0** | **0.0%** | — | **0.0%** |
| DE25020 | 4,258 | 1,259 | 29.6% | EUR 2,988,792.20 | 29.6% |
| CH25007 | 1,237 | 401 | 32.4% | CHF 670,862.95 | 33.9% |
| SE25008 | 7,538 | 4,071 | 54.0% | SEK 111,095,023.28 | **74.2%** |

**ES25021 proves the point**: a 70% match rate on cases cost **0%** of the
payment history, because every unmatched case was a non-payer.

⚠⚠ **SE25008 is the outlier and it is serious.** 74% of its pre-acquisition cash
cannot be linked, and the same book has zero post-acquisition collections in our
warehouse. Two independent symptoms of one problem: its bridge is probably
wrong, not merely incomplete.

### There is no way to recover the unmatched ones from this data

Tested 2026-09-22, all four books, and **every route returned zero hits**:

| Route tried | Hits |
|---|---|
| asset-index `case_id` against `DIM_CASE.case_id` | 0 |
| the book's system code + asset-index `case_id` as a business key | 0 |
| `internal_case_id` against `DIM_CASE.case_id` | 0 |

The reason is simple: the unmatched bridge rows carry **no `servicer_case_id`
at all** — the column is NULL on every one of the 12,264. `not_in_mapping` is
literal. There is nothing to build a key from, and the seller's own case id does
not appear anywhere in our warehouse.

**So this cannot be fixed with SQL.** It needs the mapping file extended, from
Intrum or from whoever built `CASE_BRIDGE`. That is a request, not an analysis.

⚠ **The mapping is many-to-one.** 610 asset-index cases share one of our loans
with another case — one loan is claimed by seven. All of them are on DE25020.
Any query that joins our facts through the bridge **must collapse to our loan
key first**, or that loan's money is counted once per claimant.

---

## 4. Pre- and post-acquisition payments: they fit together cleanly

The two sources **do not overlap at all**. Zero loan-months appear in both.
What sits between them is a gap.

| Book | Seller data ends | Our data starts | Gap |
|---|---|---|---|
| CH25007 | 2025-10 | 2026-01 | 2 months |
| DE25020 | 2025-08 | 2026-01 | 4 months |
| ES25021 | 2025-09 | 2026-03 | 5 months |
| SE25008 | 2025-04 | — | **no data at all** |

⚠ **A chart drawn straight across the gap reads as a collapse that did not
happen.** Nobody reported anything in those months.

⚠ **SE25008 has 6,267 mapped loans and not one collection recorded since we
bought it.** Either the feed has not started or the mapping is wrong for that
book. It is the biggest open question here, and it is worth asking before anyone
concludes Swedish borrowers stopped paying.

**None of the four books has pre-acquisition data in NPL_COMMON** — checked, 0
of 4, not one row before the capex month. So the seller's file is the *only*
source of pre-acquisition payments, and our feed is the only source of
post-acquisition ones. The "prefer the asset index" rule in the dataset has
therefore never had to decide anything; it exists for the day the two overlap.

---

## 5. Which fields to trust

### Trust these

| Field | Source | Why |
|---|---|---|
| `registration_date` | **NPL_COMMON** | 100% populated. The asset index's own column is 100% **empty** on all four books. |
| `currency_id` | either | One currency per book, and the two sources agree exactly. |
| `portfolio_sk` | case snapshot | 92.6% coverage, and no loan maps to two portfolios. |
| payment amounts | both | The only genuinely complete data on both sides. |
| `principal_at_cutoff` | asset index | 100% on three books — **but see the CH25007 hole below.** |

### Treat these with care

**Default dates disagree, sometimes by years.** Both are emitted; neither is
declared correct.

| Book | Agree | Differ | Mean gap |
|---|---|---|---|
| CH25007 | 5 | 3,059 | **1,273 days (~3.5 years)** |
| DE25020 | 5,915 | 2,988 | 120 days |
| ES25021 | 0 | 2,832 | 249 days |
| SE25008 | 0 | 6,267 | 8 days |

SE25008's eight days looks like a convention difference (month-end vs exact
day). CH25007's three and a half years is a different *definition* of default.
**Find out which one the deal was priced on before using either for seasoning.**

**The money column needs a decision, and one book cannot make it.**
Project Elsa dropped interest from its balance because two sellers delivered it
two different ways. Same risk here, with four. So the benchmark uses
`principal_at_cutoff` — capital only.

⚠ **CH25007 has no capital figure at all.** Its `principal_at_cutoff` is empty
on all 4,439 cases. It has only a balance *including* interest (CHF 38.46m) and
a principal at *origination*, which is a different point in time and not a
substitute. **That book cannot be valued from this data.** Ask the seller.

For the record, `legal_balance_at_cutoff` is exactly principal + accrued
interest + other balances — verified to the cent on 12,685 of 12,685 DE25020
cases and 12,160 of 12,160 on SE25008.

### Do not trust these

**`loan_legal_status` means a different thing per seller.** Same column, four
vocabularies: CH uses `1`/`2`, DE uses `none`/`legal_proceedings`, ES uses
`NO`/`None`, SE uses `Yes`/`No`. **Never group across books on it.**

**Insolvency data is real but patchy**, and it lives on `COUNTERPARTIES`, not on
the loan:

| Field | CH25007 | DE25020 | ES25021 | SE25008 |
|---|---|---|---|---|
| `bankruptcy` | — | 100% (all false) | — | 100% (1 true) |
| `debt_restructuring` | — | — | — | 100% (**1,568 true**) |
| `forbearance` | — | — | — | 100% (36 true) |
| `deceased` | — | — | — | 100% (24 true) |

⚠ **NPL_COMMON cannot help here.** `STATUS_DESCRIPTION`, `CLOSING_CODE`,
`CLOSING_DESCRIPTION` and `CLOSING_CATEGORY` are **100% NULL across all 22.5
million rows**. Legal, amicable and insolvency *stage* cannot be reported from
our warehouse at all. Only a bare numeric `status_code` survives, undecoded.

### Empty everywhere — the column exists, nothing is in it

`registration_date` (asset index's own), `registration_balance`,
`purchase_price`, `status`, `days_in_past_due`, `stage_of_legal_proceedings`,
`legal_restricted`, `pricing_reference_basis`, `last_payment_amount`,
`beginning`/`end_payment_history_date`, `insolvency_restructuring`,
`bankruptcy_date`, `insolvency_proceeding_name`,
`status_of_legal_proceedings`, `enforcement_outcome`.

---

## 6. Two practical blockers

**FX is not available in the sandbox.** Rates live in
`PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY`, and the share into brocc-sandbox covers
only the `NPL_COMMON` schema. Three books in three currencies and no way to
convert them here. Best fix: **ask the data team to add `PROD.COMMON` to the
share.** Otherwise convert outside, in a notebook against PROD.

**`mise run sql` does not work on any of these files.** `mise.toml` pins the
prod connection, and mise's environment beats anything you export, so the query
goes to brocc-prod where none of these tables exist. Use:

```sh
uv run python scripts/run_sql.py <file> --connection dev
```

---

## 7. Should we build a platinum layer for this? — Yes, and here is the case

**The problem.** Every query in this folder rebuilds the same three things:
the ID translation, the collapse to one row per loan, and the loan-to-portfolio
lookup. That last one costs a scan of a **1.47 billion row** table each time.
Six queries, six copies of a correctness rule that is easy to get wrong — I got
it wrong once while writing them, and the fix was a silent doubling of money.

**What the model should carry.** One row per loan, all the keys resolved:

| Column | Why |
|---|---|
| `case_sk` | our loan key — the grain |
| `case_bk` | our business key |
| `portfolio_sk`, `portfolio_bk` | resolved **per loan**, not per book |
| `capex_date` | follows `portfolio_sk` |
| `asset_index_portfolio_id`, `asset_index_case_id` | the seller's keys |
| `servicer`, `system_code` | which servicer system the loan sits in |
| `asset_index_case_count` | **above 1 means several seller cases are one loan** |
| `match_status` | whether the bridge reached it |

Then every downstream query is one join instead of four, and the many-to-one
collapse is done once, in a model with a test on it, rather than by hand.

**Three honest caveats before anyone commits.**

1. **This is a `brocc-data` change, not something to do here.** New warehouse
   models belong in the dbt project, under the data team's conventions and
   review. This document is the case for opening that conversation, not a
   substitute for it.
2. **A dimension that covers 7.55% of its source needs to say so on the tin.**
   Coverage will rise as more books are bridged, but a consumer who assumes it
   is complete will quietly lose 19 books.
3. **The asset index is not a production source yet.** It lives in `DEV`, and
   `CASE_BRIDGE` is built by an engineer's own process (it carries a `built_at`
   and a `match_status`). Modelling on top of something that may be rebuilt is a
   decision to make deliberately.

**What I would ask for, in order:**

1. `PROD.COMMON` added to the sandbox share, so FX works. Small, unblocks a lot.
2. An answer on **SE25008** — 6,267 mapped loans, zero collections.
3. A decision on **which default date** the deals were priced on.
4. `principal_at_cutoff` for **CH25007** from the seller.
5. Then, if the asset index is staying, the platinum dimension above.

---

## 8. The files here

| File | Grain | Use it for |
|---|---|---|
| `benchmark_case_accounts.sql` | one loan | the static picture: balances, dates, borrower, flags |
| `benchmark_case_payments_monthly.sql` | one loan-month | the continuous payment history, labelled by source |
| `bridge_overlap_by_portfolio.sql` | one book | how each book connects, and whether the sources have started to overlap |
| `ref_case_bridge.sql` | one seller case | the raw mapping with its gaps visible |
| `case_preacquisition_payments.sql` | one payment | the seller's history at full detail |
| `case_payment_history.sql` | one payment | both sources unioned, unaggregated |

The two `benchmark_*` files are the pair. They share a key, and the population
check holds: **every loan in payments exists in accounts.** 12,181 loans
(59.5%) appear in accounts with no payment at all — that is the never-paid
population, not a gap.
