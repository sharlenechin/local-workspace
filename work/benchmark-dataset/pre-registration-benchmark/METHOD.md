# pre-registration-benchmark - the method

Turn a seller's diligence tape into the accounts schema, with evidence the
numbers are right. Per-deal work is DATA (registry rows); the engine is shared
and a deal may never change it.

`../post-registration-benchmark/` has ONE source schema (CAT), so one
parameterised template covers every book. Here every seller ships a different
shape, so this is a method, not a template.

!! THIS FILE DESCRIBES WHAT RUNS, NOT WHAT IS PLANNED. An earlier version
   documented "step 2 - detect known traps" while `detectors.py` did not exist
   and traps.yaml merely NAMED seven functions. Nothing caught it for a day.
   "Still to build" at the bottom is the honest list; everything above it has
   been run.

---

## The sequence

    uv run python scripts/run.py <deal>

It runs every deterministic step and STOPS where judgement is needed. Do not
chain the scripts by hand - a sequence remembered is a sequence that drifts.

!! THIS TABLE IS CHECKED AGAINST run.py BY A REGRESSION CASE. It described
   the wrong order for a day after run.py was fixed - review at step 5, before
   the clean at 6 - which is exactly the bug that made a reviewer read a sheet
   built from the PREVIOUS run. A method document that disagrees with the code
   is worse than none, because people trust it.

| step | who | what | blocks? |
|---|---|---|---|
| 0 | AUTO | `load_tapes.py` - every workbook to text parquet | - |
| 1 | AUTO | `find_strats.py` - the seller's own published figure | - |
| 2 | AUTO | `find_dictionary.py` - does the tape define its columns? | - |
| 2b | AUTO | `detectors.py` - which known traps are in THIS tape | - |
| 2c | AUTO | `readiness.py` - is the book COMPLETE enough to map definitely? STOPS on an unreadable delivery, because a missing file is a missing population | - |
| 3 | USER | review the strats hits | - |
| 4 | AGENT | write registry rows in `mappings.csv` | YES, if absent |
| 5 | AUTO | `clean_accounts.py` | **YES** on failure |
| 6 | AUTO | `clean_payments.py` | no - a blocked join is reported, not fatal |
| 7 | AUTO | `guards.py` | **YES** on failure |
| 8 | AUTO | `summarise.py` | - |
| 9 | AUTO | `review.py` - write the approval sheet | - |
| 10 | USER | read it and decide | **YES** |
| 11 | AUTO | `backtest.py` - did any OTHER deal move? | - |
| 12 | AGENT | record the learning in CONTEXT.md and traps.yaml | - |

**Build before you ask anyone to sign.** Steps 5 to 9 produce the artefacts;
step 10 is the first time a human is asked for anything about them. The sheet
always describes what exists right now, never the previous run.

## How a reviewer answers - REJECT UNTIL APPROVE

The sheet is a list to be CHALLENGED, not a checklist to be ticked.

| you have | you use | goes to | blocks |
|---|---|---|---|
| this FIELD is wrong | `--reject <field> "reason"` | agent | yes |
| anything not about one field | `--note "whatever"` | agent | yes |
| nothing left to challenge | `--approve` | - | it IS the sign-off |
| (optional) a field settled early | `--confirm <field> "why"` | nobody | clears that row |

Approving signs off everything not rejected, in one action, and PINS every
field's mapping plus the raw tape md5 plus the output md5. Change any one of
them afterwards and the sheet names the field and shows was/now. Traceability
comes from what the approval pins, not from how many times a human typed yes.

A rejection and a note both return to the AGENT, who edits `mappings.csv` -
never code - and the deal rebuilds from step 5. `--resolve` refuses unless the
mapping actually changed; `--close` refuses on an unanswered note.

## What comes out - three files, and why the split

    portugal/cleaned/accounts/<deal>.parquet               one row per LOAN,
                                                       20 FIXED columns
    portugal/cleaned/additional_attributes/<deal>.parquet  one row per loan per FACT
    portugal/cleaned/payments/<deal>.parquet               one row per payment

    portugal/raw/assets/                               the RAW deliveries,
                                                       exactly as received and
                                                       never written to

**The core is a promise; the long table is a sponge.** Those 20 columns are
what every consumer can rely on existing, with the same meaning, on every deal
in the country. Everything else a seller ships - a claim amount, an insolvency
date, a judicialisation flag, a product description - lands in
`additional_attributes` as `deal_id, loan_id, column_name, column_value,
column_type`.

!! WHAT THIS REPLACED, AND WHY. The contract used to be a 26-column superset
   that grew with every tape. A deceased flag wanted by five deals, a fee
   column by two, an insolvency date by two - each one widened the table for
   all twelve, left it null on most, and forced a schema version, a re-run and
   a re-approval on deals that had not changed. Null then meant two different
   things: this tape does not carry it, and some OTHER seller had this.

Now:

