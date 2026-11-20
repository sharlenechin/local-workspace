# `dbt/` — the one model, mirrored from `brocc-data`

**`brocc-data` is the source of truth.** These two files are a copy of what sits
on branch `add/servicing-mart`, kept here so the design can be read and diffed
without opening the other repo. Re-synced **2026-10-06**; the SQL is
byte-identical as at that date.

| | |
|---|---|
| Model | `mart_npl_servicing_agg_cases_monthly` |
| In `brocc-data` | `transformation/dbt/models/marts/npl_common/marts/` |
| Branch | `add/servicing-mart` — raised, under review, **not merged** |
| In PROD | **no.** `PROD.INFORMATION_SCHEMA.TABLES` has no table of that name |

## What it is

One row per **(portfolio_sk, period_end_date)**, month-**end**: how the cases on
each book collected, and how much they collected in local currency. ⚠ **Counts only — no money, and no reconciliation.** Both
of those moved to Sigma on 2026-10-05, because a local-currency comparison is
meaningless on a portfolio-month carrying two currencies and two Polish books
carry three. Sigma compares in EUR, converting each currency before summing.

⚠ **It is not a dashboard backing table on its own.** It carries none of the
capex, GBV, carrying amount, balance, servicer cost, rolling-window or
cumulative columns the dashboard shows. Joined to `Portfolio Information` on
`portfolio_sk` it adds the collecting-case behaviour, and nothing else.

Scope, measured 2026-10-06: **1,296 rows across 164 of the 264 portfolios.**
It is driven from the case side, so the 100 books whose cases have never
collected are absent; the portfolio side `LEFT JOIN`s this, so an absent row
reads as *no case detail* rather than *no portfolio*.

## The six transition measures, as three months

Stated as **x-2 / x-1 / x**, where x is the row's own month:

| | x-2 | x-1 | x | |
|---|---|---|---|---|
| `collected_cases_first_collection_count` | – | – | **yes** | nothing before it at all |
| `collected_cases_three_consecutive_months_count` | **yes** | **yes** | **yes** | |
| `collected_cases_jitter_in_count` | **yes** | no | **yes** | back after one quiet month |
| `collected_cases_new_count` | no | no | **yes** | back after a longer gap |
| `collected_cases_jitter_out_count` | no | **yes** | no | one isolated month, then quiet |
| `collected_cases_lost_count` | **yes** | **yes** | no | was collecting, has stopped |

⚠ `jitter_out` and `lost` end in a month with **no** collection, so no row
exists to look back from — both are anchored on the case's last collecting
month and emitted one month forward. That is the only reason the behaviour CTE
is a `UNION ALL`. The other four describe a month the case did collect in.

⚠ `new` and `first_collection` **overlap**: a case's first collection in scope
satisfies both. Never add them together.

## ⚠ Four traps worth carrying

**Months are month-end, and every month step is wrapped in `last_day`.**
`dateadd` keeps the day number, so `2026-04-30` less one month is `2026-03-30`
and equals no month-end row. Measured without the wrapping, most months return
**zero**.

**A `RANGE BETWEEN` frame would work, and is deliberately not used.** Measured
2026-10-06 on a dense month-end series: its boundary lands on or before the true
previous month end every time, so it never misses one. It is rejected because it
answers *how many* of the last two months collected rather than *which* — so
`jitter_in` needs a second frame minus the first — and because it still cannot
reach the month **after** a case's last collection, which `lost` and
`jitter_out` are measured on.

**The capex floor is applied in the first CTE and never revisited.** It cannot be
a later filter: it changes what "the previous month" means, so it changes the
measures rather than just hiding rows. Measured on `HEI-PT25001-U02/2512` for
December 2025, `first_collection` is **9,967** with the floor and **339**
without.

**The three book counts are AS AT EACH MONTH, changed 2026-10-06.**
`cases_on_book_count`, `cases_ever_collected_count` and
`cases_never_collected_count` now move month to month — ever-collected reads
as a penetration curve and never falls. The old advice to take `MAX` is now
**wrong**; it would report the last month on every row. **No column in the model
is a portfolio constant any more** — `portfolio_latest_collection_month` was
dropped on 2026-10-06 and Sigma derives it. ⚠ The book count is **null, not
zero**, on 2 rows where the snapshot has no entry for that month.

⚠ `never` in `cases_never_collected_count` means **not as at this month**, not
never-in-the-end: a case counted in May may collect in June and leave the count.

**The two amount columns are local currency and are not money.** 20 of 1,252
portfolio-months hold two currencies. They are also **net of reversals and can
be negative** — one portfolio-month nets **-896,873.55**, being 6,070,595.83
collected against -6,967,469.38 reversed. Convert per currency in Sigma before
summing.

## What was verified, and what was not

Read-only against PROD on **2026-10-06**: the restructure into
`case_monthly_lagged_historical_collections` → `case_collection_behaviour` →
final was diffed row-by-row against the previous version — **all 11 measures
identical** on the 1,252 shared rows.

⚠ That first CTE does the month rollup and the lags **in one pass**: the
`group by` deduplicates a case that collected several times in a month, and the
window functions run after it, so they see one row per month. Measured
2026-10-06 that Snowflake also resolves the `collection_month` alias inside the
window specs, so the `last_day` is written once rather than five times. A
separate rollup CTE buys nothing.

The restructure also **added 44 rows**, all with `collected_cases_count = 0`:
months where a portfolio collected from nobody but cases were recorded as
stopping. The previous version built its month list from collecting rows only,
so it dropped those months and the losses in them — one book lost **3,180
`lost` and 917 `jitter_out`** in February 2026 that way. The new rows are a fix.

Earlier, on 2026-10-02: grain unique across the output; the "collected this
month" states partition the collecting population exactly, February included;
month-end matches `period_end_date` on 100% of 4.6m upstream rows;
`dim_npl_portfolio` as the baseline excludes **nothing** today.

⚠ **The table has never been built.** Nothing here has run `dbt run` — a local
build is blocked on a stale `prod-state` manifest and no `aws` CLI to refresh
it. CI's build step is the first real test, and it is what exercises the grain
test on the actual output.
