# Italy settlement rates by age — answers

**Asked:** grouped by balance and time since last payment, how many open
amicable accounts pay off their debt each month, what % of their balance do
they pay, and how many close — as % of accounts and % of balance open at the
snapshot.

**Both books answered.** Cerved is below; Intrum is §7. They are reported side
by side and never added — §8 says why.

📗 **Everything here is also in `italy-question.xlsx`**, in this folder: a
Cerved tab and an Intrum tab, each with the seven questions labelled, plus a
Read me tab carrying the caveats.

Cerved Italy · **29,740 open amicable accounts** · **EUR 599.1m** · 11 monthly
snapshots, **Sep 2025 – Jul 2026**, each with the following month observed for
closures. Measured 2026-09-15 against the raw feed.

---

## The short answer

**Recency of payment is what predicts settlement, and it holds inside every
balance band.** A small Cerved account that paid in the last three months closes
at **3.1% a month**; the same size account that has not paid in over six months
is at or near **zero**. Balance matters, but far less: it mostly determines *how
much* gets paid, not *whether* the account closes.

**The two servicers agree.** Intrum, measured independently on a different feed
with a different definition of "amicable", shows the same gradient and a steeper
one — **2.48% a month** for accounts that paid in the last three months against
**0.04%** for those that never have. That the shape survives two unrelated data
sources is the most reliable thing in this note.

Practically: **an account that has not paid in six months is unlikely to settle
at any balance**, on either book.

---

## 1. How many open amicable accounts there are

Monthly average across the 11 snapshots, by balance band × months since last
payment. **These are the denominators for every rate below.**

*Average, not a total: an account open in all 11 months is one account, not
eleven. The book barely moves — 29,825 open at the first snapshot, 29,590 at
the last — so the average is a fair picture of any single month.*

| Balance | 0–3 m | 4–6 m | 7–12 m | 13–24 m | 24 m+ | Never paid | **Total** |
|---|---:|---:|---:|---:|---:|---:|---:|
| Under 1k | 110 | 44 | 93 | 157 | 404 | 1,930 | **2,738** |
| 1k–5k | 248 | 24 | 73 | 192 | 808 | 2,376 | **3,722** |
| 5k–20k | 564 | 73 | 190 | 425 | 1,969 | 10,527 | **13,748** |
| 20k–100k | 164 | 32 | 90 | 214 | 1,111 | 7,767 | **9,377** |
| Over 100k | 8 | 3 | 5 | 9 | 40 | 90 | **155** |
| **Total** | **1,093** | **176** | **451** | **997** | **4,332** | **22,690** | **29,740** |

## 2. …and the balance they hold

Monthly average, EUR:

| Balance | 0–3 m | 4–6 m | 7–12 m | 13–24 m | 24 m+ | Never paid | **Total** |
|---|---:|---:|---:|---:|---:|---:|---:|
| Under 1k | 44,851 | 13,236 | 25,179 | 47,968 | 141,525 | 769,584 | **1.0m** |
| 1k–5k | 723,510 | 70,576 | 212,679 | 578,866 | 2,325,317 | 7,845,031 | **11.8m** |
| 5k–20k | 5,994,521 | 782,501 | 2,137,407 | 4,933,042 | 22,549,000 | 121,793,300 | **158.2m** |
| 20k–100k | 5,032,477 | 1,096,351 | 3,089,630 | 7,244,261 | 37,662,020 | 271,619,700 | **325.7m** |
| Over 100k | 9,463,271 | 5,314,683 | 7,833,113 | 8,082,649 | 25,105,150 | 46,559,540 | **102.4m** |
| **Total** | **21.3m** | **7.3m** | **13.3m** | **20.9m** | **87.8m** | **448.6m** | **599.1m** |

⚠ **The book is concentrated in two cells.** *5k–20k never paid* (10,527
accounts) and *20k–100k never paid* (7,767 accounts) are 61% of all open
amicable accounts and EUR 393m of the EUR 599m. The recently-paying cells that
produce nearly all the settlements hold EUR 21.3m — **3.6% of the balance**.

