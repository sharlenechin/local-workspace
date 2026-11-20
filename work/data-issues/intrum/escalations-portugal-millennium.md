# What to raise with Intrum — Portugal / Millennium feeds

**For:** product manager, to forward to Intrum
**Scope:** 14 PAM batches, Portugal / Millennium (BCP), Intrum instance 4050, 120,713 loans
**Feeds compared:** CAT (loan level) vs PAM (batch × month), both from Intrum
**Measured:** 2026-09-10, against the raw feeds, read-only

Reconciling Intrum's two feeds against each other turned up five things only
Intrum can answer — from a batch that reports EUR 660,000.00 of collections
with no loans behind it, to EUR 6,831,847.76 riding on loans whose batch
reference has been wiped. Everything below is measured, not inferred.

CAT figures exclude February–July 2026 on **both** sides of every comparison,
so the delivery lag in item 4 cannot flatter any ratio quoted here.

---

## Raise with Intrum

### 1. Three batches Intrum reports collections for have no money in the loan-level feed

PAM reports collections for three batches that the CAT feed cannot account for
at all — EUR 1,130,420.97 between them. For `PT06014B010000` this is not a
filtering artefact: asked with no source-system filter at all, no Intrum
instance holds a single case for that batch reference.

| Batch | PAM collections | CAT loans | CAT payments | Still collecting? |
|---|---|---|---|---|
| PT06014B010000 | EUR 660,000.00 | 0 (in any instance) | none | no |
| PT070040000000 | EUR 340,000.00 | 2 | none — neither loan has ever paid | no |
| PT15018A040000 | EUR 130,420.97 | 0 (see item 2) | none | **yes — paid in 5 of the last 7 months** |

PT15018A040000 is the pointed one: PAM booked collections against it in five of
the seven months to July 2026, so this is a live book producing cash today,
not a dormant historical batch — and CAT holds no loans for it at all.

**Two of the three are not collections at all — PAM's own numbers show it**
(measured 2026-09-10). On both `PT070040000000` and `PT06014B010000`, the
reported `COLLTOTAL` equals that batch's `ACQUISITIONPRINCIPAL` to the cent,
posted once, in the capex month:

| Batch | Capex month | COLLTOTAL | ACQUISITIONPRINCIPAL | PAM months | Collecting months |
|---|---|---|---|---|---|
| PT070040000000 | 2007-04 | 340,000.00 | 340,000.00 | 375 | 1 |
| PT06014B010000 | 2006-12 | 660,000.00 | 660,000.00 | 379 | 1 |

Each therefore reads as having recovered exactly 100% of principal in month
zero and nothing in the ~31 years since. The other twelve Portugal/Millennium
batches collect across 106–253 months each — roughly 2,500 collecting months
between them — and not one ever posts a month equal to its acquisition
principal. The pattern is unique to these two, which rules out coincidence:
this is acquisition principal booked into the collections column, not cash.

**Consequence for us:** the EUR 1,000,000.00 across those two batches must not
be counted as collections. Both are excluded from `accounts.sql` and
`payments.sql` via `$exclude_batches`. `PT15018A040000` is different — 106
collecting months and EUR 130,420.97 against EUR 18,551,110.00 of acquisition
principal, which is a real if poorly-performing book.

**Ask Intrum:** (a) confirm that the single capex-month entry on
`PT070040000000` and `PT06014B010000` is an opening or adjustment posting
rather than cash, and correct the feed if so; (b) which loans sit behind all
three batches, and why does the CAT extract carry no payments for them when
PAM reports money against each?

### 2. PAM and CAT disagree about which batch owns 84 loans

PAM reports 106 months of collections against `PT15018A040000`. In CAT, the
newest version of all 84 of that batch's loans names a different batch,
`PT16023C000000`. One feed bills the money to one batch, the other bills the
loans to another, so per-batch performance for both is wrong.

| | |
|---|---|
| PAM collections, PT15018A040000 | EUR 130,420.97 |
| CAT loans still naming that batch | 0 of 84 |
| Their CAT payments, now billed to PT16023C000000 | EUR 11,955.29 |

**Ask Intrum:** which batch owns these 84 loans, and was the reassignment to
PT16023C000000 intentional? If so, why does PAM still report collections under
the old batch?

### 3. 12% of one batch's loans have had their batch reference wiped

On `PT15018G000000`, the newest CAT version of 2,173 loans carries an **empty
batch reference and an empty seller name**. They still carry EUR 6.83m of
payments, which we currently attribute using the last version that named a
batch — a workaround, not a fact.

