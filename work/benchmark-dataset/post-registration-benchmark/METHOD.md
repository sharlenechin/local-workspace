# How to build a benchmark dataset

The repeatable process behind the Portugal / Millennium benchmark, generalised so
it can be run for any country / seller in the Intrum estate.

The worked example — every figure, every guard, every escalation — is
[`../project-elsa-benchmark/FINDINGS.md`](../project-elsa-benchmark/FINDINGS.md).
Read the step here, then read the matching section there to see what the answer
looked like on a book where it has already been done.

**A benchmark dataset is two tables plus a reconciliation you can defend:**

| | |
|---|---|
| `accounts` | one row per loan — the valuation base |
| `payments` | one row per loan per payment date — the recovery curve |
| the reconciliation | why these two agree with the servicer's own report, and by exactly how much they do not |

The third one is the work. The first two are a week of guards.

---

## The shape of the problem

Intrum delivers the same book twice, and neither delivery alone is the answer:

| | `RAW.HYPERION_INTRUM_PAM.PAM` | `RAW.HYPERION_INTRUM_CAT.*` |
|---|---|---|
| Grain | batch × month | loan / transaction |
| Starts at | the batch's capex month | the servicer's whole history |
| Currency | batch currency | case currency |
| Delivered | monthly, current | per Intrum instance, **can be months behind** |
| Good for | recent cash, batch truth, defining the scope | lifetime curves, anything per loan |

And our own warehouse (`PROD.NPL_COMMON`) is a third thing again: conformed,
dimensionally clean, and — for collections — **truncated at whatever date the
servicer's platform took the case on**. On Portugal that cost 58% of the money.
Check it on your book before assuming otherwise; do not assume it is broken
either.

**The method is: define the scope in PAM, build the loan level from CAT, then
reconcile CAT back to PAM batch by batch and explain every difference.**

### When does this move onto `NPL_COMMON`?

Not yet, and **not entirely, ever**. `work/dbt/NPL-UNDERWRITING-DESIGN.md` and
the Pipeline Change Map set out the changes that would let most of this come
from the warehouse instead of RAW. Tracking what each one buys:

| Benchmark step | Moves to `NPL_COMMON` when | Why not today |
|---|---|---|
| `00_scope` — batches in scope | **change 2** carries deal type to `dim_npl_batch` | One-off vs forward flow cannot be expressed at all, so a mart cannot reproduce a scope |
| `01_accounts` — the spine | **changes 1, 3, 4** — originator, registration amounts, `batch_sk` on `dim_npl_case` | The columns are loaded and staged, then dropped by the last model |
| `02_payments` — the curve | **changes 5 and 5b** — backdate the case SCD *and* make the collection join null-safe | The fact holds 66.75% of reported cash on the big PT book and 1.28% on the small one (measured 2026-10-02) |
| `03_reconcile` — the deliverable | **change 10** — one shared reconciliation model at batch × month | Nothing in `NPL_COMMON` pairs PAM against CAT, so the batch ledger cannot be built there |

⚠⚠ **Three things stay on RAW whatever lands**, and they are the reason this
file will not be deleted:

- **Borrower type.** PROD cannot answer it per loan. Measured 2026-10-02: one
  `BORROWER_BK` in `DIM_BORROWER` is shared by **24,559,290 cases**, so the key
  is collapsed and the corporate/individual split cannot be resolved through it.
  **No change in the artifact fixes this** — raise it separately. Keep using
  `templates/05_borrower_type_probe.sql` and the raw `DEBTORS` route in
  `01_accounts`.
- **Exclusions.** `templates/07` is a record of decisions about what belongs in
  **one priced book**. That is never a mart — it travels with the deal.
- **The feed lag.** `NPL_COMMON` inherits CAT's delivery lag, so recent months
  still have to be read from PAM. `templates/06_feed_lag.sql` stays the check.

⚠ **And none of the collection recovery is proven.** Nobody has run the
backdated model. 42–58% is the size of the hole, not a promise of the fill —
re-measure on your own book before trusting a warehouse-sourced curve.

