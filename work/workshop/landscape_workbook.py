"""Write the data landscape to one documented Excel workbook.

Every data sheet opens with a title, what it answers, its grain and its source, then the
table. A Guide sheet explains the labels, and a Data Dictionary sheet defines every column
of every sheet. Colours come from conditional formatting, not per-cell styles, so the large
deal x attribute grids stay quick to write and to open.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field, replace

import pandas as pd
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

TABLE_ROW = 6  # the table's header row; rows 1-4 describe the sheet

# Cell values that are labels rather than prose are written Title Case, so the sheets
# read as a document. Column ids stay snake_case: they name a field, and a reader who
# cross-references one against the grids needs to recognise it. Free text, file names and
# real source column names (CASES.statute_barred_date) are left exactly as they are.
TITLED_VALUES = (
    "attribute", "static_or_variable", "legal_source", "acquired_by", "balance_basis",
    "npl_common_grain", "who", "how_long", "product_type", "deal_flow_type",
    "main_blocker", "verdict",
)
# Prose, so only the first letter: "no" -> "No", not "Yes: Matching and Benchmark Filter".
# local_term is left alone: those are foreign terms as a tape spells them.
SENTENCE_VALUES = ("used_in_npl_underwriting",)
UPPER_WORDS = {"id", "eur", "cat", "pam", "npl", "gbv", "sme", "vat", "fx", "uk", "gb",
               "dbt", "drm", "iban", "nif"}
LOWER_WORDS = {"of", "to", "and", "or", "the", "a", "an", "in", "on", "at", "per", "by",
               "for", "vs"}


def _title_word(word: str, first_or_last: bool) -> str:
    """One word, keeping whatever punctuation it arrived with (gbv: -> GBV:)."""
    core = word.strip(":.,;()[]")
    if not core:
        return word
    head, tail = word[:word.index(core)], word[word.index(core) + len(core):]
    low = core.lower()
    if low in UPPER_WORDS:
        core = low.upper()
    elif low in LOWER_WORDS and not first_or_last:
        core = low
    elif "-" in core:                               # mail-order -> Mail-Order
        core = "-".join(w[:1].upper() + w[1:] for w in core.split("-"))
    else:
        core = core[:1].upper() + core[1:]
    return head + core + tail


def titleize(text: str) -> str:
    """snake_case or lower case -> Title Case."""
    words = str(text).replace("_", " ").split()
    return " ".join(_title_word(w, i in (0, len(words) - 1)) for i, w in enumerate(words))


def _titled(sheet: "Sheet") -> "Sheet":
    """The same sheet with its label columns written Title Case. Headers are untouched."""
    cols = [c for c in TITLED_VALUES if c in sheet.frame.columns]
    sentence = [c for c in SENTENCE_VALUES if c in sheet.frame.columns]
    if not cols and not sentence:
        return sheet
    frame = sheet.frame.copy()
    for c in cols:
        frame[c] = frame[c].map(lambda v: titleize(v) if isinstance(v, str) else v)
    for c in sentence:
        frame[c] = frame[c].map(lambda v: v[:1].upper() + v[1:] if isinstance(v, str) else v)
    return replace(sheet, frame=frame)

NAVY = PatternFill("solid", fgColor="1F3864")
LABEL_COLOURS = {
    # label prefix -> fill. The first prefix that matches a cell wins.
    "Found": "C6EFCE",
    "Mainly Not Null": "C6EFCE",
    "Mainly Null": "FFEB9C",
    "Not Found: DBT Clean Up Required": "F8CBAD",
    "Not Found: Batch Level Only": "DDEBF7",
    "Not Found": "FFC7CE",
    "Unreadable": "E4DFEC",
    "No Seller Tape": "D9D9D9",
    "Not Relevant": "F2F2F2",
}

# What every label in the grids means. Shown on the Guide sheet, so plain words: the
# labels themselves keep their internal names, which the grids and the code share.
LABELS = [
    ("Found", "D1", "A column in the seller's files carries it (or what it is built from)."),
    ("Not Found", "D1", "No readable seller file carries it."),
    ("Unreadable", "D1, D2", "The deal has seller files nobody can open, so it may be inside them."),
    ("No Seller Tape", "D1, D2", "We own the deal but hold no seller files for it."),
    ("Not Relevant", "D, E", "A legal attribute of another country, never expected here."),
    ("Mainly Not Null (90%+)", "D2, E3", "At least 90% of rows hold a real value."),
    ("Mainly Null (10%+)", "D2, E3", "10% or more are blank, in any language. Includes an entirely empty column."),
    ("Found in a Table", "E1, E2", "Held per case, for this deal."),
    ("Not Found in a Table", "E1", "The servicer's feed has no case-level column for it."),
    ("Not Found: DBT Clean Up Required", "E2, E3", "The servicer sends it per case; our modelling does not carry it through. Our work."),
    ("Not Found: Batch Level Only", "E2, E3", "We hold it per batch, not per loan. Splitting it to a loan needs a decision."),
    ("Not Found: Not Sent by Servicer", "E2, E3", "The servicer does not send it."),
    ("Not Found: No Data for Deal", "E2, E3", "The column exists but holds nothing for this deal."),
]


# One hue per section, so 21 tabs read as six groups rather than a wall of names.
#   navy    the story: Summary and slides 1-3
#   slate   its appendix: 1a, 2a
#   teal    what an attribute is: A, B
#   grey    the book itself: C
#   orange  before we bought it: D
#   purple  after we bought it: E
#   silver  reference: Guide, Data Dictionary
TAB_COLOURS = {
    "Summary": "1F3864", "1": "1F3864", "2": "1F3864", "3": "1F3864",
    "A": "2E7D6F", "B": "2E7D6F", "C": "7F7F7F", "D": "C55A11", "E": "7030A0",
    "Guide": "BFBFBF", "Data Dictionary": "BFBFBF",
}
RULE = Side(style="thin", color="BFBFBF")
BAND = PatternFill("solid", fgColor="F7F9FC")
BAND_LIMIT = 400  # rows; above this, banding costs more than it is worth to write or open


def _tab_colour(name: str) -> str:
    # "1a Deal Readiness", "2a By Attribute": the two pages the workbook leads with.
    if len(name) > 1 and name[0].isdigit() and name[1].isalpha():
        return "1F3864"
    return TAB_COLOURS.get(name) or TAB_COLOURS.get(name[0], "7F7F7F")


def polish(ws) -> None:
    """The visual pass: applied on build, and re-appliable to a saved workbook.

    Sheet- and column-level only on the big grids. The deal x attribute sheets are
    2,680 x 110, so per-cell work there is ~295k cells and makes the file slow to write
    and to open -- the same reason the label colours come from conditional formatting.
    """
    ws.sheet_properties.tabColor = _tab_colour(ws.title)
    ws.sheet_view.showGridLines = False       # the tables carry their own structure
    ws.sheet_view.zoomScale = 90

    # Print: landscape, one page wide, header row repeated on every page.
    ws.page_setup.orientation = "landscape"
    ws.page_setup.fitToWidth = 1
    ws.page_setup.fitToHeight = 0
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    ws.print_options.horizontalCentered = True

    ws.sheet_format.defaultRowHeight = 16     # a little air between rows

    header = TABLE_ROW if ws.title not in ("Summary", "Guide", "Data Dictionary") else None
    if header and ws.max_row > header:
        ws.print_title_rows = f"{header}:{header}"
        # A rule under the header separates it from the data once gridlines are off.
        for c in range(1, ws.max_column + 1):
            ws.cell(row=header, column=c).border = Border(bottom=Side(style="medium",
                                                                      color="FFFFFF"))

        # A deal x attribute grid. Keep deal_id, vehicle and country on screen while
        # reading across 100+ attribute columns -- freezing only deal_id leaves you
        # scrolling back to find out whose row you are on.
        # Keyed on deal_id, not just on width: sheet 1b is 21 columns wide and is not a
        # grid, and freezing three columns there would hide the counts it leads with.
        if ws.max_column > 20 and ws.cell(row=header, column=1).value == "deal_id":
            ws.freeze_panes = ws.cell(row=header + 1, column=4)
            # Centre the label columns, set on the column so 295k cells are not touched.
            for c in range(4, ws.max_column + 1):
                col = ws.column_dimensions[get_column_letter(c)]
                col.alignment = Alignment(horizontal="center", vertical="center")

        if ws.max_row - header <= BAND_LIMIT:
            for r in range(header + 2, ws.max_row + 1, 2):
                for c in range(1, ws.max_column + 1):
                    ws.cell(row=r, column=c).fill = BAND
    elif ws.max_row and ws.title != "Summary":
        # The Guide and the dictionary have their own header rows; the Summary styles its own.
        for r in (4, 3):
            if ws.cell(row=r, column=1).font and ws.cell(row=r, column=1).font.bold:
                for c in range(1, ws.max_column + 1):
                    ws.cell(row=r, column=c).border = Border(bottom=RULE)
                break


@dataclass
class Sheet:
    name: str                      # Excel tab name, 31 characters at most
    title: str
    answers: str                   # what question the sheet answers, one or two sentences
    grain: str
    source: str
    frame: pd.DataFrame
    columns: dict[str, str] = field(default_factory=dict)  # column -> meaning, for the dictionary
    grid: bool = False             # deal x attribute grid: label colours, narrow columns
    decimals: tuple[str, ...] = () # columns shown to 5 decimal places
    percent: tuple[str, ...] = ()  # shares shown as a rounded percentage, for the slides
    money: tuple[str, ...] = ()    # money columns, 5 decimal places with thousands separators
    wide: tuple[str, ...] = ()     # long free-text columns, wrapped


def _describe(ws, sheet: Sheet, as_of: str) -> None:
    ws["A1"] = sheet.title
    ws["A1"].font = Font(bold=True, size=14, color="1F3864")
    for row, (label, text) in enumerate(
        [("Answers", sheet.answers), ("Grain", sheet.grain), ("Source", f"{sheet.source} As of {as_of}.")],
        start=2,
    ):
        ws.cell(row=row, column=1, value=label).font = Font(bold=True)
        ws.cell(row=row, column=2, value=text).alignment = Alignment(wrap_text=False, vertical="top")


def _style_table(ws, sheet: Sheet) -> None:
    df = sheet.frame
    n_rows, n_cols = len(df), len(df.columns)
    last_row = TABLE_ROW + n_rows
    for c, name in enumerate(df.columns, start=1):
        cell = ws.cell(row=TABLE_ROW, column=c)
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = NAVY
        cell.alignment = Alignment(wrap_text=True, vertical="center")
        letter = get_column_letter(c)
        if name in sheet.wide:
            width = 60
        elif sheet.grid and c > 3 and name not in sheet.decimals:
            width = 16
        else:
            width = min(max(len(str(name)) + 2, 12), 34)
        ws.column_dimensions[letter].width = width
        fmt = None
        if name in sheet.money:
            fmt = "#,##0.00000"
        elif name in sheet.percent:
            # Slides only. The count it divides is in the column beside it, so rounding
            # the share here hides nothing; the appendix keeps all 5 decimals.
            fmt = "0.0%"
        elif name in sheet.decimals:
            fmt = "0.00000"
        elif pd.api.types.is_datetime64_any_dtype(df[name]):
            fmt = "yyyy-mm-dd"
        if fmt or name in sheet.wide:
            for r in range(TABLE_ROW + 1, last_row + 1):
                cell = ws.cell(row=r, column=c)
                if fmt:
                    cell.number_format = fmt
                if name in sheet.wide:
                    cell.alignment = Alignment(wrap_text=True, vertical="top")
    ws.row_dimensions[TABLE_ROW].height = 45
    ws.freeze_panes = ws.cell(row=TABLE_ROW + 1, column=2)
    if n_rows:
        ws.auto_filter.ref = f"A{TABLE_ROW}:{get_column_letter(n_cols)}{last_row}"
    if sheet.grid and n_rows:
        first = 4
        rng = f"{get_column_letter(first)}{TABLE_ROW + 1}:{get_column_letter(n_cols)}{last_row}"
        top_left = f"{get_column_letter(first)}{TABLE_ROW + 1}"
        for prefix, colour in LABEL_COLOURS.items():
            # Exact for "Found", a prefix for the rest; stopIfTrue makes the first match win.
            formula = (f'{top_left}="{prefix}"' if prefix == "Found"
                       else f'LEFT({top_left},{len(prefix)})="{prefix}"')
            ws.conditional_formatting.add(
                rng, FormulaRule(formula=[formula], fill=PatternFill("solid", fgColor=colour), stopIfTrue=True)
            )


def _summary(ws, headline, rows, as_of: str) -> None:
    """The front page: three figures, then the findings. Nothing else."""
    ws["A1"] = "Data Landscape"
    ws["A1"].font = Font(bold=True, size=18, color="1F3864")
    ws["A2"] = f"What we own, and how much of it a model can use. As of {as_of}."
    ws["A2"].font = Font(size=10, color="7F7F7F")

    r = 4
    for label, figure, note in headline:
        ws.cell(row=r, column=1, value=figure).font = Font(bold=True, size=20, color="1F3864")
        ws.cell(row=r, column=2, value=label).font = Font(bold=True, size=11)
        ws.cell(row=r, column=3, value=note).font = Font(size=10, color="7F7F7F")
        ws.row_dimensions[r].height = 26
        r += 1

    r += 1
    head = r
    for c, h in enumerate(["Finding", "Figure", "How Solid", "Sheet"], start=1):
        cell = ws.cell(row=head, column=c, value=h)
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = NAVY
    for i, row in enumerate(rows, start=head + 1):
        for c, v in enumerate(row, start=1):
            cell = ws.cell(row=i, column=c, value=v)
            cell.alignment = Alignment(wrap_text=True, vertical="top")
    for letter, width in zip("ABCD", (54, 24, 34, 24)):
        ws.column_dimensions[letter].width = width
    ws.freeze_panes = f"A{head + 1}"


def _guide(ws, sheets: list[Sheet], nav: dict[str, str]) -> None:
    """Contents, then the label legend. One screen each."""
    ws["A1"] = "Contents"
    ws["A1"].font = Font(bold=True, size=14, color="1F3864")
    r = 3
    for c, h in enumerate(["Sheet", "Shows"], start=1):
        cell = ws.cell(row=r, column=c, value=h)
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = NAVY
    for sheet in sheets:
        r += 1
        ws.cell(row=r, column=1, value=sheet.name)
        text = nav.get(sheet.name, sheet.answers)
        ws.cell(row=r, column=2, value=text).alignment = Alignment(vertical="top")

    r += 2
    ws.cell(row=r, column=1, value="Grid labels").font = Font(bold=True, size=14, color="1F3864")
    r += 1
    for c, h in enumerate(["Label", "Used In", "Meaning"], start=1):
        cell = ws.cell(row=r, column=c, value=h)
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = NAVY
    for label, where, meaning in LABELS:
        r += 1
        ws.cell(row=r, column=1, value=label).fill = PatternFill(
            "solid", fgColor=next(v for k, v in LABEL_COLOURS.items() if label.startswith(k))
        )
        ws.cell(row=r, column=2, value=where)
        ws.cell(row=r, column=3, value=meaning).alignment = Alignment(vertical="top")
    r += 2
    ws.cell(row=r, column=1, value="Percentages on sheets 1-3 are rounded; the count they "
            "divide sits beside them, and the appendix carries 5 decimals.").font = Font(
                size=10, italic=True, color="7F7F7F")
    ws.column_dimensions["A"].width = 26
    ws.column_dimensions["B"].width = 78
    ws.column_dimensions["C"].width = 86


def _dictionary(ws, sheets: list[Sheet], attribute_note: str) -> None:
    ws["A1"] = "Data Dictionary"
    ws["A1"].font = Font(bold=True, size=14, color="1F3864")
    ws["A2"] = attribute_note
    for c, h in enumerate(["Sheet", "Column", "Meaning"], start=1):
        cell = ws.cell(row=4, column=c, value=h)
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = NAVY
    r = 4
    for s in sheets:
        for col, meaning in s.columns.items():
            r += 1
            ws.cell(row=r, column=1, value=s.name)
            ws.cell(row=r, column=2, value=col)
            ws.cell(row=r, column=3, value=meaning).alignment = Alignment(wrap_text=True, vertical="top")
    ws.column_dimensions["A"].width = 26
    ws.column_dimensions["B"].width = 38
    ws.column_dimensions["C"].width = 110
    ws.freeze_panes = "A5"
    ws.auto_filter.ref = f"A4:C{r}"


def build(path, sheets: list[Sheet], summary_rows, as_of: str, attribute_note: str,
          headline=(), nav=None) -> None:
    """Write Summary, every data sheet, then the Guide and Data Dictionary, to `path`.

    `headline` is the three figures on the front page, `nav` a short line per sheet for
    the Contents -- both kept out of here so the wording lives with the numbers.
    """
    sheets = [_titled(s) for s in sheets]
    for s in sheets:
        undocumented = [c for c in s.frame.columns if c not in s.columns and not s.grid]
        assert not undocumented, f"{s.name}: no meaning for {undocumented}"
    with pd.ExcelWriter(path, engine="openpyxl") as xl:
        book = xl.book
        _summary(book.create_sheet("Summary"), headline, summary_rows, as_of)
        for s in sheets:
            s.frame.to_excel(xl, sheet_name=s.name, startrow=TABLE_ROW - 1, index=False)
            ws = xl.sheets[s.name]
            _describe(ws, s, as_of)
            _style_table(ws, s)
        # Guide and dictionary are reference, so they sit at the back, after the evidence.
        _guide(book.create_sheet("Guide"), sheets, nav or {})
        _dictionary(book.create_sheet("Data Dictionary"), sheets, attribute_note)
        if "Sheet" in book.sheetnames:
            del book["Sheet"]
        for ws in book.worksheets:
            polish(ws)
