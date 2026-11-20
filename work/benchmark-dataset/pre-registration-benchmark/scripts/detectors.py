"""Scan a RAW tape for every failure mode we have already met.

    uv run python scripts/detectors.py PT19013
    uv run python scripts/detectors.py --all

Runs BEFORE any mapping exists, so the agent is TOLD what this tape does rather
than discovering it the hard way. Each detector corresponds to a trap in
traps.yaml and reads only the raw parquet - no registry, no output.

!! A DETECTOR IS NOT A GUARD. A guard reads the OUTPUT and refuses; a detector
   reads the INPUT and warns. Most of these describe defects a guard can NEVER
   see, because the output is internally consistent afterwards: Portuguese month
   headers decoded as English drop 22 of 26 months and every total still ties.

!! THESE WERE NAMED IN traps.yaml FOR A DAY BEFORE THEY EXISTED. METHOD.md
   documented "step 2 - detect known traps" and run.py listed it. Nothing ran.
   Naming a check is not having one, and the gap was only found by auditing
   whether the named functions existed.
"""
import hashlib
import re
import sys
from pathlib import Path
import pandas as pd

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
DATA = _P.TAPES

MONTHS_EN = ("jan feb mar apr may jun jul aug sep oct nov dec").split()
MONTHS_PT = ("janeiro fevereiro marco março abril maio junho julho agosto "
             "setembro outubro novembro dezembro").split()
MONTHISH = re.compile(r"(?:^|\s)(" + "|".join(MONTHS_EN + MONTHS_PT) +
                      r")[a-zç]*\s+\d{2,4}\s*$", re.I)


def _wide(tape, sheet):
    g = tape[tape.source_sheet == sheet]
    return g.pivot_table(index="source_row", columns="cn", values="value",
                         aggfunc="first")


def detect_untranslated_months(tape, **_):
    """T1 - a month-looking column the loader did not decode into a period."""
    import importlib.util
    lt_path = _P.LOADER
    spec = importlib.util.spec_from_file_location("lt", lt_path)
    lt = importlib.util.module_from_spec(spec); spec.loader.exec_module(lt)
    bad = [c for c in tape.cn.unique()
           if MONTHISH.search(str(c)) and not lt.PAYMENT_COL.match(str(c))]
    return bad and f"{len(bad)} month-like column(s) NOT collected, e.g. {bad[:3]}"


def detect_duplicate_files(tape, deal=None, **_):
    """T2 - byte-identical files, which double every figure in the book."""
    man = pd.read_parquet(DATA / "manifest.parquet")
    man = man[man.deal == deal]
    if "path" not in man:
        return "manifest has no `path` column - basename collisions invisible"
    d = int(man[["path", "sheet"]].duplicated().sum())
    return d and f"{d} duplicate (path, sheet) row(s) survived the MD5 guard"


def detect_derived_file(tape, **_):
    """T55 - a file in the raw folder that is OUR OWN output, not the seller's.

    !! CIRCULAR EVIDENCE IS WORSE THAN NO EVIDENCE. A dump of "everything we
    have on this deal" can contain a file somebody downstream produced, and
    it looks like raw data: PT15020 arrived with `ONEY_PT15020_cleaned_aux
    .xlsx`, whose columns are `cutoff_principal`, `cutoff_fv`, `country`,
    `default_date`, `reflect_id`. The strat scanner duly found four more
    "published" totals in it and they matched the book exactly - because the
    book is where they came from. A deal that reconciles against its own
    output has proved nothing, and nothing in the pipeline could tell.
    A seller writes Portuguese column names and its own system's ids. It does
    not write our schema's. Three or more core field names in one sheet is
    not a coincidence.
    """
    import yaml
    sc = yaml.safe_load(open(_P.SCHEMA))["columns"]
    core = {c if isinstance(c, str) else c["name"] for c in sc}
    out = []
    for (f, sh), g in tape.groupby(["source_file", "source_sheet"]):
        hit = sorted({str(c) for c in g.cn.unique()} & core)
        if len(hit) >= 3:
            out.append(f"{f} | {sh} uses {len(hit)} of OUR schema's own "
                       f"column names ({', '.join(hit[:5])}) -- this is a "
                       f"DERIVED file, not seller evidence")
    return out and "; ".join(out)


