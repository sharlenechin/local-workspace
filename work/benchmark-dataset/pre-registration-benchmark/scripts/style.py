"""House style for everything this pipeline writes. Plain ASCII punctuation.

    from style import ascii_only
    path.write_text(ascii_only(text))

!! NOT COSMETIC. A curly quote breaks a grep for a word you can see on screen.
   An em dash in a CSV breaks a naive parser. A review pasted into a terminal or
   a ticket shows mojibake. A diff of two glyph-laden files is harder to read
   than the change itself.

!! THE GENERATORS MUST SANITISE, NOT JUST THE AUTHORS. Half the text in a review
   is SAMPLE VALUES READ FROM THE SELLER'S TAPE. A product description can carry
   a curly apostrophe or a non-breaking space that nobody typed. Cleaning the
   source files by hand never touches those; only cleaning at write time does.

!! THIS FILE USES ESCAPES, NOT THE CHARACTERS THEMSELVES. Written with literals
   it became the only file in the pipeline failing its own style case -- which is
   how the rule gets exempted, and then ignored.

Accented letters are KEPT. `Credito hipotecario` and `Data de Insolvencia` are
the seller's own column names; mangling them would break the registry and make
the review unreadable against the workbook. This strips PUNCTUATION and SYMBOLS,
never language.
"""
import re

SUBS = {
    "\u2014": " - ",   # em dash
    "\u2013": "-",     # en dash
    "\u2018": "'",     # left single quote
    "\u2019": "'",     # right single quote / apostrophe
    "\u201C": '"',     # left double quote
    "\u201D": '"',     # right double quote
    "\u2026": "...",   # ellipsis
    "\u00B7": "-",     # middot
    "\u2022": "-",     # bullet
    "\u2192": "->",    # right arrow
    "\u2190": "<-",    # left arrow
    "\u21D2": "=>",    # double right arrow
    "\u00A0": " ",     # non-breaking space
    "\u202F": " ",     # narrow no-break space
    "\u2009": " ",     # thin space
    "\u2212": "-",     # minus sign
    "\u26A0": "!!",    # warning sign
    "\u2705": "OK",    # white heavy check mark
    "\u274C": "FAIL",  # cross mark
    # !! BOX DRAWING AND MATH OPERATORS SLIPPED THROUGH FOR A WEEK. Neither is
    #   decorative in the emoji sense, so neither matched DROP and neither had
    #   a substitution -- and run.py drew every section rule with U+2500 while
    #   passing its own STYLE case. They mojibake in exactly the way the trap
    #   describes, which is the whole test.
    "\u2500": "-",     # box drawing horizontal
    "\u2501": "-",     # box drawing heavy horizontal
    "\u2502": "|",     # box drawing vertical
    "\u2550": "=",     # box drawing double horizontal
    "\u2260": "!=",    # not equal
    "\u2264": "<=",    # less than or equal
    "\u2265": ">=",    # greater than or equal
    "\u00D7": "x",     # multiplication sign
}
for _i, _d in enumerate("1234567890"):          # circled digits 1-10
    SUBS[chr(0x2460 + _i)] = _d + "."

DROP = re.compile(
    "[\U0001F000-\U0001FAFF"   # emoji and pictographs
    "\u2600-\u27BF"            # misc symbols and dingbats
    "\u2190-\u21FF"            # arrows block
    "\u25A0-\u25FF"            # geometric shapes
    "]")


def ascii_only(text: str) -> str:
    """Substitute what has a plain equivalent, drop what does not. Keeps accents."""
    for bad, good in SUBS.items():
        text = text.replace(bad, good)
    text = DROP.sub("", text)
    return re.sub(r"[ \t]+\n", "\n", text)      # and no trailing whitespace


def in_scope(df, col="segment", excluded="Excluded"):
    """The loans this deal actually contains.

    !! A NULL SEGMENT IS NOT AN EXCLUSION, and getting that wrong loses loans
       without a sound. On pandas 2.3 `s.ne("Excluded")` yields <NA> for a null
       cell, and boolean indexing then DROPS the row -- so a loan whose segment
       the seller simply never filled in disappears from the population, from
       the balance, and from every figure built on them. It was written that
       way in four separate files.

       Unknown means unknown. Only an EXPLICIT exclusion marker excludes.
    """
    if col not in df:
        return df
    return df[~df[col].eq(excluded).fillna(False)]


# the money fields, most-complete first. A deal's HEADLINE measure is the
# first of these it actually carries.
MONEY_ORDER = ("cutoff_balance", "cutoff_principal")


def headline(df, mapped=None):
    """(field, series) for the figure this deal is measured on.

    !! NOT ALWAYS `cutoff_balance`. That field means the WHOLE of what the
       borrower must repay, and a seller who publishes only an outstanding
       principal does not give us one - PT15018 is 32,529 loans and
       EUR 407,079,317.23 of principal with no total owed stated anywhere on
       the tape. Reading its in-scope total off `cutoff_balance` returned
       0.00, which is not "no money"; it is "wrong question".

       So the headline is `cutoff_balance` where the seller published a total,
       and `cutoff_principal` where they published only principal. Every
       script that reports "the" figure for a deal must ask here, so the
       summary, the guards and the approval sheet cannot disagree about which
       number the deal IS.
    """
    import pandas as _pd
    for f in MONEY_ORDER:
        if f not in df:
            continue
        if mapped is not None and f not in mapped:
            continue
        v = _pd.to_numeric(df[f], errors="coerce")
        if v.notna().any():
            return f, v
    return None, _pd.Series(dtype="float64")


