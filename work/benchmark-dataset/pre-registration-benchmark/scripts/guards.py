"""Guard rails for the cleaned pre-registration accounts and payments.

    uv run python work/benchmark-dataset/pre-registration-benchmark/guards.py PT15018

Exits non-zero if any guard fails. Every expected figure below was MEASURED, and
most were measured twice by different routes. They are frozen on purpose: adding
a column later must not move them, and if it does, this fails loudly instead of
the number quietly drifting.

WHY THIS EXISTS: every defect found while building this book was SILENT.
Portuguese month names decoded as English kept 4 months of 26 and dropped the
rest with no error. Three byte-identical files were read twice, doubling those
books' payments. A dot decimal read as a Portuguese comma turned EUR 66,924 into
6.6e18. None of it raised anything. Eyes do not catch these; totals do.
"""
import sys
from pathlib import Path
import pandas as pd
from style import in_scope, headline, attr_series

import paths as _P

HERE = Path(__file__).resolve().parent          # scripts/
BASE = HERE.parent                              # pre-registration-benchmark/
TAPES = _P.TAPES

# deal -> guard -> expected. Frozen once a book reconciles.
EXPECT = {
    "PT15018": {
        # SCOPE COMES FROM THE STRATS. The .xlsb summary block publishes a total
        # per segment; scope is every collections row whose Segmento is not
        # 'Excluded'. These two figures are the seller's own, so if a change moves
        # either one, the change is wrong.
        # !! MEASURED ON THE OUTPUT, not on tape rows. PT15018 collapses 79
        #   migration-split accounts (grain: loan_id), so the output is smaller
        #   than the tape and that is correct. The seller published a BALANCE for
        #   this book, not a count, so the balance is the real proof and the count
        #   is a stability check.
        # 32,531 until 2026-10-07. Two rows left the book that day and both
        # were junk: the ENGLISH header row (loan_id "Account Number",
        # product_type "Product Code") and an all-`x` stray. Neither carried a
        # balance, so the published 407,079,317.23 is unchanged to the cent --
        # which is the proof that the drop was right and not a trim to fit.
        "in_scope_loans":       32_529,
        "in_scope_balance":     407_079_317.23,   # = published A+B+C exactly
        "n_strats_hits":        2,
        # the seller ALSO publishes its collections for Oct-2015..13-Feb-2016.
        # A second, independent proof -- never drop it to tidy the code.
        "interim_window":       1_569_865.11,
        # Payments: the summary also publishes Interim Collections for
        # Oct-2015..13-Feb-2016, excluding the same segment. Rebuilt from the
        # loan detail we land on it to the cent, in all three segments separately.
        "payment_months":       26,
        # Every in-scope loan must carry its payment rows. 0 means none were lost.
        # A loan is never written under two different ORIGINAL account numbers;
        # only the (Sistema) id multiplies. If this stops being 0 the join is unsafe.
                # !! ONE LOAN DEFAULTS BEFORE IT IS ORIGINATED. 1232400533, originated
        #   2007-05-10 and defaulted 2007-04-10 -- 30 days earlier. Both dates
        #   parse cleanly, so this is the seller's error and not ours. The same
        #   loan also carries capital (33,553.15) far above its balance
        #   (4,911.57), which is this deal's open Claims-versus-Collections
        #   disagreement. Raise both with the deal owner.
        "default_before_origination": 1,
        # !! THE ROLL-FORWARD RESIDUAL, in EUR. Opening minus collections
        #   minus closing. 0.29 is rounding across 32,529 loans and
        #   EUR 405.5m; anything larger means the balances and the payments
        #   have stopped agreeing.
        "rollforward_residual": -0.29,
"duplicate_files":      0,
    },
    "PT20006": {
        # No seller figure usable: the `Summary` / `Summary Reflect` tabs are
        # BROCC'S OWN pricing blocks (T25). 0 per-sheet footer total(s) are
        # proven (T21); the union has no published figure of its own.
        "in_scope_loans":   4_781,
        "in_scope_balance": 23_077_119.87,
        "n_strats_hits":    0,
        "duplicate_files":  0,
    },
    "PT20014": {
        # No seller figure usable: the `Summary` / `Summary Reflect` tabs are
        # BROCC'S OWN pricing blocks (T25). 1 per-sheet footer total(s) are
        # proven (T21); the union has no published figure of its own.
        "in_scope_loans":   11_388,
        "in_scope_balance": 55_834_580.56,
        "n_strats_hits":    1,
        "duplicate_files":  0,
    },
    "PT21004": {
        # No seller figure usable: the `Summary` / `Summary Reflect` tabs are
        # BROCC'S OWN pricing blocks (T25). 0 per-sheet footer total(s) are
        # proven (T21); the union has no published figure of its own.
        # 8,948 briefly, while a bad collapse rule was deleting
        # within-sheet duplicate ids. Restored to 9,029.
        # !! `reference_number` IS NOT A KEY HERE EITHER (T19, as PT16023).
        #   81 numbers cover two rows each - same client, same dates,
        #   different balances - so two facilities under one reference. Both
        #   balances are real and both are counted; the id is simply not
        #   unique. Pinned, never surrogate-keyed, and the bridge has to be
        #   told.
        "duplicate_loan_ids": 81,
        "in_scope_loans":   9_029,
        "in_scope_balance": 46_226_579.98,
        "n_strats_hits":    0,
        "duplicate_files":  0,
    },
    "PT19013": {
        # NO SELLER FIGURE (zero strats hits), and the same buyer-authored
        # `Summary Reflect` tab as PT19007 (T25) which must not be used.
        # This book arrives in the messiest shape of the twelve: the same
        # loans appear in up to three blocks at once, across DIFFERENT sheet
        # names, and 6,745 is the union after containment pruning.
        # !! 10 ACCOUNTS ARE IN DISPUTE. The Deceased stock ships as 320 and
        #   again, in a file named "final", as 310. The 310 is a strict subset,
        #   so the containment rule keeps the 320 - which is the conservative
        #   error, not a decision. Ask whether those 10 were withdrawn; if so,
        #   add a `prefer` row for the "final" file and this count drops to
        #   6,735.
        "in_scope_loans":   6_639,
        "in_scope_balance": 33_901_283.73,
        "n_strats_hits":    0,
        "duplicate_files":  0,
        # One account, 73432: capital 2,068.33 against a balance of 2,016.90,
        # EUR 51.43 over. The same shape as PT15020's three - a rebate or a
        # post-write-off credit - and far too small to be a parse error,
        # which would misread a column not a single cell.
        "capital_over_balance": 1,
    },
    "PT19007": {
        # NO SELLER FIGURE. The `Summary Reflect` tab looks like one and is
        # NOT (T25): its columns are Price %, Price LCY and Total Net Price
        # LCY -- it is BROCC'S OWN pricing sheet, carried inside the seller's
        # workbook. Its "Principal" of 4,288,865.88 is reproduced by nothing
        # on the tape; the nearest column is 1.2% away. Reconciling to it
        # would prove the buyer agrees with the buyer.
        # What IS proven: 1 per-sheet footer totals (T21).
        "in_scope_loans":   14_830,
        "in_scope_balance": 68_768_260.97,
        "n_strats_hits":    1,
        "duplicate_files":  0,
    },
    "PT20008": {
        # Published on the `TD` pivot tab: 2,905 accounts, Divida_Total
        # 5,751,844.33, Divida_Contabilistico 3,725,152.89. Both reproduced
        # exactly, with no scope filter -- all three recovery phases are in.
        # !! THIS BOOK SHIPPED TWICE (T24) and cleaned to exactly 2x both
        #   figures until the loader began deduplicating on sheet CONTENT.
        "in_scope_loans":   2_905,
        "in_scope_balance": 5_751_844.33,
        "n_strats_hits":    2,
        "duplicate_files":  0,
    },
    "PT15014": {
        # ELEVEN MONTHLY WRITE-OFF COHORTS, disjoint: 7,121 distinct accounts
        # over 7,121 rows, zero overlap on any pair of sheets. So the
        # population is their union and there is NO single published figure
        # for it -- each sheet reconciles to its own footer total instead
        # (T21), which is 20 independent proofs rather than one.
        # The `calculation` sheet prices one month at GCV 2,768,647.98 x 8.1%,
        # and WOFF_MASTER_201606 carries the same arithmetic in its own footer.
        "in_scope_loans":   7_121,
        "in_scope_balance": 27_442_668.42,
        "n_strats_hits":    20,
        "duplicate_files":  0,
    },
    "PT15016": {
        # Published in the total row at the foot of the single detail sheet
        # (T21): woff_bal 14,949,117.19 over 3,958 accounts. Before that row
        # was excluded the column summed to exactly 29,898,234.38 - twice the
        # figure - which is the signature of the trap.
        # !! 14,949,117.19 -> 14,942,413.07 on 2026-10-08, when cutoff_balance
        #   moved from `woff_bal` to `curr_bal` - what is owed now rather than
        #   the balance frozen at charge-off. The two differ on 48 of 3,958
        #   loans, where something has been recovered since.
        #   THE COST, CHOSEN DELIBERATELY: the seller published a total for
        #   woff_bal and not for curr_bal, so this deal drops from
        #   `reconciled` to `consistent`. The old figure stays reachable here
        #   so the change is legible, not silent.
        "in_scope_loans":   3_958,
        "in_scope_balance": 14_942_413.07,
        "n_strats_hits":    1,
        "duplicate_files":  0,
        # !! BOTH ACKNOWLEDGEMENTS ARE GONE, AND THAT IS THE EVIDENCE THE
        #   COLUMN CHOICE WAS RIGHT. Against `woff_bal` two loans breached
        #   capital + interest <= balance and the residual was EUR 6,704.12.
        #   Against `curr_bal` the identity is exact on all 3,958:
        #       curr_bal == sum_prin + sum_int + sum_fee
        #   with zero breaches and a residual of zero. `woff_bal` is the
        #   balance frozen at charge-off and sits ABOVE the live components
        #   wherever something has been recovered since; `curr_bal` is what is
        #   owed now, and that is what this deal measures.
    },
    "PT15020": {
        # Published in the total row at the bottom of the DETAIL sheet (T21),
        # not on a summary tab -- row 5314 of 5,318. Three figures, and they
        # also reconcile to each other: 1,339,500.46 + 511,181.84 = 1,850,682.30.
        # `Encours_contabilistico` on the OTHER sheet independently reproduces
        # the principal, which is what proves the two sheets are one export.
        "in_scope_loans":   5_313,
        "in_scope_balance": 1_850_682.30,
        "n_strats_hits":    3,
        "duplicate_files":  0,
        # !! NEGATIVE INTEREST ON 3 LOANS, so capital exceeds balance there.
        #   Not a parse error: `balance = capital + interest` holds on all
        #   5,313 loans to the cent, so these three simply carry a rebate --
        #   EUR -22.79, -0.83 and -106.95. On 101134931 the interest exactly
        #   cancels the capital and the balance is 0.00, which is what a
        #   written-back account looks like. Pinned so it stays visible.
        "capital_over_balance": 3,
    },
    "PT16023": {
        # Published in `Strats - Total`: 19,434 accounts, OB 224,485,808.25.
        # Both reproduced exactly by the detail, with NO scope filter -- unlike
        # PT15018, this tape ships only in-scope loans.
        "in_scope_loans":   19_434,
        "in_scope_balance": 224_485_808.25,
        "n_strats_hits":    8,
        # !! `COMP_OPER_PROD (Unique Loan ID)` IS NOT UNIQUE. 1,877 rows share
        #   723 ids, carrying EUR 22,713,253.39 (10.1% of the book), and the
        #   same id appears under DIFFERENT clients (`0_0_CMC` sits on both
        #   20780066 and 21758639). The row count still ties to the seller's
        #   published 19,434 exactly, so the ROWS are right and the ID is not a
        #   key. Pinned, not fixed: inventing a surrogate here would hide a
        #   fan-out that the bridge has to be told about. Open with the deal
        #   owner. If this number MOVES, the guard fails and someone looks.
        "duplicate_loan_ids": 1_151,
        "duplicate_files":  0,
    },
}
def interim_window(deal):
    """The months between the pricing cut-off and completion, FROM DATA.

    !! THIS WAS A HARDCODED LIST OF FIVE MONTHS. `WINDOW = ["2015-10", ...]`
       sat at module level in this file - a per-deal fact in code, which is
       the one thing the registry exists to prevent. It also meant the window
       was invisible to anyone reading the deal's own configuration.
       The dates now live in deals.csv, and a deal without them simply has no
       interim window rather than borrowing PT15018's.
    """
    d = pd.read_csv(_P.DEALS).query("deal_id == @deal")
    if not len(d):
        return []
    cut, comp = str(d.cutoff_date.iloc[0]), str(d.completion_date.iloc[0])
    if cut in ("nan", "") or comp in ("nan", ""):
        return []
    months, cur = [], pd.Period(cut, "M") + 1
    while cur <= pd.Period(comp, "M"):
        months.append(str(cur))
        cur += 1
    return months