**Until all of that lands, build from RAW as described below.** The guards in
[`GUARDS.md`](GUARDS.md) are what make a RAW build defensible, and they stay
true either way.

---

## Before you start

Three facts decide everything downstream. Get them first.

| Question | How | Template |
|---|---|---|
| Which batches am I in scope for? | PAM, newest delivery, country + seller | `00_scope.sql` |
| Which Intrum instance holds them? | CAT `CASES`, **no instance filter**, grouped by `_file_path` | `00_scope.sql` block B |
| How far behind is that instance? | max payment date vs PAM's last actuals month | `06_feed_lag.sql` |
| What will my scope throw away? | PAM, same scope, filters applied as LABELS not predicates | `07_exclusions.sql` |

⚠ **Do not guess the source system.** `CASE_ID` is unique only *within* an Intrum
instance. Pin the wrong one and you silently pull another country's
transactions; pin none and the query is unaffordable. Block B of `00_scope.sql`
asks the feed which instance actually holds your batch refs, and also tells you
whether more than one does — in which case every downstream query needs the
instance in its join key, not just in a file filter.

⚠ **Check the currency before you write a single sum.** If
`CASES.CURRENCY_CAP_INTEREST` has more than one value on your scope, currency
belongs in the grain of both deliverables and nothing may be summed across it
without FX. Portugal is single-currency EUR, which is why its files carry no
currency column — that is a **guard that was removed after measurement**, not a
guard that generalises.

---

## The eight steps

⚠ **Read [`GUARDS.md`](GUARDS.md) before step 00.** It is the eleven
measurement rules every book carries, numbered C1–C11, plus three unnumbered
ones. Each step below repeats the handful that bite hardest there; the file is
the whole list, and `templates/01` and `02` name the guards inline in the SQL so
a query can be checked against it line by line.

⚠ **A guard is not an exclusion.** Guards travel with the *feed* and are never
optional. Exclusions are decisions about what belongs in *one priced book*, they
travel with the *deal*, and they ship in `templates/07_exclusions.sql`. Applying
one book's exclusions to another book's scope silently deletes real loans.

### 1 · Scope — `00_scope.sql`

One row per batch, from the newest PAM delivery, for one country and seller.
Plus: which Intrum instance holds them, and does any batch reference appear in
more than one.

**Five PAM guards, all of them load-bearing:**

⚠ Full list, with what each costs to skip: [`GUARDS.md`](GUARDS.md).

| Guard | Without it |
|---|---|
| Newest file only, matching `'%/pam.pam.pam.2%'` | the table holds every monthly delivery — an unfiltered sum is N× too high, and mis-loaded `pam_perimeter` files win a plain `max(_file_path)` |
| `PMODE_NAME = 'Real'` | `'Adjust'` rows are internal accounting batches |
| `coalesce(is_ownership_change,0) = 0` | repeats a batch-month for a legal buyer transfer |
| Actual months only: `period_start_date < extraction month` | plan months run out past 2040 and a "last collection month" silently returns a forecast |
| `upper(seller_name)` | seller names are inconsistently cased and whole portfolios go missing |

`PERIOD_START_DATE` is VARCHAR and holds the **first day of the reporting
month**. Cast it.

**Exit criteria:** you can name every batch, its capex month, its acquisition
principal, and its lifetime collections — and the batch count matches what the
deal documents say. A batch in PAM that the deal does not mention, or vice
versa, is a finding to raise now, not a row to quietly drop.

### 2 · Accounts — `01_accounts.sql`

One row per loan: batch, loan id, registration date, registration capital and
interest, borrower classification.

**Four CAT guards:**

⚠ Full list, with what each costs to skip: [`GUARDS.md`](GUARDS.md).

| Guard | Without it |
|---|---|
| `CASES` is a **change-history feed** — dedupe to the latest version per `CASE_ID` | balances multiply (147× on Portugal) |
| **Batch filter before the `qualify`** | a loan whose newest version left the scope vanishes instead of keeping its last in-scope batch |
| Pin `_file_path` to one instance, as a **literal prefix with no leading `%`** | wrong loans, and no micro-partition pruning — the difference between 30 seconds and a timeout |
| Read **all** extracts of that instance | extracts are not complete re-deliveries of each other; pinning the newest lost 4.6% of money on Portugal |