Closure does not explain it. Every other batch closes loans in bulk and none
lose their reference: `PT050030000000` has 10,332 closed loans, all still
labelled. The wiping is specific to this one batch — which is also the one
batch whose CAT-to-PAM reconciliation does not close.

| | |
|---|---|
| Loans with a wiped reference | 2,173 of 17,943 (12.1%) |
| Payments riding on them | EUR 6,831,847.76 |
| Comparable wiping across the other 11 batches | 1 loan |
| This batch's unexplained CAT-over-PAM gap | ~EUR 362,000 (+1.30%) |

**Ask Intrum:** why has the batch reference been cleared on these loans, are
they still part of PT15018G000000, and does PAM still report their collections
under it?

### 4. The loan-level feed is six months behind the batch-level one

CAT's most recent payment is dated 2026-01-14. PAM's newest delivery reports
actuals through 2026-07. For lifetime work the gap is immaterial; for anything
current it is fatal, because the book is in run-off and the missing months are
the ones carrying the trend.

| | |
|---|---|
| Last payment in CAT | 2026-01-14 |
| PAM actuals through | 2026-07 |
| Collections CAT cannot see | EUR 1,946,151.11 |
| As a share of 2025 collections | 54% |
| As a share of the 21-year lifetime | 1.20% |

The gap falls almost entirely on the two 2016 books — 72% of it — but that is
run-off, not a fault: measured against each batch's own trailing twelve months,
every batch is missing between 0.24 and 0.74 of a year's collections, clustered
near half. Seven reporting months are excluded (2026-01 to 2026-07), because
CAT's January is a half month and the comparison closes at the last complete
CAT month.

**Ask Intrum:** what is the intended delivery cadence for the loan-level CAT
extract, and can it be brought in line with PAM? A six-month lag makes
loan-level analysis of the current book impossible.

### 5. Payments arrive with no payment date, in any version of the record

A transaction is delivered many times and some versions carry a date while
others do not, so we already recover the date across every version — that
alone rescues about EUR 53m. What is left has **no date in any version**: real
money that cannot be placed in a month, so it cannot enter a collection curve,
a vintage or any period comparison.

| | |
|---|---|
| Payments with no date anywhere | 16,551 (3.1%) |
| Money affected | EUR 5,450,225.84 |
| Loans affected | 6,090 |
| Where it lands hardest | the pre-2010 batches |

**Ask Intrum:** can transaction dates be supplied for these 16,551 payments?
They are the single largest reason our loan-level collections do not tie to
PAM month by month.

---

## Confirm, then close

Probably routine, but we are carrying an assumption on each, and a one-line
answer retires it.

### 6. 139 loans now sit under a Swiss Intrum entity

Spread across 11 of the 12 batches, 139 loans have moved in CAT to batch
`PT24004B000000` with seller name `INTRUM INVESTMENT SWITZER`, 138 of them with
a closing date. We read that as an onward sale and exclude them from the
Millennium scope. If it is anything else, our per-batch loan counts are wrong.

**Ask Intrum:** confirm these 139 loans left the Millennium books, and when.
If they were sold on, is that reflected in what PAM reports for the
originating batches?

### 7. Payment rows with no amount pass Intrum's own payment filter, on every batch

Rows flagged as payments but carrying a null amount and null currency. We
exclude them so they cannot create zero-value payment dates, so money is
unaffected — but any *payment count* taken from this feed without that
exclusion is overstated.

| | |
|---|---|
| Loans carrying such a row | 43,658 across all 12 batches |
| Largest single batch | PT050030000000, 11,418 (one per loan, 2012–2016) |
| Money affected | none |

**Ask Intrum:** what are these amount-less payment rows, and should they carry
the payment indicator at all?

---

## Ours, not Intrum's

Real problems, but on our side of the boundary. For the data team.

### Our warehouse holds 42% of this scope's collections

Collections in `FCT_CASE_COLLECTION` are inner-joined to the case history on
transaction date, and the first case version begins when Intrum's platform took
the case on — 2014-10-10 for these books, nine years after registration. Every
payment before that is dropped silently. Intrum sends the money; our model
discards it. Lifetime questions therefore have to be answered from the raw
feed, which is why this review reads raw at all.

### The shared dedupe key drops payments with a missing original transaction id

The key concatenates fields, and a concatenation containing a null returns
null — so every such payment collapses into one group and all but one is
discarded. We deliberately match the existing model so our figures agree with
the warehouse, but it is the likeliest cause of the small, consistent shortfall
on the nine pre-2010 batches. Untested.

