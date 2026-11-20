"""Scan the raw workbooks for a stated CUT-OFF DATE and record it.

    uv run python scripts/find_cutoff.py            # report every deal
    uv run python scripts/find_cutoff.py --write    # fill blank deals.csv rows

!! THE DATE WAS ON THE TAPE ALL ALONG, ONE ROW ABOVE THE DATA. PT16023's
   master data tape says `Cut-off date | 42643` in row 1 - Excel serial for
   2016-09-30 - and the loader never saw it, because finding the real header
   means skipping exactly the banner rows a seller puts that sort of thing in.
   Twelve of thirteen deals had no cut-off date and nobody had looked here.

!! THIS READS, IT DOES NOT INFER. A date is recorded only where the sheet
   LABELS it: `cut-off`, `cutoff`, `data de corte`, `data de referencia`,
   `as of`, `reference date` and the like, with a date in a nearby cell. A
   date sitting alone in a banner proves nothing and is ignored. Guessing a
   cut-off from the newest default date is exactly the derivation the rest of
   this pipeline refuses, and it is not done here either.
"""
import re
import sys
import warnings

import pandas as pd

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import paths as _P

warnings.simplefilter("ignore")

# what a seller might call it, in either language
LABEL = re.compile(r"cut[\s\-_]?off|data\s+de\s+corte|data\s+de\s+refer|"
                   r"reference\s+date|as\s+of\s+date|^as\s+of$|fecha\s+de\s+corte",
                   re.I)
ENGINES = {".xlsx": "openpyxl", ".xls": "xlrd", ".xlsb": "pyxlsb"}
BANNER_ROWS = 8            # a banner lives at the very top or not at all


def as_date(v):
    """A cell that is a date, or an Excel serial that plausibly is one."""
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        # 36526 = 2000-01-01, 54789 = 2050-01-01: outside that it is not a date
        if 36526 <= float(v) <= 54789:
            return (pd.Timestamp("1899-12-30")
                    + pd.Timedelta(days=float(v))).date()
        return None
    try:
        d = pd.to_datetime(v, errors="coerce")
    except Exception:
        return None
    if pd.isna(d) or not (2000 <= d.year <= 2050):
        return None
    return d.date()


def scan(deal):
    """Every (file, sheet, label, date) a labelled cut-off appears in."""
    found = []
    root = _P.PROCESSED / deal
    if not root.exists():
        return found
    for f in sorted(p for p in root.rglob("*")
                    if p.suffix.lower() in ENGINES and not p.name.startswith("~$")):
        try:
            xl = pd.ExcelFile(f, engine=ENGINES[f.suffix.lower()])
        except Exception:
            continue
        for sh in xl.sheet_names:
            try:
                top = xl.parse(sh, header=None, nrows=BANNER_ROWS)
            except Exception:
                continue
            for r in range(len(top)):
                for c in range(len(top.columns)):
                    cell = top.iat[r, c]
                    if not isinstance(cell, str) or not LABEL.search(cell):
                        continue
                    # the date sits beside it, or just under it
                    for rr, cc in ((r, c + 1), (r, c + 2), (r + 1, c),
                                   (r + 1, c + 1)):
                        if rr >= len(top) or cc >= len(top.columns):
                            continue
                        d = as_date(top.iat[rr, cc])
                        if d:
                            found.append((f.name, sh, cell.strip(), d))
                            break
    return found


def payment_span(deal):
    """(first, last) month money actually moved -- CORROBORATION, never a source.

    !! A CUT-OFF SITS NEAR THE LAST PAYMENT, and that is evidence, not a date.
       PT16023's banner says 2016-09-30 and its payments stop 2016-08: those
       two agreeing is worth far more than either alone. PT15018's run five
       months PAST its cut-off, which is also right - those are the interim
       collections, money paid between the tape being struck and the book
       registering.
       So the span is PRINTED beside any stated date and never written as
       one. A tape whose payments end in October is suggestive of an October
       cut-off and proves nothing: the seller might have cut in December and
       nobody paid for two months.
    """
    f = _P.PAYMENTS_RAW
    if not f.exists():
        return None, None
    g = pd.read_parquet(f)
    g = g[(g.deal == deal)
          & (pd.to_numeric(g.amount, errors="coerce").fillna(0) != 0)]
    m = g.period_month.dropna() if len(g) else pd.Series(dtype=str)
    if not len(m):
        return None, None
    return str(m.min()), str(m.max())


def main(write=False):
    deals = pd.read_csv(_P.DEALS)
    known = {str(r.deal_id): str(r.cutoff_date) for _, r in deals.iterrows()}
    hits, changed = {}, []
    for d in sorted(p.stem for p in _P.ACCOUNTS.glob("PT*.parquet")):
        f = scan(d)
        hits[d] = f
        have = known.get(d, "nan")
        have = "" if have in ("nan", "") else have
        dates = sorted({x[3] for x in f})
        if not f:
            _f, _l = payment_span(d)
            _hint = (f"   payments run {_f}..{_l}, so a cut-off near {_l} "
                     f"would fit - EVIDENCE ONLY, nothing written"
                     if _l and not have else "")
            print(f"  {d}  {'(' + have + ')' if have else 'no label found'}"
                  f"{_hint}")
            continue
        # !! A SHEET'S CUT-OFF IS NOT THE DEAL'S, and this tool finds both.
        #   PT15018 labels `Cut-Off Date` on its Claims sheet as 2016-07-08 -
        #   the date the CLAIMS were measured, on 673 loans - while the deal
        #   is struck at 2015-09-30 across all 32,692. Writing the first
        #   label found would re-create T45 exactly. Where the tape and
        #   deals.csv disagree, the tape is REPORTED and nothing is written:
        #   a human knows which sheet speaks for the deal and this cannot.
        if have and str(sorted({x[3] for x in f})[0]) != have:
            print(f"  {d}  !! DISAGREES: deals.csv says {have}, the tape "
                  f"labels {sorted({x[3] for x in f})[0]} on "
                  f"`{f[0][1]}` of {f[0][0][:30]}")
            print(f"        A SHEET may carry its own cut-off (T45). Not "
                  f"written - check which one speaks for the whole deal.")
            continue
        where = f"{f[0][2]} in {f[0][1]} of {f[0][0][:34]}"
        if len(dates) > 1:
            print(f"  {d}  !! {len(dates)} DIFFERENT dates labelled cut-off: "
                  f"{dates} -- NOT written, a human must choose")
            continue
        _f, _l = payment_span(d)
        _corr = ""
        if _l:
            _agree = str(dates[0])[:7] >= _l
            _corr = (f"   [payments {_f}..{_l}, "
                     + ("consistent" if _agree else
                        "money AFTER the cut-off - interim collections")
                     + "]")
        print(f"  {d}  {dates[0]}   <- `{where}`{_corr}")
        if not have:
            changed.append((d, dates[0], where))

    if changed:
        print(f"\n{len(changed)} deal(s) have a stated cut-off date and no "
              f"cutoff_date in deals.csv:")
        for d, dt, where in changed:
            print(f"  {d}  {dt}")
        if write:
            for d, dt, where in changed:
                deals.loc[deals.deal_id == d, "cutoff_date"] = str(dt)
                deals.loc[deals.deal_id == d, "note"] = (
                    f"cutoff_date {dt} READ from the tape, not inferred: "
                    f"`{where}`. Found by find_cutoff.py.")
            deals.to_csv(_P.DEALS, index=False)
            print(f"\nwritten to {_P.DEALS.name}. Re-clean those deals.")
        else:
            print("\nAdd --write to record them. Nothing was changed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main("--write" in sys.argv))
