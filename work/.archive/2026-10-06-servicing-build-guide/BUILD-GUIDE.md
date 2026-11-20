# Building the servicing dashboard in Sigma — step by step

> ## ⚠ READ THIS FIRST — the build moved on twice since this was written
>
> **2026-09-17 — the Diagnostics page is gone.** `dash_portfolio_diagnostics`
> was deleted: the business does not trust the amicable / legal split it
> existed to carry, because those codes come from `GROUP_CASE_PHASE` and Intrum
> has never sent a dictionary for them. That also took an unmodelled 346m-row
> RAW table off the critical path of a published dashboard. **Every mention of
> Diagnostics, the phase split, the secured and debt-age mix below is stale.**
> The evidence and the open ask with Intrum are in
> [`../data-issues/intrum/`](../data-issues/intrum/).
>
> **2026-09-30 — two datasets became six elements.** The single 900-line
> `dash_portfolio_overview` custom-SQL element was split into the six files
> beside this one, and the expensive loan-feed half was pushed into a dbt
> model. The *steps* below (Edit mode, pasting SQL, controls, grouping, the
> page layouts) are all still correct; the *dataset names and column names* in
> them are not. [`README.md`](README.md) is the current map — start there, then
> use this for the mechanics.
>
> The loan-level **payer counts** this page used to get from Diagnostics now
> come from the `Case Metrics` element: `paying_loans_count`,
> `paying_loans_activated_count`, `paying_loans_consistent_3m_count`,
> `payment_loans_new_count`, `payment_loans_jitter_count`,
> `payment_loans_lost_count`, `payment_loans_not_paying_count`, and the
> `feed_stopped_flag` guard on `Reconciliation`.

Multi-page, drill-down, built on **two datasets**. Everything below is done by
hand in the Sigma editor; the MCP connector is read-only and cannot create
elements.

