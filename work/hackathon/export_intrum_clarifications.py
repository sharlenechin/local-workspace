"""Export the hand-over folder for whoever takes the Intrum clarifications forward.

    uv run python work/hackathon/export_intrum_clarifications.py

Reads what sweden_status.ipynb wrote (sweden_status.csv, intrum_asks.csv), so run the
notebook first. Writes intrum_clarifications/ beside this file: the workbook, and copies
of the queries and write-ups behind it. README.md in that folder is hand-written and kept.
Ids, counts and amounts only; no seller value is read or written.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pandas as pd
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

HERE = Path(__file__).parent
OUT = HERE / "intrum_clarifications"
WORK = HERE.parent
AS_OF = pd.Timestamp.fromtimestamp((HERE / "sweden_status.csv").stat().st_mtime)
RAW_AS_OF = pd.Timestamp.fromtimestamp((HERE / ".cache/sweden_raw_cat.csv").stat().st_mtime)

QUERIES = {
    # what the workbook is built from
    HERE / "queries/sweden_deals.sql": "1_sweden_deals.sql",
    HERE / "queries/sweden_raw_cat.sql": "2_sweden_raw_cat.sql",
    # evidence for the two dbt bugs and the field questions
    WORK / "data-issues/intrum/queries/dbt_vs_ours_vs_pam.sql": "3_bug_isolation_six_books.sql",
    WORK / "data-issues/intrum/queries/booking_ind_by_instance.sql": "4_booking_ind_by_instance.sql",
    WORK / "data-issues/intrum/queries/booking_ind_money_by_instance.sql":
        "5_booking_ind_money_by_instance.sql",
    WORK / "data-issues/intrum/queries/mismatch_se25018.sql": "6_se25018_three_numbers.sql",
    # evidence for the reconciliation questions
    WORK / "data-issues/intrum/queries/pam_vs_cat_by_year_se16025.sql":
        "7_pam_vs_cat_by_year_se16025.sql",
    WORK / "data-issues/intrum/queries/collection_date_floor.sql": "8_collection_date_floor.sql",
}
WRITEUPS = {
    WORK / "data-issues/intrum/pam-pre-2020-swedish-books.md": "pam-pre-2020-swedish-books.md",
}

DEAL_COLUMNS = {  # the table as asked for, then the supporting columns
    "intrum_id": "Intrum id",
    "dim_case_cases": "Cases in DIM_CASE",
    "has_seller_tape": "Has seller tape",
    "tape_with_payments": "Tape has dated payments",
    "payment_history": "Seller payment history",
    "bridge_pct": "Tape bridge %",
    "bridge_via": "Tape joins via",
    "cat_collections": "CAT collections (today)",
    "pam_collections": "PAM collections",
    "reconciles": "Reconciles today",
    "reconciliation_pct": "Reconciliation % today",
    "fail_reason": "Reason",
    "reconciles_after_fixes": "Reconciles after bug fixes",
    "reconciliation_pct_after_fixes": "Reconciliation % after fixes",
    "months_pct": "Months % today",
    "months_pct_after_fixes": "Months % after fixes",
    "fixed_collections": "CAT collections (after fixes)",
    "raw_cat_cases": "Cases in raw CAT",
    "which_bug": "Bug that applies",
    "acquisition_date": "Acquisition date",
    "tape_found_in": "Tape found in",
    "unreadable_files": "Unreadable tape files",
}
MONEY = {"CAT collections (today)", "PAM collections", "CAT collections (after fixes)"}
PCT = {"Tape bridge %", "Reconciliation % today", "Reconciliation % after fixes",
       "Months % today", "Months % after fixes"}
COUNT = {"Cases in DIM_CASE", "Cases in raw CAT", "Deals", "Cases", "Unreadable tape files",
         "Number of deals"}
DARK, LIGHT = "012E26", "F2FDBE"


def read_me() -> pd.DataFrame:
    rows = [
        ("What this is", "All 639 Swedish deals we own, whether CAT reconciles to PAM for "
         "each one, and if not, why. The Intrum asks tab has the questions we need answered."),
        ("Dates", f"Warehouse figures from {AS_OF:%d %b %Y}. The after-fix figures come from "
         f"a raw CAT query run {RAW_AS_OF:%d %b %Y}. Tape match counts are from 16 Nov 2026."),
        ("Deal key", "Heimdall (HEI) deals use Intrum's id. Lokki (LOK) deals use ours, which "
         "can be different, so LOK-SE25008 is the book Intrum calls SE25018."),
        ("PAM", "Intrum's monthly report of what each book collected. We treat it as the "
         "right answer."),
        ("CAT", "Intrum's loan-level feed. 'Today' is our warehouse table as it is now, with "
         "our two bugs in it. 'After fixes' is the same data rebuilt without them."),
        ("Bug 1", "We drop payments where booking_ind = 'Y'. On Intrum system 1062 every "
         "payment is 'Y', so we lose all of that system's cash."),
        ("Bug 2", "We de-duplicate payments on orig_tr_id. On Intrum system 2080 the same "
         "payment can come in under several ids, so some get counted twice or more."),
        ("Reconciles", "CAT has payments in at least 80% of the months PAM does, and the total "
         "is within 10% of PAM, counting from the acquisition date."),
        ("Seller payment history", "What payment information the seller's tape has. "
         "'dated payments': every payment with its date, enough to build a collection curve. "
         "'totals only': just amounts paid so far. 'none': no payment information."),
        ("Tape bridge %", "How many of the deal's CAT cases (on both Swedish systems) the "
         "seller tape matches, for every deal with a tape. 'Tape joins via' says which column "
         "does it. Each tape was only matched against one of Intrum's two systems, so the "
         "real figure may be higher once both are checked."),
        ("Pass today, fail once fixed", "Some deals only reconcile today because bug 1 "
         "drops cash and bug 2 double counts it, and the two cancel out. Once fixed, they "
         "don't reconcile."),
        ("How sure", "The reasons starting with 'Probably' are a guess from the acquisition "
         "date. Only SE15044 and SE16025 have been checked year by year. Everything else is "
         "measured."),
    ]
    return pd.DataFrame(rows, columns=["Item", "Meaning"])


def summary(t: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    cancel = t["reconciles"] & ~t["reconciles_after_fixes"]
    head = pd.DataFrame([
        ("Swedish deals we own", len(t), t["dim_case_cases"].sum()),
        ("With a seller tape", t["has_seller_tape"].sum(),
         t.loc[t["has_seller_tape"], "dim_case_cases"].sum()),
        ("With a tape that has payment history", t["tape_with_payments"].sum(),
         t.loc[t["tape_with_payments"], "dim_case_cases"].sum()),
        ("Reconcile today", t["reconciles"].sum(), t.loc[t["reconciles"], "dim_case_cases"].sum()),
        ("Reconcile after our two fixes", t["reconciles_after_fixes"].sum(),
         t.loc[t["reconciles_after_fixes"], "dim_case_cases"].sum()),
        ("Pass today but fail once fixed", cancel.sum(), t.loc[cancel, "dim_case_cases"].sum()),
        ("Still fail after our fixes", (~t["reconciles_after_fixes"]).sum(),
         t.loc[~t["reconciles_after_fixes"], "dim_case_cases"].sum()),
    ], columns=["Measure", "Deals", "Cases"])
    reasons = (t.assign(Reason=t["fail_reason"].replace("", "Reconciles"))
                .groupby("Reason")
                .agg(Deals=("intrum_id", "size"), Cases=("dim_case_cases", "sum"),
                     **{"PAM collections": ("pam_collections", "sum"),
                        "CAT collections (today)": ("cat_collections", "sum"),
                        "CAT collections (after fixes)": ("fixed_collections", "sum")})
                .sort_values("Cases", ascending=False).reset_index())
    return head, reasons


def style(ws, df: pd.DataFrame, start_row: int = 1, wrap: set[str] = frozenset()) -> None:
    header = ws[start_row]
    for cell in header:
        cell.font = Font(bold=True, color=LIGHT)
        cell.fill = PatternFill("solid", fgColor=DARK)
        cell.alignment = Alignment(wrap_text=True, vertical="top")
    for i, name in enumerate(df.columns, start=1):
        letter = get_column_letter(i)
        width = 60 if name in wrap else min(max(len(str(name)), 12) + 2, 28)
        ws.column_dimensions[letter].width = width
        fmt = ("#,##0.00###" if name in MONEY else "0.00000" if name in PCT
               else "#,##0" if name in COUNT else None)
        for cell in ws[letter][start_row:]:
            if fmt:
                cell.number_format = fmt
            if name in wrap:
                cell.alignment = Alignment(wrap_text=True, vertical="top")


def main() -> None:
    t = pd.read_csv(HERE / "sweden_status.csv", index_col=0)
    # A deal that reconciles cleanly has an empty reason, which the CSV reads back as NaN.
    t["fail_reason"] = t["fail_reason"].fillna("")
    asks = pd.read_csv(HERE / "intrum_asks.csv")
    head, reasons = summary(t)
    deals = t.rename(columns=DEAL_COLUMNS)[list(DEAL_COLUMNS.values())]
    deals.index.name = "Deal key"
    key = ["HEI-SE20009", "LOK-SE25008", "LOK-SE25013", "HEI-SE19026", "HEI-SE17039",
           "LOK-SE25014", "HEI-SE16025", "HEI-SE15044"]
    asks = asks.rename(columns={"theme": "Theme", "ask": "Ask", "why": "Why",
                                "deals": "Deals (largest first)", "n_deals": "Number of deals",
                                "cases": "Cases"})

    (OUT / "queries").mkdir(parents=True, exist_ok=True)
    (OUT / "writeups").mkdir(exist_ok=True)
    xlsx = OUT / "sweden_intrum_reconciliation.xlsx"
    with pd.ExcelWriter(xlsx, engine="openpyxl") as xl:
        read_me().to_excel(xl, sheet_name="Read me", index=False)
        style(xl.sheets["Read me"], read_me(), wrap={"Meaning"})
        head.to_excel(xl, sheet_name="Summary", index=False)
        reasons.to_excel(xl, sheet_name="Summary", index=False, startrow=len(head) + 3)
        ws = xl.sheets["Summary"]
        style(ws, head)
        style(ws, reasons, start_row=len(head) + 4, wrap={"Reason"})
        asks.to_excel(xl, sheet_name="Intrum asks", index=False)
        style(xl.sheets["Intrum asks"], asks, wrap={"Ask", "Why", "Deals (largest first)"})
        deals.loc[key].to_excel(xl, sheet_name="Tape deals")
        style(xl.sheets["Tape deals"], deals.reset_index(), wrap={"Reason"})
        deals.to_excel(xl, sheet_name="All deals")
        style(xl.sheets["All deals"], deals.reset_index())
        for name in ("Intrum asks", "Tape deals", "All deals"):
            xl.sheets[name].freeze_panes = "B2"
            xl.sheets[name].auto_filter.ref = xl.sheets[name].dimensions

    for source, name in {**QUERIES, **WRITEUPS}.items():
        folder = "queries" if source.suffix == ".sql" else "writeups"
        shutil.copy2(source, OUT / folder / name)
    print(f"wrote {xlsx.relative_to(WORK.parent)} and {len(QUERIES)} queries, "
          f"{len(WRITEUPS)} write-up")


if __name__ == "__main__":
    main()