**On borrower type**, which is where the judgement lives: expect to find that the
feed has no product, size or segment column at all, and that the only signal is
an undocumented per-debtor code. Before you build a segmentation on it:

1. Count how many loans carry **both** codes. On Portugal it was 88% of the SME
   balance — the split was a tie-break decision, not a reading of the data.
2. Try to corroborate it (name forms, VAT, industry codes). Record that you
   tried and what it returned, even when the answer is "every name field is
   empty".
3. ⚠⚠ **Do not put the rule in `01_accounts.sql`** (changed 2026-10-02). The
   template ships the FACTS — `loan_holder_corporate_flag` and
   `loan_holder_individual_flag`, **both of which can be true on one loan** —
   and no segment. What counts as a pricing segment changes with every deal,
   and `SME` is a *size* class this feed cannot answer: no income, turnover,
   headcount, VAT or company-number column is populated. Apply the deal's rule
   downstream, state it **and what the opposite rule would have produced**.
   Portfolio totals are usually robust to this; segment-differentiated pricing
   never is. `templates/05` block D shows you the balance a company-wins rule
   would move, as a what-if.
4. `DEBTORS` is one-to-many *and* a change feed. Group it to one row per loan
   before joining, and **do not use `row_number()`** if update timestamps tie —
   keep every row at the latest version and OR the flags, or your segmentation
   flips between runs.

**Exit criteria:** row count = distinct loan count; capital + interest = balance
exactly (assert it with `convert=False`); and the roll-forward closes —
opening capital ≈ remaining capital + lifetime collections, within a few percent.
A wrong opening balance would not close.

### 3 · Payments — `02_payments.sql`

One row per loan per payment date.

**Four more guards, plus the date rule:**

⚠ Full list, with what each costs to skip: [`GUARDS.md`](GUARDS.md).

| Guard | Without it |
|---|---|
| `TRANSACTIONS` is a change-history feed — dedupe on `(case_id, orig_tr_id \|\| coalesce(pkey,''))`, latest update wins | payments multiply (10.8× on Portugal) |
| Payments only: `payment_cost_ind = 'P'` and `booking_ind <> 'Y'` | costs and fees land in the collections total |
| `AMOUNT` is stored **sign-flipped** — read `-amount` | right magnitude, wrong sign |
| `amount is not null` | amount-less rows pass the servicer's own payment filter and invent zero-value payment dates |

⚠ **Recover the payment date across every version of the transaction**, not from
the winning version alone. On Portugal that rescued EUR 53m — 36.5% of the money
was undated before recovery, 3.4% after.

⚠ **Never bound the payment date on a deduped read.** Sentinel dates (1900, 2099)
live on superseded versions and non-payment rows and never survive the dedupe.
Bounding instead of recovering silently lost EUR 5.45m on the first attempt.

⚠ **Keep what has no date in any version.** Flag it, do not drop it. It is real
money that simply cannot enter a time series — and the moment someone filters on
the date to build a curve, the flag is what stops them quoting the remainder as
the book's collections.

⚠ **Do not return a payment count** unless you have checked the amount-less
rows. Money is unaffected by them; counts are not.

**Exit criteria:** the two deliverables cover the **same population**. Whatever
loans `accounts` drops as unclassifiable, `payments` drops too, and the notebook
asserts `set(payments.LOAN_ID) <= set(accounts.LOAN_ID)`. They will drift
otherwise — that assert exists because they did.

### 4 · Reconcile CAT to PAM — `03_reconcile_cat_pam.sql`

**This is the step that makes the dataset defensible, and it is the one that is
usually skipped.**

A whole-against-whole ratio is worthless. On Portugal it read 99.88% — which
looked excellent and was a coincidence, two large opposite errors cancelling.
Cut to the same period it was 100.92%.

**Break out every difference as its own column, and know which way each pushes:**

