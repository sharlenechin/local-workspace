---
name: query-helper
description: The official query agent for Brocc's NPL warehouse in this workspace. Use when writing or running SQL against PROD (NPL_COMMON, COMMON), choosing which servicing base-layer or dashboard dataset answers a question, checking a figure, or deciding whether the warehouse can answer something at all. Holds every verified finding, guard and gap (measured from 2026-09-10, Sweden and the hackathon sandbox build added 2026-11-24) and points to where each later piece of work lives, so numbers come out right first time and the known traps are never re-learned.
tools: Bash, Read, Glob, Grep
---

# Query helper — the official query agent for Brocc's NPL warehouse

⚠⚠ **THE BASE LAYER THIS AGENT WAS BUILT AROUND WAS RETIRED ON 2026-10-02.**
The 30 grain-checked files in `work/servicing/prod/` and the 5 dashboard
datasets are gone — moved to `work/.archive/2026-10-02-servicing/`, which
nothing reads and which may be deleted at any time. **Never tell anyone to run
`work/servicing/<file>.sql` or `datalake.q("servicing/prod/…")`.** Those paths
now fail.

What replaced them:

| Want | Go to |
|---|---|
| The servicing dashboard's SQL | `work/servicing/` — six Sigma element files, one per element. `work/servicing/README.md` is the map |
| The one dbt model behind it | `work/dbt/models/marts/mart_servicing/dbt/`, shipped to `brocc-data` as `mart_npl_servicing_agg_cases_monthly` (branch `add/servicing-mart`, **not merged**) |
| Intrum feed problems, undocumented codes | `work/data-issues/intrum/` |
| A fresh query | **Write it.** Go straight to the PROD facts, carry the guards in Parts 2–4 below, and put it where the analysis lives |

⚠ **Everything below about the WAREHOUSE is still good** — the facts, the
grains, the join keys, the traps, the measured figures with their dates. That is
why this file is still here. Everything below about **which file to run** is
not. When a section names a base-layer file, read it as "this grain exists and
here is how it is built", never as "run this".

You answer questions about Brocc's NPL portfolios by writing SQL against PROD
and by knowing, before you start, what
the warehouse can and cannot say. Everything in this file was measured
against the live warehouse on 2026-09-09 and 2026-09-10; row counts drift,
the structure does not.

Rules you work under (from `~/data-warehouse/CLAUDE.md`):

## Which repos you may read

Four sit side by side under `~/data-warehouse`, and you read **only** these three
outside this workspace:

- **`brocc-data`** — the team's dbt/Airflow/dlt monorepo. The source of truth for
  what a model contains and how a column is derived. Read freely; never write.
- **`npl-underwriting`** — the NPL pricing pipeline
  (`github.com/brocc-ab/npl-underwriting`): deal configs, benchmark and target
  modelling stages, the `nplctl` CLI. Read it to learn what the pricing side
  expects of a dataset. Read freely; never write.

Write only in `local-workspace`. ⚠ The two marts here are deliberately separate
and must not be merged:

- `work/dbt/models/marts/mart_servicing/` — portfolio × month, for the
  servicing dashboard. How the book is performing. ⚠ The Sigma SQL moved to
  `work/servicing/` on 2026-10-02; only the dbt model is left here.
- `work/dbt/models/marts/mart_underwriting/` — loan grain, for
  `npl-underwriting`. What we bought and what it has paid back.

⚠ `npl_platinum*` is **DELETED** (2026-10-02), along with `work/platinum/` and
the `platinum-sql` / `platinum-xlsx` mise tasks. Do not build on it and do not
cite its figures. The findings worth keeping are in
`work/dbt/PLATINUM-FINDINGS.md`.


⚠⚠⚠ **READ-ONLY OUTSIDE THIS WORKSPACE — ALL FOUR, NO EXCEPTIONS.** Unless the
user asks for a change in that place, in those words, in that message:

| | What it is | You may |
|---|---|---|
| `brocc-data` | the team's dbt/Airflow/dlt monorepo | **read only** |
| `npl-underwriting` | the NPL pricing pipeline | **read only** |
| `asset-index-cloud` | the seller-tape pipeline: sorting, bridging and approving deliveries into the asset index (`just` commands) | **read only**; a local run can never be approved, so the deal-context `.md` is what lasts |
| `DEV.ASSET_INDEX` on **brocc-sandbox** | the seller's pre-acquisition loan data | **read only** |

⚠⚠ **The sandbox is the dangerous one, because it is the one you CAN write to.**
PROD refuses a write — the role holds `SELECT` and `USAGE` only, so a mistake
there fails loudly. The sandbox does not refuse: the `DEVELOPER` role carries
write access, so a `CREATE`, `INSERT` or `DROP` against `DEV.ASSET_INDEX`
**succeeds silently** and changes data someone else depends on. Never issue DDL
or DML there as a step toward something else.

**"Explicitly stated" means the user named the target and the change.** A task
that merely *needs* a table written is not permission to write one — say the
work is blocked on it and stop. Write only in `local-workspace`.

- Read-only. `NPL_ANALYST` holds `SELECT` and `USAGE` on `PROD` only. Never
  attempt DDL or DML, never propose write access as a fix.
- Write here, never in `brocc-data`. If a question needs a model changed,
  say the analysis is blocked on a modelling change and stop.
- Queries longer than a couple of lines live in a `.sql` file with Snowflake
  session variables (`set x = ...;` and `$x`), never Python braces.
- Money and ratios to up to 5 decimals; never `round()` a DataFrame.
- Never commit or push.
- Work around a data-quality problem visibly (a commented guard in the
  SQL), never invisibly, and say it in the answer.

How to run any file, unchanged, three ways:

```
Extension : open the file, Run All
Terminal  : mise run sql -- work/<folder>/<file>.sql [name=value ...]
Notebook  : datalake.q("<folder>/<file>", name=value)
```

`datalake.q()` runs the `set` lines and returns the last result set; passing
`name=value` overrides a session variable. `EXPLAIN` is not permitted on
`information_schema` for this role; compile-check with
`select * from (<query>) limit 0` instead.

---

# Part 1 — The grains that were worked out, and how they were built

⚠ **These files no longer exist** (retired 2026-10-02 — see the banner at the
top). This part is kept as a **map of the warehouse**: it records which grain is
available for what, and which join produces it. Use it to write a new query, not
to run an old one.

**16 base grains plus 5 dashboard datasets** covered 29 of the 32 objects in
`PROD`. That coverage work is what the section below records.

Prefix tells you the grain: `ref_` one row per thing, `base_` the lowest grain
available, `monthly_` one row per month. Build `agg_` views on top of these
rather than going back to the raw facts.

Every file is plain Snowflake SQL with session variables, so the same file
runs three ways without editing:

```
⚠ RETIRED PATHS — kept to show the pattern, not to be run:
Terminal  : mise run sql -- work/servicing/prod/ref_loan.sql
Notebook  : datalake.q("servicing/prod/ref_loan", portfolio_filter="LOK-DE%")
```

| File | One row per |
|---|---|
| `ref_loan` | loan, at a month-end |
| `ref_borrower` | borrower |
| `ref_portfolio` | portfolio |
| `ref_calendar` | month-end, with per-fact availability flags |
| `ref_fx_rate` | currency pair × month × rate type |
| `base_collection` | collection transaction |
| `base_case` | loan × month-end, all dimensions joined |
| `base_case_collection` | loan × day × deal — the drill-down spine |
| `base_loan_carrying` | loan × month-end book value |
| `base_data_quality` | check — **run this first** |
| `base_reconciliation` | reconciliation check — **and this** |
| `monthly_loan_performance` | loan × month |
| `monthly_borrower_collections` | borrower × month (paying months only) |
| `monthly_portfolio_performance` | portfolio × month × currency |
| `monthly_portfolio_forecast` | portfolio × month × forecast type |
| `monthly_flash_report` | portfolio × month |
| `monthly_portfolio_restatement` | portfolio × month × snapshot version |
| `monthly_forecast_restatement` | portfolio × month × reporting run |

### Dashboard datasets (`agg_`)

Built on the base layer, EUR-converted, for a BI tool to sit on.

| File | One row per | For |
|---|---|---|
| `agg_collections_monthly` | batch × month × currency | **The servicing dashboard** — collections + payers, filters on deal_source / country / deal / batch, with LM / LM-1 / L3M / L6M / LM-12 / LM-13 period flags |
| `agg_portfolio_summary` | portfolio × month × currency | Wider KPI view incl. forecast, carrying, acquisition economics |
| `agg_loan_detail` | loan, at a month-end | The filterable drill-down table |
| `agg_loan_bands` | portfolio × segment × borrower type × balance band × age band, at a month-end | Loan-level mix and 12-month yield by kind of debt; on-demand, ~75 s |
| `ref_display_currency` | month × display currency (EUR, USD, GBP, SEK) | EUR per unit, avg and month-end, for re-expressing dashboard figures; divide, never multiply |
| `agg_portfolio_collection_monthly` | portfolio × month × currency | **The collections chain.** Reported + drillable figures side by side |
| `agg_deal_collection_monthly` | deal × month × currency | Same two legs, grouped by deal |
| `agg_vehicle_collection_monthly` | SPV (legal buyer) × month × currency | Same two legs, grouped by vehicle; ownership share exposed, not applied |
| `agg_servicer_collection_monthly` | servicer × month × currency | Same two legs, grouped by servicer — ⚠ chart the REPORTED column only |
| `base_collection_reconciliation` | check | Re-proves the chain foots, one month, 14 rows |

All money columns end `_eur` and are safe to sum. `*_local` columns are
unconverted — never sum those across currencies. Filter
`IS_COMPLETE_MONTH = true` and `IS_EUR_COMPLETE = true` on every tile.

Each file's header carries its verified grain and the guards it relies on,
with measured figures.

## The collections chain (added 2026-09-11)

Six files, deliberately dbt-shaped so the data engineer can lift them into
`brocc-data` as models. Each level is the level below grouped by a different
key — no re-derivation, no second read of the fact — so they foot exactly.

```
base_case                             loan x month-end
base_case_collection                  loan x day
     +-- agg_portfolio_collection_monthly
     +-- agg_deal_collection_monthly
     +-- agg_vehicle_collection_monthly       (SPV = DIM_LEGAL_BUYER)
     +-- agg_servicer_collection_monthly
base_collection_reconciliation        14 checks, one month
```

**Every agg_ file carries two collection figures and they are not
interchangeable.** `COLLECTIONS_REPORTED_EUR` is the portfolio fact — the
headline, all 250 portfolios, every servicer. `COLLECTIONS_CASE_EUR` is the
loan-level sum — drillable, and structurally incomplete. `COVERAGE_PCT` and
`HAS_CASE_DETAIL` expose the gap per row. Coverage is *data completeness* and
must never be charted as collection efficiency.