**Never used Sigma?** Start at [New to Sigma?](#new-to-sigma-read-this-first)
below — it covers Edit mode, elements, pasting SQL, formulas, controls and
grouping. The numbered steps assume it.

**Read [FLAGS.md](FLAGS.md) first.** Six of its flags change what a tile is
allowed to say, and three of them change what you can promise the stakeholder.
**Then read [../data-issues/intrum/feed-coverage.md](../data-issues/intrum/feed-coverage.md)** — it maps every
metric in the stakeholder's pack to buildable / needs-modelling / blocked, and
Step 4 (the Scorecard page) only covers the buildable third.

⚠ **Redesigned 2026-09-15.** Two datasets, not five; sums only, no stored
ratios; the servicer forecast only. Pages 2–4 below were rewritten to match.
If a tile references a column that is not in `sigma/`, it is from the old
build — see *What changed* at the end.

| | |
|---|---|
| Workbook | **Servicing Dashboard** — [open](https://app.sigmacomputing.com/brocc/workbook/Servicing-Dashboard-6K98gtvWEoAEoBu9tkJCzb) (id `dd98cc62-912e-4681-8269-323a90ffe295`) |
| Connection | **Snowflake - PROD** (id `b3be9b8b-fb38-4b05-a8db-afdb5c47cdbf`) |
| Data as at | 2026-08-31, the latest complete month |
| Pages | 5 — Overview, Performance, Scorecard, Diagnostics, Data & definitions |

---

## New to Sigma? Read this first

Everything below assumes you know five things. If you don't, this section is
the whole of it. ⚠ Sigma renames menu items between releases — where a label
here doesn't match exactly, look for the nearest equivalent; the *sequence* is
what matters.

### 1. You must be in Edit mode

Open the workbook and look top-right for **Edit**. Until you click it,
everything is read-only and you'll wonder why nothing is clickable. When you're
done, **Publish** (same corner) makes your changes visible to everyone else.
Until you publish, only you see them.

⚠ **Publishing is what shares real production data with whoever can open the
workbook.** Check who that is before your first publish — FLAGS.md §1.

### 2. An element is one tile

A workbook has **pages** (tabs along the top) and each page holds **elements**
— a table, a chart, a KPI card, a control. Everything you build is an element.

To add one: **+** button (or **Add element** / **Insert** panel, usually left
or top). You'll be asked what kind:

| Pick this | To get |
|---|---|
| **Table** | rows and columns — also how you paste custom SQL |
| **Chart** / **Visualization** | bars, lines, scatter |
| **Chart** → type **KPI** | one big number — the cards in Step 2. ⚠ KPI is a *chart type*, not a separate element |
| **Control** / **Filter** | a dropdown or date picker at the top of the page |

### 3. How to paste our SQL — the one step that confuses everyone

1. **+ → Table**
2. Sigma asks where the data comes from. Ignore the list of tables — look for
   a **Write SQL** / **SQL** / **Custom SQL** option (often a small tab or a
   link under the table browser).
3. Choose the connection **Snowflake - PROD**.
4. Open the matching file from `work/servicing/`, select all,
   paste. **Change nothing.**
5. **Run** (or ⌘/Ctrl + Enter), then **Save** / **Done**.

You now have one element holding the whole dataset. Every tile on that page is
built *from this element*, not from a fresh paste — see §5.

⚠ **Sigma renames your columns.** `collections_eur` in the SQL shows up as
**`Collections Eur`** in Sigma. That is normal. Every formula in this guide
uses the Sigma name, in square brackets: `[Collections Eur]`.

### 4. How to write a calculation

This guide says things like *"define it as `sum(actual) / sum(plan)`"*. Here is
how that actually happens:

1. Select the element.
2. In the **Columns** list (right or left panel), click **+** → **New column**
   / **Add calculation**.
3. Type the formula, then rename the column by double-clicking its header.

Sigma formulas look like spreadsheet formulas, with column names in square
brackets:

```
Sum([Collections Eur]) / Sum([Underwriting Forecast Eur])
```

Then set the format to **Percent** (column menu → **Format** → **Percent**).

⚠ **Always `Sum(...) / Sum(...)`, never `Avg([some ratio])`.** That is FLAGS.md
§7 and it is the single easiest way to publish a wrong number here.

### 5. Controls do nothing until you target them

Add one with **+ → Control**, pick the type (**List** for a dropdown,
**Date range**, **Number range**), then:

1. Point it at a **column** — e.g. a List control at `Country Name`.
2. **Target it at the elements it should filter.** There is a *Targets* /
   *Applies to* setting on the control. **A control with no targets filters
   nothing and gives no error** — if a dropdown seems dead, this is why, every
   time.

### 6. Grouping — this is the drill-down

The Performance page needs `Vehicle → Deal → Portfolio`. In a table element:

1. Find the **Grouping** / **Rows** section of the element's panel.
2. Drag `Vehicle` into it, then `Deal`, then `Portfolio Name`.
3. Reorder by dragging. Collapse and expand with the arrows in the table.

Your money columns must be **aggregates** (`Sum([Collections Eur])`), not raw
columns, or grouping has nothing to total.

✅ Verified 2026-09-14: **you can reorder those levels freely and every total
still foots** — see FLAGS.md §2.

### 7. Copy an element instead of re-pasting SQL

For a second tile on the same data: right-click the element → **Duplicate**,
or add a chart and choose the **existing element** as its source. Re-pasting
the SQL creates a second copy of the query that then drifts from the first.

### If you get stuck

| Symptom | Cause |
|---|---|
| Nothing is clickable | Not in **Edit** mode |
| A dropdown does nothing | Control has no **targets** (§5) |
| `[Collections Eur]` not found | Sigma's name differs — check the Columns list for the exact spelling |
| Numbers look far too big | A money column isn't aggregated, or you're grouping on nothing |
| A percentage looks wrong | You averaged a ratio instead of `Sum/Sum` (§4) |
| "Invalid identifier is_complete_month" | That column was removed — FLAGS.md §4 |


---

## What you are building — the whole thing on one page

**Five pages, two datasets**, plus one control panel.
Build them in this order — each step below is exactly one page.

| Page | Elements | Reads |
|---|---|---|
| **1. Overview** | banner · KPI cards | Portfolio overview |
| **2. Performance** | performance chart · L3M grouped table · since-inception chart | Portfolio overview |
| **3. Scorecard** | the servicer-cost table | Portfolio overview *(the cost columns)* |
| **4. Diagnostics** | grouped table · rate chart | Portfolio diagnostics |
| **5. Data & definitions** | text only | — |

Plus **one control panel**, built once on page 1 and copied to the others
(Step 1).

⚠ **Every page needs the banner from Step 2** — `snapshot_date`, `fx_from`,
`fx_to`. Build it once, duplicate it onto each page.

---

## Step 0 — Load the two datasets

They live in `work/servicing/` and are compile-checked against PROD.
Run each locally once before pasting, so you know what it returns:

```bash
# retired 2026-10-02 — see work/.archive/2026-10-02-servicing/prod/
# deleted 2026-09-17 — the phase split is not trusted
```

| Dataset | One row per | Source | Feeds | Runtime |
|---|---|---|---|---|
| `prod/dash_portfolio_overview.sql` | portfolio × month | the servicer's **portfolio** report (PROD only) | Overview, Performance, Scorecard | ~8s |
| `raw/dash_portfolio_diagnostics.sql` | portfolio × snapshot × **flags** | the **loan** feeds (PROD + RAW phase) | Diagnostics | **~100s** with phase (Sigma default) · 43s with phase off |

**The split.** Everything that comes from the servicer's monthly portfolio
report — collections, balance, carrying, the servicer forecast, commission and
fees — is in the overview. Everything that comes from the loan-level feeds —
open/closed, secured, payment arrangements, workout phase, debt age, paying
counts — is in diagnostics. **The two do not reconcile and are not meant to**
(FLAGS.md §6): the overview is the number for *how much*, diagnostics for *how
it splits*.

**Sums only.** Neither dataset returns a ratio or a percentage. Every rate is a
Sigma formula over sums, so it stays right under any filter:

```
paying rate     = Sum([N Paying L3m]) / Sum([N Loans])
performance     = Sum([Collections L3m Eur]) / Sum([Servicer Forecast L3m Eur])
cost to collect = Sum([Servicer Cost Total Eur]) / Sum([Collections Eur])
```

**One forecast.** `servicer_forecast_eur` — what Intrum says it will collect.
The accounting and underwriting forecasts were removed on 2026-09-15; the
overview's header says how to put one back.

### ⚠ There is nothing to generate any more (changed 2026-10-02)

There used to be two copies of every dataset — a `set`-and-`$variable` source
that ran from this workspace, and a paste-ready copy generated from it by
`mise run sigma-sql`. **Both the task and the generator are gone.** The six
files in `work/servicing/` are written directly in the form Sigma needs: no
`set` lines, no `$variables`, no trailing `order by` or `;`. Edit the file,
paste the file.

⚠ **The cost of that is you cannot always run them here.** Four of the six read
PROD only and run as-is wrapped in a subquery:

```bash
mise run sql -- work/servicing/sigma_portfolio_information.sql
```

The other two call `sigma_element()`, which exists only inside Sigma. To verify
one of those locally, inline the referenced elements by hand first.

⚠ **Never edit anything in `sigma/`** — edit the source in `prod/` or `raw/`
and regenerate. The banner at the top of each generated file says so.

For each: **Add element → Table → Write SQL → Snowflake - PROD**, paste the
file from `sigma/` unchanged, and save.

⚠ **One value still needs rebinding by hand:** in
`sigma/dash_portfolio_diagnostics.sql`, the literal `'2026-08-31'` is the month
the page describes. Bind it to a Sigma date control, or the page quietly
reports a stale month forever. The generated file carries that warning at the
top.

Name them `Portfolio overview` and `Portfolio diagnostics`.

---

## Step 1 — Create the five empty pages

Two minutes, then move on. **No controls yet** — a control has to be pointed at
tiles, and there are no tiles until Step 2.

Right-click the page tab at the top → **Duplicate page** / **Add page**, and
name the five:

```
Overview  ·  Performance  ·  Scorecard  ·  Diagnostics  ·  Data & definitions
```

That is the whole step. You now have five empty pages and the two datasets
from Step 0.

⚠ **Build the pages in order.** Each one below is self-contained: you add its
tiles, then its controls, then check it works, before moving on. Do not try to
build the control panel once for everything — the controls on each page must
point at that page's own tiles.

---

## Step 2 — PAGE 1: Overview

> ### 📄 PAGE 1 — Overview: "Where we stand"
>
> **Elements on this page:**
>
> | # | Element |
> |---|---|
> | 1 | Banner (text) |
> | 2 | Card: Collected, latest month |
> | 3 | Card: Collected, rolling 3 months |
> | 4 | Card: Against underwriting plan |
> | 5 | Card: Against current forecast |
> | 6 | Card: Portfolio balance |
> | 7 | Card: Portfolios under management |
> | 8 | Card: Average month, L3M *(optional)* |
> | 9 | Card: Collected NET, latest month *(optional)* |
>
> **Reads:** `Portfolio overview`

Eight KPI cards — six core, plus the L3M average (7) and the net variant (8).
**How to build one** (then repeat):

1. **+ → Chart**, then set its **visualization type to KPI**.
   ⚠ KPI is a *chart type*, not its own element type — there is probably no
   "+ → KPI" button. Add any chart, then switch the type; Sigma lets you
   change visualization type at any time, so starting with a bar costs
   nothing. (Sometimes labelled *Single value* or *Stat*.)
2. Source: the existing **Portfolio overview** element — not a new SQL paste.
3. ⚠⚠ **The formula goes in the VALUE slot, not the title.** A KPI card has
   three separate things and they are easy to confuse:

   | Slot | What it is |
   |---|---|
   | **Title** | plain text **you type** — it computes nothing |
   | **Description** | optional text under the title |
   | **Value** | ← **the formula goes here** |

   If your number appears where the title should be and the big number reads
   `0`, the formula went into the title. Move it to the value slot.

4. Click the **value** slot → **New column** / **Add calculation** → paste the
   formula from the table below.
5. **Set the title.** Double-click the title text on the card and type
   `Collected, latest month`. (If double-click does nothing, use the element's
   **⋮** menu → *Rename*, or the **Title** field in its properties panel.)

   ⚠⚠ **A Sigma title evaluates a formula if you start it with `=`.** That is
   the trap: paste `=Sum(...)` into the title and it renders the number there,
   while the real value slot stays empty and shows `0`. The title is meant to
   be **plain text with no `=`**.
6. Format the value: column menu → **Format**.

   | For | Set |
   |---|---|
   | Money on a **card** | *Currency* EUR → **Abbreviate / Compact**, 1 decimal → `€33.3M` |
   | Money in a **table** | *Currency* EUR, 2 decimals, **not** abbreviated |
   | A ratio | *Percent*, 2 decimals |

   ⚠ Unformatted it reads `33334835.79979`. Formatting changes only what is
   printed — the value keeps full precision underneath, so hover still shows
   the exact figure and Step 7's checks still match.

   ⚠⚠ **Never divide by 1,000,000 in the formula to get millions.** That
   changes the VALUE, not the display: anything downstream — a ratio, a total,
   an export — then carries a number 10⁶ too small, and it breaks the moment
   someone regroups or mixes a divided column with an undivided one. Use the
   Abbreviate format instead. Same rule as never rounding the data to tidy it.

   ⚠ **Keep tables unabbreviated.** You cannot check `€33.3M` against
   `EUR 33,334,835.80` in the Step 7 table.

### ⚠ Columns were renamed to full words on 2026-09-15

Abbreviations are gone — if you built tiles before this date, the names moved:

| Was | Now |
|---|---|
| `data_as_at` | **`snapshot_date`** |
| `uw_forecast_eur` | *removed 2026-09-15 — use `servicer_forecast_eur`* |
| `cum_collections_eur` | **`cumulative_collections_eur`** |
| `cum_collections_uw_window_eur` | **`cumulative_collections_in_servicer_window_eur`** |
| `pct_accounts_paying` | **`percent_accounts_paying`** |
| `arrangement_rate` | *removed — `Sum([N Loans]) where In Arrangement / Sum([N Loans])` in Sigma* |
| `paying_rate_3m` | *removed — `Sum([N Paying L3m]) / Sum([N Loans])` in Sigma* |

Re-paste the SQL and fix any formula referencing an old name. A stale name
fails silently, so check every card after re-pasting.

### ⚠ Column names carry the source element's name

This is not in any Sigma tutorial and it will stop you dead. When a card reads
from another element, Sigma qualifies every column with **that element's
name**:

```
[Portfolio overview /Collections Eur]
      ↑ your element's name          ↑ the column
```

So the formulas below are written with a placeholder. **Replace
`<ELEMENT>` with whatever you actually named the Custom SQL element** — and
the safest way is not to type it at all: press `[` and pick from autocomplete,
which fills in the full qualified name for you.

⚠ If you mistyped the element name when creating it, the prefix inherits the
typo. Rename the element early — Sigma updates existing references — rather
than after six cards are written against it.

Formulas in Sigma syntax, column names in square brackets:

| # | Card title | Formula |
|---|---|---|
| 1 | **Collected, latest month** | `Sum(If([<ELEMENT> /Month End] = [<ELEMENT> /Snapshot Date], [<ELEMENT> /Collections Eur], 0))` |
| 2 | **Collected, rolling 3 months** | `Sum(If([<ELEMENT> /Month End] = [<ELEMENT> /Snapshot Date], [<ELEMENT> /Collections L3m Eur], 0))` |
| 7 | **Average month, last 3 months** *(optional)* | card 2's formula, then `/ 3` — see below |
| 3 | **Against underwriting plan** | `Sum([<ELEMENT> /Collections Eur]) / Sum([<ELEMENT> /Underwriting Forecast Eur])` |
| 4 | **Against current forecast** | `Sum([<ELEMENT> /Collections Eur]) / Sum([<ELEMENT> /Forecast Eur])` |
| 5 | **Portfolio balance** | `Sum(If([<ELEMENT> /Month End] = [<ELEMENT> /Snapshot Date], [<ELEMENT> /Balance Eur], 0))` |
| 6 | **Portfolios under management** | `CountDistinct([<ELEMENT> /Portfolio Id])` |
| 8 | **Collected NET, latest month** | `Sum(If([<ELEMENT> /Month End] = [<ELEMENT> /Snapshot Date], [<ELEMENT> /Net Collections Eur], 0))` |

### Show gross AND net — both, side by side

⚠ **They are different questions, not different opinions:**

| | Means | Answers |
|---|---|---|
| **Gross** `collections_eur` | what the debtor paid | *how well is the servicer collecting?* |
| **Net** `net_collections_eur` | after commission, VAT, passthrough | *what do we actually get?* |

Net runs about **78% of gross** (Intrum 0.777, Gescobro 0.795, Cerved 0.884),
and the headline moves with it:

| Basis | Since June 2025 |
|---|---|
| Gross | **104.30%** |
| Net | **~101.6%** |

⚠⚠ **Label every money card with its basis** — put *(gross)* or *(net)* in the
title. A card showing net next to one showing gross, with neither labelled, is
how two people leave the same meeting with different numbers.

⚠ **Never put gross and net in the same total.** They are not additive
together.

### Card 7 — the rolling 3-month AVERAGE

`Collections L3m Eur` is a **sum** over three calendar months. For the
average month, divide card 2's formula by 3:

```
Sum(If([<ELEMENT> /Month End] = [<ELEMENT> /Snapshot Date],
       [<ELEMENT> /Collections L3m Eur], 0)) / 3
```

✅ Unfiltered, the three averages are:

| Window | Sum | ÷ | Average month |
|---|---|---|---|
| L3M | EUR 123,737,077.81 | 3 | **EUR 41,245,692.60** |
| L6M | EUR 239,929,790.29 | 6 | **EUR 39,988,298.38** |
| L12M | EUR 473,793,572.99 | 12 | **EUR 39,482,797.75** |

⚠ The averages fall as the window lengthens — collections are trending down.
That is real, and it is the kind of thing the pack's three columns exist to
show.

⚠⚠ **L3M EXCLUDES THIS MONTH. Changed 2026-09-15.**

```
L0M = this month (excluded)   L1M + L2M + L3M = the window
```

On the August row that is **May + June + July** — not August. Checked by hand
on one portfolio: 5,414.94 + 8,456.34 + 9,492.95 = 23,364.23, and the file
returns 23,364.23.

✅ **This now matches the payer window.** `New` / `Lost` / `Recurrent` have
always used L1M..L3M, so a 3-month collections figure and a payer count finally
cover the same span. Before this change they did not.

⚠ **The columns were RENAMED with the definition** — `rolling_3m_*` →
`*_l3m_*` — so no tile built on the old meaning keeps computing silently
against the new one. Re-paste and fix any formula using an old name.

⚠ **Divide by 3, not by `Months In L3m Window`.** Both give the same answer for
any portfolio with three months of history, but across a group a per-portfolio
month count does not aggregate correctly. Divide by 3 for *"the average month
in the last quarter"*; only use `Months In L3m Window` if you specifically mean
*"the average of the months that exist"*, which is a different question — and
say which you used.

This is the same measure as **AVG L3M** in the servicer pack, so it carries
over to the Scorecard page unchanged (it reads the same dataset).

✅ **Card 1 is verified against the warehouse.** Built exactly as above it
returns **33,295,795.95** — the same figure as the Step 7 check table. If
yours matches, the whole chain works: SQL → element → formula.

⚠⚠ **Compare to `[Snapshot Date]`, never to `Max([Month End])`.** Corrected
2026-09-15 — an earlier version of this table used `Max()`, and it is wrong
twice over:

1. **It nests an aggregate inside a row-level `If` inside another aggregate.**
   Sigma frequently rejects that outright.
2. **`Max()` means "the latest month currently in view".** Narrow the date
   control and the card silently starts describing a different month while
   still being labelled *"latest month"*.

`Snapshot Date` is a column on every row holding the latest complete month. It
does not move when someone filters.

⚠ **The trade-off, so you can choose:** if the date control excludes the
as-at month, these cards read **0** rather than showing the last month in
view. That is the honest behaviour for a card labelled *"latest month"* beside
a banner saying *"Data as at 31 August 2026"* — but if you want
"last month in view" instead, that is a different card and it needs a
different name.

⚠ Column names are Sigma's Title Case: `month_end` → **`Month End`**, with a
space and no hyphen. A misspelled name fails silently.

⚠ **Card 3 must be filtered to `Has Underwriting Plan` = true**, or you divide
real collections by a plan that does not exist before June 2025 and the card
reads far too high. Add it as a filter on that card — FLAGS.md §3.

⚠ **Cards 3 and 4 are `Sum(...) / Sum(...)`.** Never `Avg` of a ratio —
FLAGS.md §7.

⚠ **Card 3 needs a footnote**: *"Underwriting plan exists from June 2025
only."* Add it with **+ → Text** under the card.

### The banner — build this first, it takes two minutes

**+ → Text**, placed at the top of the page. Insert dynamic values by typing
`=` in the text box and referencing the columns:

> **Data as at** `=Max([Snapshot Date])`. Months shown: `=Min([Fx From])` –
> `=Max([Fx To])`. Part-loaded months and periods without an FX rate are
> excluded.

⚠ **Bind it, don't type the dates.** Typed dates go stale silently and the
page then lies about which month it describes — FLAGS.md §4.

Two optional extras, one formula each:

- **Collection yield** — `Sum([Collections Eur]) / Sum([Balance Eur])`
- **Arrangement rate** — from *Portfolio diagnostics*; label it *"loans in a
  payment arrangement"*, **never "amicable"** (FLAGS.md §5)

---

## Step 2b — PAGE 1: now add the controls

The six cards exist, so now there is something for a control to filter.
**Build all nine here, on Overview.** Later pages copy them.

### Build ONE control first — every click

Do **Vehicle** completely, check it works, then repeat for the rest. Getting
the first one right is the whole lesson.

1. **+ → Control** → **List** (a multi-select dropdown).
2. **Where does it get its values?** Point the control at the **Hierarchy
   monthly** element and the **`Vehicle`** column. Sigma fills the dropdown
   with the distinct values it finds — you do not type them in.
3. **Leave the selection EMPTY.** ← this is what "default: all" means.
4. **Targets.** Find *Targets* (sometimes *Applies to* / *Controlled
   elements*). Tick **every element on the page that reads Hierarchy
   monthly** — on Overview that is all six cards. Sigma often pre-ticks
   elements built from the same source; **check it did**, do not assume.
5. Test it: pick one vehicle. Every card should move. Clear it. They go back.

If the cards did **not** move, it is step 4. It is always step 4.

### ⚠ "Default: all" means EMPTY — do not select every value

This is the bit that trips people up, and selecting-all looks like it works.

| | What happens today | What happens in three months |
|---|---|---|
| **Empty** ✅ | shows everything | a new vehicle appears **automatically** |
| **All values ticked** ❌ | shows everything | a new vehicle is **silently invisible** |

An empty control means *"no filter"*. A control with every value ticked means
*"only these named values"* — which is the same thing right up until someone
adds a portfolio, a deal or an SPV. Then the new one is not in your list, its
money vanishes from every total, **and nothing warns you.**

Same reason `Unknown` must stay in the list: it is a real value carrying real
money, and hiding it makes totals stop footing (FLAGS.md §2).

### Then repeat for the other eight

Same five steps, changing only the type and the column:

| Control | Type | Column | Starting selection |
|---|---|---|---|
| Vehicle | List (multi) | `Vehicle` | **empty** |
| Deal | List (multi) | `Deal` | **empty** |
| Servicer | List (multi) | `Servicer` | **empty** |
| Country | List (multi) | `Country Name` | **empty** |
| Portfolio | List (multi) | `Portfolio Name` | **empty** |
| Deal source | List (multi) | `Deal Source` | **empty** |
| Months shown | Date range | `Month End` | **empty** = full history |
| Acquisition cost ≥ (EUR m) | Number | `Capex Eur` | **empty** |
| Price paid, % of GBV | Range | `Price Percent` | **empty** |

Every one starts empty. There is no control on this dashboard that should
begin with values pre-selected.

⚠ Column names are Sigma's Title Case versions of the SQL names —
`country_name` appears as **`Country Name`**. Check the Columns list for the
exact spelling if one is not found.

⚠⚠ **A control with no targets filters nothing and shows no error.** If a
dropdown seems dead, this is why — every time.

### Why there is no "complete months" control

You may expect one. There isn't, and that's deliberate — **part-loaded months
and months with no FX rate never leave the datasets**. They are filtered inside
the SQL, so no tile can forget them. Changed 2026-09-14; the old
`is_complete_month` / `is_eur_complete` columns are gone, and a control
pointed at them would now fail with *"invalid identifier"*.

That is why the **banner** in Step 2 is not optional: the exclusion is
invisible in the data, so the page has to say it out loud (FLAGS.md §4).

⚠ Two flags **are** still yours to filter, because they describe real gaps
rather than load artefacts:

| Flag | Where | Why |
|---|---|---|
| `Has Underwriting Plan` | Overview card 3 | no plan exists before June 2025 |
| `Has Case Collection Detail` | all Accounts tiles | loan feed covers 135 of 250 portfolios |

### Control ID — set it, and one of them is load-bearing

Every control has an **ID** (sometimes *Control name*). Sigma auto-generates
something like `control-1`. Rename it: lowercase-hyphenated, matching what it
filters.

| Control | ID |
|---|---|
| Vehicle | `vehicle` |
| Deal | `deal` |
| Servicer | `servicer` |
| Country | `country` |
| Portfolio | `portfolio` |
| Deal source | `deal-source` |
| Months shown | `months-shown` |
| Acquisition cost ≥ | `capex-min` |
| Price paid, % of GBV | `price-pct` |
| **Diagnostics page month** | **`month-end`** ← see below |

For eight of the nine the ID is just readability — it shows up in the workbook
URL, so a clean one makes a shared link legible.

⚠⚠ **`month-end` is different: it is referenced inside SQL.** The Accounts
page needs the month to be a control, not a hardcoded date, and Sigma
references controls in custom SQL with double braces:

```sql
where s.date_day = {{month-end}}::date
```

**So on the Diagnostics page, after pasting
`sigma/dash_portfolio_diagnostics.sql`:**

1. Create a **Date** control, single value, ID exactly **`month-end`**,
   default 2026-08-31.
2. In the pasted SQL, **find and replace every `'2026-08-31'` with
   `{{month-end}}`** — there are several.
3. Re-run the element.

⚠ The ID must match the braces **exactly** — `{{month-end}}` will not find a
control called `month_end` or `Month End`.

⚠ Get this wrong by skipping it and the page still works — it just reports
August 2026 forever, however long that is. That is the failure mode the
generated file's header warns about.

---

## Step 3 — PAGE 2: Performance

> ### 📄 PAGE 2 — Performance: the drill-down
>
> **Elements on this page:**
>
> | # | Element |
> |---|---|
> | 1 | Performance chart (bar + line) — cross-filtered, level set by a control |
> | 2 | Rolling-3m **grouped table** — this is where the drill path lives |
> | 3 | Since-inception chart (lines) |
>
> **Reads:** `Portfolio overview`

This is the page you described. Three elements, all reading the same filtered
dataset, stacked top to bottom.

### 3a — The performance chart (top)

**Element:** bar + line combo, x-axis `month_end`.

- Bars: `sum(collections_eur)` — actual
- Line: `sum(servicer_forecast_eur)` — the servicer's own forecast
- Dotted line: `sum(forecast_eur)` — current forecast
- One axis, all three in EUR

⚠⚠ **A CHART HAS NO COLLAPSIBLE DRILL PATH.** Expand/collapse levels
(Vehicle ▸ Deal ▸ Portfolio, with arrows) are a **grouped table** feature —
they live on element 2, not here. This section used to describe both as one
"drill-down chart", which is not a thing you can build. Corrected 2026-09-15.

A chart gets its level three other ways, and you probably want the first:

| Mechanism | What the viewer does | Set up |
|---|---|---|
| **A grouping control** | picks Vehicle / Deal / Country from a segmented control above the chart | add a list or segmented control, target the chart's dimension |
| **Cross-filtering** | clicks a bar → every other element on the page filters | element menu → *Cross-filtering* / *Enable actions* |
| **Drill anywhere** | steps into the next level in place | enable on the element |

Step 6b has the full comparison of all four mechanisms.

### 3a-bis — The drill path (on the table, element 2)

**Select the TABLE**, find its **Grouping** (or *Rows*) section, and drag these
in, in this order:

```
1. Vehicle          2. Deal          3. Portfolio Name
```

Then make sure your money columns are **aggregates** — `Sum([Collections
Eur])`, not the raw column — or there is nothing for the grouping to total.
Collapse and expand the levels with the arrows in the table itself.

**Levels can be dragged and reordered freely and every total still foots** —
verified 2026-09-14: vehicle-only, Vehicle→Deal, Deal→Vehicle, country-only and
all five levels each return EUR 3,912,489,378.67164, identical to the cent.
Distinct portfolio counts foot too (252 at every level). That works because
every level is a **column on the same row**, not a separate join.

⚠ Three things still do not foot, and all three are Sigma-side:
1. **Define every ratio as `sum(actual) / sum(plan)`**, so it recomputes at
   whatever level is displayed. A stored per-row ratio will be wrong the moment
   someone regroups.
2. **Two of 61 deals span two vehicles** and will appear under both when
   vehicle is above deal. Correct, but caption it — readers call it
   double-counting.
3. **Leave `Unknown` selectable.** Filtering it out breaks footing.

⚠ Servicer is *derived from* deal source and country, so putting it above
country is legal and foots but reads as a child above its parent. Prefer it as
a filter and a column.

FLAGS.md §2 has the full measurement. Note it was **corrected on 2026-09-14** —
the earlier "19 portfolios change vehicle" counted SCD surrogate-key versions,
not real vehicle changes.

### 3b — L3M liquidations table (below the chart)

⚠ **L3M = L1M + L2M + L3M — it excludes the current month (L0M).**

**Element:** table, filtered by the same controls — it moves with the chart.

⚠ **"Liquidations" is not a warehouse word.** This is built as collections —
gross cash recovered. Confirm the definition before the meeting (FLAGS.md §9).

One row per current drill level, columns:

| Column | Sigma formula |
|---|---|
| L3M actual | `sum(collections_l3m_eur)` at the latest month in view |
| L3M servicer forecast | `sum(servicer_forecast_l3m_eur)` |
| L3M performance | `sum(collections_l3m_eur) / sum(servicer_forecast_l3m_eur)` |
| L1M / L6M / L12M | same pattern — every period exists for both measures |

**Every period uses the same vocabulary, on every dataset:**

```
L0M = the snapshot month itself   (EXCLUDED from L3M / L6M / L12M)
L1M = the month before it
L3M = L1M+L2M+L3M      L6M = L1M…L6M      L12M = L1M…L12M
```

| Dataset | L0M | L1M | L3M / L6M / L12M |
|---|---|---|---|
| **Overview** (row per month) | ⚠ **no column** — it is `Collections Eur` on the snapshot row; filter to `Snapshot Date` | `Collections L1m Eur` | `Collections L3m Eur` … |
| **Diagnostics** (one month-end) | `Collected L0m Eur` | `Collected L1m Eur` | `Collected L3m Eur` … |

⚠⚠ **The overview deliberately has no `l0m` column.** It is one row per month,
so an "L0M" column would just be `Collections Eur` again — and someone would
sum it and get *all-time* collections while believing they had this month.
On Diagnostics there is one month-end per row, so `Collected L0m Eur` is
unambiguous and does exist.

The `rolling_3m_*` columns are **pre-computed sums per portfolio-month**, so
they stay correct under any filter — that is why they are in the dataset and
the ratios are not.

⚠ Show `months_in_l3m_window` as a small column or a warning icon. It is 3 for
a full window; 1 or 2 means the portfolio is too young and its "rolling 3m" is
not comparable with the others.

### 3c — Since inception (bottom)

**Element:** line chart, x-axis `month_end`, **starting 2025-06-30**.

- Line 1: `sum(cumulative_collections_in_servicer_window_eur)` — cumulative actual
- Line 2: `sum(cumulative_servicer_forecast_eur)` — cumulative servicer forecast
- Line 3 (optional): `sum(cumulative_forecast_eur)` — cumulative current forecast

⚠⚠ **Use `cumulative_collections_in_servicer_window_eur`, not `cumulative_collections_eur`.** The
first counts only months where a plan exists; the second runs from 2018 and
would show a fake shortfall of several hundred million. FLAGS.md §3.

⚠ **For a total *card* beneath this chart, sum the monthly column over the
period — do not read the cumulative at the latest month.** Cumulative columns
accumulate per portfolio, so reading them at one month silently drops every
portfolio with no row that month (worth EUR 964,450.31 at August). FLAGS.md §8.

Title it **"Collected against underwriting plan, since June 2025 (EUR)"** —
the date belongs in the title, not a footnote.

---
### Now add the controls to this page

1. Go to **Overview**, select the nine controls, **Copy**.
2. Come back to **Performance**, **Paste**.
3. ⚠⚠ **Re-do Targets on every one.** A pasted control keeps its column but
   **loses its targets** — the tiles here are objects it has never seen. This
   is the number one reason a copied panel looks dead.
4. Target them at: **the performance chart, the rolling-3m grouped table and the since-inception chart**.
5. Test: pick one country. Every number on this page should move.
6. ⚠ **Also switch on cross-filtering** on the chart, so clicking a bar
   filters the table beneath it. That is what makes the rolling-3m section
   follow the chart.

⚠ Copy the **banner** across too (it is a Text element, not a control — it
needs no targets).

---
## Step 4 — PAGE 3: Scorecard

> ### 📄 PAGE 3 — Scorecard: what the servicer costs us
>
> **Elements:** one table. **Reads:** `Portfolio overview` — the same dataset
> as pages 1 and 2. There is no separate scorecard dataset any more.

The servicer's cut is itemised on every overview row, so the scorecard is a
grouped table over the columns you already loaded:

| Row | Sigma formula |
|---|---|
| Collected, gross | `Sum([Collections Eur])` |
| Collected, net | `Sum([Net Collections Eur])` |
| Servicer cost, total | `Sum([Servicer Cost Total Eur])` — gross minus net |
| … of which commission | `Sum([Commission Eur])` |
| … of which management fee | `Sum([Portfolio Mgmt Fee Eur])` |
| … of which passthrough | `Sum([Passthrough Cost Eur])` |
| Cost to collect | `Sum([Servicer Cost Total Eur]) / Sum([Collections Eur])` |
| Servicer forecast | `Sum([Servicer Forecast Eur])` |
| Performance vs forecast | `Sum([Collections Eur]) / Sum([Servicer Forecast Eur])` |

**Periods** come from the month filter plus the L-columns: filter `month_end`
to the latest month for L0M, then use `[Collections L1m Eur]`,
`[... L3m ...]`, `[... L6m ...]`, `[... L12m ...]` for the trailing windows.
Every measure has every period.

⚠ **Sign.** The three cost components are stored positive (negated at source,
where Intrum sends them negative). `Servicer Cost Total Eur` is gross minus
net and will not always equal the three components summed — the residual is
un-itemised cost. Show all four and let the reader see the gap.

⚠ **`servicer_forecast_n_versions`** tells you how many revisions of that
month's forecast existed (up to 12). The dataset keeps the newest. Never sum
this column; `Max()` it if you show it at all.

Group by `servicer` → `country_name` → `portfolio_name`, controls copied from
page 1 with targets re-pointed (Step 2b).

---

## Step 5 — PAGE 4: Diagnostics

> ### 📄 PAGE 4 — Diagnostics: how the book splits, and who pays
>
> **Elements:** one grouped table, one chart. **Reads:** `Portfolio diagnostics`.

This dataset is **one row per portfolio × snapshot × flags**, and every
measure is a sum. That is the whole design: you group by whichever flags you
care about and Sigma re-sums.

### The flags (group by any of them)

| Column | Values | What it means |
|---|---|---|
| `is_open` | true / false | closing date null or after the snapshot. ⚠ 41% of the snapshot is closed — filter to `true` for "under management" |
| `is_secured` | true / false | `DIM_CASE.SECURED_FLAG` |
| `in_arrangement` | true / false | `FORBEARANCE_FLAG`. ⚠ Label *"in a payment arrangement"*, never *"amicable"* |
| `has_phase_feed` | true / false | does this loan's Intrum instance send a phase feed at all? False for Gescobro, Cerved and feed-less instances. **Filter on it before reading `phase`** |
| `phase` | Amicable · Legal · Execution · No Phase · No Phase Feed | the workout phase **in force at the snapshot**. ⚠ A loan attribute — see below. `No Phase` = feed exists, no spell; `No Phase Feed` = `has_phase_feed` is false |
| `debt_age_bucket` | `0-4`, `5-9`, … `Unknown` | years since default, 5-year bands. Sort on `debt_age_bucket_start` |

### The measures (sums; divide in Sigma)

| Column | Sigma formula for the rate |
|---|---|
| `n_loans`, `balance_eur` | — |
| `collected_l0m / l1m / l3m / l6m / l12m_eur` | yield = `Sum([Collected L12m Eur]) / Sum([Balance Eur])` |
| `n_paying_l3m / l6m / l12m` | paying rate = `Sum([N Paying L3m]) / Sum([N Loans])` |

Share secured = `Sum([N Loans]) filtered to is_secured / Sum([N Loans])` —
build it as a calculation, not a stored column.

### The table

Group by `servicer` → `portfolio_name`, then add `phase` and `is_open` as the
next levels. Columns: `n_loans`, `balance_eur`, `collected_l12m_eur`, paying
rate, yield. Filter `is_open = true` by default and say so in the title.

### The chart

Scatter, one point per portfolio: x = paying rate, y = yield, size =
`Sum([Balance Eur])`, colour = servicer. Bottom-left is the page's question.

### ⚠ Three things this page cannot do

**Phase is where the loan is NOW, not where the cash came from.**
`collected_l12m_eur` where `phase = Legal` is twelve months of cash from loans
*currently* in legal, whatever phase they were in when they paid. Caption it
that way. The per-payment split (cash earned *while* in legal) is a different
dataset and is not on the dashboard.

**Loan level does not tie to portfolio level, and never will.** 114 of 252
portfolios send no loan file. Use this page for mix and rates; use the
overview for any money total. If a portfolio is missing here, it is absent
from the feed, not at zero.

**The phase labels are ours, with one confirmed.** A / L are a reading of the
code prefix; **E = Execution** (enforcement after a legal ruling) was confirmed
2026-09-15. Intrum's own GROUP_PHASE_CODE list is still outstanding (FLAGS.md §5).

### ⚠ The phase switch — the fallback if Sigma times out

Putting phase on every one of 21.9m loans means reading the 346m-row RAW phase
feed. Rewritten 2026-09-15 to aggregate that feed to one row per case *before*
joining it to the book: **100 seconds with phase, 43 without** (it was 195).
Sigma runs it **on**.

⚠ This switch is moot — the Diagnostics page it served was deleted on
2026-09-17, and the generator that carried the flag went on 2026-10-02. Kept
because it records the cost: if a phase page is ever rebuilt, aggregating the
feed to one row per case *before* the join is the difference between 100
seconds and 195, and the lasting fix is a materialised phase-at-snapshot dbt
model (`work/dbt/DBT-HANDOFF.md` model 1).

### ⚠ One edit after pasting — do not skip it

The literal `'2026-08-31'` in `sigma/dash_portfolio_diagnostics.sql` is the
snapshot month. Create a single-value date control with ID `month-end` and
replace every occurrence with `{{month-end}}`, or the page reports the same
month forever. The generated file says this at the top.

---

## Step 6 — PAGE 5: Data & definitions

> ### 📄 PAGE 5 — Data & definitions
>
> **Elements on this page:**
>
> | # | Element |
> |---|---|
> | 1 | Text blocks only |
>
> **Reads:** `—`

One page, no charts. Paste in:

- Which two datasets feed which page, and their grain
- The three measures and that they are **not interchangeable**: actual,
  underwriting plan (from June 2025), current forecast (revised, 8 vintages)
- The two default filters and why
- **What is not in the warehouse**: amicable / legal / insolvency split,
  instalment amounts, borrower age, a segment-split plan, workout duration
- The as-at month, and that it is production data

This page is what stops the next person re-deriving a number and getting a
different answer. It is the cheapest page to build and the most valuable in
six months.

---

### Controls on this page: none

⚠ **Do not paste the control panel here.** It is text only — there is nothing
to filter, and a control with no targets is just clutter that looks broken.

Copy the **banner** across, though, so the as-at date is on every page.

---
## Step 6b — Make it explorable: drill-down and drag-and-drop

Your stakeholder should be able to ask *why* without asking you. Four
mechanisms, in order of how much they will actually use them.

⚠ Only the first works on a **table**. A chart cannot have expand/collapse
levels — if you want a chart to change level, that is mechanism 4.

### 1. Grouped tables — expand and collapse

Any table with **Grouping** levels is already a drill-down: rows collapse to
the top level with an arrow to open each one.

```
Vehicle  ▸  Deal  ▸  Portfolio
```

✅ **Verified: they can reorder the levels freely and every total still
foots.** Vehicle-only, Vehicle→Deal, Deal→Vehicle, Country-only and all five
levels each return the same grand total to the cent, and distinct portfolio
counts foot too (FLAGS.md §2). That works because every level is a column on
the **same row**, not a separate join — so any subset, in any order, sums the
same rows.

### 2. Charts — click a bar to filter everything else

Turn on **cross-filtering** on the Performance chart (element menu → look for
*Cross-filtering* / *Enable actions*). Clicking a bar then filters every other
element on the page. That is what makes the rolling-3m table follow the chart.

Sigma also has **drill-down / "drill anywhere"** on charts, letting a viewer
step into the next level in place. Enable it on the Performance chart.

### 3. Click a portfolio → jump to Diagnostics

The most valuable one, and the one nobody sets up. On the Performance table,
add an **action**: on click of a portfolio row, **navigate to the Diagnostics
page** with that portfolio passed into its control.

That turns *"PT15018G is behind plan"* into *"...and here is its paying rate,
arrangement rate, debt age and legal/amicable split"* in one click — which is
the actual question your stakeholder is asking.

### 4. A grouping control — change what a CHART is grouped by

The one the page-2 spec assumed and never named. Add a segmented control or
list above the performance chart offering Vehicle / Deal / Country / Portfolio,
and target it at the chart's dimension. The viewer switches level without the
chart needing any grouping hierarchy of its own.

Use this when someone wants "the same chart, by country instead" — which is
most of the time. It is not a drill-down: it replaces the level rather than
nesting into it.

### ⚠ Three things that do NOT survive regrouping

| | Why |
|---|---|
| **Ratios** | A parent's percentage is not the sum or average of its children. Define every one as `Sum(x) / Sum(y)` so it recomputes at whatever level is shown. Never store a per-row ratio. FLAGS.md §7 |
| **Two deals** | 2 of 63 deals span two vehicles and appear under both when vehicle is above deal. The grand total is right; caption it, or a reader calls it double-counting |
| **`Unknown`** | Filtering it out breaks footing. It is a real value carrying real money |

### ⚠ What drill-down cannot reach

Below portfolio, **the trail stops**. Loan-level detail lives in
`prod/agg_loan_detail.sql` and needs a **required** portfolio control — 21.8m
loans. And there is no debtor level at all: one `borrower_sk` is shared by
8,936,830 cases, so a per-debtor figure would be wrong while looking plausible.

⚠ On the Diagnostics page, remember the paying rate is meaningless
on the 115 portfolios with no loan feed — keep every engagement tile filtered
to `has_case_collection_detail = true`, or a portfolio with no feed ranks
bottom while collecting normally (FLAGS.md §6).

---

## Step 7 — Verify before you share

Run these against the dashboard with **no filters applied** and all controls
cleared. Re-measured **2026-09-15** for month-end **2026-08-31**:

| Check | Expected |
|---|---|
| Snapshot date | 2026-08-31 |
| Portfolios | 265 |
| Vehicles / deals / countries | 19 / 63 / 16 |
| Collected, L0M (this month) | EUR 33,334,835.80 |
| Collections L3M (L1M+L2M+L3M) | EUR 123,737,077.81 |
| **Average month, L3M** | **EUR 41,245,692.60** |
| Underwriting L3M | EUR 116,265,260.56 |
| **L3M performance vs plan** | **106.43%** |
| L3M vs current forecast | 107.76% |
| Cumulative actual, plan window | EUR 565,040,621.43 |
| Cumulative underwriting plan | EUR 541,737,942.50 |
| **Performance since June 2025** | **104.30%** |
| Portfolio balance | EUR 48,767,872,418.71 |

⚠⚠ **These moved between 14 and 15 September — portfolios 250 → 265, deals
60 → 63 — with no change to any query.** That is new data loading, and it is
the whole reason the banner binds to `snapshot_date` instead of a typed date.
**If your figures are close but not identical, check the snapshot date before
assuming a tile is wrong.**

⚠ The L3M figures also changed when L3M was redefined to exclude the current
month (2026-09-15). Anything quoting the older EUR 115,778,855.57 predates it.

If a figure is out, check you re-pasted the SQL after the renames — the
completeness filters are now enforced inside the query, so a missing filter is
no longer a possible cause.

To check any single tile without leaving the terminal:

```bash
# retired 2026-10-02 — see work/.archive/2026-10-02-servicing/prod/
```

The Sigma MCP connector can also run SQL against the same connection
(read-only, Postgres dialect, tables by inode id) if you want to compare a
tile without opening the editor.

---

## Look and feel

Carried over from the previous design, which the stakeholders signed off:

- White page, dark green `#17382C` banner and headings, light green `#CDF09A`
  on the banner only
- Fixed colours per servicer on every chart — Intrum blue, Gescobro orange,
  Cerved green, **Unknown always grey**
- Every chart title names the measure, the level and the currency, e.g.
  *Collected by vehicle (EUR, portfolio level)*
- Plain business language throughout — no element codes, no column names
- Money to 2 decimals in tables, compact on cards; ratios to 2 decimals in
  percent, 5 in tables. **Nothing is rounded in the data.**

---

## What changed from the old build

The Streamlit app is gone — `work/servicing-dashboard/dashboard.py`,
`build_snowflake_app.py`, `.streamlit/`, `.build/`, the `dash` / `build-sis` /
`deploy-sis` mise tasks and the `streamlit` dependency were all removed on
2026-09-14. Sigma is the dashboard now.

⚠ **The deployed Snowflake app was not touched.** `SERVICING_DASHBOARD` still
exists in `brocc-sandbox` `DEV.DBT_SHARLENE` and will keep serving a stale
copy to anyone with the link. Dropping it needs the `DEVELOPER` role and is a
one-line `snow streamlit drop` — say the word and it goes, but it is an
outward-facing object so it was left alone.

`dashboard.ipynb` — the servicing foundation index, a tour of the 30-file
`prod/` base layer — was retired with that base layer on 2026-10-02. Both are in
`work/.archive/2026-10-02-servicing/`. The dashboard no longer reads any of it:
the six elements beside this file are the whole thing.

---

### 2026-09-15 — two datasets, sums only, servicer forecast

- **Five datasets → two.** `dash_servicer_scorecard`, `dash_phase_collections`
  and `dash_phase_collections_wide` are no longer generated for Sigma. Their
  sources stay in `prod/` and `raw/` as reference. The scorecard's cost
  columns moved into `dash_portfolio_overview`; the phase split moved into
  `dash_portfolio_diagnostics` as a per-loan flag.
- **No stored ratios anywhere.** Every `percent_*`, `*_per_*` and `*_yield*`
  column was removed. Rates are Sigma formulas over sums.
- **Servicer forecast only.** `forecast_eur` (accounting) and
  `underwriting_forecast_eur` and all their L-window and cumulative variants
  were removed. `cumulative_collections_in_plan_window_eur` became
  `cumulative_collections_in_servicer_window_eur`.
- **Diagnostics regrained** from one row per portfolio to one row per
  portfolio × snapshot × `is_open` × `is_secured` × `in_arrangement` ×
  `phase` × `debt_age_bucket`.
- **`portfolio_id` dropped** from both datasets; `portfolio_name` is the key.
- **Overview runs in ~8s** (was ~10 min): the RAW phase leg left it, and a
  duplicate scan of the snapshot fact was folded away.
- `underwriting_unlevered_irr` removed from the overview.
