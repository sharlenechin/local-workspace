"""Random dipstick: combinations of filters and toggles no fixed check covers, each compared with an independent
recompute from the dashboard query's rows. Read-only (Sigma exports only).

    uv run python work/servicing/tests/dipstick.py [n_scenarios] [seed]

A scenario is 2-3 header filters drawn at random (Country, Servicer, Seller, Deal, Reconciliation, a month range),
kept only if some portfolio-month survives them, with a random Benchmark, View and Comparison Window. For each it
checks the latest-month cards, the Cases chart's bar totals and the Performance table's column sums. First run
2026-10-13. Seed it to reproduce a failure."""
import random, sys, pathlib
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _lib

N = int(sys.argv[1]) if len(sys.argv) > 1 else 30
rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 20261013)
d = _lib.dashboard()
d["m"] = pd.to_datetime(d["reporting_month"])
months = sorted(d["m"].unique())
COLS = {"Country": "country_name", "Servicer": "servicer_group", "Seller": "seller", "Deal": "deal", "Reconciliation": "reconciliation_status"}


def draw() -> tuple[dict, pd.DataFrame]:
    while True:
        keys = rng.sample(list(COLS) + ["Reporting-Month"], rng.choice([2, 3]))
        rows, params = d, {}
        for k in keys:
            if k == "Reporting-Month":
                a, b = sorted(rng.sample(range(len(months)), 2))
                lo, hi = pd.Timestamp(months[a]), pd.Timestamp(months[b])
                params[k] = f"min:{lo.replace(day=1):%Y-%m-%d},max:{hi:%Y-%m-%d}"
                rows = rows[(rows["m"] >= lo.replace(day=1)) & (rows["m"] <= hi)]
            else:
                v = rng.choice(sorted(rows[COLS[k]].dropna().unique())) if len(rows) else None
                if v is None:
                    break
                params[k] = v
                rows = rows[rows[COLS[k]] == v]
        if len(rows):
            return params, rows


BENCH = {"Servicer": ("servicer_forecast_sum", "collections_servicer_lfl_sum"), "Accounting": ("accounting_forecast_sum", "collections_sum"),
         "Underwriting": ("underwriting_forecast_sum", "collections_sum")}


def scenario(i: int):
    params, rows = draw()
    bench = rng.choice(list(BENCH))
    latest = rows[rows["m"] == rows["m"].max()]
    fc, coll = BENCH[bench]
    s = lambda c: latest[c].sum(min_count=1)
    want = {"p_coll": s("collections_sum") / 1e6, "p_net": s("net_collections_sum") / 1e6, "p_fc": s(fc) / 1e6,
            "p_vs": s(coll) / s(fc) if s(fc) else None, "p_gap": (s(coll) - s(fc)) / 1e6,
            "c_cc": s("collected_cases_count"), "c_ce": s("collected_cases_amount_sum") / 1e6,
            "c_nl": s("collected_cases_new_count") - s("collected_cases_lost_count") if pd.notna(s("collected_cases_count")) else None}
    p = {**params, "Bench": bench, "P-Window": rng.choice(["Previous month", "Last 3 months"]), "C-Window": "Last 3 months"}
    out = []
    for el, w in want.items():
        try:
            t = _lib.tile(el, params=p)
            got = pd.to_numeric(t["v"], errors="coerce").iloc[-1] if len(t) else None
        except Exception as e:
            out.append((i, params, bench, el, "export failed", str(e)[:120])); continue
        if (w is None or pd.isna(w)) != (got is None or pd.isna(got)):
            out.append((i, params, bench, el, w, got))
        elif w is not None and not pd.isna(w) and abs(got - w) > 1e-6 * max(1, abs(w)):
            out.append((i, params, bench, el, w, got))
    # Cases chart: each month's bar total (every segment, spacer and Lost included) = that month's collected cases
    try:
        t = _lib.tile("c_chart", params=params)
        if len(t):
            bar = t.groupby("reporting month")["cases"].sum()
            fed = rows[rows["collected_cases_count"].notna()]
            exp = fed.groupby(fed["m"].dt.strftime("%b %Y"))["collected_cases_count"].sum()
            bad = [m for m in set(bar.index) | set(exp.index) if abs(bar.get(m, 0) - exp.get(m, 0)) > 0]
            if bad:
                out.append((i, params, bench, "c_chart bar totals", dict(exp), dict(bar)))
    except Exception as e:
        out.append((i, params, bench, "c_chart", "export failed", str(e)[:120]))
    # Performance table: groups add up to the card (latest month's collections)
    try:
        t = _lib.tile("bp_perf", params={**params, "P-Perf-Grain": rng.choice(["Country", "Servicer", "Seller", "Deal", "Portfolio"])})
        tot = pd.to_numeric(t["total collections"], errors="coerce").sum()
        if abs(tot - s("collections_sum")) > 0.01:
            out.append((i, params, bench, "bp_perf sum", s("collections_sum"), tot))
    except Exception as e:
        out.append((i, params, bench, "bp_perf", "export failed", str(e)[:120]))
    return i, params, bench, len(rows), out


with ThreadPoolExecutor(6) as ex:
    results = list(ex.map(scenario, range(N)))
fails = [f for r in results for f in r[4]]
for i, params, bench, n, out in results:
    print(f"{i:>2} {'FAIL' if out else 'ok  '} rows={n:<4} bench={bench:<12} {params}")
print(f"\n{N} scenarios, {sum(1 for r in results if not r[4])} clean, {len(fails)} mismatches")
for f in fails:
    print("  ", f)
