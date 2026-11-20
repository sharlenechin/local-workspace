"""Run every Servicing dashboard check, or one suite of them.

    uv run python work/servicing/tests/run.py                  # everything, ~7 minutes (suite 9 exports ~70 live tiles)
    uv run python work/servicing/tests/run.py --suite cases    # one suite
    uv run python work/servicing/tests/run.py --as-of 2026-06  # back-test: both sides as at June 2026
    uv run python work/servicing/tests/run.py --offline        # skip the live Sigma tiles
    uv run python work/servicing/tests/run.py --full           # exhaustive design sweep (~2.5 min)
    uv run python work/servicing/tests/run.py --doc            # print the catalogue (TEST-CASES.md), touch nothing
    uv run python work/servicing/tests/run.py --only 'live.chart_*' --only 'controls.chart_*'   # just the checks a change touches

Targeted runs (--only, a glob on check ids, repeatable) are for a change to ONE component: a chart, a tile, the header.
Run everything when the query (sigma_queries/*.sql) or a shared helper changes, and once before a release.

Suites live in tests/suites/, one file per topic, each readable on its own.
Every run appends to tests/results.csv, so drift shows as a trend.
Exit code 0 only if every check passes.
"""
from __future__ import annotations

import argparse
import fnmatch
import importlib
import pathlib
import sys
import textwrap
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import _lib  # noqa: E402

SUITES = ["s1_structure", "s2_money", "s3_forecasts", "s4_windows", "s5_cases", "s6_live_dashboard", "s7_design", "s8_edge_cases", "s9_controls"]


def load(only: str | None):
    mods = [importlib.import_module(f"suites.{name}") for name in SUITES]
    return [m for m in mods if only in (None, m.SUITE, m.__name__.split(".")[-1])]


def _try(fn, *a):
    try:
        fn(*a)
    except Exception:
        pass   # the check itself will re-raise and report it


