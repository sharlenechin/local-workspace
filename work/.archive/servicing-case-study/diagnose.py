"""Why is a portfolio behind plan? The diagnosis behind ../case-study.md.

Runs the live dashboard's own query (sigma_queries/portfolios_element.sql), so every figure here is one the
dashboard can show, then compares two quarters: Mar-May 2026 (A) and Jun-Aug 2026 (B), Aug being the latest
complete month on 2026-10-12. Quarters, not single months, because one month is lumpy (see Heimdall, August).

For each portfolio behind its accounting forecast it asks, in order:
  1. Is it timing?           Behind now, but on plan over the six months together.
  2. Do the two feeds agree? The servicer's report and the case-level feed moved differently: check data first.
  3. Is the plan too high?   Behind in both quarters and not falling.
  4. Otherwise, what fell?   Fewer people paying, or the people paying are paying less.
and separately flags portfolios not replacing the payers they lose (Fresh below Lost), the leading indicator.

Writes, beside this file:
  findings_portfolios.csv   every portfolio with three months in both quarters, its figures and its diagnosis
  findings_book_monthly.csv the like-for-like case book by month (portfolios with a case feed every month Mar-Aug)
  findings_leading.csv      does Fresh vs Lost in Mar-May predict who is behind plan in Jun-Aug?
  findings_deals.csv        every deal: collections vs accounting forecast in each quarter and in August
  findings_countries.csv    the same by country, plus Heimdall with and without its Finnish portfolio
  findings_feed_gaps.csv    case-feed months that are mostly missing (Heimdall Denmark, June: 569 cases instead of ~16,000)
  findings_walkthrough.csv  what the dashboard's cards show at each step of the case study's drill-down

Run from the workspace root:  uv run python work/servicing/case_study/diagnose.py
"""
from __future__ import annotations

import pathlib

import datalake
import numpy as np
import pandas as pd
from scipy.stats import spearmanr

HERE = pathlib.Path(__file__).resolve().parent
SQL = HERE.parent / "sigma_queries" / "portfolios_element.sql"

A = pd.period_range("2026-03", "2026-05", freq="M")   # earlier quarter
B = pd.period_range("2026-06", "2026-08", freq="M")   # latest quarter (August = latest complete month)
BEHIND = 0.90          # below 90% of the accounting forecast over Jun-Aug counts as behind plan
MATERIAL = 50_000      # ...and only where Jun-Aug's forecast is at least EUR 50k: tiny plans give silly ratios
FELL = -0.10           # a fall of more than 10% quarter on quarter
FEEDS_DISAGREE = 0.25  # report and case feed changes more than 25 points apart
HEIMDALL_FI = "HEI-FI25001-U01/2512"   # ~3m cases on book; its August payout is a one-off
GAP = 0.5              # a case-feed month holding under half of what the servicer's report says was collected...
USUAL = 0.8            # ...in a portfolio whose case feed usually holds at least 80% of it: a gap, not behaviour

NUM = ["collections_sum", "accounting_forecast_sum", "collected_cases_count", "collected_cases_amount_sum",
       "collected_cases_new_count", "collected_cases_first_collection_count", "collected_cases_lost_count",
       "collected_cases_consistent_3m_count", "cases_on_book_count"]
DIMS = ["deal", "seller", "servicer_group", "country_name", "reconciliation_status", "feed_stopped_flag"]


def load() -> pd.DataFrame:
    d = datalake.q(str(SQL), lower=True)
    d["m"] = pd.to_datetime(d["reporting_month"]).dt.to_period("M")
    for c in NUM:
        d[c] = pd.to_numeric(d[c], errors="coerce")
    return d


def quarter(d: pd.DataFrame, months: pd.PeriodIndex) -> pd.DataFrame:
    g = d[d["m"].isin(months)].groupby("portfolio_name")
    out = g[NUM].sum(min_count=1)
    out["months"] = g["m"].nunique()                       # months with a servicer report
    out["case_months"] = g["collected_cases_count"].count()  # months with a case feed
    return out


def diagnose(r: pd.Series) -> str:
    if r["att_6m"] >= 0.95:
        return "Timing: ahead earlier, on plan over six months"
    if pd.isna(r["case_chg"]):
        return "No case feed: cannot diagnose from case data"
    if abs(r["coll_chg"] - r["case_chg"]) > FEEDS_DISAGREE:
        return "Report and case feed disagree: check data first"
    if r["att_A"] < BEHIND and r["case_chg"] > FELL:
        return "Behind plan in both quarters, not falling: plan likely too high"
    if r["case_chg"] > FELL:
        return "Behind plan, case collections steady"
    return "Fewer people paying" if np.log1p(r["payers_chg"]) < np.log1p(r["epp_chg"]) else "Payers paying less"


