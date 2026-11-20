"""9 · Every control setting - the live tiles with the controls moved, not just at their defaults.

Suite 6 reads the dashboard as it opens. This one asks Sigma to export a tile as a viewer
who changed the controls would see it (the export's `parameters`: control id -> value),
and checks each figure against SQL written here on the warehouse facts and the mart.
It covers every Window (This month, Previous month, Last 3/6/12 months), every Benchmark,
every §2 Grain including Seller, the book cards, the Data Quality page at every Window, and
the workbook spec itself: the live query is the one in this folder, Clear Filters clears
every filter, the manager's review (2026-10-09) is applied, and the user's hand edits
(sigma_build/user_edits.json) are in the live workbook.

Window arithmetic, for the selected month M (the last complete month):
  This month      = M                     previous = M-1
  Previous month  = M-1                   previous = M-2
  Last n months   = M-n .. M-1            previous = M-2n .. M-n-1
Money tiles show the window's TOTAL; averages divide by the months that exist; case
counts are the average month over the months WITH a case feed.
Skipped by --offline and --as-of (a live tile cannot be rewound).
"""
from __future__ import annotations

import json
import math
import re

import pandas as pd

import _lib
from _lib import Check, actuals_keys, cap, tile, warehouse
from suites.s4_windows import ACC, ACTUALS, COLL, UW, _case_base, _forecast_source, _lfl_base, _monthly, _reconciled_base

SUITE = "controls"
WINDOWS = {   # window -> (current months, previous months), as offsets from the selected month
    "This month": ((0, 0), (-1, -1)),
    "Previous month": ((-1, -1), (-2, -2)),
    "Last 3 months": ((-3, -1), (-6, -4)),
    "Last 6 months": ((-6, -1), (-12, -7)),
    "Last 12 months": ((-12, -1), (-24, -13)),
}
SINGLE = {"This month", "Previous month"}
# The overview cards' Comparison Window (the user, 2026-10-12): the cards show the latest reporting month (offset 0),
# and the comparison is the month before or the average month of the window before it. Data Quality keeps WINDOWS.
CMP = {"Previous month": (-1, -1), "Last 3 months": (-3, -1), "Last 6 months": (-6, -1), "Last 12 months": (-12, -1)}


CMP_LEN = {"Previous month": 1, "Last 3 months": 3, "Last 6 months": 6, "Last 12 months": 12}


def _lfl(base: str) -> str:
    """Like-for-like, as the dashboard's cards (2026-10-14): the comparison months count only portfolios that reported
    in the latest month. Sigma sums the latest rows' own window sums, so a servicer late with the latest month (Massey,
    Sep 2026) drops out of both sides instead of making the month look worse."""
    return f"""SELECT * FROM ({base}) WHERE portfolio_sk IN (
      SELECT DISTINCT portfolio_sk FROM ({actuals_keys()}) WHERE period_end_date = {cap()})"""


def _full(base: str, window: str, value):
    """Blank (NaN) unless every month of the window has a value (the user, 2026-10-12): L12M before Dec 2026 has 8."""
    a, b = CMP[window]
    return value() if _months(_lfl(base), a, b) >= CMP_LEN[window] else math.nan


def _cavg(base: str, window: str) -> float:
    """The comparison window's average month, over its months; blank unless every month exists."""
    a, b = CMP[window]
    return _full(base, window, lambda: _total(_lfl(base), a, b) / _months(_lfl(base), a, b))


def _blankable(actual_fn, expected_fn):
    """A blank expected value passes only if the dashboard shows a blank too (actual 0 vs expected 0); otherwise the
    two numbers are compared as usual. The runner cannot compare NaN, so blanks are mapped to 0 and 1."""
    cache = {}
    def both():
        if not cache:
            cache["e"], cache["a"] = expected_fn(), actual_fn()
        return cache["a"], cache["e"]
    def actual():
        a, e = both()
        return (0.0 if math.isnan(a) else 1.0) if math.isnan(e) else a
    def expected():
        a, e = both()
        return 0.0 if math.isnan(e) else e
    return actual, expected
# The mart as the dashboard can show it: only portfolio-months the servicer reported. A case feed can arrive before its
# portfolio report (Massey, Sep 2026), and the dashboard shows those cases once the report lands (2026-10-14).
MART = """(SELECT m.* FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS m
  WHERE EXISTS (SELECT 1 FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
                WHERE f.portfolio_sk = m.portfolio_sk AND f.period_end_date = m.period_end_date))"""


def _span(col: str, a: int, b: int) -> str:
    return f"{col} BETWEEN LAST_DAY(DATEADD(month, {a}, {cap()})) AND LAST_DAY(DATEADD(month, {b}, {cap()}))"


def _total(base: str, a: int, b: int) -> float:
    return warehouse(f"SELECT SUM(v) FROM ({base}) WHERE {_span('period_end_date', a, b)}")


def _months(base: str, a: int, b: int) -> float:
    """Months in the range that have a value: the divisor the dashboard uses."""
    return warehouse(f"SELECT COUNT(DISTINCT IFF(v IS NOT NULL, period_end_date, NULL)) FROM ({base}) WHERE {_span('period_end_date', a, b)}")


def _avg(base: str, window: str, prev: bool = False) -> float:
    a, b = WINDOWS[window][1 if prev else 0]
    t = _total(base, a, b)
    return t if window in SINGLE else t / _months(base, a, b)


def _live(element: str, column: str, **params: str) -> float:
    """The tile's latest value with the controls set."""
    df = tile(element, params=params or None)
    return float(pd.to_numeric(df[column], errors="coerce").iloc[-1]) * (1e6 if element in _lib.MILLIONS else 1)   # in euros


def _servicer() -> str:
    return _monthly("f.amount", _forecast_source("FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY"))


def _net() -> str:
    return _monthly("f.net_cash_recoveries", ACTUALS)


BENCH = {"Servicer": (_lfl_base, _servicer), "Accounting": (COLL, ACC), "Underwriting": (COLL, UW)}

# Seller, independently of the dashboard query: the deal on the portfolio's facts, then the deal's seller.
SELLER_MAP = """SELECT f.portfolio_sk, COALESCE(MAX(d.seller_name), 'Unknown') AS seller
  FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
  LEFT JOIN PROD.NPL_COMMON.DIM_DEAL AS d ON d.deal_sk = f.deal_sk
  GROUP BY 1"""


def _seller_groups_wrong() -> float:
    """§2 Performance grouped by Seller: groups whose latest-month collections differ from the warehouse by over a cent."""
    live = tile("bp_perf", params={"P-Perf-Grain": "Seller"})
    live = live.set_index("group")["total collections"].astype(float)
    sql = f"""SELECT m.seller, SUM(c.v) AS v FROM ({COLL()}) AS c JOIN ({SELLER_MAP}) AS m ON m.portfolio_sk = c.portfolio_sk
      WHERE c.period_end_date = {cap()} GROUP BY 1"""
    truth = _lib.datalake.q(sql, lower=True).set_index("seller")["v"].astype(float)
    both = pd.concat([live.rename("live"), truth.rename("truth")], axis=1)
    # Blank on both sides is agreement: a seller whose only servicer has not reported the latest month (Arrow Global,
    # Massey, Sep 2026) reads blank in the dashboard and has no money in the warehouse either (2026-10-14).
    one_blank = both["live"].isna() != both["truth"].isna()
    return float(((both["live"] - both["truth"]).abs() > 0.01).sum() + one_blank.sum())


def _grain_total(grain: str) -> float:
    return float(tile("bp_perf", params={"P-Perf-Grain": grain})["total collections"].astype(float).sum())


# One group's change, worked out from the warehouse: Portugal's latest month against its L3M average month (the window's
# total ÷ 3, a missing portfolio-month counting as 0).
PT_COLL = f"""SELECT c.portfolio_sk, c.period_end_date, c.v FROM ({{coll}}) AS c
  JOIN (SELECT DISTINCT portfolio_sk FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY WHERE country_id = 'PT') AS p
    ON p.portfolio_sk = c.portfolio_sk"""


def _pt_change() -> float:
    base = PT_COLL.format(coll=COLL())
    return _total(base, 0, 0) / (_total(_lfl(base), -3, -1) / 3) - 1


def _pt_live() -> float:
    df = tile("bp_perf", params={"P-Perf-Grain": "Country", "P-Perf-Window": "Last 3 months"}).set_index("group")
    return float(df.loc["Portugal", "total collections vs window"])


