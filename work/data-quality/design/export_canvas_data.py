"""Compact data file for the design canvas: the two dashboard queries, as run today."""
import json, math, datalake as b, pandas as pd
from concurrent.futures import ThreadPoolExecutor
OUT = "/private/tmp/claude-501/-Users-sharlenechin-data-warehouse-local-workspace/f912e5e7-944b-453d-a142-54dc9fa1c8eb/scratchpad/canvas/"
Q = "work/data-quality/sigma_queries/"
with ThreadPoolExecutor(2) as ex:
    pm, ref = ex.map(lambda f: b.q(open(Q + f).read(), lower=True), ["portfolio_months_element.sql", "combined_refs_element.sql"])
pm.to_pickle(OUT + "pm.pkl"); ref.to_pickle(OUT + "ref.pkl")
def v(x):
    if x is None or (isinstance(x, float) and math.isnan(x)): return None
    if hasattr(x, "isoformat"): return str(x)[:7]
    if isinstance(x, (bool,)) or str(type(x)).endswith("bool_'>"): return 1 if x else 0
    if isinstance(x, float): return round(x, 2)
    try: return int(x) if float(x).is_integer() and not isinstance(x, str) else (round(float(x), 2) if not isinstance(x, str) else x)
    except Exception: return x
PCOLS = ["reporting_month", "servicer", "portfolio_name", "deal", "country_name", "currency", "purchase_price",
         "portfolio_feed_received_flag", "portfolio_feed_due_flag", "case_feed_status", "refs_reported",
         "portfolio_feed_collections", "case_feed_collections", "portfolio_feed_balance", "case_feed_balance", "closed_cases_balance",
         "case_feed_cases", "case_feed_open_cases", "forecast_received_flag", "portfolio_feed_first_month", "portfolio_feed_last_month",
         "case_feed_first_month", "case_feed_last_month", "months_reported_to_date", "months_overlap_to_date",
         "collections_reconciled_flag", "case_payments_loaded_flag", "case_payment_months_since_acquisition", "reported_months_since_acquisition"]
last = pm.reporting_month.max()
RCOLS = ["reporting_month", "servicer", "portfolio_name", "combined_ref", "deal", "country_name", "currency", "purchase_price",
         "portfolio_feed_received_flag", "portfolio_feed_due_flag", "case_feed_status",
         "portfolio_feed_collections", "case_feed_collections", "portfolio_feed_balance", "case_feed_balance", "closed_cases_balance",
         "case_feed_cases", "case_feed_open_cases", "forecast_received_flag", "portfolio_feed_first_month", "portfolio_feed_last_month",
         "case_feed_first_month", "case_feed_last_month", "months_reported_to_date", "months_overlap_to_date", "case_payments_loaded_flag"]
r = ref[ref.reporting_month >= sorted(ref.reporting_month.unique())[-3]]   # the ref view covers the last 3 months
blob = {"asOf": "2026-10-14", "P_COLS": PCOLS, "P": [[v(x) for x in row] for row in pm[PCOLS].itertuples(index=False)],
        "R_COLS": RCOLS, "R": [[v(x) for x in row] for row in r[RCOLS].itertuples(index=False)]}
json.dump(blob, open(OUT + "dq_canvas_2026-10-14.json", "w"), separators=(",", ":"))
print(len(blob["P"]), len(blob["R"]), last)
