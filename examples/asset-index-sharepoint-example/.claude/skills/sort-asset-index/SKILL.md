---
name: sort-asset-index
description: Sorts an asset-index delivery in asset-index-sharepoint-example into <VEHICLE>-<DEALID> folders. Use when seller tapes, benchmark files or servicer deliveries land in raw/ and need splitting per deal. Finds each file's deal ids, looks the vehicle up in the warehouse rather than guessing it, loads everything that exists except forward-flow samples, and writes a YAML summary, grouped by deal, saying what happened and why.
---

You sort deliveries in this folder. Nothing else.

    raw/      what landed. READ ONLY -- never move, rename or delete anything here.
    sorted/   what you produce: one <VEHICLE>-<DEALID> folder per deal.
    queries/  portfolio_exists.sql -- the existence check.
    relevant/ the pick that follows the sort; see relevant/README.md.

Copy, never move. `raw/` is the only record of what was delivered, and a sort
that turns out wrong has to be re-runnable from it.

---

# The six steps

## Step 1 — Find the deal ids

Walk `raw/`. Every file belongs to one or more deals, and the id comes from one
of two places:

**The folder name.** `raw/<tree>/PT15016/...` -- the deal is `PT15016`, and the
whole folder belongs to it.

**A `portfolio_id` column.** Benchmark files such as
`SE26XXX_BMK_accounts_*.xlsx` span many deals at once. Read the column and take
its distinct values; one file can produce fifteen deal ids.

Collect every distinct id across the whole delivery before going on. You run
the check once, not once per file.

## Step 2 — Ask the warehouse what each deal is

Put the ids into `CANDIDATES` in `queries/portfolio_exists.sql` and run it once:

    python scripts/run_sql.py queries/portfolio_exists.sql --connection dev --warehouse DEV_WH

It returns, per deal and per source, the **vehicle**, **seller**, **flow type**,
a **unit count** and a **verdict** of `FOUND` or `NOT FOUND`. A deal can come
back from both sources, so expect two rows for some.

**Never guess the vehicle from a filename or a folder.** It is a fact in the
warehouse: `DIM_BATCH.DEAL_SOURCE_BK` is `HEI` on 11,485 batches but `LOK` on
248, `LEG` on 60 and `GCB` on 10. SE25008 and SE25037 are `LOK`.

## Step 3 — Pick the folder name

The folder is `<VEHICLE>-<DEALID>`, and when a deal is in both sources this is
the tie-break:

| Where it was found | Folder name comes from |
|---|---|
| Both sources, and it is a **Heimdall** deal | **`DIM_BATCH`** vehicle + deal id |
| Both sources, anything else | **`DIM_PORTFOLIO`** vehicle + deal id |
| One source only | that source |

So `HEI-PT08018` from `DIM_BATCH`, `LOK-SE25008` from `DIM_PORTFOLIO`.

## Step 4 — Decide: load or not

**Everything that exists loads, except a forward-flow sample.**

| Verdict | Flow type | Sample? | Load |
|---|---|---|---|
| `FOUND` | Forward | **yes** | **no** |
| `FOUND` | Forward | no | **yes** |
| `FOUND` | One-off | either | **yes** |
| `FOUND` | Forward | *looks like* a sample | **flag, ask** |
| `NOT FOUND` | — | — | **no** |

The rule applies the same whether the flow type came from `DIM_BATCH` or
`DIM_PORTFOLIO`. A forward flow delivered as a partial file tells you neither
the book nor the month, which is why that one combination is refused.

### Deciding "sample"

**The filename says so** -- `sample`, `amostra` (pt), `muestra` (es),
`urval` (sv) anywhere in the name. That is a sample. No further checking.

**It looks like one** -- the row count is well short of the deal's `cases`
from the check. **Do not decide this yourself: flag it and ask.** Set
`sorted: null` and say what you measured.

⚠ **Sum every file for the deal before judging.** A forward flow arrives as one
file per monthly tranche -- PT20014 is 43 files, PT21004 is 37. Reading only the
largest shows 8% and reads as a sample; the 43 together come to 117%.

## Step 5 — Sort, flat

Copy into `sorted/<VEHICLE>-<DEALID>/` with **every file directly in that
folder. No nested directories.** A deal folder is a flat list of files,
whatever shape the delivery arrived in.

For files split on a `portfolio_id` column, keep the original filename and
write only that deal's rows.

**Collisions are the one risk of flattening.** Two deliveries can hold the same
filename, and a flat copy would silently overwrite one with the other. Before
writing, check whether the name is already taken in that deal folder:

- **free** -- write it as is.
- **taken** -- prefix with the delivery folder's basename and a double
  underscore: `swedish BMK + NORION__accounts.xlsx`. Never overwrite, never
  append a bare `(1)`, which says nothing about where the file came from.

Report every rename in the summary, so a reader can tell a prefixed name is a
collision and not part of the original filename.

### Partitioning is not enough -- filter the contents too

Putting a file in a deal folder does not make it that deal's data. **If the file
covers more than one deal, filter its rows to that deal before writing it.** A
folder named for one deal holding every deal's rows is worse than no folder: it
reads as scoped and is not.

This applies to any partitioning column, not just `portfolio_id`:

| Delivery | Partition on | Note |
|---|---|---|
| benchmark files | `portfolio_id` | the obvious case |
| a tape covering several countries | country or currency | one deal per country |
| any file whose rows span deals | whatever identifies the deal | find it before copying |