# What a viewer does, and which checks prove the dashboard answers correctly. Shown first in TEST-CASES.md.
SCENARIOS = [
    ("Opens the dashboard", "Every portfolio-month reaches the page; tiles show the latest complete month",
     "live.no_default_filter, edge.loading_month_excluded, live.tile_collections_window"),
    ("Changes the Comparison Window (L1M … L12M) on Portfolio", "Every card stays the latest reporting month; only the % moves: the month before, or the average month of the window (ratios: the window's ratio)",
     "controls.collections.*, controls.net.*"),
    ("Changes the Benchmark", "Forecast, % of forecast and the gap switch plan; Servicer is like-for-like",
     "controls.forecast.*, controls.vs_forecast.*, controls.gap.*"),
    ("Reads the Collections vs Forecasts chart", "Collections plus all three forecasts whatever the Benchmark and Window; past months match the facts; "
     "forecasts run 12 months past the selected month (or the latest), for the book owned then; Cumulative stops collections there; the header filters reach it",
     "live.chart_*, controls.chart_*"),
    ("Changes the Comparison Window on Cases", "Every card stays the latest month; the comparison is the average month over months with a case feed; the book is read at the latest month",
     "controls.collected_cases.*, controls.c_first.*, controls.c_new.*, controls.c_lost.*, controls.c_three.*, controls.c_ce.*, controls.c_nl.*, controls.c_cpe.*, controls.book.*, controls.c_everc.*, controls.c_ever.*"),
    ("Reads the Cases chart, on both tabs", "Stacked bars coloured by behaviour in the palette with a legend on the right, each behaviour matching the mart; the Country filter reaches it; the hover counts feed portfolios",
     "controls.count_chart.*, controls.money_chart.*, controls.case_chart_*"),
    ("Groups §2 Performance by a grain, incl. Seller", "Every portfolio lands in exactly one group; Seller groups match the warehouse",
     "controls.performance_total.*, controls.performance_by_seller, controls.performance_window"),
    ("Reads §3 Full Breakdown", "One row per portfolio; totals and every portfolio's seller match the warehouse",
     "live.full_breakdown_total, live.full_breakdown_rows, live.seller_in_full_breakdown, live.cases_full_*"),
    ("Opens Data Quality and changes its Window", "The reconciled share, the euro not reconciled and the stopped feeds cover exactly the months named; By Servicer and By Portfolio add up to the tiles",
     "controls.dq_*, live.data_quality_*"),
    ("Clicks Clear Filters", "All six filters reset; the toggles keep their defaults", "controls.clear_filters"),
    ("Quotes a figure", "Collections, forecasts and case counts match the facts on every portfolio-month",
     "edge.collections_every_row, money.*, forecasts.*, cases.*"),
    ("Selects a portfolio with no case feed", "Case tiles show blank (Sigma prints 'null'); Data Quality's Data Status says 'No case feed.'; nothing is summed as zero",
     "cases.blank_means_no_feed, controls.dq_status_words (the display measured by hand 2026-10-09)"),
    ("Reviews the manager's changes", "No Vehicle or jitter on screen; reconciliation only on Data Quality; one Cases chart with Count | Collections tabs",
     "controls.manager_review_applied"),
    ("Someone edits the workbook in Sigma, then it is rebuilt", "The hand edits survive", "controls.user_edits_live"),
    ("Back-tests a past month", "Both sides capped at that month: run.py --as-of YYYY-MM", "every offline suite"),
]
# Honest limits, from the independent audit of 2026-10-09. Fix one, then delete its line.
KNOWN_GAPS = [
    "The reconciled flag (case feed within 10% of the servicer report) is the query's own calculation; "
    "windows.collections_reconciled_* and controls.dq_reconciled_share.* / dq_not_reconciled.* read the query to build their expectation, "
    "so they test the windowing, not the flag. controls.dq_feeds_stopped.* reads the query's feed-stopped flag the same way.",
    "design.* checks prove the mock is in sync with the query; they re-implement the mock's logic, not Sigma's.",
    "Ratios are checked to 1e-9 against SQL; Sigma's display rounding (and the delta display on % tiles) is not checked.",
    "Tiles with no live check of their own: Servicer Cost %, Month Still Loading (a text, checked by design.status_matches_query on the query) and most of the band's status tiles. "
    "Their columns are checked in the query (suites 2-5).",
    "Mutants exist only for the query, not for Sigma formulas; suite 9 covers the formulas by checking every control setting.",
    "Nothing is checked against a servicer statement or the ledger.",
    "The chart's future forecast months convert at each currency's newest rate (no future rates exist); live.chart_*_ahead checks that rule, not a rate anyone published. "
    "Colours and dashes are not read back from the rendered chart (an export has none): the series order that sets them is checked in the spec, and the look in a rendered PNG.",
]


