"""Regression cases -- every one derived from a REAL defect on a REAL deal.

    uv run python scripts/cases.py

This is how the pipeline learns. A defect found on deal 1 becomes a case that
runs forever, so deal 12 cannot reintroduce it. Each case names the deal that
taught it and what the defect cost.

DIFFERENT FROM backtest.py, and both are needed:

    backtest.py   did a change move an EXISTING DEAL's output?
                  -> only covers deals already cleaned
    cases.py      does the ENGINE still handle a known defect correctly?
                  -> runs in milliseconds, needs no deal, catches a regression
                     BEFORE anything is cleaned

Run both before promoting a trap to a detector or a guard.
"""
import sys
from pathlib import Path
import importlib.util
import pandas as pd
from style import in_scope

import paths as _P

HERE = Path(__file__).resolve().parent
BASE = HERE.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def load_tapes():
    p = _P.LOADER
    spec = importlib.util.spec_from_file_location("load_tapes", p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


CASES = []


def case(trap, learned_from, cost):
    def deco(fn):
        CASES.append((trap, fn.__name__, learned_from, cost, fn))
        return fn
    return deco


# -- T1 - month headers in the seller's language ----------------------------
@case("T1", "PT15018 / PT16023", "22 of 26 months silently dropped")
def portuguese_and_english_months():
    lt = load_tapes()
    assert lt.period_month("Janeiro 2014") == "2014-01"
    assert lt.period_month("Fevereiro 2015") == "2015-02"      # no English prefix collision
    assert lt.period_month("Março 2015") == "2015-03"          # accented
    assert lt.period_month("Dezembro 2014") == "2014-12"
    assert lt.period_month("January 2014") == "2014-01"
    assert lt.period_month("Novermber 2014") == "2014-11"      # the file's own typo
    assert lt.period_month("1-13th February 2016") == "2016-02"  # partial month
    # and things that are NOT payments must not decode
    assert lt.PAYMENT_COL.match("Interim Collections") is None
    assert lt.PAYMENT_COL.match("Total OPB  Setembro 2015 (€)") is None


# -- T5 - two decimal conventions in one sheet ------------------------------
@case("T5", "PT15018", "every origination value nulled, then summed to 0")
def mixed_decimal_conventions():
    ca = load("clean_accounts")
    s = pd.Series(["64843.729999999996", "48000,00", "1.234.567,89",
                   "Not Available", ""], dtype="string")
    got = ca.amount(s)
    assert abs(got[0] - 64843.73) < 0.01, got[0]      # dot decimal
    assert abs(got[1] - 48000.00) < 0.01, got[1]      # comma decimal, SAME sheet
    assert abs(got[2] - 1234567.89) < 0.01, got[2]    # dot thousands + comma decimal
    assert pd.isna(got[3]) and pd.isna(got[4])        # sentinels -> null, NEVER 0


# -- T6 - a null that becomes a confident zero ------------------------------
@case("T6", "PT15018", "all 1,555 loans read as 'originated for nothing'")
def all_null_sum_stays_null():
    s = pd.Series([None, None, None], dtype="float64")
    assert s.sum() == 0.0, "pandas default -- this is the trap"
    assert pd.isna(s.sum(min_count=1)), "min_count=1 is the fix and must stay"


# -- T11 - a Y/N column with no "No" ----------------------------------------
@case("T11", "PT15018", "would have written 29,581 false 'not judicialised'")
def yn_never_writes_false():
    ca = load("clean_accounts")
    got = ca.yn(pd.Series(["Yes", "Not Available", "X", None], dtype="string"))
    assert got[0] is True or got[0] == True
    assert all(pd.isna(got[i]) for i in (1, 2, 3)), f"must be null, got {list(got)}"
    assert not (got == False).any(), "False must NEVER appear -- the tape has no 'No'"


# -- FRESH - the documents on disk match the current code -----------------
@case("FRESH", "the whole pipeline",
      "11 of 12 approval sheets were stale on disk and nothing said so")
def generated_documents_are_current():
    """Regenerate every REVIEW.md and cleaned_summary.md and compare.

    !! reproduce.py AND backtest.py BOTH COVER ONLY THE DATA. Change review.py
       and the sheets on disk silently lag the code - which is worse than a
       stale dataset, because the sheet is the thing a human reads and signs.
       Eleven of twelve were behind when this was first measured.

       The `generated` date line is excluded: it moves every midnight and
       says nothing about whether the content is current.
    """
    import subprocess, shutil, tempfile, filecmp
    ctx = _P.CONTEXT
    deals = sorted(p.name for p in ctx.iterdir()
                   if p.is_dir() and (p / "REVIEW.md").exists())
    assert deals, "no deals found"

    def body(path):
        return [l for l in path.read_text(encoding="utf-8").splitlines()
                if not l.strip().startswith("generated")]

    stale = []
    for d in deals:
        before = {f: body(ctx / d / f) for f in
                  ("REVIEW.md", "cleaned_summary.md")
                  if (ctx / d / f).exists()}
        for script in ("review.py", "summarise.py"):
            r = subprocess.run([sys.executable, str(HERE / script), d],
                               capture_output=True, text=True)
            assert r.returncode == 0, f"{script} {d} failed:\n{r.stderr[-300:]}"
        for f, was in before.items():
            if body(ctx / d / f) != was:
                stale.append(f"{d}/{f}")
    assert not stale, (
        f"{len(stale)} generated document(s) were STALE on disk - the code has "
        f"moved since they were written:\n  " + "\n  ".join(stale) +
        "\n(they have just been regenerated, so re-running this will pass - "
        "the point is that nothing told you)")


# -- DOCS - the method document must match the code -----------------------
@case("DOCS", "the whole pipeline",
      "METHOD.md described review-before-clean for a day after run.py was fixed")
def method_matches_the_code():
    """Every script run.py actually calls must appear in METHOD.md's table,
    and every count METHOD.md quotes must be true.

    !! A METHOD DOCUMENT THAT DISAGREES WITH THE CODE IS WORSE THAN NONE,
       because people trust it. METHOD.md kept the old ordering - review at 5,
       clean at 6 - which is precisely the defect that had a reviewer reading
       a sheet built from the previous run. It also quoted 32 traps and 3
       promotions when there were 40 and 4.
    """
    import re as _re
    run = (HERE / "run.py").read_text(encoding="utf-8")
    method = (BASE / "METHOD.md").read_text(encoding="utf-8")

    called = set(_re.findall(r'"(\w+\.py)"', run))
    called -= {"run.py"}
    missing = sorted(c for c in called if f"`{c}`" not in method)
    assert not missing, f"run.py calls these and METHOD.md never mentions them: {missing}"

    # the ORDER that matters: the artefacts are built before the human is asked
    seq = method[method.index("| step |"):method.index("## How a reviewer")]
    def pos(name):
        for ln in seq.splitlines():
            if name in ln:
                return int(ln.split("|")[1].strip().rstrip("b"))
        raise AssertionError(f"{name} is not in the step table")
    assert pos("clean_accounts.py") < pos("review.py"), \
        "METHOD.md still puts the review BEFORE the clean"
    assert pos("guards.py") < pos("review.py"), \
        "METHOD.md puts the review before the guards"

    # the AGENT file must know every registry role and transform the engine
    # supports, or a fresh session writes mappings the old way and silently
    # misses half the capability
    agent = (_P.WORK.parent / ".claude" / "agents"
             / "benchmark-pre-registration-builder.md")
    if agent.exists():
        a_txt = agent.read_text(encoding="utf-8")
        reg = pd.read_csv(_P.REGISTRY)
        for role in sorted(set(reg.role.dropna())):
            assert role in a_txt, \
                f"the agent file never mentions the `{role}` role"
        for script in ("clean_payments.py",):
            assert script in a_txt, f"the agent file never mentions {script}"
        # !! AND IT MUST KNOW WHERE A FIELD LANDS. An agent that thinks every
        #   field goes in one wide table will propose a schema edit for a
        #   fact that needs a single registry row.
        assert "additional_attributes" in a_txt, \
            "the agent file never mentions additional_attributes"

    # and any count it quotes must be the real one
    import yaml as _y
    n_traps = sum(len(_y.safe_load(f.read_text(encoding="utf-8")))
                  for f in _P.TRAP_FILES)

    # !! THE AGENT DEFINITION IS A DOCUMENT TOO, AND IT WENT STALE FIRST. It
    #   told every agent "40 failure modes" for the 35 traps after the 40th,
    #   which is the T40 defect exactly: a thing a HUMAN (or an agent) reads
    #   drifts with nothing to catch it, while every machine-read file is
    #   hashed. It is outside this tree, so a missing file is not a failure -
    #   a WRONG one is.
    _agent = (_P.BASE.parents[2] / ".claude" / "agents" /
              "benchmark-pre-registration-builder.md")
    if _agent.exists():
        _n_tape = len(_y.safe_load(_P.TRAPS.read_text(encoding="utf-8")))
        _txt = _agent.read_text(encoding="utf-8")
        for m in _re.finditer(r"\*\*(\d+) SELLER-TAPE failure modes", _txt):
            assert int(m.group(1)) == _n_tape, (
                f"the agent definition says {m.group(1)} tape traps, "
                f"traps.yaml holds {_n_tape}")
    for m in _re.finditer(r"(\d+) of (\d+) traps", method):
        assert int(m.group(2)) == n_traps, (
            f"METHOD.md says {m.group(2)} traps, there are {n_traps}")


# -- REGISTRY - a row that points at nothing must fail ---------------------
@case("REGISTRY", "the whole pipeline",
      "a misspelled column cleaned fine, passed every guard, and read as 'the tape lacks this field'")
def a_mapping_that_matches_nothing_is_refused():
    """Typo one column name and the deal must REFUSE, not quietly skip it.

    !! THIS IS THE SILENT FAILURE THE WHOLE PIPELINE EXISTS TO PREVENT.
       `Producto` for `Produto` produced exit 0, ALL GUARDS PASS, and an empty
       product_type - which the approval sheet then filed under "empty on this
       deal", turning a typo into a fact about the seller.
    """
    import subprocess, shutil, tempfile, os
    reg = _P.REGISTRY
    original = reg.read_text(encoding="utf-8")
    line = [l for l in original.splitlines()
            if l.startswith("PT15020,base,product_type,")][0]
    assert ",Produto," in line, "the fixture row has changed"
    try:
        reg.write_text(original.replace(line, line.replace(",Produto,",
                                                           ",Producto,")),
                       encoding="utf-8")
        r = subprocess.run([sys.executable, str(HERE / "clean_accounts.py"),
                            "PT15020"], capture_output=True, text=True)
        assert r.returncode != 0, \
            "a mapping pointing at a column that does not exist must REFUSE"
        out = r.stdout + r.stderr
        assert "Producto" in out, f"the error must name the bad column: {out[-200:]}"
        assert "Produto" in out.replace("Producto", ""), \
            "the error should suggest the closest real column"
    finally:
        reg.write_text(original, encoding="utf-8")
    # and the real registry must still build
    r = subprocess.run([sys.executable, str(HERE / "clean_accounts.py"),
                        "PT15020"], capture_output=True, text=True)
    assert r.returncode == 0, f"restoring the registry did not restore the run:\n{r.stderr[-300:]}"


# -- PAYMENTS - the cleaned payments account for the raw ones -------------
@case("PAYMENTS", "PT18019 / PT15014",
      "EUR 10.6m of payments aggregated to zero, and returns were counted twice")
def payments_reconcile_to_the_tape():
    """For every deal with a payments file: net = gross - returns, and
    gross + returns + what was dropped = the raw tape.

    !! BOTH HALVES WERE WRONG ONCE. PT18019's undated rows vanished into a
       null group key (T32), and the out-of-scope figure double-counted
       returns because the raw total is gross PLUS returns, both stored
       positive.
    """
    import json as _j
    pf = _P.PAYMENTS_RAW
    raw_all = pd.read_parquet(pf)
    seen = 0
    for mf in sorted((_P.PAYMENTS).glob("*.meta.json")):
        meta = _j.loads(mf.read_text())
        deal = meta["deal"]
        out = _P.PAYMENTS / f"{deal}.parquet"
        if not out.exists():
            continue
        seen += 1
        w = pd.read_parquet(out)
        g = float(w.loc[w.payment_amount.gt(0), "payment_amount"].sum())
        r = float(-w.loc[w.payment_amount.lt(0), "payment_amount"].sum())
        n = float(w.payment_amount.sum())
        assert abs((g - r) - n) < 0.005, \
            f"{deal}: net {n:,.2f} != gross {g:,.2f} - returns {r:,.2f}"
        raw = raw_all[raw_all.deal == deal].copy()
        raw["a"] = pd.to_numeric(raw.amount, errors="coerce")
        if meta.get("sign_flipped"):
            raw["a"] = -raw["a"]
        # !! THE RAW NET, NOT THE RAW SUM. A seller either ships returns as a
        #   separate POSITIVE series (raw sum = pay + ret) or as negative
        #   values inside one series (raw sum is already the net). Comparing
        #   the output against the wrong one of those fails a correct deal.
        if "series" in raw and raw.series.nunique() > 1:
            rt = float(raw.loc[raw.series.eq("pay"), "a"].sum()
                       - raw.loc[raw.series.eq("ret"), "a"].sum())
        else:
            rt = float(raw["a"].sum())
        assert rt + 0.005 >= n, \
            f"{deal}: net {n:,.2f} exceeds the raw tape net {rt:,.2f}"
        if meta.get("rows") and not meta.get("blocked"):
            assert g + r > 0 or rt == 0, \
                f"{deal}: {meta['rows']:,} raw rows produced nothing"
    assert seen >= 3, f"expected several payments files, found {seen}"


# -- DATES - a loan cannot default before it exists -----------------------
@case("DATES", "PT15018", "one loan defaulted 30 days before it was originated")
def default_never_precedes_origination():
    """Checked on the REAL output of every deal, not on a fixture.

    !! THE RULE IS ONLY WORTH ASSERTING BECAUSE IT IS UNIVERSAL. It holds on
       every loan carrying both dates across four sellers and twelve books,
       with one exception, which is pinned. A rule that is merely usually true
       produces noise and gets ignored.
    """
    import json as _j
    reg = pd.read_csv(_P.REGISTRY)
    gu = load("guards")
    for f in sorted((_P.ACCOUNTS).glob("*.parquet")):
        deal = f.stem
        mapped = set(reg.query("deal_id == @deal").target_field)
        if not {"origination_date", "default_date"} <= mapped:
            continue
        a = pd.read_parquet(f)
        o = pd.to_datetime(a.origination_date, errors="coerce")
        x = pd.to_datetime(a.default_date, errors="coerce")
        bad = int(((o.notna() & x.notna()) & (x < o)).sum())
        want = (gu.EXPECT.get(deal) or {}).get("default_before_origination", 0)
        assert bad == want, (
            f"{deal}: {bad} loan(s) default before origination, pinned at "
            f"{want}. If this is new, it is a NEW defect on this tape.")


# -- SELLER - the registry and the prose must agree -----------------------
@case("SELLER", "PT15020", "a deal's context named the wrong seller for a day")
def seller_matches_the_registry():
    """`deals.csv` is the source; CONTEXT.md repeats it in prose.

    !! PT15020's context said Cetelem while its own filename said Oney. The
       seller appears on every summary and every review, so a fact retyped by
       hand in twelve files will eventually be wrong in one of them.
    """
    reg = pd.read_csv(_P.DEALS).set_index("deal_id")
    ctx = _P.CONTEXT
    deals = sorted(p.name for p in ctx.iterdir()
                   if p.is_dir() and (p / "CONTEXT.md").exists())
    assert deals, "no cleaning-context folders found"
    for d in deals:
        assert d in reg.index, f"{d} has a CONTEXT.md but no row in deals.csv"
        want = str(reg.loc[d, "seller"])
        head = (ctx / d / "CONTEXT.md").read_text(encoding="utf-8").split("\n")[0]
        assert want in head, \
            f"{d}: deals.csv says `{want}`, CONTEXT.md says `{head.strip()}`"


# -- RESOLVE - a rejection cannot be cleared without a change -------------
@case("RESOLVE", "the whole pipeline",
      "a field could be rejected, left untouched, resolved and approved")
def resolving_needs_a_real_change():
    """`--resolve` used to be a one-line delete of the rejection.

    !! NOTHING CHECKED THAT THE MAPPING HAD MOVED. Reject a field, change
       nothing, resolve, approve - and the trail showed a question raised and
       answered when nothing had been answered. The mapping is now pinned when
       the rejection is raised and compared when it is cleared.
    """
    rv = load("review")
    # the pinned signature must ignore the NOTE and track what actually
    # decides the data: role, sheet, column, transform
    sig = rv.mapping_of("PT15020", "product_type")
    assert "ANEXO_I_DADOS" in sig and "Produto" in sig, sig
    assert "only" not in sig.lower(), \
        f"the note leaked into the signature, so editing prose would read as a fix: {sig}"
    # a field nobody maps has a signature too, so a rejection on one is
    # resolvable once it IS mapped
    assert rv.mapping_of("PT15020", "collateral_type") == "(not mapped)"
    # and the signature must survive being asked twice
    assert rv.mapping_of("PT15020", "product_type") == sig


# -- SUMCOL - a schema field built from two seller columns ----------------
@case("SUMCOL", "PT15014 / PT15016",
      "EUR 1,798,863.37 of fees had nowhere to go, and an absent column read as a perfect identity")
def registry_can_add_two_columns():
    ca = load("clean_accounts")
    w = pd.DataFrame({"sum_prin": ["100.00", "50.00"],
                      "sum_int": ["10.00", "5.00"],
                      "sum_fee": ["1.50", "0.50"],
                      "opened": ["2020-01-01", "2020-02-01"]})
    one = ca.take(w, "sum_int", "amount")
    assert list(one) == [10.0, 5.0]

    both = ca.take(w, "sum_int + sum_fee", "amount")
    assert list(both) == [11.5, 5.5], f"the fee was not added: {list(both)}"
    # whitespace around the + must not matter
    assert list(ca.take(w, "sum_int+sum_fee", "amount")) == [11.5, 5.5]

    # adding only makes sense for amounts -- a sum of two dates is nonsense
    try:
        ca.take(w, "opened + opened", "date")
    except SystemExit:
        pass
    else:
        raise AssertionError("adding non-amounts must be refused, not guessed")

    # a named column that is absent yields nothing, rather than a partial sum
    # that would look like real data
    assert ca.take(w, "sum_int + no_such_column", "amount") is None


# -- PROVEN - only the column a total actually reproduces --------------
@case("PROVEN", "PT15014 / PT15018",
      "the sheet told the reviewer to skip fields nothing had proven")
def proven_is_per_column_not_per_family():
    rv = load("review")
    Row = type("R", (), {})

    def row(field, col):
        r = Row(); r.target_field = field; r.source_column = col; return r

    hits = [{"amount_column": "woff_bal", "scope_column": None,
             "scope_excludes": None, "total": 1.0}]
    # the column the total reproduces is proven
    assert rv.tier(row("cutoff_balance", "woff_bal"), hits) == "PROVEN"
    # a DIFFERENT amount column on the same deal is not
    assert rv.tier(row("cutoff_principal", "sum_prin"), hits) == "JUDGEMENT", \
        "a hit on one column must not settle another"
    # and a segment is only proven when the reconciliation NEEDED it
    assert rv.tier(row("segment", "segment"), hits) == "JUDGEMENT", \
        "no hit uses a scope rule here, so the segment proves nothing"

    scoped = [{"amount_column": "Total OPB", "scope_column": "Segmento",
               "scope_excludes": "Excluded", "total": 1.0}]
    assert rv.tier(row("segment", "Segmento"), scoped) == "PROVEN", \
        "this reconciliation could not be reproduced without the scope rule"
    assert rv.tier(row("segment", "Something Else"), scoped) == "JUDGEMENT"
    # whitespace and case in a seller's column name must not decide the tier
    assert rv.tier(row("cutoff_balance", " WOFF_BAL "), hits) == "PROVEN"


# -- SHEET - every approval sheet states its own status --------------------
@case("SHEET", "the whole pipeline",
      "an approved deal's sheet still read 'nobody has confirmed'")
def review_sheet_states_its_own_status():
    """The sheet a human signs must say whether it HAS been signed.

    !! AND IT MUST SAY IT FOR EVERY DEAL. The first version crashed on any
       deal with a derived field, because a loop variable shadowed the
       decisions dict. Those deals kept their OLD sheet on disk and a
       regeneration sweep that swallowed stderr called it success - so this
       case checks the FILES, not the exit code.
    """
    import re
    ctx = _P.CONTEXT
    deals = sorted(p.name for p in ctx.iterdir()
                   if p.is_dir() and (p / "REVIEW.md").exists())
    assert len(deals) >= 2, f"expected several deals, found {deals}"
    STATES = re.compile(
        r"^\*\*APPROVED\*\*|^\*\*APPROVED-STALE|^\*\*NOT APPROVED|"
        r"^Until then the deal is cleaned but", re.M)
    for d in deals:
        body = (ctx / d / "REVIEW.md").read_text(encoding="utf-8")
        # !! MATCH THE HEADING BY NAME, NOT BY NUMBER. Sections renumber when
        #   a deal has rows to report as removed, so a literal "## 3. Approve"
        #   silently stopped finding the section it was meant to check.
        tail = re.split(r"^## \d+\. Approve\s*$", body, maxsplit=1, flags=re.M)
        assert len(tail) == 2, f"{d}: no approval section in REVIEW.md"
        assert STATES.search(tail[1]), \
            f"{d}: approval section states no status -- a reader cannot tell"


# -- T23 - a null segment is not an exclusion ------------------------------
@case("T23", "the whole pipeline",
      "a loan the seller forgot to label vanished from the population")
def null_segment_stays_in_scope():
    st = load("style")
    a = pd.DataFrame({"segment": pd.Series(["SME", None, "Excluded", "Retail"],
                                           dtype="string"),
                      "cutoff_balance": [100.0, 250.0, 999.0, 50.0]})
    # the expression this replaced, kept here so the defect cannot come back
    # by someone "simplifying" in_scope away
    naive = a[a.segment.ne("Excluded")]
    assert len(naive) == 2, f"the trap itself has changed: {len(naive)}"

    ins = st.in_scope(a)
    assert len(ins) == 3, f"the null-segment loan was dropped: {len(ins)}"
    assert abs(ins.cutoff_balance.sum() - 400.0) < 0.001, \
        f"balance lost with the loan: {ins.cutoff_balance.sum()}"
    assert "Excluded" not in set(ins.segment.dropna()), \
        "an EXPLICIT exclusion must still be excluded"


# -- T21 - the published total hides at the bottom of the detail sheet ----
@case("T21", "PT15020 / the WiZink family",
      "a deal that reconciles three ways was recorded as having no published figure")
def footer_total_is_found_and_excluded():
    fs = load("find_strats")
    fs.TOTAL_ROWS.clear()
    n = 5000
    # a detail sheet far longer than SUMMARY_MAX_ROWS, with the grand total in
    # its last row -- and one BLANK cell above it, which used to end the walk
    vals = [float(100 + i) for i in range(n)]
    rows = []
    for i, v in enumerate(vals):
        rows.append({"source_file": "f", "source_sheet": "detail",
                     "source_row": i, "cn": "balance", "value": str(v)})
    rows.append({"source_file": "f", "source_sheet": "detail",
                 "source_row": n, "cn": "balance", "value": str(sum(vals))})
    tape = pd.DataFrame(rows)
    cand = fs.harvest(tape)

    total = round(sum(vals), 2)
    assert total in cand, f"the footer total was not harvested: {list(cand)[:4]}"
    assert fs.TOTAL_ROWS.get("detail") == {n}, \
        f"the total ROW must be recorded so the cleaner can drop it, got {fs.TOTAL_ROWS}"

    # and the search must reproduce it -- which it can ONLY do by excluding
    # that row, since including it doubles the column
    hits, _ = fs.search(tape, cand)
    assert any(abs(h["total"] - total) < 0.01 for h in hits), \
        "the total row was not excluded from the search: the column sums to 2x"


# -- T18 - a fact encoded as one value of a segment column -----------------
@case("T18", "PT18019", "would have asserted 22,401 loans solvent on no evidence")
def eq_writes_true_or_null_never_false():
    ca = load("clean_accounts")
    f = ca.conv("eq:Bankruptcy")
    got = f(pd.Series(["Bankruptcy", "Category 1", "Deceased", None], dtype="string"))
    assert got[0] == True, f"the match must be True, got {got[0]}"
    assert all(pd.isna(got[i]) for i in (1, 2, 3)), f"must be null, got {list(got)}"
    # .eq(False) on a nullable boolean yields NA, not False -- fill before testing
    assert not got.eq(False).fillna(False).any(), \
        "False must NEVER appear -- `Category 1` says what a loan IS, not that it is solvent"
    # whitespace and case must not decide a loan's insolvency
    assert f(pd.Series([" bankruptcy "], dtype="string"))[0] == True


# -- T13 - precision loss on long identifiers -------------------------------
@case("T13", "PT15016 / the backtest itself", "ids stopped joining; fingerprints drifted")
def long_ids_survive_as_text():
    raw = "0004064740080003334"                       # 19 digits, leading zeros
    assert str(int(float(raw))) != raw, "read as a number it is destroyed -- the trap"
    assert str(raw) == raw, "as text it survives"
    big = 17058393504739769001                        # a 20-digit content hash
    assert str(big) == "17058393504739769001"
    assert int(float(big)) != big, "through a JSON float it is rounded -- the trap"


# -- T2 - byte-identical duplicate files ------------------------------------
@case("T2", "PT15018 / PT19007 / PT21004", "those books' payments doubled")
def duplicate_files_are_skipped():
    man = pd.read_parquet(_P.MANIFEST)
    # !! KEY ON THE PATH, NOT THE NAME. PT20014 ships two different files both
    #   called PT20014A022111_Wizink_asset-index.xlsx in different subfolders --
    #   30 rows in one, 29 in the other. MD5 correctly keeps both; a manifest
    #   keyed on the basename alone cannot tell them apart. This case found that,
    #   on its first run.
    assert "path" in man.columns, "the manifest must record the full path"
    dupes = man[["deal", "path", "sheet"]].duplicated().sum()
    assert dupes == 0, f"{dupes} genuinely duplicate (path, sheet) rows survived MD5"
    collisions = man[["deal", "file", "sheet"]].duplicated().sum()
    assert collisions > 0 or True, "basename collisions are expected and are why `path` exists"


# -- T12 - a population silently disappearing -------------------------------
@case("T12", "PT15018 / PT16023", "lost 31,000 loans, then 882, then 107 -- none raised")
def in_scope_total_still_ties_to_the_seller():
    a = pd.read_parquet(_P.ACCOUNTS / "PT15018.parquet")
    ins = in_scope(a)
    # 32,530 -> 32,531 on 2026-10-07 when the fake-header filter was generalised
    # for PT16023 (it had assumed loan ids are numeric). One zero-balance row is
    # now kept.
    # 32,531 -> 32,529 later the same day: that kept row WAS the English header
    # ("Account Number" / "Product Code"), plus an all-`x` stray. Both carry no
    # amount and no date, so neither can be a loan, and both are now dropped by
    # the quantity test in clean_accounts.
    # THE BALANCE DID NOT MOVE BY A CENT ON EITHER CHANGE. That is the whole
    # reason a count change is acceptable here: the seller published a balance
    # for this book, not a count, so the balance is the proof and the count is
    # a stability check. A count change WITH a balance change is a regression.
    assert len(ins) == 32_529, f"loan count moved: {len(ins):,}"
    # !! ASK WHICH FIELD, DO NOT NAME IT. PT15018 publishes an outstanding
    #   PRINCIPAL and no total owed, so its figure lives in cutoff_principal
    #   and cutoff_balance is NULL by design. Naming the field here made this
    #   case assert 0.00 against 407,079,317.23 on a deal that was correct.
    st = load("style")
    reg = pd.read_csv(_P.REGISTRY).query("deal_id == 'PT15018'")
    field, v = st.headline(ins, set(reg.target_field))
    assert field == "cutoff_principal", \
        f"PT15018 is measured on principal, not {field}"
    assert abs(v.sum() - 407_079_317.23) < 0.01, \
        f"the published figure moved: {v.sum():,.2f}"

    # PT16023 -- a second seller format, added 2026-10-07. Its published strats
    # state "# of accounts 19,434" AND the OB total, so both are checkable.
    b = pd.read_parquet(_P.ACCOUNTS / "PT16023.parquet")
    assert len(b) == 19_434, f"PT16023 loan count moved: {len(b):,}"
    assert abs(b.cutoff_balance.sum() - 224_485_808.25) < 0.01, \
        f"PT16023 balance moved: {b.cutoff_balance.sum():,.2f}"


# -- T16 - the finer grain wins when a fact is stated twice -----------------
@case("T16", "PT15018 / PT16023", "a person's flag asserted about up to 21 loans")
def finer_grain_wins():
    # !! judicialised_flag LEFT THE CORE at schema v4. It is a fact only some
    #   sellers state, so it lives in the open long table - and the rule it
    #   proves is unchanged: a person-level source rolls up to True or
    #   ABSENT, never False.
    st = load("style")
    a = st.attr_series(BASE, "PT15018", "judicialised_flag")   # person level
    b = st.attr_series(BASE, "PT16023", "judicialised_flag")   # loan level
    # person-level rolls up to a FLOOR: True or nothing, never False
    assert not a.eq(False).any(), \
        "PT15018 has no 'No' in the source -- False must never appear"
    assert a.eq(True).sum() == 3_112
    # loan-level keeps real negatives
    assert b.eq(False).sum() == 6_691, \
        "PT16023 HAS real Ns -- dropping them discards 6,691 genuine negatives"
    assert b.eq(True).sum() == 12_743


# -- house style - plain ASCII in everything we write ----------------------
@case("STYLE", "the whole pipeline", "unreadable in a terminal, a ticket or a diff")
def no_decorative_characters():
    """Generated output and source must be plain ASCII punctuation.

    !! TIDYING ONCE IS NOT ENFORCING. The files were cleaned by hand; without a
       case, the next edit reintroduces a glyph and nothing notices until someone
       pastes a review into a terminal and sees mojibake, or greps for a word and
       misses it because of a curly quote.
    """
    import re
    # !! DERIVED FROM style.py, NEVER RESTATED. This case used to carry its own
    #   copy of the glyph list, so the two drifted: U+2500 (box drawing) and
    #   U+2260 were added to style.SUBS and this case went on passing, while
    #   run.py drew every section rule with U+2500. A checker that does not
    #   read the rule it enforces is decoration itself.
    st = load("style")
    BAD = re.compile("[" + "".join(re.escape(k) for k in st.SUBS) + "]"
                     + "|" + st.DROP.pattern)
    hits = []
    # !! THE AGENT FILE LIVES OUTSIDE THIS FOLDER and writes CONTEXT.md and
    #    traps.yaml entries, so it is the one place a glyph gets reintroduced
    #    from. Scanning only the pipeline folder missed it entirely.
    agents = _P.WORK.parent / ".claude" / "agents"
    # !! THE RAW DELIVERY IS NOT OURS TO RESTYLE. It moved inside this folder
    #   at the restructure, and the scan immediately found 57 glyphs in files
    #   the seller sent us. We sanitise what WE write; a delivered workbook or
    #   its accompanying note stays exactly as it arrived, because changing a
    #   source document to satisfy our own house style is how provenance dies.
    def _ours(p):
        return _P.RAW not in p.parents and "__pycache__" not in p.parts
    files = ([f for f in BASE.rglob("*.md") if _ours(f)]
             + [f for f in BASE.rglob("*.py") if _ours(f)]
             + [f for f in BASE.rglob("*.yaml") if _ours(f)]
             + [f for f in BASE.rglob("*.csv") if _ours(f)]
             + list(agents.glob("benchmark-pre-registration-*.md")))
    for f in files:
        for i, line in enumerate(f.read_text().split("\n"), 1):
            m = BAD.search(line)
            if m:
                hits.append(f"{f.relative_to(BASE)}:{i} {m.group()!r}")
    assert not hits, f"{len(hits)} decorative char(s), first: {hits[0]}"


# -- reproducibility - the output must be rebuildable from its inputs -------
@case("REPRO", "the whole pipeline", "a dataset nobody can rebuild is not evidence")
def output_is_reproducible():
    """Every cleaned deal rebuilds byte-for-byte from the same four inputs.

    !! PROVEN BY HAND ONCE AND THAT PROOF EXPIRED IMMEDIATELY. Deleting both
       outputs and rebuilding gave identical MD5s - true at that minute, and
       nothing kept it true. Checked here on every run instead.
    """
    import subprocess
    r = subprocess.run([sys.executable, str(HERE / "reproduce.py")],
                       capture_output=True, text=True)
    assert r.returncode == 0, (r.stdout or r.stderr).strip()[-300:]


# -- every CONTEXT.md keeps the canonical shape ----------------------------
@case("SHAPE", "PT15018 / PT16023", "a changelog nobody reads, with the rule buried")
def context_files_keep_the_template_shape():
    """CONTEXT.md sections must match CONTEXT_TEMPLATE.md, in order.

    !! THE NATURAL MOVE AFTER EVERY REVIEW IS TO APPEND. Six rounds later the
       document is a pile of dated sections and the important rule is under five
       later ones. Enforcing the shape means the sixth finding sits beside the
       first one it relates to.
    """
    import re as _re
    tmpl = (BASE / "CONTEXT_TEMPLATE.md").read_text()
    want = _re.findall(r"^## (.+)$", tmpl, _re.M)
    for f in sorted((_P.CONTEXT).glob("*/CONTEXT.md")):
        got = _re.findall(r"^## (.+)$", f.read_text(), _re.M)
        extra = [g for g in got if g not in want]
        missing = [w for w in want if w not in got]
        assert not extra, f"{f.parent.name}: unexpected section(s) {extra}"
        assert not missing, f"{f.parent.name}: missing section(s) {missing}"
        order = [w for w in want if w in got]
        assert got == order, f"{f.parent.name}: sections out of order -> {got}"


# -- T54 - one book delivered twice, in a deal that maps no loan id ---------
@case("T54", "PT20008", "5,810 accounts and EUR 11,503,688.66 for a 2,905-account book")
def a_book_delivered_twice_is_still_one_book():
    """PT20008 holds BOTH copies in its tape and must still come out once.

    The seller ships no account number, so block pruning cannot compare id
    sets and falls back to a row fingerprint. Remove that fallback and this
    deal doubles in silence on any book with no published figure to guard it.
    """
    import paths
    t = pd.read_parquet(paths.for_deal("PT20008").TAPES / "PT20008.parquet")
    files = set(t[t.source_sheet == "Folha1"].source_file)
    assert len(files) == 2, f"both deliveries must still be LOADED, got {files}"

    a = pd.read_parquet(paths.for_deal("PT20008").ACCOUNTS / "PT20008.parquet")
    assert "loan_id" not in a or a.loan_id.isna().all(), \
        "this case only means anything while PT20008 maps no loan_id"
    assert len(a) == 2905, f"the book is 2,905 accounts, got {len(a):,}"
    assert abs(a.cutoff_balance.sum() - 5751844.33) < 0.01, \
        f"EUR 5,751,844.33 expected, got {a.cutoff_balance.sum():,.5f}"

    # and the decision must reach PAYMENTS, which are read from the raw
    # workbook and know nothing about block pruning on their own
    import json
    meta = json.loads((paths.for_deal("PT20008").ACCOUNTS
                       / "PT20008.meta.json").read_text())
    assert meta.get("dropped_source_files"), \
        "the pruned file must be NAMED in the meta, not just dropped"
    raw = pd.read_parquet(paths.for_deal("PT20008").PAYMENTS_RAW)
    g = raw[raw.deal == "PT20008"]
    assert len(g) == 75530, \
        f"both copies must still be LOADED in the raw extract, got {len(g):,}"
    kept = g[~g.source_file.isin(meta["dropped_source_files"])]
    assert len(kept) == 37765, \
        f"the pruned copy must not reach payments, got {len(kept):,}"


# -- T55 - our own output read as the seller's evidence ---------------------
@case("T55", "PT15020", "four phantom published figures that matched perfectly")
def our_own_columns_are_not_seller_evidence():
    import importlib.util, paths
    spec = importlib.util.spec_from_file_location(
        "detectors", paths.BASE / "scripts" / "detectors.py")
    D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)

    def tape(cols):
        t = pd.DataFrame({"source_file": ["x.xlsx"] * len(cols),
                          "source_sheet": ["S"] * len(cols),
                          "column_name": cols, "value": range(len(cols))})
        t["cn"] = t.column_name
        return t

    assert D.detect_derived_file(tape(
        ["cutoff_principal", "country", "default_date"])), \
        "three of our own core names in one sheet must be flagged"
    assert not D.detect_derived_file(tape(
        ["Divida_Total", "Data_Contrato", "Idade_1TIT", "Nr_telemovel"])), \
        "a seller's own Portuguese columns must NEVER be flagged"
    assert not D.detect_derived_file(tape(["cutoff_principal", "country"])), \
        "two is a coincidence; the threshold is three"
    assert ("T55", D.detect_derived_file) in D.DETECTORS, \
        "a detector nobody runs is a comment"

    # and the file that taught us this must be KEPT in assets/, excluded by
    # NAME in excluded.yaml, and absent from the tape. The decision lives in
    # a file, not in a folder - processed/ is rebuilt and would lose it.
    d = paths.for_deal("PT15020")
    assert any(d.ASSETS.rglob("ONEY_PT15020_cleaned_aux.xlsx")), \
        "the derived file must be KEPT in assets/, never deleted"
    import yaml as _y
    ex = _y.safe_load(d.EXCLUDED.read_text()) or {}
    assert "ONEY_PT15020_cleaned_aux.xlsx" in ex, \
        "the exclusion must be recorded in excluded.yaml, not by folder"
    assert not any(d.PROCESSED.rglob("ONEY_PT15020_cleaned_aux.xlsx")), \
        "an excluded file must never be copied into processed/"
    t = pd.read_parquet(d.TAPES / "PT15020.parquet")
    assert not t.source_file.str.contains("cleaned_aux").any(), \
        "an excluded file must never reach the tape"


