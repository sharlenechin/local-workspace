# PT16023 - Millennium BCP, Portugal. Cleaning context.

Sections are fixed by CONTEXT_TEMPLATE.md and enforced by cases.py. A new
finding goes INTO the section it belongs to, never a new one at the bottom.

## Header

    deal    PT16023, Millennium BCP, EUR
    files   1 (Millennium_2016_Masterdatatape_NBO.xlsb, 13 sheets)
    offer   nbo - the only one of the twelve whose filename says so
    scope   19,434 loans, EUR 224,485,808.25
    status  reconciled
    run     uv run python scripts/run.py PT16023

## What the seller published, and we reproduce

The `Strats - Total` sheet states the portfolio three ways - by sub-portfolio,
by ticket range, by default year - and all three total the same. Reproduced
exactly from the loan detail:

    # of accounts   19,434          = published
    OB  (EUR)       224,485,808.25  = published
    UPB (EUR)       219,753,165.09  = published

!! NO SCOPE FILTER IS NEEDED. Unlike PT15018, which ships 163 `Excluded` loans
   that must be dropped before the total ties, this tape contains only in-scope
   loans. The strats search found the totals with no filter at all.

## Mapping decisions

- **`cutoff_balance` = `OB (EUR)`, `cutoff_principal` = `UPB (EUR)`.** Both
  reconcile, so both are PROVEN. They are EQUAL on 17,683 of 19,434 loans; the
  EUR 4.7m difference sits in 1,751. OB is the broader measure (principal plus
  costs), UPB is principal only.
- **`product_type` = `Product Type`**, the readable name (12 values:
  `Overdraft/ C.A.`, `Leasing`, `Loan`). !! `Product Code` is a CODE, 48 of them
  (`DDA`, `LEA`, `CLS`), and mapping it here was REJECTED on review 2026-10-07.
  `product_description` is left unmapped - this tape has no description field.
- **Grain is `row`, not `loan_id`.** The published count is "# of accounts
  19,434", one per tape row. Collapsing on the composite id gives 18,283 and
  stops matching the seller's own count. PT15018 is the opposite and must
  collapse. See T12.
- **`judicialised_flag` and `insolvent_flag` are LOAN level here**, columns on
  the loan row itself. On PT15018 the same facts are PERSON level and must be
  rolled up. See T16 - the finer grain wins, and the engine handled both from
  the registry role alone.

## What the data cannot tell you

- **`judicialised_flag = False` MEANS "not in court" on this deal.** The column
  holds `Y` (12,743) and a REAL `N` (6,691). On PT15018 there is no `N` at all,
  so false never appears there and null means "unknown". Same column name,
  opposite meaning, both passing every guard. Carry this into any stitch.
- **81 loans carrying EUR 3,422,668.84 share 8 identifiers** like `0_0_CCJ`:
  their company and account numbers are both zero, so the composite degenerates
  to the product code. Harmless at row grain - the balance still ties - but they
  cannot be told apart, and collapsing on that id would merge 81 loans into 8.
  See T15. Found by the approval sheet, not by any guard.
- **`default_date` is 86% populated** (16,716 of 19,434), from `Delinquency
  Date`, which ships as Excel serials. See T14.

## Not mapped, and the distinction

GENUINELY ABSENT from this tape:

    claims_balance       a PT15018 concept (a second sheet); this deal has one
    origination_amount   no such column
    collateral_type      no such column

DERIVABLE but NOT YET MAPPED - do not read these as "the seller did not give it":

    cutoff_interest      OB - UPB = EUR 4,732,643.16, the non-principal part
    origination_date     `Age (Months)` exists, 220 distinct values
    cutoff_date          probably a constant in the file title, not a column

UNMAPPED AND NOT IN THE SCHEMA AT ALL - real data being discarded:

    Number of Guarantors, Number of Holders, Country (Residency), Nationality,
    Legal segment, Ticket Range, IJ-Type of product, Type of produc segment

## Traps this deal taught

T14  Excel serial dates. `Delinquency Date` ships as 42402, not a date.
         Parsed as a date it is null; as a number it is a plausible 42,402 that
         no guard would question. New transform `date_serial`.
    T15  a composite id collapsing because its parts are zero (the 81 loans).
    T16  the same fact at two grains - loan level here, person level on PT15018.

    T19  `COMP_OPER_PROD (Unique Loan ID)` IS NOT UNIQUE, despite the name.
         1,877 rows share 723 ids - EUR 22,713,253.39, 10.1% of the book - and
         one id spans DIFFERENT clients (`0_0_CMC` sits on both 20780066 and
         21758639), because the composite collapses wherever its parts are
         zero. The row count still ties to the published 19,434 exactly, so
         the rows are right and the id is simply not a key. Found on
         2026-10-07, by a guard written for a deal that had no strats at all.
         NOT fixed with a surrogate key: the count is pinned in guards.py so
         the defect stays visible and any change in it re-fails.

And it sharpened T11: whether `False` is writeable is a property of the COLUMN,
not a constant. PT16023 has real Ns and they must be kept; PT15018 has none and
writing False there would invent 29,582 negatives.

## Still open

- `default_date` - a reviewer rejection is OPEN: is `Delinquency Date` when the
  loan defaulted, or when the claim fell due? Not resolvable by cleaning.
- The derivable fields above: whether to compute `cutoff_interest` from OB - UPB
  and `origination_date` from `Age (Months)`.
- Whether the unmapped columns (guarantors, holders, nationality, legal segment)
  warrant schema fields.
- **The non-unique loan id (T19).** Open with the deal owner: is there a column
  that IS one row per loan, or does the seller accept that 723 of its ids are
  shared? This has to be settled before the bridge, which will otherwise fan
  out on 1,877 rows.

## Files

    CONTEXT.md           this - judgement calls, hand-written, fixed sections
    cleaned_summary.md   GENERATED from the output
    REVIEW.md            GENERATED - what the reviewer reads
    decisions.yaml       approvals, rejections, resolutions, approved output hash
