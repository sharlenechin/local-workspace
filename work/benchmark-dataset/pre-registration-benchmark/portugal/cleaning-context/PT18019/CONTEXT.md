# PT18019 - WiZink, Portugal. Cleaning context.

## Header

    deal    PT18019, WiZink, EUR
    files   1
    offer   unknown
    scope   31,699 loans, EUR 145,611,063.99
    status  consistent
    run     uv run python scripts/run.py PT18019

## What the seller published, and we reproduce

**Nothing.** `find_strats.py` harvests zero candidate totals from this tape -
there is no strats sheet, no summary block, and no cell that equals the sum of
a contiguous run above it. So there is no external figure to tie to, and this
deal can never reach `reconciled`. Its ceiling is `consistent`.

What `consistent` buys here, concretely: every mapped column parsed, the ids
are unique and survive as text, capital never exceeds balance, no balance is
negative, and re-running reproduces the output byte for byte. That is internal
arithmetic only. If the seller's own figure for this book turns out to differ
from EUR 145,611,063.99, nothing in this pipeline would have caught it.

Worth asking the deal owner for a published total. One figure would move this
deal from `consistent` to `reconciled`.

## Mapping decisions

**`loan_id` <- `account`, not `Loan.ID`.** Three identifiers ship on this tape:
`account` (19 digits), `Loan.ID` (`L_82278`) and `reference_number` (`82278`).
OVERVIEW.md records that `account` matches prod on 100% of loans while the
other two reach it on none, so `account` is the one that bridges. All 31,699
are distinct. Read as text - as a number the leading zeros are destroyed (T13).

**`insolvent_flag` <- `Perimeter`, with `eq:Bankruptcy`.** This tape has no
insolvency column. It has `Perimeter`, whose four labels are Bankruptcy
(9,298), Category 1 (1,883), Category 2 (19,126) and Deceased (1,392).
Bankruptcy IS the insolvency fact, and dropping it as "not on this tape" would
discard 9,298 real facts. The `eq:` transform writes True on the match and NULL
on everything else, never False: `Category 2` says what a loan IS, not that the
borrower is solvent (T18).

**`segment` <- `Perimeter`, and nothing is dropped.** Unlike PT15018, where
`Segmento = Excluded` marks 163 loans as out of the deal, all four Perimeter
labels are segments OF the book. 31,699 in, 0 out.

## What the data cannot tell you

**No cut-off date.** `Balance.CutOff` and `Principal.CutOff` are named for a
date the tape never states. The balances are usable; the date is not known, so
`cutoff_date` is NULL on every row rather than guessed from the filename.

**Payments carry no dates at all (T20).** The 15 payment columns are relative -
`-12M`..`-1M` before the cut-off and `1M`..`3M` after it - and with no cut-off
date there is no anchor. EUR 10,615,169.65 across 475,485 rows is real money
whose timeline is unknown. `period_month` is NULL on every row deliberately.
The `1M`..`3M` columns are post-cut-off ACTUALS, which for a benchmark is the
most valuable data here; they were dropped silently until 2026-10-07, when the
loader's regex was widened from `-\d+M` to `-?\d+M`.

**No borrower identity.** There is no client number, no person sheet and no
borrower type, so `client_id`, both holder flags and everything party-level
stay NULL. `judicialised_flag` is NULL on all 31,699 - unknown, which is not
the same as "not judicialised".

## Not mapped, and the distinction

NULL here means one of two things and they are not interchangeable.

**Not on the tape at all (11):** `client_id`, `cutoff_date`, `cutoff_interest`,
`claims_balance`, `origination_amount`, `origination_date`,
`judicialised_flag`, `loan_holder_individual_flag`,
`loan_holder_corporate_flag`, `product_description`, `collateral_type`,
`insolvency_date`.

**On the tape and deliberately not mapped (2):** `Debt.Age` and
`reference_number`. `Debt.Age` is a derived age in days that the schema has no
field for and that `default_date` already implies. `reference_number` is the
seller's own sequence, kept out so nothing accidentally joins on it (T7).

**Derivable but NOT derived (1):** balance minus capital is EUR 23,782,613.02
across the book, and that is NOT `cutoff_interest` - it is interest plus fees
plus whatever else the seller folded in, with nothing on the tape to separate
them. Writing it into `cutoff_interest` would be a guess wearing a column name.

## Traps this deal taught

- **T18** - a schema fact encoded as one value of a segment column. Now a
  detector, an `eq:` transform and a regression case.
- **T20** - payment columns relative to an unstated cut-off, and the regex that
  silently dropped the post-cut-off half.

Running the detectors against the deals already settled, T18 then found a
loan-level insolvency source on PT15018 that its person-level mapping had
missed - 5,319 loans gained a True.

## Still open

1. **No published figure.** Ask the deal owner. Until then, `consistent`.
2. **No cut-off date**, so the payments cannot be dated. Same ask.
3. **Prod holds 29,976 loans for PT18019** per OVERVIEW.md, against 31,699
   here. A 1,723 difference that is expected - the tape is pre-registration and
   prod is what was ultimately bought - but it has not been reconciled loan by
   loan. That is the bridge's job, not this stage's.

4. **`Perimeter = Deceased` has no home in the schema.** 1,392 loans, EUR
   6,580,059.54. A deceased borrower changes how a loan is worked and is
   exactly the kind of fact underwriting asks for, but there is no
   `deceased_flag` column and inventing one for a single deal is how a schema
   rots. The detector now says so explicitly rather than naming a column that
   does not exist. If a second deal carries the same fact, add it through
   `add_column.py` and backfill - that is the promotion rule for columns.
   Until then the information survives in `segment`.

## Files

    tape        portugal/raw/processed/tables/PT18019.parquet
    payments    portugal/raw/processed/tables/payments.parquet  (deal == PT18019)
    output      accounts/PT18019.parquet
    registry    mappings.csv, 7 rows, all role `base`
    summary     cleaning-context/PT18019/cleaned_summary.md
    review      cleaning-context/PT18019/REVIEW.md