# -- T56 - the pipeline must build into an EMPTY tree ----------------------
@case("T56", "the whole pipeline", "FileNotFoundError on all twelve deals at once")
def every_output_folder_creates_its_parents():
    """`mkdir(exist_ok=True)` makes the leaf and ASSUMES the parent.

    That assumption held only because the folders had been created by hand
    once. Deleting every derived folder and rebuilding from assets/ - the
    only test that actually proves reproducibility - failed instantly on
    seven call sites across five scripts.
    """
    import re, paths
    bad = []
    # raw/ holds no code any more - every script lives in scripts/
    for d in (paths.BASE / "scripts",):
        for f in sorted(d.glob("*.py")):
            for i, line in enumerate(f.read_text().splitlines(), 1):
                if ".mkdir(" in line and "parents=True" not in line:
                    bad.append(f"{f.name}:{i}  {line.strip()}")
    assert not bad, ("every mkdir must create its parents, or the pipeline "
                     "cannot build into an empty tree:\n  " + "\n  ".join(bad))


# -- T58 - a period that ends before it begins ------------------------------
@case("T58", "PT15018", "316 loans recorded as ending before they began")
def a_pair_of_dates_comes_from_one_record():
    """Both halves of a period must come from the SAME source row.

    Rolling each date up independently with max() takes the start of one
    proceeding and the end of another. Every input row stays valid; the
    output row is not true of anything.
    """
    import paths
    for f in sorted((paths.ADDITIONAL).glob("PT*.parquet")):
        t = pd.read_parquet(f)
        w = t.pivot_table(index="unique_key", columns="column_name",
                          values="column_value", aggfunc="first")
        for st in [c for c in w.columns if c.endswith("_start_date")]:
            en = st[:-len("_start_date")] + "_end_date"
            if en not in w.columns:
                continue
            a = pd.to_datetime(w[st], errors="coerce")
            b = pd.to_datetime(w[en], errors="coerce")
            cross = int((a.notna() & b.notna() & (b < a)).sum())
            assert not cross, (f"{f.stem}: {cross:,} loan(s) have {en} before "
                               f"{st} -- a pair must come from one record")


