# Bridge: LOK-SE25013

How this deal's tapes join Intrum's cases in CAT, measured by deal-bridge on the tapes before the PII strip.

CAT holds the deal as SE25037, on instances 2080 (1,584 cases), 1062 (611 cases).

## The bridge

`LoanNumber` in `OffShoreIIDataSet7 2025-05-13 Loans SEK Komplettering flagga skulder att exkludera.xlsx`, sheet `CaseDataMain` is CAT's `invoices.invoice_number`, for 2,186 of 2,195 cases; 53.7% of the column's values are CAT's.
By instance: 2080 1,583 of 1,584; 1062 603 of 611.
One row per value on the tape.

## Other columns that met CAT

- `LoanNumber` in `OffShoreIIDataSet7 2025-05-13 Loans SEK Komplettering flagga skulder att exkludera.xlsx`, sheet `CaseDataMain` met `client_ref_1`: 8.74% of its values, 361 of 2,195 cases (weak).
- `CaseId` in `OffShoreIIDataSet7 2025-05-13 Loans SEK Komplettering flagga skulder att exkludera.xlsx`, sheet `CaseDataComparison` met `case_id`: 0.13% of its values, 8 of 2,195 cases (weak).
- `SecondaryDebtId` in `OffShoreIIDataSet7 2025-05-13 Loans SEK Komplettering flagga skulder att exkludera.xlsx`, sheet `CaseDataMain` met `main_debtor`: 0.08% of its values, 3 of 2,195 cases (weak).
- Amount `registration_balance` in `SE26043_SE26044_NOBA_BMK_accounts_v2.csv` met `remaining_capital`: 97.29% of its values, 2,154 of 2,195 cases, one to one on 93.66% of rows.
- Amount `registration_balance` in `SE26043_SE26044_NOBA_BMK_accounts_v2.csv` met `original_capital`: 87.79% of its values, 1,945 of 2,195 cases, one to one on 84.47% of rows.