# The case study's drill-down, one row per step: the header filters a viewer sets, and what the dashboard's cards
# then show with Benchmark = Accounting and Comparison Window = L3M (August against the average of May-July).
STEPS = [
    ("1", "No filters", {}),
    ("3", "Country = Italy", {"country_name": ["Italy"]}),
    ("4", "Deal = Breeze 2", {"deal": ["Intesa Sanpaolo - 03/2026 (Breeze 2)"]}),
    ("5a", "Deal = Breeze I", {"deal": ["Intesa Sanpaolo - 03/2025 (Breeze I)"]}),
    ("5b", "Deal = Polar", {"deal": ["BPER Banca - 12/2024 (Polar)"]}),
    ("5c", "Deal = Rubicon", {"deal": ["Delta - 12/2025 (Rubicon)"]}),
    ("6", "Country = Finland", {"country_name": ["Finland"]}),
    ("6b", "Every country except Finland", {"country_name": "not Finland"}),
    ("7a", "Deal = Heimdall, Country = Denmark", {"deal": ["Intrum - 12/2025 (Heimdall)"], "country_name": ["Denmark"]}),
    ("7b", "Deal = Heimdall, Country = Germany", {"deal": ["Intrum - 12/2025 (Heimdall)"], "country_name": ["Germany"]}),
    ("8", "Deal = Virgin Money Maiden", {"deal": ["Virgin Money - 08/2024 (Maiden)"]}),
]


def walkthrough(d: pd.DataFrame) -> pd.DataFrame:
    aug, win = B[-1], pd.period_range("2026-05", "2026-07", freq="M")   # L3M on August = May-July
    rows = []
    for step, label, flt in STEPS:
        x = d
        for col, vals in flt.items():
            x = x[x[col] != "Finland"] if vals == "not Finland" else x[x[col].isin(vals)]
        now, w = x[x["m"] == aug], x[x["m"].isin(win)]
        s = lambda df, c: df[c].sum()
        rows.append({
            "step": step, "filters": label, "portfolios_in_august": now["portfolio_name"].nunique(),
            "collections_aug": s(now, "collections_sum"), "collections_window_avg": s(w, "collections_sum") / 3,
            "forecast_aug": s(now, "accounting_forecast_sum"),
            "pct_of_forecast_aug": s(now, "collections_sum") / s(now, "accounting_forecast_sum"),
            "pct_of_forecast_window": s(w, "collections_sum") / s(w, "accounting_forecast_sum"),
            "gap_aug": s(now, "collections_sum") - s(now, "accounting_forecast_sum"),
            "paying_cases_aug": s(now, "collected_cases_count"), "paying_cases_window_avg": s(w, "collected_cases_count") / 3,
            "eur_per_paying_case_aug": s(now, "collected_cases_amount_sum") / s(now, "collected_cases_count") if s(now, "collected_cases_count") else np.nan,
            "eur_per_paying_case_window": s(w, "collected_cases_amount_sum") / s(w, "collected_cases_count") if s(w, "collected_cases_count") else np.nan,
            "fresh_aug": s(now, "collected_cases_new_count"), "fresh_window_avg": s(w, "collected_cases_new_count") / 3,
            "lost_aug": s(now, "collected_cases_lost_count"), "lost_window_avg": s(w, "collected_cases_lost_count") / 3,
            "new_first_ever_aug": s(now, "collected_cases_first_collection_count"),
            "collections_6m": s(x[x["m"].isin(A.append(B))], "collections_sum"),
            "forecast_6m": s(x[x["m"].isin(A.append(B))], "accounting_forecast_sum"),
        })
    out = pd.DataFrame(rows)
    out["pct_of_forecast_6m"] = out["collections_6m"] / out["forecast_6m"]
    return out