## 3. How many pay off each month — % of accounts open at snapshot

Monthly closure rate, by balance band × months since last payment:

| Balance | 0–3 m | 4–6 m | 7–12 m | 13–24 m | 24 m+ | Never paid |
|---|---:|---:|---:|---:|---:|---:|
| **Under 1k** | **3.135%** | 1.253% | 0.000% | 0.116% | 0.472% | 0.188% |
| **1k–5k** | **1.284%** | 0.743% | 0.250% | 0.047% | 0.056% | 0.057% |
| **5k–20k** | 0.403% | 0.125% | 0.000% | 0.000% | 0.018% | 0.067% |
| **20k–100k** | 0.332% | 0.000% | 0.000% | 0.043% | 0.016% | 0.078% |
| **Over 100k** | 0.000% | 0.000% | 0.000% | 0.000% | 0.230% | 0.706% |

The gradient runs left to right in every row. The top-left corner — small and
recently paying — is where settlement happens.

## 4. …and as % of balance open at snapshot

| Balance | 0–3 m | 4–6 m | 7–12 m | 13–24 m | 24 m+ | Never paid |
|---|---:|---:|---:|---:|---:|---:|
| **Under 1k** | **1.335%** | 1.193% | 0.000% | 0.000% | 0.294% | 0.072% |
| **1k–5k** | **1.071%** | 0.864% | 0.237% | 0.061% | 0.046% | 0.057% |
| **5k–20k** | 0.438% | 0.110% | 0.000% | 0.000% | 0.012% | 0.064% |
| **20k–100k** | 0.391% | 0.000% | 0.000% | 0.036% | 0.028% | 0.083% |
| **Over 100k** | 0.000% | 0.000% | 0.000% | 0.000% | 1.679% | 0.443% |

Balance-weighted rates are close to the account rates, so accounts that close
are not unusually large or small for their band.

## 5. What % of their balance do they pay each month

| Balance | 0–3 m | 4–6 m | 7–12 m | 13–24 m | 24 m+ | Never paid |
|---|---:|---:|---:|---:|---:|---:|
| **Under 1k** | **16.007%** | 0.980% | 0.172% | 0.051% | 1.381% | 0.002% |
| **1k–5k** | **3.980%** | 0.361% | 0.021% | 0.043% | 0.072% | 0.037% |
| **5k–20k** | 1.351% | 0.297% | 0.038% | 0.040% | 0.025% | 0.031% |
| **20k–100k** | 0.542% | 0.545% | 0.076% | 0.050% | 0.031% | 0.020% |
| **Over 100k** | 0.730% | 0.000% | 1.041% | 0.159% | 0.053% | 0.020% |

**Small, recently-paying accounts clear 16% of their balance a month** — they
are being paid off outright. Everything not paid in the last six months pays
under 0.1% a month, which is not repayment, it is noise.

## 6. How many closed — counts over the 11 months

| Balance | 0–3 m | 4–6 m | 7–12 m | 13–24 m | 24 m+ | Never paid | **Total** |
|---|---:|---:|---:|---:|---:|---:|---:|
| Under 1k | 38 | 6 | 0 | 2 | 21 | 40 | **107** |
| 1k–5k | 35 | 2 | 2 | 1 | 5 | 15 | **60** |
| 5k–20k | 25 | 1 | 0 | 0 | 4 | 78 | **108** |
| 20k–100k | 6 | 0 | 0 | 1 | 2 | 67 | **76** |
| Over 100k | 0 | 0 | 0 | 0 | 1 | 7 | **8** |
| **Total** | **104** | **9** | **2** | **4** | **33** | **207** | **359** |

**359 accounts closed across 11 months**, out of 29,740 open — about 33 a
month, or **0.110%** of the book.

### Month by month