| adding | costs |
|---|---|
| a FACT (anything outside the core) | one registry row, re-run that deal. No schema edit, no other deal touched |
| a CORE column | a schema edit, a re-run of ALL deals, and every existing approval goes stale |

The second is deliberately expensive, because it is a promise to every
consumer. The first is how a seller's oddity gets captured without taxing
eleven other books.

Absence in the long table means exactly one thing: the tape does not carry
that fact for that loan. There are no null rows to interpret.

**Payments are separate because they are a different grain** - one row per
payment, signed, so summing `payment_amount` over any grouping is the net.
Which months are interim is derivable from `cutoff_date` in accounts; it is
not stored twice.

## The registry roles - the only place a deal differs

`mappings.csv` is the whole per-deal configuration. One row is one column of
one sheet feeding one schema field, and the `role` says how it is combined.
A new deal is new ROWS, never new code.

| role | what it does | the rule it must obey |
|---|---|---|
| `base` | defines the population - one row out per row in | must tally to the seller's published figure. If it does not, the scope rule is wrong, not the arithmetic. |
| `enrich` | left-joins detail on a discovered key | may fill fields; may never add or remove a loan |
| `party` | person-level facts rolled up to the loan with `max()` | fills only what the loan level left NULL (T16 - the finer grain wins) |
| `align` | a second sheet of the SAME export, paired by POSITION | refused unless a column PROVES the ordering row for row |

`align` is the one that looks dangerous, so it is the one with a precondition
the engine enforces on every run. PT15020 ships its book as two sheets with no
key in common - one carries the contract number and the dates, the other the
balance, principal and interest - and `Contrato` overlaps `Venda` on zero
values because `Venda` is just a row counter. Pairing by position is a guess
unless something independent says the two orderings agree, so the engine looks
for a column on both sheets that matches row for row and REFUSES if it cannot
find one. It also refuses outright if the second sheet is shorter than the
base, because that means rows are missing rather than trailing.

## Is it deterministic? Yes, and here is the proof

    same inputs -> byte-identical output   verified across PYTHONHASHSEED 1 and 2
    the tape itself                        MD5-pinned in the backtest fingerprint
    every value in the output              hashed PER COLUMN, in a stable row order
    every reconciliation                   pinned, including each published cut

So a run that produces a different number has had a different INPUT or a
different ENGINE, and the backtest says which:

    OK          nothing moved
    ADDITIVE    only new or newly-populated columns; every prior value identical
    REGRESSED   an existing value moved - STOP AND READ IT
    INPUT CHANGED   the tape itself differs. Re-verify from scratch; do not
                    compare against a stale baseline.

!! DETERMINISTIC IS NOT CORRECT. `clean_accounts.py` was perfectly deterministic
   while producing the wrong answer three times in one day - reliably, the same
   wrong answer each run. What determinism buys is that an EXTERNAL check, once
   passed, stays passed. Correctness comes from reconciling to a figure the
   seller published, never from the pipeline agreeing with itself.

## Is it traceable? Yes - every number has a path

    accounts/<deal>.parquet
      <- clean_accounts.py            the shared engine, same for every deal
      <- mappings.csv rows             which column fed which field, with a note
      <- schema.yaml                   the column contract, one source of truth
      <- data/tapes/<deal>.parquet     the raw tape, MD5-pinned
      <- the seller's workbook          named in the manifest, with its full path

and the judgement beside it:

    strats/<deal>.json                 what reconciled, and what was searched
    dictionaries/<deal>.json           whether the seller defined its own columns
    cleaning-context/<deal>/
      REVIEW.md                        what the reviewer was shown
      decisions.yaml                   who approved, when, what they rejected
      CONTEXT.md                       the judgement calls and why
      cleaned_summary.md               GENERATED from the output, cannot drift

`verification_status` on every row is set from the guard result, never by hand.
`reconciled` is unreachable without a step-1 hit.

## The three safety nets, and what each can see

    cases.py      does the ENGINE still handle a known defect?
                  No deal needed. Milliseconds. Runs before anything is cleaned.
    guards.py     is THIS DEAL's output right?
                  Reads the output. Refuses the run.
    backtest.py   did a change move an EXISTING deal, or its proof?
                  Content hashes. ~1s per deal. Run it after every change.

!! A DETECTOR IS NOT A GUARD. A detector reads the INPUT and warns; a guard reads
   the OUTPUT and refuses. Most of the worst defects are invisible to a guard
   because the output stays internally consistent: Portuguese month headers
   decoded as English dropped 22 of 26 months and every total still tied.

## Promotion - how a trap becomes a check

`scripts/promote.py` reports what is due. The rule:

    seen on 1 deal   prose, unless detection is structural and cheap
    seen on 2 deals  -> DETECTOR + CASE
    seen on 3 deals  -> GUARD
    engine-level     -> CASE immediately, whatever the count