def _spec() -> dict:
    return json.loads(_lib._sigma("workbooks", "spec", "get", "--params", json.dumps({"workbookId": _lib.WORKBOOK})))["document"]


def _hover_duplicates() -> float:
    """Names shown twice in any chart's hover: the plotted columns Sigma shows by itself (axes, colour) unless hidden
    from the tooltip, plus the extra tooltip columns. Collections appeared twice on the forecast chart (2026-10-12)."""
    dup = 0
    for e in _spec()["elements"]:
        if not e.get("kind", "").endswith("-chart") or e["kind"] == "kpi-chart":
            continue
        cols = {x["id"]: x for x in e.get("columns", [])}
        plotted = json.dumps([e.get(k) for k in ("xAxis", "yAxis", "color")])
        shown = [x for i, x in cols.items() if f'"{i}"' in plotted and x.get("tooltip") != "hidden"]
        shown += [cols[t["id"]] for t in e.get("tooltip", {}).get("columns", []) if t["id"] in cols]
        names = [str(x.get("name", x["id"])).strip().lower() for x in shown]
        dup += len(names) - len(set(names))
    return float(dup)


def _header_widths() -> float:
    """How many different widths and rows the seven header filters have (1 = all equal, on one line; the user,
    2026-10-12). Sigma fixes a header at 24 columns: seven filters and Clear Filters take 3 each."""
    import re
    lay = _spec()["layout"]; hdr = lay[lay.index('id="hdr"'):lay.index("</Panel>", lay.index('id="hdr"'))]
    found = re.findall(r'elementId="(f_[a-z]+)" gridColumn="(\d+) / (\d+)" gridRow="([^"]+)"', hdr)
    if len(found) != 7 or max(int(b) for _e, _a, b, _r in found) > 25:
        return 99.0
    return float(len({int(b) - int(a) for _e, a, b, _r in found}) * len({r for *_x, r in found}))


def _source_duplicates() -> float:
    """Duplicate rows in the two chart sources, at their grain (the user, 2026-10-12: no duplicates anywhere)."""
    cb, fc = tile("cb_src", tries=240), tile("fc_src", tries=240)
    return float(cb.duplicated(["portfolio_name", "reporting_month", "behaviour"]).sum()
                 + fc.duplicated(["row_kind", "portfolio_name", "anchor_month", "chart_month", "series"]).sum())


def _filter_value_variants() -> float:
    """Filter values that would appear twice: a portfolio under two deals, sellers, servicers or countries, or one name
    spelt two ways (case or spaces)."""
    d = _lib.dashboard()
    bad = sum(int((d.groupby("portfolio_name")[c].nunique() > 1).sum()) for c in ("deal", "seller", "servicer_group", "country_name"))
    bad += sum(d[c].nunique() - d[c].astype(str).str.strip().str.upper().nunique() for c in ("deal", "seller", "portfolio_name", "country_name"))
    return float(bad)


def _filters_not_cleared() -> float:
    els = {e["id"]: e for e in _spec()["elements"]}
    filters = {e["controlId"] for e in els.values() if e.get("kind") == "control" and e.get("filters")}
    filters |= {els["f_month"]["controlId"]} if "f_month" in els else set()
    cleared = {x["scope"].get("controlId") for a in els["h_clear"].get("actions", []) for x in a["effects"]}
    return float(len(filters - cleared))


def _live_sql_differs() -> float:
    live = next(e for e in _spec()["elements"] if e["id"] == "src")["source"]["statement"]
    return float(live.strip() != _lib.PROPOSED_SQL.read_text().strip())


def _user_edits_missing() -> float:
    """Fields from sigma_build/user_edits.json that the live workbook does not carry."""
    edits = json.loads((_lib.SERVICING / "sigma_build" / "user_edits.json").read_text())
    els = {e["id"]: e for e in _spec()["elements"]}
    missing = 0
    for eid, fields in edits["elements"].items():
        for path, value in fields.items():
            node = els.get(eid, {})
            for k in path.split("."):
                node = node.get(k) if isinstance(node, dict) else None
            same = node == value or (isinstance(node, str) and isinstance(value, str) and node.strip() == value.strip())
            missing += 0 if same else 1
    missing += sum(1 for e in edits.get("extra_elements", []) if e["id"] not in els)
    return float(missing)


CHECKS: list[Check] = []
LATEST = lambda base: _total(base, 0, 0)
DEAL = "Intrum - 12/2025 (Heimdall)"   # the largest deal, with a case feed: it reaches every card and both charts


def _pair(cid: str, desc: str, el: str, params: dict, exp_value, exp_compared, proves: str) -> list:
    """Two checks per card: its value (the latest reporting month) and its comparison (the Comparison Window)."""
    act, exp = _blankable(lambda: _live(el, "previous window", **params), exp_compared)
    return [Check(f"{SUITE}.{cid}", f"{desc}: the latest reporting month", actual=lambda: _live(el, "v", **params),
                  expected=exp_value, tol=1e-9, live=True, proves="The card is the latest month, whatever the Comparison Window."),
            Check(f"{SUITE}.{cid}.compared", f"{desc}: what it is compared with (blank if the window is short)", actual=act,
                  expected=exp, tol=1e-9, live=True, proves=proves + " A window without all its months shows no comparison.")]


for w in CMP:
    P, C = {"P-Window": w}, {"C-Window": w}
    CHECKS += _pair(f"collections.{w}", f"Total Collections, Comparison Window = {w}", "p_coll", P,
                    lambda: LATEST(COLL()), lambda w=w: _cavg(COLL(), w), "A month is compared with the window's average month.")
    CHECKS += _pair(f"net.{w}", f"Total Net Collections, Comparison Window = {w}", "p_net", P,
                    lambda: LATEST(_net()), lambda w=w: _cavg(_net(), w), "Net collections follow the same rule.")
    CHECKS += _pair(f"collected_cases.{w}", f"Collected Cases, Comparison Window = {w}", "c_cc", C,
                    lambda: LATEST(_case_base("collected_cases_count")), lambda w=w: _cavg(_case_base("collected_cases_count"), w),
                    "The average month over the months WITH a case feed.")

L3 = "Last 3 months"
for bench, (num, den) in BENCH.items():
    PB = {"P-Window": L3, "Bench": bench}
    CHECKS += _pair(f"forecast.{bench}", f"Total Forecast, L3M, Benchmark = {bench}", "p_fc", PB,
                    lambda d=den: LATEST(d()), lambda d=den: _cavg(d(), L3), "The Benchmark switch picks the right forecast, compared with its average month.")
    CHECKS += _pair(f"vs_forecast.{bench}", f"Collections as % of Forecast, L3M, Benchmark = {bench}", "p_vs", PB,
                    lambda n=num, d=den: LATEST(n()) / LATEST(d()), lambda n=num, d=den: _total(_lfl(n()), -3, -1) / _total(_lfl(d()), -3, -1),
                    "Ratios compare with the window's totals' ratio, never an average of ratios; Servicer stays like-for-like.")
    CHECKS += _pair(f"gap.{bench}", f"Collections Minus Forecast, L3M, Benchmark = {bench}", "p_gap", PB,
                    lambda n=num, d=den: LATEST(n()) - LATEST(d()), lambda n=num, d=den: _cavg(n(), L3) - _cavg(d(), L3),
                    "The shortfall or surplus in euro, a month against an average month.")

