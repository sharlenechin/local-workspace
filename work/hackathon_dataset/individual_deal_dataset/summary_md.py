"""Turn a deal's summary (the dict each <deal>/summary/summary.py builds) into summary.md.

Shared by every deal so their summaries read the same way: an overview table first, then the detail.
"""

from __future__ import annotations


def reconciliation(payments) -> dict:
    """The deal-wide PAM check from the sandbox build, as payments_post_registration.sql gives it."""
    row = payments[payments.payment_source == "warehouse"].iloc[0]
    return {
        "share_of_pam_pct": round(float(100 + row.warehouse_vs_pam_collection_total_pct), 5),
        "month_coverage_pct": round(float(row.warehouse_vs_pam_month_coverage_pct), 5),
        "reconciles": bool(row.warehouse_reconciles_with_pam),
        "months": f"{row.warehouse_vs_pam_compared_from:%Y-%m} to {row.warehouse_vs_pam_compared_to:%Y-%m}",
    }


def _n(value) -> str:
    return "" if value is None else f"{value:,}"


def _sek(value) -> str:
    return "" if value is None else f"{value:,.2f}"


def _pct(value) -> str:
    return "" if value is None else f"{value:g}%"


def _yes(value: bool) -> str:
    return "**Yes**" if value else "**No**"


def _table(header: list[str], rows: list[list]) -> str:
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    lines += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(lines)


def render(s: dict) -> str:
    own = s["ownership"]
    bridge = s["bridge_tape_to_cases_owned"]
    fixed = s["reconciliation"]
    prod_vs_snapshot = s["payments_since_purchase"]["npl_common_case_collection"]["vs_portfolio_snapshot_pct"]
    rows = s["dataset_rows"]

    overview = [
        ["Cases we own (warehouse)", _n(own["cases_owned_in_npl_common"])],
    ]
    if "loans_owned" in own:
        overview.append(["Loans we own", _n(own["loans_owned"])])
    overview += [
        [
            "Cases bridged to the Asset Index",
            f"**{_pct(bridge['bridged_total']['pct'])}** ({_n(bridge['bridged_total']['cases'])})",
        ],
        [
            "Warehouse payments vs Intrum's report (PAM): sandbox build with both fixes, used in this dataset",
            f"**{_pct(fixed['share_of_pam_pct'])}** of PAM, payments in {_pct(fixed['month_coverage_pct'])} "
            f"of PAM's months; reconciles: {_yes(fixed['reconciles'])}",
        ],
        [
            "Same on prod today, for comparison (both bugs, against PAM's portfolio snapshot)",
            f"{_pct(round(100 + prod_vs_snapshot, 5))} of PAM",
        ],
        ["Rows in accounts / payments", f"{_n(rows['accounts_sql'])} / {_n(rows['payments_sql'])}"],
    ]

    out = [
        f"# {s['deal']}",
        "",
        f"Measured {s['measured_on']} from {s['source_of_numbers']}.",
        "",
        "## Overview",
        "",
        _table(["", ""], overview),
        "",
        "Reconciles means the warehouse total is within 10% of PAM's and has payments in at least 80% of "
        f"PAM's months, from purchase ({fixed['months']}).",
        "",
        "## How the Asset Index bridges to the cases we own",
        "",
    ]
    ways = [
        [key.replace("_", " "), _n(v["cases"]), _pct(v["pct"]), v["how"]]
        for key, v in bridge.items()
        if isinstance(v, dict) and "how" in v
    ]
    ways.append(["**bridged**", f"**{_n(bridge['bridged_total']['cases'])}**", f"**{_pct(bridge['bridged_total']['pct'])}**", ""])
    nb = bridge["not_bridged"]
    ways.append(["not bridged", _n(nb["cases"]), _pct(nb["pct"]), nb.get("note", "")])
    out += [_table(["Way", "Cases", f"% of {_n(bridge['cases_owned'])} owned", "How"], ways), ""]
    for key in ("tape_cases_not_owned", "tape_rows_not_matched"):
        if key in bridge:
            v = bridge[key]
            count = v.get("cases", v.get("rows"))
            out += [f"Asset Index rows not matched to any case we own: {_n(count)}.", ""]
    if "loans_on_tape" in bridge:
        v = bridge["loans_on_tape"]
        out += [f"Loans in the Asset Index: {_n(v['loans'])} of {_n(v['of_loans_owned'])} ({_pct(v['pct'])}).", ""]

    pay = s["payments_since_purchase"]
    out += [f"## Payments since purchase ({pay['months']}, {pay['currency']})", ""]
    sources = [
        [
            name.replace("_", " "),
            _sek(v.get("paid")),
            _pct(v.get("vs_portfolio_snapshot_pct")),
            _n(v.get("months_with_payments")),
            _n(v.get("cases_with_payments")),
            v["scope"],
        ]
        for name, v in pay.items()
        if isinstance(v, dict)
    ]
    out += [
        _table(["Source", "Paid", "vs portfolio snapshot", "Months with payments", "Cases with payments", "What it is"], sources),
        "",
        "vs portfolio snapshot is how far the source's total is above (+) or below (-) the portfolio "
        "snapshot's, which is built from Intrum's own monthly report (PAM).",
        "",
    ]

    if "payments_before_registration" in s:
        v = s["payments_before_registration"]
        out += [
            "## Payments before registration",
            "",
            f"{v['what'].capitalize()}: SEK {_sek(v['paid'])} on {_n(v['cases_with_payments'])} cases, "
            f"{v['first']} to {v['last']}.",
            "",
        ]

    if "monthly_payments_asset_index_vs_warehouse" in s:
        v = s["monthly_payments_asset_index_vs_warehouse"]
        by = [[system, _n(x["loan_months"]), _n(x["matched"]), _pct(x["matched_pct"])] for system, x in v["by_system_of_current_case"].items()]
        by.append(["**all**", f"**{_n(v['loan_months_with_a_payment'])}**", f"**{_n(v['matched'])}**", f"**{_pct(v['matched_pct'])}**"])
        out += [
            "## Monthly payments: Asset Index vs warehouse (sandbox build)",
            "",
            f"Counted over {v['what']}.",
            "",
            _table(["Intrum system", "Loan-months", "Matched", "Matched %"], by),
            "",
        ]

    out += ["## Ownership", ""]
    by_system = ", ".join(f"{_n(n)} on {system}" for system, n in own["cases_owned_by_system"].items())
    out += [f"{_n(own['cases_owned_in_npl_common'])} cases ({by_system}). {own['note']}", ""]

    out += [
        "## Dataset rows",
        "",
        _table(
            ["Source in payments", "Rows", "Amount (SEK)"],
            [[k.replace("_", " "), _n(v["rows"]), _sek(v["amount"])] for k, v in rows["payments_sql_by_source"].items()],
        ),
        "",
    ]
    return "\n".join(out)