**Find the column before you trust a name.** On the Ember tape, `Market` looks
like the country column and is `Business` on all 14.8m rows; the real split is
`GoverningLawofLoanAgreement`, which maps 1:1 to `Currency` (SEK/NOK/DKK/EUR).
Count the distinct values first -- a column with one value is not a partition.

**Split every file in the set on the same key.** Ember has three tapes; two
carry no country column but all three carry `Currency`, so all three split
without a join. A deal folder with a filtered loan tape and an unfiltered
payment tape is still wrong.

**Check the row counts balance.** Rows in must equal rows out summed across
deals, with unmatched reported, or something was silently dropped.
`scripts/split_by_deal.py` does the split and that arithmetic together, and
refuses a key with a single distinct value.

**Then delete the unsplit original** from the deal folders. Leaving it beside
the filtered files means somebody reads the wrong one, and it is usually the
largest file there -- carrying Ember's 918 MB zip into four folders cost 3.5 GB
to say nothing true.

Write large splits gzipped (`.csv.gz`); the source was compressed and the
filtered output is often bigger uncompressed than the archive it came from.

**Summary and pivot files** -- a delivery sometimes holds a pivot rather than
data (`SE26XXX_BMK_accounts_Brocc 4.xlsx` is `portfolio_id` / `seller_name` /
count). Split it like anything else, but write it as CSV with `_PIVOT_SUMMARY`
in the name, and keep the `Grand Total` row beside the deal's own row. Left
under its original name it reads as accounts data and gets summed as such.

Exclude `.DS_Store` and Excel `~$` lock files from every copy.

## Step 6 — Write the summary

`sorted/_summary.yaml`, **grouped by deal, not by file** -- a reader should be
able to scan one block per deal and see what happened. Report the same content
back.

```yaml
run: '2026-10-22'
delivery: Sweden Benchmarks
summary:
  deals_seen: 15
  sorted: 10
  refused: 5
  files_written: 94

sorted:
  HEI-SE16004:
    deal: SE16004
    vehicle: HEI
    seller: Ikano Bank
    found_in: [DIM_BATCH]
    flow_type: Forward
    files: 8
    deliveries: [OneDrive_1_6-10-2026, swedish BMK + NORION]
    renamed: []
    reason: forward flow but not a sample

  LOK-SE25008:
    deal: SE25008
    vehicle: LOK
    seller: Santander Consumer Bank
    found_in: [DIM_PORTFOLIO]
    flow_type: One-off
    files: 8
    deliveries: [OneDrive_1_6-10-2026, swedish BMK + NORION]
    reason: exists, one-off

refused:
  SE25016:
    seller_per_file: Entercard-SE25
    files: 6
    deliveries: [Swedish BMK fix - 2026_05_26, swedish BMK + NORION]
    reason: NOT FOUND in either source
```

Four things make it scannable, and all of them matter:

- **The key is the folder name**, so the YAML reads in the same order as the
  directory.
- **`found_in` is always a list**, so one source versus both is visible at a
  glance.
- **`deliveries` uses the folder's basename**, not its full path -- full paths
  wrap and the block stops being readable.
- **Refused deals carry `seller_per_file`**, taken from the delivery rather
  than the warehouse, because that is the only identifying thing left. Without
  it a refusal is an id and nothing more; with it, somebody can recognise
  `Entercard-SE25` and say whether we hold that book.

`reason` is filled even when a deal sorted -- a summary that only explains
refusals cannot be audited. Use `sorted: null` on a deal you flagged rather than
decided, never "skipped quietly".

Finish by stating the numbers: files read, rows in versus out for column-split
files, and the null `portfolio_id` count.

---

# Traps

**An environment variable can pin the wrong warehouse.** A tool like mise
re-applies its own `SNOWFLAKE_WAREHOUSE` inside a subprocess and silently wins,
so `scripts/run_sql.py` takes the warehouse as an argument instead:

    python scripts/run_sql.py queries/portfolio_exists.sql --connection dev --warehouse DEV_WH

`portfolio_exists.sql` is written for `PROD.NPL_COMMON`. On a share such as
brocc-sandbox, swap it for `PROD_NPL_COMMON.NPL_COMMON`.

**`NOT FOUND` is not proof we do not own it.** Our deal id and the servicer's
can differ -- our SE25008 is Intrum's SE25018. Report the seller name from the
file so a person can check, and never create a folder on a hunch.

**Deal ids are not unique across countries.** `CH21009`, `FI21054` and
`UK25013` share digits with Swedish ids and are unrelated. Compare full ids.

**One book can arrive under two ids.** SE25008 and SE25018 are the same
Santander portfolio, and benchmark files carry both as separate `portfolio_id`
values. Sorting splits one book across two folders -- say so in the summary
rather than merging them.

**A deal in both sources can show two sellers.** IT24013 is `Gruppo Banca
Popolare dell'Emilia Romagna` in `DIM_BATCH` and `BPER Banca` in `DIM_DEAL`.
Same company. Do not treat it as a conflict.

# Never

    move or delete anything in raw/     it is the only record of the delivery
    assume the vehicle                  look it up; SE25008 is LOK, not HEI
    create a folder for NOT FOUND       report it; an empty-but-present folder
                                          reads as a book we hold
    decide "looks like a sample"        flag it with the numbers and ask
    judge a sample on one file          sum the deal's files first
    rename a summary file as data       it will be summed as if it were loans
