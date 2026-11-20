# Portugal asset index  -  can these loans be matched to our warehouse?

**Short answer: yes for 6 of the 12 deals, no for 6.** About **64% of the
Portuguese loans** (75,464 of 118,177) can be tied from a tape in this folder to
a case in production, loan by loan. The rest cannot  -  not because the match is
hard, but because those tapes never shipped the one column that identifies a
loan.

No new bridge table needs building. **The link already exists in the data**  -
it just isn't in any modelled table, so you have to read the raw Intrum feed to
get at it.

> Measured **2026-10-05**, by live query against production and by reading all
> 168 spreadsheets in `PT - Orange - Asset Index/`. The Intrum feed behind it was
> delivered **2026-01-14**.

---

## What matches, deal by deal

| Deal | Seller | Loans in prod | Matched | Coverage | Tape column that matched |
|---|---|---:|---:|---:|---|
| PT15016 | Barclays | 3,708 | 3,708 | **100%** | `acct` |
| PT15018 | Millennium BCP | 17,943 | 17,943 | **100%** | `Cliente Number` |
| PT15020 | Oney | 5,279 | 5,279 | **100%** | `Contrato` |
| PT18019 | WiZink | 29,976 | 29,912 | **100%** | `account` |
| PT16023 | Millennium BCP | 10,253 | 10,158 | **99%** | `Client Number` |
| PT15014 | Barclaycard | 7,317 | 6,730 | **92%** | `acct` |
| PT20014 | WiZink | 11,253 | 837 | 7% | `account`  -  only 3 of 43 files have it |
| PT19007 | WiZink | 13,506 | 881 | 7% | `account`  -  only 2 of 17 files have it |
| PT19013 | WiZink | 1,890 | 16 | 1% | `account`  -  only 2 of 29 files have it |
| PT20006 | WiZink | 5,574 | 0 | **0%** | no file carries `account` |
| PT21004 | WiZink | 8,757 | 0 | **0%** | no file carries `account` |
| PT20008 | Oney | 2,721 | 0 | **0%** | no loan identifier at all |
| | | **118,177** | **75,464** | **64%** | |

---

## How the match works

Every Portuguese loan reaches us through Intrum's collections system. Intrum
keeps the seller's own loan number  -  the credit-card number, the contract
number  -  in a field called `client_ref_1`. That is the same number the seller
printed on the diligence tape. So:

```
  tape column              Intrum feed            production
 +--------------+        +--------------+      +------------------+
 | acct         |        | client_ref_1 |      | DIM_CASE.CASE_SK |
 | Contrato     | =====> |              | ===> |                  |
 | account      | match  | case number  | 100% | CASE_BK          |
 | Cliente No.  |        +--------------+      +------------------+
 +--------------+
   the seller's             the only field        the warehouse's
   own reference            carrying both         own identifiers
```

**The second hop is not the problem.** Every Intrum case reaches production:
118,153 of 118,177 land in `DIM_CASE`, a 99.98% hit. Only 24 loans fall out.

**The first hop is where deals succeed or fail.** It works only if the tape
printed the seller's loan reference.

### Why production can't do this on its own

`DIM_CASE.CASE_ID` is a 32-character hash like `c4a235c9f431f2d7...`. It is
built from Intrum's internal case number, and it carries nothing a seller would
recognise. `CASE_BK` is `4050-8209025`  -  Intrum's own numbering. **Neither
contains the seller's loan reference**, and `client_ref_1` is not carried into
any modelled table. It survives only in the raw feed.

That is the one real gap: the link exists, but it stops at the raw layer.

---

## The six that don't match, and why

**PT20006, PT21004  -  WiZink, 14,331 loans.** Their tapes carry
`reference_number` (a 5-6 digit number like `127363`) and `client_number`.
Neither is the loan's account number. Every other WiZink deal that matched did
so on a column called `account`, holding a 19-digit number like
`0008424030901259356`. These two deals have no such column in any of their 57
files.

**PT19007, PT19013, PT20014  -  WiZink, partly.** Same story, but a handful of
files do carry `account`, and those files match at 99%. The other 86 files carry
only `reference_number`. The method is proven on these books  -  the data is just
missing from most of the files.

**PT20008  -  Oney, 2,721 loans.** Its only candidate column, `ID Base cessão`,
contains `1, 2, 3, 4, 5...`. It is a spreadsheet row number, not a loan
identifier. The sister deal PT15020 shipped a real `Contrato` column and matched
100%, so this is a one-off gap in what Oney delivered.

### Two routes that were tried and do not work

**`client_ref_2` is empty.** Checked 2026-10-06 on all six deals: `client_ref_2`
and `client_ref_extra` are populated on **0 of 43,702 cases**. Of the other
reference-ish fields in the raw feed, `ref_case_id` is a copy of `client_ref_1`
with fewer rows filled, `master_cl_number` holds 2 distinct values across all
six deals, and `parent_ref` and `link_id` are `0` on every row. There is no
second reference to fall back on.