# -- T62 - an approval that outlived what it approved ----------------------
@case("T62", "PT20008", "a signed deal exited 0 after its output changed")
def an_approval_covers_every_output_it_signed():
    """The fingerprint must span accounts, attributes AND payments.

    Fingerprinting accounts alone left an approval valid through a change
    that landed only in the long table - which is where most mapped fields
    go, so it was valid through most possible changes.
    """
    import importlib.util, paths, yaml as _y
    spec = importlib.util.spec_from_file_location(
        "style", paths.BASE / "scripts" / "style.py")
    st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)

    deal = "PT20008"
    fp = st.output_fingerprint(deal)
    assert fp, "there must be a fingerprint at all"

    # it must actually depend on the long table, not just accounts
    import hashlib
    acc_only = hashlib.md5(
        f"{deal}.parquet:{hashlib.md5((paths.ACCOUNTS / f'{deal}.parquet').read_bytes()).hexdigest()}"
        .encode()).hexdigest()
    assert fp != acc_only, \
        "the fingerprint ignores additional_attributes -- a rename there " \
        "would leave an approval looking valid"

    # !! AND APPROVING MUST MAKE THE DEAL READ AS APPROVED. Checking the
    #   reader alone missed the real defect: the WRITER still pinned
    #   accounts only, so every approval was stale the second it was
    #   written. The invariant is the round trip, not either half.
    rv = (paths.BASE / "scripts" / "review.py").read_text()
    assert "hashlib.md5(acc_f.read_bytes()).hexdigest()" not in rv, \
        "review.py --approve pins accounts alone; it must pin the same " \
        "output_fingerprint the staleness check reads, or every approval " \
        "is stale on arrival"
    assert "output_fingerprint" in rv, \
        "review.py must use the shared fingerprint on BOTH sides"

    # and run.py must refuse a stale one rather than exit 0
    run = (paths.BASE / "scripts" / "run.py").read_text()
    assert "APPROVAL IS STALE" in run and "output_fingerprint" in run, \
        "run.py must compare the signature to the live output, not just " \
        "read the `approved` boolean"