# Every Cases card, every Comparison Window: the latest month, against the window's average month (months with a feed).
CASE_TILES = {   # tile -> (mart column, in euro?)
    "c_first": ("collected_cases_first_collection_count", False),
    "c_lost": ("collected_cases_lost_count", False), "c_three": ("collected_cases_three_consecutive_months_count", False),
    "c_ce": ("collected_amount_local_sum", True),
}
for w in CMP:
    C = {"C-Window": w}
    for eid, (col, eur) in CASE_TILES.items():
        CHECKS += _pair(f"{eid}.{w}", f"Cases card {eid}, Comparison Window = {w}", eid, C,
                        lambda c=col, x=eur: LATEST(_case_base(c, x)), lambda c=col, x=eur, w=w: _cavg(_case_base(c, x), w),
                        "The average month over the months with a case feed.")
    # Fresh is dbt's new minus New (the user, 2026-10-13): paid before, then two quiet months. The two never overlap.
    CHECKS += _pair(f"c_new.{w}", f"Cases card c_new (Fresh), Comparison Window = {w}", "c_new", C,
                    lambda: LATEST(_case_base("collected_cases_new_count")) - LATEST(_case_base("collected_cases_first_collection_count")),
                    lambda w=w: _cavg(_case_base("collected_cases_new_count"), w) - _cavg(_case_base("collected_cases_first_collection_count"), w),
                    "Fresh excludes New: dbt's new less first collections, against the same in the window's average month.")
    CHECKS += _pair(f"c_nl.{w}", f"Net Change in Collected Cases, Comparison Window = {w}", "c_nl", C,
                    lambda: LATEST(_case_base("collected_cases_new_count")) - LATEST(_case_base("collected_cases_lost_count")),
                    lambda w=w: _cavg(_case_base("collected_cases_new_count"), w) - _cavg(_case_base("collected_cases_lost_count"), w),
                    "New plus fresh, minus lost (dbt's new minus lost), against the same in the window's average month.")
    CHECKS += _pair(f"c_cpe.{w}", f"Avg Monthly Collection per Case, Comparison Window = {w}", "c_cpe", C,
                    lambda: LATEST(_case_base("collected_amount_local_sum", True)) / LATEST(_case_base("collected_cases_count")),
                    lambda w=w: _full(_case_base("collected_cases_count"), w, lambda: _total(_lfl(_case_base("collected_amount_local_sum", True)), *CMP[w]) / _total(_lfl(_case_base("collected_cases_count")), *CMP[w])),
                    "Euro per paying case: total euro over total cases in the window, never an average of ratios.")

# The book (stocks) is read at the latest reporting month, whatever the Comparison Window (2026-10-12).
BOOK = {"c_everc": "cases_ever_collected_count"}   # Cases never collected removed (the user's artifact, 2026-10-12)
for w in ("Previous month", "Last 6 months"):
    for eid, col in BOOK.items():
        CHECKS.append(Check(f"{SUITE}.{eid}.{w}", f"{eid}, Comparison Window = {w}: read at the latest reporting month",
                            actual=lambda e=eid, w=w: _live(e, "v", **{"C-Window": w}),
                            expected=lambda c=col: warehouse(f"SELECT SUM({c}) FROM {MART} WHERE period_end_date = {cap()}"),
                            tol=0, live=True, proves="Ever collected is a stock at one month-end: the latest one."))
    CHECKS.append(Check(f"{SUITE}.c_ever.{w}", f"Cases Ever Collected, % of Book, Comparison Window = {w}",
                        actual=lambda w=w: _live("c_ever", "v", **{"C-Window": w}),
                        expected=lambda: warehouse(f"SELECT SUM(cases_ever_collected_count) / SUM(cases_on_book_count) FROM {MART} WHERE period_end_date = {cap()}"),
                        tol=1e-4, live=True, proves="The share at the latest month-end (the export rounds the % to 6 places)."))

# The Cases chart (the user, 2026-10-12 and 2026-10-13), read from cb_src: one row per portfolio-month-behaviour, so
# the export has a Behaviour column. Count (c_chart) and Collections (c_money) stack four paying groups that split
# collected cases exactly, with Lost below zero; Avg Collection per Case (c_avg) sets the same groups side by side
# against All Collected Cases. Each group is the mart's: three straight from dbt, Fresh and Two of Three
# Months by subtraction. Lost euro is what they paid in their last paying month.
from suites.s5_cases import _mart_eur   # noqa: E402
CNT, EURC = "collected_cases_count", "collected_amount_local_sum"
FRESH, FRESH_E = "collected_cases_new_count", "collected_amount_local_new_sum"
FIRST, FIRST_E = "collected_cases_first_collection_count", "collected_amount_local_first_collection_sum"
THREE, THREE_E = "collected_cases_three_consecutive_months_count", "collected_amount_local_three_consecutive_months_sum"
LOST, LOST_E = "collected_cases_lost_count", "collected_amount_local_lost_last_month_sum"
# name: (count as +/- mart columns, euro as +/- mart columns)
CASE_LINES = {"new": ([(1, FIRST)], [(1, FIRST_E)]),
              "fresh": ([(1, FRESH), (-1, FIRST)], [(1, FRESH_E), (-1, FIRST_E)]),
              "two of three months": ([(1, CNT), (-1, FRESH), (-1, THREE)], [(1, EURC), (-1, FRESH_E), (-1, THREE_E)]),
              "three consecutive months": ([(1, THREE)], [(1, THREE_E)]),
              "lost": ([(-1, LOST)], [(-1, LOST_E)])}
PAYING = [n for n in CASE_LINES if n != "lost"]
VALUE_COL = {"c_chart": "cases", "c_money": "collections (€)", "c_avg": "average collection per case (€)"}


def _names(df: pd.DataFrame) -> pd.Series:
    return df["behaviour"].str.replace("\u200b", "", regex=False).str.lower()   # the invisible stack-order keys


def _series(el: str, name: str | list[str], params: dict | None = None) -> float:
    df = tile(el, params=params)
    pick = _names(df).isin([name] if isinstance(name, str) else name)
    return float(pd.to_numeric(df.loc[pick, VALUE_COL[el]], errors="coerce").fillna(0).sum()) * (1e6 if el in _lib.MILLIONS else 1)


def _mart_count(terms) -> float:
    return warehouse(f"SELECT SUM({' + '.join(f'({k}) * {c}' for k, c in terms)}) FROM {MART} WHERE period_end_date <= {cap()}")


def _mart_euro(terms) -> float:
    return sum(k * warehouse(_mart_eur(c)) for k, c in terms)


def _tally_gaps(el: str) -> float:
    """Months where the four paying groups do not add up to the month's collected cases (or collections from cases)."""
    df = tile(el)
    df = df.assign(n=_names(df), v=pd.to_numeric(df[VALUE_COL[el]], errors="coerce").fillna(0) * (1e6 if el in _lib.MILLIONS else 1))
    parts = df[df["n"].isin(PAYING)].groupby("reporting month")["v"].sum()
    bar = df.groupby("reporting month")["v"].sum()   # every segment, Lost and the spacer too: what Sigma writes over the bar
    d = _lib.dashboard()
    d = d[d["collected_cases_count"].notna()]
    want = d.groupby(pd.to_datetime(d["reporting_month"]).dt.strftime("%b %Y"))["collected_cases_count" if el == "c_chart" else "collected_cases_amount_sum"].sum()
    tol = 0 if el == "c_chart" else 0.01
    return float(sum(1 for m in want.index if abs(parts.get(m, 0) - want[m]) > tol or abs(bar.get(m, 0) - want[m]) > tol)
                 + sum(1 for m in parts.index if m not in want.index))


def _avg_gaps() -> float:
    """Months x behaviours where the Avg tab is not that group's collections / its cases, from the dashboard query."""
    df = tile("c_avg")
    df = df.assign(n=_names(df), v=pd.to_numeric(df[VALUE_COL["c_avg"]], errors="coerce"))
    d = _lib.dashboard()
    d = d[d["collected_cases_count"].notna()].assign(month=lambda x: pd.to_datetime(x["reporting_month"]).dt.strftime("%b %Y"))
    g = d.groupby("month").sum(numeric_only=True)
    want = {"all collected cases": (g.collected_cases_amount_sum, g.collected_cases_count),
            "new": (g.collected_cases_first_collection_amount_sum, g.collected_cases_first_collection_count),
            "fresh": (g.collected_cases_new_amount_sum - g.collected_cases_first_collection_amount_sum,
                                  g.collected_cases_new_count - g.collected_cases_first_collection_count),
            "two of three months": (g.collected_cases_amount_sum - g.collected_cases_new_amount_sum - g.collected_cases_three_consecutive_months_amount_sum,
                                    g.collected_cases_count - g.collected_cases_new_count - g.collected_cases_consistent_3m_count),
            "three consecutive months": (g.collected_cases_three_consecutive_months_amount_sum, g.collected_cases_consistent_3m_count),
            "lost": (g.collected_cases_lost_last_month_amount_sum, g.collected_cases_lost_count)}
    bad = 0
    for name, (eur, n) in want.items():
        for m in g.index:
            got = df.loc[(df["n"] == name) & (df["reporting month"] == m), "v"]
            exp = eur[m] / n[m] if n[m] else None
            if exp is None:
                bad += len(got.dropna()) > 0
            else:
                bad += len(got) != 1 or abs(float(got.iloc[0]) - exp) > 0.01
    return float(bad)