def main() -> None:
    d = load()
    latest = d["m"].max()
    assert latest == B[-1], f"latest complete month is {latest}, not {B[-1]}: move the quarters"

    # One-month case-feed gaps: the feed_stopped flag misses them, and they read as a wave of Lost payers who all
    # "come back" the month after. Found 2026-10-12 (Heimdall Denmark, June 2026).
    six = d[d["m"].isin(A.append(B)) & d["collected_cases_count"].notna()].copy()
    six["case_share"] = six["collected_cases_amount_sum"] / six["collections_sum"].where(six["collections_sum"] > 0)
    usual = six.groupby("portfolio_name")["case_share"].median()
    six = six.join(usual.rename("usual_share"), on="portfolio_name")
    gaps = six[(six["case_share"] < GAP) & (six["usual_share"] >= USUAL)]
    gaps[["portfolio_name", "deal", "country_name", "m", "collections_sum", "collected_cases_amount_sum", "collected_cases_count",
          "collected_cases_lost_count", "case_share", "usual_share"]].sort_values(["portfolio_name", "m"]).to_csv(HERE / "findings_feed_gaps.csv", index=False)
    gap_ports = set(gaps["portfolio_name"])

    a, b = quarter(d, A), quarter(d, B)
    dims = d.sort_values("m").groupby("portfolio_name")[DIMS].last()
    t = dims.join(a.add_suffix("_A")).join(b.add_suffix("_B"))
    t = t[(t["months_A"] == 3) & (t["months_B"] == 3)].copy()

    t["att_A"] = t["collections_sum_A"] / t["accounting_forecast_sum_A"]
    t["att_B"] = t["collections_sum_B"] / t["accounting_forecast_sum_B"]
    t["att_6m"] = (t["collections_sum_A"] + t["collections_sum_B"]) / (t["accounting_forecast_sum_A"] + t["accounting_forecast_sum_B"])
    t["gap_B"] = t["collections_sum_B"] - t["accounting_forecast_sum_B"]
    t["coll_chg"] = t["collections_sum_B"] / t["collections_sum_A"] - 1

    feed = (t["case_months_A"] == 3) & (t["case_months_B"] == 3) & (t["collected_cases_count_A"] > 0) & (t["collected_cases_count_B"] > 0)
    t["payers_A"] = (t["collected_cases_count_A"] / 3).where(feed)   # paying cases, average month
    t["payers_B"] = (t["collected_cases_count_B"] / 3).where(feed)
    t["epp_A"] = (t["collected_cases_amount_sum_A"] / t["collected_cases_count_A"]).where(feed)   # euro per paying case
    t["epp_B"] = (t["collected_cases_amount_sum_B"] / t["collected_cases_count_B"]).where(feed)
    t["payers_chg"] = t["payers_B"] / t["payers_A"] - 1
    t["epp_chg"] = t["epp_B"] / t["epp_A"] - 1
    t["case_chg"] = (t["collected_cases_amount_sum_B"] / t["collected_cases_amount_sum_A"] - 1).where(feed)
    # Fresh (dbt "new": paying again after two quiet months, first-ever payers included) per Lost payer
    t["fresh_per_lost_A"] = (t["collected_cases_new_count_A"] / t["collected_cases_lost_count_A"].replace(0, np.nan)).where(feed)
    t["fresh_per_lost_B"] = (t["collected_cases_new_count_B"] / t["collected_cases_lost_count_B"].replace(0, np.nan)).where(feed)

    t["material"] = t["accounting_forecast_sum_B"] >= MATERIAL
    t["behind"] = t["material"] & (t["att_B"] < BEHIND)
    t["diagnosis"] = np.where(t["behind"], t.apply(diagnose, axis=1), "")
    t["case_feed_gap"] = t.index.isin(gap_ports)
    t["not_replacing_payers"] = (t["fresh_per_lost_B"] < 1) & ~t["case_feed_gap"]

    keep = DIMS + ["material", "behind", "diagnosis", "not_replacing_payers", "case_feed_gap", "att_A", "att_B", "att_6m", "gap_B", "coll_chg",
                   "case_chg", "payers_A", "payers_B", "payers_chg", "epp_A", "epp_B", "epp_chg", "fresh_per_lost_A",
                   "fresh_per_lost_B", "collections_sum_A", "collections_sum_B", "accounting_forecast_sum_A", "accounting_forecast_sum_B"]
    t[keep].sort_values("gap_B").to_csv(HERE / "findings_portfolios.csv", index_label="portfolio_name")

    # The like-for-like case book: portfolios with a case feed in every month Mar-Aug
    cc = d[d["m"].isin(A.append(B))].pivot_table(index="portfolio_name", columns="m", values="collected_cases_count", aggfunc="sum")
    stable = cc.index[cc.notna().all(axis=1) & (cc > 0).all(axis=1) & ~cc.index.isin(gap_ports)]   # and no gap month
    bk = d[d["portfolio_name"].isin(stable) & (d["m"] >= A[0])].groupby("m")[NUM].sum(min_count=1)
    bk["portfolios"] = len(stable)
    bk["eur_per_paying_case"] = bk["collected_cases_amount_sum"] / bk["collected_cases_count"]
    bk["fresh_per_lost"] = bk["collected_cases_new_count"] / bk["collected_cases_lost_count"]
    hei = d[(d["portfolio_name"] == HEIMDALL_FI) & (d["m"] >= A[0])].set_index("m")
    bk["heimdall_fi_paying_cases"] = hei["collected_cases_count"]
    # ...and without Heimdall Finland, whose August (paying cases 38k -> 128k) is a one-off that swamps the rest
    ex = d[d["portfolio_name"].isin(stable) & (d["portfolio_name"] != HEIMDALL_FI) & (d["m"] >= A[0])].groupby("m")[NUM].sum(min_count=1)
    bk = bk.join(ex.add_prefix("exfi_"))
    bk["exfi_attainment"] = bk["exfi_collections_sum"] / bk["exfi_accounting_forecast_sum"]
    bk["exfi_eur_per_paying_case"] = bk["exfi_collected_cases_amount_sum"] / bk["exfi_collected_cases_count"]
    bk["exfi_fresh_per_lost"] = bk["exfi_collected_cases_new_count"] / bk["exfi_collected_cases_lost_count"]
    allb = d[d["m"] >= A[0]].groupby("m")[["collections_sum", "accounting_forecast_sum"]].sum()
    bk["whole_book_attainment"] = allb["collections_sum"] / allb["accounting_forecast_sum"]
    bk.to_csv(HERE / "findings_book_monthly.csv")

    # Deals and countries: a sub-portfolio can look behind while its deal is on plan (Virgin Money Maiden books
    # collections across 33 monthly sub-portfolios), so the deal is the level to judge
    def vs_plan(group: str | pd.Series, name: str) -> pd.DataFrame:
        rows = {}
        for label, months in (("A", A), ("B", B), ("Aug", B[-1:])):
            g = d[d["m"].isin(months)].groupby(group)[["collections_sum", "accounting_forecast_sum"]].sum()
            rows[f"collections_{label}"] = g["collections_sum"]
            rows[f"forecast_{label}"] = g["accounting_forecast_sum"]
            rows[f"attainment_{label}"] = g["collections_sum"] / g["accounting_forecast_sum"]
            rows[f"gap_{label}"] = g["collections_sum"] - g["accounting_forecast_sum"]
        out = pd.DataFrame(rows); out.index.name = name
        return out.sort_values("gap_B")
    vs_plan("deal", "deal").to_csv(HERE / "findings_deals.csv")
    hei_split = np.where(d["portfolio_name"] == HEIMDALL_FI, "Heimdall: Finland",
                         np.where(d["deal"] == "Intrum - 12/2025 (Heimdall)", "Heimdall: other countries", "Not Heimdall"))
    pd.concat([vs_plan("country_name", "group"), vs_plan(pd.Series(hei_split, index=d.index), "group")]).to_csv(HERE / "findings_countries.csv")

    # Leading indicator: Mar-May's Fresh-per-Lost against Jun-Aug's outcome, material portfolios with a case feed
    x = t[t["material"] & feed & ~t["case_feed_gap"]].replace([np.inf, -np.inf], np.nan).dropna(subset=["fresh_per_lost_A"])
    lo, hi = x[x["fresh_per_lost_A"] < 1], x[x["fresh_per_lost_A"] >= 1]
    rho, p = spearmanr(x["fresh_per_lost_A"], x["att_B"])
    pd.DataFrame([
        {"group": "Not replacing payers in Mar-May (Fresh < Lost)", "portfolios": len(lo),
         "share_behind_plan_jun_aug": (lo["att_B"] < BEHIND).mean(), "median_collections_change": lo["coll_chg"].median()},
        {"group": "Replacing payers in Mar-May (Fresh >= Lost)", "portfolios": len(hi),
         "share_behind_plan_jun_aug": (hi["att_B"] < BEHIND).mean(), "median_collections_change": hi["coll_chg"].median()},
        {"group": "Rank correlation, Fresh-per-Lost (Mar-May) vs attainment (Jun-Aug)", "portfolios": len(x),
         "share_behind_plan_jun_aug": rho, "median_collections_change": p},
    ]).to_csv(HERE / "findings_leading.csv", index=False)

    walkthrough(d).to_csv(HERE / "findings_walkthrough.csv", index=False)

    with pd.option_context("display.float_format", "{:,.5f}".format, "display.width", 200, "display.max_columns", 20):
        m = t[t["material"]]
        print(f"latest month {latest}; {len(t)} portfolios with 3+3 months, {int(t['material'].sum())} material")
        print(f"material: forecast Jun-Aug {m['accounting_forecast_sum_B'].sum():,.2f}, collected {m['collections_sum_B'].sum():,.2f}")
        print(t[t["behind"]].groupby("diagnosis")["gap_B"].agg(["size", "sum"]).sort_values("sum"))
        print(pd.read_csv(HERE / "findings_leading.csv"))


if __name__ == "__main__":
    main()