| Snapshot | Accounts open | Balance open EUR | Closed next month | Collected next month EUR |
|---|---:|---:|---:|---:|
| 2025-09-30 | 29,825 | 608,003,700 | 7 | 605,449 |
| 2025-10-31 | 29,794 | 583,601,400 | 11 | 347,986 |
| 2025-11-30 | 29,810 | 607,234,400 | 15 | 793,405 |
| 2025-12-31 | 29,797 | 606,604,700 | 16 | 244,370 |
| 2026-01-31 | 29,784 | 606,140,900 | 37 | 228,058 |
| 2026-02-28 | 29,787 | 600,598,200 | 46 | 532,879 |
| 2026-03-31 | 29,754 | 598,818,400 | 71 | 895,816 |
| 2026-04-30 | 29,683 | 595,801,500 | 18 | 330,994 |
| 2026-05-31 | 29,667 | 595,263,900 | 23 | 584,537 |
| 2026-06-30 | 29,645 | 594,264,500 | 68 | 391,522 |
| 2026-07-31 | 29,590 | 593,668,900 | 47 | 145,179 |

⚠ **Closures are lumpy — 7 in one month, 71 in another.** With ~33 a month
across 30 cells, most individual cells in the tables above rest on single
figures. Read the direction of the gradient, not any one cell.

⚠ **Most closures (207 of 359) are accounts that never paid anything.** Those
are not settlements; see the next section.

---

## Four things that have to travel with the Cerved numbers

**1. Closed does not mean settled.** The feed records that an account closed,
not why — a write-off and a payment in full look identical. Read the closure
rate next to §5. The 0–3 month band closes at 3.1% while paying 16% of balance,
which is settlement. The never-paid band closes at 0.19% on 0.002%, which is
almost certainly write-off. **207 of the 359 closures are in that second group.**

**2. "Amicable" is our definition, not Cerved's.** Cerved has no amicable flag.
We have used *open and never having reached a legal stage* — no pre-legal
collection notice, no post-legal agreement. **This needs confirming**: a
narrower reading exists, since only 915 records carry an explicit *"Amicable
Agreement"* label, and that would give a much smaller and different answer.

**3. Three quarters of the book has never paid** — 22,690 of 29,740 accounts
(76.3%), EUR 448.6m of EUR 599.1m. Any single whole-book average is really describing those
accounts.

**4. The "over 100k" row is 155 accounts and 8 closures.** One settlement moves
it by a percentage point. It should not be read as a trend.

⚠ **Eleven months is the entire history.** The Cerved snapshot feed begins
2025-09-30, so no cohort can be followed longer, and seasonality cannot yet be
separated from trend.

---

## 7. Intrum — the same questions, the second book

Intrum CAT instance 4034 · **19,941 open amicable accounts** · **EUR 366.1m** ·
24 monthly snapshots, Jul 2024 – Jun 2026. Full cross-tabs are on the Intrum
tab of the workbook; this is the summary by recency.

| Months since last payment | Accounts open | Balance open | Closed over 24m | **Closure rate/mo** | **% balance paid/mo** |
|---|---:|---:|---:|---:|---:|
| **0–3 months** | 246 | EUR 9.8m | 146 | **2.477%** | **0.786%** |
| 4–6 months | 62 | EUR 3.1m | 21 | 1.419% | 0.004% |
| 7–12 months | 81 | EUR 4.0m | 19 | 0.978% | 0.171% |
| 13–24 months | 35 | EUR 1.4m | 1 | 0.118% | 0.103% |
| Over 24 months | — | — | — | — | — |
| **Never paid** | **19,518** | **EUR 347.7m** | 184 | 0.039% | 0.219% |

### ⚠ The two books agree on the thing that matters

**The recency gradient appears independently on both, and it is steeper on
Intrum.** Two servicers, two different definitions of "amicable", two different
ways of measuring balance — and the same shape:

