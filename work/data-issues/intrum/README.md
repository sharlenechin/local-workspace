# Intrum — what is wrong with the feeds, and what we have asked for

Two feeds come from Intrum and they do not agree with each other:

- **CAT** — loan level, one row per case, delivered as change history
- **PAM** — batch × month, the servicer's own portfolio report

Most of what follows is the gap between them, plus the codes Intrum sends
without a dictionary.

| File | Topic | Status |
|---|---|---|
| [`escalations-portugal-millennium.md`](escalations-portugal-millennium.md) | Seven items only Intrum can answer, measured on the Portugal / Millennium book (instance 4050, 14 PAM batches, 120,713 loans) | **open with Intrum** |
| [`phase-codes.md`](phase-codes.md) | What each `GROUP_PHASE_CODE` means — inferred, because no dictionary was ever sent | **inferred, not confirmed** |
| [`feed-coverage.md`](feed-coverage.md) | Which of the 35 RAW CAT tables PROD models (26), what the missing nine hold, and the three dictionaries that would unblock most of a stakeholder pack | **scoping, 2026-09-14** |
| [`queries/`](queries/) | The SQL behind all three. Every figure above is reproducible | — |
| `2026-09-18-pam-vs-cat-recon-from-intrum.xlsx` | **Intrum's own** PAM-vs-CAT reconciliation, sent to Brocc 2026-09-18. Two sheets, `data` and `pivot`, 24MB | **their numbers, not ours** |

⚠ **The workbook is Intrum's working, not a Brocc figure.** It arrived in
response to the escalations above and has not been reconciled against the
warehouse. Never quote a number from it as ours; use it to see what Intrum
believes, then check that against `queries/pam_vs_cat_by_portfolio.sql`.

## The one thing to know before quoting any of this

**Only the first letter of a phase code is confirmed by a person**: `A` =
Amicable, `L` = Legal, `E` = Execution (Sharlene, 2026-09-16). Everything
finer-grained in `phase-codes.md` is inferred from where a code sits in a
case's life, and is labelled as such.

This is why the dashboard carries **no amicable / legal split**. The
`dash_portfolio_diagnostics` element that did was deleted on 2026-09-17 — the
business does not trust a split built on undocumented codes, and keeping it
also put an unmodelled 346m-row RAW table on the critical path of a published
dashboard. Ask for it back only with a dictionary from Intrum in hand.

## ⚠ Reading RAW Intrum tables at all

Every query in `queries/` carries these guards and a new one must too:

- **Change history.** RAW repeats every version of every record — 147× the
  cases, 10.8× the transactions. Dedupe to the latest version.
- **`CASE_ID` is unique only within an instance.** Pin the source system.
- **Match `_file_path` as a literal prefix**, no leading `%`, and read every
  extract. The newest extract is a DELTA, so "latest file only" returns almost
  nothing.
- **35% of payments have a NULL `transaction_date`.** Never bound the date.

The full method is in [`../../benchmark/METHOD.md`](../../benchmark/METHOD.md).
