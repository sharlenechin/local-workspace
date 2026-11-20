"""Build the Servicing dashboard in Sigma from the design, in one repeatable step.

    uv run python work/servicing/sigma_build/build_workbook.py --dry-run          # write contents.json, send nothing
    uv run python work/servicing/sigma_build/build_workbook.py --create           # new workbook beside the live one
    uv run python work/servicing/sigma_build/build_workbook.py --update <id>      # replace an existing build's contents

Reads, never edits: sigma_queries/portfolios_element.sql, design/sigma_theme.json,
docs/definitions.csv, docs/SIGMA-AGENT.md. The layout follows design/ (the reviewed mock) and
design/project/Build.dc.html (the build map). Element ids are stable and written to
element_ids.json, which tests/suites/s6_live_dashboard.py reads.

The live workbook is protected: --update refuses its id unless --live is passed. The safe route for a
change is --create a copy, run the tests against it, then swap names (README §4).
"""
from __future__ import annotations

import argparse
import csv
import json
import pathlib
import re
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
SERVICING = HERE.parent
SQL = SERVICING / "sigma_queries" / "portfolios_element.sql"
FC_SQL = SERVICING / "sigma_queries" / "forecast_chart_element.sql"   # the Portfolio chart only; reads SQL as its CTE `main`
CB_SQL = SERVICING / "sigma_queries" / "case_behaviour_element.sql"  # the Cases chart only; reads SQL as its CTE `main`
THEME = SERVICING / "design" / "sigma_theme.json"
DEFS = SERVICING / "docs" / "definitions.csv"
AGENT = SERVICING / "docs" / "SIGMA-AGENT.md"

LIVE_WORKBOOK = "031548ab-54d6-437f-b452-e728c30cfb5b"   # "Servicing Dashboard", promoted 2026-10-09
FOLDER = "b406c34e-2ce1-42a1-a8e7-4502ad86db87"
CONNECTION = "b3be9b8b-fb38-4b05-a8db-afdb5c47cdbf"   # Snowflake - PROD

SRC = {"kind": "table", "elementId": "src"}
DEF_SRC = {"kind": "table", "elementId": "src_defs"}
FC = {"kind": "table", "elementId": "fc_src"}
CB = {"kind": "table", "elementId": "cb_src"}
EUR = {"kind": "number", "formatString": "$.4s", "currencySymbol": "€"}   # €32.64M, €707.4k
EUR0 = EUR
PCT = {"kind": "number", "formatString": ",.1%"}
# The standard for comparisons (the user, 2026-10-12): percentages to 1 decimal, euro amounts to 2 decimals in millions.
EUR_M2 = {"kind": "number", "formatString": "$,.2f", "currencySymbol": "€", "suffix": "M"}   # cards, charts: value / 1,000,000
EUR_FULL = {"kind": "number", "formatString": "$,.2f", "currencySymbol": "€"}                  # tables, per-case: euros and cents
M = lambda formula: f"({formula}) / 1000000"   # a card or chart figure in millions
INT = {"kind": "number", "formatString": ",.0f"}
MONTH = {"kind": "datetime", "formatString": "%b %Y"}
CARD = {"backgroundColor": "#ffffff", "borderColor": "#DCE3DF", "borderRadius": "round", "borderWidth": 1}

# Vehicle removed from every grain, filter and breakdown (the manager's review, 2026-10-09).
GRAINS = ["Country", "Servicer", "Seller", "Deal", "Portfolio"]
GRAIN_COL = {"Country": "country_name", "Servicer": "servicer_group", "Seller": "seller", "Deal": "deal", "Portfolio": "portfolio_name"}
WINDOWS = ["This month", "Previous month", "Last 3 months", "Last 6 months", "Last 12 months"]   # Performance, Data Quality
WINDOW_LABELS = ["Month", "LM", "L3M", "L6M", "L12M"]   # "Month" so five fit the uniform toggle width (2026-10-14)   # short labels on the toggles, as set in Sigma by the user
# The overview cards' Comparison Window (the user, 2026-10-12): the cards show the latest reporting month, and the
# toggle only picks what the % compares with: the month before, or the average month of the 3, 6 or 12 before.
CMP_WINDOWS = ["Previous month", "Last 3 months", "Last 6 months", "Last 12 months"]
CMP_LABELS = ["L1M", "L3M", "L6M", "L12M"]


# --- formula helpers ----------------------------------------------------------
def c(name: str) -> str:
    """A source column. Source columns keep the query's snake_case names, so a formula reads like the SQL."""
    return f"[Portfolios/{name}]"


def fcc(name: str) -> str:
    """A column of the forecast-chart source (fc_src)."""
    return f"[Forecast lines/{name}]"


def window(this: str, prefix: str, months: str = "months_in_l{n}m_window") -> str:
    """Switch over the window control: this month, L1M, or the L3/6/12M average (sum / months that exist)."""
    parts = [f'"This month", Sum({c(this)})', f'"Previous month", Sum({c(prefix + "_l1m_sum")})']
    for n in (3, 6, 12):
        parts.append(f'"Last {n} months", Sum({c(prefix + f"_l{n}m_sum")}) / Max({c(months.format(n=n))})')
    return "Switch([P-Window], " + ", ".join(parts) + ")"


def cur(column: str) -> str:
    """The latest reporting month's figure: a KPI with a month timeline shows its last month."""
    return f"Sum({c(column)})"


def cmp_avg(prefix: str, ctl: str, months: str = "months_in_l{n}m_window") -> str:
    """The comparison window's average month: the month before (L1M), or the 3/6/12 months before the latest one,
    summed and divided by the months that exist (the same divisor the windows always used)."""
    # Blank unless every month of the window exists (the user, 2026-10-12): L12M before Dec 2026 has only 8 months.
    full = lambda n, x: f"If(Max({c(months.format(n=n))}) < {n}, Null, {x})"
    parts = [f'"Previous month", Sum({c(prefix + "_l1m_sum")})']
    parts += [f'"Last {n} months", ' + full(n, f'Sum({c(prefix + f"_l{n}m_sum")}) / Max({c(months.format(n=n))})') for n in (3, 6, 12)]
    return f"Switch([{ctl}], " + ", ".join(parts) + ")"


def cmp_sum(prefix: str, ctl: str, months: str = "months_in_l{n}m_window") -> str:
    """The comparison window's total, for ratios: sum the top and the bottom over the window, then divide. Blank unless
    every month of the window exists."""
    full = lambda n, x: f"If(Max({c(months.format(n=n))}) < {n}, Null, {x})"
    parts = [f'"Previous month", Sum({c(prefix + "_l1m_sum")})'] + [f'"Last {n} months", ' + full(n, f'Sum({c(prefix + f"_l{n}m_sum")})') for n in (3, 6, 12)]
    return f"Switch([{ctl}], " + ", ".join(parts) + ")"


def wsum(this: str, prefix: str) -> str:
    """Switch over the window control: the TOTAL for the window (this month, or the sum of the months before it)."""
    parts = [f'"This month", Sum({c(this)})', f'"Previous month", Sum({c(prefix + "_l1m_sum")})']
    parts += [f'"Last {n} months", Sum({c(prefix + f"_l{n}m_sum")})' for n in (3, 6, 12)]
    return "Switch([P-Window], " + ", ".join(parts) + ")"


def wprior(this: str, prefix: str, ctl: str = "P-Window", months: str | None = "months_in_l{n}m_window") -> str:
    """The PREVIOUS window for the same selection: the month before 'This month', the month before the
    previous month, the 3 months before the last 3 (L6M - L3M), and so on. With `months`, the monthly
    average of that previous window; with months=None, its total."""
    l = lambda n: f'Sum({c(prefix + f"_l{n}m_sum")})'
    m = lambda n: f'Max({c(months.format(n=n))})' if months else None
    def arm(a, b):
        diff = f"({l(a)} - {l(b)})"
        return f"{diff} / ({m(a)} - {m(b)})" if months else diff
    return (f'Switch([{ctl}], "This month", {l(1)}, "Previous month", {l(2)} - {l(1)}, '
            f'"Last 3 months", {arm(6, 3)}, "Last 6 months", {arm(12, 6)}, "Last 12 months", {arm(24, 12)})')


# Tables wrap instead of cutting text to "..." (the user, 2026-10-14: no truncated headers or values).
# 2026-10-14: columns autofit to their content (wrapped cells split money values over two lines and narrow columns
# still cut text to "..."), headers wrap.
WRAP = {"autofitColumns": "shown", "textStyles": {"header": {"textWrap": "wrap"}}}


def hide_nulls(col_ids: list) -> dict:
    """Sigma writes "null" in an empty number cell and has no setting for it: draw it in the card's white so the cell
    reads blank (the user, 2026-10-14). The value stays empty, so sorting and sums are unchanged."""
    return {"type": "single", "columnIds": col_ids, "condition": "IsNull", "style": {"color": "#FFFFFF", "backgroundColor": "none"}}
CARD_BOX = {"backgroundColor": "#FFFFFF", "borderColor": "#DCE3DF", "borderWidth": 1, "borderRadius": "round"}


def box(eid: str) -> dict:
    """A white rounded card that holds controls or text, which cannot be styled themselves."""
    return {"id": eid, "kind": "container", "style": CARD_BOX, "spacing": "medium"}


# §2 Performance has its own Window. Each group reads the window ending at the latest month in view:
# GrandTotal(Max(...)) is that month for the whole (filtered) table, the month the tiles show.
ANCHOR = f'{c("reporting_month")} = GrandTotal(Max({c("reporting_month")}))'


def perf_window(ctl: str, this: str, prefix: str, months: str | None = None) -> str:
    """Sum over the group of one metric's window column at the anchor month. With `months`, the average month."""
    at = lambda col: f"Sum(If({ANCHOR}, {c(col)}))"
    parts = [f'"This month", {at(this)}', f'"Previous month", {at(prefix + "_l1m_sum")}']
    for n in (3, 6, 12):
        tot = at(prefix + f"_l{n}m_sum")
        parts.append(f'"Last {n} months", ' + (f"{tot} / Max(If({ANCHOR}, {c(months.format(n=n))}))" if months else tot))
    return f"Switch([{ctl}], " + ", ".join(parts) + ")"


def perf_cur(this: str) -> str:
    """A group's latest reporting month (§2 reads the whole group's rows; the anchor picks the latest month)."""
    return f"Sum(If({ANCHOR}, {c(this)}))"


def perf_avg(ctl: str, prefix: str, months: str = "months_in_l{n}m_window") -> str:
    """A group's comparison-window average month, read on the latest month's rows (as §1's cards)."""
    at = lambda col: f"Sum(If({ANCHOR}, {c(col)}))"
    full = lambda n, x: f"If(Max(If({ANCHOR}, {c(months.format(n=n))})) < {n}, Null, {x})"   # blank unless every month exists
    parts = [f'"Previous month", {at(prefix + "_l1m_sum")}']
    parts += [f'"Last {n} months", ' + full(n, f'{at(prefix + f"_l{n}m_sum")} / Max(If({ANCHOR}, {c(months.format(n=n))}))') for n in (3, 6, 12)]
    return f"Switch([{ctl}], " + ", ".join(parts) + ")"


def perf_sum(ctl: str, prefix: str, months: str = "months_in_l{n}m_window") -> str:
    """A group's comparison-window total, for ratios. Blank unless every month of the window exists."""
    at = lambda col: f"Sum(If({ANCHOR}, {c(col)}))"
    full = lambda n, x: f"If(Max(If({ANCHOR}, {c(months.format(n=n))})) < {n}, Null, {x})"
    parts = [f'"Previous month", {at(prefix + "_l1m_sum")}'] + [f'"Last {n} months", ' + full(n, at(prefix + f"_l{n}m_sum")) for n in (3, 6, 12)]
    return f"Switch([{ctl}], " + ", ".join(parts) + ")"


def compare_line(ctl: str, months: str = "months_in_l{n}m_window") -> str:
    """The line above the overview cards: they show the latest reporting month, compared with the window the toggle
    picks. Sigma labels a KPI's comparison with a fixed name, so this says which months it is. The window starts at
    the first month that exists (L12M before Dec 2025 has fewer than 12): the same months the average divides by."""
    a = "Max([Portfolios/reporting_month])"
    m = lambda k: f'DateFormat(DateAdd("month", {k}, {a}), "%b %Y")'
    have = lambda n: f"Max({c(months.format(n=n))})"
    arms = [f'"Previous month", {m(-1)}'] + [
        f'"Last {n} months", {m(-n)} & " – " & {m(-1)} & If({have(n)} < {n}, ": not enough months yet (" & Text({have(n)}) & " of {n}), so no comparison", " (monthly average)")'
        for n in (3, 6, 12)]
    return ('<span style="color: #5C6B66">{{"The tiles compare the latest reporting month, " & ' + m(0) + ' & ", with " & '
            f'Switch([{ctl}], ' + ", ".join(arms) + ')}}</span>')


