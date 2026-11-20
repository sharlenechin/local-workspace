"""Split one delivery file into per-deal copies, and prove nothing was lost.

    python scripts/split_by_deal.py "raw/Sweden Benchmarks/swedish BMK + NORION/accounts.xlsx" \
        --key portfolio_id --vehicles HEI-SE16004 LOK-SE25008 --out sorted

Step 5 of the sort skill: a file whose rows span several deals must be filtered
to each deal before it is written into that deal's folder. A folder named for
one deal that holds every deal's rows reads as scoped and is not -- which is
worse than leaving the file unsorted.

Two things this does that a by-hand copy will not:

  * it refuses a key with a single distinct value, because a column with one
    value is not a partition (on the Ember tape `Market` reads 'Business' on
    all 14.8m rows while the real split is the governing-law column); and
  * it checks that rows in equal rows out plus rows dropped, and names the
    deals it had no folder for, so a silent loss is impossible.

Deals you do not pass in --vehicles are reported as unmatched and not written.
That is the refusal path: a deal the warehouse does not hold gets no folder.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

# Above this many rows the filtered output is written gzipped: the source is
# usually a compressed archive, and an uncompressed split can be larger than
# the delivery it came from.
GZIP_ABOVE_ROWS = 100_000


def read_any(path: Path) -> pd.DataFrame:
    if path.suffix.lower() in {".xlsx", ".xlsb", ".xls"}:
        return pd.read_excel(path)
    return pd.read_csv(path)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path)
    ap.add_argument("--key", required=True, help="the column that identifies the deal")
    ap.add_argument("--vehicles", nargs="+", required=True,
                    help="target folder names, e.g. HEI-SE16004 LOK-SE25008")
    ap.add_argument("--out", type=Path, default=Path("sorted"))
    ap.add_argument("--prefix", default="",
                    help="collision prefix, e.g. 'swedish BMK + NORION__'")
    args = ap.parse_args()

    df = read_any(args.source)
    if args.key not in df.columns:
        print(f"no column {args.key!r}; file has {list(df.columns)}", file=sys.stderr)
        return 1

    distinct = df[args.key].dropna().unique()
    if len(distinct) < 2:
        print(f"{args.key!r} has {len(distinct)} distinct value(s) -- that is not a "
              f"partition. Find the column that actually splits the file.", file=sys.stderr)
        return 1

    # The deal id is the tail of the folder name: HEI-SE16004 -> SE16004.
    targets = {v.split("-", 1)[1]: v for v in args.vehicles}
    stem, suffix = args.source.stem, args.source.suffix.lower()

    written, rows_out = [], 0
    for deal, folder in targets.items():
        part = df[df[args.key] == deal]
        if part.empty:
            print(f"  {folder:<16} no rows -- nothing written")
            continue
        dest = args.out / folder
        dest.mkdir(parents=True, exist_ok=True)
        gz = len(part) > GZIP_ABOVE_ROWS
        name = f"{args.prefix}{stem}.csv.gz" if gz else f"{args.prefix}{stem}.csv"
        part.to_csv(dest / name, index=False, compression="gzip" if gz else None)
        written.append(dest / name)
        rows_out += len(part)
        print(f"  {folder:<16} {len(part):>8,} rows -> {dest / name}")

    unmatched = sorted(set(distinct) - set(targets))
    nulls = int(df[args.key].isna().sum())

    print(f"\nrows in {len(df):,} = rows out {rows_out:,} + unmatched "
          f"{len(df) - rows_out - nulls:,} + null key {nulls:,}")
    assert rows_out + (len(df) - rows_out - nulls) + nulls == len(df)
    if unmatched:
        print(f"no folder for: {', '.join(unmatched)}  "
              f"(refused, or you did not pass it in --vehicles)")
    print(f"\nDelete the unsplit original from every deal folder it reached -- "
          f"left beside these, somebody reads the wrong one.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
