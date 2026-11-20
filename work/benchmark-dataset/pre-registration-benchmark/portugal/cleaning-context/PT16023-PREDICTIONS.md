# PT16023 -- predictions, written BEFORE running it

Written 2026-10-07, before a single mapping row exists. The point is to find out
whether the design generalises or whether it was fitted to PT15018. Predicting
afterwards is rationalising.

Scored honestly when the deal is done.

## The design holds if ONLY these change

| file | expected change | why |
|---|---|---|
| `mappings.csv` | +10-15 rows | per-deal by design |
| `guards.py` EXPECT | +1 entry | per-deal by design |
| `cleaning-context/PT16023/` | new | per-deal by design |

## I PREDICT these will ALSO need changing -- and that is a design failure

| file | line | why it will break |
|---|---|---|
| `clean_accounts.py` | the enrich join key, hardcoded `"Numero de Conta"` | PT16023 is one flat sheet (`Masterdatatape_NBO`); its loan id is not called that |
| `clean_accounts.py` | the party join key, hardcoded `"Numero de Cliente Interno"` | PT16023 may ship NO party sheet at all |
| `clean_accounts.py` | the fake-header filter, `["Account Number", "Numero de Conta"]` | same |

**If I am right, those three must move into the registry before deal 3.**

## Specific predictions, checkable

1. PT16023 reconciles. `OB (€)` = 224,485,808.25 and `UPB (€)` = 219,753,165.09,
   both already found by find_strats with no filter.
2. 19,434 loans, matching the strats' own `# of accounts`.
3. `detail_level` will be 100% `basic` -- one flat sheet, so nothing to enrich.
4. `judicialised_flag` will be ENTIRELY NULL. The 12-deal column survey found
   PT16023 has 4 judicial-ish columns, but they are on `Strats` sheets, not at
   loan level.
5. `offer_stage` = `nbo` -- PT16023 is the ONLY deal whose filename says so.
6. At least ONE new trap. PT15018 produced thirteen; a different format will
   have its own. If PT16023 produces zero new traps I should distrust the run,
   not celebrate it.

## What would mean the design is WRONG, not just incomplete

- the `base` / `enrich` / `party` roles cannot express this tape's shape
- the engine needs a new concept, not a new registry row
- cleaning it moves ANY PT15018 number (the backtest must stay GREEN or ADDITIVE)

## Cost prediction

PT15018 took a full day and thirteen traps. If PT16023 takes more than two hours
and does not reuse most of the method, the method is not a method.