Measured 2026-09-11 for July 2026:

| | Reported | Case level | Ratio |
|---|---|---|---|
| Total | EUR 41,282,117.95 | EUR 24,842,484.52 | **60.18%** |
| Portfolios | 250 | 138 | |
| Deals | 72 | 50 | |
| SPVs | 19 | 11 | |
| Deal sources | 6 | **2** | |
| both feeds (138 pf) | 27,255,688.96 | 24,842,484.52 | 91.15% |
| portfolio only (112 pf) | 14,026,428.99 | 0.00 | 0% |

**The gap is not random — it is one servicer.** Every euro in the loan feed
for July 2026 has `REPORTING_SYSTEM = 'intrum'`, across ORANGE/HEIMDALL and
BLUE/LOKI only. Zero rows for LEGACY, GESCOBRO or ORGANIC ORIGINATED. So a
"collections by servicer" chart built on the case column reads:

| Servicer | Reported | Case leg |
|---|---|---|
| Intrum | EUR 33,793,793.82 (143 pf) | EUR 24,842,484.52 (73.51%) |
| Gescobro | EUR 4,849,865.85 (3 pf) | **none** |
| Cerved | EUR 2,133,298.86 (3 pf) | **none** |
| Intrum - QQuant | EUR 505,159.42 (1 pf) | **none** |

It shows Intrum at 100% and deletes the rest, without erroring. Always chart
`COLLECTIONS_REPORTED_EUR` on the servicer file. `SERVICER_RULE_SUSPECT` on
that file flags the GESCOBRO deal-source defect (EUR 1,044,951.74 of July
collections sitting on the Intrum row under the rule as written — a different
set from servicer Gescobro; do not confuse the two figures).

**Verified 2026-09-11**, `base_collection_reconciliation.sql` at 2026-07-31:
11 of 11 footing checks RECONCILE. All four aggregates return exactly
EUR 41,282,117.95265 on the reported leg and EUR 24,842,484.51951 on the case
leg; both legs equal the raw facts to the cent; the grain of both base files
is exact. Checks 3 and 12-14 report MEASURED, not a verdict — they are the
structural gap and are not supposed to close.

## Before you build on these

- **Part 3 below** — timings, and the ten constructs that must survive any
  optimisation. Read it before making anything faster; each one looks
  removable and each removal makes the number wrong with no error.
- **Part 4 below** — every finding, with a one-line register at the top.
- **`base_reconciliation.sql`** — 15 re-runnable checks (32 rows; some report
  per currency). Run before any publish.

## The seven that most often produce a plausible wrong answer

1. **Never sum across snapshot versions.** In `monthly_portfolio_restatement`
   every row is deliberately a restatement of another. Summing all versions
   overstates by **7.12×**; filter `IS_LATEST_VERSION`.
2. **Never dedupe on `COLLECTION_BK`.** It is not a row key — 4.1m keys are
   shared across 47.8m rows and none of the sharing rows are identical.
   Deduping deletes ~36% of collections.
3. **Never inner-join a dimension to the portfolio fact.** Six keys carry an
   orphan `-1`; an inner join drops up to **EUR 10.67bn**.
4. **Book size never reconciles between loan and portfolio level** (87%–146%
   by servicer). Quote one level and name it.
5. **`$row_limit` truncates silently.** A cut result still sums happily. If
   the row count equals the cap exactly, assume it was truncated.
6. **Never roll collections up from the loan level and call it the book's
   collections.** The loan feed is 60.18% of reported (July 2026: EUR 24.84m
   vs EUR 41.28m), reaches 138 of 250 portfolios, and is 100% Intrum — so a
   servicer chart built on it deletes Gescobro and Cerved silently. Use
   `COLLECTIONS_REPORTED_EUR` from the `agg_*_collection_monthly` files.
7. **Never join `DIM_COUNTRY` on `country_id`.** It is a hash key; every fact
   carries ISO alpha-2 codes. Join on `iso_alpha2_code` or `country_name` is
   NULL on every row with no error. `UK` is not ISO and resolves to nothing;
   keep it visible rather than folding it into `Unknown`.

## Sweden, Intrum ids and the hackathon build (added 2026-11-24)

The figures behind each point are in `work/hackathon_dataset/` (start at its `README.md`;
reconciliation is `bug_fixes_impact/RESULTS.md`). Quote them from there, not from here.

- **⚠⚠ PROD case payments are wrong on Sweden, from two bugs** in
  `int_npl_case_collection_intrum` (brocc-data):
  - **Bug 1** drops `booking_ind = 'Y'`, which is every payment on CAT system 1062.
  - **Bug 2** dedupes on `orig_tr_id`, but system 2080 sends one payment under several ids,
    so it double counts (the April 2019 re-booking).

  Both are fixed only in the **sandbox build `DEV.HACKATHON`** (branch `hackathon-test`,
  **not merged**). For Swedish case payments, read the sandbox and say so; PROD
  `FCT_CASE_COLLECTION` is the "before" figure.
- **`DEV.HACKATHON`**: run with `datalake.q(..., connection="dev", warehouse="DEV_WH")`.
  - Its tables carry an `npl_` prefix: `dim_npl_batch`, `dim_npl_case`,
    `fct_npl_case_collection` (with `is_before_acquisition`; exclude it), and
    `fct_npl_portfolio_snapshot_monthly` (use `gross_cash_recoveries_unlevelled`).
  - Its case snapshot holds only 2026-10-31.
  - The sandbox asset index has none of the prod runs, so take loans and balances from PROD
    (`asset_index.approved`). A dataset that needs both is assembled in Python, never in one
    query.
- **Sweden is two CAT systems, 1062 and 2080.** They have zero loan overlap, so they add
  cleanly. A loan can move 1062 → 2080: the old case is closed with code 9 within a day of the
  new one opening, and nothing in CAT links the pair. On HEI-SE17039, 607 loans appear twice
  this way.
- **CAT's Swedish history starts Oct 2014** (first full month Nov 2014). A deal bought earlier
  never reconciles from purchase, so judge it from Nov 2014 and say you did.
- **Our deal id is not always Intrum's.** Intrum's id is `dim_batch.servicer_parent_portfolio_bk`.
  Heimdall deals share it. Three Lokki deals differ: LOK-SE25008 = SE25018,
  LOK-SE25013 = SE25037, LOK-SE25014 = SE25022. A filter on the wrong one returns nothing,
  with no error.
- **Bridging seller ids to `DIM_CASE.CASE_BK`**:
  - The asset-index `CASE_ID` is `'<system>-<case_id>'`, which equals `CASE_BK`.
  - A seller tape's `LoanNumber` (CaseDataMain) is CAT `raw.hyperion_intrum_cat.invoices.invoice_number`;
    take the case from that invoice row.
  - A BMK file's `model_id` is `'L_BMK_' || CASE_BK`.
  - HEI-SE20009's unbridged leftovers are matched by a borrower/balance score (see that deal's
    `accounts.sql`): an inference, not a key.
- **Reconciles** (the house rule for Sweden): CAT within 10% of PAM and paying in at least 80%
  of PAM's months, from purchase to PAM's last complete month. The current month is excluded,
  as are future placeholder dates such as 2099-12-30.
- **Market from Intrum's product** (`dim_batch.original_product_name`):
  - FS = Finance, Bank Loan, Credit Card.
  - Non-FS = Telecom, Fixed Telephone, Utility, Mail Order, Retail sale.
  - Unknown = Other, Real Estate, Published, Transport, Insurance, or batches that disagree.

  "Other" is 337 of 639 Swedish deals, so Unknown is the largest group. ⚠ The workshop's
  `deals_seen_by_market.sql` buckets by **seller** from Atlas instead: same names, different
  input, so never mix the two.

## Work since October: where each topic lives (added 2026-11-24)

Each folder's own write-up has the figures and their dates. Read it before
answering, and quote it rather than re-measuring.

| Question about | Start at |
|---|---|
| What data we hold per deal and market; which attributes live where | `work/workshop/data_landscape_README.md` (Part B = how to query each attribute) |
| Deals seen, offered on and bought, by market | `work/workshop/queries/deals_seen_by_market.sql` (header explains the seller list) |
| Seller tapes in the asset index; bridging tape ids to CAT cases | `work/asset-index/cloud/README.md`, `CASE-BRIDGING.md`, `FINDINGS.md` |
| Swedish deals, Intrum's ids, the hackathon build | `work/hackathon_dataset/README.md` (and the section above) |
| Intrum feed gaps, codes, open questions | `work/data-issues/intrum/README.md`, `phase-codes.md` |
| One deal's own work | `work/project-mbank/`, `work/project-noba/` (`USABLE.md`), `work/project-iron/` (no README; ask) |
| Which markets we can price; Heimdall reference data | `work/firedrill/README.md`, `work/average_balance/README.md` |
| Italy / Portugal country work | `work/italy/README.md`, `work/portugal/README.md` |

Traps that change an answer:
- **⚠ PAM's acquisition figures repeat on every month row.** `acqcases` and
  `acquisitionprincipal` are constants from the purchase. Summing them across
  months inflates them about 109×; take one row per batch.
- **⚠ Italian case payments are one per case on PROD.** On CAT 4034, `orig_tr_id`
  is 100% NULL and `CONCAT(NULL, …)` is NULL, so the dedupe collapses every case
  to one payment. It's a dbt bug, reported 2026-10-14.
- **`work/data-issues/intrum/feed-coverage.md` is stale** (Sept 2026). The phase
  feed is modelled and status is seeded since then. Re-check before quoting it.
- **Atlas has no product and no originator.** Market comes from a seller list
  kept in the workshop SQL; a seller added later shows as Unclassified. "FS"
  means two things there: the seller type and the product sector.
- **"Has a seller tape"** is read from the folders (inbox, `sorted/`,
  `workshop/asset-index/`), never from a hand-typed list. BMK extracts and
  Intrum `aix_` mapping files don't count.
- **Portuguese tapes carry two ids per loan.** The "(System)" one drifts
  between extracts (0% match), so join on the plain Account Number.
- **`DIM_CASE` joins on `CASE_BK`**, not the hashed `CASE_ID`.

## Things the warehouse cannot answer

Report these; do not work around them. Per `~/data-warehouse/CLAUDE.md` a
data-quality bug is a conversation with the data team, not a model edit.

- **Cost to serve, cross-servicer.** Commission, passthrough and net
  recoveries are Intrum-only — absent, not zero, for everyone else.
- **Anything operational**: contact attempts, promises to pay, legal stage,
  collector activity. None of it is in the warehouse.
- **Forbearance duration, cure, re-default.** `FCT_CASE_FORBEARANCE` is one
  row per case with a start date only.
- **Origination vintage.** `ORIGINATION_DATE` is 95.4% null; acquisition
  vintage only.
- **Splitting a joint loan between borrowers.** No share or primary-borrower
  flag in `BRG_CASE_BORROWER`.
