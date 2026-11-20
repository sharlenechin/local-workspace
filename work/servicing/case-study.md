# "Are we collecting what we planned, and if not, why?"
### A Servicing Dashboard walkthrough, told as one investigation

**For:** CEO, CTO, Head of Servicing · **Length:** about 15 minutes · **Prepared:** 14 October 2026 (dashboard v66)
**Data:** the live dashboard, **September 2026**, the latest reporting month (267 portfolios). Every number below was read
from the live dashboard on 14 October. Euro figures convert every month at the 30 September 2026 month-end rate, as the
NPL dashboard does. Massey's September report has not arrived, so its two UK portfolios are missing from September; every
comparison is like-for-like (the same portfolios on both sides), so the % changes stay fair.

---

## The pitch in one breath

> September *looks* on plan: 101%. Take out one €2.1 million one-off and we are at **95%**. Three countries carry the
> shortfall, and each has a different reason. **Italy** is recovering, and its real problems are three deals we can't
> see inside. **Sweden**'s payers are still paying, but **a third less each** than in June. **Germany** is **losing
> payers** and not replacing them. One method on the dashboard finds each answer in three clicks.

## Before you start

Open the dashboard on the **Portfolio** page. Press **Clear Filters**. Set **Benchmark = Accounting** (finance's plan,
the only one that covers every portfolio) and **Comparison Window = L3M**. The cards show **September**; the figure under
each card compares it with the average month of June to August.

---

## Act 1: How are we doing?

### 1.1 Read the cards · *Portfolio page, Overview*

| Card | September | Under it (vs L3M) |
|---|---|---|
| Total Collections | €37.68M | +2.2% (June–August averaged €36.88M) |
| Collections as % of Forecast | **101.1%** | **+1.8 pts** (June–August was 99.3%) |
| Collections minus Forecast | **+€0.40M** | |

> **Say:** "We collected €37.7 million in September, €0.4 million ahead of plan, and a little better than the summer."

### 1.2 The year so far · *Collections vs Forecasts chart, View = Cumulative, hover September*

Since December: **€382.1M against a plan of €361.0M, 105.8%**. Switch to **Monthly**: ahead of plan in eight of the ten
months; February and August were the misses.

*Benchmark toggle, if asked:* Servicer reads 107.2%, Underwriting 101.9%. For the deals we bought ourselves, the
"servicer forecast" in Intrum's report is the plan we priced the deal on, so only Heimdall carries a forecast Intrum made
itself.

---

## Act 2: Is that the real picture?

### 2.1 Find the one-off · *Section 2 Performance, Group By = Portfolio; sort Collections minus Forecast, high to low*

The top row is **LOK-BE25004-U02 (Electrabel)**: **€2.14M collected against a plan of €11k**. Its balance is now zero
and the servicer took no commission on it, which is what a sale or settlement of the whole portfolio looks like, not
debtors paying.

| | With it | **Without it** |
|---|---|---|
| Collections as % of Forecast | 101.1% | **95.4%** |
| Collections minus Forecast | +€0.40M | **−€1.72M** |

> **Say:** "One portfolio carries September. Without it we are at 95%. That's the number to manage to."

### 2.2 Where the shortfall sits · *Group By = Country; sort Collections minus Forecast, low to high*

| Country | September, % of plan | Collections minus forecast | vs L3M |
|---|---|---|---|
| **Italy** | 86.6% | −€0.78M | +18.0 pts |
| **Sweden** | 79.1% | −€0.56M | **−25.8 pts** |
| **Germany** | 85.1% | −€0.50M | −4.9 pts |
| Poland | 93.7% | −€0.28M | −15.3 pts |

Three questions follow from this table, and the rest of the walkthrough answers them with one method.

---

## Act 3: One method, three questions

For each country:

1. **Where?** Set the header **Country**, then **Section 2, Group By = Deal** (or Portfolio). Which deal carries the gap?
2. **Real or timing?** Set the header **Deal**, chart **View = Cumulative**. Behind since purchase, or just a lumpy month?
3. **Why?** First the **Data Quality** page: can we trust the case data? Then the **Cases** page, where three cards answer
   three different questions:
   - **Collected Cases**: are *fewer people paying*?
   - **Avg Monthly Collection per Case** (and the Average Collection per Case tab): are people *paying less*?
   - **New** and **Fresh** against **Lost**, summed in **Net Change**: are we *replacing the payers we lose*?

---

## Act 4: Why is Italy down?

