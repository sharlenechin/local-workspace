"""6 · Live dashboard - what the Sigma tiles actually show.

Suites 1-5 test the query. This one tests the workbook on top of it: each check
exports a tile from the built workbook and compares it to independent SQL. It
catches what SQL testing alone misses - a renamed column that renders 'Unknown
column' as text, a control default that filters the page (the 43-row trap), a
Sigma formula dividing the wrong way, a Switch arm that points at the wrong column.

Which workbook: sigma_build/workbook.json (written by build_workbook.py), so the
suite follows the build. Controls are at their defaults: §2 on both pages and Data Quality
'This month'; the overview Comparison Windows L1M on Portfolio and L3M on Cases (the user's
choice). The overview cards show the latest reporting month whatever that window. Benchmark 'Servicer'.
Skipped by --offline, and by --as-of (a live tile cannot be rewound).
"""
from __future__ import annotations

import json
import pathlib

import pandas as pd

import _lib
from _lib import Check, cap, tile, warehouse
from suites.s2_money import _fact
from suites.s3_forecasts import _forecast
from suites.s4_windows import COLL, _lfl_base, _reconciled_base
from suites.s5_cases import _mart, _mart_eur

SUITE = "live"
_BUILD = pathlib.Path(_lib.SERVICING / "sigma_build" / "workbook.json")
if _BUILD.exists():
    _lib.WORKBOOK = json.loads(_BUILD.read_text())["workbookId"]
# Exported in the background at the start of a run, so the checks cost almost nothing when reached.
# §2's columns, as exported (lower case): the artifact's metric lists, in order.
P_PERF_COLS = [x for n in ["total collections", "total forecast", "collections as % of forecast", "collections minus forecast",
                            "total net collections", "servicer cost, % of collections"] for x in (n, f"{n} vs window")]
C_PERF_COLS = [x for n in ["collected cases", "collected cases, % of book", "collections", "three consecutive months", "avg monthly collection per case",
                            "new", "fresh", "lost", "net change in collected cases"] for x in (n, f"{n} vs window")]
PREFETCH = ["p_vs", "p_gap", "p_coll", "c_cc", "c_ce", "c_cpe", "c_nl", "src", "p_fc", "p_chart", "bp_perf", "bp_full", "bc_perf", "bc_full", "c_book", "c_ever", "bp_ports", "d_table",
            "d_recshare", "d_notrec", "d_srv", "d_port", "bd_ports"]


def _latest(element: str, column: str) -> float:
    """A KPI exports one row per month; the card shows the last one (in euros, whatever the card's unit)."""
    return float(pd.to_numeric(tile(element)[column], errors="coerce").iloc[-1]) * (1e6 if element in _lib.MILLIONS else 1)


def _col(element: str, column: str, agg: str = "sum") -> float:
    v = pd.to_numeric(tile(element)[column], errors="coerce")
    return float(v.max() if agg == "max" else v.sum())


# ---- the Portfolio chart: collections and all three forecasts, 12 months ahead (2026-10-11) ----
FC_TABLES = {"servicer": "FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY",
             "accounting": "FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY",
             "underwriting": "FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY"}


def _chart(params: dict | None = None) -> pd.DataFrame:
    d = tile("p_chart", params=params).copy()
    for c in d.columns[1:]:
        d[c] = pd.to_numeric(d[c], errors="coerce")
        if not c.startswith("vs ") and "portfolios" not in c:   # the lines and their hover copies are in millions
            d[c] = d[c] * 1e6
    return d


def _ahead(params: dict | None = None) -> pd.DataFrame:
    """The forecast-only months: those after the selected month, where collections are blank."""
    d = _chart(params)
    return d[d["collections"].isna()]


