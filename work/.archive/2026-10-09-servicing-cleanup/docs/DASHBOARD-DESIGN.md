# Servicing dashboard — what it should show

Written as the Head of Servicing would use it, against the six elements we
already have. Figures are the last six months to 2026-08, measured 2026-10-07.

**The principle: one question per tile, and every tile answers "who do I call
on Monday".** The current workbook has seven elements of which three are the
same rolling average at different lengths. That is not three answers.

---

## Band 0 — One control above everything: complete months

**Default: complete months only. One toggle to include the incomplete one.**

The three sides of this dashboard do not end on the same month:

| Month | Portfolios on the money side | Portfolios on the case side | FX rates |
|---|---|---|---|
| 2026-07-31 | 251 | 141 | 11 |
| 2026-08-31 | **264** | 145 | 11 |
| 2026-09-30 | **none** | **155** | **10** |

**September 2026 has case data, no portfolio money, and a short FX table.** Left
in by default it does three things, all wrong:

- collections appear to collapse — there is no portfolio row, not no money;
- euro totals understate, because the EUR rate itself is missing that month;
- 155 portfolio-months show as unreconciled when the truth is *not comparable*.

That last one is the 10.5% of collecting cases in the payer table above.

### Missing is not zero — and stale is not missing

Three different things look identical on a chart today, and each needs a
different person to fix it:

| What happened | How to tell | Who fixes it |
|---|---|---|
| **The feed is stale** | our table rebuilt recently, but the source data is old | chase the **servicer** |
| **The pipeline did not run** | our table has not rebuilt | chase the **data team** |
| **Genuinely nothing collected** | fresh on both counts, month present, value 0 | chase the **collection strategy** |

Measured 2026-10-07:

| Source | Reaches | Source data as of | Our table rebuilt |
|---|---|---|---|
| Case collection | 2026-09-30 | 2026-10-05 | 2026-10-07 18:01 |
| Case snapshot | 2026-09-30 | 2026-10-05 | 2026-10-07 18:01 |
| FX | 2026-09-30 | — | 2026-10-07 08:01 |
| **Portfolio report** | **2026-08-31** | **2026-09-18** | 2026-10-07 17:54 |

**Our pipeline ran today. The servicer's September report has not arrived** —
their data was captured on 18 September and still stops at August. So the
missing September money is a **servicer chase**, not a data-team ticket, and
nobody looking at the dashboard today can tell that.

### The freshness tile

Small, top right, three values per source — not one "last updated" date, which
is the thing that misleads:

| Show | From |
|---|---|
| Reaches | `Max([Reporting Month])` on each element |
| Source data as of | `Max(AS_OF_TS)` on the underlying fact |
| Our table rebuilt | `INFORMATION_SCHEMA.TABLES.LAST_ALTERED` |

Amber when *reaches* is more than one month behind the current month while
*rebuilt* is recent — that is the stale-feed case, and it is the live state
today for the portfolio side.

⚠ **A month genuinely absent from the source must render as absent, never as
zero.** A zero says "they collected nothing"; absent says "we do not know". The
only time a zero is correct is when the feed is fresh, the month is present, and
the value really is nil — vanishingly rare, but the chart must be able to say it.

### Define it, never type it

A month is complete when **all three sides cover it**. The money side is always
the laggard, so:

    [Is Complete Month] = [Reporting Month] <= Max([Portfolio Metrics].[Reporting Month])

Today that resolves to **2026-08-31**. ⚠ Do not hard-code that date — it moves
every month, and a typed date silently becomes a lie. This is the same rule
`FLAGS.md` §4 sets for the part-loaded newest month: bind to the data, never to
a literal.

### The toggle, and the banner

| State | Shows | Use |
|---|---|---|
| **Complete months only** *(default)* | through 2026-08-31 | every number anyone quotes |
| Include the latest partial month | adds 2026-09-30 | case-side early warning only, never money |

Put a banner under the title, bound to the same column, never typed:

> **Data as at 31 August 2026.** September is loaded on the case side only and
> is excluded. Money for September is not missing — it has not arrived.

⚠ The mart already excludes the **current** month, so today is never half-counted.
This toggle is about the month after the money side stops, which is a different
and less obvious hole.

---

## Band 1 — Four numbers, nothing else

