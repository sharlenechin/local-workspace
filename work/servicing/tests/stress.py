"""Stress test the live Servicing dashboard: export every visible tile under every toggle and a set of awkward
filters (one country, a no-feed servicer, a tiny portfolio, a single early month), and flag any cell that is
impossible or suspicious. Read-only: Sigma exports only. About 620 exports, 15 minutes.

    uv run python work/servicing/tests/stress.py [flags.json]

First run 2026-10-13 found Net Change at -3,082% and net collections at -1,168% (a % of a signed number); fixed
in v50. Flags are not failures: most are real data (fees above tiny collections, tiny forecasts). Read them."""
import itertools, json, sys, re, traceback
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

import pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _lib

d = _lib.dashboard()
latest = d[d.reporting_month == d.reporting_month.max()]
# awkward filters: biggest country, a weak one, no-case-feed servicer, a 2-portfolio servicer, a small deal,
# the smallest portfolio, a single early month, the first month alone
small_port = latest.sort_values("collections_sum").iloc[len(latest) // 10]["portfolio_name"]
tiny_port = latest.loc[latest.collections_sum.abs() > 0].sort_values("collections_sum").iloc[0]["portfolio_name"]
neg_port = d.loc[d.collections_sum < 0, "portfolio_name"].iloc[0] if (d.collections_sum < 0).any() else tiny_port
elec = [x for x in d.deal.dropna().unique() if "Electrabel" in x][0]
FILTERS = {
    "none": {},
    "Finland": {"Country": "Finland"},
    "Italy": {"Country": "Italy"},
    "Fire (no feed)": {"Servicer": "Fire"},
    "Massey": {"Servicer": "Massey"},
    "Electrabel": {"Deal": elec},
    f"small portfolio": {"Portfolio": small_port},
    f"tiny portfolio": {"Portfolio": tiny_port},
    f"negative-month portfolio": {"Portfolio": neg_port},
    "Apr-Jun 2026": {"Reporting-Month": "min:2026-04-01,max:2026-06-30"},
    "Dec 2025 only": {"Reporting-Month": "min:2025-12-01,max:2025-12-31"},
    "Jan 2026 only": {"Reporting-Month": "min:2026-01-01,max:2026-01-31"},
}
W4 = ["Previous month", "Last 3 months", "Last 6 months", "Last 12 months"]
B3 = ["Servicer", "Accounting", "Underwriting"]
G4 = ["Country", "Servicer", "Seller", "Deal", "Portfolio"]

jobs = []
for fname, f in FILTERS.items():
    full = fname == "none"
    for w, b in itertools.product(W4, B3):
        for el in ("p_coll", "p_vs", "p_gap", "p_fc", "p_net", "p_cost"):
            if full or (w in ("Last 3 months",) and b == "Accounting"):
                jobs.append((fname, el, {**f, "P-Window": w, "Bench": b}))
    for g, w, b in itertools.product(G4, W4, B3):
        if full or (g in ("Country", "Deal") and w in ("Previous month", "Last 3 months") and b == "Accounting"):
            jobs.append((fname, "bp_perf", {**f, "P-Perf-Grain": g, "P-Perf-Window": w, "P-Perf-Bench": b}))
    for g, w in itertools.product(G4, W4):
        if full or (g in ("Country", "Deal") and w in ("Previous month", "Last 3 months")):
            jobs.append((fname, "bc_perf", {**f, "C-Perf-Grain": g, "C-Perf-Window": w}))
    for w in W4:
        if full or w == "Last 3 months":
            for el in ("c_cc", "c_ce", "c_cpe", "c_nl", "c_first", "c_new", "c_lost", "c_three", "c_book", "c_everc", "c_ever"):
                jobs.append((fname, el, {**f, "C-Window": w}))
    for v, b in itertools.product(["Monthly", "Cumulative"], B3):
        if full or b == "Accounting":
            jobs.append((fname, "p_chart", {**f, "View": v, "Bench": b}))
    for el in ("bp_full", "bc_full", "c_chart", "c_money", "c_avg"):
        jobs.append((fname, el, dict(f)))
    for w in ["This month"] + W4:
        if full or w == "Last 3 months":
            for el in ("d_recshare", "d_notrec", "d_stopped", "d_srv", "d_port"):
                jobs.append((fname, el, {**f, "D-Window": w}))

print(len(jobs), "exports", flush=True)
results = {}


def run(job):
    fname, el, params = job
    try:
        return job, _lib.tile(el, params=params), None
    except Exception as e:   # an export that fails is itself a finding
        return job, None, f"{type(e).__name__}: {e}"[:300]


with ThreadPoolExecutor(8) as ex:
    out = list(ex.map(run, jobs))

flags = []
def flag(rule, fname, el, params, col, val, row=None):
    flags.append({"rule": rule, "filter": fname, "element": el, "params": {k: v for k, v in params.items()}, "column": col,
                  "value": None if val is None else (float(val) if isinstance(val, (int, float)) else str(val)), "row": row})

for (fname, el, params), df, err in out:
    if err:
        flag("export failed", fname, el, params, None, err); continue
    if df is None or df.empty:
        flag("empty export", fname, el, params, None, None); continue
    label = df.columns[0]
    for col in df.columns:
        s = df[col]
        txt = s.astype(str)
        bad_txt = txt[txt.str.contains(r"Unknown column|NaN|Infinity|inf$|#ERR|Error", regex=True, na=False)]
        for i, v in bad_txt.items():
            flag("bad text", fname, el, params, col, v, str(df.iloc[i, 0]))
        num = pd.to_numeric(s, errors="coerce")
        if num.notna().sum() == 0:
            continue
        lc = col.lower()
        rowname = lambda i: str(df.iloc[i][label])
        is_change = "vs window" in lc or lc in ("previous window",)
        for i, v in num.items():
            if pd.isna(v):
                continue
            if "vs window" in lc and "net change" in lc:   # a difference in cases since v50, not a %
                continue
            if "vs window" in lc:
                pts = "% of forecast" in lc or "servicer cost" in lc or "% of book" in lc   # changes in points, not a %
                if pts and abs(v) > 100: flag("change > 100 pts", fname, el, params, col, v, rowname(i))
                elif not pts and "minus forecast" not in lc:
                    if v <= -0.999999: flag("change = -100%", fname, el, params, col, v, rowname(i))
                    elif abs(v) > 5: flag("change beyond ±500%", fname, el, params, col, v, rowname(i))
            elif "not reconciled" in lc or lc == "reconciled":   # euro, and a count of portfolios
                continue
            elif any(k in lc for k in ("% of forecast", "% of servicer", "% of accounting", "% of underwriting", "% of book", "share")):
                if v < 0 or v > 5: flag("ratio outside 0-500%", fname, el, params, col, v, rowname(i))
            elif "servicer cost" in lc and "%" in lc:
                if v < -0.05 or v > 1: flag("cost share outside 0-100%", fname, el, params, col, v, rowname(i))
            elif "per case" in lc:
                if v < 0 or v > 20000: flag("per-case euro implausible", fname, el, params, col, v, rowname(i))
            elif any(k in lc for k in ("collected cases", "cases on book", "ever collected", "portfolios", "three consecutive", "fresh", "new")) \
                    and el not in ("c_chart",) and "net change" not in lc and "minus" not in lc:
                if v < 0: flag("negative count", fname, el, params, col, v, rowname(i))
pd.DataFrame(flags).to_json(sys.argv[1] if len(sys.argv) > 1 else "stress_flags.json", orient="records", indent=1)
fl = pd.DataFrame(flags)
print("flags:", len(fl))
if len(fl):
    fl["el_col"] = fl["element"] + " · " + fl["column"].fillna("")
    print(fl.groupby(["rule", "el_col"]).size().sort_values(ascending=False).head(60).to_string())
