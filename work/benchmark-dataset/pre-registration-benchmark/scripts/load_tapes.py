"""Load every Portugal asset-index tape into clean parquet, ready for analysis.

    uv run python scripts/load_tapes.py

Writes to portugal/raw/processed/tables/:
    manifest.parquet        one row per (deal, file, sheet) that was read
    tapes/<deal>.parquet    every sheet of that deal, long format
    payments.parquet        the wide monthly payment columns, unpivoted
    bridge.parquet          seller reference -> prod CASE_SK (from bridge.sql)

!! EVERYTHING IS READ AS TEXT. Account numbers run to 19 digits; one blank cell
  in a column makes pandas infer float64 and round away everything past ~15
  digits (0004064740080003334 -> 4064740080003300.0). That silently broke the
  match on three deals. Values are only ever converted downstream, never here.
"""
import hashlib
import os
import re
import sys
import warnings
import pathlib
from pathlib import Path

import pandas as pd

warnings.simplefilter("ignore")

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
# !! EVERY LOADED ROOT, NOT ONE. `processed/` is where intake.py files a
#   dump, so a new delivery reaches the workflow without anyone editing a
#   path. A root listed here IS read; anything else under this folder is
#   reported by check_new_data.py and deliberately left alone.
ROOTS = [_p.PROCESSED]
ROOT = ROOTS[0]
OUT = _p.TAPES
ENGINES = {".xlsx": "openpyxl", ".xls": "xlrd", ".xlsb": "pyxlsb"}

# Wide monthly payment columns. Each seller writes them differently, and only
# four deals ship a series at all -- the WiZink books carry installment_amount
# (the contractual instalment) and no payment history, which is NOT the same
# thing and is deliberately not collected here.
#   PT18019          -12M ... -1M        months before cutoff, no absolute date
#   PT20008 (Oney)   PAGAMENTOS_201903   absolute year-month
#   PT15014/PT15016  JAN15pay            absolute month, two-digit year
#   PT15018 (Millen.) January 2014        full English month name + year, on the
#                                         .xlsb `Collections` sheet. A partial
#                                         final month is written "1-13th February
#                                         2016", and November 2014 is misspelled
#                                         "Novermber" in the file.
# !! BOTH SIGNS. The first version matched only `-\d+M` and silently dropped
#   PT18019's `1M`, `2M` and `3M` columns -- 95,097 cells holding EUR
#   2,359,907.66 of collections AFTER the cut-off, which for a benchmark is the
#   most valuable data on the tape. Nothing failed: the deal cleaned, guarded
#   and reconciled with those columns simply absent. `period` keeps the label,
#   so pre-cutoff (-1M) stays distinguishable from post-cutoff (1M).
PAYMENT_COL = re.compile(
    r"^(-?\d+M"
    r"|PAGAMENTOS_\d{6}"
    r"|[A-Z]{3}\d{2}(?:pay|ret)"
    r"|(?:\d{1,2}-\d{1,2}(?:st|nd|rd|th)?\s+)?"
    r"(?:JAN|FEB|FEV|MAR|APR|ABR|MAY|MAI|JUN|JUL|AUG|AGO"
    r"|SEP|SET|OCT|OUT|NOV|DEC|DEZ)[A-ZÇ]*\s+\d{4})$",
    re.I)

MONTHS = {m: i for i, m in enumerate(
    ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
     "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"], start=1)}

# !! PT15018's Collections sheet carries its month headers TWICE -- Portuguese on
#   Excel row 23, English on row 25 -- and the header hunt lands on the Portuguese
#   one. Decoding those as English silently kept only the four months whose first
#   three letters collide (JANeiro, JUNho, JULho, NOVembro) and dropped the other
#   eight with no error. Both languages are decoded here.
MONTHS_PT = {"JANEIRO": 1, "FEVEREIRO": 2, "MARCO": 3, "MARÇO": 3, "ABRIL": 4,
             "MAIO": 5, "JUNHO": 6, "JULHO": 7, "AGOSTO": 8, "SETEMBRO": 9,
             "OUTUBRO": 10, "NOVEMBRO": 11, "DEZEMBRO": 12}


