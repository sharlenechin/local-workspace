# NPL_COMMON as a general layer — what to change, and why

**Written 2026-10-02 in `local-workspace`. Nothing here has been changed in
`brocc-data`.** Every file path below is under `brocc-data/transformation/dbt/`,
and every claim was read out of that repo rather than inferred. This is a
proposal for the data team, not a change.

---

## The reframing

The first version of this document asked: *what does `NPL_COMMON` need so that
an underwriting mart and a servicing mart can be built?* That is the wrong
question, and the answer it produces is a layer shaped by whichever two
consumers happened to ask first.

**The right question is: what does `NPL_COMMON` need in order to be correct and
unambiguous for any consumer?** Marts are then where a use case shapes the data,
not where it recovers from the layer below.

That is not a bigger change. Every fix in this document is the same fix either
way. What changes is **how you judge a proposal** — and two of them fail the
stricter test:

| | Mart-driven question | General-layer question |
|---|---|---|
| A column two teams read differently | Pick one meaning; the other mart adapts | **Name both. Neither meaning is default** |
| A row only one team wants | Filter it out; that team re-reads raw | **Keep it, flag it. The mart filters** |
| A key that is ambiguous | Document the trap | **Remove the trap** |

### ⚠⚠ THE RULE THAT MATTERS MOST: A CONFORMED LAYER MUST NOT FILTER

A filter in `NPL_COMMON` is a **use-case decision made on everyone's behalf**,
and it is invisible to the consumer who needed the rows. Four already exist, and
each one silently decides something:

| Filter | Where | Who it decides for |
|---|---|---|
| Payments before the case SCD opens | `int_npl_case_collection_conformed` | Servicing does not miss them. **Underwriting loses 42–58% of its history** |
| Payments with no date | same join, via `>=` on a NULL | Anyone measuring lifetime cash. **Zero undated rows survive, of 134m** |
| `is_ownership_change = false` | `int_npl_portfolio_monthly_intrum:44` | Anyone asking when a batch changed hands |
| `case_id not like '%-%'` | `int_npl_case_intrum` | Every consumer, on every source, though scoped to 2080 in its comment |

**The fix is the same in each case: keep the row, add a flag, let the mart
choose.** That is the one architectural change here; everything else is naming.

---

## The ambiguity register

A name in a conformed layer has to answer **whose, as at when, in what
currency** without the reader knowing which team wrote it. These are the terms
that currently fail that test — all of them found by using the warehouse, not by
reading it.

| # | Term today | Why it is ambiguous | What it should be |
|---|---|---|---|
| A1 | `seller` | **Two different companies.** PAM's `SELLER_NAME` is the originating bank; Atlas's `DIM_DEAL.SELLER_NAME` is Intrum, because Intrum is who Brocc bought from. Both are correct. | `originator_name` and `vendor_name`. **Never a bare `seller`** |
| A2 | `capex_date` / `legacy_capex_date` | Two different purchases. "Legacy" reads as *superseded*, not *a different buyer* | `servicer_acquisition_date`, `brocc_acquisition_date` |
| A3 | `collections` | Loan-level (CAT) or portfolio-level (PAM); gross or net; remitted or not. Servicing means *this month, as reported*; underwriting means *lifetime, per loan* | Name the source and the basis in the column |
| A4 | balances | `original_principal`, `registration_balance`, GBV, remaining — each a different **reference moment** | Encode the moment: `principal_at_cutoff`, `_at_default`, `_at_origination`, `_at_registration` |
| A5 | `default_date` | Seller's and servicer's disagree by a mean of 1,273.7 days on one book | Keep both, named by source. Do not pick |
| A6 | `status_code` | Conflates open/closed, legal phase, and insolvency. Servicing wants phase; underwriting wants closed-ness | Separate columns, one concept each |
| A7 | `case_sk` | A **version**, not a loan — 154m versions for 22.5m loans. Facts carry only this | Carry `case_bk` beside every `case_sk` |
| A8 | `FCT_CASE_SNAPSHOT_DAILY` | **Month-end grain.** The name is wrong, and it is what people size queries on | Rename, or fix the description |
| A9 | money columns | `currency_id` present, no converted measure. A cross-currency `sum()` compiles and is wrong | A converted measure, or a test that forbids the sum |
| A10 | `deal_type` | `OO` / `DRG`, meaning unconfirmed and pending Intrum | Carry it, label it unconfirmed, do not infer "one-off" |