| Difference | Direction |
|---|---|
| PAM's lifetime starts at capex; CAT carries earlier servicer history | CAT **over** |
| The CAT extract is behind PAM's newest actuals month | CAT **under** |
| CAT payments with no date at all — cannot be placed in a month | CAT **under**, in every period |
| PAM restates past months as late cash lands | either way, small |

**Close the window at the last COMPLETE month in the CAT feed**, on both sides —
derive it, never hard-code it. A partial final month drags the match down for no
reason.

**Quote the residual, not the match ratio.** The residual credits back the
undated cash; the ratio cannot. On Portugal the worst-looking batch by ratio
(0.895) had the **smallest** residual (−0.089%).

**Run the cut twice**, once from the batch capex month and once from each case's
own registration date. They answer different questions — "what could PAM possibly
report" vs "what came in while the servicer held the case" — and on Portugal the
second one resolved a batch the first could not.

⚠⚠ **Ask how much work the undated cash is doing.** Crediting it is legitimate —
it is real money the servicer cannot place in a month — but it closes a gap
**without explaining it**. `UNDATED_SHARE_OF_GAP` is undated cash over the raw
shortfall before crediting. **Above 0.5 the residual passes mostly on cash nobody
can date**, and the batch is `RECONCILES WITH RESERVATION`, not `RECONCILES`.

That is not a failure and it is not a reason to drop the batch. It is a batch
whose closure rests on an assumption, and it must be **counted separately from
the clean ones** in any statement of how far a book got. A reconciliation where
most batches close on undated cash is weaker than its pass rate suggests.

⚠ Report undated cash **three ways, every time**: as EUR, as a share of the
book's matched total, and as a share of the gap it closes. The third is the one
that tells you whether the reconciliation means anything. Portugal ran at 3.4%
of the money after date recovery; on a book where it runs much higher than that,
say so before quoting a pass rate.

**Exit criteria:** every batch is either within ~1% after crediting undated cash,
or it is on the escalation list with a named hypothesis. "Unexplained" is an
acceptable answer; "unexamined" is not. **State how many of the passes carry a
reservation.**

### 5 · Exceptions per batch — `04_batch_exceptions.sql`

One row per batch, one column per known problem, so a reader can see at a glance
which issues touch which book and by how much. Built for escalation.

Look for, at minimum:

| Flag | What it means |
|---|---|
| **No loan-level money** | PAM reports collections for a batch CAT has no loans or no payments for |
| **Batch dispute** | the loans exist but their newest version names a different in-scope batch |
| **Wiped reference** | newest version has a null batch ref and blank seller — money riding on a workaround |
| **Sold on** | newest version names a batch belonging to another entity |
| **Undated cash** | per batch, both EUR and loans touched |
| **Pre-capex cash** | CAT payments PAM structurally cannot hold |
| **Amount-less rows** | pass the payment filter with no amount |
| **Feed lag** | PAM months the CAT extract cannot see |

⚠ **Keep every batch in the output, including those with nothing in CAT.** A
batch with no loan-level money is a *finding*, not a row to drop. Portugal had
three, worth EUR 1,130,420.97 — and two of them turned out to be acquisition
principal booked into the collections column, not cash at all. The tell was that
`COLLTOTAL` equalled `ACQUISITIONPRINCIPAL` to the cent, posted once, in the
capex month, while ~2,500 collecting months across the other batches never did
that once.

⚠ **Build this independently of step 4 if you can.** Portugal's two queries were
written separately and reproduced each other's fourteen-batch breakdown **to the
cent**. That agreement is the reason to trust either.

**Exit criteria:** every exception has a EUR figure and a named owner — Intrum,
our data team, or accepted-and-documented.

### 6 · Borrower / segment probe — `05_borrower_type_probe.sql`

Run this **before** committing to a segmentation, not after. It is a report, not
a deliverable: what the raw feed says, what the warehouse maps it to, and how far
apart they are.

⚠ **A warehouse mapping is not a second opinion.** If `LEGAL_EBA_TYPE` is a
one-to-one relabel of the same raw code, it agrees by construction and
corroborates nothing.

