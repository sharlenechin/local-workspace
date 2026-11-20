"""Build italy-question.xlsx — the PM's settlement-rate answer, one tab per servicer.

    uv run python work/italy/settlement/build_workbook.py

Cerved and Intrum are DELIBERATELY on separate tabs and are never summed: the
two feeds mean different things by "account", by "amicable" and by "balance",
and they cover different windows. The Read me tab spells that out.

Every table is preceded by the PM's question it answers, in words.
"""

from __future__ import annotations

from pathlib import Path

import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

import datalake

HERE = Path(__file__).resolve().parent
OUT = HERE / "italy-question.xlsx"

MEASURED = "2026-09-15"

# Intrum only. The feed holds no `cashin` row at all in these two months —
# absent, not zero. Excluded from the cash rate, and said so on the tab.
INTRUM_CASH_GAPS = {pd.Timestamp("2025-10-31"), pd.Timestamp("2026-05-31")}

BAND_ORDER = ["1. 0-3 months", "2. 4-6 months", "3. 7-12 months",
              "4. 13-24 months", "5. over 24 months", "9. never paid"]

INK = "1F3864"
HEAD = PatternFill("solid", fgColor="D9E2F3")
TITLE = PatternFill("solid", fgColor=INK)
WARN = PatternFill("solid", fgColor="FCE4D6")
THIN = Side(style="thin", color="BFBFBF")
BOX = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)


def tidy(label: str) -> str:
    """Strip the sort prefix a band carries so the sheet reads in English."""
    text = label.split(". ", 1)[1]
    return text[0].upper() + text[1:]


def _grid(df: pd.DataFrame, value: str) -> pd.DataFrame:
    """Balance band x last-payment band, with every band present.

    Both tabs are reindexed onto the full band list even where a band cannot
    occur, so the two servicers line up cell for cell and a missing band reads
    as blank rather than as a column that quietly is not there.
    """
    grid = df.pivot_table(index="balance_band", columns="last_payment_band",
                          values=value, aggfunc="sum", fill_value=0)
    grid = grid.reindex(columns=BAND_ORDER)
    # min_count keeps a band that CANNOT occur on this book blank all the way
    # through, including its total — a zero there would read as "nobody", when
    # the truth is "the window is too short for this band to exist".
    grid["TOTAL"] = grid.sum(axis=1, min_count=1)
    grid.loc["TOTAL"] = grid.sum(min_count=1)
    return grid


def crosstab(df: pd.DataFrame, value: str, *, divide_by: str | None = None,
             months: int | None = None) -> pd.DataFrame:
    """A count/amount table, or a rate table if DIVIDE_BY is given.

    A rate is Sum(numerator)/Sum(denominator) over the whole window — never an
    average of monthly rates, which would weight a thin month like a fat one.
    The totals row and column are computed the same way, so they foot.
    """
    grid = _grid(df, value)
    if divide_by is not None:
        grid = grid / _grid(df, divide_by).replace(0, pd.NA)
    elif months:
        grid = grid / months
    grid.index = [tidy(i) if i != "TOTAL" else "Total" for i in grid.index]
    grid.columns = [tidy(c) if c != "TOTAL" else "Total" for c in grid.columns]
    return grid


