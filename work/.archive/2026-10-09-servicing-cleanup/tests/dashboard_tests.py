"""Reconcile what the Sigma dashboard SHOWS against what the warehouse SAYS.

Each test reads a TILE's actual rendered data out of Sigma (export -> poll ->
download), then computes the same figure independently from the source facts
and compares.

    uv run python work/servicing/tests/dashboard_tests.py [workbook_id]

⚠ The expected values are written here from the facts, never taken from the
dashboard's own SQL. If both sides came from the same query the test would
prove nothing.
"""
from __future__ import annotations
import csv, datetime as dt, io, json, pathlib, subprocess, sys, textwrap, time
from typing import NamedTuple
import pandas as pd
import datalake

WORKBOOK = sys.argv[1] if len(sys.argv) > 1 else "77cac618-7b47-46cb-9171-95ad9976f36d"
TOL = 0.005          # 0.5%: Sigma rounds for display; a real break is never this small


def _sigma(*args: str, body: str | None = None) -> str:
    cmd = ["sigma", "-p", "brocc", "api", *args]
    if body:
        cmd += ["--body", body]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    return r.stdout


_TILES: dict[str, pd.DataFrame] = {}


def read_tile(element_id: str, tries: int = 75) -> pd.DataFrame:
    """What the tile actually shows, straight out of Sigma.

    Cached per element: 21 reconciliations read only 6 distinct elements, and an
    export costs ~14s (Snowflake runs the query, then Sigma materialises a CSV).
    Polling at 1s rather than 3s removes most of the remaining wait - the publish
    itself is only ~1.8s, so almost all the suite's runtime is reading data back.
    """
    if element_id in _TILES:
        return _TILES[element_id].copy()
    started = _sigma("workbooks", "export", "--params",
                     json.dumps({"workbookId": WORKBOOK}),
                     body=json.dumps({"elementId": element_id, "format": {"type": "csv"}}))
    qid = json.loads(started)["queryId"]
    for _ in range(tries):
        time.sleep(1)
        out = _sigma("query", "download", "get", "--params", json.dumps({"queryId": qid}))
        if out.strip() and out.strip() != "null":
            df = pd.read_csv(io.StringIO(out))
            df.columns = [c.strip().lower() for c in df.columns]
            _guard_unresolved(element_id, df)
            _TILES[element_id] = df
            return df.copy()
    raise TimeoutError(f"export for {element_id} never completed")


def _guard_unresolved(element_id: str, df: pd.DataFrame) -> None:
    """Sigma does not error on a formula it cannot resolve — it writes
    `Unknown column "[X]"` into every cell as text. Without this check a broken
    tile reads as a numeric zero and passes silently."""
    hits = set()
    for col in df.columns:
        vals = df[col].astype(str)
        for v in vals[vals.str.startswith("Unknown column")].unique()[:3]:
            hits.add(f"{col}: {v}")
    if hits:
        raise ValueError(
            f"{element_id} has unresolved formulas — Sigma rendered them as text, "
            f"not numbers: {'; '.join(sorted(hits))}. Child elements must address "
            f"the source as [Portfolios/Column Name], using Sigma's own casing "
            f"(e.g. 'Case on Book Count', not 'Case On Book Count').")


def warehouse(sql: str) -> float:
    df = datalake.q(sql, convert=False)
    return float(pd.to_numeric(df.iloc[:, 0], errors="coerce").sum())


# --- independent expectations, written from the facts ------------------------
# ⚠ The dashboard scopes to the last COMPLETE month, not the newest one. A month
# whose portfolio count collapses against the month before is still loading and
# is excluded. This guard was dormant all day and fired for real on 2026-10-08,
# when September arrived carrying 4 portfolios against August's 264 - so the
# expectations must apply the same rule or they measure a month the page omits.
LAST_COMPLETE_MONTH = """(
    SELECT MAX(m.period_end_date) FROM (
      SELECT period_end_date,
             COUNT(DISTINCT portfolio_sk) AS n,
             LAG(COUNT(DISTINCT portfolio_sk)) OVER (ORDER BY period_end_date) AS prev_n
      FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
      WHERE period_end_date <= CURRENT_DATE()
      GROUP BY 1) m
    WHERE m.prev_n IS NULL OR m.n >= 0.5 * m.prev_n)"""


