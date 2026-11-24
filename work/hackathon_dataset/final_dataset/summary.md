# Final dataset: all hackathon deals

Measured 2026-11-24 from live queries: each deal's accounts.sql and payments_pre_registration.sql on prod, payments_post_registration.sql on the sandbox build DEV.HACKATHON (connection dev). Amounts in SEK.

## Overview

| Deal | Loans | Loans in the Asset Index | Warehouse vs PAM | Months with payments | Reconciles |
|---|---:|---:|---:|---:|---|
| HEI-SE17039 | 2,095 | 2,085 (99.5227%) | **93.9415%** (2018-12 to 2026-10) | 100% | **Yes** |
| HEI-SE19026 | 9,574 | 9,292 (97.0545%) | **97.2124%** (2019-12 to 2026-10) | 100% | **Yes** |
| HEI-SE20009 | 15,514 | 13,587 (87.579%) | **97.8167%** (2020-07 to 2026-10) | 100% | **Yes** |
| LOK-SE25008 | 9,755 | 9,692 (99.3542%) | **97.2787%** (2025-06 to 2026-10) | 100% | **Yes** |

Warehouse vs PAM is the warehouse's total as a share of Intrum's monthly report (PAM), from purchase to PAM's last complete month. A deal reconciles when that is within 10% and the warehouse has payments in at least 80% of PAM's months.

## Payments by month

![Payments by month, one row per deal](payments_by_month.png)

Bars are the Asset Index (seller tape) payments the dataset uses: before each loan's registration month. The black line is every warehouse payment on the deal (sandbox build) at any date, so it overlays the bars wherever the warehouse has the same months; the dataset uses it only from each loan's registration month. The dashed line is the month the most loans registered with Intrum. HEI-SE20009 has no black line before Jul 2020 because the warehouse holds nothing on it before its cases registered.

**LOK-SE25008 is split at Intrum's acquisition month (Jun 2025), not by registration.** Intrum was already collecting its loans for the seller from 2016, and its tape is that collection history (it matches the warehouse to the öre on 97.9% of loan-months). Split by registration, almost all of it would have been replaced by the warehouse. So the tape is used up to the purchase and the warehouse from it, and its chart has a second dashed line at the acquisition month. Before it, the black line sits on the bars: the same payments from both sources.

Why some deals have warehouse payments before the dashed line: Intrum was already collecting part of the deal for the seller before we bought it, and each loan registered with Intrum when it went to collection. Each loan switches from Asset Index to warehouse in its own registration month, so where bars and line overlap on HEI-SE17039 they are different loans. On LOK-SE25008 they are the same payments, drawn from both sources on the chart only; the dataset never holds a payment twice. The current month is left out of the lines.

| Deal | Bought | Loans registered with Intrum before we bought | First registration |
|---|---|---:|---|
| HEI-SE17039 | Dec 2018 | 1,640 of 2,095 (78.282%) | Nov 2008 |
| HEI-SE19026 | Dec 2019 | 1,094 of 9,574 (11.427%) | Mar 2019 |
| HEI-SE20009 | Jul 2020 | 0 of 15,514 (0%) | Jul 2020 |
| LOK-SE25008 | Jun 2025 | 9,712 of 9,755 (99.559%) | Dec 2016 |

## Rows and totals

The split is each loan's registration month, except LOK-SE25008 (Intrum's acquisition month).

36,938 loans; 2,482,391 rows in accounts, 744,686 in payments (output/, .csv and .parquet).

| Deal | Source | Rows | Amount (SEK) |
|---|---|---:|---:|
| HEI-SE17039 | Asset Index, before the split | 37,367 | 73,912,830.53 |
| HEI-SE17039 | warehouse, from the split | 97,511 | 159,307,063.04 |
| HEI-SE19026 | Asset Index, before the split | 13,627 | 21,373,412.56 |
| HEI-SE19026 | warehouse, from the split | 162,574 | 141,824,644.67 |
| HEI-SE20009 | Asset Index, before the split | 32,160 | 45,164,322.52 |
| HEI-SE20009 | warehouse, from the split | 256,566 | 280,663,029.73 |
| LOK-SE25008 | Asset Index, before the split | 95,461 | 119,363,157.59 |
| LOK-SE25008 | warehouse, from the split | 49,420 | 46,387,850.37 |
| **All deals** | Asset Index, before the split | 178,615 | 259,813,723.20 |
| **All deals** | warehouse, from the split | 566,071 | 628,182,587.81 |
