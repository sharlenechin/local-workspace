# Heimdall reference data — are `n_accounts` and `total_balance` right?

**Yes. Per row, both are correct, and dividing one by the other gives the right
average balance for that segment.** That is how the modelling pipeline uses them
(`AggregatePaymentsSchema.mean_balance`), so the original extract was sound on the
thing you asked about.

Three other things were wrong. One of them affects the payments you model.

> Measured **2026-10-05** by live query against the Intrum PAM file produced
> **2026-09-10**. Latest real month in it: **August 2026**.

## Proof, since this is the part that matters

Checked on all **151,756** rows of the original output:

| Check | Result |
|---|---|
| `n_accounts` NULL or zero | **0 rows** |
| `total_balance` NULL or zero | **0 rows** |
| `total_balance` negative | **0 rows** |
| Same on the forecast rows the original lets in | **0 rows** |
| Range of `total_balance / n_accounts` | SEK 319.94 to SEK 372,933.86 |

Both fields are also genuinely constant within a segment, as the original's
comment claims — 0 of 1,557 segments carry more than one value of either. So
`max()` is picking from a single value, not choosing between competing ones.
**Nothing about those two fields needed changing.**

**And `acqcases` is the right denominator.** PAM also has `acqdebtors` (people
rather than loans), which would give SEK 20,801.79567 instead of SEK 7,238.64791.
Do not switch to it: it is **empty on 894 of the 1,557 segments**, so its total is
unusable. `acqcases` is populated everywhere.

---

## What to do

Run [reference_data.sql](reference_data.sql) instead of the original. **Same 12
columns, same names, same one-row-per-segment-per-month grain** — it drops
straight into the pipeline. It returns **150,199 rows** against the original's
151,756.

---

## The three fixes

**1. A fake month on the end of every segment — the one that matters.**
The file contains Intrum's **forecasts mixed in with its history**, out to
**November 2040**, and nothing in the data marks which is which. The only
separator is the cut-off date. The original cut at *today's* month end, but the
file is always about a month behind, so **one forecast month slipped through on
all 1,557 segments** — 1,557 rows with `payment_amount = 0`. A trailing fake zero
on every payment series will drag down any decay curve fitted to it. Now cut at
the file's own date.

**2. Ownership-transfer duplicates.** Missing entirely. There are none in Sweden,
so nothing changes here — but there are **3,075 such rows in Switzerland and 131
in Poland in this same file**, and each one **doubles that segment-month's
`payment_amount`**. Your header says the country code is meant to be changed per
deal, so this would have bitten the next person silently.

**3. The file was picked by newest timestamp.** It lands on the right file today.
But six times Intrum has also sent a `pam_perimeter` file into the same table, and
**every time it arrived 1–3 seconds later** (e.g. 16:01:33 vs 16:01:**34**). It
contains none of these columns, so a newest-timestamp pick would return **zero
rows with no error**. Now pinned by filename.

Plus: the two date columns are cast, since the raw feed holds them as text and
pandera wants `DateTime`.

---

## Two things left as your decision

**`payment_amount` counts `colltotal` only.** The warehouse also counts
`salesproceeds` as cash recovered — SEK 1,388,978.48 here, **0.059%** of
SEK 2,335,727,824.14. Adding it would change the modelled target, so I left it
alone rather than change it quietly. Say the word if you want it in.

**`total_balance` collides with a warehouse term.** PROD has its own
`TOTAL_BALANCE` which includes interest and fees and is **2.26× larger**. Your
column is purchase principal. I did **not** rename it — pandera validates on the
name — but two people comparing "total balance" across the two will disagree and
both be right.

---

## The reconciliation

Each step adds one rule, so every movement has a named cause. Run it with
[reconciliation.sql](reconciliation.sql).

| Step | | Rows | Accounts | Total (SEK) |
|---|---|---:|---:|---:|
| 1 | The raw file, no rules | 5,568,315 | 1,768,067,460 | 12,445,827,592,123.65 |
| 2 | + one month's file only | 371,881 | 117,874,140 | 830,001,773,326.07 |
| 3 | + no internal accounting | 371,881 | 117,874,140 | 830,001,773,326.07 |
| 4 | + no ownership transfers | 371,881 | 117,874,140 | 830,001,773,326.07 |
| **5** | **← the original extract** | **151,756** | 51,192,712 | 348,974,232,215.44 |
| **6** | **← the corrected extract** | **150,199** | 50,723,018 | 345,574,282,722.61 |
| 7 | *for reference only, see below* | 1,557 | 469,694 | 3,399,949,492.83 |

Steps 3 and 4 change nothing in Sweden. They are still required — see fix 2.

---

## ⚠ One trap, if anyone ever adds these rows up

`n_accounts` and `total_balance` are fixed on the day a batch is bought, so the
file repeats them on **every** monthly row of that batch — 10 to 231 rows, median
84. That is correct for the pipeline, which reads one row at a time. But it means:

> A library buys 500 books in 2019. Every month since, it writes *"500 books,
> SEK 10,000"* on that month's report. After 84 reports, adding them up says the
> library bought 42,000 books.

So **anyone totalling these columns must count each purchase once first** (step 7
above). Summing the extract as-is gives 50,723,018 accounts instead of **469,694**
— 108× too many. And the true book-wide average is **SEK 7,238.64791 per
account**, not the SEK 6,812.96769 you get by dividing the summed columns.

⚠ And never average the per-row averages — that gives **SEK 41,996.74442**, 5.8×
too high, because batch averages run from SEK 319.94 to SEK 372,933.86 and some
batches hold a single account. Add up the money, add up the accounts, divide.

---

## One number not to trust

`ownershippercentage` reads **0.00 on 1,547 of the 1,557 batches**, including the
biggest and all still collecting. Taken literally Brocc owns almost none of the
Swedish book. **Do not filter or multiply by it.** Worth raising with the data
team.

---

| File | What it is |
|---|---|
| [reference_data.sql](reference_data.sql) | The corrected extract — run this |
| [reconciliation.sql](reconciliation.sql) | The proof, seven steps |