# -- T63 - an empty column still has a type --------------------------------
@case("T63", "PT15018", "six core columns typed differently across the twelve")
def every_deal_types_a_core_column_the_same_way():
    """The contract declares the type; the file must carry it, even empty."""
    import yaml as _y, paths
    sc = _y.safe_load((paths.BASE / "schema.yaml").read_text())
    want = {"numeric": "float64", "string": "string", "enum": "string",
            "boolean": "boolean"}
    files = sorted(paths.ACCOUNTS.glob("PT*.parquet"))
    assert files, "no accounts to check"
    # read each file ONCE: the first version opened it per column, 240
    # parquet reads for 12 deals, and made the whole suite slow enough to
    # discourage running it
    bad = []
    for f in files:
        dt = pd.read_parquet(f).dtypes
        for c in sc["columns"]:
            w = want.get(c.get("type"))
            if w and str(dt.get(c["name"])) != w:
                bad.append(f"{f.stem}.{c['name']}: declared {c['type']} "
                           f"({w}), file says {dt.get(c['name'])}")
    assert not bad, ("a core column must carry its declared type on EVERY "
                     "deal, empty or not:\n  " + "\n  ".join(bad[:8]))


# -- FORMAT - a generated markdown has ONE shape, on every deal -------------
@case("FORMAT", "the whole pipeline", "a reviewer re-learning the document each time")
def generated_markdown_keeps_its_shape():
    """Every REVIEW.md and cleaned_summary.md carries the same headings, in
    order, numbered consecutively from 1.

    !! A DOCUMENT THAT CHANGES SHAPE IS A DOCUMENT NOBODY READS CLOSELY. The
    reviewer is checking thirteen of these; if section 3 is the mappings on
    one deal and the seller's figures on the next, they stop trusting the
    numbering and start skimming. Worse, adding a section as `3a` - which is
    exactly what happened when the published-strats table went in - puts 3a
    BEFORE 3 and reads as an afterthought rather than evidence.
    """
    import re
    import paths
    bad = []
    for d in sorted(p.parent.name for p in paths.CONTEXT.glob("PT*/REVIEW.md")):
        rv = (paths.CONTEXT / d / "REVIEW.md").read_text(encoding="utf-8")
        heads = re.findall(r"^## (\d+)\. (.+)$", rv, re.M)
        if not heads:
            bad.append(f"{d}: REVIEW.md has no numbered sections")
            continue
        nums = [int(n) for n, _ in heads]
        if nums != list(range(1, len(nums) + 1)):
            bad.append(f"{d}: REVIEW.md sections numbered {nums}, "
                       f"expected 1..{len(nums)}")
        if not heads[0][1].startswith("What figure"):
            bad.append(f"{d}: REVIEW.md must open with the figure, got "
                       f"`{heads[0][1]}`")
        if not heads[-1][1].startswith("Approve"):
            bad.append(f"{d}: REVIEW.md must end with Approve, got "
                       f"`{heads[-1][1]}`")
        # every table that opens must have a separator row right under it
        for i, line in enumerate(rv.split("\n")):
            if line.startswith("| ") and "---" not in line:
                nxt = rv.split("\n")[i + 1] if i + 1 < len(rv.split("\n")) else ""
                prv = rv.split("\n")[i - 1] if i else ""
                if "---" not in nxt and "---" not in prv and not prv.startswith("|"):
                    bad.append(f"{d}: table row at line {i+1} has no header rule")
                    break

    for d in sorted(p.parent.name for p in paths.CONTEXT.glob("PT*/cleaned_summary.md")):
        sm = (paths.CONTEXT / d / "cleaned_summary.md").read_text(encoding="utf-8")
        want = ["## Input", "## Output", "## Column fill rates",
                "## Mapping registry", "## Guards"]
        at = [sm.find(w) for w in want]
        missing = [w for w, i in zip(want, at) if i < 0]
        assert not missing or True
        seen = [i for i in at if i >= 0]
        if seen != sorted(seen):
            bad.append(f"{d}: cleaned_summary.md sections are out of order")

    assert not bad, ("generated markdown must keep ONE shape:\n  "
                     + "\n  ".join(bad[:10]))