**Step 1 · Where?** *Country = Italy, Group By = Deal*

| Deal (seller · servicer) | September, % of plan | Collections minus forecast |
|---|---|---|
| Breeze 2 (Intesa Sanpaolo · Intrum) | 71.1% | −€0.51M |
| Rubicon (Delta · Cerved) | 76.7% | −€0.35M |
| Sophia (Banco BPM · Intrum) | 1.3% | −€0.25M |
| Polar (BPER · Intrum) | 43.6% | −€0.19M |
| … | | |
| Breeze I (Intesa Sanpaolo · Intrum) | 128.3% | +€0.29M |
| Bo Katan 2 (Intesa Sanpaolo · Intrum) | 596.4% | +€0.31M |

Italy is recovering: −€0.78M in September against an average of −€1.87M a month over June to August.

**Step 2 · Real or timing?** *Deal = each in turn, chart Cumulative*

- **Breeze 2: timing.** €11.89M collected since purchase against €8.89M of plan, **134%**. It paid €5.5M up front in May,
  so later months look weak against a plan that expected that money later.
- **Polar: real.** 64% of plan since December, below plan in **nine of ten** months.
- **Rubicon: real.** 83% of plan since December, below plan in seven of ten months.
- **Sophia: real.** €19k collected against €1.03M of plan since it was bought in May.

**Step 3 · Why?** *Data Quality page, Country = Italy*

Every Italian portfolio reads **Not reconciled**, and the dashboard can't say why from case data:
- **Intrum Italy's case data loses payments** (a warehouse bug: one payment kept per case, so everyone looks like a
  first-time payer), and its **September** case file has not arrived yet.
- **Rubicon is serviced by Cerved**, which sends no case-level data.

> **Say:** "Italy is improving overall, and its biggest September gap, Breeze 2, is timing. The real problems are Polar,
> Rubicon and Sophia, and for all three we can't see why. The ask is twofold: a recovery plan from the servicers, and
> case data we can read, which means our data team fixing Intrum Italy and Cerved sending case files."

---

## Act 5: Why is Sweden down?

**Step 1 · Where?** *Country = Sweden, Group By = Deal.* Almost all of it is **Heimdall Sweden**: 77.7% of plan,
−€0.52M, after averaging 102.8% over the summer.

**Step 2 · Real or timing?** Over six months Heimdall Sweden is still **ahead of plan (102.0%)**. September is the first
real miss, so this is an early warning, not yet a loss.

**Step 3 · Why?** *Data Quality: Heimdall Sweden reads Reconciled, so the case data is complete. Cases page, Deal =
Heimdall, Country = Sweden*

| Card | September | Average month, June–August | |
|---|---|---|---|
| Collected Cases | 31,652 | 34,793 | −9.0% |
| Avg Monthly Collection per Case | **€55.79** | €67.24 | **−17.0%: paying less** |
| New | 4,186 | 6,855 | −38.9% |

On the **Average Collection per Case** tab, the steady payers (Three Consecutive Months, 17,000 to 19,000 people every month
since May) paid **€72.90 each in June and €46.21 in September: 37% less**. The same people are paying, but much less
each.

> **Say:** "Sweden's payers haven't gone anywhere; they're paying a third less than in June. That points at payment plans
> being renegotiated down or arrangements breaking. It's one bad month on the money so far, but three on the amounts.
> That's the question for Intrum."

---

## Act 6: Why is Germany down?

**Step 1 · Where?** *Country = Germany, Group By = Deal*

| Deal | September, % of plan | Collections minus forecast |
|---|---|---|
| Heimdall Germany (Intrum · Intrum) | 81.6% | −€0.39M |
| Santander Consumer Bank 11/2025 (Intrum) | 57.0% | −€0.11M |
| Korund (Deutsche Bank · Intrum) | 75.5% | −€0.07M |

**Step 2 · Real or timing?** Heimdall Germany has been **below plan in all ten months** since we bought it (85.4% of plan
since December, −€3.30M). Santander has been below plan every month since June.

**Step 3 · Why?** Two different problems.

- **Heimdall Germany: losing payers.** The steady payers fell from **12,903 in February to 11,042 in September (−14%)**,
  and Net Change was negative in most months. Each steady payer pays as much as before (€96.78 in September, the
  highest of the year). Its case data is complete except April and August (Data Quality), so leave those two months out.
- **Santander Consumer Bank: no new payers, and payers paying less.** First-time payers fell from 172 in March to 39 in
  September, and each paying case paid €191 in September against €234 in March.