**The precedent already exists and is not ours.** The asset-index target schema
(v4.1, anchored on the EBA NPL Transaction Templates) solves A4 exactly this
way — the reference moment is in the field name, and every field declares a
`Source` (`tape` / `seller` / `internal` / `derived`) and a `Stage`
(`pre_acquisition` / `at_acquisition` / `post_acquisition`). **Adopting that
convention in `NPL_COMMON` costs nothing and makes half this register
unnecessary**, because a reader can see whose a number is and when it was true.

---

## The original question, and the answer that still holds

To build **benchmark accounts** (one row per loan) and **benchmark payments**
(one row per loan per payment date) at underwriting grade, do we rebuild
`NPL_COMMON`, or make small edits to it and put a `mart_underwriting` layer on
top?

## The answer

**Small edits, then a mart.** Not a rebuild.

Five things are missing. **Four of the five are columns that already exist
upstream and are dropped by a single `select`**; one is a join condition with a
fix pattern already written elsewhere in the same repo. None of them is a grain
change, none needs a new fact table, and none invalidates the existing
dimensional model.

That is the whole finding: the warehouse is not wrong, it is **narrow**. It was
built to answer "how is the book performing this month", and underwriting asks
"what did we buy and what has it paid since" — which needs four more columns and
one wider join, not a different model.

---

## The five gaps

### 1 · The originator is dropped one model before the mart

Brocc bought these loans from Intrum, who bought them from WiZink, Barclaycard,
Millennium, Oney and Cofidis. **The warehouse records the seller as Intrum**, so
no originator can be selected — which is why every benchmark so far has gone to
the raw feed.

The column is not missing. It survives the whole pipeline and dies in the mart:

```
base_intrum_pam__pam.sql:30        source.seller_name as legal_seller_name
  → stg_intrum_pam__portfolio_collections.sql:29
  → int_npl_portfolio_base_intrum.sql
  → int_npl_batch_intrum.sql:24
  → int_npl_batch_conformed.sql:92   combined.legal_seller_name
  → dim_npl_batch.sql                ✗ DROPPED
```

`dim_npl_batch.sql` is a five-column select:

```sql
select batch_sk, batch_bk, legacy_capex_date, legacy_capex_amount, legacy_principal
from batch
```

`legal_seller_name`, `legal_buyer_name`, `legal_buyer_code`,
`legal_buyer_country_code`, `legal_buyer_dk`, `country_id` and `portfolio_bk`
are all sitting in the upstream model, unaltered.

⚠ **This is under-built against its own signed-off spec.**
`logical-models/case-level-v1.0.sql` specifies `DIM_BATCH.LEGAL_SELLER_NAME`
with the comment `Source: RAW.INTRUM_PAM.EXT_PAM.SELLER_NAME`, and also calls
for `CAPEX_DATE`, `CAPEX_AMOUNT`, `CURRENCY_ID`, `LEGAL_BUYER_*` and `EIR` on
the same dimension. So this is drift from an agreed design, not a new ask.

⚠ **Do not confuse it with `DIM_DEAL.SELLER_NAME`**, which comes from Atlas and
is documented as *"the company the portfolios in this deal were acquired from"* —
that is Intrum, correctly. The two sellers are different facts and both are
wanted.

**Fix:** widen the select in `dim_npl_batch.sql`. No upstream change.

**Loan-grain originator** is a second, larger ask: `cases.portfolio_sellers_name`,
`seller_id`, `client_name`, `int_creditor_id` are all declared in
`stg/intrum_cat/source.yml` and none is selected by `stg_intrum_cat__cases.sql`.
Batch-grain is enough for a benchmark; loan-grain would be needed only if one
batch can hold two originators, which has not been measured.

---

### 2 · No registration-era amounts reach the warehouse

`DIM_CASE.ORIGINAL_PRINCIPAL` is **not** the loan's balance at registration. It
is `CASES.PRINCIPAL_AT_CUTOFF` — the principal at the cut-off date of one
particular sale — renamed in staging:

```
stg_intrum_cat__cases.sql:27   principal_at_cutoff::decimal(18,2) as original_principal
```

