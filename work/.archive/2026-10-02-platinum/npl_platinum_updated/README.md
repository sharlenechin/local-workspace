# npl_platinum_updated — a loan's life, and a portfolio's, as rows

**Who this is for:** anyone who needs to ask *what happened to this loan, when,
and who was involved* — without knowing how the warehouse is wired underneath.

Two dimension tables. One describes a **portfolio's** history, one describes
every **loan's**. Both answer the same shape of question: *who held this, and
when.*

---

## 1. The one idea: a row means something happened

The obvious way to build this is one row per loan with a column per date:

| case_bk | registration_date | acquisition_date | cutoff_date |
|---|---|---|---|
| 4042-4605327 | 2019-03-01 | 2025-12-31 | *(null)* |

That breaks as soon as you want to know *what the balance was* at each of those
moments — you'd need a column per date per measure. So instead, **each event
gets its own row**, carrying the state as at that date:

| case_bk | phase_type | phase_date | balance_total | phase_entity | is_latest_phase_flag |
|---|---|---|---|---|---|
| 4042-4605327 | REGISTRATION | 2019-03-01 | *(null)* | intrum | false |
| 4042-4605327 | LEGACY_ACQUISITION | 2021-06-30 | 12,400.00 | Previous owner | false |
| 4042-4605327 | BROCC_ACQUISITION | 2025-12-31 | 11,850.00 | Brocc Portfolio 3 AB | **true** |

**The table is DENSE: a row exists only where the event actually happened.**
This loan has no `ORIGINATION` row because we have no origination date for it —
not a row full of NULLs. Two consequences you must hold on to:

- **The number of rows per loan varies.** Never assume a fixed multiple. Read
  `phase_count` if you need to know how much history a loan has.
- **Browsing the table does not show you what is missing.** The catalogue of
  phases that *could* exist lives in the model's `phase_list` and in
  `models.yml`. Check there before concluding a loan has no origination.

### ⚠⚠ There is no `LATEST` phase — and that is deliberate

An earlier build had one. It was removed because it was **current state wearing
an event's clothes**, and mixing "what happened" with "where things stand" in one
table cost three things:

- **It forced a full rebuild every run.** Real events never change once
  recorded, so they could simply be appended — but `LATEST` moved for *every*
  loan *every* month, so the whole table had to be recomputed.
- **It stored a six-row fact 22 million times.** Every loan carried a `LATEST`
  row, plus empty `ORIGINATION` and `SELLER_CUTOFF` rows, whether or not
  anything was known.
- **It asserted recency by name** rather than reading it off the dates.

`is_latest_phase_flag` replaces it, derived from `phase_date`.

⚠⚠ **What you lose: the current balance is no longer in this model.** Only
balances *at recorded events* are. For today's figure read
`fct_npl_case_snapshot_daily`. And note `is_latest_phase_flag` marks the newest
**activity**, not today's state — a loan whose last recorded event was its 2019
registration has *that* row flagged.

## 2. The two tables at a glance

| | `dim_npl_portfolio_history` | `dim_npl_case_history` |
|---|---|---|
| One row per | portfolio x phase x party | loan x phase |
| Rows | ~1,166 | **63,334,153** (was 135,180,702 before the model went dense) |
| Covers | 264 portfolios | **22,511,035** loans — ⚠ not all 22,530,117, see below |
| Time is a | `phase_date` plus `phase_last_active_date` — read `phase_date_type` for what that means | `phase_date`, always a point |
| Answers | who serviced and owned this book, between when | what happened to this loan, and what was true of it then |
| Batch? | no, deliberately | yes, `batch_sk` |

Row counts measured 2026-09-27 against PROD. ⚠ The warehouse has been rebuilding
through this work and loan counts drift by a handful between runs — treat the
last digit as soft.

---

## 3. The shared vocabulary — how the two tables map

Four columns mean the **same thing on both tables**, so a filter written against
one works on the other:

| Column | On both tables |
|---|---|
| `phase_status` | the *kind* of event — `REGISTRATION` maps to `REGISTRATION`, `ACQUISITION` to `ACQUISITION` |
| `phase_entity` | **the company** — a servicer, a vehicle, a seller |
| `phase_entity_type` | what kind of party that is — `SERVICER`, `VEHICLE`, `SELLER`, `OWNER` |
| `phase_date` | when. On the portfolio table it is the **start** of a window |

`phase_status` is the axis to filter on when a question spans both grains:

| `phase_status` | On the portfolio table | On the case table |
|---|---|---|
| `REGISTRATION` | ✅ `REGISTRATION` | ✅ `REGISTRATION` |
| `ACQUISITION` | ✅ `LEGACY_ACQUISITION`, `BROCC_ACQUISITION` | ✅ `LEGACY_ACQUISITION`, `BROCC_ACQUISITION` |
| `SERVICING` | ✅ `SERVICER` | — |
| `OWNERSHIP` | ✅ `LEGAL_BUYER` | — |
| `ORIGINATION` / `CUTOFF` | — | ✅ *(reserved)* |

**The one difference that remains, by design:** the portfolio table describes
**windows** and the case table describes **points**. So the portfolio table keeps
`phase_last_active_date` alongside `phase_date`. To join them, use a date range,
not equality — and check `phase_date_type` first, because a NULL end means
"still active" on a window and "not applicable" on a point event:

