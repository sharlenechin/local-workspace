# Sorting an asset-index delivery — a worked example

Seller tapes arrive from SharePoint as a pile of folders: one per deal
sometimes, one per delivery date other times, and often a single spreadsheet
covering fifteen deals at once. This folder is a small, complete example of
turning that pile into something you can load, **locally, from the files on
disk**. Nothing here uploads anything or touches a pipeline.

Everything in `raw/` is synthetic — made-up loans, made-up balances. The deal
ids and seller names are real internal identifiers, so strip them if that
matters where this is going. The structure, the queries and the scripts are the
real ones.

## The three folders, and the step after them

```
raw/        what landed. READ ONLY — never move, rename or delete anything here.
sorted/     one <VEHICLE>-<DEALID> folder per deal. Everything that was delivered.
relevant/   only the files you would actually load. A human decides this.
```

Then you map the tape, and the first thing mapping asks is which column joins to
Intrum. `queries/bridge_candidates.sql` answers that from the warehouse rather
than from column names — see **Choosing the bridge columns** below.

Copy at every step, never move. `raw/` is the only record of what was
delivered, and a sort that turns out wrong has to be re-runnable from it.

Why `sorted/` and `relevant/` are separate folders rather than one: the sort is
mechanical and auditable, the pick is judgement. Keeping them apart means you
can redo the pick without redoing the sort, and anyone can see which files were
delivered but deliberately not loaded.

## Running it

```bash
# 1. Which deals are in the delivery, and what are they?
#    Put the ids in CANDIDATES, then:
python scripts/run_sql.py queries/portfolio_exists.sql --connection dev --warehouse DEV_WH

# 2. Sort. This is the skill's job — open the folder in Claude Code and ask it
#    to sort the delivery; it follows .claude/skills/sort-asset-index/SKILL.md.
#    The one mechanical part has its own script:
python scripts/split_by_deal.py "raw/Sweden Benchmarks/swedish BMK + NORION/accounts.xlsx" \
    --key portfolio_id --vehicles HEI-SE16004 LOK-SE25008 --out sorted

# 3. Pick what to load, by hand. See relevant/README.md.

# 4. Before mapping the tape: which Intrum column can carry case_id, and which
#    counterparty_id? Put the deal ids in $deals, then:
python scripts/run_sql.py queries/bridge_candidates.sql --connection dev --warehouse DEV_WH
```

You need a `~/.snowflake/config.toml` profile, plus `pandas`,
`snowflake-connector-python`, `openpyxl` and `pyyaml`.

## What's here

| Path | What it is |
|---|---|
| `.claude/skills/sort-asset-index/SKILL.md` | The sort itself: six steps, the traps, and what the summary must say. This is the substance — the scripts are support. |
| `queries/portfolio_exists.sql` | Does the warehouse hold this deal, and what is its vehicle, seller and flow type? One row per (deal, source). |
| `queries/deal_vehicle.sql` | Just the vehicle, for every SE/PT/FI/GE deal. Useful when you only need the folder name. |
| `queries/bridge_candidates.sql` | Profiles every candidate key column in raw Intrum CAT per deal, and suggests which could be `case_id`, which `counterparty_id`, and which amount can verify a match. |
| `scripts/run_sql.py` | Runs a `.sql` file. Self-contained — no workspace imports. |
| `scripts/split_by_deal.py` | Splits a multi-deal file on a key column, and proves rows in = rows out + unmatched. |
| `sorted/_summary.yaml` | What a finished sort reports, grouped by deal. |
| `relevant/README.md` | How to pick, and the `_picked.md` note that records why. |

## Choosing the bridge columns

A seller's tape and Intrum share no account number. They are joined on the
seller's own reference, which Intrum keeps in `RAW.HYPERION_INTRUM_CAT.CASES` —
so before anyone writes a mapping, you have to know which column in that table
can carry the tape's `case_id`, and which its `counterparty_id`.

`queries/bridge_candidates.sql` measures it instead of guessing from names. One
row per deal and candidate column, with fill rate, how many cases share each
value, the value lengths, and a suggested role. Measured on four Portuguese
deals, it says:

| Column | Filled | What it is |
|---|---|---|
| `client_ref_1` | **100% on all four** | the key. 3–9 characters on two deals, 19 zero-padded digits on another |
| `ref_case_id` | 57–71% | clean but under-filled |
| `main_debtor` | 100% | a debtor **row number** on three deals, a real debtor id on the fourth |
| `client_number`, `master_cl_number` | 100% | 1–3 distinct values: client codes, not entity keys |
| `client_ref_2`, `client_ref_extra`, `debt_enforcement_number` | **0%** | empty on every deal |

Three things worth knowing before you use it:

**Intrum supplies no party key.** Every usable column holds about one value per
case. The borrower grain comes from the tape; `client_ref_1` is matched against
whatever the tape calls its counterparty. Don't go looking for a borrower column
in CAT — there isn't one, and a `counterparty_id` verdict is rare enough to
check by hand.

**`main_debtor` is the trap the query exists for.** Its average of 1.99 cases
per value reads as party-grained, which is exactly what you want — but the value
`1` sits on every case in the book, because it is a row number. The query tests
how much of the deal sits on the single commonest value before it reads any
average, and calls it out.

**Leading zeros are padding, not part of the reference.** One deal carries 16
digits on the tape against 19 in CAT and bridges at 0% until both sides are
stripped. The `collisions_if_unpadded` column proves stripping is safe before
you do it.

Columns no deal populates still get a row saying so. A column that vanishes from
the output reads as untested rather than as empty.

## The four things that go wrong

**Guessing the vehicle from the filename.** It is a fact in the warehouse, not
a naming convention. `DEAL_SOURCE_BK` is `HEI` on 11,485 batches but `LOK` on
248 — and SE25008, in this example, is one of the `LOK` ones. Step 2 exists for
this.

**Checking only one source.** `DIM_BATCH` and `DIM_PORTFOLIO` each hold deals
the other does not. SE25008 returns nothing from `DIM_BATCH` and is a real
deal. Run both or you silently drop live books.

**Filing a multi-deal file without filtering it.** Putting
`accounts.xlsx` in `HEI-SE16004/` does not make it SE16004's data. A folder
named for one deal that holds every deal's rows reads as scoped and is not,
which is worse than leaving it unsorted. `split_by_deal.py` filters and then
checks the arithmetic.

**Treating `NOT FOUND` as proof.** Our deal id and the servicer's can differ —
our SE25008 is Intrum's SE25018. The example refuses SE25016 and records
`seller_per_file: Entercard-SE25`, because the seller name is the only
identifying thing left for a person to check.

## What the example delivery exercises

Four deals sorted, one refused, from six files:

| Deal | How its id was found | Note |
|---|---|---|
| `HEI-PT15018` | folder name | tape + collections, copied as delivered |
| `HEI-PT16023` | folder name | tape only, no collections file |
| `HEI-SE16004` | `portfolio_id` column | 5 of 12 rows; second copy renamed on collision |
| `LOK-SE25008` | `portfolio_id` column | 4 of 12 rows; `LOK`, not `HEI` |
| `SE25016` | `portfolio_id` column | **refused** — not in the warehouse, no folder created |

It also covers the two file-level traps: the same filename arriving in two
delivery trees (prefixed `OneDrive_1_6-10-2026__` rather than overwritten), and
a pivot table that would be summed as if it were loan data (written as
`..._PIVOT_SUMMARY.csv`, with the `Grand Total` row kept).