class Tab:
    """A worksheet written top to bottom, keeping track of where it is."""

    def __init__(self, book, name: str):
        self.ws = book.create_sheet(name)
        self.row = 1

    def title(self, text: str, size: int = 14) -> None:
        cell = self.ws.cell(self.row, 1, text)
        cell.font = Font(bold=True, size=size, color="FFFFFF")
        cell.fill = TITLE
        self.ws.merge_cells(start_row=self.row, start_column=1,
                            end_row=self.row, end_column=9)
        self.ws.row_dimensions[self.row].height = 24
        self.row += 2

    def line(self, text: str, *, bold: bool = False, warn: bool = False) -> None:
        cell = self.ws.cell(self.row, 1, text)
        cell.font = Font(bold=bold, color=INK if bold else "000000")
        cell.alignment = Alignment(wrap_text=False, vertical="top")
        if warn:
            cell.fill = WARN
        self.row += 1

    def question(self, number: str, text: str, note: str = "") -> None:
        cell = self.ws.cell(self.row, 1, f"{number}.  {text}")
        cell.font = Font(bold=True, size=12, color=INK)
        self.row += 1
        if note:
            self.ws.cell(self.row, 1, note).font = Font(italic=True, size=9,
                                                        color="595959")
            self.row += 1

    def table(self, grid: pd.DataFrame, fmt: str, index_header: str) -> None:
        head = self.ws.cell(self.row, 1, index_header)
        head.font, head.fill, head.border = Font(bold=True), HEAD, BOX
        for j, col in enumerate(grid.columns, start=2):
            cell = self.ws.cell(self.row, j, col)
            cell.font, cell.fill, cell.border = Font(bold=True), HEAD, BOX
            cell.alignment = Alignment(horizontal="right", wrap_text=True)
        self.row += 1
        for label, values in grid.iterrows():
            last = str(label) == "Total"
            cell = self.ws.cell(self.row, 1, label)
            cell.font, cell.border = Font(bold=last), BOX
            for j, value in enumerate(values, start=2):
                cell = self.ws.cell(self.row, j,
                                    None if pd.isna(value) else float(value))
                cell.number_format, cell.border = fmt, BOX
                cell.font = Font(bold=last or grid.columns[j - 2] == "Total")
            self.row += 1
        self.row += 1

    def widths(self, first: int = 26, rest: int = 15) -> None:
        self.ws.column_dimensions["A"].width = first
        for j in range(2, 12):
            self.ws.column_dimensions[get_column_letter(j)].width = rest
        self.ws.sheet_view.showGridLines = False


def servicer_tab(book, name: str, df: pd.DataFrame, *, scope: list[str],
                 cash_note: str = "", cash_mask: pd.Series | None = None,
                 cash_gaps: set | None = None) -> None:
    tab = Tab(book, name)
    tab.title(f"{name} — Italy · settlement rates by age")
    for text in scope:
        tab.line(text)
    tab.row += 1

    months = df.snapshot_month.nunique()
    accounts = df.accounts_open.sum() / months
    balance = df.balance_open_eur.sum() / months
    tab.line(f"{accounts:,.0f} open amicable accounts  ·  EUR {balance:,.0f}  "
             f"·  {months} monthly snapshots", bold=True)
    tab.row += 1

    tab.question("Q1", "How many open amicable accounts are there?",
                 "Monthly average across the snapshots. An account open in every "
                 "month is one account, not one per month — so the cells add to "
                 "the book, not to a multiple of it.")
    tab.table(crosstab(df, "accounts_open", months=months), "#,##0",
              "Balance band  \\  Months since last payment")

    tab.question("Q2", "…and how much balance do they hold? (EUR)",
                 "Monthly average. This is the denominator for Q4 and Q5.")
    tab.table(crosstab(df, "balance_open_eur", months=months), "#,##0",
              "Balance band  \\  Months since last payment")

    tab.question("Q3", "How many pay off their debt each month? "
                       "— as % of accounts open at the snapshot",
                 "Closed in the month after the snapshot, over accounts open at "
                 "it. Sum of closures / sum of accounts across the window.")
    tab.table(crosstab(df, "accounts_closed", divide_by="accounts_open"),
              "0.000%", "Balance band  \\  Months since last payment")

    tab.question("Q4", "…and as % of balance open at the snapshot",
                 "The balance those closing accounts were carrying, over the "
                 "balance open at the snapshot.")
    tab.table(crosstab(df, "balance_closed_eur", divide_by="balance_open_eur"),
              "0.000%", "Balance band  \\  Months since last payment")

    cash = df if cash_mask is None else df[cash_mask]
    tab.question("Q5", "What % of their balance do they pay each month?",
                 cash_note or "Cash collected in the month after the snapshot, "
                              "over the balance open at it.")
    tab.table(crosstab(cash, "collected_eur", divide_by="balance_open_eur"),
              "0.000%", "Balance band  \\  Months since last payment")

    tab.question("Q6", "How many closed in total across the window? (counts)",
                 "Not a rate — the actual number of accounts that closed.")
    tab.table(crosstab(df, "accounts_closed"), "#,##0",
              "Balance band  \\  Months since last payment")

    tab.question("Q7", "Month by month",
                 "The same figures per snapshot, so any month can be read on "
                 "its own and the tables above can be re-sliced."
                 + (" ⚠ = the month whose cash is being measured has no payment "
                    "rows in the feed at all, so that zero is a gap, not a zero."
                    if cash_gaps else ""))
    monthly = df.groupby("snapshot_month").agg(
        accounts_open=("accounts_open", "sum"),
        balance_open_eur=("balance_open_eur", "sum"),
        accounts_closed=("accounts_closed", "sum"),
        balance_closed_eur=("balance_closed_eur", "sum"),
        collected_eur=("collected_eur", "sum"))
    monthly["percent_accounts_closed"] = (monthly.accounts_closed
                                          / monthly.accounts_open)
    monthly["percent_balance_collected"] = (monthly.collected_eur
                                            / monthly.balance_open_eur)
    monthly.index = [
        d.date().isoformat()
        + (" ⚠" if cash_gaps and d + pd.offsets.MonthEnd(1) in cash_gaps else "")
        for d in monthly.index]
    monthly.columns = ["Accounts open", "Balance open EUR", "Closed next month",
                       "Balance closed EUR", "Collected next month EUR",
                       "% accounts closed", "% balance collected"]
    head = tab.ws.cell(tab.row, 1, "Snapshot month")
    head.font, head.fill, head.border = Font(bold=True), HEAD, BOX
    for j, col in enumerate(monthly.columns, start=2):
        cell = tab.ws.cell(tab.row, j, col)
        cell.font, cell.fill, cell.border = Font(bold=True), HEAD, BOX
        cell.alignment = Alignment(horizontal="right", wrap_text=True)
    tab.row += 1
    for label, values in monthly.iterrows():
        tab.ws.cell(tab.row, 1, label).border = BOX
        for j, (col, value) in enumerate(values.items(), start=2):
            cell = tab.ws.cell(tab.row, j, float(value))
            cell.number_format = "0.000%" if col.startswith("%") else "#,##0"
            cell.border = BOX
        tab.row += 1
    tab.widths(first=34, rest=16)
    tab.ws.freeze_panes = "B2"