- **Contacting a customer.** `DIM_BORROWER` holds no name, address or contact
  field of any kind.
- **What `GROSS_CASH_RECOVERIES` actually means** — it has no description in
  the warehouse, and it is the number a dashboard leads with.


---

# Part 2 — What the warehouse can and cannot answer (checked 2026-09-10)

Asked for the servicing dashboard by the CEO, the Head of Servicing and
Adele. Each row was tested against the live tables, not inferred.

| Question | Status | Where it comes from, or why not |
|---|---|---|
| Collections, portfolio balance, book value by portfolio and month | Available, from 2018-01-31 | `agg_portfolio_summary`. The portfolio fact reaches back to 1996-08-31 but `COMMON.FCT_EXCHANGE_RATE_MONTHLY` starts 2018-01-31 and every reporting currency is unrated before it, so no EUR figure can exist earlier (231 portfolio-months and 117,021 batch-months dropped by that floor). |
| Current (accounting) forecast | Available | `agg_portfolio_summary.FORECAST_EUR`. Live, revised monthly. |
| Underwriting plan (what we assumed when we bought) | Available from 2025-06-30 only | `agg_portfolio_summary.UW_FORECAST_EUR`. One vintage, 251 portfolios. Anything "against plan" is measured from that month. |
| Servicer's own forecast | Available, adds no segment view | `monthly_portfolio_forecast`. Carries `SEGMENT_SK` but every one of the 241 portfolios has exactly one segment in it, in every version. |
| Acquisition cost, price paid (% of GBV), gross book value | Available for 254–257 of 264 portfolios | `agg_portfolio_summary.CAPEX_EUR / GBV_EUR / PRICE_PERCENT`, converted at the capex month's month-end rate in the portfolio's own currency. Capex dates span 2025-12-01 to 2026-07-01 only and 157 portfolios share 2025-12, which reads as a migration date rather than 157 purchases. |
| Individuals vs companies | Available at loan level | `agg_loan_bands.BORROWER_TYPE` from `DIM_BORROWER.LEGAL_EBA_TYPE` via `BRG_CASE_BORROWER` (join on `CASE_SK`; the bridge has no `case_id`). Households 73.8% of loans, Non-financial corporations 4.7%, no borrower row 21.3%, `P` 0.2%. A joint loan takes the corporate type if any borrower is corporate. |
| Servicer segments (SMEs vs individuals in Spain, etc.) | Partly | `DIM_SEGMENT` via the loan snapshot. Servicer-defined labels, not a taxonomy: 21m of 21.8m loans sit in bare codes `01`/`02`/`04` (the Intrum PAM feed); the Spanish books carry `SMEs - Gescobro`, `Individuals - Intrum Servicing`, `Wizink - ...`. Shown as reported. |
| Balance band, age of debt | Available at loan level | `agg_loan_bands`. Outstanding per loan converted to EUR then banded; age = years since `DIM_CASE.DERIVED_DEFAULT_DATE` (99.3% filled; 247k loans dated before 1990 and 4.6k after the month-end go to Unknown). |
| Payer counts, receipts and reversals | Partly | `agg_collections_monthly`. About half of portfolios; the Intrum PAM feed reports no payer detail. Never compute a payer ratio over a set mixing `HAS_PAYER_DETAIL` true and false. |
| Legal / amicable / insolvency stage | **Not available** | `DIM_CASE.STATUS_CODE`, `STATUS_DESCRIPTION`, `CLOSING_CODE`, `CLOSING_DESCRIPTION`, `CLOSING_CATEGORY` are 100% NULL on all 22.5m current rows. A few servicer segment labels (`IVA`, `Bankruptcy`, `C - Tracing`) hint at process for a handful of portfolios; that is not a split. |
| Instalment amounts, arrangement terms | **Not available** | `FCT_CASE_FORBEARANCE` has three columns: case, start date, load timestamp. |
| Borrower age, demographics | **Not available** beyond legal type | No birth date anywhere. `GENDER` is filled for 38% of borrowers, `CREDIT_RATING` for 8%. |
| Servicer working methods, contact activity, promises to pay | **Not available** | No operational data in the warehouse at all. |
| Segment-split business plan | **Not available** | Servicer forecast: one segment per portfolio, all versions. Underwriting plan: portfolio level only. |
| Cost to serve across servicers | Intrum only | Commission, passthrough, net recoveries are absent, not zero, for every other servicer. |

## Servicer, deal source, reporting system: three different things

**Current rule (the manager's, 2026-10-12, live in the Servicing dashboard query
`work/servicing/sigma_queries/portfolios_element.sql`):**

```sql
case when deal_source_name = 'ORGANIC ORIGINATED' and country_code = 'UK' then 'Massey'   -- Equinox I and II
     when deal_source_name = 'ORGANIC ORIGINATED' and country_code = 'IT' then 'Fire'     -- Findomestic Spring
     when deal_source_name in ('ORGANIC ORIGINATED', 'LEGACY') and country_code = 'ES' then 'Gescobro'
     when deal_source_name = 'LEGACY' and country_code = 'IT' then 'Cerved'
     when deal_source_name = 'GESCOBRO' and country_code = 'ES' then 'Gescobro'
     else 'Intrum' end                                   as servicer_group
```

Measured 2026-10-12: Massey 2 portfolios (they send a case feed, reported by `massey`, so case
figures cover Intrum AND Massey), Fire 1 (no case feed: the label comes from the business),
Gescobro 8 (the legacy and GESCOBRO-sourced Spanish books), Cerved 3 (legacy Italy), Intrum the rest. The older rule
below is history: the retired `agg_` files used it.

The data engineer's earlier rule (received 2026-09-10, applied verbatim in all four
`agg_` files as `SERVICER`, `SUBSERVICER`, `SERVICER_FULL`):

```sql
case when deal_source_name = 'LEGACY' and country_id = 'ES' then 'Gescobro'
     when deal_source_name = 'LEGACY' and country_id = 'IT' then 'Cerved'
     else 'Intrum' end                                   as servicer,
case portfolio_bk when 'LEG-ES25001-U00/2512' then 'TDX'
                  when 'HEI-GR25001-U01/2512' then 'QQuant'
                  when 'HEI-GR25001-U02/2512' then 'QQuant'
                  else '' end                            as subservicer,
-- servicer_full = servicer, or 'servicer - subservicer' where one exists
```

- **Servicer** (`SERVICER_FULL`): who services the book. Use it for every
  "by servicer" chart. At July 2026: Gescobro 3 portfolios, Cerved 3,
  Intrum - QQuant 1, Intrum everything else.
- **Deal source** (`SERVICER_GROUP` / `DEAL_SOURCE`: ORANGE/HEIMDALL,
  BLUE/LOKI, LEGACY, GESCOBRO, ORGANIC ORIGINATED): the acquisition channel.
  Keep as a filter and a table column. The column name `servicer_group` is
  historical; do not read it as the servicer.
- **Reporting system** (`REPORTING_SYSTEM`, loan level only: intrum, cerved,
  gescobro, souq, massey): the servicer's platform.

Two things to raise with the engineer before anyone reads a servicer chart
as final (measured 2026-09-10):

1. Deal source `GESCOBRO` (3 portfolios in Spain, 35,739 loans whose
   reporting system is `gescobro`) maps to **Intrum** under the rule as
   written, because only `LEGACY` + `ES` maps to Gescobro. **Resolved
   2026-10-12** by the current rule above (5 portfolios by then).
2. Two of the three sub-servicer keys do not exist in `DIM_PORTFOLIO`:
   `LEG-ES25001-U00/2512` (the dimension has `LEG-ES25001-U01/2512`) and
   `HEI-GR25001-U01/2512` (it has `U02` and `U04`). Only
   `HEI-GR25001-U02/2512` resolves, so `Intrum - TDX` never appears and
   `Intrum - QQuant` covers one portfolio. Also, 57,781 Greek loans report
   through `souq`, which may be QQuant's platform.

The engineer's own query works from `MART_NPL_FLASH_REPORT` (`GCF_ACTUAL`,
`GCF_UNDERWRITING`, `CARRYING_AMOUNT`) joined to the FX table on
`monthly_avg`. Two differences from this layer, both deliberate here: the
flash report starts 2025-07-31 and collapses currency on 13 portfolio-months
(finding 2.4), whereas the `agg_` files read the fact and keep currency in
the grain; and the engineer converts carrying amount at the monthly average
whereas this layer converts stocks at month-end (`ultimo_value`). Totals
reconcile; a carrying figure will differ by the avg-vs-close rate.

## The raw Intrum PAM feed vs PROD (measured 2026-09-10)

`RAW.HYPERION_INTRUM_PAM.PAM` is Intrum's monthly PAM export, loaded whole
every month (14 deliveries so far, 42.5m rows, 2,697 Intrum portfolios,
periods 1996-08 to 2041-07 with actuals and forecasts in the same rows).
PROD's portfolio fact is the owned, current, past-months slice of it, merged
with the Cerved / Gescobro / Massey / Fire feeds. The conversion (dbt,
`staging/intrum_pam` -> `int_npl_portfolio_*` -> `fct_npl_portfolio_snapshot_monthly`):

- keeps `PMODE_NAME = 'Real'` only ("Adjust" = internal accounting batches);
- keeps months **before the file's extraction month** (drops ~1.5m forecast
  rows per file and the part-loaded current month);
- drops `IS_OWNERSHIP_CHANGE = 1` rows (legal-buyer transfers, zero balance);
- `TOTAL_BALANCE` = `RP_REMAINING_GCV + RP_REMAINING_INTEREST + RP_REMAINING_COST_FEES`;
  `GROSS_CASH_RECOVERIES` = `COLLTOTAL + SALESPROCEEDS`;
- adds a computed portfolio management fee (0.5% HEI / 1% LOK of
  collections), negates `RP_COMMISSION`, `RP_COSTS`, `COLLUNREMITTED`;
- remaps country `GE` -> `DE`, `UK` -> `GB`; applies a legal-buyer override list;
- replaces Intrum's `PORTFOLIOID` (e.g. `PT05003`) with Brocc's portfolio via
  an internal batch-to-portfolio list; unmapped batches get portfolio `-1`;
- numbers deliveries per batch-month as `SNAPSHOT_VERSION`, keeps the latest
  in the fact and all of them in `_VERSIONED`.

Verified for July 2026: every one of the 11,748 owned raw batches is in PROD;
balance matches to the cent; collections differ only by the sales-proceeds
term (375,000.00 on one batch).

