"""Net collections per loan, per month, from the seller's payment columns.

    uv run python scripts/clean_payments.py PT15018
    uv run python scripts/clean_payments.py --all

Reads  portugal/raw/tapes/payments.parquet   (one row per cell)
       accounts/<deal>.parquet                           (the cleaned population)
Writes payments/<deal>.parquet                           (one row per key x month)
       payments/<deal>.meta.json

!! NET COLLECTIONS, NOT GROSS. `pay - ret`: a seller who ships returns as a
   separate series means the gross figure overstates what was actually
   collected. Where only `pay` exists the net IS the gross, and the metadata
   says which, because "we netted" and "there was nothing to net" are
   different claims.

!! THE SIGN CONVENTION IS THE SELLER'S, NOT OURS. Some tapes write a
   collection as a positive and a reversal as a negative; others do the
   reverse. Guessing per-value is how a refund becomes a receipt. The
   convention is decided ONCE PER DEAL from the shape of the data - if the
   non-zero values are overwhelmingly negative, that seller signs collections
   negative - and the decision is recorded, never inferred silently.

!! SCOPE COMES FROM THE CLEANED POPULATION. Only payments belonging to loans
   that survived cleaning are kept. A payment against a loan that is not in
   the book is not this book's money, and counting it is how collections
   quietly exceed the portfolio.
"""
import json
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from style import ascii_only, in_scope                      # noqa: E402

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
DATA = _P.TAPES
OUT = _P.PAYMENTS

# a payments id column must beat the next best by this much to be believed
CLEAR_WINNER = 5.0
ID_COLS = ("acct", "account", "reference_number", "Cliente Number",
           "Client Number", "ID Base cessão")


def pick_key(pay, acc):
    """Which payments column joins to which accounts field, by VALUE OVERLAP.

    !! NOT BY NAME. PT15018's payments are keyed on `Cliente Number` - the
       BORROWER - while its accounts are keyed on `Numero de Conta`, the
       loan. Assuming the payment id is the loan id silently orphans every
       row. The overlap is measured and the winner must beat the next best by
       a wide margin, or nothing is chosen.
    """
    cands = []
    for col in ID_COLS:
        if col not in pay.columns or not pay[col].notna().any():
            continue
        vals = set(pay[col].dropna().astype(str).str.strip())
        for field in ("loan_id", "client_id"):
            if field not in acc or not acc[field].notna().any():
                continue
            have = set(acc[field].dropna().astype(str).str.strip())
            n = len(vals & have)
            if n:
                cands.append((n, col, field))
    if not cands:
        return None, None, "no payments id column overlaps the cleaned population"
    cands.sort(reverse=True)

    # !! THE FINER GRAIN WINS WHEN BOTH WOULD WORK, and that was not what
    #   this did. It sorted by raw overlap and REFUSED whenever the top two
    #   were within CLEAR_WINNER of each other - so a tape offering a usable
    #   account column AND a usable client column got no payments at all,
    #   when the right answer was obviously the account.
    #   loan_id is strictly better: it rolls up to the borrower whenever
    #   somebody wants that, and a client-grain file can never be pushed the
    #   other way (T69). So where both are viable, take the loan.
    #   No Portuguese deal exercises this today - PT15018's single loan_id
    #   match out of 17,944 is coincidence, and is dropped as noise below -
    #   but the refusal was wrong and would have cost a whole payments file.
    top = cands[0][0]
    live = [c for c in cands if c[0] * CLEAR_WINNER >= top]   # the rest is noise
    by_field = {}
    for n, col, field in live:
        by_field.setdefault(field, []).append((n, col))

    # ambiguity is TWO COLUMNS claiming the SAME field, which is a real
    # question; two fields is not, because the grain settles it
    for field, rows in by_field.items():
        if len(rows) > 1 and rows[1][0] * CLEAR_WINNER >= rows[0][0]:
            return None, None, (
                f"ambiguous key: `{rows[0][1]}` matches {rows[0][0]:,} and "
                f"`{rows[1][1]}` matches {rows[1][0]:,}, both as `{field}`. "
                f"Too close to choose.")

    for field in ("loan_id", "client_id"):          # finest grain first
        if field in by_field:
            n, col = by_field[field][0]
            why = f"{n:,} values overlap `{field}`"
            if len(by_field) > 1:
                other = "client_id" if field == "loan_id" else "loan_id"
                why += (f" -- `{other}` would also have worked "
                        f"({by_field[other][0][0]:,}), and the FINER grain is "
                        f"taken: a loan rolls up to a borrower, never back")
            return col, field, why
    return None, None, "no payments id column overlaps the cleaned population"