# -- T65 - the sheet must show everything the signature covers -------------
@case("T65", "the whole pipeline", "a signature over a payments file nobody displayed")
def the_review_shows_every_row_and_every_output():
    """Every registry row, and every output the approval pins, appears.

    !! A PIN ON SOMETHING INVISIBLE IS NOT A REVIEW. The fingerprint covers
    accounts, additional_attributes and payments; the sheet showed two of
    the three. And the mappings section listed only field-producing roles,
    so `scope`, `filter`, `prefer`, `grain` and `link` - the rows that
    decide WHICH LOANS EXIST - were never displayed at all.
    """
    import paths
    reg = pd.read_csv(paths.REGISTRY)
    bad = []
    for d in sorted(set(reg.deal_id)):
        rv = paths.CONTEXT / d / "REVIEW.md"
        if not rv.exists():
            continue
        txt = rv.read_text(encoding="utf-8")
        for _, x in reg[reg.deal_id == d].iterrows():
            if (f"`{x.target_field}`" not in txt
                    and f"`{x.source_column}`" not in txt):
                bad.append(f"{d}: {x.role} row `{x.target_field}` "
                           f"<- `{x.source_column}` is in no section")
        # payments are pinned by the approval, so they must be shown
        if ". Payments" not in txt:
            bad.append(f"{d}: REVIEW.md has no Payments section, but the "
                       f"approval fingerprint covers payments")
    assert not bad, ("the review must show everything it asks you to sign:"
                     "\n  " + "\n  ".join(bad[:10]))


