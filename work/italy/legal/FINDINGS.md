# Italy — legal phases · FINDINGS

Intrum CAT instance **4034**, 7 portfolios, seller "Blue SPV", **48,547 loans**,
**EUR 1,058,690,235.15** original capital. All figures measured against the live
warehouse on **2026-09-15**.

The notebook `italy_legal_phases.ipynb` is the readable version. This file is the
durable record: what was asked, what the data could answer, and what it could not.

---

## The headline

Italy has **two phases, not a ladder**. Every loan starts amicable (`A002`); 17,003 of
48,547 (**35.024%**) reach legal (`L002`). One transition exists. Of those in legal,
**3,234 (19.020%) were bought already in legal** rather than escalated, and they carry
**EUR 294.5m — 39.1% of all legal capital**. The 13,769 that genuinely escalated took a
**median 198 days**. How long a legal case *takes* is not answerable: 98.265% are open.

## The questions asked, and what came back

| asked | answer |
|---|---|
| What legal phases are there? | Two codes only: `A002` amicable, `L002` legal. `CUSTOM_CODE`, which would carry a sub-phase, is 100% NULL. **No decreto ingiuntivo / precetto / pignoramento breakdown exists in this feed.** |
| How many loans went through each stage? | A002 48,546 → L002 17,003. 31,544 never reach legal (31,543 amicable-only, plus 1 loan with no phase row at all). |
| Mean time in each phase | Time to escalate: median 198 / mean 281.0 days (escalated loans only). Time in legal: **censored**, see below. |
| Loan count | 48,547 — but **13,020 of them are expense lines, not loans**. |
| Where does the status-code mapping fit? | It decodes this book perfectly, to **two codes**: 64 On-going, 6 Completed. Open and closed. It yields no amicable/legal split for Italy. |
| Other insolvency / legal fields in CAT? | **None for this instance.** Every legal and insolvency table is empty. |
| Broken down by loan type | Done — but the source field is truncated to 10 chars and the grouping is ours. |

## The five findings that change a number

1. **`A002`'s start date is a batch-loading stamp, not a loan event.** Only 8 distinct
   A002 dates across 48,546 loans, each matching one portfolio's exact size
   (2024-12-24 = 17,241 = all of IT24013A010000). "Time in amicable" is therefore time
   from onboarding, not evidence of an amicable strategy.

2. **19.020% of legal loans never escalated — they arrived in legal.** `DAYS_IN_AMICABLE`
   has 3,234 loans at exactly 1 day and **nothing at all from day 2 to day 10** (the next
   loans are 3 of them on day 11). A gap that clean is a load artefact. Including them drops the median time-to-escalate from 198
   days to 156. They are capital-heavy: EUR 91k average against EUR 33k for escalators.

3. **`PRODUCT_ID`, `IS_TITLED` and `CASE_PHASE` are the legal flag in disguise.**
   `product_id=7` and `case_phase=2000` partition the book identically (709 never-legal /
   16,440 legal); `is_titled=1` is 95.9% legal against 1.2% for `is_titled=0`. Treating
   them as loan attributes produces a circular finding. **`IS_SECURED` is independent** —
   404 loans, escalating at 75.495% against 34.684%.

4. **26.818% of rows are cost lines, not loans.** `SPESE` / `SPESE LEGALI` / `SPESE
   DIVERSE` and friends: 13,020 rows, EUR 9.4m, averaging EUR 723 against EUR 86,805 for
   a mortgage. 0.889% of capital. Any per-loan average that leaves them in is about half
   the truth.

5. **`L002` is stamped repeatedly and the repeats are not re-entries.** 7,792 of 17,003
   legal loans carry 2-8 L002 start dates. Consecutive case_ids share identical
   sequences (1182342/1182343/1182344 all read L002 on 2024-12-16, 2025-03-17,
   2025-04-14, 2026-06-23), so these are tranche stamps. Only the **first** is used.
   Summing per-stamp durations would count the same days up to 8 times.

## Escalation by loan type — the substantive result

| loan type | loans | capital EUR | escalation rate | median days to escalate |
|---|---:|---:|---:|---:|
| Leasing | 61 | 15,578,227.95 | 75.410% | 148 |
| Mortgage (mutuo) | 3,504 | 303,920,584.86 | 63.870% | 248 |
| Guarantee (fideiussione) | 231 | 8,323,590.76 | 59.740% | 169 |
| Advances / receivables | 3,118 | 117,463,171.93 | 56.158% | 189 |
| Other / unmapped | 531 | 91,036,043.55 | 41.808% | 189 |
| Loan / financing | 6,644 | 159,292,956.77 | 41.556% | 189 |
| Current account / overdraft | 19,826 | 351,479,547.25 | 34.606% | 189 |
| Cards | 536 | 2,188,763.16 | 28.172% | 198 |
| Expenses (not loans) | 13,020 | 9,407,348.92 | 21.774% | 406 |
| Unclassified | 1,076 | 0.00 | 0.000% | — |

Totals: 48,547 loans / EUR 1,058,690,235.15. Loans in legal hold EUR 752,594,965.64.

Secured, big-ticket credit goes to court and goes there often. **Mortgages are the single
biggest block of legal capital on the book: 2,238 of 3,504 in legal.** Note the trap —
unsplit, mortgages show a median of *1 day* because 1,139 arrived in legal; split out,
the genuine escalators are the **slowest** major type at 248 days, not the fastest.

