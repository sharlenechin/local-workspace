# Servicing dashboard — what it surfaces

Five findings from the dashboard's own queries, run against PROD on
**2026-10-06**. Every figure below is live, converted to euro per currency
before summing. Read "what this is" and "what to do"; the working is underneath.

**Scope.** 264 portfolios, December 2025 to August 2026. Case-level findings
cover the 164 portfolios (62%) whose cases appear in the loan feed — see
*Finding 5* before quoting any case count as a total.

---

## 1. One servicer costs half as much again as the others

Cost as a share of what they collect, last 12 months:

| Servicer | Collected | Their cost | Cost as % |
|---|---|---|---|
| **Gescobro** | 35,140,860 | 13,683,774 | **38.9%** |
| Intrum | 290,741,901 | 75,966,257 | 26.1% |
| Intrum – QQuant | 3,920,434 | 973,959 | 24.8% |
| Cerved | 17,594,876 | 3,752,935 | 21.3% |

**Gescobro is 12.8 points above Intrum on three portfolios.** On the 35.1m they
collect, closing that gap is worth roughly **4.5m a year**.

Their cost is almost entirely commission — 12.5m of the 13.7m, with no
management fee — so this is a rate question, not a fee-structure question.

**Do:** ask why the commission rate differs, and whether those three books are
harder than the rate implies.

---

## 2. Cerved misses its own forecast, and is slowing

Cerved delivered **80.6%** of the forecast *it set itself* over six months —
**2.83m short**. Over the same period Intrum came in **4.7% above** its own.

Momentum, last 3 months against the 3 before:

| Servicer | Last 3M | Prior 3M | Change |
|---|---|---|---|
| **Cerved** | 5,483,242 | 6,218,958 | **−11.8%** |
| Intrum | 94,007,603 | 97,632,220 | −3.7% |
| Gescobro | 12,129,073 | 12,461,944 | −2.7% |
| Intrum – QQuant | 1,262,878 | 1,176,851 | +7.3% |

Missing a forecast is one thing; a servicer's own forecast being 24 points
better than its delivery is a planning problem as much as a collection one.

**Do:** challenge Cerved's forecast method before next quarter's plan is built on it.

---

## 3. We lose about 13% of our monthly collection every six months

Cases that were paying consecutively and then stopped, last six months, valued
at what they were paying in their final month:

| Book | Country | Cases lost | Monthly EUR stopped | Per case |
|---|---|---|---|---|
| HEI-FI25001-U01/2512 | Finland | 47,800 | 3,289,082 | 69 |
| HEI-PL25001-U02/2512 | Poland | 29,917 | 2,926,135 | 98 |
| HEI-DK25001-U01/2512 | Denmark | 17,845 | 2,565,033 | 144 |
| HEI-SE25001-U01/2512 | Sweden | 29,857 | 2,042,687 | 68 |
| HEI-DE25001-U01/2512 | Germany | 8,834 | 1,452,683 | 164 |
| **HEI-PL25001-S01/2512** | Poland | **121** | **1,124,844** | **9,296** |

**Total: 20.9m of monthly collection stopped, against 160.0m collected — 13%.**

The last row is the one to act on first. **121 cases carry 1.1m** — 9,296 each
per month, against 69 a case in Finland. A hundred-odd accounts worth that much
should not be churning unnoticed; they are a call list, not a statistic.

**Do:** put the top-value stopped cases on a named recovery list each month.
The dashboard can produce it.

---

## 4. Penetration ranges from 0.2% to 69%

Share of each book that has ever paid, latest month, books over 5,000 cases:

| Book | Country | Cases on book | Ever paid | % |
|---|---|---|---|---|
| ORG-UK26003-U01/2606 | UK | 38,383 | 26,314 | **68.6%** |
| ORG-UK26002-U01/2606 | UK | 10,401 | 6,938 | 66.7% |
| LOK-DE24016-U01/2512 | Germany | 8,104 | 2,251 | 27.8% |
| … | | | | |
| HEI-FR25001-U02/2512 | France | 885,602 | 9,784 | 1.1% |
| HEI-CH25001-U01/2512 | Switzerland | 1,810,403 | 18,647 | 1.0% |
| HEI-BE25001-U01/2512 | Belgium | 204,087 | 406 | 0.2% |
| **HEI-ES25001-U01/2512** | **Spain** | **6,709,206** | **12,425** | **0.19%** |

A 350-fold spread. The UK books are a different kind of asset from the Spanish
one, so the gap is not failure on its face — but **6.7 million Spanish cases
with 12,425 ever paying** is either the wrong collection strategy or the wrong
expectation, and nobody can currently say which.

**Do:** agree an expected penetration per book type, so the dashboard can show
variance against it rather than a raw rate.

---

## 5. The dashboard catches a data problem that looks like a triumph

August 2026, whole book:

| Month | Cases collecting | First-ever payers | EUR collected |
|---|---|---|---|
| Jun 2026 | 212,186 | 62,959 | 25,519,538 |
| Jul 2026 | 227,144 | 29,844 | 25,681,626 |
| **Aug 2026** | **305,396** | **103,565** | **23,908,760** |

Cases collecting jumped **34%** and first-ever payers **tripled** — while the
money **fell**. If a hundred thousand people genuinely started paying, cash
would rise. It did not, so this is a **feed artefact**: a backlog loaded into
one month, not a collection event.

Read off a case-count chart alone, August is the best month on record. That is
exactly the mistake this view prevents.

**The wider trust problem.** Only **25%** of portfolio-months reconcile between
the servicer's report and the loan feed; the median gap is **46.7%**. Coverage
is fine (median 88.9% of months present) — the *amounts* disagree, because the
loan-level feed carries roughly half of what the servicer reports.

**Do:** treat this as a data-quality escalation with the warehouse team, and
until it is closed, quote money from the servicer's report and behaviour from
the loan feed. Never mix them on one card.

---

## What is solid, and what is shaky

**Solid.** Every money figure above comes from the servicer's own portfolio
report, converted per currency at that month's rate. Cost ratios, forecast
delivery and momentum are reliable.

**Shaky, and why.**

- **Case counts are a floor, never a total.** The loan feed covers 164 of 264
  portfolios; **79.5m of collections (22.9%) have no case detail behind them.**
  A book with no feed shows as zero, not as unknown.
- **September 2026 is excluded** from every chart here. The FX table has no
  September rates yet, so converted totals for that month are understated.
- **Churn values are what a case last paid**, not a guaranteed forward loss —
  some of those cases will resume.
