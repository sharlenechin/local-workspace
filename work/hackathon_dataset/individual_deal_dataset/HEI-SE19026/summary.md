# HEI-SE19026

Measured 2026-11-24 from live queries: accounts.sql and payments_pre_registration.sql on prod, payments_post_registration.sql on the sandbox build, summary/summary_sources.sql on prod.

## Overview

|  |  |
|---|---|
| Cases we own (warehouse) | 10,065 |
| Loans we own | 9,574 |
| Cases bridged to the Asset Index | **96.9995%** (9,763) |
| Warehouse payments vs Intrum's report (PAM): sandbox build with both fixes, used in this dataset | **97.2124%** of PAM, payments in 100% of PAM's months; reconciles: **Yes** |
| Same on prod today, for comparison (both bugs, against PAM's portfolio snapshot) | 91.3831% of PAM |
| Rows in accounts / payments | 794,642 / 176,201 |

Reconciles means the warehouse total is within 10% of PAM's and has payments in at least 80% of PAM's months, from purchase (2019-12 to 2026-10).

## How the Asset Index bridges to the cases we own

| Way | Cases | % of 10,065 owned | How |
|---|---|---|---|
| via case bk | 9,292 | 92.3199% | the Asset Index case id equals the warehouse case id (DIM_CASE.CASE_BK) |
| via moved loan link | 471 | 4.67958% | old 1062 case of a moved loan whose new 2080 case is in the Asset Index |
| via payment history | 0 | 0% | not tried on this deal; moved loans are paired on principal only, see bridge_check/. |
| **bridged** | **9,763** | **96.9995%** |  |
| not bridged | 302 | 3.0005% |  |

Asset Index rows not matched to any case we own: 17.

Loans in the Asset Index: 9,292 of 9,574 (97.0545%).

## Payments since purchase (2019-12 to 2026-10, SEK)

| Source | Paid | vs portfolio snapshot | Months with payments | Cases with payments | What it is |
|---|---|---|---|---|---|
| npl common portfolio snapshot | 145,389,472.47 |  | 83 |  | whole deal; FCT_PORTFOLIO_SNAPSHOT_MONTHLY.GROSS_CASH_RECOVERIES, built from PAM |
| npl common case collection | 132,861,380.57 | -8.61692% | 83 | 5,923 | whole deal; FCT_CASE_COLLECTION, built from CAT |
| asset index | 142,644,837.94 | -1.88778% | 83 | 6,556 | Asset Index (seller tapes); asset_index.approved.payments |

vs portfolio snapshot is how far the source's total is above (+) or below (-) the portfolio snapshot's, which is built from Intrum's own monthly report (PAM).

## Monthly payments: Asset Index vs warehouse (sandbox build)

Counted over loan-months where either source has a payment; matched = equal to the öre.

| Intrum system | Loan-months | Matched | Matched % |
|---|---|---|---|
| 1062 | 3,921 | 2,968 | 75.695% |
| 2080 | 80,957 | 56,387 | 69.6506% |
| **all** | **84,878** | **59,355** | **69.9298%** |

## Ownership

10,065 cases (1,353 on 1062, 8,712 on 2080). A moved loan has two cases, so cases_owned = loans_owned + loans_moved. 11 more old cases closed on a move but had no partner with equal principal, so they count as loans of their own.

## Dataset rows

| Source in payments | Rows | Amount (SEK) |
|---|---|---|
| asset index | 13,627 | 21,373,412.56 |
| warehouse | 162,574 | 141,824,644.67 |
