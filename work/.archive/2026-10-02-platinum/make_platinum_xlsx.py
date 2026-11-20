"""Run every npl_platinum model and write a SAMPLE of each to its own Excel sheet.

    mise run platinum-xlsx

Reads the generated Snowflake copies (models/marts/npl_platinum_snowflake/), so
run `mise run platinum-sql` first if a dbt model has changed.

⚠⚠ THIS FILE IS A SAMPLE, NOT AN EXTRACT. Every sheet is capped at 5,000 rows.
Four of the eight models run to tens of millions, so what you see is a slice --
NEVER total a column here and quote it. The INDEX sheet carries each model's
REAL row count beside what was written, and says which sheets are sampled.

⚠ A sampled sheet uses Snowflake SAMPLE, so the rows are spread across the
table rather than being the first 5,000 -- which would otherwise come back from
one micro-partition and show one portfolio in one year. The trade is that the
rows CHANGE BETWEEN RUNS. A sheet whose model fits under the cap is the whole
model and is stable.
"""

import os
import time
import pandas as pd
import datalake


def q(sql, attempts=3):
    """datalake.q, with the connection recycled on failure.

    ⚠⚠ THE CONNECTION GOES BAD AFTER SEVERAL LARGE FETCHES IN ONE PROCESS. The
    Snowflake connector's Arrow reader then raises
        SystemError: <function SnowLogger.log ...> returned a result with an
        exception set
    on the NEXT model, whichever that happens to be -- so it looks like a broken
    model and is not. Every query here runs fine on its own; it is the ninth
    fetch in one process that fails. datalake.reset() drops the cached
    connection so the retry opens a new one.
    """
    for attempt in range(1, attempts + 1):
        try:
            return datalake.q(sql)
        except SystemError as exc:
            if attempt == attempts:
                raise
            print(f"    fetch failed ({str(exc)[:50]}...); reconnecting "
                  f"({attempt}/{attempts - 1})", flush=True)
            datalake.reset()
            time.sleep(2)

SRC = ("/Users/sharlenechin/data-warehouse/local-workspace/work/dbt/"
       "models/marts/npl_platinum_snowflake/")
OUT = "/Users/sharlenechin/data-warehouse/local-workspace/work/npl_platinum_extract.xlsx"

SAMPLE_ROWS = 5_000                      # per sheet, so the file stays openable

# ⚠ Excel caps a sheet NAME at 31 characters and the model names run to 40, so
# they are shortened here deliberately rather than letting pandas truncate them
# into something ambiguous.
SHEETS = {
    "dim_npl_platinum_portfolio":               "dim_portfolio",
    "dim_npl_platinum_portfolio_batch":         "dim_portfolio_batch",
    "dim_npl_platinum_case":                    "dim_case",
    "fct_npl_platinum_case_status":             "fct_case_status",
    "fct_npl_platinum_case_collection_daily":   "fct_case_collection_daily",
    "agg_npl_platinum_case_collection_monthly": "agg_case_collection_monthly",
    "agg_npl_platinum_portfolio_monthly":       "agg_portfolio_monthly",
    "agg_npl_platinum_forecast_monthly":        "agg_forecast_monthly",
    "agg_npl_platinum_case_payer_monthly":      "agg_case_payer_monthly",
}

index_rows, frames = [], {}
for model, sheet in SHEETS.items():
    sql = open(SRC + model + ".sql").read()
    n = int(q(f"SELECT COUNT(*) AS n FROM (\n{sql}\n)")["N"].iloc[0])
    sampled = n > SAMPLE_ROWS
    # ⚠ SAMPLE, not LIMIT. LIMIT returns whatever the first micro-partition
    # holds, which is one portfolio in one year and misleads about the shape.
    query = (f"SELECT * FROM (\n{sql}\n) SAMPLE ({SAMPLE_ROWS} ROWS)" if sampled
             else f"SELECT * FROM (\n{sql}\n)")
    print(f"{model:45} {n:>12,}  {'SAMPLE of ' + format(SAMPLE_ROWS, ',') if sampled else 'complete'}",
          flush=True)
    # ⚠ Recycled before each fetch on purpose -- see q(). Cheap next to the
    # query itself, and it keeps a nine-model run from falling over at model 2.
    datalake.reset()
    df = q(query)
    index_rows.append({
        "model": model,
        "sheet": sheet,
        "rows_in_model": n,
        "rows_in_sheet": len(df),
        "is_sample": "YES - do not total this sheet" if sampled else "no - complete model",
    })
    frames[sheet] = df

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with pd.ExcelWriter(OUT, engine="openpyxl") as xl:
    # INDEX goes first so nobody opens the file and assumes a sheet is complete.
    pd.DataFrame(index_rows).to_excel(xl, sheet_name="INDEX", index=False)
    for sheet, df in frames.items():
        df.to_excel(xl, sheet_name=sheet, index=False)
        print(f"  wrote {sheet:30} {len(df):>8,} rows x {len(df.columns)} cols", flush=True)

print(f"\n{OUT}  ({os.path.getsize(OUT) / 1e6:.2f} MB)")
