# <DEAL> - <seller>, <country>. Cleaning context.

<!--
THE SECTION HEADINGS BELOW ARE FIXED, IN THIS ORDER. scripts/cases.py enforces
it. A new finding goes INTO the section it belongs to; it does not get a new
section at the bottom.

!! WHY THIS IS ENFORCED AND NOT JUST ASKED FOR. Every round of review adds
   something, and the natural move is to append. Do that six times and the
   document is a changelog nobody reads, with the important rule buried under
   five later ones. A fixed shape means the sixth finding sits beside the first
   one it relates to.

!! AND THE DOCUMENT SHOULD SHRINK AS THE CODE IMPROVES. Once a finding has a
   detector or a guard, its prose here becomes a POINTER to the trap id. Prose is
   where knowledge waits until it can be made deterministic - not where it
   retires.
-->

## Header

    deal    <id>, <seller>, <currency>
    files   <n>
    offer   <bo|nbo|unknown>
    scope   <n> loans, EUR <total>
    status  <reconciled|consistent|unverified>
    run     uv run python scripts/run.py <DEAL>

## What the seller published, and we reproduce

The figure(s) this deal reconciles to, exactly. If none, say so plainly and say
what `consistent` means for this book.

## Mapping decisions

Which column feeds which field, and WHY that one and not the obvious alternative.
Grain, scope rule, and anything a reviewer rejected and how it was resolved.

## What the data cannot tell you

The limits of the tape itself. A flag that cannot express "no". A date that is
59% null. A balance that disagrees with another sheet. Written so someone
quoting a number knows what it will not bear.

## Not mapped, and the distinction

Three lists, kept apart because they mean different things:

    GENUINELY ABSENT     the seller did not give it
    DERIVABLE            it is there, nobody has mapped it yet
    NOT IN THE SCHEMA    real data this contract has no field for

!! "Unavailable" was once written for all three, which made an omission look
   like the seller's gap.

## Traps this deal taught

Trap ids and one line each. The detail lives in traps.yaml; do not restate it.

## Still open

Questions for the deal owner. Nothing here may be resolved by cleaning.

## Files

    CONTEXT.md           this - judgement calls, hand-written, fixed sections
    cleaned_summary.md   GENERATED from the output
    REVIEW.md            GENERATED - what the reviewer reads
    decisions.yaml       approvals, rejections, resolutions, approved output hash
