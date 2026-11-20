"""Add a column to the target schema, safely, with the procedure ENFORCED.

    uv run python scripts/add_column.py collateral_type string "the tape does not describe collateral"

Not a checklist in a README that someone follows three steps of. The order is the
safety, so the order is the code:

    1  REFUSE unless the backtest is already green. If the baseline is stale you
       cannot tell what YOUR change did from what was already broken.
    2  add the column to schema.yaml (the single source -- nothing else hardcodes
       a column list)
    3  re-run every deal that has already been cleaned
    4  backtest. The ONLY acceptable verdict is ADDITIVE: the new column appears
       and EVERY EXISTING VALUE IS BYTE-IDENTICAL, hashed per column so offsetting
       changes cannot hide.
    5  ADDITIVE  -> re-snapshot, done.
       REGRESSED -> ROLL BACK schema.yaml and report what moved. The column is
                    not added. You are told exactly which values changed.

!! WHY THE ROLLBACK MATTERS. Three separate "improvements" today each silently
  dropped a population -- 31,000 loans, then 882 (EUR 15.4m), then 107
  (EUR 1,673,770.57). None raised an error; each looked like an improvement. A
  procedure that cannot refuse is not a procedure.
"""
import subprocess
import sys
from pathlib import Path

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
ACC = _P.ACCOUNTS


def run(script, *args):
    r = subprocess.run([sys.executable, str(HERE / script), *args],
                       capture_output=True, text=True)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main(name, ctype, null_means):
    schema = _P.SCHEMA
    original = schema.read_text()

    if f"name: {name}," in original:
        print(f"`{name}` is already in schema.yaml -- nothing to do")
        return 1

    print("1 - is the baseline clean?")
    rc, out = run("backtest.py")
    if rc:
        print(out)
        print("\n  REFUSED. The backtest is not green BEFORE your change, so its\n"
              "  verdict afterwards would be meaningless. Resolve that first.")
        return 2
    print("    green -- safe to proceed\n")

    print(f"2 - adding `{name}` to schema.yaml")
    line = (f'  - {{name: {name},{" " * max(1, 20 - len(name))}type: {ctype},'
            f'  null_means: "{null_means}"}}\n')
    schema.write_text(original.replace("  - {name: source,", line + "  - {name: source,"))
    print(f"    {line.strip()}\n")

    deals = sorted(p.stem for p in ACC.glob("*.parquet"))
    print(f"3 - re-running {len(deals)} cleaned deal(s)")
    for d in deals:
        rc, out = run("clean_accounts.py", d)
        if rc:
            schema.write_text(original)
            print(f"    {d} FAILED to clean -- schema.yaml rolled back\n{out}")
            return 1
        print(f"    {d} ok")

    print("\n4 - backtest -- did anything EXISTING move?")
    rc, out = run("backtest.py")
    print("    " + out.replace("\n", "\n    ").strip())

    if "REGRESSED" in out:
        schema.write_text(original)
        print("\n5 - ROLLED BACK. `{}` was NOT added.".format(name))
        print("    An existing value moved, which means this column is not purely\n"
              "    additive. Read the diff above before trying again.")
        for d in deals:
            run("clean_accounts.py", d)
        return 1

    print("\n5 - ADDITIVE -- re-snapshotting the baseline")
    run("backtest.py", "--snapshot")
    print(f"\n{'='*70}\n`{name}` added. Every existing value byte-identical.\n"
          f"Next: add mappings.csv rows for the deals whose tape carries it.\n{'='*70}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3]))