> **Say:** "Germany is two stories. Heimdall is a slowly shrinking base of payers: a contact and re-engagement question.
> Santander has stopped finding new payers, and the ones it has pay less."

*Heimdall France has the same shape as Heimdall Germany (steady payers −14% since February, not replaced for eight
months running); `insight-heimdall.md` walks through both.*

---

## Act 7: Who else is behind, month after month?

One month can mislead, so look at six in one view. Set the header **Reporting Month = April to September 2026**, scroll to
**Section 3, Full breakdown** (one row per portfolio, summed over the months selected), and sort **Collections minus
Forecast**, low to high:

| Portfolio (deal) | April–September, % of plan | Shortfall |
|---|---|---|
| HEI-DE25001-U01 (Heimdall Germany) | 86.5% | −€1.69M |
| LEG-ES25003-U01 (Boreal · Zolva · Gescobro) | 88.0% | −€1.16M |
| LOK-IT24014-U01 (Breeze I) | 78.8% | −€1.10M |
| LOK-IT25026-U01 (Sophia) | 1.8% | −€1.01M |
| LEG-IT25002-U01 (Rubicon) | 89.3% | −€0.97M |
| HEI-FR25001-U02 (Heimdall France) | 84.6% | −€0.96M |
| HEI-PT25001-U02 (Heimdall Portugal) | 91.8% | −€0.92M |
| LOK-IT24013-U01 (Polar) | 60.8% | −€0.83M |
| LEG-ES25002-U01 (Ares · ING · Gescobro) | 81.8% | −€0.52M |

> **Say:** "This is the standing list. Germany, France and Sweden we can diagnose. Italy, Boreal, Ares and Rubicon we
> can't, because the case data is missing or broken."

---

## Act 8: What the dashboard taught us about our data · *Data Quality page*

| Card (September) | Value |
|---|---|
| Share Reconciled | 39.2% of collections |
| Not Reconciled | €22.91M |
| No Case Feed | 112 of 267 portfolios |
| Feeds Stopped | 22 |

1. **Intrum Italy's case data loses payments** (a warehouse bug): Intrum's raw file has 2,850 Italian payments from
   December to August, the warehouse 1,041. Italy is marked Not reconciled until the data team fixes it. Its collections
   and plan figures are unaffected.
2. **Gescobro and Cerved send no case-level data**, so Boreal, Ares and Rubicon can be measured but not diagnosed.
3. **Late files:** Massey's September report and Intrum Italy's September case file have not arrived yet.

For the full picture by servicer and combined ref, the Data Quality page links to the **Servicer Data Quality
dashboard**; its reconciled figures match this page, portfolio-month by portfolio-month.

---

## The close

| Question | Answer | Ask |
|---|---|---|
| Why is Italy down? | Recovering; Breeze 2 is timing. Polar, Rubicon and Sophia are really behind, and we can't see why | Recovery plans from Intrum and Cerved; our data team fixes Intrum Italy's case data |
| Why is Sweden down? | The same payers paying a third less than in June | Intrum: are payment plans being renegotiated down in Sweden? |
| Why is Germany down? | Heimdall losing payers (10 months below plan); Santander not finding new ones | Intrum: re-engagement plan for Heimdall; new-payer pipeline for Santander |
| Is September really on plan? | No: 95% without the Electrabel one-off | Confirm the Electrabel payment was a sale or settlement |

**Three things to take away**

1. **Manage to the number without one-offs:** 95% in September, not 101%.
2. **Each country is behind for a different reason**, and the Cases page tells them apart: fewer payers, payers paying
   less, or payers not replaced.
3. **Where we can't see why, the fix is data:** Intrum Italy's case data, and case files from Cerved and Gescobro.

## What is solid and what is shaky

- **Solid:**
  - every collections and forecast figure: the dashboard's tests check it against the warehouse (back-tests included),
    and it matches the NPL dashboard portfolio-month by portfolio-month;
  - every figure in this document, read from the live dashboard on 14 October;
  - Sweden's and Germany's case findings (their case feeds reconcile with the servicer's report).
- **Shaky:**
  - **Sweden** is one month on the money (three on the amounts per payer); watch October.
  - **Italy's "why"** can't be read until its case data is fixed.
  - **The Electrabel one-off** is our reading of the report (zero balance, no commission), not confirmed.
  - **Massey's September** is missing until its report arrives; totals will rise by about €0.6M.