for name, (count_terms, eur_terms) in CASE_LINES.items():
    CHECKS.append(Check(f"{SUITE}.count_chart.{name}", f"Cases chart, Count tab: the {name} segment is the mart's",
                        actual=lambda n=name: _series("c_chart", n),
                        expected=lambda t=count_terms: _mart_count(t),
                        tol=0, live=True, proves="Every group is a segment of the one chart; none falls through to blank. Lost is negative."))
    CHECKS.append(Check(f"{SUITE}.money_chart.{name}", f"Cases chart, Collections tab: the {name} segment is the euro that group paid",
                        actual=lambda n=name: _series("c_money", n),
                        expected=lambda t=eur_terms: _mart_euro(t), tol=1e-6, live=True,
                        proves="The Collections tab shows the euro of the same groups the Count tab counts, at each month's rate."))
CHECKS += [
    Check(f"{SUITE}.count_chart_tallies", "Cases chart, Count tab: each month's four paying groups, and the total over the bar, are that month's collected cases",
          actual=lambda: _tally_gaps("c_chart"), expected=lambda: 0.0, tol=0, live=True,
          proves="No paying case is missing from the bars or in two of them, and the number over the bar is not netted by Lost (the user, 2026-10-13)."),
    Check(f"{SUITE}.money_chart_tallies", "Cases chart, Collections tab: each month's four paying groups, and the total over the bar, are that month's collections from cases",
          actual=lambda: _tally_gaps("c_money"), expected=lambda: 0.0, tol=0, live=True,
          proves="The euro stack is the Collections card's figure for every month, to the cent."),
    Check(f"{SUITE}.stacked_tabs_no_total_row", "Cases chart: All Collected Cases is not a segment of the Count or Collections tab",
          actual=lambda: float(sum((_names(tile(e)) == "all collected cases").sum() for e in ("c_chart", "c_money"))),
          expected=lambda: 0.0, tol=0, live=True, proves="The total is the stack's height, never a segment that would double it."),
    Check(f"{SUITE}.avg_chart", "Cases chart, Average Collection per Case tab: every group, every month, is its collections ÷ its cases",
          actual=_avg_gaps, expected=lambda: 0.0, tol=0, live=True,
          proves="A ratio of sums per group and month, never an average of averages; All Collected Cases is the month's overall figure."),
]


# Cases §2 Performance: every "vs window" cell, every group, recomputed from the query (2026-10-13). Until then only the
# column names and the value columns were checked, and a missing bracket showed -100% for every group on Avg Monthly
# Collection per Case and garbage on Net Change. (name, latest month from rows, window base from rows, ratio?)
C_PERF_CHANGE = {
    "collected cases": ("collected_cases_count", "collected_cases"),
    "collections": ("collected_cases_amount_sum", "collected_cases_amount"),
    "three consecutive months": ("collected_cases_consistent_3m_count", "collected_cases_three_consecutive_months"),
    "new": ("collected_cases_first_collection_count", "collected_cases_first_collection"),
    "dbt new": ("collected_cases_new_count", "collected_cases_new"),   # New plus Fresh; the Fresh column is this minus New
    "lost": ("collected_cases_lost_count", "collected_cases_lost"),
    "book": ("cases_on_book_count", "cases_on_book"),   # denominator of Collected cases, % of book (2026-10-14)
}


GRAIN_COL = {"Country": "country_name", "Servicer": "servicer_group", "Seller": "seller", "Deal": "deal", "Portfolio": "portfolio_name"}


def _perf_change_gaps(window: str, grain: str = "Country") -> float:
    n = {"Previous month": 1, "Last 3 months": 3, "Last 6 months": 6, "Last 12 months": 12}[window]
    d = _lib.dashboard()
    d = d[d["reporting_month"] == d["reporting_month"].max()]
    live = tile("bc_perf", params={"C-Perf-Grain": grain, "C-Perf-Window": window}).set_index("group")
    bad = 0
    for g, r in d.groupby(GRAIN_COL[grain]):
        months = 1 if n == 1 else r[f"months_in_case_l{n}m_window"].max()
        if pd.isna(months) or months == 0:   # no case feed in the group: every cell blank
            months, full = 1, False
        else:
            full = n == 1 or months >= n
        now = {k: r[a].sum(min_count=1) for k, (a, _) in C_PERF_CHANGE.items()}   # no feed: blank, not 0
        tot = {k: r[f"{b}_l{n}m_sum"].sum(min_count=1) for k, (_, b) in C_PERF_CHANGE.items()}
        base = {k: v / months for k, v in tot.items()}
        now["avg monthly collection per case"] = now["collections"] / now["collected cases"] if now["collected cases"] else None
        base["avg monthly collection per case"] = tot["collections"] / tot["collected cases"] if tot["collected cases"] else None
        # A rate: the window is its totals' ratio, the change in points (2026-10-14).
        now["collected cases, % of book"] = now["collected cases"] / now["book"] if now["book"] else None
        base["collected cases, % of book"] = tot["collected cases"] / tot["book"] if tot["book"] else None
        now.pop("book"); base.pop("book")
        for x in (now, base):
            dbt_new = x.pop("dbt new")
            x["fresh"] = dbt_new - x["new"]
            x["net change in collected cases"] = dbt_new - x["lost"]
        for k in now:
            diff = k == "net change in collected cases"   # signed: a difference in cases, not a % (2026-10-13)
            pts = k == "collected cases, % of book"
            got = pd.to_numeric(pd.Series([live.loc[g, f"{k} vs window"]]), errors="coerce").iloc[0] if g in live.index else None
            if not full or now[k] is None or base[k] is None or pd.isna(now[k]) or pd.isna(base[k]):
                want = None
            elif diff:
                want = now[k] - base[k]
            elif pts:
                want = 100 * (now[k] - base[k])
            else:
                want = None if base[k] <= 0 else now[k] / base[k] - 1   # a % of a zero or negative base is blank
            if want is None:
                bad += got is not None and not pd.isna(got)
            else:
                # the export cuts points to 4 decimals and a % to ~6 significant digits (5.000006 for +500% on a tiny portfolio)
                tol = 1.5e-4 if pts else 1e-5 * max(1, abs(want))
                bad += got is None or pd.isna(got) or abs(got - want) > tol
    return float(bad)


for w in ("Previous month", "Last 3 months", "Last 6 months"):
    CHECKS.append(Check(f"{SUITE}.cases_perf_change.{w}", f"Cases Performance by Country, Comparison Window = {w}: every 'vs window' cell is the query's",
                        actual=lambda w=w: _perf_change_gaps(w), expected=lambda: 0.0, tol=0, live=True,
                        proves="Each change is latest month ÷ window - 1, the window an average month (counts, euro) or a ratio of window totals (per case); % of book in points; blank when the window is short."))
# Group by Portfolio (the user, 2026-10-14): one row per portfolio, every cell recomputed from that portfolio's rows.
CHECKS.append(Check(f"{SUITE}.cases_perf_change.Portfolio", "Cases Performance by Portfolio, Comparison Window = Last 3 months: every 'vs window' cell is the query's",
                    actual=lambda: _perf_change_gaps("Last 3 months", "Portfolio"), expected=lambda: 0.0, tol=0, live=True,
                    proves="Grouping by portfolio is the same arithmetic on one portfolio's rows; blank where it has no case feed."))


def _full_book_rate_gaps() -> float:
    """Cases §3: Collected cases, % of book per portfolio = its case-months paid / its case-months on book (2026-10-14)."""
    d = _lib.dashboard()
    g = d.groupby("portfolio_name")[["collected_cases_count", "cases_on_book_count"]].sum(min_count=1)
    want = g["collected_cases_count"] / g["cases_on_book_count"]
    live = tile("bc_full").set_index("portfolio")["collected cases, % of book"]
    live = pd.to_numeric(live, errors="coerce")
    bad = 0
    for port, w in want.items():
        got = live.get(port)
        if pd.isna(w):
            bad += got is not None and not pd.isna(got)
        else:
            bad += got is None or pd.isna(got) or abs(got - w) > 1e-6
    return float(bad)


CHECKS.append(Check(f"{SUITE}.cases_full_book_rate", "Cases Full Breakdown: Collected cases, % of book on every portfolio",
                    actual=_full_book_rate_gaps, expected=lambda: 0.0, tol=0, live=True,
                    proves="Over the selected months: case-months that paid ÷ case-months on book, per portfolio; blank without a case feed."))


