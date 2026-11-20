# PT17013 -- approval sheet

**Oney**, PT. 11,827 loans, EUR 18,657,766.36.

Everything here is either settled by arithmetic or waiting on your judgement.
The sheet says which is which.

**Deal type: one-off.** ONE-OFF as Intrum underwrote it: a single PAM reference ending 0000, no monthly tranches, no FF segment label. A single tape CAN be the whole book here.

**As at 2017-06-30.** Everything below is the book on that date.

## 1. What figure is this deal, and how far is it proven?

**The deal is `Valor total em dívida`.** It is mapped to `cutoff_balance`, and over the
11,827 in-scope loans it totals **EUR 18,657,766.36**. Every figure anyone
quotes for this book comes from that one column choice.

**Nothing on this tape is proven against a seller figure.** `find_strats` found
no published total to reconcile against, so this deal can reach `consistent`
and never `reconciled`.

What `consistent` means here: every column parsed, the ids behave, capital
never exceeds balance, and a re-run reproduces the file byte for byte. All
internal. If the seller's own number differs from EUR 18,657,766.36, nothing
in this pipeline would catch it.

**Your decision:** is that acceptable for this book, or should someone ask the
seller for a published total?

## 2. Do these mappings mean what they say?

Evidence: no data dictionary -- everything below is inference.

**No row is settled by arithmetic.** Nothing on this tape reconciles, so every
mapping below is inference and every one needs reading.

**6 row(s) to read.** Each is a column name we interpreted. Nothing
proves these mean what they say - that judgement is what you are signing.

`lands in` says which output carries the field: the fixed `core` every consumer
relies on, or `additional` - the open long table. Approving covers BOTH.

**Reject what is wrong, note what you want answered, then approve the rest:**

    review.py PT17013 --reject <field> "what is wrong"
    review.py PT17013 --note "anything not about one field"
    review.py PT17013 --approve        # signs off everything not rejected

| field | lands in | <- column | filled | sample | why this column |
|---|---|---|---:|---|---|
| `loan_id` | core | `ID` | 11,827 (100%) | 1, 10 | 11,827 values, all distinct, one per row |
| `cutoff_balance` | core | `Valor total em dívida` | 11,827 (100%) | 16574.48, 13436.26 | total owed: EUR 18,657,766.36 over 11,827 loans, populated on every row |
| `cutoff_principal` | core | `Valor de Capital` | 11,827 (100%) | 4601.14, 7234.96 | EUR 10,521,475.87 |
| `origination_date` | core | `Data Contrato` | 11,827 (100%) | 1998-10-19, 1999-01-22 | contract date, populated on all 11,827 |
| `judicialised_flag` | additional | `Fase` | 11,827 (100%) | True, False | `Fase` is a COMPLETE PARTITION: Contencioso (4,650) and Pre-Contencioso (7,177) cover all 11,827 rows with no blanks, ... |
| `product_type` | core | `Rede` | 11,827 (100%) | PPR Lyberdade, Cartão Jumbo Mais | the credit product: Cartao Jumbo Mais (7,167), Cartao Jumbo mais I (3,446), Credito Conta Corrente (581), PPR Lyberdad... |

**Empty on this deal (17).** Either the tape does not carry the
fact, or it carries it somewhere we did not map. `CONTEXT.md` for this deal
separates the two, field by field:

`client_id`, `segment`, `cutoff_interest`, `cutoff_other_fee`, `origination_amount`, `default_date`, `loan_holder_individual_flag`, `loan_holder_corporate_flag`, `borrower_type`, `claims_balance`, `insolvency_claims_balance`, `judicial_start_date`, `judicial_end_date`, `insolvent_flag`, `insolvency_start_date`, `insolvency_end_date`, `product_description`


---

**This sheet is the OUTSTANDING list and nothing else.** Every field this deal
produces - its source sheet and column, the transform, how full it is, an example
value and whether you have signed it - is in `cleaned_summary.md`, which is the
permanent record. When this deal is approved there is nothing left to read here.

## 3. Payments

This tape carries **no payment columns at all**, so no payments file was
written. That is the seller's tape, not a gap in our reading. The accounts
are unaffected and there is nothing to approve here.

## 4. Approve

```sh
uv run python scripts/review.py PT17013 --approve
```

Until then the deal is cleaned but **unreviewed** -- nobody has confirmed
that any JUDGEMENT row means what it says.