def detect_banner_header(tape, **_):
    """T3 - a merged title row read as the header."""
    out = []
    for sheet in tape.source_sheet.unique():
        cols = [str(c) for c in tape[tape.source_sheet == sheet].cn.unique()]
        if len(cols) < 4:
            continue
        bases = {re.sub(r"\.\d+$", "", re.sub(r"^Unnamed.*$", "U", c)) for c in cols}
        if len(bases) < len(cols) * 0.5:
            out.append(f"{sheet} ({len(cols)} cols, {len(bases)} distinct names)")
    return out and f"banner-like header on: {', '.join(out[:3])}"


def detect_double_header(tape, **_):
    """T4 - the sheet labels every column twice, so one row arrives as data."""
    out = []
    for sheet in tape.source_sheet.unique():
        w = _wide(tape, sheet)
        if w.empty or len(w) < 2:
            continue
        first = {str(v).strip().lower() for v in w.iloc[0].dropna()}
        names = {str(c).strip().lower() for c in w.columns}
        if first and len(first & names) >= max(2, len(names) * 0.3):
            out.append(sheet)
    return out and (f"{', '.join(out[:3])}: the first data row holds COLUMN NAMES "
                    f"- a second header arriving as a loan")


def detect_mixed_decimals(tape, **_):
    """T5 - two decimal conventions in ONE sheet."""
    out = []
    for sheet in tape.source_sheet.unique():
        dot, comma = [], []
        for c in tape[tape.source_sheet == sheet].cn.unique():
            v = tape[(tape.source_sheet == sheet) & (tape.cn == c)].value.dropna().astype(str)
            if len(v) < 20:
                continue
            if v.str.fullmatch(r"-?\d+\.\d+").mean() > 0.5:
                dot.append(c)
            elif v.str.fullmatch(r"-?[\d.]*,\d{1,2}").mean() > 0.5:
                comma.append(c)
        if dot and comma:
            out.append(f"{sheet}: dot in {dot[0][:24]!r}, COMMA in {comma[0][:24]!r}")
    return out and " | ".join(out[:2])


def detect_system_id_twins(tape, **_):
    """T7 - a (System)/(Sistema) twin, renumbered between deliveries."""
    twins = [c for c in tape.cn.unique()
             if re.search(r"\((sistema|system)\)", str(c), re.I)]
    return twins and (f"{len(twins)} column(s) have a (System) twin - NEVER join on "
                      f"them, e.g. {twins[0][:46]!r}")


def detect_yn_without_no(tape, **_):
    """T11 - a Y/N column with no negative, where False must never be written."""
    YES = {"y", "yes", "s", "sim", "true", "1"}
    NO = {"n", "no", "nao", "não", "false", "0"}
    out = []
    for c in tape.cn.unique():
        v = tape[tape.cn == c].value.dropna().astype(str).str.strip().str.lower()
        u = set(v.unique())
        if len(u) <= 4 and (u & YES) and not (u & NO) and len(v) > 50:
            out.append(str(c)[:40])
    return out and (f"{len(out)} flag column(s) hold a YES but NO negative - null "
                    f"means UNKNOWN there, never 'no': {out[:2]}")

def _schema_fields():
    """The target columns that actually exist, read from the single source."""
    import yaml
    y = yaml.safe_load((_P.SCHEMA).read_text(encoding="utf-8"))
    cols = y.get("columns", y)
    return {c["name"] if isinstance(c, dict) else c for c in cols} \
        if isinstance(cols, list) else set(cols)


# a schema field -> the words a segment label would use to carry it
SEGMENT_FACTS = {
    "insolvent_flag":    ("insolven", "bankrupt", "falencia", "falência", "piar"),
    "judicialised_flag": ("judicial", "litig", "contencios", "legal"),
    "deceased_flag":     ("deceased", "obito", "óbito", "falecid"),
}


