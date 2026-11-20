"""Find the figure a seller published about its own book, and the scope rule.

    uv run python find_strats.py PT15018
    uv run python find_strats.py --all

Writes strats/<deal>.json. Nothing else in this pipeline is allowed to claim
`reconciled` without a hit here.

HOW IT WORKS, and why it is a search and not a guess:

  1 harvest   every large number sitting in a SMALL region (a summary block is
              short; a loan table is not). These are candidate published totals.
  2 search    every (amount column x categorical filter) pair, for one whose sum
              reproduces a candidate EXACTLY, to the cent.
  3 a hit is PROOF, not a hypothesis. On PT15018, 714 combinations were searched
     and 2 matched -- both correct. 41 others landed within 1% and are wrong.
     Exactness is doing the work: a false positive would need an unrelated column
     to agree on all eleven significant digits.

!! THIS CANNOT TELL YOU WHAT A COLUMN MEANS. It proves `Total OPB Setembro 2015`
  is the column the seller totalled. That it is a September-2015 balance comes
  from reading the header -- and if you need a cut-off balance, that may be the
  wrong date. One human glance per deal, on the hits only.

No hit is not a failure: the deal lands `consistent` instead of `reconciled`.
"""
import json
import sys
from pathlib import Path
import pandas as pd

import paths as _P

HERE = Path(__file__).resolve().parent          # scripts/
BASE = HERE.parent                              # pre-registration-benchmark/
TAPES = _P.TAPES
OUT = _P.STRATS

SUMMARY_MAX_ROWS = 60      # a summary block is short; a loan table is not
MIN_CANDIDATE = 100_000    # a PORTFOLIO total is large. At 1,000 the round
                           # numbers collide: PT20006 "matched" credit_limit
                           # = 5,000.00 filtered by meses_antiguedad != '16'.
MAX_CARDINALITY = 15       # a scope flag has few values
TOL = 0.005                # half a cent
MAX_CANDIDATES = 200       # above this, an exact match is not evidence
MIN_SHARE = 0.10           # a published total is a BIG share of its own column.
                           # A filter that keeps 0.001% of a column and happens
                           # to hit a round number is arithmetic, not a strat.


TOTAL_WORDS = ("total", "totals", "soma", "totais", "grand total", "sum",
               "portfolio overview", "overall",
               # Excel's own Portuguese pivot-table grand-total label. PT15020
               # publishes under it and the exact-match test missed it.
               "total geral", "total general")


FOOTER_ROWS = 6            # a grand total sits at the very bottom, or near it

# sheet -> {source_row}: rows PROVEN to be published totals by the arithmetic
# above, so the search and the cleaner can both exclude them. Written by
# _harvest_sheet_footer, published in the strats JSON, never hand-edited.
TOTAL_ROWS = {}


def _harvest_sheet_footer(g, sh, out):
    """Totals hiding at the bottom of a LARGE sheet. See the note in harvest()."""
    w = g.pivot_table(index="source_row", columns="cn", values="value",
                      aggfunc="first").sort_index()
    if len(w) < 20:
        return
    for c in w.columns:
        v = pd.to_numeric(w[c], errors="coerce")
        if v.notna().sum() < 10:
            return_ = None          # too sparse to be a measure column
            continue
        for i in range(len(v) - FOOTER_ROWS, len(v)):
            x = v.iloc[i]
            if not pd.notna(x) or abs(x) < MIN_CANDIDATE:
                continue
            above = v.iloc[:i]
            if above.notna().sum() < 10:
                continue
            if abs(above.sum() - x) < TOL:
                row = list(v.index)[i]
                out.setdefault(round(float(x), 2),
                               f"{sh} (row {row} = sum of "
                               f"{int(above.notna().sum())} rows above)")
                # !! AND REMEMBER THAT THIS ROW IS NOT A LOAN. It carries real
                #   amounts and no id, so every downstream step would treat it
                #   as one more account: the population gains a phantom, and
                #   the column sums to exactly TWICE the published figure,
                #   which then matches nothing. Identifying a total row and
                #   then counting it is worse than not finding it at all.
                TOTAL_ROWS.setdefault(sh, set()).add(int(row))


