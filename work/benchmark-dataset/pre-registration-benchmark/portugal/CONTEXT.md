# Portugal - country context

Facts that are true of EVERY Portuguese deal, so no per-deal CONTEXT.md has to
repeat them and no two deals can quietly disagree about them.

A ruling here is a decision somebody made and can be argued with. Each one says
who made it and when, so it can be revisited rather than inherited.

---

## PT20008's three phases are a complete partition

**Ruling by sharlene, 2026-10-12.** `fase_recuperacao` assigns every one of the
2,905 loans exactly one phase, with no blanks and no overlap:

| phase | meaning | loans | debt |
|---|---|---:|---:|
| PRE-CONTENCIOSO | pre-legal / amicable, no court action yet | 1,121 | EUR 0.54m |
| CONTENCIOSO | judicial: court enforcement against the debtor | 579 | EUR 2.16m |
| INSOLVENTE | insolvency: recovery goes through the administrator | 1,205 | EUR 3.05m |
| | | **2,905** | **EUR 5,751,844.33** |

Because it is exhaustive, the other labels ARE the denial, so the flags write
False rather than NULL - `insolvent_flag` True 1,205 / False 1,700,
`judicialised_flag` True 579 / False 2,326. PT18019's `Perimeter` is the same
shape. PT15018's `Segmento` is NOT: 506 loans it labels `Individuals and ENIs`
are flagged insolvent by a PERSON on another sheet, so there the other labels
contradict nothing and the flag stays NULL. See T61.

`insolvency_claims_balance` is named for its proceeding because it is measured
to belong to one: `Valor_Reclamado` is populated on exactly the 1,205
INSOLVENTE loans and on zero others. PT15018's `claims_balance` keeps the
general name - 325 of its 673 claims sit on loans flagged insolvent=False, so
it is not an insolvency figure.

---

## Three claim fields, and which one a deal may use

A claim lodged in an insolvency ranks against the estate and is recovered
through an administrator. A claim in a court enforcement recovers against the
debtor directly. They are different amounts with different prospects, so they
are different fields - and neither is a balance owed.

    insolvency_claims_balance   PT20008 - all 1,205 claims sit on INSOLVENTE
                                loans and none on the 579 CONTENCIOSO or
                                1,121 PRE-CONTENCIOSO. Attribution proven
                                per loan.
    judicial_claims_balance     no deal yet.
    claims_balance              PT15018 - the proceeding is NOT recoverable.

!! WHY PT15018 STAYS GENERIC, having been checked rather than assumed. Of the
   673 loans carrying a claim, 287 are flagged NOT insolvent, 309 are flagged
   BOTH insolvent and judicialised, and 38 are flagged neither - so the loan's
   own flags cannot attribute it. The tape does ship a bridge,
   `Claims_Legal`, linking a loan to a ProcessNumber whose type
   `Proceedings Legal` would then give. It reaches 118 of the 673, and only
   after splitting a composite id (`70_1043635623_MLS`) on underscores - a
   rule that is already wrong for at least one row, where the middle segment
   is the literal text `OPER`.

   17.5% coverage bought with string surgery is not attribution. The other
   555 claims would have to be asserted into a proceeding the seller never
   named, which is the exact error these three fields exist to prevent.

**Ruling by sharlene, 2026-10-11.** Portuguese law has a single regime -
*insolvência*, under the CIRE - and no separate "bankruptcy" proceeding. A
seller writing `ind_bankruptcy`, `Perimeter = Bankruptcy` or `Insolvent? (Y/N)`
is naming the same legal state in different words, usually because the tape was
produced from an English-language template.

So every one of those columns maps to `insolvent_flag`, and no deal carries a
separate bankruptcy field. Six deals depend on this:

