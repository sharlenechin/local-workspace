"""Generate the approval sheet for a deal, and record the decision.

    uv run python scripts/review.py PT16023                       # show what needs approving
    uv run python scripts/review.py PT16023 --approve              # all of it is right
    uv run python scripts/review.py PT16023 --reject default_date "Data Vencido is
        when the CLAIM fell due, not when the loan defaulted"      # one row is wrong

REJECTING IS THE NORMAL CASE, not a failure. You reject ONE FIELD with a reason;
the deal stays unapproved, the reason goes to the agent, and nothing downstream
treats the deal as checked. Rejections accumulate until they are resolved -- so
a deal with three open rejections cannot be quietly approved by someone who only
looked at one of them.

Writes cleaning-context/<deal>/REVIEW.md -- what you look at -- and, on approval,
decisions.yaml, which is what the pipeline reads so you are never asked twice.

WHY THIS EXISTS: guards catch mechanical wrongness. They cannot catch SEMANTIC
wrongness, and today proved it twice.

  - PT15018 and PT16023 BOTH passed every guard while `judicialised_flag = False`
    meant OPPOSITE things -- "not in court" on one, "we don't know" on the other.
  - `Data Vencido -> default_date` is a judgement from a Portuguese word. Every
    guard passes whether or not it is right.

So the output carries `reviewed_by` and `reviewed_at`. A deal nobody has looked at
says so, instead of looking identical to one that was checked.

EVERY ROW IS LABELLED BY EVIDENCE TIER, so the read is short:

    PROVEN     settled by an exact reconciliation. SKIP THESE.
    ATTESTED   the seller's own data dictionary says so.
    JUDGEMENT  inferred from a column name. THIS is what you read.
"""
import sys
from pathlib import Path
import json
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from style import ascii_only, attr_series

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
# the raw tape, so the sheet can tell when it is describing a stale output
TAPES = _P.TAPES


def _n(x):
    return " ".join(str(x).split()).strip().casefold()


def evidence(row, deal):
    """One short line saying WHY this column was chosen.

    !! THE REASON WAS ONLY EVER IN mappings.csv. A reviewer reading the sheet
       saw `cutoff_balance <- curr_bal` with no indication that the choice had
       been argued at all - so a decision someone had measured looked
       identical to a guess. The registry note carries the argument; this
       puts its first sentence where the question is asked.
    """
    note = str(row.get("note") or "").strip()
    if not note or note.lower() == "nan":
        return "-"
    # the note's first sentence is written to be the headline; a `!!` marks
    # the part that matters most, so prefer it when there is one
    if "!!" in note:
        note = note.split("!!", 1)[1].strip()
    first = note.split(". ")[0].strip().rstrip(".")
    return (first[:118] + "...") if len(first) > 121 else first


def tier(row, hits):
    """PROVEN only if an exact reconciliation settled THIS column.

    !! IT USED TO SAY PROVEN FOR THE WHOLE FAMILY. The test was "any hit
       exists AND the field is one of cutoff_balance / cutoff_principal /
       segment", so a deal that proved one interest column marked its balance,
       its capital AND its segment as settled - and the sheet told the
       reviewer to SKIP all three. PT15014 listed `segment <- segment` as
       settled by arithmetic when none of its hits uses a scope rule at all.
       Telling someone not to check something nothing proved is the worst
       thing this sheet can do.

    A column is proven when IT is the amount a published total reproduces.
    `segment` is different: it is proven only when the reconciliation NEEDED
    it - that is, when it was the scope column of a hit, which is what
    PT15018's `Segmento != Excluded` is.

    !! AND A PROVEN FIGURE IS NOT A PROVEN MEANING. PT20008's
    `Divida_Contabilistico` reproduces a published total exactly, so it was
    marked PROVEN and the sheet told the reviewer to skip it. But the column
    is ACCOUNTING debt, and calling it `cutoff_principal` is a reading, not a
    translation - this tape names no capital column at all. Arithmetic cannot
    settle what a column MEANS, only that it adds up.
    So a registry note that opens `JUDGEMENT` overrides the tier: whoever
    wrote the mapping is saying out loud that the meaning is inferred, and
    that belongs in front of the reviewer however well the number ties.
    """
    # getattr, not .get: this is called with a pandas row AND with the
    # lightweight stub cases.py builds, which has attributes but no .get
    if str(getattr(row, "note", "") or "").lstrip().upper().startswith("JUDGEMENT"):
        return "JUDGEMENT"
    col = _n(row.source_column)
    for h in hits:
        if row.target_field == "segment":
            if h.get("scope_column") and _n(h["scope_column"]) == col:
                return "PROVEN"
        elif _n(h.get("amount_column")) == col:
            return "PROVEN"
    return "JUDGEMENT"


def tape_md5(deal):
    """The exact raw file this deal was built from.

    !! A CONFIRMATION IS ONLY VALID FOR THE FILE IT WAS MADE AGAINST. Pinning
       the mapping alone is not enough: the seller can send a corrected tape
       with the mapping untouched, and every field would still read as
       confirmed against data nobody has looked at. Same raw file AND same
       mapping, or the question re-opens.
    """
    import hashlib
    f = TAPES / f"{deal}.parquet"
    return hashlib.md5(f.read_bytes()).hexdigest() if f.exists() else None


def mapping_of(deal, field):
    """The registry rows feeding one field, as a stable string.

    Captured when a field is REJECTED and compared when it is resolved, so a
    rejection cannot be cleared without the mapping actually changing.
    """
    m = pd.read_csv(_P.REGISTRY)
    r = m[(m.deal_id == deal) & (m.target_field == field)]
    if r.empty:
        return "(not mapped)"
    cols = [c for c in ("role", "source_sheet", "source_column", "transform")
            if c in r.columns]
    return " ; ".join(sorted(" | ".join(str(x[c]) for c in cols)
                             for _, x in r.iterrows()))


def load_decisions(out):
    f = out / "decisions.yaml"
    if not f.exists():
        return {"open_rejections": []}
    import yaml
    return yaml.safe_load(f.read_text()) or {"open_rejections": []}


def save_decisions(out, d):
    import yaml
    (out / "decisions.yaml").write_text(yaml.safe_dump(d, sort_keys=False,
                                                       allow_unicode=True))


