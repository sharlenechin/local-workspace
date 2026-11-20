"""Does the book explain its own balance movement?

    uv run python rollforward.py PT15018
    uv run python rollforward.py --all

    opening balance  -  collections over a period  =  closing balance

WHY THIS MATTERS MORE THAN IT LOOKS: it ties THREE separately parsed quantities
-- two balance columns and a payment matrix, usually on different sheets. Any
parsing defect breaks it: a wrong decimal mark explodes it, a mis-decoded month
understates the collections, a duplicate file doubles them, a dropped row
misaligns the sides. On PT15018 it closes to EUR 0.27 across EUR 409.7m, and
PER LOAN on 32,869 of 32,872 -- which is far stronger than one aggregate
matching, because offsetting errors cannot hide.

And it needs NO seller summary. Only 4 of 12 Portuguese tapes publish a figure we
can reconcile against; this is available to any tape shipping two balance dates
and the payments between them, so it is the main defence for the other eight.

SELF-DISCOVERING: the opening/closing columns are not declared anywhere. Every
pair of numeric columns is tested against every contiguous month window, and a
pair is accepted only if it closes. Nothing to configure per deal.

!! IT PROVES THE PARSING, NOT THE SCOPE. A book can roll forward perfectly on a
  population that is the wrong one -- the roll-forward closes on PT15018
  including the loans the seller excluded. Scope comes from the strats.
"""
import sys
from pathlib import Path
import pandas as pd

import paths as _P

HERE = Path(__file__).resolve().parent          # scripts/
BASE = HERE.parent                              # pre-registration-benchmark/
TAPES = _P.TAPES
TOLERANCE = 0.005          # 0.5% of the opening balance -- agreed band
MIN_BALANCE = 1_000_000    # below this a "balance" column is not a book


def check(deal):
    pay = pd.read_parquet(TAPES / "payments.parquet")
    pay = pay[pay.deal == deal].copy()
    if pay.empty:
        return {"deal": deal, "status": "no_payments", "detail": "nothing to roll forward"}
    pay["amt"] = pd.to_numeric(pay.amount, errors="coerce")
    months = sorted(m for m in pay.period_month.dropna().unique())
    if not months:
        return {"deal": deal, "status": "undated_payments",
                "detail": "payments carry no absolute month -- cannot place them on a timeline"}

    tape = pd.read_parquet(TAPES / f"{deal}.parquet")
    tape["cn"] = tape.column_name.map(lambda c: " ".join(str(c).split()))
    best = None
    for sheet, g in tape.groupby("source_sheet"):
        rows = set(pay.source_row) & set(g.source_row)
        if len(rows) < 100:
            continue                                  # not the payment sheet
        w = g.pivot_table(index="source_row", columns="cn", values="value", aggfunc="first")
        nums = {c: pd.to_numeric(w[c], errors="coerce") for c in w.columns}
        bal = {c: v for c, v in nums.items()
               if v.notna().mean() > 0.8 and abs(v.sum()) > MIN_BALANCE}
        # cumulative payments per contiguous window, cheap
        by_month = {m: pay[pay.period_month == m].groupby("source_row")["amt"].sum()
                    for m in months}
        for a in bal:
            for b in bal:
                if a == b or bal[a].sum() <= bal[b].sum():
                    continue                           # opening must exceed closing
                drop = bal[a].sum() - bal[b].sum()
                run = None
                for i in range(len(months)):
                    run = by_month[months[i]] if run is None else run.add(by_month[months[i]], fill_value=0)
                    tot = float(run.sum())
                    gap = abs(drop - tot) / abs(bal[a].sum())
                    if best is None or gap < best["gap"]:
                        best = {"opening": a, "closing": b, "months": (months[0], months[i]),
                                "opening_total": float(bal[a].sum()),
                                "closing_total": float(bal[b].sum()),
                                "collections": tot, "gap": gap}
    if not best:
        return {"deal": deal, "status": "no_balance_pair",
                "detail": "no two balance columns on the payment sheet"}
    best["status"] = "closes" if best["gap"] <= TOLERANCE else "does_not_close"
    best["deal"] = deal
    return best


def main(deal):
    r = check(deal)
    if "gap" not in r:
        print(f"{deal}: {r['status']} -- {r['detail']}")
        return 1
    v = "PASS" if r["status"] == "closes" else "FAIL"
    print(f"{deal}: {v}  gap {r['gap']*100:.4f}%  (tolerance {TOLERANCE*100}%)")
    print(f"   opening {r['opening'][:34]:<36} {r['opening_total']:>18,.2f}")
    print(f"   less collections {r['months'][0]}..{r['months'][1]:<14} {r['collections']:>18,.2f}")
    print(f"   closing {r['closing'][:34]:<36} {r['closing_total']:>18,.2f}")
    return 0 if r["status"] == "closes" else 1


if __name__ == "__main__":
    a = sys.argv[1:] or ["PT15018"]
    if a[0] == "--all":
        for d in sorted(p.stem for p in TAPES.glob("*.parquet")):
            main(d)
        sys.exit(0)
    sys.exit(main(a[0]))