The repo already knows it is sparse. `logical-models/case-level-v1.0.sql:139`:

> `Source: RAW.INTRUM_CAT.CASES.PRINCIPAL_AT_CUTOFF` · `Note: Might not be 100% palulated`

So the ~14.5% fill rate is the documented behaviour of the chosen column, not a
load bug. **The right columns exist and are never read:**

| Raw column | Declared in `source.yml` | Selected by any model |
|---|---|---|
| `CASES.ORIGINAL_CAPITAL` | yes | **no** |
| `CASES.ORIGINAL_INTEREST` | yes | **no** |
| `interest_at_cutoff`, `face_value_at_cutoff`, `original_undue_capital`, `accrued_interest_reg_date`, `purchase_price`, `interest_rate` | yes | **no** |

⚠ **There is no interest-at-registration anywhere in the warehouse.** The
servicer data contract macro `generic_staging_cases.sql:29` *does* define
`original_interest`, and the matching `generic_intermediate_cases.sql` drops it
— so the contract promises a column the next layer discards. `original_fees`
goes the same way.

This is why every benchmark computes `registration_balance` itself:
`ORIGINAL_CAPITAL + ORIGINAL_INTEREST`, measured at 88.8–100% of what PAM says
Intrum paid depending on the book.

**Fix:** add both columns to `stg_intrum_cat__cases.sql`, carry through
`int_npl_case_*`, surface on `dim_npl_case`. Also fix
`generic_intermediate_cases.sql` so the contract's `original_interest` lands.

---

### 3 · Collections truncate at the left edge of the case SCD

**This is the expensive one** — 42–58% of collections on Portugal books.

`int_npl_case_collection_conformed.sql`:

```sql
from combined
inner join cases
    on combined.case_dk = cases.case_dk
    and combined.transaction_date >= cases.valid_from
    and (combined.transaction_date < cases.valid_to or cases.valid_to is null)
```

`cases.valid_from` comes from the `scd_table` macro applied over
`record_update_date`, so **`min(valid_from)` is the first CAT snapshot Brocc
ever received for that case**. The right edge is open (`9999-12-31`), so nothing
is lost there. The left edge is hard:

> Every payment dated before Brocc's first CAT delivery of that case is silently
> dropped by the inner join.

#### ⚠⚠ And the backdate alone does not finish the job

The same `inner join` has a second effect nobody has costed: **a NULL
`transaction_date` fails `>= valid_from`**, so undated payments are dropped
too — and they are dropped whatever `valid_from` becomes. Backdating fixes the
left edge; it does not fix the comparison.

Measured against PROD on **2026-10-02**: `FCT_CASE_COLLECTION` carries **zero**
rows with a null `COLLECTION_DATE`, across all **134,472,689**. There is no
undated cash in the warehouse at all. The raw feed has plenty — on Project
Elsa, *after* recovering dates across record versions, **EUR 5,587,796.29
remained undated (2.01921%, 6,233 loans)**, which the benchmark keeps flagged
rather than dropped.

This matters because **"flag, never filter" is already stated below as a
requirement of the payments mart** — and as the pipeline stands that
requirement cannot be met from `NPL_COMMON`, because the money is gone three
models upstream. It needs its own change beside the backdate: either make the
predicate null-safe, or carry undated rows through on a separate branch with a
flag. ⚠ Decide which, because it changes published collections totals a second
time and should be reconciled in the same pass as the backdate, not after it.

⚠ **Size of the surviving gap, measured 2026-10-02** — the loan-level fact
against the servicer's own report, both from PROD:

| Portfolio | PAM reported | In `FCT_CASE_COLLECTION` | Survives |
|---|---|---|---|
| `HEI-PT25001-U02/2512` | 491,347,313.75 | 327,991,889.83 | **66.75%** |
| `HEI-PT25001-S01/2512` | 10,964,981.23 | 140,828.65 | **1.28%** |

That is a different cut from the 42–58% above, which was batch-scoped against
raw PAM. Same cause, different denominator — quote whichever matches the
question, and say which.

The CAT transactions feed carries each case's **whole** payment history, back to
Intrum's registration. Intrum had been collecting for years before Brocc bought.
The overlap is the only part that survives.