def main(deal):
    # !! A DEAL WITH NO PUBLISHED FIGURE STILL GETS GUARDED. This used to
    #   `return 1` whenever EXPECT had no entry, so the eight deals that ship no
    #   strats ran ZERO checks -- the deals with the LEAST external evidence got
    #   the LEAST scrutiny, which is exactly backwards. An absent EXPECT now
    #   means only that nothing EXTERNAL can be proved; everything internal
    #   below still runs, and the deal is capped at `consistent`.
    exp = dict(EXPECT.get(deal) or {})
    unreconciled = not exp

    # !! READ THE REGISTRY AND THE STRATS RESULT, NEVER HARDCODED COLUMN NAMES.
    #   This body used to name PT15018's `Collections` sheet, `Segmento` and
    #   `Total OPB Setembro 2015 (€)` directly, which is exactly the overfitting
    #   that made deal 2 the real test. The scope rule and the balance column are
    #   DISCOVERED by find_strats.py; the guard just re-measures what it found.
    import json
    acc = pd.read_parquet(_P.ACCOUNTS / f"{deal}.parquet")
    ins = in_scope(acc)

    pay = pd.read_parquet(TAPES / "payments.parquet")
    pay = pay[pay.deal == deal].copy()
    if len(pay):
        pay["amt"] = pd.to_numeric(pay.amount, errors="coerce")

    strat = _P.STRATS / f"{deal}.json"
    hits = json.loads(strat.read_text()).get("hits", []) if strat.exists() else []
    man = pd.read_parquet(TAPES / "manifest.parquet")

    got = {
        "in_scope_loans":   len(ins),
        # !! THE FIGURE A DEAL IS MEASURED ON IS NOT ALWAYS cutoff_balance.
        #   PT15018 publishes an outstanding PRINCIPAL and no total owed, so
        #   summing cutoff_balance there returned 0.00 against a pinned
        #   407,079,317.23 - a guard failing on a deal that is perfectly fine,
        #   which is the fastest way to teach people to ignore guards.
        "in_scope_balance": round(float(headline(
            ins, set(pd.read_csv(_P.REGISTRY)
                     .query("deal_id == @deal").target_field))[1].sum()), 2),
        "payment_months":   int(pay.period_month.nunique()) if len(pay) else 0,
        "n_strats_hits":    len(hits),
        "duplicate_files":
            int(man[man.deal == deal][["path", "sheet"]].duplicated().sum())
            if "path" in man.columns else 0,
    }
    # !! DEAL-SPECIFIC GUARDS ARE ADDITIVE, NOT ALTERNATIVES. Making the body
    #   generic for PT16023, I deleted three PT15018 checks instead of making
    #   them optional -- including `interim_window`, the PAYMENTS reconciliation
    #   to the seller's published 1,569,865.11. That is a second, independent
    #   proof and losing it to tidy the code is exactly the kind of silent
    #   weakening this whole pipeline exists to prevent. A deal may always ask
    #   for MORE checks; it may never have fewer because of another deal.
    if "interim_window" in exp and len(pay):
        tape = pd.read_parquet(TAPES / f"{deal}.parquet")
        tape["cn"] = tape.column_name.map(lambda c: " ".join(str(c).split()))
        col = tape[tape.cn == "Segmento"][["source_row", "value"]].rename(
            columns={"value": "segment"})
        w = pay[pay.period_month.isin(interim_window(deal))].merge(
            col, on="source_row", how="left")
        got["interim_window"] = round(float(w.loc[w.segment != "Excluded", "amt"].sum()), 2)
    # !! THE ROLL-FORWARD: do the BALANCES and the PAYMENTS agree?
    #   A strats hit proves one total at one date. This proves something no
    #   single-date check can: that two dated snapshots and the cash between
    #   them tell the same story. PT15018 is the only tape of twelve that can
    #   support it - it ships OPB at September 2015 AND at 13-Feb-2016, with
    #   the collections for exactly that window.
    #       407,079,317.23 - 1,569,864.82 = 405,509,452.41, and the seller's
    #       own 13-Feb-2016 column reads 405,509,452.41.
    #   29 cents across EUR 405.5m, which is rounding on 32,529 loans.
    #   Proven BY HAND for weeks before this; a proof that lives in prose is
    #   a proof that stops being checked.
    if "rollforward_residual" in exp:
        tape2 = pd.read_parquet(TAPES / f"{deal}.parquet")
        tape2["cn"] = tape2.column_name.map(lambda c: " ".join(str(c).split()))
        w = tape2[tape2.source_sheet == "Collections"].pivot_table(
            index=["source_file", "source_row"], columns="cn",
            values="value", aggfunc="first")

        def _n(col):
            v = w[col].astype(str).str.strip()
            both = v.str.contains(",") & v.str.contains(r"\.")
            v = v.where(~both, v.str.replace(".", "", regex=False))
            return pd.to_numeric(v.str.replace(",", ".", regex=False),
                                 errors="coerce")

        ins2 = w[w["Segmento"].astype(str).str.strip().ne("Excluded")]
        _rf_open = float(_n("Total OPB Setembro 2015 (€)")[ins2.index].sum())
        _rf_close = float(_n("Total OPB 13-fev-2016 (€)")[ins2.index].sum())
        got["rollforward_residual"] = round(
            _rf_open - got.get("interim_window", 0.0) - _rf_close, 2)

    if "loans_without_payments" in exp and len(pay):
        got["loans_without_payments"] = int(
            (~acc.loan_id.isin(set(pay.get("acct", pd.Series(dtype=str))))).sum()
            if "acct" in pay else 0)

    for k in list(exp):
        if k not in got:
            exp.pop(k)          # genuinely not computable for this deal

    print(f"{deal} -- guard rails (scope from the strats)\n")
    bad = 0
    if unreconciled:
        print("  note  no figure published by the seller -- nothing EXTERNAL to")
        print("        reconcile against. Ceiling is `consistent`, never")
        print("        `reconciled`. The internal checks below still bind.\n")
    for k, want in exp.items():
        ok = abs(got[k] - want) < 0.01
        bad += not ok
        print(f"  {'PASS' if ok else 'FAIL'}  {k:<28} got {got[k]:>16,}   expected {want:,}")

    # ---- DATA-TYPE INTEGRITY -------------------------------------------
    # !! Every conversion defect on this book was SILENT. A wrong decimal mark
    #   nulls a whole column; a null later summed becomes 0; a long id read as a
    #   number loses its tail. None of it raises. These check the SHAPE of what
    #   came out, so a parse that fails wholesale cannot pass unnoticed.
    acc_f = _P.ACCOUNTS / f"{deal}.parquet"
    if acc_f.exists():
        a = pd.read_parquet(acc_f)
        print("\n  data-type integrity")
        # !! ONLY JUDGE COLUMNS THIS DEAL ACTUALLY MAPS. An unmapped column is
        #   null by design -- PT16023 ships no interest or origination figures --
        #   and calling that "parse failed" turns an honest gap into a red light,
        #   which is how a guard stops being believed.
        mapped = set(pd.read_csv(_P.REGISTRY)
                     .query("deal_id == @deal").target_field)
        AMOUNTS = ["cutoff_balance", "cutoff_principal", "cutoff_interest",
                   "origination_amount"]
        for c in [c for c in AMOUNTS if c in a and c in mapped]:
            v = pd.to_numeric(a[c], errors="coerce")
            filled = v.notna().sum()
            # a column that is 100% null, or 100% zero where it is filled, is a
            # failed parse wearing the costume of real data
            dead = filled == 0 or (filled and (v.fillna(0) == 0).all())
            bad += dead
            print(f"    {'FAIL' if dead else 'PASS'}  {c:<20} {filled:>7,} filled  "
                  f"{int((v == 0).sum()):>6,} zero   max {v.max():,.2f}" if filled
                  else f"    FAIL  {c:<20} ENTIRELY NULL -- parse failed")
        for c in [c for c in ("loan_id", "client_id") if c in a]:
            v = a[c].dropna().astype(str)
            # an unmapped id is null by design; printing PASS over 0 rows reads
            # as "checked and fine" when nothing was checked at all
            if v.empty:
                print(f"    note  {c:<20} entirely null -- not mapped on this deal")
                continue
            # a float artefact means the id was read as a number somewhere
            art = int(v.str.contains(r"\.0$|[eE]\+", regex=True).sum())
            bad += art > 0
            print(f"    {'FAIL' if art else 'PASS'}  {c:<20} {v.nunique():>7,} distinct  "
                  f"len {v.str.len().min()}-{v.str.len().max()}  float artefacts {art}")
        for c in [c for c in ("origination_date", "default_date", "cutoff_date") if c in a]:
            d = pd.to_datetime(a[c], errors="coerce")
            if d.notna().any():
                lo, hi = d.min().year, d.max().year
                odd = not (1900 <= lo and hi <= 2030)
                bad += odd
                print(f"    {'FAIL' if odd else 'PASS'}  {c:<20} {d.notna().sum():>7,} parsed  "
                      f"years {lo}-{hi}")
            else:
                print(f"    note  {c:<20} entirely null")

    # !! THE ROLL-FORWARD: do the BALANCES and the PAYMENTS agree?
    #   A strats hit proves one total at one date. This proves what no
    #   single-date check can: that two dated snapshots and the cash between
    #   them tell the same story. Only PT15018 of the twelve can support it -
    #   the rest have one balance date, or no payments, or both.
    #   !! AND WHEN IT CANNOT RUN IT SAYS SO. "ALL GUARDS PASS" on a deal
    #   where a check was never attempted reads as if it had been attempted.
    print("\n  roll-forward")
    if "rollforward_residual" in exp:
        print(f"    opening {_rf_open:,.2f} - collections "
              f"{got.get('interim_window', 0.0):,.2f} = "
              f"{_rf_open - got.get('interim_window', 0.0):,.2f}")
        print(f"    closing on the tape {_rf_close:,.2f}")
    else:
        print("    note  NOT POSSIBLE on this deal -- it needs TWO dated "
              "balance snapshots")
        print("          and the collections between them. This tape has one "
              "balance")
        print("          date, or no payments, or both.")

    # ---- PAYMENTS -------------------------------------------------------
    # !! THE CLEANED PAYMENTS MUST ACCOUNT FOR THE RAW ONES. Netting, keying
    #   and scoping all remove or combine rows, and every one of those steps
    #   is a chance to lose money silently - PT18019's whole EUR 10,615,169.65
    #   aggregated to zero once, because the group key was a column of nulls
    #   and pandas drops those. So the output is reconciled back to the input:
    #   gross - returns = net, and gross + what was dropped as out-of-scope
    #   equals the raw total.
    _pf = _P.PAYMENTS / f"{deal}.parquet"
    _pm = _P.PAYMENTS / f"{deal}.meta.json"
    if _pm.exists():
        import json as _pj
        pmeta = _pj.loads(_pm.read_text())
        print("\n  payments")
        if not pmeta.get("rows"):
            print("    note  this tape carries no payment columns")
        elif pmeta.get("blocked"):
            print(f"    note  NOT TIED TO THE POPULATION -- {pmeta['blocked']}")
            print("          the accounts are unaffected; no payments file written")
        elif _pf.exists():
            w = pd.read_parquet(_pf)
            # long shape: the sign IS the direction, so the net is a sum
            g = round(float(w.loc[w.payment_amount.gt(0), "payment_amount"].sum()), 2)
            r = round(float(-w.loc[w.payment_amount.lt(0), "payment_amount"].sum()), 2)
            n = round(float(w.payment_amount.sum()), 2)
            ok = abs((g - r) - n) < 0.005
            bad += not ok
            print(f"    {'PASS' if ok else 'FAIL'}  net = gross - returns   "
                  f"{g:,.2f} - {r:,.2f} = {n:,.2f}")
            # !! THE RAW NET DEPENDS ON HOW THE SELLER STORES RETURNS. Two
            #   shapes exist and they do not share an arithmetic:
            #     a separate `ret` SERIES, stored POSITIVE -- PT15014,
            #       PT15016. The raw total is then pay PLUS ret, and the net
            #       is pay MINUS ret.
            #     negative values inside the pay series -- PT18019's 18 rows.
            #       The raw total is already the net.
            #   Summing the raw column and calling it either one is wrong for
            #   the other, which is what broke when payments went long.
            raw = pd.read_parquet(TAPES / "payments.parquet")
            raw = raw[raw.deal == deal].copy()
            raw["a"] = pd.to_numeric(raw.amount, errors="coerce")
            if pmeta.get("sign_flipped"):
                raw["a"] = -raw["a"]
            if "series" in raw and raw.series.nunique() > 1:
                rt = round(float(raw.loc[raw.series.eq("pay"), "a"].sum()
                                 - raw.loc[raw.series.eq("ret"), "a"].sum()), 2)
            else:
                rt = round(float(raw["a"].sum()), 2)
            # !! THE RAW TOTAL IS GROSS **PLUS** RETURNS. Both series are
            #   stored as positive amounts on the tape; the minus sign only
            #   appears when we net them. Writing `rt - g + r` made PT15014
            #   report EUR 520.00 out of scope when the true figure is zero -
            #   it counted the returns twice and then blamed the difference on
            #   a scope filter that had dropped nothing.
            lost = round(rt - n, 2)
            print(f"    note  raw tape NET {rt:,.2f}, kept {n:,.2f}, "
                  f"out of scope {lost:,.2f}")
            # a negative row is an `out` by construction; what is worth
            # seeing is a key-month whose NET went negative
            _net = w.groupby([c for c in ("loan_id", "client_id")
                              if c in w] + ["payment_month"],
                             dropna=False).payment_amount.sum()
            neg = int((_net < -0.005).sum())
            print(f"    {'note' if neg else 'PASS'}  payment_amount >= 0     "
                  f"{neg:,} row(s) net NEGATIVE"
                  + ("  -- a refund exceeding receipts in that month"
                     if neg else ""))
            if not pmeta.get("dated"):
                print("    note  no dates on any row (T20) -- these cannot be "
                      "placed on a timeline")

    # ---- INTERNAL CONSISTENCY ------------------------------------------
    # !! THESE NEED NO PUBLISHED FIGURE, so they are the only arithmetic a deal
    #   without strats ever gets. Each one is a relationship the seller's own
    #   numbers must satisfy whatever the deal: an id identifies one loan,
    #   capital is part of the balance, a balance owed is not negative. They
    #   catch a mis-parse that leaves the output internally plausible -- which
    #   is the failure mode a totals check would have caught and here cannot.
    if acc_f.exists():
        a = pd.read_parquet(acc_f)
        reg = pd.read_csv(_P.REGISTRY).query("deal_id == @deal")
        mapped = set(reg.target_field)
        sheet = dict(zip(reg.target_field, reg.source_sheet))
        print("\n  internal consistency")

        # !! A DUPLICATE loan_id IS NOT AUTOMATICALLY A BUG -- it is a fact
        #   about the seller's id, and the fix is never to invent a key. The
        #   count is pinned in EXPECT once a human has seen it, so the defect
        #   stays visible and any CHANGE in it re-fails. Unacknowledged, it
        #   fails: an id that is not a key will fan out at the bridge.
        # !! A VACUOUS PASS IS WORSE THAN NO CHECK. With every loan_id null
        #   this printed "PASS loan_id unique 0 duplicated of 0", which reads
        #   as a clean key and means the opposite: PT20008 is anonymised and
        #   has no identifier at all.
        if a.loan_id.notna().sum() == 0:
            print("    note  loan_id unique          NO IDENTIFIER ON THIS "
                  "TAPE -- nothing to check, and nothing to bridge on")
        dup = int(a.loan_id.dropna().duplicated().sum())
        want_dup = (EXPECT.get(deal) or {}).get("duplicate_loan_ids", 0)
        ok = dup == want_dup
        bad += not ok
        note = "" if not dup else (
            f"   acknowledged (T19)" if ok else
            f"   expected {want_dup:,}")
        if a.loan_id.notna().sum():
            print(f"    {'PASS' if ok else 'FAIL'}  loan_id unique          "
                  f"{dup:,} duplicated of {a.loan_id.notna().sum():,}{note}")

        # !! ONLY COMPARABLE WHEN BOTH COME FROM THE SAME SHEET. On PT15018
        #   `cutoff_principal` is Claims.Capital and `cutoff_balance` is
        #   Collections."Total OPB Setembro 2015", two sheets that are already
        #   documented as disagreeing (673 shared loans, 2 of them agree). This
        #   check flagged 43 loans there and every one was the known sheet
        #   disagreement, not a defect -- a guard that fires on a thing it
        #   cannot judge teaches people to ignore it.
        if {"cutoff_balance", "cutoff_principal"} <= mapped:
            same = sheet.get("cutoff_balance") == sheet.get("cutoff_principal")
            if not same:
                print(f"    note  capital <= balance      not comparable -- "
                      f"capital is from `{sheet.get('cutoff_principal')}`, "
                      f"balance from `{sheet.get('cutoff_balance')}`")
            else:
                b = pd.to_numeric(a.cutoff_balance, errors="coerce")
                k = pd.to_numeric(a.cutoff_principal, errors="coerce")
                # a cent absorbs rounding, not a swapped pair of columns
                over = int((k > b + 0.01).sum())
                # acknowledged like the duplicate ids: a count a human has
                # seen and ruled on, so the fact stays visible and any CHANGE
                # in it re-fails
                want_over = (EXPECT.get(deal) or {}).get("capital_over_balance", 0)
                ok = over == want_over
                bad += not ok
                print(f"    {'PASS' if ok else 'FAIL'}  capital <= balance      "
                      f"{over:,} loans breach it"
                      + (f"   worst {float((k - b).max()):,.2f}" if over else "")
                      + ("   acknowledged" if over and ok else
                         f"   expected {want_over:,}" if not ok else ""))

        # !! THE PARTS MAY NOT EXCEED THE WHOLE. The first version of this
        #   asserted balance == capital + interest, which is true of PT15020
        #   to the cent on all 5,313 loans - and false of PT15016, whose
        #   balance is principal + interest + FEES and whose fee column the
        #   schema has no home for. Asserting an identity that only some
        #   sellers satisfy would have failed 3,958 correct loans.
        #   What holds for EVERY seller is the inequality: the named
        #   components cannot sum to more than the total. The residual is
        #   printed rather than judged, because what it contains - fees,
        #   costs, nothing - is a question for the reviewer, and a residual of
        #   exactly zero is the strongest evidence the columns mean what they
        #   say.
        # Superseded by `parts <= balance` below once a deal maps
        # cutoff_other_fee: with the fee mapped this one reports it as an
        # unexplained residual, which reads like a problem and is not one.
        if {"cutoff_balance", "cutoff_principal", "cutoff_interest"} <= mapped and \
                "cutoff_other_fee" not in mapped and \
                len({sheet.get(x) for x in ("cutoff_balance", "cutoff_principal",
                                            "cutoff_interest")}) == 1:
            b = pd.to_numeric(a.cutoff_balance, errors="coerce")
            k = pd.to_numeric(a.cutoff_principal, errors="coerce")
            i = pd.to_numeric(a.cutoff_interest, errors="coerce")
            # !! AN ABSENT COLUMN IS NOT A ZERO RESIDUAL. With cutoff_interest
            #   entirely NULL this printed "residual exactly zero -- balance IS
            #   capital + interest", because a NaN residual sums to 0.0. The
            #   guard was reporting a perfect identity over a column that had
            #   failed to parse at all.
            if not (b.notna().any() and k.notna().any() and i.notna().any()):
                print("    note  capital+int <= balance  not comparable -- "
                      "one of the three is entirely null")
                resid = None
            else:
                resid = b - k - i
            if resid is not None:
                over = int(resid.lt(-0.005).sum())
                want_c = (EXPECT.get(deal) or {}).get("components_over_balance", 0)
                okc = over == want_c
                bad += not okc
                tot = float(resid.sum())
                how = ("exactly zero -- balance IS capital + interest"
                       if abs(tot) < 0.005 else
                       f"EUR {tot:,.2f} unexplained (fees? costs? ask)")
                print(f"    {'PASS' if okc else 'FAIL'}  capital+int <= balance  "
                      f"{over:,} loans breach it"
                      + ("   acknowledged" if over and okc else
                         f"   expected {want_c:,}" if not okc else "")
                      + f"   residual {how}")

        # !! A LOAN CANNOT DEFAULT BEFORE IT EXISTS. This holds on every one of
        #   the 63,000-odd loans that carry both dates, across four sellers and
        #   twelve books - which is what makes it worth asserting rather than
        #   merely observing. The single exception is PT15018's 1232400533,
        #   dated 2007-04-10 against an origination of 2007-05-10. One loan,
        #   30 days, and it is the seller's error not a parse error: both dates
        #   read cleanly. Pinned per deal, so it stays visible and any CHANGE
        #   in the count re-fails.
        if {"origination_date", "default_date"} <= mapped:
            _o = pd.to_datetime(a.origination_date, errors="coerce")
            _x = pd.to_datetime(a.default_date, errors="coerce")
            _both = _o.notna() & _x.notna()
            _bad = int((_both & (_x < _o)).sum())
            _want = (EXPECT.get(deal) or {}).get("default_before_origination", 0)
            _ok = _bad == _want
            bad += not _ok
            print(f"    {'PASS' if _ok else 'FAIL'}  default >= origination  "
                  f"{_bad:,} of {int(_both.sum()):,} loans default BEFORE they "
                  f"were originated"
                  + ("   acknowledged" if _bad and _ok else
                     f"   expected {_want:,}" if not _ok else ""))

        # !! THE THREE OUTPUTS MUST JOIN ON EVERY DEAL, BY RULE NOT BY LUCK.
        #   accounts <-> additional_attributes is safe by construction:
        #   unique_key is ours and never null. Payments are the exposed
        #   one - they key on whichever id the SELLER used, so a deal can
        #   map payments on `client_id` while its accounts carry none, and
        #   nothing would notice until somebody tried to join.
        _pf = _P.PAYMENTS / f"{deal}.parquet"
        if _pf.exists():
            _pw = pd.read_parquet(_pf)
            _g = str(_pw.grain.dropna().iloc[0]) if "grain" in _pw else None
            _have = (_g in a.columns and a[_g].notna().any())
            bad += not _have
            _n = int(a[_g].nunique()) if _have else 0
            _m = int(_pw[_g].isin(a[_g]).sum()) if _have else 0
            print(f"    {'PASS' if _have else 'FAIL'}  payments join           "
                  + (f"grain `{_g}`: {_n:,} in accounts, "
                     f"{_m:,} of {len(_pw):,} payment row(s) match"
                     if _have else
                     f"payments key on `{_g}` but accounts carry none - "
                     f"these two outputs CANNOT be joined"))
        # !! ALSO: the long table must always be joinable on unique_key.
        _af = _P.ADDITIONAL / f"{deal}.parquet"
        if _af.exists():
            _aw = pd.read_parquet(_af)
            _orph = int((~_aw.unique_key.isin(a.unique_key)).sum())
            bad += _orph > 0
            print(f"    {'PASS' if not _orph else 'FAIL'}  attributes join         "
                  f"{_orph:,} attribute row(s) with no matching unique_key")

        # !! NOT STATED MEANS NULL. NEVER A PLUG, NEVER A ZERO.
        #   All four cut-off amounts - balance, principal, interest, other fee
        #   - carry only what the seller wrote. None is ever computed from the
        #   others, and the temptation runs in every direction: balance as
        #   principal + interest, interest as balance - principal, other fee
        #   as whatever is left over. Five of the thirteen deals have an
        #   unexplained residual between balance and principal - PT18019 alone
        #   is EUR 23,782,613.02 - and every one of those is correctly NULL
        #   rather than filled.
        #   A derived figure is indistinguishable from a stated one once it
        #   sits in the column, and this benchmark exists to say what the
        #   SELLER said. The test is total: a value may not exist where the
        #   registry maps nothing.
        _cut = ["cutoff_balance", "cutoff_principal", "cutoff_interest",
                "cutoff_other_fee"]
        _plug = [(c, int(pd.to_numeric(a[c], errors="coerce").notna().sum()))
                 for c in _cut
                 if c in a.columns and c not in mapped
                 and pd.to_numeric(a[c], errors="coerce").notna().any()]
        bad += bool(_plug)
        print(f"    {'PASS' if not _plug else 'FAIL'}  nothing is filled in    "
              + ("no cut-off amount carries a value the tape did not state"
                 if not _plug else
                 "; ".join(f"{c} has {n:,} value(s) but is NOT MAPPED"
                           for c, n in _plug)))

        # !! PRINCIPAL + INTEREST + OTHER FEE MAY NOT EXCEED THE BALANCE.
        #   The pair check above runs only where interest is mapped and only
        #   on the two components the schema had. `cutoff_other_fee` is the
        #   third: court costs, collection fees, VAT, penalties - everything
        #   owed that is neither principal nor interest. Once a seller states
        #   it, the three named parts should account for the whole, and a
        #   residual of exactly zero is the strongest evidence the columns
        #   mean what they say.
        #   Still an INEQUALITY, never an identity: a seller may state some
        #   costs and not others, so parts < whole is normal and parts > whole
        #   is a defect. Whatever is absent contributes nothing, and a field
        #   nobody mapped is skipped rather than read as zero (T6).
        _parts = [c for c in ("cutoff_principal", "cutoff_interest",
                              "cutoff_other_fee") if c in mapped]
        if "cutoff_balance" in mapped and len(_parts) >= 2 and \
                len({sheet.get(x) for x in _parts + ["cutoff_balance"]}) == 1:
            _b = pd.to_numeric(a.cutoff_balance, errors="coerce")
            _have = [c for c in _parts
                     if pd.to_numeric(a[c], errors="coerce").notna().any()]
            if not _b.notna().any() or len(_have) < 2:
                print(f"    note  parts <= balance       not comparable -- "
                      f"{len(_have)} of {len(_parts)} component(s) carry a value")
            else:
                _sum = sum(pd.to_numeric(a[c], errors="coerce").fillna(0)
                           for c in _have)
                _r = _b - _sum
                _over = int(_r.lt(-0.005).sum())
                _want = (EXPECT.get(deal) or {}).get("parts_over_balance", 0)
                _ok = _over == _want
                bad += not _ok
                _tot = float(_r.sum())
                print(f"    {'PASS' if _ok else 'FAIL'}  parts <= balance        "
                      f"{_over:,} loan(s) where "
                      f"{' + '.join(c.replace('cutoff_', '') for c in _have)}"
                      f" EXCEEDS balance"
                      + ("   acknowledged" if _over and _ok else
                         f"   expected {_want:,}" if not _ok else "")
                      + (f"   residual exactly zero -- the parts ARE the whole"
                         if abs(_tot) < 0.005 else
                         f"   residual EUR {_tot:,.2f} unexplained"))

        # !! A PERIOD CANNOT END BEFORE IT BEGINS, and when one does the cause
        #   is almost never the seller. These pairs live in
        #   additional_attributes, and they got there by being rolled up to the
        #   loan - so the first version of PT15018's court dates reported 316
        #   loans ending before they started while the seller's own sheet had
        #   zero such rows out of 1,103. Each date was individually the max of
        #   a real proceeding; together they described one that never existed.
        #   Any start/end pair in the long table is checked, so a new pair on a
        #   new deal is covered the day it is mapped and nobody has to remember.
        _att = _P.ADDITIONAL / f"{deal}.parquet"
        if _att.exists():
            _t = pd.read_parquet(_att)
            _w = _t.pivot_table(index="unique_key", columns="column_name",
                                values="column_value", aggfunc="first")
            for _st in [c for c in _w.columns if c.endswith("_start_date")]:
                _en = _st[:-len("_start_date")] + "_end_date"
                if _en not in _w.columns:
                    continue
                _a1 = pd.to_datetime(_w[_st], errors="coerce")
                _a2 = pd.to_datetime(_w[_en], errors="coerce")
                _pair = _a1.notna() & _a2.notna()
                _cross = int((_pair & (_a2 < _a1)).sum())
                bad += _cross > 0
                print(f"    {'PASS' if not _cross else 'FAIL'}  "
                      f"{_st[:-11]} end >= start  {_cross:,} of "
                      f"{int(_pair.sum()):,} loan(s) END BEFORE THEY BEGIN")

        for c in [c for c in ("cutoff_balance", "cutoff_principal") if c in mapped]:
            v = pd.to_numeric(a[c], errors="coerce")
            neg = int((v < 0).sum())
            # negative is not automatically wrong (a credit balance is real), so
            # this WARNS and does not fail -- it exists to be noticed and ruled on
            print(f"    {'note' if neg else 'PASS'}  {c + ' >= 0':<22}  "
                  f"{neg:,} negative")

    if acc_f.exists():
        acc = pd.read_parquet(acc_f)
        _j = attr_series(BASE, deal, "judicialised_flag")
        unknown = int(len(acc) - len(_j))
        _dl = attr_series(BASE, deal, "detail_level")
        print(f"\n  note  accounts file holds {len(acc):,} rows "
              f"({int(_dl.eq('full').sum()):,} full detail)")
        print(f"  note  judicialised NOT STATED on {unknown:,} of {len(acc):,}"
              f" -- absence is NOT 'not judicialised'")
    print(f"\n{'ALL GUARDS PASS' if not bad else str(bad) + ' GUARD(S) FAILED'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "PT15018"))