def main(deal, approve=False, who=None, reject=None, reason=None):
    out = _P.CONTEXT / deal
    out.mkdir(parents=True, exist_ok=True)

    d = load_decisions(out)

    if reject:
        d.setdefault("open_rejections", [])
        d["open_rejections"] = [r for r in d["open_rejections"] if r["field"] != reject]
        d["open_rejections"].append({
            "field": reject, "reason": reason or "(no reason given)",
            "raised_by": who or "sharlene",
            "raised_at": f"{pd.Timestamp.now():%Y-%m-%d %H:%M}",
            # !! PIN WHAT WAS WRONG. Without it, `--resolve` could clear a
            #    rejection with nothing changed and no trace of whether the
            #    mapping had ever been touched.
            "mapping_when_rejected": mapping_of(deal, reject)})
        d["approved"] = False
        save_decisions(out, d)
        print(f"{deal}: `{reject}` REJECTED -- {reason or '(no reason)'}")
        print(f"  {len(d['open_rejections'])} open rejection(s). The deal stays")
        print(f"  unapproved until they are resolved. The agent should fix the")
        print(f"  mapping, re-run, then you review again.")
        return 0

    if approve:
        rv = out / "REVIEW.md"
        if not rv.exists():
            print(f"nothing to approve -- run without --approve first", file=sys.stderr)
            return 2
        # !! GUARDS FIRST. --approve checked only that a REVIEW.md existed, so
        #   a deal whose balance no longer ties to the seller's published
        #   figure could be signed off by anyone running this script directly.
        #   run.py blocks on a guard failure; nothing stopped the user from
        #   bypassing run.py entirely.
        import subprocess as _sp
        _g = _sp.run([sys.executable, str(HERE / "guards.py"), deal],
                     capture_output=True, text=True)
        if _g.returncode:
            print(f"REFUSED -- {deal}'s guards do not pass. Nothing may be "
                  f"signed off while a guard fails.\n", file=sys.stderr)
            print("\n".join(l for l in _g.stdout.splitlines()
                             if "FAIL" in l or "GUARD" in l), file=sys.stderr)
            return 1
        _on = [n for n in (d.get("notes") or []) if n.get("state") != "closed"]
        if _on:
            print(f"REFUSED -- {len(_on)} open note(s) on {deal}:",
                  file=sys.stderr)
            for n in _on:
                st = "answered, not closed" if n.get("answer") else "UNANSWERED"
                print(f"    {n['id']}. [{st}] {n['text'][:70]}", file=sys.stderr)
            print("\n  Close each one before approving.", file=sys.stderr)
            return 1
        open_r = d.get("open_rejections") or []
        if open_r:
            print(f"REFUSED -- {len(open_r)} rejection(s) still open:", file=sys.stderr)
            for r in open_r:
                print(f"    `{r['field']}` -- {r['reason']}", file=sys.stderr)
            print("\n  Resolve them (fix the mapping, re-run, then "
                  f"`--resolve <field>`) before approving.", file=sys.stderr)
            return 1
        # !! RECORD WHAT WAS APPROVED, NOT MERELY THAT IT WAS. Without the
        #    output hash, an engine change afterwards leaves the deal reading
        #    "approved" while the numbers have moved -- the signature outlives
        #    the thing it signed. With it, `verify.py` can say "approved on the
        #    7th, output has changed since" instead of silently accepting it.
        import hashlib
        acc_f = _P.ACCOUNTS / f"{deal}.parquet"
        # !! APPROVING CONFIRMS EVERYTHING NOT REJECTED, IN ONE ACTION.
        #   Per-field confirmation was the first design and it is the wrong
        #   shape for how review actually happens: twelve deals at roughly
        #   eight judgement rows each is ninety-six keystrokes to say "yes"
        #   ninety-six times, when the reviewer's real answer is "these two
        #   are wrong, the rest are fine".
        #   So the model is REJECT UNTIL APPROVE. You reject what is wrong,
        #   note what you want answered, and approving signs off everything
        #   left. To keep that as traceable as the per-field version, the
        #   approval pins the mapping of EVERY field plus the raw tape - so
        #   if any one of them changes afterwards, the sheet says which.
        # !! THE WRITER AND THE READER MUST COMPUTE THE SAME THING. They did
        #   not: the staleness check was widened to cover accounts, the long
        #   table and payments, and this line was left hashing accounts
        #   alone. Every approval was therefore stale the instant it was
        #   written - the sheet said APPROVED-STALE on the same second it
        #   said approved - which would have blocked the entire review.
        #   One function, called from both sides, so they cannot diverge
        #   again.
        import style as _st2
        _reg = pd.read_csv(_P.REGISTRY).query("deal_id == @deal")
        _fields = sorted({r.target_field for _, r in _reg.iterrows()
                          if r.role in ("base", "enrich", "party", "align",
                                        "bridge", "duration")})
        d.update({"deal": deal, "approved": True,
                  "approved_mappings": {f: mapping_of(deal, f) for f in _fields},
                  "approved_tape_md5": tape_md5(deal),
                  "approved_output_md5": _st2.output_fingerprint(deal),
                  "reviewed_by": who or "sharlene",
                  "reviewed_at": f"{pd.Timestamp.now():%Y-%m-%d %H:%M}",
                  "note": "Approved the strats hit as the right quantity and the "
                          "JUDGEMENT mappings as meaning what they say. PROVEN rows "
                          "were settled by exact reconciliation and not re-checked."})
        save_decisions(out, d)
        print(f"{deal} approved -- recorded in cleaning-context/{deal}/decisions.yaml")
        # and rewrite the sheet, so what is on disk agrees with what was signed
        main(deal)
        return 0

    acc = pd.read_parquet(_P.ACCOUNTS / f"{deal}.parquet")
    m = pd.read_csv(_P.REGISTRY).query("deal_id == @deal")
    # !! A SHEET BUILT FROM A STALE OUTPUT IS WORSE THAN NO SHEET. Editing
    #   mappings.csv and running review.py without re-cleaning produced a
    #   perfectly confident document describing the PREVIOUS registry, with
    #   no warning anywhere on it.
    meta_f = _P.ACCOUNTS / f"{deal}.meta.json"
    meta = json.loads(meta_f.read_text()) if meta_f.exists() else {}
    _acc_p = _P.ACCOUNTS / f"{deal}.parquet"
    _stale = []
    if _acc_p.exists():
        import hashlib as _h5
        _meta_f = _P.ACCOUNTS / f"{deal}.meta.json"
        _mj = json.loads(_meta_f.read_text()) if _meta_f.exists() else {}
        _rows = pd.read_csv(_P.REGISTRY).query("deal_id == @deal")
        _now = _h5.md5(_rows.sort_values(list(_rows.columns)).astype(str)
                       .to_csv(index=False).encode()).hexdigest()
        if _mj.get("registry_md5") and _mj["registry_md5"] != _now:
            _stale.append("this deal's rows in mappings.csv")
        _tf = TAPES / f"{deal}.parquet"
        if _tf.exists() and _mj.get("registry_md5") is not None:
            if _h5.md5(_tf.read_bytes()).hexdigest() != (
                    _mj.get("tape_md5") or _h5.md5(_tf.read_bytes()).hexdigest()):
                _stale.append("the raw tape")

    # !! THE SHEET MUST SAY WHETHER IT HAS BEEN SIGNED. It used to end with
    #   "nobody has confirmed that any JUDGEMENT row means what it says" and
    #   go on saying it after approval, because approving writes
    #   decisions.yaml and never touched this file. Someone reading an
    #   approved deal's sheet a month later would have been told, in writing,
    #   that it was unreviewed.
    import style as _st
    _live = _st.output_fingerprint(deal)
    sf = _P.STRATS / f"{deal}.json"
    hits = json.loads(sf.read_text()).get("hits", []) if sf.exists() else []
    df = _P.DICTIONARIES / f"{deal}.json"
    has_dict = json.loads(df.read_text()).get("dictionaries") if df.exists() else None

    L = [f"# {deal} -- approval sheet", ""]
    if _stale:
        L += ["> **DO NOT SIGN THIS. IT IS OUT OF DATE.**", ">",
              "> " + " and ".join(f"`{x}`" for x in _stale) +
              " changed after this deal was last cleaned,",
              "> so everything below describes the PREVIOUS output. Rebuild "
              "first:", ">",
              f"> ```sh", f"> uv run python scripts/run.py {deal}", "> ```", ""]
    # read straight from meta -- the derived n_ins / b_ins are set further down,
    # and depending on them here is how this line crashed on every deal
    _who, _ctry = meta.get("seller"), meta.get("country", "")
    _n, _b = meta.get("in_scope_loans"), meta.get("in_scope_balance")
    if _who:
        head = f"**{_who}**, {_ctry}."
        if _n is not None and _b is not None:
            head += f" {_n:,} loans, EUR {_b:,.2f}."
        L += [head, ""]
    _notes = d.get("notes") or []
    _open_notes = [n for n in _notes if n.get("state") != "closed"]
    if _open_notes:
        L += [f"> **{len(_open_notes)} OPEN NOTE(S).** This deal cannot be "
              "approved until each is", "> answered and closed.", ">"]
        for n in _open_notes:
            L.append(f"> **{n['id']}.** {n['text']}  "
                     f"_({n.get('raised_by')}, {n.get('raised_at')})_")
            if n.get("answer"):
                L.append(f">     answered: {n['answer']}")
                L.append(f">     close it: `review.py {deal} --close {n['id']}`")
            else:
                L.append(f">     awaiting the agent")
            L.append(">")
        L.append("")
    if [n for n in _notes if n.get("state") == "closed"]:
        L += ["**Closed notes** (kept so the question and its answer survive):",
              ""]
        for n in [n for n in _notes if n.get("state") == "closed"]:
            L.append(f"- **{n['id']}.** {n['text']}")
            L.append(f"  -> {n.get('answer') or n.get('closed_note') or 'closed'}")
        L.append("")
    L += ["Everything here is either settled by arithmetic or waiting on your "
          "judgement.", "The sheet says which is which.", ""]

    # !! SECTION 1 USED TO LIST PROVEN TOTALS AND NOTHING ELSE, which on a
    #   multi-sheet deal is unreadable: PT15014 showed `curr_bal` TWICE with
    #   two different totals and no indication of which sheet either came
    #   from, whether any of them was the column actually used, or that only
    #   75.3% of the book was proven at all. A reviewer cannot sign that.
    #   It now answers three questions in order: what is this deal measured
    #   on, how far is that proven, and what else could have been chosen.
    # !! ASK WHICH FIELD THIS DEAL IS MEASURED ON. Hardcoding cutoff_balance
    #   meant PT15018 - 32,529 loans and EUR 407m of outstanding principal -
    #   produced a section 1 with no column, no total and no table at all,
    #   because that deal publishes a principal and no total owed.
    _hf = meta.get("headline_field") or "cutoff_balance"
    bal_row = m[(m.target_field == _hf)]
    bal_col = str(bal_row.source_column.iloc[0]) if len(bal_row) else None
    n_ins = meta.get("in_scope_loans")
    b_ins = meta.get("in_scope_balance")
    cov = meta.get("proven_coverage")
    n_src = len(meta.get("source_sheets") or [])
    n_pro = len(meta.get("proven_sheets") or [])

    # !! HOW THE SELLER BOUGHT IT DECIDES WHAT A TOTAL CAN MEAN, so it goes
    #   ABOVE the figure, not in a footnote. On a forward flow the tape is one
    #   delivery under a contract, never the book, and a reviewer who approves
    #   a total without knowing that has approved the wrong noun.
    _dl = pd.read_csv(_P.DEALS)
    _dr = _dl[_dl.deal_id == deal]
    _dtype = (str(_dr.deal_type.iloc[0])
              if len(_dr) and "deal_type" in _dr.columns else "")
    _dnote = (str(_dr.deal_type_note.iloc[0])
              if len(_dr) and "deal_type_note" in _dr.columns else "")
    if _dtype and _dtype != "nan":
        if _dtype == "forward_flow":
            L += ["> !! **THIS IS A FORWARD FLOW**, as Intrum underwrote it.",
                  ">",
                  "> The book was delivered MONTHLY under a contract, not "
                  "bought once. So this",
                  "> tape is a delivery, and any total from it is a total of "
                  "what arrived - never",
                  "> of the deal. Read every figure below with that noun in "
                  "mind.",
                  ">",
                  f"> {_dnote}", ""]
        else:
            L += [f"**Deal type: one-off.** {_dnote}", ""]

    # !! AS OF WHEN. A balance with no date is not a figure anybody can use,
    #   and this sheet asked a reviewer to approve one without ever saying.
    #   Three deals of thirteen state a cut-off; where none is stated the
    #   payment span is the only clue and it is shown as exactly that.
    _co = (str(_dr.cutoff_date.iloc[0])
           if len(_dr) and "cutoff_date" in _dr.columns else "")
    _co = "" if _co in ("nan", "") else _co
    if _co:
        L += [f"**As at {_co}.** Everything below is the book on that date.", ""]
    else:
        L += ["!! **This deal states NO CUT-OFF DATE.** The balances are as at "
              "whatever date",
              "the seller struck the tape, and the tape does not say which. "
              "`find_cutoff.py`",
              "reads the banner rows of every sheet looking for one; it found "
              "none here.",
              "A figure from this deal cannot be dated.", ""]

    L += ["## 1. What figure is this deal, and how far is it proven?", ""]
    if bal_col and b_ins is not None:
        L += [f"**The deal is `{bal_col}`.** It is mapped to `{_hf}`, "
              f"and over the",
              f"{n_ins:,} in-scope loans it totals **EUR {b_ins:,.2f}**. Every "
              "figure anyone",
              "quotes for this book comes from that one column choice.", ""]
    if hits:
        if _hf != "cutoff_balance":
            L += [f"!! **This deal has no TOTAL OWED.** `{bal_col}` is an "
                  f"outstanding PRINCIPAL,",
                  f"mapped to `{_hf}`. The tape carries no interest and no fee "
                  "column for this",
                  "population, so what the borrower must actually repay is not "
                  "stated anywhere",
                  "and `cutoff_balance` is NULL by design, not by omission. "
                  "Any figure quoted",
                  "from this deal is principal.", ""]
        if cov is not None and n_src > 1:
            L += [f"**Proven on {n_pro} of {n_src} sheets, which is "
                  f"{cov:.1%} of that balance.**", ""]
            if cov < 0.995:
                L += [f"The other {1 - cov:.1%} sits on sheets where the seller "
                      "published no total,",
                      "so nothing external confirms it. That is why this deal "
                      "is `consistent`",
                      "and not `reconciled` - the arithmetic below is real, and "
                      "it does not",
                      "cover the whole book.", ""]
        else:
            L += [f"**Proven against the seller's own published figure, to the "
                  f"cent.**", ""]

        # group by column: a multi-sheet deal proves the same column many times
        by_col = {}
        for h in hits:
            k = h["amount_column"]
            e = by_col.setdefault(k, {"sheets": set(), "total": 0.0, "scope": set()})
            e["sheets"].add(h.get("sheet"))
            e["total"] += float(h["total"])
            e["scope"].add(f"{h['scope_column']} != {h['scope_excludes']}"
                           if h.get("scope_column") else "none")
        used = [c for c in by_col if bal_col and c == bal_col]
        other = sorted(c for c in by_col if c not in used)

        def _row(c):
            e = by_col[c]
            sc = ", ".join(sorted(e["scope"]))
            where = (f"{len(e['sheets'])} sheets" if len(e["sheets"]) > 1
                     else next(iter(e["sheets"])) or "-")
            return (f"| `{c}` | {where} | {e['total']:,.2f} | "
                    f"{'none' if sc == 'none' else '`' + sc + '`'} |")

        if used:
            L += ["**The column this deal uses:**", "",
                  "| column | proven on | sum of the proven totals | scope rule |",
                  "|---|---|---:|---|"] + [_row(c) for c in used] + [""]
        if other:
            L += ["**Other columns on this tape that ALSO reproduce a published "
                  "figure.**",
                  "These are the alternatives. Picking one instead changes what "
                  "this deal is:", "",
                  "| column | proven on | sum of the proven totals | scope rule |",
                  "|---|---|---:|---|"] + [_row(c) for c in other[:8]] + [""]
            if len(other) > 8:
                L += [f"...and {len(other) - 8} more in "
                      f"`strats/{deal}.json`.", ""]
        L += ["**Your decision:** is `" + str(bal_col) + "` the right measure, "
              "and is it as of the right",
              "date? A balance can reconcile perfectly and still be the wrong "
              "month, or the",
              "balance at write-off rather than the balance today."]
    else:
        L += ["**Nothing on this tape is proven against a seller figure.** "
              "`find_strats` found", "no published total to reconcile against, "
              "so this deal can reach `consistent`",
              "and never `reconciled`.", "",
              "What `consistent` means here: every column parsed, the ids "
              "behave, capital",
              "never exceeds balance, and a re-run reproduces the file "
              "byte for byte. All",
              "internal. If the seller's own number differs from "
              f"EUR {b_ins:,.2f}, nothing" if b_ins is not None else "internal.",
              "in this pipeline would catch it.", "",
              "**Your decision:** is that acceptable for this book, or should "
              "someone ask the",
              "seller for a published total?"]
    L.append("")

    # !! WHAT WAS REMOVED IS PART OF WHAT IS BEING SIGNED. The engine drops
    #   published total rows, footer calculations, header rows, whole cohorts
    #   delivered twice, and loans the seller marks not-for-sale. All of that
    #   was printed to a terminal and then lost, so the sheet described only
    #   the survivors. Approving PT19013 meant approving the removal of 310
    #   rows from a file named "final" without being told.
    # !! A ROW THAT CHANGED IS NOT A ROW THAT LEFT. The fallback decision was
    #   listed under "what was removed" and added into the total, so PT15014
    #   read "729 rows left the book" when 9 left and 720 simply took their
    #   balance from a second column. Two different things, two lists.
    # !! A DECISION IS NOT ALWAYS A REMOVAL, and summing them as if it were
    #   overstates what left. PT15018 reported "4,744 row(s) left the book"
    #   when 3,853 of those were the bridge join - 2,797 participant-rows and
    #   1,056 rolled-up clients, neither of which removes a loan. Only kinds
    #   that actually DROP rows belong in that total; the rest are reported,
    #   plainly, as things the engine did rather than things it deleted.
    NOT_REMOVED = {"fallback_column", "bridged_sheet", "bridge_rollup",
                   "derived_end_date", "bridge_unreachable"}
    dec_rows = meta.get("decisions") or []
    gone = [r for r in dec_rows if r["kind"] not in NOT_REMOVED]
    kept = [r for r in dec_rows if r["kind"] in NOT_REMOVED]
    if dec_rows:
        L += ["## 2. What the engine decided", ""]
        if gone:
            L += [f"**{sum(r['rows'] for r in gone):,} row(s) left the book** "
                  f"before the {n_ins:,} above were counted:" if n_ins else
                  "**Rows that left the book:**", "",
                  "| rows | why |", "|---:|---|"]
            for r in gone:
                # a file|sheet detail carries pipes, which would split cells
                L.append(f"| {r['rows']:,} | "
                         + str(r["detail"]).replace("|", "/") + " |")
            L.append("")
        if kept:
            L += ["**Rows that stayed, but were built differently.** These "
                  "loans ARE in the",
                  f"{n_ins:,} above - nothing was dropped - but a field came "
                  "from a second column:" if n_ins else
                  "**Rows that stayed, but were built differently:**", "",
                  "| loans | what |", "|---:|---|"]
            for r in kept:
                L.append(f"| {r['rows']:,} | "
                         + str(r["detail"]).replace("|", "/") + " |")
            L.append("")
        L += ["Each of these is a rule the engine applies to every deal, not a "
              "judgement about",
              "this one - the rules are in `traps.yaml` and each is covered by "
              "a regression",
              "case. What needs YOUR eye is whether any of them did something "
              "you did not",
              "expect on THIS book.", ""]
        _sp, _s3, _s4 = "3", "4", "5"
    else:
        _sp, _s3, _s4 = "2", "3", "4"

    # !! THE PUBLISHED TABLES THEMSELVES, not only the hits taken from them.
    #   Section 1 says which figure reconciles; it never showed the reviewer
    #   what the seller actually printed. A strat table is the seller's own
    #   summary of their own book - the one artefact in the pack written to be
    #   read by a buyer - and judging whether a column is the right QUANTITY is
    #   far easier beside it than in the abstract.
    if not hits:
        _s3, _s4 = _sp, _s3
    if hits:
        _st = {}
        for h in hits:
            _st.setdefault(h.get("sheet") or "(unnamed)", []).append(h)
        L += ["## " + str(_sp) + ". What the seller published", "",
              "Printed on the tape by the seller - this is what the arithmetic "
              "above",
              "reconciles against. Read it to judge whether the figure this "
              "deal reports",
              "is the QUANTITY you want.", "",
              "| sheet | column the seller totalled | their total | scope they applied |",
              "|---|---|---:|---|"]
        for sh in sorted(_st):
            for h in sorted(_st[sh], key=lambda x: -float(x["total"])):
                sc = ("`" + str(h["scope_column"]) + "` != `"
                      + str(h["scope_excludes"]) + "`"
                      if h.get("scope_column") else "whole sheet")
                L += ["| `" + str(sh) + "` | `" + str(h["amount_column"])
                      + "` | " + format(float(h["total"]), ",.2f") + " | "
                      + sc + " |"]
        L += ["", str(len(hits)) + " published total(s) across "
              + str(len(_st)) + " sheet(s).", ""]

    L += [f"## {_s3}. Do these mappings mean what they say?", "",
          f"Evidence: {'a data dictionary WAS found' if has_dict else 'no data dictionary -- everything below is inference'}.", ""]
    # !! EVERY MAPPING ROLE, NOT A HARDCODED THREE. Adding `align` for PT15020
    #   left its cutoff_balance, cutoff_principal and cutoff_interest out of BOTH
    #   tiers -- the three columns that actually reconcile, invisible on the
    #   sheet the reviewer signs. A role list that has to be edited in step
    #   with the engine will fall behind it.
    # bridge and duration PRODUCE a target field, so they belong here;
    # scope/filter/prefer/grain/link shape the population instead and are
    # listed in their own section, where their effect can be explained
    MAPPING_ROLES = ("base", "enrich", "party", "align", "bridge",
                     "duration")
    jud = [r for _, r in m.iterrows()
           if r.role in MAPPING_ROLES
           and tier(r, hits) == "JUDGEMENT"]
    prov = [r for _, r in m.iterrows()
            if r.role in MAPPING_ROLES
            and tier(r, hits) == "PROVEN"]

    # !! NAME THE PROVEN ROWS, DO NOT JUST COUNT THEM. "3 PROVEN rows -- skip
    #   them" tells a reviewer to skip three things it declines to identify,
    #   so the only way to know what was skipped was to read the registry.
    if prov:
        # !! THIS SHEET IS A TO-DO LIST, NOT A RECORD. It printed every
        #   settled row in full beside every open one, so a deal with two
        #   questions left looked the same length as one nobody had opened.
        #   The settled rows are COUNTED here and listed in full in
        #   cleaned_summary.md, which is the permanent record and carries
        #   every field's source, fill rate, an example value and its state.
        #   As a deal is reviewed this section shrinks; when it is approved
        #   there is nothing left in it, which is the point.
        L += [f"**{len(prov)} row(s) settled by arithmetic** - the column "
              f"reproduces a published",
              "figure exactly, so the only open question would be what it "
              "MEANS, and section 1",
              "asks that: "
              + ", ".join(f"`{r.target_field}`" for r in prov) + ".", ""]
    else:
        L += ["**No row is settled by arithmetic.** Nothing on this tape "
              "reconciles, so every",
              "mapping below is inference and every one needs reading.", ""]
    # !! ONLY WHAT IS STILL OPEN. A confirmed field whose mapping AND whose
    #   raw tape are unchanged has been settled by a human and does not belong
    #   on a to-do list. If either moved, the confirmation is void and the
    #   row comes back - which is the whole point of pinning both.
    DERIVED = {"borrower_type": ["loan_holder_individual_flag",
                                 "loan_holder_corporate_flag"]}
    # !! ONE ROW PER FIELD, not per mapping. A field can be fed by SEVERAL sheets
    #   -- PT15018 takes judicialised_flag from both `Main Debtors` and `Other
    #   Participants`, and taking only the first loses 200 `Yes` belonging to
    #   co-holders. Printing it twice makes the reviewer think something is
    #   duplicated when the mapping is right; it just has two sources.
    byfield = {}
    for r in jud:
        byfield.setdefault(r.target_field, []).append(r)
    jud = []
    for f, rows in byfield.items():
        r = rows[0].copy()
        srcs = sorted({f"{x.source_sheet}.{x.source_column}" for x in rows})
        r["_sources"] = (f"`{rows[0].source_column}`" if len(srcs) == 1
                         else f"`{rows[0].source_column}` ({len(srcs)} sheets)")
        jud.append(r)

    _conf = {c["field"]: c for c in (d.get("confirmed") or [])}
    _live_tape = tape_md5(deal)
    settled, stale = {}, []
    for f_, c in _conf.items():
        if c.get("mapping") != mapping_of(deal, f_):
            stale.append((f_, "its mapping changed"))
        elif c.get("tape_md5") and c["tape_md5"] != _live_tape:
            stale.append((f_, "the raw tape changed"))
        else:
            settled[f_] = c
    jud_open = [r for r in jud if r.target_field not in settled]

    if settled:
        # counted, not listed: who confirmed what and when is in
        # decisions.yaml and in cleaned_summary.md's `state` column
        L += [f"**{len(settled)} row(s) you have already confirmed** against "
              f"this exact raw file",
              "and this exact mapping - if either changes they come back: "
              + ", ".join(f"`{f_}`" for f_ in sorted(settled)) + ".", ""]
    if stale:
        L += ["!! **Confirmations VOIDED** -- these were signed off against "
              "something that has", "since changed, so they are open again:", ""]
        for f_, why in stale:
            L.append(f"- `{f_}` -- {why}")
        L.append("")

    if not jud_open:
        L += ["**Nothing left to read.** Every mapping on this deal is either "
              "settled by",
              "arithmetic or confirmed by a human against this exact tape.", ""]
    else:
        L += [f"**{len(jud_open)} row(s) to read.** Each is a column name we "
              "interpreted. Nothing",
              "proves these mean what they say - that judgement is what you "
              "are signing.", "",
              "`lands in` says which output carries the field: the fixed "
              "`core` every consumer",
              "relies on, or `additional` - the open long table. Approving "
              "covers BOTH.", "",
              "**Reject what is wrong, note what you want answered, then "
              "approve the rest:**", "",
              f"    review.py {deal} --reject <field> \"what is wrong\"",
              f"    review.py {deal} --note \"anything not about one field\"",
              f"    review.py {deal} --approve        # signs off everything "
              f"not rejected", "",
              "| field | lands in | <- column | filled | sample | "
              "why this column |", "|---|---|---|---:|---|---|"]


    for r in jud_open:
        # a mapped column can be CONSUMED into other fields; show those instead,
        # or the row reads 0% filled and looks broken when it is not
        if r.target_field in DERIVED:
            # !! NOT `d`. That is the decisions dict, loaded at the top of this
            #   function, and this loop was overwriting it with a column name.
            #   Every deal with a derived field then crashed at the approval
            #   banner with AttributeError, left its OLD sheet on disk, and a
            #   regeneration sweep that hid stderr reported "nothing changed"
            #   as if that were success.
            for dcol in DERIVED[r.target_field]:
                _dv = acc[dcol] if dcol in acc else attr_series(BASE, deal, dcol)
                n = int(_dv.eq(True).sum())
                _w = "core" if dcol in acc.columns else "additional"
                L.append(f"| `{dcol}` | {_w} | {r['_sources']} | {n:,} true | "
                         f"derived from `{r.target_field}` | "
                         f"{evidence(r, deal)} |")
            continue
        f = r.target_field
        # !! A FIELD OUTSIDE THE CORE IS NOT MISSING, IT IS ELSEWHERE. Reading
        #   only the accounts file made every moved field report 0 (0%) on the
        #   sheet a human signs - `insolvent_flag` on 8,591 loans read as
        #   nothing at all.
        v = acc[f] if f in acc else attr_series(BASE, deal, f)
        n = int(v.notna().sum())
        pct = f"{100*n/len(acc):.0f}%" if len(acc) else "--"
        samp = ", ".join(map(str, v.dropna().unique()[:2]))[:34]
        # !! SAY WHICH TABLE. An approval covers BOTH outputs, and a reviewer
        #   should not have to know the schema to tell whether a field is a
        #   fixed core column every consumer relies on, or a fact in the open
        #   long table. The two carry different weight.
        where = "core" if f in acc.columns else "additional"
        L.append(f"| `{f}` | {where} | {r['_sources']} | {n:,} ({pct}) | "
                 f"{samp} | {evidence(r, deal)} |")

    import yaml as _y
    _sch = _y.safe_load((_P.SCHEMA).read_text(encoding="utf-8"))
    _have_attr = set(meta.get("attribute_names") or [])
    missing = [c for c in acc.columns if acc[c].isna().all()]
    missing += [c for c in (_sch.get("additional_attributes_seen") or [])
                if c not in _have_attr]
    L += ["", f"**Empty on this deal ({len(missing)}).** Either the tape does "
          "not carry the",
          "fact, or it carries it somewhere we did not map. `CONTEXT.md` for "
          "this deal",
          "separates the two, field by field:", "",
          ", ".join(f"`{c}`" for c in missing), ""]

    # !! PAYMENTS WERE PINNED BY THE APPROVAL AND SHOWN BY NOTHING.
    #   The signature covers accounts, the long table AND payments, but this
    #   sheet only ever displayed the first two - so a reviewer signed for a
    #   payments file they were never shown. Worse, payments carry the two
    #   judgement calls nobody was being asked about: WHICH COLUMN is the key
    #   (chosen by value overlap, not by name) and WHETHER THE SIGN WAS
    #   FLIPPED (decided once per deal from how the seller writes receipts).
    #   Both are inferences. Both change every figure in the file.
    _pm = _P.PAYMENTS / f"{deal}.meta.json"
    _pf = _P.PAYMENTS / f"{deal}.parquet"
    # !! THE ROWS THAT DECIDE WHICH LOANS EXIST WERE NEVER DISPLAYED.
    #   The mappings section lists roles that produce a FIELD - base, enrich,
    #   party, align, bridge, duration. It skipped every row that shapes the
    #   POPULATION instead: `scope` (which loans are excluded), `filter`
    #   (which rows a sheet may not contribute), `prefer` (which file wins
    #   when one cohort arrives twice), `grain` (how rows collapse to a loan)
    #   and `link` (how a keyless sheet reaches the book). PT15018 has 22
    #   registry rows and showed 14. Those eight are the most consequential
    #   rows in the file - they decide what is counted at all - and a
    #   reviewer signing the deal had never seen them.
    _struct = m[~m.role.isin(MAPPING_ROLES)] if len(m) else m
    if len(_struct):
        _what = {
            "scope":  "EXCLUDES LOANS - a dedicated in/out column",
            "filter": "DROPS ROWS from a sheet, using the seller's own label",
            "prefer": "PICKS A FILE when one cohort was delivered twice",
            "grain":  "COLLAPSES ROWS to one per loan",
            "link":   "BRIDGES a keyless sheet to the book",
        }
        L += ["", f"## {_s4}. How this deal was assembled", "",
              "These registry rows carry no field of their own. They decide "
              "WHICH LOANS",
              "EXIST and which rows count - so they move every figure above, "
              "and none of",
              "them is visible in the mappings.", "",
              "| role | what it does | sheet | column | why |",
              "|---|---|---|---|---|"]
        for _, r in _struct.iterrows():
            _n = str(r.get("note") or "").replace("|", "/")
            _n = (_n[:150] + "...") if len(_n) > 150 else _n
            L += [f"| `{r.role}` | {_what.get(r.role, 'shapes the build')} | "
                  f"`{r.source_sheet}` | `{r.source_column}` | {_n} |"]
        L += ["", "**Read these first.** A wrong `scope` or `filter` row "
              "removes real loans and",
              "every total below still reconciles - the arithmetic cannot see "
              "a loan that",
              "was never there.", ""]
        _s4 = str(int(_s4) + 1)

    L += ["", "---", "",
          "**This sheet is the OUTSTANDING list and nothing else.** Every "
          "field this deal",
          "produces - its source sheet and column, the transform, how full it "
          "is, an example",
          "value and whether you have signed it - is in "
          "`cleaned_summary.md`, which is the",
          "permanent record. When this deal is approved there is nothing left "
          "to read here.",
          "",
          f"## {_s4}. Payments", ""]
    # !! "NO PAYMENTS" AND "PAYMENTS WE COULD NOT ATTRIBUTE" ARE DIFFERENT
    #   FACTS, and only one of them is a question for anybody. The first cut
    #   of this section tested for the OUTPUT file alone, so PT20014 and
    #   PT17013 - which carry no payment column at all - were described as
    #   "the tape HAS payment cells", a statement this document had no basis
    #   for and that is simply untrue. A review sheet asserting something
    #   false about the tape is worse than one that says nothing.
    _p = json.loads(_pm.read_text()) if _pm.exists() else {}
    _raw_rows = int(_p.get("rows") or 0)
    if not _pm.exists() or _raw_rows == 0:
        L += ["This tape carries **no payment columns at all**, so no payments "
              "file was",
              "written. That is the seller's tape, not a gap in our reading. "
              "The accounts",
              "are unaffected and there is nothing to approve here.", ""]
    else:
        if not _pf.exists():
            if _p.get("empty_reason"):
                L += [f"**{_raw_rows:,} payment cell(s) on this tape, and "
                      f"EVERY ONE IS ZERO.**", "",
                      "The seller shipped the payment columns with no money in "
                      "them. A zero is",
                      "not a payment, so every cell is null and the file is "
                      "empty. That is their",
                      "data, not a gap in our reading - and it is NOT the same "
                      "as a tape whose",
                      "payments we could not attribute.", ""]
            else:
                L += ["!! **Payments were BLOCKED, not empty.** "
                      + str(_p.get("blocked") or _p.get("blocked_reason")
                            or "no id column on the payment cells overlaps the "
                               "cleaned population."),
                      "",
                      f"The tape carries {_raw_rows:,} payment cell(s) with "
                      f"money in them. They are",
                      "not in the output because attributing them would have "
                      "been a guess. The",
                      "accounts are unaffected.", ""]
        else:
            L += ["| | |", "|---|---:|",
                  f"| Rows kept | {_p.get('rows_out', 0):,} |",
                  f"| Grain | one row per `{_p.get('grain')}` x month |",
                  # !! "Months covered 0" ON A FILE WITH 98,488 PAYMENTS.
                  #   PT18019 dates its payments RELATIVE to the cut-off
                  #   (-12M..3M), so the calendar-month count is zero and the
                  #   sheet reported a payments file that covered no time at
                  #   all. It covers fifteen periods; what it lacks is a
                  #   calendar, not a span.
                  (f"| Months covered | {_p.get('months_covered', 0)} |"
                     if _p.get("dated", True) else
                     f"| Periods covered | {_p.get('periods') or 0} "
                     f"(the seller's own labels - NO calendar) |"),
                  f"| Gross | EUR {float(_p.get('gross_pay') or 0):,.2f} |",
                  f"| Returns | EUR {float(_p.get('returns') or 0):,.2f} |",
                  f"| **Net collections** | **EUR "
                  f"{float(_p.get('net_collections') or 0):,.2f}** |", "",
                  "**Two things here are JUDGEMENTS, not arithmetic.** Both "
                  "were inferred from",
                  "the data, and both move every figure above if they are "
                  "wrong:", "",
                  f"- **The key is `{_p.get('payments_key')}`**, matched to "
                  f"`{_p.get('grain')}`. "
                  f"Chosen by VALUE OVERLAP, never by name: "
                  f"{_p.get('key_evidence')}.",
                  "- **The sign was "
                  + ("FLIPPED" if _p.get("sign_flipped")
                     else "left as the seller wrote it")
                  + ".** " + str(_p.get("sign_evidence")), ""]
            _cav = []
            if _p.get("straddling_keys"):
                _cav.append(
                    f"{_p['straddling_keys']} key(s) hold BOTH in- and "
                    f"out-of-scope loans, EUR "
                    f"{float(_p.get('straddling_amount') or 0):,.2f} - kept in "
                    f"full, because splitting a payment between them would be "
                    f"an allocation nobody can defend")
            # !! "NET EQUALS GROSS" PRINTED BESIDE A RETURNS FIGURE OF
            #   EUR 3,654.07. `netted` means the seller ships a SEPARATE
            #   returns series; PT18019 does not, but it writes refunds as
            #   negatives inside the payment series itself (T48). Saying the
            #   deal "cannot show you refunds" while the table above shows
            #   3,654.07 of them is simply wrong.
            _ret = float(_p.get("returns") or 0)
            if not _p.get("netted"):
                _cav.append(
                    "the seller ships no separate RETURNS series. "
                    + (f"Refunds appear as negatives inside the payment "
                       f"series instead - EUR {abs(_ret):,.2f} of them (T48)"
                       if abs(_ret) > 0.005 else
                       "No refunds appear anywhere on this tape, so net "
                       "equals gross"))
            if _p.get("zero_rows_dropped"):
                _cav.append(
                    f"{_p['zero_rows_dropped']:,} empty cell(s) dropped: the "
                    f"tape is WIDE (a column per month) and most cells are "
                    f"blank, so only months where money actually moved are "
                    f"kept (T34)")
            if not _p.get("dated", True):
                # !! THEY WERE NOT TRANSLATED. This said "were translated",
                #   which is false: with no cut-off date on the deal there is
                #   nothing to translate them against, so the seller's labels
                #   are KEPT AS THEY ARE. A review sheet claiming work that
                #   did not happen is worse than one that says nothing.
                _cav.append(
                    "the seller dates payments RELATIVE to the cut-off "
                    "(`-12M`, `-1M`, `1M`...) and this deal has no cut-off "
                    "date, so the labels are KEPT AS THEY ARE in `period` "
                    "and `payment_month` is NULL. Nothing was translated; "
                    "anchoring them needs a cut-off date from the seller")
                try:
                    _wp = pd.read_parquet(_pf)
                    if "period" in _wp.columns:
                        _post = _wp[~_wp["period"].astype(str).str.startswith("-")]
                        if len(_post):
                            # !! POST-CUT-OFF PAYMENTS ARE KEPT ON PURPOSE,
                            #   and they are an asset, not a contaminant. A
                            #   seller's tape is struck weeks or months before
                            #   the book actually registers, and the interim
                            #   collections are the only record of what was
                            #   paid in that gap - money that is already gone
                            #   by the time we own the loans. Dropping them
                            #   would hide it. The caveat is that they must
                            #   not be summed WITH the pre-cut-off months
                            #   when the question is "what did this book owe
                            #   at cut-off", which is a different question.
                            _cav.append(
                                f"{len(_post):,} row(s) sit AFTER the cut-off "
                                f"({', '.join(sorted(set(_post['period'].astype(str))))})"
                                f" - EUR {_post.payment_amount.sum():,.2f} of "
                                f"INTERIM collections. KEPT deliberately: a "
                                f"tape is struck before the book registers, "
                                f"and these are the only record of what was "
                                f"paid in that gap. Filter on `period` when "
                                f"you want one side or the other")
                except Exception:
                    pass
            try:
                _w = pd.read_parquet(_pf)
                _neg = int((_w.payment_amount < 0).sum())
                if _neg:
                    _cav.append(
                        f"{_neg:,} row(s) are NET NEGATIVE - a refund "
                        f"exceeding receipts in that month. Real, not an error")
            except Exception:
                pass
            if _cav:
                L += ["**Caveats on this file.** None of these is a defect; "
                      "each is a thing a",
                      "reader could otherwise misread:", ""]
                L += [f"- {c}" for c in _cav] + [""]

    L += [f"## {int(_s4) + 1}. Approve", ""]
    if d.get("approved") and d.get("approved_output_md5") == _live:
        L += [f"**APPROVED** by {d.get('reviewed_by', '?')} on "
              f"{d.get('reviewed_at', '?')}.", "",
              "The signature covers the output file as it stands now "
              f"(`{str(_live)[:12]}`).", "",
              "Re-approving is not needed and not possible without a change: if "
              "the output",
              "moves, this line turns to APPROVED-STALE and the deal must be "
              "reviewed again.",
              "", "    uv run python scripts/verify.py " + deal]
    elif d.get("approved"):
        # !! SAY WHICH FIELD MOVED, NOT JUST THAT SOMETHING DID. The output
        #   hash alone tells a reviewer their signature is void and nothing
        #   about what to re-read. The approval pinned every field's mapping,
        #   so the diff is free.
        _moved = [f for f, sig in (d.get("approved_mappings") or {}).items()
                  if mapping_of(deal, f) != sig]
        _tape_moved = (d.get("approved_tape_md5")
                       and d["approved_tape_md5"] != tape_md5(deal))
        if _moved or _tape_moved:
            L += ["**What changed since you signed:**", ""]
            if _tape_moved:
                L.append("- the RAW TAPE itself -- everything below is rebuilt "
                         "from different data")
            for f in sorted(_moved):
                L.append(f"- `{f}` -- was `{d['approved_mappings'][f]}`, "
                         f"now `{mapping_of(deal, f)}`")
            L.append("")
        L += ["**APPROVED-STALE.** This deal was signed off by "
              f"{d.get('reviewed_by', '?')} on {d.get('reviewed_at', '?')}, "
              "**and the output has changed since**.", "",
              f"    signed   {str(d.get('approved_output_md5'))[:12]}",
              f"    current  {str(_live)[:12]}", "",
              "The signature no longer covers what is in `accounts/`. Read the "
              "backtest diff,",
              "then approve again if the change is right:", "",
              "```sh", f"uv run python scripts/review.py {deal} --approve", "```"]
    elif d.get("open_rejections"):
        L += [f"**NOT APPROVED -- {len(d['open_rejections'])} open rejection(s).**",
              ""]
        for r in d["open_rejections"]:
            L.append(f"- `{r['field']}` -- {r['reason']}  "
                     f"({r.get('raised_by', '?')}, {r.get('raised_at', '?')})")
        L += ["", "Fix the mapping, re-run the deal, then "
              f"`--resolve <field>` before approving."]
    else:
        L += ["```sh", f"uv run python scripts/review.py {deal} --approve", "```",
              "",
              "Until then the deal is cleaned but **unreviewed** -- nobody has "
              "confirmed",
              "that any JUDGEMENT row means what it says."]

    (out / "REVIEW.md").write_text(ascii_only("\n".join(L) + "\n"))
    print(f"wrote cleaning-context/{deal}/REVIEW.md")
    print(f"  {len(prov)} proven (skip) - {len(jud)} to read - {len(missing)} unavailable")
    # !! DO NOT INVITE AN APPROVAL THAT ALREADY EXISTS. Printing "approve
    #   with: ..." under a deal that is already signed reads as if the
    #   approval had not registered, and invites a second one.
    if d.get("approved") and d.get("approved_output_md5") == _live:
        print(f"  APPROVED by {d.get('reviewed_by', '?')} on "
              f"{d.get('reviewed_at', '?')} -- nothing to do")
    elif d.get("approved"):
        print(f"  APPROVED-STALE -- signed on {d.get('reviewed_at', '?')}, "
              f"output has changed since. Review again.")
    else:
        print(f"  approve with:  uv run python scripts/review.py {deal} --approve")
    return 0