---

## Checked and clean

Three things that looked like they were losing data and are not. Recorded so
nobody re-opens them.

- **Pinning to source system 4050 hides nothing.** Case ids repeat across
  Intrum instances, so our queries pin to one. Asked with no instance filter at
  all, 4050 is the only system holding any of these 14 batch references —
  17,841,296 history rows, 13 of 14 batches, one row in the result. The pin
  buys correctness and query cost for no loss of coverage.
- **Keeping only each loan's newest version drops no loan.** The batch filter
  runs before the deduplication, so ranking happens only among versions naming
  a batch in scope — a loan that has since left keeps its last in-scope batch
  instead of vanishing. Reversing those two steps would silently drop 2,313
  loans and EUR 6,856,071.22 of collections PAM still reports.
- **The batch-mixing theory is dead.** We suspected CAT was crediting
  PT15018A040000's loans to its sibling PT15018G000000, which would have
  explained a third of that batch's unexplained overage. Measured: they go to
  PT16023C000000 instead, carrying EUR 11,955.29. It explains none of it. The
  wiped references in item 3 are now the leading candidate.

---

## Per-batch impact matrix

Every batch, every issue, measured 2026-09-10. Reproduce with
`mise run sql -- work/.archive/2026-10-02-benchmark-investigation-trail/batch_impact_matrix.sql`.

### A. Where each batch stands

`RESIDUAL` is the figure to quote: CAT's period-matched collections plus its
undated cash, against PAM for the same months. `MATCH RATIO` excludes the
undated cash, which is why the pre-2010 books look far worse on the ratio than
they are — PT08018B000000 is the clearest case, worst ratio of all fourteen and
the smallest residual.

| Batch | Capex | Loans in CAT | PAM lifetime | CAT matched | PAM matched | Match ratio | Residual | Residual % |
|---|---|---|---|---|---|---|---|---|
| PT050030000000 | 2005-06 | 28,444 | 12,150,023.20 | 10,995,458.69 | 12,098,842.44 | 0.90880 | −66,185.74 | −0.547% |
| PT05007C000000 | 2005-09 | 9,785 | 22,624,643.59 | 21,780,303.63 | 22,545,240.90 | 0.96607 | −61,478.72 | −0.273% |
| PT06002B000000 | 2006-03 | 11,141 | 12,380,822.21 | 11,813,828.78 | 12,346,715.48 | 0.95684 | −88,724.34 | −0.719% |
| PT06014B000000 | 2006-12 | 9,514 | 18,115,823.68 | 17,319,757.43 | 18,015,065.25 | 0.96140 | −105,969.67 | −0.588% |
| **PT06014B010000** | 2006-12 | **0** | 660,000.00 | 0.00 | 660,000.00 | — | **−660,000.00** | **−100%** |
| **PT070040000000** | 2007-04 | 2 | 340,000.00 | 0.00 | 340,000.00 | — | **−340,000.00** | **−100%** |
| PT07007C000000 | 2007-06 | 7,414 | 10,867,251.22 | 10,217,977.85 | 10,803,118.12 | 0.94584 | −103,996.16 | −0.963% |
| PT07010C000000 | 2007-11 | 2,940 | 5,448,802.75 | 5,141,248.03 | 5,405,253.85 | 0.95116 | −66,693.36 | −1.234% |
| PT08010C000000 | 2008-06 | 8,822 | 10,031,583.11 | 9,403,871.18 | 9,965,692.89 | 0.94362 | −91,771.79 | −0.921% |
| PT08018B000000 | 2008-09 | 10,923 | 11,435,435.25 | 10,181,841.13 | 11,375,171.02 | 0.89509 | −10,081.84 | −0.089% |
| PT09006D000000 | 2009-06 | 3,532 | 4,027,540.03 | 3,615,277.99 | 3,990,692.34 | 0.90593 | −31,100.12 | −0.779% |
| **PT15018G000000** | 2016-03 | 17,943 | 34,323,780.86 | 34,051,806.66 | 33,616,121.43 | 1.01296 | **+435,685.23** | **+1.296%** |
| **PT15018A040000** | 2016-11 | **0** | 130,420.97 | 0.00 | 126,093.94 | — | **−126,093.94** | **−100%** |
| PT16023C000000 | 2016-12 | 10,253 | 19,016,781.64 | 18,595,793.51 | 18,318,749.74 | 1.01512 | +277,043.77 | +1.512% |

