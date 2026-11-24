"""Draw payments by month for every deal, one row per deal, into payments_by_month.png beside this file.

    uv run python work/hackathon_dataset/final_dataset/plot_payments.py

Bars are the Asset Index payments before registration, from output/ (final_dataset.py writes it, then calls this).
Lines: every warehouse payment on the deal at any date (sandbox build), prod's case payments today, and Intrum's PAM for the
whole deal (sandbox build). Each loan switches from Asset Index to warehouse in its own registration month; the dashed
line marks the month most loans registered. LOK-SE25008 switches at Intrum's acquisition month instead.
"""

from __future__ import annotations

from pathlib import Path

import datalake
import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

HERE = Path(__file__).parent
IMAGE = HERE / "payments_by_month.png"
SANDBOX = {"connection": "dev", "warehouse": "DEV_WH"}
# Deals whose payments switch from Asset Index to warehouse at Intrum's acquisition month, not each loan's
# registration month: their tape is Intrum's own collection history from before the purchase.
SPLIT_AT_ACQUISITION = {"LOK-SE25008"}

INK = "#1f2a2e"
MUTED = "#6b7a80"
TAPE = "#e09a9a"
PAM = "#9fbab3"
WAREHOUSE = "#123f3a"
PROD = "#9b1b30"


def monthly(series: pd.Series, dates: pd.Series) -> pd.Series:
    """Sum by month-end, in SEK millions."""
    return series.groupby(dates + pd.offsets.MonthEnd(0)).sum() / 1e6


def draw(ax, deal: str, payments: pd.DataFrame, accounts: pd.DataFrame) -> None:
    p = payments[payments.deal_id == deal]
    # Intrum's id, not the deal name: LOK-SE25008 is SE25018 at Intrum.
    intrum_id = p.intrum_id.dropna().iloc[0]

    tape = p[p.payment_source == "asset_index"]
    tape_m = monthly(tape.payment_amount, tape.payment_date)
    # Every warehouse payment on the deal at any date, not only the dataset's months after the split, so the
    # line overlays the bars wherever the warehouse has the same months.
    wh = datalake.q(HERE / "monthly_warehouse.sql", lower=True, portfolio_id=intrum_id, **SANDBOX)
    warehouse_m = pd.Series(wh.collected.astype(float).values / 1e6, index=pd.to_datetime(wh.month_end))
    pam = datalake.q(HERE / "monthly_pam.sql", lower=True, portfolio_id=intrum_id, **SANDBOX)
    prod = datalake.q(HERE / "monthly_prod_collections.sql", lower=True, portfolio_id=intrum_id)
    # Each loan switches from Asset Index to warehouse in its own registration month; the line marks the month most did.
    loans = accounts[accounts.deal_id == deal].drop_duplicates("model_id").warehouse_registration_date.dt.to_period("M")
    busiest = loans.value_counts()
    markers = [(busiest.index[0].to_timestamp(), "Registration Date")]
    if deal in SPLIT_AT_ACQUISITION:
        # The whole deal switches at the acquisition month, so that gets a line of its own.
        acquired = p.warehouse_vs_pam_compared_from.dropna().iloc[0]
        markers.append((pd.Timestamp(acquired).to_period("M").to_timestamp(), "Acquisition Date"))

    # Bars sit on the month they belong to, about a month wide with a thin gap.
    ax.bar(tape_m.index - pd.to_timedelta(14, unit="D"), tape_m.values, width=26, color=TAPE,
           label="Asset Index, before registration (LOK-SE25008: before acquisition)")
    ax.plot(pam.month_end, pam.pam / 1e6, color=PAM, linewidth=3, label="PAM, whole deal (sandbox build)")
    ax.plot(warehouse_m.index, warehouse_m.values, color=WAREHOUSE, linewidth=1.5,
            label="Warehouse, all payments (sandbox build, both fixes)")
    # Drawn on top: on a deal neither bug touches it sits exactly on the dataset's line.
    ax.plot(prod.month_end, prod.collected / 1e6, color=PROD, linewidth=1.8, linestyle=":", zorder=5,
            label="Warehouse on prod today (both bugs)")
    for when, _ in markers:
        ax.axvline(when, color=INK, linewidth=1, linestyle="--")
    # Headroom above the tallest series, so the label never sits on a bar or a line.
    top = max(tape_m.max(), warehouse_m.max(), pam.pam.max() / 1e6, prod.collected.max() / 1e6)
    ax.set_ylim(0, top * 1.22)
    # Start a little before the first non-zero payment from any source, so a zero-value row can't stretch
    # the axis. HEI-SE20009's really does start in 2008: its tape has small seller payments from Aug 2008.
    firsts = [s[s > 0].index.min() for s in (tape_m, warehouse_m) if (s > 0).any()]
    firsts += [d.month_end[d[c] > 0].min() for d, c in ((pam, "pam"), (prod, "collected")) if (d[c] > 0).any()]
    ax.set_xlim(left=pd.Timestamp(min(firsts)) - pd.DateOffset(months=6))
    for when, label in markers:
        ax.text(when, 0.985, f" {label}: {when:%b %Y}", transform=ax.get_xaxis_transform(),
                va="top", ha="left", color=INK, fontsize=9,
                bbox={"facecolor": "white", "edgecolor": "none", "pad": 1.5})

    ax.set_title(deal, loc="left", color=INK, fontsize=11, fontweight="bold")
    ax.set_ylabel("SEK m per month", color=MUTED)
    ax.grid(axis="y", color="#e6ebec", linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color("#c5cfd2")
    ax.tick_params(colors=MUTED)
    ax.xaxis.set_major_locator(mdates.YearLocator(2))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))


def main(deals: list[str] | None = None) -> Path:
    payments = pd.read_parquet(HERE / "output" / "payments.parquet")
    accounts = pd.read_parquet(
        HERE / "output" / "accounts.parquet", columns=["deal_id", "model_id", "warehouse_registration_date"]
    )
    deals = deals or sorted(payments.deal_id.unique())
    fig, axes = plt.subplots(len(deals), 1, figsize=(11, 3.6 * len(deals)), squeeze=False)
    for ax, deal in zip(axes[:, 0], deals):
        draw(ax, deal, payments, accounts)
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=2, frameon=False, fontsize=9, labelcolor=INK)
    # Keep about half an inch at the top for the legend, however many deals there are.
    fig.tight_layout(rect=(0, 0, 1, 1 - 0.5 / fig.get_figheight()))
    fig.savefig(IMAGE, dpi=150, facecolor="white")
    print(f"wrote {IMAGE}")
    return IMAGE


if __name__ == "__main__":
    main()
