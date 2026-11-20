"""Prove a change to the base did not move any deal that was already clean.

    uv run python scripts/backtest.py --snapshot   # freeze today's output as the baseline
    uv run python scripts/backtest.py              # re-run every deal, diff against it

Exit 0 = nothing moved. Exit 1 = something did, and it names what.

WHY THIS EXISTS: the base is shared. A new transform, a widened detector, a fix
for deal 7 -- any of them can silently change deal 3. Today alone, three separate
"improvements" each silently dropped a population:

    anchoring on the detailed sheet      lost 31,000 loans
    anchoring on the tallying sheet      lost 882 loans, EUR 15.4m
    a numeric-only loan_id filter        lost 107 loans, EUR 1,673,770.57

None raised an error. A backtest is the only thing that catches that class of
change, and it is cheap: ~1.2s per deal.

!! A DIFF IS NOT AUTOMATICALLY A BUG. If you deliberately fixed something, the
  baseline is stale -- read the diff, confirm it is what you intended, then
  re-snapshot. Never re-snapshot to make a failure go away without reading it.

PROMOTION GATE: a trap may only be promoted to a detector or a guard when this
is green. That is what makes the trap list safe to grow.
"""
import sys
from pathlib import Path
import json
import pandas as pd

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
ACC = _P.ACCOUNTS
TAPES_DIR = _P.TAPES
SNAP = _P.BASELINE

# What a deal's output is, as CONTENT -- not as aggregates.
#
# !! SUMS AND COUNTS ARE NOT ENOUGH. Two runs can agree on every total while
#   individual rows differ: move EUR 100 from one loan to another and the sum,
#   the row count and the fill count are all unchanged. Only a hash of the actual
#   values proves the content is identical.
#
#   So each column is hashed over its VALUES, in row order. A column whose hash
#   matches has not changed in any row. Aggregates are kept alongside purely so a
#   failure is readable -- the hash says THAT something moved, the sum helps say
#   what.
import yaml as _yaml
TYPES = {c["name"]: c["type"] for c in
         _yaml.safe_load((_P.SCHEMA).read_text())["columns"]}


def inputs_fingerprint(deal):
    """The TAPE this deal was cleaned from, pinned by content.

    !! A CLEANED DEAL IS FROZEN. The seller's files never change, so the output
      should never change either -- any movement is a bug BY DEFINITION, not a
      judgement call. That is only true if we can prove the input is the same
      file, so the raw tape is hashed here.

      tape unchanged + output moved  ->  a shared change leaked into a frozen
                                         deal. This is the bug the backtest exists
                                         to catch.
      tape changed   + output moved  ->  legitimate. A new delivery arrived, and
                                         the deal must be re-verified from scratch
                                         rather than compared to a stale baseline.

    Without this the two cases are indistinguishable, and the second one quietly
    looks like the first.
    """
    import hashlib
    f = TAPES_DIR / f"{deal}.parquet"
    if not f.exists():
        return {"input:tape": "missing"}
    out = {"input:tape_md5": hashlib.md5(f.read_bytes()).hexdigest()}

    # !! PAYMENTS ARE AN INPUT TOO, AND THIS USED TO MISS THEM. Widening the
    #   loader's payment-column regex added 95,097 rows of post-cutoff
    #   collections to PT18019 -- EUR 2,359,907.66 that had been dropped
    #   silently -- and the backtest still reported "byte-for-byte unchanged",
    #   which was true of accounts and blind to the half that moved.
    #   Hash this DEAL'S SLICE, not the shared file: the file is rewritten
    #   whenever ANY deal reloads, and a fingerprint that moves for every deal
    #   on every reload tells you nothing.
    pf = _P.PAYMENTS_RAW
    if pf.exists():
        q = pd.read_parquet(pf)
        q = q[q.deal == deal]
        out["input:payment_rows"] = len(q)
        if len(q):
            cols = [c for c in ("acct", "period", "amount", "series")
                    if c in q.columns]
            b = q.sort_values(cols)[cols].astype(str).to_csv(index=False)
            out["input:payments_md5"] = hashlib.md5(b.encode()).hexdigest()
    return out