def window_range(ctl: str, which: str) -> str:
    """'May–Jul 2026' for the selected window (which='cur') or the one before it (which='prev')."""
    a = "Max([Portfolios/reporting_month])"
    d = lambda k: f'DateAdd("month", {k}, {a})'
    def rng(x, y):
        if x == y:
            return f'DateFormat({d(x)}, "%b %Y")'
        return (f'If(DateFormat({d(x)}, "%Y") = DateFormat({d(y)}, "%Y"), DateFormat({d(x)}, "%b") & "–" & DateFormat({d(y)}, "%b %Y"), '
                f'DateFormat({d(x)}, "%b %Y") & " – " & DateFormat({d(y)}, "%b %Y"))')
    spans = {"This month": ((0, 0), (-1, -1)), "Previous month": ((-1, -1), (-2, -2))}
    spans.update({f"Last {n} months": ((-n, -1), (-2 * n, -n - 1)) for n in (3, 6, 12)})
    i = 0 if which == "cur" else 1
    return f"Switch([{ctl}], " + ", ".join(f'"{w}", {rng(*v[i])}' for w, v in spans.items()) + ")"


# How each tile's figure is built, said on the line under it (Sigma cannot make a KPI's own comparison label dynamic).
TILE_KIND = {"p_coll": "Total", "p_vs": "Change in Points", "p_gap": "Total",
             "p_fc": "Total", "p_net": "Total", "p_cost": "Change in Points", "d_recshare": "Change in Points",
             "d_notrec": "Total", "d_nofeed": "Total", "d_stopped": "Total",
             "c_cc": "Monthly Average", "c_ce": "Monthly Average", "c_cpe": "Per Case", "c_nl": "Monthly Average",
             "c_first": "Monthly Average", "c_new": "Monthly Average", "c_lost": "Monthly Average", "c_three": "Monthly Average"}
DELTA_TILES = {"p_vs", "p_gap", "p_cost", "d_recshare", "c_nl"}   # show the change itself: points, euro for the gap, cases for Net Change


def tile_line(eid: str, ctl: str) -> str:
    kind = f'"{TILE_KIND[eid]} · "'
    if TILE_KIND[eid] == "Monthly Average":   # one month has no average: drop the word for the one-month windows
        kind = f'Switch([{ctl}], "This month", "", "Previous month", "", {kind})'
    return ('<span style="color: #5C6B66; font-size: 12px">{{' + kind + ' & ' + window_range(ctl, "cur")
            + ' & " vs " & ' + window_range(ctl, "prev") + '}}</span>')


def case_window(this: str, prefix: str) -> str:
    return window(this, prefix, "months_in_case_l{n}m_window").replace("[P-Window]", "[C-Window]")


def grain_switch(control: str) -> str:
    """One grouping column driven by a list control - the pattern the live Focus table already uses."""
    arms = ", ".join(f'"{g}", {c(GRAIN_COL[g])}' for g in GRAINS)
    return f'Switch([{control}], "All book", "All book", "(none)", "", {arms})'


HAS_FEED = f"IsNotNull({c('collected_cases_count')})"

# ---- the Data Quality page: every figure over the page's own Window, counted by row month -----------------
# MO is how many months a row sits before the latest month in view (0 = that month). A window is a band of MO:
# This month = 0, Previous month = 1, Last n months = 1..n; the comparison window is the band just before it.
# Counting rows (not the l{n}m columns) lets a portfolio count in a window even if it has not reported since, and
# keeps the tiles, By Servicer and By Portfolio adding up to each other.
_ANCHOR_M = 'DateTrunc("month", GrandTotal(Max([Portfolios/reporting_month])))'
MO = f'DateDiff("month", DateTrunc("month", {c("reporting_month")}), {_ANCHOR_M})'
_BAND = {"cur": {"This month": (0, 0), "Previous month": (1, 1), "Last 3 months": (1, 3), "Last 6 months": (1, 6), "Last 12 months": (1, 12)},
         "prev": {"This month": (1, 1), "Previous month": (2, 2), "Last 3 months": (4, 6), "Last 6 months": (7, 12), "Last 12 months": (13, 24)}}


def dq_in(which: str = "cur", ctl: str = "D-Window") -> str:
    """True on rows inside the selected window (which='cur') or the one before it (which='prev')."""
    lo = f"Switch([{ctl}], " + ", ".join(f'"{w}", {a}' for w, (a, _) in _BAND[which].items()) + ")"
    hi = f"Switch([{ctl}], " + ", ".join(f'"{w}", {b}' for w, (_, b) in _BAND[which].items()) + ")"
    return f"({MO} >= {lo} and {MO} <= {hi})"


def dq_last(ctl: str = "D-Window") -> str:
    """True on rows in the window's last month: the latest month for This month, the month before otherwise."""
    return f'({MO} = If([{ctl}] = "This month", 0, 1))'


def dq_figures(which: str = "cur") -> dict:
    inw = dq_in(which)
    coll = f'Sum(If({inw}, {c("collections_sum")}))'
    rec = f'Sum(If({inw} and {c("is_reconciled_flag")}, {c("collections_sum")}, 0))'
    return {"coll": coll, "rec": rec, "share": f"{rec} / {coll}", "not_rec": f"{coll} - {rec}",
            "ports": f'CountDistinct(If({inw}, {c("portfolio_name")}))',
            "feed": f'CountDistinct(If({inw} and {HAS_FEED}, {c("portfolio_name")}))',
            "rec_ports": f'CountDistinct(If({dq_last()} and {c("is_reconciled_flag")}, {c("portfolio_name")}))',
            "stopped": f'CountDistinct(If({inw} and {c("feed_stopped_flag")}, {c("portfolio_name")}))',
            # Portfolios reporting with no case feed in the window: reporting minus with a feed, so the two always tally
            # (the user, 2026-10-14).
            "nofeed": f'CountDistinct(If({inw}, {c("portfolio_name")})) - CountDistinct(If({inw} and {HAS_FEED}, {c("portfolio_name")}))'}


def dq_status() -> str:
    """Why a portfolio's figures might look wrong, over the window, in short sentences each ending with a full
    stop: "51% reconciled. Feed 16 of 18. 2 feeds stopped." """
    f = dq_figures()
    share, feed, ports, stop = f["share"], f["feed"], f["ports"], f["stopped"]
    return (f'If({ports} = 0, "No data.", If({feed} = 0, "No case feed.", '
            f'If({share} >= 0.995, "Reconciled.", '
            f'If({f["rec"]} <= 0, "Not reconciled.", '
            f'If({share} < 0.005, "<1", Text(Round(100 * {share}, 0))) & "% reconciled."))))'
            f' & If({feed} > 0 and {feed} < {ports}, " Feed " & Text({feed}) & " of " & Text({ports}) & ".", "")'
            f' & If({feed} > 0 and {stop} > 0, " " & Text({stop}) & If({stop} = 1, " feed stopped.", " feeds stopped."), "")')   # 'No case feed.' says it all


def data_line(ctl: str = "D-Window") -> str:
    """'Figures cover May 2026 – Jul 2026; the reconciled share compares with Feb 2026 – Apr 2026'."""
    a = "Max([Portfolios/reporting_month])"
    m = lambda k: f'DateFormat(DateAdd("month", {-k}, {a}), "%b %Y")'
    rng = lambda lo, hi: m(lo) if lo == hi else f'{m(hi)} & " – " & {m(lo)}'
    sw = ", ".join(f'"{w}", {rng(*_BAND["cur"][w])} & "; the reconciled share compares with " & {rng(*_BAND["prev"][w])}' for w in WINDOWS)
    return f'<span style="color: #5C6B66">{{{{"Figures cover " & Switch([{ctl}], {sw})}}}}</span>'


def bench(metric: str) -> str:
    """Sum of one benchmark in the selected window; Servicer collections are like-for-like."""
    return {
        "coll": f'Switch([Bench], "Servicer", Sum({c("collections_servicer_lfl_sum")}), Sum({c("collections_sum")}))',
        "fc": f'Switch([Bench], "Servicer", Sum({c("servicer_forecast_sum")}), "Accounting", Sum({c("accounting_forecast_sum")}), Sum({c("underwriting_forecast_sum")}))',
    }[metric]


# --- elements -----------------------------------------------------------------
def col(cid, formula, name=None, fmt=None, hidden=False):
    d = {"id": cid, "formula": formula}
    if name is not None:
        d["name"] = name
    if fmt:
        d["format"] = fmt
    if hidden:
        d["hidden"] = True
    return d


def text(eid, body):
    return {"id": eid, "kind": "text", "body": body}


def seg(eid, control_id, name, values, value, labels=None):
    src = {"kind": "manual", "valueType": "text", "values": values}
    if labels:
        src["labels"] = labels   # what the toggle shows; formulas still switch on the values
    return {"id": eid, "kind": "control", "controlType": "segmented", "controlId": control_id, "name": name,
            "source": src, "value": value}


def pick(eid, control_id, name, values, value):
    return {"id": eid, "kind": "control", "controlType": "list", "controlId": control_id, "name": name, "mode": "include",
            "selectionMode": "single", "source": {"kind": "manual", "valueType": "text", "values": values}, "value": value}


def filter_list(eid, control_id, name, column):
    # Every filter also targets the two chart sources (forecast lines, case behaviours), which carry the same columns.
    return {"id": eid, "kind": "control", "controlType": "list", "controlId": control_id, "name": name, "mode": "include",
            "selectionMode": "multiple", "filters": [{"columnId": column, "source": SRC}, {"columnId": column, "source": FC},
                                                     {"columnId": column, "source": CB}],
            "source": {"kind": "source", "columnId": column, "source": SRC}, "values": []}


def kpi(eid, name, value_formula, fmt, *, timeline=True, period=False, comparison=None, direction="higher", trend=False, note=None, size=22, prior=None):
    cols = [col("v", value_formula, " ", fmt)]
    el = {"id": eid, "kind": "kpi-chart", "name": name, "source": SRC, "style": CARD, "value": {"columnId": "v", "fontSize": size, "color": "#012E26"}}
    if note:
        el["description"] = {"text": note, "visibility": "shown", "color": "#5C6B66"}
    if timeline:
        cols.insert(0, col("m", f'DateTrunc("month", {c("reporting_month")})', fmt=MONTH))
        el["timeline"] = {"columnId": "m"}
        # The headline KPIs show their trend with a date axis and hover values; small tiles stay a single number.
        el["trend"] = {"xAxis": "shown", "tooltip": "shown", "valueColor": "#1D5B4D", "comparisonColor": "#4F3DFF"} if trend else {"visibility": "hidden"}
    if period:
        el["periodComparison"] = "month"
    if comparison:
        cols.append(col("cmp", comparison, "Forecast", fmt))
        el["comparisonColumn"] = {"columnId": "cmp"}
    if prior:
        # Compared with the previous window of the same length, not simply the previous month. A % against a zero or
        # negative base is meaningless (net collections go negative when fees exceed collections), so a % card shows
        # no comparison then (the stress test, 2026-10-13); delta cards compare any base.
        if eid not in DELTA_TILES:
            prior = f"If(({prior}) <= 0, Null, {prior})"
        cols.append(col("cmp", prior, "previous window", fmt))
        el["comparisonColumn"] = {"columnId": "cmp"}
    if period or comparison or prior:
        el["comparison"] = ({"display": "percentage", "direction": "none", "colorNeutral": "#5C6B66"} if direction == "none"
                            else {"display": "percentage", "direction": direction, "colorGood": "#2E7D32", "colorBad": "#C62828"})
    if prior or eid in TILE_KIND:
        el["style"] = {"backgroundColor": "#FFFFFF", "borderWidth": 0}   # the box around it is the card
        el["name"] = {"text": name, "fontSize": 14, "fontWeight": "bold", "color": "#012E26"}
    if prior:
        el["comparison"]["label"] = "hidden"   # it can only be static; the line under the tile names the windows
        if eid in DELTA_TILES:
            el["comparison"]["display"] = "delta"
        el["style"] = {"backgroundColor": "#FFFFFF", "borderWidth": 0}   # the box around it is the card
        el["name"] = {"text": name, "fontSize": 14, "fontWeight": "bold", "color": "#012E26"}   # long titles fit the boxed card
    el["columns"] = cols
    return el


# The Portfolio chart's four lines, in theme-colour order: (column id, series in fc_src, label).
FC_LINES = [("sf", "Servicer forecast", "Servicer forecast"), ("af", "Accounting forecast", "Accounting forecast"),
            ("uf", "Underwriting forecast", "Underwriting forecast"), ("a", "Collections", "Collections")]
# The newest anchor month in view: the selected month, or the latest complete one when nothing is selected.
FC_END = f'GrandTotal(Max({fcc("anchor_month")}))'
FC_EUR = {"kind": "number", "formatString": "$.4~s", "currencySymbol": "€"}   # axis €40M, hover €40.03M