A promotion may only land when the backtest is green. `--skip <trap> "reason"`
records a deliberate decision not to promote, with the reasoning, so the report
stops asking and the judgement survives.

### Run every NEW check back against the deals already settled

This is the step that pays, and it is not optional. A detector or guard written
for deal N is a question deal N happened to provoke - it was always a fair
question to ask of deals 1..N-1, and nobody had asked it.

On 2026-10-07, three checks written for PT18019 - a deal with no published
figure and nothing to reconcile against - were run back over the two deals that
were green, approved-pending and believed finished. All three found something:

| new check | written because | found, looking backwards |
|---|---|---|
| guards run with no EXPECT | PT18019 publishes no figure | PT15018 had shipped the ENGLISH header row as a loan, and an all-`x` stray |
| `loan_id unique` | nothing; it needs no published figure | PT16023's "Unique Loan ID" is not unique - 1,877 rows, EUR 22.7m, 10.1% |
| T18 detector | `Perimeter = Bankruptcy` | PT15018 was reading insolvency at the wrong grain; 5,319 loans gained a True |

Note what the first column has in common: none of these needed a seller's
figure. The deals with the LEAST external evidence force the checks that work
WITHOUT it, and those are the checks every deal should have had. A deal that
reconciles to the cent is the easiest place for an internal defect to hide,
because the one number everyone looks at is right.

The cost of the sweep is one command per deal. The cost of skipping it is that
a defect found on deal 3 stays in deals 1 and 2 for as long as nobody re-asks.

## The roll-forward - the proof a single date cannot give

A strats hit proves ONE total at ONE date against a figure the seller
published. A roll-forward proves something else entirely: that two dated
balances and the cash between them tell the same story.

    opening balance  -  collections  =  closing balance

On PT15018, all three are on the tape:

    OPB September 2015                      407,079,317.23
    less collections Oct-15 .. 13-Feb-16      1,569,865.11
                                            --------------
                                            405,509,452.12
    OPB 13-Feb-2016, as the seller gives it 405,509,452.41
                                            --------------
    residual                                        -0.29

29 cents across EUR 405.5m and 32,529 loans. It is a GUARD, pinned as
`rollforward_residual`, so if the balances and the payments ever stop agreeing
the deal refuses.

**Only one of the twelve can have one.** The rest have a single balance date,
or no payment columns, or both - PT15014 and PT15016 carry `curr_bal` and
`woff_bal`, but those are two MEASURES, not two dates. On those eleven the
guard prints that it is NOT POSSIBLE and why, because "ALL GUARDS PASS" on a
deal where a check was never attempted reads as though it had been.

## The rule under all of it

**Never write a value the tape does not support.**

    "Not Available"         -> null, never 0
    a Y/N column with no N  -> True or null, never False
    no offer-stage marker   -> `unknown`, never a guessed default
    no reconciliation       -> `consistent`, never `reconciled`

Seventeen traps are recorded. EVERY ONE WAS SILENT - a plausible wrong answer
that raised nothing. Totals compared against an independent source caught all of
them; inspection caught none.

## What is testable, and what is not

TESTABLE   totals against a published figure; row counts; uniqueness;
           null-vs-zero; byte-identical re-runs; sign conventions; detectors.

NOT TESTABLE   whether a column MEANS what we think. `Data Vencido ->
           default_date` is a judgement from a Portuguese word and every guard
           passes either way. That is why step 5 BLOCKS, and why the status says
           `reconciled` (the totals tie) rather than `clean` (everything is right).

## Still to build - not yet written, do not assume otherwise

    (rollforward)        DONE 2026-10-09, and NOT as a script. Only one deal
                         of twelve can support one, so it lives where every
                         other per-deal proof lives: PT15018's guard, pinned
                         as `rollforward_residual` at -0.29. The eleven that
                         cannot support it now say so instead of staying
                         silent.
    5 promotions due     see promote.py
    40 of 75 traps       have no regression case. Most are enforced by a guard
                         instead, which is legitimate - but the gap should be a
                         decision, not an accident. promote.py reports it.
                         The 75 are 52 tape traps in traps.yaml plus 23
                         engine lessons in engine-lessons.yaml - one ledger,
                         two files, split by WHO NEEDS TO READ IT.

!! THESE COUNTS ARE CHECKED BY cases.py (DOCS). They were wrong within a day
   of being written, twice, because a count retyped by hand is a count that
   rots. If this section disagrees with the code, the case fails.

## What exists, as at 2026-10-08

All twelve Portuguese deals are cleaned, guarded, reviewed and reproducible.
Four reconcile to a figure the seller published - EUR 639,167,652.11, 60.6% of
the book. None is approved; that is the reviewer's step and it has not started.

Payments are cleaned on the five deals that carry usable ones. Six tapes ship
no payment columns at all, and PT20008's cannot be tied to its population
because that deal has no loan identifier - the script refuses rather than
joining on a row counter.

