"""Print the "why a deal doesn't reconcile" table split by market and deal type, as markdown.

    uv run python work/hackathon_dataset/bug_fixes_impact/reasons_by_market.py

Runs deal_reasons.sql on the sandbox. Columns are market (FS, Non-FS, Unknown, from Intrum's product on the
batch) within deal type (one-off, forward flow); cells count deals.
"""

from __future__ import annotations

from pathlib import Path

import datalake
import pandas as pd

HERE = Path(__file__).parent
REASONS = [
    "Bought before Oct 2014; matches PAM from Nov 2014 on",
    "Bought before Oct 2014; still below 90% from Nov 2014",
    "No cases in CAT (bought 2001-2010)",
    "Bought after Oct 2014; CAT below 90%",
    "No CAT payments, though the deal has cases",
    "CAT above 110%",
    "Within 10%, but CAT missing some months",
    "No PAM in the window",
]
COLUMNS = [(t, s) for t in ("one-off", "forward flow") for s in ("FS", "Non-FS", "Unknown")]


def table(deals: pd.DataFrame) -> str:
    counts = deals.groupby(["reason", "deal_type", "sector"]).size()

    def row(label: str, subset: pd.DataFrame, bold: bool = False) -> str:
        c = subset.groupby(["deal_type", "sector"]).size()
        cells = [str(int(c.get(col, 0))) for col in COLUMNS] + [str(len(subset))]
        if bold:
            label, cells = f"**{label}**", [f"**{x}**" for x in cells]
        return "| " + " | ".join([label, *cells]) + " |"

    header = ["Why it doesn't reconcile"] + [f"{s} {'one-off' if t == 'one-off' else 'FF'}" for t, s in COLUMNS] + ["All"]
    lines = ["| " + " | ".join(header) + " |", "|---|" + "---:|" * (len(header) - 1)]
    failing = deals[deals.reason != "Reconcile from purchase"]
    lines += [row(r, deals[deals.reason == r]) for r in REASONS]
    lines.append(row("Total not reconciling", failing, bold=True))
    lines.append(row("Reconcile from purchase", deals[deals.reason == "Reconcile from purchase"]))
    lines.append(row("All Swedish deals", deals, bold=True))
    assert counts.sum() == len(deals)
    return "\n".join(lines)


def main() -> None:
    deals = datalake.q(HERE / "deal_reasons.sql", connection="dev", warehouse="DEV_WH", lower=True)
    print(table(deals))


if __name__ == "__main__":
    main()
