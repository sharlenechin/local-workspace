# PT15018 - Millennium BCP, Portugal. Cleaning context.

Sections are fixed by CONTEXT_TEMPLATE.md and enforced by cases.py. A new
finding goes INTO the section it belongs to, never a new one at the bottom.

## Header

    deal    PT15018, Millennium BCP, EUR
    files   3 (2 claims .xlsx + 1 collections .xlsb; a 2nd .xlsb is a
            byte-identical duplicate and is skipped)
    offer   unknown - the filename is silent
    scope   32,531 loans, EUR 407,079,317.23
    status  reconciled
    run     uv run python scripts/run.py PT15018

## What the seller published, and we reproduce

SCOPE COMES FROM THE STRATS, not from the loans sheet. The .xlsb summary block
publishes a total per segment; scope is every collections row whose `Segmento`
is not `Excluded`. Rebuilt from the loan detail we land on it TO THE CENT:

    Individuals and ENIs   182,984,753.06  = published
    Insolvent Companies    168,419,228.69  = published
    SMEs                    55,675,335.48  = published
    total                  407,079,317.23  = published 407,079,317.23
    (Excluded: 163 loans, EUR 2,599,924.58 - out, and the total proves it)

A SECOND, INDEPENDENT PROOF: the summary's Interim Collections for
Oct-2015..13-Feb-2016 is EUR 1,569,865.11 and we reproduce it exactly, per
segment. Both are guards. If a change moves either, the change is wrong.

## Mapping decisions

- `loan_id` = `Numero de Conta`, the ORIGINAL account number. The `(Sistema)`
  twin was renumbered between deliveries and matches the collections file on
  0 of 1,557. Never join on a `(Sistema)` id. (T7)
- `client_id` = `Cliente Number`. On this book it is the ONLY id that reaches
  prod (64%); the account number reaches it on 0%.
- Grain is `loan_id` - this deal COLLAPSES. 79 accounts were split into several
  system records by a DDA->OCV migration, so their balances are PARTS of one
  loan. PT16023 is the opposite and must not. (T12)
- `judicialised_flag` and `insolvent_flag` are PERSON level, from both
  `Main Debtors` AND `Other Participants`, rolled up with max(). Taking Main
  Debtors alone loses 200 Yes from co-holders. (T16)
- The party join column is DISCOVERED by value overlap: the same id is
  `Cliente Number` on Collections and `Numero de Cliente Interno` on the party
  sheets. Keying on the name silently lost 1,450 flags. (T17)

**THREE DATES, AND WHY THE BASIS IS THE EARLIEST.** This deal carries three
as-of dates and they are nearly a year apart, across three workbooks:

    Sept 2015      OPB 407,079,317.23   ..._interim-collections_draft.xlsb
    13-Feb-2016    OPB 405,509,452.41   same sheet, second column
    2016-07-08     claims  3,267,311.81  ..._asset-index_1 and _2-3.xlsx

The roll-forward between the two balances is already proven BY THE SELLER and
reproduced here to 29 cents across EUR 405.5m:

    OPB Sept 2015                        407,079,317.23
    less interim collections               1,569,864.82   Oct-15 .. 13-Feb-16
                                        ----------------
                                         405,509,452.41
    OPB 13-Feb-2016, as given on the tape  405,509,452.41

So NOTHING is derived and nothing is netted. `cutoff_principal` is the
SEPTEMBER 2015 column because that is the basis the deal is PRICED on - the
`calculation` tab computes the purchase price from it (Portfolio A,
Individuals and ENIs: OPB 182,984,753.06 at 9.746% = 17,833,561.89) and
carries interim collections as a SEPARATE line, which is how they adjust the
consideration. Subtracting them from the OPB would double-count: a smaller
balance priced AND the cash handed back.

The 13-Feb-2016 figure is on the tape for whoever needs the position at
completion. It is not the basis.

**What `Valor em Divida` is, measured.** Logged as "unexplained" for days. It
is not unexplained; it is a DIFFERENT QUANTITY, and the arithmetic says so. On
the 441 loans that appear on both sheets by account number:

    Total OPB Setembro 2015  (Collections)   8,727,973.89
    Valor em Divida          (Claims)        1,371,257.55
    Capital                  (Claims)        1,302,326.42
    Juro                     (Claims)           63,920.42

It is LOWER than OPB on 405 of those 441. What Valor IS, exactly:
`Capital + Juro + Outras Despesas == Valor em Divida` on 1,129 of the 1,132
Claims rows - so it is the total of the CLAIM, including the COURT COSTS that
no loan balance carries.

!! AND THE TWO ARE TEN MONTHS APART. The Claims sheet carries its own
`Data de Referência`, and it reads 2016-07-08 on 1,128 of 1,132 rows. The
balance is `Total OPB Setembro 2015`. Nobody was ever going to reconcile a
July 2016 legal filing to a September 2015 principal.

