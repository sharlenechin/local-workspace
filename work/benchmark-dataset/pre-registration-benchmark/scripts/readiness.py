"""Can this deal be mapped DEFINITELY, or would mapping be guesswork?

    uv run python scripts/readiness.py PT15014
    uv run python scripts/readiness.py --all

Runs BEFORE any mapping exists, like detectors.py, and answers one question a
detector cannot: is there enough here to map with CONFIDENCE, or will the
agent be filling a schema from inference?

!! "I MAPPED IT" AND "I COULD MAP IT DEFINITELY" ARE DIFFERENT CLAIMS, and
   nothing distinguished them. Every check below was a thing somebody found
   out the hard way, one deal at a time, AFTER committing to a mapping:

     PT15014  a whole monthly tranche sat PASSWORD PROTECTED and unread. The
              loader said "File is not a zip file", which reads as corruption.
              ~650 loans, about 9% of the book, silently absent.
     PT16023  a column called `Unique Loan ID` with 1,151 duplicates. The
              real key was `Client Number`, proven against CAT at 91.8%.
     ten of   no cut-off date anywhere, so every `cutoff_*` amount is "as of"
     thirteen a date nobody can state.
     PT13004  731 columns, no published total, nothing to reconcile against.

!! A BLOCKER IS NOT A REFUSAL TO WORK. It is a sentence to put in an email
   before spending a day on a mapping that cannot be defended. The verdicts
   say what is missing and who can supply it.
"""
import sys
from pathlib import Path

import pandas as pd
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths as _P

# a core field is REQUIRED when nothing downstream can work without it
REQUIRED = ["loan_id", "cutoff_balance", "cutoff_date"]


def _tape(deal):
    f = _P.TAPES / f"{deal}.parquet"
    if not f.exists():
        return None
    t = pd.read_parquet(f)
    t["cn"] = t.column_name.map(lambda c: " ".join(str(c).split()))
    return t


def _is_encrypted(path):
    """Read the BYTES, so this does not depend on when the manifest was built.

    !! THE MANIFEST CARRIES WHATEVER MESSAGE THE LOADER WROTE AT THE TIME.
    PT15014's entry still said "File is not a zip file" after the loader was
    taught to say PASSWORD PROTECTED, because nothing had re-loaded. A
    readiness check that trusts a stale string reports a stale verdict.
    """
    try:
        b = Path(path).read_bytes()
    except Exception:
        return False
    u16 = lambda t: t.encode("utf-16-le")
    return (b[:4] == b"\xd0\xcf\x11\xe0" and u16("EncryptedPackage") in b
            and not any(u16(w) in b for w in ("Workbook", "Book")))


def unreadable_files(deal):
    """Delivered files that yielded nothing, with the reason, checked NOW."""
    m = pd.read_parquet(_P.MANIFEST)
    d = m[(m.deal == deal) & m.error.notna() & m.sheet.isna()]
    out = []
    for _, r in d.iterrows():
        full = _P.PROCESSED / r.path
        why = ("PASSWORD PROTECTED -- ask the seller for the password or an "
               "unprotected copy" if _is_encrypted(full) else str(r.error))
        out.append((r.file, why))
    return out


def unique_id_candidates(t):
    """Columns that could BE the key: present on the biggest sheet, unique."""
    n = t.groupby("source_sheet").source_row.nunique()
    if not len(n):
        return [], None
    base = n.idxmax()
    g = t[t.source_sheet == base]
    rows = int(n[base])
    # !! UNIQUE AND NEARLY-UNIQUE ARE DIFFERENT ANSWERS, and collapsing them
    #   made this report PT15014 as having no id at all. `acct` is unique on
    #   741 of 742 rows - that is a strong candidate with one defect to
    #   explain, not an absence. Calling it nothing sends the agent looking
    #   for a key that is already there.
    exact, near = [], []
    for cn, col in g.groupby("cn"):
        v = col.value.dropna()
        if len(v) < rows * 0.99:          # must be present on nearly every row
            continue
        u = v.nunique()
        if u == rows:
            exact.append(str(cn))
        elif u >= rows * 0.95:
            near.append((str(cn), rows - u))
    return (sorted(exact), sorted(near)), base


def published_total(deal):
    idx = _P.STRATS / "_scanned.json"
    if not idx.exists():
        return None
    import json
    log = json.loads(idx.read_text())
    return log.get(deal, {}).get("found")


def cutoff(deal):
    d = pd.read_csv(_P.BASE / "portugal" / "deals.csv")
    r = d[d.deal_id == deal]
    if not len(r):
        return None
    v = r.cutoff_date.iloc[0]
    return None if pd.isna(v) else str(v)