def fc_line(series: str, actual_only: bool = False) -> str:
    """One line of the Portfolio chart: the Actual rows in view, plus the newest anchor's 12 months ahead."""
    keep = f'{fcc("row_kind")} = "Actual"' if actual_only or series == "Collections" else \
        f'({fcc("row_kind")} = "Actual" or {fcc("anchor_month")} = {FC_END})'
    return f'Sum(If({keep} and {fcc("series")} = "{series}", {fcc("value_sum")}))'


def fc_cum(series: str) -> str:
    """Running total. Collections stop at the selected month: without the If, CumulativeSum carries the last total flat."""
    run = f"CumulativeSum({fc_line(series)})"
    return f"If(IsNull({fc_line(series)}), Null, {run})" if series == "Collections" else run


FC_PORTS = f'CountDistinct(If({fcc("row_kind")} = "Actual" and {fcc("series")} = "Collections", {fcc("portfolio_name")}))'


def fc_signed(ratio: str) -> str:
    """'▲ +2.4%' ahead of forecast, '▼ -7.7%' behind, blank with no collections. Inline, not a column reference:
    formulas address columns by display name, which titleize() changes."""
    return f'If(IsNull({ratio}), Null, If({ratio} >= 1, "▲ +", "▼ ") & Text(Round(({ratio} - 1) * 100, 1)) & "%")'


def fc_vs(series: str) -> str:
    """Collections as a ratio of a forecast: the month's, or to date under View = Cumulative. Bracketed: it is spliced."""
    month = f"{fc_cmp(series)} / {fc_line(series, True)}"
    to_date = f"If(IsNull({fc_cmp(series)}), Null, CumulativeSum({fc_cmp(series)}) / CumulativeSum({fc_line(series, True)}))"
    return f'(Switch([View], "Cumulative", {to_date}, {month}))'


def fc_cmp(series: str) -> str:
    """The collections a forecast is measured against (like-for-like for the servicer), on Actual rows only."""
    return f'Sum(If({fcc("row_kind")} = "Actual" and {fcc("series")} = "{series}", {fcc("compare_sum")}))'


