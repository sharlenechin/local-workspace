# Archive — the Portugal / Millennium investigation trail

Eighteen `.sql` files and two CSV exports from the Project Elsa build
(2026-09-09 to 2026-09-11). **Superseded, kept deliberately.**

Every finding in them now lives in
[`../../project-elsa-benchmark/FINDINGS.md`](../../project-elsa-benchmark/FINDINGS.md),
and the reusable shape of each one lives in
[`../templates/`](../templates/). **Open a file here only when you want the
working, not the answer** — to re-run a measurement, to check how a figure was
derived, or to see a hypothesis being tested and killed.

Nothing was deleted. These files still run.

## What each one was for

### The reconciliation

| File | Question it answered |
|---|---|
| `pam_cat_match.sql` | the like-for-like CAT-vs-PAM match, four differences broken out. → `templates/03` |
| `batch_impact_matrix.sql` | one row per batch, one column per known problem. → `templates/04` |
| `reconciliation_three_sources.sql` | PAM vs CAT vs PROD side by side — where the 42% finding came from |
| `portugal_millennium_reconciliation.sql` | collections either side of case registration, both sources |
| `batch_attribution_audit.sql` | do the source-system pin and the dedupe order lose loans? (No — FINDINGS §13) |
| `cat_pam_extract_lag.sql` | how far behind PAM each Intrum instance runs. → `templates/06` |
| `pam_last_collection_month.sql` | the closest PAM can get to a last-payment date |

### The diagnostics

| File | Question it answered |
|---|---|
| `borrower_type.sql` | is there anything in the feed that says consumer vs business? (No) |
| `borrower_type_mapping.sql` | raw `DEBTORS.TYPE` vs PROD's mapping, and why PROD's is unusable. → `templates/05` |
| `undated_payments_diagnosis.sql` | are undated payments pre-acquisition, or a migration artefact? |
| `collection_window_vs_capex.sql` | which batches report collections before their own capex date |

### The earlier drafts of the deliverables

Superseded by `project-elsa-benchmark/accounts.sql` and `payments.sql`, which are
faster and correct where these were not. Kept because their headers record
measurements the final files only cite.

| File | |
|---|---|
| `portugal_millenium.sql` | the first batch × month query, with the slow CAT join attached |
| `portugal_millenium_batches.sql` | the same, narrowed to a named batch list |
| `portugal_millenium_batch_audit.sql` | companion: did every requested batch ref actually return rows? |
| `portugal_millenium_transactions.sql` | first payment date and total per batch |
| `portugal_millenium_case_collections.sql` | the case-level counterpart |
| `add_portugal_millennium_cases.sql` | the consolidated cheap version — where the six performance fixes were worked out |
| `intrum_case_collection_raw.sql` | `int_npl_case_collection_conformed` rebuilt from RAW only |

### Exports

`accounts.csv`, `payments.csv` — outputs from an earlier run, from when the two
deliverables lived in this folder. The notebook now writes its exports beside
itself in `project-elsa-benchmark/`.

## ⚠ Before you trust one of these

- **Figures in the headers are as at 2026-09-10.** Where a file disagrees with
  `FINDINGS.md`, `FINDINGS.md` is the corrected version — several of these
  headers record a claim that was later sharpened or overturned (the clearest:
  `accounts.sql`'s old "PROD merely sees less", superseded by the directional
  loss measured in `borrower_type_mapping.sql`).
- **`borrower_type.sql` still uses `row_number()`** over tied timestamps, which
  is why its counts sit a few loans from every other file. The shipped rule keeps
  all rows tied at the latest version. Do not reintroduce `row_number()` there.
- **Some of these are expensive.** Anything touching `TRANSACTIONS` without an
  instance pin occupies the shared X-Small warehouse for minutes.
