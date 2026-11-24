"""Stack every hackathon deal into one accounts and one payments dataset.

    uv run python work/hackathon_dataset/final_dataset/final_dataset.py

Each deal is put together by ../individual_deal_dataset/deal_dataset.py from its three queries:
accounts.sql and payments_pre_registration.sql on prod, payments_post_registration.sql on the sandbox
build with both collection fixes. So within a deal, payments are the Asset Index's before registration
unioned with the sandbox's from registration; then the deals are unioned.
Writes accounts and payments to output/ as .parquet and .csv (git-ignored), then payments_by_month.png
and summary.md.
"""

from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).parent
DEALS_DIR = HERE.parent / "individual_deal_dataset"
OUTPUT = HERE / "output"
DEALS = ["HEI-SE17039", "HEI-SE19026", "HEI-SE20009", "LOK-SE25008"]

sys.path.insert(0, str(DEALS_DIR))
import deal_dataset  # noqa: E402

import plot_payments  # noqa: E402


def by_source(payments: pd.DataFrame) -> dict:
    return {
        source: {"rows": len(g), "amount_sek": round(float(g.payment_amount.sum()), 2)}
        for source, g in payments.groupby("payment_source")
    }


def deal_report(accounts: pd.DataFrame, payments: pd.DataFrame) -> dict:
    loans = accounts.drop_duplicates("model_id")
    warehouse = payments[payments.payment_source == "warehouse"].iloc[0]
    return {
        "loans": len(loans),
        "loans_with_a_tape_row": int(loans.in_asset_index.sum()),
        "loans_with_a_tape_row_pct": round(float(loans.in_asset_index.mean() * 100), 5),
        "accounts_rows": len(accounts),
        "payments_rows": len(payments),
        "payments_by_source": by_source(payments),
        # Loans Intrum held for the seller before we bought: their warehouse payments start before the dashed line.
        "loans_registered_before_purchase": int(
            (
                loans.warehouse_registration_date
                < pd.Timestamp(warehouse.warehouse_vs_pam_compared_from).to_period("M").to_timestamp()
            ).sum()
        ),
        "registered_from": f"{loans.warehouse_registration_date.min():%b %Y}",
        "purchase_month": f"{warehouse.warehouse_vs_pam_compared_from:%b %Y}",
        "warehouse_vs_pam": {
            "months": f"{warehouse.warehouse_vs_pam_compared_from:%Y-%m} to "
            f"{warehouse.warehouse_vs_pam_compared_to:%Y-%m}",
            "share_of_pam_pct": round(float(100 + warehouse.warehouse_vs_pam_collection_total_pct), 5),
            "month_coverage_pct": round(float(warehouse.warehouse_vs_pam_month_coverage_pct), 5),
            "reconciles": bool(warehouse.warehouse_reconciles_with_pam),
        },
    }


def _n(value) -> str:
    return f"{value:,}"


def _sek(value) -> str:
    return f"{value:,.2f}"


