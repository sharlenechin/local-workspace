# PT18019 -- approval sheet

**WiZink**, PT. 31,699 loans, EUR 145,611,063.99.

Everything here is either settled by arithmetic or waiting on your judgement.
The sheet says which is which.

**Deal type: one-off.** ONE-OFF as Intrum underwrote it: a single PAM reference ending 0000, no monthly tranches, no FF segment label. A single tape CAN be the whole book here.

!! **This deal states NO CUT-OFF DATE.** The balances are as at whatever date
the seller struck the tape, and the tape does not say which. `find_cutoff.py`
reads the banner rows of every sheet looking for one; it found none here.
A figure from this deal cannot be dated.

## 1. What figure is this deal, and how far is it proven?

**The deal is `Balance.CutOff`.** It is mapped to `cutoff_balance`, and over the
31,699 in-scope loans it totals **EUR 145,611,063.99**. Every figure anyone
quotes for this book comes from that one column choice.

**Nothing on this tape is proven against a seller figure.** `find_strats` found
no published total to reconcile against, so this deal can reach `consistent`
and never `reconciled`.

What `consistent` means here: every column parsed, the ids behave, capital
never exceeds balance, and a re-run reproduces the file byte for byte. All
internal. If the seller's own number differs from EUR 145,611,063.99, nothing
in this pipeline would catch it.

**Your decision:** is that acceptable for this book, or should someone ask the
seller for a published total?

## 2. Do these mappings mean what they say?

Evidence: no data dictionary -- everything below is inference.

**No row is settled by arithmetic.** Nothing on this tape reconciles, so every
mapping below is inference and every one needs reading.

**7 row(s) to read.** Each is a column name we interpreted. Nothing
proves these mean what they say - that judgement is what you are signing.

`lands in` says which output carries the field: the fixed `core` every consumer
relies on, or `additional` - the open long table. Approving covers BOTH.

**Reject what is wrong, note what you want answered, then approve the rest:**

    review.py PT18019 --reject <field> "what is wrong"
    review.py PT18019 --note "anything not about one field"
    review.py PT18019 --approve        # signs off everything not rejected

| field | lands in | <- column | filled | sample | why this column |
|---|---|---|---:|---|---|
| `loan_id` | core | `account` | 31,699 (100%) | 0008424000900001034, 0008424000900 | the 19-digit account |
| `cutoff_balance` | core | `Balance.CutOff` | 31,699 (100%) | 1122.91, 988.38 | - |
| `cutoff_principal` | core | `Principal.CutOff` | 31,699 (100%) | 1050.52, 788.7 | - |
| `default_date` | core | `Default.Date` | 31,699 (100%) | 2018-06-22, 2018-01-11 | - |
| `product_type` | core | `Product.Type` | 31,699 (100%) | Credit Card, Rewrite | Credit Card (31,572) and Rewrite (127) |
| `segment` | core | `Perimeter` | 31,699 (100%) | Bankruptcy, Category 1 | Bankruptcy / Category 1 / Category 2 / Deceased |
| `insolvent_flag` | additional | `Perimeter` | 31,699 (100%) | False, True | Portugal has ONE insolvency regime (insolvencia, CIRE) and no separate bankruptcy proceeding, so a column named for ba... |

**Empty on this deal (17).** Either the tape does not carry the
fact, or it carries it somewhere we did not map. `CONTEXT.md` for this deal
separates the two, field by field:

`client_id`, `cutoff_date`, `cutoff_interest`, `cutoff_other_fee`, `origination_amount`, `origination_date`, `loan_holder_individual_flag`, `loan_holder_corporate_flag`, `borrower_type`, `claims_balance`, `insolvency_claims_balance`, `judicialised_flag`, `judicial_start_date`, `judicial_end_date`, `insolvency_start_date`, `insolvency_end_date`, `product_description`


---

**This sheet is the OUTSTANDING list and nothing else.** Every field this deal
produces - its source sheet and column, the transform, how full it is, an example
value and whether you have signed it - is in `cleaned_summary.md`, which is the
permanent record. When this deal is approved there is nothing left to read here.

## 3. Payments

| | |
|---|---:|
| Rows kept | 98,488 |
| Grain | one row per `loan_id` x month |
| Periods covered | 15 (the seller's own labels - NO calendar) |
| Gross | EUR 10,618,823.72 |
| Returns | EUR 3,654.07 |
| **Net collections** | **EUR 10,615,169.65** |

**Two things here are JUDGEMENTS, not arithmetic.** Both were inferred from
the data, and both move every figure above if they are wrong:

- **The key is `account`**, matched to `loan_id`. Chosen by VALUE OVERLAP, never by name: 31,699 values overlap `loan_id`.
- **The sign was left as the seller wrote it.** 98,470 of 98,488 non-zero values are positive (100.0%) -- collections are positive, nothing flipped

**Caveats on this file.** None of these is a defect; each is a thing a
reader could otherwise misread:

- the seller ships no separate RETURNS series. Refunds appear as negatives inside the payment series instead - EUR 3,654.07 of them (T48)
- 376,997 empty cell(s) dropped: the tape is WIDE (a column per month) and most cells are blank, so only months where money actually moved are kept (T34)
- the seller dates payments RELATIVE to the cut-off (`-12M`, `-1M`, `1M`...) and this deal has no cut-off date, so the labels are KEPT AS THEY ARE in `period` and `payment_month` is NULL. Nothing was translated; anchoring them needs a cut-off date from the seller
- 20,262 row(s) sit AFTER the cut-off (1M, 2M, 3M) - EUR 2,359,907.66 of INTERIM collections. KEPT deliberately: a tape is struck before the book registers, and these are the only record of what was paid in that gap. Filter on `period` when you want one side or the other
- 18 row(s) are NET NEGATIVE - a refund exceeding receipts in that month. Real, not an error

## 4. Approve

```sh
uv run python scripts/review.py PT18019 --approve
```

Until then the deal is cleaned but **unreviewed** -- nobody has confirmed
that any JUDGEMENT row means what it says.
