"""Asset Index x PAM Snapshot, from whatever is in asset-index-cloud's sorted/ right now.

Every PAM deal in every country (live from the warehouse), with the deals we have
sorted overlaid. Same layout as "Asset Index x PAM Snapshot - All Countries.xlsx":
Summary, Product, All deals, Have Seller Tape, then one tab per country.

    mise run summary                   # dev, from local-workspace
    mise run summary -- --env prod

README.md beside this file says what each tab holds and what not to quote.

Reads   asset-index-cloud/data/<env>/sorted/<VEHICLE>-<DEAL>/   (folder names only)
Writes  asset-index-cloud/data/<env>/summary/Asset Index x PAM Snapshot - All Countries.xlsx

Two flags per deal: In Our Books (Brocc holds it: DIM_BATCH or DIM_PORTFOLIO) and Have
Seller Tape (a folder in sorted/). They are independent -- a tape we hold for a deal not
in our books still shows Yes, with its folder.

data/ is gitignored in asset-index-cloud, so nothing here reaches the repo. Only folder
names are read from sorted/ -- never a seller file -- and the workbook holds PAM figures
only, so it carries no debtor data.

Replaces build_pam_overlay.py + build_pam_snapshot.py, which read the old local sorted/.
"""

import argparse
import datetime as dt
from pathlib import Path

import datalake as d
import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill
from openpyxl.utils import get_column_letter

HERE = Path(__file__).parent
CLOUD = Path.home() / "data-warehouse" / "asset-index-cloud" / "data"
# The brocc-sandbox share: PROD_RAW.HYPERION_INTRUM_PAM is readable there.
CONNECTION, WAREHOUSE = "sandbox", "DEV_WH"

NAVY = PatternFill("solid", fgColor="1F3864")
HDR = Font(bold=True, color="FFFFFF")
MONEY, INT, AGE, YEAR = "#,##0.00000", "#,##0", "#,##0.00000", "0"
YN = {True: "Yes", False: "No"}

COUNTRIES = dict(
    SE="Sweden", PT="Portugal", FI="Finland", GE="Germany", DE="Germany", NO="Norway",
    DK="Denmark", NL="Netherlands", BE="Belgium", IT="Italy", ES="Spain", FR="France",
    CH="Switzerland", PL="Poland", UK="United Kingdom", GB="United Kingdom", AT="Austria",
    CZ="Czech Republic", SK="Slovakia", HU="Hungary", GR="Greece", IE="Ireland",
    EE="Estonia", LV="Latvia", LT="Lithuania", RO="Romania", BG="Bulgaria", HR="Croatia",
    SI="Slovenia", RS="Serbia", LU="Luxembourg",
)  # fmt: skip

# Deal sheets: (header, column, number format, width), in the snapshot's order and wording.
COLS = [
    ("Country", "country", None, 10), ("Vehicle", "vehicle", None, 12),
    ("Deal id", "deal_id", None, 20), ("Deal (bare)", "deal", None, 13),
    ("Seller", "seller", None, 32), ("Product label", "product_label", None, 17),
    ("Debt type", "debt_type", None, 11), ("Mixed New/Existing", "debt_type_mixed", None, 19),
    ("Customer type", "customer_type", None, 15), ("Portfolio type", "portfolio_type", None, 16),
    ("Flow (Intrum purchase)", "flow_type", None, 24), ("Currency", "currency", None, 10),
    ("Acq principal", "acq_principal", MONEY, 18), ("Acq cases", "acq_cases", INT, 11),
    ("Avg debt age (PAM)", "debt_age", AGE, 17), ("Debt age min", "debt_age_min", AGE, 13),
    ("Debt age max", "debt_age_max", AGE, 13), ("Debt age flag", "debt_age_flag", None, 22),
    ("Capex year (Intrum)", "capex_year", YEAR, 21), ("PAM batches", "pam_batches", INT, 13),
    ("In Our Books", "in_our_books", None, 14), ("Have Seller Tape", "have_tape", None, 18),
    ("Sorted folder", "asset_index_folder", None, 20),
]  # fmt: skip