⚠⚠ **The fix already exists in the repo and was never applied to Intrum.**
`generic_intermediate_cases.sql` carries exactly this correction for contract
servicers:

> *"A case has been active since its origination_date, so the earliest SCD
> record for each case is valid from origination_date rather than from its first
> record_update_date."*

`int_npl_case_intrum.sql` has **no equivalent**. Intrum is the largest source and
the one with the deepest pre-Brocc history, and it is the one source that does
not get the backdate.

**Fix:** backdate the first SCD record for Intrum cases, as the macro already
does for contract servicers. Note the benchmark work suggests backdating to
`registration_date` rather than `origination_date` for this source, since
registration is when Intrum opened the case.

⚠ **Two further filters drop cases entirely**, and both should be measured
before anyone treats a case count as complete:

- `int_npl_case_conformed.sql` — `inner join batch on ... batch_bk`. A case whose
  batch is not in `int_npl_batch_conformed` disappears, case *and* collections.
  The repo documents the failure mode: `data/npl/README.md` describes the test
  `assert_owned_intrum_batches_are_mapped`, which **warns** rather than errors.
- `int_npl_case_intrum.sql` — `case_id not like '%-%'` is applied
  **unconditionally to every source system**, though the comment above it scopes
  the rule to system 2080. Any Intrum instance issuing hyphenated case ids loses
  those loans. Worth measuring on 4050 before writing it up.

---

### 4 · The secondary transaction is not modelled — but it is nearly there

**This was the hypothesis, and it is right: there is no concept of a secondary
transaction.** Searching the NPL models for `secondary`, `resale`, `originator`
or `acquisition_date` returns nothing.

But the fix is smaller than it sounds, because **both dates already exist**:

| Date | Model | Source | Which event |
|---|---|---|---|
| `dim_npl_portfolio.capex_date` | `int_npl_portfolio_atlas` | Atlas `batch_segment.capex_date` | **Intrum → Brocc** |
| `dim_npl_batch.legacy_capex_date` | `int_npl_batch_intrum` ← PAM `capex_date_m` | PAM | **originator → Intrum** |

So the warehouse already carries both halves of the chain of title. What it
lacks is **any statement of which is which**. `legacy_capex_date` is documented
only as *"Legacy capital expenditure date (from historical records)"* — "legacy"
reads as *old and superseded*, not *a different purchase by a different buyer*.

⚠ **They sit on different dimensions at different grains** (batch vs portfolio),
joined only through `int_npl_batch_portfolio_map`, and a portfolio can hold many
batches. The only model where both appear on one row is
`mart_npl_flash_report.sql`, where they are still undocumented as two events.

⚠ **There is no loan-level acquisition date of either kind.** `DIM_CASE` has
`origination_date` (the bank's), `default_date` and `registration_date` (when
Intrum opened the case — a proxy for originator→Intrum, by accident rather than
design). Nothing joins a case to a capex date.

⚠ **The two raw signals of a change of title are both unused:**
- `cases.ownership_transfer_date` — declared in `source.yml`, selected by nothing.
  This is the one raw column that expresses a per-loan ownership change.
- `pam.is_ownership_change` — used **only to delete rows**, in
  `int_npl_portfolio_monthly_intrum.sql:44` and the forecast equivalent:
  `-- Remove ownership change records ... and is_ownership_change = false`.
  Its own `source.yml` says *"If a batch has changed ownership then ? else null"*
  — a question mark in the signed-off source documentation, for the field that
  signals a change of title.

**So: a column, not a grain change.** A loan belongs to one batch; a batch maps
to one portfolio. Both dates hang off dimensions that already exist, so no new
fact table and no regrain is required. The work is:

1. **Rename and document.** `legacy_capex_date` → something that says what it is
   (`servicer_acquisition_date`), `capex_date` → `brocc_acquisition_date`. Name
   the two parties in the column descriptions.
2. **Surface both at loan grain**, so an underwriting row can carry
   "when the originator sold to Intrum" and "when Intrum sold to Brocc" side by
   side without the consumer rebuilding the batch→portfolio map.
3. **Read `ownership_transfer_date`** into staging, and measure it before relying
   on it — it may be the per-loan version of the same fact.