!! DO NOT DESCRIBE THE CLAIM AS "A FRACTION OF THE EXPOSURE". It usually is -
the median claim is 8.8% of OPB - but the ratio runs from 0 to 145.77x and
the claim EXCEEDS OPB on 32 of the 441. There is no proportional
relationship, and asserting one was wrong. Nor does product explain it:
mortgages median 0.069, overdrafts 0.114, leasing 0.125, with enormous
variance inside each.

WHY they diverge is NOT answerable from this tape. The plausible readings -
the claim covers only the portion pursued in one proceeding, the account was
partly recovered between the two dates, the claim attaches to a guarantor -
are all for the deal owner to confirm. What is settled is the practical rule:
`claims_balance` cannot be reconciled to, compared with, or substituted for a
balance. It is a legal-process figure on its own timeline.

## What the data cannot tell you

- `judicialised_flag` is a FLOOR. The column is headed `(Y/N)` but holds only
  `Yes` and `Not Available` - there is NO `No`, so false never appears and null
  means UNKNOWN. Validated against the court sheets: 0 loans have a proceeding
  on file but an unknown flag, so it never misses someone. (T11)
- `insolvent_flag` DOES have real Ns (1,134 false), unlike judicialised. Same
  tape, two conventions - handled by the data-dependent rule, not configuration.
- `origination_amount` zeros are REAL: 320 of 329 are `Descobertos / CCC`,
  overdrafts, where nothing is disbursed at origination.
- `default_date` is null on ~59%. A property of the tape.
- `claims_balance` != `cutoff_balance`. On the 673 shared loans the claims sheets
  say EUR 3.27m and collections EUR 15.92m; 2 of 673 agree. Only `cutoff_balance`
  tallies and only it may be used as THE balance.

## Not mapped, and the distinction

    GENUINELY ABSENT     collateral - no collateral/guarantee sheet shipped
    DERIVABLE            -
    NOT IN THE SCHEMA    the legal sheets: Participants Legal (4,789 rows),
                         Proceedings Legal (2,991), Claims_Legal (389). 94% are
                         about OUR clients - 824 of them have court proceedings
                         on record. The schema has no proceedings table and a
                         client can have up to 70, so there is nowhere to put it.

## Traps this deal taught

    T1 T2 T3 T4 T5 T6 T7 T8 T10 T11 T12 T16 T17 - detail in traps.yaml.
    Thirteen, every one SILENT. Not one raised an error.

Two more on 2026-10-07, both found by running PT18019's new checks back
against this deal rather than by anything on this tape:

    T18  the ENGLISH header row survived. These sheets carry TWO header rows:
         row 0 in Portuguese, which becomes the column names, and row 1 holding
         the translation, which arrives as data. The filter compared values
         against column names and `Account Number` is not one of them -
         `Numero de Conta` is - so a "loan" whose product_type was "Product
         Code" reached the output, alongside an all-`x` stray. Both now fail
         the quantity test: a row carrying no amount and no date cannot be a
         loan. 32,531 -> 32,529, and THE BALANCE DID NOT MOVE BY A CENT, which
         is what makes the drop defensible rather than a trim to fit.

    T18  insolvency was being read at the WRONG GRAIN. `insolvent_flag` came
         only from the person-level `Involvente (Y/N)`, which answers 2,138
         loans. `Segmento = Insolvent Companies` is the same fact at LOAN
         level on 6,951, and the finer grain wins (T16). Mapping it with
         `eq:Insolvent Companies` took the flag from 2,138 True to 7,457, with
         zero conflicts - no loan in that segment is marked False by a person -
         and the 1,134 real Falses are untouched.

## Still open

- PERIMETER. The claims sheets describe 1,555 loans; only 673 are in the strats
  population. The other 882 carry EUR 15.4m and are contingent exposure
  (guarantees, documentary credits, returned cheques). RESOLVED: the strats
  exclude them, and the published total proves it.
- A proceedings table in the schema - raise with the data team; this will recur
  on every Portuguese book.
- What the payment column means. Labelled interim collections and consistent with
  cash collected pre-acquisition, never confirmed against a seller remittance.
- Why only 673 of 32,529 loans carry a claim at all - no proceeding, or no
  record of one? This is what is left of the Claims-versus-Collections
  question now that the two quantities are understood (see Mapping decisions).

## Files

    CONTEXT.md           this - judgement calls, hand-written, fixed sections
    cleaned_summary.md   GENERATED from the output
    REVIEW.md            GENERATED - what the reviewer reads
    decisions.yaml       approvals, rejections, resolutions, approved output hash
