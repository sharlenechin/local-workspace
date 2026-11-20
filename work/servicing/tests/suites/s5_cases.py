"""5 · Cases - counts and euro amounts, against the dbt mart.

Source: MART_NPL_SERVICING_AGG_CASES_MONTHLY. Names match the mart:
collected_cases_* for what cases did in the month, cases_* for the book.

    behaviour                 LM-2  LM-1  LM0
    first_collection           -     -    yes   no collection before, ever
    three_consecutive_months  yes   yes   yes
    jitter_in                 yes    no   yes
    new                        no    no   yes
    jitter_out                 no   yes    no   counted on the quiet month
    lost                      yes   yes    no   counted on the first quiet month

Case amounts are in each case's local currency in the mart; the dashboard
converts them at the portfolio-month's rate (see structure.single_currency).
"""
from __future__ import annotations

from _lib import FX_FLOW, Check, actuals_keys, cap, col_sum, dashboard, warehouse

SUITE = "cases"


def _mart(column: str) -> str:
    # Only portfolio-months the servicer reported, as the dashboard (and _mart_eur) does: a case feed can arrive before
    # its portfolio report (Massey, Sep 2026: 29,894 collected cases, no report yet), and the dashboard shows that
    # portfolio-month once the report lands (2026-10-14).
    return f"""SELECT SUM(m.{column}) FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS m
      INNER JOIN (SELECT DISTINCT portfolio_sk, period_end_date FROM ({actuals_keys()})) AS k
        ON k.portfolio_sk = m.portfolio_sk AND k.period_end_date = m.period_end_date
      WHERE m.period_end_date <= {cap()}"""


def _mart_eur(column: str) -> str:
    """Mart amount converted at the rate of the currency the portfolio reported in that month."""
    return f"""SELECT SUM(m.{column} * fx.rate)
      FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS m
      INNER JOIN (SELECT DISTINCT portfolio_sk, period_end_date, currency_id FROM ({actuals_keys()})) AS k
        ON k.portfolio_sk = m.portfolio_sk AND k.period_end_date = m.period_end_date
      LEFT JOIN {FX_FLOW} AS fx ON fx.cid = k.currency_id AND fx.m = k.period_end_date"""


COUNTS = [
    ("collected_cases_count", "collected_cases_count", "Collected cases"),
    ("collected_cases_first_collection_count", "collected_cases_first_collection_count", "New (dbt first collection)"),
    ("collected_cases_consistent_3m_count", "collected_cases_three_consecutive_months_count", "Three consecutive months"),
    ("collected_cases_jitter_in_count", "collected_cases_jitter_in_count", "Jitter in"),
    ("collected_cases_jitter_out_count", "collected_cases_jitter_out_count", "Jitter out"),
    ("collected_cases_new_count", "collected_cases_new_count", "Fresh plus New (dbt new)"),
    ("collected_cases_lost_count", "collected_cases_lost_count", "Lost"),
    ("cases_on_book_count", "cases_on_book_count", "Cases on book"),
    ("cases_ever_collected_count", "cases_ever_collected_count", "Cases ever collected"),
]
AMOUNTS = [
    ("collected_cases_amount_sum", "collected_amount_local_sum", "Collected cases, EUR"),
    ("collected_cases_new_amount_sum", "collected_amount_local_new_sum", "New, EUR"),
    ("collected_cases_lost_last_month_amount_sum", "collected_amount_local_lost_last_month_sum", "Lost, last-month EUR"),
    ("collected_cases_jitter_out_last_month_amount_sum", "collected_amount_local_jitter_out_last_month_sum", "Jitter out, last-month EUR"),
]


def _rows_where(cond) -> float:
    return float(cond(dashboard()).sum())


