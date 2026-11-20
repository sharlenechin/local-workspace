# Stakeholder review: what was asked, what we decided, what is still open

Started 2026-10-15. Context for writing the tests and updating the dashboard later. **The live dashboard is not changed yet.**

## 1. What the stakeholder asked for (her notes, tidied)

- Rename **Benchmark** control to **Forecast**, and **Accounting** to **Active**, so names match the NPL dashboard.
- Show history **before Brocc's capex date** (all time).
- **Number of open cases**, and closed cases per month.
- **Month-end case status**: is the case amicable, legal, in enforcement, insolvent? Clear labels.
- **Lost** = paid every month for the last 6 months, then stopped this month. As a bar (Lost shown negative?) with a line for the net.
- **One chart**: completely new payers and closed cases, each month end.
- **Big-ticket payments**: a table with a slider; flag a case if what it paid that month is more than x% of the principal it owes. Also the pattern "paid big in the last 6 months, then stopped / kept paying a bit".
- **Portfolio name** everywhere (keep the portfolio id / deal too). She chases by portfolio.
- Portfolio page: minor renames only.
- Cases page: she does not need every breakdown. **Total collections** (toggle open / closed cases), then the asks above. Think as head of servicing: what needs settling at a glance, and the trend.

## 2. The three answers every case gets at every month end

| Answer | Values | Where it comes from |
|---|---|---|
| **Open or closed?** | true / false | Closed if a **closing date** on or before month end, **or** a **closed status code** |
| **Which collection phase?** | Amicable, Legal, Enforcement, No phase data | Intrum's **phase table** (`GROUP_CASE_PHASE`, letters A / L / E). Other servicers send none. |
| **Insolvent?** | true / false | **Status code** (Intrum codes 12, 35, 36, 59, 67, 73) |

"Status code" and "case status" are the same thing: `DIM_CASE.STATUS_CODE`.

## 3. What we change (one dbt PR on `brocc-data` branch `sc/servicing-dashboard`; description in `dbt/PR.md`; mock: https://claude.ai/artifact/DiGverE4kFrAbcWb326mPM, illustrative figures)

1. **New lookup file**: `dbt/seeds/npl_status_code_mappings.csv`. What each status code means, per servicer.
2. **`DIM_CASE`**: join that lookup, so each status gets a description, a group, and closed / insolvent flags.
3. **Phase table**: one new staging model plus one small model of phase periods (from date, to date).
4. **Servicing cases mart**: works out open / closed / phase / insolvent per case per month end and counts them per portfolio-month. **Drop the capex filter** (history before purchase: 130.4m payment rows vs 4.3m after; consider an incremental build).
5. `FCT_CASE_SNAPSHOT_DAILY` is **not changed** (no 1.47bn-row rebuild). The mart reaches `DIM_CASE` through the snapshot's `case_sk`, the case version valid on that month end.

Rejected, and why: using `CASES.CASE_PHASE` instead of the phase table. It covers 42% of Intrum cases against 62%, its codes mean different things by country, and putting it on the case would create a new case version on every phase change.

## 4. How "closed" works per servicer (measured 2026-10-15)

| Servicer | Closing date on closed cases | Status says closed | We read closed from |
|---|---|---|---|
| Intrum | Mostly | Mostly, not always updated | Both (each catches the other's misses: 2.0m dated cases still coded "Registered" / "Other measures"; 312k "Completed" without a date) |
| Gescobro | Never (0 of 58,141) | "Closed" | Status only |
| Cerved | Never (0 of 342,700) | "Closed" | Status only |
| Massey | Yes since June | Code 4 (our inference) | Both |
| Souq | Almost never (2 of 57,781) | Blank | Nothing: every case reads open |

## 5. Questions to send out

**Intrum**
- Portugal (4050) sends no phase table; Sweden (2080, Heimdall), Finland (1033), Switzerland (3010) mark most cases "NA". Please fill A / L / E for every case. (About a third of Intrum cases have no phase today.)
- The full `GROUP_PHASE_CODE` list (only the first letter is confirmed) and the `LEGAL_INFO` step codes.
- The closing code list (to tell "paid off" from "written off").

**Massey**: what do status codes 1, 2, 3 and 4 mean? Is one legal or insolvency?

**Cerved, Gescobro**: send the closing date on closed cases, and per case each month the phase (Amicable / Legal / Enforcement) and an insolvency flag.

**Data team**
- Add `collection_phase` (AMICABLE / LEGAL / ENFORCEMENT), `insolvency_flag` and a required `closing_date` to the servicer data contract, so every servicer sends the same thing.
- Souq's raw feed has real legal stages (`LEGAL_STATUS`) that never reach PROD; a small staging change.
- Did the team keep Intrum's full code list behind the forbearance codes?

## 6. Decisions still open

- Head of servicing to glance down `status_group` in the lookup (our grouping, not Intrum's). Two judgement calls: 37 "Control letter" and 80 "Debt monitoring" put under Amicable.
- Stakeholder asks (Lost over 6 months, big-ticket flag) in **this PR or a second one**.

## 7. Evidence (all in `dbt/`)

- `status_code_usage.sql` + `status_code_usage_2026-04_to_2026-09.csv`: codes in use, Apr–Sep 2026
- `case_phase_vs_phase_feed.sql` + `case_phase_vs_phase_feed_2026-10-15.csv`: the two phase sources compared

## 8. Big payment: proposed definition (2026-10-15)

A month's payment of **at least 15% of what the case owed at that month's opening** (its `outstanding_total` at the previous month end) **and at least €100**. Shown two ways: this month's big payments (a flow) and big payers ever (a stock), plus whether they stopped or kept paying in the next three months.

Measured on September 2026 (PROD case feed, euro at September month-end rates):

| Rule | Cases | Share of payers | Paid |
|---|---|---|---|
| ≥ 5% of opening balance | 64,876 | 28% | too broad |
| ≥ 15% | 31,773 | 13.8% | €10.21M of €21.31M (48%) |
| ≥ 15% and ≥ €100 | 12,217 | 5.3% | €9.49M (45%) |

19,556 of the 15% cases paid under €100 (tiny balances), hence the floor; 7,239 (23%) of the 15% group had closed by month end (settlements and pay-offs). Not in the open dbt PR: big payments and Lost after 6 months need a second, smaller change (a case-month model with the opening balance).

## 9. Mock status

https://claude.ai/artifact/5SyvnqmbvMYyfhYaWjY9tm (Cases and Portfolio pages) carries every ask in section 1 with illustrative figures where the dbt change has not run. Backups of each step in `design/reference/Main.pre-*.html`.
