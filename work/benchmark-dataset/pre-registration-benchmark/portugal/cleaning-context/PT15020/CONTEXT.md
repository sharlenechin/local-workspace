# PT15020 - Oney, Portugal. Cleaning context.

## Header

    deal    PT15020, Oney, EUR
    files   1
    offer   unknown
    scope   5,313 loans, EUR 1,850,682.30
    status  reconciled
    run     uv run python scripts/run.py PT15020

## What the seller published, and we reproduce

Three figures, all to the cent, and they also reconcile to each other:

    Saldo Total            1,850,682.30     cutoff_balance
    Saldo_Contabilistico   1,339,500.46     cutoff_principal
    Juros (interests)        511,181.84     cutoff_interest
                           ------------
    capital + interest     1,850,682.30     = balance, on every one of 5,313 loans

The seller publishes them in a total row at the BOTTOM OF THE DETAIL SHEET -
row 5314 of 5,318 - not on a summary tab. The pipeline could not see that for
a week: the harvest only scanned sheets shorter than 60 rows, so this deal was
recorded as "no published figure, `consistent` only" while reconciling three
separate ways (T21).

A fourth, independent confirmation: `Encours_contabilistico` on the OTHER
sheet reproduces the principal exactly. That is what proves the two sheets are
one export rather than two extracts.

## Mapping decisions

**The book ships as two sheets with NO key in common.** `ANEXO_I_DADOS` carries
the contract number, the tax id, the product and the dates; `asset-index with
interest` carries the balance, principal and interest. `Contrato` and `Venda`
overlap on ZERO values - `Venda` is a row counter whose first cell is a leaked
header reading `ass`, not an identifier.

Dropping the second sheet would have lost the headline balance and the entire
interest split, so the two are paired by POSITION under the `align` role. That
is only permitted because the ordering is PROVEN, not assumed:
`Data_Contrato` agrees row for row across all 5,313 rows, and
`Encours_contabilistico` against `Saldo_Contabilistico` agrees on all 5,313 to
ten decimal places. The engine re-checks this every run and refuses rather
than mis-pairing. Four trailing rows of loose cells below the total are
discarded and counted.

**`loan_id` <- `Contrato`**, 5,313 distinct over 5,313 rows.
**`client_id` <- `nif`**, the tax number: 5,279 distinct, so a few borrowers
hold more than one contract.
**`segment` <- `FaseRecup`** (PRC / CON) and nothing is excluded - both values
are in the book. The seller's own summary labels the whole population
`Pre-Contencioso`.

## What the data cannot tell you

**No cut-off date.** Nothing on the tape states as-of when the balances were
struck, so `cutoff_date` is NULL rather than guessed.

**No judicialisation, no insolvency, no collateral, no holder type.** None of
these columns exist. `judicialised_flag` is NULL on all 5,313 - unknown, which
is not "not judicialised".

**Three loans carry NEGATIVE interest** - EUR -22.79, -0.83 and -106.95 - so
capital exceeds balance there. This is not a parse error: the identity
`balance = capital + interest` holds on all 5,313 loans to the cent. On
101134931 the interest exactly cancels the capital and the balance is 0.00,
which is what a written-back account looks like. The count is pinned in
guards.py so it stays visible and any change in it re-fails.

**No payments at all.** This tape carries no collections columns, so there is
nothing to net and no roll-forward to check.

## Not mapped, and the distinction

**Not on the tape (10):** `cutoff_date`, `claims_balance`,
`origination_amount`, `judicialised_flag`, `loan_holder_individual_flag`,
`loan_holder_corporate_flag`, `product_description`, `collateral_type`,
`insolvent_flag`, `insolvency_date`.

**On the tape and deliberately not mapped:** every borrower name, address,
phone, email and date of birth on both sheets - these are personal data with
no schema field and no analytical use here. Also `saldo_Gestão` (a management
balance that reconciles to nothing published), `Idade`, `distrito`, `rede`,
`Nacionalidade`, `prefixo` and the second-holder block.

Note `Idade` differs between the two sheets on every single row, which is
another reason nothing is taken from the second sheet except the three figures
that reconcile.

## Traps this deal taught

- **T21** - the published total sits INSIDE the detail sheet, and gets counted
  as a loan. Both halves now fixed: find_strats scans the bottom of large
  sheets, and the rows it PROVES are totals are published to the strats JSON
  so clean_accounts drops exactly those. Running the new harvest across all
  twelve books found the same shape on nine of them - the WiZink family writes
  a grand total at the foot of every monthly sheet, 21 of them on PT20014.
- The `align` role, and the rule that a positional join must prove itself.

## Still open

1. **No cut-off date.** Ask the deal owner; everything else about this deal is
   settled.
2. **Which balance is the right one to price on** - `Saldo Total` (total owed,
   used here) or `saldo_Gestão` (the management balance, EUR 1,852,...-ish but
   reconciling to nothing published). The seller's own total row uses Saldo
   Total, which is why it is the one mapped.

## Files

    tape        portugal/raw/processed/tables/PT15020.parquet
    output      accounts/PT15020.parquet
    registry    mappings.csv, 9 rows: 6 base, 3 align
    summary     cleaning-context/PT15020/cleaned_summary.md
    review      cleaning-context/PT15020/REVIEW.md
