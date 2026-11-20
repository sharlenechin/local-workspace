# Project Sea — benchmark dataset

**Portugal · Intrum instance 4050 · five originators · one-off purchases only**
Built and measured **2026-10-01**. Every figure in this document carries that
date unless another is stated; the loan-level feed itself stops at **2026-01-14**.

| | |
|---|---|
| Country | PT |
| Originators (PAM `SELLER_NAME`) | `WIZINK BANK`, `BARCLAYCARD`, `MILLENNIUM`, `ONEY`, `COFIDIS` |
| Batches | **26** one-off batches (24 of them have loans in the loan-level feed) |
| Loans | **217,104** |
| Registration balance | **EUR 1,277,597,649.95** (capital 1,219,554,121.41 + interest 58,043,528.54) |
| Lifetime collections, loan level | **EUR 276,731,289.53** to 2026-01-14 |
| Deal type | `One-off` only. 141 forward-flow batches excluded — see the exclusion table |
| Registration years | 2005–2020, all kept |

## Rung reached: 3 · RECONCILED — and read the next paragraph before quoting it

Every one of the 26 batches has been compared with Intrum's own report over a
matched window, and every batch either ties within 1% or sits on the escalation
list below **with a named hypothesis**. That is what rung 3 means: a collections
total from this book is defensible externally.

**It is not signed off (rung 4).** 12 of the 26 batches do not tie, and three of
them are material: WiZink's `PT19007D010000` (−33.18%), `PT19013B010000`
(−61.18%) and `PT19013A020000` (−10.35%). Until Intrum answers those,
**do not quote a WiZink seller-level recovery rate from this dataset** — use
PAM's own collections for WiZink instead. The other four sellers are within
−0.65% to +1.36% at seller level.

---

## ⚠ Three things that would make you misuse this data

**1. The balance sizes a book. It must never rank two books.**
`REGISTRATION_BALANCE` is capital plus interest, and interest is delivered
completely differently by each originator. Interest as a share of capital:

| | ONEY | WIZINK | BARCLAYCARD | MILLENNIUM | COFIDIS |
|---|---|---|---|---|---|
| interest / capital | 67.22189% | 20.11564% | 12.07480% | 0.65904% | 0.00000% |
| loans with zero interest | 18.12% | 6.00% | 4.39% | 99.14% | **100%** |
| loans owing more interest than capital | 1,361 | 975 | 64 | 22 | 0 |

Not one of Cofidis's 8,426 loans carries positive interest; 117,490 of
Millennium's 120,713 carry an explicit 0.00. A recovery-over-balance league
table across these five sellers measures **accrual delivery, not performance** —
it would rank Oney last for a reason that is entirely about how Intrum booked
the claim. **Compare on recovery over capital, or over PAM's acquisition
principal.** Within one seller the balance is sound.

**2. The loan-level feed is seven months behind the servicer's report.**
CAT's last payment is 2026-01-14; PAM has actuals to 2026-08. The missing months
are EUR 6,365,823.40 — only **2.25069% of lifetime collections**, but
**59.64415% of the last twelve months' cash**. Anything about recent
performance must come from PAM, not from `payments.csv`.

**3. Undated cash is in the file and will vanish the moment you filter on a
date.** EUR 5,587,796.29 (2.01921% of all collections, 6,233 loans) has no
payment date in any version of the transaction. It is flagged
(`MISSING_PAYMENT_DATE_FLAG`), not dropped. Build a monthly curve and your total
is short by that much — do not then call the remainder "the book's collections".
It is almost all Millennium (3.40154% of its cash) and Cofidis (0.77669%).

---

## The book, by originator