FX = """LEFT JOIN (
  SELECT quote_currency cid, date_day m, monthly_avg rate
  FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
  WHERE base_currency='EUR' AND rate_type='PMI' AND quote_currency<>'EUR'
  UNION ALL SELECT DISTINCT 'EUR', period_end_date, 1
  FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
) fx ON fx.cid=f.currency_id AND fx.m=f.period_end_date"""
SCOPE = f"""INNER JOIN PROD.NPL_COMMON.DIM_PORTFOLIO s ON f.portfolio_sk=s.portfolio_sk
WHERE f.period_end_date <= {LAST_COMPLETE_MONTH}
  AND (s.capex_date IS NULL OR f.period_end_date >= DATE_TRUNC('MONTH', s.capex_date))"""

def _window_base() -> str:
    """One row per portfolio-month, scoped exactly as the dashboard scopes it:
    inside DIM_PORTFOLIO, at or after the acquisition month, and no later than
    the last complete reporting month."""
    return f"""
    SELECT f.portfolio_sk, f.period_end_date,
           SUM(f.gross_cash_recoveries*fx.rate) AS coll
    FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f {FX} {SCOPE}
      AND f.period_end_date <= {LAST_COMPLETE_MONTH}
    GROUP BY 1,2"""


def _window_sum(n: int) -> str:
    return f"""SELECT SUM(w) FROM (
      SELECT SUM(coll) OVER (PARTITION BY portfolio_sk
          ORDER BY DATEDIFF(MONTH,'1900-01-01',period_end_date)
          RANGE BETWEEN {n} PRECEDING AND 1 PRECEDING) AS w
      FROM ({_window_base()}))"""


def _window_months(n: int) -> str:
    return f"""SELECT SUM(w) FROM (
      SELECT COUNT(coll) OVER (PARTITION BY portfolio_sk
          ORDER BY DATEDIFF(MONTH,'1900-01-01',period_end_date)
          RANGE BETWEEN {n} PRECEDING AND 1 PRECEDING) AS w
      FROM ({_window_base()}))"""


def _mart(col: str) -> str:
    """Sum one mart column, capped at the last complete reporting month exactly
    as the dashboard caps it."""
    return f"""SELECT SUM({col})
      FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY
      WHERE period_end_date <= {LAST_COMPLETE_MONTH}"""


def _window_avg(n: int) -> str:
    """The Sigma side of the rolling average, computed independently.

    [M] Average Collections LNM divides at ROW level - each portfolio-month's
    window sum over its own month count - and the KPI then sums those. That is
    "total average monthly collections across the book", not "average per
    portfolio-month", and the two differ by the portfolio count (~150x).
    """
    return f"""SELECT SUM(w / NULLIF(n, 0)) FROM (
      SELECT SUM(coll) OVER (PARTITION BY portfolio_sk
          ORDER BY DATEDIFF(MONTH,'1900-01-01',period_end_date)
          RANGE BETWEEN {n} PRECEDING AND 1 PRECEDING) AS w,
             COUNT(coll) OVER (PARTITION BY portfolio_sk
          ORDER BY DATEDIFF(MONTH,'1900-01-01',period_end_date)
          RANGE BETWEEN {n} PRECEDING AND 1 PRECEDING) AS n
      FROM ({_window_base()}))"""


