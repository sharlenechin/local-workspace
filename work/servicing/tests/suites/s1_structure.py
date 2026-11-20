"""1 · Structure - is the dashboard query the shape every tile assumes?

Every tile sums or groups this one table, so a duplicated row, a currency mix or
a drift from the retired v1 query would corrupt all of them at once. These run first.
"""
from __future__ import annotations

import pandas as pd

import _lib
from _lib import Check, dashboard

SUITE = "structure"

# Columns the retired dashboard (v1, sigma_queries/retired/) already carried. The query must
# reproduce every one of them unchanged - it only ADDS columns. A regression check, not a correctness one.
SHARED_MONEY = ["collections_sum", "net_collections_sum", "servicer_forecast_sum", "balance_sum",
                "servicer_cost_total_sum", "collections_l3m_sum", "collections_l12m_sum",
                "cumulative_collections_sum"]
SHARED_COUNTS = ["collected_cases_count", "collected_cases_new_count", "collected_cases_lost_count",
                 "cases_on_book_count", "months_in_l3m_window"]


def _dupes() -> float:
    df = dashboard()
    return float(df.duplicated(["portfolio_name", "reporting_month"]).sum())


def _multi_ccy() -> float:
    return float(dashboard()["is_multi_currency_flag"].fillna(False).astype(bool).sum())


def _row_diff() -> float:
    """Rows in one query and not the other, matched on the grain."""
    k = ["portfolio_name", "reporting_month"]
    a = dashboard("proposed")[k].astype(str).apply("|".join, axis=1)
    b = dashboard("v1")[k].astype(str).apply("|".join, axis=1)
    return float(len(set(a) ^ set(b)))


def _same_as_live(column: str):
    """This query minus v1 for one shared column, row by row, summed in absolute value."""
    def f() -> float:
        k = ["portfolio_name", "reporting_month"]
        a = dashboard("proposed")[k + [column]].set_index(k)[column]
        b = dashboard("v1")[k + [column]].set_index(k)[column]
        diff = (pd.to_numeric(a, errors="coerce").fillna(0) - pd.to_numeric(b, errors="coerce").fillna(0)).abs()
        return float(diff.sum())
    return f


CHECKS = [
    Check(f"{SUITE}.grain_unique", "One row per portfolio per reporting month",
          actual=_dupes, expected=lambda: 0.0, tol=0,
          proves="No portfolio-month appears twice, so a column sum is the book total and nothing is double-counted."),
    Check(f"{SUITE}.single_currency", "No portfolio reports in two currencies in one month",
          actual=_multi_ccy, expected=lambda: 0.0, tol=0,
          proves="Case amounts are converted at the portfolio-month's one rate. If this ever fails, that conversion is wrong for the affected rows."),
    Check(f"{SUITE}.same_rows_as_v1", "The query covers exactly the rows of v1 (the retired dashboard's query)",
          actual=_row_diff, expected=lambda: 0.0, tol=0,
          proves="Adding forecasts and case amounts did not add, drop or re-key a single portfolio-month."),
]
for c in SHARED_MONEY + SHARED_COUNTS:
    CHECKS.append(Check(f"{SUITE}.v1_equal.{c}", f"Same as v1, row by row: {c}",
                        actual=_same_as_live(c), expected=lambda: 0.0, tol=0,
                        proves="A regression check: the redesign changed none of the figures the retired dashboard showed, to the cent, on every row."))
CHECKS.append(Check(f"{SUITE}.reconciliation_words", "The Reconciliation control's words match the flag on every row",
                    actual=lambda: float(((dashboard()["reconciliation_status"] == "Reconciled") != dashboard()["is_reconciled_flag"].fillna(False).astype(bool)).sum()),
                    expected=lambda: 0.0, tol=0,
                    proves="Choosing 'Reconciled' in the control shows exactly the reconciled portfolio-months."))


# Servicer group (the manager's rule, 2026-10-12): worked out again here from the warehouse, not from the query, so a
# drift in the query's CASE shows. The manager's rule: Massey = organic UK, Fire = organic Italy,
# Gescobro = organic, legacy or Gescobro-sourced Spain, Cerved = legacy Italy, else Intrum.
SERVICER_SQL = """
SELECT p.portfolio_bk AS portfolio_name,
       CASE WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND MAX(f.country_id) = 'UK' THEN 'Massey'
            WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND MAX(f.country_id) = 'IT' THEN 'Fire'
            WHEN ds.deal_source_name IN ('ORGANIC ORIGINATED', 'LEGACY') AND MAX(f.country_id) = 'ES' THEN 'Gescobro'
            WHEN ds.deal_source_name = 'LEGACY' AND MAX(f.country_id) = 'IT' THEN 'Cerved'
            WHEN ds.deal_source_name = 'GESCOBRO' AND MAX(f.country_id) = 'ES' THEN 'Gescobro'
            ELSE 'Intrum' END AS expected_group
FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY AS f
INNER JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p ON p.portfolio_sk = f.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL_SOURCE AS ds ON ds.deal_source_sk = f.deal_source_sk
GROUP BY p.portfolio_bk, ds.deal_source_name"""
_EXPECTED: dict = {}


def _servicer_mismatches() -> float:
    if not _EXPECTED:
        exp = _lib.datalake.q(SERVICER_SQL, lower=True)
        _EXPECTED["df"] = exp.drop_duplicates("portfolio_name")
    got = dashboard()[["portfolio_name", "servicer_group"]].drop_duplicates()
    m = got.merge(_EXPECTED["df"], on="portfolio_name", how="left")
    return float((m["servicer_group"] != m["expected_group"]).sum())


def _massey() -> float:
    d = dashboard()
    got = sorted(d.loc[d["servicer_group"] == "Massey", "portfolio_name"].unique())
    if d["reporting_month"].max() < pd.Timestamp("2026-06-30"):   # a back-test before Equinox was bought (June 2026)
        return float(got == [])
    return float(got == ["ORG-UK26002-U01/2606", "ORG-UK26003-U01/2606"])


CHECKS += [
    Check(f"{SUITE}.servicer_rule", "Every portfolio's servicer group follows the rule (Massey, Fire, Cerved, Gescobro, else Intrum), from the warehouse",
          actual=_servicer_mismatches, expected=lambda: 0.0, tol=0,
          proves="Deal source and country, read again from the facts, put each portfolio with the servicer that reports it."),
    Check(f"{SUITE}.servicer_massey", "Massey holds exactly the two Arrow Global UK books (Equinox I and II)",
          actual=_massey, expected=lambda: 1.0, tol=0,
          proves="The 48,010 loans the case feed shows Massey reporting are no longer counted as Intrum."),
]
