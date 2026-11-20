# Italy — settlement rates by age · FINDINGS

**Both sides built and measured 2026-09-15.**

The question: *grouped by balance and time since last payment, how many open
amicable accounts pay off their debt each month, and what share of their
balance do they pay?* **"Paid off" = closed = we no longer collect** (confirmed
2026-09-15). Rates are over **accounts and balance open at the snapshot**.

Two servicers, **two tables, never combined** — see §4.

Deliverables: `answer.md` (the PM note), `italy-question.xlsx` (a tab per
servicer, seven labelled questions each), and the two `.sql` files that produce
them.

---

## 1. The headline: recency of payment is the dominant predictor

Cerved, amicable accounts, summed across the 11 observable months:

| Months since last payment | Account-months | Balance EUR | Closed | **Closure rate** | **% balance collected** |
|---|---:|---:|---:|---:|---:|
| **0–3** | 12,027 | 233.8m | 104 | **0.865%** | **1.004%** |
| 4–6 | 1,938 | 80.1m | 9 | 0.464% | 0.119% |
| 7–12 | 4,958 | 146.3m | 2 | 0.040% | 0.638% |
| 13–24 | 10,966 | 229.8m | 4 | 0.037% | 0.090% |
| over 24 | 47,657 | 965.6m | 33 | 0.069% | 0.039% |
| **never paid** | **249,590** | **4,934.5m** | 207 | 0.083% | 0.023% |

**An account that paid in the last three months closes at roughly 20× the rate
of one that has not paid in a year**, and pays about 25× as much of its balance.
After six months without a payment the curve flattens — 7–12, 13–24 and 24+ are
all in the same low band, so the information is in the *recent* months.

⚠ **"Never paid" is the bulk of the book** — 249,590 account-months and EUR
4.93bn, against 77,546 and EUR 1.66bn for everything else combined. Any
book-wide average is dominated by accounts that have never paid anything.

Monthly: ~29,700 open amicable positions carrying ~EUR 600m, with 7–71 closing
per month (0.02%–0.24%) and EUR 145k–895k collected (0.02%–0.15% of balance).

### ⚠⚠ THE SAME GRADIENT APPEARS ON INTRUM, INDEPENDENTLY

Measured on a different feed, with Intrum's own `A002` phase code rather than
our derived definition, and over a different window:

| Months since last payment | Cerved closure rate | Intrum closure rate |
|---|---:|---:|
| 0–3 | 0.865% | **2.477%** |
| 4–6 | 0.464% | 1.419% |
| 7–12 | 0.040% | 0.978% |
| 13–24 | 0.036% | 0.118% |
| over 24 | 0.069% | *cannot occur — window too short* |
| never paid | 0.083% | 0.039% |

**Two servicers, four differing definitions, one shape.** This is the finding
that survives a challenge. The *levels* are not comparable (§4); the ordering
is.

⚠ **Intrum's never-paid band collects MORE of its balance (0.219%) than its
7–12m (0.171%) and 13–24m (0.103%) bands** — the reverse of Cerved. Reason:
Intrum onboards continuously, so "never paid" is where *first* payments come
from. Cerved's book is static, and there never-paid collects least of all.

Intrum monthly: **19,941 open amicable accounts, EUR 366.1m**, over 24
snapshots Jul 2024 – Jun 2026, with 371 closures. 97.9% have never paid — only
1,927 of 48,547 cases ever have.

---

## 2. Three guards, or the numbers are wrong

All measured 2026-09-15 on `RAW.HYPERION_CERVED`.

| # | Guard | Cost of removing it |
|---|---|---|
| **G1** | **October 2025 is double-loaded** — 812,857 rows against 394,205 in every other month, 133,660 "open" against ~52,000 | October reads as a doubling of the book |
| **G2** | **788,410 rows have no `UPDATE_DATE`** — two whole deliveries that cannot be placed in a month | Silently inflates whatever month they land in |
| **G3** | **`COLLECTIONS` is re-delivered whole every month** — 20,687,484 rows for **1,483,527 distinct `EVENTO_ID`**, a **13.9× fan-out** | **Cash multiplied by ~14** |

⚠ G3 is the same trap as the Intrum change-history feeds. Dedupe on
`EVENTO_ID`, newest delivery wins.

⚠ `ACCOUNTING_DATE` is used, not `VALUE_DATE`: `VALUE_DATE`'s maximum does not
resolve to a real date (sentinels), while `ACCOUNTING_DATE` is populated on all
20.7m rows.

⚠ **Only 12 snapshots exist** — 2025-09-30 to 2026-08-31 — and the last is
unusable (no following month to observe a closure in). **11 observable months.**

### Intrum's own guards, measured the same day

| # | Guard | Cost of removing it |
|---|---|---|
| **I1** | **`TRANSACTIONS` fans out 2.2x — and it is ALL in `adjustment`**: 207,533 rows for 48,547 distinct `PKEY`, a 4.3x repeat | The adjustment total flips from **−EUR 1,574,790 to +EUR 209,782,200** — ~EUR 211m of balance that was never there |
| **I2** | **Two whole months of payments are ABSENT** — not one `cashin` row dated **Oct 2025** or **May 2026**, against 280–410 in every neighbouring month | The book reads ~9% worse at collecting than it is |
| **I3** | **13,020 of 48,547 records are expense lines** (SPESE), not loans | Roughly halves every per-account rate |
| **I4** | First extract is the **full load**, the other eight are deltas | `max(_file_path)` silently returns 18,798 loans instead of 48,547 |

