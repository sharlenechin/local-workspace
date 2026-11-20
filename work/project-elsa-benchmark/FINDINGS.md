# Portugal / Millennium — everything measured

The consolidated record of the Project Elsa benchmark: 14 PAM batches, Portugal /
Millennium (BCP), Intrum instance **4050**, 120,713 loans in scope.

Every figure here was measured against the live warehouse on **2026-09-10** or
**2026-09-11**, read-only, and is reproducible from the files named beside it.
Row counts drift as new deliveries land; the structure does not.

This file replaces eighteen investigation `.sql` files. Those files are kept in
[`../../work/.archive/2026-10-02-benchmark-investigation-trail/`](../../work/.archive/2026-10-02-benchmark-investigation-trail/) as the audit trail — nothing was
deleted — but you should not need to open them to answer a question.

**Read this before quoting any number.** Almost every headline figure here has a
condition attached, and most of the conditions were discovered by getting the
number wrong first.

---

## ⚠ STALE AS OF 2026-09-16 — the collections figures below predate G9

`payments.sql` now **excludes pre-registration cash** (its READ FIRST 4), on
request. Every collections number in this file was measured before that change
and is therefore **too high**. The accounts side, the balance and capital
figures, the identifiers and the guards are all unaffected.

| | Before G9 | Now |
|---|---|---|
| Collections, both sellers | 206,143,932.48 | **201,224,598.53** |
| Millennium | 160,045,164.05 | **158,078,425.40** |
| WiZink | 46,098,768.43 | **43,146,173.13** |
| Rows / loans | 824,337 / 68,236 | **798,774 / 67,503** |
| CAT vs PAM, period-matched | 100.05% over 11 batches | **99.36130% over 12** |
| Per-batch range | 89.51%-101.51% | **98.16997%-101.29145%** |

Removed: EUR 4,919,333.95 across 25,563 rows and 9 of the 12 batches. 733 loans
left the payments file because every payment they had predated their own
registration date. Undated cash is untouched at 5,407,533.41.

**Sections 2, 9, 10 and 11 need rewriting.** Until they are, read
`payments.sql` READ FIRST 2 and 4 for the current collections position, and
treat §10's capex-cut reconciliation as the historical basis, not the live one.

---

## Contents