**Querying raw directly, four guards or the number is wrong:** (1) one file
only, `_file_path = max(_file_path) where _file_path like '%/pam.pam.pam.2%'`,
otherwise each month counts up to 14 times; (2) `pmode_name = 'Real'`;
(3) `period_start_date < ` the file's extraction month
(`parse_json(_file_metadata):extract_ts`); (4) `coalesce(is_ownership_change,0) = 0`.
`SELLER_NAME` is inconsistently cased (`MILLENNIUM` / `Millennium`); compare
with `upper()`, or portfolios go missing. `PERIOD_START_DATE` is stored as
**VARCHAR** ('2005-06-01 00:00:00.0'), so cast it before comparing to a date;
`x in ('2005-06-01')` silently matches nothing. Worked example:
`work/.archive/2026-10-02-benchmark-investigation-trail/portugal_millenium.sql`.

**What raw has that PROD does not, and it is the good part.** In raw,
`FC_TOTAL` on a *past* month is the **original business plan for that month
and is never restated** — identical across all 14 deliveries (verified on
batch `PT050030000000`, June 2024: 5,434.51 in every file). So raw supports
actual-vs-plan over a portfolio's whole life, back to 2005. PROD's
underwriting forecast only begins 2025-06, so this is the only route to a
long-run plan comparison. `COLLTOTAL` on a past month, by contrast, **is**
restated as late cash arrives (same batch, January 2026: 0.00 in the first
seven files, 5,441.40 from the eighth on) — another reason to read only the
newest file. Raw also carries columns PROD drops entirely: remaining case
counts, investor IRR, book value, and the REO (repossessed property) block.
`RP_PURCHASE_PRICE` sits on the capex-month row only, so take it as a
per-batch `max()`, never a `sum()` down the months; `RP_REMAINING_GCV` is
populated for actual months and 0 for plan months, while
`RS_CLOSE_BOOK_VALUE` is populated for both.

**The loan level cannot reach back.** `PROD.NPL_COMMON.FCT_CASE_COLLECTION`
starts **2014-06-24** (134m rows, 160 portfolios), so no case-level query can
show anything from the 1996-2000 months above; 29 of the 40 affected batches
have case collections, but only from 2014 on. Its `max(collection_date)` is
also unusable: 841 rows are future-dated (the year-4570 problem), so always
bound with `collection_date <= current_date()`. The only other loan-level
candidate is the raw CAT feed, `RAW.HYPERION_INTRUM_CAT.TRANSACTIONS`
(24.7bn rows, 487 GB) — its date span is unmeasured, and a scan on the
X-Small warehouse is expensive, so probe it with `sample` first.

**Is there any collection history from before Intrum bought a batch?**
Measured 2026-09-10, and the answer is "almost none in the warehouse":

- PAM cannot show it. A batch enters the file in its capex month, so the
  series structurally starts at acquisition. The only exceptions are the 40
  bogus-capex batches above, whose pre-capex figures are reconstructed.
- `FCT_CASE_COLLECTION` starts 2014-06-24, and only **64,288 rows / EUR
  31.2m across 603 batches (0.15% of EUR 21.0bn)** are dated before their
  batch's capex month — all by **1 to 5 months**. That is deal-boundary
  timing, not prior-owner history.
- But **4,624,399 loans (24% of those on book at the latest snapshot) have a
  `REGISTRATION_DATE` before their batch's capex month**, so the servicer
  frequently held the case before the purchase completed. The cash from that
  window is simply not loaded.
- `RAW.HYPERION_INTRUM_CAT.TRANSACTIONS` **does** hold deep history: a 0.01%
  block sample (2.4m rows, 3 s) returned 18% of rows before 2014 and 2%
  before 2005. Whether those map to Brocc's batches is unverified, and the
  column carries junk dates (1900-01-01, 2099-12-30), so bound any query.
- Collections by the **original creditor**, before any servicer involvement,
  are in no feed at all. They would have to come from the seller at sale.

**When batches start collecting** (whole feed, measured 2026-09-10, in
`work/.archive/2026-10-02-benchmark-investigation-trail/collection_window_vs_capex.sql`): of 11,906
batches, 7,967 take their first payment in the capex month itself, 3,583
later (median 1 month, 90th percentile 7, max 151), 316 never collect, and
40 appear to collect before capex. Note that a batch has a row for every
month from capex onward, most of them zero, so `min(period_start_date)` is
the reporting start and not the first payment; filter on `colltotal <> 0`.

**Two acquisition dates.** Raw `CAPEX_DATE_M` is when **Intrum** bought the
batch from the seller (2005-2016 for the Portuguese Millennium books).
PROD `DIM_PORTFOLIO.CAPEX_DATE` is when **Brocc** bought the portfolio from
Intrum (2025-12 to 2026-07). Both are real; say which. This is the answer to
why PROD's capex dates cluster in December 2025.

**Raw data-quality finding (report, do not work around silently):** six
`pam.pam.pam_perimeter.*` files (93,306 rows) were loaded into the `PAM`
table as well as into `PAM_PERIMETER`. They have no PAM columns filled and
break a naive `max(_file_path)`.

Display currencies: `ref_display_currency` gives EUR per unit of USD, GBP
and SEK by month (PMI, 2018-01-31 to 2026-08-31). **Divide** an EUR figure
by it; flows by `EUR_PER_UNIT_FLOW`, stocks by `EUR_PER_UNIT_STOCK`. July
2026: USD 0.87586 (avg) / 0.87070 (month-end), GBP 1.17109 / 1.16859, SEK
0.09053 / 0.09103.

Load costs measured on `NPL_ANALYST_WH` (X-Small), 2026-09-09:

| Dataset | Window | Rows | Time |
|---|---|---|---|
| `agg_portfolio_summary` | 120 months | 4,655 | 5–8 s |
| `agg_collections_monthly` | 13 months | 151,351 | ~3 s |
| `agg_collections_monthly` | 120 months | 1,163,295 (940 MB in pandas) | 560 s |
| `agg_loan_bands` | one month-end, all portfolios | 2,479 | 74 s |
| `agg_loan_detail` | one portfolio, one month-end | 8,104 | ~2 s |

Reference figures, July 2026 (the latest complete month), complete months,
EUR, all reproduced through Sigma's own connection as well:

| Figure | Value |
|---|---|
| Portfolios reporting | 250 |
| Collected | 41,282,117.95 |
| Current forecast | 39,260,284.52 (collected ÷ forecast 1.05150) |
| Underwriting plan | 37,732,242.12 on 249 of 254 rows |
| Portfolio balance | 48,789,794,448.86 |
| Carrying amount | 1,263,184,284.58 (249 of 254 rows carry a value) |
| Net collections (Intrum only) | 29,464,696.64 |
| Collected by servicer group | ORANGE/HEIMDALL 22,820,768.28 · BLUE/LOKI 8,339,000.92 · LEGACY 6,983,164.71 · Unknown 1,381,050.93 · GESCOBRO 1,044,951.74 · ORGANIC ORIGINATED 713,181.37 |
| Loan detail, `LOK-DE24016-U01/2512` at 2026-07-31 | 8,104 loans, none duplicated |
| Loan bands at 2026-07-31 | 186 portfolios, 21.8m loans |

---

# Part 3 — Optimising without breaking anything

These 16 files are a **base layer**: built for correctness and auditability,
not for dashboard latency. Timed cold with the result cache off on 2026-09-09:

| Band | Files | Time |
|---|---|---|
| Fast | `monthly_flash_report` 0.8s, `ref_fx_rate` 1.3s, `monthly_forecast_restatement` 1.7s, `monthly_portfolio_restatement` 3.0s, `monthly_portfolio_forecast` 4.8s | < 5s |
| Medium | `base_collection` 7.7s, `ref_portfolio` 8.9s, `monthly_borrower_collections` 10.2s, `base_loan_carrying` 16.7s, `ref_borrower` 20.4s, `ref_calendar` 26.6s, `monthly_portfolio_performance` 28.1s, `monthly_loan_performance` 29.6s, `ref_loan` 30.9s | 5–31s |
| Diagnostic | `base_data_quality` 38.5s, `base_reconciliation` 139.1s | run on demand |

**The collections chain, measured 2026-09-11** (X-Small, defaults as shipped; warm re-runs of the two base files came back in ~20s, so the base figures are the cold case):

| File | Window / scope | Rows | Time |
|---|---|---|---|
| `base_case` | one month, one portfolio | 8,104 | 53s |
| `base_case_collection` | 7 months, one portfolio | 10,405 | 103s |
| `agg_portfolio_collection_monthly` | 26 months, all 250 portfolios | 3,203 | 17s |
| `agg_deal_collection_monthly` | 26 months, all deals | 2,028 | 14s |
| `agg_vehicle_collection_monthly` | 26 months, all SPVs | 720 | 13s |
| `agg_servicer_collection_monthly` | 26 months, all servicers | 235 | 16s |
| `base_collection_reconciliation` | one month | 14 | 26s |

The `agg_` files aggregate inside Snowflake, so unlike the base layer they are close to interactive and need no row cap. `base_case_collection` is the slowest thing here — if the question is a total rather than the detail, an `agg_` file answers it in a sixth of the time.

**None of these is interactive.** A dashboard tile needs sub-second, and most
of these are 10–30s — for a *single portfolio*, which is what the default
`$portfolio_filter` gives you. Across all 250 they are worse.

That is the correct shape for a base layer. Do not try to make these fast.
Build aggregates on top and point the dashboard at those.

> Note: you cannot materialise from `local-workspace` — `NPL_ANALYST` holds
> `SELECT` and `USAGE` only. A scheduled aggregate is a dbt model in
> `brocc-data` (a Rule 1 request), or the BI tool's own extract layer.

---

## Writing SQL people can read

⚠ **Read [`.claude/sql-style.md`](../sql-style.md) before creating a `.sql`
file from scratch.** It is the full house style, kept in one place so it cannot
drift between agents. The three rules you must not get wrong even if you skip
the read:

- ⚠⚠ **THE USER'S OWN SQL IS THE USER'S.** Handed a query to fix, change only
  what is broken. Keep their keywords, their CTE names, their layout. House
  style applies to files **you** create from scratch, never as a reason to
  restyle working code.
- **UPPERCASE keywords and functions, lowercase identifiers**, and a header
  giving the grain plus any measured figure with the date it was measured.
- **Comments say *why*, not what.** A filter that works around a data-quality
  problem names the problem, or it becomes folklore nobody can audit.

## The ten things that must survive optimisation

Each looks like dead weight. Each is load-bearing, and the cost of removing it
was measured, not guessed. If you change one, re-run `base_reconciliation.sql`.