def period_month(col: str) -> str | None:
    """Absolute YYYY-MM for a payment column, or None where it is relative.

    '-3M' is three months before that book's cutoff, and the cutoff is not in
    the tape -- so it stays relative rather than being guessed at.
    """
    c = str(col).strip()
    if m := re.fullmatch(r"PAGAMENTOS_(\d{4})(\d{2})", c, re.I):
        return f"{m.group(1)}-{m.group(2)}"
    if m := re.fullmatch(r"([A-Z]{3})(\d{2})(?:pay|ret)", c, re.I):
        return f"20{m.group(2)}-{MONTHS[m.group(1).upper()]:02d}"
    # Millennium: "January 2014", and "1-13th February 2016" for a partial month.
    # A partial month is still that month -- the day range is the cut-off, not a
    # different period -- so it folds into the same YYYY-MM.
    # NOV also matches the file's misspelled "Novermber".
    if m := re.fullmatch(
            r"(?:\d{1,2}-\d{1,2}(?:st|nd|rd|th)?\s+)?([A-ZÇ]+)\s+(\d{4})", c, re.I):
        word, year = m.group(1).upper(), m.group(2)
        if word in MONTHS_PT:
            return f"{year}-{MONTHS_PT[word]:02d}"
        if word[:3] in MONTHS:
            return f"{year}-{MONTHS[word[:3]]:02d}"
    return None


def why_unreadable(path, exc):
    """Name the REASON a workbook would not open, not just the exception.

    !! "File is not a zip file" IS A PASSWORD PROMPT IN DISGUISE. PT15014's
    April 2016 tranche is AES-encrypted; openpyxl expected an OOXML zip, got
    an OLE2 container, and said the file was not a zip. That reads as
    corruption, so it sat unnoticed from 5 October - a whole monthly tranche
    of a forward flow, roughly 650 loans, stranded by a misleading message.
    Encryption is the one failure a HUMAN can fix, by asking the seller, so
    it is the one that must never be mistaken for a broken file.

    Encrypted OOXML is an OLE2 container holding `EncryptedPackage` and no
    workbook stream. OLE2 stream names are stored UTF-16LE.
    """
    try:
        b = Path(path).read_bytes()
    except Exception:
        return f"{type(exc).__name__}: {str(exc)[:90]}"
    u16 = lambda t: t.encode("utf-16-le")
    if b[:4] == b"\xd0\xcf\x11\xe0":
        if u16("EncryptedPackage") in b and not any(
                u16(w) in b for w in ("Workbook", "Book")):
            return ("PASSWORD PROTECTED -- ask the seller for the password or "
                    "an unprotected copy. This is NOT a corrupt file")
        if Path(path).suffix.lower() in (".xlsx", ".xlsm"):
            return ("MISNAMED -- the bytes are OLE2 (.xls) but the extension "
                    "says .xlsx. Rename it, or read it with the xlrd engine")
    return f"{type(exc).__name__}: {str(exc)[:90]}"