def sorted_folders(sorted_dir: Path) -> dict[str, list[str]]:
    """Deal id -> its folders in sorted/. Usually one; a deal sorted under two vehicles
    keeps both, so the disagreement shows rather than one folder silently winning."""
    folders: dict[str, list[str]] = {}
    for p in sorted(sorted_dir.iterdir()):
        if p.is_dir() and "-" in p.name and not p.name.startswith(("_", ".")):
            folders.setdefault(p.name.split("-", 1)[1].upper(), []).append(p.name)
    return folders


def overlay(sorted_dir: Path) -> pd.DataFrame:
    """One row per PAM deal plus one per sorted deal PAM does not have."""
    df = d.q(HERE / "pam_overlay.sql", connection=CONNECTION, warehouse=WAREHOUSE, lower=True)
    held = set(d.q(HERE / "held_deals.sql", connection=CONNECTION, warehouse=WAREHOUSE, lower=True).deal)
    folders = sorted_folders(sorted_dir)

    df["in_pam"] = True
    df["in_our_books"] = df.vehicle != "(not held)"
    extra = [
        dict(cc=deal[:2], vehicle=names[0].split("-")[0], deal_id=names[0], deal=deal,
             seller="(not in PAM)", in_pam=False, in_our_books=deal in held)
        for deal, names in folders.items()
        if deal not in set(df.deal)
    ]  # fmt: skip
    df = pd.concat([df, pd.DataFrame(extra)], ignore_index=True)

    df["asset_index_folder"] = df.deal.map(lambda x: "/".join(folders.get(x, [])) or None)
    df["have_tape"] = df.asset_index_folder.notna()
    df["country"] = df.cc.map(COUNTRIES).fillna(df.cc)
    return df


def header(ws, row, labels):
    for j, v in enumerate(labels, 1):
        c = ws.cell(row, j, v)
        c.font, c.fill = HDR, NAVY


def table(ws, row, labels, rows, fmts):
    header(ws, row, labels)
    for i, r in enumerate(rows, row + 1):
        for j, (v, f) in enumerate(zip(r, fmts), 1):
            c = ws.cell(i, j, None if pd.isna(v) else v)
            if f:
                c.number_format = f
    return row + len(rows) + 1


def deal_sheet(wb, title, data):
    ws = wb.create_sheet(title)
    header(ws, 1, [h for h, _, _, _ in COLS])
    for i, row in enumerate(data.itertuples(index=False), 2):
        for j, ((_, _, fmt, _), v) in enumerate(zip(COLS, row), 1):
            c = ws.cell(i, j, None if pd.isna(v) else v)
            if fmt:
                c.number_format = fmt
    for j, (_, _, _, w) in enumerate(COLS, 1):
        ws.column_dimensions[get_column_letter(j)].width = w
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = f"A1:{get_column_letter(len(COLS))}{len(data) + 1}"


