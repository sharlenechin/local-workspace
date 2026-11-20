"""Cross-check the Servicing dashboard against the NPL Portfolio Dashboard (v2), month by month. Read-only.

    uv run python work/servicing/tests/npl_crosscheck.py

The two show different totals on purpose: Servicing shows 100% of each portfolio's collections; NPL v2
(MART_NPL_FLASH_REPORT) shows Brocc's ownership share. Both convert every month at the latest month-end rate (Servicing
since 2026-10-14), so the currency column of the bridge should read 0.00. So this checks
the inputs in local currency (collections, accounting = NPL "active", underwriting), every portfolio-month, and prints
the bridge from one dashboard's monthly total to the other's. First run 2026-10-14 (net collections added the same day): 2,106 / 2,115 / 2,115 portfolio-months,
0 differences over 1 unit of currency; the bridge closed in every month Dec 2025 - Sep 2026."""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _lib, datalake, pandas as pd

pd.set_option("display.width", 250); pd.set_option("display.float_format", lambda x: f"{x:,.2f}")
q = lambda s: datalake.q(s, lower=True)
SPAN = "BETWEEN '2025-12-31' AND LAST_DAY(DATEADD(month, -1, CURRENT_DATE()))"
# Ignis / Ignis II pre-closing collections sit in the servicer feed before capex; NPL v2 drops them, so does Servicing.
IGNIS = "NOT (deal_bk IN ('GCB-ES26101', 'GCB-ES26106') AND month_end_date < capex_date)"

flash = q(f"""SELECT portfolio_bk, month_end_date AS m, SUM(gcf_actual) AS coll, SUM(ncf_actual) AS net, SUM(gcf_active) AS acc, SUM(gcf_underwriting) AS uw
  FROM PROD.NPL_COMMON.MART_NPL_FLASH_REPORT WHERE month_end_date {SPAN} AND {IGNIS} GROUP BY 1, 2""")
snap = q(f"""SELECT p.portfolio_bk, f.period_end_date AS m, SUM(f.gross_cash_recoveries) AS coll, SUM(f.net_cash_recoveries) AS net
  FROM PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f JOIN PROD.NPL_COMMON.DIM_PORTFOLIO p ON p.portfolio_sk = f.portfolio_sk
  WHERE f.period_end_date {SPAN} AND (p.capex_date IS NULL OR f.period_end_date >= DATE_TRUNC('MONTH', p.capex_date)) GROUP BY 1, 2""")
def latest(t):
    return q(f"""SELECT p.portfolio_bk, f.period_end_date AS m, SUM(f.gross_collection_forecast) AS v
      FROM (SELECT * FROM PROD.NPL_COMMON.{t} WHERE period_end_date {SPAN}
            QUALIFY snapshot_version = MAX(snapshot_version) OVER (PARTITION BY portfolio_sk, period_end_date)) f
      JOIN PROD.NPL_COMMON.DIM_PORTFOLIO p ON p.portfolio_sk = f.portfolio_sk GROUP BY 1, 2""")
bad = 0
for name, ours, col in [("collections", snap[["portfolio_bk", "m", "coll"]].rename(columns={"coll": "v"}), "coll"),
                        ("net collections", snap[["portfolio_bk", "m", "net"]].rename(columns={"net": "v"}), "net"),
                        ("accounting vs NPL active", latest("FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY"), "acc"),
                        ("underwriting", latest("FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY"), "uw")]:
    j = flash[["portfolio_bk", "m", col]].merge(ours, on=["portfolio_bk", "m"], how="outer").fillna(0)
    off = j[(j[col] - j["v"]).abs() > 1]
    bad += len(off)
    print(f"{name:26s} {len(j):5d} portfolio-months, {len(off)} differ by more than 1 unit of local currency")
    if len(off):
        print(off.head(10).to_string(index=False))

# The bridge, in EUR: Servicing's monthly total -> NPL v2's chart (dates = last complete month, Overall, Gross)
d = _lib.dashboard().assign(m=lambda x: pd.to_datetime(x.reporting_month))
srv = d.groupby("m").collections_sum.sum() / 1e6
r = q(f"""WITH fx AS (SELECT quote_currency, ultimo_value FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
                     WHERE date_day = LAST_DAY(DATEADD(month, -1, CURRENT_DATE())) AND base_currency = 'EUR')
  SELECT a.month_end_date AS m, SUM(a.gcf_actual * b.ultimo_value) AS full, SUM(a.gcf_actual * b.ultimo_value * a.ownership_share) AS npl
  FROM PROD.NPL_COMMON.MART_NPL_FLASH_REPORT a JOIN fx b ON a.currency_id = b.quote_currency
  WHERE a.month_end_date {SPAN} AND {IGNIS} GROUP BY 1 ORDER BY 1""")
r["m"] = pd.to_datetime(r.m); r = r.set_index("m") / 1e6
print(pd.DataFrame({"Servicing (100%)": srv, "currency difference (0 since 2026-10-14)": r["full"] - srv,
                    "Brocc's share only": r.npl - r["full"], "= NPL v2 chart": r.npl}).to_string())
print("\nRESULT:", "consistent" if bad == 0 else f"{bad} portfolio-months differ - investigate")
