"""Run a .sql file from the command line and show the result.

    mise run sql -- examples/example_servicing-dashboard.sql
    mise run sql -- examples/example_servicing-dashboard.sql months=3
    mise run sql -- collections_by_servicer months=6 --csv out.csv
    mise run sql -- examples/example_servicing-dashboard.sql --open

Paths are relative to the workspace root, because mise runs tasks from
there rather than from the directory you typed the command in.

The file is otherwise found the way `datalake.q()` finds it: as given, then
in `work/`, then the workspace root — `.sql` optional.

`key=value` works with either style of file: it fills a `{placeholder}`,
or rewrites a `set name = ...;` session variable. `db` defaults to PROD.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
import webbrowser
from pathlib import Path

import pandas as pd
from rich.console import Console
from rich.table import Table

import datalake

# Up to 5 decimal places, trailing zeros trimmed. 2dp hides real
# differences in rates and per-unit figures.
MAX_DP = 5


def _fmt(value: object) -> str:
    """Format one cell for the terminal."""
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return "—"
    if isinstance(value, (int,)) and not isinstance(value, bool):
        return f"{value:,}"
    if isinstance(value, float):
        return f"{value:,.{MAX_DP}f}".rstrip("0").rstrip(".")
    if isinstance(value, pd.Timestamp):
        # Midnight timestamps are dates in practice; drop the noise.
        return value.strftime("%Y-%m-%d" if value.normalize() == value else "%Y-%m-%d %H:%M")
    return str(value)


def render(df: pd.DataFrame, title: str, console: Console) -> None:
    """Draw the DataFrame as a bordered, right-aligned table."""
    table = Table(
        title=title,
        title_style="bold",
        header_style="bold cyan",
        row_styles=["", "on grey11"],  # zebra striping, readable on dark or light
        expand=False,
    )
    numeric = {
        c for c in df.columns if pd.api.types.is_numeric_dtype(df[c])
    }
    for col in df.columns:
        table.add_column(
            col,
            justify="right" if col in numeric else "left",
            no_wrap=col in numeric,
        )
    for row in df.itertuples(index=False):
        table.add_row(*(_fmt(v) for v in row))
    console.print(table)


def write_html(df: pd.DataFrame, title: str, path: Path) -> None:
    """Write a standalone HTML table and return nothing."""
    style = """
    <style>
      body { font: 14px -apple-system, system-ui, sans-serif; margin: 2rem;
             color: #1a1a1a; background: #fff; }
      h1 { font-size: 1.1rem; font-weight: 600; }
      table { border-collapse: collapse; font-variant-numeric: tabular-nums; }
      th, td { padding: 6px 12px; border-bottom: 1px solid #e5e5e5;
               text-align: right; white-space: nowrap; }
      th { position: sticky; top: 0; background: #fafafa; font-weight: 600;
           border-bottom: 2px solid #d4d4d4; text-align: right; }
      td:nth-child(-n+2), th:nth-child(-n+2) { text-align: left; }
      tr:hover td { background: #f5f8ff; }
      @media (prefers-color-scheme: dark) {
        body { color: #e5e5e5; background: #141414; }
        th { background: #1f1f1f; border-bottom-color: #3a3a3a; }
        th, td { border-bottom-color: #2a2a2a; }
        tr:hover td { background: #1c2333; }
      }
    </style>"""
    formatters = {
        c: (lambda v: _fmt(v)) for c in df.columns
    }
    body = df.to_html(index=False, border=0, formatters=formatters, escape=False)
    path.write_text(
        f"<!doctype html><meta charset=utf-8><title>{title}</title>"
        f"{style}<h1>{title}</h1>{body}"
        f"<p>{len(df):,} rows &times; {len(df.columns)} columns</p>"
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="run_sql", description="Run a .sql file and show the result."
    )
    ap.add_argument("sql_file", help="name or path of the .sql file")
    ap.add_argument(
        "variables", nargs="*", metavar="key=value",
        help="values for the {placeholders} in the file (db defaults to PROD)",
    )
    ap.add_argument("--csv", metavar="PATH", help="also write the result to CSV")
    ap.add_argument("--lower", action="store_true",
                    help="return column names in lower case")
    ap.add_argument("--excel", metavar="PATH", help="also write the result to xlsx")
    ap.add_argument(
        "--open", dest="open_html", action="store_true",
        help="render as HTML and open it in your browser",
    )
    ap.add_argument("--limit", type=int, metavar="N", help="show only N rows")
    ap.add_argument("--connection", help="profile name (default: prod)")
    # The sandbox has no NPL_ANALYST_WH, so a non-prod profile must name its own.
    ap.add_argument("--warehouse", help="warehouse (default: SNOWFLAKE_WAREHOUSE)")
    ap.add_argument("--plain", action="store_true", help="plain text, no table borders")
    ap.add_argument(
        "--show", action="store_true",
        help="print the rendered SQL and exit without running it",
    )
    args = ap.parse_args()

    # When stdout is not a terminal (piped, or captured by an editor panel)
    # rich falls back to 80 columns and squeezes early columns to nothing.
    # Force a wide canvas in that case so no column is truncated.
    console = Console(width=None if sys.stdout.isatty() else 240)

    passed: dict[str, str] = {}
    for item in args.variables:
        if "=" not in item:
            ap.error(f"expected key=value, got {item!r}")
        key, _, value = item.partition("=")
        passed[key] = value

    try:
        raw = datalake.read_sql(args.sql_file)
    except FileNotFoundError as exc:
        console.print(f"[red]{exc}[/red]")
        return 1

    # `db` is a convenience default, so only apply it to files that ask for
    # it. Anything the user passed explicitly must resolve, or it is an error.
    variables: dict[str, str] = dict(passed)
    if "db" in datalake.placeholder_names(raw) and "db" not in variables:
        variables["db"] = "PROD"

    try:
        sql = datalake.apply_variables(raw, variables)
    except KeyError as exc:
        console.print(f"[red]{str(exc).strip(chr(34))}[/red]")
        return 1

    if args.show:
        from rich.syntax import Syntax
        console.print(Syntax(sql, "sql", theme="ansi_dark", line_numbers=False))
        return 0

    label = Path(args.sql_file).stem
    with console.status(f"running {label}…"):
        df = datalake.q(
            sql,
            connection=args.connection,
            warehouse=args.warehouse,
            lower=args.lower,
        )

    shown = df.head(args.limit) if args.limit else df

    if args.plain:
        pd.set_option("display.width", 250)
        pd.set_option("display.max_columns", 50)
        pd.set_option("display.float_format",
                      lambda v: f"{v:,.{MAX_DP}f}".rstrip("0").rstrip("."))
        print(shown.to_string(index=False))
    else:
        subtitle = f" (first {len(shown)} of {len(df):,})" if args.limit else ""
        render(shown, f"{label}{subtitle}", console)

    console.print(f"[dim]{len(df):,} rows × {len(df.columns)} columns[/dim]")
    if not args.plain and console.is_terminal and len(df.columns) > 6:
        console.print(
            "[dim]wide result — add --open to view it in the browser instead[/dim]"
        )

    if args.csv:
        df.to_csv(args.csv, index=False)
        console.print(f"[green]wrote[/green] {args.csv}")
    if args.excel:
        df.to_excel(args.excel, index=False)
        console.print(f"[green]wrote[/green] {args.excel}")
    if args.open_html:
        out = Path(tempfile.gettempdir()) / f"{label}.html"
        write_html(df, label, out)
        console.print(f"[green]opening[/green] {out}")
        webbrowser.open(out.as_uri())

    return 0


if __name__ == "__main__":
    sys.exit(main())
