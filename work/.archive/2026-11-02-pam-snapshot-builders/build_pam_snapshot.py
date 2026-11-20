"""Asset Index x PAM Snapshot, all countries.

Same layout as the OneDrive "Asset Index x PAM Snapshot Latest.xlsx" (which
covered SE/PT/FI/GE only): Summary, Product, All deals, In Asset Index, then
one tab per country. Reads pam_overlay_all.csv, so run build_pam_overlay.py
first when the data needs refreshing.

    uv run python work/asset-index-sharepoint/checks/build_pam_snapshot.py
"""

import datetime as dt
from pathlib import Path

import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

HERE = Path(__file__).parent
OUT = HERE / "Asset Index x PAM Snapshot - All Countries.xlsx"
CSV = HERE / "pam_overlay_all.csv"

NAVY = PatternFill("solid", fgColor="1F3864")
HDR = Font(bold=True, color="FFFFFF")
MONEY, INT, AGE, YEAR = "#,##0.00000", "#,##0", "#,##0.00000", "0"

df = pd.read_csv(CSV)
asof = dt.date.fromtimestamp(CSV.stat().st_mtime).isoformat()
yn = {True: "Yes", False: "No"}

# Deal sheets: the OneDrive file's 24 columns, in its order and wording.
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
    ("In PAM", "in_pam", None, 10), ("In warehouse", "in_warehouse", None, 17),
    ("In Asset Index", "in_asset_index", None, 19), ("Asset index folder", "asset_index_folder", None, 20),
]
deals = df[[c for _, c, _, _ in COLS]].copy()
for c in ["debt_type_mixed", "in_pam", "in_warehouse", "in_asset_index"]:
    # Non-PAM rows have no debt_type_mixed; leave those blank, not "No".
    deals[c] = deals[c].map(lambda v: yn.get(v, yn.get(str(v) == "True") if pd.notna(v) else None))
# Country name, then biggest deal first; asset-index-only deals (no principal) last.
deals = deals.sort_values(["country", "acq_principal"], ascending=[True, False], na_position="last")


def header(ws, row, labels):
    for j, v in enumerate(labels, 1):
        c = ws.cell(row, j, v)
        c.font, c.fill = HDR, NAVY


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


def table(ws, row, labels, rows, fmts, widths=None):
    header(ws, row, labels)
    for i, r in enumerate(rows, row + 1):
        for j, (v, f) in enumerate(zip(r, fmts), 1):
            c = ws.cell(i, j, None if pd.isna(v) else v)
            if f:
                c.number_format = f
    return row + len(rows) + 1


wb = Workbook()

# ---- Summary: country x vehicle -------------------------------------------
ws = wb.active
ws.title = "Summary"
ws["A1"] = "PAM deals in every country by vehicle and product, with the deals in the Asset Index overlaid"
ws["A1"].font = Font(bold=True, size=13)
ws["A2"] = (
    "Source: PROD_RAW.HYPERION_INTRUM_PAM (pmode_name='Real') + DIM_BATCH / DIM_PORTFOLIO for the vehicle, "
    f"via the brocc-sandbox share. Queried live {asof}. In Asset Index read from the sorted/ deal folders {asof}."
)
ws["A2"].font = Font(size=9)

rows = []
for (country, vehicle), g in df.groupby(["country", "vehicle"]):
    ccy = sorted(g.currency.dropna().unique())
    # One currency per row, or the principal is not addable -- blank it rather than mix.
    principal = g.acq_principal.sum() if len(ccy) == 1 else None
    rows.append([country, vehicle, int(g.in_pam.sum()), int(g.in_asset_index.sum()),
                 principal, g.acq_cases.sum(min_count=1), "/".join(ccy) or None])
end = table(ws, 4, ["Country", "Vehicle", "PAM deals", "In Asset Index", "Acq principal", "Acq cases", "Currency"],
            rows, [None, None, INT, INT, MONEY, INT, None])
ws.freeze_panes = "A5"