```sql
JOIN dim_npl_portfolio_history AS p
  ON p.portfolio_sk = c.portfolio_sk
 AND c.phase_date >= p.phase_date
 AND (p.phase_last_active_date IS NULL
      OR c.phase_date < p.phase_last_active_date)
```

---

## 4. The five phases, in plain English

| `phase_type` | What it is | Real today? |
|---|---|---|
| `ORIGINATION` | when the loan was first written, by the original lender | **no** — waiting on the asset index |
| `REGISTRATION` | when the **servicer** took the loan onto its collection platform | yes, 89.64% |
| `SELLER_CUTOFF` | the seller's data cut-off before we bought | **no** — waiting on the asset index |
| `LEGACY_ACQUISITION` | when the **previous owner** bought the batch | yes, 95.58% |
| `BROCC_ACQUISITION` | when **we** bought the portfolio | yes, 95.89% |

Because the table is dense, the two reserved phases produce **no rows at all**
today. They are declared in the model so the asset index can fill them later
without a redesign.

⚠ There is no `LATEST` — see section 1.

## 5. ⚠⚠⚠ Two registration dates means a PLATFORM migration, not a new servicer

**32 of the 174 portfolios that have a registration row have two.** In every one
of them the **servicer is unchanged** — it is Intrum throughout. What changed is
the Intrum *platform* the book sits on:

| Portfolio | Servicer | Platform | First registration | Loans |
|---|---|---|---|---|
| LOK-ES24013-U01 | intrum | CAT **Scale** | 2024-12-19 | 65,569 |
| LOK-ES24013-U01 | intrum | CAT **Fenix** | 2025-11-22 | 64,881 |
| HEI-ES25001-U01 | intrum | CAT **Scale** | 2017-12-14 | 3,480,727 |
| HEI-ES25001-U01 | intrum | CAT **Fenix** | 2025-08-09 | 3,228,479 |

The near-identical loan counts are the tell: the same book moved, shrinking
slightly as loans closed on the way.

**Why this bites.** `case_bk` is `<platform code>-<servicer case id>`. So when a
book migrates, **the same debt is issued a brand-new `case_bk` with a brand-new
registration date, and nothing links the old identity to the new one.**

In a vintage breakdown one Spanish loan therefore appears **twice** — once in the
2024 vintage as a CAT Scale case, once in 2025 as a CAT Fenix case. Both rows are
real. Neither knows about the other.

⚠ **12,646,213 of the 19.6m loans carrying a registration date sit in these 32
portfolios** — 64% of them. The true count of distinct debts is materially below
22.5m and cannot be derived, because no key survives the migration.

Use `phase_system` to see which platform a row belongs to, and
`phase_entity` when you want the company. Never read `phase_system` as a party.

⚠ `phase_system` is **not unique**: reporting system codes 7006 and 7010 are both
named `CAT Scale`, 3010 and 3020 both `CAT ReCash`.

---

## 6. A real worked example — `HEI-ES25001-U01/2512`

A Spanish book of ~3.4m loans. This is its **entire** row set in
`dim_npl_portfolio_history`, straight from PROD on 2026-09-27 — eight rows that
tell the whole story of who held it and who collected on it:

| # | phase_type | phase_date_type | phase_entity | phase_system | phase_date | phase_last_active_date | latest |
|---|---|---|---|---|---|---|---|
| 1 | LEGACY_ACQUISITION | SPREAD | Previous owner | — | 2001-01-01 | 2019-10-01 | |
| 2 | REGISTRATION | SPREAD | **Intrum** | CAT Scale | 2017-12-14 | 2025-06-18 | |
| 3 | LEGAL_BUYER | OBSERVED_WINDOW | Intrum Debt Finance **AG** | — | 2021-10-31 | *(still active)* | |
| 4 | SERVICER | OBSERVED_WINDOW | **Intrum** | CAT Scale | 2021-10-31 | *(still active)* | |
| 5 | REGISTRATION | SPREAD | **Intrum** | CAT Fenix | 2025-08-09 | 2026-07-27 | |
| 6 | SERVICER | OBSERVED_WINDOW | **Intrum** | CAT Fenix | 2025-09-30 | *(still active)* | |
| 7 | BROCC_ACQUISITION | POINT_EVENT | Brocc | — | 2025-12-01 | — | |
| 8 | LEGAL_BUYER | OBSERVED_WINDOW | Intrum Debt Finance **AG** | — | 2026-07-31 | *(still active)* | ✅ |

**How to read it:**

- **Rows 2 and 5 are the trap from section 5.** Two `REGISTRATION` rows, same
  servicer (`Intrum`), different platform — CAT Scale then CAT Fenix. This is
  **not** a change of servicer. It is the same book re-registered after a
  platform migration, and the ~3.4m loans on CAT Scale are largely the *same
  debts* as the ~3.2m on CAT Fenix, counted twice.
- **Rows 4 and 6 are both still active.** The book is live on *both* platforms
  at once — parallel running, **not** a handover. ⚠ Nothing flags this for you
  any more; see the concurrency note below.
- **Row 1 has no `loans` count** — `phase_entity_loans_on_book_count` is only
  populated on servicer phases.
