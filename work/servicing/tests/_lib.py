"""Shared plumbing for the Servicing dashboard tests. Nothing here is a test.

Every check compares two numbers that were produced INDEPENDENTLY:

    actual    what the dashboard query (or the live Sigma tile) produces
    expected  SQL written here, from the warehouse facts, by someone trying to break it

If both sides came from the same SQL the check would prove nothing, so no
expectation below ever reads `sigma_queries/`.

Back-testing: `--as-of YYYY-MM` caps BOTH sides at that month end. The dashboard
query's windows only look backwards, so capping its output rows is exactly the
same as having run it on that date - a back-test of July reproduces July.
"""
from __future__ import annotations

import csv
import datetime as dt
import io
import json
import pathlib
import subprocess
import time
from dataclasses import dataclass, field
from typing import Callable

import pandas as pd

import datalake

HERE = pathlib.Path(__file__).resolve().parent
SERVICING = HERE.parent
V1_SQL = SERVICING / "sigma_queries" / "retired" / "portfolios_element_v1.sql"   # the retired workbook's query (v1)
PROPOSED_SQL = SERVICING / "sigma_queries" / "portfolios_element.sql"   # what the live dashboard runs
DESIGN_MAIN = SERVICING / "design" / "project" / "Main.dc.html"
LOG = HERE / "results.csv"

WORKBOOK = "031548ab-54d6-437f-b452-e728c30cfb5b"   # the live Servicing Dashboard (promoted 2026-10-09)
TOL = 0.005   # 0.5%: Sigma rounds for display; a real break is never this small
# Cards and charts show euro in millions (the number standard, 2026-10-12): Sigma cannot scale a format, so these
# figures are stored / 1,000,000. Tests read them back in euros before comparing with the warehouse.
MILLIONS = {"p_coll", "p_fc", "p_net", "p_gap", "c_ce", "d_notrec", "p_chart", "c_money"}


# --- the run's settings, set once by run.py ----------------------------------
class Settings:
    as_of: str | None = None      # 'YYYY-MM-DD' month end, or None for "latest complete month"
    full: bool = False            # --full: the exhaustive design sweep (~2.5 min) instead of the sample


def as_of_label() -> str:
    return Settings.as_of or "latest"


# --- one check ---------------------------------------------------------------
@dataclass
class Check:
    """One reconciliation or invariant.

    `actual` and `expected` are zero-argument callables returning a number, so a
    suite can be listed (`--doc`) without touching Snowflake or Sigma.
    """
    id: str                         # stable, e.g. "money.collections" - used in results.csv
    title: str                      # one line, plain English
    actual: Callable[[], float]
    expected: Callable[[], float]
    proves: str                     # what a PASS means, for a reviewer
    tol: float = TOL                # relative tolerance; 0 means exact to the cent
    live: bool = False              # reads the live Sigma workbook (skipped by --offline and --as-of)
    today_only: bool = False        # describes the data as it stands today, so a back-test cannot rewind it
    tags: list[str] = field(default_factory=list)


# --- warehouse side ----------------------------------------------------------
# The dashboard scopes to the last COMPLETE month: a month whose portfolio count
# collapses against the month before is still loading and is left out. This
# guard fired for real on 2026-10-08 when September arrived with 4 portfolios
# against August's 264, so every expectation must apply the same rule.
LAST_COMPLETE_MONTH = """(
    SELECT MAX(m.period_end_date) FROM (
      SELECT period_end_date,
             COUNT(DISTINCT portfolio_sk) AS n,
             LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY period_end_date) AS prev_n
      FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
      WHERE period_end_date <= CURRENT_DATE()
      GROUP BY 1) m
    WHERE m.prev_n IS NULL OR m.n >= 0.5 * m.prev_n)"""


def cap() -> str:
    """The month-end every expectation stops at: the last complete month, or the
    back-test date if that is earlier."""
    if Settings.as_of:
        return f"LEAST({LAST_COMPLETE_MONTH}, LAST_DAY('{Settings.as_of}'::DATE))"
    return LAST_COMPLETE_MONTH


# One rate for every month, as the dashboard uses since 2026-10-14 (the NPL dashboard's rule): each currency's
# month-end rate at the latest complete reporting month. Deliberately the LIVE latest month, not the back-test date:
# the dashboard query converts with today's rate whatever month a back-test caps at. EUR rows get rate 1.
LATEST_COMPLETE = """(SELECT MAX(m.period_end_date) FROM (
    SELECT period_end_date, COUNT(DISTINCT portfolio_sk) AS n,
           LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY period_end_date) AS prev_n
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY WHERE period_end_date <= CURRENT_DATE() GROUP BY 1) m
  WHERE m.prev_n IS NULL OR m.n >= 0.5 * m.prev_n)"""
FX_FLOW = f"""(
  SELECT r.quote_currency AS cid, r.date_day AS m, l.ultimo_value AS rate
  FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY AS r
  INNER JOIN PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY AS l
    ON l.quote_currency = r.quote_currency AND l.base_currency = 'EUR' AND l.rate_type = 'PMI' AND l.date_day = {LATEST_COMPLETE}
  WHERE r.base_currency = 'EUR' AND r.rate_type = 'PMI' AND r.quote_currency <> 'EUR'
  UNION ALL
  SELECT DISTINCT 'EUR', period_end_date, 1
  FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY)"""


