# PT16023 -- approval sheet

**Millennium BCP**, PT. 19,434 loans, EUR 224,485,808.25.

Everything here is either settled by arithmetic or waiting on your judgement.
The sheet says which is which.

**Deal type: one-off.** ONE-OFF as Intrum underwrote it: a single PAM reference ending 0000, no monthly tranches, no FF segment label. A single tape CAN be the whole book here.

**As at 2016-09-30.** Everything below is the book on that date.

## 1. What figure is this deal, and how far is it proven?

**The deal is `OB (€)`.** It is mapped to `cutoff_balance`, and over the
19,434 in-scope loans it totals **EUR 224,485,808.25**. Every figure anyone
quotes for this book comes from that one column choice.

**Proven against the seller's own published figure, to the cent.**

**The column this deal uses:**

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `OB (€)` | Masterdatatape_NBO | 304,819,500.79 | `Type of Client != Company, none` |

**Other columns on this tape that ALSO reproduce a published figure.**
These are the alternatives. Picking one instead changes what this deal is:

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `August 2016` | Masterdatatape_NBO | 108,476.75 | `Type of Client != Company` |
| `July 2016` | Masterdatatape_NBO | 145,253.77 | `Type of Client != Company` |
| `June 2016` | Masterdatatape_NBO | 126,457.45 | `Type of Client != Company` |
| `May 2016` | Masterdatatape_NBO | 142,476.05 | `Type of Client != Company` |
| `UPB (€)` | Masterdatatape_NBO | 299,421,353.43 | `Type of Client != Company, none` |

**Your decision:** is `OB (€)` the right measure, and is it as of the right
date? A balance can reconcile perfectly and still be the wrong month, or the
balance at write-off rather than the balance today.

## 2. What the seller published

Printed on the tape by the seller - this is what the arithmetic above
reconciles against. Read it to judge whether the figure this deal reports
is the QUANTITY you want.

| sheet | column the seller totalled | their total | scope they applied |
|---|---|---:|---|
| `Masterdatatape_NBO` | `OB (€)` | 224,485,808.25 | whole sheet |
| `Masterdatatape_NBO` | `UPB (€)` | 219,753,165.09 | whole sheet |
| `Masterdatatape_NBO` | `OB (€)` | 80,333,692.54 | `Type of Client` != `Company` |
| `Masterdatatape_NBO` | `UPB (€)` | 79,668,188.34 | `Type of Client` != `Company` |
| `Masterdatatape_NBO` | `July 2016` | 145,253.77 | `Type of Client` != `Company` |
| `Masterdatatape_NBO` | `May 2016` | 142,476.05 | `Type of Client` != `Company` |
| `Masterdatatape_NBO` | `June 2016` | 126,457.45 | `Type of Client` != `Company` |
| `Masterdatatape_NBO` | `August 2016` | 108,476.75 | `Type of Client` != `Company` |

8 published total(s) across 1 sheet(s).

## 3. Do these mappings mean what they say?

Evidence: no data dictionary -- everything below is inference.

**2 row(s) settled by arithmetic** - the column reproduces a published
figure exactly, so the only open question would be what it MEANS, and section 1
asks that: `cutoff_balance`, `cutoff_principal`.

**9 row(s) to read.** Each is a column name we interpreted. Nothing
proves these mean what they say - that judgement is what you are signing.

`lands in` says which output carries the field: the fixed `core` every consumer
relies on, or `additional` - the open long table. Approving covers BOTH.

**Reject what is wrong, note what you want answered, then approve the rest:**

    review.py PT16023 --reject <field> "what is wrong"
    review.py PT16023 --note "anything not about one field"
    review.py PT16023 --approve        # signs off everything not rejected

| field | lands in | <- column | filled | sample | why this column |
|---|---|---|---:|---|---|
| `loan_id` | core | `COMP_OPER_PROD (Unique Loan ID)` | 19,431 (100%) | 0_0_CCJ, 0_0_CMC | NOT UNIQUE DESPITE THE NAME (T19): 1,877 rows share 723 ids, EUR 22,713,253.39 (10.1%), and one id spans different cli... |
| `client_id` | core | `Client Number` | 19,434 (100%) | 21831633, 20780066 | - |
| `segment` | core | `Sub-Portfolio` | 19,434 (100%) | Portfolio II, Portfolio III | Portfolio I/II/III -- the strats cut |
| `product_type` | core | `Product Type` | 19,434 (100%) | Overdraft/ C.A., Other Past Due Lo | the product NAME (Overdraft/ C.A., Leasing) -- 12 distinct |
| `loan_holder_individual_flag` | core | `Type of Client` | 13,599 true | derived from `borrower_type` | Company / Individual |
| `loan_holder_corporate_flag` | core | `Type of Client` | 7,142 true | derived from `borrower_type` | Company / Individual |
| `default_date` | core | `Delinquency Date` | 16,716 (86%) | 2007-01-01, 2012-03-01 | EXCEL SERIALS (42402), not dates |
| `judicialised_flag` | additional | `Judicialized?` | 19,434 (100%) | False, True | LOAN level on this tape, not person level as on PT15018 |
| `insolvent_flag` | additional | `Insolvent? (Y/N)` | 19,434 (100%) | False, True | LOAN level on this tape -- T16: the finer grain wins, no rollup needed |
| `insolvency_start_date` | additional | `Insolvency Date` | 7,818 (40%) | 2014-01-27 00:00:00, 2013-10-31 00 | Excel serials (41968), same as Delinquency Date -- T14 |

**Empty on this deal (10).** Either the tape does not carry the
fact, or it carries it somewhere we did not map. `CONTEXT.md` for this deal
separates the two, field by field:

`cutoff_interest`, `cutoff_other_fee`, `origination_amount`, `origination_date`, `claims_balance`, `insolvency_claims_balance`, `judicial_start_date`, `judicial_end_date`, `insolvency_end_date`, `product_description`


---

**This sheet is the OUTSTANDING list and nothing else.** Every field this deal
produces - its source sheet and column, the transform, how full it is, an example
value and whether you have signed it - is in `cleaned_summary.md`, which is the
permanent record. When this deal is approved there is nothing left to read here.

## 4. Payments

| | |
|---|---:|
| Rows kept | 6,153 |
| Grain | one row per `client_id` x month |
| Months covered | 32 |
| Gross | EUR 6,033,603.62 |
| Returns | EUR 0.00 |
| **Net collections** | **EUR 6,033,603.62** |

**Two things here are JUDGEMENTS, not arithmetic.** Both were inferred from
the data, and both move every figure above if they are wrong:

- **The key is `Client Number`**, matched to `client_id`. Chosen by VALUE OVERLAP, never by name: 11,064 values overlap `client_id`.
- **The sign was left as the seller wrote it.** 6,816 of 6,816 non-zero values are positive (100.0%) -- collections are positive, nothing flipped

**Caveats on this file.** None of these is a defect; each is a thing a
reader could otherwise misread:

- the seller ships no separate RETURNS series. No refunds appear anywhere on this tape, so net equals gross
- 347,895 empty cell(s) dropped: the tape is WIDE (a column per month) and most cells are blank, so only months where money actually moved are kept (T34)

## 5. Approve

**APPROVED** by sharlene on 2026-10-13 12:09.

The signature covers the output file as it stands now (`fc904f5f4c7f`).

Re-approving is not needed and not possible without a change: if the output
moves, this line turns to APPROVED-STALE and the deal must be reviewed again.

    uv run python scripts/verify.py PT16023