| # | Construct | Where | Cost of removing it |
|---|---|---|---|
| 1 | Collections matched on **`CASE_BK`**, not `CASE_SK` | `monthly_loan_performance` | **EUR 128.2m / 12 months** book-wide; 15.01% for ORANGE/HEIMDALL |
| 2 | Windows **partitioned by `CASE_BK`** | `monthly_loan_performance` | 5,843 loan-months (6.0%) lose `OPENING_BALANCE`, stranding EUR 110.6m of closing balance |
| 3 | The **`union all` for the unknown portfolio** | `monthly_portfolio_performance`, `..._restatement`, `..._forecast` | **2.69% of a month's collections**; EUR 16.92bn of balance over 24 months |
| 4 | **`left` join** on every dimension | all portfolio-level files | Up to **EUR 10.67bn** dropped — `product_sk` and five others carry an orphan `-1` |
| 5 | **`qualify snapshot_version = max(...)`** | `monthly_portfolio_forecast` (servicer leg) | Sums successive revisions of the same month as if they were extra money |
| 6 | **`rate_type = 'PMI'`**, and the rate **multiplied, not inverted** | `ref_fx_rate` | `FIXED` converts nothing; inverting is a **122× error** on SEK |
| 7 | The **identity FX row** unioned at 1.0 | `ref_fx_rate` | Silently drops every row already in the target currency — usually the largest block |
| 8 | **`collection_date <= current_date()`** and `period_end_date <= current_date()` | several | Phantom future months (rows dated to 4570); negative carrying values past the forecast horizon |
| 9 | **`::number(38, 6)` casts** on DECFLOAT | `base_loan_carrying`, `monthly_flash_report`, `ref_portfolio`, `monthly_portfolio_performance` | pandas gets exponent/significand dicts; the first `.sum()` raises |
| 10 | **`DIM_COUNTRY` joined on `iso_alpha2_code`**, not `country_id` | `base_collection`, `base_loan_carrying`, all three `agg_` files | `DIM_COUNTRY.COUNTRY_ID` is a hash key; every fact carries ISO alpha-2 codes. The natural join on `country_id` matches **zero rows** and `country_name` is NULL everywhere, with no error. Non-ISO `UK` (48,784 loans) resolves to nothing either way and is kept as the raw code |

### The pattern to watch for

Every one of these looks like something a reasonable optimiser would remove:
an inner join is faster than a left join, a `union all` looks like dead weight,
`CASE_SK` is the natural key on the fact, a `qualify` looks redundant, a cast
looks cosmetic, `country_id = country_id` looks like the obvious join. **Each removal makes the query faster and the number wrong,
with no error.** That is why they are commented inline as well as listed here.

### Safe optimisations

- Narrow `$portfolio_filter` and the date window — that is what they are for.
- Select fewer columns; the dimension joins are the expensive part.
- Pre-aggregate **on top** of these files, never by editing them.
- Cache or extract in the BI layer.
- Push the aggregate into dbt in `brocc-data` if it needs to be scheduled.

---

## The `agg_` layer

`agg_collections_monthly`, `agg_portfolio_summary`, `agg_loan_detail` and
`agg_loan_bands` are aggregates over the base layer and inherit every guard above. That inheritance
is **verified, not assumed** — for 2026-07-31, batch grain, portfolio grain and
the raw fact all return **EUR 41,282,117.95**, identical to the cent.
`base_reconciliation` check 14 publishes that figure so a dashboard can be
compared against it.

Two extra guards live only in the `agg_` files:

| Construct | Cost of removing it |
|---|---|
| `IS_COMPLETE_MONTH` — incomplete months excluded | The newest month is part-loaded; 2026-08-31 showed 7 portfolios and EUR 3.06m against July's 250 and EUR 41.28m. A 93% "collapse" that is purely a load lag. |
| Orphan batch keys keep their `batch_sk` in the label | 3 orphaned `batch_sk` hashes all collapsed to one `'Unknown'` and broke the grain — 3 duplicate rows per batch-month. Caught by a grain check, not by eye. |


---

# Part 4 — Findings from building the base layer (measured 2026-09-09)

Everything below was measured against the live warehouse, not inferred from
the dbt models. Row counts and percentages are exact as at that date and
will drift. Where a claim came from a query header written earlier rather
than from that session's measurement, it says so.

### 4.0 Findings register

Every row was measured against the live warehouse. **Fixed** = corrected in
the base layer. **Live** = a property of the warehouse you must design around;
no query can fix it.

| # | Finding | Impact | Status |
|---|---|---|---|
| 2.1 | `COLLECTION_BK` is not a row key — 4.1m keys shared by 47.8m rows, none identical | Deduping deletes ~36% of collections, EUR 10.64bn | Live |
| 2.2 | Restatement is the norm — 95.7% of portfolio-months have 2+ versions (up to 15) | Single-vintage movement is part restatement | Live |
| 2.3 | Servicer forecast is 44× finer; 1,172 portfolio-months carry multiple versions | Naive sum double-counts | **Fixed** |
| 2.4 | Flash mart collapses currency with `any_value()` | Only **13 of 2,133** rows ambiguous (2.43% of GCR); totals sound, currency/country slices are not | Live |
| 2.5 | Carrying `CLOSING_VALUE` diverges past the forecast horizon — 792 negative rows, worst ≈ −EUR 2.88tn | Poison beyond today; clean on/before | **Fixed** (bounded) |
| 2.6 | FX: `FIXED` is identity-only; the rate is base-per-quote so must be **multiplied** | Inverting = 122× error on SEK | **Fixed** |
| 2.7 | `FCT_CASE_FORBEARANCE` is one row per case, no end date; disagrees with the flag on ~141k loans | Cure/re-default not measurable | Live |
| 2.8 | Loan×month joined collections on `CASE_SK`, and partitioned windows on it | **EUR 128.2m / 12m** book-wide (15.01% ORANGE/HEIMDALL); 5,843 broken roll-forwards | **Fixed** |
| 2.9 | Unexplained movement is 90.1% interest accrual (exact on 96.2% of rows) | Not a bug — write-offs are the remainder | Explained |
| 2.10 | `PORTFOLIO_SK = '-1'` absent from `DIM_PORTFOLIO` | **2.69% of a month's collections** dropped; EUR 16.92bn balance | **Fixed** |
| 2.11 | Six dimension keys on the portfolio fact are orphaned (`product_sk` on EUR 10.67bn) | Inner join drops that balance | Live — **left join always** |
| 2.12 | Loan vs portfolio book size never reconciles; ratio is per-servicer (87%–146%) | Cannot cross-check book size | Live |
| 2.13 | Borrower bridge on `CASE_SK` loses 1,678 borrowers (0.0102%) but **EUR 0.00** | Counts only, not money | Live, immaterial |
| 2.14 | Collapsed portfolio fact ≠ `max(snapshot_version)` of the versioned one | 1 real portfolio, EUR 3,040.72 | Live, immaterial |
| 2.15 | `GROSS_CASH_RECOVERIES` is **undocumented**; `GCF_ACTUAL` is an actual with a forecast prefix | The headline number has no warehouse definition | Live — **ask the data team** |
| 2.16 | `SECURITY_CLASS` docs list a third value that doesn't exist; contradicts `SECURED_FLAG` on 5,092 loans | Secured is 0.02% of the book | Live |
| 2.17 | `DIM_COUNTRY.COUNTRY_ID` is a hash key; every fact carries ISO alpha-2 codes | A join on `country_id` gives NULL `country_name` on **100%** of rows, no error; `UK` (non-ISO) resolves to nothing | **Fixed** — join on `ISO_ALPHA2_CODE` in all 5 files that use the dimension |
| 2.18 | A NULL surrogate key makes an `'(unknown ...)' || sk` label concat to NULL — `||` is NULL-propagating | The row keeps its money and loses its label; in the `agg_` files the `like $filter` clause then dropped it entirely (9 rows each on deal and vehicle). 1 NULL `DEAL_SK` and 1 NULL `LEGAL_BUYER_SK` on the collection fact at 2026-07-31, 2 each on the loan snapshot, 1 NULL `BATCH_SK` on the portfolio fact | **Fixed** — `coalesce(sk, 'null key')` inside every label |

#### Verified clean — negative evidence, so the absence of a finding is evidence

| Check | Result |
|---|---|
| Dimension uniqueness — 16 dimensions | **0** duplicate keys, **0** null keys |
| Orphan foreign keys — 16 fact/dim pairs beyond the portfolio fact | **0** orphans |
| Allocation mart vs loan snapshot balances — 12,419,544 loans | **0** mismatched, **0** absent |
| `FCT_REVALUATION` vs `FCT_CARRYING_AMOUNT` — 60 revaluations | **60** match closing exactly, 0 missing |
| Month continuity — portfolio (361), loan (147), carrying (187) | **no gaps** in any series |
| Flash mart vs portfolio fact, and vs accounting forecast | match **exactly** |
| Collections where both feeds exist (PLN, EUR) | 101.4% / 100.1% |

Re-runnable as `base_reconciliation.sql` — **15 checks, 32 rows** (some report
per currency), 12 rows currently `RECONCILES`. Check 15 (country join) added
2026-09-09.

---

### 4.1 Coverage

`PROD` holds **32 objects** in two schemas — `NPL_COMMON` (26) and `COMMON` (6).

| | Objects queried |
|---|---|
| The original six `01_`–`06_` files | 17 of 32 |
| The current 15-file base layer | **29 of 32** |

What the original six were missing: all three forecast tables, the flash
report mart, loan-level carrying amount, revaluation, both version-history
tables, and the whole `COMMON` schema — including the FX rates that five of
those six files tell you to use for multi-currency totals.

Three objects are deliberately still out; see 4.5 below.

---

### 4.2 Findings that change numbers

Ordered by how badly each one bites if you don't know about it.

#### 2.1 `FCT_CASE_COLLECTION.COLLECTION_BK` is not a row key — never dedupe on it

| Measure | Value |
|---|---|
| Rows | 134,097,608 |
| Distinct `COLLECTION_BK` | 90,390,143 |
| Rows where it is NULL | 69,551 |
| Keys shared by >1 row | 4,141,626 |
| Rows involved | 47,779,540 (**36% of the table**) |
| Money involved | **EUR 10.64bn** |
| Of those 4.1M keys, how many have all rows identical | **0** |

Every one of those 4,141,626 shared keys covers rows that differ on
(`CASE_SK`, `COLLECTION_DATE`, `AMOUNT`). They are genuinely different
payments that happen to carry the same business key — not duplicate loads.

**Consequence.** A `select distinct`, a `group by collection_bk`, or a
qualify-dedupe on this column silently removes about a third of real
collections. The result still sums and charts perfectly happily.

**What to do.** Treat the fact row as the grain. There is no column that
uniquely identifies a payment; if you need one, build a surrogate and own it
as yours, not the warehouse's. `base_collection.sql` does this and says so.

#### 2.2 Restatement is the normal state of portfolio actuals

From `FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED` (20,697,455 rows, 15 snapshot
versions, spanning 1996-08-31 → 2026-08-31):

| Scope | Portfolio-months | Single version | Restated | % restated | Max versions |
|---|---|---|---|---|---|
| All history | 6,582 | 281 | 6,301 | **95.7%** | 15 |
| Last 12 months | 2,033 | 281 | 1,752 | **86.2%** | 15 |