def harvest(tape):
    """Candidate published totals, found by ARITHMETIC rather than vocabulary.

    !! "ANY LARGE NUMBER IN A SMALL SHEET" FAILS, silently and at scale. The
      WiZink books ship ~40 small per-month sheets, so that rule harvested 5,204
      candidates on PT20014 and then "exactly matched" 156 of them. Matching one
      of 5,204 targets is the birthday paradox dressed as evidence.

    !! KEYING ON THE WORD "TOTAL" IS BETTER BUT BRITTLE. It killed the 400+ false
      positives, and it also lost PT20008, whose tape calls it something else.
      Vocabulary does not survive a new seller or a new language.

    THE SIGNAL THAT DOES SURVIVE IS ARITHMETIC: in a strats block, the total row
    EQUALS THE SUM OF THE ROWS ABOVE IT. PT16023 writes
        Portfolio I 80,333,692.54 + II 44,264,880.66 + III 99,887,235.05
                                  = Total 224,485,808.25
    A cell that is the sum of a contiguous run above it is a published subtotal,
    whatever language the label is in and whether or not there is a label at all.
    A sheet-level "concentration of big numbers" on its own is noise; a number
    that RECONCILES to its own neighbours is a structure.

    Both routes are kept: arithmetic first, then the label words as a fallback
    for a block of one row that has nothing above it to sum.
    """
    out = {}
    for (f, sh), g in tape.groupby(["source_file", "source_sheet"]):
        if g.source_row.nunique() > SUMMARY_MAX_ROWS:
            # !! A GRAND TOTAL OFTEN SITS INSIDE THE DETAIL SHEET, and skipping
            #   every large sheet made it unreachable. PT15020 was recorded as
            #   "no published figure" while row 5314 of its 5,318-row detail
            #   sheet held 1,850,682.30 / 1,339,500.46 / 511,181.84 - balance,
            #   principal and interest, each the exact sum of the column above
            #   it, and summing to each other.
            #   Only the BOTTOM of a large sheet is scanned, and only against
            #   the sum of everything above: on 5,313 rows that test is far
            #   STRONGER than on a 3-row summary block, because hitting the sum
            #   of five thousand numbers by coincidence does not happen.
            _harvest_sheet_footer(g, sh, out)
            continue
        w = g.pivot_table(index="source_row", columns="cn",
                          values="value", aggfunc="first").sort_index()

        # --- route 1: a cell equal to the sum of a contiguous run above it ----
        # !! A BLANK CELL IS NOT A BOUNDARY; A BLANK ROW IS. The walk used to
        #   stop at the first null IN THIS COLUMN, so one empty cell anywhere
        #   above the total defeated the whole harvest. PT15020 publishes three
        #   figures in a total row inside its detail sheet -- 1,850,682.30,
        #   1,339,500.46 and 511,181.84, which are balance, principal and
        #   interest and sum exactly -- and all three were missed because four
        #   cells in a 5,313-row column are blank. The deal was recorded as
        #   "no published figure, `consistent` only" when it reconciles to the
        #   cent three ways.
        #   Excel's own SUM ignores blanks inside a range and that is how a
        #   human reads the sheet, so a null cell contributes 0 and the walk
        #   stops only where the ENTIRE ROW is empty - a real visual separator.
        row_empty = w.isna().all(axis=1).to_numpy()
        for c in w.columns:
            v = pd.to_numeric(w[c], errors="coerce")
            idx = list(v.index)
            for i in range(2, len(idx)):            # need >=2 rows to sum
                x = v.iloc[i]
                if not pd.notna(x) or abs(x) < MIN_CANDIDATE:
                    continue
                run = 0.0
                seen = 0                            # rows carrying a NUMBER
                for j in range(i - 1, -1, -1):      # walk upward
                    if row_empty[j]:
                        break
                    y = v.iloc[j]
                    if pd.notna(y):
                        run += y
                        seen += 1
                    # >=2 contributing rows, or a "total" is just a copy of the
                    # single cell above it
                    if seen >= 2 and abs(run - x) < TOL:
                        out.setdefault(round(float(x), 2),
                                       f"{sh} (row {idx[i]} = sum of {seen} rows above)")
                        break

        # --- route 2: a labelled row, for blocks with nothing to sum ----------
        lab = g[g.value.astype(str).str.strip().str.lower().isin(TOTAL_WORDS)]
        rows = set(lab.source_row) | {r + 1 for r in lab.source_row}
        for _, h in g[g.source_row.isin(rows)].iterrows():
            x = pd.to_numeric(pd.Series([h.value]), errors="coerce").iloc[0]
            if pd.notna(x) and abs(x) >= MIN_CANDIDATE:
                out.setdefault(round(float(x), 2), f"{sh} (labelled)")
    return out