⚠ What would force a genuine regrain is a loan that changed hands **more than
twice**, or a batch split across two Brocc purchases. Neither has been measured.
Until one is, two dated columns are sufficient and a transaction fact table is
over-engineering.

---

### 5 · One-off vs forward flow cannot be expressed at all

PAM's `DEAL_TYPE_DESC` separates a **one-off** spot purchase from **forward
flow**, where newly defaulted accounts arrive every month under a standing
agreement. Measured on Portugal 2026-10-01: 198 of 266 batches are `Ongoing`,
concentrated in 4 of 30 sellers.

This is not a detail. A forward-flow batch has no fixed population, no single
capex event and no cohort, so it cannot carry a vintage curve or a stable
denominator. **Project Sea excludes 141 of 167 batches on this column alone** —
84% of the batch count.

`DEAL_TYPE_DESC` is declared in `stg/intrum_pam/source.yml` and **selected by no
model**. So is `PORTFOLIOTYPE` (performing vs non-performing). Both were checked
by grep across `models/` and `macros/`: zero hits outside `source.yml`.

**Fix:** add both to the PAM base model and carry to `dim_npl_batch`. Without
this, no mart built on `NPL_COMMON` can reproduce a benchmark scope, and
underwriting silently prices forward flow as if it were a spot purchase.

---

## What to build, once those five land

### In `NPL_COMMON` — edits only

| # | File | Change | Size |
|---|---|---|---|
| 1 | `dim_npl_batch.sql` | widen the select: `legal_seller_name`, `legal_buyer_*`, `country_id`, `portfolio_bk` | one select |
| 2 | `stg_intrum_cat__cases.sql` + `int_npl_case_*` + `dim_npl_case.sql` | carry `original_capital`, `original_interest` | one column each layer |
| 3 | `int_npl_case_intrum.sql` | backdate first SCD record, as `generic_intermediate_cases` already does | one CTE |
| 4 | `dim_npl_batch.sql` / `dim_npl_portfolio.sql` | rename + document the two capex dates; add `ownership_transfer_date` to staging | rename + one column |
| 5 | `base_intrum_pam__pam.sql` → `dim_npl_batch.sql` | carry `deal_type_desc`, `portfoliotype` | two columns |

**None of these changes a grain, drops a column, or alters an existing number**
— except #3, which *increases* collections by design. #3 is therefore the only
one needing a before/after reconciliation and a note to every consumer of
`FCT_CASE_COLLECTION`.

### In `mart_underwriting` — two new models

Both at the benchmark grains, both built on `NPL_COMMON`, neither touching raw:

```
mart_npl_underwriting_accounts    one row per loan
    originator, both acquisition dates, deal type, registration capital +
    interest + balance, debt age with its coverage, borrower type

mart_npl_underwriting_payments    one row per loan per payment date
    the full history, with pre-registration and undated cash FLAGGED, not filtered
```

⚠ **The guards stay, but they move.** The benchmark queries carry C1/C4/C5/C8/C9
because they read raw. Staging already handles most of them — the dedupe, the
instance pin, the container-case drop. What the mart must still carry, as
**tests** rather than predicates:

- grain assertions (`dbt_utils.unique_combination_of_columns`) — the house
  pattern, and effectively mandatory in this repo
- accounts ⊇ payments on the loan key
- `capital + interest = balance`
- a coverage test on debt age, since unusable default dates must be NULL and
  counted, never defaulted to zero

⚠ **Flag, never filter.** Pre-registration payments (1.90546% of Project Sea's
collections) and undated cash (2.01921%) are real money. The benchmark work
measured that bounding payment dates only ever deletes money; the mart must
inherit that rule.

### Where it goes, and what the repo will say about it

`transformation/dbt/AGENTS.md` enumerates mart areas as `marts/common` and
`marts/npl_common` only. A new `marts/underwriting/` needs a `dbt_project.yml`
entry for database, schema, tags and owner — a deliberate decision, not a
drop-in.

⚠ **Two house rules will be quoted at this in review, and both have an answer:**

- *"Don't create department-specific versions of the same concept."* The answer
  is that these are not a restatement of `dim_npl_case` — they are a different
  grain pairing (loan × payment-date) with registration-era amounts that
  `dim_npl_case` does not and should not carry.
