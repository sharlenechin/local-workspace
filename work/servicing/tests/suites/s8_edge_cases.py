"""8 · Edge cases - the failures a total can hide.

Suites 2-5 compare totals. A total can be right while the money sits in the wrong
portfolio or month, or while both sides silently drop the same rows. These checks
look underneath: row by row, at the joins both sides share, and at the awkward
rows the book actually contains (negative months, zero forecasts, a month still loading).
"""
from __future__ import annotations

import pandas as pd

from _lib import FX_FLOW, Check, actuals_keys, cap, dashboard, warehouse
import datalake

SUITE = "edge"
_FRAMES: dict = {}


def _facts_by_row(value_sql: str, source_sql: str, key: str) -> pd.DataFrame:
    """One euro value per portfolio x month from the facts, keyed like the dashboard rows."""
    if key not in _FRAMES:
        _FRAMES[key] = datalake.q(f"""SELECT p.portfolio_bk AS portfolio_name, k.period_end_date AS reporting_month,
               SUM({value_sql} * fx.rate) AS v
          FROM ({actuals_keys()}) AS k
          INNER JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p ON p.portfolio_sk = k.portfolio_sk
          {source_sql}
          LEFT JOIN {FX_FLOW} AS fx ON fx.cid = k.currency_id AND fx.m = k.period_end_date
          GROUP BY 1, 2""", lower=True)
    return _FRAMES[key]


def _worst_row_gap(column: str, facts: pd.DataFrame) -> float:
    """Largest absolute difference on any single portfolio-month (rows missing on either side count in full)."""
    d = dashboard()[["portfolio_name", "reporting_month", column]].copy()
    for f in (d, facts):
        f["reporting_month"] = pd.to_datetime(f["reporting_month"]).dt.strftime("%Y-%m-%d")
    m = d.merge(facts, on=["portfolio_name", "reporting_month"], how="outer")
    return float((pd.to_numeric(m[column], errors="coerce").fillna(0) - m["v"].fillna(0)).abs().max())


ACTUALS = """INNER JOIN PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
      ON f.portfolio_sk = k.portfolio_sk AND f.period_end_date = k.period_end_date AND f.currency_id = k.currency_id"""


def _forecast(t: str) -> str:
    return f"""INNER JOIN (SELECT portfolio_sk, period_end_date, currency_id, gross_collection_forecast AS amount
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_{t}_SNAPSHOT_MONTHLY
        QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY portfolio_sk, period_end_date)) AS f
      ON f.portfolio_sk = k.portfolio_sk AND f.period_end_date = k.period_end_date AND f.currency_id = k.currency_id"""


def _no_rate() -> str:
    """In-scope fact rows with no FX rate. Both sides would drop them identically,
    so no reconciliation could ever notice - this is the only place it is caught."""
    return f"""SELECT COUNT(*) FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
      INNER JOIN ({actuals_keys()}) AS k
        ON k.portfolio_sk = f.portfolio_sk AND k.period_end_date = f.period_end_date AND k.currency_id = f.currency_id
      LEFT JOIN {FX_FLOW} AS fx ON fx.cid = f.currency_id AND fx.m = f.period_end_date
      WHERE fx.rate IS NULL"""


def _forecast_dupes(t: str, grain: str) -> str:
    """Rows sharing a key at the latest version would be added twice."""
    return f"""SELECT COUNT(*) FROM (
      SELECT {grain} FROM (
        SELECT * FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_{t}_SNAPSHOT_MONTHLY
        QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY portfolio_sk, period_end_date))
      GROUP BY {grain} HAVING COUNT(*) > 1)"""


def _latest_month_gap() -> float:
    """Months between the dashboard's newest month and the cap it should stop at (0 = right month)."""
    newest = pd.to_datetime(dashboard()["reporting_month"]).max()
    expected = pd.to_datetime(datalake.q(f"SELECT {cap()} AS m", lower=True)["m"][0])
    return float(abs((newest.year - expected.year) * 12 + newest.month - expected.month))


