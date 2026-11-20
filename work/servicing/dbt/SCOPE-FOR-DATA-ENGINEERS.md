# Servicing dashboard: case fields we need, for the data engineers to scope

**The problem in one line:** the warehouse knows each case's balance at every month end, but not, in a usable form, whether the case was **open or closed**, **what stage** it was in, or **how it paid** that month. The servicing dashboard needs all three.

**Two ways to fix it**
- **Easy:** add a few columns to tables that already exist, and count them per portfolio in the servicing mart. A draft PR does most of this (branch `sc/servicing-dashboard`, not merged).
- **Ideal:** one new table, **one row per case per month end**, holding every field below. The dashboard and anyone else can then filter cases directly instead of reading pre-counted totals.

Figures were measured on PROD on 15 October 2026. Where we are unsure, the row says so: please scope it rather than take our guess.

| Field we want | Where we think it is | What the database has today | What's lacking | Easy fix (cost) | Ideal fix (cost) | How sure we are |
|---|---|---|---|---|---|---|
| **Open or closed at month end** | `DIM_CASE.CLOSING_DATE` + `STATUS_CODE` | Both exist, versioned by date | No flag. The two disagree (2M Intrum cases have a closing date but an "open" code). Cerved and Gescobro send no closing date. | Closed = closing date by month end, or a closed status code. Computed in the mart. (Small, in the PR) | `is_open_flag` on the new case-month table | Sure |
| **Closed this month** | Same as above | – | Nothing counts closures per month | Count in the mart (small, in the PR) | `closed_in_month_flag` on the new table | Sure for Intrum and Massey. For Cerved and Gescobro only "first month marked closed". |
| **What the status code means** | Intrum's 103-code list (we have it as a file) | `DIM_CASE.STATUS_DESCRIPTION` exists but is always NULL | No code list anywhere in the warehouse | Lookup file (dbt seed), joined into `DIM_CASE` (small, in the PR; `DIM_CASE` needs one full rebuild) | Same, plus each servicer confirms its own codes | Intrum list solid. Our grouping of the codes needs sign-off. Massey codes 1–3 unknown. |
| **Insolvent** | Intrum status codes 12, 35, 36, 59, 67, 73 | Codes exist | No flag | Flag from the lookup file (small, in the PR) | `is_insolvent_flag` on the new table | Fairly sure for Intrum; nothing for other servicers |
| **Collection phase (Amicable / Legal / Enforcement)** | Intrum raw table `RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE` (347m rows) | Not in dbt at all | Never loaded. The status code only says "on-going" for most cases. | New staging model + phase-period model, counted in the mart (medium, in the PR) | `collection_phase` on the new table | Sure for Intrum where sent: about 80% of open cases have a phase. Other servicers send none. |
| **Big payment** (paid ≥ 15% of what it owed at the month's opening, at least €100) | `FCT_CASE_COLLECTION` + last month's `FCT_CASE_SNAPSHOT_DAILY.OUTSTANDING_TOTAL` | Both exist | Nobody combines them | Not in the PR. A small case-month model (medium) | `opening_balance`, `paid_in_month`, `is_big_payment_flag` on the new table | Rule is our proposal (Sep 2026: 5.3% of payers, 45% of the money). Principal or total balance still to agree. |
| **Steady payers (6 months running) and Lost after 6 months** | `FCT_CASE_COLLECTION` | Payments exist; the mart only looks back 2 months | No 6-month streak | Extend the mart's look-back (medium) | `paying_streak_months` on the new table; 6 or any other rule is then a filter | Sure it's buildable |
| **History before Brocc bought the portfolio** | Same tables | Data back to 2014 | The mart cuts everything before capex | Remove the filter (small, in the PR). The mart reads about 31x more rows, so it should become incremental. | New table built incrementally from day one | Sure. Cost to check. |
| **Stage for Cerved, Gescobro, Massey, Souq** | Gescobro `ASTREA_PROCEDURES`, Souq `LEGAL_STATUS` (raw); nothing for Cerved or Massey | Raw only, codes undocumented | Not loaded, and no code lists | Ask each servicer for their code meanings and a closing date | Add phase, insolvency and closing date to the servicer data contract, so every servicer sends the same fields | Unsure: needs the servicers' input |

**Cost notes for scoping**
- The new case-month table would be about the size of `FCT_CASE_SNAPSHOT_DAILY` (about 1.47bn rows, one per case per month end), so it should be incremental: only new months each night.
- The easy fix leaves the big snapshot table untouched. Its only rebuild is `DIM_CASE`, once.
- About 20% of open Intrum cases have no phase: Intrum sends "NA" or nothing, mainly for Portugal, Sweden, Finland and Switzerland. That is a request to Intrum, not a build task.

Detail: `work/servicing/REVIEW.md`, `work/servicing/dbt/FIELDS.md`, `work/servicing/dbt/PR.md`.
