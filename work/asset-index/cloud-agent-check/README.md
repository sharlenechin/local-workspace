# Cleaned Portuguese seller tapes - APPROVED deals only

Exported by `scripts/export_approved.py` from the pre-registration benchmark.
Every deal here has been read and signed by a human, and its signature was
re-checked against the data at export time.

## Read the ids as TEXT

    pd.read_csv("PT16023/accounts.csv", dtype=str)

Account numbers here run to 19 digits. Read without `dtype=str`, pandas makes
them floats and silently drops the last digits, so two different loans can
become the same number. Convert the amounts yourself after loading.

## The three tables, and how they join

    accounts               one row per loan, a FIXED set of columns that
                           means the same thing on every deal
    additional_attributes  everything else, long: one row per
                           (loan, column_name, column_value)
    payments               one row per payment. SIGNED - money in is
                           positive, money out is negative - so summing
                           `payment_amount` over anything gives the net

**Join on the `grain` column, not on `loan_id`.** Every table carries a
`grain` column naming the ONE id that joins all three for that deal. It is
`loan_id` on most deals and `client_id` on those whose seller records
collections against the BORROWER rather than the account. Joining those on
`loan_id` returns nothing from payments.

## What is here

| deal | table | rows | columns |
|---|---|---|---|
| PT15020 | accounts | 5,313 | 23 |
| PT15020 | additional_attributes | 15,939 | 8 |
| PT16023 | accounts | 19,434 | 23 |
| PT16023 | additional_attributes | 104,988 | 8 |
| PT16023 | payments | 6,153 | 7 |
| PT20008 | accounts | 2,905 | 23 |
| PT20008 | additional_attributes | 15,235 | 8 |

## Not exported

- PT15016: not approved
- PT15018: not approved
- PT17013: not approved
- PT18019: not approved

## Caveats that travel with the numbers

- `cutoff_*` amounts are as of that deal's `cutoff_date`. Where the column is
  null the seller did not state the figure - it is NEVER derived, so a null
  principal does not mean zero principal.
- `verification_status` says how far a deal got. `reconciled` means a figure
  the seller published was matched exactly; `consistent` means no published
  figure existed to check against. Neither means "correct".
- Forward-flow deals are absent by design: their tapes are monthly
  deliveries, not the book.