def notes(df, rows, sorted_dir):
    not_pam = df[~df.in_pam]
    not_held = df[df.in_pam & ~df.in_our_books]
    no_own = df[df.have_tape & ~df.in_our_books]
    two_folders = df[df.asset_index_folder.fillna("").str.contains("/")]
    # The folder's vehicle is what `just sort` read from the warehouse; a different one
    # here means the warehouse changed since the sort, or the folder was named by hand.
    moved = df[df.in_pam & df.asset_index_folder.notna()
               & (df.asset_index_folder.fillna("") != df.deal_id)
               & ~df.asset_index_folder.fillna("").str.contains("/")]  # fmt: skip
    mixed = sorted({f"{r[0]} {r[1]}" for r in rows if r[6] and "/" in r[6]})
    return [
        f"IN OUR BOOKS = the deal is in DIM_BATCH or DIM_PORTFOLIO, i.e. Brocc holds it: "
        f"{int(df.in_our_books.sum())} deals. HAVE SELLER TAPE = the deal has a folder in {sorted_dir}: "
        f"{int(df.have_tape.sum())} deals. The tapes are in no Snowflake table, so they are read from the "
        "folder names. "
        + (f"Tape but not in our books: {', '.join(no_own.deal)}." if len(no_own) else
           "Every deal with a tape is in our books."),
        f"{len(not_pam)} deals with a tape are NOT in PAM"
        + (f": {', '.join(not_pam.deal)}. Their vehicle is read from the folder name and they carry no "
           f"financials. Of these, {', '.join(not_pam[not_pam.in_our_books].deal) or 'none'} are in "
           "our books" + ("; the rest are in neither." if (~not_pam.in_our_books).any() else ".")
           if len(not_pam) else "."),
        *([f"Sorted under two vehicles, both folders shown: {', '.join(two_folders.deal)}."] if len(two_folders) else []),
        *([f"Folder vehicle differs from the warehouse's: "
           + ", ".join(f"{r.asset_index_folder} (warehouse {r.deal_id})" for r in moved.itertuples())
           + "."] if len(moved) else []),
        "Product label is PAM's branch_desc -- the SERVICER's label, not a clean product. 'Other' and 'Finance' are "
        "catch-alls: NL25005 is 'Finance' and an SME book, PT06014 is 'Finance' and consumer.",
        "Debt type is PAM's own label and Intrum does not define it; read from the data: 'New' = placed fresh, mostly "
        "forward flow, 'Existing' = a book already in collection. 'Mixed New/Existing' marks deals with both.",
        "Flow and capex year are INTRUM's purchase from the original seller, NOT Brocc's. Every legal buyer in PAM is an "
        "Intrum entity; Brocc and Heimdall never appear.",
        "Avg debt age is PAM's average_debt_age at acquisition, principal-weighted across a deal's batches. PAM gives NO "
        "UNIT: mostly years, but some deals are days. Read the flag before quoting: 'likely days' (over 72), 'doubtful' "
        "(40-72), 'a batch reads 0' (a 0 beside non-zero batches, most likely a blank).",
        "Vehicle comes from DEAL_SOURCE_BK, not from the folder name and not from which dimension table the deal sits in: "
        "DIM_BATCH holds Lokk deals too. A deal under two vehicles shows both, e.g. HEI/LOK-FI25001.",
        f"'(not held)' = {len(not_held)} deals PAM services that we hold in neither dimension table, so no vehicle can be "
        f"read: {', '.join(not_held.deal) or 'none'}.",
        "Currency differs by country (SEK, DKK, PLN, CHF, GBP, EUR...). Do NOT sum Acq principal across countries. "
        + (f"Rows mixing currencies show no principal: {', '.join(mixed)}." if mixed else ""),
        "Acq principal and Acq cases are acquisition statics: PAM repeats them on every monthly row, so they are MAX per "
        "batch then summed across a deal's batches. A plain SUM over the raw table overstates by the number of months.",
    ]  # fmt: skip