**Zero-padding does not bridge it.** The tape's `reference_number` is 5-6
digits; `client_ref_1` is 19. They are different numbers, not the same number
written two ways:

| | |
|---|---|
| Tape `reference_number` | `127363` |
| CAT `client_ref_1` | `0008424010000498550` |

Padding `127363` to 19 digits gives `0000000000000127363`, which matches
nothing. Measured all three ways  -  raw, both sides zero-stripped, and tape
left-padded to 19  -  **0 matches on every one**. (The matching already strips
leading zeros from both sides, so padding differences were never the obstacle.)
Searching for the tape reference *inside* the account numbers hits 3-16 times
per 300 sampled, against ~13 expected by pure chance for a 6-digit string in a
pool of 19-digit numbers  -  i.e. noise, not a pattern.

### Searched wider, and it is still nothing  -  here is the proof

The checks above constrained each tape to its own deal's cases. Dropping that
too (2026-10-06): every column of PT20006, PT21004 and PT20008 was tested
against **all 1,305,451 Portuguese loan references**, not just the matching
deal's. Apparent matches appear  -  and every one is chance.

A universe of 1.3m references contains a lot of short numbers, so short numbers
collide with it for free:

| Random number | Lands in the universe by chance |
|---|---:|
| 3-digit | **45.70%** |
| 4-digit | **32.81%** |
| 5-digit | 15.58% |
| 6-digit | **4.49%** |
| 9-digit | 0.01% |

Against that floor, the "best" candidates are all noise:

| Deal | Column | Matched | Chance floor | Verdict |
|---|---|---:|---:|---|
| PT20006 | `reference_number` (6-digit) | 6.19% | 4.49% | noise |
| PT21004 | `reference_number` (6-digit) | 5.09% | 4.49% | noise |
| PT21004 | `DPDs` (2-3 digit) | 39.50% | ~45% | noise |
| PT20006 | `credit_limit` | 31.34% | ~33% | noise |
| PT20008 | `ID Base cessão` (1...2905) | 41.45% | ~33-46% | noise |

`DPDs` is days-past-due and `credit_limit` is a credit limit. Neither is an
identifier, and both "match" as well as the reference numbers do. **That is the
tell: a real key does not score 5%, it scores 99%**  -  PT15018, PT15020 and
PT18019 all did, on 9- to 19-digit numbers whose chance floor is 0.01%.

### !! `reference_number` is a per-tape row sequence, not a loan id

Settled 2026-10-06. PT19007 has two files carrying both `reference_number` and
`account`, so its own mapping can be compared against PT18019's crosswalk. 841
reference numbers appear in both. **They agree on 0 of them.**

| `reference_number` | account per PT19007 | account per PT18019 |
|---|---|---|
| 103803 | `0008424030900716588` | `0008424080900034540` |
| 103140 | `0008424000000209024` | `0008424080900007660` |
| 103297 | `0008424000900412686` | `0008424080900014666` |

The same number means a different loan in every deal. No crosswalk built from
one deal can ever be reused on another.

### !! Do not borrow another deal's crosswalk to fix this

PT18019's `Closing_data.xlsx` carries both `reference_number` and `account` for
31,699 loans, so it looks like a lookup table that could rescue the others.
**It cannot, and using it would be worse than leaving the gap.**

`reference_number` is reused across deals. PT18019 runs 71,494-106,268 and
PT19007 runs 103,068-104,248  -  they overlap. Pushing PT19007's reference numbers
through PT18019's crosswalk produces 841 account numbers, of which **720 are
real PT18019 loans and 0 are PT19007 loans**. Every one would be a confident,
silent, wrong match.

---

## !! The trap that nearly broke this analysis

**Open these tapes as text, never as numbers.**

Account numbers are 16 to 19 digits. When a column has even one blank cell,
pandas and Excel read the whole column as a floating-point number, and anything
past about 15 digits is rounded away:

| | |
|---|---|
| In the file | `0004064740080003334` |
| Read as a number | `4064740080003300.0` <- last two digits destroyed |
| Read as text | `0004064740080003334` yes |

Two blank cells in PT15016 were enough to do this. Read as numbers, that deal
matched **7%**. Read as text, it matched **100%**. The same correction moved
PT19007 from 1% to 99% and PT20014 from 1% to 99%.

Nothing warns you. The numbers just look slightly wrong and the match quietly
fails. Always pass `dtype=str`.

---

## The loaded data

Everything in `assets/` is copied into `processed/files/` by deal, then parsed
into `processed/tables/` as parquet, so nothing is re-read from Excel. Measured
2026-10-11: 198 files in `assets/`, of which 180 are spreadsheets carrying a
deal code and are processed; 316 sheets read. Rebuild the whole of
`processed/` with:

```sh
cd ~/data-warehouse/local-workspace
uv run python work/benchmark-dataset/pre-registration-benchmark/scripts/intake.py --build
uv run python work/benchmark-dataset/pre-registration-benchmark/scripts/check_new_data.py --refresh
mise run sql -- work/benchmark-dataset/pre-registration-benchmark/portugal/bridge.sql
```