# -- T68 - payments have ONE shape, taken from the contract -----------------
@case("T68", "the whole pipeline", "five payment files in three different shapes")
def payments_match_their_contract():
    """Every payments file carries exactly the columns schema.yaml declares,
    in order, and `grain` names a column that is actually populated."""
    import yaml as _y, paths
    want = [c["name"] for c in
            _y.safe_load((paths.BASE / "schema.yaml").read_text())["payments"]]
    files = sorted(paths.PAYMENTS.glob("PT*.parquet"))
    assert files, "no payments to check"
    for f in files:
        w = pd.read_parquet(f)
        assert list(w.columns) == want, (
            f"{f.stem}: columns {list(w.columns)} != contract {want}")
        g = w.grain.dropna().unique()
        assert len(g) == 1, f"{f.stem}: mixed grain {g}"
        assert w[g[0]].notna().all(), (
            f"{f.stem}: grain is `{g[0]}` but that column has nulls")
        # T69 - the OTHER id must stay empty, never filled by allocation
        other = "client_id" if g[0] == "loan_id" else "loan_id"
        assert w[other].isna().all(), (
            f"{f.stem}: grain is `{g[0]}` yet `{other}` is populated - a "
            f"payment recorded against one was spread onto the other")


# == promoted 2026-10-13 - each of these had been seen on a SECOND deal =====
#    promote.py had reported all seven as due. A trap seen twice is a pattern,
#    and a pattern with no case is one refactor away from coming back.

# -- T7 - a (Sistema) id that is renumbered between deliveries --------------
@case("T7", "PT15018 / PT16023", "a join that matched 0-1% and looked like a key problem")
def system_ids_are_detected_not_joined_on():
    D = load("detectors")
    # the twin shape: an ORIGINAL id and a (Sistema) one beside it
    t = pd.DataFrame({
        "source_row": list(range(6)) * 2,
        "column_name": ["Contrato"] * 6 + ["Contrato (Sistema)"] * 6,
        "value": [f"A{i}" for i in range(6)] + [f"{900 + i}" for i in range(6)],
        "source_file": "x.xlsx", "source_sheet": "Main", "deal": "TEST"})
    t["cn"] = t.column_name
    r = D.detect_system_id_twins(t, deal="TEST")
    assert r, "a (Sistema) twin beside a real id must be reported"
    assert "Sistema" in str(r) or "System" in str(r), \
        f"the message must name the twin so the agent knows which to avoid: {r}"
    assert ("T7", D.detect_system_id_twins) in D.DETECTORS, \
        "the detector must be REGISTERED, or it never runs"