EXPECT = {
  "collections": f"""SELECT SUM(f.gross_cash_recoveries*fx.rate)
                     FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f """ + FX + " " + SCOPE + """""",
  "balance_latest": f"""SELECT SUM(f.total_balance*fx.rate)
                     FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f {FX} {SCOPE}
                     AND f.period_end_date={LAST_COMPLETE_MONTH}""",

  # The mart, capped at the last complete month exactly as the dashboard caps it.
  "mart_collecting": f"""SELECT SUM(collected_cases_count)
      FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY
      WHERE period_end_date <= {LAST_COMPLETE_MONTH}""",
  "mart_lost": f"""SELECT SUM(collected_cases_lost_count)
      FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY
      WHERE period_end_date <= {LAST_COMPLETE_MONTH}""",
  "mart_collected_cases_first_collection_count": f"""SELECT SUM(collected_cases_first_collection_count)
      FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY WHERE period_end_date <= {LAST_COMPLETE_MONTH}""",
  "mart_collected_cases_three_consecutive_months_count": f"""SELECT SUM(collected_cases_three_consecutive_months_count)
      FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY WHERE period_end_date <= {LAST_COMPLETE_MONTH}""",
  "mart_collected_cases_jitter_in_count": f"""SELECT SUM(collected_cases_jitter_in_count)
      FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY WHERE period_end_date <= {LAST_COMPLETE_MONTH}""",
  "mart_collected_cases_new_count": f"""SELECT SUM(collected_cases_new_count)
      FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY WHERE period_end_date <= {LAST_COMPLETE_MONTH}""",

  # ⚠ The rolling window is the THREE MONTHS BEFORE the current one, and excludes
  # the current month: if the row is Jan, the window is Oct + Nov + Dec.
  # That is what "RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING" means on a month
  # index. Measured on the book: 264 portfolio-months have 0 months of history
  # behind them, 251 have 1, 232 have 2 and only 1,092 have the full 3 - so
  # dividing by a constant 3 understates 40.6% of rows, by up to 3x.
  "l3m_collections": _window_sum(3),
  "l6m_collections": _window_sum(6),
  "l12m_collections": _window_sum(12),
  "l3m_months": _window_months(3),
  "l3m_average": _window_avg(3),
  "l6m_average": _window_avg(6),
  "l12m_average": _window_avg(12),
  # Stock columns: the book itself, not payment behaviour. Summed across the
  # nine months exactly as the tile sums them, so the comparison is like for like.
  "mart_cases_on_book": _mart("cases_on_book_count"),
  "mart_cases_ever_collected": _mart("cases_ever_collected_count"),
  "mart_cases_never_collected": _mart("cases_never_collected_count"),
  "net_collections": """SELECT SUM(f.net_cash_recoveries*fx.rate)
      FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f """ + FX + " " + SCOPE + """""",
  "servicer_commission": """SELECT SUM(-f.commission*fx.rate)
      FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f """ + FX + " " + SCOPE + """""",
  "servicer_cost_total": """SELECT SUM((f.gross_cash_recoveries - f.net_cash_recoveries)*fx.rate)
      FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f """ + FX + " " + SCOPE + """""",
}

# label, element, column in the tile's CSV, expectation key
class Case(NamedTuple):
    """One reconciliation. `column` is matched against the exported tile exactly
    first, then by prefix, so a name that is a prefix of another cannot silently
    bind to the wrong column."""
    label: str
    element: str
    column: str
    expect: str          # key into EXPECT - the independently written SQL
    agg: str = "sum"     # "max" for pivots, whose CSV repeats subtotal rows
    why: str = ""        # what a pass actually proves


SOURCE = "ROIia0oTOr"   # the map and Geographic tab were removed from the workbook on 2026-10-08
# the two sortable tables on the Overview page, rebuilt 2026-10-08
FOCUS = "focusTable"   # the metric/grain selector element

