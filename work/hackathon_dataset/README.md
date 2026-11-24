# Hackathon: Swedish deals, loan by loan

Everything for the hackathon is in this folder. Each folder has one job, and nothing is kept in two places.

| Folder | What it's for | Start with |
|---|---|---|
| `individual_deal_dataset/` | One folder per deal (HEI-SE17039, HEI-SE19026, HEI-SE20009, LOK-SE25008): `accounts.sql` and `payments_pre_registration.sql` on prod, `payments_post_registration.sql` on the sandbox build with both collection fixes; `deal_dataset.py` puts the three together | `<deal>/summary.md` |
| `final_dataset/` | Every deal from `deal_dataset.py`, stacked into one accounts and one payments dataset (`output/`, .csv and .parquet) | `summary.md` (with the payments chart), then `final_dataset.py` |
| `bug_fixes_impact/` | What the two collection fixes change, prod against the sandbox build, and why each Swedish deal does or doesn't reconcile, by market and deal type (`deal_reasons.sql`, `reasons_by_market.py`) | `RESULTS.md` |
| `intrum_clarifications/` | Which Swedish deals reconcile with Intrum's monthly report, and the questions for Intrum | `README.md` |
| `asset_index_sharepoint/` | The seller tapes (`sorted/`, never committed: they hold personal data) and the tape-to-CAT bridge notes (`bridge/`) | `bridge/<deal>/bridge.md` |

Every deal's queries return the same columns in the same order, and the two payment queries share one column
list, so payments stack before and after registration and deals stack with each other. A new deal should
copy the final `SELECT`s from an existing one and be added to `DEALS` in `final_dataset/final_dataset.py`.

Payments switch from the Asset Index to the warehouse in each loan's registration month with Intrum, with one
exception: LOK-SE25008 switches at Intrum's acquisition month (Jun 2025). Its tape is Intrum's own collection
history from before the purchase, so splitting by registration would have thrown nearly all of it away.