def detect_fact_hidden_in_a_segment(tape, deal=None, **_):
    """T18 - a schema fact encoded as one value of a multi-valued segment column.

    PT18019 ships no insolvency column; it ships `Perimeter`, one of whose four
    labels is Bankruptcy. Read as "not on this tape" the fact is lost, and read
    with a plain equality it invents a negative for every other label.
    """
    out = []
    for c in tape.cn.unique():
        v = tape[tape.cn == c].value.dropna().astype(str).str.strip()
        u = v.str.lower().unique()
        # a SEGMENT, not free text: few distinct values over many rows
        if not (2 <= len(u) <= 12 and len(v) > 100):
            continue
        for field, words in SEGMENT_FACTS.items():
            hit = [x for x in u if any(w in x for w in words)]
            if hit:
                # !! ONLY NAME A FIELD THE SCHEMA ACTUALLY HAS. This printed
                #   "carries deceased_flag" for a column that does not exist,
                #   which reads as an instruction to map something unmappable.
                #   A fact with no home is a SCHEMA question, and saying so is
                #   more useful than pretending there is a column waiting.
                where = field if field in _schema_fields() else f"{field} (NO SUCH COLUMN -- schema question)"
                out.append(f"`{str(c)[:30]}` = {hit[0][:24]!r} carries {where}")
    return out and (f"{len(out)} segment label(s) carry a schema fact - map with "
                    f"`eq:<value>` so the other labels stay NULL, never False: "
                    + "; ".join(out[:2]))


def detect_id_that_is_not_unique(tape, deal=None, **_):
    """T19 - a column named like a key that does not behave like one.

    Reads the REGISTRY only to learn which column this deal calls loan_id, and
    falls back to any column whose name says unique/id when nothing is mapped
    yet - the point is to warn BEFORE the mapping is trusted.
    """
    reg = _P.REGISTRY
    want = set()
    if reg.exists():
        r = pd.read_csv(reg)
        want = {" ".join(str(x).split()) for x in
                r[(r.deal_id == deal) & (r.target_field == "loan_id")].source_column}
    if not want:
        want = {c for c in tape.cn.unique()
                if re.search(r"unique|\bid\b|identif", str(c), re.I)}
    out = []
    for c in want:
        v = tape[tape.cn == c].value.dropna().astype(str).str.strip()
        if len(v) < 100:
            continue
        dup = len(v) - v.nunique()
        if dup:
            out.append(f"`{str(c)[:34]}` repeats on {dup:,} of {len(v):,} rows")
    return out and (f"an id column is NOT unique - pin the count in guards.py "
                    f"EXPECT, never invent a surrogate: " + "; ".join(out[:2]))


def detect_relative_payment_periods(tape, deal=None, **_):
    """T20 - payment columns relative to a cut-off the tape never states."""
    pf = DATA / "payments.parquet"
    if not pf.exists():
        return None
    q = pd.read_parquet(pf)
    q = q[q.deal == deal]
    if not len(q):
        return None
    if q.period_month.notna().any():
        return None
    per = sorted(q.period.dropna().astype(str).unique(), key=lambda x: (len(x), x))
    pre = [x for x in per if x.startswith("-")]
    amt = pd.to_numeric(q.amount, errors="coerce").sum()
    return (f"{len(q):,} payment row(s), EUR {amt:,.2f}, carry NO DATE at all - "
            f"{len(per)} relative periods ({len(pre)} before the cut-off, "
            f"{len(per) - len(pre)} after). The cut-off date is not on the tape, "
            f"so none of this can be placed on a timeline. Ask the deal owner.")


