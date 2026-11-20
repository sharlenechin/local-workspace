# PT15016 - Barclays, Portugal. Cleaning context.

## Header

    deal    PT15016, Barclays, EUR
    files   1
    offer   unknown
    scope   3,958 loans, EUR 14,942,413.07
    status  consistent
    run     uv run python scripts/run.py PT15016

## What the seller published, and we reproduce

    woff_bal   14,949,117.19   over 3,958 accounts

Published in a total row at the foot of the single detail sheet, not on a
summary tab (T21). Before that row was excluded the column summed to
29,898,234.38 - exactly twice the figure - which is the signature of the trap
and the reason a deal with a perfectly good published total can look like a
deal with none.

**AND WE DO NOT USE IT.** The deal is measured on `curr_bal`, not `woff_bal`,
so the published figure above backs a column this deal does not carry and the
status is `consistent`, not `reconciled`. That was chosen with the cost in
view: see the balance decision below.

## Mapping decisions

**`loan_id` <- `acct`, not `acct_serno`.** The same split as PT18019: a
19-digit account number and a short seller sequence. The 19-digit one is what
bridges to prod. Read as text or the leading zeros are destroyed (T13).

**`cutoff_balance` <- `curr_bal`, not `woff_bal`.** They differ by 6,704.12
across the book, on 48 of 3,958 loans.

    curr_bal  = sum_prin + sum_int + sum_fee   on ALL 3,958 loans, exactly
    woff_bal  = the balance frozen AT CHARGE-OFF, and higher on those 48
                wherever something has been recovered since

`curr_bal` is what the borrower owes now, which is what is being bought. The
internal-consistency guard is the proof: against `woff_bal` two loans breached
capital + interest <= balance and EUR 6,704.12 was unexplained; against
`curr_bal` there are zero breaches and the residual is exactly zero.

The cost is real and was accepted: the seller published a total for `woff_bal`
and not for `curr_bal`, so this deal gives up `reconciled` for `consistent`.

**`cutoff_interest` <- `sum_int + sum_fee`.** The seller splits what is
owed three ways:

    sum_prin  11,797,651.67     -> cutoff_principal
    sum_int    2,078,145.26  \
    sum_fee    1,066,616.14  /  -> cutoff_interest, added
              ------------
    curr_bal  14,942,413.07     exactly

The fee is money the borrower owes, so it belongs with the interest rather
than nowhere. Mapping `sum_int` alone left EUR 1,066,616.14 with no home and
showed up as an unexplained residual. With both, the residual falls to
EUR 6,704.12 - precisely the amount by which `woff_bal` exceeds `curr_bal`
across the book, which is the only gap that remains.

## What the data cannot tell you

**No cut-off date, no borrower identity, no judicialisation, no insolvency.**
`judicialised_flag` is NULL on all 3,958 - unknown, not "not judicialised".
There is a rich personal-data block (names, dates of birth, addresses,
employer, tax id) which is deliberately not mapped.

**One account is written off BELOW its own components.** 0004228654352662342
has woff_bal 4,809.28 against sum_prin 5,068.20 + sum_int 114.11 + sum_fee
296.02 = 5,478.33, which is exactly its own curr_bal. The components are
internally right, so this is a partial write-off or a post-charge-off payment,
not a parse error. Pinned in guards.py.

## Not mapped, and the distinction

**Not on the tape (11):** `client_id`, `cutoff_date`, `claims_balance`,
`origination_amount`, `judicialised_flag`, `loan_holder_individual_flag`,
`loan_holder_corporate_flag`, `product_description`, `collateral_type`,
`insolvent_flag`, `insolvency_date`.

**On the tape and deliberately not mapped:** `sum_fee` (no schema column - see
above), `curr_bal`, `termbal`, `amt_cgoff`, `crlim`, `woffresn`, `woff_month`,
`months_co_nopay`, `work_number`, and the whole personal-data block.

**Worth a decision:** `crlim` (credit limit, 10,631,342.00) is the closest
thing this tape has to `origination_amount`, but a revolving card's limit is
not an advanced amount and mapping it there would be wrong.

## Traps this deal taught

Nothing new - it CONFIRMED T21 on a second seller, which is what moved that
trap from one deal to two. It also forced the balance-components guard from an
equality to an inequality plus a printed residual: asserting
`balance == capital + interest`, true of PT15020 to the cent, would have
failed all 3,958 of these correct loans because this seller has fees.

## Still open

1. **No cut-off date.** The sheet is named `WOFF_MASTER_201510` and
   `woff_month` holds five month values, so the write-off months are known
   even though the balance as-of date is not stated.
2. **Whether a fee column belongs in the schema.** 1,066,616.14 here is real
   money with nowhere to go. If a second deal ships one, promote it through
   `add_column.py`.
3. **Payments are loaded but not cleaned.** 12 months of `pay` and `ret`
   columns (NOV14..OCT15) are in payments.parquet; `clean_payments.py` does
   not exist yet, so the netting is not done for any deal.

## Files

    tape        portugal/raw/processed/tables/PT15016.parquet
    payments    portugal/raw/processed/tables/payments.parquet  (deal == PT15016)
    output      accounts/PT15016.parquet
    registry    mappings.csv, 8 rows, all role `base`
    summary     cleaning-context/PT15016/cleaned_summary.md
    review      cleaning-context/PT15016/REVIEW.md