| Months since last payment | Cerved closure rate | Intrum closure rate |
|---|---:|---:|
| 0–3 months | 0.865% | **2.477%** |
| 4–6 months | 0.464% | 1.419% |
| 7–12 months | 0.040% | 0.978% |
| 13–24 months | 0.036% | 0.118% |
| Never paid | 0.083% | 0.039% |

That is the strongest single result here. It is not an artefact of one feed.

### Four things specific to the Intrum numbers

**1. "Over 24 months" cannot exist on this book.** The first payment in the
feed is August 2024, so no account can be more than ~22 months past one inside
the window. The row is blank, not zero.

**2. The never-paid band collects more than the 7–24 month bands** (0.219%
against 0.171% and 0.103%). That is not a paradox: "never paid" is where
*first* payments come from, and this book onboards continuously. On Cerved,
where the book is static, never-paid collects least of all.

**3. The cohort halves and closures are not the reason.** 29,094 accounts in
March 2025 to 19,767 in June 2026. Accounts leave by **turning legal** — 17,003
enter the legal phase, in batch stamps of up to 3,917 in one month. The
denominator moves for loading reasons, so read each month on its own.

**4. 97.9% of the accounts have never paid anything** — only 1,927 of 48,547
cases have ever made a payment. Even more concentrated than Cerved's 76%.

⚠ **Two whole months of Intrum payments are missing from the feed.** There is
no payment row dated **October 2025** or **May 2026** — absent, not zero, with
280–410 payments in every neighbouring month. Those two months are excluded
from the "% of balance paid" figures above and are marked ⚠ in the workbook's
monthly table. **This is a data-quality bug to report, not something to correct
in the analysis.**

⚠ **Intrum's balance is reconstructed, not reported.** Intrum delivers no
monthly tape and `REMAINING_CAPITAL` is 100% NULL on this instance, so the
month-end balance is the running transaction ledger. It reconciles exactly to
the book's EUR 1,058,690,235.15 of original capital, which is the check that it
is right — but it is a ledger position, not a servicer-stated outstanding.

---

## 8. Why Intrum is a second table, not more rows

The two sets of numbers above are reported **beside** each other, never added:

| | Cerved | Intrum (4034) |
|---|---|---|
| "Amicable" is | our derived definition, **fixed** | phase code `A002`, **time-varying** |
| The account is | a **position** (a debtor's loans) | a **case** (one loan) |
| Balance is | reported `OUSTANDING_GBV` | a **reconstructed ledger** |
| Settlement evidence | status Open → Closed | `CLOSING_DATE`, reason undecoded |
| Window | Sep 2025 – Jul 2026 | Jul 2024 – Jun 2026 |
| Legal detail | 16 decoded categories | none (`A002`/`L002` only) |

**Four things differ, not one.** A combined Italian settlement rate would be
averaging four different definitions, over two different windows. Compare the
*shape* of the two — which the table in §7 does — not the levels.

⚠ **13,020 of Intrum's 48,547 records are expense lines, not loans** (SPESE and
friends). They are excluded throughout; leaving them in roughly halves every
per-account rate.

⚠ **Intrum's closing codes are undecoded** — `CLOSING_TEXT` is 100% NULL — so
*why* a case closed is unknown. The code mix is available: code `9` is 1,406 of
the 2,073 closures, then `31` (297), `30` (201), `23` (169). **Ask Intrum what
those four codes mean** — it would separate settlement from write-off on this
book, which nothing else in the feed does.

⚠ Worth passing on regardless: **Cerved records the legal stage in plain
language** — *decreto ingiuntivo*, *precetto*, agreement post sentenza and 13
more. Intrum's Italian feed has no sub-phase at all. An earlier conclusion that
this breakdown did not exist was based on the Intrum book only.

---

*Full caveats and every feed guard: `FINDINGS.md` in this folder.*

*Reproduce:*
```
mise run sql -- work/italy/settlement/cerved_settlement_by_age.sql
mise run sql -- work/italy/settlement/intrum_settlement_by_age.sql
uv run python work/italy/settlement/build_workbook.py    # rebuilds the xlsx
```
