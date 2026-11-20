# Project mBank — benchmark extract

The extra benchmark requested in the mBank spec: accounts, payments and legal events for
mBank's Polish books serviced by Intrum, in the pipeline's column names. Built 2026-11-05.

| Files (in `output/`) | Books | Built from |
|---|---|---|
| `mbank_2023_accounts / _payments / _legal_events.csv` | PL23003 | mBank's tape (`mBank_2023.xlsx`) as the base; Intrum's case feed (CAT) adds the legal events and payment source |
| `mbank_2019_2021_accounts / _payments / _legal_events.csv` | PL19009, PL19017, PL20015, PL20020, PL21024 | CAT alone: no tape exists for these |
| `reconciliation.csv` | all | every check: what was compared, the figure, what was expected, pass/fail |

Amounts are EUR at **0.228885 EUR per PLN** (the tape's own rate; it is the 30 Sep 2026
rate, not the purchase-date one). Every row carries `rate_to_eur`, and payments also carry
`payment_amount_pln`. Ratios such as liquidation do not depend on the rate.

## Rebuild

From `local-workspace`, run each query in `queries/` with `--csv work/project-mbank/.cache/<name>.csv`
(00 to 05; about 15 minutes in all, 02 is the slowest), then:

```
uv run python work/project-mbank/build_extract.py
```

## Where each column comes from

| Column | PL23003 | Older books |
|---|---|---|
| `model_id` | `<portfolio>_<Intrum case id>`. The tape's `L_BMK_` prefix stripped = the case id (8,772 of 8,772 join) | same |
| `registration_date` | tape (= CAT on 100%) | CAT |
| `extraction_date` | newest CAT record, 2026-11-01 | same |
| `default_date` | tape | CAT. ⚠ **Not the same definition**: on PL23003 CAT's date is a median **123 days earlier** than mBank's (equal on 4%). Debt age on the older books reads ~4 months older |
| `registration_balance` | tape, one figure | CAT principal + interest at registration |
| `principal_balance` | CAT capital (= PAM to the zloty) | CAT capital |
| `interest_balance`, `fees_balance` | blank: the tape does not split its balance (it carries 1.6m PLN, 0.87%, more than principal) | interest from CAT; fees not sent |
| `product_type` | tape | **blank**: no CAT table on this instance carries it |
| `customer_type` | tape | CAT debtors: private only = B2C, company only or legal type 3/4 = Corpo, both = SME. Matches the tape on **99.93%** of PL23003 |
| `collection_stage`, `collection_status` | tape (`Healthly` corrected to `Healthy`) | **blank**: CAT holds no stage or status at purchase (every case reads the default) |
| `has_title` | from the tape's stage (In-/Ex-Bailiff) | **proxy**: the first legal step Intrum took was the bailiff, with no lawsuit before it. On PL23003 it is right 95.6% of the time and finds 88.4% of titled accounts |
| `origination_date`, `original_amount` | blank: not sent | blank |

`*_source` columns on each row say which rule filled the field.

**Payments**
- `payment_origin` says where each row came from:
  - `bmk_file` / `bmk_file_seller_history`: mBank's tape, monthly, dated the 1st;
  - `intrum_cat`: actual dates;
  - `intrum_cat_seller_history`: the seller's pre-purchase payments, which Intrum's feed holds as `PAY HIST`.
- ⚠ The tape's pre-purchase rows are dated the 1st of the **following** month, so they are moved back one month. That makes 98.66% of case-months equal CAT's history to the zloty, against 24% unmoved.
- Pre-purchase is cut to the 12 months before registration. PL20015 and PL21024 have none.
- `payment_source` is **derived**: what the case was in on the payment date, from the events. The priority is Insolvency > Estate > Re-enforcement > Bailiff > Settlement > Amicable. It is blank before purchase.

**Legal events**
- Letters A, V, Z, B are Intrum's legal steps. Their outcomes (VERDICT, CLAUSE, WOFF, RETURN…) are what confirm the reading.

| event_type | Rule |
|---|---|
| `lawsuit_filed` | step A start |
| `title_obtained` | step V with outcome VERDICT |
| `enforcement_clause_granted` | **added**: step Z with outcome CLAUSE, the enforceability clause. Kept separate so title is not double-counted |
| `bailiff_started` | every step B, one row per round |
| `bailiff_discontinued` | step B with outcome WOFF or RETURN |
| `insolvency_declared` | BANKRUPTCY_RECORD open date |
| `death_recorded` | the date Intrum's feed first shows the debtor deceased: when it was **recorded**, not the date of death |
| `settlement_agreed` | each instalment plan's start |
| `account_closed` | CAT closing date. The reason is the decoded status and closing code |

- `balance_at_event` is blank.
- A bailiff step agrees with Intrum's separate enforcement files on 97.9% of cases.

## What reconciles, and what does not (as of 2026-11-05)

**Solid**
- **Accounts:** principal matches Intrum's PAM report within 0.22% on every book, and to the zloty on three. Account counts match within 0.1% on four books.
- **PL23003 payments:** post-purchase 100.08% of PAM. Case by case they equal CAT on 94.1% of case-months.

**Shaky, and why**
- **PL23003's account count is 8,772 against PAM's 9,944.** The money agrees exactly, so PAM is counting something other than accounts. Open.
- **PL20015: 160 cases against PAM's 148.** It is also a corporate book (118 Corpo and 42 SME, with a median balance of €115k). PL21024 is similar: 19 cases with a median of €79k. Neither looks like PL23003's consumer book, so match them separately or leave them out.
- **The older books' collections read high in their first years.** PL20020 is 152% of PAM in 2020; PL19017 is 105–113% through 2023. All are within 2.5% from 2024. This is the same early-year pattern seen on the Swedish books, and it looks like Intrum's reporting rather than the query. Quote cash from 2024 on. A lifetime curve on these books is inflated by 3–7%.
- **PL20015's 2025 reads 0.22 of PAM.** PAM has cash that CAT does not. Open.
- 43 older accounts have no customer type, and 18 older payment rows net negative after rebookings.

## Still needed from Intrum to finish Table 1 for the older books

1. Product type.
2. Stage and status at purchase.
3. Whether a title was held at purchase.
4. mBank's termination date (the default date).
5. The interest/fees split.

These are what the spec asks for; CAT on instance 2020 does not carry them.