| Tile | Calculation | Element |
|---|---|---|
| Collections | `Sum([Collections Sum])` | Portfolio Metrics |
| Against forecast | `Sum([Collections Sum]) / Sum([Servicer Forecast Sum])` | + Forecasts |
| Cost of collection | `Sum([Servicer Cost Total Sum]) / Sum([Collections Sum])` | Portfolio Metrics |
| Net payers | `Sum([Collected Cases New Count]) - Sum([Collected Cases Lost Count])` | Case Metrics |

**Cut the three rolling-average cards.** L3M, L6M and L12M as separate KPIs are
one idea shown three times, and all three currently divide by a constant, which
understates any book younger than the window. Replace with a single trend line
under the four numbers, with a 3/6/12 toggle.

**Net payers is the card that is missing today** and it is the one that moves
first. Collections lag; the payer base turning negative is visible a quarter
earlier.

---

## Band 2 — The country league table

One table. Sortable. This is the whole "who is performing" answer:

| Country | Collections | Cost % | Payers | EUR/payer | Steady % | Net payers | Penetration |
|---|---|---|---|---|---|---|---|
| Spain | 40,970,076 | 34.1 | 37,711 | 1,086 | 37.2 | +12,615 | 0.3% |
| Italy | 31,413,105 | 27.5 | 782 | 40,170 | 0.0 | +782 | 2.1% |
| Poland | 29,647,968 | 33.2 | 342,244 | 87 | 67.5 | +24,487 | 6.3% |
| Greece | 23,488,679 | 22.7 | 89,935 | 261 | 68.8 | **−3,532** | 4.5% |
| Sweden | 18,709,425 | **14.3** | 247,214 | 76 | 43.3 | +39,177 | 5.2% |
| Germany | 17,987,172 | 21.6 | 126,905 | 142 | **74.7** | **−3,540** | 4.7% |
| Finland | 17,396,391 | 21.5 | 377,219 | 46 | 19.4 | **+153,876** | 7.8% |
| Switzerland | 14,760,573 | **44.0** | 41,862 | 353 | 53.3 | +5,427 | 1.1% |
| Denmark | 10,940,001 | 19.8 | 94,166 | 116 | 61.3 | **−14,470** | 14.2% |
| France | 6,044,554 | 34.1 | 41,175 | 147 | 72.6 | −1,164 | 1.1% |
| UK | 5,592,458 | **7.8** | 160,755 | 35 | 48.2 | +21,759 | **68.7%** |

**Three columns carry the whole story and none is on the dashboard today:**

- **Cost %** — Switzerland collects at **44%** cost, the UK at **7.8%**. A
  5.6-fold spread nobody is being asked about.
- **Net payers** — Denmark is **−14,470**, Greece and Germany negative too.
  Four countries are shrinking their payer base while reporting collections.
- **Steady %** — the share paying three months running. Germany **74.7%** is a
  book that pays itself; Finland **19.4%** is 377,000 payers churning in and out.

**Colour on exactly two things**: cost % above 30, and net payers below zero.
Nothing else. A table where everything is coloured says nothing.

---

## Band 3 — Against which plan? The answer changes who looks bad

We hold **three** forecasts, and the dashboard shows one. That is the single
biggest reporting weakness, because they disagree violently:

| Country | Collections | vs servicer | vs accounting | vs underwriting |
|---|---|---|---|---|
| **Spain** | 40,970,076 | **279.1%** | 100.2% | 100.6% |
| Germany | 17,987,172 | 87.0% | 87.4% | **80.9%** |
| Switzerland | 14,760,573 | 149.9% | 141.2% | **198.1%** |
| Italy | 31,413,105 | 83.7% | 98.1% | 83.6% |
| Denmark | 10,940,001 | 140.2% | 122.7% | 134.4% |
| France | 6,044,554 | 80.5% | 85.5% | 85.5% |

**Spain delivers 279% of the servicer's plan and 100% of ours.** The servicer's
forecast is not a target, it is a number they chose. Judging them against it
makes a merely on-plan book look like the best in the portfolio.

So the forecast tile needs **a three-way toggle, not a number**:

| Plan | Column | Answers |
|---|---|---|
| Servicer | `Servicer Forecast Sum` | is the servicer beating what they promised |
| Accounting | `Accounting Forecast Sum` | are we on the books |
| Underwriting | `Underwriting Forecast Sum` | **are we on what we told investors** |

Default it to **underwriting**. That is the number with consequences.

Coverage is not an obstacle: accounting and underwriting exist for **100%** of
portfolio-months, servicer for 97%.

**The shortfall list this produces is the Monday call list:**

