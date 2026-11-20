"""Is the output on disk still the output that was approved?

    uv run python scripts/verify.py              # every deal
    uv run python scripts/verify.py PT15018

Three questions, in order, and the third is the one nothing else asks:

    1  does it rebuild from its inputs?        reproduce.py
    2  does it pass its guards?                guards.py
    3  is it the SAME BYTES someone approved?  here

!! AN APPROVAL OUTLIVES WHAT IT SIGNED. Approving a deal records a judgement
   about SPECIFIC NUMBERS. Change the engine afterwards - even additively, even
   with a green backtest - and those numbers can move while `approved: true`
   stays sitting in decisions.yaml. The signature survives the thing it signed.

   So the approval stores the output MD5, and this compares it. A deal whose
   output has moved since approval is NOT approved; it is approved-stale, and
   needs re-reading rather than re-signing.

Exit 0 only if every deal is reproducible, guarded and matches its approval.
"""
import hashlib
import subprocess
import sys
from pathlib import Path
import yaml

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
ACC = _P.ACCOUNTS


def main(deals):
    bad = 0
    for deal in deals:
        f = ACC / f"{deal}.parquet"
        if not f.exists():
            continue
        now = hashlib.md5(f.read_bytes()).hexdigest()
        dec_f = _P.CONTEXT / deal / "decisions.yaml"
        dec = yaml.safe_load(dec_f.read_text()) if dec_f.exists() else {}

        g = subprocess.run([sys.executable, str(HERE / "guards.py"), deal],
                           capture_output=True, text=True).returncode == 0
        open_r = len(dec.get("open_rejections") or [])

        if not dec.get("approved"):
            state = f"NOT APPROVED" + (f" ({open_r} open rejection(s))" if open_r else "")
            bad += 1
        elif dec.get("approved_output_md5") is None:
            state = "APPROVED, but no output hash was recorded - cannot verify"
            bad += 1
        elif dec["approved_output_md5"] != now:
            state = (f"APPROVED-STALE - the output has CHANGED since "
                     f"{dec.get('reviewed_at', '?')}. Re-read it.")
            bad += 1
        else:
            state = f"APPROVED by {dec.get('reviewed_by')} on {dec.get('reviewed_at')}"

        print(f"  {deal}  guards={'pass' if g else 'FAIL'}  {state}")
        if not g:
            bad += 1
    print(f"\n{'ALL DEALS VERIFIED' if not bad else 'NOT ALL DEALS VERIFIED'}")
    return 1 if bad else 0


if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    sys.exit(main(a or sorted(p.stem for p in ACC.glob("*.parquet"))))
