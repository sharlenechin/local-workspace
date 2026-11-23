"""Find the loans Intrum moved from system 1062 to 2080; writes moved_loans.csv and prints the list to paste.

    uv run python work/workshop/dataset/HEI-SE17039/bridge_check/find_moved_loans.py
"""

from __future__ import annotations

from pathlib import Path

import datalake
import pandas as pd

HERE = Path(__file__).parent
MIN_EQUAL_MONTHS = 3
RUNNER_UP_MARGIN = 2

CLOSING_SQL = """
SELECT
    case_bk,
    registration_date,
    closing_date,
    closing_code
FROM prod.npl_common.dim_case
WHERE is_current_flag
    AND case_bk IN ({ids})
"""


def payment_pairs(months: pd.DataFrame) -> pd.DataFrame:
    """Pairs whose monthly payments match to the öre in at least 3 months, each the other's clear best."""
    months = months.assign(paid=months.paid.astype(float).round(2))
    months = months[months.paid > 0]
    new = months[(months.source == "asset_index") & months.case_bk.str.startswith("2080")]
    old = months[(months.source == "raw_cat") & months.case_bk.str.startswith("1062")]

    equal = new.merge(old, on=["month_start", "paid"], suffixes=("_new", "_old"))
    score = equal.groupby(["case_bk_new", "case_bk_old"]).size().rename("equal_months").reset_index()
    score = score.sort_values("equal_months", ascending=False)

    def clear_best(key: str) -> pd.DataFrame:
        """Each case's best partner, kept only if the runner-up is less than half as good."""
        rank = score.groupby(key).cumcount()
        best = score[rank == 0].set_index(key)
        runner_up = score[rank == 1].set_index(key).equal_months
        best["runner_up"] = runner_up.reindex(best.index).fillna(0)
        return best[best.runner_up * RUNNER_UP_MARGIN <= best.equal_months]

    best_for_new = clear_best("case_bk_new").reset_index()
    best_for_old = clear_best("case_bk_old").reset_index()
    pairs = best_for_new.merge(best_for_old, on=["case_bk_new", "case_bk_old", "equal_months"])
    pairs = pairs[pairs.equal_months >= MIN_EQUAL_MONTHS]
    return pairs.rename(columns={"case_bk_old": "old_case", "case_bk_new": "new_case"})[
        ["old_case", "new_case"]
    ]


def closed_on_move(pairs: pd.DataFrame) -> pd.DataFrame:
    """Keep pairs whose old case closed with code 9 within a day of the new case opening."""
    ids = ", ".join(f"'{c}'" for c in pd.concat([pairs.old_case, pairs.new_case]).unique())
    cases = datalake.q(CLOSING_SQL.format(ids=ids), lower=True).set_index("case_bk")
    old = cases.reindex(pairs.old_case)
    new = cases.reindex(pairs.new_case)
    gap = (old.closing_date.values - new.registration_date.values).astype("timedelta64[D]").astype(float)
    keep = (old.closing_code.astype(str).str.replace(".0", "", regex=False).values == "9") & (
        (gap >= 0) & (gap <= 1)
    )
    return pairs[keep]


def main() -> None:
    by_principal = datalake.q(HERE / "moved_by_principal.sql", lower=True)
    by_payments = closed_on_move(payment_pairs(datalake.q(HERE / "payment_months.sql", lower=True)))

    both = by_principal.merge(by_payments, how="outer", indicator=True)
    both["found_by"] = both._merge.map(
        {"left_only": "principal", "right_only": "payments", "both": "principal and payments"}
    )
    pairs = both.drop(columns="_merge").sort_values("old_case")
    if not (pairs.old_case.is_unique and pairs.new_case.is_unique):
        raise SystemExit("A case is paired with two different partners: check before using the list.")

    pairs.to_csv(HERE / "moved_loans.csv", index=False)
    print(pairs.found_by.value_counts().to_string(), f"\n{len(pairs)} pairs -> moved_loans.csv\n")
    items = [f"('{o}', '{n}')" for o, n in zip(pairs.old_case, pairs.new_case)]
    print(",\n".join("        " + ", ".join(items[i : i + 4]) for i in range(0, len(items), 4)))


if __name__ == "__main__":
    main()
