# Italy settlement rates — Cerved

**For:** product manager
**Question:** of the open amicable accounts, how many pay off their debt each
month, and what share of their balance do they pay?
**Scope:** Cerved Italy · ~29,700 open amicable accounts · ~EUR 600m ·
11 monthly snapshots, October 2025 – August 2026
**Measured:** 2026-09-15, against the raw Cerved feed, read-only

*"Paid off" = the account closes and we stop collecting. Rates are monthly, over
the accounts and balance open at each snapshot.*

---

## The answer

**How recently an account paid predicts settlement far better than how much it
owes.** An account that paid in the last three months closes at roughly **20×**
the rate of one that has not paid in a year, and pays about **25×** as much of
its balance.

After six months without a payment the signal is gone — 7–12 months, 13–24
months and over 24 months all behave the same.

---

## By time since last payment

| Months since last payment | Accounts open *(monthly avg)* | Balance open *(monthly avg)* | Closed over 11 months | **Closure rate per month** | **% of balance paid per month** |
|---|---:|---:|---:|---:|---:|
| **0–3 months** | 1,093 | EUR 21.3m | 104 | **0.865%** | **1.004%** |
| 4–6 months | 176 | EUR 7.3m | 9 | 0.464% | 0.119% |
| 7–12 months | 451 | EUR 13.3m | 2 | 0.040% | 0.638% |
| 13–24 months | 997 | EUR 20.9m | 4 | 0.037% | 0.090% |
| Over 24 months | 4,333 | EUR 87.8m | 33 | 0.069% | 0.039% |
| **Never paid** | **22,690** | **EUR 448.6m** | 207 | 0.083% | 0.023% |

⚠ **Three quarters of the book has never made a payment** — 22,690 of ~29,700
accounts, EUR 448.6m of the EUR 600m. Any average across the whole book is
really a statement about those accounts.

---

## By balance

| Balance band | Accounts open *(monthly avg)* | Balance open *(monthly avg)* | Closed over 11 months | **Closure rate per month** | **% of balance paid per month** |
|---|---:|---:|---:|---:|---:|
| Under EUR 1k | 2,738 | EUR 1.0m | 107 | **0.355%** | **0.897%** |
| EUR 1k–5k | 3,722 | EUR 11.8m | 60 | 0.147% | 0.288% |
| EUR 5k–20k | 13,748 | EUR 158.2m | 108 | 0.071% | 0.082% |
| EUR 20k–100k | 9,377 | EUR 325.7m | 76 | 0.074% | 0.032% |
| Over EUR 100k | 155 | EUR 102.4m | 8 | 0.469% | 0.182% |

**Small balances settle fastest** — under EUR 1k closes at 5× the rate of
EUR 5k–100k, which is what you would expect when the whole debt is payable in
one go.

⚠ **Ignore the "over EUR 100k" rate.** It is 8 closures across 155 accounts over
11 months. One or two settlements move it by a percentage point; it is not a
trend.

---

## Three things to say with these numbers

**1. Closed does not mean settled.** The feed records that an account closed,
not *why* — a write-off and a payment in full look identical. That is why the
"% of balance paid" column sits beside every closure rate. Accounts paying
recently close at 0.865% while paying 1.004% of balance, which looks like
settlement. Accounts that never paid close at 0.083% on 0.023%, which does not.

**2. "Amicable" is our definition, not Cerved's.** Cerved has no amicable flag.
We have taken it as *open and never having reached a legal stage* — no pre-legal
collection notice and no post-legal agreement. **Worth confirming with the
servicing team before this is quoted**, because a narrower reading exists:
only 915 records carry an explicit *"Amicable Agreement"* label.

**3. Eleven months is the whole history.** The Cerved snapshot feed starts
2025-09-30. No cohort can be followed for longer than that, and no seasonality
can be separated from trend yet.

---

## Cerved vs Intrum — not yet comparable

The same analysis for the **Intrum** Italian book is not built. It will be a
**separate table, not a combined number**: "amicable" means a different thing in
each feed (a phase code for Intrum, our derived definition for Cerved), and the
account grain differs.

⚠ One thing found along the way, worth passing on: **Cerved records the legal
stage in plain language** — *decreto ingiuntivo*, *precetto*, agreement post
sentenza, and 13 more. Intrum's Italian feed has no sub-phase at all. An earlier
note that this breakdown did not exist was based on the Intrum book only.

---

*Working and full caveats: `work/italy/settlement/FINDINGS.md`.
Reproduce with `mise run sql -- work/italy/settlement/cerved_settlement_by_age.sql`.*
