"""Turn docs/definitions.csv - the ONE place a term is defined - into everything that shows it.

    uv run python work/servicing/docs/build_definitions.py

Writes:
    docs/DATA-DEFINITIONS.md     the data definitions page, for reviewers and anyone reading the repo
    docs/SIGMA-AGENT.md          instructions for the workbook's Sigma agent, so people can ask the dashboard what a figure means
    design/project/Main.dc.html  the DEFS array behind the dashboard's Data & Definitions page

Edit the CSV, then run this. Never edit the three outputs by hand: tests/s7_design
fails if the dashboard's definitions drift from the CSV, or if any label on screen has none.
"""
from __future__ import annotations

import csv
import json
import pathlib
import re

DOCS = pathlib.Path(__file__).resolve().parent
SERVICING = DOCS.parent
CSV = DOCS / "definitions.csv"
MAIN = SERVICING / "design" / "project" / "Main.dc.html"

GROUP_ORDER = ["Scope", "Collections", "Benchmark", "Windows", "Data quality", "Grains", "Behaviour", "Book", "Case collections"]


def load() -> list[dict]:
    rows = list(csv.DictReader(CSV.open()))
    seen = set()
    for n, r in enumerate(rows, start=2):
        if None in r or any(v is None for v in r.values()):
            raise SystemExit(f"definitions.csv line {n}: wrong number of fields - quote any value that contains a comma")
        key = r["term"].lower()
        if key in seen:
            raise SystemExit(f"duplicate term in definitions.csv: {r['term']}")
        seen.add(key)
        r["aliases"] = [a for a in r["aliases"].split("|") if a]
        if r["group"] not in GROUP_ORDER:
            raise SystemExit(f"unknown group {r['group']!r} for {r['term']}; add it to GROUP_ORDER")
    return sorted(rows, key=lambda r: (GROUP_ORDER.index(r["group"]), rows.index(r)))


def _cell(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def write_markdown(rows: list[dict]) -> None:
    out = ["# Servicing dashboard - data definitions", "",
           "Every figure, control and grain on the dashboard, in plain English. Generated from "
           "`definitions.csv` by `build_definitions.py`: edit the CSV, not this file.", "",
           "**Computed in** says where the number is made. SQL means the dashboard query, because the "
           "figure must stay correct when a viewer filters the page (see `DESIGN.md` §5). Sigma means a "
           "calculated column. dbt mart means `PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY`, unchanged.", ""]
    for g in GROUP_ORDER:
        grp = [r for r in rows if r["group"] == g]
        if not grp:
            continue
        out += [f"## {g}", "", "| Term | Page | Meaning | Formula | Source | Computed in | Watch out |", "|---|---|---|---|---|---|---|"]
        for r in grp:
            term = r["term"] + (f" <br>_also: {', '.join(r['aliases'])}_" if r["aliases"] else "")
            out.append(f"| **{_cell(term)}** | {r['page']} | {_cell(r['definition'])} | `{_cell(r['formula'])}` | "
                       f"`{_cell(r['source'])}` | {_cell(r['computed_in'])} | {_cell(r['caveat'])} |")
        out.append("")
    (DOCS / "DATA-DEFINITIONS.md").write_text("\n".join(out))


def write_agent(rows: list[dict]) -> None:
    lines = [
        "# Sigma agent - Servicing analyst", "",
        "Paste the block below into the workbook agent's instructions, with the Portfolios element "
        "(`ROIia0oTOr`) as its data source. Generated from `definitions.csv`.", "", "```text",
        "You answer questions about Brocc's Servicing Dashboard for the CEO, the Head of Servicing and analysts.",
        "Answer in plain English first, then the figure, then where it comes from. Keep it short.",
        "",
        "Data: @dataSource(\"ROIia0oTOr\") - one row per portfolio per reporting month, all collections in euro.",
        "",
        "Rules you must follow:",
        "1. Collections come from the servicer's portfolio report; case behaviour from the loan-level case feed. Never combine them in one figure.",
        "2. Never average a ratio. Sum the numerator and the denominator, then divide.",
        "3. Compare with the servicer forecast like-for-like: only portfolio-months that have one.",
        "4. Case counts are a floor: only Intrum and Massey portfolios send a case feed. A blank means no feed, never 'nobody paid'.",
        "5. Cases on book and ever/never collected are stocks: use the selected month, never sum across months.",
        "6. Say which figures are solid and which are shaky. Quote the caveat when a figure has one.",
        "7. If the data cannot answer the question, say so. Do not estimate.",
        "",
        "Definitions:",
    ]
    for r in rows:
        alias = f" (also: {', '.join(r['aliases'])})" if r["aliases"] else ""
        lines.append(f"- {r['term']}{alias}: {r['definition']} Formula: {r['formula']}."
                     + (f" Watch out: {r['caveat']}" if r["caveat"] else ""))
    lines += ["```", ""]
    (DOCS / "SIGMA-AGENT.md").write_text("\n".join(lines))


def write_mock(rows: list[dict]) -> None:
    keep = ["term", "aliases", "page", "group", "definition", "formula", "source", "computed_in", "caveat"]
    # aliases go to the page as one "|"-separated string, as the CSV holds them
    payload = json.dumps([{k: ("|".join(r[k]) if k == "aliases" else r[k]) for k in keep} for r in rows],
                         ensure_ascii=False, separators=(",", ":"))
    payload = payload.replace("'", "\\u0027").replace("</", "<\\/")
    html = MAIN.read_text()
    line = f"    const DEFS = {payload};"
    if re.search(r"\n    const DEFS = .*;\n", html):
        html = re.sub(r"\n    const DEFS = .*;\n", lambda m: "\n" + line + "\n", html, count=1)
    else:
        anchor = "    // ---------- shared helpers"
        html = html.replace(anchor, "    // The data definitions, generated from work/servicing/docs/definitions.csv. Do not edit here.\n"
                            + line + "\n\n" + anchor, 1)
    MAIN.write_text(html)


def main() -> None:
    rows = load()
    write_markdown(rows)
    write_agent(rows)
    write_mock(rows)
    print(f"{len(rows)} terms -> DATA-DEFINITIONS.md, SIGMA-AGENT.md, Main.dc.html")


if __name__ == "__main__":
    main()
