# Fields this PR makes: logic and source

Drafted 2026-10-15; matches branch `sc/servicing-dashboard`. "Seed" = `npl_status_code_mappings.csv`, matched on **servicer + trimmed status code** (codes are servicer-specific: Massey `4` is not Intrum `4`).

## Where the two inputs come from, per servicer

| Servicer | `DIM_CASE.STATUS_CODE` comes from | `DIM_CASE.CLOSING_DATE` comes from |
|---|---|---|
| Intrum | `RAW.HYPERION_INTRUM_CAT.CASES.MAIN_STATUS_CODE` | `RAW.HYPERION_INTRUM_CAT.CASES.CLOSING_DATE` |
| Gescobro | `RAW.HYPERION_GESCOBRO.ACCOUNT_LOANS.LOAN_STATUS` | none: hard-coded NULL in `int_npl_case_conformed`; the raw table has no closing date |
| Cerved | `RAW.HYPERION_CERVED.LOANS.LOANS_STATUS` | none: hard-coded NULL in `int_npl_case_conformed`; the raw table has no closing date |
| Massey | `RAW.HYPERION_MASSEY.CASES.STATUS_CODE` | `RAW.HYPERION_MASSEY.CASES.CLOSING_DATE` |
| Souq | not mapped (blank) | `RAW.HYPERION_SOUQ.SOUQ_GR22022_STATIC.CLOSING_DATE` (filled on 2 cases) |

`DIM_CASE.CLOSING_CODE` (the closing reason) is a different field and is not used here.

## `DIM_CASE`: one row per case version (a new version when the status changes)

| Field | New? | Logic | Source |
|---|---|---|---|
| `status_description` | Existing column, NULL today | `seed.description` | Seed `status_description`, on `servicer_name` + `TRIM(status_code)` |
| `status_group` | New | 'No status' when the code is null, else `COALESCE(seed.status_group, 'Unknown code')` | Seed |
| `is_closed_status_flag` | New | `COALESCE(seed.is_closed_status_flag, FALSE)` | Seed |
| `is_insolvent_status_flag` | New | `COALESCE(seed.is_insolvent_status_flag, FALSE)` | Seed |

`servicer_name` comes from the reporting system the case belongs to. "Unknown code" should never appear: a test fails if any servicer + code is missing from the seed.

## `stg_intrum_cat__group_case_phases` (new): rename-only view of `RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE`

`case_id`, `group_phase_code`, `start_date::date`, `deleted`, `archived`, `unlinked`, `record_update` (= `COALESCE(update_ts, record_update)`), `source_system_code` and `extracted_at` from `_file_metadata`, as every CAT staging model does.

## `int_npl_case_phase_intrum` (new, a table): one row per phase period

| Field | Logic |
|---|---|
| `case_bk` | `<source_system_code>-<case_id>`, the key every Intrum model uses |
| `case_dk` | `generate_surrogate_key(['intrum', case_bk])`, equal to the snapshot's `case_id` |
| `group_phase_code` | As sent (A002, L002, E003, NA…) |
| `collection_phase` | `NA` → Not assigned; first letter `A` → Amicable, `L` → Legal, `E` → Enforcement |
| `valid_from` | `start_date` |
| `valid_to` | Next period's start date for the same case, else 9999-12-31 |
| filters | `deleted`, `archived`, `unlinked` = 0; code not null; start date 1950-01-01 to today (placeholder 1900 dates exist); one row per case and start date, latest record wins |

## `mart_npl_servicing_agg_cases_monthly`: worked out per case per month end, then counted per portfolio-month

Each case-month starts from `FCT_CASE_SNAPSHOT_DAILY` (case, month end, `case_sk`). `case_sk` is the `DIM_CASE` version valid on that month end, so every flag below is "as at month end".

| Field (per case-month) | Logic | Source |
|---|---|---|
| `is_open_flag` | `COALESCE(closing_date > month_end, TRUE) AND NOT is_closed_status_flag` | `DIM_CASE` via `case_sk` |
| `closed_in_month_flag` | Closed, and either the closing date falls in the month or, with no closing date, the closed-status version of the case began in the month | `DIM_CASE` via `case_sk` |
| `is_insolvent_flag` | `is_insolvent_status_flag` | `DIM_CASE` via `case_sk` |
| `collection_phase` | The phase period with `valid_from <= month_end < valid_to`; **No phase data** if none (all non-Intrum, and Intrum books without the feed). A closed case keeps the phase it closed in. | `int_npl_case_phase_intrum`, on `case_bk` |

| Field (per portfolio-month, new columns) | Logic |
|---|---|
| `cases_open_count` | Count where `is_open_flag` |
| `cases_closed_count` | Count where not `is_open_flag` |
| `cases_closed_in_month_count` | Count where `closed_in_month_flag` |
| `cases_open_insolvent_count` | Count where open and `is_insolvent_flag` |
| `cases_open_amicable_count`, `_legal_`, `_enforcement_`, `_phase_not_assigned_`, `_no_phase_data_` | Open cases by `collection_phase` |

Check that always holds: `cases_open_count + cases_closed_count = cases_on_book_count`, and the five phase counts add up to `cases_open_count`.

Also in the mart: the `>= capex_date` filter is dropped from collections and the book (history before purchase).

## Not changed

`FCT_CASE_SNAPSHOT_DAILY`, `status_code`, `closing_date`.
