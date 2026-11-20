# The Servicing dashboard redesign — what it shows, and how it maps to Sigma

**For:** the CEO and the Head of Servicing first; analysts second.
**Design:** [Servicing Dashboard Redesign](https://claude.ai/artifact/5SyvnqmbvMYyfhYaWjY9tm) — source in `design/project/`.
**Status (2026-10-09):** live as [Servicing Dashboard](https://app.sigmacomputing.com/brocc/workbook/5OHD9y2g5PaMr3pJqvLV9); the previous version is kept as "(retired 2026-10-09)". 18 live-tile checks pass (version 5).

---

## 1. The principle

The top of every page answers the executive question, **"are we on plan?"**, in one
sentence and a few cards. The analyst question, **"where is the gap coming from?"**,
sits underneath, in a ranked Performance table and a Full breakdown. Nothing at the top needs a filter touched to make
sense.

Money and case behaviour come from **two different feeds**, so they live on two
different pages and never share a card:

| Page | Source | Answers |
|---|---|---|
| **Portfolio** | The servicer's monthly portfolio report | How much came in, against which plan, and where the gap is |
| **Cases** | The loan-level case feed (dbt mart) | How many cases are paying, starting, stopping and returning |
| **Data Quality** | Both feeds, compared | How much of the money the case feed confirms (reconciled), where it does not, and which feeds stopped |
| **Data & Definitions** | `docs/definitions.csv` | Where every figure comes from, the five rules, and a searchable definition of every term |

One header — title, Data as of, **Reporting month**, the filters, the
Reconciliation toggle and a **Clear Filters** button (it clears those six only, never the toggles) — sits above every page, so a month chosen once applies everywhere.

## 2. Page by page

Each page has three sections, and every fact appears once: the answer and its trend, which group drives it, then every figure for every portfolio.

**Portfolio**

1. **Overview.** The cards show the **latest reporting month** (the last month the Reporting month filter keeps; set its
   end month to look at an earlier snapshot). One **Comparison Window (Average Monthly)** toggle, L1M · L3M · L6M · L12M
   (no This month; 2026-10-12), moves only the % under each card: the latest month against the month before (L1M) or the
   average month of the 3, 6 or 12 months before it. A comparison is blank only when not one portfolio in the filtered set has every month of the window (2026-10-12), so filtering in can blank it and never un-blank it: on August,
   L12M has 8 of 12 months, so its % is blank and the line says "not enough months yet (8 of 12)". Ratio cards (% of forecast, servicer cost %)
   compare with the window's ratio of totals, in points; the gap in euro. The line above the cards names the months:
   "The tiles compare the latest reporting month, Aug 2026, with May 2026 – Jul 2026 (monthly average)". Short fixed titles
   that say the calculation, in two rows of three: Total Collections · Total Forecast · Collections as % of Forecast, then
   Collections Minus Forecast · Total Net Collections · Servicer Cost, % of Collections. (Average Monthly Collections was
   removed on 2026-10-12: the % on Total Collections already compares with the window's average month.) A Benchmark switch (Servicer, Accounting,
   Underwriting) picks the forecast; the servicer comparison is like-for-like.
   **Number standard (2026-10-12), everywhere on the dashboard:** currency to 2 decimals, in millions on cards and charts
   (€32.64M, −€0.85M ▼ €2.73M) and in full euros in tables (€5,743,779.12, so a download stays in euros); per-case figures
   in euros and cents (€78.21); counts as whole numbers; % and points to 1 decimal. Sigma formats cannot scale, so card and
   chart euro figures are stored ÷ 1,000,000 (tests read them back in euros).
   (The to-date total lives in the chart's Cumulative view.) The Comparison Window defaults to L1M on Portfolio and
   L3M on Cases (the user's choice); §2 Performance and Data Quality keep their own Window (This month · LM · L3M · L6M · L12M),
   which picks the months a table covers. Beneath them, the trend once (the user, 2026-10-11): **Collections vs Forecasts**,
   collections as a solid near-black line up to the selected month and all three forecasts as dashed lines (servicer violet,
   accounting green, underwriting periwinkle) running **12 months past** it, whatever the Benchmark and Window. Monthly or
   Cumulative. Hover: one box per month with every figure, whichever line is hovered: collected, each forecast with collections as a % of it (servicer like-for-like), and the portfolios reporting, each once: the four lines are hidden from their own hover (2026-10-12; Collections showed twice). Future
   months convert at each currency's newest rate; the forecast ahead covers the portfolios owned at the selected month. Beside
   it nothing: the Month by Month table was removed on 2026-10-12 (the chart's data downloads with every figure), so the chart runs the full width.
2. **Performance.** §1's cards by group (2026-10-12): a Grain switch (Country, Servicer, Seller, Deal; Servicer from deal
   source and country: Massey organic UK, Fire organic Italy, Gescobro organic, legacy or Gescobro-sourced Spain, Cerved legacy
   Italy, Intrum the rest), its own Comparison Window (Average Monthly), L1M · L3M · L6M · L12M, default L1M, and its own
   Benchmark (Servicer, Accounting, Underwriting; independent of §1's, 2026-10-12) for the forecast columns. Every card is a
   column showing the group's latest reporting month, followed by its change against the window: the group's window total ÷ the
   window's months (a missing portfolio-month counts as 0), blank only when no portfolio in the group has every month of the window (Sigma: Max of months_in_l{n}m_window at the latest month; the artifact counts the same way)
   (% for money, points for
   ratios, euro for the gap), green when better and red when worse. Any header sorts; it opens on Total Collections.
3. **Full breakdown.** One flat table, one row per portfolio, with every grain and every metric,
   including collections as % of each of the three forecasts, and no bar column. Grains run Country · Servicer · Seller · Deal · Portfolio (every deal has exactly one seller). Click a column to sort.

**Cases**

1. **Overview.** The book first: three executive cards (Cases on Book, Ever Collected, Ever Collected % of Book; Never Collected removed 2026-10-12), title and number only, read at the latest reporting month (2026-10-12). Then the eight tiles in two shared white boxes (the user, 2026-10-13), no box per card, four equal cards each (a container grid of `repeat(4, 1fr)`): Collected Cases · New · Fresh · Lost, then Three Consecutive Months · Collections · Avg Monthly Collection per Case · Net Change in Collected Cases. Five across was tried and rendered: titles cut to "…" and every % lost its decimal, so a card needs a quarter of the page. Then one bar chart with three tabs (2026-10-13), Sigma's legend on the right: click a behaviour to highlight it, several at once. **Count** and **Collections** stack four paying groups that split each month's collected cases exactly, so a bar is the month's total, written over it (cases; euro as €X.XXM): New dark green (first payment ever), Fresh light lilac (#C4C9FA since 2026-10-14; the lavender was invisible when highlighted) (back after two quiet months, had paid before), Two of Three Months light purple (paid in one of the two months before, not both: dbt's jitter in plus second month running, the group dbt never counts), Three Consecutive Months violet at the base (colours set by the user, 2026-10-13). **Lost** is red and below zero: those cases did not pay this month (their euro is what they paid in their last paying month). New and Fresh never overlap: Fresh is dbt's new minus New, on the card as on the chart (the user, 2026-10-13). Two of Three Months' euro is the rest of the month's collections from cases, so it also carries refunds and reversals on cases that netted to zero or below. **Average Collection per Case** sets the same groups side by side, against All Collected Cases (deep green): each is its collections ÷ its cases. The number over each bar is the month's collected cases or collections from cases, never netted by Lost. Titled "<tab> over Months". Hover a segment to read it; on **Count** the hover adds Feed portfolios (n reconciled). Renamed for the manager (2026-10-12): dbt's first collection is **New**, dbt's new (back after two quiet months) is **Fresh**. Balance is not in the cases mart, so it has no tab. One Comparison Window (Average Monthly) toggle, L1M · L3M · L6M · L12M, default L3M. Net Change compares as a difference in cases, never a %; any % comparison with a zero or negative base is left blank (2026-10-13). Every card shows the latest reporting
   month; the % compares it with the month before or the average month of the window (over the months WITH a case feed:
   summing case counts across months would count the same case twice). Average Monthly Collection per Case compares with the
   window's euro ÷ its cases. The Overall Summary band says "Monthly snapshot as of the latest reporting month, Aug 2026"; the
   Case Behavioural Summary band carries the line naming the months compared (it replaced the line under the toggle). The book tiles are stocks,
   read at the latest reporting month. Each tile's (i) note defines its behaviour, so there is no key table.
2. **Performance.** §1's eight behaviour cards by group, each the latest reporting month followed by its change against
   the Comparison Window (Average Monthly), L1M · L3M · L6M · L12M, default L3M (months with a case feed). The Overall Summary
   stocks are not in it. Any header sorts.
3. **Full breakdown.** One row per portfolio: every behaviour, in counts and euro.

**Data Quality** (added from the manager's review, 2026-10-09)

Its own Window (This month … Last 12 months), counted by row month so a portfolio counts if it reported in any month
of the window. Four cards: Share of Collections Reconciled (with the change in points against the window before) ·
Collections Not Reconciled · Case Feeds Stopped · Month Still Loading. Then **By Servicer** (who to chase: portfolios,
with a case feed, reconciled, share reconciled, euro not reconciled) and **By Portfolio** (largest euro not reconciled
first, with the Data Status sentence). Both tables add up to the cards.

Jitter in and out and Vehicle were removed from every page in the same review; the query and the definitions still carry them.

**Titles are in Title Case.** Element titles, column headers, row headers, control labels and headings
capitalise every main word ("Collections as % of Forecast", "New vs Lost"); minor words (of, as, vs, by...) stay
lower unless first or last. One function does it, `title_case()` in `sigma_build/build_workbook.py`, mirrored as
`TC()` in the mock; values (statuses, toggle options like "Last 3 months") are left as they are. A chart plots its
named columns directly, never Sigma's auto `Sum()` wrappers, which surface as "Sum of % of forecast".

**Labels say what they mean.** No shorthand on screen: "Collections", not
"Collected €"; "Last 3 months", not "L3M". The short codes survive only as search aliases in the
definitions, and as column names in the query, where the data team expects them.

**Vocabulary is the dbt mart's**: `collected_cases_*` for what cases did in the
month, `cases_*` for the book. Nothing is called a payer.

## 3. Palette and type

Brocc's brand, from `design/reference/Example Slides.potx` (its theme) and NPL Portfolio Dashboard v2's current settings:
deep green carries the header on a white page, periwinkle and violet are the accents. Charts use colours that
mean something: green for actuals, violet for the forecast, and green and red only for ahead and behind.

| Token | Hex | Job |
|---|---|---|
| Deep green | `#012E26` | Header band, figures, headings |
| Green | `#1D5B4D` | Actuals line, selected toggles, table headers |
| Violet | `#4F3DFF` | The forecast line; data-bar dark end; highlight |
| Periwinkle | `#A6ADF8` | Data-bar light end, secondary series |
| Lavender | `#E4E7FC` | Soft fills, highlighted rows |
| Lilac | `#C4C9FA` | Fresh segment on the Cases chart |
| Lavender 50 | `#F7F8FE` | Group subtotal rows |
| Lime | `#D8E494` | Subtitle on the dark band |
| Grey-green | `#5C6B66` | Labels, captions |
| Border | `#DCE3DF` | Card borders, axes |
| White | `#FFFFFF` | Page background and every card |
| Orange | `#D97706` | Data-quality notes only |
| Green (status) | `#2E7D32` | Ahead of benchmark |
| Red | `#C62828` | Behind benchmark; lost cases |

**Font: FFF Acid Grotesk**, bold for every heading (its regular weight is Light, so a plain heading reads thin), Brocc's brand font, by the name Sigma knows it (the NPL workbook uses
it). Sizes as NPL v2: element titles 16 bold, table headers 12 bold, cells 13, presentation tables
with horizontal grid lines, large spacing, round corners. The theme is `design/sigma_theme.json`.
The mock names the font first and falls back to Inter: it renders on any machine with the font
installed (Brocc laptops have it in /Library/Fonts); the licensed files are never embedded.

## 4. How each visual is built in Sigma

Every visual in the mock has a Sigma equivalent. Where Sigma cannot do something
the mock was changed to match, not the other way round.

| In the mock | In Sigma |
|---|---|
| Header | White sticky header panel: the title, then one line of seven filters (Reporting month, Country, Servicer, Seller, Deal, Portfolio, Reconciliation) and Clear Filters, each 3 of the 24 columns (2026-10-12; Sigma fixes a header at 24 columns) (control labels cannot be recoloured, and a header is at most 8 rows). The dark band with the four status tiles opens each page as a Blue 900 container |
| KPI with sparkline | `kpi-chart` with a date axis and hover values; comparison colour green/red. The trend is a **line**: Sigma drops a KPI's gradient once it has a comparison |
| Tile comparison | Each tile is a pill-cornered white box holding the KPI with its own (static) comparison label hidden, so it shows the change alone: % for money and counts, points for percentages, euro for the gap. One line above the tiles names the windows: "The Tiles compare May 2026 – Jul 2026 with Feb 2026 – Apr 2026". (A line under every tile was tried and removed by the user on 2026-10-09.) |
| Window / Compare toggles on a KPI | Segmented controls driving `Switch()` columns on the KPI's source |
| Collections vs Forecasts (solid + dashed lines, 12 months ahead) | `combo-chart` on its own source `fc_src` (`sigma_queries/forecast_chart_element.sql`, the live query prepended as `main`): Actual rows plus, per anchor month, 12 Ahead rows; the Reporting month filter targets `anchor_month` and the chart keeps the newest anchor's Ahead rows (`GrandTotal(Max(anchor_month))`). Dashes per line via `seriesLineAreaStyle`; colours by the theme's list order |
| Forecast behind collections | Series are listed forecast first, collections last, so collections draw in front; series take the theme's colours in list order, so the scheme starts violet, then green |
| Dashed forecast line | Series with `lineAreaStyle.line.style: dashed`, Orange |
| Hover detail | Sigma's tooltip, with the extra tooltip columns listed in the build map |
| Performance by grain | A grouped **helper** table on the hidden **Model** page (grouped by a Grain `Switch()` column, one column per metric), and a visible child table sourced from its grouping. The child shows exactly one row per group — no repeated group rows, no subtotal clutter |
| Full breakdown | The same pattern grouped by country, servicer, seller, deal and portfolio: one flat row per portfolio |
| Cases chart: four paying groups that tally to collected cases, Lost below zero, totals over the bars; an Avg tab side by side | A `bar-chart` per tab on its own source `cb_src` (`sigma_queries/case_behaviour_element.sql`, the live query prepended as `main`: one row per portfolio-month-behaviour, six behaviours: the four groups, Lost negated, and All Collected Cases). Count and Collections are stacked with `dataLabel.totals.display: "shown"` and an element filter excluding All Collected Cases; Avg is `stacking: "none"`, value `Sum(case_amount) / Sum(case_count)`. Coloured by the behaviour column with `color.customColors`; Sigma's own legend on the right highlights one or several. Every header filter targets `cb_src` too. Sigma orders behaviours alphabetically (stack with the last at the bottom), so zero-width lead characters in `cb_src` set the order: Three Consecutive Months the base, then Two of Three Months, Fresh, New; Lost last in the legend. Sigma's bar total adds every segment, Lost too, so a white spacer worth +Lost sits on top of each stack (a value named a single space, white: Sigma's legend leaves a blank value out; a named "(Ignore - Formatting)" entry showed in the legend and was dropped) and the total reads the month's figure. Bar totals use the value's format, €X.XXM: Sigma has no format that switches to K for small bars, so a filter down to a portfolio under €5k a month reads €0.00M (the artifact switches) |
| Count / Collections toggle on the Cases chart | A `tabbed-container` with two tabs, one chart in each, each with its own y-axis title (`yAxis.format.title`) and number format; the chart titles are hidden |
| Data Quality window | Every figure is `Sum(If(in window, x))`, where "in window" is the row's month distance from `GrandTotal(Max(reporting_month))`; the KPIs have no timeline |
| Gradient bars in tables | Data bars, periwinkle → violet, in their **own column with the value label hidden** (`valueLabels: hidden`), beside the number: dark text over violet was unreadable |
| Performance text colours | `fontScale` per column, text only: red (worst) → grey → green (best), flipped where lower is better (servicer cost, lost). % of forecast pivots on 100% (domain 80%–120%), collections minus forecast on €0, so one outlier cannot repaint the column |
| Previous-window comparison | Each KPI's `comparisonColumn` is a `Switch()` over window totals: L6M − L3M for Last 3 months, L12M − L6M, L24M − L12M, L2M − L1M for Previous month. The query carries the L2M and L24M windows for this |
| Headline sentence | Text element. ⚠ A text `{{ }}` reference resolves only to a **raw Custom SQL column**, never a calculated one — so the figures come from a one-row "Headline" Custom SQL element that reads the Reporting month control |
| Behaviour key | Removed (the manager's review): the tiles' (i) notes define each behaviour |

## 5. Where each calculation lives: SQL or Sigma

**The rule: Sigma unless correctness needs the SQL.** Sigma compiles its calculated
columns into SQL and pushes them to the same Snowflake, so there is no speed to
gain by moving arithmetic into the query — measured: the eleven SQL windows cost
0.84s of a 5.17s query, and moving them would not recover it. What decides is
whether the calculation is still **correct after a viewer filters the page**.

| Lives in the query (SQL) | Why it cannot be Sigma |
|---|---|
| Euro conversion | Needs each row's own currency and month rate before anything is summed |
| L1M / L3M / L6M / L12M windows and cumulative, for collections, all three forecasts and the case behaviours | A Sigma aggregate recomputes over the **visible** rows: filter to June and an L12M silently becomes "the visible months". The SQL window always means twelve real months |
| Months in each window | The divisor must count months that exist, independent of filters. Cases get their own count: months **with case data**, since some portfolio-months have collections but no feed |
| Latest forecast version | The forecast facts are not deduped upstream; every restatement would count again |
| Last complete month guard | A month still loading (September: 4 portfolios against 264) must never reach a tile |
| Reconciled flag, like-for-like flags, feed-stopped flag | Row-level comparisons of two feeds |
| Case euro amounts | Converted at the portfolio-month's rate, like collections |

| Lives in Sigma | Why it is better there |
|---|---|
| Every sum, and every ratio as sum ÷ sum (vs forecast, cost %, reconciled %, € per case, ever collected % of book) | Recomputes correctly for whatever grain and filter the viewer picks; never averages a ratio |
| Window **average** = window sum ÷ months in window | Division at the chosen grain |
| Gap to forecast (€) | Collections − forecast at the chosen grain |
| Benchmark, window, metric and grain switches | Pure presentation: Switch() over existing columns |
| Grouping, subtotals, pivots, sorting | Native, and fast |

## 6. Asking the dashboard what is going on

Three routes, all built from **one** file, `docs/definitions.csv`, so they can never disagree:

- **The Data & Definitions page** — every term, searchable, with its formula, where it is
  computed and what to watch out for.
- **The Sigma agent** — a workbook agent ("Servicing analyst") whose instructions are
  `docs/SIGMA-AGENT.md`: the definitions, the five reading rules, and an instruction to say
  what is solid and what is shaky. People ask it "why is August below plan?" in the workbook.
- **`docs/DATA-DEFINITIONS.md`** — the same page for anyone reading the repo, or Claude.

Names follow the dbt mart (`collected_cases_*`, `cases_*`) and say what they hold
(`_sum`, `_count`, `_flag`, `_l3m_sum`, `months_in_*_window`), so a column is readable
without a lookup. One legacy name remains: `collected_cases_consistent_3m_count`, which the
live workbook reads; everything new uses the mart's `three_consecutive_months`. Rename it
when the workbook is rebuilt, not before (renaming a column the live tiles read breaks them silently).

## 7. Review checklists

**Data engineer**

- [ ] `sigma_queries/portfolios_element.sql` — reads PROD only; adds accounting + underwriting forecasts (latest version) and their windows, case € by behaviour, jitter out, and case L1M–L12M windows. Every existing column is unchanged (tested row by row)
- [ ] `uv run python work/servicing/tests/run.py` — 106 checks, under a minute; `--as-of 2026-06` back-tests
- [ ] `uv run python work/servicing/tests/mutation_test.py` — 8 deliberate mistakes: 7 caught, 1 dormant and guarded
- [ ] `docs/DATA-DEFINITIONS.md` — one definition per term; the dashboard and the Sigma agent are generated from the same CSV
- [ ] `tests/TEST-CASES.md` — what each check proves
- [ ] Section 5 above — agree what stays in SQL

**UI**

- [ ] The design link, both pages and the build map
- [ ] Section 3 — palette and font
- [ ] Section 4 — every visual has a Sigma build
- [ ] Executive read: can the CEO answer "are we on plan?" without touching a control?
