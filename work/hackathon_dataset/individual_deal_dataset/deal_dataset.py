"""Put one deal's dataset together from its three queries.

    accounts.sql                     prod      loan x month-end: the tape, balances, status
    payments_pre_registration.sql    prod      the tape's payments before the loan registered with Intrum
    payments_post_registration.sql   sandbox   warehouse payments from registration on, with the PAM check,
                                               from the build with both collection fixes (DEV.HACKATHON)

The two payment queries stack into payments. Accounts gets each month's warehouse payments, the
tape-vs-warehouse check and the PAM check from the sandbox query. Used by each deal's summary.py
and by ../final_dataset/final_dataset.py.
"""

from __future__ import annotations

from pathlib import Path

import datalake
import pandas as pd

HERE = Path(__file__).parent
SANDBOX = {"connection": "dev", "warehouse": "DEV_WH"}
PAM_CHECK = [
    "warehouse_vs_pam_collection_total_pct",
    "warehouse_vs_pam_month_coverage_pct",
    "warehouse_reconciles_with_pam",
]
PAM_WINDOW = ["warehouse_vs_pam_compared_from", "warehouse_vs_pam_compared_to"]


def build(deal: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    """The deal's accounts and payments, with the same columns for every deal."""
    folder = HERE / deal
    accounts = datalake.q(folder / "accounts.sql", lower=True)
    before = datalake.q(folder / "payments_pre_registration.sql", lower=True)
    after = datalake.q(folder / "payments_post_registration.sql", lower=True, **SANDBOX)
    if after.empty:
        raise SystemExit(f"{deal}: the sandbox build has no payments for this deal; check DEV.HACKATHON.")

    # The PAM check is for the whole deal, so every row carries the same values.
    check = after.iloc[0][PAM_CHECK + PAM_WINDOW]
    for column in PAM_CHECK + PAM_WINDOW:
        before[column] = check[column]
    payments = pd.concat([before, after], ignore_index=True)[after.columns]
    payments = payments.sort_values(["model_id", "payment_date"], ignore_index=True)

    monthly = after.groupby(["model_id", "month_end"]).payment_amount.sum().rename("paid")
    accounts = accounts.join(monthly, on=["model_id", "month_end"])
    position = accounts.columns.get_loc("asset_index_paid_in_month")
    accounts.insert(position, "warehouse_collected_in_month", accounts.paid.fillna(0))
    accounts["asset_index_vs_warehouse_paid_difference"] = (
        accounts.asset_index_paid_in_month - accounts.warehouse_collected_in_month
    )
    # TRUE if both agree to the öre; empty if neither has a payment that month.
    neither = (accounts.asset_index_paid_in_month == 0) & accounts.paid.isna()
    accounts["asset_index_vs_warehouse_paid_matches"] = (
        accounts.asset_index_vs_warehouse_paid_difference.abs() < 0.01
    ).where(~neither)
    accounts = accounts.drop(columns="paid")
    for column in PAM_CHECK:
        accounts[column] = check[column]
    return accounts, payments