def _ahead_forecast(kind: str, book_month: str | None = None, after: str | None = None) -> str:
    """Independent SQL for the chart's future months: the latest forecast for the portfolios that reported in
    book_month (default: the last complete month), for months after `after` (default: the last complete month)
    up to 12 months past book_month, each currency at its newest monthly rate."""
    book = book_month or cap()
    after = after or cap()
    d = _lib.dashboard()
    when = d["reporting_month"].max() if book_month is None else pd.Timestamp(book_month)
    books = d[pd.to_datetime(d["reporting_month"]) == pd.to_datetime(when)]["portfolio_name"].unique()
    inlist = ", ".join("'" + b.replace("'", "''") + "'" for b in books)
    book_sql = book if book_month is None else f"'{book_month}'::DATE"
    return f"""SELECT SUM(v.amount * IFF(v.currency_id = 'EUR', 1, fx.rate)) FROM (
        SELECT f.portfolio_sk, f.period_end_date, f.currency_id, f.gross_collection_forecast AS amount
        FROM PROD.NPL_COMMON.{FC_TABLES[kind]} AS f
        WHERE LAST_DAY(f.period_end_date) > {after} AND LAST_DAY(f.period_end_date) <= LAST_DAY(DATEADD(month, 12, {book_sql}))
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (PARTITION BY f.portfolio_sk, f.period_end_date)
      ) AS v
      INNER JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p ON p.portfolio_sk = v.portfolio_sk
      LEFT JOIN (SELECT quote_currency AS cid, ultimo_value AS rate FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
                 WHERE base_currency = 'EUR' AND rate_type = 'PMI'
                 QUALIFY date_day = MAX(date_day) OVER (PARTITION BY quote_currency)) AS fx ON fx.cid = v.currency_id
      WHERE p.portfolio_bk IN ({inlist})"""


def _signed(t) -> float | None:
    """'▲ +2.4%' -> 0.024, '▼ -7.7%' -> -0.077; blank -> None. Fails loudly on any other shape."""
    t = "" if pd.isna(t) else str(t).strip()
    if not t:
        return None
    arrow, num = t[0], float(t[1:].strip().rstrip("%")) / 100
    if (arrow == "▲") != (num >= 0) or arrow not in "▲▼":
        raise ValueError(f"hover figure {t!r} has the wrong arrow")
    return num


def _signed_mismatches(params: dict | None = None) -> int:
    """Accounting and underwriting hover figures, every reported month, against collections / forecast from the
    same export (the servicer one is like-for-like and has its own check). Within 0.05pp: the hover rounds to 0.1.
    Under View = Cumulative the export's lines are running totals, so this proves the % is to date too."""
    d, raw, bad = _chart(params), tile("p_chart", params=params), 0
    for kind in ("accounting", "underwriting"):
        for coll, fc, t in zip(d["collections"], d[f"{kind} forecast"], raw[f"vs {kind}"]):
            got = _signed(t)
            if pd.isna(coll):
                bad += got is not None
            else:
                bad += got is None or abs(got - (coll / fc - 1)) > 0.0005 + 1e-12
    return bad


def _reported(kind: str) -> float:
    d = _chart()
    return float(d.loc[d["collections"].notna(), f"{kind} forecast"].sum())


def _at_cap_window(base: str, n: int) -> str:
    """Book-level L n M average at the last complete month: window sums over the months that exist."""
    return f"""SELECT SUM(w) / MAX(c) FROM (
      SELECT period_end_date,
             SUM(v) OVER (PARTITION BY portfolio_sk ORDER BY DATEDIFF(MONTH, '1900-01-01', period_end_date)
                          RANGE BETWEEN {n} PRECEDING AND 1 PRECEDING) AS w,
             COUNT(v) OVER (PARTITION BY portfolio_sk ORDER BY DATEDIFF(MONTH, '1900-01-01', period_end_date)
                          RANGE BETWEEN {n} PRECEDING AND 1 PRECEDING) AS c
      FROM ({base}))
      WHERE period_end_date = {cap()}"""


def _at_cap_sum(base: str, n: int) -> str:
    """Book-level TOTAL over the n months before the last complete month."""
    return f"""SELECT SUM(w) FROM (
      SELECT period_end_date, SUM(v) OVER (PARTITION BY portfolio_sk ORDER BY DATEDIFF(MONTH, '1900-01-01', period_end_date)
                                           RANGE BETWEEN {n} PRECEDING AND 1 PRECEDING) AS w
      FROM ({base}))
      WHERE period_end_date = {cap()}"""