⚠ **I1 is the dangerous one** — it is silent, and it inflates. The check that
the dedupe is right: after it, `load` is 48,546 rows summing to exactly
**EUR 1,058,690,235.15**, the original capital in `../italy-legal/FINDINGS.md`.

⚠ **I2 is a data-quality bug to report to the data team.** It is worked around
visibly: those months are returned with `COLLECTED_EUR = 0` and flagged
`CASH_MONTH_HAS_DATA = FALSE`, and excluded from the workbook's cash rates.

⚠ **Intrum has no monthly tape, so the snapshot is RECONSTRUCTED.**
`REMAINING_CAPITAL` is 100% NULL on `CASE_STATUS_CHANGE_HISTORY` for this
instance and `CASES` carries one current value with no history, so month-end
balance is the running ledger. A ledger position, not a servicer-stated
outstanding — say so whenever it is quoted.

⚠ **Intrum's amicable cohort halves over the window and closures are not why.**
29,094 accounts (Mar 2025) to 19,767 (Jun 2026). Accounts leave by **turning
legal**: 17,003 enter `L002`, in batch stamps of up to 3,917 in one month. The
denominator moves for loading reasons, not behaviour.

---

## 3. ⚠⚠ Two grain bugs hit while building this

Both produced plausible-looking nonsense, so they are worth knowing.

**The account is the POSITION, not the LOAN.** `COLLECTIONS`, `PPT` and `PDR`
are all keyed on `(PORTFOLIO, POSITION_ID)`; only `LOANS` goes finer. Working at
loan grain and joining position-level cash fanned the cash across every loan in
the position — it read **49% of balance collected in one month and 92% in
another** before this was fixed. A position is open while any of its loans is.

**Cerved has what Intrum lacks.** `PDR_CATEGORY` is fully decoded, in English —
*Agreement post injunction (decreto ingiuntivo)*, *post writ of enforcement
(precetto)*, *Amicable Agreement*, and 13 more. ⚠ **This contradicts
`work/italy/legal/FINDINGS.md`**, which concluded no decreto ingiuntivo /
precetto breakdown exists. That was true **for Intrum instance 4034 only**.

---

## 4. ⚠⚠ Why the two servicers cannot be one number

| | Intrum (4034) | Cerved |
|---|---|---|
| "Amicable" is | phase code `A002`, **time-varying** | **not a field**, our definition, fixed |
| Settlement evidence | `CLOSING_DATE`; `closing_code` undecoded | `LOANS_STATUS` Open → Closed |
| Balance is | a **reconstructed ledger** | reported `OUSTANDING_GBV` |
| Sub-phases | **none** (`CUSTOM_CODE` 100% NULL) | 16 decoded `PDR_CATEGORY` values |
| Account grain | case (one loan) | **position** (a debtor's loans) |
| Window | Jul 2024 – Jun 2026 | Sep 2025 – Jul 2026 |

**Four things differ, not one.** A combined Italian settlement rate would
average four definitions over two windows. Compare the *shape*, never the level.

⚠ **Intrum's closing codes are undecoded but the mix IS available**: code `9` is
1,406 of the 2,073 closures, then `31` (297), `30` (201), `23` (169).
**Ask Intrum what those four mean** — it is the only thing that would separate
settlement from write-off on that book.

### ⚠ The amicable definition here is OURS and needs confirming

Cerved has no amicable flag. This file defines it as **open and never having
carried a legal-stage marker** — no `PPT` row, and no `PDR_CATEGORY` naming an
injunction, precetto, enforcement, sentenza, legal action, attachment or
concorsuale.

That definition is doing real work: it selects ~29,700 of the open positions,
and they collect very little — because most actively-worked positions have had
a pre-legal notice (`PPT`) and are therefore excluded. **Confirm this is the
cohort meant before presenting any of §1.**

⚠ Only **915** `PDR` rows are an explicit *"Amicable Agreement"*. Defining
amicable that narrowly instead would give a different and much smaller answer.

---

## 5. ⚠ Closed does not mean settled

`LOANS_STATUS` flips Open → Closed. Cerved does not say **why**, so a write-off
and a payment in full look identical.

→ **Read the closure rate beside `PERCENT_BALANCE_COLLECTED`.** A cohort
closing with little cash behind it is being written off, not settling. The 0–3
month band closes at 0.865% while collecting 1.004% of balance; the *never paid*
band closes at 0.083% on 0.023% — the first looks like settlement, the second
does not.

---

## 6. What is still open

1. **Confirm the Cerved amicable definition with the servicing team** (§4).
   Everything on that tab moves if the narrow reading is the right one.
2. **Ask Intrum to decode closing codes 9, 31, 30, 23.** Without them, closed
   vs settled cannot be separated on that book at all.
3. **Report the two missing Intrum payment months** (I2) to the data team.
4. **Neither book can be followed for longer than its window** — Cerved has 11
   observable months, Intrum 24. No cohort can be tracked further, and
   seasonality cannot be separated from trend on either.

## Files

| File | |
|---|---|
| `answer.md` | the PM note — both books, with the caveats inline |
| `italy-question.xlsx` | Read me + a tab per servicer, seven labelled questions each |
| `build_workbook.py` | rebuilds the workbook from the two queries |
| `cerved_settlement_by_age.sql` | one row per (snapshot month × balance band × last-payment band) |
| `intrum_settlement_by_age.sql` | same grain, reconstructed snapshot — guards I1–I4 in its header |
| `FINDINGS.md` | this file |
| `../italy-legal/FINDINGS.md` | the Intrum phase work this builds on — ⚠ see §3 for what it got wrong |