# The stress test (2026-10-13, 623 live exports) found % changes of a signed number: Net Change showed -3,082% and
# net collections -1,168% where fees exceed collections. A % against a zero or negative base is blank, and Net
# Change is a difference in cases. These pin both.
def _net_collections_change_gaps(window: str) -> float:
    n = {"Previous month": 1, "Last 3 months": 3}[window]
    d = _lib.dashboard()
    d = d[d["reporting_month"] == d["reporting_month"].max()]
    live = tile("bp_perf", params={"P-Perf-Grain": "Seller", "P-Perf-Window": window}).set_index("group")
    bad = 0
    for g, r in d.groupby("seller"):
        months = 1 if n == 1 else r[f"months_in_l{n}m_window"].max()
        now, base = r["net_collections_sum"].sum(), r[f"net_collections_l{n}m_sum"].sum() / (months or 1)
        want = None if (n > 1 and (pd.isna(months) or months < n)) or base <= 0 else now / base - 1
        got = pd.to_numeric(pd.Series([live.loc[g, "total net collections vs window"] if g in live.index else None]), errors="coerce").iloc[0]
        bad += (not pd.isna(got)) if want is None else (pd.isna(got) or abs(got - want) > 1e-6 * max(1, abs(want)))
    return float(bad)


def _signed_as_difference_problems() -> float:
    els = {e["id"]: e for e in _spec()["elements"]}
    bad = els["c_nl"].get("comparison", {}).get("display") != "delta"
    helper = els["bc_perf_src"]
    col = next(c for c in helper["columns"] if c.get("name", "").lower() == "net change in collected cases vs window")
    bad += col.get("format", {}).get("formatString") != "+,.0f" or col["formula"].rstrip().endswith("- 1)")
    return float(bad)


for w in ("Previous month", "Last 3 months"):
    CHECKS.append(Check(f"{SUITE}.net_collections_change.{w}", f"Portfolio Performance by Seller, Comparison Window = {w}: net collections vs window, blank when the base is zero or negative",
                        actual=lambda w=w: _net_collections_change_gaps(w), expected=lambda: 0.0, tol=0, live=True,
                        proves="Net collections go negative when fees exceed collections; a % of that base would read -1,168% or flip sign."))
CHECKS.append(Check(f"{SUITE}.performance_group_frozen", "§2 Performance (Group) and §3 Full breakdown (Portfolio only, first column) on Portfolio and Cases: columns frozen",
                    actual=lambda: float(sum((e.get("frozenColumn") or {}).get("columnId") != "v0"
                                             for e in _spec()["elements"] if e["id"] in ("bp_perf", "bc_perf"))
                                         + sum((e.get("frozenColumn") or {}).get("columnId") != "v0"
                                               or (e["columns"][0].get("name") or "").lower() != "portfolio"
                                               for e in _spec()["elements"] if e["id"] in ("bp_full", "bc_full"))),
                    expected=lambda: 0.0, tol=0, live=True,
                    proves="The group name stays in view while the metric columns scroll (the user, 2026-10-14)."))
CHECKS.append(Check(f"{SUITE}.net_change_is_difference", "Net Change in Collected Cases: card and Performance column show a difference in cases, not a %",
                    actual=_signed_as_difference_problems, expected=lambda: 0.0, tol=0, live=True,
                    proves="Net Change is signed (fresh minus lost), so a % of it is meaningless (Germany read -3,082%)."))


# Short fixed card titles (the user, 2026-10-12); what they show is named once, in the line above the cards.
CARD_TITLES = {"c_cc": "Collected Cases", "c_ce": "Collections", "c_three": "Three Consecutive Months", "c_first": "New",
               "c_new": "Fresh", "c_lost": "Lost", "c_nl": "Net Change in Collected Cases", "c_cpe": "Avg Monthly Collection per Case",
               "p_coll": "Total Collections", "p_vs": "Collections as % of Forecast",
               "p_gap": "Collections Minus Forecast", "p_fc": "Total Forecast", "p_net": "Total Net Collections",
               "p_cost": "Servicer Cost, % of Collections",
               # Data Quality: five cards across, so short titles (2026-10-14)
               "d_recshare": "Share Reconciled", "d_notrec": "Not Reconciled", "d_nofeed": "No Case Feed", "d_stopped": "Feeds Stopped"}
def _card_title_problems() -> float:
    els = {e["id"]: e for e in _spec()["elements"]}
    name = lambda e: e["name"]["text"] if isinstance(e.get("name"), dict) else e.get("name", "")
    bad = sum(1 for eid, want in CARD_TITLES.items() if name(els[eid]) != want)
    # The Comparison Window toggles: L1M to L12M only, named so a reader knows the % compares with an average month.
    for eid in ("p_window", "c_window"):
        src = els[eid]["source"]
        bad += src["values"] != ["Previous month", "Last 3 months", "Last 6 months", "Last 12 months"] or src.get("labels") != ["L1M", "L3M", "L6M", "L12M"]
        bad += els[eid].get("name") != "Comparison Window (Average Monthly)"
    # The line above the cards (Portfolio) and in the behaviour band (Cases) names the latest month and the window.
    for eid, ctl in (("p_cmp", "P-Window"), ("nSopK5b7To", "C-Window")):
        body = els[eid].get("body", "")
        bad += "The tiles compare the latest reporting month, " not in body or f'Switch([{ctl}], "Previous month"' not in body or "(monthly average)" not in body
    # The Overall Summary band names the book's snapshot: the latest reporting month.
    bad += "Monthly snapshot as of the latest reporting month" not in els["MxSGmmb_TV"].get("body", "")
    bad += "c_cmp" in els   # the Cases line moved into the band
    return float(bad)


CASE_COLOURS = {"New": "#1D5B4D", "Fresh": "#C4C9FA", "Two of Three Months": "#A6ADF8",
                "Three Consecutive Months": "#4F3DFF", "Lost": "#C62828"}
CASE_TITLES = {"c_chart": "Count over Months", "c_money": "Collections over Months", "c_avg": "Average Collection per Case over Months"}


def _case_chart_spec_problems() -> float:
    els = {e["id"]: e for e in _spec()["elements"]}
    bad = 0
    for eid, title in CASE_TITLES.items():
        e = els[eid]
        name = e["name"]["text"] if isinstance(e.get("name"), dict) else e.get("name")
        colours = {x["value"].replace("\u200b", ""): x["color"].upper() for x in e.get("color", {}).get("customColors", [])}
        stacked = eid != "c_avg"   # averages do not add: side by side
        want = dict(CASE_COLOURS, **{" ": "#FFFFFF"}) if stacked else dict(CASE_COLOURS, **{"All Collected Cases": "#012E26"})
        bad += e.get("kind") != "bar-chart" or e.get("stacking", "stacked") != ("stacked" if stacked else "none")   # Sigma drops the default
        bad += e.get("source", {}).get("elementId") != "cb_src" or e.get("color", {}).get("by") != "category"
        bad += colours != want or e.get("legend", {}).get("position") != "right" or name != title
        if stacked:   # the month's total over each bar; the total row filtered out
            bad += e.get("dataLabel", {}).get("totals", {}).get("display") != "shown"
            bad += not any(f.get("mode") == "exclude" and f.get("values") == ["All Collected Cases"] for f in e.get("filters", []))
        else:   # the white spacer is only for the stacked tabs' totals
            bad += not any(f.get("mode") == "exclude" and f.get("values") == [" "] for f in e.get("filters", []))
    # every header filter reaches the chart's source
    bad += sum(1 for e in els.values() if e.get("kind") == "control" and e.get("filters")
               and not any(f.get("source", {}).get("elementId") == "cb_src" for f in e["filters"]))
    return float(bad)


def _feed_text() -> str:
    df = tile("c_chart")
    latest = pd.to_datetime(df["reporting month"], format="%b %Y").idxmax()   # "Aug 2026": sort as a date, not as text
    return str(df.loc[latest, "feed portfolios"])


def _feed_expected() -> str:
    d = _lib.dashboard()
    d = d[d["reporting_month"] == d["reporting_month"].max()]
    feed = d[d["collected_cases_count"].notna()]
    return f'{feed["portfolio_name"].nunique()} ({feed[feed["is_reconciled_flag"].astype(bool)]["portfolio_name"].nunique()} reconciled)'


