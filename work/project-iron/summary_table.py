"""Deal summary table for Project Iron: one row per deal, built from 01_accounts.sql.

    uv run python work/project-iron/summary_table.py

Grain of 01 is one row per bridged Intrum case (model_id), so every figure here is per
bridged case unless it says otherwise.

  Average balance     legal balance at the seller's cut-off date, per bridged case
  Average debt age    cut-off date minus the borrower's earliest tape default date, in years
  Bridging confidence share of bridged cases where AT LEAST ONE independent check agrees:
                      tape principal within 1% of CAT ORIGINAL_CAPITAL, or tape default date
                      within a month of DIM_CASE.DEFAULT_DATE. On the ~10% sample tapes the
                      principal check fails by construction (the tape holds only some of a
                      borrower's loans), so there the date check carries the score.
"""

import datalake as d
import pandas as pd

pd.set_option("display.float_format", "{:,.5f}".format)
pd.set_option("display.width", 250)

a = d.q("work/project-iron/01_accounts.sql", connection="sandbox", warehouse="DEV_WH", lower=True)

principal_ok = a.bridge_principal_check.isin(["Exact", "Within 1% of Warehouse"])
date_ok = a.bridge_default_date_check.isin(["Exact", "Within a Month"])
a = a.assign(
    age=(pd.to_datetime(a.cutoff_date) - pd.to_datetime(a.default_date)).dt.days / 365.25,
    principal_ok=principal_ok,
    date_ok=date_ok,
    either=principal_ok | date_ok,
    both=principal_ok & date_ok,
)

out = a.groupby("portfolio_id").agg(
    cases_bridged=("model_id", "size"),
    avg_balance_at_cutoff=("balance_at_cutoff", "mean"),
    avg_debt_age_yrs=("age", "mean"),
    principal_check=("principal_ok", "mean"),
    date_check=("date_ok", "mean"),
    confidence_either=("either", "mean"),
    confidence_both=("both", "mean"),
)
print(out.to_string())