def document(mods) -> int:
    """The catalogue, written for a reviewer. `--doc > tests/TEST-CASES.md` regenerates the file."""
    total = sum(len(m.CHECKS) for m in mods)
    print("# Servicing dashboard - test cases\n")
    print(f"{total} checks in {len(mods)} suites. Generated by `run.py --doc`; edit the suites, not this file.\n")
    print("Every check compares the dashboard (its query, or a live Sigma tile) with SQL written independently "
          "from the warehouse facts. **Tolerance** is relative: `exact` means to the cent or to the unit.\n")
    print("Back-test any month with `--as-of YYYY-MM`: both sides are capped at that month end. "
          "The live suites (6 and 9) cannot be rewound and are skipped in a back-test.\n")
    print("## At a glance\n")
    print("| Suite | Checks | Checks the | Against |")
    print("|---|---|---|---|")
    for m in mods:
        live = any(c.live for c in m.CHECKS)
        what, against = (("design mock", "the dashboard query") if m.SUITE == "design"
                         else ("live Sigma workbook", "warehouse SQL written in the test") if live
                         else ("dashboard query", "warehouse SQL written in the test"))
        print(f"| {(m.__doc__ or '').strip().splitlines()[0]} | {len(m.CHECKS)} | {what} | {against} |")
    print("\n## Scenarios: what a viewer does, and what proves it\n")
    print("| A viewer… | The dashboard must… | Proved by |")
    print("|---|---|---|")
    for who, must, by in SCENARIOS:
        print(f"| {who} | {must} | `{by}` |")
    print("\n## Known weak spots\n")
    for g in KNOWN_GAPS:
        print(f"- {g}")
    print()
    for m in mods:
        doc = (m.__doc__ or "").strip().splitlines()
        print(f"## {doc[0]}\n")
        body = "\n".join(doc[1:]).strip()
        if body:
            print(textwrap.indent(body, "") + "\n")
        print("| Check | What it compares | Tolerance | A pass proves |")
        print("|---|---|---|---|")
        for c in m.CHECKS:
            tol = "exact" if c.tol == 0 else f"{c.tol * 100:g}%"
            print(f"| `{c.id}` | {c.title} | {tol} | {c.proves} |")
        print()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite")
    ap.add_argument("--as-of", help="YYYY-MM: back-test as at that month end")
    ap.add_argument("--offline", action="store_true", help="skip checks that read the live Sigma workbook")
    ap.add_argument("--full", action="store_true", help="run the exhaustive design sweep")
    ap.add_argument("--doc", action="store_true")
    ap.add_argument("--only", action="append", default=[], metavar="GLOB",
                    help="run only checks whose id matches (e.g. 'live.chart_*'); repeatable")
    args = ap.parse_args()

    mods = load(args.suite)
    if not mods:
        print(f"no suite called {args.suite!r}; choose from {[s.split('_', 1)[1] for s in SUITES]}")
        return 2
    if args.doc:
        return document(mods)
    if args.only:   # keep only the checks named; a suite left empty drops out
        for m in mods:
            m.CHECKS = [c for c in m.CHECKS if any(fnmatch.fnmatchcase(c.id, g) for g in args.only)]
        mods = [m for m in mods if m.CHECKS]
        if not mods:
            print(f"no check matches {args.only}")
            return 2

    _lib.Settings.as_of = f"{args.as_of}-01" if args.as_of else None
    _lib.Settings.full = args.full
    run_at, started = _lib.now(), time.time()
    print(f"Servicing dashboard checks · as of {_lib.as_of_label()} · {run_at}\n")

    # Live Sigma exports are slow but independent of Snowflake: start them now.
    if not (args.offline or args.as_of or args.only):   # a targeted run exports only what its checks ask for
        for m in mods:
            for element in getattr(m, "PREFETCH", []):
                threading.Thread(target=lambda e=element: _try(_lib.tile, e), daemon=True).start()

    rows, failed, skipped = [], 0, 0
    for m in mods:
        print(f"{(m.__doc__ or m.SUITE).strip().splitlines()[0]}")
        for c in m.CHECKS:
            rec = {"run_at": run_at, "as_of": _lib.as_of_label(), "suite": m.SUITE, "check_id": c.id,
                   "title": c.title, "actual": "", "expected": "", "drift_pct": "",
                   "tol_pct": f"{c.tol * 100:g}", "status": ""}
            if c.today_only and args.as_of:
                skipped += 1
                rec["status"] = "SKIP"
                rows.append(rec)
                print(f"   SKIP  {c.title}  (describes today's data; not rewindable)")
                continue
            if c.live and (args.offline or args.as_of):
                skipped += 1
                rec["status"] = "SKIP"
                rows.append(rec)
                print(f"   SKIP  {c.title}  (live tile; {'--offline' if args.offline else 'not rewindable'})")
                continue
            try:
                a, e = float(c.actual()), float(c.expected())
                drift = abs(a - e) / abs(e) if e else abs(a - e)
                ok = drift <= c.tol if c.tol else round(abs(a - e), 2) == 0
                rec |= {"actual": f"{a:.5f}", "expected": f"{e:.5f}", "drift_pct": f"{drift * 100:.6f}",
                        "status": "PASS" if ok else "FAIL"}
                failed += 0 if ok else 1
                print(f"   {'PASS' if ok else 'FAIL'}  {c.title:<70} {a:>18,.2f}  vs {e:>18,.2f}  {drift * 100:8.4f}%")
            except Exception as exc:   # one broken check must not hide the rest
                failed += 1
                rec["status"] = "ERROR"
                print(f"   ERROR {c.title:<70} {str(exc).splitlines()[0][:90]}")
            rows.append(rec)
        print()

    _lib.log(rows)
    ran = len(rows) - skipped
    print(f"{ran - failed} of {ran} passed" + (f", {skipped} skipped" if skipped else "")
          + f" · {time.time() - started:.0f}s · logged to tests/results.csv")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