CHECKS = [
    Check(f"{SUITE}.collections_every_row", "Collections match the facts on every single portfolio-month",
          actual=lambda: _worst_row_gap("collections_sum", _facts_by_row("f.gross_cash_recoveries", ACTUALS, "coll")),
          expected=lambda: 0.0, tol=0,
          proves="Not just the total: no money has moved between portfolios or months. Measured exact on all 1,839 rows, 2026-10-09."),
    Check(f"{SUITE}.accounting_every_row", "Accounting forecast matches the facts on every portfolio-month",
          actual=lambda: _worst_row_gap("accounting_forecast_sum", _facts_by_row("f.amount", _forecast("ACCOUNTING"), "acc")),
          expected=lambda: 0.0, tol=0,
          proves="A forecast landing in the wrong month would net out in a nine-month total; it cannot hide here."),
    Check(f"{SUITE}.underwriting_every_row", "Underwriting forecast matches the facts on every portfolio-month",
          actual=lambda: _worst_row_gap("underwriting_forecast_sum", _facts_by_row("f.amount", _forecast("UNDERWRITING"), "uw")),
          expected=lambda: 0.0, tol=0,
          proves="Same, for the plan executives are measured against."),
    Check(f"{SUITE}.fx_coverage", "Every in-scope portfolio-month has an exchange rate",
          actual=lambda: warehouse(_no_rate()), expected=lambda: 0.0, tol=0,
          proves="No collections are silently dropped by a missing rate - a failure both sides of every other check would share."),
    Check(f"{SUITE}.servicer_forecast_grain", "Servicer forecast: no duplicate rows at the latest version",
          actual=lambda: warehouse(_forecast_dupes("SERVICER", "portfolio_sk, period_end_date, currency_id, batch_sk, segment_sk")),
          expected=lambda: 0.0, tol=0,
          proves="The servicer fact is batch- and segment-level (up to 44x finer than the others); summing its parts is right, summing a repeated row would not be."),
    Check(f"{SUITE}.accounting_forecast_grain", "Accounting forecast: one row per portfolio-month at the latest version",
          actual=lambda: warehouse(_forecast_dupes("ACCOUNTING", "portfolio_sk, period_end_date, currency_id")),
          expected=lambda: 0.0, tol=0, proves="No restatement is counted twice."),
    Check(f"{SUITE}.underwriting_forecast_grain", "Underwriting forecast: one row per portfolio-month at the latest version",
          actual=lambda: warehouse(_forecast_dupes("UNDERWRITING", "portfolio_sk, period_end_date, currency_id")),
          expected=lambda: 0.0, tol=0, proves="No restatement is counted twice."),
    Check(f"{SUITE}.loading_month_excluded", "The newest month shown is the last COMPLETE month",
          actual=_latest_month_gap, expected=lambda: 0.0, tol=0,
          proves="A month still loading (September 2026: 4 portfolios against 264) never reaches a tile."),
    Check(f"{SUITE}.negative_months_kept", "Negative collection months (reversals) are kept, not dropped or floored",
          actual=lambda: float(dashboard()["collections_sum"].clip(upper=0).sum()),
          expected=lambda: float(_facts_by_row("f.gross_cash_recoveries", ACTUALS, "coll")["v"].clip(upper=0).sum()),
          tol=0, proves="Net-of-reversal months stay negative, as the servicer reported them (12 rows on 2026-10-09)."),
    Check(f"{SUITE}.superseded_versions_carry_no_value", "Superseded forecast versions in the dashboard's months hold no money",
          actual=lambda: warehouse(" UNION ALL ".join(f"""SELECT COALESCE(SUM(ABS(v.amount)), 0) FROM (
              SELECT f.gross_collection_forecast AS amount FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_{t}_SNAPSHOT_MONTHLY AS f
              INNER JOIN ({actuals_keys()}) AS k ON k.portfolio_sk = f.portfolio_sk AND k.period_end_date = f.period_end_date AND k.currency_id = f.currency_id
              QUALIFY f.snapshot_version < MAX(f.snapshot_version) OVER (PARTITION BY f.portfolio_sk, f.period_end_date)) AS v""" for t in ("SERVICER", "ACCOUNTING", "UNDERWRITING"))),
          expected=lambda: 0.0, tol=0,
          proves="Today every superseded version is zero-valued (servicer) or absent (accounting, underwriting), so the latest-version "
                 "filter changes no figure and no reconciliation can test it. The day a restatement carries money this fails: the filter "
                 "is then load-bearing, and mutation_test.py's version mutant starts to bite."),
]


# ---- the header's data status: what is NOT shown must be said ----------------
def _loading_expected() -> tuple:
    """The first month after the cap that has any portfolios, and how many - from the facts."""
    df = datalake.q(f"""SELECT MIN(period_end_date) AS m FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        WHERE period_end_date > {cap()} AND period_end_date <= CURRENT_DATE()""", lower=True)
    m = df["m"][0]
    if m is None or pd.isna(m):
        return None, 0.0
    n = datalake.q(f"""SELECT COUNT(DISTINCT portfolio_sk) AS n FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        WHERE period_end_date = '{pd.Timestamp(m).date()}'""", lower=True)["n"][0]
    return pd.Timestamp(m), float(n)


def _shown(col: str):
    return dashboard()[col].iloc[0]


CHECKS += [
    Check(f"{SUITE}.loading_month_reported", "The header's 'still loading' count matches the facts",
          actual=lambda: float(_shown("loading_month_portfolio_count")),
          expected=lambda: _loading_expected()[1], tol=0, today_only=True,
          proves="When a month is held back, viewers are told how many portfolios have reported so far (September 2026: 4 of 264) instead of the month silently vanishing."),
    Check(f"{SUITE}.data_as_of_is_cap", "'Data as of' is the last complete month",
          actual=lambda: float(pd.Timestamp(_shown("data_as_of_month")).toordinal()),
          expected=lambda: float(pd.Timestamp(datalake.q(f"SELECT {cap()} AS m", lower=True)["m"][0]).toordinal()), tol=0, today_only=True,
          proves="The month the header names is exactly the month the tiles show."),
]