- *"Don't create marts with aggregated time dimensions."* The payments model is
  **not** aggregated — it is one row per payment date, a periodic fact, the same
  shape as `fct_npl_case_snapshot_daily`. Frame it that way.

⚠ **Tag it `npl_case` or it will never build.** Airflow selects by tag —
`dags/dbt_npl_case.py` runs `--select +tag:npl_case`. An untagged mart is
invisible to the scheduler.

---

## Does any of this need a rebuild?

No. Stated plainly for whoever asks:

- **No grain changes.** Every new column hangs off a dimension that exists.
- **No new fact tables in `NPL_COMMON`.** The two new models are marts.
- **No existing number moves**, except collections, which rise — and that is a
  bug fix with a documented cause, not a restatement.
- **Four of the five gaps are a `select` that is too narrow.** The data is
  already loaded, staged and conformed; it is discarded in the last model.

The one thing that would change this conclusion is if a loan can change hands
more than twice, or a batch can be split across two Brocc purchases. **Measure
that before committing to the two-date design.**

---

## Bugs and open items to raise with the data team

Found in `brocc-data` while reading, worth a ticket each. Not fixed here — Rule 3.

| # | Where | What |
|---|---|---|
| 1 | `facts/models.yml` ×15 | `NDP-396` — tests downgraded to `severity: warn` with *"Should be error, investigate nulls"*: null `batch_sk`, `deal_sk`, `segment_sk`, `product_sk` on `FCT_CASE_SNAPSHOT_DAILY`, null forecast values on all three forecast facts |
| 2 | `int_npl_case_intrum.sql` | Greek cases closed for migration are **added back** manually; comment says this must be removed after the Qquant migration *"as we would then include these cases twice"* |
| 3 | `int_npl_case_intrum.sql` | `case_id not like '%-%'` applied to **every** source system though its comment scopes it to 2080 |
| 4 | `data/npl/README.md` | `assert_owned_intrum_batches_are_mapped` **warns**; an unmapped batch silently drops every case under it |
| 5 | `stg/intrum_pam/source.yml:57` | `is_ownership_change` documented as *"If a batch has changed ownership then ? else null"* — a question mark in a signed-off source doc |
| 6 | `stg/intrum_pam/source.yml:19` | PRS `seller_name` *"does not reliably match the Atlas seller"* — the repo acknowledging two different seller concepts without reconciling them |
| 7 | spec drift | `DIM_BATCH` missing `CAPEX_DATE`, `CAPEX_AMOUNT`, `CURRENCY_ID`, `LEGAL_BUYER_*`, `LEGAL_SELLER_NAME`, `EIR`; `FCT_CASE_SNAPSHOT_DAILY` missing `DAYS_PAST_DUE`, `COLLATERAL_SK`; `DIM_CASE` has hardcoded `null as status_description` placeholders — all against `logical-models/case-level-v1.0.sql` |
| 8 | `int_npl_case_collection_cerved.sql:18` | `-- Todo: clarify date collection_type values` |
| 9 | `generic_intermediate_cases.sql` | `original_interest` and `original_fees` are in the staging contract and dropped by the intermediate macro |
| 10 | — | **PAM `AVERAGE_DEBT_AGE` has inconsistent units between batches** (WiZink median 18 / max 72 = months; Barclaycard 2.8, Cofidis 1.67 = years; Oney spans both). Measured here 2026-10-01, not currently loaded — do not load it without a unit rule |

---

## Servicing — same pipeline, second mart

**Not a separate pipeline.** Servicing and underwriting read the same facts and
need the same five fixes; they differ in which grain they stop at, and both
grains already exist in `NPL_COMMON`.

| | Underwriting | Servicing |
|---|---|---|
| Grain | loan · loan × payment date | portfolio × month |
| Already in NPL_COMMON? | `DIM_CASE`, `FCT_CASE_COLLECTION` | `FCT_PORTFOLIO_SNAPSHOT_MONTHLY` |
| Question | what did we buy, what has it paid | how is the book performing this month |

⚠ **Neither needs a new grain.** That is the reason this is one pipeline with
two marts rather than two pipelines.

### Three of the five fixes are already costing servicing money

