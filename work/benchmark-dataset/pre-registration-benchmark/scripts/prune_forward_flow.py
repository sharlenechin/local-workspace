"""Remove the outputs of deals that are forward flows, which are not cleaned.

    uv run python scripts/prune_forward_flow.py            # say what it would remove
    uv run python scripts/prune_forward_flow.py --remove   # actually remove

!! THESE OUTPUTS WERE BUILT BEFORE THE RULE EXISTED, and they look exactly
   like a one-off's: an accounts file, a long table, a review sheet, a
   backtest baseline. A consumer reading `portugal/cleaned/` cannot tell
   that EUR 255,276,889.23 of what they are reading is a total of what
   ARRIVED under a monthly contract rather than a total of six books.
   That is why they go, rather than being left with a warning in them.

!! NOTHING IN assets/ IS EVER TOUCHED. The tapes stay, the registry rows
   stay, and `run.py <deal> --anyway` still cleans one on demand. This
   removes DERIVED files only - everything it deletes can be rebuilt by one
   command, which is the whole reason it is safe to delete.
"""
import shutil
import sys

import pandas as pd

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import paths as _P


def main(remove=False):
    if not _P.DEALS.exists():
        print("no deals.csv")
        return 1
    d = pd.read_csv(_P.DEALS)
    if "deal_type" not in d.columns:
        print("deals.csv carries no deal_type -- run find_cutoff/deal typing first")
        return 1
    ff = sorted(d.loc[d.deal_type == "forward_flow", "deal_id"].astype(str))
    if not ff:
        print("no forward-flow deals recorded")
        return 0

    total, found = 0.0, []
    for deal in ff:
        hits = []
        acc = _P.ACCOUNTS / f"{deal}.parquet"
        if acc.exists():
            a = pd.read_parquet(acc)
            col = ("cutoff_balance" if a.cutoff_balance.notna().any()
                   else "cutoff_principal")
            total += float(a[col].sum())
            hits.append((acc, f"{len(a):,} loans, EUR {a[col].sum():,.2f}"))
        for f in (_P.ACCOUNTS / f"{deal}.meta.json",
                  _P.ADDITIONAL / f"{deal}.parquet",
                  _P.PAYMENTS / f"{deal}.parquet",
                  _P.PAYMENTS / f"{deal}.meta.json",
                  _P.BASELINE / f"{deal}.json",
                  _P.STRATS / f"{deal}.json",
                  _P.DICTIONARIES / f"{deal}.json"):
            if f.exists():
                hits.append((f, ""))
        ctx = _P.CONTEXT / deal
        if ctx.exists():
            hits.append((ctx, f"{len(list(ctx.glob('*')))} file(s)"))
        if hits:
            found.append((deal, hits))

    if not found:
        print(f"{len(ff)} forward-flow deal(s), none has any output. Nothing to do.")
        return 0

    verb = "REMOVED" if remove else "WOULD REMOVE"
    print(f"{len(found)} forward-flow deal(s) still have cleaned output:\n")
    for deal, hits in found:
        print(f"  {deal}")
        for f, why in hits:
            print(f"     {verb}  {f.relative_to(_P.BASE)}"
                  + (f"   ({why})" if why else ""))
            if remove:
                shutil.rmtree(f) if f.is_dir() else f.unlink()
    print(f"\nEUR {total:,.2f} of cleaned balance across {len(found)} deal(s).")
    print("The TAPES and the REGISTRY ROWS are untouched: "
          "`run.py <deal> --anyway`")
    print("rebuilds any of it.")
    if not remove:
        print("\nDry run. Add --remove to delete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main("--remove" in sys.argv))
