# `work/portugal/` — the Portuguese estate, across sellers

Country-level scoping: **who sold what in Portugal**, so a new book can be
picked and sized before anyone writes a benchmark for it. Not a benchmark
itself — for that, see [`../benchmark/METHOD.md`](../benchmark/METHOD.md) and
the two books already built, `project-elsa-benchmark` (Millennium) and
`project-sea-benchmark` (WiZink + Barclaycard).

| File | What it is |
|---|---|
| `portugal_seller_profile.sql` | the census query: one row per Portuguese seller — size, price shape, debt age, spot purchase vs forward flow. **Open this before scoping any new Portugal book** |
| `portugal_seller_profile.csv` | its output, run 2026-10-01. **30 sellers, all batches** |
| `portugal_five_sellers_oneoff.csv` | the same five shortlisted sellers restricted to their **one-off batches only**, run 2026-10-01 |

```
mise run sql -- work/portugal/portugal_seller_profile.sql --csv work/portugal/portugal_seller_profile.csv
```

## ⚠ The two CSVs are different cuts, not a file and its subset

The census counts **every** batch a seller sold. The one-off file counts **spot
purchases only**. For WiZink that is 4 batches of 133, and for Barclaycard 2 of
14 — so every figure moves, not just the batch count: outstanding, average per
loan, interest share and debt age all differ. **Say which cut a number came
from.**

## ⚠ A census is not a valuation base

The query applies Project Elsa's **guards** but deliberately not Elsa's
**exclusions**:

- **Guards** (C1, C4, C5, C8, C9 and the PAM scope) are measurement
  correctness. They apply to every book, so they are applied here.
- **Exclusions** (unclassifiable debtors, WiZink's 5 company loans, six named
  batches) are decisions about what belongs in **one priced book**. Applying
  them to a country-wide census would silently delete real loans from sellers
  Elsa never looked at.

To price a book, scope it with `../benchmark/templates/00_scope.sql` instead.