CHECKS += [
    Check(f"{SUITE}.case_chart_country_filter", "Cases chart: the Country filter reaches the chart (Portugal, collected cases)",
          actual=lambda: _series("c_chart", PAYING, {"Country": "Portugal"}),
          expected=lambda: float(_lib.dashboard().query("country_name == 'Portugal'")["collected_cases_count"].sum()), tol=0, live=True,
          proves="The header filters target the chart's own source too, so it never shows the whole book under a filter."),
    Check(f"{SUITE}.case_chart_month_range", "Cases chart: a Reporting month range (Apr–Jun 2026) shows only those months, each the mart's",
          actual=lambda: _series("c_chart", PAYING, {"Reporting-Month": "min:2026-04-01,max:2026-06-30"}),
          expected=lambda: float(_lib.dashboard().loc[lambda d: d["reporting_month"].astype(str).str[:7].isin(["2026-04", "2026-05", "2026-06"]), "collected_cases_count"].sum()),
          tol=0, live=True, proves="The Reporting month filter targets the chart's own source on its month column."),
    Check(f"{SUITE}.case_chart_servicer_filter", "Cases chart: Servicer = Massey shows only the two Massey books' cases",
          actual=lambda: _series("c_chart", PAYING, {"Servicer": "Massey"}),
          expected=lambda: float(_lib.dashboard().query("servicer_group == 'Massey'")["collected_cases_count"].sum()), tol=0, live=True,
          proves="The corrected servicer reaches the chart: Massey's case feed is counted under Massey, not Intrum."),
    Check(f"{SUITE}.case_chart_feed_hover", "Cases chart hover: Feed portfolios at the latest month, with how many reconcile",
          actual=lambda: float(_feed_text() == _feed_expected()), expected=lambda: 1.0, tol=0, live=True,
          proves="The hover's 'N (M reconciled)' counts portfolios with a case feed that month, and those of them reconciled."),
    Check(f"{SUITE}.no_rank_or_behaviour_pickers", "No Rank By or Behavioural Metric control, no Cases Never Collected card, no Month by Month table",
          actual=lambda: float(sum(1 for e in _spec().get("elements", [])
                                   if e.get("controlId") in ("P-Rank", "C-Rank", "Behaviour") or e.get("id") in ("c_never", "p_months"))),
          expected=lambda: 0.0, tol=0, live=True, proves="The pickers, the card and the table removed on 2026-10-12 are gone from live."),
    Check(f"{SUITE}.net_change_title_period", "Cards have short fixed titles; the Comparison Window offers L1M–L12M; the lines name the latest month, the window and the book's snapshot",
          actual=_card_title_problems, expected=lambda: 0.0, tol=0, live=True,
          proves="Readers see which month the cards show and what the % compares with, without a period in every title."),
    Check(f"{SUITE}.case_chart_stacked", "Cases chart: Count and Collections stacked with totals, Avg side by side; coloured by behaviour in the palette, legend on the right",
          actual=_case_chart_spec_problems, expected=lambda: 0.0, tol=0, live=True,
          proves="Each behaviour is pinned to its palette colour (so a new value or a reorder cannot recolour it), and Sigma's legend can highlight several."),
]

for w in ("Previous month", "Last 3 months"):
    CHECKS.append(Check(f"{SUITE}.book.{w}", f"Cases on Book, Comparison Window = {w}: read at the latest reporting month",
                        actual=lambda w=w: _live("c_book", "v", **{"C-Window": w}),
                        expected=lambda: warehouse(f"SELECT SUM(cases_on_book_count) FROM {MART} WHERE period_end_date = {cap()}"),
                        tol=0, live=True, proves="The book is a stock: one month-end, the latest one, never summed."))

for grain in ("Country", "Servicer", "Seller", "Deal", "Portfolio"):
    CHECKS.append(Check(f"{SUITE}.performance_total.{grain}", f"§2 Performance grouped by {grain}, This month: groups add up to the book",
                        actual=lambda g=grain: _grain_total(g), expected=lambda: _total(COLL(), 0, 0), tol=0, live=True,
                        proves="Every portfolio lands in exactly one group, whatever the grain."))
def _portfolio_rows_wrong() -> float:
    """§2 Performance grouped by Portfolio: one row per portfolio reporting in the latest month, each its own collections."""
    d = _lib.dashboard()
    want = d[d["reporting_month"] == d["reporting_month"].max()].groupby("portfolio_name")["collections_sum"].sum()
    live = tile("bp_perf", params={"P-Perf-Grain": "Portfolio"})
    bad = float(live["group"].duplicated().sum())
    live = pd.to_numeric(live.set_index("group")["total collections"], errors="coerce")
    both = pd.concat([live.rename("live"), want.rename("want")], axis=1)
    missing = both["want"].notna() & both["live"].isna()                      # a reporting portfolio with no row
    extra = both["want"].isna() & both["live"].fillna(0).ne(0)                # a row with money but no latest month
    return bad + float(((both["live"] - both["want"]).abs() > 0.01).sum() + missing.sum() + extra.sum())


CHECKS += [
    Check(f"{SUITE}.performance_by_portfolio", "§2 Performance grouped by Portfolio: one row per portfolio, each its latest month's collections",
          actual=_portfolio_rows_wrong, expected=lambda: 0.0, tol=0, live=True,
          proves="Group by Portfolio (2026-10-14) lists every portfolio once, with nothing merged or dropped."),
    Check(f"{SUITE}.performance_by_seller", "§2 Performance grouped by Seller: every group matches the warehouse",
          actual=_seller_groups_wrong, expected=lambda: 0.0, tol=0, live=True,
          proves="Seller comes from the deal on the facts (DIM_DEAL), independently of the dashboard query."),
    Check(f"{SUITE}.performance_window", "§2 Performance, L3M: Portugal's change = its latest month ÷ its May–Jul average month − 1",
          actual=_pt_live, expected=_pt_change, tol=1e-6, live=True,
          proves="Each row's change is §1's comparison for that group, worked out from the warehouse; the export rounds to six places."),
    *[Check(f"{SUITE}.performance_bench.{b}", f"§2 Performance, its own Benchmark = {b}: Total Forecast adds up to that forecast in the latest month",
            actual=lambda b=b: float(tile("bp_perf", params={"P-Perf-Bench": b})["total forecast"].astype(float).sum()),
            expected=lambda d=den: _total(d(), 0, 0), tol=1e-9, live=True,
            proves="The §2 Benchmark switches the table's forecast columns (2026-10-12).") for b, (_n, den) in BENCH.items()],
    Check(f"{SUITE}.performance_bench_independent", "§2 Performance ignores §1's Benchmark: §1 = Accounting, §2 left at Servicer",
          actual=lambda: float(tile("bp_perf", params={"Bench": "Accounting"})["total forecast"].astype(float).sum()),
          expected=lambda: _total(_servicer(), 0, 0), tol=1e-9, live=True,
          proves="Each section has its own Benchmark, so changing the cards' plan never changes the table's."),
    Check(f"{SUITE}.performance_short_window_blank", "§2 Performance, Comparison Window = L12M (8 of 12 months exist): every change column is blank",
          actual=lambda: float(tile("bp_perf", params={"P-Perf-Window": "Last 12 months"}).filter(like="vs window").notna().sum().sum()),
          expected=lambda: 0.0, tol=0, live=True, proves="A window without all its months shows no change, rather than one built on fewer months."),
    Check(f"{SUITE}.compare_line_short_window", "The line above the cards says when a window is short (L12M: not enough months yet)",
          actual=lambda: float(all("not enough months yet" in e.get("body", "") and "so no comparison" in e.get("body", "")
                                   for e in _spec()["elements"] if e["id"] in ("p_cmp", "nSopK5b7To"))),
          expected=lambda: 1.0, tol=0, live=True, proves="Readers see why a comparison is missing."),
    Check(f"{SUITE}.deal_filter_card", f"Deal filter ({DEAL}): Total Collections is that deal's latest month",
          actual=lambda: _live("p_coll", "v", **{"Deal": DEAL}),
          expected=lambda: float(_lib.dashboard().loc[lambda d: (d["deal"] == DEAL) & (d["reporting_month"] == d["reporting_month"].max()), "collections_sum"].sum()),
          tol=1e-9, live=True, proves="The header's Deal filter (2026-10-12) reaches the cards."),
    Check(f"{SUITE}.deal_filter_forecast_chart", f"Deal filter ({DEAL}): the forecast chart's collections are that deal's",
          actual=lambda: float(_chart({"Deal": DEAL})["collections"].sum()),
          expected=lambda: float(_lib.dashboard().query("deal == @DEAL")["collections_sum"].sum()), tol=1e-9, live=True,
          proves="The chart's own source carries the deal, so the filter reaches it."),
    Check(f"{SUITE}.deal_filter_cases_chart", f"Deal filter ({DEAL}): the Cases chart's collected cases are that deal's",
          actual=lambda: _series("c_chart", PAYING, {"Deal": DEAL}),
          expected=lambda: float(_lib.dashboard().query("deal == @DEAL")["collected_cases_count"].sum()), tol=0, live=True,
          proves="The Cases chart's own source carries the deal, so the filter reaches it."),
    Check(f"{SUITE}.clear_filters", "Live workbook: Clear Filters clears every filter control",
          actual=_filters_not_cleared, expected=lambda: 0.0, tol=0, live=True,
          proves="Reporting month, Country, Servicer, Seller, Portfolio and Reconciliation all reset; the toggles keep their defaults."),
    Check(f"{SUITE}.live_query_is_this_folder", "Live workbook runs sigma_queries/portfolios_element.sql, unchanged",
          actual=_live_sql_differs, expected=lambda: 0.0, tol=0, live=True,
          proves="Every offline suite tests the file in this folder; this proves that file is what the dashboard runs."),
    Check(f"{SUITE}.user_edits_live", "Live workbook carries every hand edit in sigma_build/user_edits.json",
          actual=_user_edits_missing, expected=lambda: 0.0, tol=0, live=True,
          proves="A rebuild never undoes what the user changed in the Sigma editor."),
]

