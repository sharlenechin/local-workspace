"""What has arrived, what changed, and which deals must be rebuilt.

    uv run python work/benchmark-dataset/pre-registration-benchmark/scripts/check_new_data.py
    uv run python work/benchmark-dataset/pre-registration-benchmark/scripts/check_new_data.py --refresh

Compares every source file under the data roots against `data/load_state.json`
and reports, per deal: NEW, CHANGED, REMOVED, unchanged. With --refresh it
reloads the tapes and tells you exactly which deals need re-cleaning.

!! WHY THIS EXISTS. Eight deal folders arrived and nothing said so. They were
   found only because someone happened to re-run the loader, two days later -
   and that run then CRASHED on one of them, aborting every write after it and
   leaving a tapes/ folder that was part fresh and part two days stale, with no
   error anyone saw because the loader's output was always piped somewhere.

!! A DEAL WHOSE TAPE CHANGES INVALIDATES ITS APPROVAL. That is the point of
   reporting per deal rather than per file: the approval sheet pins the tape's
   md5, so a changed tape stales the signature and the deal must be reviewed
   again. This tells you which, before you discover it by reading a stale sheet.

The deal code is found ANYWHERE in the path - `PT\\d{5}` - so a new delivery
can arrive in whatever folder shape the seller or the data room produces.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import pathlib
from pathlib import Path

# !! THESE THREE SCRIPTS USED TO LIVE INSIDE portugal/raw/ AND DERIVE EVERY
#   PATH FROM THEIR OWN LOCATION. That made `raw/` a folder of code AND data,
#   and it hard-wired one country into the loader: the deal pattern was typed
#   out as `PT\d{5}` in three separate files. They now sit in scripts/ with
#   everything else and resolve paths through paths.py, so `raw/` holds
#   nothing but assets/ and processed/, and a second country needs no edit
#   here at all.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import paths as _P

COUNTRY = os.environ.get("BENCHMARK_COUNTRY", "portugal")


def _paths():
    """Every path this script needs, for the country being processed."""
    pre = next(k for k, v in _P.COUNTRY_OF.items() if v == COUNTRY)
    return _P.for_deal(f"{pre}00000")


_p = _paths()
HERE = _p.RAW
OUT = _p.TAPES
STATE = OUT / "load_state.json"
ENGINES = {".xlsx", ".xls", ".xlsb"}
DEAL = _P.DEAL_RE

# !! TWO LISTS, DELIBERATELY. `LOADED` is what load_tapes.py actually reads.
#   Anything else under this folder is SEEN and reported, never read - because
#   silently widening what gets loaded would change a deal's population
#   without anyone reviewing it. `PT - Orange - Extract` holds six files the
#   loader has never touched, including PT18019 `..._v3.xlsx` - a version 3 of
#   a deal currently built from `Closing_data.xlsx`. That is a decision, not a
#   scan setting.
LOADED = [_p.PROCESSED]
SEEN_NOT_LOADED = []     # nothing waits any more: assets/ is the archive,
                         # processed/ is built from it, and intake.py
                         # reports anything it could not place.
ROOTS = LOADED


def deal_of(path, root):
    """The deal code, from ANYWHERE in the path or the filename.

    !! NOT `parts[0]`. That assumed one fixed folder shape - deal at the top,
       everything beneath it. A data room that ships
       `2026-01 delivery/PT20014/asset index/` or
       `PT20014_WiZink_tranche2.xlsx` at the root breaks it silently, and the
       files land under a "deal" that is really a folder name.
    """
    m = DEAL.search(str(path.relative_to(root)))
    return m.group(1) if m else None


def scan():
    """Every source file we can see, keyed by path, with a content hash."""
    found = {}
    for root in ROOTS:
        if not root.exists():
            continue
        for p in sorted(root.rglob("*")):
            if p.suffix.lower() not in ENGINES or p.name.startswith("~$"):
                continue
            d = deal_of(p, root)
            key = str(p.relative_to(HERE))
            found[key] = {
                "deal": d,
                "size": p.stat().st_size,
                "md5": hashlib.md5(p.read_bytes()).hexdigest(),
            }
    return found


def main(refresh=False):
    found = scan()
    was = json.loads(STATE.read_text()) if STATE.exists() else {}

    new = {k: v for k, v in found.items() if k not in was}
    changed = {k: v for k, v in found.items()
               if k in was and was[k]["md5"] != v["md5"]}
    gone = {k: v for k, v in was.items() if k not in found}
    unknown = sorted({k for k, v in found.items() if not v["deal"]})

    print(f"source files: {len(found):,} across {len(ROOTS)} root(s)")
    print(f"  new      {len(new):,}")
    print(f"  changed  {len(changed):,}")
    print(f"  removed  {len(gone):,}")
    print(f"  same     {len(found) - len(new) - len(changed):,}")

    # files present but outside every loaded root
    import hashlib as _h
    loaded_md5 = {v["md5"] for v in found.values()}
    outside = []
    for root in SEEN_NOT_LOADED:
        if not root.exists():
            continue
        for p in sorted(root.rglob("*")):
            if p.suffix.lower() not in ENGINES or p.name.startswith("~$"):
                continue
            md5 = _h.md5(p.read_bytes()).hexdigest()
            if md5 not in loaded_md5:
                outside.append((deal_of(p, root), str(p.relative_to(HERE))))
    if outside:
        print(f"\n!! {len(outside)} file(s) present but NOT LOADED - they sit "
              f"outside every root\n   load_tapes.py reads. Nothing has used "
              f"them; adding a root is a DECISION\n   because it changes a "
              f"deal's population:")
        for d, k in outside:
            print(f"     {d or '(no deal code)':<9} {k}")

    if unknown:
        print(f"\n!! {len(unknown)} file(s) carry NO deal code (PTnnnnn) anywhere "
              f"in their path.\n   They are read but filed under no deal:")
        for k in unknown[:6]:
            print(f"     {k}")

    touched = sorted({v["deal"] for v in list(new.values()) + list(changed.values())
                      + list(gone.values()) if v.get("deal")})
    if not touched:
        print("\nNothing has moved. No deal needs rebuilding.")
    else:
        print(f"\n{len(touched)} DEAL(S) AFFECTED:")
        for d in touched:
            n = sum(1 for v in new.values() if v["deal"] == d)
            c = sum(1 for v in changed.values() if v["deal"] == d)
            g = sum(1 for v in gone.values() if v["deal"] == d)
            bits = [f"{n} new" if n else "", f"{c} changed" if c else "",
                    f"{g} removed" if g else ""]
            print(f"  {d}  {', '.join(b for b in bits if b)}")

    if not refresh:
        if touched:
            print("\n  uv run python work/benchmark-dataset/pre-registration-benchmark/scripts/check_new_data.py --refresh")
        return 0

    print("\nreloading tapes...")
    r = subprocess.run([sys.executable, str(_P.LOADER)],
                       capture_output=True, text=True)
    sys.stderr.write(r.stderr[-1500:])
    if r.returncode:
        print("\n!! THE LOADER FAILED. Nothing is recorded as loaded, so this "
              "will\n   report the same files as new next time. Fix it first.",
              file=sys.stderr)
        return 1

    STATE.write_text(json.dumps(found, indent=2, sort_keys=True) + "\n")
    print(f"\nstate recorded: {len(found):,} file(s)")
    if touched:
        print("\nNOW RE-CLEAN THESE DEALS. Each one's tape has changed, so its")
        print("approval (if any) is STALE and it must be reviewed again:")
        for d in touched:
            print(f"    uv run python scripts/run.py {d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main("--refresh" in sys.argv))
