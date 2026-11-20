# PT20008 - Oney, Portugal. Cleaning context.

## Header

    deal    PT20008, Oney, EUR
    files   2 (the same book twice - see below)
    offer   unknown
    scope   2,905 loans, EUR 5,751,844.33
    status  reconciled
    run     uv run python scripts/run.py PT20008

## What the seller published, and we reproduce

The `TD` tab is a pivot by recovery phase and every line of it is reproduced:

    CONTENCIOSO        579     2,155,285.75     1,198,890.49
    PRE-CONTENCIOSO  1,121       542,230.31       310,339.71
    INSOLVENTE       1,205     3,054,328.27     2,215,922.69
                     -----     ------------     ------------
    Total Geral      2,905     5,751,844.33     3,725,152.89
                               Divida_Total     Divida_Contabilistico

Both totals reconcile to the cent with no scope filter: all three phases are
in the book.

**This book cleaned to exactly TWICE those figures for an hour** - 5,810 loans
and EUR 11,503,688.66 - because it ships as two files,
`..._Oney_asset-index.xlsx` and `..._Oney_asset-index (1).xlsx`, whose bytes
differ and whose data is identical (T24). The byte-level duplicate guard
could not see it. It was caught only because the result was exactly 2x a
figure the seller had published; a book without a published total would have
passed every check in the pipeline.

## Mapping decisions

**There is no loan identifier on this tape, at all.** The only id-shaped
column, `ID Base cessao`, holds exactly the values 1..2905 in order - it sums
to 4,220,965, which is 2905 x 2906 / 2. It is a row counter the seller left
in. There is no contract number and no tax number; the tape is anonymised
apart from phone numbers.

So `loan_id` is NULL on all 2,905 rows and `loan_id_missing_flag` is True on
all of them. The deal cleans and reconciles; it **cannot be bridged to prod**
until the seller supplies a key. That is stated here rather than discovered
later by a join that silently returns nothing.

**`fase_recuperacao` drives three fields, and the structure proves it** rather
than the labels alone:

    insolvent_flag     <- eq:INSOLVENTE    1,205 loans
    insolvency_date    <- Data_Inicio_Exoneracao_Insolv
    judicialised_flag  <- eq:CONTENCIOSO     579 loans

`Valor_Reclamado`, `Valor_Reconhecido` and `Data_Inicio_Exoneracao_Insolv` are
populated on exactly the 1,205 INSOLVENTE rows and on no others, and
`Estado Processo em Contencioso` on 576 of the 579 CONTENCIOSO rows and
nothing else. The phases are a clean partition.

**Neither flag writes False** (T18). PRE-CONTENCIOSO arguably does mean
not-yet-judicialised, and a reviewer may decide that; INSOLVENTE says nothing
either way, so no negative is written anywhere.

**`claims_balance` <- `Valor_Reclamado`** - the amount claimed in the
insolvency, meaningful only on those 1,205 loans and never to be used as a
balance.

## What the data cannot tell you

**No cut-off date, no default date, no borrower identity, no collateral.**
`AAAMM_entrada_Pre-Contencioso` gives the month of entry into pre-litigation
as `yyyymm` text and could be read as a default date, but entry into
pre-litigation is not default and mapping it there would be a guess wearing a
column name.

## Not mapped, and the distinction

**Not on the tape (10):** `loan_id`, `client_id`, `cutoff_date`,
`cutoff_interest`, `origination_amount`, `default_date`,
`loan_holder_individual_flag`, `loan_holder_corporate_flag`,
`product_description`, `collateral_type`.

**On the tape and deliberately not mapped:** `ID Base cessao` (a row counter -
mapping it to loan_id would manufacture a key that joins to nothing),
`Valor_Reconhecido`, `Estado Processo em Contencioso`,
`Data_Fim_Exoneracao_Insolv`, `Nr_intervenientes`, `Tipo_Gestao`,
`Idade_1TIT`, `rede`, `Tipo_Contrato` (a single value, PARTICULAR), and the
phone numbers.

**Payments:** 13 monthly `PAGAMENTOS_yyyymm` columns (201803-201903) plus
`PAG_ULT_ANO`, loaded but not cleaned - `clean_payments.py` does not exist
for any deal yet.

## Traps this deal taught

- **T24** - the same sheet twice under two filenames, bytes differing. The
  loader now hashes sheet CONTENT, keyed on deal plus sheet name so two real
  monthly cohorts can never collide. Thirteen duplicate sheets were found
  across five deals this way, including an 894-row and an 801-row cohort in
  books not yet loaded.
- A tape with NO identifier is a real state, not a crash. The engine used to
  raise an AttributeError.
- A vacuous guard is worse than none: "PASS loan_id unique, 0 duplicated of
  0" read as a clean key and meant there was no key.

## Still open

1. **No key, so no bridge.** Ask the seller for a contract number. Everything
   else about this deal is settled.
2. **Whether PRE-CONTENCIOSO should write `judicialised_flag = False`.** A
   reviewer's call, not a cleaner's.
3. **Whether `AAAMM_entrada_Pre-Contencioso` is close enough to a default
   date** to map.

## Files

    tape        portugal/raw/processed/tables/PT20008.parquet
    payments    portugal/raw/processed/tables/payments.parquet  (deal == PT20008)
    output      accounts/PT20008.parquet
    registry    mappings.csv, 9 rows, all role `base`
    summary     cleaning-context/PT20008/cleaned_summary.md
    review      cleaning-context/PT20008/REVIEW.md
