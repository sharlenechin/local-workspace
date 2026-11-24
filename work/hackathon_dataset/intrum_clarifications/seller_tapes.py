"""Which deals have a seller tape on this laptop, and whether it carries payment history.

WHERE A TAPE IS LOOKED FOR. A deal has a seller tape when a file in one of PLACES carries
either of its ids in its path: our id (VEHICLE-ID's number) or Intrum's (LOK-SE25008's
tape is filed under SE25018). Not tapes, though they carry deal ids: our own benchmark
extracts (*_BMK_*), our pricing outputs (*model_fit*), Intrum's case-mapping files
(Intrum Mappings/, aix_*), and documents (.docx, .pdf, .pptx).

PAYMENT HISTORY, three levels, decided per file:
  dated     the seller's payment-by-payment history: a file named for it
            (DATED_NAMES), e.g. "Historical Collections", "Interim Collections",
            "Kassaflöde" (cash flow).
  summary   a tape whose header row has payment columns (SUMMARY_HEADERS) but no dated
            history, e.g. "Amount of payments, last 12 months", "Inbet kapital" (capital
            paid to date). Totals, not a curve.
  none      neither.
A deal takes the best level among its files. Only HEADER ROWS are read, through the
workshop's asset_index_scan; no seller value is kept or printed. A file that cannot be
opened (DRM-protected) is judged by its name alone and listed as unreadable.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).parent
WAREHOUSE = HERE.parents[3]  # ~/data-warehouse
sys.path.insert(0, str(HERE.parents[1] / "workshop"))
import asset_index_scan as scan

PLACES = {
    "inbox": WAREHOUSE / "asset-index-cloud/data/dev/inbox",
    "sorted": WAREHOUSE / "asset-index-cloud/data/dev/sorted",
    "workshop": WAREHOUSE / "local-workspace/work/workshop/asset-index",
}
DEAL_ID = re.compile(r"[A-Z]{2}\d{5}")
DOCUMENTS = {".docx", ".doc", ".pdf", ".pptx", ".ppt", ".txt"}
DATED_NAMES = re.compile(
    r"historical collections|interim collections|kassafl[öo]de|payment history|"
    r"transactions|betalningshistorik",
    re.IGNORECASE,
)
SUMMARY_HEADERS = re.compile(
    r"payment|inbet|collect|kassa|insättn|amort|betal", re.IGNORECASE
)
LEVEL = {"none": 0, "summary": 1, "dated": 2}


def _not_a_tape(path: Path) -> bool:
    return (
        "_BMK_" in path.name
        or path.name.startswith("aix_")
        or "Intrum Mappings" in path.parts
        or "_meta" in path.parts
        or path.suffix.lower() in DOCUMENTS
        # Our own pricing outputs (OKQ8_OO_Model_Fit, pricing_models_fit): filed beside
        # tapes in the old sort, but ours, not the seller's.
        or "model_fit" in path.name.lower()
    )


def _file_level(path: Path) -> tuple[str, bool]:
    """(level, readable) for one file, from its name, else its header rows."""
    if DATED_NAMES.search(path.name):
        return "dated", True
    if path.suffix.lower() not in scan.TABULAR:
        return "none", True
    try:
        sheets = scan._sheets(path)
    except Exception:  # DRM-protected or corrupt: judged by name only
        return "none", False
    for rows in sheets.values():
        _, header = scan._header_row(rows[: scan.SCAN_ROWS])
        if any(SUMMARY_HEADERS.search(name) for _, name in header):
            return "summary", True
    return "none", True


def tape_files(ids: set[str]) -> pd.DataFrame:
    """One row per (deal id, file) for the ids asked for. Paths only, plus header rows."""
    rows, seen = [], {}
    for place, root in PLACES.items():
        for path in root.rglob("*"):
            if not path.is_file() or path.name.startswith(".") or _not_a_tape(path):
                continue
            for deal_id in set(DEAL_ID.findall(str(path.relative_to(root)))) & ids:
                if path not in seen:
                    seen[path] = _file_level(path)
                level, readable = seen[path]
                rows.append(
                    {
                        "deal_id": deal_id,
                        "place": place,
                        "file": path.name,
                        "payment_history": level,
                        "readable": readable,
                    }
                )
    return pd.DataFrame(
        rows, columns=["deal_id", "place", "file", "payment_history", "readable"]
    )


def per_deal(deals: pd.DataFrame, id_columns: list[str]) -> pd.DataFrame:
    """For each deal_key: has_seller_tape, payment_history (best level), unreadable files,
    and where the tape was found. `deals` has deal_key plus the id columns to search by."""
    ids = (
        deals.melt(id_vars="deal_key", value_vars=id_columns, value_name="deal_id")[
            ["deal_key", "deal_id"]
        ]
        .dropna()
        .drop_duplicates()
    )
    files = tape_files(set(ids["deal_id"]))
    joined = ids.merge(files, on="deal_id")
    out = joined.groupby("deal_key").agg(
        payment_history=("payment_history", lambda s: max(s, key=LEVEL.get)),
        tape_files=("file", "nunique"),
        unreadable_files=("readable", lambda s: int((~s).sum())),
        tape_found_in=("place", lambda s: ", ".join(sorted(set(s)))),
    )
    return out.reset_index()