# ---- the Data Quality page, every Window: row months in the window (see WINDOWS above) ---------------
def _rows_in(a: int, b: int) -> pd.DataFrame:
    """The query's rows in the window, for the one figure only the query defines (the feed-stopped flag)."""
    d = _lib.dashboard()
    m = pd.to_datetime(d["reporting_month"]).dt.to_period("M")
    top = m.max()
    return d[(m >= top + a) & (m <= top + b)]


def _distinct_portfolios(base: str, a: int, b: int) -> float:
    return warehouse(f"SELECT COUNT(DISTINCT IFF(v IS NOT NULL, portfolio_sk, NULL)) FROM ({base}) WHERE {_span('period_end_date', a, b)}")


def _table_sum(element: str, column: str, w: str) -> float:
    return float(pd.to_numeric(tile(element, params={"D-Window": w})[column], errors="coerce").fillna(0).sum())


def _not_reconciled(a: int, b: int) -> float:
    return _total(COLL(), a, b) - _total(_reconciled_base(), a, b)


def _manager_review_missing() -> float:
    """What the manager's review removed but the live workbook still has, plus what it added but is missing."""
    spec = _spec()
    els = {e["id"]: e for e in spec["elements"]}
    bad = sum(1 for g in ("f_vehicle", "p_recshare", "c_key", "6kmnYaGsXV") if g in els)
    visible = [e for e in spec["elements"] if not e["id"].endswith("_src") and e["id"] not in ("src", "src_defs")]
    bad += sum(1 for e in visible if any(w in json.dumps(e) for w in ("Vehicle", "vehicle", "Jitter", "jitter")))
    bad += sum(1 for e in ("bp_perf", "bp_full", "bc_perf", "bc_full", "p_chart")
               for c in els[e]["columns"] if "reconcil" in (c.get("name") or "").lower() or (c.get("name") or "").lower() == "data status")
    bad += [t["name"] for t in els.get("c_tabs", {}).get("tabs", [])] != ["Count", "Collections", "Average Collection per Case"]
    bad += "Data Quality" not in [p["name"] for p in spec["pages"]]
    return float(bad)


STATUS_WORDS = r"^(No data\.|No case feed\.|(Reconciled|Not reconciled|(<1|\d{1,3})% reconciled)\.( Feed \d+ of \d+\.)?( \d+ feeds? stopped\.)?)$"

for w, (cur, prev) in WINDOWS.items():
    CHECKS += [
        Check(f"{SUITE}.dq_reconciled_share.{w}", f"Data Quality: Share of Collections Reconciled, Window = {w}",
              actual=lambda w=w: _live("d_recshare", "v", **{"D-Window": w}),
              expected=lambda c=cur: _total(_reconciled_base(), *c) / _total(COLL(), *c), tol=1e-9, live=True,
              proves="Reconciled collections over all collections in exactly the months the Window names; a ratio of sums."),
        Check(f"{SUITE}.dq_not_reconciled.{w}", f"Data Quality: Collections Not Reconciled, Window = {w}",
              actual=lambda w=w: _live("d_notrec", "v", **{"D-Window": w}), expected=lambda c=cur: _not_reconciled(*c), tol=1e-9, live=True,
              proves="The euro not yet confirmed by the case feed, including portfolios with no feed at all."),
        # No Case Feed (the user, 2026-10-14) tallies: reporting = with a case feed + no case feed, and it is the number of
        # portfolios whose Data Status reads "No case feed."
        Check(f"{SUITE}.dq_no_case_feed.{w}", f"Data Quality: No Case Feed = portfolios reporting minus those with a case feed, Window = {w}",
              actual=lambda w=w: _live("d_nofeed", "v", **{"D-Window": w}),
              expected=lambda w=w: _table_sum("d_srv", "portfolios", w) - _table_sum("d_srv", "with a case feed", w), tol=0, live=True,
              proves="The card and the By Servicer table cannot disagree: every reporting portfolio has a feed or is counted here."),
        Check(f"{SUITE}.dq_no_case_feed_status.{w}", f"Data Quality: No Case Feed = portfolios whose Data Status is 'No case feed.', Window = {w}",
              actual=lambda w=w: _live("d_nofeed", "v", **{"D-Window": w}),
              expected=lambda w=w: float((tile("d_port", params={"D-Window": w})["data status"] == "No case feed.").sum()), tol=0, live=True,
              proves="The card counts exactly the portfolios the By Portfolio table marks as having no case feed."),
        Check(f"{SUITE}.dq_feeds_stopped.{w}", f"Data Quality: Case Feeds Stopped, Window = {w}",
              actual=lambda w=w: _live("d_stopped", "v", **{"D-Window": w}),
              expected=lambda c=cur: float(_rows_in(*c).loc[lambda d: d.feed_stopped_flag.fillna(False).astype(bool), "portfolio_name"].nunique()),
              tol=0, live=True, proves="Portfolios whose feed went quiet in any month of the window, each counted once."),
        Check(f"{SUITE}.dq_servicer_adds_up.{w}", f"Data Quality: By Servicer, not reconciled adds up to the tile, Window = {w}",
              actual=lambda w=w: _table_sum("d_srv", "collections not reconciled", w), expected=lambda c=cur: _not_reconciled(*c), tol=1e-9, live=True,
              proves="Every euro lands with exactly one servicer: the table and the tile cannot disagree."),
        Check(f"{SUITE}.dq_servicer_portfolios.{w}", f"Data Quality: By Servicer, portfolios = those reporting in the window, Window = {w}",
              actual=lambda w=w: _table_sum("d_srv", "portfolios", w), expected=lambda c=cur: _distinct_portfolios(COLL(), *c), tol=0, live=True,
              proves="A portfolio counts once if it reported in any month of the window, from the facts."),
        Check(f"{SUITE}.dq_servicer_feeds.{w}", f"Data Quality: By Servicer, portfolios with a case feed, Window = {w}",
              actual=lambda w=w: _table_sum("d_srv", "with a case feed", w),
              expected=lambda c=cur: _distinct_portfolios(_case_base("collected_cases_count"), *c), tol=0, live=True,
              proves="Feed portfolios come from the case mart, independently of the dashboard query."),
        Check(f"{SUITE}.dq_portfolio_adds_up.{w}", f"Data Quality: By Portfolio, not reconciled adds up to the tile, Window = {w}",
              actual=lambda w=w: _table_sum("d_port", "collections not reconciled", w), expected=lambda c=cur: _not_reconciled(*c), tol=1e-9, live=True,
              proves="One row per portfolio, none dropped or doubled."),
    ]
    if w != "Last 12 months":   # the 12 months before the last 12 hold no data yet
        CHECKS.append(Check(f"{SUITE}.dq_reconciled_share_previous.{w}", f"Data Quality: reconciled share comparison, Window = {w}: the window before",
                            actual=lambda w=w: _live("d_recshare", "previous window", **{"D-Window": w}),
                            expected=lambda p=prev: _total(_reconciled_base(), *p) / _total(COLL(), *p), tol=1e-9, live=True,
                            proves="The points change compares with the window of the same length just before."))
