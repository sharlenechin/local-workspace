"""Build the Servicer Data Quality dashboard in Sigma, in one repeatable step.

    uv run python work/data-quality/sigma_build/build_workbook.py --dry-run     # write contents.json, verify, send nothing
    uv run python work/data-quality/sigma_build/build_workbook.py --create      # a new workbook
    uv run python work/data-quality/sigma_build/build_workbook.py --update <id> # replace an existing build's contents

Reads, never edits: sigma_queries/portfolio_months_element.sql, sigma_queries/combined_refs_element.sql,
design/sigma_theme.json. The layout follows the reviewed design canvas (design/project/Servicer.dc.html).
Same pattern as work/servicing/sigma_build/build_workbook.py: the SQL is the data, every check is a Sigma
formula over it, helper tables live on a hidden Model page.

How a figure is computed, once:
  - The To month is the newest month left in view: last month, even while it is still arriving (From - To can move it back).
  - Reporting Months picks how many months, counting back from the To month, the table covers.
  - Flows (collections) add up over those months; stocks (balance, cases, status, forecast) are read at the To month.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
DQ = HERE.parent
PM_SQL = DQ / "sigma_queries" / "portfolio_months_element.sql"
REF_SQL = DQ / "sigma_queries" / "combined_refs_element.sql"
THEME = DQ / "design" / "sigma_theme.json"
USER_EDITS = HERE / "user_edits.json"     # the user's hand edits in Sigma, applied last
USER_LAYOUT = HERE / "user_layout.xml"   # the page layout as the user arranged it

FOLDER = "b406c34e-2ce1-42a1-a8e7-4502ad86db87"       # the Servicing dashboard's folder
CONNECTION = "b3be9b8b-fb38-4b05-a8db-afdb5c47cdbf"   # Snowflake - PROD

# The two Custom SQL elements are the ones materialised nightly, so nothing may filter them: Sigma will not materialise
# an element a control filters. Each has a plain pass-through child (pm_rows, ref_rows) that the controls filter and
# everything else reads.
PM_SQL_NAME, REF_SQL_NAME = "Portfolio Months", "Combined Refs"   # materialise these two
PM, REF = "Portfolio Rows", "Combined Ref Rows"        # their children: formulas address [PM/column]
SRC = {"kind": "table", "elementId": "pm_rows"}
REF_SRC = {"kind": "table", "elementId": "ref_rows"}
INT = {"kind": "number", "formatString": ",.0f"}
AMT = {"kind": "number", "formatString": ",.2f"}       # in the row's own currency (Currency column)
PCT = {"kind": "number", "formatString": "+,.1%"}
SHARE = {"kind": "number", "formatString": ",.1%"}   # 0% to 100%, one decimal
CARD = {"backgroundColor": "#FFFFFF", "borderColor": "#DCE3DF", "borderRadius": "round", "borderWidth": 1}

SERVICERS = ["Intrum", "Gescobro", "Cerved", "Souq", "Massey", "Fire"]   # by portfolios, as the design's tabs
PRESETS = ["Latest Month", "Last 3 Months", "Last 6 Months", "Last 12 Months", "All Time"]
PRESET_MONTHS = {"Latest Month": 1, "Last 3 Months": 3, "Last 6 Months": 6, "Last 12 Months": 12}
PRESET_LABELS = [None, "L3M", "L6M", "L12M", None]   # what the toggle shows, as the Servicing dashboard; formulas switch on the values
SHOW_BY = ["By Portfolio", "By Combined Ref"]        # the Show By toggle; each value selects one tab of `tabs`
FILTERS = ["Month-Filter", "Country", "Deal", "Portfolio", "Purchase-Price"]   # what Clear Filters clears

# Whole-cell fills (Sigma conditional formatting), the design's palette.
GREEN, AMBER, RED, GREY = ("#E8F3E9", "#1E6B24"), ("#FDF1E7", "#9A3412"), ("#FBE9E9", "#A61B1B"), ("#F0F2EA", "#5C6B66")
GOOD = ["Received", "Reconciled", "Healthy"]
WARN = ["Partly Received", "Under Another Ref", "Payments in Under 80% of Months", "Not Yet Received"]
PENDING = "Not Yet Received"                           # a report not due yet (the 15th of the month after): amber, not an issue
# A cell scale needs more colour than a text tint to read: the design's red, amber and green, one step stronger.
SCALE_RED, SCALE_AMBER, SCALE_GREEN = "#F4C7C7", "#FBE0C3", "#C6E5C9"
OURS = ["Not Loaded by Brocc", "Not Compared"]          # not the servicer's fault: grey, never red


def cols_of(sql: str) -> list[str]:
    """The output columns: the aliases and bare columns of the final SELECT list."""
    select_list = sql.rsplit("\nSELECT\n", 1)[1].split("\nFROM ", 1)[0]
    select_list = re.sub(r"--[^\n]*", "", select_list)
    names = []
    for line in select_list.split(",\n"):
        line = line.strip()
        m = re.search(r"\bAS\s+([a-z0-9_]+)\s*$", line) or re.search(r"^[a-z]+\.([a-z0-9_]+)$", line)
        if m:
            names.append(m.group(1))
    return names


def col(cid, formula, name=None, fmt=None):
    d = {"id": cid, "formula": formula}
    if name is not None:
        d["name"] = name
    if fmt:
        d["format"] = fmt
    return d


def text(eid, body):
    return {"id": eid, "kind": "text", "body": body}


def box(eid, colour="#FFFFFF", radius="round"):
    return {"id": eid, "kind": "container", "spacing": "medium",
            "style": {"backgroundColor": colour, "borderColor": "#DCE3DF", "borderWidth": 0 if colour != "#FFFFFF" else 1, "borderRadius": radius}}


# --- the shared formulas, for a source element named `el` -----------------------------------------
def f(el: str) -> dict:
    c = lambda n: f"[{el}/{n}]"
    # The To month is the newest month in view: last month by default, since both queries stop at today. It is
    # shown even while it is still arriving (the user, 2026-10-13): a report not in yet is what this page is for.
    anchor = f'GrandTotal(Max({c("reporting_month")}))'
    mo = f'DateDiff("month", DateTrunc("month", {c("reporting_month")}), DateTrunc("month", {anchor}))'
    n = "Switch([Quick-Filter-Months], " + ", ".join(f'"{k}", {v}' for k, v in PRESET_MONTHS.items()) + ", 100000)"
    return {"c": c, "IN": f"({mo} >= 0 and {mo} < {n})", "AT": f"({mo} = 0)"}


def check_columns(el: str, *, portfolio: bool) -> list[dict]:
    """Every column of one table, built over the rows of one group (a portfolio, or a combined ref)."""
    F = f(el); c, IN, AT = F["c"], F["IN"], F["AT"]
    at = lambda x: f"Max(If({AT}, {x}))"
    month = lambda x: f'DateFormat({x}, "%b %Y")'
    dates = lambda first, last: (f'If(IsNull(Min({c(first)})), "Never", {month(f"Min({c(first)})")} & " – " & '
                                 f'If(IsNull({at(c(last))}), "Stopped", {month(at(c(last)))}))')
    loaded = f'Max(If({c("case_payments_loaded_flag")}, 1, 0)) = 1'
    # A report is due by the 15th of the month after (portfolio_feed_due_flag); until then a missing one is
    # Not Yet Received, amber, and is not counted as an issue or on a tile.
    due_at = f'Coalesce(Max(If({AT}, If({c("portfolio_feed_due_flag")}, 1, 0))), 1) = 1'
    rc, lc = f"Sum(If({IN}, {c('portfolio_feed_collections')}))", f"Sum(If({IN}, {c('case_feed_collections')}))"
    rb, lb = at(c("portfolio_feed_balance")), at(c("case_feed_balance"))
    within = lambda a, b: f"(Abs(({a}) - ({b})) <= 0.1 * Abs({a}) and ({a}) <> 0)"
    # Collections, in step with the Servicing dashboard (the user, 2026-10-14): a portfolio is Reconciled exactly
    # when the Servicing dashboard says so. Its flag (collections_reconciled_flag: within 10%, payments in 80% of the
    # months reported since acquisition, never Italy) is per month, so over several months Reconciled means every
    # month reported was. The other values say why not. The combined-ref element has no such flag, so a ref is
    # checked on the 10% alone, over the months shown.
    coverage = f'Max({c("case_payment_months_since_acquisition")}) >= 0.8 * Max({c("reported_months_since_acquisition")})'
    if portfolio:
        every = f'Min(If({IN} and {c("portfolio_feed_received_flag")}, If({c("collections_reconciled_flag")}, 1, 0))) = 1'
        why = f'If(IsNull({lc}), "No Payments", If({coverage}, "Not Reconciled", "Payments in Under 80% of Months"))'
        rec = f'If({every}, "Reconciled", {why})'
    else:
        rec = f'If(IsNull({lc}), "No Payments", If({within(rc, lc)}, "Reconciled", "Not Reconciled"))'
    coll = (f'If(Not ({loaded}), "Not Loaded by Brocc", If(IsNull({rc}), If({due_at}, "No Portfolio Feed", "{PENDING}"), '
            f'{rec}))')
    bal = (f'If(IsNull({rb}) and Not ({due_at}), "{PENDING}", If(IsNull({rb}) or IsNull({lb}), "Not Compared", '
           f'If({within(rb, lb)}, "Reconciled", "Not Reconciled")))')
    absent = f"{IN} and Not {c('portfolio_feed_received_flag')}"
    miss = f"Sum(If({absent} and {c('portfolio_feed_due_flag')}, 1, 0))"
    pend = f"Sum(If({absent} and Not {c('portfolio_feed_due_flag')}, 1, 0))"
    pf = (f'If({miss} = 0, If({pend} > 0, "{PENDING}", "Received"), '
          f'If(Sum(If({IN}, 1, 0)) = 1, "Not Received", Text({miss}) & " Months Missing"))')
    ov_n, ov_d = at(c("months_overlap_to_date")), at(c("months_reported_to_date"))
    fc = f'If(Max(If({AT} and {c("forecast_received_flag")}, 1, 0)) = 1, "Received", "Not Received")'
    cf = at(c("case_feed_status"))
    issues = (f'If({miss} > 0, 1, 0) + If({cf} = "Received", 0, 1) + If({ov_n} < {ov_d}, 1, 0) '
              f'+ If(In({coll}, "No Payments", "Not Reconciled", "Payments in Under 80% of Months"), 1, 0) '
              f'+ If({bal} = "Not Reconciled", 1, 0) + If({fc} = "Received", 0, 1)')
    keys = [col("k_port", c("portfolio_name"), "Portfolio Name"), col("k_deal", c("deal"), "Deal"),
            col("k_srv", c("servicer"), "Servicer"), col("k_cty", c("country_name"), "Country"),
            col("k_cur", c("currency"), "Currency")]
    if not portfolio:
        keys.insert(1, col("k_ref", c("combined_ref"), "Combined Ref"))
    # Column order (the user, 2026-10-14): Status and Issues, then the coloured checks, then the figures behind them.
    calcs = [
        col("st", f'If(({issues}) > 0, "Needs Action", "Healthy")', "Status"),
        col("issues", issues, "Issues", INT),
        col("pf", pf, "Portfolio Feed"),
        col("cf", cf, "Case Feed"),
        # A share (the user, 2026-10-13): months with both feeds, of the months the portfolio feed came.
        col("ov", f"If(IsNull({ov_d}) or {ov_d} = 0, Null, ({ov_n}) / ({ov_d}))", "Months Overlap %", SHARE),
        col("cs", coll, "Collections"),
        col("bs", bal, "Balance"),
        col("fc", fc, "Forecast"),
        col("price", f"Max({c('purchase_price')})", "Purchase Price", AMT),
        col("ovm", f'Text({ov_n}) & " / " & Text({ov_d})', "Months Overlap"),
        col("pfd", dates("portfolio_feed_first_month", "portfolio_feed_last_month"), "Portfolio Feed Dates"),
        col("cfd", dates("case_feed_first_month", "case_feed_last_month"), "Case Feed Dates"),
        col("rc", rc, "Collections Portfolio Feed", AMT),
        col("lc", lc, "Collections Case Feed (All Cases)", AMT),   # every payment, open and closed cases
        col("cd", f"If(Not ({loaded}) or ({rc}) = 0, Null, ({lc}) / ({rc}) - 1)", "Collections Difference %", PCT),
        col("gap", f"If(Not ({loaded}), Null, ({rc}) - Coalesce({lc}, 0))", "Not in Case Feed", AMT),
        col("rb", rb, "Balance Portfolio Feed", AMT),
        # The three comparisons (the user, 2026-10-14): collections against every payment; balance and cases on OPEN
        # cases, the report holding open cases only, with the all-cases figure beside each so the closed cases the
        # case list still carries are in plain view. The report's case count is not in PROD, so Cases has no check.
        col("lb", lb, "Balance Case Feed (Open Cases)", AMT),
        col("bd", f"If(({rb}) = 0, Null, ({lb}) / ({rb}) - 1)", "Balance Difference %", PCT),
        col("lba", f"({lb}) + Coalesce({at(c('closed_cases_balance'))}, 0)", "Balance Case Feed (All Cases)", AMT),
        col("cso", at(c("case_feed_open_cases")), "Cases (Open)", INT),
        col("csa", at(c("case_feed_cases")), "Cases (All)", INT),
        # A group with no row in the months shown (a ref that ended, a portfolio bought later) is left out.
        col("inview", f'If(Sum(If({IN}, 1, 0)) > 0, "Yes", "No")', "In View"),
    ]
    if portfolio:
        # How many combined refs the portfolio feed carried at the To month.
        calcs.insert(calcs.index(next(x for x in calcs if x["id"] == "ovm")), col("refs", at(c("refs_reported")), "Combined Ref Count", INT))
        # For the Months Overlap tile: both feeds in every month the portfolio feed came.
        calcs.append(col("ovfull", f'If({ov_n} = {ov_d}, "Full", "Gaps")', "Months Overlap Full"))
    return keys + calcs


STATUS_COLS = ["pf", "cf", "cs", "bs", "fc", "st"]
IN_VIEW = lambda column_id: {"id": f"in_view_{column_id}", "columnId": column_id, "kind": "list", "mode": "exclude", "values": ["No"]}


def fills(ids: dict) -> list[dict]:
    """The colours (the user, 2026-10-14): a check written in words colours its TEXT (grey ours, green, amber, red,
    first match wins); a number we colour fills its CELL on a scale across the column (Months Overlap %)."""
    rules, i = [], 0
    targets = [ids[k] for k in STATUS_COLS if k in ids]
    text = lambda colour: {"color": colour, "bold": True}
    for values, (_, fg) in ((OURS, GREY), (GOOD, GREEN), (WARN, AMBER)):
        for v in values:
            rules.append({"id": f"cf{i}", "type": "single", "columnIds": targets, "condition": "=", "value": v, "style": text(fg)}); i += 1
    for v in ("Not Received", "Stopped", "Not Reconciled", "No Payments", "No Portfolio Feed", "Needs Action"):
        rules.append({"id": f"cf{i}", "type": "single", "columnIds": targets, "condition": "=", "value": v, "style": text(RED[1])}); i += 1
    rules.append({"id": f"cf{i}", "type": "single", "columnIds": targets, "condition": "Contains", "value": "Missing", "style": text(RED[1])})
    if "ov" in ids:   # Months Overlap %: red at 0%, amber at 50%, green at 100% (the JSON shape read back from a probe, 2026-10-14)
        rules.append({"id": "ov_scale", "type": "backgroundScale", "columnIds": [ids["ov"]],
                      "scheme": [SCALE_RED, SCALE_AMBER, SCALE_GREEN], "domain": {"min": 0, "mid": 0.5, "max": 1}})
    # Difference %: green at 0, red at -50% and +50% and beyond (the user, 2026-10-14). Off either way is bad, so
    # the scale diverges from 0 with red at both ends; past 50% the colour holds.
    diff = [ids[k] for k in ("cd", "bd") if k in ids]
    if diff:
        rules.append({"id": "diff_scale", "type": "backgroundScale", "columnIds": diff,
                      "scheme": [SCALE_RED, SCALE_GREEN, SCALE_RED], "domain": {"min": -0.5, "mid": 0, "max": 0.5}})
    return rules


def flat_table(eid: str, name: str, helper: str, helper_name: str, columns: list[dict], description: str) -> dict:
    """The visible table: one flat row per group of the hidden helper (the Servicing pattern)."""
    shown = [cc for cc in columns if cc["id"] not in ("k_srv", "ovfull")]
    out = [col(f"v_{cc['id']}", f"[{helper_name}/{cc['name']}]", cc["name"], cc.get("format")) for cc in shown]
    # Show toggle: All, Needs Action or Healthy, read from the row's own Status.
    out.append(col("v_show", 'If([Show] = "All" or [Show] = [Status], "Yes", "No")', "Shown"))
    for o in out:
        if o["id"] in ("v_inview", "v_show"):
            o["hidden"] = True
    ids = {cc["id"]: f"v_{cc['id']}" for cc in shown}
    return {"id": eid, "kind": "table", "name": name, "style": CARD, "description": description,
            "source": {"kind": "table", "elementId": helper, "groupingId": "g"}, "columns": out,
            "conditionalFormats": fills(ids),
            "filters": [IN_VIEW("v_inview"), IN_VIEW("v_show")],
            "sort": [{"columnId": "v_price", "direction": "descending", "nulls": "last"}]}


def helper(eid: str, name: str, source: dict, columns: list[dict]) -> dict:
    keys = [cc["id"] for cc in columns if cc["id"].startswith("k_")]
    return {"id": eid, "kind": "table", "name": name, "source": source, "columns": columns,
            "groupings": [{"id": "g", "groupBy": keys, "calculations": [cc["id"] for cc in columns if cc["id"] not in keys]}]}


def tile(eid: str, title: str, table: str, column: str, passing: list[str], counted: list[str] | None = None, note: str = "") -> dict:
    """'249 / 249': groups passing a check, of the groups it applies to (all but Not Yet Received unless `counted`).
    'Not Yet Due' when nothing it applies to is due yet."""
    v = f"[{table}/{column}]"
    ok = f"Sum(If(In({v}, {', '.join(json.dumps(p) for p in passing)}), 1, 0))"
    of = (f"Sum(If(In({v}, {', '.join(json.dumps(p) for p in counted)}), 1, 0))" if counted
          else f'Sum(If({v} = "{PENDING}", 0, 1))')
    pend = f'Sum(If({v} = "{PENDING}", 1, 0))'
    return {"id": eid, "kind": "kpi-chart", "name": {"text": title, "fontSize": 12, "fontWeight": "bold", "color": "#1D5B4D"},
            "source": {"kind": "table", "elementId": "t_tiles"},
            "style": {"backgroundColor": "#FFFFFF", "borderWidth": 0, "borderRadius": "round"},
            "description": {"text": note, "visibility": "shown", "color": "#5C6B66"},
            # "169 / 254  ·  67%" (the user, 2026-10-14)
            "columns": [col("v", f'If({of} = 0 and {pend} > 0, "Not Yet Due", Text({ok}) & " / " & Text({of}) & "  ·  " '
                                 f'& Text(Round(100 * ({ok}) / ({of}), 0)) & "%")', " ")],
            "value": {"columnId": "v", "fontSize": 22, "color": "#012E26"}}


NOTES = """### **Not the Servicer's Fault**

