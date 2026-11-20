# Servicing dashboard — flags, caveats and what to tell your stakeholder

> ## ⚠ The Diagnostics page it refers to was deleted on 2026-09-17
>
> The business does not trust the amicable / legal split that page existed to
> carry: those codes come from `GROUP_CASE_PHASE` and Intrum has never sent a
> dictionary for them. **§5 below, and every mention of the phase split, the
> secured mix and the debt-age mix, is therefore stale** — kept because it
> records what was measured and why it was dropped. The evidence and the open
> ask now live in [`../data-issues/intrum/`](../data-issues/intrum/).
>
> **Everything else here still stands**, and §11 is still what to say to a
> stakeholder. Figures were measured against PROD on 2026-09-14 and move as new
> months load; the structure does not.

Everything measured against **PROD** on **2026-09-14**, read-only. Figures move
as new months load; the structure does not.

Read this before the build guide, and read §11 before the stakeholder meeting.

| § | Flag | Severity |
|---|---|---|
| 1 | [This is production data](#1-this-is-production-data) | process |
| 2 | [The hierarchy nests; drag-and-drop is safe](#2-the-hierarchy-nests--and-drag-and-drop-regrouping-is-safe) | **corrected** |
| 3 | [The underwriting plan starts June 2025](#3-the-underwriting-plan-starts-june-2025) | **blocking** |
| 4 | [Completeness is enforced in the SQL](#4-completeness-is-enforced-in-the-sql-not-on-the-dashboard) | **changed** |
| 5 | [The amicable / legal split now exists — labels unconfirmed](#5-the-amicable--legal-split-now-exists--labels-unconfirmed) | **changed** |
| 6 | [Loan-level detail covers 54% of portfolios](#6-loan-level-detail-covers-54-of-portfolios) | **blocking** |
| 7 | [Never average a ratio](#7-never-average-a-ratio) | **correctness** |
| 8 | [Cumulative-at-latest-month drops portfolios](#8-cumulative-at-latest-month-drops-portfolios) | correctness |
| 9 | ["Liquidations" is not a warehouse word](#9-liquidations-is-not-a-warehouse-word) | definition |
| 10 | [Closed cases are in the data — and explain the balance gap](#10-closed-cases-are-in-the-data--and-they-are-most-of-the-balance-gap) | **corrected** |
| 10b | [One period vocabulary, used everywhere](#10b-one-period-vocabulary-used-everywhere) | **correctness** |
| 10c | [16% of the servicer's cut is not itemised](#10c-16-of-the-servicers-cut-is-not-itemised) | **open question** |
| 11 | [What to tell your stakeholder](#11-what-to-tell-your-stakeholder) | — |
| 12 | [The ask list](#12-the-ask-list) | — |

---

## 1. This is production data

Every dataset reads `PROD.NPL_COMMON` and `PROD.COMMON` through the Sigma
*Snowflake - PROD* connection. Three consequences worth saying out loud:

- **Read-only, and it must stay that way.** The `NPL_ANALYST` role holds
  `SELECT` and `USAGE` only. Nothing on this dashboard writes, and no
  dashboard problem is ever fixed by asking for write access.
- **Numbers move under you.** A figure quoted in a meeting is as at the month
  loaded that day. Always show the month-end on the page.
- **Anyone with the workbook sees real portfolios, real counterparties and
  real money.** Check who the Sigma workbook is shared with before you send
  the link.

There is no loan-level personal data on any page in this design — no name,
no date of birth, no account number. Keep it that way.

---

## 2. The hierarchy nests — and drag-and-drop regrouping is safe

⚠ **This section was corrected on 2026-09-14.** It previously said 19
portfolios change vehicle and 14 deals span two vehicles. That measured
`legal_buyer_sk` — a **surrogate key on an SCD**, which changes every time the
dimension versions, not when the business entity changes. Measured again on
the **names the dashboard actually displays**, over full history:

| Test | Result |
|---|---|
| Portfolios in more than one deal | **0** of 252 ✅ |
| Portfolios in more than one vehicle | **0** of 252 ✅ |
| Deals spanning more than one vehicle | **2** of 61 ⚠️ |
| Deals spanning more than one country | **2** of 61 ⚠️ |

So `Vehicle → Deal → Portfolio` nests cleanly apart from two deals.

### Drag-and-drop: yes, and here is why it works

Every level — vehicle, deal, servicer, country, portfolio — is a **column on
the same row** of `Portfolio Information`, not a separate join. So any subset,
in any order, aggregates the same rows. Verified 2026-09-14:

| Grouping | Total | Groups |
|---|---|---|
| Vehicle only | EUR 3,912,489,378.67164 | 19 |
| Vehicle → Deal | EUR 3,912,489,378.67164 | 66 |
| **Deal → Vehicle** | **EUR 3,912,489,378.67164** | 66 |
| Country only | EUR 3,912,489,378.67164 | 16 |
| All five levels | EUR 3,912,489,378.67164 | 252 |

**Identical to the cent in every order.** Distinct counts foot too — 252
portfolios whether counted grand-total, by vehicle, or by deal.

### The three things that still do not foot

1. **Ratios never foot.** Performance at a parent is not the sum or average of
   its children. Define every percentage in Sigma as `sum(actual) / sum(plan)`
   so it recomputes at whatever level is displayed — never as a stored column.
   See §7.
2. **The two multi-vehicle deals appear twice** when vehicle sits above deal —
   once under each. The grand total is still right and the split is *correct*,
   but readers see a deal listed twice and call it double-counting. Caption it.
3. **Filtering out `Unknown` breaks footing.** It is a real value carrying real
   money. Leave it selectable.

⚠ One structural note that is not a data problem: **servicer is derived from
deal source and country** (`LEGACY + ES → Gescobro`, `LEGACY + IT → Cerved`,
else Intrum). Putting servicer *above* country in a drag order is legal and
the totals foot, but it is a child above its parent and will read oddly.

## 3. The underwriting plan starts June 2025

**This is the one that changes what you can promise.**

| | |
|---|---|
| Underwriting plan covers | **2025-06-30 → 2041-06-30**, 251 portfolios, **one** vintage |
| Actual collections go back to | 2018-01-31 (the FX floor) |

So **"total actual vs total underwriting since inception" cannot be built as
asked.** Before June 2025 there is no plan — not a zero, an absence. Put
actuals from 2018 next to a plan from 2025 and the chart shows a catastrophic
shortfall that is pure artefact.

**What to build instead:** the since-inception chart runs **from 2025-06-30**,
and the actual line uses `cumulative_collections_in_servicer_window_eur` — collections
restricted to the months where a plan exists. *(Renamed 2026-09-15: the plan
is now the servicer forecast; the underwriting plan left the dataset.)* The dataset carries both, so
the honest comparison is one column away.

Measured at 2026-08-31 on that basis:

| | EUR |
|---|---|
| Cumulative actual, plan window | 564,965,087.52 |
| Cumulative underwriting plan | 541,592,525.67 |
| **Performance** | **104.32%** |

**That is good news and it is the headline** — the book is ahead of what we
underwrote. Say so, and say it covers 14 months, not the life of the book.

Also note the plan is **one vintage, never revised**. The accounting forecast
has 8 vintages and *is* revised. "Behind plan but on forecast" means
expectations were reset, not that the servicer recovered.

---

## 4. Completeness is enforced in the SQL, not on the dashboard

**Changed 2026-09-14.** These used to be two flag columns the dashboard had to
filter on. They are now **filtered inside the three datasets**, because a guard
that can be forgotten is not a guard.

**Complete months only.** The newest month is routinely part-loaded — measured
2026-09-09, 2026-08-31 held 7 portfolios against July's 250, which reads as a
93% collapse and is purely a load lag. August has since filled in and is now
the latest complete month, which is why the test is live (portfolio count at
least half the prior month's) and never a hard-coded date.

**EUR-convertible only.** FX covers 2018-01-31 to 2026-08-31. Outside it the
rate is NULL, so every `*_EUR` column would be NULL — **not zero** — and an
unfiltered sum silently shrinks.

Verified after the change: the grand total is unchanged at
EUR 3,912,489,378.67164 and **zero rows come back with a null money column**.

### The page must still say what is excluded

The exclusion is now invisible in the result, so three columns come back on
every row to drive a banner — bind to them, do not type dates:

| Column | Value today |
|---|---|
| `snapshot_date` | 2026-08-31 |
| `fx_from` | 2018-01-31 |
| `fx_to` | 2026-08-31 |

> **Data as at 31 August 2026.** Months shown: January 2018 – August 2026.
> Part-loaded months and periods without an FX rate are excluded.

⚠ **A silent filter becomes folklore nobody can audit.** Enforcing the guard
is right; hiding it is not. The banner is the other half of the change.

⚠ Two flags that are **still yours to filter** and have not moved:
`has_servicer_forecast` (§3, was `has_underwriting_plan`) on the overview, and
`is_open` on diagnostics. Those describe real gaps in coverage, not load
artefacts. *(`has_case_collection_detail` was removed 2026-09-15 with the
stored ratios; a portfolio absent from diagnostics is absent from the feed.)*

---

## 5. The amicable / legal split now exists — labels unconfirmed

⚠ **This section was rewritten on 2026-09-14.** It previously said the split
was impossible. It is not — it just is not where anyone looked.

### It is built and it returns numbers

✅ **Sigma can read RAW — confirmed 2026-09-15**, so this works as a Sigma
element today.

`work/data-issues/intrum/queries/dash_phase_collections.sql` stamps each payment
with the workout phase **in force on its own payment date**, from RAW
`GROUP_CASE_PHASE` (346m rows, not modelled in PROD, not even a declared dbt
source). Run over the three months to 2026-08-31:

| Phase | Collections | Payments | Avg payment |
|---|---|---|---|
| E (execution — confirmed 2026-09-15; was labelled unknown) | EUR 20,318,751.16 | 525,757 | EUR 38.65 |
| **A (amicable?)** | EUR 18,647,791.62 | 191,256 | **EUR 97.50** |
| **L (legal?)** | EUR 11,788,394.98 | 65,502 | **EUR 179.97** |
| unassigned | EUR 10,747,671.06 | 291,635 | EUR 36.85 |

**The payment sizes corroborate the labels** — legal recovering fewer, larger
lumps and amicable more, smaller instalments is what those two processes look
like. That is evidence, not proof.

### Three things that must travel with it

1. **The labels keep their question marks.** `A = Amicable, L = Legal` is a
   reading of the code prefix, not a documented mapping. The query returns
   `'A (amicable?)'` deliberately; strip the mark only when Intrum confirms.
2. **`E` is a third of the phased money and nobody knows what it is** —
   525,757 payments at EUR 38.65 across 15 portfolios, the highest-frequency
   track of all. **This is the first question for Intrum**, ahead of A/L.
3. **Coverage is ~53%**, inherited from the loan feed (§6).
   `percent_of_reported_phased` measures it per row. Absent ≠ zero.

⚠ **Instance 4050 (Portugal) carries only `A000`** — one phase, no split at
all. That is the feed, not a bug.

### Why the status codes were the wrong route

`STATUS_CODE` is populated on 22,434,117 of 22,528,961 current loans (99.6%)
with 76 values, but `STATUS_DESCRIPTION` and `CLOSING_CATEGORY` are 100% NULL
and Intrum (~89% of the book) sends bare numbers (`64`, `6`, `0`, `55`…).

⚠ **Part of that dictionary is already in-house**, though:
`int_npl_forbearance_intrum.sql` in `brocc-data` decodes seven codes **in its
comments** — `23` Settlement payment plan, `24` Settlement, `29` Payment plan,
`313` Settlement offer, `315` Restructuring of debt, `35` Debt reconstruction
plan, `56` Payment plan. **Ask the data engineer before emailing Intrum.**

### The fallback proxy, still useful

`FORBEARANCE_FLAG` (25.1% true) remains on the Diagnostics page as the
`in_arrangement` group-by flag (the stored `percent_loans_in_arrangement` was
removed 2026-09-15; the rate is a Sigma formula) — label it *"loans in a payment arrangement"*, never
"amicable". ⚠ 8 portfolios (1,794,945 loans) read **exactly 100%** and 54 read
exactly 0%; treat both extremes as feed defaults and show blank.

---

## 6. Case-level detail covers 62% of portfolios

Collection behaviour is built from the case level, and the case feed is partial.
**Re-measured 2026-10-06** against the whole book, not a 12-month window:

| | |
|---|---|
| Portfolios with case-level collections | **164 of 264 (62%)** |
| Portfolios with **none** | **100 (38%)** |
| Of those, still collecting at portfolio level | **73** |
| Collections with no case detail behind them | **EUR 79,465,857.81 — 22.9% of EUR 347,398,071.67** |

The case feed covers Intrum's ORANGE/BLUE books only. **So a portfolio with no
feed shows a 0% collecting rate and ranks as the worst performer — while
collecting perfectly well.**

→ **A portfolio with no case feed is simply absent from Case Metrics.** The
portfolio side left joins it, so an absent row means *no case detail*, never
*no collections*. Put the count of absent portfolios in the caption, and never
read absence as zero.

---

## 7. Never average a ratio

Performance is `sum(actual) / sum(plan)`, computed **after** Sigma has
filtered — never the average of a per-portfolio ratio. Averaging weights a
EUR 2k book the same as a EUR 40m one and can move the headline by tens of
points.

This is why the datasets pre-compute **sums only** (`*_L3M_*`, `CUM_*`)
and no ratios. Sums stay correct under any filter; ratios do not. Every
percentage on the dashboard is a Sigma-side calculation over filtered sums.

---

## 8. Cumulative-at-latest-month drops portfolios

`CUM_*` columns accumulate within each portfolio's own series. If you read
the cumulative **at the latest month only**, every portfolio with no row in
that month contributes nothing.

Measured: reading cumulative-at-August gives EUR 564,965,087.52, while summing
the monthly values over the same window gives EUR 565,929,537.83 — a gap of
**EUR 964,450.31** from portfolios absent in August.

→ **For a total card, sum the monthly column over the period.** Use the `CUM_*`
columns for the cumulative *line chart*, where they are plotted per month and
are correct.

---

## 9. "Liquidations" is not a warehouse word

Nothing in the warehouse or in this workspace is called a liquidation. I have
built the rolling-3m section as **collections — gross cash recovered**
(`GROSS_CASH_RECOVERIES`), which is what the rolling actual / underwriting /
performance framing implies.

**Confirm this with your stakeholder before the meeting.** If they mean
something narrower — cash from enforcing or selling collateral specifically —
that is a different number and the warehouse cannot currently isolate it:
secured loans are 0.02% of the book (4,031 loans).

Two related definitions to settle in the same conversation:

- **Gross or net? — THIS IS THE LIVE DISAGREEMENT, resolve it first.**
  ⚠ **Corrected 2026-09-14.** An earlier version of this note said net was
  "Intrum-only, costs absent for other servicers". **That was wrong.** Net is
  populated on every servicer with zero nulls:

  | Servicer | Net nulls | Net ÷ Gross |
  |---|---|---|
  | Intrum | 0 | 0.777 |
  | Gescobro | 0 | 0.795 |
  | Cerved | 0 | 0.884 |

  **This is what makes the Sigma "Performance Summary" disagree with these
  datasets.** Measured on the matched plan window:

  | | Actual | Plan | Performance |
  |---|---|---|---|
  | These datasets (**gross**) | EUR 565.93m | EUR 542.46m | 104.3% |
  | These datasets (**net**) | EUR 427.34m | EUR 420.51m | 101.6% |
  | Sigma Performance Summary | EUR 418.47m | EUR 392.24m | 106.7% |

  Net brings the actual leg within **2.1%**. It is not a scope difference —
  the same 15 countries appear on both sides and the ratio is a uniform
  0.69-0.78 in **every one of them**, which only a measure or window change
  produces. A residual of ~7% remains on the plan leg, so there is a second,
  smaller difference there still to find.

  **Neither is wrong; they answer different questions.** Gross is what the
  debtor paid — the servicer's collection performance. Net is what reaches us
  after commission, VAT and passthrough costs — the investor return. A
  servicer scorecard is normally gross; a board view is normally net. **Pick
  one per page, label it, and never mix them on a card.**

  ⚠ **Net has one real gap:** 397 portfolio-months collected EUR 46.2m with
  **no cost recorded at all** (net = gross on a non-zero month). Net is
  overstated on those. The other 89,037 net-equals-gross rows are
  zero-collection months and are benign.
- **"Performance" against which line?** Against the **underwriting plan** ("did
  we buy well") or the **accounting forecast** ("are we on the current view")?
  They answer different questions. The design shows both; the stakeholder
  should pick which one is the headline.

⚠ You mentioned a layout — *"the total something like this"* — but no image
came through. The chart shapes in the build guide are my reading of your
description; check them against what you actually had in mind.

---

## 10. Closed cases are in the data — and they are most of the balance gap

**Two findings, and the second explains the first.** Both measured 2026-08-31.

### The loan snapshot includes closed cases

| State | Cases | Balance |
|---|---|---|
| Open | 12,816,379 (58.6%) | EUR 80.70bn |
| **Closed on or before the month-end** | **9,066,819 (41.4%)** | **EUR 20.13bn** |
| Closing date in the future | 246 | EUR 0.46m |

`FCT_CASE_SNAPSHOT_DAILY` carries no closed indicator of its own — the closing
date lives only in `DIM_CASE`, which is why this is easy to miss.

→ Both loan-level datasets now return **both**: `LOANS_ON_BOOK` /
`BALANCE_EUR` count everything, `LOANS_OPEN` / `BALANCE_OPEN_EUR` and
`N_ACCOUNTS_OPEN` count only open cases. **Use the OPEN ones for anything
described as "under management".**

### And that is most of the loan-vs-portfolio gap

| Basis | vs portfolio level |
|---|---|
| Loan level, **all** cases | **134.2%** |
| Loan level, **open only** | **107.4%** |

An earlier version of this section reported the gap as a flat 39% and left it
unexplained. It is mostly closed cases. The residual ~7% is still unexplained
and small enough to live with; by servicer the all-cases figure was Intrum
139.1%, Gescobro 103.2%, Cerved 100.0%.

### The rule this gives you

| Use | For | Never for |
|---|---|---|
| `Portfolio Metrics` (portfolio level) | every money total in euro | — |
| `Case Metrics` (case level) | rates, mix and behaviour | any euro money total |

Never add them, never put them on the same card. `Case Metrics` carries amounts
in **local currency only**, so it cannot be summed across a multi-currency book;
euro money comes from `Portfolio Metrics`, which converts per currency first.

⚠ A collecting rate whose denominator includes closed cases understates
engagement. Build it as `Max([Cases Ever Collected Count]) / Max([Cases On Book
Count])`, both as at the same month.

---

## 10b. One period vocabulary, used everywhere

Fixed **2026-09-15** after the two datasets were found using the same words for
different windows.

```
L0M = the snapshot month itself        (EXCLUDED from every L-window)
L1M = the month before it
L3M = L1M + L2M + L3M                  the three completed months
L6M = L1M … L6M          L12M = L1M … L12M
```

⚠ **No element stores these windows any more.** The pre-computed
`collections_l1m/l3m/l6m/l12m_eur` columns went with the datasets retired on
2026-10-02. Every window is now a **running or windowed sum in Sigma** over
`reporting_month`, which is why the vocabulary above still has to be agreed:
two tiles labelled "3 months" can still cover different periods if one includes
the snapshot month and the other does not.

| Still true | Where |
|---|---|
| case new / lost / jitter | L1M…L3M — the window this convention was aligned *to* |
| every money window | built in Sigma from `Portfolio Metrics` monthly rows |

⚠ **What the bug was.** Diagnostics used `> dateadd(month,-3, month_end)`,
which **includes** the snapshot month, while the overview's L3M excluded it.
Two tiles labelled "3 months" on one dashboard covered different periods, and
nothing would have flagged it.

⚠⚠ **Divide by months present, not by the window length.** This is a live
defect, not a hypothetical: the dashboard today computes
`Sum([Collections L 3 M Sum]) / 3`, and **299 of 1,130 portfolio-months (26.5%)
have fewer than three months of history** — understated by up to **3x** where
only one month exists, so a young book looks like it collects a third of what
it does. Count the months in the window and divide by that. See
[`LIVE-WORKBOOK.md`](LIVE-WORKBOOK.md) §2.

---

## 10c. 16% of the servicer's cut is not itemised

Measured 2026-08-31, across the book:

| | EUR |
|---|---|
| Gross collections | 33,334,835.80 |
| Net collections | 25,518,663.33 |
| **Servicer cost (gross − net)** | **7,816,172.47** |
| **Cost to collect** | **23.45% of gross** |

Broken down by the columns the feed itemises:

| Component | EUR |
|---|---|
| Commission | 4,135,207.86 |
| Portfolio management fee | 177,307.22 |
| Passthrough cost | 2,287,740.62 |
| *Itemised total* | *6,600,255.70* |
| **⚠ Unitemised residual** | **1,215,916.77 — 15.6%** |

⚠⚠ **What that 15.6% is has not been established.** It is not rounding. It is
either a fee type the feed does not break out, or something in the gross-to-net
derivation that is not a servicer fee at all.

→ `SERVICER_COST_UNITEMISED_EUR` returns it, so a stacked breakdown foots to
the total instead of silently under-reporting the cut by a sixth. **Do not
present the three components as a complete breakdown without it.**

→ **A question for the data team**, alongside the borrower-key defect. Added to
`work/dbt/DBT-HANDOFF.md`.

⚠ The three source columns are stored **negative** (they are deductions). The
dataset negates them so every cost column has the same sign as the total —
otherwise a card summing the components returns a negative cost.

---

## 11. What to tell your stakeholder

Five sentences, in this order:

1. **"We are at 104.32% of underwriting plan"** — EUR 564.97m collected
   against EUR 541.59m planned. Ahead of what we underwrote.
2. **"That comparison covers 14 months, not the life of the book."** The
   underwriting plan only exists from June 2025. There is no way to compare
   against plan before that, for any portfolio.
3. **"We can now split collections into amicable and legal — with a caveat."**
   Built 2026-09-14 from the servicer's raw feed: over the last three months,
   EUR 18.6m amicable at EUR 98 a payment against EUR 11.8m legal at EUR 180 a
   payment. ⚠ The labels are our reading of the servicer's phase codes and are
   not yet confirmed by Intrum, and a third track worth EUR 20.3m is
   unidentified. It covers ~53% of collections, being loan-level.
4. **"Engagement metrics only cover about half the portfolios"** — 135 of 250.
   The rest report at portfolio level only. We show which is which rather than
   ranking a portfolio bottom for having no feed.
5. **"Everything is production data as at 2026-08-31"**, and it moves monthly.

### What to promise, and what not to

| Asked for | Status |
|---|---|
| Multi-page dashboard with drill-down | ✅ buildable now |
| L3M actual / underwriting / performance | ✅ buildable now |
| Total since inception, actual vs underwriting | ⚠️ **from June 2025 only** |
| Vehicle → deal → … drill path | ⚠️ **vehicle is as-at-month, not fixed** |
| % amicable payment | 🟡 **built 2026-09-14** — labels unconfirmed, ~53% coverage |
| Why a portfolio underperforms | ⚠️ **partial** — engagement and mix, not workout type |

---

## 12. The ask list

Two for Intrum, one for our own data team. All three are small and each
unlocks a page.

**For Intrum**

0. ⭐ **What is phase track `E`?** 525,757 payments, EUR 20.3m in three months,
   15 portfolios — a third of all phased collections and the highest-frequency
   track we have. And please confirm `A` = amicable and `L` = legal. **This is
   now the highest-value question on the list**; it finishes a metric that is
   otherwise already built.
1. **The status code dictionary.** ⚠ Ask our own data engineer first — seven
   codes are already decoded in a `brocc-data` model comment. 76 codes on 22.4m loans with no
   descriptions. Ask for the lookup — code, label, and which of amicable /
   legal / insolvency each belongs to. **This single file turns the Accounts
   page from a proxy into the real answer.**
2. **The forbearance flag on 8 portfolios reads 100%.** 1,794,945 loans, every
   one flagged as in an arrangement. Ask whether that is a real state or a
   feed default.

**For our data team**

3. **Loan-level collections cover 54% of portfolios.** 96 portfolios collect
   EUR 137.25m a year with no loan-level detail. Ask whether the non-Intrum
   feeds can be landed at loan level, or confirm that portfolio level is all
   there will ever be for them — so the dashboard can say so permanently.

Pattern and tone for these: `work/data-issues/intrum/escalations-portugal-millennium.md`,
which is the Project Elsa version of exactly this list.