| Country | Servicer | Delivered vs underwriting | Short by |
|---|---|---|---|
| Germany | Intrum | 80.9% | **4,236,828** |
| Italy | Intrum | 85.5% | 3,348,806 |
| Italy | Cerved | 80.5% | 2,826,106 |
| France | Intrum | 85.5% | 1,027,078 |
| Portugal | Intrum | 91.6% | 966,701 |

---

## Band 4 — The payer tab, which is empty today

This is the part the current dashboard cannot show, and the new mart exists for
it. One grouped table, rows = country then servicer, these columns:

| Column | From | Reads as |
|---|---|---|
| Cases on book | `Cases On Book Count` (**Max**, not Sum) | the denominator |
| Ever collected | `Cases Ever Collected Count` (Max) | penetration |
| Collecting this month | `Collected Cases Count` | the active base |
| Steady | `Collected Cases Three Consecutive Months Count` | the reliable core |
| New | `Collected Cases New Count` | won |
| Lost | `Collected Cases Lost Count` | gone |
| Value stopped | `Collected Amount Local Lost Last Month Sum` × FX | **what the losses were worth** |

**"Value stopped" is the tile that changes behaviour.** A lost-case count treats
every case alike. Converted to euro it does not:

| Book | Cases lost | Monthly EUR stopped | Per case |
|---|---|---|---|
| Finland | 47,800 | 3,289,082 | 69 |
| Poland HEI-PL25001-U02 | 29,917 | 2,926,135 | 98 |
| Denmark | 17,845 | 2,565,033 | 144 |
| **Poland HEI-PL25001-S01** | **121** | **1,124,844** | **9,296** |

121 cases worth more than 17,845 Danish ones. That is a call list, and no
count-based tile would ever surface it.

**Total: 20.9m of monthly collection stopped in six months, against 160.0m
collected — 13%.** That number belongs on Band 1 if there is room.

---

## Band 5 — The lagged behaviours, read as one row

Six transitions, and they are only useful side by side. One stacked bar per
month, or one row per country:

| Flag | Column | x-2 / x-1 / x | Reads as |
|---|---|---|---|
| First collection | `Collected Cases First Collection Count` | – / – / yes | never paid before |
| Steady | `…Three Consecutive Months Count` | yes / yes / yes | the reliable core |
| Jitter in | `Collected Cases Jitter In Count` | yes / no / yes | came back after one month |
| New | `Collected Cases New Count` | no / no / yes | back after a longer gap |
| Jitter out | `Collected Cases Jitter Out Count` | no / yes / no | one month then quiet |
| Lost | `Collected Cases Lost Count` | yes / yes / no | was steady, has stopped |

**Two traps to build around:**

- **They do not add up to the collecting total.** A case in its *second*
  consecutive month matches none of them — 377,028 case-months. Never chart
  these three (steady + jitter in + new) as a complete breakdown.
- **First collection overlaps New entirely.** Never sum both.

⚠ **Jitter out and Lost sit on a month with no collection**, so their amount
columns carry what those cases collected in their **last** month. That is the
right number — monthly collection that has just stopped — but it is a different
month's money and must never be added to the others.

---

## The flag rail — and where reconciliation belongs

⚠⚠ **Reconciliation is a case-data flag, not a money flag.** It asks whether the
case feed agrees with the servicer's portfolio report. The portfolio report is
the servicer's own and is the source of truth for money — it is true whether or
not the case feed happens to match it.

Measured: filtering portfolio collections by `Is Reconciled Flag` leaves
**EUR 146,691,613 of EUR 347,398,072 — it deletes 57.8% of the money for no
reason.** That is precisely the error the live dashboard makes today.

So the rule is:

| Tile | Reconciliation |
|---|---|
| Collections, cost, balance, forecast — anything from **Portfolio Metrics** | **never applied.** The portfolio side is the truth |
| Payers, transitions, penetration — anything from **Case Metrics** | **always shown**, because it says whether these counts can be trusted |

### The payer tab needs three states, not two

| State | Portfolio-months | Collecting cases | Share |
|---|---|---|---|
| Reconciled | 464 | 1,122,374 | **52.3%** |
| Not reconciled | 677 | 796,782 | 37.2% |
| **No portfolio row to compare** | 155 | 225,224 | **10.5%** |

The third state is not "false" — it is **unknown**, and it is mostly September
2026, where the case feed runs a month ahead of the portfolio fact. Showing it
as unreconciled would be wrong; showing it as reconciled would be worse.

