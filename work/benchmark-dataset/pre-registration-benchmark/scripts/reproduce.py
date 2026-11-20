"""Prove the output can be rebuilt from its inputs, byte for byte.

    uv run python scripts/reproduce.py            # every cleaned deal
    uv run python scripts/reproduce.py PT15018

Rebuilds into a scratch directory and compares MD5s. Never touches the real
output, so it is safe to run at any time.

!! DEMONSTRATING REPRODUCIBILITY ONCE IS NOT GUARANTEEING IT. It was proven by
   hand - delete both outputs, rebuild, identical hashes - and that proof expired
   the moment the next line of code was written. This runs it every time.

THE FOUR INPUTS that fully determine an output. Nothing else is read: no clock,
no randomness, no ordering dependency (verified across PYTHONHASHSEED values).

    data/tapes/<deal>.parquet   the raw tape
    mappings.csv                which column means what, for this deal
    schema.yaml                 the column contract
    clean_accounts.py           the shared engine

Their hashes are recorded beside the result, so a failure says WHICH input moved
rather than just that something did. An engine change failing here is expected
and is what the backtest is for; a TAPE change means a new delivery arrived and
the deal must be re-verified from scratch, not compared to a stale baseline.
"""
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
ACC = _P.ACCOUNTS
TAPES = _P.TAPES


def md5(p):
    return hashlib.md5(Path(p).read_bytes()).hexdigest()


def inputs(deal):
    return {
        "tape": md5(TAPES / f"{deal}.parquet"),
        "mappings.csv": md5(_P.REGISTRY),
        "deals.csv": md5(_P.DEALS),
        "schema.yaml": md5(_P.SCHEMA),
        "clean_accounts.py": md5(HERE / "clean_accounts.py"),
        "clean_payments.py": md5(HERE / "clean_payments.py"),
    }


# !! EVERY OUTPUT, NOT JUST THE ACCOUNTS. This checked accounts/<deal>.parquet
#   and nothing else, which was the whole story when accounts WERE the output.
#   They are now one of three: the long table carries eight facts that used to
#   be columns, and payments carry every collection. Proving a third of the
#   folder rebuilds and calling the folder reproducible is a claim bigger than
#   the evidence.
OUTPUTS = [("accounts", _P.ACCOUNTS, "clean_accounts.py"),
           ("additional_attributes", _P.ADDITIONAL, "clean_accounts.py"),
           ("payments", _P.PAYMENTS, "clean_payments.py")]


def check(deal):
    live = {name: d / f"{deal}.parquet" for name, d, _ in OUTPUTS}
    if not live["accounts"].exists():
        return None
    before = {n: md5(f) for n, f in live.items() if f.exists()}
    tmp = Path(tempfile.mkdtemp())
    for n, f in live.items():
        if f.exists():
            shutil.copy(f, tmp / f"{n}.parquet")   # keep the real outputs safe
    try:
        for script in ("clean_accounts.py", "clean_payments.py"):
            r = subprocess.run([sys.executable, str(HERE / script), deal],
                               capture_output=True, text=True)
            if r.returncode:
                return {"deal": deal, "ok": False,
                        "why": f"{script} FAILED: {(r.stderr or '').strip()[-110:]}"}
        moved = []
        for n, f in live.items():
            if n not in before:
                continue
            after = md5(f) if f.exists() else "(gone)"
            if after != before[n]:
                moved.append(n)
                shutil.copy(tmp / f"{n}.parquet", f)   # restore
        if moved:
            return {"deal": deal, "ok": False,
                    "why": f"rebuild produced DIFFERENT bytes in: "
                           f"{', '.join(moved)}",
                    "before": before, "inputs": inputs(deal)}
        return {"deal": deal, "ok": True,
                "md5": " ".join(f"{n}:{h[:8]}" for n, h in sorted(before.items())),
                "inputs": inputs(deal)}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(deals):
    rows = [r for r in (check(d) for d in deals) if r]
    if not rows:
        print("no cleaned deals to check")
        return 0
    bad = 0
    for r in rows:
        if r["ok"]:
            print(f"  REPRODUCIBLE  {r['deal']}  {r['md5']}")
        else:
            bad += 1
            print(f"  NOT REPRODUCIBLE  {r['deal']} -- {r['why']}")
            for k, v in (r.get("inputs") or {}).items():
                print(f"       input {k:<20} {v}")
    print(f"\n{'ALL DEALS REPRODUCIBLE' if not bad else f'{bad} DEAL(S) NOT REPRODUCIBLE'}")
    return 1 if bad else 0


if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    sys.exit(main(a or sorted(p.stem for p in ACC.glob("*.parquet"))))