| Originator | Batches | Loans | Capital | Balance | Collections (CAT) | Recovery on capital | PAM acq. principal | Capex paid | Price |
|---|---|---|---|---|---|---|---|---|---|
| MILLENNIUM | 14 | 120,713 | 906,554,742.21 | 912,529,292.37 | 160,228,394.35 | 17.67443% | 903,461,713.18 | 68,098,053.99 | 7.53746% |
| WIZINK BANK | 4 | 34,357 | 141,881,273.65 | 170,421,597.18 | 53,647,718.14 | 37.81170% | 149,992,805.27 | 31,170,888.47 | 20.78159% |
| BARCLAYCARD | 2 | 30,584 | 103,473,581.87 | 115,967,810.86 | 43,043,724.86 | 41.59876% | 113,011,013.53 | 5,036,185.08 | 4.45637% |
| ONEY | 4 | 23,024 | 16,414,929.87 | 27,449,355.73 | 2,098,860.49 | 12.78629% | 26,818,088.69 | 1,820,993.38 | 6.79017% |
| COFIDIS | 2 | 8,426 | 51,229,593.81 | 51,229,593.81 | 17,712,591.69 | 34.57492% | 51,229,593.81 | 3,122,778.57 | 6.09565% |
| **Total** | **26** | **217,104** | **1,219,554,121.41** | **1,277,597,649.95** | **276,731,289.53** | **22.69119%** | **1,244,513,214.48** | **109,248,899.49** | **8.77844%** |

Money multiple on PAM's lifetime collections (to 2026-08) over capex paid:
Barclaycard 8.60590×, Cofidis 5.82577×, Millennium 2.37525×, WiZink 1.84183×,
Oney 1.17880×, whole book 2.58896×. ⚠ Lifetime collections are **not
risk-adjusted and not time-adjusted**, so these multiples are not comparable:
Barclaycard's is thirteen years of cash on a 4.46-cent purchase price (capex
2013 and 2015), while Oney's batches run 2013 to 2020 and WiZink's 2018–2019.

⚠ **PAM's acquisition case count is not our loan count and must never be
differenced against it.** PAM counts cases at acquisition (257,593 across the 26
batches); we count loans still in the loan-level feed today, after the guards
(217,104). They count different things at different dates. The ledger prints
them side by side.

---

## What was excluded, and why

A reader cannot see what is missing from a CSV. This is every scope filter,
including the ones that removed nothing.

| Filter | Batches removed | Loans | EUR removed | Reason — in words |
|---|---|---|---|---|
| Forward flow, WIZINK BANK | 129 | 37,495 in CAT | 54,294,403.41 PAM collections; 185,886,465.90 acquired principal | `DEAL_TYPE_DESC = 'Ongoing'` is a standing agreement under which newly defaulted accounts arrive every month. The population is not fixed, so there is no stable denominator and no cohort for a vintage curve; capex is not a single event, so every per-batch acquisition comparison moves; and loans added after the CAT extract look exactly like a feed gap. Not a benchmark. |
| Forward flow, BARCLAYCARD | 12 | 7,314 in CAT | 12,531,227.79 PAM collections; 29,790,744.81 acquired principal | as above |
| Performing portfolios | 0 | 0 | 0 | `PORTFOLIOTYPE` carries `Performing` elsewhere in the estate (8 batches), but all 167 batches for these five sellers are `Non-Performing`. Nothing removed; checked, not assumed. |
| Ownership-change rows | 0 | 0 | 0 | `IS_OWNERSHIP_CHANGE = 1` restates a batch for a legal-buyer transfer and would double it. Zero such rows exist in this scope. |
| `$exclude_batches` | 0 | 0 | 0 | Ships **empty on purpose**. Project Elsa excludes six batches; that is a pricing decision, not a measurement — see "Elsa's exclusions" below. |
| Debtor-type gate | 0 | 0 | 0 | The template drops loans with no identifiable debtor. Not applied: `INDIVIDUAL_FLAG` carries `NULL` on those 177 loans instead, which states the same fact without removing a loan, and keeps accounts and payments pairing exactly. |
| Container cases (`CASE_ID` containing `-`) | — | not re-measured | — | Dropped as dbt does. Elsa measured this as a no-op on instance 4050; kept so `$source_system` can change. Not re-measured today. |
| Other PT originators | n/a | n/a | n/a | Portugal has about 30 originators in PAM (Unicre, Portugal Telecom, Nestlé Water, Avon and more). They are outside this book by the user's scope decision, not by a data rule. |

