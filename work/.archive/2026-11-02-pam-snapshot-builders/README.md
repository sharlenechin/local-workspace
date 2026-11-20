# Retired 2026-11-02: the local PAM snapshot builders

The Asset Index x PAM Snapshot is now `just summary --env dev` in asset-index-cloud
(`cli/cli/summary/`, tested in `tests/cli/test_summary.py`). It writes
`asset-index-cloud/data/<env>/summary/Asset Index x PAM Snapshot - All Countries.xlsx`.

What is here, in the order it was replaced:

- `build_pam_overlay.py` + `build_pam_snapshot.py` -- the 2026-10-26 two-step version: query
  plus overlay of the old local `asset-index-sharepoint/sorted/` into a CSV, then the CSV
  into the workbook. Three flags: In PAM / In warehouse / In Asset Index.
- `summarise_sorted.py` + `held_deals.sql` -- the same morning's one-step version
  (`mise run summary`), reading asset-index-cloud's `sorted/`, xlsx only, with the two flags
  In Our Books / Have Seller Tape. Moved into asset-index-cloud the same day; its output
  matched the CLI's on every PAM column of all 2,697 deals.

Nothing reads these files; the folder is disposable.
