# Servicing dashboard

The Sigma dashboard the CEO and the Head of Servicing use to answer **"are we
collecting what we planned?"** and, underneath, **where the gap comes from**.

| | |
|---|---|
| **Live workbook** | [Servicing Dashboard](https://app.sigmacomputing.com/brocc/workbook/5OHD9y2g5PaMr3pJqvLV9) · `031548ab-54d6-437f-b452-e728c30cfb5b` · built by `sigma_build/build_workbook.py`; hand edits made in Sigma are kept in `sigma_build/user_edits.json` |
| **Design** | [Servicing Dashboard Redesign](https://claude.ai/artifact/5SyvnqmbvMYyfhYaWjY9tm) (a mock of the live dashboard) · source in `design/` · explained in [`docs/DESIGN.md`](docs/DESIGN.md) |
| **Tests** | `uv run python work/servicing/tests/run.py`: 381 checks in 9 suites · `--only 'live.chart_*'` runs just the checks one change touches, every one listed in plain English in [`tests/TEST-CASES.md`](tests/TEST-CASES.md) · `tests/mutation_test.py` proves they catch real mistakes · `tests/stress.py` exports every tile under every toggle and awkward filters and flags impossible values (~15 min) |
| **Definitions** | [`docs/DATA-DEFINITIONS.md`](docs/DATA-DEFINITIONS.md): every term, generated from `docs/definitions.csv` |
| **Case study** | [`case-study.md`](case-study.md): the dashboard walkthrough pitch: click by click from the whole book to the problem deals and why they are behind (fewer payers, paying less, not replacing) |
| **Insight** | [`insight-heimdall.md`](insight-heimdall.md): one finding proved click by click: Heimdall's Germany and France are €4.2M behind plan this year, for different reasons (France not replacing payers, Germany's payers paying less) |
| **Retired** | "Servicing Dashboard (retired 2026-10-09)" `77cac618-…`: the previous design, correct figures · "(retired 2026-10-08)" `65a9392f-…`: wrong figures, do not use |

## 1. Files

```
work/servicing/
├─ README.md                               start here
├─ case-study.md                           the dashboard walkthrough pitch, click by click, with August 2026's findings
├─ insight-heimdall.md                     one finding, click by click: Heimdall Germany and France behind plan, and why
├─ docs/
│  ├─ DESIGN.md                            what each page shows and how each visual is built in Sigma
│  ├─ HOW-IT-WORKS.md                      architecture, debugging, every Sigma API rule learned the hard way
│  ├─ definitions.csv                      THE definition of every term: edit here only
│  ├─ build_definitions.py                 turns the CSV into the three files below
│  ├─ DATA-DEFINITIONS.md                  the data definitions page (generated)
│  └─ SIGMA-AGENT.md                       instructions for the workbook's Sigma agent (generated)
├─ sigma_queries/
│  ├─ portfolios_element.sql               the one query the live dashboard runs (a check proves it is identical)
│  └─ retired/portfolios_element_v1.sql    the retired dashboard's query: the regression baseline for suite 1
├─ sigma_build/
│  ├─ build_workbook.py                    builds the whole workbook: query, theme, definitions, layout, agent
│  ├─ user_edits.json                      hand edits made in the Sigma editor, applied last on every build
│  ├─ contents.json, element_ids.json      what was sent (generated)
│  └─ workbook.json                        which workbook the build and the live tests point at
├─ design/
│  ├─ project/                             the design mock (Main = Portfolio + Cases + Data Quality + Data & Definitions, Build = Sigma build map)
│  └─ sigma_theme.json                     the workbook theme: FFF Acid Grotesk, Brocc's brand palette
└─ tests/
   ├─ run.py                               one command for every check
   ├─ TEST-CASES.md                        every check and what a pass proves (generated: run.py --doc)
   ├─ stress.py                            ~620 live exports, every toggle and odd filter, flags impossible cells
   ├─ dipstick.py                          random filter combinations, each recomputed from the query (seeded)
   ├─ verify_case_behaviour.sql            the dbt cases mart's behaviours rebuilt without window frames (check cases.mart_logic_recomputed)
   ├─ suites/s1_structure.py … s9_controls.py   one file per topic
   ├─ mutation_test.py                     breaks the query on purpose; every mistake must be caught
   ├─ _lib.py, design_sweep.js             plumbing
   ├─ results.csv                          every run appended: the drift history
   └─ history/                             earlier logs
```

Retired files are in `../.archive/`, each folder with a note on why.

## 2. The figures, Dec 2025 – Aug 2026

264 portfolios, 1,839 portfolio-months, 62 deals from 49 sellers. August is the newest
complete month (September is still loading). Source: `sigma_queries/portfolios_element.sql`
run against PROD on 2026-10-12 (the case mart and the reconciliation flags were restated overnight on 2026-10-11/12); every figure is re-checked by `tests/run.py`.

| Collections (EUR, each currency converted at its month's rate) | |
|---|---|
| Gross collections | **347,398,614.21** |
| Net collections | 253,021,690.03 |
| Servicer cost | 94,376,924.18 |
| vs servicer forecast (like-for-like: portfolios that have one) | **105.5%** |
| vs accounting forecast | 106.5% |
| vs underwriting forecast | 105.6% |
| Reconciled share (case feed agrees with the servicer report; Italy excluded by hand, 2026-10-14) | 40.3% |

| Cases (case-months, from the dbt mart) | |
|---|---|
| Collected cases | 1,945,587 |
| New (dbt first collection) · Fresh (dbt new minus New) · Lost | 603,634 · 79,699 · 184,279 |
| Jitter in · Jitter out | 140,613 · 328,466 |
| Three consecutive months | 767,850 |

## 3. How we know, and what we do not

**How the tests work.** Each check compares the dashboard with SQL written separately,
in the test, against the warehouse facts and the dbt mart. The dashboard side is either
the query's output or a tile exported from the live workbook. Since 2026-10-09 the live
exports can set controls, so suite 9 checks every Window, Benchmark and Grain the way a
viewer would set them, not only the defaults. See [`tests/TEST-CASES.md`](tests/TEST-CASES.md)
for every check, what it proves, and the known weak spots.

**How robust, honestly.**

- **They can fail.** `tests/mutation_test.py` makes eight realistic mistakes in the query
  (a window that includes the current month, the wrong exchange rate, a forecast on the
  wrong month, the wrong case divisor, a swapped column, a sign error, a leaked loading
  month, a dropped version filter). Seven are caught; the eighth cannot change any figure in
  today's data, and a check fails the day it could.
- **They look under the totals.** Collections and both plans match the facts on every one of
  the 1,839 portfolio-months, so money cannot move between portfolios or months unnoticed.
- **What they cannot catch.** A misunderstanding shared by the query and the test: both read
  the same facts with the same idea of what "collections" means. Nothing is checked against a
  servicer statement or the ledger. The reconciled flag itself is the query's own calculation;
  the tests check what is built on it, not the 10% rule that sets it.

**Limits: read before quoting a figure.**

- **Case figures are a floor.** Only Intrum and Massey portfolios send a case feed: 148 of 264 in August (146 Intrum, 2 Massey; measured 2026-10-12).
  A blank means no feed, never "nobody paid". A card shows the word "null" when the selection
  has no case feed at all.
- **Two feeds, two answers.** Quote collections from the Portfolio page and behaviour from the Cases
  page; never mix them on one card.
- **Like-for-like matters for the servicer forecast.** Some portfolios have no servicer
  forecast; counting their collections anyway overstates the % of forecast.
- **The newest month moves most.** August's first collections include a feed backlog.
- **Window starts are artefacts.** December 2025 is the first month, so every case looks New
  and none can be Lost; "Last 12 months" compares against an empty year.

## 4. Changing the dashboard

1. **Diff live first.** People edit in the Sigma editor. Before any rebuild, pull the live
   workbook and compare it with `sigma_build/contents.json`; move every hand edit into
   `sigma_build/user_edits.json` (element fields) or the builder's layout, or the push undoes it.
2. **Build a staging copy and test it.**
   ```bash
   uv run python work/servicing/sigma_build/build_workbook.py --dry-run                          # Sigma's verify; sends nothing
   uv run python work/servicing/sigma_build/build_workbook.py --create --name "Servicing Dashboard (staging)"
   uv run python work/servicing/tests/run.py --suite live                                         # against the staging copy
   ```
3. **Promote in place** (same link): `--update 031548ab-54d6-437f-b452-e728c30cfb5b --live`, run the
   full suite, delete the staging copy. The builder refuses the live id without `--live`.
4. **Never rename a source column**: child elements read `[Portfolios/Column Name]`, and a rename
   renders `Unknown column` as text, which reads as zero.
5. **Undo** is Sigma's Version history → Restore version as draft.