Read these before telling a servicer a figure is wrong. Each is on Brocc's side, and the table shows it in grey, never red.

- **Cerved, Gescobro and Intrum Italy collections: Not Loaded by Brocc.** Cerved and Gescobro send case payments, but brocc-data does not load them into PROD yet. For Intrum Italy it keeps only one payment per case (the file has no transaction ID), so Italy is never reconciled, as on the Servicing dashboard. Their Collections cannot be compared.
- **Closed cases are left out of the case feed.** Brocc's case table keeps a case on the list after the servicer closes it, with its last balance (Intrum, Aug 2026: 9.0m of 19.5m listed cases, 20.2bn). Balance and Cases compare open cases; the All Cases columns show what the closed ones add. Collections count every payment, closed cases included (0.4–0.9% of the money a month).
- **Under Another Ref (Massey).** Massey's case feed uses its own refs, not the report's: the cases are there, under different IDs.
- **Not Yet Received.** A report is due by the 15th of the following month (in the past year every Intrum report arrived by the 14th). Until then a missing report is amber and is not counted as an issue.
- **Servicer from the business rule.** A portfolio with no case feed has no servicer in PROD, so it is named by the manager's rule.

### **The Three Comparisons**

The portfolio feed (the servicer's monthly report) is the figure trusted; the case feed (the case list and its payments) is checked against it, and they match within ±10%.

- **Collections: report against every payment.** Money paid in the month counts on both sides, whether the case is open or closed. The same check, and the same answer, as the Servicing dashboard: within 10%, payments in at least 80% of months since acquisition, month by month; over several months Reconciled only if every month was.
- **Balance: report against open cases.** The report holds open cases only; the case list keeps closed cases with their last balance. So Balance Difference % uses the open cases, and Balance Case Feed (All Cases) shows what the closed ones would add (Intrum, Aug 2026: 86% of refs match on open cases, 12% on all).
- **Cases: open against all.** Shows how many closed cases the list still carries. Not yet checked against the report: its case count is not in PROD.

Collections add up over the months shown; balance, cases, status and forecast are at the last month. Amounts are in the Currency column's currency. Months Overlap: months with both feeds, of the months the portfolio feed came, from Jun 2014. Data: Snowflake PROD, NPL_COMMON, portfolios in DIM_PORTFOLIO, from Jun 2014."""


def build() -> dict:
    pm_sql, ref_sql = PM_SQL.read_text(), REF_SQL.read_text()
    theme = json.loads(THEME.read_text()); theme.pop("_comment", None)
    els: list[dict] = [
        {"id": "src", "kind": "table", "name": PM_SQL_NAME, "source": {"kind": "sql", "connectionId": CONNECTION, "statement": pm_sql},
         "columns": [col(n.upper(), f"[Custom SQL/{n.upper()}]", n) for n in cols_of(pm_sql)]},
        {"id": "ref_src", "kind": "table", "name": REF_SQL_NAME, "source": {"kind": "sql", "connectionId": CONNECTION, "statement": ref_sql},
         "columns": [col(n.upper(), f"[Custom SQL/{n.upper()}]", n) for n in cols_of(ref_sql)]},
        {"id": "pm_rows", "kind": "table", "name": PM, "source": {"kind": "table", "elementId": "src"},
         "columns": [col(n.upper(), f"[{PM_SQL_NAME}/{n}]", n) for n in cols_of(pm_sql)]},
        {"id": "ref_rows", "kind": "table", "name": REF, "source": {"kind": "table", "elementId": "ref_src"},
         "columns": [col(n.upper(), f"[{REF_SQL_NAME}/{n}]", n) for n in cols_of(ref_sql)]},
    ]

    # ---- header, as the Servicing dashboard's: title, then one row of filters and Clear Filters ------
    both = lambda column: [{"columnId": column, "source": SRC}, {"columnId": column, "source": REF_SRC}]
    pick_list = lambda eid, cid, name, column: {
        "id": eid, "kind": "control", "controlType": "list", "controlId": cid, "name": name, "mode": "include",
        "selectionMode": "multiple", "filters": both(column), "source": {"kind": "source", "columnId": column, "source": SRC}, "values": []}
    els += [
        text("h_title", "## **Servicer Data Quality**"),
        text("h_sub", '<span style="color: #5C6B66">Snowflake PROD · NPL_COMMON · from Jun 2014 · portfolio feed nightly, case feed when the data team loads it</span>'),
        # Toggles where the design has them (the user, 2026-10-13: "toggles for most"). Servicer is the one
        # filter with a default: a servicer sees one servicer at a time, as the design's tabs.
        {"id": "f_servicer", "kind": "control", "controlType": "segmented", "controlId": "Servicer", "name": "Servicer",
         "filters": both("SERVICER"), "source": {"kind": "manual", "valueType": "text", "values": SERVICERS}, "value": "Intrum",
         "showClearLabel": False},
        {"id": "f_months", "kind": "control", "controlType": "segmented", "controlId": "Quick-Filter-Months", "name": "Quick Filter Months",
         "source": {"kind": "manual", "valueType": "text", "values": PRESETS, "labels": PRESET_LABELS}, "value": "Latest Month",
         "showClearLabel": False},
        {"id": "f_range", "kind": "control", "controlType": "date-range", "controlId": "Month-Filter", "name": "Month Filter",
         "mode": "between", "filters": both("REPORTING_MONTH"), "includeNulls": "when-no-value-is-selected"},
        pick_list("f_country", "Country", "Country", "COUNTRY_NAME"),
        pick_list("f_deal", "Deal", "Deal", "DEAL"),
        pick_list("f_portfolio", "Portfolio", "Portfolio", "PORTFOLIO_NAME"),
        # Amounts are in each portfolio's own currency, so a range compares raw amounts across currencies.
        {"id": "f_price", "kind": "control", "controlType": "number-range", "controlId": "Purchase-Price", "name": "Purchase Price",
         "filters": both("PURCHASE_PRICE")},
        # Clears the five filters, not Servicer, Quick Filter Months or Show By: every formula switches on those.
        {"id": "h_clear", "kind": "button", "text": "Clear Filters", "appearance": "outline", "size": "small", "align": "right",
         "fontColor": "#1D5B4D", "actions": [{"id": "clear_filters", "trigger": "on-click", "effects": [
             {"effect": "clear-control", "scope": {"type": "control", "controlId": cid}} for cid in FILTERS]}]},
    ]

    # ---- the tiles, then the two tables ------------------------------------------------------------
    pm_cols, ref_cols = check_columns(PM, portfolio=True), check_columns(REF, portfolio=False)
    els += [
        helper("pm_by_port", "pm by portfolio", SRC, pm_cols),
        helper("ref_by_ref", "ref by ref", REF_SRC, ref_cols),
        # The tiles read their own copy, so the table's Show filter never changes them.
        {"id": "t_tiles", "kind": "table", "name": "tiles", "source": {"kind": "table", "elementId": "pm_by_port", "groupingId": "g"},
         "columns": [col(f"t_{cc['id']}", f"[pm by portfolio/{cc['name']}]", cc["name"]) for cc in pm_cols
                     if cc["id"] in ("k_port", "pf", "cf", "ovfull", "cs", "bs", "fc", "inview")],
         "filters": [IN_VIEW("t_inview")]},
        box("band", "#012E26"),
        text("band_sub", '<span style="color: #D8E494">**{{"Checks for " & [Servicer] & ", " & DateFormat(Max([Portfolio Months/reporting_month]), "%b %Y") & " · reports due by " & DateFormat(DateAdd("day", 15, Max([Portfolio Months/reporting_month])), "%d %b %Y")}}**</span>'),
        tile("k_pf", "Portfolio Feed Received", "tiles", "Portfolio Feed", ["Received"], note="Portfolios whose monthly report came in"),
        tile("k_cf", "Case Feed Received", "tiles", "Case Feed", ["Received"], note="Portfolios whose case list came in"),
        tile("k_ov", "Months Overlap", "tiles", "Months Overlap Full", ["Full"], note="Both feeds every month since Jun 2014"),
        tile("k_cs", "Collections Reconciled", "tiles", "Collections", ["Reconciled"],
             ["Reconciled", "Not Reconciled", "No Payments", "Payments in Under 80% of Months"],
             note="Case payments match the report, as on Servicing"),
        tile("k_bs", "Balance Reconciled", "tiles", "Balance", ["Reconciled"], ["Reconciled", "Not Reconciled"], note="Open-case balance within 10% of the report"),
        tile("k_fc", "Forecast Received", "tiles", "Forecast", ["Received"], note="Portfolios with a servicer forecast"),
        box("port_bar", "#DAE49D"),
        text("port_title", "### **Portfolios and Their Feeds**"),
        # Show filters both tables through their own Shown column (never the tiles).
        {"id": "f_show", "kind": "control", "controlType": "segmented", "controlId": "Show", "name": "Show",
         "source": {"kind": "manual", "valueType": "text", "values": ["All", "Needs Action", "Healthy"]}, "value": "All",
         "showClearLabel": False},
        # Show By (the user, 2026-10-14: a toggle, not tabs): a table cannot change its grain, so the two tables
        # sit in a tabbed container with its tab bar hidden, and each value of the toggle selects one tab.
        {"id": "f_showby", "kind": "control", "controlType": "segmented", "controlId": "Show-By", "name": "Show By",
         "source": {"kind": "manual", "valueType": "text", "values": SHOW_BY}, "value": SHOW_BY[0], "showClearLabel": False,
         "actions": [{"id": f"show_by_{i}", "name": f"Show {v}",
                      "trigger": {"on": "on-change", "condition": {"type": "constant", "cond": "=", "value": {"type": "text", "value": v}}},
                      "effects": [{"effect": "select-tab", "tabbedContainerElementId": "tabs", "selectedTab": {"type": "tab", "index": i}}]}
                     for i, v in enumerate(SHOW_BY)]},
        {"id": "tabs", "kind": "tabbed-container", "tabs": [{"name": v} for v in SHOW_BY],
         "tabBar": {"alignment": "left", "size": "medium", "style": "open", "visibility": "hidden"}},
        flat_table("t_port", "By Portfolio", "pm_by_port", "pm by portfolio", pm_cols,
                   "Biggest purchase price first · click a header to sort"),
        flat_table("t_ref", "By Combined Ref", "ref_by_ref", "ref by ref", ref_cols,
                   "Combined Ref = the ID Intrum knows it by; other servicers call it the Portfolio ID"),
        box("notes_box"),
        text("notes", NOTES),
    ]
    layout = """<?xml version="1.0" encoding="utf-8"?>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg_main">
  <Container elementId="band" type="grid" gridColumn="1 / 25" gridRow="1 / 8" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="band_sub" gridColumn="1 / 25" gridRow="1 / 2"/>
    <Element elementId="k_pf" gridColumn="1 / 5" gridRow="2 / 7"/>
    <Element elementId="k_cf" gridColumn="5 / 9" gridRow="2 / 7"/>
    <Element elementId="k_ov" gridColumn="9 / 13" gridRow="2 / 7"/>
    <Element elementId="k_cs" gridColumn="13 / 17" gridRow="2 / 7"/>
    <Element elementId="k_bs" gridColumn="17 / 21" gridRow="2 / 7"/>
    <Element elementId="k_fc" gridColumn="21 / 25" gridRow="2 / 7"/>
  </Container>
  <Container elementId="port_bar" type="grid" gridColumn="1 / 25" gridRow="8 / 10" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="port_title" gridColumn="1 / 9" gridRow="1 / 3"/>
    <Element elementId="f_showby" gridColumn="9 / 16" gridRow="1 / 3"/>
    <Element elementId="f_show" gridColumn="16 / 25" gridRow="1 / 3"/>
  </Container>
  <TabbedContainer elementId="tabs" type="tabbed-container" gridColumn="1 / 25" gridRow="10 / 44">
    <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="t_port" gridColumn="1 / 25" gridRow="1 / 34"/>
    </Tab>
    <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="t_ref" gridColumn="1 / 25" gridRow="1 / 34"/>
    </Tab>
  </TabbedContainer>
  <Container elementId="notes_box" type="grid" gridColumn="1 / 25" gridRow="44 / 58" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="notes" gridColumn="1 / 25" gridRow="1 / 14"/>
  </Container>
</Page>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg_model">
  <Element elementId="src" gridColumn="1 / 25" gridRow="1 / 12"/>
  <Element elementId="ref_src" gridColumn="1 / 25" gridRow="12 / 24"/>
  <Element elementId="pm_rows" gridColumn="1 / 25" gridRow="60 / 72"/>
  <Element elementId="ref_rows" gridColumn="1 / 25" gridRow="72 / 84"/>
  <Element elementId="pm_by_port" gridColumn="1 / 25" gridRow="24 / 36"/>
  <Element elementId="ref_by_ref" gridColumn="1 / 25" gridRow="36 / 48"/>
  <Element elementId="t_tiles" gridColumn="1 / 25" gridRow="48 / 60"/>
</Page>
<Panel type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="hdr">
  <Element elementId="h_title" gridColumn="1 / 13" gridRow="1 / 3"/>
  <Element elementId="h_sub" gridColumn="13 / 25" gridRow="1 / 3"/>
  <Element elementId="f_servicer" gridColumn="1 / 14" gridRow="3 / 6"/>
  <Element elementId="f_months" gridColumn="14 / 25" gridRow="3 / 6"/>
  <Element elementId="f_range" gridColumn="1 / 5" gridRow="6 / 9"/>
  <Element elementId="f_country" gridColumn="5 / 8" gridRow="6 / 9"/>
  <Element elementId="f_deal" gridColumn="8 / 11" gridRow="6 / 9"/>
  <Element elementId="f_portfolio" gridColumn="11 / 15" gridRow="6 / 9"/>
  <Element elementId="f_price" gridColumn="15 / 21" gridRow="6 / 9"/>
  <Element elementId="h_clear" gridColumn="21 / 25" gridRow="6 / 9"/>
</Panel>"""
    # The user's hand edits win (sigma_build/user_edits.json, user_layout.xml): wording, sizes and the page layout.
    if USER_LAYOUT.exists():
        layout = USER_LAYOUT.read_text()
    if USER_EDITS.exists():
        by_id = {e["id"]: e for e in els}
        for eid, fields in json.loads(USER_EDITS.read_text())["elements"].items():
            for path, value in fields.items():
                node, *keys = [by_id[eid]] + path.split(".")
                for k in keys[:-1]:
                    node = node.setdefault(k, {})
                node[keys[-1]] = value
    return {
        "schemaVersion": 1, "kind": "workbook",
        "settings": {"theme": theme, "navigation": {"pageHeader": "enabled"}},
        "pages": [{"id": "pg_main", "name": "Servicer Data Quality", "backgroundColor": "#FFFFFF", "pageWidth": {"mode": "custom", "maxWidth": 1360}},
                  {"id": "pg_model", "name": "Model", "visibility": "hidden"}],
        "panels": [{"id": "hdr", "type": "header", "title": "Header", "pages": ["pg_main"],
                    "config": {"backgroundColor": "#FFFFFF", "scroll": "sticky", "borderStyle": "shadow"}}],
        "elements": els,
        "layout": layout,
    }


def sigma(*args: str, body_file: pathlib.Path | None = None) -> dict:
    cmd = ["sigma", "-p", "brocc", "api", *args] + (["--body", f"@{body_file}"] if body_file else [])
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        raise SystemExit(f"sigma {' '.join(args[:3])} failed:\n{out.stdout[:2000]}\n{out.stderr[:2000]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--dry-run", action="store_true")
    g.add_argument("--create", action="store_true")
    g.add_argument("--update")
    ap.add_argument("--name", default="Servicer Data Quality (staging)")
    args = ap.parse_args()

    contents = build()
    (HERE / "contents.json").write_text(json.dumps(contents, indent=1))
    print(f"{len(contents['elements'])} elements -> sigma_build/contents.json")
    check = HERE / ".verify.json"
    check.write_text(json.dumps({"name": args.name, "folderId": FOLDER, "document": contents}))
    verdict = sigma("workbooks", "spec", "verify", body_file=check)
    check.unlink()
    if not verdict.get("valid", False):
        for e in verdict.get("errors", [])[:25]:
            print("  ✗", e.get("summary", e))
        raise SystemExit("verify failed - nothing was sent")
    print("verify: valid")
    if args.dry_run:
        return 0
    body = HERE / ".push.json"
    if args.create:
        body.write_text(json.dumps({"name": args.name, "folderId": FOLDER, "contents": contents}))
        res = sigma("workbooks", "create", body_file=body)
    else:
        body.write_text(json.dumps({"contents": contents}))
        res = sigma("workbooks", "contents", "update", "--params", json.dumps({"workbookId": args.update}), body_file=body)
    body.unlink()
    if "workbookId" not in res:
        raise SystemExit(f"Sigma rejected the build:\n{json.dumps(res, indent=1)[:4000]}")
    (HERE / "workbook.json").write_text(json.dumps({k: res[k] for k in ("workbookId", "url", "name", "latestVersion")}, indent=1))
    print(f"{res['name']} · v{res['latestVersion']} · {res['url']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