def actuals_keys() -> str:
    """Every portfolio x month x currency the dashboard covers: inside
    DIM_PORTFOLIO, on or after the acquisition month, no later than the cap."""
    return f"""
    SELECT DISTINCT f.portfolio_sk, f.period_end_date, f.currency_id
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
    INNER JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p ON p.portfolio_sk = f.portfolio_sk
    WHERE f.period_end_date <= {cap()}
      AND (p.capex_date IS NULL OR f.period_end_date >= DATE_TRUNC('MONTH', p.capex_date))"""


_SCALARS: dict[str, float] = {}


def warehouse(sql: str) -> float:
    """First column of the first row, summed - cached per SQL text and as-of."""
    key = as_of_label() + sql
    if key not in _SCALARS:
        df = datalake.q(sql, convert=False)
        _SCALARS[key] = float(pd.to_numeric(df.iloc[:, 0], errors="coerce").fillna(0).sum())
    return _SCALARS[key]


# --- dashboard side: the query, run once per process -------------------------
_FRAMES: dict[str, pd.DataFrame] = {}


def dashboard(which: str = "proposed") -> pd.DataFrame:
    """The dashboard query's output, one row per portfolio x reporting month,
    capped at the back-test date when one is set."""
    if which not in _FRAMES:
        path = PROPOSED_SQL if which == "proposed" else V1_SQL
        _FRAMES[which] = datalake.q(path, lower=True)
    df = _FRAMES[which]
    if Settings.as_of:
        df = df[pd.to_datetime(df.reporting_month) <= pd.Timestamp(Settings.as_of) + pd.offsets.MonthEnd(0)]
    return df


def col_sum(column: str, which: str = "proposed", where: Callable[[pd.DataFrame], pd.Series] | None = None) -> float:
    df = dashboard(which)
    if where is not None:
        df = df[where(df)]
    return float(pd.to_numeric(df[column], errors="coerce").fillna(0).sum())


# --- live Sigma side ---------------------------------------------------------
def _sigma(*args: str, body: str | None = None) -> str:
    cmd = ["sigma", "-p", "brocc", "api", *args]
    if body:
        cmd += ["--body", body]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout


_RAW_COLUMNS: dict[str, list[str]] = {}
_TILES: dict[str, pd.DataFrame] = {}


def tile(element_id: str, tries: int = 90, params: dict | None = None) -> pd.DataFrame:
    """What a tile in the live workbook actually shows (export -> poll -> CSV).

    Sigma does not error on a formula it cannot resolve: it writes
    `Unknown column "[X]"` into every cell as text, which reads as zero
    downstream. That is caught here, loudly."""
    key = element_id if not params else element_id + "|" + json.dumps(params, sort_keys=True)
    if key not in _TILES:
        body = {"elementId": element_id, "format": {"type": "csv"}}
        if params:
            body["parameters"] = params   # control id -> value: the tile as a viewer who set those controls sees it
        started = _sigma("workbooks", "export", "--params", json.dumps({"workbookId": WORKBOOK}), body=json.dumps(body))
        qid = json.loads(started)["queryId"]
        for _ in range(tries):
            time.sleep(1)
            out = _sigma("query", "download", "get", "--params", json.dumps({"queryId": qid}))
            if out.strip() and out.strip() != "null":
                df = pd.read_csv(io.StringIO(out))
                _RAW_COLUMNS[key] = [c.strip() for c in df.columns]
                df.columns = [c.strip().lower() for c in df.columns]
                bad = {f"{c}: {v}" for c in df.columns
                       for v in df[c].astype(str)[df[c].astype(str).str.startswith("Unknown column")].unique()[:2]}
                if bad:
                    raise ValueError(f"{key} has unresolved formulas: {'; '.join(sorted(bad))}")
                _TILES[key] = df
                break
        else:
            raise TimeoutError(f"export for {element_id} never completed")
    return _TILES[key]


def raw_tile_columns(element_id: str) -> list[str]:
    """The headers exactly as Sigma exports them, before tile() lowercases them."""
    tile(element_id)
    return _RAW_COLUMNS[element_id]


def tile_sum(element_id: str, column: str) -> float:
    df = tile(element_id)
    hits = [c for c in df.columns if c == column] or [c for c in df.columns if c.startswith(column)]
    if not hits:
        raise KeyError(f"{element_id} has no column like {column!r}; it has {list(df.columns)[:6]}")
    return float(pd.to_numeric(df[hits[0]], errors="coerce").sum())


# --- results log -------------------------------------------------------------
FIELDS = ["run_at", "as_of", "suite", "check_id", "title", "actual", "expected", "drift_pct", "tol_pct", "status"]


def log(rows: list[dict]) -> None:
    """Append every run, so drift is a trend rather than a snapshot. A figure
    that is right today and 0.4% out next month still passes the tolerance, but
    the log shows it moving."""
    new = not LOG.exists()
    with LOG.open("a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS)
        if new:
            w.writeheader()
        w.writerows(rows)


def now() -> str:
    return dt.datetime.now().isoformat(timespec="seconds")
