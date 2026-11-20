"""Which traps have earned promotion to a deterministic check?

    uv run python scripts/promote.py                      # what is due
    uv run python scripts/promote.py --skip T9 "reason"   # decided NOT to, and why
    uv run python scripts/promote.py --done T9 detector   # wrote it; record it

YOUR PART IS THE DECISION, NOT THE TYPING. The rule says what is DUE; you say
whether it is WORTH it, because some traps genuinely cannot be checked:

  worth promoting   the symptom is visible in the file or the output, and the
                    check is cheap. Nearly all of them.
  not worth it      no deterministic signal exists. T13 (a short token matching
                    by chance) is a JUDGEMENT about evidence, not a condition a
                    function can test. `--skip` records that, with the reason, so
                    the report stops asking and the reasoning survives.

A skip is a decision, not a dismissal: it stays visible in the listing as SKIPPED
with your reason, so a later deal can overturn it.

Reads traps.yaml and reports what should move up the ladder. Promotion decided by
a rule, not by whoever remembers - a trap seen on five deals and still sitting in
prose is a trap that will be hit a sixth time.

THE LADDER, and what each rung costs to skip:

    TRAP      prose. A human must READ it and recognise the symptom.
              Costs: nothing if nobody looks.
    DETECTOR  a function over the RAW tape, run before any mapping exists.
              Answers "is this present in this file?" - so the agent is TOLD
              rather than having to discover it.
    GUARD     an assertion over the OUTPUT. Fails the run.
              Answers "did this happen to this deal?"
    CASE      a test over the ENGINE, needing no deal at all. Milliseconds.
              Answers "can this defect still occur?"

A trap can hold more than one rung. T2 (duplicate files) is a detector AND a
guard AND a case, because it is cheap at every level.

!! DETECTOR AND GUARD ARE NOT THE SAME THING, and conflating them is why defects
   recur. A DETECTOR looks at the INPUT and warns. A GUARD looks at the OUTPUT and
   refuses. A detector cannot fail a run; a guard cannot see a problem that never
   reached the output. The Portuguese months (T1) silently dropped 22 of 26
   months - no guard could see it, because the output was internally consistent.
   Only a detector reading the raw headers catches that.

PROMOTION RULE:

    seen on 1 deal    stays prose, unless detection is structural and cheap
    seen on 2 deals   -> DETECTOR, if the symptom is visible in the raw tape
    seen on 3 deals   -> GUARD, if a deterministic assertion exists
    engine-level      -> CASE immediately, whatever the count. A defect in a
                         shared function is not a per-deal problem.

DEMOTION is rare and deliberate: a guard that has never fired across five or more
deals AND costs real time. These cost microseconds, so the honest default is
never.
"""
import sys
from pathlib import Path
import yaml

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent


DEC = BASE / "promotion-decisions.yaml"


def decisions():
    return yaml.safe_load(DEC.read_text()) if DEC.exists() else {}


def record(tid, verb, detail):
    d = decisions()
    d[tid] = {"decision": verb, "detail": detail,
              "by": "sharlene", "at": str(__import__("datetime").date.today())}
    DEC.write_text(yaml.safe_dump(d, sort_keys=False, width=100))
    print(f"{tid}: recorded as {verb} - {detail}")


def main():
    traps = {}
    for _f in _P.TRAP_FILES:
        traps.update(yaml.safe_load(_f.read_text()) or {})
    dec = decisions()
    cases = (HERE / "cases.py").read_text()

    rows = []
    for tid, t in traps.items():
        if not isinstance(t, dict):
            continue
        n = len(t.get("seen_on") or {})
        has_det = bool(t.get("detector"))
        has_gd = bool(t.get("guard"))
        has_case = f'@case("{tid}"' in cases
        skipped = dec.get(tid, {}).get("decision") == "skip"
        want = []
        if skipped:
            pass
        elif n >= 2 and not has_det:
            want.append("DETECTOR")
        if not skipped and n >= 3 and not has_gd:
            want.append("GUARD")
        if not skipped and n >= 2 and not has_case:
            want.append("CASE")
        title = str(t.get("title", ""))[:44]
        if skipped:
            title += "   SKIPPED: " + str(dec[tid].get("detail", ""))[:40]
        rows.append((tid, n, has_det, has_gd, has_case, want, title))

    rows.sort(key=lambda r: (-len(r[5]), -r[1]))
    print(f"{'trap':<6}{'deals':>6}  {'det':^5}{'guard':^7}{'case':^6}  title")
    print("-" * 78)
    for tid, n, d, g, c, want, title in rows:
        mark = lambda b: " yes " if b else "  -  "
        flag = "  <- " + ", ".join(want) if want else ""
        print(f"{tid:<6}{n:>6}  {mark(d)}{mark(g):^7}{mark(c):^6}  {title}{flag}")

    due = [r for r in rows if r[5]]
    print(f"\n{len(due)} trap(s) due for promotion." if due
          else "\nNothing due. Every trap sits at the rung its frequency earns.")
    for tid, n, _, _, _, want, title in due:
        print(f"  {tid}: seen on {n} deal(s) -> add {', '.join(want)}")
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if "--skip" in a:
        i = a.index("--skip")
        sys.exit(record(a[i + 1], "skip", a[i + 2] if len(a) > i + 2 else "(no reason)"))
    if "--done" in a:
        i = a.index("--done")
        sys.exit(record(a[i + 1], "done", a[i + 2] if len(a) > i + 2 else "promoted"))
    sys.exit(main())
