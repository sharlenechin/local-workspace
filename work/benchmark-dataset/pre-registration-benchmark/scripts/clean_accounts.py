"""Clean one deal's tape into the accounts schema (schema.yaml).

    uv run python work/benchmark-dataset/pre-registration-benchmark/clean_accounts.py PT15018

Reads  portugal/raw/tapes/<deal>.parquet   (long: one row per cell)
       mappings.csv                                           (which column means what)
Writes accounts/<deal>.parquet                                (one row per LOAN)

THREE ROLES IN THE REGISTRY, and the order matters:

  base    the sheet that defines WHICH LOANS ARE IN THE DEAL. It is chosen because
          its totals tally to the strats the seller published, so the row count and
          the balance are defensible against the bank's own number.
  enrich  extra per-loan detail from another sheet, LEFT-joined on loan_id. Null
          where that sheet does not describe the loan. Never adds or removes loans.
  party   person-level facts, joined on client_id and rolled up to the loan.

!! WHY NOT ANCHOR ON THE DETAILED SHEET: PT15018's Claims sheets carry far more
  fields, but only 1,555 loans -- 5% of the deal -- and their balances do NOT
  reconcile with the collections file (on the 673 shared loans, 3.27M against
  15.92M; 2 of 673 agree). Anchoring there gives rich detail on a population that
  tallies to nothing. Anchoring on the sheet that reconciles gives the whole deal,
  with detail where it exists and honest nulls elsewhere.

!! EVERYTHING ARRIVES AS TEXT and is converted here, never upstream.
"""
import fnmatch
import hashlib as _hashlib
import re
import sys
from pathlib import Path
import pandas as pd
from style import in_scope, headline

import paths as _P

HERE = Path(__file__).resolve().parent          # scripts/
BASE = HERE.parent                              # pre-registration-benchmark/
TAPES = _P.TAPES
OUT = _P.ACCOUNTS

# !! READ FROM schema.yaml, NEVER HARDCODED. The column list lived here AND in
# a prose copy, which is how two sources of truth drift apart. There WAS
# one, SCHEMA.md; it still described judicialised_flag as a core column
# months after it moved, and was deleted rather than re-synced. Adding a field is one
# edit to schema.yaml plus registry rows; see the procedure at the top of it.
import yaml as _yaml
# !! TWO TABLES. `columns` is the fixed core every consumer relies on;
#   everything else a seller ships goes to the OPEN long table, so a new fact
#   is a registry row and never a schema change. See schema.yaml for why.
_SCH = _yaml.safe_load((_P.SCHEMA).read_text())
_SCHEMA_COLS = _SCH["columns"]
SCHEMA = [c["name"] for c in _SCHEMA_COLS]
ATTR_COLS = [c["name"] for c in _SCH["additional_attributes"]]

# how to READ a value back out of the long table. Derived from the registry's
# own transform, so the two can never disagree about what a column holds.
TYPE_OF = {"text": "text", "amount": "amount", "date": "date",
           "date_serial": "date", "yn": "boolean"}


def column_type(transform, field):
    """`column_type` for one attribute row."""
    t = str(transform)
    if (t.startswith("eq:") or t.startswith("part:")
            or t.startswith("lead_in:")):
        return "boolean"
    if t in TYPE_OF:
        return TYPE_OF[t]
    if field in AMOUNT_FIELDS:
        return "amount"
    if field in DATE_FIELDS:
        return "date"
    return "text"

def amount(s):
    """Numeric, or null. "Not Available" becomes null, NEVER zero.

    !! ONE SHEET, TWO DECIMAL CONVENTIONS. Claims writes `Capital` as "64843.73"
      and `Montante de Capital Inicial` as "48000,00", side by side. Assuming
      either for the whole sheet silently nulls the other column -- and a null
      later summed becomes 0, which is how every loan once came out "originated
      for nothing". Decide per VALUE.
    """
    def one(v):
        if v is pd.NA or v is None:
            return None
        v = str(v)
        if "," in v and "." in v:
            v = (v.replace(".", "").replace(",", ".") if v.rfind(",") > v.rfind(".")
                 else v.replace(",", ""))
        elif re.fullmatch(r"-?[\d.]*,\d{1,2}", v):
            v = v.replace(".", "").replace(",", ".")
        return v
    return pd.to_numeric(s.astype("string").str.strip().map(one), errors="coerce")


YES = {"y", "yes", "s", "sim", "true", "1"}
NO = {"n", "no", "nao", "não", "false", "0"}


def yn(s):
    """Yes -> True. A GENUINE no -> False. Anything else -> null.

    !! WHETHER `False` IS WRITEABLE IS A PROPERTY OF THE COLUMN, NOT A CONSTANT.

      PT15018's `Reclamado Judicialmente (Y/N)` holds only `Yes` and
      `Not Available` -- there is NO `No` anywhere in it. Writing False there
      would assert something the tape never said, and would have produced 29,581
      confident "not judicialised" values. So: null.

      PT16023's `Judicialized?` holds `Y` (12,743) and `N` (6,691). This tape CAN
      say no, so False is real information and nulling it would throw away 6,691
      genuine negatives.

      The column decides. If it contains a negative value anywhere, the
      convention supports False; if it does not, every non-yes is unknown.
      Deterministic, and it needs no per-deal configuration.
    """
    t = s.astype("string").str.strip().str.lower()
    has_no = t.isin(NO).any()
    out = pd.Series(pd.NA, index=t.index, dtype="object")
    out[t.isin(YES)] = True
    if has_no:
        out[t.isin(NO)] = False
    return out


def date_serial(s):
    """An Excel date serial -> a date. Falls back to a normal date parse.

    !! TRAP T14, found on PT16023. Excel stores a date as the number of days since
      1899-12-30, and some exports ship the NUMBER rather than the date: PT16023
      writes `Delinquency Date` as 42402. Parsed as a date that is NaT; parsed as
      a number it is a plausible-looking 42,402 that no guard would question.
      Neither is visible without decoding it.

      The 1899-12-30 origin (not 1900-01-01) absorbs Excel's own leap-year bug.
      Only values in a sane range are treated as serials -- 20,000..60,000 is
      roughly 1954..2064 -- so a genuine small number is never silently turned
      into a date.
    """
    t = s.astype("string").str.strip()
    n = pd.to_numeric(t, errors="coerce")
    serial = n.between(20_000, 60_000)
    out = pd.to_datetime(t.where(~serial), errors="coerce", format="mixed")
    out = out.fillna(pd.to_datetime(n.where(serial), unit="D",
                                    origin="1899-12-30", errors="coerce"))
    return out.dt.date


# !! EVERY ROW THIS ENGINE REMOVES IS A DECISION A REVIEWER SHOULD SEE.
#   Nine kinds of row leave the book - published total rows, footer
#   calculations, header rows, a cohort delivered twice, a loan reported in
#   two months, loans the seller marks not-for-sale. Each was printed to the
#   terminal and then lost, so the sheet a human signs described only what
#   SURVIVED. Someone approving PT19013 could not see that 310 rows from a
#   file named "final" had been set aside.
DECISIONS = []


# !! A BOOK DROPPED AS A DUPLICATE IS DROPPED FOR THE WHOLE DEAL.
#   The block rules below run on the ACCOUNTS tape only, and payments are
#   extracted separately, straight from the raw workbook. So when PT20008's
#   second copy was pruned out of accounts its PAGAMENTOS_* columns stayed:
#   75,530 payment rows for a book with 37,765. Nothing shipped - that deal's
#   payments are not cleaned yet - but the next deal to arrive twice WOULD
#   have doubled silently. Every file pruned here is written to the meta, and
#   clean_payments refuses to read it.
DROPPED_FILES = set()


def decide(kind, rows, detail):
    """Record a row-level decision, and print it as before."""
    DECISIONS.append({"kind": kind, "rows": int(rows), "detail": detail})
    print(f"  {detail}")


# the two families that carry a QUANTITY, as opposed to a label
AMOUNT_FIELDS = {"cutoff_balance", "cutoff_principal", "cutoff_interest",
                 "cutoff_other_fee", "claims_balance",
                 "insolvency_claims_balance", "origination_amount"}
DATE_FIELDS = {"cutoff_date", "origination_date", "default_date",
               "insolvency_start_date", "insolvency_end_date",
               "judicial_start_date", "judicial_end_date"}

CONV = {"text": lambda s: s.astype("string").str.strip(), "amount": amount,
        "date_serial": date_serial,
        "date": lambda s: pd.to_datetime(s, errors="coerce", format="mixed").dt.date,
        "yn": yn}


def conv(name):
    """Resolve a registry `transform` to a function, including parameterised ones.

    `eq:<value>` is the one parameterised form: True where the cell equals
    <value>, NULL everywhere else -- never False.

    Why never False: a segment label is not a statement about its own absence.
    PT18019 labels 9,298 loans `Perimeter = Bankruptcy`; the other three labels
    (Category 1, Category 2, Deceased) say what those loans ARE, not that they
    are solvent. Writing False there would invent a negative the seller never
    made, which is the same defect as T5 in the other direction. The value
    lives in mappings.csv, so a deal that DOES publish a negative gets `yn`
    instead and no code changes.
    """
    # !! `part:` IS `eq:` FOR A COLUMN THAT IS A COMPLETE PARTITION, and the
    #   difference is the whole point. `eq:` refuses to write False because a
    #   label usually says what a loan IS, not what it is not. But where the
    #   seller assigns EVERY loan exactly one of a closed set - PT20008's
    #   fase_recuperacao is CONTENCIOSO, INSOLVENTE or PRE-CONTENCIOSO on all
    #   2,905 rows with no blanks - the other labels ARE the denial. Leaving
    #   them NULL throws away a statement the seller made: "how many are not
    #   insolvent" answered 0 on a book where the answer is 1,700.
    #
    # !! IT IS A DELIBERATE CLAIM, NOT A DEFAULT, because the same column
    #   shape can mean the opposite. PT15018's `Segmento` also partitions the
    #   book, and 506 loans labelled `Individuals and ENIs` are flagged
    #   insolvent by a PERSON on another sheet - so there the other labels
    #   contradict nothing and `eq:` is correct. Which it is cannot be read
    #   off the column; it is a judgement, recorded in the registry note.
    #
    #   NULL survives only where the column itself is blank - still unknown.
    # !! A PORTUGUESE TAX NUMBER SAYS WHETHER THE HOLDER IS A PERSON.
    #   The NIF's FIRST DIGIT is assigned by law: 1, 2 and 3 are natural
    #   persons, 5 is a company, 6 public administration, 7 and 9 other
    #   entities. PT15020 carries no customer-type column at all - but every
    #   one of its 5,313 nine-digit NIFs begins 1 or 2, so every holder is an
    #   individual and no mapping was needed to know it.
    #   `lead_in:<chars>` is True when the first character is one of those
    #   given, False when it is a value that is not, NULL only when the cell
    #   is blank. It is a COMPLETE classification - the digit is always one
    #   thing or the other - which is why it may write False (T61).
    #   The legal rule lives in the registry note, not here: another country's
    #   tax number means something else entirely.
    if name.startswith("lead_in:"):
        want = {c.strip() for c in name[len("lead_in:"):].split(",") if c.strip()}
        def lead_in(s):
            v = s.astype("string").str.strip()
            hit = v.str[0].isin(want)
            return hit.where(v.notna() & v.ne(""), other=pd.NA).astype("boolean")
        return lead_in
    if name.startswith("part:"):
        want = name[5:].strip().casefold()
        def part(s):
            v = s.astype("string").str.strip().str.casefold()
            hit = v.eq(want)
            return hit.where(v.notna(), other=pd.NA).astype("boolean")
        return part
    if name.startswith("eq:"):
        want = name[3:].strip().casefold()
        def eq(s):
            # !! VECTORISED, NOT .map(). An element-wise `v == want` on a null
            #   cell returns pd.NA, and `if pd.NA` raises -- so a single blank
            #   cell anywhere in the column killed the whole run. Series.eq
            #   propagates NA instead of testing it.
            v = s.astype("string").str.strip().str.casefold()
            hit = v.eq(want)
            # True on a match; NULL on a miss AND on a blank. Never False.
            return hit.where(hit.fillna(False), other=pd.NA).astype("boolean")
        return eq
    return CONV[name]