def sign_convention(v):
    """(flip, why) -- does this seller write a collection as a negative?"""
    nz = v[v != 0]
    if not len(nz):
        return False, "every value is zero; no convention to read"
    neg = int((nz < 0).sum())
    share = neg / len(nz)
    if share > 0.9:
        return True, (f"{neg:,} of {len(nz):,} non-zero values are NEGATIVE "
                      f"({share:.1%}) -- this seller signs collections negative, "
                      f"so they are flipped")
    if share < 0.1:
        return False, (f"{len(nz) - neg:,} of {len(nz):,} non-zero values are "
                       f"positive ({1 - share:.1%}) -- collections are positive, "
                       f"nothing flipped")
    return False, (f"MIXED: {neg:,} of {len(nz):,} non-zero values are negative "
                   f"({share:.1%}). Not flipped, and NOT safe to assume -- ask "
                   f"the deal owner which sign is a receipt")


def main(deal):
    pf = DATA / "payments.parquet"
    af = _P.ACCOUNTS / f"{deal}.parquet"
    if not af.exists():
        print(f"{deal}: clean the accounts first", file=sys.stderr)
        return 2
    pay = pd.read_parquet(pf)
    pay = pay[pay.deal == deal].copy()

    # !! HONOUR THE DUPLICATE DECISION clean_accounts ALREADY MADE.
    #   Payments are extracted from the raw workbook, not from the accounts
    #   tape, so a second copy of a book that accounts pruned away is still
    #   sitting here with all its PAGAMENTOS_* columns. PT20008: 75,530
    #   payment rows for a 37,765-row book, every figure doubled. One
    #   decision, taken once, applied everywhere.
    mp = af.with_suffix("").with_suffix(".meta.json")
    mp = af.parent / f"{deal}.meta.json"
    if mp.exists():
        dropped = set(json.loads(mp.read_text()).get("dropped_source_files", []))
        if dropped and "source_file" in pay.columns:
            n = int(pay.source_file.isin(dropped).sum())
            if n:
                print(f"  dropped {n:,} payment row(s) from "
                      f"{len(dropped)} file(s) clean_accounts pruned as a "
                      f"duplicate book: {', '.join(sorted(dropped))}")
                pay = pay[~pay.source_file.isin(dropped)]
    acc = in_scope(pd.read_parquet(af))
    OUT.mkdir(parents=True, exist_ok=True)
    meta = {"deal": deal, "in_scope_loans": int(len(acc))}

    if not len(pay):
        print(f"{deal}: no payment columns on this tape")
        meta.update({"rows": 0, "note": "the tape carries no payment columns"})
        (OUT / f"{deal}.meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        return 0

    pay["amt"] = pd.to_numeric(pay.amount, errors="coerce")

    # !! COLUMNS WITH NO MONEY IN THEM ARE NOT A KEYING PROBLEM.
    #   PT20008 ships thirteen PAGAMENTOS_YYYYMM columns across 2,905 loans -
    #   37,765 cells, every one 0.00, confirmed by reading the workbook
    #   directly. The key test ran first, found no id column (that tape is
    #   anonymised), and the review sheet therefore told a reviewer the
    #   payments could not be ATTRIBUTED. True, and beside the point: there
    #   is nothing to attribute. A seller who ships empty columns has told us
    #   something, and it is not the same thing as a seller whose ids we
    #   cannot match.
    #   Asked first, because the honest reason is the one a reader can act on.
    _nz = int((pay.amt.fillna(0) != 0).sum())
    if _nz == 0:
        print(f"{deal}: {len(pay):,} payment cell(s), EVERY ONE ZERO")
        print("     The tape carries payment columns and no payments. By the "
              "rule that a\n     zero is not a payment, all of them are null, "
              "so the file is empty -\n     which is the seller's data, not a "
              "gap in our reading.")
        meta.update({"rows": int(len(pay)), "non_zero_cells": 0,
                     "note": "payment columns present; every cell is zero",
                     "empty_reason": "every payment cell on this tape is 0.00"})
        (OUT / f"{deal}.meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        return 0

    key, field, why = pick_key(pay, acc)
    print(f"{deal}: {len(pay):,} payment row(s)")
    if key is None:
        print(f"  !! {why}")
        print("     Nothing is written: a payments file that cannot be tied to "
              "the\n     population is not evidence.")
        meta.update({"rows": int(len(pay)), "blocked": why})
        (OUT / f"{deal}.meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        # !! BLOCKED IS NOT FAILED. This returned 1, the same code a crash
        #   returns, so no caller could tell "this tape's payments cannot be
        #   tied to the population" from "this script threw". A real
        #   exception in here ran for twenty minutes behind a loop that had
        #   been told to ignore rc=1 on this script.
        #   A reported, understood condition exits 0. Anything non-zero is a
        #   defect, and run.py stops on it.
        return 0
    print(f"  key: payments.`{key}` -> accounts.`{field}`  ({why})")

    flip, swhy = sign_convention(pay.amt)
    print(f"  sign: {swhy}")
    if flip:
        pay["amt"] = -pay["amt"]

    # !! A KEY THAT STRADDLES THE SCOPE BOUNDARY CANNOT BE SPLIT. Where the
    #   payments are keyed on the BORROWER and scope is decided per LOAN, a
    #   client holding one in-scope loan and one excluded loan has payments
    #   that belong to both and divide into neither.
    #   PT15018 has exactly 2 such clients, EUR 16.52 across the interim
    #   window - which is why the client-grain interim figure reads
    #   1,569,881.63 against the seller's row-level 1,569,865.11. The
    #   difference is not an error in either; it is the grain.
    #   Reported, never silently pro-rated: splitting a payment between two
    #   loans on a ratio nobody published is invention.
    full = pd.read_parquet(af)
    if field == "client_id" and "segment" in full:
        _in = set(in_scope(full)[field].dropna().astype(str).str.strip())
        _out = set(full[~full.index.isin(in_scope(full).index)][field]
                   .dropna().astype(str).str.strip())
        straddle = _in & _out
        if straddle:
            _sk = pay[key].astype(str).str.strip()
            amt = float(pay.loc[_sk.isin(straddle), "amt"].sum())
            meta["straddling_keys"] = len(straddle)
            meta["straddling_amount"] = round(amt, 2)
            print(f"  !! {len(straddle)} {field}(s) hold BOTH in-scope and "
                  f"out-of-scope loans, EUR {amt:,.2f}")
            print(f"     Their payments cannot be split at this grain and are "
                  f"KEPT IN FULL.")

    pay["_k"] = pay[key].astype(str).str.strip()
    have = set(acc[field].dropna().astype(str).str.strip())
    inside = pay._k.isin(have)
    if (~inside).any():
        lost = pay.loc[~inside, "amt"].sum()
        print(f"  dropped {int((~inside).sum()):,} row(s), EUR {lost:,.2f} -- "
              f"against loans that are NOT in the cleaned population")
    pay = pay[inside]

    series = sorted(pay.series.dropna().unique()) if "series" in pay else []
    # !! GROUP WITH dropna=False. PT18019 carries no dates at all (T20), and
    #   pandas drops rows whose GROUP KEY is NaN - so 475,485 real payment
    #   rows holding EUR 10,615,169.65 aggregated to nothing, and the script
    #   cheerfully reported 0.00 over 0 months. An undated payment is still a
    #   payment; it is the DATE that is missing, not the money.
    #   `period` keeps the seller's own label (-12M, 1M), so the rows stay
    #   distinguishable even with no month to place them on.
    idx = ["_k", "period_month"] if pay.period_month.notna().any() \
        else ["_k", "period"]
    wide = (pay.pivot_table(index=idx, columns="series", values="amt",
                            aggfunc="sum", observed=True, dropna=False)
            .reset_index() if series else
            pay.groupby(idx, observed=True, dropna=False)
            .amt.sum().reset_index(name="pay"))
    if "period_month" not in wide.columns:
        wide["period_month"] = pd.NA
    for s in ("pay", "ret"):
        if s not in wide:
            wide[s] = 0.0
    wide[["pay", "ret"]] = wide[["pay", "ret"]].fillna(0.0)
    # !! NAME THE OUTPUT COLUMNS FOR WHAT THEY ARE. `pay`/`ret`/`net` are the
    #   SELLER's series labels, fine inside this script and opaque in a file
    #   someone else reads a year from now. The output says payment_in,
    #   payment_out and payment_amount, where the amount is the net - which is
    #   the number anyone quoting collections wants.
    wide = wide.rename(columns={"pay": "payment_in", "ret": "payment_out"})
    # !! THE NET IS THE NUMBER. Gross collections on a tape that ships returns
    #   separately overstate what the book actually received.
    wide["payment_amount"] = wide["payment_in"] - wide["payment_out"]

    # !! NO PERIOD LABEL HERE. The payments file stays id + date + amount.
    #   Which months are interim is DERIVABLE downstream: accounts carry
    #   cutoff_date on every loan, so anyone who needs the split computes it
    #   from the one source rather than trusting a label baked in at cleaning
    #   time. A derived column stored is a derived column that can disagree
    #   with what it was derived from.

    # !! A ROW MEANS A PAYMENT HAPPENED. The sellers ship a DENSE grid - every
    #   loan gets a cell for every month, paid or not - and keeping all of it
    #   made 1.5m rows carrying about 109k facts, between 79% and 99.8% of
    #   them zero. Worse than the bloat: a zero and a month the seller never
    #   reported become indistinguishable downstream, so "no payment" and "no
    #   data" collapse into the same value.
    #   Only months where something MOVED are kept. The test is `pay` or
    #   `ret`, never `net`: 100 paid and 100 returned nets to zero and is two
    #   real events. Totals are unaffected by construction, and the dropped
    #   count is recorded so the shrinkage is evidence, not a mystery.
    _before = len(wide)
    moved = wide["payment_in"].ne(0) | wide["payment_out"].ne(0)
    _months_all = int(wide.period_month.nunique())
    wide = wide[moved]
    _dropped = _before - len(wide)

    wide = wide.rename(columns={"_k": field,
                                "period_month": "payment_month"})

    # !! LONG, AND THE SIGN CARRIES THE DIRECTION. The wide shape put
    #   payment_in, payment_out and payment_amount side by side, which forces
    #   every reader to know that the third is the first minus the second, and
    #   invents a row for a return that never happened.
    #   One row per payment EVENT instead: money in is positive, money out is
    #   negative, and summing payment_amount over anything - a loan, a month,
    #   the book - is the net by construction.
    #   !! THE SELLER'S OWN SIGN CONVENTION IS NORMALISED FIRST, above, and
    #   recorded in the metadata as `sign_evidence`. By the time a row is
    #   written, positive means money received on this book. A reader must
    #   never have to guess which way a negative points, and here they do not
    #   have to: the convention was decided once per deal, from the data, and
    #   written down.
    # the wide `payment_amount` was only ever a working column; in the long
    # shape the signed amount IS the value, so it must not also be an input
    wide = wide.drop(columns=[c for c in ("payment_amount",) if c in wide])
    long = wide.melt(
        id_vars=[c for c in (field, "payment_month", "period") if c in wide],
        value_vars=[c for c in ("payment_in", "payment_out") if c in wide],
        var_name="direction", value_name="payment_amount")
    long = long[long.payment_amount.ne(0) & long.payment_amount.notna()]
    # money out is negative; the SIGN is the only direction marker the file
    # needs, and summing is then the net over any grouping
    long.loc[long.direction.eq("payment_out"), "payment_amount"] *= -1
    long = long.drop(columns=["direction"]).assign(deal_id=deal)

    # !! ONE SHAPE ON EVERY DEAL, FROM schema.yaml. The columns used to
    #   depend on the tape: `loan_id` on three deals, `client_id` on two,
    #   and `period` on one. Five files, three shapes, no contract - so a
    #   consumer reading them all had to special-case each.
    #   Both id columns now always exist and `grain` says which one carries
    #   the key. The empty one is not a gap: on a client-grain tape a NULL
    #   `loan_id` states that this money CANNOT be attributed to one
    #   account, which is true and worth saying.
    import yaml as _yaml
    _cols = [c["name"] for c in
             _yaml.safe_load(_P.SCHEMA.read_text())["payments"]]
    # !! THE SHARED VALUE, NOT A LOCAL ONE. This wrote whichever field this
    #   script had picked. That is the same answer in every case today, but
    #   two places deciding the same thing is how they come to disagree - so
    #   it asks the one helper accounts asked, and refuses if they differ.
    import style as _st_g
    _shared, _ = _st_g.deal_grain(deal)
    if _shared != field:
        raise SystemExit(
            f"REFUSING: payments keyed on `{field}` but the deal's shared "
            f"grain is `{_shared}`. The three outputs would not join.")
    long["grain"] = field
    for _c in _cols:
        if _c not in long.columns:
            long[_c] = pd.NA
    wide = long[_cols].sort_values([field, "payment_month"],
                                   na_position="last").reset_index(drop=True)

    wide.to_parquet(OUT / f"{deal}.parquet", index=False)

    meta.update({
        "rows": int(len(pay)), "grain": field, "payments_key": key,
        "key_evidence": why, "sign_flipped": bool(flip), "sign_evidence": swhy,
        "series_present": series,
        "netted": "ret" in series,
        "rows_out": int(len(wide)),
        "zero_rows_dropped": int(_dropped),
        "months_covered": _months_all,
        "months": int(wide.payment_month.nunique()),
        "periods": int(wide["period"].nunique()) if "period" in wide else None,
        "dated": bool(wide.payment_month.notna().any()),
        "gross_pay": round(float(
            wide.loc[wide.payment_amount.gt(0), "payment_amount"].sum()), 2),
        "returns": round(float(
            -wide.loc[wide.payment_amount.lt(0), "payment_amount"].sum()), 2),
        "net_collections": round(float(wide.payment_amount.sum()), 2),
        f"{field}s_with_a_payment": int(wide[field].nunique()),
    })
    (OUT / f"{deal}.meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"  kept {len(wide):,} row(s) where a payment occurred; dropped "
          f"{_dropped:,} empty {field} x month cell(s) "
          f"({_months_all} month(s) covered)")
    print(f"  gross {meta['gross_pay']:,.2f}  returns {meta['returns']:,.2f}"
          f"  NET {meta['net_collections']:,.2f}"
          f"   over {meta['months']} month(s)"
          f", {meta[f'{field}s_with_a_payment']:,} {field}s")
    if not meta["netted"]:
        print("  note  this tape has no RETURNS series, so net == gross here")
    if not meta["dated"]:
        print("  !! no dates on any row (T20): these cannot be placed on a "
              "timeline")
    return 0


if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("-")]
    if "--all" in sys.argv:
        deals = sorted(p.stem for p in (_P.ACCOUNTS).glob("*.parquet"))
        sys.exit(max(main(d) for d in deals))
    sys.exit(main(a[0] if a else "PT15018"))