**Forward flow is 141 of the 167 batches PAM names for these five sellers — 84%
of the batch count and EUR 66,825,631.20 of collections.** It is the single
largest thing missing from these CSVs, and it is missing deliberately.

---

## Does it tie to Intrum's own report?

`reconciliation.sql` → `project_sea_batch_ledger.csv`, one row per
batch, all 167, each with its status in a sentence.

The comparison is **window-matched**: CAT cut at each batch's capex month (PAM's
life starts there) and both sides closed at the last **complete** CAT month,
derived in the query rather than hard-coded. Undated cash is credited back
before the residual is read.

| | EUR |
|---|---|
| PAM, matched window | 276,475,500.90 |
| CAT, matched window | 266,588,362.63 |
| CAT undated, credited back | 5,587,796.29 |
| **Net residual** | **−4,299,341.98 (−1.55505%)** |
| **Gross residual** (sum of absolute per-batch) | **7,093,665.66 (2.56575%)** |

⚠ **Quote both.** The net figure is two sets of errors cancelling — Elsa's
famous 99.88% was exactly that. Per seller the residual is Barclaycard +1.36087%,
Oney +0.65780%, Cofidis −0.37005%, Millennium −0.65120%, **WiZink −6.88985%**.

**12 of 26 batches reconcile within 1%. The other 14, each with a hypothesis:**

| Batch | Seller | Residual | Residual ratio | Hypothesis — what we think it is |
|---|---|---|---|---|
| `PT19007D010000` | WIZINK | −3,157,533.27 | 0.66818 | 3,605 loans in CAT against 4,633 cases PAM says it bought — about a fifth of the batch has no loan-level record. Missing population, not missing cash. **Intrum's to answer.** |
| `PT13004E010000` | BARCLAYCARD | +658,840.36 | 1.01835 | CAT over by 1.8%. Carries 267,819.36 of cash dated before its own capex month, and C8 keeps loans whose newest version left the scope — both push CAT above what PAM can bill to this batch. |
| `PT15018G000000` | MILLENNIUM | +435,685.23 | 1.01296 | CAT over by 1.3%, with 1,571,494.31 of pre-capex cash. Elsa measured 2,173 loans on this batch (12% of it) whose newest version carries a **null** batch reference; our guard keeps them here while PAM may bill them elsewhere. |
| `PT19013B010000` | WIZINK | −309,201.77 | 0.38816 | 232 loans against 310 acquired cases. Same shape as `PT19007D010000`, smaller. **Intrum's to answer.** |
| `PT070040000000` | MILLENNIUM | −340,000.00 | 0.00000 | **Not cash at all.** PAM posts 340,000.00 once, in the capex month, exactly equal to its own acquisition principal; across all 26 batches only this one and `PT06014B010000` ever do that, against 3,906 collecting months elsewhere. CAT holds 2 loans worth EUR 4.00, registered 279 days after capex. An accounting entry. |
| `PT16023C000000` | MILLENNIUM | +277,043.77 | 1.01512 | The 84 cases that PAM bills to `PT15018A040000` resolve into this batch under the latest-in-scope rule. The two batches' residuals partly cancel (+277,044 here, −126,094 there). A misallocation between two batches, not missing money. |
| `PT06014B010000` | MILLENNIUM | −660,000.00 | 0.00000 | **No cases in CAT under any instance.** Same single-posting signature as `PT070040000000` — PAM's 660,000.00 equals its acquisition principal to the cent. A feed gap on an accounting entry. |
| `PT15018A040000` | MILLENNIUM | −126,093.94 | 0.00000 | **No cases in CAT**; its 84 cases live under `PT16023C000000` (above). PAM still carries 18,551,110.00 of acquired principal against it. |
| `PT19013A020000` | WIZINK | −103,327.76 | 0.89651 | 544 loans against 733 acquired cases. ⚠ This is also the batch that inflates to 909 loans if the deal-type filter is written in the wrong place — see "How to reproduce it". |
| `PT15016D000000` | BARCLAYCARD | −85,230.67 | 0.98634 | 3,708 loans against 3,958 acquired cases: 250 cases absent from CAT, and a 1.4% shortfall is the right order of magnitude for that. |
| `PT07010C000000` | MILLENNIUM | −66,693.36 | 0.98766 | 2,940 loans against 5,435 acquired cases — nearly half absent. The surprise is that the shortfall is only 1.2%, i.e. the missing cases had collected almost nothing. |
| `PT10002B000000` | COFIDIS | −27,701.21 | 0.97000 | 500 loans both sides, EUR 27,701 on a 923k batch. Consistent with PAM restating late cash after the CAT extract. Immaterial. |
| `PT13013C000000` | ONEY | +23,856.50 | 1.08421 | CAT over by 8.4% on a 283k batch — EUR 23,857. Small absolute figure; most likely cash CAT dates into a month PAM books differently. |
| `PT17013C000000` | ONEY | −11,874.10 | 0.98962 | 1.0% short, barely outside the band, on a batch where PAM delivers **no** `ACQCASES` at all. Timing, not structure. |

