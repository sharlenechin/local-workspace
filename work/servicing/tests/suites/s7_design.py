"""7 · Design - the mock in design/ shows the query's real numbers, and its controls hold up.

The design is what reviewers sign off. If its embedded data drifted from the
query, people would approve numbers the dashboard will never show. Values are
rounded to whole euros in the mock, so money totals carry a 0.001% tolerance
(about EUR 3,500 on EUR 347m, against at most EUR 920 of rounding).
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess

from _lib import DESIGN_MAIN, HERE, Check, Settings, col_sum, dashboard

SUITE = "design"
_CACHE: dict = {}


def _embedded() -> dict:
    """The row-level array the mock computes everything from."""
    if not _CACHE:
        html = DESIGN_MAIN.read_text()
        _CACHE["rd"] = json.loads(re.search(r"const RD = (\{.*?\});\n", html).group(1))
    return _CACHE["rd"]


def _rows() -> list:
    """The mock's rows, capped like the query when back-testing. Mock months are
    indexed 0..n from the first month in the data."""
    rows = _embedded()["rows"]
    if Settings.as_of:
        n = dashboard()["reporting_month"].astype(str).str[:7].nunique()
        rows = [r for r in rows if r[0] < n]
    return rows


def _mock_sum(i: int) -> float:
    return float(sum(r[i] for r in _rows()))


def _toggles() -> float:
    """Run the mock's own logic through every control combination (node). 0 = no errors."""
    if not shutil.which("node"):
        raise RuntimeError("node is not installed; install it to run the toggle sweep")
    out = subprocess.run(["node", str(HERE / "design_sweep.js"), str(DESIGN_MAIN)] + (["--full"] if Settings.full else []), capture_output=True, text=True, timeout=600)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:300] or out.stdout.strip()[:300])
    return float(json.loads(out.stdout.strip().splitlines()[-1])["problems"])


# K column -> the RD row column holding the same behaviour (collected, dbt new, lost, first collection, three)
K_TO_ROW = {1: 15, 2: 16, 3: 17, 4: 18, 5: 19}


def _mock_kpi(col: int, n: int):
    """The mock's book-level average for one case behaviour: the n months before the latest month, averaged over the
    months that exist. Like-for-like, as Sigma and the mock (2026-10-14): only portfolios that reported in the latest
    month count in the months before it, so a late servicer (Massey, Sep 2026) leaves both sides."""
    def f() -> float:
        rows = _embedded()["rows"]
        mi = len(_month_index()) - 1
        live = {r[5] for r in rows if r[0] == mi}
        months = range(max(0, mi - n), mi) if n else [mi]
        prior = [sum(r[K_TO_ROW[col]] for r in rows if r[0] == k and r[5] in live and r[14]) for k in months]
        return sum(prior) / len(prior)
    return f


def _sigma_kpi(column: str, n: int):
    """The same KPI the way Sigma will compute it from the query, at the latest
    month: Sum(window sum) / Max(months in case window)."""
    def f() -> float:
        d = dashboard()
        last = d[d.reporting_month == d.reporting_month.max()]
        months = 1 if n == 1 else float(last[f"months_in_case_l{n}m_window"].max())
        return float(last[f"{column}_l{n}m_sum"].sum()) / months
    return f


def _definitions_drift() -> float:
    """Terms whose definition on the dashboard differs from docs/definitions.csv (or is missing)."""
    import csv
    from _lib import SERVICING
    on_page = {d["term"]: d for d in json.loads(re.search(r"\n    const DEFS = (\[.*?\]);\n", DESIGN_MAIN.read_text()).group(1))}
    rows = list(csv.DictReader((SERVICING / "docs" / "definitions.csv").open()))
    drift = [r["term"] for r in rows if r["term"] not in on_page
             or any(on_page[r["term"]][k] != r[k] for k in ("definition", "formula", "caveat", "aliases"))]
    if drift:
        print(f"      out of date on the dashboard: {drift[:5]} - run docs/build_definitions.py")
    return float(len(drift) + abs(len(on_page) - len(rows)))


def _month_index() -> list:
    return sorted(dashboard()["reporting_month"].astype(str).str[:7].unique())