## Time in legal — why it is not answerable

| | n | median days |
|---|---:|---:|
| All legal loans, entry to horizon or closure | 17,003 | 385 |
| **Still open (censored)** | **16,708 (98.265%)** | — |
| Entered legal *and* closed | **295** | **262** |

Only 295 loans give an uncensored duration. Quote 262 days as indicative **with the n
attached**; the 385 is "how long ago they entered", bounded by the feed horizon
(2026-07-31), not by an outcome.

## Insolvency: nothing, and it is an Intrum question

Row counts for instance 4034, measured 2026-09-15 (`cat_table_coverage.sql`):

| table | rows | what it would have given us |
|---|---:|---|
| `BANKRUPTCY_RECORD` | **0** | `INSOLVENCY_OPEN_DATE`, `BANKRUPTCY_END_DATE`, affidavit, arrest warrant |
| `LEGAL_STEPS` | **0** | `LEGAL_STEP` + `START_DATE` + `END_DATE` — per-stage durations |
| `LEGAL_INFO` | **0** | judgement/summons dates, verdict amounts, legal process code |
| `LEGAL_RESULT_INFO` | **0** | outcome of each step, and the next step |
| `LEGAL_STEP_PARTIES` | **0** | parties to each step |
| `ASSIGNMENT` | **0** | external lawyer / bailiff, and de-assignment reason |
| `SETTLEMENT`, `DEBT_CHARGES`, `CASE_PRODUCT`, `PRODUCT_HISTORY`, `CASE_EXTENSION` | **0** | |
| `GROUP_CASE_PHASE` | 77,285 | the phase spells this analysis rests on |
| `CASE_STATUS_CHANGE_HISTORY` | 50,746 | open/closed only |
| `CASES` / `TRANSACTIONS` | 132,011* / 289,788 | *first extract is the full load |

The legal columns on `CASES` are 0% filled too: `COURT_PROCEDURE`, `JUDGEMENT_DATE`,
`SERVING_DATE`, `LEGAL_CLAIM_REASON`, `STATUTE_BARRED_DATE`, `DEBT_ENFORCEMENT_NUMBER`,
`DENOUNCEMENT_DATE`.

**Ask Intrum** whether the Italian servicer populates the legal module at all, or whether
those tables exist for 4034 and are not in the extract we receive. Until then, legal
analysis for Italy stops at amicable-vs-legal.

## Data-quality items to report to the data team

Per CLAUDE.md Rule 6 these are reported, not fixed here, and none has been worked around
invisibly.

1. **`CASE_CLASSIFICATION` is truncated to exactly 10 characters at source.** max(length)
   is 10 across all 133 values: "CONTO CORR", "SPESE LEGA", "MUTUO IPOT". Some are
   genuinely ambiguous ("CREDITO A", 3,149 loans) and the same product appears under
   variant spellings ("MUTUO CHIR" / "MUTUI CHIR"). This is the only loan-type field.
2. **`MAIN_STATUS_CODE` disagrees between two CAT tables.** `CASES` says `0`
   ("Registered — no action taken yet") for 46,474 loans; `CASE_STATUS_CHANGE_HISTORY`
   says `64` ("On-going") for 48,546. `PROD.DIM_CASE` inherits the `0`, which is plainly
   wrong for a book that is 35% in legal.
3. **`PROD.DIM_CASE.STATUS_DESCRIPTION` is NULL for all 48,547 loans**, and
   `CLOSING_CATEGORY` / `CLOSING_DESCRIPTION` likewise. The 103-code lookup
   (`main_status_code.csv`) belongs in `brocc-data` as a **dbt seed** so every model can
   decode it. That is a separate Rule 1 request — not added from here.
4. **`GROUP_CASE_PHASE` is not modelled in PROD and is not declared as a dbt source.**
   It is the only place phase history exists, for any instance.
5. **`GROUP_CASE_PHASE` records tranche stamps as if they were case events** (finding 5
   above), with no field distinguishing a genuine phase entry from a re-stamp.

## Gotchas specific to instance 4034

- **The FIRST extract is the full load, the other eight are deltas** — the opposite shape
  to 4050. `20251103T122454` holds 48,329 cases; the rest hold 12k-24k each. Taking
  `max(_file_path)` returns 18,798 loans instead of 48,547, with no error. Read all
  extracts and dedupe to the latest version per `case_id`.
- **CAT gives this book no extra history.** The usual reason to prefer raw CAT is PROD's
  2014-10-10 collection floor; it does not apply. Registrations run 2024-07-21 to
  2025-12-07 and the phase feed starts 2024-07-21. PROD holds the same 48,547 cases and
  agrees on the status split exactly. `DEFAULT_DATE` does reach back to 1993-07-30 — the
  debts are old, Intrum's case records are not.
- `_file_path` must be a **literal prefix**; a leading `%` loses partition pruning on a
  6.4bn-row table.

## Files

| file | what it is |
|---|---|
| `italy_legal_phases.ipynb` | the analysis, with the caveats inline |
| `loan_phase_history.sql` | one row per loan. **The authority — all guards are in its header** |
| `phase_summary.sql` | funnel + durations by loan type and route |
| `cat_table_coverage.sql` | proof of which CAT tables are empty; parameterised by `source_system` |
| `main_status_code.csv` | Intrum's own 103-code lookup with their comments |
