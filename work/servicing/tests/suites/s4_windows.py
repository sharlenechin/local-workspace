"""4 · Rolling windows - L1M, L3M, L6M, L12M and cumulative.

The window is the N months BEFORE the current one and EXCLUDES it: for a January
row, L3M is October + November + December. That is what RANGE BETWEEN 3
PRECEDING AND 1 PRECEDING means on a month index. The average divides by the
months that exist, never by N: 40.6% of portfolio-months have a short window.

These live in SQL, not Sigma, on purpose: a Sigma aggregate recomputes over the
rows currently visible, so under a date filter an L12M would silently become
"the last 12 visible months".
"""
from __future__ import annotations

import _lib
from _lib import FX_FLOW, Check, actuals_keys, col_sum, warehouse

SUITE = "windows"


def _monthly(value_sql: str, source: str) -> str:
    """One euro value per portfolio-month, on the dashboard's keys."""
    return f"""SELECT k.portfolio_sk, k.period_end_date, SUM({value_sql} * fx.rate) AS v
      FROM ({actuals_keys()}) AS k
      {source}
      LEFT JOIN {FX_FLOW} AS fx ON fx.cid = k.currency_id AND fx.m = k.period_end_date
      GROUP BY 1, 2"""


ACTUALS = """INNER JOIN PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
        ON f.portfolio_sk = k.portfolio_sk AND f.period_end_date = k.period_end_date AND f.currency_id = k.currency_id"""


def _forecast_source(table: str) -> str:
    return f"""INNER JOIN (
        SELECT portfolio_sk, period_end_date, currency_id, gross_collection_forecast AS amount
        FROM PROD.NPL_COMMON.{table}
        QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY portfolio_sk, period_end_date)
      ) AS f ON f.portfolio_sk = k.portfolio_sk AND f.period_end_date = k.period_end_date AND f.currency_id = k.currency_id"""


def _window(base: str, n: int, agg: str = "SUM") -> str:
    frame = "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" if n == 0 else f"RANGE BETWEEN {n} PRECEDING AND 1 PRECEDING"
    return f"""SELECT SUM(w) FROM (
      SELECT {agg}(v) OVER (PARTITION BY portfolio_sk
          ORDER BY DATEDIFF(MONTH, '1900-01-01', period_end_date) {frame}) AS w
      FROM ({base}))"""


# Built when a check runs, not at import: the back-test date is set after import.
def COLL() -> str:
    return _monthly("f.gross_cash_recoveries", ACTUALS)


def ACC() -> str:
    return _monthly("f.amount", _forecast_source("FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY"))


def UW() -> str:
    return _monthly("f.amount", _forecast_source("FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY"))

CHECKS = []
for n in (3, 6, 12):
    CHECKS.append(Check(f"{SUITE}.collections_l{n}m", f"Collections, L{n}M window sum",
                        actual=lambda n=n: col_sum(f"collections_l{n}m_sum"),
                        expected=lambda n=n: warehouse(_window(COLL(), n)),
                        proves=f"The frame is the {n} PRIOR months, never including the current one."))
CHECKS += [
    Check(f"{SUITE}.collections_l1m", "Collections, L1M (the previous month)",
          actual=lambda: col_sum("collections_l1m_sum"),
          expected=lambda: warehouse(_window(COLL(), 1)),
          proves="L1M is last month's figure, not this month's."),
    Check(f"{SUITE}.months_in_l3m", "Months present in the L3M window",
          actual=lambda: col_sum("months_in_l3m_window"),
          expected=lambda: warehouse(_window(COLL(), 3, "COUNT")),
          proves="The divisor of the L3M average counts the months that exist, not a constant 3."),
    Check(f"{SUITE}.cumulative_collections", "Cumulative collections",
          actual=lambda: col_sum("cumulative_collections_sum"),
          expected=lambda: warehouse(_window(COLL(), 0)),
          proves="The cumulative view on the main chart adds up month by month from each portfolio's first month."),
]
for name, base in (("accounting", ACC), ("underwriting", UW)):
    for n in (1, 3, 12):
        CHECKS.append(Check(f"{SUITE}.{name}_l{n}m", f"{name.title()} forecast, L{n}M window sum",
                            actual=lambda name=name, n=n: col_sum(f"{name}_forecast_l{n}m_sum"),
                            expected=lambda base=base, n=n: warehouse(_window(base(), n)),
                            proves=f"The KPI's 'Compare to {name}' uses the same {n}-month window as the collections it is compared with."))