- **Only row 8 is `is_latest_phase_flag`** — the most recent thing we know
  happened, derived from the dates rather than asserted.
- **`phase_date_type` tells you what `phase_last_active_date` means.** Rows 1,
  2 and 5 are a **SPREAD** — row 2 does not mean "Intrum serviced this book from
  2017 to 2025", it means the *earliest* loan was registered in 2017 and the
  *latest* in 2025. Rows 3, 4, 6 and 8 are a real **OBSERVED_WINDOW**, still
  active. Row 7 is a single recorded day, so it has no last activity.

⚠⚠ **Note rows 3 and 8: that is ONE vehicle, not two.** Intrum Debt Finance AG
appears twice because **Brocc's stake in it changed** — 65% until 2026-07-01,
100% from it. `legal_buyer_sk` is keyed on the vehicle's name *plus* the date
its ownership share began, so a stake change mints a brand-new key, and this
model groups by that key. Nothing about who holds the loans changed.

**This is exactly why `is_concurrent_flag` was removed on 2026-09-27.** It
counted overlapping windows without checking the parties differed, so it fired
on rows 3 and 8 — two keys genuinely share 2026-07 and 2026-08, but they are the
same company, so it is neither parallel running nor a handover. The flag
overstated handovers and there is no replacement yet.

⚠⚠ **Concurrency is still real, and it is not servicer-only.** Measured before
removal: 69 `SERVICER` rows across 34 portfolios and 26 `LEGAL_BUYER` rows
across 13. Until a replacement lands, **compare `phase_entity` yourself** before
reading two open rows of one `phase_type` as a transfer. A correct definition
needs a product decision: does parallel running mean two *distinct* parties in a
month, and does a gap in the files break a window?

**Measured in PROD on 2026-09-27:** 14 portfolios carry two `legal_buyer_sk`
windows. In **all 14 the vehicle name is identical in both** — and no portfolio
anywhere carries two different vehicle names. So *every* split in this model is
a stake change, and a vehicle change has never happened in this data.

| Vehicle | Share before | Share after | Changed on | Portfolios |
|---|---|---|---|---|
| Intrum Debt Finance AG | 0.65000 | 1.00000 | 2026-07-01 | 10 |
| Intrum Justitia Debt Fund 1 FIZNF | 0.65000 | 1.00000 | 2026-07-01 | 2 |
| Intrum Hellas DAC | 0.65000 | 1.00000 | 2026-07-01 | 1 |
| Danubio S.r.l. | 0.95000 | 1.00000 | 2026-01-01 | 1 |

⚠ **The old key does not stop — it runs on beside the new one**, on 13 of the
14. On `HEI-ES25001-U01/2512` at 2026-08-31 the split is exactly the platform
split from section 5: the 3,480,727 CAT **Scale** loans still carry the 65% key
while the 3,228,479 CAT **Fenix** loans carry the 100% one. The migrated
platform picked up the new share and the legacy platform did not. **So the
upstream fact holds a stale share for those loans, and this model inherits it.**
`LEG-IT25001-U01/2512` is the only clean changeover.

⚠⚠ **`ownership_share` is real and is often below 1.** Brocc's economic share
of a 65% vehicle's loans was 65%, not 100%. Summing balances by vehicle and
reading the total as wholly Brocc's overstates it — and, because of the stale
key above, reading today's share off the *latest* row understates it on the
loans still stuck on the old key. Neither is safe without saying which you used.

---

### And two loans from that same book, in `dim_npl_case_history`

Straight from PROD on 2026-09-27. Two loans, **both in `HEI-ES25001-U01/2512`**
— one registered on CAT Scale, one on CAT Fenix. Three rows each, because three
things are known to have happened to them:

| case_bk | # | phase_type | phase_status | phase_entity | phase_system | grain | phase_date | balance | status | case_status | latest |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **7006**-70060007106000 | 1 | LEGACY_ACQUISITION | ACQUISITION | Previous owner | CAT Scale | BATCH | 2016-08-01 | — | — | CLOSED | |
| **7006**-70060007106000 | 2 | REGISTRATION | REGISTRATION | intrum | CAT Scale | CASE | 2019-11-12 | — | — | CLOSED | |
| **7006**-70060007106000 | 3 | BROCC_ACQUISITION | ACQUISITION | Intrum Debt Finance AG | CAT Scale | PORTFOLIO | 2025-12-01 | **1,042.47** | 6 · Completed | CLOSED | ✅ |
| **4042**-4623641 | 1 | LEGACY_ACQUISITION | ACQUISITION | Previous owner | CAT Fenix | BATCH | 2016-09-01 | — | — | OPEN | |
| **4042**-4623641 | 2 | REGISTRATION | REGISTRATION | intrum | CAT Fenix | CASE | 2025-11-22 | — | — | OPEN | |
| **4042**-4623641 | 3 | BROCC_ACQUISITION | ACQUISITION | Intrum Debt Finance AG | CAT Fenix | PORTFOLIO | 2025-12-01 | — | — | OPEN | ✅ |

**How to read it:**

- **Three rows, not five.** `ORIGINATION` and `SELLER_CUTOFF` produce nothing —
  the asset index is not in PROD. That is the dense contract: no row means no
  event, not a missing value. `phase_count` = 3 on every row.
