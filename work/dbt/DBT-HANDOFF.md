# Servicing models — what to hand to the data engineer

What in `work/servicing/` should become a dbt model, what should not,
and the **new models needed** to answer the amicable / legal question.

Conventions below follow `brocc-data/transformation/dbt/AGENTS.md`, read
2026-09-14: four layers — `staging` → `intermediate/npl_common` →
`marts/{common,npl_common}` → `exports`. **Placement is the engineer's call**;
this document is about content and sequencing, not about overriding their
structure.

⚠ Nothing here was written into `brocc-data`. Per `CLAUDE.md` Rules 1 and 3,
that repo is changed only by an explicit request that starts with its own
reading list.

---

## The one-line summary

There are **33 `.sql` files** in `work/servicing/` (30 in `prod/`, 3 in `raw/`). About **four**
earn a materialised table, **three** are test suites wearing a table's
clothes, and the rest are views, wrappers or analysis.

Separately, the metrics your stakeholder asked for need **four models sourced
from RAW** — three genuinely new, and one that is just **widening a staging
model that already exists**. That last one is the cheapest win in this
document and it also fixes a defect in `FCT_CASE_FORBEARANCE`.

---

## Part A — why 33 files is not 33 models

The folder was built to a **coverage** goal ("29 of the 32 PROD objects") —
a map of the warehouse, not a set of models. A model earns materialisation
when something **reads** it and when recomputing costs more than storing it.
Today nothing reads anything: every file goes straight to the PROD facts.

The duplication that follows, measured across them:

| Repeated block | Files |
|---|---|
| PMI FX conversion | **16** |
| Servicer rule (`LEGACY + ES → Gescobro`) | **13** |
| Country join on `iso_alpha2_code` | **14** |
| `(unknown portfolio -1)` sentinel union | **10** |

Those are not 16 models. They are **one macro** that 16 files each re-typed
because a standalone `.sql` file has no `ref()`.

### A.1 Materialise — the four that earn it

| Today | Becomes | Why |
|---|---|---|
| `base_case` | loan × month fact | Reads a **1.47bn-row** fact and resolves 10 dimensions. Everything loan-shaped needs it |
| `base_case_collection` | loan × day fact | 134m-row fact plus the same dimension block |
| `agg_portfolio_summary` **+** `monthly_portfolio_performance` **+** `agg_portfolio_collection_monthly` | **one** portfolio × month × currency fact | Three files, one grain. Merge the column union |
| `monthly_portfolio_forecast` | portfolio × month × forecast-type | Stacks three forecasts with the servicer-version dedupe. Real logic, not a re-group |

### A.2 Convert to tests — three

`base_data_quality`, `base_reconciliation`, `base_collection_reconciliation`
all return "one row per check". That is a **test suite**, not a mart. Their
three jobs are genuinely distinct — is a column populated / do the levels
agree / does the chain foot — so keep all three, as dbt tests.

### A.3 Views, not tables — about nine

The four `agg_*_collection_monthly` files (portfolio / deal / vehicle /
servicer) are *the same select grouped four ways*. Once the portfolio fact is
materialised, a re-`group by` is nearly free — storing four copies just
creates four things to keep in sync. Same for `agg_loan_bands`,
`agg_loan_detail`, and the three dashboard datasets.

### A.4 Do not model at all — five

`ref_portfolio`, `ref_borrower`, `ref_loan`, `ref_calendar`,
`ref_display_currency` wrap `DIM_PORTFOLIO`, `DIM_BORROWER` and friends —
dimensions that **already exist in PROD**. Re-wrapping gives the same thing a
second name and a second place to drift.

### A.5 Analysis, not pipeline — about seven

`monthly_flash_report`, both restatement files, `monthly_loan_performance`,
`monthly_borrower_collections`, `base_collection`, `base_loan_carrying`. Real
questions, genuinely useful, nobody downstream reads them. Leave them here.

### A.6 The macros that remove the duplication

Four macros retire most of the table above:

| Macro | Replaces |
|---|---|
| `npl_fx_to_eur(amount, currency, month, 'flow'\|'stock')` | 16 copies of the PMI block, including the flow/stock distinction |
| `npl_servicer(deal_source, country)` | 13 copies of a **business rule** that already has two open questions against it |
| `npl_unknown_portfolio_label(sk)` | 10 copies of the sentinel union |
| `npl_is_complete_month()` | the part-loaded-month guard |