not_pam = df[~df.in_pam]
not_held = df[df.in_pam & ~df.in_warehouse]
n_ai = int(df.in_asset_index.sum())
no_own = df[df.asset_index_folder.notna() & ~df.in_asset_index]
mixed = sorted({r[0] + " " + r[1] for r in rows if r[6] and "/" in r[6]})
NOTES = [
    f"IN ASSET INDEX = we have the deal's files (a folder in sorted/) AND we own it (IN WAREHOUSE): {n_ai} deals. "
    f"{len(no_own)} more have a folder but are not in the warehouse, so read No; their folder still shows in "
    f"Asset index folder: {', '.join(no_own.deal)}. IN WAREHOUSE = the deal is in DIM_BATCH or DIM_PORTFOLIO, "
    "i.e. Brocc holds it. The asset index itself is in no Snowflake table, so it is read from the files.",
    f"{len(not_pam)} deals with an asset-index folder are NOT in PAM: {', '.join(not_pam.deal)}. Their vehicle is read from the folder "
    "name and they carry no financials. "
    f"Of these, {', '.join(not_pam[not_pam.in_warehouse].deal) or 'none'} are in the warehouse; the rest are in neither.",
    "Norway has no deals in PAM or the warehouse; its two rows are asset-index folders we do not own.",
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
    f"read: {', '.join(not_held.deal)}.",
    "Currency differs by country (SEK, DKK, PLN, CHF, GBP, EUR...). Do NOT sum Acq principal across countries. "
    + (f"Rows mixing currencies show no principal: {', '.join(mixed)}." if mixed else ""),
    "Acq principal and Acq cases are acquisition statics: PAM repeats them on every monthly row, so they are MAX per "
    "batch then summed across a deal's batches. A plain SUM over the raw table overstates by the number of months.",
]
r = end + 1
ws.cell(r, 1, "Notes").font = Font(bold=True)
for i, n in enumerate(NOTES, r + 1):
    ws.cell(i, 1, n)
for col, w in zip("ABCDEFG", [32, 12, 11, 18, 20, 11, 10]):
    ws.column_dimensions[col].width = w

# ---- Product ----------------------------------------------------------------
ws = wb.create_sheet("Product")
ws["A1"] = ("Product label is PAM's branch_desc -- the servicer's own label. 'Other' and 'Finance' are catch-alls; "
            "treat them as unknown. No principal here: one label spans many currencies.")
pam = df[df.in_pam]
p = (pam.groupby("product_label").agg(deals=("deal", "count"), cases=("acq_cases", "sum"),
                                       ai=("in_asset_index", "sum"))
     .sort_values("deals", ascending=False))
end = table(ws, 3, ["Product label", "Deals", "Acq cases", "In Asset Index"],
            [[k, int(v.deals), v.cases, int(v.ai)] for k, v in p.iterrows()], [None, INT, INT, INT])

for title, by in [("Deals by product x country", "country"), ("Deals by product x vehicle", "vehicle")]:
    r = end + 1
    ws.cell(r, 1, title).font = Font(bold=True)
    x = pd.crosstab(pam.product_label, pam[by], margins=True, margins_name="All")
    end = table(ws, r + 2, ["Product label", *x.columns],
                [[k, *map(int, v)] for k, v in x.iterrows()], [None] + [INT] * len(x.columns))
ws.column_dimensions["A"].width = 28
for j in range(2, 20):
    ws.column_dimensions[get_column_letter(j)].width = 12

# ---- Deal sheets --------------------------------------------------------------
deal_sheet(wb, "All deals", deals)
deal_sheet(wb, "In Asset Index", deals[deals.in_asset_index == "Yes"])
for country in sorted(deals.country.unique()):
    deal_sheet(wb, country[:31], deals[deals.country == country])

wb.save(OUT)
print(OUT, "|", len(deals), "deals |", wb.sheetnames)
print(pd.DataFrame(rows, columns=["country", "vehicle", "pam", "ai", "principal", "cases", "ccy"]).to_string())