- **`phase_grain` tells you whose date it is.** Only `REGISTRATION` is the
  loan's own. `LEGACY_ACQUISITION` is its **batch's** date and
  `BROCC_ACQUISITION` its **portfolio's** — both stamped onto every loan inside,
  which is why 2025-12-01 is identical on both loans from different platforms.
- **`phase_system` is a property of the loan, not of the phase.** It repeats on
  every row because it comes from `case_bk`, which never changes for a given
  loan. The 2019 loan is `7006-` (CAT Scale); the 2025 one is `4042-` (CAT
  Fenix). **Same book, same servicer, two platforms** — section 5.
- **Balances are sparse and that is expected.** Only one of six rows has one.
  The case snapshot starts 2014-06-30 and is month-end, so a phase only carries
  a balance if the loan was on a file that month-end. `has_snapshot_flag`
  distinguishes "nothing recorded" from "no date".
- **A CLOSED loan can still owe money.** The first loan is `CLOSED` with
  **1,042.47** outstanding — the servicer marked the case complete, not the debt
  repaid. Do not read `case_status = 'CLOSED'` as "recovered".
- **Only the newest row carries `is_latest_phase_flag`.** No `LATEST` phase, no
  extra row — recency is read off the dates.

⚠ Note the second loan: registered **2025-11-22**, acquired by us **2025-12-01**
— nine days later. Its vintage is 2025, but the debt itself dates to a 2016
batch acquisition. **Registration year is when the servicer booked it, not how
old the debt is.** That is the vintage trap in section 11.

---

## 7. The columns of `dim_npl_case_history`

**Keys — what this row is about**

| Column | Meaning |
|---|---|
| `case_bk` | the loan. `<system code>-<servicer case id>`, e.g. `4042-4605327`. **This is the join key**, not `case_sk` |
| `case_sk` | a *version* key. A loan has many; do not join on it |
| `case_id` | the servicer's own id for the loan, without the platform prefix |
| `portfolio_sk`, `batch_sk` | the book and batch at the latest snapshot |
| `portfolio_count` | ⚠ above 1 means the loan sits in **two** books and `portfolio_sk` is one of two answers (2,321 loans) |

**The phase — which moment this is**

| Column | Meaning |
|---|---|
| `phase_type` | the specific event (six values, listed above) |
| `phase_status` | the *kind* of event — ACQUISITION, REGISTRATION, CUTOFF... |
| `phase_entity` | **the company** — resolved per row, never assumed. The actual servicer, the actual vehicle |
| `phase_entity_type` | what kind of party that is — `SERVICER`, `VEHICLE`, `SELLER`, `OWNER` |
| `phase_system` | ⚠ the servicer's **platform** (`CAT Fenix`). Not a company — see section 5 |
| `phase_date` | when. NULL where unknown |
| `phase_order` | 1, 2, 3... in **date** order. Never NULL — every row has a date |
| `is_latest_phase_flag` | the most recent event we hold. ⚠ Newest **activity**, not today's state |
| `phase_count` | how many events we hold for this loan. ⚠ 1 means a single point in time |
| `phase_month`, `phase_year` | `phase_date` truncated. **`phase_year` on the `REGISTRATION` row is your vintage key** — see trap 6 in section 11 |
| `phase_grain` | ⚠ whether this date is the loan's own, its batch's, or its portfolio's |
| `phase_source` | `WAREHOUSE` (real today) or `ASSET_INDEX` (reserved) |

**State as at that moment**

| Column | Meaning |
|---|---|
| `balance_principal/interest/fees/total` | what was owed **on that date** |
| `status_code`, `status_description` | the action the servicer recorded then. ⚠ Not a legal stage |
| `is_forbearance_flag` | real, and point-in-time |
| `is_insolvency_flag`, `insolvency_status` | **reserved NULLs** — nothing populates these yet |
| `has_snapshot_flag` | whether a snapshot backed it, so a NULL balance is explained |

**Provenance**

| Column | Meaning |
|---|---|
| `source_updated_at` | when the warehouse last touched the record. ⚠ Not when the event happened — that is `phase_date`. This is the watermark an incremental build would use |
| `latest_snapshot_day` | the newest file this loan appeared on. An attribute, not a phase row |

**Lifecycle — is this loan still live**

| Column | Meaning |
|---|---|
| `case_status` | OPEN / CLOSED, from the servicer's `closing_date` |
| `closing_date`, `closing_code` | when and why it closed |
| `is_on_latest_book_flag` | whether it still appears on a servicer's newest file |

⚠ The last two rows are **different questions** — see trap 3 in section 11.

---

## 8. The columns of `dim_npl_portfolio_history`

**Keys and the phase**

| Column | Meaning |
|---|---|
| `portfolio_sk` | the book |
| `phase_type` | `SERVICER`, `LEGAL_BUYER`, `REGISTRATION`, `BROCC_ACQUISITION`, `LEGACY_ACQUISITION` |
| `phase_status` | the shared axis — `SERVICING`, `OWNERSHIP`, `REGISTRATION`, `ACQUISITION` |
| `phase_entity` | **the company** — servicer or vehicle |
| `phase_entity_type` | `SERVICER` / `VEHICLE` / `OWNER` |
| `phase_entity_sk` | the party's key. ⚠ NULL on the acquisition phases — a purchase has no party dimension |
| `phase_system` | ⚠ the **platform** (`CAT Fenix`). Not a company — see section 5 |
| `phase_order` | 1, 2, 3... in date order |
| `phase_source` | which table the date came from |