| § | Section | Read it when |
|---|---|---|
| 1 | [The two deliverables](#1-the-two-deliverables) | You want the dataset itself |
| 2 | [Headline numbers](#2-headline-numbers) | You need a figure to quote |
| 3 | [Three sources, three answers](#3-three-sources-and-which-one-answers-what) | Deciding where to read from |
| 4 | [Identifiers](#4-identifiers-and-the-three-things-called-portfolio) | A join returned nothing |
| 5 | [The guards](#5-the-guards) | Changing or reusing a query |
| 6 | [Balance and interest](#6-balance-and-interest) | Quoting a valuation base |
| 7 | [Borrower type / SME](#7-borrower-type-and-the-sme-split) | Segmenting the book |
| 8 | [Default date](#8-default-date) | Any vintage or seasoning work |
| 9 | [Collections and undated cash](#9-collections-and-undated-cash) | Building a curve |
| 10 | [CAT vs PAM reconciliation](#10-cat-vs-pam-the-reconciliation) | Someone asks "do they tie?" |
| 11 | [Per-batch tables](#11-per-batch-tables) | A batch looks odd |
| 12 | [Open questions](#12-open-questions-with-intrum) | Escalating |
| 13 | [Checked and clean](#13-checked-and-clean--do-not-reopen) | Before re-investigating |
| 14 | [How to run it](#14-how-to-run-it) | Reproducing |

---

## 1. The two deliverables

Two files, same population, joining on `(PORTFOLIO_ID, LOAN_ID)`.

### `accounts.sql` — one row per loan

120,543 rows × 9 columns. ~30 seconds.

| Column | What it is |
|---|---|
| `PORTFOLIO_ID` | the **batch** ref, e.g. `PT050030000000` (PAM `COMBINED_REF`) |
| `LOAN_ID` | raw Intrum `CASE_ID`. PROD's key is `4050-<LOAN_ID>` |
| `REGISTRATION_DATE` | when Intrum **opened the case** — not origination |
| `REGISTRATION_CAPITAL` | `ORIGINAL_CAPITAL`. Complete on every loan. **The comparable figure** |
| `REGISTRATION_INTEREST` | `ORIGINAL_INTEREST` at registration. **Incomplete — see §6** |
| `REGISTRATION_BALANCE` | capital + interest. A **floor**, not a claim |
| `DEFAULT_DATE` | PROD `DERIVED_DEFAULT_DATE`. **A proxy on every loan — see §8** |
| `DEFAULT_DATE_SUSPECT_FLAG` | 1,876 pre-1990 dates (earliest 1978-01-01), flagged not nulled |
| `PRICING_SEGMENT` | `SME` if any corporate debtor, else `Individual`. **Policy, not evidence — see §7** |

### `payments.sql` — one row per loan per payment date

474,900 rows × 5 columns, over 52,062 loans that ever paid, 11 batches. ~9 minutes.

| Column | What it is |
|---|---|
| `PORTFOLIO_ID` | batch ref; joins to `accounts` |
| `LOAN_ID` | raw `CASE_ID`; joins to `accounts` |
| `PAYMENT_DATE` | `TRANSACTION_DATE`, recovered across versions. NULL if no version had one |
| `MISSING_PAYMENT_DATE_FLAG` | true on EUR 5,407,535.03 (3.38%) of collections |
| `TOTAL_COLLECTIONS` | EUR, sign-corrected |

There is deliberately **no payment count** — see §9.

### Joining them without double counting

`accounts` is one row per loan; `payments` is many. Join them raw and
`REGISTRATION_BALANCE` repeats once per payment row; an INNER join also drops the
68,481 loans that never paid, so the total falls *and* the survivors multiply.

```sql
collections as (select loan_id, sum(total_collections) as collections
                from payments group by loan_id)
... from accounts left join collections using (loan_id)
```

LEFT, so a loan that never paid keeps its row. Same rule for any other
one-to-many source (`DEBTORS`, `INVOICES`, `LEGAL_STEPS`): group, then join.

### The two populations must move together

Both files drop the **168 loans with no borrower type in the raw feed** — they
cannot be priced. Both apply the same `$exclude_batches`. The notebook's assert
`set(payments.LOAN_ID) <= set(accounts.LOAN_ID)` exists because they drifted once.
Change the classification in one file and you must change it in the other.

`$exclude_batches` removes no rows from `payments` — none of the three batches has
a payment in CAT. It is there for symmetry, so a batch that starts paying cannot
appear in one file and not the other.

---

## 2. Headline numbers

As returned by the two files (120,543 loans, three batches excluded, 168
unpriceable loans dropped):

| | Count | EUR |
|---|---|---|
| Loans | 120,543 | |
| `REGISTRATION_CAPITAL` — principal, complete | | 906,359,149.41 |
| `REGISTRATION_INTEREST` — **incomplete**, 1,044 loans | | 5,974,550.16 |
| `REGISTRATION_BALANCE` | | 912,333,699.57 |
| SME (49.41%) | 12,844 | 450,739,900.85 |
| Individual (50.59%) | 107,699 | 461,593,798.72 |
| Payment rows / paying loans | 474,900 / 52,062 | 160,045,164.05 |
| of which **undated** (3.38%) | | 5,407,535.03 |

**Lifetime recovery: 17.658% on capital · 17.542% on balance · 18.106% on PAM
principal · 17.061% on dated cash only.** Always say which denominator.

### Whole-population figures (no exclusions)

Used in the reconciliation work, so they differ from the table above:

- 120,713 loans in scope, `ORIGINAL_CAPITAL` 906,554,742.21
- CAT collections 160,228,394.35 (the priceable filter costs 183,230.30)
- `REMAINING_CAPITAL` 759,751,422.46

**Roll-forward closes to 1.48%:** 759,751,422.46 + 160,228,394.35 =
919,979,816.81 against opening 906,554,742.21. The residual is write-offs, fees
and accrual. A wrong opening balance would not close.

### Five things to say whenever you quote a figure

1. **Which balance column.** Capital and balance differ by EUR 5,974,550.16.
2. **The balance is a floor** — its interest is 97.7% non-delivery (§6).
3. **`SME` means "a corporate debtor is on the loan"**, not a size class (§7).
4. **This is not collections to date** — CAT stops 2026-01-14, PAM runs to 2026-07 (§9).
5. **Undated cash is real money and it is kept** — filter it out and you lose
   EUR 5,407,535.03 (§9).

---

## 3. Three sources, and which one answers what

| Source | Grain | Reaches back to | Use it for |
|---|---|---|---|
| **PAM** `RAW.HYPERION_INTRUM_PAM.PAM` | batch × month | the batch's capex month | anything recent; batch-level truth; the scope |
| **CAT** `RAW.HYPERION_INTRUM_CAT.*` | loan / transaction | the servicer's whole history | anything lifetime-shaped or loan-level |
| **PROD** `PROD.NPL_COMMON.*` | conformed warehouse | 2014-10-10 for this book | dimensions only — **not collections** |

### ⚠ PROD holds 42% of this scope's collections

`int_npl_case_collection_conformed` inner-joins collections to the case SCD on
`transaction_date >= valid_from`, and the first case version starts **2014-10-10**
— nine years after registration. Every earlier payment is dropped. PROD cannot
answer anything lifetime-shaped for this book.

A **second, separate** loss sits one layer earlier:
`stg_intrum_cat__transactions` filters
`transaction_date >= dateadd(month, -1, current_date())`, and NULL fails that
comparison, so undated payments never reach the join at all. Verified:
`FCT_CASE_COLLECTION` holds zero rows with a null `COLLECTION_DATE` out of
134,097,608. **Fixing the SCD join would not recover this portion** — there is no
date to place it on.

PROD is still used for exactly one column: `DIM_CASE.DERIVED_DEFAULT_DATE`
(§8), joined on `CASE_BK`, one current row per case.

### What PAM cannot do

- **No default date.** Batch grain only; the nearest thing is `AVERAGE_DEBT_AGE`
  (4.17 years for this scope).
- **No payment date and no loan.** Its finest grain is batch × month. There is no
  PAM column corresponding to CAT's `PAYMENT_DATE` and no query can produce one.
  The best it offers is the last **month** a batch reported collections in.
- **No pre-capex cash.** A batch enters the file in its capex month, so PAM's
  lifetime starts at acquisition by construction. Where CAT shows real
  pre-registration money (PT15018G000000: EUR 1.57m from 2011, five years before
  Intrum registered the case) PAM shows nothing — because that cash predates
  PAM's own lifetime. **A zero in a PAM "pre" column is the absence of a
  reporting window, not evidence that no money arrived.**

### What PAM is current on

Measured 2026-09-10: every batch that collects at all last collected in
**2026-07**, the newest actuals month in the newest delivery. PAM is current and
uniform; the batch-by-batch variation in CAT's max payment date (2026-01-09 to
2026-01-14) is an artefact of CAT's extract, not of the books.

---

## 4. Identifiers, and the three things called "portfolio"

**This is the first thing to check on an empty join.** Three real columns carry
the name and they mean different things:

| Value | Where | What it is |
|---|---|---|
| `PT050030000000` | PAM `COMBINED_REF`, CAT `LONG_PORTFOLIO_ID` | the **batch** — what `PORTFOLIO_ID` means in both deliverables |
| `PT05003` | PAM `PORTFOLIOID` | 7 chars, one per **several** batches |
| `HEI-PT25001-U02/2512` | `PROD.DIM_PORTFOLIO.PORTFOLIO_BK` | Brocc's portfolio these batches roll into |

Joining to the wrong one matches nothing, silently.

### Loan ids

`LOAN_ID` is the raw servicer id. PROD uses `CASE_BK = '4050-' || case_id`, so
`LOAN_ID` does not join to PROD directly. `CASE_BK` is not returned — build it as
`$source_system || '-' || loan_id`.

**`CASE_ID` is unique only within a source system.** Unpinned, this scope's loans
match rows in **601** transaction files against **11** in their own instance.

`CLIENT_REF_1` (not returned) is populated and **unique on all 120,713** cases.
It is the seller's own loan reference — the join key to anything Millennium
supplies directly, and the proof that cases = loans.

### Two acquisition dates

- `CAPEX_DATE_M` (PAM) — when **Intrum** bought the batch: 2005–2016 here. This
  is what a lifetime curve is anchored on.
- `PROD.DIM_PORTFOLIO.CAPEX_DATE` — **2025-12-01**, when Brocc bought the book
  from Intrum.

---

## 5. The guards

Each one silently inflates or distorts if removed. Measured 2026-09-10.

### On PAM

| # | Guard | Cost of removing it |
|---|---|---|
| P1 | **One file.** Newest `_file_path like '%/pam.pam.pam.2%'` | The table holds 14 whole deliveries — an unfiltered sum is ~14× too high. The name pattern matters: six mis-loaded `pam.pam.pam_perimeter.*` files (93,306 rows) would win a plain `max(_file_path)` |
| P2 | `PMODE_NAME = 'Real'` | `'Adjust'` rows are internal accounting batches, not the real book |
| P3 | `coalesce(is_ownership_change,0) = 0` | Repeats a batch-month for a legal buyer transfer, with zero balance |
| P4 | **Actual months only** (`period_start_date < extraction month`) | Plan months run to 2041 and would stretch the series into the 2030s. On a "last collection month" query this returns a forecast month and the answer is silently nonsense — it looks exactly like a healthy book still collecting |
| P5 | `upper(seller_name)` | `'MILLENNIUM'` and `'Millennium'` both exist in Portugal; two portfolios go missing without it |

`PERIOD_START_DATE` is **VARCHAR** and holds the **first day of the reporting
month**: `2005-06-01` means "June 2005", not the 1st. Cast before comparing.

⚠ **PAM restates past months** as late cash lands — PT050030000000, January 2026:
0.00 in the first seven files, 5,441.40 from the eighth on. Always read the newest
file, which is what P1 does.

### On CAT

| # | Guard | Cost of removing it |
|---|---|---|
| C1 | **`CASES` is a change-history feed** — 17,841,296 rows for 120,713 loans (**147×**). Dedupe to latest version per `CASE_ID` | Every balance multiplies |
| C2 | **`TRANSACTIONS` is a change-history feed** — 133,930,261 rows for ~12.35m real payments (**10.8×**). Dedupe on `(case_id, orig_tr_id \|\| coalesce(pkey,''))`, latest `RECORD_UPDATE` wins | Every payment multiplies. `PKEY` is in the key because Denmark splits one transaction across rows |
| C3 | **`DEBTORS` is one-to-many AND a change feed** (15,264,217 rows here). Group to one row per `CASE_ID` before joining | Every balance multiplies |
| C4 | **Pin `_file_path` to one source system** | `CASE_ID` is unique only within an instance: 601 transaction files vs 11. Also what makes it affordable — cuts the read from 24.7bn rows to ~404m |
| C5 | **Read ALL extracts** | Pinning the newest loses **4.6%** of money overall and **10.4%** on one batch. `split_part(max(_file_path),'.',4)` lands on a 1,178-row cases delta / 2,486-row transactions delta |
| C6 | **Payments only**: `payment_cost_ind = 'P'` and `booking_ind <> 'Y'` | Intrum's own rule. Without it the sum includes costs and fees |
| C7 | **`AMOUNT` is stored sign-flipped.** Read `-amount` | A plain sum gives the right magnitude with the wrong sign |
| C8 | **Batch filter BEFORE the qualify** | See below — 2,313 loans and EUR 6,856,071.22 |
| C9 | **Drop container cases** (hyphenated `CASE_ID`), as `int_npl_case_intrum` does | A no-op on 4050; kept so `$source_system` can change |
| C10 | **No `row_number()` on `DEBTORS`** — keep every row tied at the latest version and OR the flags | `RECORD_UPDATE` ties at the latest version on **97.4%** of debtor slots and `TYPE` changes across versions on **33.4%**, so picking one row resolves arbitrarily and `PRICING_SEGMENT` flips between runs |

### C8 in full — the ordering is load-bearing

The batch filter runs **before** the `qualify`, so ranking happens only among
versions naming an in-scope batch. A loan whose newest version left the scope
keeps its last in-scope batch instead of vanishing.

Of the 120,543 loans returned:

- **118,400** latest ref unchanged
- **2,174** latest ref NULL, seller name blank — 2,173 of them on
  PT15018G000000 (12% of that batch), 2,172 carrying a `CLOSING_DATE`
- **139** latest ref `PT24004B000000`, seller "INTRUM INVESTMENT SWITZER" — sold
  on, 138 with a closing date, spread over 11 of the 12 batches

Dedupe-then-filter would drop all 2,313 and **EUR 6,856,071.22** of CAT payments
PAM still reports, EUR 6,845,160.28 of it on PT15018G000000.

⚠ **Closure is not the cause of the wiped refs.** PT050030000000 has 10,332
closed loans and not one loses its ref.

84 loans name two in-scope batches (PT15018A040000 → PT16023C000000).
Latest-in-scope-wins puts all 84 under PT16023C000000: one id each, so no double
count, but a real misallocation — PAM bills that money to PT15018A040000.
Portfolio totals right; those two batches are not.

### The dedupe key's known weakness (inherited deliberately)

`concat()` returns NULL if any argument is NULL, so payments with a NULL
`ORIG_TR_ID` collapse into one partition and all but one is discarded.
`int_npl_case_collection_intrum` has the same shape, so the deliverables agree
with PROD. This is the **likeliest cause of the small, consistent shortfall on
the nine pre-2010 batches** (§10). Untested.

### Performance — why the fast version is fast

`TRANSACTIONS` is 24.7bn rows / 454 GB and `CASES` 6.4bn / 221 GB, neither
clustered. The single biggest win is matching `_file_path` as a **literal prefix
with no leading wildcard** — Snowflake prunes micro-partitions on a prefix and
cannot prune a pattern beginning with `%`. An early version matched a pattern
mid-path and got no pruning at all: `explain` assigned 53,398 of 55,653
micro-partitions and 673 GiB, i.e. **96% of the feed**.

Other levers, in order of payoff: pin one source system; apply the case list
**before** the dedupe window; collapse PAM to one row per batch before any join;
join `DIM_CASE` directly on `CASE_BK` rather than through
`FCT_CASE_SNAPSHOT_DAILY`.

On the two `in (select ...)` filters in `payments.sql`: the `batches` semi-join
stays a semi-join (14 rows, referenced once — a join saves no read and cannot fan
out). The transaction scan *was* changed to an inner join against `cases`,
because Snowflake does not guarantee a CTE is materialised and `cases` was
otherwise read twice. ⚠ **The saving came from reading `cases` once, not from the
join operator** — Snowflake compiles `in (subquery)` to a semi-join and pushes it
down exactly as it does an inner join.

⚠ **Nothing may follow the final semicolon** in a `.sql` file, not even a
comment: `run_sql.py` sends the file through `execute_string()`, which splits on
`;`, and a trailing comment-only chunk fails with "Empty SQL statement".

---

## 6. Balance and interest

### `REGISTRATION_INTEREST` is incomplete — use `REGISTRATION_CAPITAL`

`ORIGINAL_INTEREST` is non-zero on **1,044 of 120,711 loans (0.86%)**. Of the
119,669 loans where it is exactly 0.00, **116,905 (97.7%) had defaulted before
registration at a median of 3.01 years**. Three years in default cannot owe zero
interest, so the zeros are **non-delivery, not economics**. PAM agrees — its
interest column is 0.00 in all 163 months. 99.99% of what *is* delivered sits on
the two 2016 batches: a partial backfill.

→ `REGISTRATION_BALANCE` is a **floor** on the claim, and measures 1,044 loans
differently from the other 119,667. For any like-for-like comparison across
loans, batches or segments, and for the PAM check, **use
`REGISTRATION_CAPITAL`**. Ask Intrum for the missing accrual.

### `ACCRUED_INTEREST` — tested for inclusion 2026-09-11 and rejected

EUR 135,711,978.79, accrued *since* registration — **23× the registration
interest**. When someone says "the interest", establish which they mean.

It fails the same test as `ORIGINAL_INTEREST`, harder:

| | Loans | |
|---|---|---|
| > 0 | 14,147 (11.72%) | EUR 135,711,978.79 |
| = 0.00 | 58,610 (48.55%) | median 19.09 yrs in the book |
| NULL | 47,954 (39.73%) | median 18.57 yrs in the book |

So **88.28% of a defaulted book that has sat with Intrum ~19 years shows no
accrual at all**.

⚠ **And it runs backwards to age.** Accrued interest as a share of batch capital
is *highest* on the two youngest batches and lowest on the oldest:

| Batch | Age | Accrued / capital |
|---|---|---|
| PT16023C | 9.0 yrs | 16.56% |
| PT15018G | 9.8 yrs | 17.26% |
| PT06002B | 19.9 yrs | 9.65% |
| PT05007C | 20.3 yrs | 9.10% |
| PT050030 | 20.5 yrs | **2.72%** |

A real accrual grows with time. This shrinks, so it tracks when Intrum started
capturing the field, not what the borrower owes. 76.7% of it (104,123,079.18)
sits on those two 2016 batches. It is also undated and incoherent: only 5,001 of
the 14,147 loans that have an amount carry `ACCRUED_INTEREST_REG_DATE`, while
12,108 loans with **zero** accrual do carry one.

→ Adding it would inflate the denominator ~15% and drop every recovery rate
**unevenly by batch**, on delivery artefacts rather than economics. It would also
mix a figure as at the extract date into a balance as at registration, ~18 years
apart.

⚠ An earlier note said "on 72,759 loans", which counted non-null rows including
the zeros. **Only 14,147 loans actually carry a figure.** Do not quote 72,759.

### There is no cost component at registration

Checked column by column: `ORIGINAL_UNDUE_CAPITAL` and `PURCHASE_AMOUNT` are
filled but sum to 0.00; `ORIG_CAPITAL_VAT`, `ORIGINAL_BALANCE_AT_CLIENT`, all
`*_AT_CUTOFF`, `LATE_PAYMENT_FEE`, `SECURED_ADMITTED_AMOUNT`,
`UNSECURED_ADMITTED_AMOUNT` and `CUSTOM_AMOUNT_1` are 100% empty.

Costs exist only as `REMAINING_*` — as at the latest delivery, undated —
totalling 8,541,391.95 (0.94% of capital). Mixing those into a registration
figure would span two points in time years apart. So say **"at registration"**,
never "total owed".

### Nothing here is a current balance

No dated balance history exists for these books. `CASE_BALANCE` holds no rows for
system 4050 (only 4034, 4042, 7006, 7010, none earlier than 2020-05-30);
`DETAILED_CASE_BALANCE` covers only 7006 and 7010; every `*_AT_CUTOFF` column and
`ORIGINAL_BALANCE_AT_CLIENT` is 100% NULL here. What exists is the balance the
case was **opened** with.

### Currency: everything is EUR, verified before the column was removed

`CURRENCY_ID` used to be in the `payments` grain as a guard. Removed 2026-09-11
on request, after verifying:

- Of the 474,900 payment rows, **474,899 are EUR** and exactly **one** has no
  currency at all — loan 1959892 on PT08010C000000, an undated EUR 1,732.52
  mirroring a payment of the same amount on 2017-08-31 that was reversed on
  2017-12-05.
- `CASES.CURRENCY_CAP_INTEREST` — the currency of `ORIGINAL_CAPITAL` and
  `ORIGINAL_INTEREST` — is `'EUR'` on **all 120,713 loans**, no nulls, no other
  value.
- Collapsing currency out of the grain merges **zero** rows (474,900 distinct
  `(batch, loan, date)` either way).

**No FX conversion is needed or performed** in either file. There is no
`currency = 'EUR'` predicate either — such a filter would silently drop that
one row's 1,732.52.

⚠ **This is a guard that was removed, not one that passed.** If `$country` or
`$seller` change, the files will sum across currencies without saying so.

### Registration capital vs PAM acquisition principal

These are **different quantities** — deal-level acquired principal vs the sum of
what each case was opened with — so agreement is reassurance, not proof.

| Batch | CAT / PAM | | Batch | CAT / PAM |
|---|---|---|---|---|
| PT05007C | 100.0 | | PT16023C | 101.8 |
| PT07010C | 100.0 | | PT15018G | 103.2 |
| PT06002B | 100.0 | | PT09006D | 104.6 |
| PT08010C | 100.0 | | PT08018B | 109.7 |
| PT07007C | 100.3 | | PT06014B | 94.0 |
| | | | **PT050030** | **126.0** ← diverges |

Portfolio: capital **102.562%** of PAM, balance **103.238%** (the 0.676pp gap is
just the delivered interest).

- **PT050030000000 was investigated and registration capital survives.** Ruled
  out: sibling batches (PT05003 has exactly one batch in PAM); post-acquisition
  additions (all 28,444 cases registered within ten weeks of capex); and the one
  that would have mattered, one debt split across several cases — `CLIENT_REF_1`
  is unique on all 28,444, so no principal is double-counted. What is unexplained
  is why PAM is 6.2m **lower**: a question about PAM, for Intrum. ⚠ Its recovery
  rate reads **40.44% or 50.97%** depending on the denominator.
- **PT08018B000000 at +9.7% has not been investigated.**

---

## 7. Borrower type and the SME split

### There is no product, size or segment column anywhere in this feed

Measured 2026-09-10 over all 120,713 loans:

- `CASES.CASE_CLASSIFICATION`, `CLAIM_CONCERN`, `RECEIVABLE_TYPE`,
  `ORIG_PRODUCT_NAME`, `GGCV`, `DATA_EXCL_CLASSIF` — **100% NULL**
- `CASES.IJ_INDUSTRY_CODE` — the single value `'Other'` on every loan
- `CASES.INDUSTRY_CODE` — two values, K and Z, on all 120,713
- `CASES.PRODUCT_ID` — two values, 2 and 4, on all 120,713; `ORIG_PRODUCT_ID` has
  15 and 21 on 74,405 (61.6%). **Neither is decoded anywhere in RAW or PROD** —
  there is no product lookup table
- `PRODUCT_HISTORY` — 31,368 loans (26%), `PRODUCT_ID = 7` on every one,
  `ORIG_PRODUCT_NAME` 100% NULL
- `DEBTORS.LEGAL_TYPE`, `ORIG_LEGAL_TYPE`, `OCCUPATION`, `INCOME`,
  `DEBTOR_FIRST_NAME` — **100% NULL**. `GENDER` filled on 6,860 loans (5.7%)
- `PROD.DIM_CASE` has `SECURED_FLAG` but no segment or product

### So the only candidate is `DEBTORS.TYPE`, and it is undocumented

| `TYPE` | Loans | Debtor slots |
|---|---|---|
| P | 119,075 | 642,227 |
| C | 12,844 | 38,400 |
| NULL | 13,234 | 38,070 |

Counts overlap because a loan carries many debtors. Only **168 loans** have
neither a P nor a C anywhere; every loan has at least one debtor row.

### ⚠ It cannot be validated from this feed — measured, not assumed

A validation block counted how often each type's name takes a Portuguese company
form (LDA, UNIPESSOAL, SOCIEDADE, COMERCIAL, S.A.). It returns **zero matches for
every type, because every name field is empty**. Across all 15,264,217 debtor
rows on instance 4050, `DEBTOR_NAME1`, `DEBTOR_NAME2` and `DEBTOR_LAST_NAME` are
100% NULL — and so are `OCR_NUMBER` and `DEBTOR_NUMBER`, which would have been
the other way to tell a company from a person. `PERSONAL_DATA_DELETED` is `'N'`
on 12.3m of those rows, so **the names were never delivered rather than erased
under GDPR**.

`PRODUCT_ID` offers no help either: every class sits under `PRODUCT_ID` 2, and
`PRODUCT_ID` 4 has three loans in total.

**P for private, C for company is the obvious reading, and only Intrum can
confirm it.**

### ⚠ 'SME' is not a size class

It means only "a corporate debtor is on the loan". `DEBTORS.INCOME` is 100% NULL
and there is no turnover, headcount or company registration number anywhere in
the feed, so a corner shop and a large corporate are indistinguishable.
`DIM_BORROWER.VAT` is 0% filled for this scope, and `LEGAL_EBA_TYPE` stops at
`'Non-financial corporations'` with no SME / non-SME split.

**Do not use it for regulatory or capital segmentation.**

### ⚠ The split is a tie-break, not a reading — EUR 398.6m rides on it

Of the 12,844 loans with a company debtor, only **1,470 (EUR 52,177,435.07)** are
company-**only**. The other **11,374 (EUR 398,562,465.78 — 88% of the SME
balance)** carry a company **and** a private debtor, and are SME purely because
`'C'` is let win over `'P'`. That is **ratified policy, not evidence**.

| Rule | SME loans | SME balance | Share of book |
|---|---|---|---|
| C + P → Individual | 1,470 | 52,177,435.07 | 5.72% |
| **C + P → SME (shipped)** | **12,844** | **450,739,900.85** | **49.39%** |
| PROD-first (old, withdrawn) | 5,569 | 279,942,246.25 | 30.68% |

**Portfolio totals are robust to this; segment-differentiated pricing is not.**

And it is really a question about two batches: **PT15018G000000 EUR
207,317,079.38** and **PT16023C000000 EUR 101,785,544.73** — 77.6% of the C+P
balance between them.

Under a three-way reading (the withdrawn `borrower_type.sql` construct):

| Class | Loans | EUR | Share of balance |
|---|---|---|---|
| CONSUMER | 107,744 (89.3%) | 462,690,047.83 | 50.6% |
| MIXED | 11,324 (9.4%) | 397,424,562.40 | 43.4% |
| COMPANY | 1,473 (1.2%) | 52,207,500.86 | 5.7% |
| UNKNOWN | 169 (0.1%) | 199,166.89 | 0.0% |

Push MIXED to CONSUMER and the consumer share is 94% of balance; push it to
COMPANY and it is 51%. **State which you did.**

(These counts sit a few loans from the `accounts.sql` ones because that file used
`row_number()`; the shipped rule uses the `max_ts` tie-keeping of C10.)

### ⚠⚠ PROD must not be used for the borrower type on this scope

`int_npl_borrower_intrum.sql` keys a borrower as:

```
borrower_bk = source_system_code || '-' || debtor_row_number
```

**There is no case in that key**, and `DEBTOR_ROW_NUMBER` is not unique per case.
Measured on raw instance 4050: 15,264,217 rows, 1,613,593 distinct (case, slot)
pairs, only 1,085,265 distinct `DEBTOR_ROW_NUMBER`s — and **one of them is shared
by 296,041 different cases**. `dim_npl_borrower.sql` then keeps one row per
`borrower_sk` ordered by `record_update_date`, under its own comment *"attributes
will diff between cases. For now, only take latest"*.

So one "borrower" is a slot number shared across hundreds of thousands of cases,
and its legal type is whichever case touched it last:

- 120,710 of 120,713 loans have a debtor slot whose `DEBTOR_ROW_NUMBER` is shared
  by over 100,000 other cases.
- 120,711 loans have a slot on a `DEBTOR_ROW_NUMBER` carrying **conflicting**
  types (P and C and null) across the cases sharing it.

**The loss is directional — it systematically drops companies.** On the 7,204
loans where raw says C+P and PROD says Private only:

| Slot type | Slots | Median cases sharing the row number |
|---|---|---|
| C | 17,559 | **296,041** — the most-shared value in the feed; **zero** on a unique number |
| P | 38,668 | **1** — 19,600 of them on a unique number |

The company slots sit on a sentinel row number shared by 296,041 cases, so their
SCD version is almost never the current one; the private slots are mostly unique
and survive. **PROD understates SME by construction.**

The funnel, for completeness — the loans are *not* absent from PROD, they are
lost at one filter, `dim_borrower.is_current`:

| | Loans |
|---|---|
| classified | 91,930 |
| bridge → a borrower with no `is_current` row | 28,533 |
| borrower current but `ORIGINAL_LEGAL_TYPE` null | 250 |

Of the bridged `borrower_sk`s: 125,011 present and current, 74,377 present but on
an **expired** SCD version, only 572 truly absent.

⚠ **Do not "recover" the 28,533 by dropping `is_current`.** The expired rows carry
the same borrowed values; dropping the filter adds coverage, not correctness —
plus fan-out.

⚠ **Do not read the 7,204 as PROD "missing a co-debtor"** — PROD's value there may
simply belong to another case that shares the slot number.

⚠ **This is a report, not a fix.** Those models live in `brocc-data` and are the
data team's to change (CLAUDE.md Rules 1, 3, 6). Raise the `borrower_bk` grain
with them; do not edit the dbt project from here.

### `LEGAL_EBA_TYPE` is a relabel, not a second opinion

The PROD mapping is one-to-one and has no third value, so it agrees by
construction wherever it has a row:

| `ORIGINAL_LEGAL_TYPE` | → `LEGAL_EBA_TYPE` | Loans |
|---|---|---|
| Private | Households | 90,341 |
| Company | Non-financial corporations | 4,058 |
| NULL | NULL | 1,208 |

For EBA vocabulary, map from `PRICING_SEGMENT` exactly as the data team's own seed
does — one-to-one, and it cannot express SME for Intrum at all:

```
intrum,P,Private,Households
intrum,C,Company,Non-financial corporations
```

**PROD never calls a loan private that raw calls corporate** — it sees less, but
in one direction only, which is exactly why it is unusable here.

`HAS_COMPANY_DEBTOR` / `HAS_PRIVATE_DEBTOR` were returned and were **removed
2026-09-11 on request**, so the sensitivity can no longer be run from the output.
The flags still exist as `is_company` / `is_private` in the `enriched` CTE — add
them back to the final select to restore it.

⚠ **No personal data leaves these queries.** No name, number or date of birth is
selected. Keep it that way.

---

## 8. Default date

### ⚠⚠ It is a proxy on every single loan — there is no real default date in this book

Traced through dbt and measured 2026-09-11:

1. **`RAW CASES.DEFAULT_DATE` is populated on 0 of 120,713 loans.**
2. `int_npl_case_intrum.sql` substitutes invoice data when the servicer's date is
   missing, and the rule is **country-specific**:

   | Country | Substitute |
   |---|---|
   | DE, CH | `invoices.max_invoice_date` |
   | NL, HU, SE, FI | `invoices.min_due_date` (earliest) |
   | **everyone else, incl. PT** | `invoices.max_due_date` (**latest**) |

   So every default date here is "the **latest** invoice due date on the case",
   never an observed default event.
3. `dim_npl_case.sql` then computes
   `derived_default_date = coalesce(default_date, origination_date + 36m)`.
   **That second fallback never fires here and could not** — `ORIGINATION_DATE`
   is also 100% NULL on all 120,713.

**Measured consequence: `DEFAULT_DATE` and `DERIVED_DEFAULT_DATE` are identical
on all 120,713 loans, differing on zero.** Returning either gives the same column.

### ⚠ Taking the latest due date biases the date late

Invoices keep being raised after Intrum takes a case on, so `max(due date)`
drifts forward. That is the most likely explanation for:

- **413 loans (EUR 44,014,486.68, 4.8% of balance)** whose default date falls
  **after** registration — and it cannot be tested against an un-derived value
  because none exists.
- **2,692 loans (EUR 148,284,254.43, 16.3%)** whose default date is **exactly
  equal** to their registration date.

**Treat any seasoning, vintage or time-to-recovery analysis built on this column
with suspicion.**

120,713 of 120,713 are populated; **117,552 (97.4%) fall before the capex
month** — the only sense in which it marks "distressed when we bought it".
1,876 dates are pre-1990 (earliest 1978-01-01), flagged by
`DEFAULT_DATE_SUSPECT_FLAG` rather than nulled so they can be excluded
deliberately instead of vanishing.

`DIM_CASE` is keyed on `CASE_BK`, one current row per case, so the borrower
defect in §7 does not touch this column.

### Do not read default dates through the snapshot

An earlier route reached default dates via
`DIM_BATCH → FCT_CASE_SNAPSHOT_DAILY → DIM_CASE`. That costs more **and**
restricts the answer to loans still on book at the latest snapshot — survivors
only. The loan snapshot covers 2024-06 onward, so there is no way to see the
original population that way.

### Insolvency is not a substitute

`BANKRUPTCY_RECORD` covers 4.87% of loans and **every date falls in a 23-month
window (2018-10 to 2020-09)** for books registered 2005–2016.
`BANKRUPTCY_END_DATE` is 100% NULL here, there is no usable record key, and PROD
does not model the table at all. It cannot mark distress at acquisition.

---

## 9. Collections and undated cash

### ⚠ This is not "collections to date"

`payments.sql` is collections **to the CAT extract date** (last payment
2026-01-14) **plus undated cash**. PAM's newest delivery reports actuals through
**2026-07**, so PAM holds six months this file cannot: **EUR 1,653,076.48** across
these batches (EUR 1,946,151.11 measured at loan level over the seven excluded
reporting months). **Read anything recent from PAM, not from CAT.**

How big that gap is depends entirely on the question:

| | |
|---|---|
| As a share of the 21-year lifetime | **1.20%** — immaterial for vintage work |
| As a share of calendar 2025 collections | **54%** — fatal for anything current |

The book is in run-off — 2023: 5,186,062.63, 2024: 4,340,821.85, 2025:
3,584,454.52, falling ~17% a year — so the missing months carry the trend.

### The date is recovered across versions, then kept NULL if still absent

Before recovery, **190,189 of 542,385** deduped payments carry no transaction date
— EUR 58,556,660.58, **36.5% of the money**. The date is taken as the **latest
non-null value across ALL versions** of a transaction, not from the winning
version alone, which recovers roughly **EUR 53m** that a naive
`where transaction_date is not null` throws away.

What no version dates stays in the file with `MISSING_PAYMENT_DATE_FLAG` true:
**EUR 5,407,535.03** (5,450,225.84 on the whole population, 16,551 payments across
6,090 loans, 3.1%). An earlier version bounded the date instead and silently lost
5,450,225.84.

⚠ **Never bound this date.** There are **zero** pre-1990 and **zero** future-dated
payments in the deduped set; the 1979 and 2028 values in the raw column belong to
non-payment rows or superseded versions and never arrive here. (Bounding is
correct on an *undeduped* read, where 1900-01-01 and 2099-12-30 sentinels do
appear — that is a different query.)

`PAYMENT_DATE` is `TRANSACTION_DATE`, **not `BANKING_DATE` or
`REGISTRATION_DATE`** — it is when the payment is attributed, which is what a
curve wants.

### ⚠ Undated cash is real money and it is kept

Filter on `PAYMENT_DATE` for any time series and the total falls short by EUR
5,407,535.03. **Do not filter it out and then quote the remainder as the book's
collections.** Lifetime recovery reads 17.658% on all cash against registration
capital, 17.061% on dated cash only.

**Do not treat it as a data-quality score either.** `CAT_TOTAL_ALL` is the book's
collections; a period match ratio is a diagnostic. They answer different
questions.

### Where the undated cash comes from — migration, not pre-acquisition

Every pre-2010 batch carries **3–10%** of its collections undated; both 2016
batches carry **exactly zero**. Yet the only batch with material pre-acquisition
payments is PT15018G000000 — EUR 1,571,494.31 of them, **dated**, up to five years
before its capex month — and it has **no undated cash at all**. If undated meant
"before we bought it", those two columns would coincide; they are mutually
exclusive instead.

The competing explanation is **migration**: Intrum's CAT platform took these books
on **2014-10-10**, nine years after the pre-2010 registrations, so that history
had to be loaded from an older system and may have arrived without dates.

⚠ **A fallback date is not a payment date.** `BANKING_DATE` is when the cash
cleared, `REGISTRATION_DATE` when the transaction was keyed, `BOOKING_DATE` when
it was posted. They are enough to test the migration hypothesis and are **not** a
substitute for `TRANSACTION_DATE` in a collections curve. Do not backfill from
them without agreeing it with the data team first.

### No payment count, because it could only mislead

Rows pass Intrum's own payment filter carrying a **NULL amount and NULL
currency**, on every batch — **43,658 loans across the twelve**: PT050030000000
11,418, then 5,141 · 4,906 · 4,226 · 4,038 · 3,390 · 3,318 · 3,155 · 1,553 ·
1,384 · 1,129.

`amount is not null` excludes them so they cannot invent zero-value payment
dates. **Keep that guard** — money is unaffected either way, but without it these
rows create `(LOAN_ID, PAYMENT_DATE)` rows with a NULL total. Worth raising with
Intrum.

(An exceptions query may deliberately *admit* these rows to count them, ordering
NULL amounts last in the dedupe so money stays identical. Never copy that CTE
into a money query.)

---

## 10. CAT vs PAM: the reconciliation

### ⚠ Never quote a CAT-vs-PAM ratio without the period cut

Whole against whole, CAT is **99.88%** of PAM — **and that figure is a
coincidence.** Two opposite errors cancel in it: CAT missing Feb–Jul 2026, against
CAT's undated cash that PAM already counted before the cut.

Cut both sides at 2026-01 and the real relationship appears:

| | EUR |
|---|---|
| CAT (all, incl. undated) | 160,228,394.35 |
| PAM (actuals to 2026-01) | 158,769,411.06 |
| **CAT is 100.92% of PAM** | **+1,458,983.29** |

### The four differences, and which way each pushes

| # | Difference | Direction | Size |
|---|---|---|---|
| 1 | **PAM's lifetime starts at capex, CAT's does not** | CAT **over** | PT15018G 2015: CAT 1,054,484.34 vs PAM 0.00; 2016: 5,616,413.57 vs 4,727,287.04. PT16023C 2016: 322,912.24 vs 0.00 |
| 2 | **The CAT extract is six months behind** (last payment 2026-01-14 vs PAM actuals to 2026-07) | CAT **under** | EUR 1,653,076.48 / 1,946,151.11 |
| 3 | **3.1% of CAT payments have no date at all** | CAT **under, in every year** | EUR 5,450,225.84, 16,551 payments, 6,090 loans |
| 4 | **PAM restates past months** as late cash lands | either way, small | read the newest file |

The comparison window therefore **ends at the last complete CAT month**
(December 2025), not at the extract date — CAT's January is a half month and
would drag the match down for no reason. That means **seven** PAM reporting
months are excluded (2026-01 to 2026-07); "six months behind" describes the
extract, not the column.

### The measured result (window 2005-06 .. 2025-12)

| | EUR |
|---|---|
| CAT matched | 153,117,164.88 |
| CAT undated (cannot be placed in a month) | 5,450,225.84 |
| PAM matched | 158,480,663.46 |
| **CAT matched + undated / PAM matched** | **100.05% (+86,727.26)** |

⚠ **That 0.05% is a net of two opposite residuals which happen to cancel.** Do not
read it as "reconciled" without looking at both halves:

| | Residual | As % of PAM |
|---|---|---|
| 9 pre-2010 batches | **−626,001.74** | −0.59%, **every one under** (range −0.09% to −1.23%) |
| 2 × 2016 batches | **+712,729.00** | +1.37%, **both over** (PT15018G +1.30%, PT16023C +1.51%) |

Those two sums are reproduced **to the cent** by an independently built query.
Two different queries agreeing on a fourteen-batch breakdown is the reason to
trust either.

### ⚠ Read the residual, never the raw match ratio, on a pre-2010 batch

The match ratio is already period-matched, so the delivery lag cannot flatter or
depress it. What it does **not** credit is the undated cash — real money PAM has
already counted in some month. That is the whole reason the pre-2010 books look
3–11% short on the ratio while their true residual is under 1.3%.
**PT08018B000000 is the clearest case: the worst ratio of all fourteen (0.895)
and the smallest residual (−0.089%).**

### The post-registration cut

Repeating the match with the lower bound set to each **case's own registration
date** instead of the batch capex month barely moves the answer overall — 96.37%
against 96.62% before undated cash is credited — because registration and capex
are days apart on most batches. It matters on exactly two:

| Batch | Capex cut | Post-reg cut | |
|---|---|---|---|
| PT16023C000000 | 101.51% | **99.75%** | **RESOLVED** |
| PT050030000000 | 90.88% | 90.37% | |

**PT16023C000000 is the finding.** Its 1.51% overage was EUR 322,493.00 of
payments made *after* the December 2016 purchase but *before* the cases were
registered a few weeks later. So **PAM's collection clock starts at case
registration, not at the capex month its lifetime starts from.**

PT15018G000000 is unchanged at 101.29% — its pre-registration cash is also
pre-capex, so the capex cut had already removed it.

On a post-registration basis with undated cash credited back: 9 pre-2010 batches
−0.65%, 2 × 2016 batches +0.75%, overall **99.81% (−306,404.04)** against 100.05%
on the capex cut. **Both bases are defensible; they differ by EUR 393,131.30.**
Use the capex cut to ask "what could PAM possibly report"; use the
post-registration cut to ask "what came in while Intrum was servicing the case".

### The one batch that does not reconcile

**PT15018G000000**, over by ~EUR 436k before undated cash and after every other
correction. It is also the only batch with a material wiped-reference count.

**Leading hypothesis, untested:** 2,173 of its 17,943 loans (12%) have a NULL
`LONG_PORTFOLIO_ID` and a blank seller name in their newest CAT version, and carry
**EUR 6,831,847.76** of in-window payments. The deliverables bill all of it to
PT15018G000000, on their last version that named a batch. No other batch does
this. If PAM has stopped reporting even 5% of that cohort's collections, that is
the overage. **Test that before anything else.**

The pre-2010 shortfall is a separate question: consistent direction, small, and
the likeliest cause is the NULL-`ORIG_TR_ID` collapse in the dedupe key (§5),
which only ever drops rows. Also untested.

### The estate-wide extract lag, for context

Measured 2026-09-10 across every Intrum system. **A lagging system is usually a
decommissioned one — check coverage before raising it:**

| System | Country | Last payment | Behind | "Missing" | Verdict |
|---|---|---|---|---|---|
| 1062 | SE | 2016-01-29 | 126 months | EUR 1.51bn | **not a gap** — 348 of 352 batches also served by 2080; 4 stranded, EUR 116,974.70 |
| 7006 | ES | 2025-11-07 | 8 months | EUR 18.04m | **not a gap** — all 79 batches also served by 4042 |
| **4050** | **PT** | **2026-01-14** | **6 months** | **EUR 11.05m** | **251 of 251 batches stranded. The only real gap in the estate** |

Use *batches stranded* and *truly undelivered*, never "collections not yet
delivered" on its own. And note `LAST_PAYMENT_DATE`, not the extract timestamp, is
the honest measure — a filename says when Intrum cut the file, not how far the
data inside reaches.

---

## 11. Per-batch tables

### A. Where each batch stands (2026-09-10)

`RESIDUAL` is the figure to quote: CAT's period-matched collections **plus** its
undated cash, against PAM for the same months.

| Batch | Capex | Loans in CAT | PAM lifetime | CAT matched | PAM matched | Match ratio | Residual | Residual % |
|---|---|---|---|---|---|---|---|---|
| PT050030000000 | 2005-06 | 28,444 | 12,150,023.20 | 10,995,458.69 | 12,098,842.44 | 0.90880 | −66,185.74 | −0.547% |
| PT05007C000000 | 2005-09 | 9,785 | 22,624,643.59 | 21,780,303.63 | 22,545,240.90 | 0.96607 | −61,478.72 | −0.273% |
| PT06002B000000 | 2006-03 | 11,141 | 12,380,822.21 | 11,813,828.78 | 12,346,715.48 | 0.95684 | −88,724.34 | −0.719% |
| PT06014B000000 | 2006-12 | 9,514 | 18,115,823.68 | 17,319,757.43 | 18,015,065.25 | 0.96140 | −105,969.67 | −0.588% |
| **PT06014B010000** | 2006-12 | **0** | 660,000.00 | 0.00 | 660,000.00 | — | **−660,000.00** | **−100%** |
| **PT070040000000** | 2007-04 | 2 | 340,000.00 | 0.00 | 340,000.00 | — | **−340,000.00** | **−100%** |
| PT07007C000000 | 2007-06 | 7,414 | 10,867,251.22 | 10,217,977.85 | 10,803,118.12 | 0.94584 | −103,996.16 | −0.963% |
| PT07010C000000 | 2007-11 | 2,940 | 5,448,802.75 | 5,141,248.03 | 5,405,253.85 | 0.95116 | −66,693.36 | −1.234% |
| PT08010C000000 | 2008-06 | 8,822 | 10,031,583.11 | 9,403,871.18 | 9,965,692.89 | 0.94362 | −91,771.79 | −0.921% |
| PT08018B000000 | 2008-09 | 10,923 | 11,435,435.25 | 10,181,841.13 | 11,375,171.02 | 0.89509 | −10,081.84 | −0.089% |
| PT09006D000000 | 2009-06 | 3,532 | 4,027,540.03 | 3,615,277.99 | 3,990,692.34 | 0.90593 | −31,100.12 | −0.779% |
| **PT15018G000000** | 2016-03 | 17,943 | 34,323,780.86 | 34,051,806.66 | 33,616,121.43 | 1.01296 | **+435,685.23** | **+1.296%** |
| **PT15018A040000** | 2016-11 | **0** | 130,420.97 | 0.00 | 126,093.94 | — | **−126,093.94** | **−100%** |
| PT16023C000000 | 2016-12 | 10,253 | 19,016,781.64 | 18,595,793.51 | 18,318,749.74 | 1.01512 | +277,043.77 | +1.512% |

### B. Which issue touches which batch

| Batch | No CAT money | Batch dispute | 6m lag EUR | Undated EUR | Pre-capex EUR | Wiped loans | Wiped EUR | Sold on | Amount-less loans |
|---|---|---|---|---|---|---|---|---|---|
| PT050030000000 | – | – | 51,180.76 | 1,037,198.01 | 0.00 | 0 | 0.00 | 52 | 11,418 |
| PT05007C000000 | – | – | 79,402.69 | 703,458.55 | 0.00 | 0 | 0.00 | 5 | 4,906 |
| PT06002B000000 | – | – | 34,106.73 | 444,162.36 | 750.00 | 1 | 0.00 | 7 | 3,390 |
| PT06014B000000 | – | – | 100,758.43 | 589,338.15 | 1,163.21 | 0 | 0.00 | 7 | 4,226 |
| PT06014B010000 | **Y** | – | 0.00 | 0.00 | 0.00 | 0 | 0.00 | 0 | 0 |
| PT070040000000 | **Y** | – | 0.00 | 0.00 | 0.00 | 0 | 0.00 | 0 | 0 |
| PT07007C000000 | – | – | 64,133.10 | 481,144.11 | 0.00 | 0 | 0.00 | 12 | 3,318 |
| PT07010C000000 | – | – | 43,548.90 | 197,312.46 | 0.00 | 0 | 0.00 | 3 | 1,384 |
| PT08010C000000 | – | – | 65,890.22 | 470,049.92 | 0.00 | 0 | 0.00 | 7 | 4,038 |
| PT08018B000000 | – | – | 60,264.23 | 1,183,248.05 | 104.53 | 0 | 0.00 | 11 | 5,141 |
| PT09006D000000 | – | – | 36,847.69 | 344,314.23 | 95.30 | 0 | 0.00 | 3 | 1,553 |
| PT15018G000000 | – | – | 707,659.43 | 0.00 | **1,571,494.31** | **2,173** | **6,831,847.76** | 25 | 3,155 |
| PT15018A040000 | **Y** | **Y** | 4,327.03 | 0.00 | 0.00 | 0 | 0.00 | 0 | 0 |
| PT16023C000000 | – | – | 698,031.90 | 0.00 | 0.00 | 0 | 0.00 | 7 | 1,129 |

⚠ **The 6m-lag column is PAM-only and measures run-off, not a fault.** 72% of the
EUR 1,946,151.11 sits on the two 2016 books, which looks alarming — but measured
against each batch's own trailing twelve months, every batch lands between 0.24×
and 0.74× of a year's collections, clustered near 0.5×. That is what seven months
of an even run rate looks like. And a batch with no CAT loans can still show lag:
PT15018A040000 collected in 5 of those 7 months while CAT holds zero loans for
it — which makes it a **live** book, not a dormant one.

### The three excluded batches

`$exclude_batches = 'PT06014B010000,PT070040000000,PT15018A040000'`. Set it to
`''` to return them.

| Batch | Why excluded |
|---|---|
| `PT070040000000` | The only one that changes `accounts` output: 2 loans holding EUR 2.00 of capital each against PAM's 340,000.00, registered **279 days** after capex where every other batch lands within −2 to +40 days. Never paid |
| `PT06014B010000` | **No cases in CAT under any source system.** PAM reports 660,000.00. A feed gap, not an empty book |
| `PT15018A040000` | Its 84 cases resolve to PT16023C000000 (§5 C8), so it was never in the output. PAM puts `ACQUISITIONPRINCIPAL` at 18,551,110.00 against 3,452,055.62 of registration balance on those loans — **15.1m of acquired principal with no loans behind it**. Second-largest Intrum item |

⚠⚠ **Two of the three are not collections at all.** PT070040000000 and
PT06014B010000 each post **one month equal to their own `ACQUISITIONPRINCIPAL` to
the cent, in the capex month**:

| Batch | Capex month | COLLTOTAL | ACQUISITIONPRINCIPAL | PAM months | Collecting months |
|---|---|---|---|---|---|
| PT070040000000 | 2007-04 | 340,000.00 | 340,000.00 | 375 | **1** |
| PT06014B010000 | 2006-12 | 660,000.00 | 660,000.00 | 379 | **1** |

Each therefore reads as having recovered exactly 100% of principal in month zero
and nothing in the ~31 years since. The other twelve batches collect across
106–253 months each — roughly 2,500 collecting months — and **not one** ever
posts a month equal to its acquisition principal. **EUR 1,000,000.00 of
"collections" across the two must not be counted as cash.**

Three batches have no CAT money, not two — `accounts.sql` reports "12 of 14" on a
**loan** count, which hides PT070040000000 (it *has* two loans, neither has ever
paid). On money the tally is 11 of 14, and the three unreconcilable batches carry
EUR 1,130,420.97 of PAM collections between them.

---

## 12. Open questions with Intrum

Full write-up, formatted for forwarding: [`../data-issues/intrum/escalations-portugal-millennium.md`](../data-issues/intrum/escalations-portugal-millennium.md).

| # | Question | Money at stake |
|---|---|---|
| 1 | Three batches PAM reports collections for have no money in CAT. Are the two single-month postings cash or an opening/adjustment entry? | EUR 1,130,420.97, of which **1,000,000.00 is almost certainly not cash** |
| 2 | PAM and CAT disagree about which batch owns 84 loans (PT15018A040000 vs PT16023C000000) | EUR 130,420.97 billed to a batch with no loans |
| 3 | 12% of PT15018G000000's loans have had their batch reference **wiped** | EUR 6,831,847.76 riding on a workaround |
| 4 | The loan-level CAT feed is six months behind PAM. What is the intended cadence? | EUR 1,946,151.11 = 54% of 2025 collections |
| 5 | 16,551 payments arrive with **no date in any version** | EUR 5,450,225.84 |
| 6 | 139 loans moved to `PT24004B000000` / "INTRUM INVESTMENT SWITZER" — confirm onward sale | per-batch loan counts |
| 7 | Amount-less rows pass Intrum's own payment filter, on every batch | no money; payment **counts** overstated |

Plus two for our own data team (not Intrum):

- **Our warehouse holds 42% of this scope's collections** (§3).
- **The shared dedupe key drops payments with a missing `ORIG_TR_ID`** (§5).

---

## 13. Checked and clean — do not reopen

Four things that looked like they were losing data and are not.

1. **Pinning to source system 4050 hides nothing.** Asked with **no instance
   filter at all**, 4050 is the only system holding any of these 14 batch
   references — 17,841,296 history rows, 120,713 loans, 13 of 14 batches, one row
   in the result. The pin buys correctness and query cost for no loss of coverage.
2. **Keeping only each loan's newest version drops no loan** — because the batch
   filter runs before the dedupe (§5 C8). Reversing them would silently drop
   2,313 loans and EUR 6,856,071.22.
3. **The batch-mixing theory is dead.** The hypothesis was that CAT credits
   PT15018A040000's loans to its sibling PT15018G000000 (both `PT15018*`), which
   would have explained a third of that batch's overage. Measured: they go to
   **PT16023C000000** instead, carrying only EUR 11,955.29 against the batch's EUR
   130,420.97 of PAM collections. It explains **none** of PT15018G000000's excess
   and at most 3.7% of PT16023C000000's — which the post-registration cut already
   resolves.
4. **The 2016 overage is not a timing effect.** Specifically tested: pre-capex
   cash is already excluded, the window already ends at the last complete CAT
   month, and extract lag pushes CAT **down** not up. Neither 2016 batch has any
   undated cash to explain it.

---

## 14. How to run it

```
mise run sql -- work/project-elsa-benchmark/accounts.sql     # ~30s
mise run sql -- work/project-elsa-benchmark/payments.sql     # ~9 min
```

```python
datalake.q("work/project-elsa-benchmark/accounts", convert=False)
datalake.q("work/project-elsa-benchmark/payments", convert=False)
```

Or open [`portugal_millenium_benchmark.ipynb`](portugal_millenium_benchmark.ipynb)
and Run All — it loads both, runs the asserts and exports the CSVs.

### `convert=False` is not optional here

It keeps Snowflake's `Decimal` values instead of float64. The notebook's asserts
check `CAPITAL + INTEREST == BALANCE` **exactly**, and in float64 that identity
fails on rounding. It is also the workspace rule for anything you sum or
reconcile — and this is the valuation base.

Trade-off: `display.float_format` does not apply to `Decimal` columns, so format
money explicitly when you print it. `convert=False` also leaves DATE columns as
Python `date` objects, which pandas cannot min/max/resample — coerce them back
with `pd.to_datetime`. Undated payments become `NaT`, which is what you want:
they drop out of any time series while their money stays in the total.

### Session variables

| Variable | Value | Notes |
|---|---|---|
| `$country` | `'PT'` | matched with `like` |
| `$seller` | `'MILLENNIUM'` | matched case-insensitively; both casings exist |
| `$source_system` | `'4050'` | the Intrum instance |
| `$raw_prefix` | `'data-prod-data-raw-sftp-071269be/intrum/cat.'` | **literal prefix, no leading wildcard** |
| `$exclude_batches` | three batch refs | `''` returns them |

Override at the terminal with `key=value`, or in a notebook with
`datalake.q("...", country="ES")`.

### Workspace rules that apply

- **Read-only.** `NPL_ANALYST` holds `SELECT` and `USAGE` on PROD only.
- **Write here, never in `brocc-data`.** If a question needs a model changed,
  say the analysis is blocked on a modelling change and stop.
- Money and ratios to **up to 5 decimals**; never `round()` a DataFrame.
- Never commit or push.
- Work around a data-quality problem **visibly** — a commented guard in the SQL —
  and say it in the answer, not just the code.

---

## File map

| File | What it is |
|---|---|
| `accounts.sql` | deliverable — one row per loan |
| `payments.sql` | deliverable — one row per loan per payment date |
| `portugal_millenium_benchmark.ipynb` | loads both, asserts, exports |
| `FINDINGS.md` | **this file** |
| `../../work/benchmark-dataset/post-registration-benchmark/METHOD.md` | how to build one of these for another book |
| `../../work/benchmark-dataset/post-registration-benchmark/templates/` | parameterised template queries |
| `../../work/.archive/2026-10-02-benchmark-investigation-trail/` | the eighteen investigation files, kept as audit trail (`README.md` there says what each one answered) |
| `../data-issues/intrum/escalations-portugal-millennium.md` | the escalation write-up for the product manager |
