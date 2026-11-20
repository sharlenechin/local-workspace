"""Build the mBank benchmark extract: accounts, payments and legal events, in the spec's columns.

Two sets of files, both in output/:
  mbank_2023_*        PL23003. mBank's own tape (mBank_2023.xlsx) is the base; Intrum's case
                      feed (CAT) adds legal events, payment source and customer-type checks.
  mbank_2019_2021_*   PL19009, PL19017, PL20015, PL20020, PL21024, from CAT alone.
plus reconciliation.csv, every check below with its figure and whether it passed.

Inputs are the caches the queries in queries/ write (run each with --csv into .cache/).
Run from local-workspace:  uv run python work/project-mbank/build_extract.py

Each rule that is measured rather than given says so beside it, with the figure, so a
reader can tell a fact from an inference.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache"
OUT = HERE / "output"
TAPE = HERE / "mBank_2023.xlsx"
STATUS_LOOKUP = HERE.parent / "italy" / "legal" / "main_status_code.csv"

TAPE_DEAL = "PL23003"
OLD_DEALS = ["PL19009", "PL19017", "PL20015", "PL20020", "PL21024"]

# EUR per PLN. The tape's own Reg_Balance / Reg_Balance_LCC is exactly 0.228885 on every row,
# which is PROD.COMMON.FCT_EXCHANGE_RATE_DAILY on 2026-09-30 (0.22889), not the purchase date.
# Every book uses the same rate so balances and payments stay comparable across them; a
# liquidation ratio does not depend on it at all.
RATE_TO_EUR = 0.228885

# Legal steps whose outcome means the bailiff closed the round without full recovery.
# WOFF (written off) and RETURN (returned to the creditor) are Intrum's LEGAL_RESULT values.
DISCONTINUED = {"WOFF", "RETURN"}


def read(name: str, **kw) -> pd.DataFrame:
    df = pd.read_csv(CACHE / f"{name}.csv", dtype=str, **kw)
    df.columns = df.columns.str.lower()
    return df


def dates(df: pd.DataFrame, *cols: str) -> pd.DataFrame:
    for c in cols:
        df[c] = pd.to_datetime(df[c], errors="coerce")
    return df


def numbers(df: pd.DataFrame, *cols: str) -> pd.DataFrame:
    for c in cols:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


checks: list[dict] = []


def check(topic: str, deal: str, what: str, figure, expected: str, passed: bool | None, note: str = "") -> None:
    checks.append({"topic": topic, "deal": deal, "check": what, "figure": figure,
                   "expected": expected, "passed": passed, "note": note})


# --------------------------------------------------------------------------- load

cases = numbers(dates(read("01_cases"), "registration_date", "default_date", "closing_date",
                      "statute_barred_date", "recorded_at"),
                "original_capital", "original_interest")
first = cases[cases.version_kind == "first"].set_index("case_id")
latest = cases[cases.version_kind == "latest"].set_index("case_id")

attrs = dates(read("02_case_attributes"), "first_seen_d", "insolvency_open_date",
              "bankruptcy_end_date").set_index("case_id")
events_raw = dates(read("03_legal_events"), "start_date", "end_date", "result_date")
pay = numbers(dates(read("04_payments"), "payment_date"), "amount")
pam = numbers(dates(read("05_pam_monthly"), "month"), "pam_collections")
scope = numbers(read("00_scope"), "pam_cases", "pam_principal", "cat_cases")

status_names = pd.read_csv(STATUS_LOOKUP, dtype=str).set_index("CODE")["DESCRIPTION"]

tape_acc = pd.read_excel(TAPE, sheet_name="Accs")
tape_pay = pd.read_excel(TAPE, sheet_name="Pmts")
tape_acc["case_id"] = tape_acc["Loan_ID"].str.removeprefix("L_BMK_")
tape_pay["case_id"] = tape_pay["Loan_ID"].str.removeprefix("L_BMK_")
tape_acc = tape_acc.set_index("case_id")

extraction_date = latest["recorded_at"].max().normalize()
pam_last_month = pam["month"].max()

# --------------------------------------------------------------------------- customer type
# From CAT's DEBTORS, checked against the tape's Customer_Type on PL23003 (2026-11-05):
#   a private debtor only                      B2C    7,173 of 7,173
#   a company debtor only                      Corpo     19 of 19
#   LEGAL_TYPE 3 or 4 on any debtor            Corpo     87 of 87
#   a private AND a company debtor otherwise   SME    1,487 of 1,493 (3 B2C, 3 Corpo)
# A sole trader is filed as both a person and a business, which is what makes SME.


def customer_type(row) -> str | None:
    legal = row["legal_types"] if isinstance(row["legal_types"], str) else ""
    private = float(row["any_private"] or 0) == 1
    company = float(row["any_company"] or 0) == 1
    if company and ("3" in legal or "4" in legal or not private):
        return "Corpo"
    if company and private:
        return "SME"
    if private:
        return "B2C"
    return None


attrs["customer_type_cat"] = attrs.apply(customer_type, axis=1)

# --------------------------------------------------------------------------- legal events

steps = events_raw[events_raw.source == "LEGAL_STEPS"].copy()
# A step can carry several outcomes; one row per step, keeping whether it ever ended in a
# discontinuation, and the date that outcome was recorded.
steps["discontinued"] = steps["result"].isin(DISCONTINUED)
steps["discontinued_on"] = steps["result_date"].where(steps["discontinued"]).fillna(
    steps["end_date"].where(steps["discontinued"]))
step_one = (steps.sort_values("discontinued", ascending=False)
            .groupby(["case_id", "record_key"], as_index=False)
            .agg(code=("code", "first"), start_date=("start_date", "first"),
                 end_date=("end_date", "first"), discontinued=("discontinued", "max"),
                 discontinued_on=("discontinued_on", "first"),
                 results=("result", lambda s: ",".join(sorted(set(s.dropna()))))))

ev = []
a = step_one[step_one.code == "A"]
ev.append(a.assign(event_type="lawsuit_filed", event_date=a.start_date, detail="LEGAL_STEPS A"))
v = steps[(steps.code == "V") & (steps.result == "VERDICT")]
v = v.assign(event_date=v.result_date.fillna(v.end_date)).drop_duplicates(["case_id", "record_key"])
ev.append(v.assign(event_type="title_obtained", detail="LEGAL_STEPS V, result VERDICT"))
z = steps[(steps.code == "Z") & (steps.result == "CLAUSE")]
z = z.assign(event_date=z.result_date.fillna(z.end_date)).drop_duplicates(["case_id", "record_key"])
ev.append(z.assign(event_type="enforcement_clause_granted", detail="LEGAL_STEPS Z, result CLAUSE"))
b = step_one[step_one.code == "B"]
ev.append(b.assign(event_type="bailiff_started", event_date=b.start_date,
                   detail="LEGAL_STEPS B, outcome " + b.results.replace("", "none yet")))
bd = b[b.discontinued]
ev.append(bd.assign(event_type="bailiff_discontinued", event_date=bd.discontinued_on,
                    detail="LEGAL_STEPS B, result " + bd.results))
ins = events_raw[events_raw.source == "BANKRUPTCY_RECORD"].drop_duplicates(["case_id", "start_date"])
ev.append(ins.assign(event_type="insolvency_declared", event_date=ins.start_date, detail="BANKRUPTCY_RECORD"))
death = attrs[attrs.first_seen_d.notna()].reset_index()
ev.append(death.assign(event_type="death_recorded", event_date=death.first_seen_d,
                       detail="DEBTORS status D, date first seen in the feed"))
plans = events_raw[events_raw.source == "INSTALLMENT"].drop_duplicates(["case_id", "record_key"])
ev.append(plans.assign(event_type="settlement_agreed", event_date=plans.start_date,
                       detail="INSTALLMENT status " + plans.code.fillna("?")))
closed = events_raw[(events_raw.source == "CASES") & events_raw.start_date.notna()]
closed = closed.assign(reason=closed.status.map(status_names).fillna("status " + closed.status.fillna("?")))
ev.append(closed.assign(event_type="account_closed", event_date=closed.start_date,
                        detail=closed.reason + " (closing code " + closed.code.fillna("?") + ")"))

events = pd.concat(ev, ignore_index=True)[["case_id", "event_type", "event_date", "detail"]]
events = events[events.event_date.notna()].drop_duplicates()
events["deal"] = events.case_id.map(first.deal)
events["balance_at_event"] = np.nan

# --------------------------------------------------------------------------- has_title proxy
# CAT holds no title or stage at purchase on instance 2020 (is_titled 0 on every case). A
# case whose FIRST legal step is the bailiff, with no lawsuit or verdict before it, was
# enforced on a title it already had. Checked on PL23003 in reconciliation.csv.
first_step = step_one.sort_values("start_date").groupby("case_id").first()
title_proxy = first_step.code.eq("B")

# --------------------------------------------------------------------------- accounts


def accounts_for(deals: list[str], with_tape: bool) -> pd.DataFrame:
    f = first[first.deal.isin(deals)].copy()
    # Zero-capital cases are kept: 333 of the 358 have payments (4.96m PLN), and mBank's tape
    # gives 22 of PL23003's a balance, so zero capital in CAT does not mean nothing was bought.
    f = f.join(attrs[["customer_type_cat"]])
    out = pd.DataFrame(index=f.index)
    out["portfolio_id"] = f.deal
    out["model_id"] = f.deal + "_" + f.index
    out["registration_date"] = f.registration_date
    out["extraction_date"] = extraction_date
    out["default_date"] = f.default_date
    out["default_date_source"] = "intrum_cat"
    principal = f.original_capital
    interest = f.original_interest.where(f.original_interest > 0)
    out["registration_balance"] = (principal + interest.fillna(0)) * RATE_TO_EUR
    out["principal_balance"] = principal * RATE_TO_EUR
    out["interest_balance"] = interest * RATE_TO_EUR
    out["fees_balance"] = np.nan
    out["product_type"] = None
    out["customer_type"] = f.customer_type_cat
    out["customer_type_source"] = "intrum_cat_legal_type"
    out["collection_stage"] = None
    out["collection_status"] = None
    out["has_title"] = title_proxy.reindex(f.index, fill_value=False)
    out["has_title_source"] = "proxy_first_legal_step_is_bailiff"
    out["origination_date"] = pd.NaT
    out["original_amount"] = np.nan
    out["rate_to_eur"] = RATE_TO_EUR
    if with_tape:
        t = tape_acc
        out = out.loc[out.index.intersection(t.index)]
        idx = out.index
        out["default_date"] = t.loc[idx, "Default_Date"]
        out["default_date_source"] = "mbank_tape"
        out["registration_balance"] = t.loc[idx, "Reg_Balance_LCC"] * RATE_TO_EUR
        # The tape's balance is one figure; CAT's capital is its principal on 73% of
        # accounts exactly, the tape carrying 1.6m PLN more on the rest, unsplit.
        out["principal_balance"] = f.loc[idx, "original_capital"] * RATE_TO_EUR
        out["interest_balance"] = np.nan
        out["product_type"] = t.loc[idx, "Product_Type"]
        out["customer_type"] = t.loc[idx, "Customer_Type"]
        out["customer_type_source"] = "mbank_tape"
        out["collection_stage"] = t.loc[idx, "Stage"]
        out["collection_status"] = t.loc[idx, "Status_Code"].replace({"Healthly": "Healthy"})
        # The spec's stage definitions: In- and Ex-Bailiff hold a title; Amicable and
        # Legal Phase ("no title or enforcement yet") do not.
        out["has_title"] = out.collection_stage.isin(["In-Bailiff", "Ex-Bailiff"])
        out["has_title_source"] = "mbank_tape_stage"
        out["multidebtor"] = t.loc[idx, "Multidebtor"]
    return out.reset_index(drop=True)


acc_new = accounts_for([TAPE_DEAL], with_tape=True)
acc_old = accounts_for(OLD_DEALS, with_tape=False)

# --------------------------------------------------------------------------- payment source


def payment_source(p: pd.DataFrame) -> pd.Series:
    """Amicable / Bailiff / Re-enforcement / Insolvency / Estate / Settlement, per payment.

    DERIVED, not sent by anyone: what the case was in on the payment date, from the events.
    Priority Insolvency > Estate > Re-enforcement > Bailiff > Settlement > Amicable.
    """
    p = p[["case_id", "payment_date"]].reset_index().rename(columns={"index": "pid"})
    src = pd.Series("Amicable", index=p.pid)

    rounds = step_one[step_one.code == "B"][["case_id", "start_date", "end_date", "discontinued_on"]].copy()
    first_disc = rounds.groupby("case_id").discontinued_on.min()
    rounds["is_re"] = rounds.start_date > rounds.case_id.map(first_disc)
    rounds["until"] = rounds.discontinued_on.fillna(rounds.end_date).fillna(pd.Timestamp.max.normalize())

    def within(spans: pd.DataFrame, start: str, until: str) -> pd.DataFrame:
        m = p.merge(spans, on="case_id")
        return m[(m.payment_date >= m[start]) & (m.payment_date <= m[until])]

    plans_s = plans.assign(until=plans.end_date.fillna(pd.Timestamp.max.normalize()))
    src[within(plans_s, "start_date", "until").pid.unique()] = "Settlement"
    hit = within(rounds, "start_date", "until")
    src[hit.pid.unique()] = "Bailiff"
    src[hit[hit.is_re].pid.unique()] = "Re-enforcement"
    deaths = death[["case_id", "first_seen_d"]].assign(until=pd.Timestamp.max.normalize())
    src[within(deaths, "first_seen_d", "until").pid.unique()] = "Estate"
    ins_s = ins.assign(until=ins.end_date.fillna(pd.Timestamp.max.normalize()))
    src[within(ins_s, "start_date", "until").pid.unique()] = "Insolvency"
    return src.values


# --------------------------------------------------------------------------- payments

pay["deal"] = pay.case_id.map(first.deal)
pay["registration_date"] = pay.case_id.map(first.registration_date)
pay["is_history"] = pay.transaction_type_code.eq("PAY HIST")


def cat_payments(deals: list[str], keep: set[str]) -> pd.DataFrame:
    p = pay[pay.deal.isin(deals) & pay.case_id.isin(keep)].copy()
    pre = p[p.is_history & (p.payment_date < p.registration_date)
            & (p.payment_date >= p.registration_date - pd.DateOffset(months=12))]
    post = p[~p.is_history & (p.payment_date >= p.registration_date)]
    out = pd.concat([pre.assign(payment_origin="intrum_cat_seller_history"),
                     post.assign(payment_origin="intrum_cat")])
    # One row per account, date and origin: a payment arrives split across capital,
    # interest and penalty records, and rebookings net against the payment they move.
    out = (out.groupby(["deal", "case_id", "payment_date", "payment_origin"], as_index=False)
           .amount.sum())
    out = out[out.amount.abs() > 0.005]
    return out


def finish_payments(p: pd.DataFrame) -> pd.DataFrame:
    p = p.reset_index(drop=True)
    p["payment_source"] = np.where(p.payment_origin.str.contains("history"), None,
                                   payment_source(p))
    p["model_id"] = p.deal + "_" + p.case_id
    p["payment_amount"] = p.amount * RATE_TO_EUR
    p["payment_amount_pln"] = p.amount
    p["rate_to_eur"] = RATE_TO_EUR
    return p[["model_id", "payment_date", "payment_amount", "payment_source",
              "payment_origin", "payment_amount_pln", "rate_to_eur"]]


old_keep = set(acc_old.model_id.str.split("_").str[1])
pay_old = finish_payments(cat_payments(OLD_DEALS, old_keep))

# PL23003 from mBank's tape. Its PRE-purchase rows are dated the 1st of the month AFTER the
# payment: moved back one month, 98.66% of case-months equal CAT's own seller history to the
# zloty (24.0% unmoved). Its post-purchase rows already sit in the right month (94.1% exact).
reg23 = tape_acc.Reg_Date.iloc[0]
tp = tape_pay.copy()
tp["pre"] = tp.Pmt_Date < reg23
tp["payment_date"] = np.where(tp.pre, tp.Pmt_Date - pd.DateOffset(months=1), tp.Pmt_Date)
tp["payment_date"] = pd.to_datetime(tp.payment_date)
tp["amount"] = tp.Pmt_Amt / RATE_TO_EUR
tp["deal"] = TAPE_DEAL
tp["payment_origin"] = np.where(tp.pre, "bmk_file_seller_history", "bmk_file")
pay_new = finish_payments(tp[["deal", "case_id", "payment_date", "payment_origin", "amount"]])
# The tape is monthly (1st of the month), so its payment_source is the case's state on that 1st.

# --------------------------------------------------------------------------- legal events out


def events_for(acc: pd.DataFrame) -> pd.DataFrame:
    keep = acc.model_id
    e = events.assign(model_id=events.deal + "_" + events.case_id)
    e = e[e.model_id.isin(keep)]
    return (e[["model_id", "event_type", "event_date", "balance_at_event", "detail"]]
            .sort_values(["model_id", "event_date", "event_type"]).reset_index(drop=True))


ev_new = events_for(acc_new)
ev_old = events_for(acc_old)

# --------------------------------------------------------------------------- checks

for deal, acc in [(TAPE_DEAL, acc_new)] + [(d, acc_old[acc_old.portfolio_id == d]) for d in OLD_DEALS]:
    s = scope[scope.deal == deal].iloc[0]
    cat_all = int((first.deal == deal).sum())
    zero = int(((first.deal == deal) & (first.original_capital.fillna(0) <= 0)).sum())
    check("accounts", deal, "accounts shipped / PAM cases bought", f"{len(acc):,} / {int(s.pam_cases):,}",
          "within 1%", abs(len(acc) / s.pam_cases - 1) <= 0.01,
          f"CAT holds {cat_all:,} cases, {zero:,} of them with zero capital (kept)")
    principal_pln = acc.principal_balance.sum() / RATE_TO_EUR
    check("accounts", deal, "principal shipped / PAM acquisition principal",
          round(principal_pln / s.pam_principal, 5), "1.00000 within 0.5%",
          abs(principal_pln / s.pam_principal - 1) <= 0.005,
          f"{principal_pln:,.2f} vs {s.pam_principal:,.2f} PLN")
    check("accounts", deal, "model_id unique", int(acc.model_id.duplicated().sum()), "0",
          not acc.model_id.duplicated().any())

# Payments vs PAM, post-purchase, through PAM's last actual month.
for deal, pp in [(TAPE_DEAL, pay_new)] + [(d, pay_old) for d in OLD_DEALS]:
    pp = pp[pp.model_id.str.startswith(deal) & ~pp.payment_origin.str.contains("history")
            & (pp.payment_date < pam_last_month + pd.offsets.MonthBegin(1))]
    ours = pp.payment_amount_pln.sum()
    theirs = pam[pam.deal == deal].pam_collections.sum()
    check("payments", deal, "post-purchase collections / PAM", round(ours / theirs, 5),
          "1.00000 within 2%", abs(ours / theirs - 1) <= 0.02, f"{ours:,.2f} vs {theirs:,.2f} PLN")
    by_year = (pp.assign(y=pp.payment_date.dt.year).groupby("y").payment_amount_pln.sum()
               / pam[pam.deal == deal].assign(y=lambda d: d.month.dt.year).groupby("y").pam_collections.sum())
    check("payments", deal, "post-purchase collections / PAM, by year",
          "; ".join(f"{y}: {r:.5f}" for y, r in by_year.items()), "each year within 5%",
          bool((by_year.dropna().sub(1).abs() <= 0.05).all()))

# PL23003: the tape against CAT, on the same accounts.
cat23 = pay[(pay.deal == TAPE_DEAL) & pay.case_id.isin(tape_acc.index)].copy()
cat23["m"] = cat23.payment_date.dt.to_period("M")
tp["m"] = tp.payment_date.dt.to_period("M")
for part, cm, tm in [("pre-purchase (tape moved back a month)", cat23.is_history, tp.pre),
                     ("post-purchase", ~cat23.is_history & (cat23.payment_date >= reg23), ~tp.pre)]:
    x = pd.concat({"cat": cat23[cm].groupby(["case_id", "m"]).amount.sum(),
                   "tape": tp[tm].groupby(["case_id", "m"]).amount.sum()}, axis=1).dropna()
    share = ((x.cat - x.tape).abs() <= 1).mean()
    check("tape vs CAT", TAPE_DEAL, f"{part}: case-months equal to 1 PLN", round(share, 5), "90%+",
          share >= 0.9, f"{len(x):,} case-months in both")
ct = attrs.loc[attrs.index.intersection(tape_acc.index), "customer_type_cat"]
agree = (ct == tape_acc.loc[ct.index, "Customer_Type"]).mean()
check("tape vs CAT", TAPE_DEAL, "customer type from CAT debtors = tape", round(agree, 5), "95%+",
      agree >= 0.95, "the rule the older books use")
tp_title = acc_new.set_index(acc_new.model_id.str.split("_").str[1]).has_title
px = title_proxy.reindex(tp_title.index, fill_value=False)
prec = (tp_title[px]).mean()
rec = px[tp_title].mean()
check("tape vs CAT", TAPE_DEAL, "has_title proxy: precision / recall vs the tape's stage",
      f"{prec:.5f} / {rec:.5f}", "precision 90%+", prec >= 0.9,
      f"proxy true on {int(px.sum()):,}, tape titled {int(tp_title.sum()):,}; "
      "Legal Phase cases sent straight to bailiff count as wrong here")
dd = (pd.to_datetime(first.loc[tape_acc.index, "default_date"]) - tape_acc.Default_Date).dt.days
check("tape vs CAT", TAPE_DEAL, "CAT default date minus mBank's, median days", float(dd.median()),
      "0", None,
      f"equal on {(dd == 0).mean():.5f}; IQR {dd.quantile(.25):.0f} to {dd.quantile(.75):.0f}. "
      "The older books carry CAT's definition")
diff = tape_acc.Reg_Balance_LCC - first.loc[tape_acc.index, "original_capital"]
check("tape vs CAT", TAPE_DEAL, "tape balance / CAT principal",
      round(tape_acc.Reg_Balance_LCC.sum() / first.loc[tape_acc.index, "original_capital"].sum(), 5),
      "1.00000", None, f"equal on {(diff.abs() <= 0.01).mean():.5f} of accounts; the tape carries "
      f"{diff.sum():,.2f} PLN more, not split into interest and fees")

# Legal events: the bailiff steps against CAT's separate enforcement files.
exe_cases = set(events_raw[(events_raw.source == "LEGAL_INFO") & (events_raw.code == "EXE")].case_id)
b_cases = set(b.case_id)
both = len(exe_cases & b_cases) / max(len(exe_cases | b_cases), 1)
check("legal events", "all", "cases with a bailiff step = cases with an EXE legal file", round(both, 5),
      "95%+", both >= 0.95)
for name, acc, e in [("PL23003", acc_new, ev_new), ("older books", acc_old, ev_old)]:
    orphans = (~e.model_id.isin(acc.model_id)).sum()
    check("legal events", name, "events whose account is not in the accounts file", int(orphans), "0", orphans == 0)
for name, acc, p in [("PL23003", acc_new, pay_new), ("older books", acc_old, pay_old)]:
    orphans = (~p.model_id.isin(acc.model_id)).sum()
    check("payments", name, "payments whose account is not in the accounts file", int(orphans), "0", orphans == 0)

# --------------------------------------------------------------------------- write

OUT.mkdir(exist_ok=True)
spec_cols = ["portfolio_id", "model_id", "registration_date", "extraction_date", "default_date",
             "registration_balance", "principal_balance", "interest_balance", "fees_balance",
             "product_type", "customer_type", "collection_stage", "collection_status", "has_title",
             "origination_date", "original_amount"]
extra = ["default_date_source", "customer_type_source", "has_title_source", "rate_to_eur"]
acc_new[spec_cols + extra + ["multidebtor"]].to_csv(OUT / "mbank_2023_accounts.csv", index=False)
acc_old[spec_cols + extra].to_csv(OUT / "mbank_2019_2021_accounts.csv", index=False)
pay_new.to_csv(OUT / "mbank_2023_payments.csv", index=False)
pay_old.to_csv(OUT / "mbank_2019_2021_payments.csv", index=False)
ev_new.to_csv(OUT / "mbank_2023_legal_events.csv", index=False)
ev_old.to_csv(OUT / "mbank_2019_2021_legal_events.csv", index=False)
rec = pd.DataFrame(checks)
rec.to_csv(OUT / "reconciliation.csv", index=False)

if __name__ == "__main__":
    pd.set_option("display.width", 250)
    pd.set_option("display.max_colwidth", 120)
    print(rec.to_string(index=False))
    for name, e in [("PL23003", ev_new), ("older", ev_old)]:
        print(name, e.event_type.value_counts().to_dict())
    print("rows:", {"acc_new": len(acc_new), "acc_old": len(acc_old), "pay_new": len(pay_new),
                    "pay_old": len(pay_old), "ev_new": len(ev_new), "ev_old": len(ev_old)})
