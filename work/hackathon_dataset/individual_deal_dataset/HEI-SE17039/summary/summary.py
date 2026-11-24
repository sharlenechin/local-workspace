"""Write ../summary.md (loans owned, payments by source, bridge rates) by running the dataset queries.

    uv run python work/hackathon_dataset/individual_deal_dataset/HEI-SE17039/summary/summary.py
"""

from __future__ import annotations

import datetime as dt
import re
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
    WHERE portfolio_id = 'SE17039'
        AND source_work_uri LIKE 's3://ml-prod-asset-index-work/%'
    QUALIFY ROW_NUMBER() OVER (ORDER BY approved_at DESC) = 1
)
"""
CASES_OWNED_SQL = """
SELECT DISTINCT c.case_bk
FROM prod.npl_common.fct_case_snapshot_daily AS s
INNER JOIN prod.npl_common.dim_batch AS b
    ON b.batch_sk = s.batch_sk
INNER JOIN prod.npl_common.dim_case AS c
    ON c.case_sk = s.case_sk
WHERE b.servicer_parent_portfolio_bk = 'SE17039'
"""


def moved_pairs(cases_owned: set[str]) -> pd.DataFrame:
    """The moved-loan pairs listed in accounts.sql where we own both cases, as accounts.sql uses them."""
    text = (DATASET / "accounts.sql").read_text()
    pairs = pd.DataFrame(
        re.findall(r"\('(1062-\d+)', '(2080-\d+)'\)", text), columns=["old_case", "new_case"]
    )
    return pairs[pairs.old_case.isin(cases_owned) & pairs.new_case.isin(cases_owned)]


def money(value) -> float | None:
    """Round money to two decimals for display only."""
    if value is None or pd.isna(value):
        return None
    return float(Decimal(value).quantize(Decimal("0.01")))


def pct(part: int, whole: int) -> float:
    return round(part / whole * 100, 5) if whole else None


def monthly_match(accounts: pd.DataFrame) -> dict:
    """How often the asset index and the warehouse show the same payments in a loan-month."""
    paying = accounts[accounts.asset_index_vs_warehouse_paid_matches.notna()]
    out = {
        "what": "loan-months where either source has a payment; matched = equal to the öre",
        "loan_months_with_a_payment": len(paying),
        "matched": int(paying.asset_index_vs_warehouse_paid_matches.astype(bool).sum()),
    }
    out["matched_pct"] = pct(out["matched"], out["loan_months_with_a_payment"])
    by_system = {}
    for system, g in paying.groupby(paying.model_id.str[:4]):
        m = int(g.asset_index_vs_warehouse_paid_matches.astype(bool).sum())
        by_system[system] = {"loan_months": len(g), "matched": m, "matched_pct": pct(m, len(g))}
    out["by_system_of_current_case"] = by_system
    return out


def main() -> None:
    accounts, payments = deal_dataset.build(DATASET.name)
    sources = datalake.q(HERE / "summary_sources.sql", lower=True, convert=False)
    tape_ids = set(datalake.q(RUN_SQL, lower=True).case_id)

    loans = accounts.drop_duplicates("model_id")
    cases_owned = set(datalake.q(CASES_OWNED_SQL, lower=True).case_bk)
    moved = moved_pairs(cases_owned)
    loan_of = {**{m: m for m in loans.model_id}, **dict(zip(moved.old_case, moved.new_case))}

    cases_of_loan = {m: {m} for m in loans.model_id}
    for old, new in zip(moved.old_case, moved.new_case):
        cases_of_loan[new].add(old)

    on_tape_direct = {c for c in cases_owned if c in tape_ids}
    # Cases not on the tape whose loan's other case is on the tape.
    on_tape_via_move = {
        c for c in cases_owned - on_tape_direct if cases_of_loan[loan_of[c]] & tape_ids
    }
    not_bridged = cases_owned - on_tape_direct - on_tape_via_move

    src = sources.set_index("source")
    window_start = src.window_start.iloc[0]
    window_end = src.window_end.iloc[0]
    reference = Decimal(src.loc["npl_common_portfolio_snapshot", "paid_in_window"])

    def source_entry(name: str, scope: str) -> dict:
        row = src.loc[name]
        paid = Decimal(row.paid_in_window or 0)
        entry = {"scope": scope, "paid": money(paid)}
        if name != "npl_common_portfolio_snapshot":
            entry["vs_portfolio_snapshot_pct"] = round(float((paid / reference - 1) * 100), 5)
        entry["months_with_payments"] = int(row.months_with_payments)
        if pd.notna(row.cases_with_payments):
            entry["cases_with_payments"] = int(row.cases_with_payments)
        return entry

    summary = {
        "deal": "HEI-SE17039",
        "measured_on": dt.date.today().isoformat(),
        "source_of_numbers": (
            "live queries: accounts.sql and payments_pre_registration.sql on prod, "
            "payments_post_registration.sql on the sandbox build, summary/summary_sources.sql on prod"
        ),
        "ownership": {
            "cases_owned_in_npl_common": len(cases_owned),
            "cases_owned_by_system": {
                "1062": sum(c.startswith("1062") for c in cases_owned),
                "2080": sum(c.startswith("2080") for c in cases_owned),
            },
            "loans_owned": len(loans),
            "loans_moved_from_1062_to_2080": len(moved),
            "note": "A moved loan has two cases, so cases_owned = loans_owned + loans_moved.",
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
                "asset_index", "loans on Intrum's benchmark file only; asset_index.approved.payments"
            ),
            "note": (
                "vs_portfolio_snapshot_pct is the source's total above (+) or below (-) the "
                "portfolio snapshot's, which is built from Intrum's own monthly report."
            ),
        },
        "bridge_tape_to_cases_owned": {
            "denominator": "cases owned in npl_common",
            "cases_owned": len(cases_owned),
            "via_case_bk": {
                "cases": len(on_tape_direct),
                "pct": pct(len(on_tape_direct), len(cases_owned)),
                "how": "the tape's case id equals the warehouse case id (DIM_CASE.CASE_BK)",
            },
            "via_moved_loan_link": {
                "cases": len(on_tape_via_move),
                "pct": pct(len(on_tape_via_move), len(cases_owned)),
                "how": "old 1062 case of a moved loan whose new 2080 case is on the tape",
            },
            "via_payment_history": {
                "cases": 0,
                "pct": 0.0,
                "how": (
                    "not used in the queries. Matching leftover cases on months with equal "
                    "payments found 1 possible pair, too weak to use; see bridge_check/."
                ),
            },
            "bridged_total": {
                "cases": len(on_tape_direct) + len(on_tape_via_move),
                "pct": pct(len(on_tape_direct) + len(on_tape_via_move), len(cases_owned)),
            },
            "not_bridged": {
                "cases": len(not_bridged),
                "pct": pct(len(not_bridged), len(cases_owned)),
                "by_system": {
                    "1062": sum(c.startswith("1062") for c in not_bridged),
                    "2080": sum(c.startswith("2080") for c in not_bridged),
                },
            },
            "tape_cases_not_owned": {
                "cases": len(tape_ids - cases_owned),
                "note": "on the tape but not a case we own in the warehouse",
            },
            "loans_on_tape": {
                "loans": int(loans.in_asset_index.sum()),
                "of_loans_owned": len(loans),
                "pct": pct(int(loans.in_asset_index.sum()), len(loans)),
            },
        },
        "monthly_payments_asset_index_vs_warehouse": monthly_match(accounts),
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