⚠ The servicer rule is the one that matters most. It encodes a business
decision, it is pasted into 13 files, and the headers already flag two
unresolved cases. If it changes today, someone edits 13 files and misses one.

---

## Part B — the new models, and this is the answer to "what should we add"

**Yes — and the highest-value one is no longer hypothetical.**

⚠ **Updated 2026-09-14: model 2 below has been BUILT AND RUN** as
`work/data-issues/intrum/queries/dash_phase_collections.sql`. It returns a real
split (EUR 18.6m amicable / EUR 11.8m legal over three months, with average
payment sizes that corroborate the labels). So the dbt work is
**productionising a proven query**, not exploring — a materially smaller and
lower-risk ask. See FLAGS.md §5.

Your stakeholder's pack is built around the **amicable / legal / BK split**.
That is not in PROD. It is in RAW, in `GROUP_CASE_PHASE`, and — verified
2026-09-14 — it is shaped correctly to answer the question.

### B.0 First: only 6 of 35 RAW tables are declared as sources

`models/staging/intrum_cat/source.yml` declares **`cases`, `invoices`,
`transactions`, `debtors`, `installment`, `settlement`** — six of the 35 tables
in `RAW.HYPERION_INTRUM_CAT`.

`GROUP_CASE_PHASE`, `ACTIONS`, `LEGAL_STEPS`, `LEGAL_INFO`,
`BANKRUPTCY_RECORD` and `CASE_STATUS_CHANGE_HISTORY` are **not declared at
all**, so step zero for each is a source declaration before any model.

### B.1 Why it works structurally

`GROUP_CASE_PHASE` is a **timeline, not a label**. Measured on Intrum instance
7006 (Spain):

| Phase spells per case | Cases |
|---|---|
| 1 | 239,413 |
| **2** | **3,490,869** |
| 3 | 5,507 |
| 4+ | 1,078 |

The dominant pattern is **two spells** — consistent with an amicable phase
followed by a legal one. Each spell carries a `START_DATE`, so the end of a
spell is the start of the next: a classic SCD built from events.

**That means a payment can be attributed to the phase in force on its payment
date** — which is exactly what "€ Amicable vs € Legal" requires, and it is
something a single current-state flag could never do.

The codes carry a readable prefix: `A000/A001/A002/A006`, `L000/L002/L003`,
`E002/E003/E005/E006`, plus `NA`.

⚠ **A = Amicable and L = Legal is a reading of the prefixes, not documented**,
and `E` is genuinely unknown. Build the model; **do not publish the labels**
until Intrum confirms the mapping. The model should carry the raw code and a
mapped label that comes from a **seed**, so the day the dictionary arrives it
is a one-file change.

⚠ Instance **4050 (Portugal) has only `A000`** — one phase, no split at all.
The metric will be legitimately blank for some books.

### B.2 The four models to add

Following the existing pattern (`stg_intrum_cat__transactions`,
`int_npl_case_collection_intrum`, `int_npl_case_collection_conformed`):

| # | Model | Source | Grain | Unblocks |
|---|---|---|---|---|
| 1 | `stg_intrum_cat__case_phases` → `int_npl_case_phase_intrum` | `GROUP_CASE_PHASE` (346m) | case × phase spell, with derived `valid_from` / `valid_to` | the whole Split Collections section |
| 2 | **`int_npl_case_collection_phased`** ✅ **prototyped** in `raw/dash_phase_collections.sql` | model 1 ⨝ existing collections | collection, stamped with the phase in force on its date | **€ / % amicable, legal, BK and their payment counts** |
| 3 | **widen `stg_intrum_cat__installment`** (it already exists) → `int_npl_case_payment_plan_intrum` | `INSTALLMENT` (1.07bn) | payment plan | new / in-force / cancelled plans, plan value and length |
| 4 | `int_npl_case_insolvency_intrum` | `BANKRUPTCY_RECORD` (3.7m) | case × record | the BK leg of the split |

**Model 2 is the one that matters.** Models 1, 3 and 4 are inputs; model 2 is
what the dashboard reads.

⚠ **Updated 2026-09-15: the dashboard now depends on this.**
`dash_portfolio_diagnostics` folds the phase split in directly, so the
Diagnostics page reads `GROUP_CASE_PHASE` live from RAW every refresh. That
works — Sigma can see RAW — but it means **an unmodelled 346m-row RAW table is
now on the critical path of a published dashboard**, which is exactly the
argument for modelling it properly.

