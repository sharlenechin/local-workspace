# The platinum layer — retired 2026-10-02, and what it taught

**Nothing here is built, and nothing should be rebuilt from it.** The models are
in `work/.archive/2026-10-02-platinum/`. This file is the part worth keeping:
four design findings that cost real work to learn and that apply to the next
model whatever it is called.

## Why it went

Platinum was a general-purpose layer between the golden marts and whatever
consumed them — nine dbt models plus a generated runnable copy of each, plus
four standalone queries in `work/platinum/`. Three things killed it:

- **Nothing consumed it.** The servicing dashboard went straight to the facts,
  then to one purpose-built mart. The benchmark work reads RAW. No consumer ever
  arrived for the layer in between.
- **Every model existed twice**, in dbt dialect and in a generated Snowflake
  copy, kept in step by `mise run platinum-sql`. Two copies of nine models is
  eighteen things to keep true.
- **The one model that was genuinely needed got built properly instead** — as
  `mart_npl_servicing_agg_cases_monthly`, raised to `brocc-data` on branch
  `add/servicing-mart`.

## The four findings worth keeping

### 1. A row should mean that something happened

The obvious shape for a loan's history is one row per loan with a column per
date. That breaks the moment you want the *balance* at each of those moments —
you need a column per date per measure. Give each event its own row instead,
carrying the state as at that date.

**The table is then DENSE: a row exists only where the event actually
happened.** A loan with no origination date has no origination row, not a row
full of NULLs. Two consequences:

- **Rows per loan varies.** Never assume a fixed multiple.
- **Browsing does not show you what is missing.** The catalogue of events that
  *could* exist has to live somewhere explicit — a `phase_list`, or the YAML.

⚠ Where this lives now: the two capex dates and the fact that **nothing joins a
case to a capex date** are documented in
[`NPL-UNDERWRITING-DESIGN.md`](NPL-UNDERWRITING-DESIGN.md) — which is live, and
the place to act on it.

### 2. There is no `LATEST` event, and that is deliberate

A `LATEST` row duplicates a real event under a second name, so any sum over the
table double-counts it. Carry an `is_latest_flag` on the real row instead.

### 3. Currency belongs in the grain, not in a conversion

One row carrying both its local figure and its euro figure is only honest if
that row has exactly **one** currency. Put `currency_id` in the grain and make
summing to portfolio-month the consumer's job. **Never sum a `_local_currency`
column across rows of different currency** — the warehouse carries six (SEK,
EUR, PLN, DKK, CHF, GBP).

### 4. The three forecasts are not variants of one number

Never average them or swap one for another:

| | |
|---|---|
| **Underwriting** | what we assumed when we **bought**. Frozen, one vintage. The benchmark for "was the purchase a good one?" |
| **Accounting** | our **current** view, revised as we learn. **The one Finance tracks** in flash and revaluations |
| **Servicer** | the servicer's own projection. Answers "is the servicer hitting the plan?" and nothing else |

⚠ **Accounting is born as a copy of underwriting** — 91.3% of portfolio-months
are still identical. Where they differ, *we* have marked the book.

## Five measurements that were only written down in the artifact

The shared write-up that argued for this layer was deleted on 2026-10-02 at
Sharlene's instruction. These were measured against PROD on 28–29 Sep 2026 and
exist nowhere else in this detail. They are warehouse facts, not platinum
facts — every one of them still applies.

### ⚠⚠ Joining a snapshot on `case_sk` loses 99.9% of the balances

`case_sk` is a **version** key: today's version never matches a past month's
row. On one Spanish book of 3,234,302 loans, the same predicate keyed two ways:

```sql
ON sn.case_sk = cp.case_sk   -- 1,070 rows find a balance
ON sn.case_bk = cp.case_bk   -- 1,026,764 rows find a balance
```

A **960× difference**. Re-keying moved balance coverage at acquisition from
**73.41% to 98.25%**, and at registration from **2.61% to 20.98%**. ⚠ It
presented as *missing data*, not as an error, because recent events still
matched — only the older ones looked empty.

### ⚠⚠ A platform migration mints a brand-new loan identity

`CASE_BK` is `<platform>-<their id>`. When a book moves between Intrum's own
platforms, **the same debt is issued a new key and a new registration date, and
nothing links the old to the new.** Portfolio money survives; loan-level
continuity does not.

**32 portfolios have migrated, holding 12,646,213 of the 19.6m loans that carry
a registration date.** In a vintage breakdown one Spanish loan appears twice —
once as a Scale case, once as a Fenix case. Both rows are real; neither knows
about the other. ⚠ Two servicer rows on one book is usually **not** a servicer
change — check the platform before reading it as one.

⚠ If a servicer transfer is ever planned, **ask for a case bridge before it
happens.** The asset index's own bridge reaches 7.55% because nobody built one
in time.

### ⚠ Nothing in the warehouse records that a servicer changed

No mandate date, no transfer date, no handover row — not in a dimension, not in
a fact. The servicing timeline is not a column you could select if only you knew
where to look. Deriving it from which months each party appears in the files
surfaced **231 servicing spells across 196 books**, and **34 books running more
than one platform** (up to three at once).

### ⚠ A derived window's start date is when our feed begins

Not when anything happened. One Spanish book shows servicing and ownership both
starting 2021-10-31 — which is simply its first month in our data. Intrum had
serviced it since at least 2017. **The median book has 11 months of history.**
Only a date a source actually recorded means what it says.

### ⚠ 2,321 loans sit under two portfolios

The case snapshot carries one row per book, so joining it raw doubles them and
gives each copy half the balance.

⚠ And **purchase price sits at portfolio and batch grain only** — nothing
allocates capex down to a loan. Recovery per loan can be measured against
**balance at acquisition**, never against price paid, until someone decides an
allocation deliberately.

## What else is in the archive

`work/.archive/2026-10-02-platinum/` also holds two dated extracts with **no
stored query**: `2026-08-forecast-variance-by-deal.csv` and
`...-by-project.csv`, exported 2026-09-21 — August 2026 actual against all three
forecasts. They cannot be refreshed as written. If a figure from either is
needed, re-derive it from the live forecast facts rather than quoting a
September export.