def _at_cap_month(base: str) -> str:
    """Book-level value in the last complete month itself: the 'This month' window."""
    return f"SELECT SUM(v) FROM ({base}) WHERE period_end_date = {cap()}"


# The mart as the dashboard can show it: only portfolio-months the servicer reported. A case feed can arrive before its
# portfolio report (Massey, Sep 2026), and the dashboard shows those cases once the report lands (2026-10-14).
MART = """(SELECT m.* FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS m
  WHERE EXISTS (SELECT 1 FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
                WHERE f.portfolio_sk = m.portfolio_sk AND f.period_end_date = m.period_end_date))"""
L3M = "{col} BETWEEN LAST_DAY(DATEADD(month, -3, {cap})) AND LAST_DAY(DATEADD(month, -1, {cap}))"


def _LATEST_PORTFOLIOS() -> str:
    """Like-for-like (2026-10-14): a card's comparison months count only portfolios that reported the latest month."""
    return f"SELECT DISTINCT portfolio_sk FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY WHERE period_end_date = {cap()}"


def _case_l3m(expr: str) -> str:
    """The Cases tiles at their default window (Last 3 months, set by the user): the average month of May-Jul for Aug."""
    w = L3M.format(col="period_end_date", cap=cap())
    return f"SELECT SUM({expr}) / COUNT(DISTINCT period_end_date) FROM {MART} WHERE {w} AND portfolio_sk IN ({_LATEST_PORTFOLIOS()})"


def _case_l3m_eur(column: str) -> str:
    w = L3M.format(col="k.period_end_date", cap=cap())
    return (_mart_eur(column).replace(f"SELECT SUM(m.{column} * fx.rate)", f"SELECT SUM(m.{column} * fx.rate) / COUNT(DISTINCT k.period_end_date)")
            + f" WHERE {w} AND k.portfolio_sk IN ({_LATEST_PORTFOLIOS()})")


def _book_at_window_end(column: str) -> str:
    """Book stocks read at the latest reporting month, whatever the Comparison Window (2026-10-12)."""
    return f"SELECT SUM({column}) FROM {MART} WHERE period_end_date = {cap()}"


def _case_latest(expr: str) -> str:
    """A Cases card's value: the latest reporting month, straight from the mart."""
    return f"SELECT SUM({expr}) FROM {MART} WHERE period_end_date = {cap()}"


def _case_latest_eur(column: str) -> str:
    return _mart_eur(column) + f" WHERE k.period_end_date = {cap()}"


def _seller_mismatches() -> float:
    """Full breakdown rows whose Seller is not the warehouse's (the deal on the facts, then DIM_DEAL)."""
    from suites.s9_controls import SELLER_MAP
    full = tile("bp_full")
    truth = _lib.datalake.q(f"""SELECT p.portfolio_bk AS portfolio, m.seller FROM ({SELLER_MAP}) AS m
        JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p ON p.portfolio_sk = m.portfolio_sk""", lower=True)
    truth = truth.drop_duplicates("portfolio").set_index("portfolio")["seller"]
    return float((full.set_index("portfolio")["seller"] != truth.reindex(full["portfolio"]).values).sum())


def _seller_filter_wired() -> float:
    """0 when the header has a Seller filter on SELLER and Clear Filters clears it."""
    els = {e["id"]: e for e in json.loads(_lib._sigma("workbooks", "spec", "get", "--params", json.dumps({"workbookId": _lib.WORKBOOK})))["document"]["elements"]}
    f = els.get("f_seller", {})
    cleared = {x["scope"].get("controlId") for a in els["h_clear"].get("actions", []) for x in a["effects"]}
    return float((f.get("source", {}).get("columnId") != "SELLER") + ("Seller" not in cleared))


def _servicer_monthly() -> str:
    from suites.s4_windows import _forecast_source, _monthly
    return _monthly("f.amount", _forecast_source("FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY"))