⚠⚠ **Model 3 is much smaller than it looks, and this is the cheapest win in
the document.** `stg_intrum_cat__installment` **already exists** — but it
selects only seven columns (`case_id`, `plan_creation_date`, `creation_date`,
`update_ts`, `record_updated`, `source_system_code`, `extracted_at`). It
**drops** `CANCEL_DATE`, `END_DATE`, `DATE_OF_LAST_PAYMENT`, the amounts,
`DESCRIPTION`, and the `DELETED` / `ARCHIVED` / `UNLINKED` flags.

**So `FCT_CASE_FORBEARANCE` has no end date because the staging model never
selected one — not because the source lacks it.** The source has all three
dates. Widening that one staging model, plus the `DELETED`/`ARCHIVED` guards
it is currently missing, unlocks plan length, cure and re-default as well as
the six pack metrics. No dictionary, no new source, no new pipeline.

### B.3 The one to leave until last

`ACTIONS` — **10,634,995,035 rows**, larger than the transaction feed that
takes 9 minutes. It holds the entire Activity block (attempts, contacts, SMS,
mail, letters, RPC) and it is **fully blocked**: codes are `G_1`, `G_16`,
`G_10001`, classifications `5`, `3`, `12`, with 980m rows carrying no
classification at all. No pattern to read.

Biggest table, fully blocked, least decision-relevant. Last.

### B.4 Guards these models must carry

Every RAW Intrum table is a **change-history feed**, and the traps are already
documented in `work/benchmark-dataset/post-registration-benchmark/METHOD.md` and
`work/project-elsa-benchmark/FINDINGS.md`. A new RAW model set should start
from those, not from scratch:

- dedupe to the latest version per key (147× fan-out on cases, 10.8× on
  transactions)
- `CASE_ID` is unique **only within a source system** — pin the instance
- `_file_path` matched as a **literal prefix**, never with a leading `%`, or
  micro-partition pruning is lost
- read **all** extracts of an instance; the newest is often a small delta
- filter the scope **before** any window function
- amounts arrive **sign-flipped** on transactions

⚠ `GROUP_CASE_PHASE` also carries `DELETED` / `ARCHIVED` / `UNLINKED` flags,
like `DEBTORS`. Apply them.

---

### B.5 ⚠ The status code dictionary may already be in-house

`models/intermediate/npl_common/conformed/intrum/int_npl_forbearance_intrum.sql`
filters on `status_code in ('23','24','29','313','315','35','56')` and carries
**the descriptions in its comments**:

```
('23','Settlement payment plan'), ('24','Settlement'), ('29','Payment plan'),
('313','Settlement offer'), ('315','Restructuring of debt'),
('35','Debt reconstruction plan'), ('56','Payment plan')
```

Someone on the data team obtained that from Intrum. It is **not** a seed and
not in the repo as data — only as a comment — but seven codes are decoded and
every one of them is amicable-track.