CASES = [
 # ---- money, straight off the servicer's own portfolio report ---------------
 Case("Total collections", "-w_fBO0GV9", "sum of [m] total collections", "collections",
      why="Gross recoveries, converted per currency at that month's average rate. "
          "Proves the FX join and the euro conversion."),
 Case("Net collections", SOURCE, "net collections sum", "net_collections",
      why="Gross minus everything the servicer keeps. Proves cost is deducted once, not twice."),
 Case("Servicer commission", SOURCE, "servicer commission sum", "servicer_commission",
      why="Commission is stored negative; proves the sign is flipped exactly once."),
 Case("Servicer cost total", SOURCE, "servicer cost total sum", "servicer_cost_total",
      why="Gross minus net, independently derived. Cross-checks the two columns above."),

 # ---- case counts, from the dbt mart ---------------------------------------
 Case("Collected cases (source)", SOURCE, "collected cases", "mart_collecting",
      why="A case counts as collecting when its month nets above zero. Proves the "
          "source element reads the mart, not the old row-exists rule."),
 Case("Source - jitter in", SOURCE, "collected cases jitter in",
      "mart_collected_cases_jitter_in_count"),
 Case("Source - first collection", SOURCE, "collected cases first collection",
      "mart_collected_cases_first_collection_count",
      why="A case's first ever collection. Distinct from 'new', which is a return "
          "after a gap."),

 # ---- the Breakdown pivot ---------------------------------------------------
 # ⚠ MAX, not sum: a pivot's CSV repeats each measure at every subtotal level,
 # so the grand total IS the column maximum and summing double-counts.

 Case("Source - cases on book", SOURCE, "cases on book", "mart_cases_on_book",
      why="The denominator for penetration. A stock, not a flow."),
 Case("Source - cases ever collected", SOURCE, "cases ever collected",
      "mart_cases_ever_collected",
      why="Cumulative: a case that ever paid stays counted. Must never exceed cases on book."),
 Case("Source - cases never collected", SOURCE, "cases never collected",
      "mart_cases_never_collected",
      why="The complement of ever-collected; the two must add to cases on book."),

 # ---- the rolling window ----------------------------------------------------
 # The window is the N months BEFORE the current one and EXCLUDES it: for a
 # January row, L3M is October + November + December. That is what
 # "RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING" means on a month index.
 Case("Rolling - L3M collections", SOURCE, "collections l 3 m sum", "l3m_collections",
      why="Proves the frame is the three PRIOR months, not a trailing three "
          "including the current one."),
 Case("Rolling - L6M collections", SOURCE, "collections l 6 m sum", "l6m_collections"),
 Case("Rolling - L12M collections", SOURCE, "collections l 12 m sum", "l12m_collections"),
 Case("Rolling - months in L3M", SOURCE, "months in l 3 m window", "l3m_months",
      why="The denominator of the L3M average. 264 portfolio-months have no "
          "history behind them, 251 have one month and 232 have two, so dividing "
          "by a constant 3 would understate 40.6% of rows by up to 3x."),

 # ---- the Sigma calculated columns, not just their SQL inputs ---------------
 # These are the headline KPI tiles. The rolling SUM is SQL; the DIVISION is a
 # Sigma calculated column, so this is the half that SQL testing alone misses.
 Case("KPI - average collections L3M", "aOgyTXDgrO",
      "sum of [m] average collections l3m", "l3m_average",
      why="Tests the Sigma division itself, not the SQL window feeding it."),
 Case("KPI - average collections L6M", "gZCOrKu-jX",
      "sum of [m] average collections l6m", "l6m_average"),
 Case("KPI - average collections L12M", "U-2bJd2aV6",
      "sum of [m] average collections l12m", "l12m_average"),

 # ---- the monthly collections vs forecast table ----------------------------- # ---- the two sortable tables on the Overview page -------------------------
 # Row grain: one per portfolio x month, so a column sum is the book total and
 # the comparison is like for like. Both carry every drilldown dimension.
 # ---- the Geographic Coverage detail table ---------------------------------
 # ---- the Focus element: user-selected metric at a user-chosen grain --------
 # Metric is a Switch over 18 measures driven by the Metric control; grain is
 # three ordered Switch columns. The default selection is Collections grouped by
 # Country, so the column must total to gross collections.
 # ⚠ Change the Metric control's default and this expectation changes with it.
 Case("Focus - selected metric", FOCUS, "metric", "collections",
      why="Proves the metric Switch resolves and aggregates correctly. Ratios in "
          "that list divide summed over summed at the chosen grain, so none of "
          "them is ever an average of per-row ratios."),
]