def build(df: pd.DataFrame, sorted_dir: Path, out: Path) -> None:
    asof = dt.date.today().isoformat()
    deals = df[[c for _, c, _, _ in COLS]].copy()
    for c in ["debt_type_mixed", "in_our_books", "have_tape"]:
        # Non-PAM rows have no debt_type_mixed; leave those blank, not "No".
        deals[c] = deals[c].map(lambda v: YN[bool(v)] if pd.notna(v) else None)
    # Country, then biggest deal first; sorted-only deals (no principal) last.
    deals = deals.sort_values(["country", "acq_principal"], ascending=[True, False], na_position="last")

    wb = Workbook()

    # ---- Summary: country x vehicle ---------------------------------------------
    ws = wb.active
    ws.title = "Summary"
    ws["A1"] = "PAM deals in every country by vehicle and product, with the deals in the Asset Index overlaid"
    ws["A1"].font = Font(bold=True, size=13)
    ws["A2"] = (
        "Source: PROD_RAW.HYPERION_INTRUM_PAM (pmode_name='Real') + DIM_BATCH / DIM_PORTFOLIO for the vehicle, "
        f"via the brocc-sandbox share. Queried live {asof}. Have Seller Tape read from {sorted_dir} {asof}."
    )
    ws["A2"].font = Font(size=9)
    rows = []
    for (country, vehicle), g in df.groupby(["country", "vehicle"]):
        ccy = sorted(g.currency.dropna().unique())
        # One currency per row, or the principal is not addable -- blank it rather than mix.
        principal = g.acq_principal.sum() if len(ccy) == 1 else None
        rows.append([country, vehicle, int(g.in_pam.sum()), int(g.have_tape.sum()),
                     principal, g.acq_cases.sum(min_count=1), "/".join(ccy) or None])  # fmt: skip
    end = table(ws, 4, ["Country", "Vehicle", "PAM deals", "Have Seller Tape", "Acq principal", "Acq cases", "Currency"],
                rows, [None, None, INT, INT, MONEY, INT, None])  # fmt: skip
    ws.freeze_panes = "A5"
    ws.cell(end + 1, 1, "Notes").font = Font(bold=True)
    for i, n in enumerate(notes(df, rows, sorted_dir), end + 2):
        ws.cell(i, 1, n)
    for col, w in zip("ABCDEFG", [32, 12, 11, 18, 20, 11, 10]):
        ws.column_dimensions[col].width = w

    # ---- Product ------------------------------------------------------------------
    ws = wb.create_sheet("Product")
    ws["A1"] = ("Product label is PAM's branch_desc -- the servicer's own label. 'Other' and 'Finance' are catch-alls; "
                "treat them as unknown. No principal here: one label spans many currencies.")  # fmt: skip
    pam = df[df.in_pam]
    p = (pam.groupby("product_label")
         .agg(deals=("deal", "count"), cases=("acq_cases", "sum"), ai=("have_tape", "sum"))
         .sort_values("deals", ascending=False))  # fmt: skip
    end = table(ws, 3, ["Product label", "Deals", "Acq cases", "Have Seller Tape"],
                [[k, int(v.deals), v.cases, int(v.ai)] for k, v in p.iterrows()], [None, INT, INT, INT])  # fmt: skip
    for title, by in [("Deals by product x country", "country"), ("Deals by product x vehicle", "vehicle")]:
        ws.cell(end + 1, 1, title).font = Font(bold=True)
        x = pd.crosstab(pam.product_label, pam[by], margins=True, margins_name="All")
        end = table(ws, end + 3, ["Product label", *x.columns],
                    [[k, *map(int, v)] for k, v in x.iterrows()], [None] + [INT] * len(x.columns))  # fmt: skip
    ws.column_dimensions["A"].width = 28
    for j in range(2, 20):
        ws.column_dimensions[get_column_letter(j)].width = 12

    # ---- Deal sheets ------------------------------------------------------------------
    deal_sheet(wb, "All deals", deals)
    deal_sheet(wb, "Have Seller Tape", deals[deals.have_tape == "Yes"])
    for country in sorted(deals.country.unique()):
        deal_sheet(wb, country[:31], deals[deals.country == country])

    wb.save(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--env", default="dev", choices=["dev", "prod", "local"])
    args = parser.parse_args()
    sorted_dir = CLOUD / args.env / "sorted"
    out_dir = CLOUD / args.env / "summary"
    if not sorted_dir.is_dir():
        raise SystemExit(f"No {sorted_dir} -- run `just sort` in asset-index-cloud first.")
    out_dir.mkdir(exist_ok=True)

    df = overlay(sorted_dir)
    out = out_dir / "Asset Index x PAM Snapshot - All Countries.xlsx"
    build(df, sorted_dir.relative_to(CLOUD.parent), out)

    sorted_only = df[~df.in_pam]
    print(f"Wrote {out}")
    print(f"  {int(df.in_pam.sum())} PAM deals, {int(df.in_our_books.sum())} In Our Books, "
          f"{int(df.have_tape.sum())} Have Seller Tape")  # fmt: skip
    if len(sorted_only):
        print(f"  sorted but not in PAM: {', '.join(sorted_only.deal_id)}")
    unowned = df[df.have_tape & ~df.in_our_books]
    if len(unowned):
        print(f"  tape but not in our books: {', '.join(unowned.asset_index_folder)}")


if __name__ == "__main__":
    main()
