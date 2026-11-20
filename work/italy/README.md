# `work/italy/` — two Italian books, two questions, one scope

Both folders measured the same estate on **2026-09-15** and both pin **Intrum
CAT instance 4034**, so they were merged into one folder on 2026-10-02. They
answer different questions and their numbers are **not interchangeable**.

| Folder | Question | Sources |
|---|---|---|
| [`legal/`](legal/) | What legal phases exist, how many loans reach each, and how long the move takes | Intrum CAT 4034 only — 17 RAW tables |
| [`settlement/`](settlement/) | Of open amicable accounts, how many pay off each month and what share of balance they pay, by balance and time since last payment | Intrum CAT 4034 **and** Cerved |

Shared between them: `CASES`, `GROUP_CASE_PHASE` and `TRANSACTIONS`, all pinned
to instance 4034. That shared spine is why they live together.

## ⚠⚠ The one rule: never add the two servicers together

`settlement/` deliberately ships **two tables, never combined** — one Cerved,
one Intrum. The definitions behind them differ (the headers of both `.sql` files
spell out how), so a total across the two is not a bigger number, it is a wrong
one. Merging these folders changes nothing about that.

⚠ The same applies between the folders. `legal/` counts **48,547 loans** across
7 portfolios of seller "Blue SPV"; `settlement/` counts open amicable accounts
at a snapshot. A loan in one is not a comparable unit to a row in the other.

## The two headlines, so nobody re-derives them

**Legal.** Italy has **two phases, not a ladder.** Every loan starts amicable
(`A002`); 17,003 of 48,547 (**35.024%**) reach legal (`L002`). Of those,
**3,234 (19.020%) were bought already in legal** rather than escalated, and they
carry **EUR 294.5m — 39.1% of all legal capital**. The 13,769 that genuinely
escalated took a **median 198 days**. ⚠ How long a legal case *takes* is not
answerable: **98.265% are still open.**

**Settlement.** Recency of payment is the dominant predictor. On Cerved amicable
accounts, closure rate runs **0.865%** for accounts that paid in the last 0–3
months against **0.464%** at 4–6 months.

Each folder's `FINDINGS.md` is the durable record — what was asked, what the
data could answer, and what it could not. Read that before quoting anything.