def offer_stage(files):
    """`bo` / `nbo` / `unknown`, from the filename.

    NBO = non-binding offer, the earlier diligence tape. BO = binding offer,
    later and fresher. Where a deal ships BOTH, BO wins per loan and NBO fills
    only the fields BO does not carry.

    !! ONLY 1 OF 12 PORTUGUESE TAPES SAYS WHICH IT IS (PT16023's filename ends
      `_NBO`). The rest are unmarked and land `unknown` -- NOT defaulted to nbo.
      A default would assert a delivery stage nobody recorded, and the stage
      decides which tape wins when two describe the same loan. `unknown` is the
      honest value and makes the gap visible; the same rule as the judicialised
      flag, which never writes False because the tape has no "No".
    """
    u = str(files).upper()
    if re.search(r"\bBO\b|_BO[_.]|BINDING", u) and "NBO" not in u:
        return "bo"
    if "NBO" in u or re.search(r"NON.?BINDING", u):
        return "nbo"
    return "unknown"


def norm(c):
    """Column names carry embedded newlines; flatten so the registry stays flat."""
    return " ".join(str(c).split())


def sheets_matching(tape, pattern):
    """Sheet names a registry `source_sheet` refers to.

    !! A PATTERN, NOT A LIST, BECAUSE THE WiZink BOOKS SHIP ONE SHEET PER
       MONTH. PT15014 has 11, PT20014 has 85. Naming each one in the registry
       means 8 rows per sheet - 680 lines of near-identical configuration that
       nobody will read and that silently misses a sheet when the next
       delivery arrives. A pattern is still DATA: the deal says which sheets
       it means, the engine just expands it.

    An exact name is matched exactly, so nothing that worked before changes.
    """
    names = tape.source_sheet.unique()
    out = []
    # `|` separates alternatives, because a deal's population can live in two
    # differently-named families: PT19007 has `Accts` AND `data_tape_WOFF_*`,
    # with no common prefix, and a bare `*` would also swallow its pricing tab.
    for pat in str(pattern).split("|"):
        pat = pat.strip()
        if any(ch in pat for ch in "*?["):
            out += [n for n in names if fnmatch.fnmatch(str(n), pat)]
        elif pat in set(names):
            out.append(pat)
    return sorted(set(out))


def take(w, source_column, transform, seen=None):
    """One registry cell -> one Series, allowing `a + b` across columns.

    !! A SCHEMA FIELD IS NOT ALWAYS ONE SELLER COLUMN. Barclaycard splits what
       is owed three ways - sum_prin, sum_int, sum_fee - and
       `prin + int + fee == woff_bal` holds on every one of PT15014's 7,121
       loans to four decimal places. Mapping `cutoff_interest` to sum_int
       alone leaves the fee with nowhere to go: EUR 1,798,863.37, 6.6% of that
       book, showing up as an unexplained residual in the guard.
       `sum_int + sum_fee` says what is meant, in DATA, and the arithmetic
       stays visible in the registry note rather than hiding in a script.

    Only amounts may be added. Adding two dates or two labels is meaningless,
    so it is refused rather than silently producing something.
    """
    # `a | b` -- take `a`, and only where it is NULL take `b`.
    # !! A FALLBACK IS A MIXED MEASURE AND MUST BE COUNTED. PT15014's January
    #   2016 sheet omits `curr_bal` on all 720 of its loans, so the book's
    #   balance is `curr_bal` for 6,401 loans and `woff_bal` for 720. The two
    #   are identical wherever both exist on this deal, which is what makes
    #   the fallback safe here - but it is still two columns in one field, and
    #   the reviewer is told exactly how many rows came from the second.
    if "|" in str(source_column):
        alts = [x.strip() for x in str(source_column).split("|")]
        out, used = None, None
        for a in alts:
            v = take(w, a, transform)
            if v is None:
                continue
            if out is None:
                out, used = v, pd.Series(a, index=v.index, dtype="object")
            else:
                fill = out.isna() & v.notna()
                if fill.any():
                    out = out.where(~fill, v)
                    used = used.where(~fill, a)
        # !! THE FLAG MUST TRAVEL WITH THE ROWS. Counting here overstated the
        #   figure by the footer rows dropped later (722 against 720), and
        #   re-counting afterwards by position failed too, because `base` is
        #   re-indexed in between. Carrying it as a column is the only way the
        #   count survives every filter intact.
        if out is not None and used is not None and seen is not None:
            seen["used"] = used
        return out

    parts = [norm(x) for x in str(source_column).split("+")]
    if len(parts) == 1:
        c = parts[0]
        return conv(transform)(w[c]) if c in w.columns else None
    if transform != "amount":
        raise SystemExit(
            f"`{source_column}` adds columns, which only makes sense for an "
            f"amount -- transform is `{transform}`")
    missing = [c for c in parts if c not in w.columns]
    if missing:
        return None
    out = None
    for c in parts:
        v = pd.to_numeric(conv("amount")(w[c]), errors="coerce")
        out = v if out is None else out.add(v, fill_value=0)
    return out


def build(tape, rows):
    """Apply one role's mappings -> a wide frame keyed by source row."""
    out = []
    for sheet, grp in rows.groupby("source_sheet"):
        # !! EXPAND `a + b` HERE TOO. The reader understood the sum and this
        #   filter did not, so the pivot was built without either column and
        #   `cutoff_interest` came out entirely NULL -- a mapping that looked
        #   present in the registry and produced nothing.
        want = {norm(x) for c in grp.source_column
                for part in str(c).split("|")
                for x in part.split("+")}
        matched = sheets_matching(tape, sheet)
        d = tape[tape.source_sheet.isin(matched) & tape.cn.isin(want)]
        if d.empty:
            continue
        w = d.pivot_table(index=["source_file", "source_sheet", "source_row"],
                          columns="cn", values="value",
                          aggfunc="first").reset_index()
        f = pd.DataFrame(index=w.index)
        # carried so the footer rule can work per sheet; dropped before write
        f["_src_sheet"] = w["source_sheet"] if "source_sheet" in w.columns else sheet
        f["_src_file"] = w["source_file"] if "source_file" in w.columns else ""
        f["_src_row"] = w["source_row"] if "source_row" in w.columns else -1
        for _, r in grp.iterrows():
            seen = {}
            v = take(w, r.source_column, r["transform"], seen)
            if v is not None:
                f[r.target_field] = v
                if "used" in seen:
                    f[f"_fb_{r.target_field}"] = seen["used"]
        out.append(f)
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame()


def _sheet(tape, sheet):
    """One sheet as a wide frame, in source order."""
    g = tape[tape.source_sheet == sheet]
    return g.pivot_table(index="source_row", columns="cn", values="value",
                         aggfunc="first").sort_index()