def assess(deal):
    blockers, warnings, notes = [], [], []

    dead = unreadable_files(deal)
    pw = [(f, e) for f, e in dead if str(e).startswith("PASSWORD")]
    if pw:
        blockers.append(
            f"{len(pw)} delivered file(s) are PASSWORD PROTECTED and have "
            f"never been read: " + ", ".join(f for f, _ in pw)
            + ". Their loans are in NO output. Ask the seller for the "
              "password or an unprotected copy.")
    other = [(f, e) for f, e in dead if not str(e).startswith("PASSWORD")]
    if other:
        blockers.append(
            f"{len(other)} delivered file(s) could not be read: "
            + "; ".join(f"{f} ({e[:50]})" for f, e in other))

    t = _tape(deal)
    if t is None:
        blockers.append("no tape has been loaded for this deal")
        return "NOT MAPPABLE", blockers, warnings, notes

    # !! A DEAL ALREADY MAPPED HAS ANSWERED THIS. Running the check over the
    #   whole book reported PT15016 and PT16023 NOT MAPPABLE while both were
    #   cleaned and APPROVED - because their rows are loans and their only
    #   stable id is the BORROWER. That is not an obstacle, it is their
    #   grain, and the registry settled it. A readiness check that argues
    #   with a finished deal is noise, and noise is how a real blocker gets
    #   scrolled past.
    reg = pd.read_csv(_P.BASE / "portugal" / "mappings.csv")
    if (reg.deal_id == deal).any():
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "style", Path(__file__).resolve().parent / "style.py")
        st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
        try:
            g, _why = st.deal_grain(deal)
            notes.append(f"ALREADY MAPPED - grain `{g}`, settled in the registry")
        except Exception:
            notes.append("ALREADY MAPPED - registry rows exist for this deal")

    (exact, near), base = unique_id_candidates(t)
    if not exact and not near:
        # !! NOT A BLOCKER. `unique_key` exists precisely so that a tape with
        #   no stable id of its own can still be mapped - it is a hash of the
        #   source row and it is never null. What is LOST is the ability to
        #   join anything to the seller's own system, which is a real cost
        #   and belongs in the report as a gap, not as a refusal.
        warnings.append(
            f"NO column on the largest sheet ({base}) is unique and complete. "
            f"The deal can still be mapped - `unique_key` is ours and never "
            f"null - but nothing will join to the seller's system. Verify "
            f"against CAT client_ref_1 before settling the grain (T72).")
    elif not exact:
        warnings.append(
            f"no column is FULLY unique on {base}. Closest: "
            + ", ".join(f"{c} ({d} duplicate{'s' if d != 1 else ''})"
                        for c, d in near[:4])
            + ". A near-unique id is usually the right column with a real "
              "defect in it - explain the duplicates before mapping (T19).")
    elif len(exact) > 6:
        warnings.append(f"{len(exact)} columns are unique and complete on "
                        f"{base} - being unique does not make one the "
                        f"SYSTEM id. Verify, do not pick by name (T19).")
    else:
        notes.append(f"loan id candidates on {base}: {', '.join(exact[:6])}")

    co = cutoff(deal)
    if not co:
        warnings.append(
            "no cut-off date is known, so every `cutoff_*` amount is 'as of' "
            "a date nobody can state. Run find_cutoff.py; if the banner is "
            "silent, ask the seller (T70).")
    else:
        notes.append(f"cut-off {co}")

    hits = published_total(deal)
    if hits is None:
        warnings.append("the strat scan has not run - no published figure to "
                        "reconcile against yet")
    elif not hits:
        warnings.append("NO published total anywhere on this tape. The deal "
                        "can reach `consistent`, never `reconciled`.")
    else:
        notes.append(f"{hits} published figure(s) to reconcile against")

    verdict = ("NOT MAPPABLE" if blockers else
               "MAPPABLE WITH GAPS" if warnings else "MAPPABLE")
    return verdict, blockers, warnings, notes


def report(deal):
    verdict, blockers, warnings, notes = assess(deal)
    print(f"\n{deal}  {verdict}")
    for b in blockers:
        print(f"  BLOCKER  {b}")
    for w in warnings:
        print(f"  GAP      {w}")
    for n in notes:
        print(f"  ok       {n}")
    return 0 if verdict == "MAPPABLE" else (1 if not blockers else 2)


def main(argv):
    if argv and argv[0] == "--all":
        deals = sorted(f.stem for f in _P.TAPES.glob("PT*.parquet"))
        worst = 0
        for d in deals:
            worst = max(worst, report(d))
        return worst
    if not argv:
        print(__doc__.strip().split("\n")[0])
        print("\n  usage: readiness.py <deal> | --all")
        return 2
    return report(argv[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
