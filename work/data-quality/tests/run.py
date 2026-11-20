"""Every check on the Servicer Data Quality dashboard, in one command.

    uv run python work/data-quality/tests/run.py              # all checks (~15 min since 2026-10-14: two queries, then Sigma exports)
    uv run python work/data-quality/tests/run.py --no-live    # the SQL checks only

Four kinds of check, each against something written separately from the thing it checks:
  query     the two queries are well formed: one row per key, in scope, the shared CTEs identical
  warehouse the queries' totals equal plain sums over the PROD facts, written here
  servicing where the Servicing dashboard shows the same figure, ours is identical (the user, 2026-10-13)
  live      what the Sigma workbook shows (exported as a viewer sees it) equals the query

Every run is appended to tests/results.csv. A failed check prints what it expected and what it got.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
import pathlib
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import pandas as pd

import datalake as b

HERE = pathlib.Path(__file__).resolve().parent
DQ = HERE.parent
PM_SQL = DQ / "sigma_queries" / "portfolio_months_element.sql"
REF_SQL = DQ / "sigma_queries" / "combined_refs_element.sql"
SERVICING_SQL = DQ.parent / "servicing" / "sigma_queries" / "portfolios_element.sql"
WORKBOOK = json.loads((DQ / "sigma_build" / "workbook.json").read_text())["workbookId"]
RESULTS = HERE / "results.csv"

ROWS: list[dict] = []


def check(cid: str, title: str, ok: bool, got="", expected="", info: bool = False) -> None:
    status = "INFO" if info else ("PASS" if ok else "FAIL")
    ROWS.append({"check_id": cid, "title": title, "status": status, "got": str(got)[:300], "expected": str(expected)[:300]})
    mark = {"PASS": "✓", "FAIL": "✗", "INFO": "·"}[status]
    print(f"  {mark} {cid}: {title}" + ("" if ok and not info else f"\n      got {got}\n      expected {expected}"))


def same(a, b_, tol=0.005) -> bool:
    return bool(np.isclose(float(a), float(b_), rtol=1e-9, atol=tol))


# --- the queries ---------------------------------------------------------------------------------
def load() -> tuple[pd.DataFrame, pd.DataFrame]:
    print("running both queries against PROD (about 3 minutes)…")
    with ThreadPoolExecutor(2) as ex:
        pm, ref = ex.map(lambda p: b.q(str(p), lower=True), [PM_SQL, REF_SQL])
    for df in (pm, ref):
        df["reporting_month"] = pd.to_datetime(df["reporting_month"])
    return pm, ref


def query_checks(pm: pd.DataFrame, ref: pd.DataFrame) -> None:
    print("query")
    dupes = int(pm.duplicated(["portfolio_name", "servicer", "reporting_month"]).sum())
    check("query.portfolio_grain", "One row per portfolio x servicer x month", dupes == 0, dupes, 0)
    keyed = ref[ref.combined_ref != "No Combined Ref"]
    dupes = int(keyed.duplicated(["portfolio_name", "combined_ref", "reporting_month"]).sum())
    check("query.ref_grain", "One row per combined ref x month", dupes == 0, dupes, 0)
    first = min(pm.reporting_month.min(), ref.reporting_month.min())
    check("query.from_jun_2014", "Nothing before Jun 2014 (the manager, 2026-10-13)", first >= pd.Timestamp("2014-06-30"), first.date(), ">= 2014-06-30")
    dim = set(b.q("SELECT portfolio_bk FROM PROD.NPL_COMMON.DIM_PORTFOLIO", lower=True).portfolio_bk)
    out = (set(pm.portfolio_name) | set(ref.portfolio_name)) - dim
    check("query.in_dim_portfolio", "Every portfolio is in DIM_PORTFOLIO", not out, sorted(out)[:5], "none outside")
    pm_text, ref_text = PM_SQL.read_text(), REF_SQL.read_text()
    shared = pm_text[pm_text.index("WITH portfolios_in_scope AS ("):pm_text.index("portfolio_feed AS (\n    -- The Portfolio Feed, summed")].rstrip().rstrip(",")
    check("query.shared_ctes_identical", "The scope and servicer CTEs are word for word the same in both files", shared in ref_text)
    two = pm.groupby(["portfolio_name", "reporting_month"]).servicer.nunique()
    split = sorted(two[two > 1].index.get_level_values(0).unique())
    check("query.split_portfolios", "Portfolios with two servicers (only HEI-GR25001-U04 on 2026-10-13)", split == ["HEI-GR25001-U04/2512"], split, ["HEI-GR25001-U04/2512"], info=split != ["HEI-GR25001-U04/2512"])


def warehouse_checks(pm: pd.DataFrame, ref: pd.DataFrame) -> None:
    """Totals per month from the facts, written independently of both queries."""
    print("warehouse")
    w = b.q("""
        WITH scope AS (SELECT portfolio_sk FROM PROD.NPL_COMMON.DIM_PORTFOLIO)
        SELECT 'portfolio_feed_collections' AS what, period_end_date AS m, SUM(gross_cash_recoveries) AS v
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        WHERE period_end_date BETWEEN '2014-06-30' AND CURRENT_DATE() AND portfolio_sk IN (SELECT portfolio_sk FROM scope) GROUP BY 1, 2
        UNION ALL
        SELECT 'case_feed_collections', LAST_DAY(collection_date), SUM(amount)
        FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION
        WHERE collection_date BETWEEN '2014-06-01' AND CURRENT_DATE() AND portfolio_sk IN (SELECT portfolio_sk FROM scope) GROUP BY 1, 2
        UNION ALL
        -- Cases and balance: open cases only. A case is closed at a month-end when the version the snapshot
        -- points at has a closing date on or before it (DIM_CASE is one row per case version).
        SELECT 'case_feed_cases', s.date_day, COUNT(*)
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        WHERE s.date_day BETWEEN '2014-06-30' AND CURRENT_DATE() AND s.portfolio_sk IN (SELECT portfolio_sk FROM scope) GROUP BY 1, 2
        UNION ALL
        SELECT 'case_feed_open_cases', s.date_day, COUNT_IF(dc.case_sk IS NULL)
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        LEFT JOIN PROD.NPL_COMMON.DIM_CASE AS dc ON dc.case_sk = s.case_sk AND dc.closing_date <= s.date_day
        WHERE s.date_day BETWEEN '2014-06-30' AND CURRENT_DATE() AND s.portfolio_sk IN (SELECT portfolio_sk FROM scope) GROUP BY 1, 2
        UNION ALL
        SELECT 'case_feed_balance', s.date_day, SUM(IFF(dc.case_sk IS NULL, s.outstanding_total, 0))
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        LEFT JOIN PROD.NPL_COMMON.DIM_CASE AS dc ON dc.case_sk = s.case_sk AND dc.closing_date <= s.date_day
        WHERE s.date_day BETWEEN '2014-06-30' AND CURRENT_DATE() AND s.portfolio_sk IN (SELECT portfolio_sk FROM scope) GROUP BY 1, 2
        UNION ALL
        SELECT 'closed_cases_balance', s.date_day, SUM(s.outstanding_total)
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY AS s
        JOIN PROD.NPL_COMMON.DIM_CASE AS dc ON dc.case_sk = s.case_sk AND dc.closing_date <= s.date_day
        WHERE s.date_day BETWEEN '2014-06-30' AND CURRENT_DATE() AND s.portfolio_sk IN (SELECT portfolio_sk FROM scope) GROUP BY 1, 2
        UNION ALL
        SELECT 'portfolio_feed_balance', period_end_date, SUM(total_balance)
        FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        WHERE period_end_date BETWEEN '2014-06-30' AND CURRENT_DATE() AND portfolio_sk IN (SELECT portfolio_sk FROM scope) GROUP BY 1, 2""", lower=True)
    w["m"] = pd.to_datetime(w["m"])
    # Case payments in a month the table has no row for are not shown, by design: the current month (no feed
    # covers it yet) and payments dated before a portfolio's first feed month (Massey's ORG-UK26002 pays from
    # 2021, its case list starts Jan 2026). Compared per portfolio-month over the rows the table has.
    pay = b.q("""SELECT d.portfolio_bk AS portfolio_name, LAST_DAY(c.collection_date) AS m, SUM(c.amount) AS v
                 FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION AS c
                 JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS d ON d.portfolio_sk = c.portfolio_sk
                 WHERE c.collection_date BETWEEN '2014-06-01' AND CURRENT_DATE() GROUP BY 1, 2""", lower=True)
    pay["m"] = pd.to_datetime(pay["m"])
    for name, df in (("portfolio", pm), ("ref", ref)):
        g = df.groupby(["portfolio_name", "reporting_month"]).case_feed_collections.sum(min_count=1).reset_index()
        x = pay.merge(g, left_on=["portfolio_name", "m"], right_on=["portfolio_name", "reporting_month"], how="left")
        shown = x.reporting_month.notna()
        bad = int((~np.isclose(x[shown].v.astype(float), x[shown].case_feed_collections.fillna(0).astype(float), atol=0.01)).sum())
        check(f"warehouse.{name}_case_feed_collections", f"{name} query: case payments equal the fact table on every portfolio-month it shows",
              bad == 0, bad, 0)
        check(f"warehouse.{name}_case_payments_not_shown", f"{name} query: payments in months with no feed row (this month, before the first feed month)",
              True, f"{(~shown).sum()} portfolio-months, {x[~shown].v.sum():,.2f}", "", info=True)
    w = w[w.what != "case_feed_collections"]
    for what in w.what.unique():
        exp = w[w.what == what].set_index("m").v.astype(float)
        for name, df in (("portfolio", pm), ("ref", ref)):
            got = df.groupby("reporting_month")[what].sum().astype(float).reindex(exp.index).fillna(0)
            bad = exp.index[~np.isclose(got, exp, rtol=1e-12, atol=0.01)]
            check(f"warehouse.{name}_{what}", f"{name} query: {what} equals the fact table, every month ({len(exp)} months)",
                  len(bad) == 0, f"{len(bad)} months differ, e.g. {[str(x.date()) for x in bad[:3]]}", "0")
    # The refs of a portfolio add up to its row: portfolio feed always; case feed except Massey (other refs).
    p = pm.groupby(["portfolio_name", "reporting_month"])[["portfolio_feed_collections", "portfolio_feed_balance", "case_feed_cases"]].sum()
    r = ref.groupby(["portfolio_name", "reporting_month"])[["portfolio_feed_collections", "portfolio_feed_balance", "case_feed_cases"]].sum()
    j = p.join(r, rsuffix="_ref", how="inner")
    for col in ("portfolio_feed_collections", "portfolio_feed_balance", "case_feed_cases"):
        bad = int((~np.isclose(j[col].astype(float), j[col + "_ref"].astype(float), atol=0.01)).sum())
        check(f"warehouse.refs_add_up_{col}", f"A portfolio's refs add up to its row: {col}", bad == 0, bad, 0)


def servicing_checks(pm: pd.DataFrame) -> None:
    """The same figure on both dashboards must be the same number (the user, 2026-10-13)."""
    print("servicing")
    sv = b.q(str(SERVICING_SQL), lower=True)
    sv["reporting_month"] = pd.to_datetime(sv["reporting_month"])
    g = pm.groupby(["portfolio_name", "reporting_month"]).agg(
        received=("portfolio_feed_received_flag", "max"), reconciled=("collections_reconciled_flag", "min"),
        case_book=("case_feed_cases", lambda x: x.notna().any()), stopped=("case_feed_status", lambda x: (x == "Stopped").any()),
        case_coll=("case_feed_collections", lambda x: x.sum(min_count=1))).reset_index()
    x = sv.merge(g, on=["portfolio_name", "reporting_month"], how="left")
    check("servicing.portfolios_reporting", f"Every portfolio-month on Servicing ({len(sv)}) is Received here",
          bool(x.received.fillna(False).all()), int((~x.received.fillna(False)).sum()), 0)
    bad = x[x.is_reconciled_flag.astype(bool) != x.reconciled.fillna(False).astype(bool)]
    check("servicing.collections_reconciled", "Collections Reconciled: identical on every portfolio-month",
          bad.empty, f"{len(bad)} differ, e.g. {bad[['portfolio_name', 'reporting_month']].head(3).values.tolist()}", "0")
    mart = b.q("""SELECT p.portfolio_bk AS portfolio_name, m.period_end_date AS reporting_month, m.collected_amount_local_sum, m.cases_on_book_count
                  FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY AS m
                  JOIN PROD.NPL_COMMON.DIM_PORTFOLIO AS p ON p.portfolio_sk = m.portfolio_sk""", lower=True)
    mart["reporting_month"] = pd.to_datetime(mart["reporting_month"])
    y = mart.merge(pm.groupby(["portfolio_name", "reporting_month"])[["case_feed_collections", "case_feed_cases"]].sum(min_count=1).reset_index(),
                   on=["portfolio_name", "reporting_month"], how="left")
    bad = int((~np.isclose(y.collected_amount_local_sum.astype(float), y.case_feed_collections.fillna(0).astype(float), atol=0.01)).sum())
    check("servicing.case_collections", f"Case feed collections equal the Servicing mart's ({len(y)} portfolio-months)", bad == 0, bad, 0)
    # Cases = every case listed, the mart's cases on book exactly; Open Cases leave closed ones out, so never more.
    bad = int((y.cases_on_book_count.fillna(-1).astype(float) != y.case_feed_cases.fillna(-1).astype(float)).sum())
    check("servicing.cases_on_book", "Cases equal the Servicing mart's cases on book", bad == 0, bad, 0)
    z = y.merge(pm.groupby(["portfolio_name", "reporting_month"]).case_feed_open_cases.sum(min_count=1).reset_index(),
                on=["portfolio_name", "reporting_month"], how="left")
    more = int((z.case_feed_open_cases.astype(float) > z.cases_on_book_count.astype(float)).sum())
    check("servicing.open_cases_never_more", "Open Cases are never more than the Servicing mart's cases on book", more == 0, more, 0)
    # Two figures differ by definition, said on the dashboard and in the README: Servicing counts a case feed only
    # once PAYMENTS arrive (its mart is built from payments); this dashboard counts the monthly case list.
    feed = int((x.collected_cases_count.notna() != x.case_book).sum())
    check("servicing.has_case_feed_differs", "Has a case feed: differs by definition (payments vs case list), portfolio-months",
          True, feed, "332 on 2026-10-13", info=True)
    stop = int((x.feed_stopped_flag.astype(bool) != x.stopped).sum())
    check("servicing.feed_stopped_differs", "Case feed stopped: differs by definition (payments stopped vs case list stopped)",
          True, stop, "28 on 2026-10-13", info=True)


# --- the live workbook ---------------------------------------------------------------------------
def _sigma(*args: str, body: str | None = None) -> str:
    cmd = ["sigma", "-p", "brocc", "api", *args] + (["--body", body] if body else [])
    return subprocess.run(cmd, capture_output=True, text=True, timeout=600).stdout


def export(element_id: str, params: dict | None = None) -> pd.DataFrame:
    """What an element shows a viewer with those controls set (export -> poll -> CSV)."""
    body = {"elementId": element_id, "format": {"type": "csv"}}
    if params:
        body["parameters"] = params
    qid = json.loads(_sigma("workbooks", "export", "--params", json.dumps({"workbookId": WORKBOOK}), body=json.dumps(body)))["queryId"]
    for _ in range(300):
        time.sleep(2)
        out = _sigma("query", "download", "get", "--params", json.dumps({"queryId": qid}))
        if out.strip() and out.strip() != "null":
            df = pd.read_csv(io.StringIO(out))
            unknown = [c for c in df.columns if df[c].astype(str).str.startswith("Unknown column").any()]
            if unknown:
                raise ValueError(f"{element_id} has unresolved formulas in {unknown}")
            return df
    raise TimeoutError(element_id)


def live_checks(pm: pd.DataFrame, ref: pd.DataFrame) -> None:
    print("live (Sigma exports, about 1 minute each, run side by side)")
    jobs = {"tiles": ("t_tiles", None), "port": ("t_port", None), "ref": ("t_ref", None),
            "port3": ("t_port", {"Quick-Filter-Months": "Last 3 Months"}), "cerved": ("t_port", {"Servicer": "Cerved"})}
    jobs |= {k: (k, None) for k in ("k_pf", "k_cf", "k_ov", "k_cs", "k_bs", "k_fc")}
    with ThreadPoolExecutor(6) as ex:
        got = dict(zip(jobs, ex.map(lambda j: export(*j), jobs.values())))
    last = pm.reporting_month.max()   # last month: the page opens on it even while it is arriving
    a = pm[(pm.servicer == "Intrum") & (pm.reporting_month == last)].set_index("portfolio_name")
    t = got["port"].set_index("Portfolio Name")
    check("live.port_rows", f"By Portfolio lists Intrum's portfolios in {last:%b %Y}", set(t.index) == set(a.index), len(t), len(a))
    for column, sql in (("Collections Portfolio Feed", "portfolio_feed_collections"), ("Collections Case Feed (All Cases)", "case_feed_collections"),
                        ("Balance Portfolio Feed", "portfolio_feed_balance"), ("Balance Case Feed (Open Cases)", "case_feed_balance"),
                        ("Cases (Open)", "case_feed_open_cases"), ("Cases (All)", "case_feed_cases"),
                        ("Purchase Price", "purchase_price")):
        x, e = pd.to_numeric(t[column], errors="coerce"), a[sql].reindex(t.index).astype(float)
        bad = int((~np.isclose(x.fillna(-1e18), e.fillna(-1e18), atol=0.005)).sum())
        check(f"live.port_{sql}", f"By Portfolio: {column} equals the query, every row", bad == 0, bad, 0)
    e = (a.case_feed_balance.fillna(0) + a.closed_cases_balance.fillna(0)).where(a.case_feed_balance.notna()).reindex(t.index).astype(float)
    bad = int((~np.isclose(pd.to_numeric(t["Balance Case Feed (All Cases)"], errors="coerce").fillna(-1e18), e.fillna(-1e18), atol=0.005)).sum())
    check("live.port_all_cases_balance", "By Portfolio: Balance Case Feed (All Cases) = open + closed, every row", bad == 0, bad, 0)
    bad = int(((t["Collections"] == "Reconciled") != a.collections_reconciled_flag.reindex(t.index).astype(bool)).sum())
    check("live.port_reconciled", "By Portfolio: Reconciled exactly where the query's flag (the Servicing rule) says so", bad == 0, bad, 0)
    bad = int((t["Case Feed"] != a.case_feed_status.reindex(t.index)).sum())
    check("live.port_case_feed", "By Portfolio: Case Feed status equals the query", bad == 0, bad, 0)
    # Tiles: passing / applicable, recomputed here from the exported table.
    # Not Yet Received (a report not due until the 15th) is left out of every tile; a tile none of whose
    # portfolios is due reads Not Yet Due.
    n = len(t)
    def tile(column, passing, counted=None):
        s = t[column]
        of = int(s.isin(counted).sum()) if counted else int((s != "Not Yet Received").sum())
        if of == 0 and (s == "Not Yet Received").any():
            return "Not Yet Due"
        ok = int(s.isin(passing).sum())
        return f"{ok} / {of}  ·  {int(100 * ok / of + 0.5)}%"   # Sigma rounds half up
    expect = {"k_pf": tile("Portfolio Feed", ["Received"]), "k_cf": tile("Case Feed", ["Received"]),
              "k_ov": (lambda ok: f"{ok} / {n}  ·  {int(100 * ok / n + 0.5)}%")(int((a.months_overlap_to_date == a.months_reported_to_date).sum())),
              "k_cs": tile("Collections", ["Reconciled"], ["Reconciled", "Not Reconciled", "No Payments", "Payments in Under 80% of Months"]),
              "k_bs": tile("Balance", ["Reconciled"], ["Reconciled", "Not Reconciled"]),
              "k_fc": tile("Forecast", ["Received"])}
    # Not Yet Received only where the query says the report is not due yet.
    due = a.portfolio_feed_due_flag.reindex(t.index).astype(bool)
    bad = int(((t["Portfolio Feed"] == "Not Yet Received") & due).sum() + ((t["Portfolio Feed"] != "Not Yet Received") & ~due & ~a.portfolio_feed_received_flag.reindex(t.index).astype(bool)).sum())
    check("live.not_yet_received", "Portfolio Feed reads Not Yet Received exactly where a report is missing and not due", bad == 0, bad, 0)
    for k, e in expect.items():
        v = str(got[k].iloc[0, 0])
        check(f"live.tile_{k}", f"Tile {k} reads {e}", v == e, v, e)
    w = pm[(pm.servicer == "Intrum") & (pm.reporting_month > last - pd.offsets.MonthEnd(3)) & (pm.reporting_month <= last)]
    e = w.groupby("portfolio_name").portfolio_feed_collections.sum()
    t3 = got["port3"].set_index("Portfolio Name")
    bad = int((~np.isclose(pd.to_numeric(t3["Collections Portfolio Feed"]), e.reindex(t3.index).astype(float), atol=0.005)).sum())
    check("live.last_3_months", "L3M: collections are the sum of the three months, every row", bad == 0, bad, 0)
    # In step with the Servicing dashboard: over L3M a portfolio is Reconciled only if every month reported was.
    every = w[w.portfolio_feed_received_flag.astype(bool)].groupby("portfolio_name").collections_reconciled_flag.min().astype(bool)
    bad = int(((t3["Collections"] == "Reconciled") != every.reindex(t3.index).fillna(False)).sum())
    check("live.l3m_reconciled", "L3M: Reconciled exactly where every month reported is reconciled (the Servicing flag)", bad == 0, bad, 0)
    r = got["ref"]
    exp_refs = len(ref[(ref.servicer == "Intrum") & (ref.reporting_month == last)])
    check("live.ref_rows", "By Combined Ref lists every Intrum ref of the month", len(r) == exp_refs, len(r), exp_refs)
    c = got["cerved"]
    check("live.cerved_not_ours", "Cerved's collections read Not Loaded by Brocc, never Not Reconciled",
          bool((c["Collections"] == "Not Loaded by Brocc").all()), c["Collections"].unique().tolist(), ["Not Loaded by Brocc"])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-live", action="store_true")
    args = ap.parse_args()
    pm, ref = load()
    query_checks(pm, ref)
    warehouse_checks(pm, ref)
    servicing_checks(pm)
    if not args.no_live:
        live_checks(pm, ref)
    run_at = dt.datetime.now().isoformat(timespec="seconds")
    new = not RESULTS.exists()
    with RESULTS.open("a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["run_at", "workbook", "check_id", "title", "status", "got", "expected"])
        if new:
            w.writeheader()
        for row in ROWS:
            w.writerow({"run_at": run_at, "workbook": WORKBOOK, **row})
    fails = [r for r in ROWS if r["status"] == "FAIL"]
    print(f"\n{len(ROWS) - len(fails)} of {len(ROWS)} passed or informational; {len(fails)} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