| File | Grain | Rows |
|---|---|---:|
| `processed/tables/manifest.parquet` | one per (deal, file, sheet) read | 317 |
| `processed/tables/<deal>.parquet` | one per cell - deal, column_name, value, provenance | 10,934,945 |
| `processed/tables/payments.parquet` | one per (loan, month) cell | 2,544,696 |
| `processed/tables/bridge.parquet` | one per prod case | 118,177 |

One file will not read: `PT15014E001604_Barclaycard_asset-index.xlsx` is
**password-protected** (`CDFV2 Encrypted`), not corrupt. It is reported as a
failure on every load rather than skipped quietly, and PT15014 is built
without it.

**The tapes land long, not wide**, keyed by column name. Four sellers with four
schemas  -  `acct_serno`, `reference_number`, `Contrato`, `Cliente Number`  -
cannot share a wide table without inventing a mapping. Pivot per deal when you
know which columns you want:

```python
import pandas as pd
t = pd.read_parquet("portugal/raw/processed/tables/PT18019.parquet")
wide = t.pivot_table(index=["source_file", "source_sheet", "source_row"],
                     columns="column_name", values="value", aggfunc="first")
```

**Every value is text.** Convert at the point of use, never on load  -  see the
float-rounding trap above. Verified after loading: all 31,699 PT18019 account
numbers are still 19 characters, with no `.0` or scientific-notation artefacts.

### !! Only 4 of 12 deals have a pre-acquisition payment series

| Deal | Column style | Months | Covers |
|---|---|---:|---|
| PT15014 | `JAN15pay` | 23 | 2014-12 -> 2016-10 |
| PT15016 | `JAN15pay` | 12 | 2014-11 -> 2015-10 |
| PT20008 | `PAGAMENTOS_201903` | 13 | 2018-03 -> 2019-03 |
| PT18019 | `-12M` ... `-1M` | 12 | **relative only** |

`period_month` is derived where the column names an absolute month, and left
NULL on PT18019  -  `-3M` means three months before that book's cutoff, and the
cutoff is not in the tape. Do not guess it.

!! **The five WiZink deals carry no payment history.** Their only money-over-time
column is `installment_amount`, which is the contractual instalment  -  what the
borrower was *meant* to pay, not what they did. It is deliberately not loaded as
a payment. PT16023 has none either, and PT15018 has only aggregate `Collections`
totals, not a series.

!! **PT20008 is the awkward one**: 13 months of payments and 2,905 loans, but no
loan identifier (see above), so its payments cannot be attached to a case in
either the tape or the warehouse.

## How to run it

[bridge.sql](bridge.sql) returns the warehouse half  -  one row
per production case for all 12 deals, carrying the seller's loan reference
beside `CASE_SK` and `CASE_BK`.

```sh
cd ~/data-warehouse/local-workspace
mise run sql -- work/benchmark-dataset/pre-registration-benchmark/portugal/bridge.sql
```

Then read your tape with `dtype=str`, strip leading zeros from both sides, and
join on `SELLER_LOAN_REFERENCE`.

Two things that will bite if you change the query:

- **Do not pick the newest file.** The Portuguese feed's last real delivery is
  `cat.4050.cases.20260114`, split across three files. A later file exists
  (`20260115`) but holds 1,178 rows  -  a delta. "Latest file" returns those and
  nothing else, with no error.
- **The raw feed is change history.** 85.4 million rows describe 118,177 loans,
  roughly 720 versions each. The query collapses to each loan's latest state;
  without that every total multiplies.

---

## What is solid and what is shaky

**Solid.** The six matching deals. Those coverage figures come from comparing
complete sets of identifiers  -  every row of every tape against every loan in the
feed  -  not from a sample. The Intrum-to-production hop at 99.98% is a direct
count. The reference-number collision is demonstrated, not inferred.

**Shaky.** PT15014 at 92% and PT16023 at 99% have a residue of a few hundred
unmatched loans that nobody has explained  -  they may be loans sold on, or a
later vintage than the tape. Worth a look before anyone quotes those two as
complete.

**Not checked.** Whether the payment histories agree once joined. This answers
only whether the loans can be matched, which is what was asked. The money is a
separate question, and the existing [work/asset-index](../work/asset-index)
analysis found real gaps between seller-reported and servicer-reported
collections on other books  -  expect the same here.

**One thing to raise.** `PT15014E001604_Barclaycard_asset-index.xlsx` is
corrupt and cannot be opened by anything. It is one of 12 monthly files for that
deal, which is part of why PT15014 sits at 92% rather than higher.

---

| File | What it is |
|---|---|
| [OVERVIEW.md](OVERVIEW.md) | this |
| [bridge.sql](bridge.sql) | the warehouse half of the bridge  -  run this |
| `assets/PT - Orange - Asset Index/` | the seller tapes as delivered 2026-01-14 - 179 files across 20 deals, of which 168 spreadsheets across 12 deals were read for the bridge |
| `assets/PT - Orange - Extract/` | a later delivery, 19 files across 13 deals. Thirteen were byte-identical repeats of the Asset Index; six were new |