⚠ **Check the warehouse's borrower key before trusting its classification.** On
Intrum it is `source_system_code || '-' || debtor_row_number` — with no case in
the key, and one row number shared by 296,041 cases. The resulting loss is
**directional**: it drops companies, so the warehouse understates the corporate
segment by construction. That is a report for the data team, never a dbt edit
from this workspace.

**Exit criteria:** you can state the segmentation rule, the population it was
measured on, what the opposite rule would give, and which two or three batches
the difference actually lives in.

### 7 · Feed lag — `06_feed_lag.sql`

How far behind PAM the loan-level feed runs, for **every** Intrum instance — not
just yours. Cheap: it reads transaction metadata with no case join.

⚠ **A lagging system is usually a decommissioned one.** Intrum retires platforms
and moves books to a successor; the retired instance keeps its rows in RAW
forever, so read on its own it looks like a catastrophe. On Portugal, 1062/SE
looked 126 months and EUR 1.51bn behind — and 348 of its 352 batches were also
served by a current instance. Use *batches stranded*, never "collections not yet
delivered" alone.

⚠ **Measure the last payment date, not the extract timestamp.** A filename says
when the file was cut, not how far the data inside reaches.

**Exit criteria:** you can say, in one sentence, how current the loan-level
dataset is and what that costs — as a share of lifetime *and* as a share of the
last twelve months. Those two numbers are usually wildly different (1.20% vs 54%
on Portugal) and the second one is the one that matters for anything recent.

---

### 8 · Exclusions — `07_exclusions.sql`

One row per (seller, reason), covering **every** batch the scope names before
any filter, so the rows sum back to the starting population.

⚠⚠ **A reader cannot see what is missing from a CSV.** Steps 1-7 decide what
the book contains; this step is the only one that records what it does *not*,
and it is the only artefact a recipient can check that against. Someone opens
`accounts.csv`, recognises the seller, and reasonably assumes it is that
seller's whole book. On Project Sea that assumption was wrong by **141 batches
and 44,809 loans** — 84% of the batch count. Nothing else in the deliverable
would have told them.

⚠ **Ship it with the data.** It is part of the deliverable, not a diagnostic.
A benchmark handed over without it is a number with no stated scope.

⚠ **This file inverts how the others work.** Every other query APPLIES the
filters; this one applies them as **labels**, so nothing leaves the table
without saying why. Each batch takes the FIRST reason that excludes it, so it
is counted exactly once — which is what makes the rows reconcile.

⚠ **Zero rows are the point, not padding.** A filter that was checked and
caught nothing tells the reader the question was asked. Count them from the
data; never hard-code a zero, or a future delivery that does trip the filter
will silently contradict a literal. State the gates you declined to apply too —
a gate the method offers and this book refused is invisible everywhere else.

⚠ **It is a rollup, not a second opinion.** Step 4's ledger is the per-batch
detail and it is authoritative. If the two disagree, the ledger is right and
this is stale.

⚠ **The money column is PAM's, not yours.** Lifetime actuals to PAM's newest
month, while `payments.csv` stops at the CAT extract — months earlier. Project
Sea: 282,841,324.30 here against 276,731,289.53 there. Say so, or they will be
read as the same quantity.

**Exit criteria:** the rows reconcile to the starting population, the in-scope
loan count equals `accounts.csv` exactly, and every filter the book applied —
plus every one it declined — has a row stating its size in batches, loans and
euros.

---

## Delivering it

A notebook that loads both files, asserts, and exports. The asserts are not
decoration — each one in the Portugal notebook failed at least once during
development:

```python
assert accounts_df["LOAN_ID"].is_unique
assert (accounts_df["REGISTRATION_CAPITAL"] + accounts_df["REGISTRATION_INTEREST"]
        == accounts_df["REGISTRATION_BALANCE"]).all()
assert set(payments_df["LOAN_ID"]) <= set(accounts_df["LOAN_ID"])
```

Print the expected counts and totals beside the actual ones, so a rerun that
drifts is obvious rather than plausible.

