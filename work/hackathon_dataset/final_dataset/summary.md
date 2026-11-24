# Final dataset: all hackathon deals

Measured 2026-11-24 from live queries: each deal's accounts.sql and payments_pre_registration.sql on prod, payments_post_registration.sql on the sandbox build DEV.HACKATHON (connection dev). Amounts in SEK.

## Overview

| Deal | Loans | Loans in the Asset Index | Warehouse vs PAM | Months with payments | Reconciles |
|---|---:|---:|---:|---:|---|
| HEI-SE17039 | 2,095 | 2,085 (99.5227%) | **93.9415%** (2018-12 to 2026-10) | 100% | **Yes** |
| HEI-SE20009 | 15,514 | 13,587 (87.579%) | **97.8167%** (2020-07 to 2026-10) | 100% | **Yes** |

Warehouse vs PAM is the warehouse's total as a share of Intrum's monthly report (PAM), from purchase to PAM's last complete month. A deal reconciles when that is within 10% and the warehouse has payments in at least 80% of PAM's months.

## Payments by month

![Payments by month, one row per deal](payments_by_month.png)

Bars are the Asset Index (seller tape) payments before each loan's registration month; lines are from the registration month on. The dashed line is the registration date of most loans (the month most registered).

Why HEI-SE17039 has warehouse payments before its registration date: Intrum was already collecting these loans for the seller before we bought the deal, and each loan registered with Intrum when it went to collection, from 2008 to 2018. Only 448 of the 2,095 loans registered in Dec 2018, the purchase month. Each loan switches from Asset Index to warehouse in its own registration month, so before 2019 the bars are loans not yet with Intrum and the line is loans already with Intrum: different loans, never the same payment twice. The current month is left out of the lines.

## Rows and totals

17,609 loans; 1,482,894 rows in accounts, 423,604 in payments (output/, .csv and .parquet).

| Deal | Source | Rows | Amount (SEK) |
|---|---|---:|---:|
| HEI-SE17039 | Asset Index, before registration month | 37,367 | 73,912,830.53 |
| HEI-SE17039 | warehouse, from registration month | 97,511 | 159,307,063.04 |
| HEI-SE20009 | Asset Index, before registration month | 32,160 | 45,164,322.52 |
| HEI-SE20009 | warehouse, from registration month | 256,566 | 280,663,029.73 |
| **All deals** | Asset Index, before registration month | 69,527 | 119,077,153.05 |
| **All deals** | warehouse, from registration month | 354,077 | 439,970,092.77 |