def render(summary: dict) -> str:
    """summary.md: the overview per deal, the chart, then the totals."""
    deals = summary["by_deal"]
    overview = [
        "| Deal | Loans | Loans in the Asset Index | Warehouse vs PAM | Months with payments | Reconciles |",
        "|---|---:|---:|---:|---:|---|",
    ]
    for deal, d in deals.items():
        pam = d["warehouse_vs_pam"]
        overview.append(
            f"| {deal} | {_n(d['loans'])} | {_n(d['loans_with_a_tape_row'])} ({d['loans_with_a_tape_row_pct']:g}%) "
            f"| **{pam['share_of_pam_pct']:g}%** ({pam['months']}) | {pam['month_coverage_pct']:g}% "
            f"| {'**Yes**' if pam['reconciles'] else '**No**'} |"
        )
    totals = ["| Deal | Source | Rows | Amount (SEK) |", "|---|---|---:|---:|"]
    for deal, d in [*deals.items(), ("**All deals**", summary["all_deals"])]:
        for source, v in d["payments_by_source"].items():
            name = "Asset Index, before the split" if source == "asset_index" else "warehouse, from the split"
            totals.append(f"| {deal} | {name} | {_n(v['rows'])} | {_sek(v['amount_sek'])} |")
    registered_early = ["| Deal | Bought | Loans registered with Intrum before we bought | First registration |", "|---|---|---:|---|"]
    for deal, d in deals.items():
        share = d["loans_registered_before_purchase"] / d["loans"] * 100
        registered_early.append(
            f"| {deal} | {d['purchase_month']} | {_n(d['loans_registered_before_purchase'])} of {_n(d['loans'])} "
            f"({share:.5g}%) | {d['registered_from']} |"
        )
    a = summary["all_deals"]
    return "\n".join(
        [
            "# Final dataset: all hackathon deals",
            "",
            f"Measured {summary['measured_on']} from {summary['source_of_numbers']}. Amounts in {summary['currency']}.",
            "",
            "## Overview",
            "",
            *overview,
            "",
            "Warehouse vs PAM is the warehouse's total as a share of Intrum's monthly report (PAM), from purchase "
            "to PAM's last complete month. A deal reconciles when that is within 10% and the warehouse has "
            "payments in at least 80% of PAM's months.",
            "",
            "## Payments by month",
            "",
            "![Payments by month, one row per deal](payments_by_month.png)",
            "",
            "Bars are the Asset Index (seller tape) payments the dataset uses: before each loan's registration month. The black "
            "line is every warehouse payment on the deal (sandbox build) at any date, so it overlays the bars wherever the "
            "warehouse has the same months; the dataset uses it only from each loan's registration month. The dashed line "
            "is the month the most loans registered with Intrum. HEI-SE20009 has no black line before Jul 2020 because "
            "the warehouse holds nothing on it before its cases registered.",
            "",
            "**LOK-SE25008 is split at Intrum's acquisition month (Jun 2025), not by registration.** Intrum was "
            "already collecting its loans for the seller from 2016, and its tape is that collection history (it matches "
            "the warehouse to the öre on 97.9% of loan-months). Split by registration, almost all of it would have "
            "been replaced by the warehouse. So the tape is used up to the purchase and the warehouse from it, and its "
            "chart has a second dashed line at the acquisition month. Before it, the black line sits on the bars: the same "
            "payments from both sources.",
            "",
            "Why some deals have warehouse payments before the dashed line: Intrum was already collecting part "
            "of the deal for the seller before we bought it, and each loan registered with Intrum when it went to "
            "collection. Each loan switches from Asset Index to warehouse in its own registration month, so where "
            "bars and line overlap on HEI-SE17039 they are different loans. On LOK-SE25008 they are the same payments, "
            "drawn from both sources on the chart only; the dataset never holds a payment twice. The current month is "
            "left out of the lines.",
            "",
            *registered_early,
            "",
            "## Rows and totals",
            "",
            "The split is each loan's registration month, except LOK-SE25008 (Intrum's acquisition month).",
            "",
            f"{_n(a['loans'])} loans; {_n(a['accounts_rows'])} rows in accounts, {_n(a['payments_rows'])} in payments "
            "(output/, .csv and .parquet).",
            "",
            *totals,
            "",
        ]
    )


def main() -> None:
    built = {deal: deal_dataset.build(deal) for deal in DEALS}
    accounts = pd.concat([a for a, _ in built.values()], ignore_index=True)
    payments = pd.concat([p for _, p in built.values()], ignore_index=True)

    OUTPUT.mkdir(exist_ok=True)
    for name, frame in {"accounts": accounts, "payments": payments}.items():
        frame.to_parquet(OUTPUT / f"{name}.parquet", index=False)
        frame.to_csv(OUTPUT / f"{name}.csv", index=False)

    summary = {
        "measured_on": dt.date.today().isoformat(),
        "source_of_numbers": (
            "live queries: each deal's accounts.sql and payments_pre_registration.sql on prod, "
            "payments_post_registration.sql on the sandbox build DEV.HACKATHON (connection dev)"
        ),
        "currency": "SEK",
        "all_deals": {
            "deals": DEALS,
            "loans": int(accounts.model_id.nunique()),
            "accounts_rows": len(accounts),
            "payments_rows": len(payments),
            "payments_by_source": by_source(payments),
        },
        "by_deal": {deal: deal_report(a, p) for deal, (a, p) in built.items()},
    }
    plot_payments.main(DEALS)
    (HERE / "summary.md").write_text(render(summary))
    print((HERE / "summary.md").read_text())


if __name__ == "__main__":
    main()