CHECKS += [
    Check(f"{SUITE}.dq_portfolio_rows", "Data Quality: By Portfolio has one row per portfolio",
          actual=lambda: float(len(tile("d_port"))), expected=lambda: float(_lib.dashboard()["portfolio_name"].nunique()), tol=0, live=True,
          proves="Every portfolio appears once; one that did not report in the window says 'No data.'"),
    Check(f"{SUITE}.dq_status_words", "Data Quality: every Data Status, at every Window, is a documented sentence",
          actual=lambda: float(sum((~tile("d_port", params={"D-Window": w})["data status"].astype(str).str.match(STATUS_WORDS)).sum() for w in WINDOWS)),
          expected=lambda: 0.0, tol=0, live=True, proves="The status column never shows a broken formula, a blank or an undocumented message."),
    Check(f"{SUITE}.manager_review_applied", "Live workbook: the manager's review (2026-10-09) is applied",
          actual=_manager_review_missing, expected=lambda: 0.0, tol=0, live=True,
          proves="No Vehicle or jitter anywhere a viewer can see; no reconciliation or Data Status on Portfolio and Cases; one chart with Count | Collections | Average Collection per Case tabs; a Data Quality page."),
]

# ---- the Portfolio chart under its controls (2026-10-11) ----
from suites.s6_live_dashboard import _ahead, _ahead_forecast, _chart   # noqa: E402


def _chart_months() -> list[pd.Timestamp]:   # not _months: that name is the window helper above
    return sorted(pd.to_datetime(_lib.dashboard()["reporting_month"]).unique())


def _range_end() -> pd.Timestamp:
    """A Reporting month range that stops four months before the latest: forecasts then overlap reported months."""
    return _chart_months()[-5]


def _range() -> dict:
    return {"Reporting-Month": f"min:{_chart_months()[0]:%Y-%m-01},max:{_range_end():%Y-%m-%d}"}


def _label(ts: pd.Timestamp) -> str:
    return f"{ts:%b %Y}"


def _future_rows(d: pd.DataFrame) -> pd.DataFrame:
    """Rows after the last complete month: the months no portfolio has reported yet."""
    return d[pd.to_datetime(d["reporting month"], format="%b %Y") > _chart_months()[-1]]


CHECKS += [
    Check(f"{SUITE}.chart_range_ends_12_ahead", "Collections vs forecasts: with a Reporting month range, forecasts end 12 months after its end",
          actual=lambda: float(tile("p_chart", params=_range())["reporting month"].iloc[-1] == _label(_range_end() + pd.offsets.MonthEnd(12))),
          expected=lambda: 1.0, tol=0, live=True,
          proves="The forecast follows the selected month, not the latest data: pick April and it runs to next April."),
    Check(f"{SUITE}.chart_range_collections", "Collections vs forecasts: with a range, collections cover exactly its months",
          actual=lambda: float(_chart(_range())["collections"].sum()),
          expected=lambda: warehouse(f"SELECT SUM(v) FROM ({COLL()}) WHERE period_end_date <= '{_range_end():%Y-%m-%d}'::DATE"), tol=1e-9, live=True,
          proves="Collections stop at the selected month even when later months exist."),
    Check(f"{SUITE}.chart_range_ahead_count", "Collections vs forecasts: with a range, 12 forecast-only months",
          actual=lambda: float(len(_ahead(_range()))), expected=lambda: 12.0, tol=0, live=True,
          proves="Months already reported but after the selection show forecasts only, never collections."),
    Check(f"{SUITE}.chart_range_future_accounting", "Collections vs forecasts: with a range, the not-yet-reported months are the selected month's book",
          actual=lambda: float(_future_rows(_chart(_range()))["accounting forecast"].sum()),
          expected=lambda: warehouse(_ahead_forecast("accounting", f"{_range_end():%Y-%m-%d}")), tol=1e-9, live=True,
          proves="The forecast ahead covers the portfolios owned at the selected month, not portfolios bought since."),
    Check(f"{SUITE}.chart_cumulative_collections", "Collections vs forecasts, Cumulative: collections end at the book total",
          actual=lambda: float(_chart({"View": "Cumulative"})["collections"].max()),
          expected=lambda: warehouse(f"SELECT SUM(v) FROM ({COLL()})"), tol=1e-9, live=True,
          proves="The running total reaches every euro collected to date."),
    Check(f"{SUITE}.chart_cumulative_stops", "Collections vs forecasts, Cumulative: the collections line stops at the latest month",
          actual=lambda: float(_chart({"View": "Cumulative"})["collections"].isna().sum()), expected=lambda: 12.0, tol=0, live=True,
          proves="A running total of nothing is not drawn flat across the forecast-only months."),
    Check(f"{SUITE}.chart_cumulative_forecast", "Collections vs forecasts, Cumulative: the servicer line ends at its monthly total",
          actual=lambda: float(_chart({"View": "Cumulative"})["servicer forecast"].max()),
          expected=lambda: float(_chart()["servicer forecast"].sum()), tol=1e-9, live=True,
          proves="CumulativeSum runs over every month, reported and ahead, without a gap or a double count."),
    Check(f"{SUITE}.chart_hover_has_all", "Collections vs forecasts: hovering any line shows every figure for that month",
          actual=lambda: float((_chart()[["collections.1", "servicer", "accounting", "underwriting"]].fillna(-1).values
                                == _chart()[["collections", "servicer forecast", "accounting forecast", "underwriting forecast"]].fillna(-1).values).all()),
          expected=lambda: 1.0, tol=0, live=True,
          proves="The hover's four figures are the four lines, month by month, so one box reads the whole month."),
    Check(f"{SUITE}.chart_no_numbered_names", "Collections vs forecasts: no column shows Sigma's '(1)' duplicate-name suffix",
          actual=lambda: float(sum(bool(re.search(r"\(\d+\)$", c)) for c in _lib.raw_tile_columns("p_chart"))), expected=lambda: 0.0, tol=0, live=True,
          proves="The hover reads 'Collections', not 'Collections (1)' (the user, 2026-10-13)."),
    Check(f"{SUITE}.header_sticky", "The header (title, Clear Filters, seven filters) stays on screen as the page scrolls",
          actual=lambda: float(any(p.get("type") == "header" and p.get("config", {}).get("scroll", "sticky") == "sticky"
                                   and len(p.get("pages", [])) == 4 for p in _spec().get("panels", []))),
          expected=lambda: 1.0, tol=0, live=True,
          proves="The header panel is sticky on all four visible pages, so the filters are always in reach."),
    Check(f"{SUITE}.header_equal_widths", "The seven header filters are all the same width, on one line",
          actual=_header_widths, expected=lambda: 1.0, tol=0, live=True,
          proves="Reporting Month, Country, Servicer, Seller, Deal, Portfolio and Reconciliation, then Clear Filters, each take 3 of the header's 24 columns in one row."),
    Check(f"{SUITE}.chart_sources_no_duplicates", "The Cases and forecast charts' sources have no duplicate rows",
          actual=_source_duplicates, expected=lambda: 0.0, tol=0, live=True,
          proves="One row per portfolio, month and behaviour (Cases) and per portfolio, month and series (forecast), so no bar or line is doubled."),
    Check(f"{SUITE}.filter_values_unique", "No filter lists the same deal, seller, servicer, country or portfolio twice",
          actual=_filter_value_variants, expected=lambda: 0.0, tol=0,
          proves="Every portfolio has exactly one deal, seller, servicer and country, and no name is spelt two ways."),
    Check(f"{SUITE}.chart_hover_unique", "No chart's hover shows the same figure name twice",
          actual=_hover_duplicates, expected=lambda: 0.0, tol=0, live=True,
          proves="Hovering a line or bar lists each figure once: the forecast chart's lines are hidden from their own hover, "
                 "so only the one-box copies show (Collections was listed twice before 2026-10-12)."),
    Check(f"{SUITE}.chart_country_filter", "Collections vs forecasts: the Country filter reaches the chart",
          actual=lambda: float(_chart({"Country": "Portugal"})["collections"].sum()),
          expected=lambda: float(_lib.dashboard().query("country_name == 'Portugal'")["collections_sum"].sum()), tol=1e-9, live=True,
          proves="The header filters target the chart's own source too, so it never shows the whole book under a filter."),
    Check(f"{SUITE}.chart_country_filter_ahead", "Collections vs forecasts: the Country filter applies to the months ahead",
          actual=lambda: float(_ahead({"Country": "Portugal"})["accounting forecast"].sum()) < float(_ahead()["accounting forecast"].sum()),
          expected=lambda: 1.0, tol=0, live=True,
          proves="The forecast ahead narrows with the filter as well, not only the reported months."),
]
PREFETCH: list[str] = []
