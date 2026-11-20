# deal_data_coverage (retired 2026-11-03)

`deal_data_coverage.ipynb` and its query `deal_data_coverage.sql` lived in `work/workshop/`.
They answered "what we own against what we can use", one row per deal, comparing PAM, PROD
case collections and the asset index.

They were replaced by `work/workshop/data_landscape.ipynb`:

- Section C lists the deals we own.
- Section D covers the asset index (D.1 found, D.2 filled).
- Section E covers post-registration Snowflake data (E.1 raw CAT, E.2 NPL_COMMON, E.3 fill
  and the CAT-vs-PAM reconciliation).

Nothing reads these files any more. The folder is safe to delete.
