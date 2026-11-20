"""Generate paste-ready Sigma versions of the dashboard datasets.

Sigma cannot run `set` statements and wraps custom SQL in its own subquery, so
each file needs four edits before it can be pasted into a Custom SQL element:

    1. drop the `set ...;` lines
    2. substitute every `$variable` with a literal
    3. drop the trailing top-level `order by` (the outer subquery wastes it)
    4. drop the trailing semicolon

Doing that by hand, per file, every time the source changes, is how the two
copies drift. This does it mechanically instead.

    mise run sigma-sql          # regenerate everything
    python setup-scripts/make_sigma_sql.py --check    # CI-style drift check

Output goes to work/servicing/sigma/. Never edit those files — edit
the source in prod/ or raw/ and regenerate.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "work" / "servicing"
OUT = SRC / "sigma"

# Source file -> the literal each $variable becomes in Sigma.
# ⚠ Keep these in step with the defaults in the source files.
DATASETS: dict[str, dict[str, str]] = {
    # THE ONLY Sigma dataset (PROD only). Carries the servicer scorecard since
    # 2026-09-15 and the loan-level payer counts since 2026-09-17, when
    # dash_portfolio_diagnostics was deleted -- the business does not trust the
    # legal/phase split it existed to carry. dash_servicer_scorecard.sql and
    # dash_phase_collections*.sql are not generated for Sigma either.
    "prod/dash_portfolio_overview.sql": {
        "portfolio_filter": "'%'",
    },
}

BANNER = """-- ============================================================================
-- GENERATED FILE — DO NOT EDIT.
--   source : work/servicing/{src}
--   make   : mise run sigma-sql
--
-- Paste-ready for a Sigma Custom SQL element (Snowflake - PROD):
--   · `set` lines removed, every $variable replaced with a literal
--   · trailing `order by` and `;` removed — Sigma wraps this in a subquery
--
-- Edit the SOURCE and regenerate. Editing this copy is how the two drift.
-- ============================================================================
{note}
"""

NOTES = {
}


def strip_line_comments(text: str) -> str:
    """Remove `--` comments, ignoring a `--` inside a quoted literal."""
    out = []
    for line in text.splitlines():
        cut, in_quote = None, False
        for i, ch in enumerate(line):
            if ch == "'":
                in_quote = not in_quote
            elif ch == "-" and not in_quote and line[i : i + 2] == "--":
                cut = i
                break
        out.append(line if cut is None else line[:cut].rstrip())
    return "\n".join(out)


def convert(src_text: str, src_name: str, values: dict[str, str]) -> str:
    # Statement split has to ignore semicolons inside comments, so comments go
    # first — but only for finding the set lines, not for the output.
    stripped = strip_line_comments(src_text)
    declared = set(re.findall(r"^\s*set\s+(\w+)\s*=", stripped, re.M | re.I))
    missing = declared - values.keys()
    if missing:
        raise SystemExit(f"{src_name}: no Sigma literal configured for {sorted(missing)}")

    body_lines = []
    for line in src_text.splitlines():
        # 1. drop `set` lines (and any trailing comment on them)
        if re.match(r"^\s*set\s+\w+\s*=", line, re.I):
            continue
        body_lines.append(line)
    body = "\n".join(body_lines)

    # 2. substitute the variables, longest name first so $month_end does not
    #    eat the front of a hypothetical $month_end_prior.
    for name in sorted(values, key=len, reverse=True):
        body = re.sub(rf"\${name}\b", values[name], body)

    if "$" in strip_line_comments(body):
        leftover = set(re.findall(r"\$\w+", strip_line_comments(body)))
        raise SystemExit(f"{src_name}: unsubstituted variables remain: {sorted(leftover)}")

    # 3 + 4. drop a trailing top-level `order by`, then the final semicolon.
    # ⚠ The semicolon is NOT always the last character: a file can end
    #   `... is not null;   -- EUR-convertible only`. Strip it from the CODE
    #   part of the last line that has one, keeping the comment intact.
    body = body.rstrip()
    lines = body.split("\n")
    for i in range(len(lines) - 1, -1, -1):
        code = strip_line_comments(lines[i]).rstrip()
        if not code:
            continue
        if code.endswith(";"):
            at = lines[i].rindex(";", 0, len(code))
            lines[i] = lines[i][:at] + lines[i][at + 1 :]
        break
    body = "\n".join(lines)
    # Line-based, not a regex: a nested-quantifier pattern here backtracks
    # catastrophically on a 300-line file. Find the last top-level `order by`
    # (column 0) and drop it and everything after.
    lines = body.split("\n")
    for i in range(len(lines) - 1, -1, -1):
        if re.match(r"^order\s+by\b", lines[i], re.I):
            lines = lines[:i]
            break
    body = "\n".join(lines)

    note = NOTES.get(src_name, "")
    return BANNER.format(src=src_name, note=note) + "\n" + body.strip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="fail if any generated file is out of date")
    args = ap.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    stale: list[str] = []

    for src_name, values in DATASETS.items():
        src_path = SRC / src_name
        if not src_path.is_file():
            raise SystemExit(f"missing source: {src_path}")
        generated = convert(src_path.read_text(), src_name, values)
        dest = OUT / Path(src_name).name

        if args.check:
            if not dest.is_file() or dest.read_text() != generated:
                stale.append(str(dest.relative_to(ROOT)))
        else:
            dest.write_text(generated)
            print(f"  {src_name}  ->  {dest.relative_to(ROOT)}")

    if args.check:
        if stale:
            print("STALE (run `mise run sigma-sql`):")
            for s in stale:
                print("  " + s)
            return 1
        print("All Sigma files are up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
