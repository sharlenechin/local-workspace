# HEI-SE17039

Measured 2026-11-24 from live queries: accounts.sql and payments_pre_registration.sql on prod, payments_post_registration.sql on the sandbox build, summary/summary_sources.sql on prod.

## Overview

|  |  |
|---|---|
| Cases we own (warehouse) | 2,702 |
| Loans we own | 2,095 |
| Cases bridged to the seller's tape | **99.6299%** (2,692) |
| Warehouse payments vs Intrum's report (PAM): sandbox build with both fixes, used in this dataset | **93.9415%** of PAM, payments in 100% of PAM's months; reconciles: **Yes** |
| Same on prod today, for comparison (both bugs, against PAM's portfolio snapshot) | 48.447% of PAM |
| Rows in accounts / payments | 226,260 / 134,878 |

Reconciles means the warehouse total is within 10% of PAM's and has payments in at least 80% of PAM's months, from purchase (2018-12 to 2026-10).

## How the seller's tape bridges to the cases we own

| Way | Cases | % of 2,702 owned | How |
|---|---|---|---|
| via case bk | 2,085 | 77.1651% | the tape's case id equals the warehouse case id (DIM_CASE.CASE_BK) |
| via moved loan link | 607 | 22.4648% | old 1062 case of a moved loan whose new 2080 case is on the tape |
| via payment history | 0 | 0% | not used in the queries. Matching leftover cases on months with equal payments found 1 possible pair, too weak to use; see bridge_check/. |
| **bridged** | **2,692** | **99.6299%** |  |
| not bridged | 10 | 0.3701% |  |

Tape rows not matched to any case we own: 420.

Loans with a tape row: 2,085 of 2,095 (99.5227%).

## Payments since purchase (2018-12 to 2026-10, SEK)

| Source | Paid | vs portfolio snapshot | Months with payments | Cases with payments | What it is |
|---|---|---|---|---|---|
| npl common portfolio snapshot | 141,558,830.74 |  | 95 |  | whole deal; FCT_PORTFOLIO_SNAPSHOT_MONTHLY.GROSS_CASH_RECOVERIES, built from PAM |
| npl common case collection | 68,580,992.07 | -51.553% | 95 | 785 | whole deal; FCT_CASE_COLLECTION, built from CAT |
| asset index | 137,241,748.89 | -3.04967% | 95 | 1,679 | loans on Intrum's benchmark file only; asset_index.approved.payments |

vs portfolio snapshot is how far the source's total is above (+) or below (-) the portfolio snapshot's, which is built from Intrum's own monthly report (PAM).

## Monthly payments: tape vs warehouse (sandbox build)

Counted over loan-months where either source has a payment; matched = equal to the öre.

| Intrum system | Loan-months | Matched | Matched % |
|---|---|---|---|
| 1062 | 15,251 | 11,752 | 77.0572% |
| 2080 | 34,679 | 23,999 | 69.2033% |
| **all** | **49,930** | **35,751** | **71.6022%** |

## Ownership

2,702 cases (1,640 on 1062, 1,062 on 2080). A moved loan has two cases, so cases_owned = loans_owned + loans_moved.

## Dataset rows

| Source in payments | Rows | Amount (SEK) |
|---|---|---|
| asset index | 37,367 | 73,912,830.53 |
| warehouse | 97,511 | 159,307,063.04 |
