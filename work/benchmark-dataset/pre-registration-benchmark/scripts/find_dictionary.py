"""Find a data dictionary in a seller tape, if it ships one.

    uv run python find_dictionary.py PT15018
    uv run python find_dictionary.py --all

A dictionary is the only evidence that speaks to WHAT A COLUMN MEANS -- the one
question no guard can answer. `Data Vencido -> default_date` is a judgement from
a Portuguese word; a dictionary turns it into something the seller stated.

TWO ROUTES, structural first:

  structural  a sheet whose VALUES are another sheet's COLUMN NAMES. That is what
              a dictionary IS, and it needs no vocabulary -- it works whether the
              seller calls it `Dicionário`, `Descripción de campos` or nothing.
  by name     a sheet named dict/gloss/defin/legend/layout/campo/descri, as a
              fallback for a dictionary describing columns we did not load.

!! NONE OF THE 12 PORTUGUESE TAPES SHIPS ONE. Checked 2026-10-07, both routes,
  164 distinct sheet names: zero. A dictionary for these books, if it exists, is
  a separate PDF or an email attachment -- ask the deal owner. The detector runs
  anyway, because the next seller may include one and it costs milliseconds.

OUTPUT feeds the mapping review as an EVIDENCE TIER:

    PROVEN     arithmetic reconciliation (find_strats.py)
    ATTESTED   the seller's own dictionary says so      <- this file
    JUDGEMENT  inferred from the column name

Today every mapping except the balance and the scope rule sits at JUDGEMENT,
which is exactly where the residual risk is.
"""
import json
import re
import sys
from pathlib import Path
import pandas as pd

import paths as _P

HERE = Path(__file__).resolve().parent          # scripts/
BASE = HERE.parent                              # pre-registration-benchmark/
TAPES = _P.TAPES
OUT = _P.DICTIONARIES

NAME_PAT = re.compile(r"dict|gloss|defin|legend|layout|campo|descri|field", re.I)
MIN_OVERLAP = 8        # fewer than this and it is coincidence, not a dictionary
MAX_LEN = 70           # a column name, not a sentence


def _record_scan(out_dir, deal, found, detail):
    """A per-deal file ONLY where something was found, plus one index line.

    !! AN EMPTY FILE IS NOT NOTHING - IT IS PROOF WE LOOKED. Deleting it
    outright loses that: an absent strats file cannot be told from a deal
    nobody ever scanned, and "we searched 648 combinations and found no
    published figure" is a real finding worth keeping.
    So the finding moves to `_scanned.json`, one line per deal, and the
    per-deal file exists only when there is something IN it. Thirteen empty
    dictionaries and four empty strat files become one index.
    """
    import datetime as _dt
    out_dir.mkdir(parents=True, exist_ok=True)
    idx = out_dir / "_scanned.json"
    try:
        log = json.loads(idx.read_text()) if idx.exists() else {}
    except Exception:
        log = {}
    log[deal] = {"found": int(found), "at": _dt.date.today().isoformat(),
                 "detail": detail}
    idx.write_text(json.dumps(dict(sorted(log.items())), indent=2) + "\n")
    stale = out_dir / f"{deal}.json"
    if not found and stale.exists():
        stale.unlink()
    return bool(found)

def norm(x):
    return " ".join(str(x).split())


def find(deal):
    t = pd.read_parquet(TAPES / f"{deal}.parquet")
    t["cn"] = t.column_name.map(norm)
    cols_by_sheet = {sh: set(g.cn.unique()) for sh, g in t.groupby("source_sheet")}
    every = {c for s in cols_by_sheet.values() for c in s if len(c) > 3}

    hits = []
    for sh, g in t.groupby("source_sheet"):
        vals = {norm(v) for v in g.value.dropna().unique() if 3 < len(str(v)) < MAX_LEN}
        # a dictionary describes OTHER sheets, not itself
        describes = vals & (every - cols_by_sheet[sh])
        if len(describes) >= MIN_OVERLAP:
            hits.append({"sheet": sh, "route": "structural",
                         "columns_described": len(describes),
                         "examples": sorted(describes)[:5]})
        elif NAME_PAT.search(str(sh)):
            hits.append({"sheet": sh, "route": "name", "columns_described": len(describes),
                         "examples": sorted(describes)[:5]})

    res = {"deal": deal, "dictionaries": hits,
           "status": "found" if hits else "none -- ask the deal owner whether one "
                                          "exists as a separate PDF or attachment"}
    if _record_scan(OUT, deal, len(hits), "no data dictionary on this tape"
                    if not hits else f"{len(hits)} sheet(s) describe columns"):
        (OUT / f"{deal}.json").write_text(json.dumps(res, indent=2))
    if hits:
        for h in hits:
            print(f"{deal}: {h['sheet'][:40]:<42} ({h['route']}) describes "
                  f"{h['columns_described']} columns")
    else:
        print(f"{deal}: no dictionary -- every mapping stays at JUDGEMENT tier")
    return 0 if hits else 1


if __name__ == "__main__":
    a = sys.argv[1:] or ["PT15018"]
    if a[0] == "--all":
        for d in sorted(p.stem for p in TAPES.glob("*.parquet")):
            find(d)
        sys.exit(0)
    sys.exit(find(a[0]))
