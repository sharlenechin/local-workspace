"""Where everything lives. ONE definition, imported by every script.

!! TWELVE SCRIPTS USED TO COMPUTE THIS INDEPENDENTLY, and not consistently:
   some spelled `.../data`, some `.../data/tapes`, and both were called
   `TAPES`. Adding the roll-forward guard meant writing
   `TAPES / f"{deal}.parquet"` in a module where TAPES was the data folder -
   a FileNotFoundError that only appeared because that guard happened to run.
   A path repeated twelve times is twelve chances to mean something slightly
   different.

!! ONE FOLDER IS WRITTEN BY HAND AND EVERYTHING ELSE IS DERIVED.
   `<country>/raw/assets/` is the drop zone: whatever shape it arrives in,
   it goes there and nothing ever modifies it. `processed/` and `tapes/`
   are both rebuilt from it, and `cleaned/` is rebuilt from those. Delete
   any of the three and one command puts it back; delete assets/ and the
   data is gone. That line is the whole reason the folders are named the
   way they are.
"""
import re
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent      # pre-registration-benchmark
WORK = BASE.parents[1]                             # work/

# ---- what is SHARED across every country ----------------------------------
# !! THE ENGINE AND THE CONTRACT ARE NOT PORTUGUESE. No script carries a
#   country, and the fixed core of the schema is the whole point of having a
#   core - a Spanish loan and a Portuguese loan must be the same 20 columns or
#   nothing downstream can compare two books. Country quirks go in the long
#   table, not in a second contract.
SCHEMA = BASE / "schema.yaml"
TRAPS = BASE / "traps.yaml"
# !! THE SPLIT MUST NOT HIDE HALF THE LEDGER. traps.yaml is tape traps and
#   engine-lessons.yaml is our own pipeline (2026-10-13). promote.py and the
#   YAML case read BOTH - a lesson that stopped being promoted or validated
#   because it moved file would make the split a loss, not a tidy-up.
LESSONS = BASE / "engine-lessons.yaml"
TRAP_FILES = (TRAPS, LESSONS)

# ---- what is PER COUNTRY ---------------------------------------------------
# !! DERIVED FROM THE DEAL CODE, NOT CONFIGURED. A setting that says which
#   country we are working on is a setting that will be wrong one day, and
#   wrong silently - cleaning a Spanish tape into the Portuguese folder. The
#   deal code already says it: PT15018 is Portuguese because it begins PT.
COUNTRY_OF = {"PT": "portugal", "ES": "spain", "IT": "italy",
              "GE": "germany", "GR": "greece", "IE": "ireland"}
DEFAULT_COUNTRY = "portugal"


# !! THE DEAL PATTERN IS BUILT FROM COUNTRY_OF, NOT TYPED OUT. intake,
#   check_new_data and load_tapes each carried their own `re.compile(
#   r"(PT\d{5})")`. Adding Spain to COUNTRY_OF would have registered the
#   country everywhere EXCEPT at the door, and every Spanish file would have
#   been reported as carrying no deal code - a silent failure that looks
#   exactly like a bad delivery.
DEAL_RE = re.compile(r"((?:" + "|".join(sorted(COUNTRY_OF)) + r")\d{5})")


def country_of(deal):
    """Folder name for a deal code. Refuses a prefix it does not know."""
    pre = str(deal)[:2].upper()
    if pre not in COUNTRY_OF:
        raise SystemExit(
            f"{deal}: no country is registered for the prefix `{pre}`. Add it "
            f"to COUNTRY_OF in scripts/paths.py - that is the ONLY place a "
            f"country is named.")
    return COUNTRY_OF[pre]


def for_deal(deal):
    """Every per-country path for one deal, as a small namespace."""
    c = BASE / country_of(deal)
    return type("P", (), {
        "COUNTRY": c,
        # raw/ holds three folders and each one has a single job:
        # raw/ holds TWO things, and one of them is yours:
        #   assets/     YOU drop deliveries here, in whatever shape they
        #               arrive. Nothing in this pipeline writes to it,
        #               renames inside it, or deletes from it. It is the
        #               archive of what we were sent and the only folder
        #               anybody edits by hand.
        #   processed/  everything derived from assets/, and nothing else.
        #     files/      the same workbooks, copied and filed by deal.
        #                 What a person opens.
        #     tables/     the same CONTENT, parsed to one parquet per deal,
        #                 one row per cell. What every script reads, because
        #                 re-reading 180 workbooks takes two minutes and
        #                 this takes milliseconds. A parse cache, not a
        #                 second copy of the files.
        #   Delete processed/ entirely and two commands rebuild it. Delete
        #   assets/ and the data is gone. That asymmetry is the design.
        "RAW": c / "raw",
        "ASSETS": c / "raw" / "assets",
        "PROCESSED": c / "raw" / "processed" / "files",
        "TAPES": c / "raw" / "processed" / "tables",
        "PAYMENTS_RAW": c / "raw" / "processed" / "tables" / "payments.parquet",
        "MANIFEST": c / "raw" / "processed" / "tables" / "manifest.parquet",
        "EXCLUDED": c / "excluded.yaml",
        "BRIDGE_SQL": c / "bridge.sql",
        "BRIDGE": c / "raw" / "processed" / "tables" / "bridge.parquet",
        "LOADER": BASE / "scripts" / "load_tapes.py",
        "ACCOUNTS": c / "cleaned" / "accounts",
        "ADDITIONAL": c / "cleaned" / "additional_attributes",
        "PAYMENTS": c / "cleaned" / "payments",
        "CONTEXT": c / "cleaning-context",
        "STRATS": c / "strats", "BASELINE": c / "backtest-baseline",
        "DICTIONARIES": c / "dictionaries",
        "REGISTRY": c / "mappings.csv", "DEALS": c / "deals.csv",
    })


# The default country's paths, for the scripts that take a deal argument and
# resolve at import. Everything below is `for_deal(<any deal>)` of that
# country; a script handling a deal from elsewhere calls for_deal() itself.
_D = for_deal("PT00000")
COUNTRY = _D.COUNTRY
# !! ONE NAME FOR ONE FOLDER. `RAW_DATA` and `TAPES` used to be two
#   names for the same place, and that is precisely how
#   `TAPES / "tapes" / ...` came to be written in guards.py - it was
#   correct while TAPES meant the parent. Renaming data/ to tapes/
#   broke it instantly. The alias is gone; there is only TAPES.
RAW, TAPES = _D.RAW, _D.TAPES
ASSETS, PROCESSED, EXCLUDED = _D.ASSETS, _D.PROCESSED, _D.EXCLUDED
BRIDGE_SQL, BRIDGE = _D.BRIDGE_SQL, _D.BRIDGE
PAYMENTS_RAW, MANIFEST, LOADER = _D.PAYMENTS_RAW, _D.MANIFEST, _D.LOADER
ACCOUNTS, ADDITIONAL, PAYMENTS = _D.ACCOUNTS, _D.ADDITIONAL, _D.PAYMENTS
CONTEXT, STRATS, BASELINE = _D.CONTEXT, _D.STRATS, _D.BASELINE
DICTIONARIES = _D.DICTIONARIES
REGISTRY, DEALS = _D.REGISTRY, _D.DEALS
CLEAN = COUNTRY / "cleaned"