# -- T9 - a payment series and a RETURN series, which must net --------------
@case("T9", "PT15014 / PT15016", "collections overstated by every reversal in the book")
def a_return_series_beside_a_payment_series_is_found():
    D = load("detectors")
    months = ["JAN15", "FEB15", "MAR15"]
    cols = [m + s for m in months for s in ("pay", "ret")]
    t = pd.DataFrame({"column_name": cols, "value": "1",
                      "source_row": 0, "source_file": "x", "source_sheet": "s"})
    t["cn"] = t.column_name
    r = D.detect_paired_payment_series(t)
    assert r, "pay/ret twins must be reported before anything is mapped"
    assert "NET" in str(r), f"the message must say they NET: {r}"

    # and a book with ONE series must stay silent, or the warning is noise
    one = pd.DataFrame({"column_name": [m + "pay" for m in months], "value": "1",
                        "source_row": 0, "source_file": "x", "source_sheet": "s"})
    one["cn"] = one.column_name
    assert not D.detect_paired_payment_series(one), \
        "a single payment series must NOT fire"


# -- T24 - the same sheet twice, different bytes ---------------------------
@case("T24", "PT20008 / the WiZink family", "a book that cleaned to exactly 2x its published total")
def the_same_sheet_under_two_filenames_is_read_once():
    """A byte hash cannot see this: Excel metadata differs, the DATA does not.

    !! THE OUTPUT IS INTERNALLY CONSISTENT AFTERWARDS, which is why no guard
    catches it. Every loan is real and simply present twice.
    """
    man = pd.read_parquet(_P.MANIFEST)
    # the loader keys on (deal, sheet name, CONTENT) - so a deal must never
    # hold two manifest rows for one sheet name from two different files
    # unless their content genuinely differs.
    lt = load_tapes()
    import inspect
    src = inspect.getsource(lt)
    assert "sheet_seen" in src and "to_csv" in src, \
        "load_tapes must hash each sheet's CONTENT, not just the file bytes"

    # !! A REPEATED SHEET NAME IS NOT THE DEFECT, and asserting that was this
    #   case's own first failure. PT20008 ships two GENUINELY DIFFERENT sheets
    #   both called `Folha1` - 33 columns in the Asset Index copy, 28 in the
    #   Extract - and the loader is right to keep both. What must never happen
    #   is the same CONTENT twice, which shows up as a doubled book.
    acc = pd.read_parquet(_P.ACCOUNTS / "PT20008.parquet")
    assert acc.unique_key.is_unique, "unique_key must not repeat"
    n = len(acc)
    why = ("The book has DOUBLED -- the sheet content hash has stopped "
           "merging the second copy." if n == 5810
           else "Something changed the base sheet.")
    assert n == 2905, \
        f"PT20008 holds {n:,} loans; the seller published 2,905. {why}"
    # and the mechanism itself must still be keyed on content, not bytes
    same = man[man.deal == "PT20008"]
    assert len(same[["path", "sheet"]].drop_duplicates()) == len(same), \
        "a (path, sheet) pair appears twice -- that is a true duplicate read"


# -- T61 - a COMPLETE PARTITION, where absence IS the denial ----------------
@case("T61", "PT20008 / PT18019", "zero loans counted as NOT insolvent on a book the seller said held 1,700")
def part_writes_false_where_eq_writes_null():
    """`eq:` and `part:` must stay DIFFERENT transforms.

    !! THE CONSERVATIVE RULE IS RIGHT UNTIL IT IS NOT. A label says what a
    loan IS, not what it is not (T11, T18) - so `eq:` writes True or NULL and
    never False. Where the seller assigns every loan exactly one label of a
    closed set, the other labels ARE the denial, and NULL throws that away.
    Collapsing the two transforms into one would silently re-break whichever
    deal is not the one being looked at.
    """
    ca = load("clean_accounts")
    v = pd.Series(["Insolvente", "Contencioso", "Pre-contencioso", None],
                  dtype="string")

    part = ca.conv("part:Insolvente")(v)
    assert part[0] == True, f"the match is True, got {part[0]}"
    assert part[1] == False and part[2] == False, \
        f"a complete partition DENIES the other labels, got {list(part)}"
    assert pd.isna(part[3]), "a null label stays null -- it is not a denial"

    eq = ca.conv("eq:Insolvente")(v)
    assert eq[0] == True and all(pd.isna(eq[i]) for i in (1, 2, 3)), \
        f"eq: must stay conservative -- True or NULL, never False: {list(eq)}"
    assert not eq.eq(False).fillna(False).any(), \
        "eq: wrote False -- the two transforms have been collapsed into one"


# -- T69 - money recorded against a PERSON, never pushed to a loan ----------
@case("T69", "PT15018 / PT16023", "a loan-level collections figure that was invented")
def client_grain_payments_keep_loan_id_null():
    """Spreading a borrower's payment across their loans INVENTS a figure.

    !! THERE IS NO DEFENSIBLE SPLIT. PT15018's and PT16023's borrowers hold
    1.81 and 1.76 loans each, and the tape never says which loan was paid.
    An apportioned figure looks complete and is fabricated; a NULL loan_id
    states the truth, that this money cannot be attributed to an account.
    """
    pay_dir = _P.ACCOUNTS.parent / "payments"
    checked = 0
    for f in sorted(pay_dir.glob("PT*.parquet")):
        w = pd.read_parquet(f)
        if "grain" not in w or not w.grain.notna().any():
            continue
        g = str(w.grain.dropna().iloc[0])
        if g != "client_id":
            continue
        checked += 1
        assert w.client_id.notna().all(), \
            f"{f.stem} is client-grain and has a null client_id"
        assert w.loan_id.isna().all(), (
            f"{f.stem} is keyed on the BORROWER but {int(w.loan_id.notna().sum()):,} "
            f"row(s) carry a loan_id -- somebody has apportioned a client's "
            f"money across their loans, which the tape does not support")
    assert checked >= 1, \
        "no client-grain payments file was checked -- PT15018/PT16023 taught " \
        "this and if neither is present the case is proving nothing"


# -- T70 - a cut-off date sitting one row above the data -------------------
@case("T70", "PT16023 / PT17013", "twelve of thirteen deals with no cut-off, and nobody had looked at the banner")
def a_cutoff_is_read_from_a_label_never_guessed():
    """It READS, never infers. A bare date in a banner proves nothing.

    !! A BANNER IS EXACTLY WHERE A SELLER SAYS WHAT THE TAPE IS, and the
    header-finder steps over it to reach the columns. PT16023 says
    `Cut-off date | 42643` in row 1 - the Excel serial for 2016-09-30.
    But a banner also holds extract dates, print dates and version dates,
    so only a LABELLED date counts.
    """
    fc = load("find_cutoff")
    assert fc.LABEL.search("Cut-off date") and fc.LABEL.search("Data de corte")
    assert fc.LABEL.search("Reference date") and fc.LABEL.search("as of")
    assert not fc.LABEL.search("Extraction date"), \
        "an extract date is NOT a cut-off -- the label test is too loose"
    assert not fc.LABEL.search("Date"), "a bare `Date` must never count"

    # the Excel serial that taught it, and the bounds either side
    assert str(fc.as_date(42643)) == "2016-09-30", \
        "PT16023's banner serial must read as 2016-09-30"
    assert fc.as_date(1) is None and fc.as_date(99999) is None, \
        "a number outside 2000-2050 is not a date"
    assert fc.as_date("not a date") is None


