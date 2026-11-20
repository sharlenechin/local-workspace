# PT15018 -- approval sheet

**Millennium BCP**, PT. 32,529 loans, EUR 407,079,317.23.

Everything here is either settled by arithmetic or waiting on your judgement.
The sheet says which is which.

**Deal type: one-off.** ONE-OFF as Intrum underwrote it: a single PAM reference ending 0000, no monthly tranches, no FF segment label. A single tape CAN be the whole book here.

**As at 2015-09-30.** Everything below is the book on that date.

## 1. What figure is this deal, and how far is it proven?

**The deal is `Total OPB Setembro 2015 (€)`.** It is mapped to `cutoff_principal`, and over the
32,529 in-scope loans it totals **EUR 407,079,317.23**. Every figure anyone
quotes for this book comes from that one column choice.

!! **This deal has no TOTAL OWED.** `Total OPB Setembro 2015 (€)` is an outstanding PRINCIPAL,
mapped to `cutoff_principal`. The tape carries no interest and no fee column for this
population, so what the borrower must actually repay is not stated anywhere
and `cutoff_balance` is NULL by design, not by omission. Any figure quoted
from this deal is principal.

**Proven against the seller's own published figure, to the cent.**

**The column this deal uses:**

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `Total OPB Setembro 2015 (€)` | Collections | 407,079,317.23 | `Segmento != Excluded` |

**Other columns on this tape that ALSO reproduce a published figure.**
These are the alternatives. Picking one instead changes what this deal is:

| column | proven on | sum of the proven totals | scope rule |
|---|---|---:|---|
| `Interim Collections` | Collections | 1,569,865.11 | `Segmento != Excluded` |

**Your decision:** is `Total OPB Setembro 2015 (€)` the right measure, and is it as of the right
date? A balance can reconcile perfectly and still be the wrong month, or the
balance at write-off rather than the balance today.

## 2. What the engine decided

**891 row(s) left the book** before the 32,529 above were counted:

| rows | why |
|---:|---|
| 2 | dropped 2 row(s) carrying no amount and no date -- a header row or a stray, never a loan |
| 889 | Proceedings Legal: dropped 889 row(s) where `Tipo de Processo` is one of Insolvência, PER, Processo de Recuperação Judicial, Pré Insolvencia -- INSOLVENCY PROCEEDINGS ARE NOT JUDICIALISATION. This sheet holds every court file, and 889 of its 2,993 rows are insolvency (491), judicial recovery (388), PER (7) or pre-insolvency (3). Taking the earliest date on the sheet dated a loan's litigation from an insolvency filing, merging the two concepts the schema keeps apart. The seller labels each row itself, so this is its classification not ours. KEPT: Acao Executiva (1,330), Acao Declarativa (109) and the Reclamacao rows (401) - a claim lodged in court about this debt IS a court process, even when the proceeding is someone else's. Also kept: 260 rows typed `Not Available`, which cannot be classified and are not assumed to be insolvency. |

**Rows that stayed, but were built differently.** These loans ARE in the
32,529 above - nothing was dropped - but a field came from a second column:

| loans | what |
|---:|---|
| 2,797 | Proceedings Legal: reached 1,056 client(s) via `Participants Legal` on 2 participant column(s) (Numero de Cliente Interno (Interveniente), Numero de Cliente Interno); 2,104 row(s) on the sheet, 2,797 after the join -- one per participant per proceeding |
| 1,056 | Proceedings Legal: 2,797 participant-row(s) over 1,056 client(s) -- judicial_start_date=min; judicial_end_date=max if all closed |

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
| `Collections` | `Total OPB Setembro 2015 (€)` | 407,079,317.23 | `Segmento` != `Excluded` |
| `Collections` | `Interim Collections` | 1,569,865.11 | `Segmento` != `Excluded` |

2 published total(s) across 1 sheet(s).

## 4. Do these mappings mean what they say?

Evidence: no data dictionary -- everything below is inference.

**2 row(s) settled by arithmetic** - the column reproduces a published
figure exactly, so the only open question would be what it MEANS, and section 1
asks that: `cutoff_principal`, `segment`.

**14 row(s) to read.** Each is a column name we interpreted. Nothing
proves these mean what they say - that judgement is what you are signing.

`lands in` says which output carries the field: the fixed `core` every consumer
relies on, or `additional` - the open long table. Approving covers BOTH.

**Reject what is wrong, note what you want answered, then approve the rest:**

    review.py PT15018 --reject <field> "what is wrong"
    review.py PT15018 --note "anything not about one field"
    review.py PT15018 --approve        # signs off everything not rejected

