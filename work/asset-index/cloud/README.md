# asset-index — pre-acquisition payments, and how to tie them to CAT

The **asset index** (`DEV.ASSET_INDEX`) is the loan-level data the *seller* gave
us at diligence: balances at cutoff, at default, at origination, and the payment
history before we owned the book. **CAT** is what the loan has paid *since*.
Joining the two gives one continuous history per loan.

Everything here reads **brocc-sandbox**, not production.

## Running these

`mise run sql` will **not** work. `mise.toml` pins `SNOWFLAKE_CONNECTION = "prod"`
and `SNOWFLAKE_WAREHOUSE = "NPL_ANALYST_WH"` in its `[env]` block, and mise's env
beats anything you export — so the query goes to brocc-prod, where none of these
tables exist. Run it directly instead:

```sh
cd ~/data-warehouse/local-workspace
uv run python scripts/run_sql.py work/asset-index/ref_case_bridge.sql --connection dev
```

⚠ `datalake.connect()` caches a connection per profile. If a `dev` call has
already failed once in the same process, every later call fails too with
`Object does not exist, or operation cannot be performed` — even
`select current_role()`. Start a fresh process, or call `datalake.close_all()`.

The `dev` profile is brocc-sandbox / `DEVELOPER` / `DEV_WH` / `DEV`. **In that
account CAT is the share `PROD_NPL_COMMON`, not `PROD`** — so it is
`PROD_NPL_COMMON.NPL_COMMON.DIM_CASE`, never `PROD.NPL_COMMON.DIM_CASE`.

## The three files

| File | Grain | What it is |
|---|---|---|
| `ref_case_bridge.sql` | one asset-index case | the mapping to CAT, with its gaps made visible |
| `case_preacquisition_payments.sql` | one payment | the seller's history, already carrying `case_sk` |
| `case_payment_history.sql` | one payment | seller + CAT unioned, labelled by source |
| `benchmark_case_accounts.sql` | one `case_sk` | **benchmark accounts** — the static picture per loan at acquisition |
| `benchmark_case_payments_monthly.sql` | one (case_sk, month) | **benchmark payments** — one monthly history per loan, asset index preferred |
| `bridge_overlap_by_portfolio.sql` | one asset-index portfolio | how each book connects, and whether the two sources overlap |

## How the mapping works

`CASE_BRIDGE` carries a `servicer_case_id` and a `system_code`. CAT's `CASE_BK`
is those two glued together, so the join is:

```sql
dc.case_bk = b.system_code || '-' || b.servicer_case_id
AND dc.is_current_flag = TRUE
```

`DIM_CASE` is a slowly-changing dimension, so without `is_current_flag` you get
one row per historical version of the case and every sum multiplies.

## What actually maps — measured 2026-09-21

**The bridge covers 4 of 23 portfolios.** The other 19 (245,602 cases) have no
bridge row at all and cannot be tied to CAT by this route.

| Portfolio | Seller | Country | Cases | Matched to CAT |
|---|---|---|---|---|
| DE25020 | Santander Consumer Bank | Germany | 12,685 | 8,903 |
| SE25008 | Santander Consumer Bank | Sweden | 12,160 | 6,267 |
| CH25007 | Cembra Money Bank AG | Switzerland | 4,439 | 3,064 |
| ES25021 | Norwegian bank | Spain | 4,046 | 2,832 |

Of 33,330 bridge rows, **21,066 match**. The rest are `not_in_mapping` (12,233)
or `interim_dropout` (31); both carry a NULL `system_code`, so the `CASE_BK` they
would build is NULL and the join can never hit. Every one of the 21,066 matched
rows resolves — the join is clean where it applies.

## Four traps, all guarded in the SQL

**The mapping is many-to-one.** 21,066 matched rows resolve to only **20,456
distinct `case_sk`** — 569 CAT cases are claimed by several asset-index cases,
one by seven. Joining CAT's 134m-row collection fact straight to the bridge
repeats those collections once per claimant. `case_payment_history.sql` collapses
to one row per `case_sk` first and flags the affected loans.

**`PAYMENT_DATE` is TEXT.** 211 of 2,156,237 values do not parse. They are kept
with a NULL date and a `has_payment_date_flag`, not dropped — the money is real,
only the date is unusable.

**"Pre-acquisition" is not always knowable.** `CUTOFF_DATE` is populated on
SE25008 (2025-02-28) and ES25021 (2025-07-31), and **NULL on DE25020 and
CH25007**. `is_before_cutoff_flag` is NULL rather than FALSE there. Even where it
is known, some payments fall after it — 6,916 of 119,494 on SE25008.

**`CASES` has 3 duplicate keys** out of 278,932 — two on UK26002, one on
DE25010. None are on a bridged portfolio today, but the queries dedupe anyway.

