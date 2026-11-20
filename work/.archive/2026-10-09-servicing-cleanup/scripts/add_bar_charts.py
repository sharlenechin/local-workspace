"""Add two bar charts to a Servicing Dashboard readback and write a contents-update body.

usage: python add_bars.py <readback.json> <out_body.json>
"""
import json
import sys

src, out = sys.argv[1], sys.argv[2]
wb = json.load(open(src))
c = wb["contents"]

# The control-default trap (docs/HOW-IT-WORKS.md §1b): a push materialises
# value:false on the three guardrail controls and filters the whole page.
for e in c["elements"]:
    if e["kind"] == "control" and "filters" in e and "value" in e:
        del e["value"]

SRC = {"kind": "table", "elementId": "ROIia0oTOr"}
EUR = {"kind": "number", "formatString": "$,.0f", "currencySymbol": "€"}
MONTH = {"kind": "datetime", "formatString": "%b %Y"}

collections_chart = {
    "id": "barCollFc",
    "kind": "bar-chart",
    "name": "Collections vs servicer forecast, by month (EUR)",
    "source": SRC,
    "columns": [
        {"id": "bcf_month", "name": "Reporting Month",
         "formula": 'DateTrunc("month", [Portfolios/Reporting Month])', "format": MONTH},
        {"id": "bcf_coll", "name": "Collections",
         "formula": "Sum([Portfolios/Collections Sum])", "format": EUR},
        {"id": "bcf_fc", "name": "Servicer forecast",
         "formula": "Sum([Portfolios/Servicer Forecast Sum])", "format": EUR},
    ],
    "xAxis": {"columnId": "bcf_month", "sort": {"by": "bcf_month", "direction": "ascending"}},
    "yAxis": {"columnIds": ["bcf_coll", "bcf_fc"]},
    "stacking": "none",
    "description": {"visibility": "shown", "text":
        "All currencies converted to EUR. The forecast is the soft number: not every portfolio has one, "
        "so a month beating forecast partly reflects missing forecasts."},
}

# New and Lost only: they are the two movements in and out of collecting.
# Not a breakdown of Collected cases (docs/BUILD-GUIDE.md trap 5), and First
# collection overlaps New entirely, so it is left off.
cases_chart = {
    "id": "barCaseFlow",
    "kind": "bar-chart",
    "name": "Collected cases gained vs lost, by month",
    "source": SRC,
    "columns": [
        {"id": "bcs_month", "name": "Reporting Month",
         "formula": 'DateTrunc("month", [Portfolios/Reporting Month])', "format": MONTH},
        {"id": "bcs_new", "name": "New (returned after a gap)",
         "formula": "Sum([Portfolios/Collected Cases New])"},
        {"id": "bcs_lost", "name": "Lost (stopped paying)",
         "formula": "Sum([Portfolios/Collected Cases Lost])"},
    ],
    "xAxis": {"columnId": "bcs_month", "sort": {"by": "bcs_month", "direction": "ascending"}},
    "yAxis": {"columnIds": ["bcs_new", "bcs_lost"]},
    "stacking": "none",
    "description": {"visibility": "shown", "text":
        "Case counts are a floor: the case feed covers 164 of 264 portfolios. Dec 2025 is the first month in "
        "the window, so every case looks New and none can be Lost until Feb. The Aug spike in New is a "
        "feed backlog, not a collection event: collections fell that month."},
}

ids = {e["id"] for e in c["elements"]}
for ch in (collections_chart, cases_chart):
    if ch["id"] in ids:
        c["elements"] = [e for e in c["elements"] if e["id"] != ch["id"]]
    c["elements"].append(ch)

lay = c["layout"]
if 'elementId="barCollFc"' not in lay:
    lay = lay.replace(
        '<Element elementId="focusTable" gridColumn="1 / 13" gridRow="31 / 50"/>',
        '<Element elementId="focusTable" gridColumn="1 / 13" gridRow="31 / 50"/>\n'
        '      <Element elementId="barCollFc" gridColumn="1 / 13" gridRow="50 / 70"/>', 1)
    lay = lay.replace(
        '<Element elementId="caBeh" gridColumn="7 / 13" gridRow="1 / 4"/>',
        '<Element elementId="caBeh" gridColumn="7 / 13" gridRow="1 / 4"/>\n'
        '      <Element elementId="barCaseFlow" gridColumn="1 / 13" gridRow="4 / 24"/>', 1)
assert 'barCollFc' in lay and 'barCaseFlow' in lay, "layout anchors not found"
c["layout"] = lay

json.dump({"contents": c}, open(out, "w"))
print("ok", len(c["elements"]), "elements")
