# LOK-SE25008

Measured 2026-11-24 from live queries: accounts.sql and payments_pre_registration.sql on prod, payments_post_registration.sql on the sandbox build, summary/summary_sources.sql on prod.

## Overview

|  |  |
|---|---|
| Cases we own (warehouse) | 13,794 |
| Loans we own | 9,755 |
| Cases bridged to the Asset Index | **99.5433%** (13,731) |
| Warehouse payments vs Intrum's report (PAM): sandbox build with both fixes, used in this dataset | **97.2787%** of PAM, payments in 100% of PAM's months; reconciles: **Yes** |
| Same on prod today, for comparison (both bugs, against PAM's portfolio snapshot) | 7.50707% of PAM |
| Rows in accounts / payments | 204,855 / 144,881 |

Reconciles means the warehouse total is within 10% of PAM's and has payments in at least 80% of PAM's months, from purchase (2025-06 to 2026-10).

## How the Asset Index bridges to the cases we own

| Way | Cases | % of 13,794 owned | How |
|---|---|---|---|
| via case bk | 9,693 | 70.2697% | the Asset Index case id equals the warehouse case id (DIM_CASE.CASE_BK) |
| via moved loan link | 4,038 | 29.2736% | old 1062 case of a moved loan whose new 2080 case is in the Asset Index |
| via payment history | 0 | 0% | not tried on this deal; moved loans are paired on principal only, see bridge_check/. |
| **bridged** | **13,731** | **99.5433%** |  |
| not bridged | 63 | 0.45672% |  |

Asset Index rows not matched to any case we own: 2,467.

Loans in the Asset Index: 9,692 of 9,755 (99.3542%).

## Payments since purchase (2025-06 to 2026-10, SEK)

| Source | Paid | vs portfolio snapshot | Months with payments | Cases with payments | What it is |
|---|---|---|---|---|---|
| npl common portfolio snapshot | 46,777,512.67 |  | 17 |  | whole deal; FCT_PORTFOLIO_SNAPSHOT_MONTHLY.GROSS_CASH_RECOVERIES, built from PAM |
| npl common case collection | 3,511,618.92 | -92.4929% | 17 | 566 | whole deal; FCT_CASE_COLLECTION, built from CAT |
| asset index | 0.00 |  | 0 | 0 | Asset Index (seller tapes); asset_index.approved.payments |

vs portfolio snapshot is how far the source's total is above (+) or below (-) the portfolio snapshot's, which is built from Intrum's own monthly report (PAM).

## Payments before acquisition (Asset Index)

The tape's payments before Intrum's acquisition month (Jun 2025), on loans we own: SEK 119,363,157.59 on 6,019 cases, 2016-12-27 to 2025-04-28.

**This deal is split at Intrum's acquisition month, not each loan's registration month.** Intrum collected these loans for the seller from 2016, and the tape is that collection history: measured 24 Nov 2026, it equals the warehouse to the öre on 68,592 of 70,066 loan-months after registration (97.9%), and totals 96.56% of it. Split by registration, all but 46 tape payments would have been replaced by the warehouse. So the tape is used up to the purchase and the warehouse from it. A further 24,056 tape payments (about SEK 30.5m) sit on SE_A tape rows that match no loan we own, so they are not in the dataset.

## Ownership

13,794 cases (9,712 on 1062, 4,082 on 2080). A moved loan has two cases, so cases_owned = loans_owned + loans_moved. 64 more old cases closed on a move but had no partner with equal principal, so they count as loans of their own.

## Dataset rows

| Source in payments | Rows | Amount (SEK) |
|---|---|---|
| asset index | 95,461 | 119,363,157.59 |
| warehouse | 49,420 | 46,387,850.37 |
