"""Apply the workbook's visual pass to an already-written data_landscape.xlsx.

Separate from landscape_workbook.py so the look can be changed without re-running the
queries that build the frames. landscape_workbook.polish() holds the same rules, so a
fresh build comes out looking the same as a restyle of an old one.

Run:  uv run python work/workshop/restyle_landscape.py
⚠ Close the workbook in Excel first. Excel holds a lock file (~$data_landscape.xlsx) and
  will write its own stale copy back over this one when it next saves.
"""

from __future__ import annotations

import sys
from pathlib import Path

import openpyxl

sys.path.insert(0, str(Path(__file__).parent))
from landscape_workbook import polish  # noqa: E402

BOOK = Path(__file__).parent / "data_landscape.xlsx"


def main() -> None:
    lock = BOOK.parent / f"~${BOOK.name}"
    if lock.exists():
        print(f"⚠ {BOOK.name} looks open in Excel ({lock.name} is present).")
        print("  Close it, then run this again, or Excel will overwrite the restyle.")
        return
    wb = openpyxl.load_workbook(BOOK)
    for ws in wb.worksheets:
        polish(ws)
    wb.save(BOOK)
    print(f"restyled {len(wb.worksheets)} sheets in {BOOK}")


if __name__ == "__main__":
    main()
