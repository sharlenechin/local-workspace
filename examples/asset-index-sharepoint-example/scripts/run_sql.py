"""Run a .sql file against Snowflake and print the result.

    python scripts/run_sql.py queries/portfolio_exists.sql
    python scripts/run_sql.py queries/portfolio_exists.sql --connection dev --warehouse DEV_WH
    python scripts/run_sql.py queries/deal_vehicle.sql --csv out.csv

Self-contained on purpose: it reads ~/.snowflake/config.toml through the
connector's own `connection_name`, so there is nothing to install beyond
`snowflake-connector-python` and `pandas`, and nothing workspace-specific to
import.

`--warehouse` exists because a profile need not name one and Snowflake refuses
to run a query without an active warehouse. Pass it explicitly rather than
relying on an environment variable: a tool like mise can re-apply its own
SNOWFLAKE_WAREHOUSE inside a subprocess and silently win.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd
import snowflake.connector as sf

# Money and ratios to 5 decimal places. Two hides real differences in rates.
MAX_DP = 5


def run(sql: str, connection: str, warehouse: str | None) -> pd.DataFrame:
    con = sf.connect(connection_name=connection)
    try:
        cur = con.cursor()
        if warehouse:
            cur.execute(f"use warehouse {warehouse}")
        cur.execute(sql)
        return cur.fetch_pandas_all() if cur.description else pd.DataFrame()
    finally:
        con.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sql_file", type=Path)
    ap.add_argument("--connection", default="prod",
                    help="profile name in ~/.snowflake/config.toml (default: prod)")
    ap.add_argument("--warehouse", default=None,
                    help="warehouse to activate, e.g. NPL_ANALYST_WH or DEV_WH")
    ap.add_argument("--csv", type=Path, default=None, help="also write the result here")
    args = ap.parse_args()

    if not args.sql_file.exists():
        print(f"no such file: {args.sql_file}", file=sys.stderr)
        return 1

    df = run(args.sql_file.read_text(), args.connection, args.warehouse)

    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 50)
    pd.set_option("display.float_format", lambda v: f"{v:,.{MAX_DP}f}")
    print(df.to_string(index=False) if len(df) else "(no rows)")

    if args.csv:
        df.to_csv(args.csv, index=False)
        print(f"\nwrote {args.csv}  {df.shape[0]:,} x {df.shape[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
