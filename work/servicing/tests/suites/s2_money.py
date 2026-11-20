"""2 · Money - collections and costs, against the servicer's own portfolio report.

Expected side: FCT_PORTFOLIO_SNAPSHOT_MONTHLY, converted per currency at that
month's average rate, scoped exactly as the dashboard scopes it.
"""
from __future__ import annotations

from _lib import FX_FLOW, Check, actuals_keys, col_sum, warehouse

SUITE = "money"


def _fact(expr: str) -> str:
    return f"""SELECT SUM({expr} * fx.rate)
      FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
      INNER JOIN ({actuals_keys()}) AS k
        ON k.portfolio_sk = f.portfolio_sk AND k.period_end_date = f.period_end_date AND k.currency_id = f.currency_id
      LEFT JOIN {FX_FLOW} AS fx ON fx.cid = f.currency_id AND fx.m = f.period_end_date"""


CHECKS = [
    Check(f"{SUITE}.collections", "Gross collections, EUR",
          actual=lambda: col_sum("collections_sum"),
          expected=lambda: warehouse(_fact("f.gross_cash_recoveries")),
          proves="The FX join and the euro conversion: each currency at its own month's rate, then summed."),
    Check(f"{SUITE}.net_collections", "Net collections, EUR",
          actual=lambda: col_sum("net_collections_sum"),
          expected=lambda: warehouse(_fact("f.net_cash_recoveries")),
          proves="Cost is deducted once, not twice."),
    Check(f"{SUITE}.servicer_cost", "Servicer cost (gross minus net), EUR",
          actual=lambda: col_sum("servicer_cost_total_sum"),
          expected=lambda: warehouse(_fact("(f.gross_cash_recoveries - f.net_cash_recoveries)")),
          proves="Cross-checks the two columns above from a third direction."),
    Check(f"{SUITE}.servicer_commission", "Servicer commission, EUR",
          actual=lambda: col_sum("servicer_commission_sum"),
          expected=lambda: warehouse(_fact("-f.commission")),
          proves="Commission is stored negative in the fact; the sign is flipped exactly once."),
    Check(f"{SUITE}.reconciled_share_bounds", "Reconciled collections never exceed total collections",
          actual=lambda: max(0.0, col_sum("collections_sum", where=lambda d: d.is_reconciled_flag.fillna(False).astype(bool))
                             - col_sum("collections_sum")),
          expected=lambda: 0.0, tol=0,
          proves="The reconciled share on the KPI and tables can only lie between 0% and 100%."),
]
