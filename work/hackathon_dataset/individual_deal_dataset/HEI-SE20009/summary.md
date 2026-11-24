# HEI-SE20009

Measured 2026-11-24 from live queries: accounts.sql and payments_pre_registration.sql on prod, payments_post_registration.sql on the sandbox build, summary/summary_sources.sql on prod.

## Overview

|  |  |
|---|---|
| Cases we own (warehouse) | 15,514 |
| Cases bridged to the Asset Index | **87.579%** (13,587) |
| Warehouse payments vs Intrum's report (PAM): sandbox build with both fixes, used in this dataset | **97.8167%** of PAM, payments in 100% of PAM's months; reconciles: **Yes** |
| Same on prod today, for comparison (both bugs, against PAM's portfolio snapshot) | 97.6268% of PAM |
| Rows in accounts / payments | 1,256,634 / 288,726 |

Reconciles means the warehouse total is within 10% of PAM's and has payments in at least 80% of PAM's months, from purchase (2020-07 to 2026-10).

## How the Asset Index bridges to the cases we own

| Way | Cases | % of 15,514 owned | How |
|---|---|---|---|
| same id | 10,755 | 69.3245% | the Asset Index case id equals the warehouse case id (DIM_CASE.CASE_BK) |
| borrower and balance | 2,832 | 18.2545% | same borrower birth year and gender, then points for equal principal, other balances, interest and verdict month; see MATCHING in accounts.sql. Picked the right case 99.815% of the time in a blind test on the same_id cases. |
| via payment history | 0 | 0% | not possible: the Asset Index payments end in May 2020 and the first case registered in July 2020, so no month is in both. |
| via moved loan link | 0 | 0% | not needed: no loan on this deal moved between Intrum's systems. |
| **bridged** | **13,587** | **87.579%** |  |
| not bridged | 1,927 | 12.421% | needs Intrum's mapping from the Asset Index SE_A/SE_C ids to their case numbers |

Asset Index rows not matched to any case we own: 2,414.

## Payments since purchase (2020-07 to 2026-10, SEK)

| Source | Paid | vs portfolio snapshot | Months with payments | Cases with payments | What it is |
|---|---|---|---|---|---|
| npl common portfolio snapshot | 286,382,971.75 |  | 76 |  | whole deal; FCT_PORTFOLIO_SNAPSHOT_MONTHLY.GROSS_CASH_RECOVERIES, built from PAM |
| npl common case collection | 279,586,566.09 | -2.37319% | 76 | 10,078 | whole deal; FCT_CASE_COLLECTION, built from CAT |
| asset index | 0.00 |  | 0 | 0 | Asset Index (seller tapes); its payments end in May 2020, before purchase |

vs portfolio snapshot is how far the source's total is above (+) or below (-) the portfolio snapshot's, which is built from Intrum's own monthly report (PAM).

## Payments before registration

The seller's payment history on the tapes, for cases we own and matched: SEK 45,164,322.52 on 4,569 cases, 2008-08-12 to 2020-05-23.

## Ownership

15,514 cases (15,514 on 2080). Every case is on Intrum's system 2080 and none moved system, so a case is a loan.

## Dataset rows

| Source in payments | Rows | Amount (SEK) |
|---|---|---|
| asset index | 32,160 | 45,164,322.52 |
| warehouse | 256,566 | 280,663,029.73 |
