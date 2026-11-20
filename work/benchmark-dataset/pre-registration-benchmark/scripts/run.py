"""The pre-registration cleaning sequence, start to finish, for one deal.

    uv run python scripts/run.py PT16023            # run every step it can
    uv run python scripts/run.py PT16023 --status   # where is this deal up to?

THE SEQUENCE LIVES HERE, NOT IN SOMEONE'S HEAD. Every step, its order, and what
blocks what. An agent invokes this; it does not reimplement it. That is the whole
point -- a sequence remembered is a sequence that drifts.

Each step is one of:
    AUTO    deterministic, runs now, no tokens
    AGENT   needs judgement -- run.py STOPS and says what is needed
    USER    needs you -- run.py STOPS and says what to decide

Stopping is a feature. A step that cannot run deterministically must not be
guessed past; it hands back with a specific ask.
"""
import json
import subprocess
import sys
from pathlib import Path

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent


def sh(script, deal):
    r = subprocess.run([sys.executable, str(HERE / script), deal],
                       capture_output=True, text=True)
    return r.returncode, (r.stdout or r.stderr).strip()


def step(n, kind, name):
    print(f"\n{'-'*72}\n{n}  [{kind}]  {name}\n{'-'*72}")


def main(deal, status_only=False, anyway=False):
    # !! A FORWARD FLOW IS NOT A BOOK, SO IT IS NOT CLEANED.
    #   The tape is one delivery under a monthly contract, never the deal, so
    #   a total taken from it is a total of what arrived - and there is no
    #   figure a reviewer could approve as "this deal". Cleaning it produces
    #   an output that looks exactly like a one-off's and means something
    #   else, which is the most expensive kind of wrong.
    #   Skipped BEFORE anything is written: no strats, no accounts, no long
    #   table, no payments, no review, no backtest baseline. Ruled by
    #   sharlene 2026-10-13.
    #   `--anyway` still runs one, for when somebody needs to look.
    import pandas as _pd
    if _P.DEALS.exists() and not anyway:
        _d = _pd.read_csv(_P.DEALS)
        _r = _d[_d.deal_id == deal]
        if len(_r) and "deal_type" in _d.columns and \
                str(_r.deal_type.iloc[0]) == "forward_flow":
            print(f"\n  SKIPPED -- {deal} is a FORWARD FLOW.")
            print("  Intrum bought it in monthly tranches, so this tape is a "
                  "delivery and not")
            print("  the book. Nothing is cleaned, nothing is written, and "
                  "there is no figure")
            print("  to approve. See portugal/CONTEXT.md and T73.")
            print(f"  To look at it anyway:  scripts/run.py {deal} --anyway")
            return 0

    mapped = False
    mf = _P.REGISTRY
    if mf.exists():
        mapped = deal in mf.read_text()

    step("1", "AUTO", "find the seller's own published figure")
    rc, out = sh("find_strats.py", deal)
    print(out)
    strat = _P.STRATS / f"{deal}.json"
    hits = json.loads(strat.read_text()).get("hits") if strat.exists() else []

    step("2b", "AUTO", "detect known traps in the raw tape")
    print(sh("detectors.py", deal)[1])

    # !! ASK WHETHER THE BOOK IS EVEN COMPLETE BEFORE MAPPING IT. PT15014's
    #   April 2016 tranche sat password protected and unread for a week, and
    #   the only record was a misleading string in a manifest column nothing
    #   displayed. A missing file is a missing POPULATION - everything built
    #   on top of it tallies perfectly and is short by a tranche. This STOPS
    #   the run, because the fix is an email to the seller, not a mapping.
    step("2c", "AUTO", "is there enough here to map DEFINITELY?")
    rc_r, out_r = sh("readiness.py", deal)
    print(out_r)
    if rc_r >= 2:
        print("  STOP -- the book is incomplete. Mapping it now would produce")
        print("  a clean output that is silently missing loans. Resolve the")
        print("  BLOCKER above, or record the decision to proceed without it.")
        return 2

    step("2", "AUTO", "find a data dictionary")
    print(sh("find_dictionary.py", deal)[1])


    step("3", "USER", "review the strats hits")
    if hits:
        print("  Decide, before any mapping is written:")
        for h in hits:
            scope = (f"{h['scope_column']} != {h['scope_excludes']!r}"
                     if h.get("scope_column") else "(no filter)")
            print(f"    {h['amount_column'][:40]:<42} {scope:<28} {h['total']:>16,.2f}")
        print("  -> is this the QUANTITY you want, and the right scope rule?")
        print("    The arithmetic is PROVEN. The meaning is not.")
    else:
        print("  no published figure found -- this deal can reach `consistent`,")
        print("  never `reconciled`. Decide whether that is acceptable for it.")

    step("4", "AGENT", "map the tape's columns to schema.yaml")
    if not mapped:
        print(f"  STOP -- no mappings.csv rows for {deal}.")
        print("  The agent writes registry rows naming this seller's columns:")
        print("     base enrich party align scope prefer grain -- see METHOD.md")
        print("  columns. It writes NO code. Then re-run this.")
        return 2
    print(f"  mappings present for {deal} -- continuing")

    # !! BUILD BEFORE YOU ASK ANYONE TO SIGN. The review used to run at step
    #    5, BEFORE the clean at step 6, and then block on NOT APPROVED -- so on
    #    an unapproved deal (which is every deal until someone signs it) the
    #    sheet described the PREVIOUS output and the clean never ran at all.
    #    Change a mapping, re-run, and you would read a review of the old
    #    numbers while believing it was the new ones. A reviewer must be shown
    #    the artefact that exists, not the one that existed last time.
    for n, (kind, name, script) in enumerate(
            [("AUTO", "clean the accounts", "clean_accounts.py"),
             ("AUTO", "clean the payments", "clean_payments.py"),
             ("AUTO", "guard", "guards.py"),
             ("AUTO", "summarise", "summarise.py")], start=5):
        step(str(n), kind, name)
        rc, out = sh(script, deal)
        print(out)
        if rc:
            print(f"\n  STOP -- {script} failed. Nothing downstream is written,")
            print("  and NOTHING is put in front of a reviewer to sign.")
            print("  If no detector explains this, it is NEW: escalate it.")
            return 1

    step("9", "AUTO", "write the approval sheet for what was just built")
    print(sh("review.py", deal)[1])

    step("10", "USER", "read it and decide")
    # !! BLOCK, DO NOT PRINT AND CARRY ON. This step used to say "a human should
    #    look" and then continue regardless, which is how two deals were cleaned,
    #    guarded and summarised with nobody having checked a single JUDGEMENT
    #    mapping. A review step that cannot stop the run is a comment.
    import yaml
    dec_f = _P.CONTEXT / deal / "decisions.yaml"
    dec = yaml.safe_load(dec_f.read_text()) if dec_f.exists() else {}
    if dec.get("open_rejections"):
        print(f"\n  STOP -- {len(dec['open_rejections'])} open rejection(s):")
        for r in dec["open_rejections"]:
            print(f"      `{r['field']}` -- {str(r['reason'])[:68]}")
        print(f"  Fix the mapping, re-run, then: review.py {deal} --resolve <field>")
        return 3
    # !! A STALE APPROVAL IS NOT AN APPROVAL. This gate used to read the
    #   `approved` boolean and nothing else, so a deal signed last week and
    #   re-cleaned today sailed through to "sequence complete" with a green
    #   exit code - the one outcome the whole review exists to prevent. The
    #   signature pins the OUTPUT; if the output has moved, the signature is
    #   about a different book.
    if dec.get("approved"):
        import style as _st
        _now = _st.output_fingerprint(deal)
        if dec.get("approved_output_md5") and dec["approved_output_md5"] != _now:
            print(f"\n  STOP -- {deal}'s APPROVAL IS STALE.")
            print(f"  Signed by {dec.get('reviewed_by','?')} on "
                  f"{dec.get('reviewed_at','?')}, but the output has changed "
                  f"since:")
            print(f"      signed  {str(dec['approved_output_md5'])[:12]}")
            print(f"      current {str(_now)[:12]}")
            print(f"  Read cleaning-context/{deal}/REVIEW.md again, then:")
            print(f"      uv run python scripts/review.py {deal} --approve")
            return 3
    if not dec.get("approved"):
        print(f"\n  STOP -- {deal} is NOT APPROVED.")
        print(f"  Read cleaning-context/{deal}/REVIEW.md, then:")
        print(f"      uv run python scripts/review.py {deal} --approve")
        print("  The deal is cleaned, guarded and summarised; it is simply not")
        print("  signed off, and nothing downstream may treat it as checked.")
        return 3

    step("11", "AUTO", "backtest -- did any OTHER deal move?")
    rc, out = sh("backtest.py", deal)
    print(out)

    step("12", "AGENT", "record the learning")
    print(f"  cleaning-context/{deal}/CONTEXT.md -- the judgement calls")
    print("  traps.yaml -- any NEW failure mode, with a detector where possible,")
    print("  so the next deal is TOLD rather than having to discover it.")
    print(f"\n{'='*72}\n{deal}: sequence complete.\n{'='*72}")
    return 0


if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    sys.exit(main(a[0] if a else "PT15018", "--status" in sys.argv,
                  "--anyway" in sys.argv))