**Time — this table describes windows**

| Column | Meaning |
|---|---|
| `phase_date` | the window's **start**. Shared name with the case table |
| `phase_date_type` | ⚠⚠ **read this first** — `OBSERVED_WINDOW`, `SPREAD` or `POINT_EVENT`. It says what `phase_last_active_date` means on this row |
| `phase_last_active_date` | the last date this phase shows activity. On `OBSERVED_WINDOW`, the last month the party was seen — NULL means **still active**. On `SPREAD`, the last underlying event (⚠ the phase did not *stop* then). On `POINT_EVENT`, NULL — a single day has no last activity |
| `phase_entity_loans_on_book_count` | how many loans that servicer holds. NULL on non-servicer phases |

**The drill path** — attributes of the book, not of the phase, so they repeat on
every row: `portfolio_name`, `vehicle`, `project`, `deal`, `seller_name`,
`region`, `country_name`, `country_code`, `portfolio_currency`, `flow_type`,
`batch_count`, `ownership_share`, `derived_servicer`.

⚠ `ownership_share` is **Brocc's stake in the vehicle, not always 1** — and on
the legacy-platform loans of 13 portfolios it is **stale**. See section 6 before
using it to weight anything.

⚠ `derived_servicer` is inferred from deal source and country and **never
changes**. For the servicer that actually moves, read `phase_entity` on the
`SERVICER` rows.

**Flags**

| Column | Meaning |
|---|---|
| `is_current_phase_flag` | the window is still open |
| `is_point_event_flag` | the phase is a single day, not a window |
| `is_multi_vintage_flag` | the book spans more than one vintage |
| `has_gap_flag` | holes in the window — usually a late file, not a real absence |

---

## 9. Your workflow, step by step

*Pick portfolios -> drop to loan level -> break down by registration vintage ->
look at liquidation.*

```sql
-- 1. the books you want, from the portfolio dim
WITH chosen AS (
    SELECT DISTINCT portfolio_sk
    FROM dim_npl_portfolio_history
    WHERE country_code = 'ES'
),

-- 2. the vintage of each loan: the YEAR IT WAS REGISTERED.
--    ⚠ ONE phase, filtered before anything is counted.
vintage AS (
    SELECT case_bk, portfolio_sk, phase_year AS registration_year
    FROM dim_npl_case_history
    WHERE phase_type = 'REGISTRATION'
),

-- 3. what we paid for it, as at acquisition.
--    ⚠ phase_TYPE, not phase_status -- ACQUISITION matches two phases.
at_purchase AS (
    SELECT case_bk, balance_total, case_status
    FROM dim_npl_case_history
    WHERE phase_type = 'BROCC_ACQUISITION'
)

SELECT v.registration_year,
       COUNT(*)                                            AS loans,
       SUM(p.balance_total)                                AS balance_at_purchase,
       SUM(IFF(p.case_status = 'CLOSED', 1, 0))            AS closed_since
FROM vintage AS v
JOIN chosen  AS c ON c.portfolio_sk = v.portfolio_sk
JOIN at_purchase AS p ON p.case_bk = v.case_bk
GROUP BY 1
ORDER BY 1;
```

**The two moves that matter**: filter to *one* `phase_type` in each CTE before
joining, and join on `case_bk`. Everything else follows.

⚠ **Liquidation itself is not in these tables.** They are dimensions — they say
what was true at a moment. Cash paid over time lives in
`agg_npl_platinum_case_collection_monthly`. A liquidation curve needs all three
tables, not two.

---

## 10. What is real today, and what is waiting

Measured 2026-09-27 against the rebuilt model, all 22,530,117 loans:

| `phase_type` | Has a date | Has a balance | Has a status | Date range |
|---|---|---|---|---|
| `BROCC_ACQUISITION` | 95.52% | **98.25%** | 91.0% | 2025-12-01 → 2026-07-01 |
| `LEGACY_ACQUISITION` | 95.21% | **10.08%** | 6.7% | 2001-01-01 → 2026-07-01 |
| `REGISTRATION` | **89.63%** | **20.98%** | 5.1% | **1900-01-01** → 2026-09-17 |
| `ORIGINATION` | 0 | 0 | 0 | *reserved* |
| `SELLER_CUTOFF` | 0 | 0 | 0 | *reserved* |

**Read this table before trusting any aggregate.** Three things it tells you:

- **Two of five phases produce no rows at all today.** A loan has at most three
  recorded events until the asset index lands.
- **Balances are good at acquisition, thinner before it.** 98.25% of
  `BROCC_ACQUISITION` rows carry a balance, against 20.98% at registration and
  10.08% at the previous owner's purchase.
  ⚠ These were 73.41%, 2.61% and 1.65% before the 2026-09-29 join fix — see the
  change log. The remaining gap is real: a book only enters the case snapshot
  when we start receiving files on it, and **the median book has 11 months of
  history**, so most of a loan's life predates our visibility entirely.
  `has_snapshot_flag` separates "nothing was recorded" from "the phase has no
  date". `original_principal` is the servicer's recorded figure and is **not** a
  balance as at that day.
