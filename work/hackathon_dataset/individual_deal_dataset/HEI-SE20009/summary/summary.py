"""Write ../summary.md (cases owned, payments by source, bridge rates) by running the dataset queries.

    uv run python work/hackathon_dataset/individual_deal_dataset/HEI-SE20009/summary/summary.py
"""

from __future__ import annotations

import datetime as dt
import sys
from decimal import Decimal
from pathlib import Path

import datalake
import pandas as pd

sys.path.insert(0, str(Path(__file__).parents[2]))
import deal_dataset  # noqa: E402
import summary_md  # noqa: E402

HERE = Path(__file__).parent
DATASET = HERE.parent
RUN_SQL = """
SELECT case_id
FROM asset_index.approved.cases
WHERE _run_id = (
    SELECT run_id
    FROM asset_index.approved.runs
    WHERE portfolio_id = 'SE20009'
        AND source_work_uri LIKE 's3://ml-prod-asset-index-work/%'
    QUALIFY ROW_NUMBER() OVER (ORDER BY approved_at DESC) = 1
)
"""


def money(value) -> float | None:
    """Round money to two decimals for display only."""
    if value is None or pd.isna(value):
        return None
    return float(Decimal(value).quantize(Decimal("0.01")))


def pct(part: int, whole: int) -> float | None:
    return round(part / whole * 100, 5) if whole else None


def main() -> None:
    accounts, payments = deal_dataset.build(DATASET.name)
    sources = datalake.q(HERE / "summary_sources.sql", lower=True, convert=False)
    tape_ids = set(datalake.q(RUN_SQL, lower=True).case_id)

    cases = accounts.drop_duplicates("model_id")
    owned = len(cases)
    method = cases.asset_index_match_method.value_counts()
    same_id = int(method.get("same_id", 0))
    by_borrower = int(method.get("borrower_and_balance", 0))
    tape_used = set(cases.asset_index_case_id.dropna())

    src = sources.set_index("source")
    window_start = src.window_start.iloc[0]
    window_end = src.window_end.iloc[0]
    reference = Decimal(src.loc["npl_common_portfolio_snapshot", "paid_in_window"])

    def source_entry(name: str, scope: str) -> dict:
        row = src.loc[name]
        paid = Decimal(row.paid_in_window) if pd.notna(row.paid_in_window) else Decimal(0)
        entry = {"scope": scope, "paid": money(paid)}
        if name != "npl_common_portfolio_snapshot" and paid:
            entry["vs_portfolio_snapshot_pct"] = round(float((paid / reference - 1) * 100), 5)
        entry["months_with_payments"] = int(row.months_with_payments)
        if pd.notna(row.cases_with_payments):
            entry["cases_with_payments"] = int(row.cases_with_payments)
        return entry

    tape_payments = payments[payments.payment_source == "asset_index"]
    summary = {
        "deal": "HEI-SE20009",
        "measured_on": dt.date.today().isoformat(),
        "source_of_numbers": (
            "live queries: accounts.sql and payments_pre_registration.sql on prod, "
            "payments_post_registration.sql on the sandbox build, summary/summary_sources.sql on prod"
        ),
        "ownership": {
            "cases_owned_in_npl_common": owned,
            "cases_owned_by_system": cases.model_id.str[:4].value_counts().to_dict(),
            "note": "Every case is on Intrum's system 2080 and none moved system, so a case is a loan.",
        },
        "payments_since_purchase": {
            "months": f"{window_start:%Y-%m} to {window_end:%Y-%m}",
            "currency": "SEK",
            "npl_common_portfolio_snapshot": source_entry(
                "npl_common_portfolio_snapshot",
                "whole deal; FCT_PORTFOLIO_SNAPSHOT_MONTHLY.GROSS_CASH_RECOVERIES, built from PAM",
            ),
            "npl_common_case_collection": source_entry(
                "npl_common_case_collection",
                "whole deal; FCT_CASE_COLLECTION, built from CAT",
            ),
            "asset_index": source_entry(
                "asset_index", "Asset Index (seller tapes); its payments end in May 2020, before purchase"
            ),
            "note": (
                "vs_portfolio_snapshot_pct is the source's total above (+) or below (-) the "
                "portfolio snapshot's, which is built from Intrum's own monthly report."
            ),
        },
        "payments_before_registration": {
            "what": "the seller's payment history on the tapes, for cases we own and matched",
            "first": f"{tape_payments.payment_date.min():%Y-%m-%d}",
            "last": f"{tape_payments.payment_date.max():%Y-%m-%d}",
            "cases_with_payments": int(tape_payments.model_id.nunique()),
            "paid": money(sum(Decimal(v) for v in tape_payments.payment_amount)),
        },
        "bridge_tape_to_cases_owned": {
            "denominator": "cases owned in npl_common",
            "cases_owned": owned,
            "same_id": {
                "cases": same_id,
                "pct": pct(same_id, owned),
                "how": "the Asset Index case id equals the warehouse case id (DIM_CASE.CASE_BK)",
            },
            "borrower_and_balance": {
                "cases": by_borrower,
                "pct": pct(by_borrower, owned),
                "how": (
                    "same borrower birth year and gender, then points for equal principal, other "
                    "balances, interest and verdict month; see MATCHING in accounts.sql. Picked the "
                    "right case 99.815% of the time in a blind test on the same_id cases."
                ),
            },
            "via_payment_history": {
                "cases": 0,
                "pct": 0.0,
                "how": (
                    "not possible: the Asset Index payments end in May 2020 and the first case "
                    "registered in July 2020, so no month is in both."
                ),
            },
            "via_moved_loan_link": {
                "cases": 0,
                "pct": 0.0,
                "how": "not needed: no loan on this deal moved between Intrum's systems.",
            },
            "bridged_total": {
                "cases": same_id + by_borrower,
                "pct": pct(same_id + by_borrower, owned),
            },
            "not_bridged": {
                "cases": owned - same_id - by_borrower,
                "pct": pct(owned - same_id - by_borrower, owned),
                "note": "needs Intrum's mapping from the Asset Index SE_A/SE_C ids to their case numbers",
            },
            "tape_rows_not_matched": {
                "rows": len(tape_ids - tape_used),
                "of_tape_rows": len(tape_ids),
                "note": (
                    "on the tape but matched to no case we own; includes 74 '1062-' ids that do "
                    "not exist on Intrum's system 1062"
                ),
            },
        },
        "reconciliation": summary_md.reconciliation(payments),
        "dataset_rows": {
            "accounts_sql": len(accounts),
            "payments_sql": len(payments),
            "payments_sql_by_source": {
                source: {"rows": len(g), "amount": money(sum(Decimal(v) for v in g.payment_amount))}
                for source, g in payments.groupby("payment_source")
            },
        },
    }
    out = DATASET / "summary.md"
    out.write_text(summary_md.render(summary))
    print(out.read_text())


if __name__ == "__main__":
    main()