def strats_fingerprint(deal):
    """The reconciliation evidence, pinned.

    !! THE OUTPUT IS NOT THE ONLY THING A CHANGE CAN MOVE. `verification_status`
      is derived from these hits, so a tweak to find_strats.py's thresholds can
      flip a deal from `reconciled` to `consistent` while every accounts value
      stays identical. Those thresholds changed four times in one afternoon
      (MIN_CANDIDATE, MAX_CANDIDATES, MIN_SHARE) and each time the hits moved.

    !! A DEAL CAN PUBLISH SEVERAL CUTS OF THE SAME BOOK. PT16023 states its
      totals by sub-portfolio, by ticket range and by default year, so several
      hits are expected and are not duplicates -- each is an independent check.
      Every hit is pinned, not just the first, because LOSING one is a weakening
      of the evidence even when the headline total still reconciles.
    """
    f = _P.STRATS / f"{deal}.json"
    if not f.exists():
        # !! AN ABSENT FILE IS NOT AN ABSENT SEARCH. find_strats stopped
        #   writing a per-deal file when it found nothing (T74), so PT17013
        #   and PT18019 -- scanned, 126 and 2,240 combinations, no published
        #   figure -- lost their file and the backtest called that a
        #   REGRESSION. The index is where the finding lives now, so read it.
        #   A deal missing from the index too is genuinely unscanned, and
        #   that IS a regression worth shouting about.
        idx = _P.STRATS / "_scanned.json"
        log = json.loads(idx.read_text()) if idx.exists() else {}
        if deal in log:
            return {"strats:status": log[deal].get(
                        "status", "no_external_figure_found"),
                    "strats:n_hits": int(log[deal].get("found", 0))}
        return {"strats:status": "never scanned", "strats:n_hits": None}
    d = json.loads(f.read_text())
    hits = d.get("hits", [])
    fp = {"strats:status": d.get("status", "?"), "strats:n_hits": len(hits)}
    for h in sorted(hits, key=lambda x: (x.get("amount_column", ""), x.get("total", 0))):
        k = f"{h.get('amount_column')}|{h.get('scope_column')}!={h.get('scope_excludes')}"
        fp[f"strats:{k}"] = h.get("total")
    return fp


def payments_fingerprint(deal):
    """The CLEANED payments, so a change to the netting cannot pass unnoticed.

    !! THE BACKTEST TRACKED ONLY THE ACCOUNTS. Payments are a second output
       built by a second script, and nothing watched it - so a change to how
       `pay - ret` is netted, or to how the key is chosen, would have moved
       real money with the backtest still reporting green.
    """
    f = ACC.parent / "payments" / f"{deal}.parquet"
    if not f.exists():
        return {}
    w = pd.read_parquet(f)
    out = {"pay:rows": len(w)}
    if "payment_amount" in w:
        out["pay:sum:net"] = round(float(w.payment_amount.sum()), 2)
        out["pay:sum:in"] = round(float(
            w.loc[w.payment_amount.gt(0), "payment_amount"].sum()), 2)
        out["pay:sum:out"] = round(float(
            w.loc[w.payment_amount.lt(0), "payment_amount"].sum()), 2)
    # !! THE GRAIN IS A COLUMN NOW, NOT WHICHEVER ID HAPPENS TO BE PRESENT.
    #   This took the first of loan_id/client_id that existed. Once the
    #   payments contract gave every file BOTH columns, that was always
    #   loan_id - so PT15018 and PT16023, whose payments are keyed on the
    #   BORROWER, reported grain `loan_id` and 0 keys. The fingerprint was
    #   describing the wrong column and calling a correct file a regression.
    if "grain" in w and w.grain.notna().any():
        _g = str(w.grain.dropna().iloc[0])
        out["pay:keys"] = int(w[_g].nunique()) if _g in w else 0
        out["pay:grain"] = _g
    else:
        g = [c for c in ("loan_id", "client_id") if c in w and w[c].notna().any()]
        if g:
            out["pay:keys"] = int(w[g[0]].nunique())
            out["pay:grain"] = g[0]
    out["pay:months"] = int(w.payment_month.nunique()) if "payment_month" in w else 0
    return out


def fingerprint(deal):
    a = pd.read_parquet(ACC / f"{deal}.parquet")
    # a stable row order, so the hash is about content and not about ordering
    key = [c for c in ("deal_id", "loan_id", "client_id") if c in a.columns]
    a = a.sort_values(key, na_position="last").reset_index(drop=True) if key else a

    fp = {"rows": len(a), "columns": len(a.columns)}
    fp.update(payments_fingerprint(deal))
    # !! THE LONG TABLE IS AN OUTPUT TOO. Everything outside the fixed core
    #   lives there now, so a backtest that watches only `accounts` would miss
    #   a change to insolvency, claims or anything else a seller ships. Per
    #   attribute: how many loans carry it, and the content, so an offsetting
    #   change cannot hide behind a stable count.
    _af = _P.ADDITIONAL / f"{deal}.parquet"
    if _af.exists():
        t = pd.read_parquet(_af)
        fp["attr:rows"] = len(t)
        for name, g in t.groupby("column_name"):
            fp[f"attr:n:{name}"] = len(g)
            fp[f"attr:hash:{name}"] = int(pd.util.hash_pandas_object(
                g.sort_values("loan_id", na_position="last")
                 .column_value.astype(str), index=False).sum())
    for c in a.columns:
        # CONTENT: every value, in order, reduced to one number
        fp[f"hash:{c}"] = int(pd.util.hash_pandas_object(
            a[c].astype("string"), index=False).sum())
        fp[f"filled:{c}"] = int(a[c].notna().sum())
        if TYPES.get(c) == "numeric":
            fp[f"sum:{c}"] = round(float(pd.to_numeric(a[c], errors="coerce").sum()), 2)
    fp.update(strats_fingerprint(deal))
    fp.update(inputs_fingerprint(deal))
    return fp