def detect_total_row_in_a_detail_sheet(tape, deal=None, **_):
    """T21 - a published total sitting at the foot of a LARGE sheet."""
    sf = _P.STRATS / f"{deal}.json"
    if not sf.exists():
        return None
    import json as _j
    tr = _j.loads(sf.read_text()).get("total_rows", {})
    if not tr:
        return None
    n = sum(len(v) for v in tr.values())
    some = ", ".join(sorted(tr)[:2])
    return (f"{n} published TOTAL row(s) sit INSIDE the detail across "
            f"{len(tr)} sheet(s) ({some}...). Counted as loans they add a "
            f"phantom account per sheet and the column sums to twice the "
            f"published figure. clean_accounts excludes exactly these rows.")


# -- promoted 2026-10-13, each seen on two deals ---------------------------

RETURN_WORDS = ("ret", "rev", "estorn", "devol", "reemb", "refund")


def detect_paired_payment_series(tape, **_):
    """T9 - a SECOND monthly series beside the first, which must be netted.

    !! COUNTING ONLY THE FIRST SERIES OVERSTATES COLLECTIONS, and the result
    is internally consistent so nothing fails. PT15014 and PT15016 ship
    `JAN15pay` AND `JAN15ret` - payments and returns/reversals. Twenty-six
    month columns look like a complete payment history; they are half of one,
    and the half that only ever adds.

    The shape is a stem with two suffixes, one of them a return word. Detected
    on the HEADERS alone, before any mapping exists, because by the time a
    total looks wrong the `ret` columns have already been left out.
    """
    cols = {str(c) for c in tape.cn.unique()}
    pairs = []
    for c in sorted(cols):
        for w in RETURN_WORDS:
            if c.lower().endswith(w) and len(c) > len(w):
                stem = c[:-len(w)]
                twin = [o for o in cols
                        if o != c and o.lower().startswith(stem.lower())]
                if twin:
                    pairs.append((stem, c, sorted(twin)[0]))
                break
    if len(pairs) < 2:
        return None
    ex = ", ".join(f"{a} + {b}" for _, b, a in pairs[:3])
    return (f"{len(pairs)} month(s) carry TWO series, a payment and a "
            f"return ({ex}...). They must NET - mapping only the first "
            f"overstates collections and nothing will fail.")


def _shared_facts(tape, min_rows=100, keyish=0.95):
    """Columns stated on more than one POPULATION sheet, excluding join keys.

    A key is near-unique on the sheet it keys; a fact repeats. Without that
    cut every join column fires, which is noise - sheets are SUPPOSED to
    share a key.
    """
    n = tape.groupby("source_sheet").source_row.nunique()
    big = set(n[n >= min_rows].index)
    sub = tape[tape.source_sheet.isin(big)]
    out = []
    for cn, g in sub.groupby("cn"):
        sh = sorted(g.source_sheet.unique())
        if len(sh) < 2:
            continue
        uq = {s: g[g.source_sheet == s].value.nunique() / max(n[s], 1)
              for s in sh}
        if max(uq.values()) >= keyish:
            continue
        out.append((cn, sh, {s: int(n[s]) for s in sh}))
    return out


def _stem(names):
    """The common leading text of a group of sheet names, if any."""
    if len(names) < 2:
        return ""
    a, b = min(names), max(names)
    i = 0
    while i < len(a) and i < len(b) and a[i] == b[i]:
        i += 1
    return a[:i]


