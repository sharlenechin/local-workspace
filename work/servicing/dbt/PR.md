# Case status, open/closed and collection phase for the servicing cases mart

## Summary

Status codes get meanings on `dim_npl_case`, Intrum's phase history gets a model, and `mart_npl_servicing_agg_cases_monthly` counts open, closed, insolvent and per-phase (Amicable / Legal / Enforcement) cases per portfolio-month, now including months before capex.

## Why a new staging model for the phase, not `CASES.CASE_PHASE`

`CASE_PHASE` is an undocumented code whose meaning changes by instance (3000 = amicable in ES, enforcement in PL), and it is filled for 42% of Intrum cases, against 62% for `GROUP_CASE_PHASE`'s A/L/E.
Carrying it on the case would also mean adding it to `int_npl_case_scd_conformed`'s `scd_columns`, which creates a new `case_sk` on every phase change; the phase feed keeps its own dated history instead.

## Changes

| | File | Change |
|---|---|---|
| New | `data/npl/npl_status_code_mappings.csv` + `.yml` | What each servicer's status code means: Intrum's 103 codes plus `99`, Gescobro, Cerved, Massey. Keyed on servicer **and** code. |
| Amend | `dim_npl_case.sql` | Left join the seed: fills `status_description` (hard-coded NULL until now) and adds `status_group`, `is_closed_status_flag`, `is_insolvent_status_flag`. No new versions: they change only with `status_code`, already tracked. |
| Amend | `staging/intrum_cat/source.yml` | Declare `group_case_phase` |
| New | `stg_intrum_cat__group_case_phases.sql` | Rename-only view, same pattern as the other CAT staging models |
| New | `int_npl_case_phase_intrum.sql` | One row per phase period (valid_from / valid_to); deleted rows and placeholder dates dropped. A table: the feed is ~347m rows. |
| Amend | `mart_npl_servicing_agg_cases_monthly.sql` | Nine new counts per portfolio-month (open, closed, closed in month, open insolvent, open per phase). Capex filter removed. |
| Amend | `models.yml` (dimensions, marts) | Docs and tests for every new column |
| No change | `fct_npl_case_snapshot_daily.sql` | Untouched, so no full refresh |

## Tests added

- `accepted_values` on `dim_npl_case.status_group`: a status code missing from the seed reads "Unknown code" and fails it
- Mart: open + closed = cases on book; the five phase counts add up to open
- Seed: unique on servicer + code; group and flags never null

## Notes for the reviewer

- `dim_npl_case` gains columns and is incremental, so it needs one `--full-refresh`.
- Dropping the capex filter grows the mart's input about 31x: 130.4m collection rows sit before capex (93 portfolios, back to 2014) against 4.3m after (measured 2026-10-15). Behaviours in the first owned months change, correctly: a payer is no longer "first collection" just because earlier months were cut.
- `status_group` is our grouping of Intrum's codes, not Intrum's. Massey's codes 1–3 are unconfirmed; 4 = closed is inferred.
- Of Intrum's 10.1m open cases at 30 Sep 2026, 11.5% have no phase record ("No phase data") and 8.3% are NA ("Not assigned"), mainly PT 4050, SE 2080, FI 1033, CH 3010. Raised with Intrum separately.
- `dbt parse` and `sqlfluff lint` / `format` pass on the changed models (dev target). Not built yet.
- The mart's new logic, run read-only on PROD for 30 Sep 2026: 21,854,824 on book = 12,036,381 open + 9,818,443 closed; 26,223 closed that month; Intrum's five phase counts add up to its 10,144,764 open cases.
- Dashboard mock of what this enables: https://claude.ai/artifact/DiGverE4kFrAbcWb326mPM (illustrative figures).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