def search(tape, candidates):
    """Every (amount column x filter) that reproduces a candidate exactly."""
    hits, searched = [], 0
    for sheet, g in tape.groupby("source_sheet"):
        if g.source_row.nunique() <= SUMMARY_MAX_ROWS:
            continue                                   # that is a summary, not detail
        w = g.pivot_table(index="source_row", columns="cn",
                          values="value", aggfunc="first")
        drop_rows = TOTAL_ROWS.get(sheet, set()) & set(w.index)
        if drop_rows:
            w = w.drop(index=list(drop_rows))
        nums = {c: pd.to_numeric(w[c], errors="coerce") for c in w.columns}
        amts = [c for c, v in nums.items() if v.notna().mean() > 0.8]
        cats = [c for c in w.columns if 1 < w[c].nunique() <= MAX_CARDINALITY]
        for a in amts:
            v = nums[a]
            combos = [(None, None, v.sum())]
            for c in cats:
                for d in w[c].dropna().unique():
                    combos.append((c, d, v[w[c].ne(d)].sum()))
            for col, drop, s in combos:
                searched += 1
                if not pd.notna(s):
                    continue
                for target, where in candidates.items():
                    if abs(s - target) < TOL and abs(s) >= abs(v.sum()) * MIN_SHARE:
                        hits.append({"sheet": sheet, "amount_column": a,
                                     "scope_column": col, "scope_excludes": drop,
                                     "total": round(float(s), 2),
                                     "published_in": where})
    return hits, searched



def _record_scan(out_dir, deal, found, detail, status=None):
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
    # !! "FOUND NOTHING" AND "COULD NOT BE SPECIFIC" ARE DIFFERENT FINDINGS.
    #   Both leave no per-deal file, so without the status on the index line
    #   the backtest cannot tell a deal we searched exhaustively from one
    #   where the search refused to answer.
    if status:
        log[deal]["status"] = status
    idx.write_text(json.dumps(dict(sorted(log.items())), indent=2) + "\n")
    stale = out_dir / f"{deal}.json"
    if not found and stale.exists():
        stale.unlink()
    return bool(found)

def main(deal):
    f = TAPES / f"{deal}.parquet"
    if not f.exists():
        print(f"no tape for {deal}", file=sys.stderr)
        return 2
    tape = pd.read_parquet(f)
    tape["cn"] = tape.column_name.map(lambda c: " ".join(str(c).split()))

    cand = harvest(tape)
    # !! SPECIFICITY GUARD. With many targets an exact match stops being evidence.
    #   Better to return nothing than noise -- the deal lands `consistent`.
    if len(cand) > MAX_CANDIDATES:
        OUT.mkdir(parents=True, exist_ok=True)
        _record_scan(OUT, deal, 0,
                     f"{len(cand):,} candidate totals -- too many for an "
                     f"exact match to be evidence",
                     status="too_many_candidates_to_be_specific")
        print(f"{deal}: {len(cand):,} candidates -- TOO MANY to be specific. "
              f"Reporting nothing rather than noise.")
        return 1
    hits, searched = search(tape, cand)

    OUT.mkdir(parents=True, exist_ok=True)
    res = {"deal": deal, "candidates": len(cand), "combinations_searched": searched,
           "hits": hits,
           # the rows PROVEN to be published totals rather than loans, so
           # clean_accounts excludes exactly the same rows the search did
           "total_rows": {k: sorted(v) for k, v in sorted(TOTAL_ROWS.items())},
           "status": "reconcilable" if hits else "no_external_figure_found"}
    if _record_scan(OUT, deal, len(hits),
                    f"{len(cand):,} candidate totals, {searched:,} "
                    f"combinations searched", status=res["status"]):
        (OUT / f"{deal}.json").write_text(json.dumps(res, indent=2))

    print(f"{deal}: {len(cand):,} candidate totals, {searched:,} combinations searched")
    if not hits:
        print("  NO EXACT MATCH -- this deal can reach `consistent`, never `reconciled`")
        return 1
    for h in hits:
        scope = (f"{h['scope_column']} != {h['scope_excludes']!r}"
                 if h["scope_column"] else "(no filter)")
        print(f"  HIT  {h['amount_column'][:38]:<40} {scope:<30} {h['total']:>18,.2f}")
    print("  !! one human glance: is this the QUANTITY you want? The arithmetic is proven,")
    print("    the meaning of the column is not.")
    return 0


if __name__ == "__main__":
    a = sys.argv[1:] or ["PT15018"]
    if a[0] == "--all":
        deals = sorted(p.stem for p in TAPES.glob("*.parquet"))
        rc = 0
        for d in deals:
            rc |= main(d) == 2
            print()
        sys.exit(rc)
    sys.exit(main(a[0]))
