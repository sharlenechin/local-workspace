# PT20008 -- approval sheet

**Oney**, PT. 2,905 loans, EUR 5,751,844.33.

Everything here is either settled by arithmetic or waiting on your judgement.
The sheet says which is which.

**Deal type: one-off.** ONE-OFF as Intrum underwrote it: a single PAM reference ending 0000, no monthly tranches, no FF segment label. A single tape CAN be the whole book here.

!! **This deal states NO CUT-OFF DATE.** The balances are as at whatever date
the seller struck the tape, and the tape does not say which. `find_cutoff.py`
reads the banner rows of every sheet looking for one; it found none here.
A figure from this deal cannot be dated.

## 1. What figure is this deal, and how far is it proven?

**The deal is `Divida_Total`.** It is mapped to `cutoff_balance`, and over the
2,905 in-scope loans it totals **EUR 5,751,844.33**. Every figure anyone
quotes for this book comes from that one column choice.

**Proven against the seller's own published figure, to the cent.**

**The column this deal uses:**

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `Divida_Total` | Folha1 | 5,751,844.33 | none |

**Other columns on this tape that ALSO reproduce a published figure.**
These are the alternatives. Picking one instead changes what this deal is:

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `Divida_Contabilistico` | Folha1 | 3,725,152.89 | none |

**Your decision:** is `Divida_Total` the right measure, and is it as of the right
date? A balance can reconcile perfectly and still be the wrong month, or the
balance at write-off rather than the balance today.

## 2. What the engine decided

**2,905 row(s) left the book** before the 2,905 above were counted:

| rows | why |
|---:|---|
| 2,905 | dropped 2,905 rows -- Portefólio OneyBank_30.06.2020.xlsx / Folha1 is the SAME book as PT20008A000000_Oney_asset-index (1).xlsx / Folha1 row for row on the 7 field(s) both populate (20,335 populated cells against 23,950; the fuller copy is kept) |

Each of these is a rule the engine applies to every deal, not a judgement about
this one - the rules are in `traps.yaml` and each is covered by a regression
case. What needs YOUR eye is whether any of them did something you did not
expect on THIS book.

## 3. What the seller published

Printed on the tape by the seller - this is what the arithmetic above
reconciles against. Read it to judge whether the figure this deal reports
is the QUANTITY you want.

| sheet | column the seller totalled | their total | scope they applied |
|---|---|---:|---|
| `Folha1` | `Divida_Total` | 5,751,844.33 | whole sheet |
| `Folha1` | `Divida_Contabilistico` | 3,725,152.89 | whole sheet |

2 published total(s) across 1 sheet(s).

## 4. Do these mappings mean what they say?

Evidence: no data dictionary -- everything below is inference.

**1 row(s) settled by arithmetic** - the column reproduces a published
figure exactly, so the only open question would be what it MEANS, and section 1
asks that: `cutoff_balance`.

**3 row(s) you have already confirmed** against this exact raw file
and this exact mapping - if either changes they come back: `origination_date`, `product_type`, `segment`.

**6 row(s) to read.** Each is a column name we interpreted. Nothing
proves these mean what they say - that judgement is what you are signing.

`lands in` says which output carries the field: the fixed `core` every consumer
relies on, or `additional` - the open long table. Approving covers BOTH.

**Reject what is wrong, note what you want answered, then approve the rest:**

    review.py PT20008 --reject <field> "what is wrong"
    review.py PT20008 --note "anything not about one field"
    review.py PT20008 --approve        # signs off everything not rejected

| field | lands in | <- column | filled | sample | why this column |
|---|---|---|---:|---|---|
| `cutoff_principal` | core | `Divida_Contabilistico` | 2,905 (100%) | 601.44, 346.56 | JUDGEMENT, not a translation |
| `insolvent_flag` | additional | `fase_recuperacao` | 2,905 (100%) | False, True | fase_recuperacao is a COMPLETE PARTITION: CONTENCIOSO (579), INSOLVENTE (1,205) and PRE-CONTENCIOSO (1,121) cover all ... |
| `insolvency_start_date` | additional | `Data_Inicio_Exoneracao_Insolv` | 1,205 (41%) | 2019-05-08 00:00:00, 2016-04-27 00 | START of the exoneration period (exoneracao do passivo restante), NOT the date insolvency was declared |
| `insolvency_end_date` | additional | `Data_Fim_Exoneracao_Insolv` | 1,205 (41%) | 2024-05-08 00:00:00, 2021-04-27 00 | END of the same period |
| `judicialised_flag` | additional | `fase_recuperacao` | 2,905 (100%) | True, False | fase_recuperacao is a COMPLETE PARTITION: CONTENCIOSO (579), INSOLVENTE (1,205) and PRE-CONTENCIOSO (1,121) cover all ... |
| `insolvency_claims_balance` | additional | `Valor_Reclamado` | 1,205 (41%) | 280.56, 950.96 | INSOLVENCY-ONLY, measured not assumed: populated on exactly the 1,205 INSOLVENTE loans and on ZERO of the 579 CONTENCI... |

**Empty on this deal (14).** Either the tape does not carry the
fact, or it carries it somewhere we did not map. `CONTEXT.md` for this deal
separates the two, field by field:

`loan_id`, `client_id`, `cutoff_date`, `cutoff_interest`, `cutoff_other_fee`, `origination_amount`, `default_date`, `loan_holder_individual_flag`, `loan_holder_corporate_flag`, `borrower_type`, `claims_balance`, `judicial_start_date`, `judicial_end_date`, `product_description`


---

**This sheet is the OUTSTANDING list and nothing else.** Every field this deal
produces - its source sheet and column, the transform, how full it is, an example
value and whether you have signed it - is in `cleaned_summary.md`, which is the
permanent record. When this deal is approved there is nothing left to read here.

## 5. Payments

**37,765 payment cell(s) on this tape, and EVERY ONE IS ZERO.**

The seller shipped the payment columns with no money in them. A zero is
not a payment, so every cell is null and the file is empty. That is their
data, not a gap in our reading - and it is NOT the same as a tape whose
payments we could not attribute.

## 6. Approve

**APPROVED** by sharlene on 2026-10-13 12:32.

The signature covers the output file as it stands now (`f80ea0c0acf2`).

Re-approving is not needed and not possible without a change: if the output
moves, this line turns to APPROVED-STALE and the deal must be reviewed again.

    uv run python scripts/verify.py PT20008