MINOR = {"a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "of", "on", "or", "per", "the", "to", "vs", "with"}
BANNED = ("sum of ", "count of ", "avg of ", "average of ", "min of ", "max of ", "countdistinct of ")


def _header_problems(header: str) -> int:
    """A header fails if Sigma's auto-aggregate prefix leaks ('Sum of ...') or a main word is not capitalised.
    Independent of the builder's title_case(): the rule is written out here."""
    if header.lower().startswith(BANNED):
        return 1
    tokens = header.replace("(", " ").replace(")", " ").replace(",", " ").split()   # '%' and '€' count as words
    return sum(1 for i, w in enumerate(tokens) if w[:1].isalpha() and w[0].islower() and (i == 0 or w.lower() not in MINOR))


def _definitions_rows() -> float:
    import csv
    return float(len(list(csv.DictReader((_lib.SERVICING / "docs" / "definitions.csv").open()))))


CHECKS = [
    Check(f"{SUITE}.no_default_filter", "The page is unfiltered: every portfolio-month reaches the tiles",
          actual=lambda: float(len(tile("src"))), expected=lambda: float(len(_lib.dashboard())), tol=0, live=True,
          proves="The Reconciliation control's default is not filtering the page (the 43-row trap). Sigma writes value:false back onto it; this proves it is harmless."),
    Check(f"{SUITE}.chart_collections", "Collections vs forecasts chart: collections line is every portfolio's collections",
          actual=lambda: float(_chart()["collections"].sum()), expected=lambda: warehouse(_fact("f.gross_cash_recoveries")), live=True,
          proves="The chart no longer follows the Benchmark toggle: collections are the whole book, not the servicer like-for-like subset."),
    Check(f"{SUITE}.chart_ahead_months", "Collections vs forecasts chart: forecast-only months after the latest month",
          actual=lambda: float(len(_ahead())), expected=lambda: 12.0, tol=0, live=True,
          proves="The forecasts run exactly 12 months past the latest complete month, and collections stop there."),
    Check(f"{SUITE}.chart_no_gaps", "Collections vs forecasts chart: every month has all three forecasts",
          actual=lambda: float(_chart()[["servicer forecast", "accounting forecast", "underwriting forecast"]].isna().sum().sum()),
          expected=lambda: 0.0, tol=0, live=True,
          proves="No forecast line breaks: the switch from the dashboard's own months to the future months is seamless."),
    Check(f"{SUITE}.chart_servicer_pct", "Collections vs forecasts chart: the servicer ahead/behind figure at the latest month is like-for-like",
          actual=lambda: _signed(tile("p_chart").dropna(subset=["collections"]).iloc[-1]["vs servicer"]),
          expected=lambda: round((warehouse(_at_cap_month(_lfl_base())) / warehouse(_forecast(FC_TABLES["servicer"]) + f" WHERE v.period_end_date = {cap()}") - 1) * 100, 1) / 100,
          tol=1e-9, live=True,
          proves="The hover's servicer % divides only collections that have a servicer forecast, as the Portfolio tiles do."),
    Check(f"{SUITE}.chart_hover_signed", "Collections vs forecasts: the hover's ahead/behind figures (accounting, underwriting) match collections / forecast",
          actual=lambda: float(_signed_mismatches()), expected=lambda: 0.0, tol=0, live=True,
          proves="'▲ +x%' exactly when collections beat that forecast, '▼ -x%' when behind, x = collections / forecast - 100% to 0.1; blank on forecast-only months."),
    Check(f"{SUITE}.chart_hover_signed_cumulative", "Collections vs forecasts, View = Cumulative: the hover's % is to date, matching the running totals",
          actual=lambda: float(_signed_mismatches({"View": "Cumulative"})), expected=lambda: 0.0, tol=0, live=True,
          proves="Until 2026-10-13 the Cumulative hover showed the month's % (France Aug -25.2%) beside to-date totals 12.1% apart."),
    Check(f"{SUITE}.chart_portfolios_blank_ahead", "Collections vs forecasts chart: no portfolio count on forecast-only months",
          actual=lambda: float(_ahead()["portfolios reporting"].notna().sum()), expected=lambda: 0.0, tol=0, live=True,
          proves="A forecast-only month reads blank, never '0 portfolios reporting'."),
    Check(f"{SUITE}.chart_servicer_reported", "Collections vs forecasts chart: servicer forecast over the reported months",
          actual=lambda: _reported("servicer"), expected=lambda: warehouse(_forecast(FC_TABLES["servicer"])), live=True,
          proves="Over the months the dashboard has, the line is the live query's servicer forecast: latest version, like-for-like keys, each month's rate."),
    Check(f"{SUITE}.chart_servicer_ahead", "Collections vs forecasts chart: servicer forecast over the next 12 months",
          actual=lambda: float(_ahead()["servicer forecast"].sum()), expected=lambda: warehouse(_ahead_forecast("servicer")), live=True,
          proves="The future months are the latest servicer forecast for the book reporting today, at each currency's newest rate."),
    Check(f"{SUITE}.chart_accounting_reported", "Collections vs forecasts chart: accounting forecast over the reported months",
          actual=lambda: _reported("accounting"), expected=lambda: warehouse(_forecast(FC_TABLES["accounting"])), live=True,
          proves="Over the months the dashboard has, the line is the live query's accounting forecast: latest version, like-for-like keys, each month's rate."),
    Check(f"{SUITE}.chart_accounting_ahead", "Collections vs forecasts chart: accounting forecast over the next 12 months",
          actual=lambda: float(_ahead()["accounting forecast"].sum()), expected=lambda: warehouse(_ahead_forecast("accounting")), live=True,
          proves="The future months are the latest accounting forecast for the book reporting today, at each currency's newest rate."),
    Check(f"{SUITE}.chart_underwriting_reported", "Collections vs forecasts chart: underwriting forecast over the reported months",
          actual=lambda: _reported("underwriting"), expected=lambda: warehouse(_forecast(FC_TABLES["underwriting"])), live=True,
          proves="Over the months the dashboard has, the line is the live query's underwriting forecast: latest version, like-for-like keys, each month's rate."),
    Check(f"{SUITE}.chart_underwriting_ahead", "Collections vs forecasts chart: underwriting forecast over the next 12 months",
          actual=lambda: float(_ahead()["underwriting forecast"].sum()), expected=lambda: warehouse(_ahead_forecast("underwriting")), live=True,
          proves="The future months are the latest underwriting forecast for the book reporting today, at each currency's newest rate."),

    # The Month by Month table was removed (2026-10-12): the chart's data downloads with every figure.
    Check(f"{SUITE}.titles_title_case", "Every visible column header is in Title Case",
          actual=lambda: float(sum(1 for e in ("bp_perf", "bp_full", "bc_perf", "bc_full", "p_chart", "d_srv", "d_port")
                                   for col in _lib.raw_tile_columns(e) if _header_problems(col))),
          expected=lambda: 0.0, tol=0, live=True,
          proves="No header reads like an internal label: no 'Sum of ...', every main word capitalised."),
    Check(f"{SUITE}.full_breakdown_total", "Full breakdown: total collections, one row per portfolio",
          actual=lambda: _col("bp_full", "collections"), expected=lambda: warehouse(_fact("f.gross_cash_recoveries")), live=True,
          proves="The grouped helper on the hidden Model page feeds one flat row per portfolio, without dropping or doubling one."),
    Check(f"{SUITE}.full_breakdown_rows", "Full breakdown: one row per portfolio",
          actual=lambda: float(len(tile("bp_full"))), expected=lambda: float(_lib.dashboard()["portfolio_name"].nunique()), tol=0, live=True,
          proves="No portfolio is split across rows by a grain that changes over time."),
    Check(f"{SUITE}.performance_total", "Performance by grain (Country): latest-month Total Collections add up to the book",
          actual=lambda: _col("bp_perf", "total collections"), expected=lambda: warehouse(_at_cap_month(COLL())), live=True,
          proves="Each group shows its latest month, and every portfolio lands in exactly one group."),
    Check(f"{SUITE}.performance_sorted", "Performance by grain: every §1 card and its change against the Comparison Window, sorted on Total Collections high to low",
          actual=lambda: float(list(tile("bp_perf").columns) == ["group"] + P_PERF_COLS
                               and (tile("bp_perf")["total collections"].astype(float).diff().dropna() <= 1e-6).all()),
          expected=lambda: 1.0, tol=0, live=True,
          proves="§2 is §1's cards by group (2026-10-12): a value and a change column per card; any header sorts."),
    Check(f"{SUITE}.cases_performance_sorted", "Cases performance by grain: every §1 behaviour card and its change, sorted on Collected Cases high to low",
          actual=lambda: float(list(tile("bc_perf").columns) == ["group"] + C_PERF_COLS
                               and (tile("bc_perf")["collected cases"].astype(float).diff().dropna() <= 1e-6).all()),
          expected=lambda: 1.0, tol=0, live=True,
          proves="All eight behaviour cards side by side, plus Collected cases, % of book (2026-10-14), each with its change; the Overall Summary stocks stay out."),
    Check(f"{SUITE}.full_breakdown_no_bar", "Full breakdowns: no relative-bar column",
          actual=lambda: float(sum(1 for e in ("bp_full", "bc_full") for c in tile(e).columns if "relative" in c)),
          expected=lambda: 0.0, tol=0, live=True, proves="The bar column was removed in the user's artifact (2026-10-12)."),
    Check(f"{SUITE}.cases_full_total", "Cases full breakdown: total collected cases",
          actual=lambda: _col("bc_full", "collected cases"), expected=lambda: warehouse(_mart("collected_cases_count")), live=True,
          proves="The Cases breakdown adds up to the mart."),
    Check(f"{SUITE}.cases_full_eur", "Cases full breakdown: total collections (case feed)",
          actual=lambda: _col("bc_full", "collections"), expected=lambda: warehouse(_mart_eur("collected_amount_local_sum")), live=True,
          proves="Case money is converted at the right month's rate."),
    Check(f"{SUITE}.cases_performance_total", "Cases performance by grain: latest-month Collected Cases add up to the mart",
          actual=lambda: _col("bc_perf", "collected cases"),
          expected=lambda: warehouse(f"SELECT SUM(collected_cases_count) FROM {MART} WHERE period_end_date = {cap()}"),
          tol=0, live=True, proves="Each group is the latest month, and every case-feed portfolio lands in one group."),
    Check(f"{SUITE}.tile_previous_window", "Total Collections comparison, default Comparison Window (L1M): the month before",
          actual=lambda: _latest("p_coll", "previous window"), expected=lambda: warehouse(_at_cap_sum(COLL(), 1)), live=True,
          proves="At the default L1M the card compares the latest month with the month before; controls.* checks every window."),
    Check(f"{SUITE}.header_portfolios", "Header: portfolios reporting at the latest month",
          actual=lambda: _latest("bp_ports", "v"),
          expected=lambda: warehouse(f"SELECT COUNT(DISTINCT portfolio_sk) FROM ({_lib.actuals_keys()}) WHERE period_end_date = {cap()}"),
          tol=0, live=True, proves="The data-status tiles count the portfolios the page actually shows."),
    Check(f"{SUITE}.definitions_table", "Data & Definitions table has every term",
          actual=lambda: float(len(tile("d_table"))), expected=_definitions_rows, tol=0, live=True,
          proves="The workbook's definitions are the CSV's, all of them."),
    Check(f"{SUITE}.cases_contribution_count", "Cases: Collected Cases card, the latest reporting month",
          actual=lambda: _latest("c_cc", "v"), expected=lambda: warehouse(_case_latest("collected_cases_count")),
          live=True, proves="The Cases cards show the latest month; the Comparison Window only moves the %."),
    Check(f"{SUITE}.cases_contribution_compared", "Cases: Collected Cases comparison, default L3M: the average month of the three before",
          actual=lambda: _latest("c_cc", "previous window"), expected=lambda: warehouse(_case_l3m("collected_cases_count")),
          live=True, proves="The comparison averages the months, never sums them (the user's default L3M)."),
    Check(f"{SUITE}.cases_contribution_eur", "Cases: Collections card, the latest reporting month in euro",
          actual=lambda: _latest("c_ce", "v"), expected=lambda: warehouse(_case_latest_eur("collected_amount_local_sum")),
          live=True, proves="What collected cases paid, converted at the month's rate."),
    Check(f"{SUITE}.cases_contribution_per_case", "Cases: Avg Monthly Collection per Case, latest month = warehouse euro ÷ warehouse cases",
          actual=lambda: _latest("c_cpe", "v"),
          expected=lambda: warehouse(_case_latest_eur("collected_amount_local_sum")) / warehouse(_case_latest("collected_cases_count")), tol=1e-9, live=True,
          proves="Collections per case is a ratio of sums, never an average of per-portfolio ratios."),
    Check(f"{SUITE}.tile_vs_forecast", "Collections as % of Forecast card, latest month: servicer, like-for-like",
          actual=lambda: _latest("p_vs", "v"),
          expected=lambda: warehouse(_at_cap_month(_lfl_base())) / warehouse(_at_cap_month(_servicer_monthly())), tol=1e-9, live=True,
          proves="The Window and Benchmark switches resolve to the right columns, and the servicer comparison is like-for-like."),
    Check(f"{SUITE}.tile_net_change", "Net Change in Collected Cases card, latest month: fresh minus lost",
          actual=lambda: _latest("c_nl", "v"), expected=lambda: warehouse(_case_latest("collected_cases_new_count - collected_cases_lost_count")),
          live=True, proves="New plus fresh, minus lost (dbt's new minus lost), straight from the mart, in the latest month."),
    Check(f"{SUITE}.book_follows_window", "Cases on Book card: read at the latest reporting month",
          actual=lambda: _latest("c_book", "v"), expected=lambda: warehouse(_book_at_window_end("cases_on_book_count")), tol=0, live=True,
          proves="The book is a stock: one month-end, the latest one, never summed."),
    Check(f"{SUITE}.book_ever_share_follows_window", "Cases ever collected, % of book: same month-end as the book card",
          actual=lambda: _latest("c_ever", "v"),
          expected=lambda: warehouse(_book_at_window_end("cases_ever_collected_count")) / warehouse(_book_at_window_end("cases_on_book_count")), tol=1e-4, live=True,
          proves="The share is ever collected ÷ on book at one month-end, never an average of shares."),
    Check(f"{SUITE}.seller_in_full_breakdown", "Full breakdown: every portfolio's Seller matches the query",
          actual=_seller_mismatches, expected=lambda: 0.0, tol=0, live=True,
          proves="Seller is a grain in its own right; every deal has exactly one seller, so it slots between Servicer and Deal."),
    Check(f"{SUITE}.seller_filter", "Header: a Seller filter on SELLER, cleared by Clear Filters",
          actual=_seller_filter_wired, expected=lambda: 0.0, tol=0, live=True,
          proves="Seller can be filtered like every other grain, and Clear Filters resets it."),
    Check(f"{SUITE}.tile_collections_window", "Total Collections card: the latest reporting month",
          actual=lambda: _latest("p_coll", "v"), expected=lambda: warehouse(_at_cap_month(COLL())), live=True,
          proves="The card is the latest month, whatever the Comparison Window."),
    Check(f"{SUITE}.tile_forecast_window", "Total Forecast card: the latest month's servicer forecast",
          actual=lambda: _latest("p_fc", "v"), expected=lambda: warehouse(_at_cap_month(_servicer_monthly())), live=True,
          proves="The Forecast card follows the Benchmark switch, for the latest month."),
    Check(f"{SUITE}.tile_gap_window", "Collections Minus Forecast card, latest month: servicer, like-for-like",
          actual=lambda: _latest("p_gap", "v"),
          expected=lambda: warehouse(_at_cap_month(_lfl_base())) - warehouse(_at_cap_month(_servicer_monthly())), live=True,
          proves="The shortfall or surplus in euro in the latest month."),
    Check(f"{SUITE}.data_quality_share", "Data Quality: Share of Collections Reconciled, This month",
          actual=lambda: _latest("d_recshare", "v"),
          expected=lambda: warehouse(_at_cap_month(_reconciled_base())) / warehouse(_at_cap_month(COLL())), tol=1e-9, live=True,
          proves="The reconciled share, moved from Portfolio to its own page, reads the latest month by default."),
    Check(f"{SUITE}.data_quality_band", "Data Quality band: portfolios reporting, the same as on Portfolio",
          actual=lambda: _latest("bd_ports", "v"), expected=lambda: _latest("bp_ports", "v"), tol=0, live=True,
          proves="The status band says the same thing on every page."),
]