CHECKS = [
    Check(f"{SUITE}.{dash}", label, actual=lambda d=dash: col_sum(d), expected=lambda m=mart: warehouse(_mart(m)), tol=0,   # counts reconcile exactly
          proves=f"'{label}' on the Cases page is the mart's own count, unaltered.")
    for dash, mart, label in COUNTS
]
CHECKS += [
    Check(f"{SUITE}.{dash}", label, actual=lambda d=dash: col_sum(d), expected=lambda m=mart: warehouse(_mart_eur(m)),
          proves=f"'{label}' converts the mart's local amounts at the right month's rate.")
    for dash, mart, label in AMOUNTS
]
CHECKS += [
    Check(f"{SUITE}.book_identity", "Ever collected + never collected = cases on book, every row",
          actual=lambda: _rows_where(lambda d: (d.cases_ever_collected_count.fillna(0) + d.cases_never_collected_count.fillna(0)
                                                 - d.cases_on_book_count.fillna(0)).abs() > 0),
          expected=lambda: 0.0, tol=0,
          proves="The mart neither double-counts nor drops a case. This breaks before any total does."),
    Check(f"{SUITE}.first_within_new", "New (first collection) never exceeds dbt new (New plus Fresh), every row",
          actual=lambda: _rows_where(lambda d: d.collected_cases_first_collection_count.fillna(0) > d.collected_cases_new_count.fillna(0)),
          expected=lambda: 0.0, tol=0,
          proves="A first-ever collection has nothing in the two months before it, so it is always in dbt's new too. Fresh on the dashboard is dbt's new minus New."),
    Check(f"{SUITE}.blank_means_no_feed", "Portfolios without a case feed read blank, never zero",
          actual=lambda: _rows_where(lambda d: ~d.have_loan_detail_flag.fillna(False).astype(bool) & d.collected_cases_count.fillna(-1).eq(0)),
          expected=lambda: 0.0, tol=0,
          proves="A portfolio with no feed reads blank ('no data'), never zero ('nobody paid')."),
    Check(f"{SUITE}.feed_share_of_collections", "Case-feed EUR on reconciled rows is within 5% of the portfolio report",
          actual=lambda: col_sum("collected_cases_amount_sum", where=lambda d: d.is_reconciled_flag.fillna(False).astype(bool)),
          expected=lambda: col_sum("collections_sum", where=lambda d: d.is_reconciled_flag.fillna(False).astype(bool)),
          tol=0.05,
          proves="Where a portfolio reconciles, the two feeds agree (measured 98.2% on 2026-10-08). Unreconciled rows are not tested: that gap is the point of the flag."),
    # Italy's case feed keeps one payment per case (dbt bug, 2026-10-14), so it is marked Not reconciled by hand.
    Check(f"{SUITE}.italy_never_reconciled", "No Italian portfolio-month is Reconciled while the dbt payment-id bug stands",
          actual=lambda: _rows_where(lambda d: d.country_name.eq("Italy") & d.is_reconciled_flag.fillna(False).astype(bool)),
          expected=lambda: 0.0, tol=0,
          proves="Its euros can pass the 10% test while every payer reads as New; remove with the SQL guard once dbt is fixed."),
]


# ---- completeness: every behaviour the mart defines reaches the dashboard ---------
MART_YML = (__import__("_lib").SERVICING.parents[2] / "brocc-data" / "transformation" / "dbt" / "models"
            / "marts" / "npl_common" / "marts" / "models.yml")


def _mart_columns_missing() -> float:
    """Mart columns (read from the dbt docs in brocc-data) that the dashboard query never reads.
    Read-only: brocc-data is never written."""
    import re
    from _lib import PROPOSED_SQL
    if not MART_YML.exists():
        raise FileNotFoundError(f"{MART_YML} not found - clone brocc-data beside local-workspace")
    text = MART_YML.read_text()
    block = text[text.index("name: mart_npl_servicing_agg_cases_monthly"):]
    nxt = re.search(r"\n  - name: ", block[1:])
    block = block[: nxt.start() + 1] if nxt else block
    cols = re.findall(r"\n      - name: (\w+)", block)
    sql = PROPOSED_SQL.read_text()
    missing = [c for c in cols if not re.search(rf"\b{c}\b", sql)]
    if missing:
        print(f"      mart columns not in the query: {missing}")
    return float(len(missing))


CHECKS.append(Check(f"{SUITE}.mart_columns_complete", "Every column of the dbt cases mart is read by the query",
                    actual=_mart_columns_missing, expected=lambda: 0.0, tol=0,
                    proves="No behaviour is left behind: 19 of 19 mart columns on 2026-10-09 (every collected_cases_* behaviour, "
                           "their euro, cases on book, ever and never collected). If dbt adds a behaviour, this fails until the query carries it."))


# ---- the mart's own logic, recomputed without its window frames (2026-10-13) ---------
# The user asked whether the mart is right, in particular RANGE BETWEEN INTERVAL '1 month' PRECEDING. This rebuilds every
# behaviour by joining each case-month to the same case one and two calendar months earlier, and compares with the mart.
VERIFY_SQL = __import__("_lib").SERVICING / "tests" / "verify_case_behaviour.sql"


def _mart_logic_mismatches() -> float:
    diffs = "d_collected, d_first, d_three, d_jitter_in, d_new, d_lost"
    sql = f"SELECT COUNT_IF(ABS(d_amount) > 0.005 OR ABS(d_amount_three) > 0.005 OR {' OR '.join(f'{d} <> 0' for d in diffs.split(', '))}) FROM ({VERIFY_SQL.read_text()})"
    return warehouse(sql)


CHECKS.append(Check(f"{SUITE}.mart_logic_recomputed", "The cases mart's behaviours, recomputed by plain joins instead of window frames, match on every portfolio-month",
                    actual=_mart_logic_mismatches, expected=lambda: 0.0, tol=0,
                    proves="Collected, New, Fresh, back after one quiet month, Three Consecutive Months, Lost and their euro all agree "
                           "(1,307 portfolio-months on 2026-10-13): the mart's RANGE frames pick exactly the previous calendar months."))