Put reconciliation on the payer tab as a **traffic light per row** — green,
amber, grey — not as a filter. The Head of Servicing needs to see that Denmark
lost 14,470 payers *and* whether that book's feed can be believed. Filtering
removes exactly the row she needs to interrogate.

### The rest of the rail

The other flags are genuine toggles, **defaulting to off**, each adding a column
rather than silently removing rows:

| Toggle | Flag | Shows |
|---|---|---|
| Has case detail | `Have Loan Detail Flag` | excludes the 100 books with no feed |
| Feed stopped | `Feed Stopped Flag` | 39 portfolio-months where the case feed went quiet |
| Has FX rate | `Has Fx Flow Flag` / `Has Fx Stock Flag` | guards any euro total |
| Multi-currency | `Is Multi Currency Flag` | the books where a local total is meaningless |
| Has servicer plan | `Have Servicer Forecast Flag` | the 3% with none |
| Has accounting plan | `Have Accounting Forecast Flag` | |
| Has underwriting plan | `Have Underwriting Forecast Flag` | |

⚠⚠ **None of these may carry a default value.** Today the page ships
`Is Reconciled Flag = false`, so it opens showing only the books that do **not**
reconcile — hiding **EUR 110.6m, 49.2% of collections**, while the headline KPI
reports the remainder as if it were the book. A flag is a lens you choose, never
a filter you inherit.

Put a one-line banner under the title stating what is currently filtered, so a
narrowed view can never be mistaken for the whole book.

---

## The charts she actually needs

Four. Each answers one question, and each is one click from the row behind it.

| Chart | Type | What it answers |
|---|---|---|
| **Collections vs plan, by month** | line, 2 series | are we on track — with the plan selector (servicer / accounting / **underwriting**) |
| **Country league, cost vs delivery** | scatter: x = cost %, y = % of underwriting plan, bubble = collections | **one picture of who is expensive and who is short.** Switzerland sits top-left at 44% cost; UK bottom-right at 7.8% |
| **Payer flow, by month** | stacked bar: new, jitter in, steady above zero; lost, jitter out below | is the payer base growing or eroding, and by how much |
| **Value at risk, top 10 books** | horizontal bar, `lost_last_month_eur` | the money that just stopped, biggest first — this is the call list |

The scatter is the one that earns its place. A table makes you read 14 rows and
hold two numbers in your head; the scatter puts the expensive-and-failing
quadrant in the top left where the eye lands first.

⚠ **No pie charts, no gauges, no map.** The map today is mislabelled anyway —
its measure is `Sum([Collections Sum])` under a title that says balance.

---

## Download: two grains, because she asks two kinds of question

A download button on each of the two tables, exporting **what is on screen** —
same filters, same columns, no surprises.

**1. Portfolio overview — one row per portfolio per month**

Everything in `Servicing`: drill path, money in EUR, forecasts, cost, the trust
flags. This is the file for "show me Germany month by month".

**2. Payer overview — one row per portfolio per month, case columns only**

Book size, ever-collected, the six transitions, and the EUR behind each. This is
the file for "which books are losing payers and what were they worth".

⚠ **Both export EUR only.** No local-currency column leaves the element, so a
downloaded file cannot be summed into a wrong total.

⚠ **Both carry the trust columns** — `have_case_detail_flag`,
`is_reconciled_flag`, `has_fx_flow_flag`, `case_month_coverage_pct`. A CSV that
leaves the dashboard loses the banner, so the caveats have to travel in the
columns or they do not travel at all.

For a deeper cut than either, the grain below portfolio is the case itself, and
that is not on this dashboard — it is a query. `work/servicing/` holds the SQL.

---

## What to remove

| Remove | Why |
|---|---|
| Average Collections L6M, L12M | same idea as L3M; replace all three with one toggled trend |
| Country by Remaining Balance | its measure is `Sum([Collections Sum])` — it has never plotted balance. Fix the formula or drop the tile |
| "Total Paying Cases Newly Activated" from the pivot | it is a growth **ratio** formatted as a count |

## Two rules for whoever builds it

**Default filters show everything.** Today the page opens with "Has been
Reconciled = false", hiding **EUR 110.6m, 49.2% of collections**. Show the flag
as a column, never as a default filter.

**Case counts are a floor.** The case feed covers 164 of 264 portfolios;
**22.9% of collections have no case detail behind them**, and Portugal has none
at all. A book with no feed must read blank, never zero — otherwise it ranks
worst on every payer tile while collecting perfectly well.