# ---- case windows, for the Cases page KPI --------------------------------------
# Counted over months WITH case data: a portfolio-month with collections but no
# case feed has a blank case count, and must not count towards the divisor.
def _case_base(expr: str, eur: bool = False) -> str:
    """One case value per portfolio-month on the dashboard's keys; blank where there is no feed."""
    fx = f"LEFT JOIN {FX_FLOW} AS fx ON fx.cid = k.currency_id AND fx.m = k.period_end_date" if eur else ""
    return f"""SELECT k.portfolio_sk, k.period_end_date, MAX(m.{expr}{' * fx.rate' if eur else ''}) AS v
      FROM (SELECT DISTINCT portfolio_sk, period_end_date, currency_id FROM ({actuals_keys()})) AS k
      LEFT JOIN PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS m
        ON m.portfolio_sk = k.portfolio_sk AND m.period_end_date = k.period_end_date
      {fx}
      GROUP BY 1, 2"""


CASE_WINDOWS = [
    ("collected_cases", "collected_cases_count", False, "Collected cases"),
    ("collected_cases_first_collection", "collected_cases_first_collection_count", False, "New"),
    ("collected_cases_three_consecutive_months", "collected_cases_three_consecutive_months_count", False, "Three consecutive months"),
    ("collected_cases_lost", "collected_cases_lost_count", False, "Lost"),
    ("collected_cases_new", "collected_cases_new_count", False, "Fresh plus New (dbt new)"),
    ("collected_cases_amount", "collected_amount_local_sum", True, "Collected cases, EUR"),
]
for name, mart_col, eur, label in CASE_WINDOWS:
    for n in (1, 3, 12):
        CHECKS.append(Check(f"{SUITE}.{name}_l{n}m", f"{label}, L{n}M window sum",
                            actual=lambda name=name, n=n: col_sum(f"{name}_l{n}m_sum"),
                            expected=lambda c=mart_col, e=eur, n=n: warehouse(_window(_case_base(c, e), n)),
                            proves=f"The Cases KPI's {label.lower()} window uses the {n} prior months of the mart, never the current one."))
for n in (3, 12):
    CHECKS.append(Check(f"{SUITE}.months_in_case_l{n}m", f"Months WITH case data in the L{n}M window",
                        actual=lambda n=n: col_sum(f"months_in_case_l{n}m_window"),
                        expected=lambda n=n: warehouse(_window(_case_base("collected_cases_count"), n, "COUNT")),
                        proves="The case average divides by months that had a case feed, not by months that had collections."))


# ---- like-for-like collections for the servicer comparison ----------------------
def _lfl_base() -> str:
    """Collections on portfolio-months that have a servicer forecast (latest version), else 0."""
    return _monthly("IFF(sf.amount IS NOT NULL, f.gross_cash_recoveries, 0)", ACTUALS + """
      LEFT JOIN (SELECT portfolio_sk, period_end_date, currency_id, SUM(gross_collection_forecast) AS amount
        FROM (SELECT * FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY
              QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY portfolio_sk, period_end_date))
        GROUP BY 1, 2, 3) AS sf
        ON sf.portfolio_sk = k.portfolio_sk AND sf.period_end_date = k.period_end_date AND sf.currency_id = k.currency_id""")


