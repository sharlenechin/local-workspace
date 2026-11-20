# PT15020 -- approval sheet

**Oney**, PT. 5,313 loans, EUR 1,850,682.30.

Everything here is either settled by arithmetic or waiting on your judgement.
The sheet says which is which.

**Deal type: one-off.** ONE-OFF as Intrum underwrote it: a single PAM reference ending 0000, no monthly tranches, no FF segment label. A single tape CAN be the whole book here.

!! **This deal states NO CUT-OFF DATE.** The balances are as at whatever date
the seller struck the tape, and the tape does not say which. `find_cutoff.py`
reads the banner rows of every sheet looking for one; it found none here.
A figure from this deal cannot be dated.

## 1. What figure is this deal, and how far is it proven?

**The deal is `Saldo Total`.** It is mapped to `cutoff_balance`, and over the
5,313 in-scope loans it totals **EUR 1,850,682.30**. Every figure anyone
quotes for this book comes from that one column choice.

**Proven against the seller's own published figure, to the cent.**

**The column this deal uses:**

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `Saldo Total` | asset-index with interest | 1,850,682.30 | none |

**Other columns on this tape that ALSO reproduce a published figure.**
These are the alternatives. Picking one instead changes what this deal is:

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `Encours_contabilistico` | ANEXO_I_DADOS | 1,339,500.46 | none |
| `Juros (interests)` | asset-index with interest | 511,181.84 | none |

**Your decision:** is `Saldo Total` the right measure, and is it as of the right
date? A balance can reconcile perfectly and still be the wrong month, or the
balance at write-off rather than the balance today.

## 2. What the engine decided

**2 row(s) left the book** before the 5,313 above were counted:

| rows | why |
|---:|---|
| 2 | excluded 2 published TOTAL row(s) from 2 sheet(s) -- proven sums, not loans |

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
| `ANEXO_I_DADOS` | `Encours_contabilistico` | 1,339,500.46 | whole sheet |
| `asset-index with interest` | `Saldo Total` | 1,850,682.30 | whole sheet |
| `asset-index with interest` | `Juros (interests)` | 511,181.84 | whole sheet |

3 published total(s) across 2 sheet(s).

## 4. Do these mappings mean what they say?

Evidence: no data dictionary -- everything below is inference.

**2 row(s) settled by arithmetic** - the column reproduces a published
figure exactly, so the only open question would be what it MEANS, and section 1
asks that: `cutoff_balance`, `cutoff_interest`.

**10 row(s) to read.** Each is a column name we interpreted. Nothing
proves these mean what they say - that judgement is what you are signing.

`lands in` says which output carries the field: the fixed `core` every consumer
relies on, or `additional` - the open long table. Approving covers BOTH.

**Reject what is wrong, note what you want answered, then approve the rest:**

    review.py PT15020 --reject <field> "what is wrong"
    review.py PT15020 --note "anything not about one field"
    review.py PT15020 --approve        # signs off everything not rejected

| field | lands in | <- column | filled | sample | why this column |
|---|---|---|---:|---|---|
| `loan_id` | core | `Contrato` | 5,313 (100%) | 100000161, 100000544 | 5,313 distinct over 5,313 rows |
| `client_id` | core | `nif` | 5,313 (100%) | 175920761, 177074850 | the tax number |
| `product_type` | core | `Produto` | 5,313 (100%) | PPR, CRT | CRT and PPR only |
| `segment` | core | `FaseRecup` | 5,313 (100%) | PRC, CON | PRC / CON |
| `origination_date` | core | `Data_Contrato` | 5,313 (100%) | 2006-01-05, 2005-12-05 | yyyymmdd as text |
| `default_date` | core | `Data_entrada` | 5,313 (100%) | 2013-12-30, 2013-10-29 | entry into pre-litigation |
| `cutoff_principal` | core | `Saldo_Contabilistico` | 5,313 (100%) | 271.3, 278.81 | Encours_contabilistico |
| `judicialised_flag` | additional | `FaseRecup` | 5,313 (100%) | False, True | THE TAPE CONTRADICTS ITSELF ON THIS LOAN: the second sheet `asset-index with interest` carries `Fase_Recuperacao` = Pr... |
| `loan_holder_individual_flag` | core | `nif` | 5,313 (100%) | True | INFERRED FROM THE TAX NUMBER, because this tape carries no customer-type column |
| `loan_holder_corporate_flag` | core | `nif` | 5,313 (100%) | False | The same NIF rule, inverted: a company NIF begins 5 (or 6/7/9 for other entity types) |

**Empty on this deal (12).** Either the tape does not carry the
fact, or it carries it somewhere we did not map. `CONTEXT.md` for this deal
separates the two, field by field:

`cutoff_date`, `cutoff_other_fee`, `origination_amount`, `borrower_type`, `claims_balance`, `insolvency_claims_balance`, `judicial_start_date`, `judicial_end_date`, `insolvent_flag`, `insolvency_start_date`, `insolvency_end_date`, `product_description`


---

**This sheet is the OUTSTANDING list and nothing else.** Every field this deal
produces - its source sheet and column, the transform, how full it is, an example
value and whether you have signed it - is in `cleaned_summary.md`, which is the
permanent record. When this deal is approved there is nothing left to read here.

## 5. Payments

This tape carries **no payment columns at all**, so no payments file was
written. That is the seller's tape, not a gap in our reading. The accounts
are unaffected and there is nothing to approve here.

## 6. Approve

**APPROVED** by sharlene on 2026-10-13 12:32.

The signature covers the output file as it stands now (`f410a7548310`).

Re-approving is not needed and not possible without a change: if the output
moves, this line turns to APPROVED-STALE and the deal must be reviewed again.

    uv run python scripts/verify.py PT15020