| field | lands in | <- column | filled | sample | why this column |
|---|---|---|---:|---|---|
| `loan_id` | core | `Numero de Conta` | 32,586 (100%) | 10000001213, 10000010234 | ORIGINAL account number |
| `client_id` | core | `Cliente Number` | 32,692 (100%) | 100494870, 101375995 | the only id on this book that reaches prod (64%) |
| `product_type` | core | `Codigo Produto` | 32,692 (100%) | DDA, FAC | product CODE only on this sheet; the description comes from Claims |
| `insolvent_flag` | additional | `Segmento` (3 sheets) | 8,591 (26%) | True, False | LOAN level, and it beats the person-level `Involvente (Y/N)` rollup below (T16) |
| `claims_balance` | additional | `Valor em Divida (€)` | 673 (2%) | 3893.83, 780.0 | DOES NOT EQUAL cutoff_balance |
| `origination_amount` | core | `Montante de Capital Inicial` | 631 (2%) | 119711.5, 100000.0 | RAW |
| `origination_date` | core | `Data de Originação` | 615 (2%) | 2006-06-22, 2005-12-07 | - |
| `default_date` | core | `Data Vencido` | 631 (2%) | 2007-09-25, 2006-06-25 | null on ~59% |
| `loan_holder_individual_flag` | core | `Tipo de Cliente` | 409 true | derived from `borrower_type` | drives the two holder flags |
| `loan_holder_corporate_flag` | core | `Tipo de Cliente` | 304 true | derived from `borrower_type` | drives the two holder flags |
| `product_description` | additional | `Tipo de Operação` | 673 (2%) | Crédito hipotecário, Descobertos / | human-readable product name |
| `judicialised_flag` | additional | `Reclamado Judicialmente (Y/N)` (2 sheets) | 3,112 (10%) | True | PERSON level - joined on client_id and rolled up with max() |
| `judicial_start_date` | additional | `Data de Entrada em Tribunal` | 2,580 (8%) | 2007-06-11 00:00:00, 2009-07-17 00 | date the action was transferred to court |
| `judicial_end_date` | additional | `Data Fim Processo` | 511 (2%) | 2013-04-23 00:00:00, 2012-05-21 00 | date the proceeding closed |
| `insolvency_start_date` | additional | `Data de Insolvência` | 2,089 (6%) | 2012-10-11 00:00:00, 2006-01-17 00 | PERSON level |

**Empty on this deal (5).** Either the tape does not carry the
fact, or it carries it somewhere we did not map. `CONTEXT.md` for this deal
separates the two, field by field:

`cutoff_balance`, `cutoff_interest`, `cutoff_other_fee`, `insolvency_claims_balance`, `insolvency_end_date`


## 5. How this deal was assembled

These registry rows carry no field of their own. They decide WHICH LOANS
EXIST and which rows count - so they move every figure above, and none of
them is visible in the mappings.

| role | what it does | sheet | column | why |
|---|---|---|---|---|
| `filter` | DROPS ROWS from a sheet, using the seller's own label | `Proceedings Legal` | `Tipo de Processo` | INSOLVENCY PROCEEDINGS ARE NOT JUDICIALISATION. This sheet holds every court file, and 889 of its 2,993 rows are insolvency (491), judicial recovery (... |
| `link` | BRIDGES a keyless sheet to the book | `Participants Legal` | `Numero Interno de Processo` | THE BRIDGE. `Proceedings Legal` holds the court record keyed by PROCESS and carries no client or account at all. This sheet carries both the process n... |
| `grain` | COLLAPSES ROWS to one per loan | `nan` | `loan_id` | COLLAPSE: 79 accounts split by a DDA->OCV migration; their balances are parts of one loan |

**Read these first.** A wrong `scope` or `filter` row removes real loans and
every total below still reconciles - the arithmetic cannot see a loan that
was never there.


---

**This sheet is the OUTSTANDING list and nothing else.** Every field this deal
produces - its source sheet and column, the transform, how full it is, an example
value and whether you have signed it - is in `cleaned_summary.md`, which is the
permanent record. When this deal is approved there is nothing left to read here.

## 6. Payments

| | |
|---|---:|
| Rows kept | 4,053 |
| Grain | one row per `client_id` x month |
| Months covered | 26 |
| Gross | EUR 13,937,342.88 |
| Returns | EUR 0.00 |
| **Net collections** | **EUR 13,937,342.88** |

**Two things here are JUDGEMENTS, not arithmetic.** Both were inferred from
the data, and both move every figure above if they are wrong:

- **The key is `Cliente Number`**, matched to `client_id`. Chosen by VALUE OVERLAP, never by name: 17,944 values overlap `client_id`.
- **The sign was left as the seller wrote it.** 4,257 of 4,257 non-zero values are positive (100.0%) -- collections are positive, nothing flipped

**Caveats on this file.** None of these is a defect; each is a thing a
reader could otherwise misread:

- 2 key(s) hold BOTH in- and out-of-scope loans, EUR 16.52 - kept in full, because splitting a payment between them would be an allocation nobody can defend
- the seller ships no separate RETURNS series. No refunds appear anywhere on this tape, so net equals gross
- 462,491 empty cell(s) dropped: the tape is WIDE (a column per month) and most cells are blank, so only months where money actually moved are kept (T34)

## 7. Approve

```sh
uv run python scripts/review.py PT15018 --approve
```

Until then the deal is cleaned but **unreviewed** -- nobody has confirmed
that any JUDGEMENT row means what it says.
