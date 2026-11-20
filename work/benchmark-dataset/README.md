# benchmark-dataset — one loan's life, from two sources

A loan has two halves and no single system holds both.

    ... seller's own records ...  | REGISTRATION |  ... servicer's records ...
    the asset index (diligence)   |   the date   |   CAT / prod (what we own)
    pre-registration              |   the seam   |   post-registration

`post-registration-benchmark/` was built and tested first, reads prod, and is
CORRECT. **Nothing in it changes.** The other three folders are new and are
expected to move as the Snowflake side matures.

| Folder | Step | Status |
|---|---|---|
| `post-registration-benchmark/` | prod accounts + payments, keyed on prod `case_id` | FROZEN — renamed 2026-10-07, content untouched |
| `pre-registration-benchmark/` | the asset index: the seller's picture before we owned it | new, expected to change |
| `bridge/` | asset-index `loan_id` -> prod `case_id` | new, the hard part |
| `stitched-dataset/` | the two halves joined into one dataset | new, expected to change |

## Which source wins, field by field

**PROD IS THE DEFAULT.** The asset index is used only where prod cannot answer.

| | Source | Why |
|---|---|---|
| `portfolio_id` | **PROD, always** | the seller's deal code is not our portfolio. Only the bridge needs the tape's side. |
| accounts — most fields | **PROD** | it is the system of record for what we own |
| `judicialised_flag`, debt age, and anything the servicer cannot concretely determine | **ASSET INDEX** | the seller knew it at diligence; prod never captured it |
| payments BEFORE registration_date | **ASSET INDEX** | prod does not have them — the servicer was not involved yet |
| payments ON/AFTER registration_date | **PROD** | the servicer's own ledger |

So accounts is `coalesce(prod.field, asset_index.field)` with a short, explicit
list of fields that invert that; payments is a `union all` split on
registration_date. Neither is a judgement call made row by row.

## ⚠ The bridge is unsolved, and everything waits on it

Measured 2026-10-07 on PT15018 against the 2026-01-14 full CAT load:

- the asset index's `loan_id` (the tape's **Account Number**) matches prod
  `client_ref_1` on **0 of 1,557** — it cannot reach Snowflake at all
- the tape's **Client Number** matches on **1,003 of 1,557 (64%)**
- fingerprinting on capital does NOT disambiguate: our `principal_at_cutoff`
  (seller, 2016-07-08) equals prod `original_capital` (servicer, at
  registration) on **57 of 1,555**. Loosening to EUR 100 adds one.
- joining through the client reference: **1,294 of 1,557 loans (83%) reach
  exactly one prod case**; 261 reach 2-4; and **209 prod cases are claimed by
  more than one of our loans** (max 21) — the double-count risk

Only unambiguous pairs may feed the stitch. Everything else is reported, never
silently dropped, and the coverage goes on the output.

## Grain

`post-registration-benchmark` is one row per loan. The asset index is one row
per SYSTEM RECORD (1,752 for 1,555 loans on PT15018) because its config format
has no aggregation. `pre-registration-benchmark` is where that collapses to the
loan — a `group by` that was impossible upstream.