---

## Column dictionary

### `project_sea_benchmark_accounts.csv` — one row per loan, 217,104 rows

| Column | Meaning | What it is **not** |
|---|---|---|
| `SELLER` | exact PAM `SELLER_NAME`, upper-cased | not Brocc's counterparty — `DIM_DEAL.SELLER_NAME` says "Intrum" for all five |
| `DEAL_TYPE` | `One-off` on every row as shipped | |
| `PORTFOLIO_ID` | the **batch** reference, PAM `COMBINED_REF` | not `PAM.PORTFOLIOID` (7 chars, one per several batches) and not `DIM_PORTFOLIO.PORTFOLIO_BK` — joining to either matches nothing, silently |
| `LOAN_ID` | raw Intrum `CASE_ID` | not PROD's key; that is `'4050-' \|\| LOAN_ID` |
| `CURRENCY_ID` | `EUR` on every loan but one (NULL) | |
| `REGISTRATION_DATE` | when **Intrum** opened the case | not origination. On this book it is the same event as acquisition: 99.64% of loans register within one month of their batch's capex |
| `DEFAULT_DATE` | `DIM_CASE.DERIVED_DEFAULT_DATE` | **not an observed default event** — the raw feed's own `DEFAULT_DATE` is 100% NULL, and this is back-filled from the latest invoice due date, so it is biased late |
| `REGISTRATION_CAPITAL` | balance when the loan entered Intrum's system | not an origination face value — it is 91–100% of what PAM says was acquired |
| `REGISTRATION_INTEREST` | interest at registration. **NULL where not delivered, 0.00 where genuinely zero — different facts** | not accrued interest since |
| `REGISTRATION_BALANCE` | capital + interest | **not comparable between sellers** — see warning 1 |
| `HAS_REGISTRATION_INTEREST` | false = capital only on this row | |
| `DEFAULT_DATE_SUSPECT_FLAG` | default date before 1990 (1,907 loans, all Millennium, earliest 1977-03-15) | |
| `DEFAULT_AFTER_REGISTRATION_FLAG` | default date later than registration — impossible for an acquired NPL (989 loans, incl. 342 Oney loans dated 2099-12-31) | |
| `INDIVIDUAL_FLAG` | true = private debtor only (204,057); false = a company is on the loan (12,870); **NULL = nobody recorded a type** (177) | not a size class — there is no turnover, headcount or company number anywhere in the feed |
| `DEBT_AGE_YEARS` | (registration − default) / 365.25, **NULL on every unusable date** | not zero-filled. See caveat 4 |

### `project_sea_benchmark_payments.csv` — one row per loan per payment date, 1,284,551 rows

| Column | Meaning |
|---|---|
| `SELLER`, `DEAL_TYPE`, `PORTFOLIO_ID`, `LOAN_ID` | as above; carried so the book can be split without re-joining |
| `PAYMENT_DATE` | `TRANSACTION_DATE`, recovered across every version of the transaction. NULL where no version carries one |
| `MISSING_PAYMENT_DATE_FLAG` | true on undated cash — EUR 5,587,796.29 |
| `TOTAL_COLLECTIONS` | cash for that loan on that date, sign corrected. 4,784 rows are negative (reversals, EUR −3,138,527.45) and are kept |