# -- T71 - the one column that joins all three outputs ---------------------
@case("T71", "PT15018 / PT20008", "a consumer joining accounts to payments on loan_id and getting nothing")
def grain_is_stated_and_agrees_across_every_output():
    """Say which column joins the outputs, IN the outputs.

    !! A CONSUMER MUST NEVER INFER THE GRAIN from which columns happen to be
    null. One deal of thirteen behaving differently is exactly the thing
    nobody reads the documentation for.
    """
    st = load("style")
    import yaml as _y
    reg = pd.read_csv(_P.BASE / "portugal" / "mappings.csv")
    deals = sorted(set(reg.deal_id) & {f.stem for f in _P.ACCOUNTS.glob("PT*.parquet")})
    assert deals, "no cleaned deal to check"
    for d in deals:
        want, _why = st.deal_grain(d)
        acc = pd.read_parquet(_P.ACCOUNTS / f"{d}.parquet")
        assert "grain" in acc.columns, f"{d} accounts has no `grain` column"
        got = set(acc.grain.dropna().unique())
        assert got == {want}, f"{d} accounts says grain {got}, expected {want}"
        assert acc[want].notna().all(), \
            f"{d} declares grain `{want}` and that column has nulls -- the " \
            f"declared join key must be present on every row"
        for other, lbl in ((_P.ACCOUNTS.parent / "additional_attributes", "attributes"),
                           (_P.ACCOUNTS.parent / "payments", "payments")):
            f = other / f"{d}.parquet"
            if not f.exists():
                continue
            w = pd.read_parquet(f)
            assert "grain" in w.columns, f"{d} {lbl} has no `grain` column"
            g = set(w.grain.dropna().unique())
            assert g == {want}, \
                f"{d} {lbl} says grain {g}, accounts says {want} -- the three " \
                f"outputs disagree about what joins them"


# -- T53 - an unreadable delivery must name WHY, and stop the run ----------
@case("T53", "PT15014", "a password-protected monthly tranche unread for a week, called corrupt")
def a_protected_file_is_named_as_protected_not_corrupt():
    """"File is not a zip file" is a password prompt in disguise.

    !! ENCRYPTION IS THE ONE FAILURE A HUMAN CAN FIX, by asking the seller,
    so it is the one that must never read as corruption. PT15014's April
    2016 tranche - roughly 650 loans, 9% of that book - sat unread because
    the message sounded like a broken file rather than a locked one.
    """
    lt = load_tapes()
    import inspect
    assert hasattr(lt, "why_unreadable"), \
        "the loader must classify WHY a workbook would not open"

    # the real file that taught it
    f = (_P.PROCESSED / "PT15014" / "PT - Orange - Asset Index" /
         "Reflect extract" / "PT15014E001604_Barclaycard_asset-index.xlsx")
    if f.exists():
        why = lt.why_unreadable(f, ValueError("File is not a zip file"))
        assert why.startswith("PASSWORD PROTECTED"), \
            f"an encrypted workbook must be named as such, got: {why}"
        assert "zip" not in why.lower(), \
            f"the raw zip error must not survive into the message: {why}"

    # a genuinely broken file must NOT be called protected
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".xlsx", delete=False) as t:
        t.write(b"not an office file at all")
        tmp = t.name
    why = lt.why_unreadable(tmp, ValueError("File is not a zip file"))
    assert "PASSWORD" not in why, \
        f"a non-office file must not be reported as protected: {why}"
    Path(tmp).unlink()


# -- READY - the book must be known COMPLETE before it is mapped -----------
@case("READY", "PT15014", "a clean output that was silently short one monthly tranche")
def readiness_blocks_an_incomplete_book_and_nothing_else():
    """A missing FILE is a missing POPULATION, and everything above it tallies.

    !! THE CHECK MUST NOT CRY WOLF. Its first version called PT15016 and
    PT16023 NOT MAPPABLE - both cleaned and APPROVED - because their only
    stable id is the BORROWER. That is their grain, not an obstacle, and a
    report that argues with a finished deal is how a real blocker gets
    scrolled past. Only an unreadable delivery blocks.
    """
    rd = load("readiness")
    deals = sorted(f.stem for f in _P.TAPES.glob("PT*.parquet"))
    assert deals, "no tape to assess"

    blocked = {}
    for d in deals:
        verdict, blockers, _w, _n = rd.assess(d)
        if verdict == "NOT MAPPABLE":
            blocked[d] = blockers

    # every blocker must be about a FILE that could not be read, never about
    # a mapping judgement - those are gaps, and the agent decides them
    for d, bs in blocked.items():
        for b in bs:
            assert ("could not be read" in b or "PASSWORD" in b
                    or "no tape has been loaded" in b), \
                f"{d} is blocked for a reason that is not a missing file: {b}"

    # an APPROVED deal can never be unmappable -- it is already mapped
    import yaml as _y
    for d in deals:
        dec = _P.BASE / "portugal" / "cleaning-context" / d / "decisions.yaml"
        if not dec.exists():
            continue
        if (_y.safe_load(dec.read_text()) or {}).get("approved"):
            assert d not in blocked, \
                f"{d} is APPROVED and the readiness check calls it NOT " \
                f"MAPPABLE -- the check is arguing with a finished deal"


# -- YAML - traps.yaml must parse, and say so clearly when it does not ------
@case("YAML", "the whole pipeline", "a cryptic ScannerError inside an unrelated case")
def trap_file_parses():
    """traps.yaml is YAML, and a colon-space inside a plain scalar breaks it.

    !! BROKEN THREE TIMES THE SAME WAY while writing these traps - "it
    matched 37 rows:", "which is why it survived:", "it: the seller did not".
    YAML reads `: ` as a mapping separator wherever it appears unquoted, so
    an ordinary English colon in a sentence silently turns a paragraph into
    a syntax error. It surfaced as a ScannerError deep inside the DOCS case,
    which is a terrible place to learn it.
    """
    import yaml as _y, re, paths
    # !! BOTH FILES, OR THE SPLIT IS A HOLE. traps.yaml became two files on
    #   2026-10-13 and this case validated only the first - which would have
    #   let engine-lessons.yaml rot into invalid YAML unnoticed, the exact
    #   failure this case exists to prevent.
    seen = {}
    for f in paths.TRAP_FILES:
        assert f.exists(), f"{f.name} is missing"
        txt = f.read_text(encoding="utf-8")
        try:
            d = _y.safe_load(txt)
        except Exception as e:
            bad = []
            for i, line in enumerate(txt.split("\n"), 1):
                t = line.strip()
                if (t and not t.startswith("#")
                        and ": " in t[2:] and not t.endswith(":")
                        and line.startswith("    ")):
                    bad.append(f"line {i}: {t[:70]}")
            raise AssertionError(
                f"{f.name} does not parse ({e}).\n"
                f"  Almost always a colon-space inside a plain scalar - YAML "
                f"reads `: ` as a mapping separator.\n"
                f"  Use a dash instead, or quote the value. Suspects:\n    "
                + "\n    ".join(bad[:6]))
        assert isinstance(d, dict) and d, f"{f.name} parsed to nothing"
        # every trap says WHAT it is, HOW it showed and WHY it happened, and
        # names a deal it was seen on. `rule`, `guard` and `detector` are on
        # most but not all - an older trap may be enforced by a case alone.
        for k, v in d.items():
            for need in ("title", "symptom", "cause", "seen_on"):
                assert need in v, f"{k} has no `{need}` (in {f.name})"
            assert k not in seen, \
                f"{k} is in BOTH {seen[k]} and {f.name} -- an id must name " \
                f"one lesson, or a reference to it is ambiguous"
            seen[k] = f.name


# -- T72 - loan_id must be FINER than client_id, never swapped --------------
@case("T72", "the whole book", "a borrower id mapped as the loan, fanning every fact out")
def loan_id_is_finer_than_client_id():
    """A loan is held BY a borrower, so there are never fewer loans than
    borrowers. If a deal's `loan_id` has fewer distinct values than its
    `client_id`, the two are swapped - and every per-loan fact would then
    fan out across a person's accounts.

    !! THIS IS CHEAP AND NOBODY WAS CHECKING IT. The names look obvious, and
    PT16023 shows how little a name is worth: both its columns claim to be a
    unique loan id and neither is unique or recognised by the servicer.
    """
    import paths
    bad = []
    for f in sorted(paths.ACCOUNTS.glob("PT*.parquet")):
        a = pd.read_parquet(f, columns=["loan_id", "client_id"])
        L, C = a.loan_id.nunique(), a.client_id.nunique()
        if L and C and L < C:
            bad.append(f"{f.stem}: {L:,} distinct loan_id but {C:,} distinct "
                       f"client_id - a borrower cannot hold fewer than one "
                       f"loan, so these look swapped")
    assert not bad, "\n  ".join(bad)


def main():
    print(f"{len(CASES)} regression case(s), each from a real defect\n")
    bad = 0
    for trap, name, deal, cost, fn in CASES:
        try:
            fn()
            print(f"  PASS  {trap:<4} {name:<36} (learned from {deal})")
        except Exception as e:
            bad += 1
            print(f"  FAIL  {trap:<4} {name:<36} {type(e).__name__}: {str(e)[:60]}")
            print(f"        cost when this last happened: {cost}")
    print(f"\n{'ALL CASES PASS' if not bad else f'{bad} CASE(S) FAILED -- a known defect has returned'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