if __name__ == "__main__":
    argv = sys.argv[1:]
    a = [x for x in argv if not x.startswith("--")]
    rej = None
    if "--reject" in argv:
        i = argv.index("--reject")
        rej = argv[i + 1] if len(argv) > i + 1 else None
        a = [x for x in a if x != rej]
    if "--note" in argv or "--answer" in argv or "--close" in argv:
        # !! NOT EVERYTHING A REVIEWER THINKS IS ABOUT ONE FIELD. Reading a
        #   sheet produces questions that span fields, or belong to no field
        #   at all - "why do only 673 of 32,529 loans have a claim?", "is this
        #   the right month?". Forcing those into a per-field confirm either
        #   loses them or files them under the wrong row.
        #   A note follows the SAME loop as a rejection, so there is one
        #   mental model: you raise it, the AGENT must answer it, you close
        #   it. It blocks approval until closed, because a note nobody has to
        #   answer is a wishlist.
        deal = a[0]
        out = _P.CONTEXT / deal
        d = load_decisions(out)
        d.setdefault("notes", [])
        now = f"{pd.Timestamp.now():%Y-%m-%d %H:%M}"
        if "--note" in argv:
            i = argv.index("--note")
            text = argv[i + 1] if len(argv) > i + 1 else None
            if not text or text.startswith("--"):
                print("--note needs the text of the note", file=sys.stderr)
                sys.exit(2)
            nid = max([n["id"] for n in d["notes"]], default=0) + 1
            d["notes"].append({"id": nid, "raised_by": "sharlene",
                               "raised_at": now, "text": text,
                               "state": "open", "answer": None})
            print(f"{deal}: note {nid} raised. It blocks approval until the "
                  f"agent answers it and you close it.")
        elif "--answer" in argv:
            i = argv.index("--answer")
            nid = int(argv[i + 1])
            text = next((x for x in argv[i + 2:] if not x.startswith("--")), None)
            n = next((x for x in d["notes"] if x["id"] == nid), None)
            if not n:
                print(f"{deal}: no note {nid}", file=sys.stderr)
                sys.exit(2)
            n.update({"answer": text or "(no answer given)",
                      "answered_at": now, "state": "answered"})
            print(f"{deal}: note {nid} answered. It stays open until you "
                  f"close it.")
        else:
            i = argv.index("--close")
            nid = int(argv[i + 1])
            n = next((x for x in d["notes"] if x["id"] == nid), None)
            if not n:
                print(f"{deal}: no note {nid}", file=sys.stderr)
                sys.exit(2)
            if n.get("state") != "answered" and "--anyway" not in argv:
                print(f"REFUSED -- note {nid} has not been answered yet:\n"
                      f"    {n['text']}\n\nThe agent answers with "
                      f"`--answer {nid} \"what was done\"`. To close it "
                      f"unanswered,\nsay so: `--close {nid} --anyway "
                      f"\"why\"`.", file=sys.stderr)
                sys.exit(1)
            n.update({"state": "closed", "closed_at": now,
                      "closed_note": next((x for x in argv[i + 2:]
                                           if not x.startswith("--")), None)})
            print(f"{deal}: note {nid} closed.")
        save_decisions(out, d)
        main(deal)
        openn = [x for x in d["notes"] if x["state"] != "closed"]
        print(f"  {len(openn)} note(s) still open.")
        sys.exit(0)

    if "--confirm" in argv:
        # !! THE SHEET MUST EMPTY AS THE WORK IS DONE. Every judgement row was
        #   listed on every regeneration forever, so a deal half-reviewed
        #   looked exactly like a deal nobody had opened, and "nothing left to
        #   address" was a state the document could not express. Confirming a
        #   field moves it OUT of the open queue and into the settled record -
        #   the review shrinks, decisions.yaml grows, and an empty section 3
        #   means genuinely nothing is outstanding.
        i = argv.index("--confirm")
        fld = argv[i + 1]
        deal = a[0]
        out = _P.CONTEXT / deal
        d = load_decisions(out)
        note = next((x for x in argv[i + 2:] if not x.startswith("--")), None)
        reg = pd.read_csv(_P.REGISTRY).query("deal_id == @deal")
        if fld not in set(reg.target_field):
            print(f"{deal}: `{fld}` is not mapped on this deal.", file=sys.stderr)
            sys.exit(2)
        d.setdefault("confirmed", [])
        d["confirmed"] = [c for c in d["confirmed"] if c["field"] != fld]
        d["confirmed"].append({
            "field": fld, "by": "sharlene",
            "at": f"{pd.Timestamp.now():%Y-%m-%d %H:%M}",
            # pin the mapping, so a later change to it re-opens the question
            "mapping": mapping_of(deal, fld),
            "tape_md5": tape_md5(deal),
            "note": note or "(confirmed, no note)"})
        save_decisions(out, d)
        main(deal)
        left = len([r for _, r in reg.iterrows()
                    if r.role in ("base", "enrich", "party", "align")]) \
            - len(d["confirmed"])
        print(f"{deal}: `{fld}` confirmed. {max(left, 0)} mapping(s) still "
              f"unconfirmed.")
        sys.exit(0)

    if "--resolve" in argv:
        i = argv.index("--resolve")
        fld = argv[i + 1]
        deal = a[0]
        out = _P.CONTEXT / deal
        d = load_decisions(out)
        hit = [r for r in d.get("open_rejections", []) if r["field"] == fld]
        if not hit:
            print(f"{deal}: no open rejection on `{fld}`.", file=sys.stderr)
            sys.exit(2)
        was = hit[0].get("mapping_when_rejected")
        now = mapping_of(deal, fld)
        # !! A RESOLUTION MUST POINT AT A CHANGE. Clearing a rejection used to
        #    be a one-line delete: reject a field, change nothing, resolve,
        #    approve - and the audit trail showed a question raised and
        #    answered when nothing had been answered at all.
        if was is None and "--anyway" not in argv:
            # a rejection raised before the mapping was pinned: there is
            # nothing to compare against, and silently accepting that defeats
            # the check for exactly the rejections that are oldest
            print(f"REFUSED -- this rejection predates the mapping check, so "
                  f"there is no\nrecord of what `{fld}` looked like when you "
                  f"rejected it. It is now:\n    {now}\n", file=sys.stderr)
            print("Nothing can verify the mapping changed. Confirm it "
                  "explicitly:\n"
                  f'    review.py {deal} --resolve {fld} --anyway "what was '
                  f'changed, or why it was right"', file=sys.stderr)
            sys.exit(1)
        if was is not None and was == now and "--anyway" not in argv:
            print(f"REFUSED -- `{fld}` is mapped exactly as it was when you "
                  f"rejected it:\n    {now}\n", file=sys.stderr)
            print("Change the mapping in mappings.csv and re-run the deal "
                  "first.\nIf the mapping was right all along and the "
                  "rejection was mistaken,\nsay so explicitly:\n"
                  f'    review.py {deal} --resolve {fld} --anyway "why it was '
                  f'right after all"', file=sys.stderr)
            sys.exit(1)
        note = next((x for x in argv[i + 2:] if not x.startswith("--")), None)
        d["open_rejections"] = [r for r in d.get("open_rejections", [])
                                if r["field"] != fld]
        d.setdefault("resolved", []).append(
            {"field": fld, "at": f"{pd.Timestamp.now():%Y-%m-%d %H:%M}",
             "was": was, "now": now,
             "unchanged": was == now,
             "note": note or ("the mapping was changed" if was != now
                              else "(no reason given)")})
        save_decisions(out, d)
        print(f"{deal}: `{fld}` resolved.")
        if was != now:
            print(f"    was  {was}")
            print(f"    now  {now}")
        print(f"  {len(d['open_rejections'])} rejection(s) still open.")
        sys.exit(0)
    sys.exit(main(a[0] if a else "PT15018", "--approve" in argv,
                  reject=rej, reason=(a[1] if rej and len(a) > 1 else None)))