Nine pre-2010 batches total −626,001.74 (−0.59%), every one of them slightly
under. The two 2016 batches total +712,729.00, both over. Those two sums are
reproduced to the cent by an independently built query, `pam_cat_match.sql`.

### B. Which issue touches which batch

| Batch | No CAT money | Batch dispute | 6m lag | 6m lag EUR | Undated | Undated EUR | Pre-capex EUR | Wiped ref | Wiped loans | Wiped EUR | Sold on | Amount-less loans |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| PT050030000000 | – | – | Y | 51,180.76 | Y | 1,037,198.01 | 0.00 | – | 0 | 0.00 | 52 | 11,418 |
| PT05007C000000 | – | – | Y | 79,402.69 | Y | 703,458.55 | 0.00 | – | 0 | 0.00 | 5 | 4,906 |
| PT06002B000000 | – | – | Y | 34,106.73 | Y | 444,162.36 | 750.00 | Y | 1 | 0.00 | 7 | 3,390 |
| PT06014B000000 | – | – | Y | 100,758.43 | Y | 589,338.15 | 1,163.21 | – | 0 | 0.00 | 7 | 4,226 |
| PT06014B010000 | **Y** | – | – | 0.00 | – | 0.00 | 0.00 | – | 0 | 0.00 | 0 | 0 |
| PT070040000000 | **Y** | – | – | 0.00 | – | 0.00 | 0.00 | – | 0 | 0.00 | 0 | 0 |
| PT07007C000000 | – | – | Y | 64,133.10 | Y | 481,144.11 | 0.00 | – | 0 | 0.00 | 12 | 3,318 |
| PT07010C000000 | – | – | Y | 43,548.90 | Y | 197,312.46 | 0.00 | – | 0 | 0.00 | 3 | 1,384 |
| PT08010C000000 | – | – | Y | 65,890.22 | Y | 470,049.92 | 0.00 | – | 0 | 0.00 | 7 | 4,038 |
| PT08018B000000 | – | – | Y | 60,264.23 | Y | 1,183,248.05 | 104.53 | – | 0 | 0.00 | 11 | 5,141 |
| PT09006D000000 | – | – | Y | 36,847.69 | Y | 344,314.23 | 95.30 | – | 0 | 0.00 | 3 | 1,553 |
| PT15018G000000 | – | – | Y | 707,659.43 | – | 0.00 | 1,571,494.31 | **Y** | **2,173** | **6,831,847.76** | 25 | 3,155 |
| PT15018A040000 | **Y** | **Y** | Y | 4,327.03 | – | 0.00 | 0.00 | – | 0 | 0.00 | 0 | 0 |
| PT16023C000000 | – | – | Y | 698,031.90 | – | 0.00 | 0.00 | – | 0 | 0.00 | 7 | 1,129 |

Reading the columns:

- **No CAT money** — PAM reports collections, CAT has none. Item 1.
- **Batch dispute** — CAT's newest version of these loans names a different
  Millennium batch. Item 2.
- **6m lag** — months PAM reports that CAT's extract cannot see. Excluded from
  both sides of the residual, so it explains none of it. Item 4.
- **Undated** — CAT money with no date in any version, so it cannot be placed
  in a month. Credited back in the residual, not in the match ratio. Item 5.
- **Pre-capex** — CAT payments dated before the batch was bought; PAM's
  lifetime structurally cannot hold them, so they are excluded. Not a fault on
  either side. PT15018G000000 carries almost all of it.
- **Wiped ref** — loans whose newest CAT version has no batch reference and no
  seller. Item 3, and the one column that concentrates in a single batch.
- **Sold on** — loans now under PT24004B000000 / INTRUM INVESTMENT SWITZER.
  Item 6.
- **Amount-less loans** — loans with a payment-flagged row carrying no amount.
  Counts only, no money effect. Item 7.

---

## Reproducing this

All figures from `RAW.HYPERION_INTRUM_CAT` and `RAW.HYPERION_INTRUM_PAM`,
newest PAM delivery only, `PMODE_NAME = 'Real'`, ownership-change rows
excluded. Money in the case currency (EUR throughout this scope), not
FX-converted.

```
mise run sql -- work/.archive/2026-10-02-benchmark-investigation-trail/batch_impact_matrix.sql
mise run sql -- work/.archive/2026-10-02-benchmark-investigation-trail/batch_attribution_audit.sql
mise run sql -- work/.archive/2026-10-02-benchmark-investigation-trail/pam_cat_match.sql
mise run sql -- work/project-elsa-benchmark/accounts.sql
mise run sql -- work/project-elsa-benchmark/payments.sql
```