def detect_population_split_across_sheets(tape, **_):
    """T12 - the population is split across SIBLING sheets, so the anchor decides who exists.

    !! WHICHEVER SHEET DEFINES THE POPULATION, LOANS ONLY IN THE OTHERS CEASE
    TO EXIST. PT18019 ships `data_tape_WOFF_201809_Ruby_PT_b` (9,440),
    `..._PT_D` (1,413) and `..._PT_v` (21,553) - the same columns, three
    cohorts. Anchoring on one of them silently drops the other two, and the
    output is perfectly consistent afterwards.

    Sibling sheets are told from two-grain sheets (T16) by their NAMES: a
    shared stem means cohorts of one population, different names mean the
    same fact stated about different things.
    """
    groups = {}
    for cn, sh, rows in _shared_facts(tape):
        st = _stem(sh)
        if len(st) >= 8:
            groups.setdefault((st, tuple(sh)), []).append(cn)
    out = []
    for (st, sh), cols in sorted(groups.items()):
        if len(cols) < 3:
            continue
        n = tape[tape.source_sheet.isin(sh)].groupby(
            "source_sheet").source_row.nunique()
        tot = int(n.sum())
        big = n.idxmax()
        out.append(
            f"{len(sh)} sibling sheets share the stem '{st}' and {len(cols)} "
            f"columns ({', '.join(sorted(cols)[:3])}...): "
            + ", ".join(f"{s}={int(v):,}" for s, v in n.items())
            + f". Anchoring on {big} alone keeps {int(n.max()):,} of {tot:,} "
              f"rows - the rest cease to exist. Decide whether these are "
              f"COHORTS of one book (map them all, `data_tape_*` pattern) or "
              f"alternative CUTS of it (`prefer` one).")
    return out and "; ".join(out)


def detect_fact_stated_at_two_grains(tape, **_):
    """T16 - the same fact on a LOAN sheet and on a PARTY sheet.

    !! A TAPE CAN STATE A FACT ABOUT THE LOAN OR ABOUT THE PERSON, and some
    ship both. Taking the wrong one is silent: a party-grain date rolled up
    to the loan is right for a sole borrower and wrong for a joint one, and
    PT15018's borrowers hold 1.81 loans each. `Data de Insolvencia` sits on
    `Main Debtors` AND `Other Participants`; `sum_prin` on PT15016 sits on
    the sale file AND a monthly write-off cohort.

    The finer grain wins (T72), but it must be a RECORDED judgement - which
    is why this warns rather than choosing.
    """
    out = []
    for cn, sh, rows in _shared_facts(tape):
        if len(_stem(sh)) >= 8:
            continue              # siblings - that is T12, not this
        out.append(f"{cn} on " + " and ".join(f"{s} ({rows[s]:,} rows)"
                                              for s in sh))
    if not out:
        return None
    return (f"{len(out)} field(s) are stated on more than one sheet, at "
            f"different grains: " + "; ".join(out[:4])
            + (f"; and {len(out) - 4} more" if len(out) > 4 else "")
            + ". Map each from the FINER grain, and say which in the note.")


DETECTORS = [("T1", detect_untranslated_months), ("T2", detect_duplicate_files),
             ("T3", detect_banner_header), ("T4", detect_double_header),
             ("T5", detect_mixed_decimals), ("T7", detect_system_id_twins),
             ("T11", detect_yn_without_no), ("T18", detect_fact_hidden_in_a_segment),
             ("T19", detect_id_that_is_not_unique),
             ("T20", detect_relative_payment_periods),
             ("T21", detect_total_row_in_a_detail_sheet),
             ("T55", detect_derived_file),
             # promoted 2026-10-13 after a second sighting each
             ("T9", detect_paired_payment_series),
             ("T12", detect_population_split_across_sheets),
             ("T16", detect_fact_stated_at_two_grains)]


def scan(deal):
    tape = pd.read_parquet(DATA / f"{deal}.parquet")
    tape["cn"] = tape.column_name.map(lambda c: " ".join(str(c).split()))
    found = []
    for tid, fn in DETECTORS:
        try:
            r = fn(tape, deal=deal)
        except Exception as e:
            r = f"detector failed: {type(e).__name__}"
        if r:
            found.append((tid, r))
    return found


def main(deal):
    found = scan(deal)
    print(f"{deal}: {len(found)} of {len(DETECTORS)} known traps present")
    for tid, msg in found:
        print(f"  {tid:<4} {msg}")
    if not found:
        print("  none - but absence is only evidence about traps we have MET")
    return 0


if __name__ == "__main__":
    a = sys.argv[1:] or ["PT15018"]
    if a[0] == "--all":
        for d in sorted(p.stem for p in DATA.glob("*.parquet")):
            main(d); print()
        sys.exit(0)
    sys.exit(main(a[0]))