## What the joined history currently contains

| Source | Currency | Payments | Cases | Amount (local) |
|---|---|---|---|---|
| Asset index | CHF | 2,714 | 836 | 1,305,236.88 |
| Asset index | EUR | 30,635 | 3,587 | 8,002,554.09 |
| Asset index | SEK | 42,141 | 3,467 | 38,716,115.94 |
| CAT | CHF | 592 | 174 | 220,585.12 |
| CAT | EUR | 5,510 | 1,241 | 889,318.78 |

CAT totals were checked against an independent sum over the same `case_sk` set
and agree to the cent.

⚠ **There is no SEK row on the CAT side.** SE25008 has 6,267 matched cases and
not one CAT collection against them. Either that book has not started reporting
into CAT or the mapping is wrong for it — worth asking before anyone reads the
Swedish comparison as "collections collapsed after acquisition".

⚠ **The two sides are not the same kind of number.** The pre-acquisition side is
the seller's own reporting, taken on trust at diligence and never reconciled.
The CAT side is our servicer's. A step change at the boundary is as likely to be
a definition change as a change in borrower behaviour.

⚠ **Everything is in local currency** (EUR, SEK, CHF) and nothing is converted.
Do not add across portfolios without a rate.


---

# The benchmark dataset

`benchmark_case_payments_monthly.sql` is the one to build on. **68,417 rows,
20,456 loans**, unique on `(case_sk, payment_month)`.

**The grain is `case_sk`, not `(portfolio_id, case_id)`** — that is what makes it
reconcile. 610 asset-index cases share a CAT loan with another (all on DE25020,
one loan claimed by seven). Keying on the asset-index case id would split one
loan's history across rows. Aggregating up to `case_sk` is correct: those cases
*are* the same loan. `asset_index_case_count` says how many fed each row.

**The source rule: the asset index wins.** A `(case, month)` the asset index
knows about is taken from the asset index; NPL_COMMON supplies only the months it
says nothing about. `pre_acquisition_source` records which, per row —
`ASSET_INDEX` or `CASE_NPL_COMMON`.

**`months_to_capex` is the benchmark axis.** 0 is the month Brocc bought the
book, negative is the seller's history, positive is ours.

| Source | Rows | Loans | Months | `months_to_capex` | Amount (mixed ccy) |
|---|---|---|---|---|---|
| `ASSET_INDEX` | 62,764 | 7,890 | 2017-03 → 2025-10 | **−44 to −2** | 48,023,906.91 |
| `CASE_NPL_COMMON` | 5,653 | 1,415 | 2026-01 → 2026-09 | **+1 to +9** | 1,109,903.90 |

The split falls exactly where it should: everything from the seller is before
acquisition, everything from NPL_COMMON is after.

## The two sources do not overlap — there is a hole between them

Measured 2026-09-22: **zero case-months appear in both**. The preference rule
changes nothing today; it exists so that the day they do overlap, the answer is
decided in the file rather than by whoever runs it.

What sits between them is a **gap**, not a seam:

| Portfolio | Asset index ends | NPL_COMMON starts | Gap |
|---|---|---|---|
| CH25007 | 2025-10 | 2026-01 | 2 months |
| DE25020 | 2025-08 | 2026-01 | 4 months |
| ES25021 | 2025-09 | 2026-03 | 5 months |
| SE25008 | 2025-04 | — | no NPL_COMMON at all |

⚠ **A cumulative curve drawn across that hole reads as a collapse that did not
happen.** Months −1 and 0 have no payments from either side.

⚠ `months_to_capex` is **NULL on SE25008** — capex comes from the NPL_COMMON
portfolio a loan maps to, and SE25008 reaches none. That is 30,909 of the 62,764
asset-index rows.

# The bridge and overlap check

`bridge_overlap_by_portfolio.sql` — **one row per asset-index portfolio, all 23**,
including the 19 with no bridge. A book with `bridge_rows = 0` is not a failed
match; it is one nobody has mapped.

| Portfolio | Seller | System | Bridge rows | Matched | Distinct `case_sk` | Surplus | Matched % |
|---|---|---|---|---|---|---|---|
| DE25020 | Santander Consumer Bank | 3031 | 12,685 | 8,903 | 8,293 | **610** | 70.19 |
| SE25008 | Santander Consumer Bank | 1062 | 12,160 | 6,267 | 6,267 | 0 | 51.54 |
| CH25007 | Cembra Money Bank AG | 3010 | 4,439 | 3,064 | 3,064 | 0 | 69.02 |
| ES25021 | Norwegian bank | 4042 | 4,046 | 2,832 | 2,832 | 0 | 70.00 |

**The many-to-one problem is entirely DE25020.** The other three map one loan to
one loan.

