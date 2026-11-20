# Heimdall's quiet problem: Germany and France
### One finding, proved on the Servicing Dashboard, click by click

**For:** CEO, CTO, Head of Servicing · **Length:** about 10 minutes · **Prepared:** 14 October 2026
**Data:** the live dashboard (v66), September 2026, the latest reporting month. Every number below is what the screen
shows at that click, read on 14 October.

---

## The finding in one breath

> Heimdall, our largest deal, is close to plan: 97.9% in September, ahead over the year. Underneath, two of its
> countries have missed plan almost every month since we bought them. **Germany is €3.30M behind plan since December,
> France €1.43M.** The money shows *that* they are behind. The case data shows *why*, and it is the same reason in both:
> **they are losing steady payers and not replacing them.** The people who still pay, pay as much as before.
> In France the servicer also keeps a third of what it collects.

## Why this is a solid case, not a cherry-pick

1. **The comparison is fair.** Every Heimdall country was bought the same day (December 2025), from the same seller,
   serviced by Intrum, planned at the same time. When Germany and France diverge from Poland and Finland, the cause is
   local. It is not "Intrum" and it is not "the plan".
2. **It is a pattern, not a month.** Germany has been below plan in **all ten months**, France in **nine of ten**.
3. **The data behind the "why" is complete.** Both case feeds reconcile with the servicer's report (Germany except
   April and August, which we leave out).
4. **Two independent sources agree.** The servicer's monthly report (Portfolio page) and the case-level feed (Cases
   page) tell the same story.

---

## The walkthrough

### Step 1 · Our biggest deal looks fine · *Portfolio page*

Press **Clear Filters**. Set **Benchmark = Accounting**, **Comparison Window = L3M**, header **Deal = Intrum - 12/2025
(Heimdall)**. Total Collections **€20.91M** in September, **97.9%** of plan (−€0.45M). Switch the chart to
**Cumulative**: Heimdall is ahead of plan over the year, carried by Poland (+€12.9M) and Finland (+€2.3M).

> **Say:** "Heimdall is more than half our monthly collections and it's roughly on plan. If we stopped here, we'd move on."

### Step 2 · Split it by country · *Section 2 Performance: Group By = Country (Deal still Heimdall)*

Germany is at **81.6%** of plan in September and France **89.2%**. One month proves nothing, so go to the chart.

### Step 3 · Behind every month: Germany · *header Country = Germany; chart View = Cumulative, hover September 2026*

| | Since December |
|---|---|
| Collections | €19.35M |
| Accounting plan | €22.65M · **85.4%**, −€3.30M |
| Underwriting plan (what we paid for) | **78.9%** |

Switch to **View = Monthly**: collections sit under the accounting line in **all ten months**. Finance lowered
Germany's plan in May (from €2.46M to €2.04M a month), and Germany is still below the lowered plan.

> **Say:** "Germany has missed every month since we bought it. Finance already lowered the bar once, and it's still
> under it. Against what we priced at purchase, it's collecting 79 cents in the euro."

### Step 4 · Behind every month: France · *header Country = France*

Since December: €10.55M against a plan of €11.99M, **88.0%**, −€1.43M. Below plan in nine of ten months; July was the
only month ahead.

> **Say:** "France is the same shape, smaller. Together the two are €4.7 million behind plan since December."

### Step 5 · Can we trust the case data? · *Data Quality page, Country = France, then Germany*

France's Heimdall portfolios read **Reconciled**: the case feed matches the servicer's report within half a percent
each month. Germany's is reconciled in every month except **April and August**, when its case feed held only 86–87% of
the reported euro. Those two months make its case counts read low and its Lost read high, so we leave them out.

> **Say:** "Before we say *why*, we check the data. France's is complete; Germany's we read without its two short months."

### Step 6 · France: losing payers, not replacing them · *Cases page, Deal = Heimdall, Country = France*

- **Net Change** (New + Fresh − Lost) has been **negative every month from February to September, eight in a row**
  (−192 in September).
- **Count tab:** the steady payers (Three Consecutive Months, dark purple) fell from **4,609 in February to 3,960 in
  September: −14%**.
- **Average Collection per Case tab:** each steady payer paid **€116.79** in September; it has stayed between €109 and
  €122 all year. **The people who pay are paying normally. There are just fewer of them every month.**
- **Overall Summary:** only **1.1% of France's 886,307 cases have ever paid.** First-time payers fell from 1,094 in
  January to 199 in September.

> **Say:** "France's problem isn't the payers we have; it's that we're not finding new ones. Ninety-nine cases in a
> hundred have never paid."

### Step 7 · Germany: the same problem · *Cases page, Country = Germany*

- **Count tab:** steady payers fell from **12,903 in February to 11,042 in September: −14%**, the same rate as France.
- **Net Change** was negative in four of the six months since February whose case feed is complete (−346 in
  September), leaving out April and August as above.
- **Average Collection per Case tab:** each steady payer paid **€96.78** in September, the highest of the year (€95.79
  in March). *An earlier version of this walkthrough said Germany's payers were paying less; September's data no longer
  supports that.*

> **Say:** "Germany is France's story again: a slowly shrinking base of payers, each paying normally. That's about
> contact and re-engagement, not payment plans."

### Step 8 · What does it cost us to collect there? · *Portfolio page, Section 2, Group By = Country, Deal = Heimdall*

Read **Servicer Cost, % of Collections**: in September Intrum kept **34.0%** of France's collections and **24.3%** of
Germany's. Since December it has kept **34.6%** in France, against **26.4%** across all Intrum portfolios.

> **Say:** "In France we're paying the most to collect the least against plan."

---

## The close

| | Germany | France |
|---|---|---|
| Behind accounting plan, since December | **€3.30M** (85.4%) | **€1.43M** (88.0%) |
| Months below plan | 10 of 10 | 9 of 10 |
| What the case data says | Steady payers −14% since February; each still pays normally | Steady payers −14%; not replacing them, 8 months running |
| Can we trust it? | Yes, except April and August | Yes, every month |
| Question for Intrum | How do you re-engage payers who stop? Why were April and August's case files short? | How will you reach the 99% of cases that have never paid, and why does France cost 35% to collect? |

**Three takeaways**

1. **A healthy deal can hide two weak countries.** Heimdall near plan contains €4.7M of shortfall since December.
2. **Both have the same cause.** Fewer payers, not lower payments: the fix is contact and re-engagement.
3. **Check the data before the diagnosis.** Germany's April and August Lost spikes would have told the wrong story.

## What is solid and what is shaky

- **Solid:** the plan figures and months below plan (servicer reports, checked by the dashboard's 381 tests and
  back-tests); France's case behaviour (reconciled every month); the fairness of the comparison (one deal, one day,
  one servicer).
- **Shaky:**
  - **Ten months is short.** Some of the fall in first-time payers is natural: the easiest payers come first.
  - **Germany's September plan rose** (€2.11M after €1.94M in August), which makes September's 81.6% look worse than
    August's 87.9%; read the cumulative figure, not the month.
  - **The cost share** includes everything the servicer keeps (commission, fees, costs); a French fee schedule that is
    higher by contract would explain part of it.

*This walkthrough is a companion to `case-study.md`. The case study tours the whole book; this follows one finding.*