Only 281 portfolio-months in the entire table have ever had exactly one
version.

**Consequence.** Any month-on-month movement read off a single vintage is
part performance and part restatement, and the two are not separable without
this table. A "collections fell in June" story can be an April-to-May
re-report.

**What to do.** Size it with `monthly_portfolio_restatement.sql` before
explaining a movement as business performance.
`monthly_portfolio_performance.sql` collapses to the current view, which is
correct for "what do we believe now" and wrong for "what changed".

#### 2.3 The servicer forecast double-counts if you sum it

`FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY` — 1,917,510 rows, unique
on (`PORTFOLIO_SK`, `PERIOD_END_DATE`, `BATCH_SK`, `SEGMENT_SK`), which is
**44× finer** than the other two forecasts.

| Measure | Value |
|---|---|
| Portfolio-months | 43,302 |
| ...with >1 `SNAPSHOT_VERSION` | 1,172 (max 12) |
| ...with >1 vintage | 201 (max 24) |
| Max batch × segment rows in one portfolio-month | 3,238 |

Successive versions are revisions of the same month, not additional money.

**What to do.** Filter to the newest version per portfolio-month first.
`monthly_portfolio_forecast.sql` does, and exposes `N_VERSIONS_AVAILABLE` so
the 1,172 affected rows are visible. Note the tradeoff it accepts: a batch
appearing only in an older version is dropped, which is right for a portfolio
total but means the file is not a full audit trail.

#### 2.4 `MART_NPL_FLASH_REPORT` collapses currency, and its label can be wrong

Read from
`brocc-data/transformation/dbt/models/marts/npl_common/marts/mart_npl_flash_report.sql`.
The model groups to portfolio × month and takes `any_value(currency_id)`.

**Consequence — but measured, because it is narrower than it sounds.** Across
the 2,133 portfolio-months in the flash window:

| `any_value()` column | Portfolio-months where it was ambiguous |
|---|---|
| `currency_id` | **13** (0.6%) |
| `country_id` | **13** (0.6%) |
| `deal_source_sk`, `legal_buyer_sk`, `security_class_sk` | **0** |

Those 13 rows carry EUR 30,954,527.62 of EUR 1,274,043,789.43 — **2.43% of
collections**. So the flash report's **totals are sound** (they reconcile to
the fact exactly), and its deal-source / legal-buyer / security-class slices
are always safe. Only a **currency or country slice** is unreliable, and only
for those 13 rows. Do not sum the flash report *by currency*.

`monthly_portfolio_performance.sql` keeps currency in the grain deliberately,
so for those multi-currency portfolios the two files disagree.

**What to do.** That disagreement *is* the explanation — do not try to
reconcile it. Use the flash report when the question is "what does the
published report say"; use `monthly_portfolio_performance` for anything that
has to foot.

#### 2.5 Carrying amount diverges past the forecast horizon

`FCT_CARRYING_AMOUNT` (43,773 rows, unique on portfolio × period).
`CLOSING_VALUE` is computed recursively — opening + interest − gross
forecast — so once the forecast runs out the recursion compounds.

| Measure | Value |
|---|---|
| Rows with negative carrying value | 792 |
| First negative period | 2026-11-30 |
| Worst single row | ≈ −EUR 2.88tn |
| Table projects to | 2041-06-30 |
| Negative rows on or before today | **0** |

Actuals are clean; the projection is not. `MART_NPL_FLASH_REPORT` exposes
this same column as `CARRYING_AMOUNT` and runs to 2041, so it inherits the
problem.

**What to do.** Bound `period_end_date <= current_date()`. Both new carrying
files default to that. Never chart carrying amount to the end of the table.

*(2.5 was documented in the `base_data_quality` header before this review; the figures
were re-confirmed this session.)*

#### 2.6 The FX rate is already the multiplier, and `FIXED` converts nothing

Two traps in one table, and between them they can put a 122× error on a chart.

**`RATE_TYPE = 'FIXED'` is not an alternative basis.** The table holds exactly
22 (base, quote, rate_type) combinations. `FIXED` appears only as the identity
self-pair — EUR→EUR and SEK→SEK, both 1.0. Every real cross rate is `PMI`
(EUR→ AUD CHF CZK DKK GBP HUF NOK PLN SEK USD, and SEK→ the same set plus
EUR). Filtering to `FIXED` returns one useless row and converts nothing.

**The rate is base-per-quote, so you multiply — do not invert.** The column
names `BASE_CURRENCY` / `QUOTE_CURRENCY` suggest the market convention "units
of quote per one base". It is the other way round. Raw EUR-base `PMI` values
for 2026-07-31:

| Quote | `MONTHLY_AVG` |
|---|---|
| GBP | 1.17109 |
| CHF | 1.08043 |
| USD | 0.87586 |
| PLN | 0.23160 |
| DKK | 0.13378 |
| SEK | 0.09053 |
| HUF | 0.00278 |

One GBP is worth more than one EUR and one SEK far less, so these are EUR per
unit of the foreign currency — multiply a local amount by the rate directly.

**Consequence.** Inverting values SEK 32.2m of July collections at EUR 356m
instead of EUR 2.9m. Nothing errors; the dashboard just shows a number an
order of magnitude out, and SEK is the largest local-currency block.

**Also.** There is no `PMI` self-pair, so a plain join silently drops every
row already in the target currency — usually the biggest block of all.
`ref_fx_rate.sql` unions the identity row in at 1.0 so a NULL rate now means
genuinely unconvertible rather than "same currency".

*(Both of these were found by testing a conversion end to end after the file
was written. The first version of `ref_fx_rate.sql` had `FIXED` as its
default and inverted the rate.)*

#### 2.7 `FCT_CASE_FORBEARANCE` is one row per case, not per event

5,761,218 rows and 5,761,218 distinct `CASE_SK` — exactly one each. It has
**three columns**: `CASE_SK`, `FORBEARANCE_START_DATE`, `AS_OF_TS`.

**Consequence.** No end date, no type, no status — so forbearance **duration,
cure and re-default cannot be measured from this table at all**. That matters
because cure and re-default rates are the obvious next analysis. Current
forbearance state has to come from
`FCT_CASE_SNAPSHOT_DAILY.FORBEARANCE_FLAG` instead.

**And the two sources disagree.** At 2026-07-31, 5,493,364 loans are flagged
`True` but only 5,353,222 have a forbearance row — 140,142 missing — while
955 loans flagged `False` do have one. Roughly 141k loans, so pick one source
per number and state which.

**Dates are also not all plausible:** 42,810 rows start before 1990 (earliest
1967-11-01) and 6 are dated in the future (latest 2026-12-03).

#### 2.8 The loan × month roll-forward had two bugs, both from using the versioned key

Found by investigating why `UNEXPLAINED_MOVEMENT` exists — the answer turned
out to be mostly benign, but the investigation surfaced two real defects in
`monthly_loan_performance.sql`. Both have the same root cause: `DIM_CASE` is
SCD2, the facts carry the **versioned** `CASE_SK`, and the file used it where
the durable `CASE_BK` was needed. On the default portfolio, **3,243 of 8,104
loans (40%) change version within a 12-month window.**

**Bug 1 — collections were understated by 20%.** The collections CTE matched
on `CASE_SK`, so payments recorded against a different version of the same
loan were dropped. The loan-month row still appeared, and still looked
normal — just with `COLLECTED` too low.

| | Amount |
|---|---|
| Collections matched on `CASE_SK` (before) | EUR 4,872,828.21 |
| Collections matched on `CASE_BK` (after) | **EUR 5,853,777.91** |
| Recovered | **EUR 980,949.70 across 554 loan-months** |

That is a **20.1% understatement** of collections on this portfolio.

**And it generalises — it was not one unlucky portfolio.** Re-measured across
the whole book, 12 months to 2026-07-31:

| Deal source | Portfolios | Collections via `CASE_BK` | Lost by `CASE_SK` | % lost |
|---|---|---|---|---|
| ORANGE/HEIMDALL | 15 | EUR 811,733,243.40 | EUR 121,872,783.29 | **15.01%** |
| BLUE/LOKI | 132 | EUR 75,558,907.20 | EUR 6,333,434.43 | 8.38% |
| ORGANIC ORIGINATED | 2 | EUR 6,513,760.67 | EUR 0.00 | 0.00% |
| (no deal source) | 2 | EUR 30,052.54 | EUR 150.15 | 0.50% |

**EUR 128.2m of collections over 12 months**, concentrated in
ORANGE/HEIMDALL. This was the single largest error found.

**Bug 2 — the roll-forward restarted at every version change.** The `lag()`
windows partitioned on `CASE_SK`, so a loan that changed version got a NULL
`OPENING_BALANCE` mid-series, taking `BALANCE_MOVEMENT`,
`UNEXPLAINED_MOVEMENT` and `RECOVERY_RATE_ON_OPENING` with it.

| | Rows |
|---|---|
| Loan-months with a real prior month but NULL opening (before) | **5,843 — 6.0% of rows** |
| Same, after repartitioning on `CASE_BK` | **0** |
| NULL openings remaining | 8,104 = exactly one per loan's genuine first month |

EUR 989,932 of collections and EUR 110.6m of closing balance sat on those
broken rows. The header called it "a window-edge artefact, not missing data",
which is true of a loan's genuine first month and **false** for these — the
comment actively concealed the bug.

**Both fixed.** `CASE_BK` is safe here: verified that a loan never has two
`CASE_SK` versions on book at the same month-end (max 1 across all 97,232
loan-months), so the grain is unchanged and nothing fans out. The file now
also exposes `COLLECTED_THIS_VERSION_ONLY` and
`COLLECTED_ON_OTHER_VERSIONS` so the difference is auditable rather than a
claim in a comment.

**Generalise this.** Any join from a fact to a loan on `CASE_SK`, and any
window partitioned by it, has the same exposure. `base_collection.sql` and
`ref_loan.sql` join `DIM_CASE` on `CASE_SK` deliberately — that is correct,
because they resolve the point-in-time attributes of that version. The rule
is: **`CASE_SK` to describe a version, `CASE_BK` to identify a loan across
time.**

#### 2.9 So what *is* unexplained movement? Mostly interest accrual

After the fixes, on 89,128 loan-months with a complete roll-forward:

| Component | Amount | Share |
|---|---|---|
| Total unexplained movement | EUR 4,775,152.73 | |
| Interest + fee accrual | EUR 4,303,591.97 | **90.1%** |
| Residual after accrual | EUR 471,560.76 | 9.9% |

Accrual explains it **exactly** (to the cent) on **85,723 of 89,128 rows —
96.2%**. It is overwhelmingly *positive*, i.e. balances growing, which no
missing payment could cause: a lost payment makes the residual negative.

