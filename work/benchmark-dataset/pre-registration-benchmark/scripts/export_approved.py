"""Export the APPROVED deals' cleaned outputs as CSV, one folder per deal.

    uv run python scripts/export_approved.py

Writes to work/asset-index/cloud-agent-check/<deal>/, for a reader outside
this pipeline who has pandas and nothing else.

!! ONLY APPROVED DEALS LEAVE. A deal that has not been signed is a draft, and
   a draft that has been handed to somebody is a figure in circulation nobody
   can retract. Approval is read from decisions.yaml, never from a flag here.

!! THE SIGNATURE IS RE-CHECKED AT EXPORT. An approval pins a fingerprint of
   all three outputs (T62). If the parquet has moved since signing, the export
   REFUSES that deal rather than shipping content nobody approved.

!! EVERY ID IS WRITTEN AS TEXT. A 19-digit account number read back by
   `pd.read_csv` without `dtype=str` becomes a float and loses its last
   digits - the same defect T13 cost us inside the pipeline. A README beside
   the files says so, because the trap moves with the data.
"""
import sys
from pathlib import Path

import pandas as pd
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths as _P
import style

OUT = _P.BASE.parents[1] / "asset-index" / "cloud-agent-check"
TABLES = {"accounts": _P.ACCOUNTS,
          "additional_attributes": _P.ACCOUNTS.parent / "additional_attributes",
          "payments": _P.ACCOUNTS.parent / "payments"}


def approved(deal):
    f = _P.BASE / "portugal" / "cleaning-context" / deal / "decisions.yaml"
    if not f.exists():
        return None
    return yaml.safe_load(f.read_text()) or {}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    deals = sorted(f.stem for f in _P.ACCOUNTS.glob("PT*.parquet"))
    index, skipped = [], []

    for deal in deals:
        dec = approved(deal)
        if not dec or not dec.get("approved"):
            skipped.append((deal, "not approved"))
            continue
        pinned = dec.get("approved_output_md5")
        now = style.output_fingerprint(deal)
        if pinned and pinned != now:
            skipped.append((deal, "APPROVAL IS STALE -- output changed since "
                                  "signing. Re-sign before exporting."))
            continue

        d = OUT / deal
        d.mkdir(parents=True, exist_ok=True)
        for name, src in TABLES.items():
            f = src / f"{deal}.parquet"
            if not f.exists():
                continue
            w = pd.read_parquet(f)
            w.to_csv(d / f"{name}.csv", index=False)
            index.append({"deal": deal, "table": name, "rows": len(w),
                          "columns": len(w.columns),
                          "file": f"{deal}/{name}.csv"})
        print(f"  {deal:<9} " + ", ".join(
            f"{r['table']} {r['rows']:,}" for r in index if r["deal"] == deal))

    pd.DataFrame(index).to_csv(OUT / "_index.csv", index=False)
    (OUT / "README.md").write_text(_readme(index, skipped))

    print(f"\n{len({r['deal'] for r in index})} approved deal(s) exported to")
    print(f"  {OUT}")
    for deal, why in skipped:
        print(f"  skipped {deal}: {why}")
    return 0


def _readme(index, skipped):
    deals = sorted({r["deal"] for r in index})
    rows = "\n".join(
        f"| {r['deal']} | {r['table']} | {r['rows']:,} | {r['columns']} |"
        for r in index)
    skip = "\n".join(f"- {d}: {w}" for d, w in skipped) or "- none"
    return f"""# Cleaned Portuguese seller tapes - APPROVED deals only

Exported by `scripts/export_approved.py` from the pre-registration benchmark.
Every deal here has been read and signed by a human, and its signature was
re-checked against the data at export time.

## Read the ids as TEXT

    pd.read_csv("PT16023/accounts.csv", dtype=str)

Account numbers here run to 19 digits. Read without `dtype=str`, pandas makes
them floats and silently drops the last digits, so two different loans can
become the same number. Convert the amounts yourself after loading.

## The three tables, and how they join

    accounts               one row per loan, a FIXED set of columns that
                           means the same thing on every deal
    additional_attributes  everything else, long: one row per
                           (loan, column_name, column_value)
    payments               one row per payment. SIGNED - money in is
                           positive, money out is negative - so summing
                           `payment_amount` over anything gives the net

**Join on the `grain` column, not on `loan_id`.** Every table carries a
`grain` column naming the ONE id that joins all three for that deal. It is
`loan_id` on most deals and `client_id` on those whose seller records
collections against the BORROWER rather than the account. Joining those on
`loan_id` returns nothing from payments.

## What is here

| deal | table | rows | columns |
|---|---|---|---|
{rows}

## Not exported

{skip}

## Caveats that travel with the numbers

- `cutoff_*` amounts are as of that deal's `cutoff_date`. Where the column is
  null the seller did not state the figure - it is NEVER derived, so a null
  principal does not mean zero principal.
- `verification_status` says how far a deal got. `reconciled` means a figure
  the seller published was matched exactly; `consistent` means no published
  figure existed to check against. Neither means "correct".
- Forward-flow deals are absent by design: their tapes are monthly
  deliveries, not the book.
"""


if __name__ == "__main__":
    sys.exit(main())