⚠ **Aggregate payments to loan level before joining to accounts**, with a LEFT
join. Joined raw, every balance repeats once per payment row; joined INNER, the
123,412 loans that never paid disappear and the total falls *and* the survivors
multiply.

### `project_sea_batch_ledger.csv` — one row per PAM batch, 167 rows

Acquisition columns (`CAPEX_*`, `ACQ_*`, `PAM_*`) come from **Intrum's own batch
report**, never from a roll-up of our loans. `CAT_*` columns are ours.
`STATUS_REASON` is the in-or-out sentence; `ELSA_TREATMENT` names Elsa's
decision on the six batches it drops.

---

## Caveats, each with a number against it

1. **Seller-to-seller balance comparison is invalid.** Interest runs 0.00% to
   67.22% of capital across the five. Compare on recovery over capital.
2. **The loan-level feed is 7 months stale**: 2.25069% of lifetime collections
   but 59.64415% of the trailing twelve months.
3. **12 of 26 batches do not tie**, net −1.55505% and gross 2.56575% of PAM.
   WiZink alone is −6.88985%.
4. **Debt age is guarded and an unguarded version is wrong by more than a
   year.** Three kinds of unusable default date are set to NULL: absent (23
   loans), pre-1990 (1,907), and later than registration (989, including Oney's
   342 loans dated 2099-12-31, each worth about minus 82 years). Oney's mean
   reads 2.06376 years unguarded and **3.33343 guarded**. Always quote the
   surviving denominator: 214,185 of 217,104 loans (98.65548%), whole-book mean
   3.38973 years.
5. **PAM's own `AVERAGE_DEBT_AGE` is unusable — its units are inconsistent
   between batches.** WiZink reads a median of 18 and a max of 72 (months);
   Barclaycard 2.8 and Cofidis 1.67 (years); Oney spans 1.4 to 72 within one
   seller. 13 WiZink and 1 Oney batch read above 24. It is carried in the ledger
   so the defect is visible and can be escalated. **Never quote or average it,
   and do not "fix" it by dividing by twelve** — we do not know which batches
   are in which unit.
6. **`REGISTRATION_CAPITAL` is an inference**, re-tested on this book: it is
   91.56–100.34% of PAM's acquisition principal on four sellers, **61.21% on
   Oney**. Oney's capital + interest is 102.35% of PAM's figure, which suggests
   PAM's "acquisition principal" there is the whole claim rather than principal.
   Open question for Intrum; it moves no loan-level number.
7. **`DEFAULT_DATE` is a proxy on every loan.** The raw field is 100% NULL; the
   warehouse back-fills it from the latest invoice due date under a
   country-specific rule, which drifts late. Treat any seasoning or
   time-to-recovery analysis built on it with suspicion.
8. **`PRINCIPAL_AT_CUTOFF`, `INTEREST_AT_CUTOFF` are 100% empty** (0 of
   217,104). So is the raw `DEFAULT_DATE`. Do not design around them.
9. **Nothing here is a current balance.** These are opening figures at
   registration. Remaining capital exists in the feed (974,014,347.39 against
   1,219,554,121.41 opening) but is undated and is not in these files.
10. **7 loans have a zero registration balance and 23 have zero or negative
    capital**, all Millennium. They are kept; drop them deliberately downstream
    if your model needs it.
11. **This is a pre-Brocc history, not a pre-originator one.** CAT starts when
    Intrum registered the loan. The originating bank's own payment history is in
    neither CAT nor the warehouse.
12. **Payments run back to 2000** (Millennium) and 2002 (Barclaycard), years
    before acquisition. That is deliberate and is what underwriting wants; EUR
    4,288,048.76 (1.54954%) predates its own batch's capex and is removed in the
    reconciliation only.

---

## Which source answered what, and why not the others