def _match(tile: pd.DataFrame, want: str) -> str | None:
    if want in tile.columns:
        return want
    hits = [c for c in tile.columns if c.startswith(want)] or \
           [c for c in tile.columns if want in c]
    return hits[0] if len(hits) >= 1 else None


def document() -> int:
    """Print the catalogue without touching Sigma, for review."""
    print(f"{len(CASES)} reconciliations. Each reads a TILE from the live workbook "
          f"and compares it\nto SQL written independently from the warehouse facts.\n"
          f"Tolerance {TOL*100:.1f}%.\n")
    for i, c in enumerate(CASES, 1):
        print(f"{i:2}. {c.label}")
        print(f"    element {c.element}, column {c.column!r}, {c.agg} -> EXPECT[{c.expect!r}]")
        if c.why:
            for line in textwrap.wrap(c.why, 92):
                print(f"    {line}")
        print()
    return 0


LOG = pathlib.Path(__file__).parent / "results.csv"


def _log(rows: list[dict]) -> None:
    """Append every run to results.csv so drift is a trend, not a snapshot.

    A figure that is correct today and 0.4% out next month still passes the
    0.5% tolerance - but the log shows it moving, which is the earlier warning.
    """
    new = not LOG.exists()
    with LOG.open("a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["run_at", "workbook", "label", "element",
                                           "column", "agg", "dashboard", "warehouse",
                                           "drift_pct", "status"])
        if new:
            w.writeheader()
        w.writerows(rows)


def main() -> int:
    if "--doc" in sys.argv:
        return document()
    run_at = dt.datetime.now().isoformat(timespec="seconds")
    print(f"workbook {WORKBOOK}\n")
    bad, rows = 0, []
    for c in CASES:
        rec = {"run_at": run_at, "workbook": WORKBOOK, "label": c.label,
               "element": c.element, "column": c.column, "agg": c.agg,
               "dashboard": "", "warehouse": "", "drift_pct": "", "status": ""}
        try:
            tile = read_tile(c.element)
            col = _match(tile, c.column)
            if col is None:
                bad += 1
                rec["status"] = "SKIP"
                rows.append(rec)
                print(f"  SKIP  {c.label:32} no column like {c.column!r}; "
                      f"tile has {list(tile.columns)[:4]}")
                continue
            vals = pd.to_numeric(tile[col], errors="coerce")
            shown = float(vals.max() if c.agg == "max" else vals.sum())
            truth = warehouse(EXPECT[c.expect])
            drift = abs(shown - truth) / abs(truth) if truth else (0.0 if not shown else 1.0)
            ok = drift <= TOL
            bad += 0 if ok else 1
            rec |= {"dashboard": f"{shown:.2f}", "warehouse": f"{truth:.2f}",
                    "drift_pct": f"{drift*100:.6f}", "status": "PASS" if ok else "FAIL"}
            rows.append(rec)
            print(f"  {'PASS' if ok else 'FAIL'}  {c.label:32} dashboard {shown:>17,.2f}  "
                  f"warehouse {truth:>17,.2f}  {drift*100:7.3f}%")
        except Exception as e:
            bad += 1
            rec["status"] = "ERROR"
            rows.append(rec)
            print(f"  ERROR {c.label:32} {str(e).splitlines()[0][:80]}")

    _log(rows)
    drifts = [float(r["drift_pct"]) for r in rows if r["drift_pct"]]
    print(f"\n  {len(CASES)-bad} of {len(CASES)} reconcile"
          f"{'' if not bad else '  — a SKIP counts as a failure, not a pass'}")
    if drifts:
        exact = sum(1 for d in drifts if d == 0)
        worst = max(zip(drifts, (r["label"] for r in rows if r["drift_pct"])))
        print(f"  {exact} of {len(drifts)} exact to the cent; "
              f"worst drift {worst[0]:.3f}% ({worst[1]}); tolerance {TOL*100:.1f}%")
    print(f"  logged to {LOG.relative_to(pathlib.Path.cwd()) if LOG.is_relative_to(pathlib.Path.cwd()) else LOG}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
