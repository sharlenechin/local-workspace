# Live workbook baseline — captured 2026-10-07, before any change

Read from Sigma through the connector. **This is the revert point for element
formulas.** If a change goes wrong, the formulas below are what was there.

| | |
|---|---|
| Workbook | Servicing Dashboard |
| Workbook ID | `65a9392f-8dcd-4723-83e8-bc01b6d6eab7` — renamed "Servicing Dashboard (retired 2026-10-08)" on 2026-10-08 |
| URL | https://app.sigmacomputing.com/brocc/workbook/Servicing-Dashboard-35PyJTGEJoomrtfdJmBmx9 |
| Elements | 7 |

## ⚠ What this baseline does NOT cover

**The Custom SQL behind `Portfolios` is not here, and cannot be read through the
connector.** Every column below shows as `[Custom SQL/NAME]` — the connector
returns the column's *reference*, not the query text. That query exists only
inside Sigma and is version-controlled nowhere.

**Before anyone edits `Portfolios`, copy its SQL out of Sigma into
`work/servicing/.before/ROIia0oTOr.sql`.** Without it a bad edit is
unrecoverable, and no amount of element metadata replaces it.

The same applies to filter defaults, formats and layout — none are readable
here. For those, copy the workbook YAML out of Sigma's code view to
`.before.yaml` first.

## Element IDs

| Element | ID | Type |
|---|---|---|
| Portfolios | `ROIia0oTOr` | level table (the one source) |
| Average Collections L3M | `aOgyTXDgrO` | kpi |
| Average Collections L6M | `gZCOrKu-jX` | kpi |
| Average Collections L12M | `U-2bJd2aV6` | kpi |
| Total Collections | `-w_fBO0GV9` | kpi |
| Country by Remaining Balance | `fK86nWD1U7` | region |
| Breakdown | `yIRjyUx0iT` | pivotTable |

## `Portfolios` — calculated columns, verbatim

```
SJbZLBdAON  [M] Total Collections                  Sum([Collections Sum])
aXPilExsnz  [M] Average Collections L3M            Sum([Collections L 3 M Sum]) / 3
xeDRLFXAHa  [M] Average Collections L6M            Sum([Collections L 6 M Sum]) / 6
9M_mD-7uwU  [M] Average Collections L12M           Sum([Collections L 12 M Sum]) / 12
-TX6nZmkT0  [M] Average Collections per Case       Sum([Collections Sum]) / Sum([Paying Loans Count])
aK-3mO1TPs  [M] Total Paying Cases                 Sum([Paying Loans Count])
tdg4G01vJ8  [M] Total Ever Paying Cases            Sum([Payment Loans Ever Paid Count])
OCmPCBiPXl  [M] Total Paying Cases Consistent 3M   Sum([Paying Loans Consistent 3 M Count])
tJHhYNgbun  [M] Total Paying Cases Lost            Sum([Payment Loans Lost Count])
Szy9tLumQM  [M] Total Paying Cases New             Sum([Payment Loans New Count])
z4ktTkD2_c  [M] Total Paying Cases Newly Activated (Sum(Coalesce([Payment Loans Ever Paid Count], 0))
                                                    - Sum(If([Reporting Month] = [First Reporting Month],
                                                      Coalesce([Payment Loans Ever Paid Count], 1), 1)))
                                                   / Sum(If([Reporting Month] = [First Reporting Month],
                                                      Coalesce([Payment Loans Ever Paid Count], 1), 1))
t3Mxur1KtZ  [F] Is Current Month Flag              If([Reporting Month] = Max([Snapshot Date]), True, False)
UoYONOn8RE  [M] Average Forecast L3M               Sum([Servicer Forecast L 3 M Sum] / 3)
mR52rGPBCF  [M] Total Forecast Collections         Sum([Servicer Forecast Sum])
WkzkO7EPJS  [M] Average Forecast L6M               Sum([Servicer Forecast L 6 M Sum]) / 6
PVDGyvvrw4  [M] Average Forecast L12M              Sum([Servicer Forecast L 12 M Sum]) / 12
I8JkE70sqk  First Reporting Month                  Min([Reporting Month])
```

## The KPI and chart elements

```
aOgyTXDgrO  zBr9b8_yLL  Month of Reporting Month   DateTrunc("month", [Reporting Month])
            G9FeIMkBtf  Sum of [M] Avg Coll L3M    Sum([[M] Average Collections L3M])
            6x-wwJdA88  Average Forecast L3M       [[M] Average Forecast L3M]

gZCOrKu-jX  8cJMKF-XNw  Month of Reporting Month   DateTrunc("month", [Reporting Month])
            GQ62exaT2y  Sum of [M] Avg Coll L6M    Sum([[M] Average Collections L6M])
            RccywXprHI  Sum of [M] Avg Fcst L6M    Sum([[M] Average Forecast L6M])

U-2bJd2aV6  5-Dvq4Nh-p  Month of Reporting Month   DateTrunc("month", [Reporting Month])
            7IKSfX5w1a  Sum of [M] Avg Coll L12M   Sum([[M] Average Collections L12M])
            11u9ynL31o  Sum of [M] Avg Fcst L12M   Sum([[M] Average Forecast L12M])

-w_fBO0GV9  6g3ceshGBK  Month of Reporting Month   DateTrunc("MONTH", [Reporting Month])
            Xef3pggQSR-…  Sum of [M] Total Coll    Sum([[M] Total Collections])
            g-SSwgAhgS  Sum of [M] Total Forecast  Sum([[M] Total Forecast Collections])

fK86nWD1U7  QYNSv1SqCF  Country Name               [Portfolios/Country Name]
            ppOi987VB_  Balance / Capex            Sum([Collections Sum])      <-- see defect 1

yIRjyUx0iT  Breakdown pivot: rows Project -> Vehicle, six case measures at
            Grand Total / Project / Vehicle level. Column ids are structural
            (st-<measure>-<row>), so they regenerate if the pivot is rebuilt.
```

## Defects visible in this baseline

**1. `Country by Remaining Balance` does not plot balance.** Its only measure,
labelled **"Balance / Capex"**, has the formula `Sum([Collections Sum])`. The
map is showing **collections**, under a title and a column name that both say
balance. Either the title is wrong or the formula is — and nobody reading the
tile can tell. **New, not previously recorded.**

**2. The rolling averages divide by a constant.** `aXPilExsnz` divides by 3,
`xeDRLFXAHa` by 6, `9M_mD-7uwU` by 12 — while `MONTHS_IN_L3M_WINDOW`,
`_L6M_` and `_L12M_` exist in the source for exactly this reason. 26.5% of
portfolio-months have a short window and read low by up to 3x.

**3. `[M] Total Paying Cases Newly Activated` is a ratio named as a count.**
The formula is `(A - B) / B`, a growth rate, formatted as an integer in the
pivot. `PAYING_LOANS_ACTIVATED_COUNT` already holds the count the name promises.

**4. `UoYONOn8RE` divides inside the Sum**, `Sum([… L 3 M Sum] / 3)`, where its
three siblings divide outside. Same result for a constant divisor, but it will
diverge the moment anyone switches to dividing by months present.

**5. The source columns are the pre-rename vocabulary** — `PAYING_LOANS_COUNT`,
`PAYMENT_LOANS_LOST_COUNT`, `CAT_MONTH_COVERAGE_PCT`, `LOANS_ON_BOOK_COUNT`.
The mart now calls these `collected_cases_*` and `cases_on_book_count`, so every
formula above has to be remapped when the dashboard moves onto the new elements.