| Question | Source used | Why not the obvious alternative |
|---|---|---|
| Which batches belong to which originator | `RAW.HYPERION_INTRUM_PAM.PAM.SELLER_NAME` | **The originator exists in exactly one place in the warehouse — here.** `DIM_DEAL.SELLER_NAME` records who Brocc bought from (Intrum, on all five), and there is no originator dimension in PROD or RAW. |
| One row per loan, balances, dates | `RAW.HYPERION_INTRUM_CAT.CASES` | `DIM_CASE.ORIGINAL_PRINCIPAL` is populated on 14.5% of loans warehouse-wide and there is no registration-interest column at all. |
| Collections | `RAW.HYPERION_INTRUM_CAT.TRANSACTIONS` | `PROD.FCT_CASE_COLLECTION` truncates each case at the date it joined the servicer's platform — **42–58% of the money, with no error raised**. |
| Default date | `PROD.NPL_COMMON.DIM_CASE.DERIVED_DEFAULT_DATE` | The raw field is 100% NULL on instance 4050. The warehouse value is the only one available, and it is derived — caveat 7. |
| Borrower type | `RAW.HYPERION_INTRUM_CAT.DEBTORS` | PROD's borrower key is `source_system_code \|\| '-' \|\| debtor_row_number` with no case in it, and one row number is shared by 296,041 cases. The loss is **anti-company**, so PROD understates the corporate segment by construction. Reported to the data team; not fixed here. |
| Acquisition side of the ledger | PAM, newest whole delivery | A roll-up of `accounts.csv` is a different quantity at a different date. |

### Borrower-type probe (step 6), measured so the rule is stated rather than assumed

The rule shipped is **company wins**: a loan with any company debtor reads
`INDIVIDUAL_FLAG = false`. That is a policy, matching Elsa, not a reading of the
data.

| | company wins (shipped) | company only (opposite rule) | carry both types |
|---|---|---|---|
| MILLENNIUM | 12,844 loans, 445,511,420.06 capital | 1,470 loans, 51,356,892.06 | 11,374 |
| COFIDIS | 10 | 3 | 7 |
| ONEY | 6 | 1 | 5 |
| WIZINK BANK | 6 | 4 | 2 |
| BARCLAYCARD | 4 | 0 | 4 |

**The whole question lives in Millennium**, where the two rules differ by a
factor of nine on loan count and by EUR 394m of capital. Portfolio totals are
robust to it; any segment-differentiated pricing is not. The other four books
are consumer books — 26 company loans between them, 0.01% of their loans.

---

## Elsa's exclusions — documented, not applied

Project Elsa (Portugal / Millennium + WiZink) drops six batches and two classes
of loan. `$exclude_batches` here **ships empty**, because that is a pricing
decision taken on an overlapping book, not a measurement. Both views:

| | Batches | Loans | Balance | Collections |
|---|---|---|---|---|
| **As shipped** (no exclusions) | 24 with loans | 217,104 | 1,277,597,649.95 | 276,731,289.53 |
| **With Elsa's rules applied** | 20 | 212,540 | 1,253,891,128.16 | 268,999,109.52 |

What each Elsa rule removes from this book: the six batches 4,383 loans /
23,469,951.60 balance / 7,534,586.53 collections; loans with no debtor type
(E1) 177 loans / 201,429.10; WiZink's company-debtor loans (E3) 6 loans /
36,446.38. ⚠ **The rules overlap on 2 loans**, so the distinct total is 4,564,
not the 4,566 you get by adding them.

To apply them, set in all three files, byte-identically:

```
set exclude_batches = 'PT06014B010000,PT070040000000,PT15018A040000,'
                   || 'PT19007D010000,PT19013A020000,PT19013B010000';
```

**Cross-check against Elsa, which was built independently:** with Elsa's rules
applied this rebuild returns Millennium at **11 batches, 120,543 loans, capital
906,359,149.41, balance 912,333,699.57, collections 160,045,164.05** and WiZink
one-off at **PT18019A000000 alone, 29,971 loans, capital 122,891,559.16** —
identical to Elsa's published figures on every one of those numbers. Two
separately written queries agreeing to the cent is the reason to trust either.

---