| Deal | the seller's column | what it says |
|---|---|---|
| PT18019 | `Perimeter` | `Bankruptcy` |
| PT19007 | `ind_bankruptcy` | Y/N |
| PT19013 | `ind_bankruptcy` | Y/N |
| PT20006 | `ind_bankruptcy` | Y/N |
| PT20014 | `ind_bankruptcy` | Y/N |
| PT21004 | `ind_bankruptcy` | Y/N |

!! THIS IS A STATEMENT ABOUT PORTUGAL AND NOTHING ELSE. It is recorded at the
   country level precisely so that it cannot be inherited. Other jurisdictions
   do separate the two - a US tape's Chapter 7 filing is not the same fact as
   balance-sheet insolvency - and folding them together there would merge two
   populations that a buyer prices differently. See trap T57.

The consequence worth knowing when reading a number: `insolvent_flag` counts
every loan the seller called insolvent OR bankrupt. There is no way to recover
which word the seller used from the cleaned output, because the distinction
does not exist. The registry row and this file are where that is written down.

---

## Judicialised is NOT insolvency

**Ruling by sharlene, 2026-10-11.** Two separate concepts, two separate sets of
fields, and neither implies the other. A loan can be in court without the
borrower being insolvent, and a borrower can be insolvent without anyone having
gone to court.

    judicialised_flag      judicial_start_date      judicial_end_date
    insolvent_flag         insolvency_start_date    insolvency_end_date

Only PT15018 ships judicial DATES. They sit on a `Proceedings Legal` sheet that
carries the court, the type of action and the dates, and is keyed by PROCESS -
no account, no client. `Participants Legal` carries both the process number and
the client number, so that is the route, and it is declared with a `link` row.
Two of its columns name a person (the debtor and the intervener); both are used,
because a proceeding reaches a loan through either.