def readme_tab(book, notes: list[tuple[str, list[str]]]) -> None:
    tab = Tab(book, "Read me")
    tab.title("Italy — settlement rates by age")
    tab.line("The question, as asked:", bold=True)
    for text in [
        "  Grouped by balance and time since last payment, how many open amicable",
        "  accounts pay off their debt each month, and what % of their balance do",
        "  they pay? How many close? Rates as % of accounts and % of balance open",
        "  at the time of the snapshot.",
        "",
        '  "Paid off" = closed = we no longer collect from the loan.',
    ]:
        tab.line(text)
    tab.row += 1
    for heading, lines in notes:
        tab.line(heading, bold=True)
        for text in lines:
            tab.line("   " + text)
        tab.row += 1
    tab.widths(first=100, rest=12)


def main() -> None:
    cerved = datalake.q("work/italy/settlement/cerved_settlement_by_age")
    intrum = datalake.q("work/italy/settlement/intrum_settlement_by_age")
    for frame in (cerved, intrum):
        frame.columns = [c.lower() for c in frame.columns]

    book = Workbook()
    book.remove(book.active)   # drop the default sheet; every tab is built below

    readme_tab(book, [
        ("⚠ The two tabs are separate on purpose. Never add them together.", [
            "\"Account\" means a POSITION for Cerved (a debtor's whole set of loans)",
            "and a CASE for Intrum (one loan). \"Amicable\" is Intrum's own phase code",
            "A002 for Intrum, and our derived \"never reached a legal stage\" for Cerved.",
            "Balance is a reported outstanding for Cerved and a reconstructed ledger",
            "for Intrum. The windows differ. A combined Italian rate would be an",
            "average of four different definitions.",
        ]),
        ("⚠ Closed does not mean settled, on either book.", [
            "Neither feed says WHY an account closed, so a write-off and a payment in",
            "full look identical. Always read Q3 next to Q5: a cohort that closes with",
            "little cash behind it is being written off, not settling.",
        ]),
        ("⚠ Cerved's \"amicable\" is our definition and is unconfirmed.", [
            "Cerved has no amicable flag. We use \"open and never having reached a legal",
            "stage\". Only 915 records carry an explicit \"Amicable Agreement\" label, and",
            "defining it that narrowly would give a much smaller, different answer.",
            "Confirm with the servicing team before this is quoted externally.",
        ]),
        ("⚠ Intrum is missing two whole months of payments.", [
            "There is no payment row at all dated October 2025 or May 2026 — absent,",
            "not zero, with 280-410 payments in every neighbouring month. Those two",
            "months are excluded from Q5 on the Intrum tab and are visible as zeros in",
            "Q7. Reported to the data team; not corrected here.",
        ]),
        ("⚠ Intrum's amicable cohort halves across the window, and closures are not why.", [
            "29,094 accounts in March 2025 to 19,767 in June 2026. Cases leave by",
            "turning legal — 17,003 enter the legal phase, in batch stamps of up to",
            "3,917 in one month. The denominator moves for loading reasons, not",
            "behaviour, so read each month on its own.",
        ]),
        ("Where the numbers come from", [
            f"Live queries against the RAW feeds, read-only, measured {MEASURED}:",
            "   work/italy/settlement/cerved_settlement_by_age.sql",
            "   work/italy/settlement/intrum_settlement_by_age.sql",
            "Each file's header carries its guards. Full working: FINDINGS.md.",
            "Rebuild this workbook: uv run python work/italy/settlement/build_workbook.py",
        ]),
    ])

    servicer_tab(book, "Cerved", cerved, scope=[
        "Source: RAW.HYPERION_CERVED — LOANS, COLLECTIONS, PPT, PDR.",
        "The account is a POSITION: a debtor's whole set of loans.",
        "Amicable = open and never having reached a legal stage. ⚠ OUR definition, "
        "not Cerved's — see Read me.",
        "Balance = OUSTANDING_GBV as the servicer reports it on the monthly tape.",
        f"Snapshots Sep 2025 – Jul 2026, each with the following month observed "
        f"for closures. Measured {MEASURED}.",
    ])

    cash_mask = ~intrum.snapshot_month.add(pd.offsets.MonthEnd(1)).isin(
        INTRUM_CASH_GAPS)
    servicer_tab(book, "Intrum", intrum, scope=[
        "Source: RAW.HYPERION_INTRUM_CAT instance 4034 — CASES, GROUP_CASE_PHASE, "
        "TRANSACTIONS.",
        "The account is a CASE, which on this book is one LOAN.",
        "Amicable = Intrum's own phase code A002 and not yet L002. Time-varying: "
        "a case leaves the cohort the month it turns legal.",
        "⚠ Balance is RECONSTRUCTED from the transaction ledger. Intrum delivers no "
        "monthly tape and REMAINING_CAPITAL is 100% NULL on this instance.",
        "⚠ Expense lines (SPESE and friends, 13,020 of 48,547 records) are excluded — "
        "leaving them in roughly halves every per-account rate.",
        "⚠ \"Over 24 months\" cannot occur here: the first payment in the feed is "
        "August 2024, so no account can be 24 months past one inside the window. "
        "The column is blank, not zero.",
        "⚠ 97.9% of the accounts (19,518 of 19,941) have never paid anything — only "
        "1,927 of 48,547 cases have ever made a payment. Every whole-book average is "
        "really about those accounts.",
        f"Snapshots Jul 2024 – Jun 2026, each with the following month observed "
        f"for closures. Measured {MEASURED}.",
    ], cash_mask=cash_mask, cash_gaps=INTRUM_CASH_GAPS,
        cash_note="Cash collected in the month after the snapshot, over the balance "
                  "open at it. ⚠ October 2025 and May 2026 are EXCLUDED: the feed "
                  "holds no payment rows for those months at all.")

    book.save(OUT)
    print(f"wrote {OUT}")
    print(f"  Cerved {len(cerved):,} rows, {cerved.snapshot_month.nunique()} months")
    print(f"  Intrum {len(intrum):,} rows, {intrum.snapshot_month.nunique()} months")


if __name__ == "__main__":
    main()