def build() -> tuple[dict, dict]:
    sql = SQL.read_text()
    theme = json.loads(THEME.read_text()); theme.pop("_comment", None)
    # The output columns are the aliases in the final SELECT list (between its SELECT and FROM).
    select_list = sql.split("\nSELECT\n")[-1].split("\nFROM aggregated_metrics")[0]
    out_cols = [m.group(1) or m.group(2) for m in
                re.finditer(r"\bAS\s+([a-z0-9_]+)\s*,?\s*$|^\s+[a-z]+\.([a-z0-9_]+)\s*,?\s*$", select_list, flags=re.M)]
    els: list[dict] = []

    # ---- data: the one query every tile reads, and the definitions ----------
    els.append({"id": "src", "kind": "table", "name": "Portfolios",
                "source": {"kind": "sql", "connectionId": CONNECTION, "statement": sql},
                "columns": [col(n.upper(), f"[Custom SQL/{n.upper()}]", n) for n in out_cols]})
    # The Portfolio chart's own source (the user, 2026-10-11): collections and all three forecasts, the
    # forecasts running 12 months past the selected month. The live query cuts forecasts at today, so the
    # chart needs future months it cannot give; this one prepends it as `main`, so past months match it to the cent.
    fc_sql = FC_SQL.read_text()
    fc_cols = re.findall(r"\bAS\s+([a-z_]+)\b", fc_sql.split("-- Long format:")[1].split("UNION ALL")[0])
    fc_cols = ["row_kind", "portfolio_name", "country_name", "servicer_group", "seller", "deal", "reconciliation_status",
               "anchor_month", "chart_month"] + fc_cols
    els.append({"id": "fc_src", "kind": "table", "name": "Forecast lines",
                "source": {"kind": "sql", "connectionId": CONNECTION,
                           "statement": "-- sigma_queries/forecast_chart_element.sql, with portfolios_element.sql as `main`. Edit those, rebuild.\n"
                                        f"WITH main AS (\n{sql}\n),\n{fc_sql}"},
                "columns": [col(n.upper(), f"[Custom SQL/{n.upper()}]", n) for n in fc_cols]})
    # The Cases chart's own source (the user, 2026-10-12): one row per portfolio-month-behaviour, so the stacked
    # bars can be coloured by a behaviour column, with fixed colours and a legend that highlights.
    cb_sql = CB_SQL.read_text()
    cb_cols = ["portfolio_name", "country_name", "servicer_group", "seller", "deal", "reconciliation_status", "is_reconciled_flag",
               "reporting_month", "behaviour", "behaviour_order", "case_count", "case_amount"]
    els.append({"id": "cb_src", "kind": "table", "name": "Case behaviours",
                "source": {"kind": "sql", "connectionId": CONNECTION,
                           "statement": "-- sigma_queries/case_behaviour_element.sql, with portfolios_element.sql as `main`. Edit those, rebuild.\n"
                                        f"WITH main AS (\n{sql}\n),\n{cb_sql}"},
                "columns": [col(n.upper(), f"[Custom SQL/{n.upper()}]", n) for n in cb_cols]})
    rows = list(csv.DictReader(DEFS.open()))
    esc = lambda v: v.replace("'", "''")
    values = ",\n".join(f"('{esc(title_case(r['term']))}', '{esc(r['page'])}', '{esc(r['group'])}', '{esc(r['definition'])}', "
                        f"'{esc(r['formula'])}', '{esc(r['computed_in'])}', '{esc(r['caveat'])}')" for r in rows)
    els.append({"id": "src_defs", "kind": "table", "name": "Data definitions",
                "source": {"kind": "sql", "connectionId": CONNECTION,
                           "statement": "-- Generated from work/servicing/docs/definitions.csv. Edit the CSV, rebuild.\n"
                                        "SELECT column1 AS term, column2 AS page, column3 AS term_group, column4 AS meaning,\n"
                                        "       column5 AS formula, column6 AS computed_in, column7 AS watch_out\n"
                                        f"FROM VALUES\n{values}"},
                "columns": [col(n.upper(), f"[Custom SQL/{n.upper()}]", label) for n, label in
                            [("term", "Term"), ("page", "Page"), ("term_group", "Group"), ("meaning", "Meaning"),
                             ("formula", "Formula"), ("computed_in", "Computed in"), ("watch_out", "Watch out")]]})

    # ---- header panel: title, data status, filters (every page) ------------
    els += [
        text("h_title", "## **Servicing Dashboard**"),
        {"id": "f_month", "kind": "control", "controlType": "date-range", "controlId": "Reporting-Month", "name": "Reporting month",
         "mode": "between", "filters": [{"columnId": "REPORTING_MONTH", "source": SRC}, {"columnId": "ANCHOR_MONTH", "source": FC},
                     {"columnId": "REPORTING_MONTH", "source": CB}], "includeNulls": "when-no-value-is-selected"},
        filter_list("f_country", "Country", "Country", "COUNTRY_NAME"),
        filter_list("f_servicer", "Servicer", "Servicer", "SERVICER_GROUP"),
        filter_list("f_seller", "Seller", "Seller", "SELLER"),
        filter_list("f_deal", "Deal", "Deal", "DEAL"),   # between Seller and Portfolio (the user, 2026-10-12)
        filter_list("f_portfolio", "Portfolio", "Portfolio", "PORTFOLIO_NAME"),
        # In words, on a text column: nothing chosen = all portfolios. No default value - a default
        # here would filter every tile (the 43-row trap).
        filter_list("f_rec", "Reconciliation", "Reconciliation", "RECONCILIATION_STATUS"),
        # Clears the seven filters only. A workbook-wide clear would also empty Window, Benchmark and Grain,
        # and every Switch() on them would go blank.
        {"id": "h_clear", "kind": "button", "text": "Clear Filters", "appearance": "outline", "size": "small", "align": "right",
         "fontColor": "#1D5B4D", "actions": [{"id": "clear_filters", "trigger": "on-click", "effects": [
             {"effect": "clear-control", "scope": {"type": "control", "controlId": cid}}
             for cid in ("Reporting-Month", "Country", "Servicer", "Seller", "Deal", "Portfolio", "Reconciliation")]}]},
    ]

    # ---- the dark band at the top of each page: page subtitle + four status tiles ----------------
    def band(pg: str, subtitle: str) -> list[dict]:
        return [
            {"id": f"{pg}_band", "kind": "container", "style": {"backgroundColor": "#012E26", "borderRadius": "pill"}, "spacing": "medium"},
            text(f"{pg}_sub", f'<span style="color: #D8E494">{subtitle}</span>'),
            kpi(f"{pg}_asof", "Data as of", f'Max({c("data_as_of_month")})', MONTH, timeline=False, note="Latest complete reporting month", size=20),
            kpi(f"{pg}_ports", "Portfolios reporting", f'CountDistinct({c("portfolio_name")})', INT, note="In the latest selected month", size=20),
            kpi(f"{pg}_feed", "Portfolios with a case feed", f'CountDistinct(If({HAS_FEED}, {c("portfolio_name")}))', INT, note="Only Intrum and Massey portfolios send one", size=20),
            kpi(f"{pg}_rec", "Portfolios reconciled", f'CountDistinct(If({c("is_reconciled_flag")}, {c("portfolio_name")}))', INT, note="Case feed agrees with the servicer report", size=20),
        ]
    els += band("bp", "**Summary**")
    els += band("bc", "**Summary**")
    els += band("bd", "**Data Quality: reconciliation and case feeds**")

    # ---- Portfolio page: 1 · Overview (executive tiles, then the trend), 2 · Drill down
    # Every tile follows the Window: collections are the TOTAL for the window, ratios are computed over it,
    # one tile is the monthly average. Servicer comparisons are like-for-like.
    # The latest reporting month (C_*) against the comparison window: its average month for money (A_*), its totals
    # for ratios (S_*). Servicer comparisons stay like-for-like.
    C_COLL, C_LFL = cur("collections_sum"), cur("collections_servicer_lfl_sum")
    C_FC = {"Servicer": cur("servicer_forecast_sum"), "Accounting": cur("accounting_forecast_sum"), "Underwriting": cur("underwriting_forecast_sum")}
    A = lambda prefix: cmp_avg(prefix, "P-Window")
    S = lambda prefix: cmp_sum(prefix, "P-Window")
    A_FC = {"Servicer": A("servicer_forecast"), "Accounting": A("accounting_forecast"), "Underwriting": A("underwriting_forecast")}
    S_FC = {"Servicer": S("servicer_forecast"), "Accounting": S("accounting_forecast"), "Underwriting": S("underwriting_forecast")}
    def vs_bench(op: str, coll, lfl, fc) -> str:
        return (f'Switch([Bench], "Servicer", {lfl} {op} {fc["Servicer"]}, '
                f'"Accounting", {coll} {op} {fc["Accounting"]}, {coll} {op} {fc["Underwriting"]})')
    fc_pick = lambda fc: f'Switch([Bench], "Servicer", {fc["Servicer"]}, "Accounting", {fc["Accounting"]}, {fc["Underwriting"]})'
    els += [
        box("p_head"),
        text("p_s1", "## ** 1  ·  Overview**"),
        seg("p_window", "P-Window", "Comparison window (average monthly)", CMP_WINDOWS, "Previous month", CMP_LABELS),
        text("p_cmp", compare_line("P-Window")),
        seg("p_bench", "Bench", "Benchmark", ["Servicer", "Accounting", "Underwriting"], "Servicer"),
        # Short fixed titles; every card is the latest reporting month, and only the % moves with the Comparison Window.
        # No Average Monthly Collections card (removed 2026-10-12): the % on Total Collections already compares with it.
        kpi("p_coll", "Total collections", M(C_COLL), EUR_M2, prior=M(A("collections")), note="What debtors paid in the latest reporting month, before servicer costs"),
        kpi("p_vs", "Collections as % of forecast", vs_bench("/", C_COLL, C_LFL, C_FC), PCT,
            prior=vs_bench("/", S("collections"), S("collections_servicer_lfl"), S_FC), note="Collections ÷ the chosen forecast · Servicer compares only portfolios with a servicer forecast"),
        # In millions to 2 decimals: Sigma formats this card's euro comparison like its value (2026-10-12).
        kpi("p_gap", "Collections minus forecast", M(vs_bench("-", C_COLL, C_LFL, C_FC)), EUR_M2,
            prior=M(vs_bench("-", A("collections"), A("collections_servicer_lfl"), A_FC)), note="Collections less the chosen forecast · Negative means behind plan"),
        kpi("p_fc", "Total forecast", M(fc_pick(C_FC)), EUR_M2, prior=M(fc_pick(A_FC)), note="The chosen forecast for the latest reporting month"),
        kpi("p_net", "Total net collections", M(cur("net_collections_sum")), EUR_M2, prior=M(A("net_collections")), note="Collections after everything the servicer keeps"),
        kpi("p_cost", "Servicer cost, % of collections", f'{cur("servicer_cost_total_sum")} / {C_COLL}', PCT,
            prior=f'{S("servicer_cost_total")} / {S("collections")}', direction="lower", note="What the servicer keeps, as a share of collections · Lower is better"),
        box("p_chartbox"),
        seg("p_view", "View", "View", ["Monthly", "Cumulative"], "Monthly"),
        # Collections and all three forecasts at once, whatever the Benchmark and Window (the user, 2026-10-11).
        # Rows of fc_src: Actual (the selected months) and Ahead (12 months of forecast after each anchor month);
        # only the newest anchor's Ahead rows count, so the forecast runs a year past the month selected.
        # Colours follow the theme's list order: servicer violet, accounting green, underwriting periwinkle,
        # collections deep green (the brand's near-black). Collections solid, forecasts dashed: seriesLineAreaStyle,
        # as NPL Portfolio Dashboard v2's collections chart does it.
        {"id": "p_chart", "kind": "combo-chart", "name": "Collections vs forecasts", "source": FC,
         "style": {"backgroundColor": "#FFFFFF", "borderRadius": "pill"},
         # Two lines fit before Sigma cuts the description off.
         "description": {"text": "Forecasts run 12 months past the selected month. Every month in euro at the latest month-end exchange rate. "
                                 "Servicer: only portfolios that have a servicer forecast.", "visibility": "shown", "color": "#5C6B66"},
         "columns": [col("m", f'DateTrunc("month", {fcc("chart_month")})', "Reporting month", MONTH)]
                    # The lines themselves stay out of the hover (2026-10-12): Sigma shows the hovered line's own figure,
                    # which repeated one of the copies below ("Collections" twice). The copies alone show each once.
                    + [dict(col(cid, M(f'Switch([View], "Cumulative", {fc_cum(series)}, {fc_line(series)})'), label, EUR_M2), tooltip="hidden")
                       for cid, series, label in FC_LINES]
                    # Every line's figure again, under short names, so hovering ANY line shows the whole month in one box
                    # (a combo chart has no shared hover: Sigma refuses multiSeries there, and a line chart drops the dashes).
                    + [col(f"h_{cid}", M(f'Switch([View], "Cumulative", {fc_cum(series)}, {fc_line(series)})'), short, EUR_M2)
                       # The copy of Collections is sent with a zero-width space so Sigma does not number it "Collections
                       # (1)" (the user, 2026-10-13); Sigma trims the space and both read "Collections". The export then
                       # has two "Collections" columns: pandas reads the copy as "collections.1".
                       for (cid, series, _), short in zip(FC_LINES, ("Servicer", "Accounting", "Underwriting", "Collections\u200b"))]
                    # Ahead or behind, signed with an arrow: a chart tooltip cannot be coloured (the user asked for green/red).
                    # The % follows the View (2026-10-13): Cumulative divides the running totals the lines show, so the
                    # hover never reads a month's -25.2% beside to-date totals that are -12.1% apart.
                    + [col(f"t_{k}", fc_signed(fc_vs(series)), f"vs {name}")
                       for k, series, name in (("sf", "Servicer forecast", "servicer"), ("af", "Accounting forecast", "accounting"),
                                               ("uf", "Underwriting forecast", "underwriting"))]
                    + [
                       col("t_ports", f'If({FC_PORTS} > 0, {FC_PORTS}, Null)', "Portfolios reporting", INT)],   # blank, not 0, on forecast-only months
         # One box per month: collected, each forecast with collections as a % of it, then portfolios reporting.
         "tooltip": {"columns": [{"id": x} for x in ("h_a", "h_sf", "t_sf", "h_af", "t_af", "h_uf", "t_uf", "t_ports")], "format": {"columnNames": "shown"}},
         "xAxis": {"columnId": "m"},
         "yAxis": {"columnIds": [{"columnId": cid, "type": "line"} for cid, _, _ in FC_LINES], "format": {"title": {"text": "Collections (€)"}}},
         "seriesLineAreaStyle": [{"columnId": cid, "style": {"line": {"style": "dashed", "width": 2}, "points": {"visibility": "hidden"}}}
                                 for cid, _, _ in FC_LINES[:3]]
                                + [{"columnId": "a", "style": {"line": {"style": "solid", "width": 3}, "missing": "hide", "points": {"visibility": "hidden"}}}],
         "legend": {"position": "bottom"}},
        # Month by Month table removed (2026-10-12): the chart's data downloads with every figure.
    ]
    # §2 Performance and §3 Full breakdown read hidden helper tables (page "Model"): a grouped table
    # gives one row per group, and the visible table reads that grouping - flat, no subtotal rows.
    PG = ["Country", "Servicer", "Seller", "Deal", "Portfolio"]   # Portfolio added (the user, 2026-10-14)
    perf_grain = lambda ctl: "Switch([" + ctl + "], " + ", ".join(f'"{g}", {c(GRAIN_COL[g])}' for g in PG) + ")"
    # §2 is §1's cards per group (the user, 2026-10-12): the latest month, then the change against the Comparison Window.
    # (title, latest month, the window's figure, change as "pct" / "pts" / "eur", lower is better)
    PPC, PPA, PPS = perf_cur, (lambda prefix: perf_avg("P-Perf-Window", prefix)), (lambda prefix: perf_sum("P-Perf-Window", prefix))
    def pbench(src, op=None):
        coll, lfl = src("collections_sum" if src is PPC else "collections"), src("collections_servicer_lfl_sum" if src is PPC else "collections_servicer_lfl")
        fc = {b: src(f"{b.lower()}_forecast_sum" if src is PPC else f"{b.lower()}_forecast") for b in ("Servicer", "Accounting", "Underwriting")}
        if op is None:
            return f'Switch([P-Perf-Bench], "Servicer", {fc["Servicer"]}, "Accounting", {fc["Accounting"]}, {fc["Underwriting"]})'
        return f'Switch([P-Perf-Bench], "Servicer", {lfl} {op} {fc["Servicer"]}, "Accounting", {coll} {op} {fc["Accounting"]}, {coll} {op} {fc["Underwriting"]})'
    P_PERF = [
        ("Total collections", PPC("collections_sum"), PPA("collections"), "pct", False),
        ("Total forecast", pbench(PPC), pbench(PPA), "pct", False),
        ("Collections as % of forecast", pbench(PPC, "/"), pbench(PPS, "/"), "pts", False),
        ("Collections minus forecast", pbench(PPC, "-"), pbench(PPA, "-"), "eur", False),
        ("Total net collections", PPC("net_collections_sum"), PPA("net_collections"), "pct", False),
        ("Servicer cost, % of collections", f'{PPC("servicer_cost_total_sum")} / {PPC("collections_sum")}',
         f'{PPS("servicer_cost_total")} / {PPS("collections")}', "pts", True),
    ]
    P_METRICS = {   # label -> formula over the selected months (Sigma aggregates over the group)
        "Collections": f'Sum({c("collections_sum")})',
        "Collections as % of forecast": f'{bench("coll")} / {bench("fc")}',
        "Collections minus forecast": f'{bench("coll")} - {bench("fc")}',
        "Net collections": f'Sum({c("net_collections_sum")})',
        "Servicer cost as % of collections": f'Sum({c("servicer_cost_total_sum")}) / Sum({c("collections_sum")})',
    }
    P_FMT = {"Collections": EUR_FULL, "Collections as % of forecast": PCT, "Collections minus forecast": EUR_FULL, "Net collections": EUR_FULL,
             "Servicer cost as % of collections": PCT}
    # Text only, coloured by where the value ranks in its column: red (worst) -> grey -> green (best).
    LOWER_IS_BETTER = {"Servicer cost as % of collections", "Lost"}
    def rank_text(cid, name):
        scheme = ["#C62828", "#8790AB", "#2E7D32"]
        rule = {"type": "fontScale", "columnIds": [cid], "scheme": scheme[::-1] if name in LOWER_IS_BETTER else scheme}
        # Plan figures pivot on the plan: below it red, above it green, whatever one outlier does to the range.
        if name == "Collections as % of forecast":
            rule["domain"] = {"min": 0.8, "mid": 1, "max": 1.2}
        elif name == "Collections minus forecast":
            rule["domain"] = {"mid": 0}
        return rule
    CHG_FMT = {"pct": {"kind": "number", "formatString": "+,.1%"}, "pts": {"kind": "number", "formatString": "+,.1f", "suffix": " pts"},
               "eur": {"kind": "number", "formatString": "+$,.2f", "currencySymbol": "€"},   # tables: full euros, 2 dp (2026-10-12)
               "cnt": {"kind": "number", "formatString": "+,.0f"}}   # a difference in cases (Net Change, 2026-10-13)
    def change(kind, now, base):   # as §1's cards: % for money and counts, points for ratios, euro for the gap
        # Bracket both sides: a ratio's base is "a / b" and Net Change's is "fresh - lost", so "now / a / b - 1" read
        # -100% for every group until 2026-10-13 (the user spotted it on Avg Monthly Collection per Case).
        now, base = f"({now})", f"({base})"
        # A % change is blank when the base is zero or negative (the stress test, 2026-10-13): net collections turn
        # negative when fees exceed collections, and a % of a negative base reads as -1,168% or flips its sign.
        if kind == "pct":
            return f"If({base} <= 0, Null, {now} / {base} - 1)"
        return f"100 * ({now} - {base})" if kind == "pts" else f"{now} - {base}"
    def perf_tables(pre, grain_ctl, metrics, fmts):
        # Every card is a column (its latest month), followed by its change against the Comparison Window; the change is
        # coloured green when better, red when worse. Opens sorted on the first card, high to low; any header sorts.
        cols = [col("grain", perf_grain(grain_ctl), "Group")]
        names = ["Group"]
        for i, (name, now, base, kind, lower) in enumerate(metrics):
            cols.append(col(f"m{i}", now, name, fmts[i]))
            cols.append(col(f"x{i}", change(kind, now, base), f"{name} vs window", CHG_FMT[kind]))
            names += [name, f"{name} vs window"]
        helper = {"id": f"{pre}_perf_src", "kind": "table", "name": f"{pre} performance by group", "source": SRC, "columns": cols,
                  "groupings": [{"id": "g", "groupBy": ["grain"], "calculations": [x["id"] for x in cols[1:]]}]}
        fmt_of = {"Group": None}
        for i, (name, *_rest) in enumerate(metrics):
            fmt_of[name] = fmts[i]; fmt_of[f"{name} vs window"] = CHG_FMT[metrics[i][3]]
        vcols = [col(f"v{k}", f"[{pre} performance by group/{n}]", n, fmt_of[n]) for k, n in enumerate(names)]
        scheme = ["#C62828", "#8790AB", "#2E7D32"]
        colours = [{"type": "fontScale", "columnIds": [f"v{2 * i + 2}"], "scheme": scheme[::-1] if lower else scheme, "domain": {"mid": 0}}
                   for i, (_n, _a, _b, _k, lower) in enumerate(metrics)]
        vis = {"id": f"{pre}_perf", "kind": "table", "name": "Performance", "style": CARD,
               "description": "Each card's latest reporting month, then its change against the Comparison Window",
               "source": {"kind": "table", "elementId": f"{pre}_perf_src", "groupingId": "g"},
               "columns": vcols,
               "sort": [{"columnId": "v1", "direction": "descending", "nulls": "last"}],
               "conditionalFormats": [hide_nulls([f"v{k}" for k in range(1, len(names))])] + colours, "tableStyle": WRAP,
               # The Group column stays put while the many metric columns scroll (the user, 2026-10-14).
               "frozenColumn": {"columnId": "v0"}}
        return [helper, vis]
    def full_tables(pre, metrics, fmts):
        # Portfolio first, so it alone can be frozen as the reference while the rest scroll (the user, 2026-10-14).
        dims = [("Portfolio", "portfolio_name"), ("Country", "country_name"), ("Servicer", "servicer_group"), ("Seller", "seller"), ("Deal", "deal")]
        nd = len(dims)
        cols = [col(f"d{i}", c(src), n) for i, (n, src) in enumerate(dims)]
        cols += [col(f"m{i}", f, n, fmts.get(n)) for i, (n, f) in enumerate(metrics.items())]
        helper = {"id": f"{pre}_full_src", "kind": "table", "name": f"{pre} by portfolio", "source": SRC, "columns": cols,
                  "groupings": [{"id": "g", "groupBy": [f"d{i}" for i in range(nd)], "calculations": [x["id"] for x in cols[nd:]]}]}
        names = [n for n, _ in dims] + list(metrics)
        vcols = [col(f"v{i}", f"[{pre} by portfolio/{n}]", n, fmts.get(n)) for i, n in enumerate(names)]
        # No relative-bar column (removed in the user's artifact, 2026-10-12).
        vis = {"id": f"{pre}_full", "kind": "table", "name": "Full breakdown", "style": CARD, "description": "Download the data locally",
               "source": {"kind": "table", "elementId": f"{pre}_full_src", "groupingId": "g"},
               "columns": vcols,
               "sort": [{"columnId": f"v{nd}", "direction": "descending", "nulls": "last"}], "tableStyle": WRAP,
               "conditionalFormats": [hide_nulls([f"v{k}" for k in range(nd, len(names))])],
               # Only Portfolio stays put; everything else scrolls (the user, 2026-10-14).
               "frozenColumn": {"columnId": "v0"}}
        return [helper, vis]
    P_FULL = {k: P_METRICS[k] for k in ["Collections", "Collections minus forecast", "Net collections", "Servicer cost as % of collections"]}
    P_FULL.update({"% of servicer forecast": f'Sum({c("collections_servicer_lfl_sum")}) / Sum({c("servicer_forecast_sum")})',
                   "% of accounting forecast": f'Sum({c("collections_sum")}) / Sum({c("accounting_forecast_sum")})',
                   "% of underwriting forecast": f'Sum({c("collections_sum")}) / Sum({c("underwriting_forecast_sum")})'})
    P_FULL_FMT = dict(P_FMT, **{"% of servicer forecast": PCT, "% of accounting forecast": PCT, "% of underwriting forecast": PCT})
    els += [
        box("p_perfhead"),
        text("p_s2", "## ** 2  ·  Performance**"),
        text("C9DdaMOFr_", "Every card above, by group: the latest reporting month and its change against the Comparison Window. Click any column to sort."),
        seg("p_pgrain", "P-Perf-Grain", "Group by", PG, "Country"),
        seg("p_pwin", "P-Perf-Window", "Comparison window (average monthly)", CMP_WINDOWS, "Previous month", CMP_LABELS),
        # §2's own Benchmark (the user, 2026-10-12): the table's forecast columns follow it, independently of §1's.
        seg("p_pbench", "P-Perf-Bench", "Benchmark", ["Servicer", "Accounting", "Underwriting"], "Servicer"),
        *perf_tables("bp", "P-Perf-Grain", P_PERF, [EUR_FULL, EUR_FULL, PCT, EUR_FULL, EUR_FULL, PCT]),
        box("p_fullhead"),
        # §3 reads like §1 and §2 (the user, 2026-10-13): a medium heading, then the description as its own paragraph.
        text("p_s3", "## ** 3  ·  Full breakdown**"),
        text("p_fulldesc", "One row per portfolio over the selected months. Click any column to sort."),
        *full_tables("bp", P_FULL, P_FULL_FMT),
    ]

    # ---- Cases page: 1 · Overview (executive tiles, behaviour over time, the book), 2 · Drill down
    cw = case_window
    # Jitter in and jitter out removed (the manager's review, 2026-10-09); the mart still carries them.
    # One bar chart of every behaviour (the user, 2026-10-12), Count | Collections | Avg tabs, read from cb_src: one row
    # per portfolio-month-behaviour, coloured by the behaviour column. That pins each behaviour to a palette colour
    # (customColors) and gives Sigma's own legend on the right: click to highlight, several at once.
    # Renamed for the manager (2026-10-12): dbt's first collection is "New". Fresh is dbt's new minus New (the user,
    # 2026-10-13): paid this month, nothing in the two before, and paid at some point before. New and Fresh never overlap.
    # The four paying groups split each month's collected cases exactly (the user, 2026-10-13: the bars tally to the
    # Cases total); cb_src says how. Lost is below zero: those cases did not pay this month. The NPL dashboard's
    # palette, plus the dashboard's own negative red for Lost. Zero-width spaces (as in cb_src) set the stack order:
    # Sigma puts the last behaviour at the bottom, so Three Consecutive Months is the base of every bar.
    ZW = "\u200b"
    # Colours (the user, 2026-10-13): New dark green; the paying base in purples, darkest for the steadiest.
    C_COLOURS = {"New": "#1D5B4D", ZW + "Fresh": "#C4C9FA", ZW * 2 + "Two of Three Months": "#A6ADF8",
                 ZW * 3 + "Three Consecutive Months": "#4F3DFF", ZW * 4 + "Lost": "#C62828"}
    C_ALL = "All Collected Cases"   # the month's total: the Avg tab's yardstick, filtered out of the two stacked tabs
    # A white spacer worth Lost on top of each stack, so Sigma's bar total (which adds every segment, Lost too) reads the
    # month's total; cb_src says why. The Avg tab filters it out.
    C_SPACER = " "   # blank, so Sigma's legend leaves it out (the user, 2026-10-13)
    cbc = lambda n: f"[Case behaviours/{n}]"
    EUR_AXIS = {"kind": "number", "formatString": "$.3~s", "currencySymbol": "€"}   # €20M, €0 on the axis (not €0.000)
    C_STACK_NOTE = ("The four paying groups add up to the month's collected cases: each paying case is in exactly one. "
                    "Lost sits below zero: those cases paid in the two months before and not this month. "
                    "Hover a segment to read it; click the legend to pick behaviours.")
    C_AVG_NOTE = ("What each group paid per case in the month: its collections ÷ its cases. All Collected Cases is the month's "
                  "average across every paying case. Lost: what those cases paid per case in their last paying month.")
    def case_bars(eid, value_col, title, fmt, axis_title, extra, millions=False):
        v = f'Sum({cbc(value_col)})'
        cols = [col("m", f'DateTrunc("month", {cbc("reporting_month")})', "Reporting month", MONTH),
                col("b", cbc("behaviour"), "Behaviour"),
                col("v", M(v) if millions else v, axis_title, fmt)] + extra
        tip = {"columns": [{"id": x["id"]} for x in extra], "format": {"columnNames": "shown"}} if extra else {"format": {"columnNames": "shown"}}
        return {"id": eid, "kind": "bar-chart", "stacking": "stacked", "name": title, "source": CB, "style": {"backgroundColor": "#FFFFFF"},
                "description": {"position": "tooltip", "text": C_STACK_NOTE},
                "columns": cols, "tooltip": tip,
                # The month's total over each bar (the user, 2026-10-13), in the value's own format: €X.XXM, or cases.
                "dataLabel": {"labels": "hidden", "totals": {"display": "shown", "labelDisplay": "all"}},
                "filters": [{"id": f"f_{eid}_all", "columnId": "b", "kind": "list", "mode": "exclude", "values": [C_ALL]}],
                "color": {"by": "category", "column": "b", "customColors": [{"value": k, "color": v} for k, v in C_COLOURS.items()] + [{"value": C_SPACER, "color": "#FFFFFF"}]},
                "xAxis": {"columnId": "m"}, "yAxis": {"columnIds": ["v"], "format": {"title": {"text": axis_title}}},
                "legend": {"position": "right"}}
    def case_avg_bars(eid, title):
        # Side by side, not stacked: averages do not add. Lost's euro and count are both negative, so its average is
        # what a lost case paid in its last paying month.
        cols = [col("m", f'DateTrunc("month", {cbc("reporting_month")})', "Reporting month", MONTH),
                col("b", cbc("behaviour"), "Behaviour"),
                col("v", f'Sum({cbc("case_amount")}) / Sum({cbc("case_count")})', "Average collection per case (€)", EUR_FULL)]
        return {"id": eid, "kind": "bar-chart", "stacking": "none", "name": title, "source": CB, "style": {"backgroundColor": "#FFFFFF"},
                "description": {"position": "tooltip", "text": C_AVG_NOTE},
                "columns": cols, "tooltip": {"format": {"columnNames": "shown"}},
                "filters": [{"id": f"f_{eid}_spacer", "columnId": "b", "kind": "list", "mode": "exclude", "values": [C_SPACER]}],
                "color": {"by": "category", "column": "b",
                          "customColors": [{"value": C_ALL, "color": "#012E26"}] + [{"value": k, "color": v} for k, v in C_COLOURS.items()]},
                "xAxis": {"columnId": "m"}, "yAxis": {"columnIds": ["v"], "format": {"title": {"text": "Average collection per case (€)"}}},
                "legend": {"position": "right"}}
    case_feed_txt = (f'Text(CountDistinct({cbc("portfolio_name")})) & " (" & '
                     f'Text(CountDistinct(If({cbc("is_reconciled_flag")}, {cbc("portfolio_name")}))) & " reconciled)"')
    # Short fixed titles (the user, 2026-10-12): the line above the cards says "Monthly Average (QoQ)" and so on.
    CA = lambda prefix: cmp_avg(prefix, "C-Window", "months_in_case_l{n}m_window")   # months with a case feed
    CS = lambda prefix: cmp_sum(prefix, "C-Window", "months_in_case_l{n}m_window")
    els += [
        box("c_head"),
        text("c_s1", "## ** 1  ·  Overview**"),
        text("c_note", "Case counts are a floor: only Intrum and Massey portfolios send a case feed."),
        seg("c_window", "C-Window", "Comparison window (average monthly)", CMP_WINDOWS, "Previous month", CMP_LABELS),
        # The section bands say what their cards show (the user, 2026-10-12): the book is one month's snapshot, and the
        # behaviour cards' period and comparison moved here from under the Window toggle.
        dict(text("MxSGmmb_TV", '<span style="color: var(--colors-baseForeground)">**Overall Summary**</span><span style="color: #5C6B66"> · </span>'
                                '<span style="color: #5C6B66">{{"Monthly snapshot as of the latest reporting month, " & '
                                'DateFormat(Max([Portfolios/reporting_month]), "%b %Y")}}</span>'), verticalAlign="center"),
        dict(text("nSopK5b7To", '**Case Behavioural Summary**<span style="color: #5C6B66"> · </span>' + compare_line("C-Window", "months_in_case_l{n}m_window")),
             verticalAlign="center"),
        # Every card is the latest reporting month; the % compares it with the Comparison Window's average month.
        kpi("c_cc", "Collected cases", cur("collected_cases_count"), INT, prior=CA("collected_cases"), note="Cases that paid something in the latest reporting month"),
        kpi("c_ce", "Collections", M(cur("collected_cases_amount_sum")), EUR_M2, prior=M(CA("collected_cases_amount")), note="What paying cases paid in the latest reporting month, from the case feed"),
        kpi("c_cpe", "Avg Monthly Collection per Case", f'{cur("collected_cases_amount_sum")} / {cur("collected_cases_count")}', EUR_FULL,
            prior=f'{CS("collected_cases_amount")} / {CS("collected_cases")}', note="Collections ÷ collected cases"),
        # dbt's new already holds New and Fresh, so new minus lost is New + Fresh - Lost: every case that started paying,
        # less every case that stopped.
        kpi("c_nl", "Net change in collected cases", f'{cur("collected_cases_new_count")} - {cur("collected_cases_lost_count")}', INT,
            prior=f'{CA("collected_cases_new")} - {CA("collected_cases_lost")}', note="New plus fresh, minus lost · Is the paying base growing?"),
        kpi("c_first", "New", cur("collected_cases_first_collection_count"), INT, prior=CA("collected_cases_first_collection"), note="Cases paying for the first time ever"),
        kpi("c_new", "Fresh", f'{cur("collected_cases_new_count")} - {cur("collected_cases_first_collection_count")}', INT,
            prior=f'{CA("collected_cases_new")} - {CA("collected_cases_first_collection")}', note="Back to paying after two quiet months, having paid before"),
        kpi("c_lost", "Lost", cur("collected_cases_lost_count"), INT, prior=CA("collected_cases_lost"), direction="lower", note="Paid two months running, then stopped"),
        kpi("c_three", "Three consecutive months", cur("collected_cases_consistent_3m_count"), INT, prior=CA("collected_cases_three_consecutive_months"), note="Paid this month and the two before"),
        box("c_chartbox"),
        # Count or Collections, each tab with its own y-axis title and number format (the manager's review, 2026-10-09).
        # Balance is not in the cases mart, so it has no tab.
        {"id": "c_tabs", "kind": "tabbed-container", "tabs": [{"name": "Count"}, {"name": "Collections"}, {"name": "Average Collection per Case"}]},
        case_bars("c_chart", "case_count", "Count over months", INT, "Cases", [col("t_feed", case_feed_txt, "Feed portfolios")]),
        case_bars("c_money", "case_amount", "Collections over months", EUR_M2, "Collections (€)", [], millions=True),
        # Avg Collection per Case by the same behaviours (the user, 2026-10-13).
        case_avg_bars("c_avg", "Average collection per case over months"),
        # The behaviour key table is gone (the manager's review): each tile's (i) note defines its behaviour.
        kpi("c_book", "Cases on book", f'Sum({c("cases_on_book_count")})', INT, note="Every case with a feed"),
        kpi("c_everc", "Cases ever collected", f'Sum({c("cases_ever_collected_count")})', INT, note="Have paid at least once"),
        kpi("c_ever", "Cases ever collected, % of book", f'Sum({c("cases_ever_collected_count")}) / Sum({c("cases_on_book_count")})', PCT, note="Read at the last month of the window"),
    ]
    EVER = (f'Sum(If({c("reporting_month")} = {c("data_as_of_month")}, {c("cases_ever_collected_count")}, 0)) / '
            f'Sum(If({c("reporting_month")} = {c("data_as_of_month")}, {c("cases_on_book_count")}, 0))')
    # "Collections from collected cases" is just "Collections" (the manager's review): only paying cases pay.
    C_METRICS = {"Collected cases": f'Sum({c("collected_cases_count")})', "Collections": f'Sum({c("collected_cases_amount_sum")})',
                 "Fresh": f'Sum({c("collected_cases_new_count")}) - Sum({c("collected_cases_first_collection_count")})', "Lost": f'Sum({c("collected_cases_lost_count")})',
                 "Net change in collected cases": f'Sum({c("collected_cases_new_count")}) - Sum({c("collected_cases_lost_count")})',
                 "New": f'Sum({c("collected_cases_first_collection_count")})', "Three consecutive months": f'Sum({c("collected_cases_consistent_3m_count")})',
                 "Cases ever collected, % of book": EVER}
    CPC = perf_cur
    CPA = lambda prefix: perf_avg("C-Perf-Window", prefix, "months_in_case_l{n}m_window")   # months with a case feed
    CPS = lambda prefix: perf_sum("C-Perf-Window", prefix, "months_in_case_l{n}m_window")
    C_PERF = [   # §1's eight behaviour cards, in the layout's order; the Overall Summary stocks stay out
        ("Collected cases", CPC("collected_cases_count"), CPA("collected_cases"), "pct", False),
        # Of the cases on book, how many paid (the user, 2026-10-14): a rate, so its change is in points, and the window
        # is its totals' ratio, never an average of monthly rates.
        ("Collected cases, % of book", f'{CPC("collected_cases_count")} / {CPC("cases_on_book_count")}',
         f'{CPS("collected_cases")} / {CPS("cases_on_book")}', "pts", False),
        ("Collections", CPC("collected_cases_amount_sum"), CPA("collected_cases_amount"), "pct", False),
        ("Three consecutive months", CPC("collected_cases_consistent_3m_count"), CPA("collected_cases_three_consecutive_months"), "pct", False),
        ("Avg Monthly Collection per Case", f'{CPC("collected_cases_amount_sum")} / {CPC("collected_cases_count")}',
         f'{CPS("collected_cases_amount")} / {CPS("collected_cases")}', "pct", False),
        ("New", CPC("collected_cases_first_collection_count"), CPA("collected_cases_first_collection"), "pct", False),
        ("Fresh", f'{CPC("collected_cases_new_count")} - {CPC("collected_cases_first_collection_count")}',
         f'{CPA("collected_cases_new")} - {CPA("collected_cases_first_collection")}', "pct", False),
        ("Lost", CPC("collected_cases_lost_count"), CPA("collected_cases_lost"), "pct", True),
        ("Net change in collected cases", f'{CPC("collected_cases_new_count")} - {CPC("collected_cases_lost_count")}',
         f'{CPA("collected_cases_new")} - {CPA("collected_cases_lost")}', "cnt", False),   # signed: a difference, not a %
    ]
    C_FMT = {k: INT for k in C_METRICS}; C_FMT.update({"Collections": EUR_FULL, "Cases ever collected, % of book": PCT})
    C_FULL = dict(C_METRICS); C_FULL.update({"Avg Monthly Collection per Case": f'Sum({c("collected_cases_amount_sum")}) / Sum({c("collected_cases_count")})',
                                             # over the selected months: case-months paid / case-months on book (2026-10-14)
                                             "Collected cases, % of book": f'Sum({c("collected_cases_count")}) / Sum({c("cases_on_book_count")})'})
    C_FULL_FMT = dict(C_FMT, **{"Avg Monthly Collection per Case": EUR_FULL, "Collected cases, % of book": PCT})
    _k = list(C_FULL); _k.remove("Collected cases, % of book"); _k.insert(_k.index("Collected cases") + 1, "Collected cases, % of book")
    C_FULL = {k: C_FULL[k] for k in _k}   # beside Collected cases, as in §2
    els += [
        box("c_perfhead"),
        text("c_s2", "## ** 2  ·  Performance**"),
        text("c_perfdesc", "Every behaviour card above, by group: the latest reporting month and its change against the Comparison Window. Click any column to sort."),
        seg("c_pgrain", "C-Perf-Grain", "Group by", PG, "Country"),
        seg("c_pwin", "C-Perf-Window", "Comparison window (average monthly)", CMP_WINDOWS, "Last 3 months", CMP_LABELS),
        *perf_tables("bc", "C-Perf-Grain", C_PERF, [INT, PCT, EUR_FULL, INT, EUR_FULL, INT, INT, INT, INT]),
        box("c_fullhead"),
        text("c_s3", "## ** 3  ·  Full breakdown**"),
        text("c_fulldesc", "One row per portfolio over the selected months. Portfolios without a case feed show blank. Click any column to sort."),
        *full_tables("bc", C_FULL, C_FULL_FMT),
    ]

    # ---- Data Quality page (the manager's review, 2026-10-09): reconciliation and data status moved off Portfolio
    # and Cases. How much of the collections is confirmed by a second source (the case feed), and where it is not.
    DQ, DQP = dq_figures("cur"), dq_figures("prev")
    def dq_card(el: dict) -> dict:   # a tile in a white pill box, as the Portfolio tiles
        el["style"] = {"backgroundColor": "#FFFFFF", "borderWidth": 0}
        el["name"] = {"text": el["name"] if isinstance(el["name"], str) else el["name"]["text"], "fontSize": 14, "fontWeight": "bold", "color": "#012E26"}
        return el
    loading = "Max([Portfolios/loading_month])"
    els += [
        box("d_head"),
        text("d_s1", "## **Data Quality**"),
        text("d_desc", "How much of the collections on the Portfolio page is confirmed by a second source (the case feed), and where it is not."),
        seg("d_window", "D-Window", "Window", WINDOWS, "This month", WINDOW_LABELS),
        text("d_cmp", data_line()),
        # The standalone Servicer Data Quality dashboard (the user, 2026-10-14): same reconciliation rule, so its figures
        # tally with this page (work/data-quality/tests/run.py checks every portfolio-month).
        text("d_link", "For a more detailed breakdown by servicer and combined ref, see the "
                       "[Servicer Data Quality dashboard](https://app.sigmacomputing.com/brocc/workbook/4BLpoS2CGnEgQ0m7SeHolH). It uses the same reconciliation rule, so its reconciled figures match this page."),
        dq_card(kpi("d_recshare", "Share reconciled", DQ["share"], PCT, timeline=False, prior=DQP["share"],
                    note="Share of collections where the case feed agrees with the servicer report")),
        dq_card(kpi("d_notrec", "Not reconciled", M(DQ["not_rec"]), EUR_M2, timeline=False,
                    note="Collections whose case feed does not agree with the servicer report, or that have no case feed")),
        dq_card(kpi("d_nofeed", "No case feed", DQ["nofeed"], INT, timeline=False,
                    note="Portfolios reporting collections with no case feed: their collections cannot be reconciled")),
        dq_card(kpi("d_stopped", "Feeds stopped", DQ["stopped"], INT, timeline=False,
                    note="Portfolios whose case feed has gone quiet: their case figures read low")),
        # A month that has started arriving but is held back: text, so 'None' can be said in words.
        text("d_loading", '**Month Still Loading**\n\n<span style="font-size: 22px">**{{If(IsNull(' + loading + '), "None", DateFormat(' + loading + ', "%b %Y"))}}**</span>\n\n'
                          '<span style="color: #5C6B66; font-size: 12px">{{If(IsNull(' + loading + '), "No later month has started arriving", '
                          'Text(Max([Portfolios/loading_month_portfolio_count])) & " of " & Text(Max([Portfolios/data_as_of_portfolio_count])) & " portfolios reported; held back until complete")}}</span>'),
        # By Servicer and By Portfolio read grouped helpers on the hidden Model page, as §2 does.
        {"id": "bd_srv_src", "kind": "table", "name": "bd by servicer", "source": SRC,
         "columns": [col("grain", c("servicer_group"), "Servicer"), col("ports", DQ["ports"], "Portfolios", INT), col("feed", DQ["feed"], "With a case feed", INT),
                     col("recp", DQ["rec_ports"], "Reconciled", INT), col("share", DQ["share"], "Share of collections reconciled", PCT),
                     col("notrec", DQ["not_rec"], "Collections not reconciled", EUR_FULL)],
         "groupings": [{"id": "g", "groupBy": ["grain"], "calculations": ["ports", "feed", "recp", "share", "notrec"]}]},
        {"id": "d_srv", "kind": "table", "name": "By servicer", "style": CARD, "description": "Who to chase: largest amount not reconciled first",
         "source": {"kind": "table", "elementId": "bd_srv_src", "groupingId": "g"},
         "columns": [col(f"v{i}", f"[bd by servicer/{n}]", n, f) for i, (n, f) in enumerate(
             [("Servicer", None), ("Portfolios", INT), ("With a case feed", INT), ("Reconciled", INT), ("Share of collections reconciled", PCT), ("Collections not reconciled", EUR_FULL)])],
         "sort": [{"columnId": "v5", "direction": "descending", "nulls": "last"}],
         # A servicer with no portfolio in the window has nothing to show, and its blanks read "null" (Massey, Sep 2026).
         "filters": [{"id": "f_d_srv_ports", "columnId": "v1", "kind": "number-range", "min": 1, "includeNulls": "never"}],
         "tableStyle": WRAP, "conditionalFormats": [hide_nulls(["v1", "v2", "v3", "v4", "v5"])]},
        {"id": "bd_port_src", "kind": "table", "name": "bd by portfolio", "source": SRC,
         "columns": [col(f"d{i}", c(src), n) for i, (n, src) in enumerate(
             [("Country", "country_name"), ("Servicer", "servicer_group"), ("Seller", "seller"), ("Deal", "deal"), ("Portfolio", "portfolio_name")])]
                    + [col("notrec", DQ["not_rec"], "Collections not reconciled", EUR_FULL), col("share", DQ["share"], "Share of collections reconciled", PCT),
                       col("status", dq_status(), "Data status")],
         "groupings": [{"id": "g", "groupBy": [f"d{i}" for i in range(5)], "calculations": ["notrec", "share", "status"]}]},
        {"id": "d_port", "kind": "table", "name": "By portfolio", "style": CARD, "description": "Largest amount not reconciled first · Data status says why a figure may read low",
         "source": {"kind": "table", "elementId": "bd_port_src", "groupingId": "g"},
         "columns": [col(f"v{i}", f"[bd by portfolio/{n}]", n, f) for i, (n, f) in enumerate(
             [("Country", None), ("Servicer", None), ("Seller", None), ("Deal", None), ("Portfolio", None),
              ("Collections not reconciled", EUR_FULL), ("Share of collections reconciled", PCT), ("Data status", None)])],
         "sort": [{"columnId": "v5", "direction": "descending", "nulls": "last"}], "tableStyle": WRAP,
         "conditionalFormats": [hide_nulls(["v5", "v6"])]},
    ]

    # ---- Data & Definitions page ---------------------------------------------
    els += [
        box("d_where_box"), box("d_rules_box"),
        text("d_where", "### Where every figure comes from\n\n**Collections** — the servicer's monthly portfolio report, in euro at each month's rate.\n\n"
                        "**Cases** — the loan-level case feed, through the dbt mart MART\\_NPL\\_SERVICING\\_AGG\\_CASES\\_MONTHLY. Only Intrum and Massey portfolios send one.\n\n"
                        "**Forecasts** — the servicer's, accounting's and underwriting's. They disagree, so the benchmark is always named."),
        text("d_rules", "### Five rules for reading this dashboard\n\n1. Collections and case behaviour come from different feeds. Never put them on one card.\n"
                        "2. Never average a ratio. Sum the top and the bottom, then divide.\n3. Compare with the servicer forecast like-for-like.\n"
                        "4. Case counts are a floor. A blank means no feed, never \"nobody paid\".\n"
                        "5. The book (on book, ever, never collected) is a stock: read it at one month, never summed."),
        {"id": "d_table", "kind": "table", "name": "Data definitions", "source": DEF_SRC, "style": CARD,
         "columns": [col(k, f"[Data definitions/{l}]", l) for k, l in
                     [("t", "Term"), ("pg", "Page"), ("gr", "Group"), ("mn", "Meaning"), ("fm", "Formula"), ("ci", "Computed in"), ("wo", "Watch out")]]},
    ]

    layout = """<?xml version="1.0" encoding="utf-8"?>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg_portfolio">
  <Container elementId="bp_band" type="grid" gridColumn="1 / 25" gridRow="1 / 8" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="bp_sub" gridColumn="1 / 25" gridRow="1 / 2"/>
    <Element elementId="bp_asof" gridColumn="1 / 7" gridRow="2 / 7"/>
    <Element elementId="bp_ports" gridColumn="7 / 13" gridRow="2 / 7"/>
    <Element elementId="bp_feed" gridColumn="13 / 19" gridRow="2 / 7"/>
    <Element elementId="bp_rec" gridColumn="19 / 25" gridRow="2 / 7"/>
  </Container>
  <Container elementId="p_head" type="grid" gridColumn="1 / 25" gridRow="9 / 15" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_s1" gridColumn="1 / 8" gridRow="1 / 3"/>
    <Element elementId="p_bench" gridColumn="1 / 8" gridRow="3 / 5"/>
    <Element elementId="p_window" gridColumn="8 / 15" gridRow="3 / 5"/>
    <Element elementId="p_cmp" gridColumn="1 / 19" gridRow="5 / 7"/>
  </Container>
  <Container elementId="p_coll_box" type="grid" gridColumn="1 / 9" gridRow="15 / 21" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_coll" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="p_fc_box" type="grid" gridColumn="9 / 17" gridRow="15 / 21" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_fc" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="p_vs_box" type="grid" gridColumn="17 / 25" gridRow="15 / 21" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_vs" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="p_gap_box" type="grid" gridColumn="1 / 9" gridRow="21 / 27" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_gap" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="p_net_box" type="grid" gridColumn="9 / 17" gridRow="21 / 27" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_net" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="p_cost_box" type="grid" gridColumn="17 / 25" gridRow="21 / 27" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_cost" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="p_chartbox" type="grid" gridColumn="1 / 25" gridRow="28 / 46" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_view" gridColumn="1 / 9" gridRow="1 / 3"/>
    <Element elementId="p_chart" gridColumn="1 / 25" gridRow="3 / 19"/>
  </Container>
  <Container elementId="p_perfhead" type="grid" gridColumn="1 / 25" gridRow="47 / 54" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_s2" gridColumn="1 / 11" gridRow="1 / 3"/>
    <Element elementId="C9DdaMOFr_" gridColumn="1 / 19" gridRow="3 / 5"/>
    <Element elementId="p_pgrain" gridColumn="1 / 11" gridRow="5 / 8"/>
    <Element elementId="p_pwin" gridColumn="11 / 18" gridRow="5 / 8"/>
    <Element elementId="p_pbench" gridColumn="18 / 25" gridRow="5 / 8"/>
  </Container>
  <Element elementId="bp_perf" gridColumn="1 / 25" gridRow="54 / 72"/>
  <Container elementId="p_fullhead" type="grid" gridColumn="1 / 25" gridRow="73 / 77" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="p_s3" gridColumn="1 / 11" gridRow="1 / 3"/>
    <Element elementId="p_fulldesc" gridColumn="1 / 19" gridRow="3 / 5"/>
  </Container>
  <Element elementId="bp_full" gridColumn="1 / 25" gridRow="77 / 103"/>
</Page>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg_cases">
  <Container elementId="bc_band" type="grid" gridColumn="1 / 25" gridRow="1 / 8" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="bc_sub" gridColumn="1 / 25" gridRow="1 / 2"/>
    <Element elementId="bc_asof" gridColumn="1 / 7" gridRow="2 / 7"/>
    <Element elementId="bc_ports" gridColumn="7 / 13" gridRow="2 / 7"/>
    <Element elementId="bc_feed" gridColumn="13 / 19" gridRow="2 / 7"/>
    <Element elementId="bc_rec" gridColumn="19 / 25" gridRow="2 / 7"/>
  </Container>
  <Container elementId="c_head" type="grid" gridColumn="1 / 25" gridRow="9 / 17" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="c_s1" gridColumn="1 / 14" gridRow="1 / 3"/>
    <Element elementId="c_note" gridColumn="1 / 25" gridRow="3 / 5"/>
    <Element elementId="c_window" gridColumn="1 / 8" gridRow="5 / 7"/>
  </Container>
  <Container elementId="c_bar_overall" type="grid" gridColumn="1 / 25" gridRow="17 / 18" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="MxSGmmb_TV" gridColumn="1 / 25" gridRow="1 / 2"/>
  </Container>
  <Container elementId="c_book_box" type="grid" gridColumn="1 / 7" gridRow="18 / 24" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="c_book" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="c_everc_box" type="grid" gridColumn="7 / 13" gridRow="18 / 24" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="c_everc" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="c_ever_box" type="grid" gridColumn="13 / 19" gridRow="18 / 24" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="c_ever" gridColumn="1 / 25" gridRow="1 / 7"/>
  </Container>
  <Container elementId="c_bar_behaviour" type="grid" gridColumn="1 / 25" gridRow="24 / 25" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="nSopK5b7To" gridColumn="1 / 25" gridRow="1 / 2"/>
  </Container>
  <Container elementId="c_beh_counts" type="grid" gridColumn="1 / 25" gridRow="25 / 31" gridTemplateColumns="repeat(4, 1fr)" gridTemplateRows="auto">
    <Element elementId="c_cc" gridColumn="1 / 2" gridRow="1 / 7"/>
    <Element elementId="c_first" gridColumn="2 / 3" gridRow="1 / 7"/>
    <Element elementId="c_new" gridColumn="3 / 4" gridRow="1 / 7"/>
    <Element elementId="c_lost" gridColumn="4 / 5" gridRow="1 / 7"/>
  </Container>
  <Container elementId="c_beh_money" type="grid" gridColumn="1 / 25" gridRow="31 / 37" gridTemplateColumns="repeat(4, 1fr)" gridTemplateRows="auto">
    <Element elementId="c_three" gridColumn="1 / 2" gridRow="1 / 7"/>
    <Element elementId="c_ce" gridColumn="2 / 3" gridRow="1 / 7"/>
    <Element elementId="c_cpe" gridColumn="3 / 4" gridRow="1 / 7"/>
    <Element elementId="c_nl" gridColumn="4 / 5" gridRow="1 / 7"/>
  </Container>
  <Container elementId="c_chartbox" type="grid" gridColumn="1 / 25" gridRow="37 / 53" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <TabbedContainer elementId="c_tabs" type="tabbed-container" gridColumn="1 / 25" gridRow="1 / 17">
      <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
        <Element elementId="c_chart" gridColumn="1 / 25" gridRow="1 / 18"/>
      </Tab>
      <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
        <Element elementId="c_money" gridColumn="1 / 25" gridRow="1 / 18"/>
      </Tab>
      <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
        <Element elementId="c_avg" gridColumn="1 / 25" gridRow="1 / 18"/>
      </Tab>
    </TabbedContainer>
  </Container>
  <Container elementId="c_perfhead" type="grid" gridColumn="1 / 25" gridRow="54 / 61" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="c_s2" gridColumn="1 / 11" gridRow="1 / 3"/>
    <Element elementId="c_perfdesc" gridColumn="1 / 19" gridRow="3 / 5"/>
    <Element elementId="c_pgrain" gridColumn="1 / 11" gridRow="5 / 8"/>
    <Element elementId="c_pwin" gridColumn="11 / 18" gridRow="5 / 8"/>
  </Container>
  <Element elementId="bc_perf" gridColumn="1 / 25" gridRow="61 / 79"/>
  <Container elementId="c_fullhead" type="grid" gridColumn="1 / 25" gridRow="80 / 84" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="c_s3" gridColumn="1 / 11" gridRow="1 / 3"/>
    <Element elementId="c_fulldesc" gridColumn="1 / 19" gridRow="3 / 5"/>
  </Container>
  <Element elementId="bc_full" gridColumn="1 / 25" gridRow="84 / 110"/>
</Page>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg_data">
  <Container elementId="bd_band" type="grid" gridColumn="1 / 25" gridRow="1 / 8" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="bd_sub" gridColumn="1 / 25" gridRow="1 / 2"/>
    <Element elementId="bd_asof" gridColumn="1 / 7" gridRow="2 / 7"/>
    <Element elementId="bd_ports" gridColumn="7 / 13" gridRow="2 / 7"/>
    <Element elementId="bd_feed" gridColumn="13 / 19" gridRow="2 / 7"/>
    <Element elementId="bd_rec" gridColumn="19 / 25" gridRow="2 / 7"/>
  </Container>
  <Container elementId="d_head" type="grid" gridColumn="1 / 25" gridRow="9 / 19" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="d_s1" gridColumn="1 / 14" gridRow="1 / 3"/>
    <Element elementId="d_desc" gridColumn="1 / 25" gridRow="3 / 5"/>
    <Element elementId="d_window" gridColumn="1 / 8" gridRow="5 / 7"/>
    <Element elementId="d_cmp" gridColumn="1 / 25" gridRow="7 / 9"/>
    <Element elementId="d_link" gridColumn="1 / 25" gridRow="9 / 11"/>
  </Container>
  <Container elementId="d_cards" type="grid" gridColumn="1 / 25" gridRow="19 / 25" gridTemplateColumns="repeat(5, 1fr)" gridTemplateRows="auto">
    <Container elementId="d_recshare_box" type="grid" gridColumn="1 / 2" gridRow="1 / 7" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="d_recshare" gridColumn="1 / 25" gridRow="1 / 7"/>
    </Container>
    <Container elementId="d_notrec_box" type="grid" gridColumn="2 / 3" gridRow="1 / 7" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="d_notrec" gridColumn="1 / 25" gridRow="1 / 7"/>
    </Container>
    <Container elementId="d_nofeed_box" type="grid" gridColumn="3 / 4" gridRow="1 / 7" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="d_nofeed" gridColumn="1 / 25" gridRow="1 / 7"/>
    </Container>
    <Container elementId="d_stopped_box" type="grid" gridColumn="4 / 5" gridRow="1 / 7" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="d_stopped" gridColumn="1 / 25" gridRow="1 / 7"/>
    </Container>
    <Container elementId="d_loading_box" type="grid" gridColumn="5 / 6" gridRow="1 / 7" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="d_loading" gridColumn="1 / 25" gridRow="1 / 7"/>
    </Container>
  </Container>
  <Element elementId="d_srv" gridColumn="1 / 25" gridRow="26 / 40"/>
  <Element elementId="d_port" gridColumn="1 / 25" gridRow="41 / 67"/>
</Page>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg_defs">
  <Container elementId="d_where_box" type="grid" gridColumn="1 / 13" gridRow="1 / 11" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="d_where" gridColumn="1 / 25" gridRow="1 / 10"/>
  </Container>
  <Container elementId="d_rules_box" type="grid" gridColumn="13 / 25" gridRow="1 / 11" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="d_rules" gridColumn="1 / 25" gridRow="1 / 10"/>
  </Container>
  <Element elementId="d_table" gridColumn="1 / 25" gridRow="12 / 42"/>
  <Element elementId="src" gridColumn="1 / 25" gridRow="43 / 59"/>
</Page>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg_model">
  <Element elementId="bp_perf_src" gridColumn="1 / 25" gridRow="1 / 12"/>
  <Element elementId="bp_full_src" gridColumn="1 / 25" gridRow="12 / 24"/>
  <Element elementId="bc_perf_src" gridColumn="1 / 25" gridRow="24 / 36"/>
  <Element elementId="bc_full_src" gridColumn="1 / 25" gridRow="36 / 48"/>
  <Element elementId="bd_srv_src" gridColumn="1 / 25" gridRow="48 / 56"/>
  <Element elementId="bd_port_src" gridColumn="1 / 25" gridRow="56 / 68"/>
  <Element elementId="src_defs" gridColumn="1 / 25" gridRow="68 / 76"/>
  <Element elementId="fc_src" gridColumn="1 / 25" gridRow="76 / 88"/>
  <Element elementId="cb_src" gridColumn="1 / 25" gridRow="88 / 100"/>
</Page>
<Panel type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="hdr">
  <Element elementId="h_title" gridColumn="1 / 25" gridRow="1 / 4"/>
  <Element elementId="f_month" gridColumn="1 / 4" gridRow="4 / 7"/>
  <Element elementId="f_country" gridColumn="4 / 7" gridRow="4 / 7"/>
  <Element elementId="f_servicer" gridColumn="7 / 10" gridRow="4 / 7"/>
  <Element elementId="f_seller" gridColumn="10 / 13" gridRow="4 / 7"/>
  <Element elementId="f_deal" gridColumn="13 / 16" gridRow="4 / 7"/>
  <Element elementId="f_portfolio" gridColumn="16 / 19" gridRow="4 / 7"/>
  <Element elementId="f_rec" gridColumn="19 / 22" gridRow="4 / 7"/>
  <Element elementId="h_clear" gridColumn="22 / 25" gridRow="4 / 7"/>
</Panel>"""
    agent_text = AGENT.read_text().split("```text", 1)[1].split("```", 1)[0].strip().replace("@dataSource(\"ROIia0oTOr\")", "@dataSource(\"src\")")
    contents = {
        "schemaVersion": 1, "kind": "workbook",
        "settings": {"theme": theme, "navigation": {"pageHeader": "enabled"}},
        # The artifact's look: grey page ground, a centred 1360px page (the side margins), white cards on it.
        "pages": [{"id": pid, "name": name, "backgroundColor": "#FFFFFF", "pageWidth": {"mode": "custom", "maxWidth": 1360}}
                  for pid, name in (("pg_portfolio", "Portfolio"), ("pg_cases", "Cases"), ("pg_data", "Data Quality"), ("pg_defs", "Data & Definitions"))]
                 + [{"id": "pg_model", "name": "Model", "visibility": "hidden"}],   # helper tables, hidden from viewers
        "panels": [{"id": "hdr", "type": "header", "title": "Servicing header", "pages": ["pg_portfolio", "pg_cases", "pg_data", "pg_defs"],
                    # Sticky: the title, Clear Filters and the seven filters stay on screen as the page scrolls (the user,
                    # 2026-10-11). The shadow separates it from the page beneath; Sigma draws it only when sticky.
                    "config": {"backgroundColor": "#FFFFFF", "scroll": "sticky", "borderStyle": "shadow"}}],
        "elements": els,
        "agents": [{"id": "servicing_analyst", "name": "Servicing analyst",
                    "description": "Answers what a figure means, where it comes from, and whether it is solid.",
                    "instructions": agent_text, "dataSources": [{"kind": "table", "elementId": "src"}]}],
        "layout": layout,
    }
    ids = {e["id"]: e.get("name", e["kind"]) for e in els}
    return contents, ids