!! NOT EVERY COURT FILE ON THAT SHEET IS A JUDICIALISATION. The seller labels
   each row in `Tipo de Processo`, and 889 of 2,993 are insolvency proceedings
   (491), judicial recoveries (388), PER (7) or pre-insolvency (3). Those are
   excluded by a `filter` row, because dating a loan's litigation from an
   insolvency filing merges the two concepts this file keeps apart. Kept:
   Acao Executiva (1,330), Acao Declarativa (109), the Reclamacao rows (401 -
   a claim lodged in court about this debt is a court process even when the
   proceeding is someone else's), and 260 rows typed `Not Available`, which
   cannot be classified and are not assumed to be insolvency. See T59.

!! THE DATES ARE AN ENVELOPE, NOT ONE CASE. 689 of 1,383 borrowers have more
   than one distinct court case and one has 270. `judicial_start_date` is the
   EARLIEST start across every qualifying case; `judicial_end_date` is the
   latest end, written ONLY where every one of that borrower's cases has an
   end date. 998 of 1,383 have at least one case still open, and dating their
   legal history as finished would be the most expensive error on this sheet.

!! NEITHER THE FLAG NOR THE DATES IS A SUPERSET OF THE OTHER on PT15018:

    180 loans have a court START date and are NOT flagged judicialised
    153 loans are flagged judicialised and have NO court date

Both are the seller's own data, from two different sheets, and neither has been
used to correct the other. If you need "has this loan been to court", say which
of the two you mean.

What is NOT a judicial date, and is deliberately unmapped:

    PT15020  `Data_Entrada em Pre-Contencioso`
    PT20008  `AAAMM_entrada_Pre-Contencioso`

PRE-contencioso is the stage BEFORE litigation. Mapping it as a court date
would say a loan went to court on a date it explicitly had not.

---

## Insolvency dates are not all the same date

`insolvency_start_date` means two different events depending on the seller, and
the registry note on each row says which:

- **PT20008** - the start of the *exoneracao do passivo restante*, the discharge
  period. `insolvency_end_date` is its end, consistently five years later - the
  statutory term. 1,205 loans.
- **PT15018, PT16023** - the date insolvency was DECLARED. A different event.
  Neither seller gives an end date, and that absence means UNKNOWN, never
  "still ongoing". 2,089 and 7,818 loans.

No other Portuguese deal ships an insolvency date at all - checked across every
sheet of all twelve tapes, not just the mapped ones. Six ship only a flag.

---

## The recovery stage: PRE-CONTENCIOSO, CONTENCIOSO, INSOLVENTE

**Confirmed by sharlene, 2026-10-12.** All three Oney books use the same
vocabulary for where a debt has got to, under slightly different column names:

| stage | means | judicialised? | insolvent? |
|---|---|---|---|
| PRE-CONTENCIOSO (`PRC`) | pre-litigation, amicable, no court action yet | no | no |
| CONTENCIOSO (`CON`, `CTX`) | litigation - a court case to enforce the debt | **yes** | no |
| INSOLVENTE | insolvency - the debtor is in insolvency proceedings, recovery runs through the administrator | no | **yes** |

Where it appears, and what each deal does with it:

    PT20008  `fase_recuperacao`   all three stages   judicialised 579, insolvent 1,205
    PT17013  `Fase` / `FaseRecup` two stages only    judicialised 4,650, insolvency NOT STATED
    PT15020  `FaseRecup`          two stages only    judicialised 1, insolvency NOT STATED

A tape with no INSOLVENTE category says NOTHING about insolvency. `insolvent_flag`
stays unmapped there - absent means unknown, never solvent.

The stage is also the `segment` on these deals, so segment and judicialised_flag
come from the same column. That is deliberate: the seller has one notion of where
a debt stands, and splitting it into two fields that could disagree would be worse.

!! PT15020 CONTRADICTS ITSELF ON ONE LOAN. `ANEXO_I_DADOS.FaseRecup` calls row
   280 (NIF 211527335) `CON`; the second sheet's `Fase_Recuperacao` calls every
   one of the 5,313 `Pre-Contencioso`, that one included. ANEXO_I_DADOS wins
   because it is the base sheet that defines the population - precedence, not
   truth. One loan, reported not resolved. See T67.

---

## A Portuguese NIF says whether the holder is a person

**Ruling by sharlene, 2026-10-12.** None of these tapes carries a customer-type
column. The tax number does the job: a NIF is nine digits and its FIRST digit is
assigned by law.

    1, 2, 3   natural person
    5         company
    6         public administration
    7, 9      other entities

PT15020's 5,313 NIFs all begin 1 (802) or 2 (4,511), so every holder is an
individual and none is a company. Mapped with the `lead_in:` transform and
recorded as a JUDGEMENT row - it reads an identifier, it is not a flag the
seller set.

!! THIS IS A STATEMENT ABOUT PORTUGUESE TAX NUMBERS AND NOTHING ELSE. Another
   country's identifier encodes something different, or nothing at all. The
   rule lives here, in the country file, for the same reason T57 does.

---

## Payments after the cut-off are KEPT

**Ruling by sharlene, 2026-10-12.** A seller's tape is struck weeks or months
before the book actually registers, and debtors keep paying in that gap. Those
interim collections are the only record of money already gone by the time we own
the loans, so they are kept, never dropped.

PT18019 is the live case: 15 periods, `-12M` to `3M`, of which

    -12M .. -1M   78,226 rows   EUR  8,255,262.00   before the cut-off
      1M ..  3M   20,262 rows   EUR  2,359,907.66   INTERIM, after it

!! THEY MUST NOT BE SUMMED TOGETHER when the question is what the book owed AT
   cut-off - a different question from what it has paid since. Filter on
   `period`: a label starting `-` is before, anything else is after. 22% of that
   deal's collections sit on the far side of the line.

!! AND PT18019 HAS NO CUT-OFF DATE, so `payment_month` is NULL and the seller's
   relative labels are kept as they are. Nothing is translated. Only PT15018 of
   the thirteen has a stated cut-off date (2015-09-30); for the other twelve
   nobody has established one, which is one question to the seller covering the
   whole book.