def main(deal):
    tape = pd.read_parquet(TAPES / f"{deal}.parquet")
    tape["cn"] = tape.column_name.map(norm)

    # !! A PUBLISHED TOTAL ROW IS NOT A LOAN, AND IT SITS IN THE DETAIL SHEET.
    #   Nine of the twelve Portuguese books carry one - the WiZink family puts
    #   a grand total at the bottom of EVERY monthly sheet, 21 of them on
    #   PT20014 alone. Counted as loans they add a phantom account holding the
    #   whole book, and the column then sums to exactly TWICE the published
    #   figure, so the deal silently stops reconciling and looks like a book
    #   that simply has no published figure. PT15020 was recorded that way.
    #   These rows are not guessed: find_strats PROVES each one equals the sum
    #   of its own column above it, and writes the row numbers into the strats
    #   JSON. Excluding exactly those rows is what makes the cleaner's
    #   population identical to the one the reconciliation was measured on.
    import json as _json
    _sf = _P.STRATS / f"{deal}.json"
    if _sf.exists():
        tr = _json.loads(_sf.read_text()).get("total_rows", {})
        if tr:
            mask = pd.Series(False, index=tape.index)
            for sh, rows in tr.items():
                mask |= tape.source_sheet.eq(sh) & tape.source_row.isin(rows)
            if mask.any():
                hit = (tape[mask].groupby("source_sheet").source_row
                       .nunique().sum())
                decide("published_total", int(hit),
                       f"excluded {int(hit)} published TOTAL row(s) from "
                       f"{len(tr)} sheet(s) -- proven sums, not loans")
                tape = tape[~mask]
    m = pd.read_csv(_P.REGISTRY).query("deal_id == @deal")
    if m.empty:
        print(f"no mappings for {deal}", file=sys.stderr)
        return 1

    # !! A REGISTRY ROW THAT POINTS AT NOTHING MUST FAIL LOUDLY. Misspell a
    #   column - `Producto` for `Produto` - and every step used to succeed:
    #   the clean exits 0, every guard passes, and the field is silently
    #   empty. The approval sheet then files it under "empty on this deal",
    #   which reads as THE TAPE DOES NOT CARRY IT. A typo became a fact about
    #   the seller.
    #   So the registry is checked against the actual tape before anything is
    #   built, and the error names the closest real column - which is also the
    #   fastest way to fix it.
    import difflib
    sheets_on_tape = set(tape.source_sheet.unique())
    cols_by_sheet = {sh: set(g.cn.unique())
                     for sh, g in tape.groupby("source_sheet")}
    problems = []
    for _, r in m.iterrows():
        # only the roles that actually name a COLUMN are checkable here:
        #   prefer -> names a FILE;  grain -> names a collapse rule
        if r.role not in ("base", "enrich", "party", "align", "scope",
                          "bridge", "link", "filter", "duration"):
            continue
        matched = sheets_matching(tape, r.source_sheet)
        if not matched:
            near = difflib.get_close_matches(str(r.source_sheet),
                                             sheets_on_tape, 1, 0.5)
            problems.append(
                f"  `{r.target_field}`: sheet `{r.source_sheet}` is not on this "
                f"tape" + (f" -- did you mean `{near[0]}`?" if near else ""))
            continue
        have = set().union(*(cols_by_sheet.get(sh, set()) for sh in matched))
        for part in str(r.source_column).split("|"):
            for col in part.split("+"):
                col = norm(col)
                if col in have:
                    continue
                near = difflib.get_close_matches(col, have, 1, 0.6)
                problems.append(
                    f"  `{r.target_field}`: column `{col}` is not on "
                    f"{r.source_sheet}" +
                    (f" -- did you mean `{near[0]}`?" if near else
                     f" (that sheet has {len(have)} columns)"))
        t = str(r["transform"])
        # a `duration` row's transform is a UNIT, not a converter: the column
        # holds a count of months or years, not a value to coerce
        ok = ({"months", "years"} if r.role == "duration"
              else set())
        if not (t in ok or t in CONV or t.startswith("eq:")
                or t.startswith("part:") or t.startswith("lead_in:")
                or t.startswith("out:") or t == "keep"):
            problems.append(f"  `{r.target_field}`: unknown transform `{t}`"
                            + ("  (a `duration` row takes `months` or `years`)"
                               if r.role == "duration" else ""))
    if problems:
        raise SystemExit(
            f"{deal}: {len(problems)} registry row(s) point at nothing. "
            f"NOTHING was built --\na mapping that silently does nothing is "
            f"indistinguishable from a tape that\nlacks the field.\n"
            + "\n".join(problems))

    # !! TWO ROWS FEEDING ONE FIELD MUST BE DELIBERATE, NEVER ACCIDENTAL.
    #   PT15018 briefly mapped `cutoff_principal` from both its Collections
    #   OPB and its Claims `Capital`. pandas merged them into
    #   `cutoff_principal_x` and `cutoff_principal_y` and carried on, so the
    #   field simply vanished from the output under a name nothing reads.
    #   `enrich` and `party` are ALLOWED to feed a field the base also feeds -
    #   that is their job, filling gaps - but two rows in the SAME role are a
    #   mistake, and so is any collision the engine cannot order.
    for role in ("base", "align", "scope", "prefer"):
        dup = (m[m.role == role].target_field.value_counts())
        dup = dup[dup > 1]
        if len(dup):
            raise SystemExit(
                f"{deal}: role `{role}` maps {', '.join(dup.index)} more than "
                f"once. One row per field per role - if two columns should be "
                f"combined, say so in one row with `a + b` or `a | b`.")

    # ---- base: the population, from the sheet that tallies to the strats ----
    base = build(tape, m[m.role == "base"])
    base_sheets = set(m[m.role == "base"].source_sheet)
    # !! Every sheet labels its columns twice (Portuguese then English), so one
    #   header row always arrives as DATA -- a "loan" whose fields are column
    #   names. Requiring a numeric loan_id drops it.
    # !! KEEP LOANS WITH NO ACCOUNT NUMBER. 107 in-scope PT15018 loans carry
    #   "Not Available" where the account number should be, and they hold
    #   EUR 1,673,770.57. Dropping them is silent and breaks the tally against the
    #   seller's published total. They are kept with a NULL loan_id and a flag, so
    #   the money is counted and nothing can accidentally join to them.
    # !! A HEADER ROW ARRIVES AS DATA, and it must be dropped without assuming
    #   what a loan id LOOKS like. The first version required a numeric id --
    #   true of PT15018 (account numbers) and false of PT16023, whose ids are
    #   composites like 20_45242832248_DDA. That filter nulled all 19,434 of them.
    #
    #   The general tell is that a header row's values ARE COLUMN NAMES. So reject
    #   a row whose loan_id equals any column name on the sheet, and treat a blank
    #   or an explicit sentinel as "no id", never as a reason to drop the loan --
    #   107 PT15018 loans carrying EUR 1,673,770.57 arrived with no account number
    #   at all and must still be counted.
    # !! A DEAL WITH NO IDENTIFIER AT ALL IS A REAL STATE, NOT A CRASH.
    #   PT20008 is anonymised: its only id-like column, `ID Base cessao`, is
    #   literally the values 1..2905 in order - a row counter the seller left
    #   in, not an account number. There is nothing else on the tape to key
    #   on. The book still has a population, a balance and a reconciliation,
    #   so it cleans; what it cannot do is BRIDGE to prod, and that must be
    #   stated rather than discovered later by a join that returns nothing.
    if "loan_id" not in base.columns:
        print("  !! NO LOAN IDENTIFIER ON THIS TAPE. Every loan_id is NULL and "
              "loan_id_missing_flag is True on all of them.")
        print("     The deal can be cleaned and reconciled; it CANNOT be "
              "bridged to prod until the seller supplies a key.")
        base["loan_id"] = pd.Series(pd.NA, index=base.index, dtype="string")

    # ---- scope: a dedicated in/out column, separate from the segment -------
    # !! SOME SELLERS SAY "NOT FOR SALE" IN THEIR OWN COLUMN. PT15018 puts
    #   `Excluded` among its segment values, so the segment IS the scope rule;
    #   PT19007 keeps a separate `ind_sale`, N on 3 of 14,833 loans worth
    #   EUR 8,431.89. Small, and still wrong to buy. The row is marked
    #   `Excluded` in segment, which is exactly the shape PT15018's seller
    #   uses, so one downstream rule covers both. The vintage label those 3
    #   rows carried is recorded in the deal's CONTEXT.md, not in the data.
    for _, r in m[m.role == "scope"].iterrows():
        c = norm(r.source_column)
        want = str(r["transform"]).split(":", 1)[-1].strip().casefold()
        sh = sheets_matching(tape, r.source_sheet)
        d = tape[tape.source_sheet.isin(sh) & tape.cn.eq(c)]
        if d.empty:
            raise SystemExit(f"scope column `{r.source_column}` not found")
        key = d.set_index(["source_file", "source_sheet", "source_row"]).value
        idx = pd.MultiIndex.from_frame(
            base[["_src_file", "_src_sheet", "_src_row"]]) \
            if "_src_row" in base.columns else None
        out_mask = base.loan_id.isin(
            set(tape[tape.source_sheet.isin(sh) & tape.cn.eq(norm(
                m[(m.role == "base") & (m.target_field == "loan_id")]
                .source_column.iloc[0]))]
                .merge(d[["source_file", "source_sheet", "source_row", "value"]]
                       .rename(columns={"value": "_flag"}),
                       on=["source_file", "source_sheet", "source_row"])
                .query("_flag.astype('string').str.strip().str.casefold() == @want")
                .value))
        n = int(out_mask.sum())
        if n:
            decide("out_of_scope", n,
                   f"{n} loan(s) marked OUT OF SCOPE by the seller's own "
                   f"`{r.source_column}` = {r['transform'].split(':', 1)[-1]}")
            base.loc[out_mask, "segment"] = "Excluded"

    # !! THE SAME LOANS ARRIVE MORE THAN ONCE, AND NOT ALWAYS TIDILY.
    #   Three shapes, all seen on real books, none caught by the loader's
    #   content hash (T24) because the files differ in bytes:
    #     EQUAL     PT19007 ships October 2019 in `..._Asset-Index.xlsx` and
    #               `..._Asset-Index__Analysis.xlsx` - same 799 accounts,
    #               same sheet name, slightly different content.
    #     CONTAINED PT19013's `data_tape_WOFF_202005_Ruby_2` holds 161
    #               accounts which are EXACTLY the March (75) and May (86)
    #               cohorts combined. Different sheet NAMES, so no
    #               same-name rule can see it.
    #     REVISED   PT19013 ships Deceased stock as 320 accounts and again,
    #               in a file named "final", as 310 - ten withdrawn.
    #   A block whose ids are a strict SUBSET of another block's is redundant
    #   whatever the seller intended: every one of its loans is already
    #   counted. Dropping it cannot lose a loan, so it needs no judgement.
    #   Equal sets are the same case; the later filename goes, which prefers
    #   a plain delivery over an `__Analysis` derivative.
    #   A PARTIAL overlap is a different thing - two blocks each holding
    #   loans the other does not - and there the pipeline has no basis to
    #   choose. It REFUSES, and the registry settles it with a `prefer` row.
    # !! A DEAL WITH NO loan_id USED TO GET NO DUPLICATE PROTECTION AT ALL.
    #   Every rule below was gated on `loan_id` being mapped, because blocks
    #   are compared by their id sets. PT20008 maps no loan_id - the seller
    #   ships none - so the whole guard was skipped, and when a second copy
    #   of its book arrived (`Portefolio OneyBank_30.06.2020.xlsx`, the same
    #   2,905 accounts the asset index already held) the engine stacked them
    #   and doubled the deal: 5,810 accounts, EUR 11,503,688.66 against a
    #   true EUR 5,751,844.33. Only the published-strat guard caught it, and
    #   a deal with no published figure would have shipped the double.
    #   So when there is no id, blocks are compared by a ROW FINGERPRINT -
    #   the mapped field values themselves. Two deliveries of one book
    #   fingerprint identically whatever the file is called.
    if ("loan_id" not in base.columns or base.loan_id.isna().all()) and \
            {"_src_sheet", "_src_file"} <= set(base.columns) and \
            base[["_src_file", "_src_sheet"]].drop_duplicates().shape[0] > 1:
        # !! THE FINGERPRINT IS TAKEN ON THE COLUMNS BOTH BLOCKS POPULATE.
        #   Fingerprinting every mapped field instead said PT20008's two
        #   copies differed on 1,205 of 2,905 rows - but the difference was
        #   entirely the five columns the asset index HAS and the portfolio
        #   file does not (the insolvency dates), NaN against a date. A
        #   richer copy of a book is still the same book. Comparing only
        #   where both can speak is the whole point; a column one side never
        #   fills carries no evidence either way.
        mapped = [c for c in base.columns if not c.startswith("_")]
        grp = {k: g for k, g in base.groupby(["_src_file", "_src_sheet"])}
        filled = {k: int(g[mapped].notna().sum().sum()) for k, g in grp.items()}

        def common_fp(a, b):
            cols = [c for c in mapped
                    if grp[a][c].notna().any() and grp[b][c].notna().any()]
            if not cols:
                return None, None, cols
            f = lambda k: set(grp[k][cols].astype(str).agg("\x1f".join, axis=1))
            return f(a), f(b), cols

        pref = {r.source_sheet for _, r in m[m.role == "prefer"].iterrows()}
        drop = set()
        for i, x in enumerate(sorted(grp)):
            for y in sorted(grp)[i + 1:]:
                if x in drop or y in drop:
                    continue
                sx, sy, cols = common_fp(x, y)
                if sx is None:
                    continue           # nothing in common to compare on
                blocks = {x: sx, y: sy}
                if not (sx & sy):
                    continue
                if sx == sy:
                    # One book, delivered twice. Neither adds an account, so
                    # this needs no judgement - but the copies are not equally
                    # useful. The richer one (more populated mapped cells)
                    # wins: PT20008's asset index carries 33 columns to the
                    # portfolio file's 28, including the insolvency dates.
                    lo, hi = (y, x) if filled[x] >= filled[y] else (x, y)
                    decide("duplicate_block", len(blocks[lo]),
                           f"dropped {len(blocks[lo]):,} rows -- {lo[0]} | "
                           f"{lo[1]} is the SAME book as {hi[0]} | {hi[1]} "
                           f"row for row on the {len(cols)} field(s) "
                           f"both populate ({filled[lo]:,} populated cells "
                           f"against {filled[hi]:,}; the fuller copy is kept)")
                    drop.add(lo)
                elif sx < sy or sy < sx:
                    lo = x if sx < sy else y
                    hi = y if sx < sy else x
                    decide("duplicate_block", len(blocks[lo]),
                           f"dropped {len(blocks[lo]):,} rows -- every row is "
                           f"already present in {hi[0]} | {hi[1]}")
                    drop.add(lo)
                elif x[1] in pref or y[1] in pref:
                    lo = y if x[1] in pref else x
                    drop.add(lo)
                    print(f"  registry prefers the other delivery of "
                          f"{lo[1]} -- dropping {lo[0]}")
                else:
                    raise SystemExit(
                        f"REFUSING: {len(sx & sy):,} row(s) are identical in\n"
                        f"  {x[0]} | {x[1]}  ({len(sx):,} rows, "
                        f"{len(sx - sy):,} unique to it)\n"
                        f"  {y[0]} | {y[1]}  ({len(sy):,} rows, "
                        f"{len(sy - sx):,} unique to it)\n"
                        f"{deal} maps no loan_id, so these blocks are "
                        f"compared row for row, and neither contains the "
                        f"other. Two overlapping deliveries of one book "
                        f"cannot be added together.\n"
                        f"Add a registry row to settle it:\n"
                        f"  {deal},prefer,cutoff_balance,{x[1]},<filename>,"
                        f'keep,"why that delivery supersedes the other"')
        if drop:
            DROPPED_FILES.update(f for f, _ in drop)
            keep = ~pd.MultiIndex.from_frame(
                base[["_src_file", "_src_sheet"]]).isin(drop)
            base = base[keep]

    if {"_src_sheet", "_src_file", "loan_id"} <= set(base.columns):
        pref = {(r.source_sheet, r.source_column)
                for _, r in m[m.role == "prefer"].iterrows()}
        blocks = {k: set(g.loan_id.dropna())
                  for k, g in base.groupby(["_src_file", "_src_sheet"])
                  if g.loan_id.notna().any()}
        drop = set()
        for x in sorted(blocks):
            for y in sorted(blocks):
                if x == y or x in drop or y in drop:
                    continue
                sx, sy = blocks[x], blocks[y]
                if not (sx & sy):
                    continue
                if sx < sy or (sx == sy and x > y):
                    # x is redundant: every one of its loans is in y
                    decide("duplicate_block", len(sx),
                           f"dropped {len(sx):,} rows -- every loan already "
                           f"present in a larger block: {x[0]} | {x[1]} "
                           f"(kept {y[0]} | {y[1]}, {len(sy):,} loans)")
                    drop.add(x)
        # whatever still overlaps partially needs a human
        rest = [k for k in sorted(blocks) if k not in drop]
        for i, x in enumerate(rest):
            for y in rest[i + 1:]:
                sh = blocks[x] & blocks[y]
                if not sh:
                    continue
                if (x[1], x[0]) in pref:
                    drop.add(y)
                    print(f"  registry prefers {x[0]} | {x[1]} -- dropping "
                          f"{y[0]} | {y[1]}")
                elif (y[1], y[0]) in pref:
                    drop.add(x)
                    print(f"  registry prefers {y[0]} | {y[1]} -- dropping "
                          f"{x[0]} | {x[1]}")
                elif x[1] == y[1]:
                    # SAME SHEET NAME, so these are two competing deliveries
                    # of ONE cohort and neither is redundant. No basis to
                    # choose; the registry must settle it.
                    raise SystemExit(
                        f"REFUSING: {len(sh):,} loan(s) appear in BOTH\n"
                        f"  {x[0]} | {x[1]}  ({len(blocks[x]):,} loans, "
                        f"{len(blocks[x] - blocks[y]):,} unique to it)\n"
                        f"  {y[0]} | {y[1]}  ({len(blocks[y]):,} loans, "
                        f"{len(blocks[y] - blocks[x]):,} unique to it)\n"
                        f"Same sheet name, so this is one cohort delivered "
                        f"twice and neither copy contains the other.\n"
                        f"Add a registry row to settle it:\n"
                        f"  {deal},prefer,loan_id,{x[1]},<filename>,keep,"
                        f'"why that delivery supersedes the other"')
                # DIFFERENT sheet names and a partial overlap is NOT a dispute.
                # These are different MONTHS, and a loan can appear in two of
                # them: one on PT20014 does, fourteen on PT21004. Refusing
                # there was wrong - the loans are real and both cohorts are
                # real. The duplicate is resolved per LOAN below, by keeping
                # the latest observation.
        if drop:
            DROPPED_FILES.update(f for f, _ in drop)
            keep = ~pd.MultiIndex.from_frame(
                base[["_src_file", "_src_sheet"]]).isin(drop)
            base = base[keep]

        # !! A LOAN IN TWO DIFFERENT MONTHS IS ONE LOAN, SEEN TWICE.
        #   After block pruning a few ids still appear in two cohorts - the
        #   same account written off, reported, and reported again in a later
        #   month. Keeping both rows would double its balance and break the
        #   uniqueness guard; dropping either arbitrarily would be a guess.
        #   The later observation supersedes, and the sheet name carries the
        #   month (data_tape_WOFF_yyyymm_...), so "latest" is a sort, not a
        #   judgement. Reported, never silent.
        # !! ONLY ACROSS SHEETS. NEVER WITHIN ONE. A repeated id inside a
        #   single sheet is the SELLER'S OWN DATA and collapsing it destroys
        #   loans: PT16023's "Unique Loan ID" is not unique (T19) and 1,153
        #   of its 19,434 accounts share an id with another, and PT15018
        #   writes migration-split accounts under one number which a LATER
        #   step collapses by grain. A first version of this rule deduplicated
        #   every repeated id and quietly deleted 1,153 loans worth
        #   EUR 12.2m from one book and 105 worth EUR 4.5m from the other.
        #   Both guards failed within the minute, which is the only reason
        #   this is a comment and not a defect in the output.
        per_sheet = base[base.loan_id.notna()].groupby("loan_id")._src_sheet.nunique()
        spans = set(per_sheet[per_sheet > 1].index)
        dupe = base.loan_id.isin(spans) & base.loan_id.duplicated(keep=False)
        if dupe.any():
            order = base[dupe].sort_values(["loan_id", "_src_sheet"])
            kept = order.groupby("loan_id", sort=False).tail(1).index
            lose = base.index[dupe].difference(kept)
            if len(lose):
                n_sheets = base.loc[lose, "_src_sheet"].nunique()
                decide("reported_twice", len(lose),
                       f"collapsed {len(lose):,} row(s) -- a loan reported in "
                       f"more than one month, across {n_sheets} sheet(s). "
                       f"Kept the LATEST observation of each.")
                base = base.drop(index=lose)

    colnames = {norm(c).lower() for c in tape.cn.unique()}
    lid = base.loan_id.astype("string").str.strip()
    header = lid.str.lower().isin(colnames)
    base = base[~header.fillna(False)]

    # !! A SECOND HEADER ROW IN ANOTHER LANGUAGE SURVIVES THE TEST ABOVE.
    #   PT15018's sheets carry TWO header rows: row 0 in Portuguese, which
    #   becomes the column names, and row 1 holding the English translation,
    #   which arrives as DATA. `Account Number` is not among the column names
    #   -- `Numero de Conta` is -- so matching values against column names
    #   cannot see it, and the row reached the output as a loan whose
    #   product_type was "Product Code".
    #   The language-independent tell is that a header row carries NO QUANTITY:
    #   every mapped amount and every mapped date is unparseable, because the
    #   cells hold words. A real loan always carries at least one. Dropping is
    #   REPORTED, never silent -- this is the one place rows leave the book.
    qty = [c for c in base.columns
           if c in AMOUNT_FIELDS or c in DATE_FIELDS]
    if qty:
        has = pd.Series(False, index=base.index)
        for c in qty:
            v = (pd.to_numeric(base[c], errors="coerce") if c in AMOUNT_FIELDS
                 else pd.to_datetime(base[c], errors="coerce"))
            has |= v.notna()
        # !! A FOOTER CALCULATION CARRIES AN AMOUNT AND IS STILL NOT A LOAN.
        #   Below its grand total, PT15014's June sheet holds 2,253,268.21 x
        #   0.081 = 182,514.73 - the book and the 8.1% purchase price. Those
        #   rows pass the quantity test above, because they ARE quantities.
        #   Two conditions together, and both are needed:
        #     TRAILING  - after the last row of that sheet carrying a loan_id,
        #                 so an interior row can never be touched. PT15018 has
        #                 106 REAL loans with no account number at all, worth
        #                 EUR 1,673,770.57, and they sit among the others.
        #     LONELY    - at most one mapped field populated. A real loan,
        #                 even one missing its id, carries a segment, a
        #                 product or a date alongside its balance.
        if "_src_sheet" in base.columns and "loan_id" in base.columns:
            # !! INTERNAL COLUMNS ARE NOT EVIDENCE OF A LOAN. The fallback
            #   flag is populated on every row including the footer ones, so
            #   counting it as a mapped field made two footer rows look like
            #   real loans again and put EUR 182,514.73 back in the book.
            # !! ONE PREFIX TEST, NOT A LIST OF NAMES. This named `_src_sheet`
            #   and `_src_file` explicitly, so adding `_src_row` for the
            #   unique_key silently made every footer row look like a real
            #   loan again and put EUR 182,514.73 back in PT15014. A list of
            #   internal columns is a list that goes stale the next time one
            #   is added.
            mapped_cols = [c for c in base.columns
                           if c != "loan_id"
                           and not c.startswith(("_src_", "_fb_"))]
            # !! "AT MOST ONE FIELD" WAS TOO NARROW. PT19007's last row holds
            #   973,486.00 and 0.33 - a book total and a price rate, TWO
            #   populated fields, so it survived and became the largest loan
            #   in the deal. What actually separates a footer from a loan is
            #   not how many fields it fills but WHICH: a real loan always
            #   carries a date or a label - a segment, a product, a client -
            #   beside its money. A footer carries money alone.
            non_amount = [c for c in mapped_cols if c not in AMOUNT_FIELDS]
            filled_n = (base[non_amount].notna().sum(axis=1) if non_amount
                        else pd.Series(0, index=base.index))
            has_id = base.loan_id.notna()
            # !! COMPARE A SERIES TO A SERIES. `base.index > mapped_series`
            #   compares an Index against a Series and quietly produced all
            #   False, so this whole rule matched nothing and two price rows
            #   reached the output as loans - one of them EUR 182,514.73, the
            #   largest "balance" in the book. It looked like it worked
            #   because a separate NA quirk was hiding them from the count.
            pos = pd.Series(range(len(base)), index=base.index)
            lastpos = pos[has_id].groupby(base._src_sheet[has_id]).max()
            after = pos > base._src_sheet.map(lastpos).fillna(-1)
            foot = after & ~has_id & filled_n.eq(0)
            if foot.any():
                decide("footer_calc", int(foot.sum()),
                       f"dropped {int(foot.sum())} trailing footer row(s) "
                       f"below the last loan -- a total, a price or a rate")
                for _, r in base[foot].head(4).iterrows():
                    vals = {k: r[k] for k in mapped_cols if pd.notna(r[k])}
                    print(f"    {r._src_sheet}: {vals}")
                base = base[~foot]

        junk = base[~has.reindex(base.index, fill_value=True)]
        if len(junk):
            decide("no_quantity", len(junk),
                   f"dropped {len(junk)} row(s) carrying no amount and no date "
                   f"-- a header row or a stray, never a loan")
            for _, r in junk.head(5).iterrows():
                shown = {k: str(r[k])[:22] for k in ("loan_id", "segment",
                         "product_type") if k in junk.columns and pd.notna(r[k])}
                print(f"    {shown}")
        base = base[has.reindex(base.index, fill_value=True)]
    lid = base.loan_id.astype("string").str.strip()
    base["loan_id_missing_flag"] = lid.isna() | lid.str.lower().isin(
        {"", "n.a.", "na", "not available", "nan", "x"})
    base.loc[base.loan_id_missing_flag, "loan_id"] = pd.NA
    # !! EVERY AMOUNT IS ADDITIVE WHEN A GRAIN COLLAPSES, not just the
    #   balance. This named `cutoff_balance` alone, so when PT15018's OPB
    #   moved to `cutoff_principal` its 79 migration-split accounts were
    #   collapsed with `first` instead of `sum` and the book came out
    #   EUR 1,201,901.56 light - against a published figure it had matched to
    #   the cent for a week. A hardcoded list of one is a list that will be
    #   wrong as soon as the schema grows.
    sums = [c for c in AMOUNT_FIELDS if c in base]
    # !! min_count=1: pandas sums all-null to 0.0, turning "not supplied" into zero.
    # Unidentified rows must each stay their own loan, not collapse into one.
    # !! THE GRAIN IS A PROPERTY OF THE DEAL, NOT OF THE PIPELINE.
    #
    #   PT15018 MUST collapse: 79 accounts were split into several system records
    #   by a DDA->OCV migration, so their balances are PARTS of one loan.
    #   PT16023 MUST NOT: its published strats say "# of accounts 19,434", one per
    #   tape row. Collapsing its composite id gives 18,283 and stops matching the
    #   seller's own count.
    #
    #   Hardcoding either one is overfitting. `grain` says which, per deal, and
    #   the default is `row` -- what the tape shipped -- because that is what a
    #   seller publishes a count of. Collapsing is the exception and must be asked for.
    grain = m[m.role == "grain"].source_column.iloc[0] if (m.role == "grain").any() else "row"
    if grain == "row":
        base = base.reset_index(drop=True)
        base["_k"] = base.index.astype(str)
    else:
        base["_k"] = base.loan_id.where(~base.loan_id_missing_flag,
                                    pd.Series("__noid__" + base.index.astype(str),
                                              index=base.index))
    # !! EVERY AMOUNT IS ADDITIVE WHEN A GRAIN COLLAPSES, not just the
    #   balance. This named `cutoff_balance` alone, so when PT15018's OPB
    #   moved to `cutoff_principal` its 79 migration-split accounts were
    #   collapsed with `first` instead of `sum` and the book came out
    #   EUR 1,201,901.56 light - against a published figure it had matched to
    #   the cent for a week. A hardcoded list of one is a list that will be
    #   wrong as soon as the schema grows.
    sums = [c for c in AMOUNT_FIELDS if c in base]
    agg = {c: (lambda x: x.sum(min_count=1)) for c in sums}
    agg.update({c: "first" for c in base.columns if c not in sums and c != "_k"})
    base = base.groupby("_k", as_index=False).agg(agg).drop(columns="_k")

    # ---- enrich: detail where the other sheet describes the loan -----------
    en = build(tape, m[m.role == "enrich"])
    if not en.empty:
        key = m[(m.role == "base") & (m.target_field == "loan_id")]
        ek = build(tape, m[m.role == "enrich"].assign(
            target_field="loan_id", source_column="Numero de Conta", transform="text"))
        en = en.assign(loan_id=ek.loan_id if "loan_id" in ek else pd.NA)
        en = en[en.loan_id.notna() & en.loan_id.str.fullmatch(r"\d+", na=False)]
        esums = [c for c in ("cutoff_principal", "cutoff_interest", "claims_balance",
                             "origination_amount") if c in en]
        en = en.groupby("loan_id", as_index=False).agg(
            {**{c: (lambda x: x.sum(min_count=1)) for c in esums},
             **{c: "first" for c in en.columns if c not in esums and c != "loan_id"}})
        base = base.merge(en, on="loan_id", how="left")
        # !! `full` MEANS "THIS LOAN IS ON THE DETAILED SHEET", and it used to
        #   be read off cutoff_principal - which was fine while principal came
        #   only from an enrich sheet, and wrong the moment a base column fed
        #   it. PT15018 flipped to 32,692 "full detail" loans overnight.
        #   The detail sheets are the enrich ones, so ask those directly.
        _enr = [r.target_field for _, r in m[m.role == "enrich"].iterrows()
                if r.target_field in base.columns]
        base["detail_level"] = ("basic" if not _enr else
                                base[_enr].notna().any(axis=1)
                                .map({True: "full", False: "basic"}))
    else:
        base["detail_level"] = "basic"

    # ---- holder flags: FACTS, NOT A SEGMENT. Both can be true. -------------
    if "borrower_type" in base:
        # !! KEEP THE SELLER'S OWN WORD, NOT ONLY OUR READING OF IT. This
        #   popped the column: the two booleans survived and `Company` /
        #   `Individual` - what the seller actually wrote - was discarded.
        #   The flags are a DERIVATION from that word, and a reader who wants
        #   to check the derivation had nothing to check it against.
        bt_raw = base["borrower_type"].astype("string").str.strip()
        bt = base.pop("borrower_type").astype("string").str.lower()
        base["borrower_type"] = bt_raw
        base["loan_holder_individual_flag"] = bt.str.contains(
            "individual|particular|eni", na=False).where(bt.notna())
        base["loan_holder_corporate_flag"] = bt.str.contains(
            "compan|empres|sociedade|eni", na=False).where(bt.notna())

    def join_column(w, ids):
        """Which column on this sheet joins to the loans' client_id?

        !! DISCOVERED BY VALUE OVERLAP, NOT BY NAME. The same identifier wears a
          different name on different sheets of ONE workbook: PT15018 calls it
          `Cliente Number` on Collections and `Numero de Cliente Interno` on the
          party sheets. Keying on the name silently found nothing and dropped
          1,450 judicialised flags -- the backtest caught it, nothing else would.

          Overlap is the honest test: the right column is the one whose values
          ARE these loans' client ids. It needs no per-deal configuration and
          survives a seller who names it a third way.

        !! A FIXED THRESHOLD IS WRONG. `Other Participants` lists co-holders and
          guarantors -- people who are NOT the main borrower -- so only 8% of its
          client numbers appear in the loan list. That is CORRECT for that sheet,
          and a 50% bar skipped it and lost 64 judicialised flags.

          So: take the clear winner, not whatever clears a bar. The right column
          beats the next best by a wide margin (8% vs 0% here, 100% vs 1% on Main
          Debtors); when nothing stands out, there is no join column and the sheet
          is skipped.
        """
        scored = []
        for c in w.columns:
            v = set(w[c].astype("string").str.strip().dropna())
            if v:
                scored.append((len(v & ids) / len(v), c))
        if not scored:
            return None
        scored.sort(reverse=True)
        best, runner = scored[0], (scored[1] if len(scored) > 1 else (0.0, None))
        if best[0] < 0.02:
            return None                      # nothing matches at all
        if runner[0] > 0 and best[0] < runner[0] * 5:
            return None                      # no clear winner -- ambiguous
        return best[1]

    def apply_filters(w, sheet):
        """Drop rows a `filter` row says do not belong on this sheet.

        !! A SHEET IS NOT ALWAYS ONE KIND OF THING. PT15018's
        `Proceedings Legal` holds 2,990 court files and only some are the bank
        suing the borrower: 308 are insolvency proceedings, 148 judicial
        recoveries, 10 pre-insolvency. Taking the earliest date on the sheet
        and calling it the judicialisation date dates a loan's litigation from
        an insolvency filing - merging the two concepts the schema keeps
        apart, in the one place nobody would look.

        The seller labels every row. The filter is therefore the seller's own
        classification, not ours.
        """
        for _, F in m[m.role == "filter"].iterrows():
            if not sheets_matching(tape, F.source_sheet) or \
                    norm(F.source_column) not in w.columns:
                continue
            if F.source_sheet != sheet:
                continue
            tf = str(F["transform"])
            if not tf.startswith("out:"):
                continue
            drop = {v.strip() for v in tf[4:].split("|")}
            col = w[norm(F.source_column)].astype("string").str.strip()
            n = int(col.isin(drop).sum())
            if n:
                decide("filtered_rows", n,
                       f"{sheet}: dropped {n:,} row(s) where "
                       f"`{F.source_column}` is one of "
                       f"{', '.join(sorted(drop))} -- {F.note}")
            w = w[~col.isin(drop)]
        return w

    def client_columns(w, ids):
        """EVERY column on this sheet whose values are clients, not just one.

        join_column answers "which column IS the key"; this answers "which
        columns name a person we know". A participant list legitimately holds
        several, and taking only the best one drops the co-debtors.
        """
        scored = []
        for c in w.columns:
            v = set(w[c].astype("string").str.strip().dropna())
            if v:
                scored.append((len(v & ids) / len(v), c))
        if not scored:
            return []
        best = max(s for s, _ in scored)
        if best < 0.02:
            return []
        return [c for sc, c in sorted(scored, reverse=True) if sc >= best / 5]

    # ---- party: person-level facts, rolled up to the loan ----------------
    #
    # !! THE FINER GRAIN WINS, ALWAYS. A fact stated about THIS LOAN is better
    #   evidence than the same fact stated about a PERSON and inherited by every
    #   loan they hold -- PT15018 borrowers hold up to 21, so a person-level
    #   rollup asserts about 21 loans what the tape said about one human.
    #
    #   So: if a field is mapped at BOTH levels, the loan-level mapping is kept
    #   and the party one only fills the rows it left null. If only the party
    #   level exists, it is rolled up with max() -- a loan is flagged when ANY
    #   party on it is -- which is a floor, never a denial.
    #
    #   General, not a rule about judicialised: it applies to any field a tape
    #   happens to state twice. PT16023 states it on the loan, PT15018 on the
    #   person, and neither needed configuring.
    pf = []
    for sheet, grp in m[m.role == "party"].groupby("source_sheet"):
        d = tape[tape.source_sheet == sheet]
        if d.empty:
            continue
        w = d.pivot_table(index=["source_file", "source_row"], columns="cn",
                          values="value", aggfunc="first").reset_index()
        ids = set(base.client_id.astype("string").str.strip().dropna())
        key = join_column(w, ids)
        if key is None:
            continue
        for _, r in grp.iterrows():
            c = norm(r.source_column)
            if c in w.columns:
                pf.append((r.target_field, pd.DataFrame({
                    "client_id": w[key].astype("string").str.strip(),
                    "v": conv(r["transform"])(w[c])}).dropna(subset=["v"])))

    # ---- bridge: a fact sheet that reaches the loan only through a THIRD ----
    #
    # !! SOME FACTS ARE NOT KEYED TO ANYBODY. PT15018's `Proceedings Legal`
    #   holds the court record - which court, what kind of action, the date it
    #   entered and the date it closed - across fifteen columns and not one of
    #   them is a client or an account. Every value on that sheet was therefore
    #   invisible: `party` looks for a column whose values ARE client ids,
    #   finds none, and skips the sheet in silence.
    #
    #   The sheet is keyed by PROCESS, and a third sheet - `Participants Legal`
    #   - carries both the process number and the client number, because that
    #   is where the seller recorded who is party to what. So the route exists;
    #   it is just two hops.
    #
    # !! THE BRIDGE IS DECLARED, THE COLUMNS ARE NOT. A `link` row names the
    #   bridging SHEET and its process column; which column holds the client,
    #   and which column on the fact sheet holds the process, are both found by
    #   VALUE OVERLAP, exactly as `party` finds its key. Naming four columns by
    #   hand across three sheets is four chances to be wrong about a seller who
    #   spells the same id three ways - and this tape does.
    #
    # !! IT FANS OUT, AND THAT IS CORRECT. One proceeding can name several
    #   participants, and the merge gives the fact to each of them. A court
    #   action against two co-debtors IS a court action against both; the
    #   rollup below then takes max() per loan, so a loan is dated when ANY
    #   party to it was.
    for sheet, grp in m[m.role == "bridge"].groupby("source_sheet"):
        d = tape[tape.source_sheet == sheet]
        if d.empty:
            continue
        w = d.pivot_table(index=["source_file", "source_row"], columns="cn",
                          values="value", aggfunc="first").reset_index()
        w = apply_filters(w, sheet)
        ids = set(base.client_id.astype("string").str.strip().dropna()) \
            if "client_id" in base else set()
        route = None
        for _, L in m[m.role == "link"].iterrows():
            b = tape[tape.source_sheet == L.source_sheet]
            if b.empty:
                continue
            bw = b.pivot_table(index=["source_file", "source_row"], columns="cn",
                               values="value", aggfunc="first").reset_index()
            lcol = norm(L.source_column)
            # !! A BRIDGE MAY CARRY THE CLIENT IN MORE THAN ONE COLUMN, AND
            #   BOTH ARE RIGHT. `Participants Legal` names the client AND the
            #   intervening party - `Numero de Cliente Interno` overlaps the
            #   loan book at 78.3%, `...(Interveniente)` at 80.7%. join_column
            #   demands a FIVE-FOLD winner and so refuses, correctly: for a
            #   single key, two near-equal candidates mean you do not know
            #   which one it is.
            #   A participant list is the opposite case. A proceeding reaches
            #   a loan through ANY party to it, so both columns are taken and
            #   stacked - the same logic as the max() rollup below, where a
            #   loan is flagged when any party on it is.
            bkeys = client_columns(bw, ids)
            if not bkeys or lcol not in bw.columns:
                continue
            link_ids = set(bw[lcol].astype("string").str.strip().dropna())
            fkey = join_column(w, link_ids)
            if fkey is None:
                continue
            pairs = pd.concat(
                [bw[[lcol, k]].rename(columns={lcol: "_link", k: "client_id"})
                 for k in bkeys], ignore_index=True)
            route = (pairs, fkey, L.source_sheet, bkeys)
            break
        if route is None:
            # REPORTED, never silent: a declared fact that cannot be reached is
            # a gap somebody should see, not an empty column.
            decide("bridge_unreachable", 0,
                   f"{sheet}: no `link` row reaches client_id from it -- "
                   f"{len(grp)} field(s) NOT mapped from this sheet")
            continue
        bmap, fkey, via, bkeys = route
        bmap = (bmap.astype("string").apply(lambda c: c.str.strip())
                .dropna().drop_duplicates())
        w["_link"] = w[fkey].astype("string").str.strip()
        j = w.merge(bmap, on="_link", how="inner")
        decide("bridged_sheet", len(j),
               f"{sheet}: reached {j.client_id.nunique():,} client(s) via "
               f"`{via}` on {len(bkeys)} participant column(s) "
               f"({', '.join(bkeys)}); {len(w):,} row(s) on the sheet, "
               f"{len(j):,} after the join -- one per participant per "
               f"proceeding")
        # !! A PERIOD IS AN ENVELOPE, NOT ONE RECORD, AND NOT A MAX PER FIELD.
        #   Three ways to roll two dates up to a loan, and only one is honest:
        #
        #   max() per field    takes the start of one proceeding and the end of
        #                      another. 316 PT15018 loans ended before they
        #                      began, against ZERO such rows on the seller's
        #                      sheet. A record that is not true of anything.
        #   one record         pick the latest proceeding, use both its dates.
        #                      Never crosses - but 692 of 1,383 clients here
        #                      have MORE than one proceeding and one has 270,
        #                      so it answers "the last time" when the question
        #                      is "how long".
        #   the envelope       min(start), max(end). The span legal action ran
        #                      over the loan. Cannot cross, and uses all of it.
        #
        # !! AND AN END IS ONLY AN END WHEN EVERYTHING IS CLOSED. 998 of those
        #   1,383 clients have at least one proceeding with no finish date.
        #   max() over the closed ones would date the loan's legal history as
        #   finished while an action is still running - the most expensive
        #   thing on this sheet to get wrong. So the end is written ONLY where
        #   every proceeding for that client has one; otherwise it is NULL,
        #   which the schema already defines as UNKNOWN and never "still open".
        cols = {norm(r.source_column): r for _, r in grp.iterrows()
                if norm(r.source_column) in j.columns}
        if cols:
            conv_j = pd.DataFrame({"client_id": j["client_id"]})
            for c, r in cols.items():
                v = conv(r["transform"])(j[c]).values
                # min()/max() on an object column of Timestamps raises; the
                # date transform hands back objects, so coerce once here
                conv_j[r.target_field] = (pd.to_datetime(v, errors="coerce")
                                          if r.target_field in DATE_FIELDS
                                          else v)
            g = conv_j.groupby("client_id")
            kept, how = {}, []
            for f in [c for c in conv_j.columns if c != "client_id"]:
                if f.endswith("_start_date"):
                    kept[f] = g[f].min(); how.append(f"{f}=min")
                elif f.endswith("_end_date"):
                    allc = g[f].apply(lambda x: x.notna().all())
                    kept[f] = g[f].max().where(allc); how.append(f"{f}=max if all closed")
                else:
                    kept[f] = g[f].max(); how.append(f"{f}=max")
            agg = pd.DataFrame(kept).reset_index()
            decide("bridge_rollup", len(agg),
                   f"{sheet}: {len(conv_j):,} participant-row(s) over "
                   f"{len(agg):,} client(s) -- {'; '.join(how)}")
            for _, r in grp.iterrows():
                if r.target_field in agg.columns:
                    pf.append((r.target_field, agg[["client_id", r.target_field]]
                               .rename(columns={r.target_field: "v"})
                               .dropna(subset=["v"])))

    if pf and "client_id" in base:
        for field, f in pf:
            rolled = base.client_id.map(f.groupby("client_id")["v"].max())
            if field in base and base[field].notna().any():
                # loan level already answered -- party only fills the gaps
                base[field] = base[field].where(base[field].notna(), rolled)
            else:
                base[field] = rolled

    # ---- align: a second sheet of the SAME export, with no shared key -------
    # !! POSITIONAL JOINS ARE NORMALLY INDEFENSIBLE, so this one must PROVE
    #   itself before it is allowed. PT15020 ships its book twice: ANEXO_I_DADOS
    #   carries the contract number, the tax id and the dates, and
    #   `asset-index with interest` carries the balance, the principal and the
    #   interest split. There is no key in common - `Contrato` and `Venda`
    #   overlap on ZERO values, because `Venda` is just a row counter whose
    #   first cell is a leaked header. Dropping the second sheet would lose
    #   the headline balance (1,850,682.30) and the whole interest split; both
    #   reconcile exactly to the seller's own total row.
    #
    #   The precondition is arithmetic and it is checked every run: some column
    #   present on BOTH sheets must agree ROW FOR ROW. Here `Encours_contabilistico`
    #   and `Saldo_Contabilistico` match on 5,313 of 5,313 to ten decimal places,
    #   which is not something two unrelated orderings do. If that stops being
    #   true the run FAILS rather than quietly mis-pairing every loan.
    al = m[m.role == "align"]
    if len(al):
        if len(base_sheets) != 1:
            raise SystemExit("align needs exactly one base sheet, got "
                             f"{sorted(base_sheets)}")
        bsheet = next(iter(base_sheets))
        for sheet, grp in al.groupby("source_sheet"):
            bw = _sheet(tape, bsheet)
            aw = _sheet(tape, sheet)
            # !! TRAILING JUNK IS ALLOWED ON THE LONGER SHEET, NOTHING ELSE.
            #   PT15020's second sheet ends with four loose cells below the
            #   total row - a stray principal, a stray interest figure, a
            #   note reading "(includes interest)". They are not loans and
            #   they are not on the base sheet. So the pairing only has to
            #   hold across EVERY row of the base, and anything past that is
            #   discarded and counted. A sheet SHORTER than the base is still
            #   refused outright: that means rows are missing, not trailing.
            if len(aw) < len(bw):
                raise SystemExit(
                    f"align refused: {sheet} has {len(aw):,} rows, fewer than "
                    f"{bsheet}'s {len(bw):,}. Rows are missing, not trailing.")
            if len(aw) > len(bw):
                print(f"  align: discarding {len(aw) - len(bw)} trailing row(s) "
                      f"of `{sheet}` below the base's last loan")
                aw = aw.iloc[:len(bw)]
            shared = [c for c in bw.columns if c in aw.columns]
            proof = None
            for c in shared:
                x = pd.to_numeric(bw[c].reset_index(drop=True), errors="coerce")
                y = pd.to_numeric(aw[c].reset_index(drop=True), errors="coerce")
                if x.notna().sum() < len(x) * 0.5:
                    continue
                if (x - y).abs().lt(0.005).sum() == len(x):
                    proof = c
                    break
            # a column need not share a NAME to prove the ordering; try the
            # pairs the registry itself says are the same measure
            if proof is None:
                for _, r in grp.iterrows():
                    bc, ac = norm(str(r.note or "")), norm(r.source_column)
                    if bc in bw.columns and ac in aw.columns:
                        x = pd.to_numeric(bw[bc].reset_index(drop=True), errors="coerce")
                        y = pd.to_numeric(aw[ac].reset_index(drop=True), errors="coerce")
                        if x.notna().sum() and (x - y).abs().lt(0.005).sum() == len(x):
                            proof = f"{bc} == {ac}"
                            break
            if proof is None:
                raise SystemExit(
                    f"align refused: no column proves {sheet} is ordered like "
                    f"{bsheet}. Without that, pairing by position is a guess.")
            print(f"  aligned `{sheet}` to `{bsheet}` by position -- "
                  f"proven row-for-row by `{proof}` on {len(bw):,} rows")
            for _, r in grp.iterrows():
                v = take(aw.reset_index(drop=True), r.source_column,
                         r["transform"])
                if v is not None:
                    v.index = base.index[:len(v)]
                    base[r.target_field] = v

    for col in [c for c in base.columns if c.startswith("_fb_")]:
        field = col[4:]
        src = m[m.target_field == field].source_column
        alts = [x.strip() for x in str(src.iloc[0]).split("|")] if len(src) else []
        for a in alts[1:]:
            n = int(base[col].eq(a).sum())
            if n:
                decide("fallback_column", n,
                       f"{n:,} loan(s) took `{a}` for `{field}` because "
                       f"`{alts[0]}` is empty on their sheet")

    files = tape.source_file.unique()
    base["offer_stage"] = offer_stage(" ".join(map(str, files)))

    # !! SET FROM EVIDENCE, NEVER BY HAND. `reconciled` requires an exact match
    #   against a figure the SELLER published (find_strats.py). I called this
    #   deal "clean" three times while it was wrong; the status is not mine to
    #   assert. No strats file, or no hit in it -> `consistent` at best.
    # !! AND COVERAGE DECIDES IT, NOT THE EXISTENCE OF A HIT. Any hit used to
    #   set `reconciled`, so PT19007 was labelled reconciled on ONE proven
    #   footer total out of thirteen sheets, and PT20014 on one out of
    #   thirty-nine. Partial evidence reading as full evidence is the exact
    #   failure this field exists to prevent - the figure a reader trusts is
    #   the one with the word `reconciled` beside it.
    #   `reconciled` now means the proven totals account for essentially the
    #   WHOLE book. A deal that proves one cohort out of twelve is
    #   `consistent`, and the coverage is printed so the gap is a number
    #   rather than an impression.
    strat = _P.STRATS / f"{deal}.json"
    # !! INITIALISE `proven`. It was assigned only inside `if hits:` and then
    #   read unconditionally when the metadata was written, so every deal with
    #   NO published total raised UnboundLocalError and never wrote its
    #   output. Four of twelve. They kept their previous parquet on disk, so
    #   the guards and reviews that followed read stale files and looked fine.
    status, covered, proven = "consistent", 0.0, set()
    if strat.exists():
        import json as _j
        hits = _j.loads(strat.read_text()).get("hits", [])
        if hits:
            bal = pd.to_numeric(base.get("cutoff_balance"), errors="coerce")
            total = float(bal.sum()) if bal is not None else 0.0
            # a hit names the sheet it was proven on; sum the in-scope balance
            # of every sheet that carries one
            # !! ONLY THE BALANCE COLUMN COUNTS TOWARDS BALANCE COVERAGE.
            #   Counting every sheet that proved ANY column overstated it:
            #   PT15014 claimed 8 of 11 sheets when `woff_bal` - the column
            #   this deal actually IS - is proven on 7, and the eighth sheet
            #   was proven only by an interest column. A sheet whose interest
            #   figure ties says nothing about whether its balance does.
            _bal = m[(m.target_field == "cutoff_balance")]
            # !! A REGISTRY CELL CAN NAME SEVERAL COLUMNS. `curr_bal | woff_bal`
            #   compared literally against a hit's amount_column matched
            #   nothing, and PT15014 reported 0% coverage on a book where
            #   20 totals reconcile.
            _bal_cols = {norm(x) for c in ([str(_bal.source_column.iloc[0])]
                                           if len(_bal) else [])
                         for part in c.split("|") for x in part.split("+")}
            proven = {h.get("sheet") for h in hits
                      if not _bal_cols
                      or norm(str(h.get("amount_column"))) in _bal_cols}
            # !! THE BALANCE DOES NOT ALWAYS COME FROM THE ROW'S OWN SHEET.
            #   PT15020's balance is `align`-mapped: every row originates on
            #   ANEXO_I_DADOS while its balance is read, position by position,
            #   from `asset-index with interest`. Matching the proven sheet
            #   against `_src_sheet` therefore matched nothing and reported
            #   0% coverage for a deal that reconciles three ways to the cent.
            #   An aligned sheet is 1:1 with the whole base by construction,
            #   so if it is proven, all of it is proven.
            _bal_sheets = set(sheets_matching(tape, _bal.source_sheet.iloc[0])) \
                if len(_bal) else set()
            _aligned = (len(_bal) and _bal.role.iloc[0] == "align") or (
                "_src_sheet" in base.columns and _bal_sheets
                and not (_bal_sheets & set(base._src_sheet.dropna().unique())))
            if _aligned:
                covered = 1.0 if (proven & _bal_sheets) else 0.0
            elif "_src_sheet" in base.columns and total:
                covered = float(bal[base._src_sheet.isin(proven)].sum()) / total
            elif total:
                covered = 1.0
            status = "reconciled" if covered >= 0.995 else "consistent"
            print(f"  strats: {len(hits)} proven total(s) covering "
                  f"{covered:.1%} of the in-scope balance -> {status}")
    base["verification_status"] = status
    # !! PERSIST THE COVERAGE. It was printed and thrown away, so the sheet a
    #   human signs could not say how far the proof actually reached - and on
    #   PT15014 that is the whole point: 20 proven totals covering 75.3% of
    #   the book. A number only the terminal ever saw is not evidence.
    # !! THE SELLER WAS NEVER IN THE DATA, only in prose I typed at the top of
    #   each CONTEXT.md - and PT15020 said Cetelem for a day when its own
    #   filename says Oney. A fact that appears on every summary and review
    #   belongs in a registry, where it can be wrong once and fixed once.
    _d = pd.read_csv(_P.DEALS).query("deal_id == @deal")
    if _d.empty:
        raise SystemExit(f"{deal} is not in deals.csv -- add its seller and "
                         f"country before cleaning it")
    # !! A FINGERPRINT OF THIS DEAL'S ROWS, NOT THE FILE'S TIMESTAMP. The
    #   staleness check compared mappings.csv's mtime, so adding a row for an
    #   UNRELATED deal stamped "DO NOT SIGN THIS" across every other sheet.
    #   One new deal would have blocked a review of twelve.
    _mysig = _hashlib.md5(
        m.sort_values(list(m.columns)).astype(str).to_csv(index=False).encode()
    ).hexdigest()
    _meta = {
        "deal": deal,
        "registry_md5": _mysig,
        "seller": str(_d.seller.iloc[0]),
        "country": str(_d.country.iloc[0]),
        "verification_status": status,
        "proven_coverage": round(covered, 6),
        # the sheets whose BALANCE figure is proven, which is what the
        # coverage above measures -- not merely sheets with some hit
        "proven_sheets": sorted(proven) if strat.exists() else [],
        "source_sheets": sorted(base._src_sheet.dropna().unique().tolist())
        if "_src_sheet" in base.columns else [],
        "decisions": list(DECISIONS),
    }

    # !! THE CUT-OFF IS A PROPERTY OF THE DEAL, ON EVERY LOAN. It was mapped
    #   from a SHEET on PT15018 - the Claims `Data de Referencia`, 2016-07-08 -
    #   which is when the legal claims were measured, not when the book was
    #   struck. It landed on 673 of 32,529 loans and was ten months late.
    #   Anyone deriving "which payments are interim" from it would have
    #   classified the entire interim window as pre-cut-off performance.
    #   It now comes from deals.csv and applies to every loan, so the
    #   accounts carry the one date the payments must be split on - and a
    #   deal without a known cut-off carries NULL, which downstream must
    #   treat as "cannot be split", not as zero.
    _cd = str(_d.cutoff_date.iloc[0]) if "cutoff_date" in _d.columns else ""
    if _cd and _cd != "nan":
        base["cutoff_date"] = pd.to_datetime(_cd).date()

    # ---- duration: an end a seller states as a LENGTH, not as a date -------
    #
    # !! A PERIOD CAN BE GIVEN AS start + term, AND THAT IS STILL AN END DATE.
    #   Portuguese exoneration runs a statutory five years, and PT20008 proves
    #   it in data: of 1,205 insolvency periods, 1,189 are exactly 5.00 years
    #   and the longest exception is 5.25. A seller who ships the start and
    #   the term, rather than both dates, is telling you the same fact in a
    #   different shape.
    #
    # !! A DERIVED END IS NOT A STATED END, AND NEVER OVERWRITES ONE. It is
    #   written only where the seller gave no end date, and every derived
    #   value is accompanied by `<x>_end_date_derived` saying what it was
    #   computed from. A reader who needs only what the seller actually
    #   stated can filter on it; without it, arithmetic and evidence would be
    #   indistinguishable in the same column, which is how a derived figure
    #   ends up quoted as a fact.
    #
    #   NO PORTUGUESE DEAL SHIPS ONE TODAY - every duration-looking column on
    #   all twelve tapes is a LOAN term (maturity_date, termmnth, termbal) or
    #   an account age (meses_antiguedad, years_on_book, Age (Months)), not
    #   the length of a proceeding. This is here so that the next tape that
    #   does costs one registry row instead of an engine change.
    for _, r in m[m.role == "duration"].iterrows():
        tgt = str(r.target_field)
        if not tgt.endswith("_end_date"):
            raise SystemExit(
                f"REFUSING: `duration` must target a `<x>_end_date`, got "
                f"`{tgt}`. A length is only meaningful against a start.")
        st = tgt[:-len("_end_date")] + "_start_date"
        unit = str(r["transform"]).strip().lower()
        if unit not in ("months", "years"):
            raise SystemExit(
                f"REFUSING: `duration` transform must be `months` or `years`, "
                f"got `{r['transform']}` for {tgt}.")
        if st not in base.columns:
            raise SystemExit(
                f"REFUSING: {tgt} is derived from a duration, but `{st}` is "
                f"not mapped on {deal}. An end with no start is not a date.")

        src = None
        for sh in sheets_matching(tape, r.source_sheet):
            w = tape[tape.source_sheet == sh].pivot_table(
                index=["source_file", "source_row"], columns="cn",
                values="value", aggfunc="first").reset_index()
            c = norm(r.source_column)
            if c not in w.columns:
                continue
            for keycol, ids in (("loan_id", set(base.loan_id.dropna().astype(str))
                                 if "loan_id" in base else set()),
                                ("client_id", set(base.client_id.dropna().astype(str))
                                 if "client_id" in base else set())):
                if not ids:
                    continue
                k = join_column(w, ids)
                if k is None:
                    continue
                mp = (pd.DataFrame({"k": w[k].astype("string").str.strip(),
                                    "v": pd.to_numeric(w[c], errors="coerce")})
                      .dropna().drop_duplicates(subset=["k"])
                      .set_index("k")["v"])
                src = base[keycol].astype("string").str.strip().map(mp)
                break
            if src is not None:
                break
        if src is None:
            raise SystemExit(
                f"REFUSING: cannot reach `{r.source_column}` on sheet "
                f"`{r.source_sheet}` from {deal}'s loans -- no column on it "
                f"holds this book's loan_id or client_id.")

        start = pd.to_datetime(base[st], errors="coerce")
        off = (pd.to_timedelta(src * 365.25, unit="D") if unit == "years"
               else pd.to_timedelta(src * 30.436875, unit="D"))
        derived = (start + off).dt.date
        have = (pd.to_datetime(base[tgt], errors="coerce").notna()
                if tgt in base.columns else pd.Series(False, index=base.index))
        fill = derived.notna() & ~have & start.notna()
        if tgt not in base.columns:
            base[tgt] = pd.NA
        base.loc[fill, tgt] = derived[fill]
        basis = f"{tgt}_derived"
        if basis not in base.columns:
            base[basis] = pd.NA
        base.loc[fill, basis] = (f"derived: {st} + {r.source_column} "
                                 f"({unit})")
        decide("derived_end_date", int(fill.sum()),
               f"{tgt}: {int(fill.sum()):,} value(s) DERIVED as {st} + "
               f"`{r.source_column}` in {unit}; {int(have.sum()):,} left as "
               f"the seller stated them. Each derived row carries `{basis}`")

    # !! HOW INTRUM BOUGHT IT DECIDES WHETHER A TAPE CAN BE THE BOOK.
    #   A one-off has one completion tape covering a closed population, so a
    #   figure from it can BE the deal. A forward flow is delivered monthly
    #   under a contract - a seller sample at signing, tranches after - so a
    #   tape covering part of it is CORRECT, not missing, and a total taken
    #   from it is a total of what arrived, never of the book.
    #   Six of the thirteen are forward flows (PT15014, PT19007, PT19013,
    #   PT20006, PT20014, PT21004), and nothing in those tapes says so: the
    #   evidence is Intrum's own PAM references, whose suffixes are YYMM
    #   delivery months. It is carried per loan so a consumer cannot read a
    #   figure without it.
    # !! THIS IS INTRUM'S UNDERWRITING, NOT BROCC'S. Brocc bought every
    #   Portuguese deal in one 2025-12-01 transaction, three years after the
    #   last tranche, so prod calls them all one-off. Both are true; they
    #   answer different questions.
    _dt = str(_d.deal_type.iloc[0]) if "deal_type" in _d.columns else ""
    base["deal_type"] = _dt if _dt and _dt != "nan" else pd.NA

    # !! ONE COLUMN JOINS ALL THREE OUTPUTS, AND IT IS NOT ALWAYS THE LOAN.
    #   Written here, in payments, and in the long table, always the same
    #   value - so a consumer reads it once and knows what to join on.
    #   style.deal_grain computes it from the registry and the raw payment
    #   cells, never from which script happens to run first.
    import style as _st_g
    _grain, _gwhy = _st_g.deal_grain(deal)
    print(f"  grain: {_grain} -- {_gwhy}")
    base["grain"] = _grain

    base["deal_id"] = deal
    base["currency_id"] = "EUR"
    base["country"] = str(_d.country.iloc[0]) if "country" in _d.columns else pd.NA
    base["source"] = "asset_index"
    # ---- unique_key: a key that EXISTS for every loan ------------------
    # !! THE LONG TABLE CANNOT BE KEYED ON THE SELLER'S ID. loan_id is NULL on
    #   106 PT15018 loans that carry no account number, and on ALL 2,905 of
    #   PT20008, which is anonymised and has no identifier anywhere on its
    #   tape. Keyed on loan_id, every one of PT20008's 10,004 attribute rows
    #   was unattachable to the loan it describes - 100% of that deal's facts,
    #   silently orphaned.
    #   So the key is OURS and deterministic: a hash of the deal plus the
    #   source row this loan came from. That is not the surrogate key T19
    #   forbids - that one would have papered over a duplicate BUSINESS id.
    #   This one claims nothing about the loan; it only says "this row".
    #   It is stable while the tape is stable, and changes when the source row
    #   changes - which is exactly when an approval should go stale anyway.
    import hashlib as _hk
    if {"_src_file", "_src_sheet", "_src_row"} <= set(base.columns):
        _k = (deal + "|" + base._src_file.astype(str) + "|"
              + base._src_sheet.astype(str) + "|" + base._src_row.astype(str))
    else:
        _k = deal + "|" + base.index.astype(str)
    base["unique_key"] = [_hk.md5(x.encode()).hexdigest()[:16] for x in _k]
    if base.unique_key.duplicated().any():
        raise SystemExit(
            f"{deal}: unique_key is not unique on "
            f"{int(base.unique_key.duplicated().sum())} row(s). It is built "
            f"from the source row, so this means two output rows claim the "
            f"same one.")

    # ---- split: the fixed core, and everything else as long rows ---------
    # !! EVERY FACT SURVIVES; ONLY ITS ADDRESS CHANGES. A field that is not in
    #   the core is not dropped - it becomes rows in the long table, one per
    #   loan that actually has a value. Absence there means the tape does not
    #   carry that fact for that loan, so there are no nulls to interpret.
    # !! A MERGE SUFFIXES ITS COLLISIONS. `_src_file` met `_src_file_x` and
    #   `_src_file_y` after the enrich join, so a prefix test is the only one
    #   that holds. These are plumbing and must never reach either table.
    extra = [c for c in base.columns
             if c not in SCHEMA and c != "unique_key"
             and not c.startswith(("_src_", "_fb_"))]
    # engine-generated facts have no registry row, so their type is declared
    _typ = {"loan_id_missing_flag": "boolean", "detail_level": "text"}
    for _, r in m.iterrows():
        if r.target_field not in _typ:
            _typ[r.target_field] = column_type(r["transform"], r.target_field)
    rows = []
    for c in extra:
        v = base[c]
        keep = v.notna()
        if not keep.any():
            continue
        rows.append(pd.DataFrame({
            "deal_id": deal,
            "unique_key": base.loc[keep, "unique_key"],
            "loan_id": base.loc[keep, "loan_id"] if "loan_id" in base else pd.NA,
            # !! THE BORROWER TOO, NOT ONLY THE ACCOUNT. Several of these
            #   facts ARE person-level - PT15018's judicialised flag, its
            #   insolvency dates and its court dates all come from party
            #   sheets keyed on the client - and grouping them by person
            #   meant joining back to accounts to find out who that was.
            #   Carried for the same reason loan_id is, and with the same
            #   warning: convenience, never the join key. Both can be null
            #   and on PT20008 both always are; unique_key is the key.
            "client_id": (base.loc[keep, "client_id"]
                          if "client_id" in base else pd.NA),
            "grain": _grain,
            "column_name": c,
            "column_value": v[keep].astype(str),
            "column_type": _typ.get(c, column_type("text", c))}))
    attrs = (pd.concat(rows, ignore_index=True) if rows
             else pd.DataFrame(columns=ATTR_COLS))
    attrs = attrs[ATTR_COLS].sort_values(["unique_key", "column_name"],
                                         na_position="last")
    attrs = attrs.reset_index(drop=True)

    for c in SCHEMA:
        if c not in base:
            base[c] = pd.NA
    out = base[SCHEMA].sort_values("loan_id")
    out = out.drop(columns=[c for c in out.columns
                            if c in ("_src_sheet", "_src_file")
                            or c.startswith("_fb_")])
    import json as _mj
    _meta["loans"] = int(len(out))
    _ins = in_scope(out)
    _meta["in_scope_loans"] = int(len(_ins))
    _hf, _hv = headline(_ins, set(m.target_field))
    _meta["headline_field"] = _hf
    _meta["in_scope_balance"] = round(float(_hv.sum()), 2) if _hf else None
    # !! parents=True IS LOAD-BEARING, NOT TIDINESS. Without it the whole
    #   pipeline could not rebuild into a fresh tree: `portugal/cleaned/`
    #   exists today only because somebody created it by hand once. Deleting
    #   every derived folder and re-running - the one test that proves the
    #   folder is reproducible - failed on all twelve deals with
    #   FileNotFoundError before a single row was written.
    # !! THE CONTRACT DECLARES A TYPE; THE FILE MUST CARRY IT, EVEN EMPTY.
    #   pandas types a column from its values, so a core column that happens
    #   to be ALL NULL on one deal came out `object` while the same column on
    #   its neighbour was float64. Nothing was wrong with any value - but
    #   PT15018's cutoff_balance, the EUR 407m book's, was an object column,
    #   and on an object column of None `.sum()` answers 0 rather than null,
    #   `.mean()` raises, and a warehouse load infers VARCHAR for that file
    #   and NUMBER for the other eleven. Six core columns drifted this way.
    #   A reader of ONE deal must get what schema.yaml promises, so the cast
    #   is driven BY schema.yaml and cannot fall out of step with it.
    _CAST = {"numeric": "float64", "string": "string", "enum": "string",
             "boolean": "boolean"}
    for _c in _SCHEMA_COLS:
        _want = _CAST.get(_c.get("type"))
        if _want and _c["name"] in out.columns:
            try:
                _col = out[_c["name"]]
                if _want == "float64":
                    # an all-null object column holds pd.NA, which astype()
                    # cannot turn into a float; to_numeric maps it to NaN
                    _col = pd.to_numeric(_col, errors="raise")
                out[_c["name"]] = _col.astype(_want)
            except (TypeError, ValueError) as _e:
                raise SystemExit(
                    f"REFUSING: {deal}.{_c['name']} is declared "
                    f"`{_c['type']}` in schema.yaml but holds something that "
                    f"will not cast to {_want}: {_e}")

    OUT.mkdir(parents=True, exist_ok=True)
    out.to_parquet(OUT / f"{deal}.parquet", index=False)
    (_P.ADDITIONAL).mkdir(parents=True, exist_ok=True)
    attrs.to_parquet(_P.ADDITIONAL / f"{deal}.parquet", index=False)
    _meta["dropped_source_files"] = sorted(DROPPED_FILES)
    _meta["attribute_rows"] = int(len(attrs))
    _meta["attribute_names"] = sorted(attrs.column_name.unique().tolist())
    (OUT / f"{deal}.meta.json").write_text(_mj.dumps(_meta, indent=2) + "\n")

    ins = in_scope(out)
    _dl = attrs[attrs.column_name.eq("detail_level")].column_value
    print(f"{deal}: {len(out):,} loans  ({int(_dl.eq('full').sum()):,} full "
          f"detail, {int(_dl.eq('basic').sum()):,} basic)")
    print(f"  in scope (segment != Excluded): {len(ins):,} loans  "
          f"EUR {_meta['in_scope_balance']:,.2f}"
          + (f"  of {_hf}" if _hf and _hf != "cutoff_balance" else ""))
    _j = attrs[attrs.column_name.eq("judicialised_flag")]
    print(f"  judicialised: {len(_j):,} stated, {len(out) - len(_j):,} "
          f"not stated -- absence is NOT 'not judicialised'")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "PT15018"))