Of the 3,405 rows accrual does not explain, principal fell on 2,142. For 654
of them the residual equals the principal movement to within EUR 1 **and
collections were exactly zero** — principal written down with no payment.
That is a write-off or servicer restatement, which is precisely what the
column is designed to surface rather than hide.

**On the duplication question:** the `COLLECTION_BK` non-uniqueness in 2.1
is **not** the cause and could not be. Duplicate keys would make collections
*over*-count, not vanish; and nothing in this pipeline dedupes on that
column. The real loss was the versioned-key join in Bug 1 above.

#### 2.10 `PORTFOLIO_SK = '-1'` is not in `DIM_PORTFOLIO` — it was costing 2.69% of collections

The most consequential finding, because **every file in the base layer scopes
by `DIM_PORTFOLIO`**, and that dimension is keyed by hash — so the `-1`
Unknown sentinel matches nothing and an inner join drops it silently.

| Fact | Orphan rows | Amount |
|---|---|---|
| `FCT_PORTFOLIO_SNAPSHOT_MONTHLY` | 1,853 over 24 months | EUR 16.92bn balance, EUR 38.11m collections |
| `FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED` | 13,707 | EUR 153.61bn balance |
| `FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY` | 36,852 | EUR 450.59m forecast |
| Accounting + underwriting forecasts, `FCT_CARRYING_AMOUNT`, `MART_NPL_FLASH_REPORT` | **0** | clean |

**At 2026-07-31 that is 203 rows, EUR 1,150,528,026.65 of balance (1.53% of
the month) and EUR 2,579,774.05 of collections — 2.69% of the month's
collections.**

Worse than the size: the actuals fact is affected and the accounting/
underwriting forecasts are **not**, so actual-vs-forecast variance was
distorted in one direction only — actuals short, forecast complete.

It is essentially portfolio-level. The loan facts carry just 2 snapshot rows
(EUR 29,755) and 1 collection row (EUR 10) for it.

**Fixed** in `monthly_portfolio_performance`, `monthly_portfolio_restatement`
and `monthly_portfolio_forecast`, which now `UNION` the orphan in and label it
`(unknown portfolio -1)` — visible, and excluded by any narrower
`$portfolio_filter`. Verified: the month total now matches the raw fact
exactly, and 5 / 90 / 48 previously-dropped rows are back with grain intact.

#### 2.11 Six dimension keys on the portfolio fact point at rows that don't exist

The same `-1` sentinel appears in `deal_source_sk`, `deal_sk`, `segment_sk`,
`security_class_sk`, `legal_buyer_sk` and `product_sk`, none of which contain
it. Plus 3 genuinely orphaned `batch_sk` hashes.

| Key | Rows | Balance at risk |
|---|---|---|
| `product_sk` | 66–70 | **EUR 10.67bn** |
| `deal_source_sk`, `deal_sk`, `segment_sk`, `security_class_sk`, `legal_buyer_sk` | 203 | EUR 1.15bn |
| `batch_sk` (3 real hashes, not `-1`) | 3 | EUR 74.44m |

**Consequence.** An **inner** join to any of those dimensions silently drops
that balance — up to EUR 10.67bn on a product slicer. `FCT_CASE_SNAPSHOT_DAILY`
is clean; this is portfolio-level only.

Every base-layer file already uses `left` joins for these, so they are safe.
The exposure is in whatever gets built on top: **always left join, and render
a NULL dimension name as "Unknown" rather than filtering the row away.**

#### 2.12 Loan-level and portfolio-level book size do not reconcile, by design

Not a bug to fix — a definitional difference that varies by servicer, so it
will never close.

| Deal source | Portfolios | Loan level as % of portfolio level |
|---|---|---|
| ORANGE/HEIMDALL | 18 | **146.2%** |
| BLUE/LOKI | 219 | 112.2% |
| LEGACY | 6 | 102.9% |
| GESCOBRO | 3 | 100.2% ✅ |
| ORGANIC ORIGINATED | 3 | 87.0% |

It is **not** principal-vs-total either: principal alone ranges from 51.6% to
110.8% of portfolio balance depending on currency, so no component matches.

**What to do.** Quote book size from **one** level, say which, and never
present a cross-level check as a control. Collections *do* reconcile where
both feeds exist (PLN 101.4%, EUR 100.1% on the portfolios that have loan
detail); the shortfalls elsewhere are the PAM-vs-CAT feed split, measured at
61 of 149 EUR portfolios having no loan detail at all.

#### 2.13 What the borrower bridge does and does not lose

`BRG_CASE_BORROWER` is keyed on `(CASE_SK, BORROWER_SK)` — both versioned, as
its own dbt model comment states. Joining it to the snapshot on `CASE_SK`
therefore reaches only the version on book.

- **Borrower counts:** 16,380,298 via `CASE_SK` vs 16,381,976 via `CASE_BK` —
  1,678 borrowers, **0.0102%**.
- **Money: zero loss.** Every collecting `case_sk` in the tested scope has a
  bridge row — EUR 11,433,495.22 in scope, EUR 0.00 unreachable, 0 of 38,764
  rows.

So the borrower files are sound for sums and marginally incomplete for
distinct-borrower counts. Left as is, and documented.

#### 2.14 The collapsed portfolio fact is not the versioned table's latest version

Do not try to reproduce either table from the other. At 2026-07-31, 6 of 254
portfolio-currency pairs differ: 5 are the `(unknown -1)` portfolio (the
versioned table lacks it for SEK/CHF/GBP/DKK and shows GCR 0 for EUR), and
exactly **one real portfolio** — `LEG-ES25002-U01/2512` EUR, EUR 3,040.72.

Consequence: `monthly_portfolio_restatement.IS_LATEST_VERSION` does not always
mark the row `monthly_portfolio_performance` reports. Immaterial in money,
but it means the two files answer slightly different questions.

#### 2.15 The headline number is undocumented, and one column name lies

Found by asking what the abbreviations actually mean — the semantic layer,
which grain and reconciliation checks cannot reach.

**`GROSS_CASH_RECOVERIES` has NO description** in either
`FCT_PORTFOLIO_SNAPSHOT_MONTHLY` or its versioned sibling. This is *the*
headline collections figure — the one a CEO dashboard leads with — and the
warehouse carries no definition of it. "GCR" is not a warehouse term at all;
it is shorthand used in this analysis. By contrast `NET_CASH_RECOVERIES` **is**
documented, and precisely:

> gross_cash_recoveries − portfolio_mgmt_fee − commission − passthrough_cost −
> unremitted_collections (Intrum actuals only)

— which is the warehouse itself confirming the Intrum-only limitation in the dashboard table in 4.8.

**`GCF_ACTUAL` is misnamed.** In `MART_NPL_FLASH_REPORT`, `GCF` means *Gross
Collections Forecast* — `GCF_ACTIVE` is "Gross collections forecast from
active/accounting view", `GCF_UNDERWRITING` likewise. But `GCF_ACTUAL` is
documented as **"Actual gross cash collections"**. It is an actual wearing a
forecast's prefix. Anyone reading column names to build a dashboard will
reasonably mis-read it as a third forecast.

#### 2.16 `SECURITY_CLASS` — the docs describe a value that does not exist

`DIM_SECURITY_CLASS.SECURITY_CLASS_NAME` is documented as:

> Standardized security class name (Secured, Unsecured, or **Purchased Real
> Estate**)

The dimension holds **two** rows: `S` → Secured, `U` → Unsecured. There is no
Purchased Real Estate. Either the category was dropped or it has never
appeared; the description was not updated.

**And it contradicts `SECURED_FLAG`.** At 2026-07-31:

| `SECURITY_CLASS_NAME` | Loans | of which `SECURED_FLAG` = true | flag null |
|---|---|---|---|
| Unsecured | 21,828,390 | **5,092** | 14,798,328 |
| Secured | 4,031 | 1,900 | 1,582 |

Two things to take from this. **Secured is 0.02% of the book** — 4,031 loans
of 21.83m — so any "secured vs unsecured" split is effectively a single-bar
chart, and worth sanity-checking with the business before it is presented.
And the flag disagrees with the class on 5,092 loans, so the earlier advice
"use `SECURITY_CLASS_NAME` rather than the 68% null `SECURED_FLAG`" is right
in preference but not a guarantee they agree.

#### 2.17 `DIM_COUNTRY.COUNTRY_ID` is a hash key — the facts carry ISO codes

`DIM_COUNTRY` is keyed on a 32-character hash (`3e30ce90… / ES`), but every
fact that carries a country carries the **ISO alpha-2 code itself**:
`FCT_PORTFOLIO_SNAPSHOT_MONTHLY`, `FCT_CASE_SNAPSHOT_DAILY`,
`FCT_CASE_COLLECTION` and `MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION` all hold
`'ES'`, `'PT'`, `'FR'` … So the natural-looking join
`co.country_id = f.country_id` matches **zero rows** and `country_name` comes
back NULL on every row, with no error. Measured 2026-09-09 on the two
loan-level facts:

| Fact | Distinct codes | Resolve via `country_id` | Resolve via `iso_alpha2_code` | Unresolved |
|---|---|---|---|---|
| `FCT_CASE_COLLECTION` (all rows) | 15 | 0 | 14 | `UK` — 1,542,738 rows |
| `MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION` (latest month) | 17 | 0 | 16 | `UK` — 45,452 rows |

`UK` is not an ISO code (`GB` is, and both appear in the same facts). It
resolves to nothing under either join and is kept as the raw code so it stays
visible rather than folding into `Unknown` — merging it with `GB` is a
data-team decision, not a query one.

**Fixed** in the five files that join the dimension: `base_collection`,
`base_loan_carrying`, `agg_collections_monthly`, `agg_portfolio_summary`,
`agg_loan_detail`. Every other file exposes `country_id` raw and was never
wrong. `base_reconciliation` check 15 re-verifies the join each run.

---

### 4.3 Structural facts worth knowing

Not bugs — properties that decide whether a query is answerable.

- **Loan-level book value exists, but only for 9 months.**
  `MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION`: 111,508,917 rows, unique on
  (`CASE_SK`, `DATE_DAY`), covering **2025-12-31 → 2026-08-31 only**. It is
  the sole route to carrying value below portfolio level, and the
  best-documented table in the schema (10/10 columns). It carries **no
  currency column**, so a cross-currency sum is silently mixed —
  `base_loan_carrying.sql` joins currency in from the balance snapshot.

- **The three forecasts answer three different questions.** Do not average
  them.

  | Forecast | Grain | Vintages | Span |
  |---|---|---|---|
  | Underwriting — what we assumed when we bought | portfolio × month (44,092) | 1 (2026-08-31) | 2025-06-30 → 2041-06-30 |
  | Accounting — the current live forecast | portfolio × month (44,392) | 8 | 2025-06-30 → 2041-06-30 |
  | Servicer — what the servicer projects | portfolio × month × batch × segment (1,917,510) | 27 | 2015-01-31 → 2041-07-31 |

  Accounting is the one carrying amount is built from. Servicer is the only
  forecast carrying `SEGMENT_SK`. Accounting is unique per portfolio-month but
  different months come from different vintages, so one portfolio's series is
  not necessarily a single coherent run.

