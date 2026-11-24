"""Stack every hackathon deal into one accounts and one payments dataset.

    uv run python work/hackathon_dataset/final_dataset/final_dataset.py

Each deal is put together by ../individual_deal_dataset/deal_dataset.py from its three queries:
accounts.sql and payments_pre_registration.sql on prod, payments_post_registration.sql on the sandbox
build with both collection fixes. So within a deal, payments are the tape's before registration
unioned with the sandbox's from registration; then the deals are unioned.
Writes accounts and payments to output/ as .parquet and .csv (git-ignored), and summary.yaml.
"""

from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

import pandas as pd
import yaml

HERE = Path(__file__).parent
DEALS_DIR = HERE.parent / "individual_deal_dataset"
OUTPUT = HERE / "output"
DEALS = ["HEI-SE17039", "HEI-SE20009"]

sys.path.insert(0, str(DEALS_DIR))
import deal_dataset  # noqa: E402


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
        "warehouse_vs_pam": {
            "months": f"{warehouse.warehouse_vs_pam_compared_from:%Y-%m} to "
            f"{warehouse.warehouse_vs_pam_compared_to:%Y-%m}",
            "share_of_pam_pct": round(float(100 + warehouse.warehouse_vs_pam_collection_total_pct), 5),
            "month_coverage_pct": round(float(warehouse.warehouse_vs_pam_month_coverage_pct), 5),
            "reconciles": bool(warehouse.warehouse_reconciles_with_pam),
        },
    }


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
    (HERE / "summary.yaml").write_text(
        yaml.safe_dump(summary, sort_keys=False, allow_unicode=True, width=100)
    )
    print((HERE / "summary.yaml").read_text())


if __name__ == "__main__":
    main()
