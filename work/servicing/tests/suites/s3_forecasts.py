"""3 · Forecasts - servicer, accounting and underwriting, the three benchmarks.

Each forecast fact keeps every revision as a new snapshot_version and is NOT
deduped upstream, so the expectation takes the latest version per portfolio-month
itself. Forecasts are compared only on portfolio-months that have actuals, in the
same currency: that is what makes "collections vs forecast" like-for-like.
"""
from __future__ import annotations

from _lib import FX_FLOW, Check, actuals_keys, col_sum, dashboard, warehouse

SUITE = "forecasts"


def _forecast(table: str) -> str:
    return f"""SELECT SUM(v.amount * fx.rate) FROM (
        SELECT f.portfolio_sk, f.period_end_date, f.currency_id, f.gross_collection_forecast AS amount
        FROM PROD.NPL_COMMON.{table} AS f
        WHERE f.period_end_date <= CURRENT_DATE()
        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (PARTITION BY f.portfolio_sk, f.period_end_date)
      ) AS v
      INNER JOIN ({actuals_keys()}) AS k
        ON k.portfolio_sk = v.portfolio_sk AND k.period_end_date = v.period_end_date AND k.currency_id = v.currency_id
      LEFT JOIN {FX_FLOW} AS fx ON fx.cid = v.currency_id AND fx.m = v.period_end_date"""


def _flag_share(flag: str) -> float:
    d = dashboard()
    return float(d[flag].fillna(False).astype(bool).mean())


CHECKS = [
    Check(f"{SUITE}.servicer", "Servicer forecast, EUR",
          actual=lambda: col_sum("servicer_forecast_sum"),
          expected=lambda: warehouse(_forecast("FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY")),
          proves="Latest version only, like-for-like keys, converted at the flow rate."),
    Check(f"{SUITE}.accounting", "Accounting forecast, EUR",
          actual=lambda: col_sum("accounting_forecast_sum"),
          expected=lambda: warehouse(_forecast("FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY")),
          proves="The accounting forecast joins exactly as the servicer one does, so the benchmark toggle compares like with like."),
    Check(f"{SUITE}.underwriting", "Underwriting forecast, EUR",
          actual=lambda: col_sum("underwriting_forecast_sum"),
          expected=lambda: warehouse(_forecast("FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY")),
          proves="Same for the underwriting plan - the number with consequences."),
    Check(f"{SUITE}.accounting_coverage", "Every portfolio-month has an accounting forecast",
          actual=lambda: _flag_share("have_accounting_forecast_flag"), expected=lambda: 1.0, tol=0,
          proves="'vs accounting' needs no like-for-like filter. If this drops below 100%, the dashboard must start filtering as it does for servicer."),
    Check(f"{SUITE}.underwriting_coverage", "Every portfolio-month has an underwriting forecast",
          actual=lambda: _flag_share("have_underwriting_forecast_flag"), expected=lambda: 1.0, tol=0,
          proves="Same for underwriting."),
    Check(f"{SUITE}.servicer_like_for_like", "Collections behind the servicer comparison come only from months with a servicer forecast",
          actual=lambda: col_sum("collections_sum", where=lambda d: d.have_servicer_forecast_flag.fillna(False).astype(bool)),
          expected=lambda: col_sum("collections_sum", where=lambda d: d.servicer_forecast_sum.notna()),
          proves="The flag and the forecast agree, so 'vs servicer' never divides collections by a forecast that is not there."),
]