→ **Resolved 2026-09-15: the full dictionary is in hand.** Sharlene obtained
Intrum's own `lookup.main_status_code` — **103 codes** with descriptions. It
lives at `work/italy/legal/main_status_code.csv` and is inlined as a
`code_dictionary` CTE in `work/project-elsa-benchmark/status_code_breakdown.sql`.
All 25 codes on the Millennium book and every code seen on Italy resolve.
**It should land in `brocc-data` as a seed** (`dim_status_code`, B.6 #1) so it
is versioned and joinable, not copied file to file. The dictionary covers
`MAIN_STATUS_CODE` only — `GROUP_PHASE_CODE` (A/L/E) and `DETAIL_STATUS_CODE`
(two-letter) are still undecoded by Intrum; E was confirmed as Execution.

### B.6 Case status: keep the history, make it usable

**Written 2026-09-16 after measuring `DIM_CASE`.** The question was whether
status history is lost between RAW and `DIM_CASE`. It is not — and the model
should NOT be changed in that respect. What is missing is the layer that makes
the history usable, and one column the SCD never tracked.

**What `DIM_CASE` gets right (do not touch):**

- `int_npl_case_scd_conformed` versions on ten attributes including
  `status_code`, deduping only *consecutive identical* rows with `lag()`, so
  A → B → A survives. Raw is ~74 update timestamps per loan (balance refreshes);
  `DIM_CASE` is 6.83 versions per case — and 63% of multi-version cases show a
  status change, 0% show no tracked change at all. That is the history, intact.
- Exactly one `is_current_flag = TRUE` row per case (22,530,004 = 22,530,004).
- `effective_from_date` is the **only reliable status date in PROD**:
  `status_date` is the date of the *current action* (filled on codes 43, 1, 44,
  3, 64…, blanked when the case goes passive — 865,042 cases lose it in a later
  version) and on Millennium it simply restates the registration date.

**What is genuinely lost, measured:**

| Loss | Size | Why it matters |
|---|---|---|
| `DETAIL_STATUS_CODE` / `DETAIL_STATUS_DATE` not in `scd_columns` | 100% of it | the two-letter sub-status is the only status field with real dates on legal (17%) and bankruptcy (11%) codes, back to 2005; `MAIN_STATUS_DATE` is 0% there |
| Descriptions | 100% NULL in PROD | the dictionary exists (B.5) — this is a seed away |
| `closing_date` cleared on reopen | 444,265 cases (2.4%) | `closing_date IS NULL` on the current row means *open now*, not *never closed*; a reopen rate needs history |
| Same-day status flips | unmeasured, small | the `(case_dk, valid_from)` fan-out guard keeps one row per day by design |

**The four things to add** (all Rule 1 — `brocc-data`, the team's conventions):

| # | Model | Shape | Built from | Answers |
|---|---|---|---|---|
| 1 | **`dim_status_code`** — a seed | 103 rows: `code`, Intrum's `description`, our `workout_track` (legal / insolvency / amicable / closed / other) — **two separate columns, never conflated** | `work/italy/legal/main_status_code.csv` | every "what does 36 mean" |
| 2 | **`fct_case_status_change`** | one row per case per **transition**: `case_bk`, `from_status`, `to_status`, `changed_on` (= `effective_from_date`), `ended_on`, `days_in_status`, `is_current`, `portfolio_sk` | `DIM_CASE` versions + `lag()`, exactly the pattern in `work/.archive/2026-10-02-servicing/test.sql` | ever judicialised, ever insolvent, amicable → legal this month, time in status, reopen count. Cheap: it reads a model that already exists |
| 3 | **`dim_case_current`** | one row per `case_bk` (22.5m), the current version, **keyed on `case_bk`** — plus lifetime columns from #2: `first_legal_on`, `first_insolvency_on`, `first_closed_on`, `last_closed_on`, `n_closures`, `is_closed_now` | `DIM_CASE where is_current_flag` ⨝ #2 | "what is it now" without the `case_sk`-is-a-version-key trap that silently dropped 95% of rows on 2026-09-15 |
| 4 | **add `detail_status_code`, `detail_status_date` to `scd_columns`** in `int_npl_case_scd_conformed` | widens `DIM_CASE` — detail moves more often than main, so **measure the row growth first** | RAW `CASES` | the only route to dated legal / bankruptcy events on the pre-2014 books |

**#2 is the one that matters.** It turns a 153.9m-row SCD that every analyst
has to `lag()` themselves into a fact Sigma can `sum()`. #1 and #3 are small
and make #2 readable; #4 is the only one that changes what reaches PROD.

**How each date behaves across a case's versions** (measured 2026-09-16 on all
153.9m rows; counts are consecutive-version transitions). This is the yml
description `DIM_CASE` currently lacks:

| Column | Changes value | Direction | Reverts to NULL | Read it from |
|---|---:|---|---:|---|
| `registration_date` | 4,477,755 | **earlier** (79%) | 0 | **latest version.** Almost all changes are version 1 → 2: on `7006`, 3,479,399 cases (94% of the instance) were first delivered with a date the source then moved a median **710 days earlier** — a genuine source-side revision, not origination and not a sentinel. On `3010`, 24,529 version-1 values equal the version's own `effective_from` — i.e. the source first delivered the case with registration = delivery date, then corrected it. (Not the macro backdating: `generic_intermediate_cases` backdates only the contract servicers — Gescobro, Cerved, Souq, Massey; `int_npl_case_intrum` does not.) On `2080`, 787 version-2 values are sentinels (pre-1950 / post-2100). |
| `origination_date` | 388,500 | later (95%) | 0 | latest version |
| `default_date` / `derived_default_date` | 1,400,821 | **earlier** (97%) | 653,006 transient — only **9 cases** end NULL | latest version; corrections backfill towards the true default |
| `closing_date` | 313,079 | later (90%) — re-closed | **610,322** — reopened | latest = closed *now*; history for ever-closed (444,265 cases end cleared) |
| `status_date` | 92,708,398 | later (92%) | 955,187 | **do not use as a date of anything durable** — it is the date of the current action |
| `effective_from_date` | — | monotone by construction | — | the reliable status-change date |

⚠ Do not "fix" `closing_date` either — the SOURCE clears it when a case
reopens, so on the current row it means "closed now, since when". Keep that
meaning; carry "was it ever closed, when, how often" as the lifetime columns
on `dim_case_current` (#3), derived from the history. Never coalesce a cleared
`closing_date` with an old value in the dimension: that row would read as
closed while the case is open.

⚠ Do not "fix" `status_date` — it is not broken, it means something narrower
than its name. Document it in the yml (`DIM_CASE` currently has no column
descriptions) and point people at `effective_from_date`.

⚠ The SCD carries **1,466 non-current rows with `effective_to_date =
9999-12-31`** — closed versions with an open end date. Tiny, but it will break
a naive "version in force on date X" join; worth a dbt test.

**Case coverage RAW → `DIM_CASE` (measured 2026-09-16, live query, every
instance).** The pipeline drops whole cases in only three places — container
sub-cases on `1033`, `real_case_ind` on `2080`, and the inner join on batch in
`int_npl_case_conformed` — and the measured gap is consistent with those being
deliberate:

| Instance | Raw cases | In `DIM_CASE` | Missing | Why |
|---|---|---|---|---|
| 1033 | 5,398,780 | 2,662,478 | 50.684% | container sub-cases, by design |
| 2080 | 1,830,935 | 1,738,370 | 5.056% | `real_case_ind` filter, by design |
| 3010 | 1,871,216 | 1,853,871 | 0.927% | unexplained — likely batch not in servicer batch feed |
| 1039 / 1080 / 1071 | — | — | 1.5–2.7% | same, small |
| 7006, 4050, 4042, 2020, 4034 … | — | — | 0.000–0.003% | complete |

Conclusion: build the status-history models **on top of `DIM_CASE` /
`int_npl_case_scd_conformed`**, not from RAW. Going back to RAW buys only
`detail_status_code`, and that is a one-line staging change, not a rebuild.
Query: `work/data-issues/intrum/queries/raw_vs_dim_case_coverage.sql` (~2 min).

**Status code vs legal phase (measured 2026-09-16, `status_vs_phase.sql`).**
They do not align, and should not be expected to. Across every instance with a
phase feed, only 231k of 4.28m legal/execution-phase cases (5.4%) carry a
status that says legal or insolvency; `64 On-going` and `6 Completed` dominate
every phase. On `7006` (Millennium), `4042`, `7010`, `2020`, `4034` the share is
**0%** — those instances use status purely as open/closed. `1137` is the lone
instance where status tracks phase (97%). Consequence for modelling: the
amicable/legal split must come from `GROUP_CASE_PHASE` (the phase-at-snapshot
model above), never from `status_code`; status keeps its value as the
insolvency signal (codes 12/35/36/59/67/69/73/315) and open/closed. `NA` is a
literal phase code (4.4m cases) meaning "phase not assigned" — label it, do not
treat it as a missing feed.

### B.7 ⚠ These models are now written — `work/dbt/`

**2026-09-16.** B.6's four asks plus the phase models from B.2 have been written out as real
dbt code in the team's own conventions and folder structure, ready to be dragged into
`brocc-data` and committed: `work/dbt/` in this workspace, with its own README.

Ten new nodes (3 staging, 3 intermediate, 2 dimensions, 2 facts), 2 seeds, 4 singular tests,
and 2 patches to existing files. `dbt parse` returns 0 against the real project and every node
resolves with the intended alias and schema; the tree was copied in, validated, and removed,
leaving `brocc-data` pristine.

⚠ The models are written keywords-UPPERCASE (Sharlene's house style), while
`.sqlfluff` sets `capitalisation.keywords = lower` — so CI lint will flag every file on
capitalisation alone. Style conflict, not a defect: `mise :format` resolves it in one pass.
See the README's house-style section.

⚠ `sqlfluff` could not be run at all to check anything else: it fails on an *untouched*
`brocc-data` model with
`Unrecognized config 'force_enable' for Rule PG01`, a pre-existing environment problem
(sqlfluff 3.5.3 vs the pinned templater). **`mise :lint` is broken on this laptop** and the CI
lint gate has not been exercised — that is the one check the data team must run themselves.

### B.8 Case × month metrics — scoped 2026-09-16, not yet built

⚠ The scoping file this cited (`work/dbt/PLAN-case-metrics.md`) no longer exists. The two
tables it scoped were a case × month metrics fact and a one-row-per-case summary. Three
findings from that scoping are recorded here and matter beyond those two models:

1. **`FCT_CASE_SNAPSHOT_DAILY` is month-end grain, not daily** — 147 distinct `date_day` values,
   2014-06-30 → 2026-08-31, **zero** rows on a non-month-end date. The name misleads; it should
   be documented in the yml (it has no column descriptions) but **not renamed**, since the
   exports, the accounting allocation and the dashboards all reference it.
2. **Commission, mgmt fee and passthrough cost exist only at portfolio grain.** The raw
   transaction rows the pipeline discards (`payment_cost_ind` in 'C','A') are debtor-charged
   costs, balance loads and manual adjustments — not servicer commission. Per-case cost can only
   be *allocated*, and should be named `allocated_*` so it is never mistaken for an invoice.
3. ⚠⚠ **Case-level collections do not reconcile to portfolio-level collections.** Matched
   portfolio-months, same currency, 2025-01 → 2026-08: EUR case-level 310.8m vs portfolio-level
   101.1m (**307%**), GBP 73%, DKK and PLN wilder; and only 1,572 of 2,825 portfolio-months
   (55.65%) have any case-level collections at all. The unknown-portfolio sentinel is ruled out
   (205,952 EUR). This is consistent with reconciliation checks 12-14 never closing, is
   **pre-existing**, and gates publishing any per-case cash figure. Query:
   `work/data-issues/intrum/queries/case_vs_portfolio_collections.sql`. The probe is coarse — no FX, no
   acquisition-date bounding — so measure it properly before drawing a conclusion.



---

## Sequencing

Cheapest first, each step independently useful:

| # | Step | Cost | Unblocks |
|---|---|---|---|
| 1 | Merge the three portfolio × month files; add the four macros | small | removes most duplication before it multiplies |
| 2 | ~~Ask for the status code dictionary~~ **Obtained 2026-09-15** — land it as the `dim_status_code` seed (B.6 #1) | **tiny** | decoded status everywhere |
| 2b | **`fct_case_status_change`** + `dim_case_current` (B.6 #2, #3) — from `DIM_CASE`, no new source | small | ever-judicialised / ever-insolvent / reopen rate / time in status on the dashboard |
| 3 | **Widen `stg_intrum_cat__installment`** (B.2 #3) — it already exists | **small** | 6 metrics + forbearance end dates, **no dictionary needed** |
| 4 | Model `GROUP_CASE_PHASE` + the phased-collection model (B.2 #1, #2) | medium | the Split Collections section |
| 5 | Convert the three check files to dbt tests | small | CI catches drift |
| 6 | Model `ACTIONS` (B.3) | large | the Activity block |
| 7 | Track `detail_status_code` / `_date` in the case SCD (B.6 #4) — measure row growth first | medium | dated legal / bankruptcy events on pre-2014 books |

Steps 1, 2, 2b, 3, 5 and 7 need nothing from Intrum and can start now.

---

## Before any of this is written

`CLAUDE.md` Rule 1: whoever writes these models reads, in order —
`brocc-data/AGENTS.md`, `brocc-data/transformation/dbt/AGENTS.md`, and
`brocc-data/transformation/dbt/.claude/agents/dbt-agent.md` — then follows
those over this document. Finish with `mise :lint` and `mise :format` from
`brocc-data/transformation/dbt`, and never add Python dependencies to that
project's `pyproject.toml`.

See also: [../data-issues/intrum/feed-coverage.md](../data-issues/intrum/feed-coverage.md) for the
metric-by-metric matrix, [../servicing/FLAGS.md](../servicing/FLAGS.md) for the caveats that survive
into any model built from these sources.