def read_sheet(path: Path, sheet: str, engine: str) -> pd.DataFrame:
    """Read one sheet as text, hunting for the real header if row 0 is blank.

    The Millennium .xlsb workbooks carry title rows above the table, so a plain
    read returns 'Unnamed: 0..n'. Pick the row with the most text-like cells.
    """
    d = pd.read_excel(path, sheet_name=sheet, engine=engine, header=0, dtype=str)
    unnamed = sum(str(c).startswith("Unnamed") for c in d.columns)
    # !! A BANNER ROW IS NOT ALWAYS MOSTLY BLANK. PT15018's "Other Participants"
    #   on file 2-3 has a merged "PART B" title, which pandas de-duplicates into
    #   PART B, PART B.1 ... PART B.13 -- only half the columns read as Unnamed,
    #   under the 0.6 bar, so the hunt never ran and the sheet landed with 28
    #   meaningless column names. Repeated base names are the other tell: one
    #   banner cell spread across many columns.
    # Collapse BOTH de-duplication shapes to one base: pandas writes a repeated
    # banner cell as "PART B, PART B.1 ... PART B.13" and a blank one as
    # "Unnamed: 0 ... Unnamed: 27". Counting the latter as 14 distinct names kept
    # this sheet just above the bar and it stayed broken through two reloads.
    bases = {re.sub(r"^Unnamed:.*$", "Unnamed", re.sub(r"\.\d+$", "", str(c)))
             for c in d.columns}
    banner = len(bases) < len(d.columns) * 0.5
    if unnamed > len(d.columns) * 0.6 or banner:
        head = pd.read_excel(path, sheet_name=sheet, engine=engine, header=None, nrows=30)
        best, best_n = None, 0
        for i in range(min(25, len(head))):
            n = sum(1 for v in head.iloc[i] if isinstance(v, str) and 1 < len(str(v).strip()) < 60)
            if n > best_n:
                best, best_n = i, n
        if best is not None and best_n >= 3:
            d = pd.read_excel(path, sheet_name=sheet, engine=engine, header=best, dtype=str)
    return d


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    # !! EVERY FILE IN processed/ IS LOADED, WITH NO EXCEPTIONS HERE.
    #   There used to be an underscore-folder rule, so a file could be
    #   excluded by where it sat. Two places to exclude a file is one too
    #   many: `excluded.yaml` is now the only one, intake.py honours it, and
    #   anything that reaches processed/ is meant to be read.
    files = sorted(p for r in ROOTS if r.exists()
                   for p in r.rglob("*") if p.suffix.lower() in ENGINES
                   and not p.name.startswith("~$"))

    # !! BYTE-IDENTICAL DUPLICATES ARE A REAL DELIVERY, NOT A THEORY. PT15018 ships
    #   the interim-collections .xlsb twice -- "...draft.xlsb" and "...draft (1).xlsb",
    #   same MD5 -- a download artefact. Reading both DOUBLES every payment in that
    #   book, silently, because nothing downstream can tell the copies apart.
    #   First path wins; the dropped ones are reported, not hidden.
    seen, deduped, dupes = {}, [], []
    sheet_seen, sheet_dupes = {}, []
    for f in files:
        h = hashlib.md5(f.read_bytes()).hexdigest()
        if h in seen:
            dupes.append((f, seen[h]))
        else:
            seen[h] = f
            deduped.append(f)
    for d, orig in dupes:
        print(f"  ! duplicate skipped: {d.name}  (identical to {orig.name})", file=sys.stderr)
    files = deduped
    manifest, per_deal, payments = [], {}, []

    for i, f in enumerate(files, 1):
        # !! THE DEAL CODE IS FOUND ANYWHERE IN THE PATH. `parts[0]` assumed
        #   one fixed folder shape and files a delivery under a folder NAME
        #   the moment a data room ships a different layout.
        _rel = f.relative_to(next(r for r in ROOTS if r in f.parents))
        _m = _P.DEAL_RE.search(str(_rel))
        deal = _m.group(1) if _m else _rel.parts[0]
        engine = ENGINES[f.suffix.lower()]
        try:
            xl = pd.ExcelFile(f, engine=engine)
        except Exception as e:
            why = why_unreadable(f, e)
            manifest.append({"deal": deal, "file": f.name, "path": str(_rel), "sheet": None, "rows": 0,
                             "cols": 0, "error": why[:120]})
            print(f"  [{i}/{len(files)}] UNREADABLE {f.name}\n"
                  f"        {why}", file=sys.stderr)
            continue

        for sheet in xl.sheet_names:
            try:
                d = read_sheet(f, sheet, engine)
            except Exception as e:
                manifest.append({"deal": deal, "file": f.name,
                                 "path": str(_rel), "sheet": str(sheet),
                                 "rows": 0, "cols": 0, "error": str(e)[:120]})
                continue
            d = d.dropna(how="all").dropna(axis=1, how="all")
            if d.empty:
                continue

            # !! THE SAME SHEET ARRIVES TWICE UNDER TWO FILENAMES. The MD5
            #   guard above compares BYTES and these files differ - a browser
            #   "(1)" re-download, a stray space before ".xlsx", an
            #   "__Analysis" copy - while the DATA is identical. PT20008 ships
            #   its whole book twice that way and cleaned to exactly 2x the
            #   seller's published total, 5,810 loans against 2,905 and
            #   EUR 11,503,688.66 against 5,751,844.33. Ten such pairs across
            #   four deals, every one invisible to a byte hash.
            #   Keyed on deal + SHEET NAME + content, so this only ever merges
            #   two copies of the same named sheet. Two genuinely different
            #   monthly cohorts never collide: their sheet names carry the
            #   month.
            ch = hashlib.md5(
                d.astype(str).to_csv(index=False).encode()).hexdigest()
            key = (deal, str(sheet), ch)
            if key in sheet_seen:
                sheet_dupes.append((f.name, str(sheet), sheet_seen[key]))
                continue
            sheet_seen[key] = f.name

            manifest.append({"deal": deal, "file": f.name,
                             "path": str(_rel), "sheet": str(sheet),
                             "rows": len(d), "cols": len(d.columns), "error": None})

            # Long format: one row per cell. Heterogeneous sellers cannot share a
            # wide schema -- Barclays has acct_serno, Oney has Contrato -- so the
            # tapes land keyed by column NAME and are pivoted per deal downstream.
            # !! A COLUMN NAME IS NOT ALWAYS A STRING. PT13004 heads columns
            #   with real datetimes, and parquet refuses a mixed object column:
            #   "Expected bytes, got a datetime.datetime object". The write
            #   raised, the whole loop aborted, and every tape after it in the
            #   run was simply never written - leaving a tapes/ folder that
            #   was part fresh and part two days stale with nothing saying so.
            d = d.reset_index(names="source_row")
            d.columns = [str(c) for c in d.columns]
            long = d.melt(id_vars="source_row", var_name="column_name", value_name="value")
            long["column_name"] = long["column_name"].astype(str)
            long = long[long["value"].notna()]
            long["deal"] = deal
            long["source_file"] = f.name
            long["source_sheet"] = str(sheet)
            long["source_path"] = str(_rel)
            per_deal.setdefault(deal, []).append(long)

            # Unpivot the wide monthly payment columns into a payment series.
            pcols = [c for c in d.columns if PAYMENT_COL.match(str(c).strip())]
            if pcols:
                # !! Millennium ships each loan under TWO identities. Keep the
                #   ORIGINAL "Account Number"; the "(System)" twin was renumbered
                #   between deliveries and matches the claims sheets 0 of 1,557.
                idcols = [c for c in ("account", "reference_number", "acct", "Contrato",
                                      "ID Base cessão", "Cliente Number", "Client Number",
                                      "Account Number", "COMP_OPER_PROD (Unique Loan ID)")
                          if c in d.columns]
                keep = ["source_row", *idcols, *pcols]
                p = d[keep].melt(id_vars=["source_row", *idcols],
                                 var_name="period", value_name="amount")
                p = p[p["amount"].notna()]
                p["period_month"] = p["period"].map(period_month)
                # !! TWO SERIES, NOT ONE. PT15014/PT15016 carry JAN15pay AND
                #   JAN15ret side by side -- receipts and returns (reversed or
                #   bounced payments). They must never be summed together: a
                #   reversal is not a collection. Labelled, both retained.
                p["series"] = p["period"].str.extract(r"(pay|ret)$", expand=False)
                p["series"] = p["series"].fillna("pay")
                p["deal"] = deal
                p["source_file"] = f.name
                p["source_sheet"] = str(sheet)
                payments.append(p)

        print(f"  [{i}/{len(files)}] {deal} {f.name[:48]}", file=sys.stderr)

    pd.DataFrame(manifest).to_parquet(OUT / "manifest.parquet", index=False)
    # !! ONE BAD DEAL MUST NOT TAKE THE REST WITH IT. This loop had no guard,
    #   so a single unwritable deal aborted every write after it AND the
    #   payments file, silently, leaving stale parquet on disk. Each deal is
    #   now isolated and a failure is collected, reported and returned as a
    #   non-zero exit - not a traceback that scrolls past.
    write_failed = []
    for deal, parts in per_deal.items():
        try:
            pd.concat(parts, ignore_index=True).to_parquet(
                OUT / f"{deal}.parquet", index=False)
        except Exception as e:
            write_failed.append((deal, f"{type(e).__name__}: {str(e)[:90]}"))
    if payments:
        try:
            pd.concat(payments, ignore_index=True).to_parquet(
                OUT / "payments.parquet", index=False)
        except Exception as e:
            write_failed.append(("payments", f"{type(e).__name__}: {str(e)[:90]}"))

    m = pd.DataFrame(manifest)

    # !! AN UNREADABLE DELIVERY MUST NOT BE A ROW IN A COLUMN NOBODY READS.
    #   The manifest recorded PT15014's encrypted tranche correctly and
    #   nothing ever looked. A missing file is a missing POPULATION, so it
    #   belongs in the same place as the row count.
    _dead = m[m.error.notna() & m.sheet.isna()]
    if len(_dead):
        print(f"\n!! {len(_dead)} DELIVERED FILE(S) COULD NOT BE READ. Their "
              f"loans are NOT in any output:", file=sys.stderr)
        for _, r in _dead.iterrows():
            print(f"   {r.deal}  {r.file}\n        {r.error}", file=sys.stderr)
        _pw = _dead[_dead.error.str.startswith("PASSWORD", na=False)]
        if len(_pw):
            print(f"   -> {len(_pw)} of these need a PASSWORD from the seller. "
                  f"That is an email, not a bug.", file=sys.stderr)

    if sheet_dupes:
        print(f"\n{len(sheet_dupes)} sheet(s) skipped as a CONTENT duplicate of a "
              f"sheet already read (same deal, same sheet name, identical data):")
        for fn, sh, first in sheet_dupes:
            print(f"  {fn} | {sh}\n      already read from {first}")
    print(f"\n{len(files)} files, {m.error.isna().sum()} sheets read, "
          f"{int(m.rows.sum()):,} rows, {m.error.notna().sum()} failures", file=sys.stderr)
    if write_failed:
        print(f"\n!! {len(write_failed)} DEAL(S) COULD NOT BE WRITTEN. Their "
              f"tape on disk is STALE or absent:", file=sys.stderr)
        for d, why in write_failed:
            print(f"     {d}: {why}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