MINOR = {"a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "of", "on", "or", "over", "per", "the", "to", "vs", "with"}


def title_case(s: str) -> str:
    """'Collections as % of forecast' -> 'Collections as % of Forecast'. Minor words stay lower unless first or
    last (Jitter In, Rank By); codes and symbols (L3M, €, %) are left alone. A {{formula}} is left exactly as
    written: its quoted values must match the control's ("This month"), so only the words around it change."""
    if "{{" in s:
        return "".join(part if part.startswith("{{") else title_case(part) for part in re.split(r"(\{\{.*?\}\})", s) if part)
    toks = re.split(r"(\s+)", s)
    words = [i for i, t in enumerate(toks) if t.strip()]
    out, first = [], True
    for i, tok in enumerate(toks):
        if not tok.strip():
            out.append(tok); continue
        lead = re.match(r"^[(\[\"'·]*", tok).group()
        word, tail = re.match(r"^(.*?)([),.:;\]\"']*)$", tok[len(lead):]).groups()
        last = i == words[-1] or bool(tail.strip(",.;"))   # last word, or closes a bracket
        if word and word[0].isalpha():
            parts = word.split("-")
            ends = (0, len(parts) - 1)
            def cap(j, w):
                if w != w.lower():          # already has capitals (L3M, Intrum): leave it
                    return w
                keep_lower = w in MINOR and not (j == 0 and (first or lead)) and not (j == ends[1] and last) \
                    and not (len(parts) > 1 and j in ends)   # Like-for-Like: a compound's ends are capitalised
                return w if keep_lower else w[:1].upper() + w[1:]
            word = "-".join(cap(j, w) for j, w in enumerate(parts))
        out.append(lead + word + tail)
        first = word in ("·", "-", "—") or tail.endswith(":")
    return "".join(out)


def anchor_book(contents: dict) -> None:
    """Cases on book, ever and never collected are stocks: one month-end, never summed over months. They follow the
    Cases Window by reading the window's last month: the selected month for This month, the month before for the rest
    (every other window ends there). GrandTotal(Max(...)) is the latest month in view, so the Reporting month filter still applies."""
    end = 'DateTrunc("month", GrandTotal(Max([Portfolios/reporting_month])))'   # the latest reporting month (2026-10-12)
    at = lambda col: f'Sum(If(DateTrunc("month", [Portfolios/reporting_month]) = {end}, [Portfolios/{col}]))'
    vals = {"c_book": at("cases_on_book_count"), "c_everc": at("cases_ever_collected_count"),
            "c_ever": f'{at("cases_ever_collected_count")} / {at("cases_on_book_count")}'}
    for e in contents["elements"]:
        if e["id"] in vals:
            v = next(x for x in e["columns"] if x["id"] == "v")
            v["formula"] = vals[e["id"]]
            # Title and number only (the user, 2026-10-09): no timeline date, no note.
            e["columns"] = [x for x in e["columns"] if x["id"] != "m"]
            e.pop("timeline", None); e.pop("trend", None); e.pop("description", None)
            e["style"] = {"backgroundColor": "#FFFFFF", "borderWidth": 0}
            e["name"] = {"text": e["name"] if isinstance(e["name"], str) else e["name"]["text"], "fontSize": 14, "fontWeight": "bold", "color": "#012E26"}
            contents["elements"].append(dict(box(f'{e["id"]}_box'), spacing="small", style=dict(CARD_BOX, borderRadius="pill")))


# The user's coloured section bars on Cases (set in the Sigma editor, 2026-10-09). A text element takes no background
# through the API, so the colour lives on a container around it; without this a rebuild would drop the colours.
# The Cases behaviour cards: the user's order (Sigma, v32), at equal widths, 6 of 24 columns, each in its own box
# (2026-10-12). At 5 columns Sigma dropped the decimal from a card's % ("42%" for 42.46%); the rule is one decimal.
# The behaviour cards share two boxes (the user, 2026-10-13), four equal cards each, in the user's order: Collected
# Cases, New, Fresh, Lost; Three Consecutive Months, Collections, Avg Monthly Collection per Case, Net Change. Five
# across (5/3) cut titles to "..." and dropped the %'s decimal: a card needs a quarter of the page (rendered 2026-10-13).
C_SHARED = {"c_beh_counts": ["c_cc", "c_first", "c_new", "c_lost"], "c_beh_money": ["c_three", "c_ce", "c_cpe", "c_nl"]}
USER_REMOVED_BOXES: set = {t for ts in C_SHARED.values() for t in ts}
SECTION_BARS = {"c_bar_overall": "#C7D2D0", "c_bar_behaviour": "#DEE4E3"}   # the user set these in Sigma (2026-10-12)


def wrap_tiles(contents: dict) -> None:
    """Each compared tile sits in a white pill-cornered box; the Cases section bars get their colours."""
    for cid in C_SHARED:
        contents["elements"].append(box(cid))
    # Five equal Data Quality cards (2026-10-14): a bare grid of five, each card its own box inside it.
    contents["elements"].append({"id": "d_cards", "kind": "container", "spacing": "small"})
    for cid, colour in SECTION_BARS.items():
        contents["elements"].append({"id": cid, "kind": "container", "spacing": "small",
                                     "style": {"backgroundColor": colour, "borderRadius": "round"}})
    for eid in list(TILE_KIND) + ["d_loading"]:
        # The user removed the per-tile window line (2026-10-09): the one "The Tiles compare" line above them says it.
        if eid in USER_REMOVED_BOXES:
            continue
        contents["elements"] += [dict(box(f"{eid}_box"), spacing="small", style=dict(CARD_BOX, borderRadius="pill"))]
    # Pill corners on the band's status tiles and the Overview headers too, as the user set Portfolio.
    pill = {f"{pg}_{t}" for pg in ("bp", "bc", "bd") for t in ("asof", "ports", "feed", "rec")} | {"p_head", "c_head", "d_head"}
    for e in contents["elements"]:
        if e["id"] in pill:
            e["style"] = dict(e.get("style") or CARD_BOX, borderRadius="pill")


USER_EDITS = HERE / "user_edits.json"


def apply_user_edits(contents: dict) -> None:
    """The user's hand edits in Sigma (user_edits.json), applied last so a rebuild never undoes them."""
    if not USER_EDITS.exists():
        return
    edits = json.loads(USER_EDITS.read_text())
    by_id = {e["id"]: e for e in contents["elements"]}
    for eid, fields in edits.get("elements", {}).items():
        for path, value in fields.items():
            node, *rest = path.split(".")
            target = by_id[eid]
            for k in [node] + rest[:-1] if rest else []:
                target = target.setdefault(k, {})
            target[rest[-1] if rest else node] = value
    contents["elements"] += [e for e in edits.get("extra_elements", []) if e["id"] not in by_id]


def titleize(contents: dict) -> None:
    """Every title a viewer reads is in Title Case: element titles, column headers, control labels, headings.
    Values stay as they are (statuses, toggle options), and so do the hidden helper tables' columns,
    because the visible tables address them by name."""
    hidden = {m for m in re.findall(r'elementId="([^"]+)"', contents["layout"].split('id="pg_model"', 1)[1].split("</Page>", 1)[0])} \
        if 'id="pg_model"' in contents["layout"] else set()
    hidden |= {"src", "src_defs"}   # children address these by name: [Portfolios/...]
    for e in contents["elements"]:
        if e["id"] in hidden:
            continue
        if e.get("name") and isinstance(e["name"], str):
            e["name"] = title_case(e["name"])
        elif isinstance(e.get("name"), dict) and e["name"].get("text"):
            e["name"]["text"] = title_case(e["name"]["text"])
        if e["kind"] == "kpi-chart" and isinstance(e.get("description"), dict) and e["description"].get("text"):
            e["description"]["text"] = title_case(e["description"]["text"])
        for col in e.get("columns", []):
            if col.get("name"):
                col["name"] = title_case(col["name"])
        if e["kind"] == "text":
            body = e["body"].split("\n")
            for i, line in enumerate(body):
                if line.startswith("#"):
                    body[i] = re.sub(r"^(#+ )(.*)$", lambda m: m.group(1) + "**" + title_case(m.group(2).strip("* ")) + "**", line)   # no space inside ** or Markdown prints the stars
                elif line.startswith("| ") and not line.startswith("|---"):
                    cells = line.split("|")
                    head = i == 0 or body[i - 1] == ""
                    for j in range(1, len(cells) - 1):
                        if head or j == 1:
                            cells[j] = title_case(cells[j])
                    body[i] = "|".join(cells)
            e["body"] = "\n".join(body)


def strip_control_defaults(contents: dict) -> int:
    """The 43-row trap: a control with a filter and a `value` filters every tile on push. Drop the key."""
    n = 0
    for e in contents["elements"]:
        if e["kind"] == "control" and "filters" in e and "value" in e:
            del e["value"]; n += 1
    return n


def sigma(*args: str, body_file: pathlib.Path | None = None) -> dict:
    cmd = ["sigma", "-p", "brocc", "api", *args] + (["--body", f"@{body_file}"] if body_file else [])
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        raise SystemExit(f"sigma {' '.join(args[:3])} failed:\n{out.stdout[:2000]}\n{out.stderr[:2000]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--dry-run", action="store_true")
    g.add_argument("--create", action="store_true")
    g.add_argument("--update")
    ap.add_argument("--name", default="Servicing Dashboard (rebuild)")
    ap.add_argument("--live", action="store_true", help="allow --update on the live workbook (executives see it at once)")
    args = ap.parse_args()

    contents, ids = build()
    wrap_tiles(contents)
    anchor_book(contents)
    titleize(contents)
    apply_user_edits(contents)
    strip_control_defaults(contents)
    (HERE / "contents.json").write_text(json.dumps(contents, indent=1))
    (HERE / "element_ids.json").write_text(json.dumps(ids, indent=1))
    print(f"{len(contents['elements'])} elements on {len(contents['pages'])} pages -> sigma_build/contents.json")
    # Pre-flight: Sigma's verify endpoint names the exact element and field at fault, where a
    # failed create only says "1 schema error". Nothing is created by this call.
    check = HERE / ".verify.json"
    check.write_text(json.dumps({"name": args.name, "folderId": FOLDER, "document": contents}))
    verdict = sigma("workbooks", "spec", "verify", body_file=check)
    check.unlink()
    if not verdict.get("valid", False):
        for e in verdict.get("errors", [])[:20]:
            print("  ✗", e.get("summary", e))
        raise SystemExit("verify failed - nothing was sent")
    print("verify: valid")
    if args.dry_run:
        return 0
    body = HERE / ".push.json"
    if args.create:
        body.write_text(json.dumps({"name": args.name, "folderId": FOLDER, "contents": contents}))
        res = sigma("workbooks", "create", body_file=body)
    else:
        if args.update == LIVE_WORKBOOK and not args.live:
            raise SystemExit("that is the live workbook: --create a copy, test it, swap names - or pass --live if you mean it")
        body.write_text(json.dumps({"contents": contents}))
        res = sigma("workbooks", "contents", "update", "--params", json.dumps({"workbookId": args.update}), body_file=body)
    body.unlink()
    if "workbookId" not in res:
        raise SystemExit(f"Sigma rejected the build:\n{json.dumps(res, indent=1)[:4000]}")
    (HERE / "workbook.json").write_text(json.dumps({k: res[k] for k in ("workbookId", "url", "name", "latestVersion")}, indent=1))
    print(f"{res['name']} · v{res['latestVersion']} · {res['url']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
