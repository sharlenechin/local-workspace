"""Build `processed/` from `assets/`, filed by deal.

    uv run python .../scripts/intake.py            # say what it would do
    uv run python .../scripts/intake.py --build    # do it

    assets/        YOU drop files here, in ANY folder shape. Nothing in this
      |            pipeline writes to it, renames inside it, or deletes from
      |            it. It is the archive of what we were sent.
      v  intake.py   finds the deal code, COPIES, files it by deal
    processed/<DEAL>/...
      |
      v  check_new_data.py --refresh   -> tapes/
      v  scripts/run.py <DEAL>         -> cleaned/

!! INTAKE COPIES. IT USED TO MOVE, AND THAT WAS THE DEFECT UNDER EVERYTHING
   ELSE. A drop zone that empties itself is not an archive: once a file had
   been filed, the delivery as sent no longer existed anywhere, so "keep the
   original and process the duplicate" could not be honoured however many
   holding folders were bolted on. Copying makes `processed/` entirely
   derived - delete it and this script rebuilds it - and makes `assets/` the
   single thing worth backing up.

!! WHICH MEANS NO DECISION MAY BE STORED IN `processed/`. A file we have
   decided NOT to use is recorded in `excluded.yaml`, which sits beside this
   script and survives a rebuild. Parking it in an underscore folder inside
   a derived tree would lose the decision the next time the tree is rebuilt.

!! A FILE WITH NO DEAL CODE IS NOT GUESSED AT. It is reported, by path, and
   left exactly where it is. Renaming somebody's delivery to make it parse
   is a silent assumption about which book it belongs to.
"""
import hashlib
import os
import re
import shutil
import sys
import pathlib
from pathlib import Path

import yaml

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
ASSETS = _p.ASSETS
PROCESSED = _p.PROCESSED
EXCLUDED = _p.EXCLUDED
ENGINES = {".xlsx", ".xls", ".xlsb", ".csv"}
DEAL = _P.DEAL_RE


def md5(p):
    return hashlib.md5(p.read_bytes()).hexdigest()


def excluded():
    """{filename: reason} for files we hold but have decided not to use."""
    if not EXCLUDED.exists():
        return {}
    d = yaml.safe_load(EXCLUDED.read_text()) or {}
    return {k: v.get("reason", "") if isinstance(v, dict) else str(v)
            for k, v in d.items()}


def main(build=False):
    ASSETS.mkdir(parents=True, exist_ok=True)
    if not ASSETS.exists():
        print(f"no assets folder at {ASSETS}")
        return 1

    skip = excluded()
    files = sorted(p for p in ASSETS.rglob("*") if p.is_file()
                   and not p.name.startswith("~$") and not p.name.startswith("."))

    plan, dupes, versions, unfiled, other, held = [], [], [], [], [], []
    seen = {}                      # md5 -> first asset path that had it

    for p in files:
        rel = p.relative_to(ASSETS)
        if p.suffix.lower() not in ENGINES:
            other.append((rel, p.suffix.lower() or "no extension"))
            continue
        if p.name in skip:
            held.append((rel, skip[p.name]))
            continue
        m = DEAL.search(str(rel))
        if not m:
            unfiled.append(rel)
            continue

        h = md5(p)
        if h in seen:
            prior = seen[h]
            a = DEAL.search(str(prior))
            dupes.append((rel, prior, a.group(1) if a else None, m.group(1)))
            continue
        seen[h] = rel

        deal = m.group(1)
        parts = [x for x in rel.parts if DEAL.fullmatch(x) is None]
        dest = PROCESSED / deal / Path(*parts) if parts else PROCESSED / deal / p.name
        if dest.exists() and md5(dest) == h:
            continue                                  # already built, unchanged
        if dest.exists():
            versions.append((rel, dest.relative_to(HERE)))
            dest = dest.with_name(f"{dest.stem}__v{h[:8]}{dest.suffix}")
        plan.append((deal, p, dest))

    # anything in processed/ with no asset behind it is a leftover, because
    # processed/ is a MIRROR. Named, never deleted without being asked.
    want = {d for _, _, d in plan} | {
        PROCESSED / DEAL.search(str(p.relative_to(ASSETS))).group(1)
        / Path(*[x for x in p.relative_to(ASSETS).parts if DEAL.fullmatch(x) is None])
        for p in files
        if p.suffix.lower() in ENGINES and p.name not in skip
        and DEAL.search(str(p.relative_to(ASSETS)))}
    orphans = sorted(q.relative_to(HERE) for q in PROCESSED.rglob("*")
                     if q.is_file() and q not in want
                     and "__v" not in q.name) if PROCESSED.exists() else []

    verb = "copied" if build else "WOULD copy"
    print(f"{len(files)} file(s) in assets/\n")
    if plan:
        print(f"{verb} {len(plan)}:")
        for deal, src, dest in plan:
            print(f"  {deal}  {src.relative_to(ASSETS)}"
                  f"\n        -> {dest.relative_to(HERE)}")
            if build:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest)
    else:
        print("processed/ is already in step with assets/ - nothing to copy")

    if dupes:
        print(f"\n{len(dupes)} identical copy(ies) in assets/ - kept there, "
              f"processed ONCE:")
        for rel, prior, theirs, mine in dupes:
            flag = ("  !! and that copy is filed under a DIFFERENT DEAL"
                    if theirs and mine and theirs != mine else "")
            print(f"  {rel}\n        same bytes as {prior}{flag}")
    if versions:
        print(f"\n!! {len(versions)} NEW VERSION(S) of a file already "
              f"processed. Both are kept;\n   NOTHING was replaced. If the "
              f"old one is WRONG, say so in excluded.yaml;\n   if it is "
              f"merely older, settle it with a `prefer` row in mappings.csv:")
        for rel, dest in versions:
            print(f"  {rel}\n        existing: {dest}")
    if held:
        print(f"\n{len(held)} file(s) held in assets/ and deliberately NOT "
              f"processed (excluded.yaml):")
        for rel, why in held:
            print(f"  {rel}\n        {why}")
    if unfiled:
        print(f"\n!! {len(unfiled)} file(s) carry NO deal code (PTnnnnn) "
              f"anywhere in their path.\n   NOT processed, and left exactly "
              f"where they are - guessing a deal is worse:")
        for rel in unfiled:
            print(f"  {rel}")
    if other:
        print(f"\n{len(other)} file(s) are not a spreadsheet, so nothing "
              f"reads them. Kept in assets/:")
        for rel, ext in other:
            print(f"  {ext:<14} {rel}")
    if orphans:
        print(f"\n!! {len(orphans)} file(s) in processed/ have NO asset "
              f"behind them.\n   processed/ is a mirror of assets/, so these "
              f"are leftovers. Delete them by hand\n   once you are sure:")
        for rel in orphans:
            print(f"  {rel}")

    if not build:
        print(f"\nDry run. Add --build to copy.")
    else:
        print(f"\nNext:\n    uv run python work/benchmark-dataset/"
              f"pre-registration-benchmark/scripts/check_new_data.py "
              f"--refresh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main("--build" in sys.argv))