- **Status is thin except at the end.** 5.1% at registration against 91.0% at
  `BROCC_ACQUISITION`. Historic status is mostly unknowable.

The ~4.11% missing at `BROCC_ACQUISITION` are the 925,003 loans no longer on any
file. Under the dense model they simply produce no row for that phase.

⚠ Percentages above are measured against all 22,531,451 current loans on
2026-09-29, after the balance join fix. The "loans with it" column describes how
many loans have each event, which is what determines the row count.

---

## 11. Six traps

**1. The row count is not the loan count.** A loan has as many rows as it has
known events — between 1 and 5, never a fixed number. `COUNT(*)` is a count of
events; `COUNT(DISTINCT case_bk)` is a count of loans. Filter to one
`phase_type` before aggregating anything per loan.

**2. `phase_status = 'ACQUISITION'` matches two phases** —
`LEGACY_ACQUISITION` *and* `BROCC_ACQUISITION`. Summing a balance across it
double-counts every loan. Use `phase_type` for a single event.

**3. "Still on a file" is not "open".** The two signals disagree on 9.77m loans:

| | loans | |
|---|---|---|
| On a file, no closing date | 12,547,584 | unambiguously live |
| On a file, **has** closing date | 9,057,528 | closed, still being reported |
| Off the file, has closing date | 212,471 | unambiguously done |
| Off the file, **no** closing date | 712,534 | vanished, never marked |

Servicers keep reporting closed cases for years, so `case_status` is driven by
`closing_date`, and `is_on_latest_book_flag` is kept as a **separate column**.
⚠ The 712,534 that vanished unmarked read as OPEN, so **an open-loan count is an
upper bound**. As at 2026-09-27: 13,260,118 open, 9,269,999 closed.

**4. Not every date belongs to the loan.** `LEGACY_ACQUISITION` is its
*batch's* date and `BROCC_ACQUISITION` its *portfolio's*, stamped onto every
loan inside. `phase_grain` tells you which, so an inherited date is never
mistaken for a fact about that loan.

**5. `LEGACY_ACQUISITION` names nobody.** `phase_entity` is the literal string
`'Previous owner'`. If you are tracing *a servicer bought it, then Cerberus, then
Brocc*, the middle step has a date but no company. This is the weakest link in
the lineage and the one worth fixing next.

**6. ⚠⚠ `REGISTRATION` is a shaky vintage key — and vintage is your grouping
column.** Measured over current `DIM_CASE` on 2026-09-27:

| | loans | share |
|---|---|---|
| No registration date at all | **2,334,681** | **10.36%** |
| Pre-1990, i.e. sentinel values (min **1900-01-01**) | 8,578 | 0.04% |
| 1990–2009 | 1,949,852 | 8.65% |
| 2010–today | 18,237,006 | 80.95% |

So **one loan in ten has no vintage** and falls into a NULL bucket, and 8,578
more land in a fake "1900" vintage that will sit at the left edge of every chart
you draw. Bound the date and show the NULL bucket explicitly rather than letting
it drop out of a `GROUP BY`.

---

## 12. Data quality to raise with the data team

Measured 2026-09-27 over all 22,530,117 current loans in `DIM_CASE`:

- `CLOSING_DESCRIPTION` and `CLOSING_CATEGORY` are **100% NULL**. Unusable.
- `CLOSING_CODE` **is** populated — 9,263,268 loans, 47 distinct codes — but
  nothing in the warehouse decodes it. Decoding it would turn "this loan closed"
  into "this loan closed *because*", which is what a liquidation story needs.
- `CLOSING_DATE` spans **1947-07-10 to 2026-12-26**. One loan closes in the
  future. Bound the date before bucketing by close year.
- There is **no insolvency stage** anywhere in the warehouse. That is why
  `is_insolvency_flag` is reserved rather than computed.

---

## 13. How it is built

```
                    fct_npl_case_snapshot_daily   (1.47bn, month-end grain)
                       │  carries portfolio_sk, batch_sk,
                       │  reporting_system_sk, legal_buyer_sk
                       │
        ┌──────────────┴───────────────┐
        ▼                              ▼
dim_npl_portfolio_history      dim_npl_case_history
  ~1,166 rows                    ~63m rows
        │                              │
        │  + dim_npl_reporting_system  │  + dim_npl_case        (the loan spine)
        │  + dim_npl_legal_buyer       │  + dim_npl_batch       (legacy acquisition)
        │  + dim_npl_platinum_portfolio│  + dim_npl_portfolio   (brocc acquisition)
                                       │  + fct_npl_platinum_case_status (decoded status)
```

Both read the case snapshot because **it is the only table carrying every key at
once** — portfolio, batch, servicer system and vehicle, per loan per month.

⚠ The loan spine comes from `dim_npl_case`, **not** from the snapshot. Driving it
from the snapshot dropped the 925,003 loans no longer on any file — the closed
and sold-on ones, which are exactly what a liquidation curve measures.

### ⚠⚠ The portfolio table: windows, not spells

**544 portfolio-months carry two reporting systems at once**, across all 34
portfolios that have more than one. An earlier build assumed one servicer at a
time and opened a new spell on every change — it produced **1,273 spells where
only 231 real pairs exist**, because interleaving systems make every month look
like a handover.

