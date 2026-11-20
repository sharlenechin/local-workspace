"""Verify the Snowflake SSO connection this workspace is configured for.

    mise run check              # uses SNOWFLAKE_CONNECTION from mise.toml
    mise run check -- sandbox   # or name a profile explicitly
"""

from __future__ import annotations

import os
import sys

import pandas as pd

import datalake


def main() -> int:
    name = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "SNOWFLAKE_CONNECTION", "prod"
    )
    print(f"\n  connecting as '{name}'...")
    try:
        info = datalake.session_info(connection=name)
    except Exception as exc:
        print(f"\n  CONNECTION FAILED\n  {type(exc).__name__}: {exc}\n")
        return 1

    print("\n  CONNECTED\n")
    row = info.iloc[0]
    for col in info.columns:
        value = row[col]
        shown = "(not set)" if pd.isna(value) else value
        print(f"    {col.lower():10} {shown}")

    if pd.isna(row["WAREHOUSE"]):
        print(
            "\n    No active warehouse — queries will fail until you set one."
            "\n    Visible warehouses:"
        )
        try:
            for wh in datalake.warehouses(connection=name)["name"].tolist():
                print(f"      - {wh}")
            print("\n    Put the one you want in mise.toml as SNOWFLAKE_WAREHOUSE.")
        except Exception as exc:
            print(f"      (could not list warehouses: {exc})")

    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
