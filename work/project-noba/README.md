# Project NOBA — a loan-level valuation dataset for six Swedish books

Two exports, one reconciliation, and a note on what is safe to quote.
**Read `USABLE.md` before using any number.**

## Run them

```
mise run sql -- work/project-noba/accounts_export.sql    --connection dev --warehouse DEV_WH --lower
mise run sql -- work/project-noba/payments_export.sql    --connection dev --warehouse DEV_WH --lower
mise run sql -- work/project-noba/reconciliation.sql     --connection dev --warehouse DEV_WH --lower
```

`--connection dev` and `--warehouse DEV_WH` are both required: the asset index lives on
brocc-sandbox, and the workspace default warehouse exists only on brocc-prod.

| File | What it gives you | Rows |
|---|---|---|
| `accounts_export.sql` | one row per loan we own, seller tape filled in where it reaches | 62,641 |
| `payments_export.sql` | one row per payment: seller tape before registration, servicer after | 937,770 |
| `reconciliation.sql` | one row per deal: CAT against PAM on cases, principal and cash | 6 |
| `USABLE.md` | which deals are safe for what | — |

All three were run and verified on 2026-11-03.

## The three things that will trip you up

**1. Two id systems for the same book.** CAT, PAM and `DIM_BATCH` use Intrum's id;
`DIM_PORTFOLIO` and the asset index use our Atlas id.

| Atlas (ours) | Intrum | Book |
|---|---|---|
| LOK-SE25008 | **SE25018** | Santander, Jun 2025 |
| LOK-SE25013 | **SE25037** | Norion, Dec 2025 |

`SET deals` at the top of each file takes **Intrum's** ids. The `tape_alias` CTE maps
SE25018 to SE25008 for the asset-index lookup only. Put an Atlas id in `SET deals` and
the deal silently returns nothing -- PAM has never heard of it, so it drops out with no
error. That mistake cost 13,793 loans once already. The asset index is itself
inconsistent: SE25037's run is filed under Intrum's number, SE25008's under ours, so the
mapping has to be a lookup, not a rule.

**2. Two Intrum instances.** Swedish books are split across 1062 and 2080, and `case_id`
is unique only *within* one. Every join and every dedupe key carries the instance as
well. SE19026, SE25018 and SE25037 span both.

**3. Compare post-ACQUISITION, never post-registration.** PAM only counts cash collected
since we bought the book. SE25018 reads 385% of PAM the wrong way and 102% the right way.

## Conventions

- Amounts are SEK, shown to 5 decimal places. Never `round()` a DataFrame.
- CAT is a change-history feed: the newest version of each case wins, and payments are
  deduped on `(source_system, case_id, transaction_date, amount_type_code, amount)`.
  **Not** on `orig_tr_id` -- that overstates SE15044 by 3.6x. The header explains why.
- Never bound the transaction date. Sentinel years run from 1733 to 2159 and sit on
  superseded rows; a bound deletes real money.
- The scope guard is `real_case_ind <> '1'`. Both options were measured; the header
  records what each costs.

## Related

- `../data-issues/intrum/dbt-updates.md` -- a live dbt defect that deletes collections on
  five Intrum instances. It is why these exports read raw CAT rather than
  `FCT_CASE_COLLECTION`.
- `../data-issues/intrum/pam-pre-2020-swedish-books.md` -- why SE15044 and SE16025 cannot
  carry a lifetime recovery curve.