**So a second row does not mean a transfer happened.** ⚠ There is no flag for
this since `is_concurrent_flag` was removed — compare `phase_entity` across the
rows yourself. See section 6.

Nothing in the warehouse records a mandate, a contract or a transfer date.
On `OBSERVED_WINDOW` rows, `phase_date` is the first month-end that party
appears in the data — **inferred, not recorded**, and month-end aligned.
`phase_last_active_date` is NULL while still active, so test `IS NULL`, never an
equality.

### ⚠⚠ A phase is never named after a servicer

An earlier build called the registration phase `INTRUM_REGISTRATION`. That is
**wrong on any book Gescobro or Cerved services**. `phase_entity` carries
whichever servicer it actually is — 5 exist across the estate (intrum, gescobro,
cerved, massey, souq). Never hard-code a party into a phase name; it lies
silently on every other book.

---

## 14. When the asset index reaches PROD

| Phase | Fills from |
|---|---|
| `ORIGINATION` | `CASES.inception_date`, `principal_at_origination` |
| `SELLER_CUTOFF` | `CASES.cutoff_date`, `principal_at_cutoff`, `accrued_interest_at_cutoff`, `legal_balance_at_cutoff` |

And the two reserved insolvency columns fill from `COUNTERPARTIES`
(`bankruptcy`, `debt_restructuring`, `insolvency_restructuring`).

**It is a source swap, not a redesign** — which is the whole reason the phases
are declared up front and the model is long rather than wide.

⚠ The ceiling: the asset index bridge reaches **7.55%** of its own cases and 4 of
23 books, so those phases stay mostly NULL even once connected.

---

## 15. Running these

```sh
mise run platinum-sql        # regenerate the runnable Snowflake copies
mise run sql -- work/dbt/models/marts/npl_platinum_updated_snowflake/dim_npl_portfolio_history.sql --connection prod
```

⚠ Never edit `npl_platinum_updated_snowflake/` — it is generated, the filenames
duplicate these, and two models with one name break `dbt parse`.

---

## Change log

**2026-09-29 — the balance lookup joined on the wrong key.** `snapshot_at_phase`
was keyed on `case_sk` and matched against `cp.case_sk`, which is the **current**
version — while a snapshot row from a past month carries whatever version was
current *then*. Every loan restated since its phase date therefore found no
balance, and ~40% of loans are restated within a year.

Measured on `HEI-ES25001-U01/2512`, 3,234,302 loans whose registration falls
inside the book's coverage window: the version key found **1,070** balances, the
durable key finds **1,026,764** — a **960x** undercount.

⚠ It read as missing data rather than as a bug, because `BROCC_ACQUISITION` is
recent (Dec 2025) so few loans had been restated since and that phase still
matched. Only the older phases came back empty, which looked exactly like the
known snapshot-coverage limit.

Fixed by keying `snapshot_at_phase` on `case_bk` — which costs an INNER JOIN to
`dim_npl_case` to resolve the durable key, since the snapshot only carries
`case_sk`. Safe: a loan never has two versions on book at the same month-end.
`has_snapshot_flag` was wrong the same way and is fixed with it.


**2026-09-27 — audited against the vintage workflow.** Three bugs found and
fixed:

| Bug | Impact | Fix |
|---|---|---|
| The loan spine was an INNER JOIN onto the latest snapshot | **925,003 loans (4.1%) got no rows at all** — the closed and sold-on ones, biasing every vintage curve downward | Driven from `dim_npl_case` instead |
| "Which book is this loan in" kept one row per loan *per portfolio*, and 2,321 loans sit in two | 14,472 duplicate rows | Collapsed to one row per loan; `portfolio_count` flags the 2,321 |
| The balance lookup did the same | 318 duplicate rows, each carrying one book's share | Aggregated per loan per day, **summing** balances |

Plus: `BROCC_ACQUISITION` named the vehicle holding the loan *today* — now
resolved as at the phase date. ⚠ **The reason given here was wrong and is
corrected in section 6:** those 14 portfolios have *not* changed vehicle. Every
one of them shows the **same company twice** because Brocc's ownership share in
it changed, and the share is part of the key. Resolving as at the phase date is
still the right behaviour — it gets the *share* right — but no phase was ever
naming the wrong company. `case_status`, `closing_date`, `closing_code` and `is_on_latest_book_flag`
added. `models.yml` documented a column that does not exist
(`phase_entity_name`, now `phase_entity`) and wrongly called `closing_code` 100%
NULL.

**Verified after the fixes: 135,180,702 rows = 22,530,117 loans x 6 phases
exactly, zero duplicate (loan, phase) pairs.** *(That was the sparse build; the
model has since gone dense — see the entry below.)*

**2026-09-27 (later) — the two tables made mappable, and a correction.**

`phase_entity` on the portfolio table was returning `reporting_system_name` — an
Intrum **platform** ('CAT Fenix'), not a company. A portfolio Intrum had migrated
between two of its own systems therefore read as **two different parties**. It is
one servicer throughout. Corrected to `servicer_name`; the platform moved to a
new `phase_system` column.

Added to **both** tables so a filter written against one works on the other:

| Column | Meaning |
|---|---|
| `phase_entity_type` | `SERVICER` / `VEHICLE` / `SELLER` / `OWNER` |
| `phase_system` | the servicer's platform, where one applies |
| `phase_date` | one name for the start date on both tables |