CHECKS.append(Check(f"{SUITE}.collections_servicer_lfl", "Like-for-like collections (months with a servicer forecast)",
                    actual=lambda: col_sum("collections_servicer_lfl_sum"),
                    expected=lambda: warehouse(f"SELECT SUM(v) FROM ({_lfl_base()})"),
                    proves="The servicer comparison counts only collections that have a forecast to be compared with (EUR 308.4m of 347.4m)."))
for n in (1, 3, 12):
    CHECKS.append(Check(f"{SUITE}.collections_servicer_lfl_l{n}m", f"Like-for-like collections, L{n}M window sum",
                        actual=lambda n=n: col_sum(f"collections_servicer_lfl_l{n}m_sum"),
                        expected=lambda n=n: warehouse(_window(_lfl_base(), n)),
                        proves="The Portfolio KPI's value when compared with the servicer forecast, in the same window as that forecast."))


# ---- window sums behind the Portfolio tiles: net, servicer cost, reconciled ------
def _reconciled_base() -> str:
    """Collections on portfolio-months the dashboard marks reconciled. The flag itself is the query's
    (a row-level comparison of two feeds); this checks the windowing, not the flag."""
    # Capped at the back-test month like every other base (found 2026-10-14, the first back-test): without it the
    # expected side summed months the dashboard side had already cut.
    return f"""SELECT p.portfolio_sk, d.reporting_month AS period_end_date, SUM(IFF(d.is_reconciled_flag, d.collections_sum, 0)) AS v
      FROM ({_dashboard_rows()}) AS d INNER JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p ON p.portfolio_bk = d.portfolio_name
      WHERE d.reporting_month <= {_lib.cap()} GROUP BY 1, 2"""


def _dashboard_rows() -> str:
    import _lib
    return _lib.PROPOSED_SQL.read_text()


for name, base, label in (("net_collections", lambda: _monthly("f.net_cash_recoveries", ACTUALS), "Net collections"),
                          ("servicer_cost_total", lambda: _monthly("(f.gross_cash_recoveries - f.net_cash_recoveries)", ACTUALS), "Servicer cost")):
    for n in (1, 3, 12):
        CHECKS.append(Check(f"{SUITE}.{name}_l{n}m", f"{label}, L{n}M window sum",
                            actual=lambda name=name, n=n: col_sum(f"{name}_l{n}m_sum"),
                            expected=lambda base=base, n=n: warehouse(_window(base(), n)),
                            proves=f"The Portfolio tile '{label}' follows the Window switch over the {n} prior months."))
for n in (1, 3, 12):
    CHECKS.append(Check(f"{SUITE}.collections_reconciled_l{n}m", f"Reconciled collections, L{n}M window sum",
                        actual=lambda n=n: col_sum(f"collections_reconciled_l{n}m_sum"),
                        expected=lambda n=n: warehouse(_window(_reconciled_base(), n)),
                        proves="The 'Share of collections reconciled' tile follows the Window switch."))


# ---- 2- and 24-month windows: the previous-window comparison on every tile ----------
for n in (2, 24):
    CHECKS.append(Check(f"{SUITE}.collections_l{n}m", f"Collections, L{n}M window sum",
                        actual=lambda n=n: col_sum(f"collections_l{n}m_sum"), expected=lambda n=n: warehouse(_window(COLL(), n)),
                        proves=f"With the other windows it gives each tile's previous window (e.g. the 3 months before the last 3 = L6M − L3M)."))
    CHECKS.append(Check(f"{SUITE}.collected_cases_l{n}m", f"Collected cases, L{n}M window sum",
                        actual=lambda n=n: col_sum(f"collected_cases_l{n}m_sum"),
                        expected=lambda n=n: warehouse(_window(_case_base("collected_cases_count"), n)),
                        proves="The Cases tiles' previous window, from the mart."))
    CHECKS.append(Check(f"{SUITE}.months_in_l{n}m", f"Months present in the L{n}M window",
                        actual=lambda n=n: col_sum(f"months_in_l{n}m_window"), expected=lambda n=n: warehouse(_window(COLL(), n, "COUNT")),
                        proves="The previous window's average divides by the months that exist."))
