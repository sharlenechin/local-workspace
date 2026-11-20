# Intrum CAT `GROUP_PHASE_CODE` — what each code means

**Status of this page:** Intrum has never sent a phase dictionary (asked for in
`work/dbt/DBT-HANDOFF.md`). Everything below is inferred on
2026-09-16 from two live queries, and each row says how solid it is:

- `queries/phase_code_custom_labels.sql` — the feed's `CUSTOM_CODE` column carries a
  free-text label on some instances. Where it does, that label is Intrum's own
  wording → **solid**.
- `queries/phase_code_sequence.sql` — where the code sits in a case's life: share of
  cases where it is the first spell, share where it is the latest, and the
  code that usually precedes / follows it → **inferred**.

Only the first letter is confirmed by a person: A = Amicable, L = Legal,
E = Execution (Sharlene, 2026-09-16).

## Two families of instances

| Family | Instances | Codes used | Labels |
|---|---|---|---|
| Text-labelled | 7006, 7010 (PT), 4042 (ES), 4020 (FI), 1137, 1080, 4050 | `A000`, `L000`, plus `A003`–`A005`, `L005` | `CUSTOM_CODE` is a word |
| Numbered | 2020, 3010, 3020, 3031, 3032, 1033, 1039, 4034 | `A001/A002/A006`, `L002–L004`, `E000–E006`, `NA` | `CUSTOM_CODE` NULL, or a number on 3010 only |

## The codes

| Code | Cases | Meaning | How we know | Confidence |
|---|---|---|---|---|
| `A000` | 7.23m | Amicable collection, standing state | `CUSTOM_CODE` = "Debt Surveillance" / "Debt collection" (PT), "AMISTOSO" (ES), "Regular Debt Collection" / "Installment agreement" (1137) | solid |
| `A001` | 2.08m | Case registered / intake | 68.68% of spells are a case's first; almost never its latest (0.15%); always followed by `A002` | inferred |
| `A002` | 4.71m | Active amicable collection cycle | The workhorse: 40m spells for 4.7m cases — the same case re-enters it repeatedly. 4020 labels it "AM" / "NP" | inferred |
| `A003` | 89k | Handed to an external collector / consultant | "EC" (4020), "Consultant" (1137) | solid on those two |
| `A004` | 124k | Debt relief / arrangement | "NL Debt relief" (1071), "BF" (4020, unknown expansion) | shaky |
| `A005` | 14k | Pre-legal (last amicable step before court) | "PRELEGAL" (4042); usual next code is `L002` | solid |
| `A006` | 1.37m | Long-running amicable monitoring (surveillance-like) | Rarely a first spell (0.31%), self-repeating; 3010 sub-codes 60/70/4 | shaky |
| `NA` | 5.86m | **No phase assigned** | Literal string. 72% of its spells are the case's first and it is usually the only spell; where it moves on, to `L002`. 3010 codes it 97/98 | solid that it is "unassigned"; nothing more |
| `L000` | 1.48m | Legal / judicial, standing state | "Legal" (PT, 1137), "JUDICIAL" (ES); 4020 sub-labels JK/JF/JH/JI | solid |
| `L002` | 2.43m | Legal proceedings initiated (filing) | Enters from `NA`/`A002`, leaves to `L003`; rarely a case's latest (1.21%) | inferred |
| `L003` | 2.41m | Judgment / title obtained, pre-enforcement | Enters from `L002`, leaves to `E002` | inferred |
| `L004` | 154k | Legal branch other than the main track (restructuring?) | Enters from `L002`, self-repeating, 18% latest; 3010 codes 12/13 | shaky |
| `L005` | 19k | Insolvency | "Insolvency" (1137); 75% latest — cases stay here | solid |
| `E000` / `E001` | 75k / 88k | Enforcement application (2020 only) | `E001` enters from `L003`, both lead to `E002` | inferred |
| `E002` | 2.36m | Enforcement in progress (bailiff) | Enters from `L003`; 44.61% latest — where legal cases sit | inferred |
| `E003` | 668k | Enforcement sub-step (attachment / seizure actions) | Enters from `E002`, leaves to `E005`; 3010 sub-codes 22/25/30/31/44 | inferred |
| `E005` | 579k | Later enforcement stage (2020, 3020) | Enters from `E003`, 48.63% latest | inferred |
| `E006` | 372k | Enforcement variant (1033, 1039, 3020) | Enters from / returns to `E002` | shaky |

## What to do with this

- For the dashboard, **stay at the letter level** (Amicable / Legal / Execution /
  No Phase). It is the only level a person has confirmed and it is consistent
  across both instance families.
- `NA` is not a missing feed: label it "No Phase", never "No Phase Feed".
- The numbered sub-codes only mean something inside one instance's workflow;
  do not compare `A002` on 3010 with `A002` on 4034.
- Ask Intrum for the dictionary before quoting any row marked *inferred* or
  *shaky* to a PM.

## Data-quality notes (Rule 6)

`START_DATE` carries junk on a handful of rows: `1900-01-01` on `E002`,
`L002`, `L003`, `E001`, `E006`; and future dates `2032-07-19` (`L003`) and
`2202-08-22` (`E001`). Any "phase at date X" logic must bound `start_date`
to `<= current_date`; the dashboard's `start_date <= $month_end` already does.