`phase_status` already mapped across both tables (`REGISTRATION` ->
`REGISTRATION`, `ACQUISITION` -> `ACQUISITION`) and is the axis to filter on for
questions spanning both grains.

**2026-09-27 (later still) — the model went DENSE and `LATEST` was removed.**

The history table was storing a placeholder row for every phase of every loan,
whether or not anything was known — 135m rows to hold roughly 63m facts. And
`LATEST` was not an event at all; it was current state sharing a table with
history.

| Change | Why |
|---|---|
| A row is emitted **only where the event has a date** | A row now means something happened. Drops ~45m empty `ORIGINATION` / `SELLER_CUTOFF` rows and ~22m `LATEST` rows |
| `LATEST` removed from the phase spine | It moved for every loan every month, forcing a full rebuild of a table whose real events never change |
| `is_latest_phase_flag` added | Recency derived from `phase_date` instead of asserted by a phase name |
| `phase_count` added | Rows per loan now vary, so the table says how much history it holds |
| `source_updated_at` added | When the record was last touched — the watermark an incremental build needs |
| `latest_snapshot_day` kept as an attribute | Appearing on a file is not an event |

Both models are dense on the same contract.

**Verified 2026-09-27: 63,334,153 rows, zero duplicate (loan, phase) pairs,
exactly one `is_latest_phase_flag` per loan, every row carrying a date and a
timestamp, 1 to 3 events per loan.**

⚠⚠ **19,082 loans now produce no rows at all** — 22,511,035 of the 22,530,117 in
`dim_npl_platinum_case` appear here. Those loans have no dated event of any
kind: no registration date, no batch acquisition date, no portfolio capex date.
Under the old sparse design they got six rows of NULLs; now they get none, so a
LEFT JOIN from the case dimension drops them. That is the density contract
working as intended, but it is 0.08% of the book and you should know it is
happening.

⚠⚠ **Known consequence:** the **current balance** is no longer available from
this layer — only balances at recorded events. `dim_npl_platinum_case` carries
no balance columns either, so today's figure must come from
`fct_npl_case_snapshot_daily`. Adding current balances to the case dimension
would close that gap and is not yet done.

**2026-09-27 (final) — the portfolio table's dates fixed and simplified.**

`phase_end_date` was carrying **three incompatible meanings**, so no date
comparison was safe across phase types:

| On these phases | It meant | NULL meant |
|---|---|---|
| `SERVICER`, `LEGAL_BUYER` | when the party stopped being seen | **still active** |
| `REGISTRATION`, `LEGACY_ACQUISITION` | the **last underlying event** — a spread across the loans or batches in the book, never a period of validity | — |
| `BROCC_ACQUISITION` | nothing | **not applicable** |

| Change | Why |
|---|---|
| `phase_date` is now the single start date | One date to trust, whatever the phase. `phase_start_date` removed as a duplicate |
| `phase_date_type` added — `OBSERVED_WINDOW` / `SPREAD` / `POINT_EVENT` | Says which of the three kinds a row is, so the end column can be read correctly. ⚠ Also flags confidence: `OBSERVED_WINDOW` dates are *inferred* from monthly files and month-end aligned; the other two are recorded |
| `phase_end_date` replaced by **`phase_last_active_date`** | One column asking one question, named for what it holds |
| `phase_end_date` + `phase_date_last` merged into **`phase_last_active_date`** | Two columns asking the same question. `phase_date_type` already says what counts as activity, so one column is enough and the name now states what it holds |
| `phase_entity_detail` **removed** | It was `COALESCE(servicer_name, legal_buyer_bk, seller_name)` — a *name* on servicer rows but a padded *code* on vehicle rows, so a legal-buyer row read `004` rather than "Intrum Debt Finance AG". `phase_entity` already carries the proper name for every phase type |
| `months_active`, `months_spanned`, `phase_year` **removed** | All trivially derivable from `phase_date` and `phase_last_active_date`. `months_active` is still computed internally for `has_gap_flag` |

**2026-09-27 — `is_concurrent_flag` removed, pending a better definition.**

It counted overlapping windows of a phase type **without checking the parties
differed**, so a vehicle whose `legal_buyer_sk` changed (an ownership-share
change mints a new key) counted as concurrent with itself and read as two owners
where there was one. Measured before removal: 69 `SERVICER` rows over 34
portfolios and 26 `LEGAL_BUYER` rows over 13 — the same-party share was never
measured, so the overstatement is unquantified.

The `concurrency` CTE went with it. **Concurrency itself is real and affects
both window phases**, so the phenomenon stays documented in section 6 even
though the flag is gone; rebuilding it needs a product decision on what parallel
running means.

**Also: `phase_entity` is now title-cased**, but only where the source arrives
lower case (`intrum` → `Intrum`). Names that already carry capitals are left
untouched — a blanket `INITCAP` would turn `Intrum Debt Finance AG` into
`... Ag` and `Rubicon SPV S.r.l` into `... Spv S.R.L`. Measured 2026-09-27: 23 of
24 servicer names are all lower case, 0 of 26 vehicle names are. Applied to both
models. A dead `WHEN 'LATEST'` branch left over from removing that phase was
also cleared out of the case model.