Run this after any reload. It carries `overlapping_case_months`,
`overlap_difference` and `overlap_absolute_difference_pct`, all NULL today — the
moment they are not, the "asset index wins" rule starts changing numbers and you
want to know by how much.


---

# Benchmark accounts

`benchmark_case_accounts.sql` is the static half, paired with the payments file
on the same key. **20,456 rows, one per `case_sk`**, verified unique.

The method's population assert holds: **0** payment loans are missing from
accounts. 12,181 accounts loans (59.5%) have no payment at all — that is the
never-paid population, not a gap.

| Portfolio | Seller | Ccy | Loans | With capital | `cutoff_capital` | `cutoff_total_balance` |
|---|---|---|---|---|---|---|
| CH25007 | Cembra Money Bank AG | CHF | 3,064 | **0** | — | 26,665,594.84 |
| DE25020 | Santander Consumer Bank | EUR | 8,293 | 8,293 | 72,962,274.30 | 87,810,971.23 |
| ES25021 | Norwegian bank | EUR | 2,832 | 2,832 | 12,765,743.41 | 16,704,613.84 |
| SE25008 | Santander Consumer Bank | SEK | 6,267 | 6,267 | 169,812,378.79 | 217,850,209.07 |

## The money column follows Project Elsa

`cutoff_capital` is **capital only**, mirroring Elsa's removal of
`registration_interest` and `registration_balance` once a second seller arrived:
four sellers deliver interest four different ways, so a balance summed across
them adds four standards together.

⚠ **CH25007 has no capital figure at all** — `principal_at_cutoff` is empty on
all 4,439 of its cases. That book cannot be valued from this dataset. Its only
figures are the interest-inclusive `legal_balance_at_cutoff` and a principal at
*origination*, which is a different point in time and not a substitute.

`cutoff_interest`, `cutoff_other_balance` and `cutoff_total_balance` are emitted
but are **not** the benchmark money — they exist so Elsa's delivery test can be
re-run without re-reading source. `cutoff_total_balance` is verified to be
exactly principal + accrued interest + other balances.

## Two source disagreements it surfaces rather than hides

**`registration_date` comes from NPL_COMMON**, because the asset index's own
column is 100% empty on all four books. `DIM_CASE` has it on 100% of matched
loans.

**Default dates disagree, sometimes by years.** Both are emitted —
`default_date` is the seller's, `npl_common_default_date` is ours, and
`default_date_gap_days` is the gap:

| Portfolio | Agree | Differ | Mean gap |
|---|---|---|---|
| CH25007 | 5 | 3,059 | **1,273.7 days** |
| DE25020 | 5,915 | 2,988 | 119.7 days |
| ES25021 | 0 | 2,832 | 249.0 days |
| SE25008 | 0 | 6,267 | 8.3 days |

Decide which one the deal was priced on before using either for seasoning.

## Guards carried over from the method

- **Deduped** on `(portfolio_id, case_id)` — 3 rows in `CASES` repeat their key.
- **Every one-to-many source grouped before joining** — 383 SE25008 cases and 1
  ES25021 case carry two counterparties, so a bare join would double their capital.
- **No pricing segment is emitted** (changed 2026-10-02, matching
  `work/benchmark-dataset/post-registration-benchmark/templates/01_accounts.sql`): what counts as a segment changes
  with every deal, and `SME` is a size class this feed cannot answer. Three
  facts ship instead — `loan_holder_corporate_flag`,
  `loan_holder_individual_flag`, `loan_holder_unknown_flag` — and more than one
  can be true. A corporate holder is on 65 DE25020 loans.
- **No SME or forward-flow exclusion applied** — the population is reported
  instead. `DEV.ASSET_INDEX` has no forward-flow column; `deal_type` is `OO` on
  all four, which reads as one-off. Stated rather than filtered.
- **Secured is asserted, not filtered** — `COLLATERAL` is empty on all four books.
- ⚠ **`loan_holder_unknown_flag` is not `loan_holder_individual_flag`.** Where no
  borrower type was delivered, both the corporate and individual flags are false
  and unknown is true. CH25007 delivers none at all, so all 3,064 read unknown —
  counting them as individuals would invent a population.

## Distress flags are real but patchy

`bankruptcy_flag`, `debt_restructuring_flag`, `debt_settlement_flag`,
`forbearance_flag` and `deceased_flag` come from `COUNTERPARTIES`, OR'd across
co-borrowers. Only **SE25008** carries anything material — 772 restructured
loans. DE25020 delivers `bankruptcy` as all-false; CH25007 and ES25021 deliver
none of it.

⚠ `loan_legal_status` is passed through raw and means a **different thing per
seller** — CH `1`/`2`, DE `none`/`legal_proceedings`, ES `NO`/`None`, SE
`Yes`/`No`. Do not group across books on it.