## How to reproduce it

```
mise run sql -- work/project-sea-benchmark/accounts.sql \
      --csv work/project-sea-benchmark/project_sea_benchmark_accounts.csv
mise run sql -- work/project-sea-benchmark/payments.sql \
      --csv work/project-sea-benchmark/project_sea_benchmark_payments.csv
mise run sql -- work/project-sea-benchmark/reconciliation.sql \
      --csv work/project-sea-benchmark/project_sea_batch_ledger.csv
```

Runtimes 2 / 6 / 6 minutes on `NPL_ANALYST_WH` (X-Small, shared).

**Four parameters that are easy to get wrong:**

1. ⚠⚠ **`$deal_type` must be applied at the FINAL SELECT, never in the
   `batches` CTE.** Filtering early changes what the change-history dedupe can
   see, and the batch filter then re-attributes loans. Measured today: the early
   version moves **365 loans** out of `PT19007E021905` (forward flow) into
   `PT19013A020000` (one-off), inflating that batch from 544 to 909 and the book
   from 217,104 loans to 217,469. The proof the placement is right: the three
   sellers that run *only* one-off batches — Millennium, Oney, Cofidis — return
   **identical** counts filtered and unfiltered (120,713 / 23,024 / 8,426).
2. ⚠ **`$seller_list` matches exact names, not substrings.** `GE MONEY BANK`
   contains `ONEY`; a regex alternation of the kind Elsa uses would silently
   pull a sixth originator into this book. And a stray space —
   `'WIZINK BANK, BARCLAYCARD'` — makes `SPLIT` yield `' BARCLAYCARD'`, which
   never matches, and that seller vanishes from the whole book with no error.
   The `REPLACE(', ', ',')` guards it; keep it.
3. ⚠ **The parameters must be byte-identical across all three files.**
   `$seller_list`, `$deal_type` and `$exclude_batches` are copied, not imported.
4. ⚠ **`$source_system = '4050'` costs nothing and that is measured.** Asked
   with **no** path filter on 2026-10-01, of the 19 Intrum instances in the feed
   only 4050 holds any batch reference beginning `PT` — 266 batches, 1,156,769
   cases. So an originator reading zero loans is genuinely absent from the
   loan-level feed, not hidden behind the pin.

**Asserts worth keeping** (all verified today): `LOAN_ID` unique (217,104 rows,
217,104 distinct); no loan under two batches; every
`(PORTFOLIO_ID, LOAN_ID)` in payments exists in accounts (0 orphans); capital +
interest = balance on every row; one currency (EUR, with one NULL loan).

---

## What this dataset cannot answer

- **Anything about the last seven months.** Use PAM.
- **Anything about forward flow**, which is 84% of these sellers' batches.
- **A current balance.** These are opening figures at registration.
- **Borrower size or sector.** `DEBTORS.INCOME` is NULL, and there is no
  turnover, headcount or company registration number in the feed. "A company is
  on the loan" is the whole of what is known.
- **A true default or origination date.** Both are derived or absent.
- **Anything about the originating bank's own collection history** before Intrum
  took the book on. On the earlier two-seller Sea build (measured 2026-09-29)
  pre-Intrum coverage was 0.5% on Barclaycard and 2.4% on WiZink; it was not
  re-measured here.
- **A WiZink seller-level recovery rate**, until the three unreconciled batches
  are answered.

---

## Files

| File | What it is |
|---|---|
| `accounts.sql` | one row per loan |
| `payments.sql` | one row per loan per payment date |
| `reconciliation.sql` | the batch ledger: every batch in or out, with the reason |
| `project_sea_benchmark_accounts.csv` | 217,104 rows × 15 columns |
| `project_sea_benchmark_payments.csv` | 1,284,551 rows × 7 columns |
| `project_sea_batch_ledger.csv` | 167 rows × 26 columns |
| `project_sea_benchmark_README.md` | this file — the one that travels with the data |

Method: `work/benchmark-dataset/post-registration-benchmark/METHOD.md`. Worked precedent:
`work/project-elsa-benchmark/FINDINGS.md`.