def attributes(base, deal):
    """The long table for one deal, as a wide frame keyed by loan_id.

    !! THE FACTS DID NOT DISAPPEAR, THEY MOVED. Everything outside the fixed
       core lives in `attributes/<deal>.parquet` as one row per loan per fact.
       Readers that want a column back ask here rather than reaching into the
       accounts file for something that is no longer in it.

       A loan with no row for a fact simply has no value for it - absence is
       the only thing a missing row means, which is why there are no nulls in
       the long table to interpret.
    """
    import pandas as _pd
    # the caller passes BASE for history; the location is paths.py
    import paths as _P
    f = _P.ADDITIONAL / f"{deal}.parquet"
    if not f.exists():
        return _pd.DataFrame()
    t = _pd.read_parquet(f)
    if t.empty:
        return _pd.DataFrame()
    return t.pivot_table(index="loan_id", columns="column_name",
                         values="column_value", aggfunc="first")


def attr_series(base, deal, name, kind=None):
    """One attribute as a Series indexed by loan_id, read back to its type."""
    import pandas as _pd
    # the caller passes BASE for history; the location is paths.py
    import paths as _P
    f = _P.ADDITIONAL / f"{deal}.parquet"
    if not f.exists():
        return _pd.Series(dtype="object")
    t = _pd.read_parquet(f)
    t = t[t.column_name.eq(name)]
    if t.empty:
        return _pd.Series(dtype="object")
    kind = kind or t.column_type.iloc[0]
    v = t.set_index("loan_id").column_value
    if kind == "amount":
        return _pd.to_numeric(v, errors="coerce")
    if kind == "date":
        return _pd.to_datetime(v, errors="coerce")
    if kind == "boolean":
        return v.map({"True": True, "False": False}).astype("boolean")
    return v


def output_fingerprint(deal):
    """ONE md5 over everything an approval signs off: accounts, the long
    table, and payments.

    !! THREE PLACES USED TO DECIDE THIS AND ONLY ONE WAS RIGHT. review.py
       fingerprinted accounts alone, so a change landing only in
       additional_attributes left an approval looking valid - PT20008 was
       signed, a field was renamed under it, 1,205 attribute rows moved and
       the sheet still read APPROVED. run.py checked only the `approved`
       boolean and never compared anything at all, so it exited 0 ("sequence
       complete") on a deal whose output had moved since signing.

       A reviewer signs the MAPPINGS, and most mappings land in the long
       table. So the long table is part of what was signed, and there is now
       one definition of that, here.
    """
    import hashlib
    import paths as _P
    parts = []
    for f in (_P.ACCOUNTS / f"{deal}.parquet",
              _P.ADDITIONAL / f"{deal}.parquet",
              _P.PAYMENTS / f"{deal}.parquet"):
        if f.exists():
            parts.append(f"{f.name}:{hashlib.md5(f.read_bytes()).hexdigest()}")
    return hashlib.md5("|".join(parts).encode()).hexdigest() if parts else None


def deal_grain(deal):
    """(grain, why) -- the ONE id column that joins all three outputs.

    !! IT IS NOT ALWAYS THE LOAN, and that is the whole point of writing it
       down. accounts and additional_attributes are always per loan, so on
       their own the answer would be `loan_id` everywhere. Payments are not:
       two sellers record collections against the BORROWER, and those rows
       can never be pushed to the account (T69). So on PT15018 and PT16023
       the only column present in all three is `client_id`, and a consumer
       joining on `loan_id` gets nothing from payments at all.

    !! COMPUTED FROM THE REGISTRY AND THE RAW PAYMENT CELLS, so it does not
       depend on which script runs first. clean_accounts writes it before
       clean_payments has run; both get the same answer.

    The order is: whatever payments can key on, else the finest id the deal
    maps, else `unique_key` - which exists on every loan of every deal and
    is the only honest answer for an anonymised tape like PT20008.
    """
    import pandas as pd
    import paths as _P

    reg = pd.read_csv(_P.REGISTRY).query("deal_id == @deal")
    mapped = set(reg.target_field)

    pf = _P.PAYMENTS_RAW
    if pf.exists():
        pay = pd.read_parquet(pf)
        pay = pay[pay.deal == deal]
        if len(pay) and pd.to_numeric(pay.amount, errors="coerce").fillna(0).ne(0).any():
            acc_f = _P.ACCOUNTS / f"{deal}.parquet"
            if acc_f.exists():
                acc = pd.read_parquet(acc_f)
                best = (0, None)
                for col in pay.columns:
                    if pay[col].isna().all():
                        continue
                    vals = set(pay[col].dropna().astype(str).str.strip())
                    for field in ("loan_id", "client_id"):
                        if field not in acc or acc[field].isna().all():
                            continue
                        n = len(vals & set(acc[field].dropna()
                                           .astype(str).str.strip()))
                        if n > best[0]:
                            best = (n, field)
                if best[1]:
                    return best[1], (f"payments key on `{best[1]}` "
                                     f"({best[0]:,} values overlap), so that "
                                     f"is the only column all three share")

    for field in ("loan_id", "client_id"):
        if field in mapped:
            return field, f"`{field}` is the finest id this deal maps"
    return "unique_key", ("this tape carries no identifier at all, so the "
                           "only key is the one we make")