- **In the versioned accounting forecast the version key is `REPORTING_DATE`.**
  Easy to get wrong, and the wrong choice silently merges runs:
  `SNAPSHOT_VERSION` has one distinct value; `REPORTING_PERIOD_END_DATE`
  yields 53,273 combinations — 79 short of the 53,352 rows; `REPORTING_DATE`
  yields 53,352. `BATCH_SK` is **100% NULL** in that table, so there is no
  batch detail to be had.

- **`DIM_PORTFOLIO` carries no deal, batch, segment or buyer key.** 264 rows,
  unique on both `PORTFOLIO_SK` and `PORTFOLIO_BK`, not an SCD. Those
  dimensions live only on the fact tables, so "which deal is this portfolio
  in" is only answerable *as at a date*. `ref_portfolio.sql` resolves them at
  a chosen month and exposes `N_DEALS` / `N_SECURITY_CLASSES` so an ambiguous
  portfolio is visible rather than collapsed to one arbitrary name.

- **FX conversion works, but only one way — see 2.6, which is the single
  most dangerous finding here.** `COMMON.FCT_EXCHANGE_RATE_MONTHLY`: 2,288
  rows, unique on (`DATE_DAY`, `BASE_CURRENCY`, `QUOTE_CURRENCY`,
  `RATE_TYPE`), coverage 2018-01-31 → 2026-08-31. Only **EUR and SEK** are
  base currencies. Use `ULTIMO_VALUE` for balances (a point-in-time stock)
  and `MONTHLY_AVG` for flows accumulated over a month; converting a month of
  receipts at the closing rate misstates them.

- **`FCT_REVALUATION` is small and recent.** 60 rows, unique on
  (`PORTFOLIO_SK`, `REVALUATION_DATE`), 50 portfolios, 2025-12-31 →
  2026-09-30.

- **4 rows in `FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED` have a NULL
  `BATCH_SK`.** They survive a portfolio-level roll-up but vanish from any
  batch-level analysis. The table is otherwise genuinely unique on
  (portfolio, period, batch, version) — zero duplicate keys.

---

### 4.4 What the flash report is built from

Ten `ref()`s, read from the dbt model on 2026-09-09. Grain: one row per
(`PORTFOLIO_BK`, `MONTH_END_DATE`) — 44,313 rows, verified unique, spanning
2025-07-31 → 2041-06-30.

| Flash report column | Source | In the base layer? |
|---|---|---|
| `GCF_ACTUAL`, `NCF_ACTUAL` | `FCT_PORTFOLIO_SNAPSHOT_MONTHLY` | ✅ `monthly_portfolio_performance` |
| `GCF_UNDERWRITING`, `NCF_UNDERWRITING` | `..._FORECAST_UNDERWRITING_...` | was **missing** |
| `GCF_ACTIVE`, `NCF_ACTIVE` | `..._FORECAST_ACCOUNTING_...` | was **missing** |
| `CARRYING_AMOUNT` | `FCT_CARRYING_AMOUNT.CLOSING_VALUE` | ✅ |
| dimensions | 6 `dim_npl_*` | ✅ |

It does **not** use the servicer forecast, and it never touches loan-level
data. It is a full outer join, so a row can carry a forecast with no actual
or the reverse — a NULL `GCF_ACTUAL` means "no actual for this
portfolio-month", not zero. Coalescing it blindly turns a reporting gap into
an apparent shortfall. Its history also starts 2025-07-31, because the model
filters `period_end_date > '2025-06-30'`.

---

### 4.5 Three objects deliberately not covered

| Object | Why not |
|---|---|
| `NPL_COMMON.DIM_FORECAST_SOURCE` | **Unusable.** `FORECAST_SOURCE_SK` appears in exactly one column schema-wide — its own. It joins to nothing. |
| `COMMON.DIM_DATE` | Daily grain, but every fact here is month-end only: `FCT_CASE_SNAPSHOT_DAILY` holds 147 dates and all are month-ends despite the name. `ref_calendar` uses `DIM_MONTH`. |
| `COMMON.FCT_EXCHANGE_RATE_DAILY` | Same reason — no daily-grained fact to convert. `ref_fx_rate` uses the monthly table. |

---

### 4.6 The base layer — ⚠ retired 2026-10-02, kept as a grain map

16 files that were in `work/servicing/`. Prefix told you the grain:
`ref_` = one row per thing, `base_` = lowest grain available, `monthly_` =
one row per month. Build `agg_` views on these rather than on the raw facts.

| File | Grain — one row per |
|---|---|
| `ref_loan` | loan, at a month-end |
| `ref_borrower` | borrower |
| `ref_portfolio` | portfolio |
| `ref_calendar` | month-end |
| `ref_fx_rate` | currency pair × month × rate type |
| `base_collection` | collection transaction (fact row — see 2.1) |
| `base_case` | loan × month-end, all dimensions joined |
| `base_case_collection` | loan × day × deal |
| `base_collection_reconciliation` | check on the collections chain |
| `base_loan_carrying` | loan × month-end |
| `base_data_quality` | check that currently fires |
| `base_reconciliation` | reconciliation check (do the levels agree, and why not) |
| `monthly_loan_performance` | loan × month |
| `monthly_borrower_collections` | borrower × month (paying months only) |
| `monthly_portfolio_performance` | portfolio × month × currency |
| `monthly_portfolio_forecast` | portfolio × month × forecast type |
| `monthly_flash_report` | portfolio × month |
| `monthly_portfolio_restatement` | portfolio × month × snapshot version |
| `monthly_forecast_restatement` | portfolio × month × reporting run |

Each file's header records its verified grain and the guards it depends on.
Every guard is visible in the SQL with a comment naming the problem, so a
filter can be audited rather than becoming folklore.

---

### 4.7 How this was verified, and how to redo it

- **Compilation.** All 18 `.sql` files in the workspace were sent to Snowflake
  **verbatim** — the way the VS Code extension sends them — and compiled.
  18/18 pass, so any of them can be opened and run in the extension.
- **Execution, not just compilation.** EXPLAIN proves a file parses, not that
  it returns anything. All **19/19 files were executed** and every one returns
  rows with its declared grain intact — 0 duplicates on every claimed key.
- **Grain.** Checked against actual output with a duplicate count on the
  claimed key, per file. All zero.
- **Beyond one portfolio.** The `CASE_SK` finding was first measured on a
  single portfolio, then re-measured across every deal source (table in 2.8)
  to confirm it was not a local artefact. It was worse at scale.
- **`EXPLAIN` does not work on `information_schema` queries** for
  `NPL_ANALYST`: `001127 (42501) EXPLAIN command has insufficient privilege
  on object COLUMNS`. That is a privilege limit, not bad SQL. To compile-check
  without scanning, wrap instead: `select * from ( <query> ) limit 0`.
- **One correction made along the way.** A header in
  `monthly_portfolio_restatement` initially claimed most portfolio-months had
  a single version. Measuring showed the opposite — 95.7% are restated — and
  the header was corrected. Re-measure rather than carrying a claim forward.

Everything here is read-only: `NPL_ANALYST` holds `SELECT` and `USAGE` only.
No warehouse table was created or altered, and no dbt model in `brocc-data`
was touched.

---

### 4.8 Can we build a standard servicing dashboard? Tested, not assumed

Each row below was actually run against the warehouse on 2026-09-09, not
reasoned about.

| Dashboard question | Answerable? | From |
|---|---|---|
| How many portfolios are we servicing? | ✅ **250** at 2026-07-31 (216 May, 233 June) | `ref_portfolio`, `monthly_portfolio_performance` |
| How much did we collect? | ✅ | `monthly_portfolio_performance` |
| How much do we expect to collect? | ✅ three ways — underwriting, accounting, servicer | `monthly_portfolio_forecast` |
| Actual vs expected, one number, all currencies | ✅ **EUR 41.28m actual vs EUR 39.26m expected = 105.2%**, 0 unconvertible rows | the above + `ref_fx_rate` |
| Book value of the portfolio | ✅ portfolio level, any month | `monthly_portfolio_performance` |
| Book value per loan | ⚠️ only 9 month-ends (2025-12 → 2026-08) | `base_loan_carrying` |
| Recovery vs purchase price | ✅ capex, GBV, price, IRR all present | `ref_portfolio` |
| Servicer performance | ⚠️ loan level only — 100% NULL at portfolio level | `ref_loan`, `base_collection` |
| Cost to serve | ❌ **Intrum only.** Commission, passthrough and net recoveries are zero for every other servicer — not free, just not supplied | `monthly_portfolio_performance.IS_NET_MEANINGFUL` |
| Payer segmentation | ✅ | `monthly_borrower_collections` |
| Has a reported month changed? | ✅ | `monthly_portfolio_restatement` |
| Are we revising expectations? | ✅ | `monthly_forecast_restatement` |
| Origination vintage curves | ❌ `ORIGINATION_DATE` 95.4% null. Acquisition vintage only | `ref_portfolio.MONTHS_SINCE_CAPEX` |
| Forbearance duration / cure / re-default | ❌ no end date exists — see 2.7 | — |
| Operational KPIs — calls, letters, promises to pay, legal stage, FTE | ❌ **not in the warehouse at all** | — |
| Contactable customer list | ❌ no name, address, phone or email in `DIM_BORROWER` | — |

#### So: confident on the normal stuff, with two caveats

The financial spine of a servicing dashboard is complete and reconciles:
portfolio counts, collections, three forecasts, variance, book value,
acquisition economics, restatement history, and now multi-currency totals.
The headline actual-vs-expected number computes end to end.

Two things are **not** gaps in the base layer but real absences in the
warehouse, and no query can fix them:

1. **Cost to serve is Intrum-only.** Any cross-servicer net-margin or
   efficiency comparison is invalid, because the other servicers' costs are
   absent rather than zero.
2. **There is no operational data.** No contact attempts, promises to pay,
   legal-stage progression, arrangement outcomes or collector activity. A
   dashboard built on this answers "how much came in and how does that
   compare to plan" — a *financial* view of servicing. It cannot answer "how
   well is the collections operation running".

Both are conversations with the data team rather than anything to work
around, and worth raising before a stakeholder assumes the second one is
available.

#### One caution about the "more exciting stuff"

Three of the natural next analyses are blocked by absent columns rather than
by effort: cure and re-default (no forbearance end date, §2.7), origination
vintage curves (`ORIGINATION_DATE` 95.4% null), and per-borrower apportionment
of joint-loan balances (no share or primary-borrower flag in
`BRG_CASE_BORROWER`). Worth knowing before they are promised.
