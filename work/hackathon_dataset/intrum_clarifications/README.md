# Intrum clarifications: Sweden

Sharlene Chin, 18 Nov 2026

For most of our Swedish deals, the payments in CAT don't add up to what Intrum reports in PAM.
Part of that is two bugs in our own dbt model, which we'll fix. The rest we can't explain without
Intrum, and this folder has the evidence and the questions.

## Background

We own 639 Swedish deals, about 1.9 million cases. 636 of them are the Heimdall back book we bought
from Intrum in December 2025, and three are Lokki deals we bought ourselves. Intrum services all of
them and sends us two feeds:

- CAT: every case and every payment, loan by loan.
- PAM: Intrum's monthly summary of what each book collected.

We treat PAM as the right answer. If a deal's CAT payments add up to PAM, we trust CAT enough to
model it loan by loan. In this folder "reconciles" means CAT has payments in at least 80% of the
months PAM does, and the total is within 10% of PAM, counting from when we bought the book.

Heimdall deals use Intrum's ids. Lokki deals use ours, and three of them are different, so use
Intrum's when you write to them: our LOK-SE25008 is their SE25018, LOK-SE25013 is SE25037, and
LOK-SE25014 is SE25022. The workbook has an Intrum id column.

## Where things stand

| | Deals | Cases |
|---|---:|---:|
| Swedish deals we own | 639 | 1,914,527 |
| Reconcile today | 53 | 261,743 |
| Reconcile after our two fixes | 82 | 671,883 |
| Pass today but fail once fixed | 14 | |
| Still fail after our fixes | 557 | |
| Have a seller tape | 6 | 44,335 |
| Have a seller tape with payment history | 3 | 31,502 |

The three "after our fixes" rows are measured on the sandbox build with both fixes (`DEV.HACKATHON`, 23 Nov 2026),
from `../bug_fixes_impact/RESULTS.md`. They replace the 18 Nov estimate (115 reconcile, 20 pass-then-fail, 524 still
fail), which came from a rebuild that still double counted the April 2019 re-booking.

Our two bugs, both in `int_npl_case_collection_intrum` in brocc-data:

- Bug 1: we drop payments where `booking_ind = 'Y'`. On Intrum's system 1062 every payment is 'Y',
  so we lose all of that system's cash. LOK-SE25008 shows 7.5% of PAM today and 97.4% once fixed.
- Bug 2: we de-duplicate payments on `orig_tr_id`. On system 2080 the same payment can arrive
  under several ids (case 2080-1212023 has 14 rows of 570.00 on 2016-01-27), so some get counted
  twice or more.

Intrum's data isn't wrong in either case, we read two fields wrongly. Questions 1 and 2 just check
what those fields mean, so the fix is based on their definition rather than our guess.

14 deals only reconcile today because the two bugs cancel out: one drops cash, the other double
counts it. Once both are fixed those 14 don't reconcile either.

## What's left once our bugs are fixed

⚠ This table is the 18 Nov estimate. The measured breakdown of the 557 deals, by reason and by market, is in
`../bug_fixes_impact/RESULTS.md`.

| Reason | Deals | How sure |
|---|---:|---|
| Probably bought before CAT's history starts (Oct 2014) | 350 | a guess from the dates |
| No cases in CAT at all (all bought 2001–2010) | 84 | probably closed before Oct 2014, not confirmed |
| CAT has more 2016–2019 cash than PAM | 2 | checked year by year, see `work/data-issues/intrum/pam-pre-2020-swedish-books.md` |
| Probably PAM's pre-2020 reporting | 38 | a guess, same pattern as the two above |
| Total matches but CAT is missing months | 16 | measured |
| Not explained yet, including the 20 that only pass because of our bugs | 34 | open |

## Questions for Intrum

All 21 are on the Intrum asks tab of the workbook, numbered the same as in the Jira ticket, with
the deals each one covers. Briefly:

- Fields (1–3): what `booking_ind` means, what identifies a single payment, and which date to use
  for the 35% of payments with no `transaction_date`.
- Reconciliation (4–9): the 84 deals with no cases, history before Oct 2014, PAM before 2020,
  missing months, the deals we can't explain, and why CAT has 152% of the principal we bought on
  SE25018.
- Mappings (10–13): the missing batch SE25018D010000, case ids for the SE20009 tape, whether
  `invoice_number` is Norion's `LoanNumber`, and which client reference holds the seller's account
  number.
- Code lists (14–17): status, closing, phase (and phase filled in, since it's NA on most Swedish
  cases), legal step and result.
- Seller tapes (18–21): unlocked Norion files, payment history for SE19026 and SE25022, tapes for
  the 111 deals that reconcile once our bugs are fixed, and any tape for SE15044 or SE16025.

Where a reason says "probably", ask it as a question. We haven't confirmed it.

## What's in the folder

| File | What it is |
|---|---|
| `sweden_intrum_reconciliation.xlsx` | Start here. Tabs: Read me, Summary, Intrum asks, Tape deals (the 8 that matter most), All deals. Written by `export_workbook.py`, not committed |
| `sweden_status.ipynb` | Builds the deal table and the ask list the workbook is made from (`sweden_status.csv`, `intrum_asks.csv`) |
| `seller_tapes.py` | Which deals have a seller tape, and whether it has payment history; used by the notebook |
| `export_workbook.py` | Writes the workbook from the notebook's output |
| `queries/1_sweden_deals.sql` | Deals, cases, PAM and CAT today (about a minute) |
| `queries/2_sweden_raw_cat.sql` | CAT rebuilt without our bugs (about 20 minutes) |
| `queries/3_reconcile_hackathon_build.sql` | Which Swedish deals reconcile in the sandbox build with both bugs fixed |
| `queries/0_test.sql` | Scratch query |

The evidence for the bugs and the PAM questions lives with the other Intrum data issues, in
`work/data-issues/intrum/`:

| File | What it is |
|---|---|
| `../../data-issues/intrum/pam-pre-2020-swedish-books.md` | The PAM pre-2020 gap year by year, and what we ruled out |
| `../../data-issues/intrum/queries/dbt_vs_ours_vs_pam.sql` | Each bug on its own, on six books |
| `../../data-issues/intrum/queries/booking_ind_by_instance.sql`, `booking_ind_money_by_instance.sql` | Which systems bug 1 hits, by rows and by money |
| `../../data-issues/intrum/queries/mismatch_se25018.sql` | Bug 1 on one deal: what we show, what Intrum says, what the fix gives |
| `../../data-issues/intrum/queries/pam_vs_cat_by_year_se16025.sql` | The pre-2020 PAM gap by year |
| `../../data-issues/intrum/queries/collection_date_floor.sql` | Where our payment history starts compared with the raw feed |

The queries are read-only and run on the brocc-sandbox account, which can see Intrum's raw feeds:
`mise run sql -- <file> --connection dev --warehouse DEV_WH --lower`, run from `local-workspace/`.

## Before sending anything

Only send ids, counts and amounts. Never attach a seller tape or a CAT extract.

The numbers are from 18 Nov 2026. To refresh them, rerun `sweden_status.ipynb` and
then `export_workbook.py`.