def main(snapshot=False):
    deals = sorted(p.stem for p in ACC.glob("*.parquet"))
    if not deals:
        print("no cleaned deals yet -- nothing to backtest")
        return 0
    SNAP.mkdir(parents=True, exist_ok=True)

    if snapshot:
        for d in deals:
            # !! AS TEXT, NEVER AS JSON NUMBERS. These hashes are 19 digits; JSON
            #   stores them as floats and the last four digits are rounded away,
            #   so a fingerprint silently stops matching itself. The same float
            #   trap has now bitten three times today -- account numbers, id sums,
            #   and here. Any value over ~15 digits is text or it is wrong.
            (SNAP / f"{d}.json").write_text(json.dumps(
                {k: str(v) for k, v in fingerprint(d).items()}, indent=1))
        print(f"baseline frozen for {len(deals)} deal(s): {', '.join(deals)}")
        return 0

    bad = 0
    for d in deals:
        f = SNAP / f"{d}.json"
        if not f.exists():
            print(f"  NEW   {d} -- no baseline. Snapshot it once you trust it.")
            continue
        old = json.loads(f.read_text())
        new = {k: str(v) for k, v in fingerprint(d).items()}
        keys = sorted(set(old) | set(new))
        moved = [(k, old.get(k), new.get(k)) for k in keys if old.get(k) != new.get(k)]
        if not moved:
            print(f"  OK        {d} -- byte-for-byte unchanged")
            continue

        # !! ADDING A FIELD IS NOT THE SAME AS CHANGING ONE, and the difference is
        #   the whole question. A new column appears as keys that did not exist in
        #   the baseline, plus the column COUNT. Anything else is an existing
        #   value that MOVED -- a regression until proven otherwise.
        new_cols = {k.split(":", 1)[1] for k, o, n in moved
                    if ":" in k and o is None and n is not None}

        # !! FILLING A COLUMN THAT WAS ENTIRELY NULL IS NOT A REGRESSION. Adding a
        #   schema field creates it empty; mapping it later populates it. Both are
        #   intended, and calling the second one REGRESSED trains people to
        #   re-snapshot past red -- which is how a real regression gets waved
        #   through. A column going 0 -> N filled, with nothing else moving, is
        #   ENRICHED.
        enriched = {k.split(":", 1)[1] for k, o, n in moved
                    if k.startswith("filled:") and str(o) == "0" and str(n) != "0"}
        enriched = {c for c in enriched
                    if not any(m[0] == f"sum:{c}" and str(m[1]) not in ("0", "0.0")
                               for m in moved)}
        additive = [m for m in moved
                    if (":" in m[0] and m[0].split(":", 1)[1] in (new_cols | enriched))
                    or m[0] == "columns"]
        regress = [m for m in moved if m not in additive]

        tape_moved = any(k.startswith("input:") for k, _, _ in moved)
        if regress and tape_moved:
            bad += 1
            print(f"  INPUT CHANGED {d} -- an INPUT is different "
                  f"({', '.join(sorted(k for k, _, _ in moved if k.startswith('input:')))}).")
            print(f"            A new delivery arrived. Do NOT compare to the old")
            print(f"            baseline -- re-verify the deal from scratch.")
        elif regress:
            bad += 1
            print(f"  REGRESSED {d} -- tape unchanged, but {len(regress)} value(s) moved:")
            for k, o, n in regress[:8]:
                print(f"            {k:<34} {o}  ->  {n}")
            if additive:
                print(f"            (plus {len(new_cols)} new column(s), which is fine)")
        else:
            what = []
            if new_cols:
                what.append(f"new: {', '.join(sorted(new_cols))}")
            if enriched:
                what.append(f"newly populated: {', '.join(sorted(enriched))}")
            print(f"  ADDITIVE  {d} -- {'; '.join(what)}")
            print(f"            every PREVIOUSLY POPULATED value unchanged. "
                  f"Safe to re-snapshot.")
    print(f"\n{'BACKTEST GREEN -- no existing value moved' if not bad else f'{bad} DEAL(S) REGRESSED -- read the diff before re-snapshotting'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main("--snapshot" in sys.argv))