Use `convert=False`. It keeps Snowflake `Decimal`s, and the capital + interest
assert fails on float64 rounding. Coerce date columns back with `pd.to_datetime`
afterwards — `convert=False` leaves them as Python `date` objects, which pandas
cannot resample.

---

## Writing the queries

Conventions this folder follows, all from `~/data-warehouse/CLAUDE.md` and the
Portugal build:

- **Session variables, never Python braces.** `set country = 'PT';` and
  `$country`. Both `mise run sql -- <file> country=ES` and
  `datalake.q("...", country="ES")` rewrite them.
- **Nothing may follow the final semicolon**, not even a comment — `run_sql.py`
  splits on `;` and a trailing comment-only chunk fails.
- **`_file_path` patterns must be literal prefixes.** A leading `%` destroys
  micro-partition pruning. This is the single biggest performance lever in the
  whole feed: one early query got no pruning at all and read 673 GiB, 96% of the
  table.
- **Filter to the scope before any window function runs.**
- **Collapse PAM to one row per batch before it joins to anything.** It is batch
  × month × delivery; joined raw it multiplies every case by thousands.
- **Keep headers short.** State the grain, the runtime, the guards by name, and
  point at `METHOD.md` or `FINDINGS.md` for the reasoning. The long-form
  explanation belongs in markdown an agent can read, not in a comment block a
  human has to scroll past to reach the SQL.
- **Money and ratios to up to 5 decimals.** Never `round()` a DataFrame.
- **Guard visibly.** A filter that works around a data-quality problem gets a
  comment naming the problem. A silent filter becomes folklore nobody can audit.

---

## What will bite you, ranked

From the Portugal build, in the order the mistakes actually happened:

1. **Unfiltered PAM** — N whole deliveries summed together.
2. **Undeduped change feeds** — 147× on cases, 10.8× on transactions.
3. **Wildcard-prefixed `_file_path`** — no pruning, query cancelled.
4. **Dedupe before filter instead of filter before dedupe** — 2,313 loans and EUR
   6.86m gone silently.
5. **Bounding the payment date instead of recovering it** — EUR 5.45m gone.
6. **Quoting a whole-against-whole ratio** — a meaningless number that looks like
   a triumph.
7. **Joining `accounts` to `payments` without aggregating first** — balances
   multiply *and* an inner join drops every loan that never paid.
8. **Believing a warehouse column that turns out to be derived** — the default
   date was 100% back-fill from invoice due dates, with a country-specific rule.
9. **`row_number()` over tied timestamps** — a segmentation that changes between
   runs.
10. **Reading collections from the conformed warehouse** — 42% of the money, with
    no error.

---

## Files here

| File | What it is |
|---|---|
| `METHOD.md` | this file — the eight-step process |
| `GUARDS.md` | the eleven measurement rules every book carries, and why each is not optional |
| `templates/00_scope.sql` | batches in scope + which Intrum instance holds them |
| `templates/01_accounts.sql` | one row per loan |
| `templates/02_payments.sql` | one row per loan per payment date |
| `templates/03_reconcile_cat_pam.sql` | the like-for-like reconciliation, differences broken out |
| `templates/04_batch_exceptions.sql` | one row per batch, one column per known problem |
| `templates/05_borrower_type_probe.sql` | what the feed says about borrower type vs what PROD maps it to |
| `templates/06_feed_lag.sql` | loan-level feed currency, every Intrum instance |
| `templates/07_exclusions.sql` | what the scope filters removed and why — ships WITH the data |

**This folder is book-agnostic on purpose.** Nothing country-specific lives
here. What is elsewhere:

| Want | Go to |
|---|---|
| A worked example, in full | `../project-elsa-benchmark/FINDINGS.md` (Millennium), `../project-sea-benchmark/` (WiZink + Barclaycard) |
| Who sold what in a country, before picking a book | `../portugal/` — the seller census and its two cuts |
| The Italian books | `../italy/` — legal phases, and settlement rates by age |
| The investigation trail behind Elsa | `../.archive/2026-10-02-benchmark-investigation-trail/` — the working, not the answer |
