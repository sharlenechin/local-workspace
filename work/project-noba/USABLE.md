# Project NOBA — what is usable

Measured 2026-11-03 against PAM, Intrum's own report. Six Swedish books, amounts SEK.
`accounts_export.sql` 62,641 loans · `payments_export.sql` 937,770 payments.

| Deal | Seller | Accounts (what we own) | Bridge found | Tape actually joins | Payments (cash) | Use it for |
|---|---|---|---|---|---|---|
| **SE19026** | Ikano | ✅ 101% of principal | 93.4% | ✅ **92.3%** | ✅ 99.3% of PAM | **everything** |
| **SE25037** | Norion | ✅ 104.2% | ids already CAT-shaped | ✅ **90.6%** | ⚠️ 87.6% — real gap | balances; cash short by 13% |
| **SE15044** | Santander | ✅ 95.4% | ids already CAT-shaped | ⚠️ **72.8%** | ⚠️ 128% — only 2020+ is sound | balances; cash from 2020 only |
| **SE16025** | Santander | ✅ 104.8% | ids already CAT-shaped | ❌ **27.9%** | ⚠️ 121% — only 2020+ is sound | balances; cash from 2020 only |
| **SE25018** | Santander | ❌ 152% of principal | **64.5%** | ❌ **0%** — ingest lost it | ✅ 102% | cash only — **not for pricing** |
| **SE20009** | Santander | ✅ 96.2% | none found | ❌ **0%** | ✅ 98.8% | **everything after purchase** |

**Bridge found** is what `_meta/bridge.yaml` says the tape *could* reach. **Tape actually
joins** is what the approved run delivers. Where they differ, the bridge was not applied
at ingest — that is SE25018, and it is a pipeline fix, not a query one.

**Why the ⚠️ and ❌**

- **SE15044 / SE16025 cash before 2020** — both run 150–180% of PAM across 2016–2018 and
  98–105% from 2020 on. It is Intrum's own reporting, not our query, so no lifetime
  recovery curve from these two. Details in `../data-issues/intrum/pam-pre-2020-swedish-books.md`.
- **SE25018 principal** — we hold 152% of the principal PAM says we bought, across 142%
  of the cases. Unexplained, and it is the number pricing divides by.
- **SE25037 cash** — we hold 87.6% of the cash PAM reports. **This is a real gap.** It
  was assumed to be forecast contamination; it is not. `reconciliation.sql` now cuts PAM
  at its own extract month and every figure came back unchanged, so `pmode_name = 'Real'`
  already excludes future months. The likeliest remaining cause is CAT feed lag on a book
  bought in Dec 2025, but that is untested. Do not quote this deal's collections.
- **SE16025 case count** — 11,836 cases against 4,831 acquired. The money is right
  (104.8%); the extra cases are near-zero fragments. Count money, not cases.
- **SE25018 seller tape** — a run WAS approved (2026-11-03, filed under our Atlas id
  SE25008, 12,160 cases) and `bridge.yaml` finds a 64.5% bridge on `Case ID (client)`.
  But the approved run stores synthetic ids, `SE_A00001` to `SE_A12160`, so nothing joins
  to a CAT case. **The run needs re-ingesting with the bridge applied** — no query change
  will recover it. Same symptom as SE20009, which also has a run and 0% coverage.
- **PAM forecast months** — `reconciliation.sql` cuts PAM at its own extract month so
  both sides are collected-to-date. Measured 2026-11-03: the cut removes nothing, on any
  of the six deals. The guard stays because it makes the basis explicit, but no figure
  here was ever inflated by forecast months.