CHECKS = [
    Check(f"{SUITE}.rows", "Mock carries one row per portfolio-month",
          actual=lambda: float(len(_rows())), expected=lambda: float(len(dashboard())), tol=0,
          proves="The mock is built from the same grain as the query."),
    Check(f"{SUITE}.collections", "Mock collections = query collections",
          actual=lambda: _mock_sum(6), expected=lambda: col_sum("collections_sum"), tol=1e-5,
          proves="Every money figure in the mock derives from the real query output."),
    Check(f"{SUITE}.underwriting", "Mock underwriting forecast = query",
          actual=lambda: _mock_sum(11), expected=lambda: col_sum("underwriting_forecast_sum"), tol=1e-5,
          proves="The benchmark toggle in the mock shows the real plan."),
    Check(f"{SUITE}.collected_cases", "Mock collected cases = query",
          actual=lambda: _mock_sum(15), expected=lambda: col_sum("collected_cases_count"), tol=0,
          proves="The Cases page counts are the mart's."),
    Check(f"{SUITE}.jitter_out", "Mock jitter out = query",
          actual=lambda: _mock_sum(29), expected=lambda: col_sum("collected_cases_jitter_out_count"), tol=0,
          proves="The newest behaviour is wired into the mock."),
    Check(f"{SUITE}.status_matches_query", "The mock's data-status line matches the query's status columns",
          actual=lambda: float(_embedded()["status"]["loadingN"] * 1000 + _embedded()["status"]["asOfN"]),
          expected=lambda: float(dashboard()["loading_month_portfolio_count"].iloc[0] * 1000 + dashboard()["data_as_of_portfolio_count"].iloc[0]),
          tol=0, today_only=True, proves="Reviewers see the real 'still loading' message, not an invented one."),
    Check(f"{SUITE}.definitions_match_csv", "The Data & Definitions page shows exactly docs/definitions.csv",
          actual=_definitions_drift, expected=lambda: 0.0, tol=0,
          proves="One source of truth: the dashboard, DATA-DEFINITIONS.md and the Sigma agent cannot disagree on what a term means."),
    Check(f"{SUITE}.toggle_sweep", "Every control combination renders without an error or a blank value",
          actual=_toggles, expected=lambda: 0.0, tol=0,
          proves="Month, page, window, benchmark, grain (any order), view, sort, measure and definitions search: no state throws, shows NaN or leaves a hole unfilled, and every metric label on screen has a data definition."),
] + [
    Check(f"{SUITE}.cases_kpi_{name}_l{n}m", f"Cases KPI, {label}, L{n}M average: mock = Sigma formula on the query",
          actual=_mock_kpi(col, n), expected=_sigma_kpi(column, n), tol=1e-9,
          proves="The window average the reviewers see is exactly what Sigma will show: Sum(window) / Max(months in case window).")
    for name, col, column, label in (("collected", 1, "collected_cases", "collected cases"),
                                     ("first", 4, "collected_cases_first_collection", "new"),
                                     ("lost", 3, "collected_cases_lost", "lost"))
    for n in (1, 3, 12)
]


def _boards_failing() -> float:
    """Every other artboard's script (the build map, the page wrappers) runs: a stray quote once broke the build map
    on the canvas while the main board's sweep stayed green."""
    if not shutil.which("node"):
        raise RuntimeError("node is not installed; install it to run the artboard check")
    bad = 0
    for board in sorted(DESIGN_MAIN.parent.glob("*.dc.html")):
        if board == DESIGN_MAIN:
            continue
        m = re.search(r'<script type="text/x-dc" data-dc-script[^>]*>(.*?)</script>', board.read_text(), re.S)
        if not m:
            continue
        js = "class DCLogic {}\n" + m.group(1) + "\nconst c = new Component(); c.props = {}; c.state = {}; c.renderVals();\n"
        bad += subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=60).returncode != 0
    return float(bad)


CHECKS.append(Check(f"{SUITE}.artboards_run", "Every other artboard's script (build map, page wrappers) runs without an error",
                    actual=_boards_failing, expected=lambda: 0.0, tol=0,
                    proves="The canvas shows every board: no syntax slip (a stray apostrophe) hides one."))
