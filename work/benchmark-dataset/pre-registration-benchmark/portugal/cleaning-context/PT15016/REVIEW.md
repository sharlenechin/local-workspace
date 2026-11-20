# PT15016 -- approval sheet

**Barclays**, PT. 3,958 loans, EUR 14,942,413.07.

Everything here is either settled by arithmetic or waiting on your judgement.
The sheet says which is which.

**Deal type: one-off.** ONE-OFF as Intrum underwrote it: a single PAM reference ending 0000, no monthly tranches, no FF segment label. A single tape CAN be the whole book here.

!! **This deal states NO CUT-OFF DATE.** The balances are as at whatever date
the seller struck the tape, and the tape does not say which. `find_cutoff.py`
reads the banner rows of every sheet looking for one; it found none here.
A figure from this deal cannot be dated.

## 1. What figure is this deal, and how far is it proven?

**The deal is `curr_bal`.** It is mapped to `cutoff_balance`, and over the
3,958 in-scope loans it totals **EUR 14,942,413.07**. Every figure anyone
quotes for this book comes from that one column choice.

**Proven against the seller's own published figure, to the cent.**

**Other columns on this tape that ALSO reproduce a published figure.**
These are the alternatives. Picking one instead changes what this deal is:

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `woff_bal` | WOFF_MASTER_201510 | 14,949,117.19 | none |

**Your decision:** is `curr_bal` the right measure, and is it as of the right
date? A balance can reconcile perfectly and still be the wrong month, or the
balance at write-off rather than the balance today.

## 2. What the engine decided

**1 row(s) left the book** before the 3,958 above were counted:

| rows | why |
|---:|---|
| 1 | excluded 1 published TOTAL row(s) from 1 sheet(s) -- proven sums, not loans |

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
| `WOFF_MASTER_201510` | `woff_bal` | 14,949,117.19 | whole sheet |

1 published total(s) across 1 sheet(s).

## 4. Do these mappings mean what they say?

Evidence: no data dictionary -- everything below is inference.

**No row is settled by arithmetic.** Nothing on this tape reconciles, so every
mapping below is inference and every one needs reading.

**9 row(s) to read.** Each is a column name we interpreted. Nothing
proves these mean what they say - that judgement is what you are signing.

`lands in` says which output carries the field: the fixed `core` every consumer
relies on, or `additional` - the open long table. Approving covers BOTH.

**Reject what is wrong, note what you want answered, then approve the rest:**

    review.py PT15016 --reject <field> "what is wrong"
    review.py PT15016 --note "anything not about one field"
    review.py PT15016 --approve        # signs off everything not rejected

| field | lands in | <- column | filled | sample | why this column |
|---|---|---|---:|---|---|
| `loan_id` | core | `acct` | 3,958 (100%) | 0004064740080003334, 0004064740080 | the 19-digit account, 3,958 distinct |
| `cutoff_balance` | core | `curr_bal` | 3,958 (100%) | 8302.66, 690.12 | COST OF THIS CHOICE: the seller published a total for woff_bal (14,949,117.19) and not for curr_bal, so this deal drop... |
| `cutoff_principal` | core | `sum_prin` | 3,958 (100%) | 5758.13, 486.45 | - |
| `cutoff_interest` | core | `sum_int` | 3,958 (100%) | 1864.16, 90.35 | interest ALONE |
| `cutoff_other_fee` | core | `sum_fee` | 3,958 (100%) | 680.37, 113.32 | EUR 3,007,870.65 of fees, costs and charges - owed at cut-off, neither principal nor interest |
| `origination_date` | core | `date_opened` | 3,958 (100%) | 2004-04-16, 2004-04-22 | - |
| `default_date` | core | `date_cgoff` | 3,958 (100%) | 2014-08-08, 2014-09-10 | charge-off date, 2014-2015 |
| `product_type` | core | `lb_description` | 3,958 (100%) | Barclaycard Classic, Barclaycard G | Barclaycard Classic / Gold and five more |
| `segment` | core | `segment` | 3,958 (100%) | PRM, ECS | PRM / ECS |

**Empty on this deal (15).** Either the tape does not carry the
fact, or it carries it somewhere we did not map. `CONTEXT.md` for this deal
separates the two, field by field:

`client_id`, `cutoff_date`, `origination_amount`, `loan_holder_individual_flag`, `loan_holder_corporate_flag`, `borrower_type`, `claims_balance`, `insolvency_claims_balance`, `judicialised_flag`, `judicial_start_date`, `judicial_end_date`, `insolvent_flag`, `insolvency_start_date`, `insolvency_end_date`, `product_description`


---

**This sheet is the OUTSTANDING list and nothing else.** Every field this deal
produces - its source sheet and column, the transform, how full it is, an example
value and whether you have signed it - is in `cleaned_summary.md`, which is the
permanent record. When this deal is approved there is nothing left to read here.

## 5. Payments

| | |
|---|---:|
| Rows kept | 218 |
| Grain | one row per `loan_id` x month |
| Months covered | 12 |
| Gross | EUR 16,842.19 |
| Returns | EUR 85.00 |
| **Net collections** | **EUR 16,757.19** |

**Two things here are JUDGEMENTS, not arithmetic.** Both were inferred from
the data, and both move every figure above if they are wrong:

- **The key is `acct`**, matched to `loan_id`. Chosen by VALUE OVERLAP, never by name: 3,958 values overlap `loan_id`.
- **The sign was left as the seller wrote it.** 218 of 218 non-zero values are positive (100.0%) -- collections are positive, nothing flipped

**Caveats on this file.** None of these is a defect; each is a thing a
reader could otherwise misread:

- 47,278 empty cell(s) dropped: the tape is WIDE (a column per month) and most cells are blank, so only months where money actually moved are kept (T34)
- 1 row(s) are NET NEGATIVE - a refund exceeding receipts in that month. Real, not an error

## 6. Approve

```sh
uv run python scripts/review.py PT15016 --approve
```

Until then the deal is cleaned but **unreviewed** -- nobody has confirmed
that any JUDGEMENT row means what it says.