- **#3 collection truncation.** The servicing build measured **110 of 263
  portfolios that report cash and never a payer**. 96 of those have no loan feed
  at all — a source-coverage problem, not this bug — but **14 have loan
  collections where every one predates the portfolio's capex date**, which is
  the SCD left edge showing up at portfolio grain. `FLAGS.md` §6 puts the
  visible cost at **EUR 137.25m of collections with no loan-level detail behind
  them**, and warns that a portfolio with no feed "shows a 0% paying rate and
  ranks as the worst performer while collecting perfectly well".
- **#5 deal type.** A forward-flow portfolio takes new loans every month, so its
  paying-rate denominator moves for a reason that is not performance. Servicing
  needs the one-off / forward-flow split as much as underwriting does, and for
  the same reason: without it the ratio is not comparable month to month.
- **#4 acquisition dates.** Servicing already bounds collections at capex. It
  does so by reaching for `legacy_capex_date` without anything telling it that
  is Intrum's purchase and not Brocc's.

### Four things servicing needs that underwriting does not

These are the genuinely servicing-specific asks, and none is in `NPL_COMMON`:

1. **A first-class loan-feed coverage flag at portfolio × month.** Absence is
   currently indistinguishable from zero, which is the single most dangerous
   thing on the dashboard — it inverts the performance ranking. There has been
   no stored coverage column since 2026-09-15, so each consumer re-derives it.
   `mart_npl_servicing_agg_cases_monthly` already emits `have_loan_detail_flag`;
   it belongs upstream of the mart, not inside it.
2. **Servicer commission at case grain.** None exists. `FLAGS.md` §10c:
   **16% of the servicer's cut is not itemised.** Portfolio-grain fees are
   allocated from Netsuite SPV grain for non-Intrum servicers, per
   `conformed/README.md` — so the allocation is modelled but the case-level
   truth is not there.
3. **A conformed FX rate at month end.** The flash report collapses currency,
   and a month-key bug in the dashboard's own FX table understated collections
   by 47.3% until it was fixed on 2026-09-29. A display-currency conversion that
   every consumer re-implements is a bug waiting to recur.
4. **Forecast vintage.** The underwriting plan only starts June 2025 — `FLAGS.md`
   §3, marked **blocking** — and the servicer forecast double-counts. Servicing
   needs to say which forecast, as at which date; underwriting needs the curve
   fixed at underwriting and never restated, which
   `fct_npl_portfolio_forecast_underwriting_snapshot_monthly` already does.

⚠ **Restatement is handled and should not be rebuilt.** 95.7% of
portfolio-months get restated, and `fct_npl_portfolio_snapshot_monthly_versioned`
→ `fct_npl_portfolio_snapshot_monthly` already carries the versioning. Servicing
needs to *use* it, not replace it.

### The immediate blocker is not any of this

`mart_npl_servicing_agg_cases_monthly` — the one model dbt has to build for the
dashboard — **exists as `brocc-data` branch `add/servicing-mart` and is not
merged**. Checked against `PROD.INFORMATION_SCHEMA.TABLES` on 2026-10-02: no
table of that name and no `AGG_NPL_*` of any kind. Two of the six Sigma elements
error until it lands.

⚠ **So the ordering is: merge that PR first.** It unblocks the dashboard today
and is independent of the five fixes. The five fixes then improve both marts at
once — they are upstream of the split.

---

## Open questions before anyone writes code

1. **Can a batch hold more than one originator?** Decides whether originator is
   batch-grain (cheap) or loan-grain (reads unused `cases` columns).
2. **Can a loan change hands more than twice?** Decides two columns vs a
   transaction fact.
3. **Backdate to `origination_date` or `registration_date` for Intrum?** The
   existing macro uses origination; the benchmark evidence favours registration,
   because registration is when Intrum opened the case and started collecting.
4. **How much does the hyphen filter cost on instance 4050?** Unmeasured.
5. **Does `ownership_transfer_date` agree with PAM capex?** If it does, loan-level
   acquisition is free.
6. **Can the non-Intrum feeds be landed at loan level at all?** 96 portfolios
   collect EUR 137.25m a year with no loan detail. If the answer is no, servicing
   should say so permanently rather than show a gap. Already on the ask list in
   `work/servicing/FLAGS.md` §12.
7. **Is servicer commission recoverable at case grain**, or is portfolio-grain
   allocation the ceiling? Decides whether 16% of the servicer's cut can ever be
   itemised.
