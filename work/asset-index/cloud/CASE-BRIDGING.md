# Bridging the asset index to our case data

**How a loan in the asset index is tied to the same loan in NPL_COMMON, which
rules work, why there is no universal one, and what to do about it.**

Companion documents: `README.md` (how to run the queries, the benchmark
dataset), `FINDINGS.md` (what the asset index contains and which fields to
trust). This file is only about the join between the two worlds.

Last measured **2026-10-21** against brocc-sandbox. Every figure here is a
measurement with a date, not an estimate — re-measure rather than quoting.

---

## 1. The one-paragraph version

The asset index is what a seller showed us at diligence. NPL_COMMON is what the
loan has done since. Joining them gives one continuous history per loan, which
is what underwriting wants. The join is hard because **the servicer's case id is
assigned by their system and has no derivable relationship to ours** — so every
link is a lookup, and the lookup differs per deal. Today **7 of 23 books are
bridged**, 35,023 loans reach our case data, and **3,925 of those have
collections since acquisition**.

---

## 2. How the link actually works

Never id → id. Always three steps:

```
our case_id  →  the servicer column that records OUR reference  →  their case id
```

For the German books that middle column is CAT's `client_ref_1`. The servicer's
own `case_id` is then what `CASE_BRIDGE.servicer_case_id` holds, and CAT's
`CASE_BK` is `system_code || '-' || servicer_case_id`, which resolves in
`DIM_CASE`.

**Proof there is no formula.** Across 35,023 verified pairs, our id and theirs
are *never* identical, neither contains the other, and they never agree after
stripping zeros. Their id is also shorter than ours in every book (ours 12 →
theirs 9; ours 14 → theirs 7). A shorter id sharing no substring cannot be
computed from ours — the information is not there.

That is why mapping files exist. **A mapping file is a lookup table because
there is no formula to replace it.**

---

## 3. What the Intrum deck established (2024)

`Asset_Index_Linking_Seller_References_to_Case_IDs.pptx`, shared by Roeland in
August 2026, documenting work from 2024 on the old Reflect/Catalyst stack. It
examined seven deals and found four different patterns — which is why the team
began collecting per-deal mappings.

| Pattern | Deck example | What it means |
|---|---|---|
| Our case id = their `case_id` | CH20020, NN22020 | internal portfolio acquisitions, ownership moved in ReCash/Pink |
| Our **customer** id = their `client_ref_1` | GE23013, UK22018 | the common case; note it is the customer id, not the case id |
| Invoice level only | PL24002 | cases are built by grouping invoices per customer; no case-level id exists |
| Nothing links | PT22015 | and CAT's own `long_portfolio_id` was wrong for that book |

Four warnings from the deck that still apply:

- **Hashing makes linking impossible.** `client_ref_1` is sometimes a base64
  SHA-256 digest. No rule recovers it.
- **Leading-zero drift.** ES23005 matched only once CAT's `0` prefix was allowed for.
- **Germany runs multiple collection systems**, so a system id is needed to link properly.
- **CAT calls Germany `GE`**; the asset index calls it `DE`.

---

## 4. What we measured in October 2026

### The derived rule is exact where it fires

Verified pair by pair against the servicer's own file — not just by count:

| Deal | Verified pairs | Rule fired | Agreed | Disagreed |
|---|---|---|---|---|
| DE25010 | 8,871 | 8,871 | **8,871** | **0** |
| DE25021 | 760 | 760 | **760** | **0** |
| DE25023 | 4,936 | 4,243 | **4,243** | **0** |

**Precision 100% over 13,874 firings.** Its failure mode is silence, not error —
which is what makes it safe where no file exists to check against.

### But it does not generalise, not even within one country

All 8 candidate CAT columns tested (`client_ref_1/2/extra`, `parent_ref`,
`ref_case_id`, `external_collector_id`, `main_debtor`), with and without
prefix-stripping:

| Deal | System | `client_ref_1` | Everything else |
|---|---|---|---|
| DE25010 | 3031 | 100% | 0 |
| DE25021 | 3031 | 100% | 0 |
| DE25023 | 3031 | 86% | 0 |
| **DE25020** | **3031** | **0** | 0 |
| SE25008 | 1062 | 0 | 0 |
| CH25007 | 3010 | 0 | 0 |
| ES25021 | 4042 | 0 | 0 |

**DE25020 is the same country, same servicer and the same Intrum system as the
three that work, and matches nothing.** The rule is therefore not per country,
per servicer or per system — it is **per deal**, fixed by whatever was agreed at
onboarding. Which deals will yield cannot be predicted from the outside.

**Hit rate on books we can verify: 3 of 7.**

### The reference route is exhausted — exact only, `client_ref_1` only

The full grid (our 2 fields × their 3 fields × 3 normalisations) run against
every verified pair returns **15 firing combinations across only 3 books**, and
every one of them is `client_ref_1`. Nothing reaches DE25020, SE25008, CH25007
or ES25021 by any reference at all.

Two things that shape the rule format:

- **Normalisation adds nothing and `strip_zeros` is harmful.** On DE25023,
  `exact` and `alnum` both give 4,243 correct with 0 wrong; `strip_zeros` fires
  on 4,244 and introduces **6 disagreements** — false matches, no new finds.
  Default to `exact`.
- **On DE25021 and DE25023, `case_id` and `counterparty_id` give identical
  results**, so the left-hand dimension collapses on those books. Only DE25010
  distinguishes them.

### Amount matching DOES work, scoped — correcting an earlier finding

An earlier version of this file said balance matching fails. **That was wrong,
for two reasons, both in the test rather than the data:**

1. It compared our `principal_at_cutoff` to CAT's `principal_at_cutoff`, which
   matches **zero** rows. The correct pairing is our `principal_at_cutoff` to
   CAT's **`original_capital`**.
2. It matched globally across 20m CAT cases instead of scoping to the book's own
   portfolio, so real matches drowned in collisions.

Corrected and scoped to the portfolio, verified against the bridge:

| Deal | Unambiguous matches | Correct | Wrong | Precision | Recall |
|---|---|---|---|---|---|
| DE25021 | 749 | 744 | **0** | 100% | 98% |
| DE25010 | 7,325 | 7,286 | 11 | 99.85% | 82% |
| **DE25020** | 5,938 | 5,896 | 18 | **99.70%** | 66% |
| SE25008 | 2,429 | 2,034 | 390 | 83.9% | 32% |
| ES25021 | 118 | 0 | **71** | **0%** | 0% |

**DE25020 is the case that matters: it has no reference key of any kind, and
amount matching bridges 5,896 of its loans at 99.7% precision.**

⚠ **Precision varies enormously and must be measured per book.** ES25021
produced 118 unambiguous matches and every one checkable was wrong. This route
can fail completely and silently, so never carry a sibling book's precision
across.

⚠ **Only take unambiguous matches** — one candidate for one of our cases.
Round amounts collide; ambiguous matches are not matches.

⚠ `REGISTRATION_BALANCE` is 100% NULL on all 23 books. Only
`LEGAL_BALANCE_AT_CUTOFF` and `PRINCIPAL_AT_CUTOFF` carry values.

### Validating a rule with no ground truth: the unambiguity gate

A book with no servicer file has nothing to check a rule against. The fraction
of our cases that hit **exactly one** of theirs solves this — it needs no truth
and it predicts precision:

| Deal | Unambiguous rate | Measured precision |
|---|---|---|
| DE25020 | 5,938 / 5,971 = **99.4%** | **99.70%** |
| DE25010 | 7,325 / 7,380 = **99.3%** | **99.85%** |
| DE25021 | 749 / 766 = **97.8%** | **100%** |
| SE25008 | 2,429 / 4,759 = **51.0%** | 83.9% |
| ES25021 | 118 / 534 = **22.1%** | **0%** |

Above ~97% the rule is sound; around 50% it is shaky; at 22% it is worthless.
ES25021's total failure was knowable in advance from its own data, with no
bridge to compare against. **Make this the gate: refuse a rule below threshold
and record the number alongside `measured_coverage`.**

### Date corroboration does not work — tested

A second agreeing field would be the obvious way to score a match. It is not
available: CAT's `default_date` and `origination_date_at_client` are **empty on
every German pair** (7,286 of 7,286 correct matches have no date to check), and
where dates do exist, on SE25008 and ES25021, they never agree. Use the
unambiguity gate instead.

### The two routes are complementary

| Deal | Reference | Amount |
|---|---|---|
| DE25010 | **100%** | **99.85%** |
| DE25021 | **100%** | **100%** |
| DE25023 | **86%** | 0% |
| DE25020 | 0% | **99.70%** |
| SE25008 | 0% | 84% |
| CH25007 | 0% | 0% |
| ES25021 | 4% | 0% |

Neither route alone covers the German books; together they cover all four. Where
both fire they agree, and two independent methods reaching the same answer is
what makes a bridge trustworthy on a book with no servicer file to check against.

---

## 5. The rule vocabulary

A rule names a **route** and its parameters. Two routes are proven:
**reference** (our id in one of their columns) and **amount** (our
`principal_at_cutoff` = their `original_capital`, scoped to their portfolio,
unambiguous matches only). The reference route's grid:

| Dimension | Values |
|---|---|
| **our field** | `case_id`, `counterparty_id` |
| **their field** | `case_id`, `client_ref_1`, `client_ref_2` |
| **normalise** | `exact` (default; measured best), `casefold`, `alnum`, `strip_prefix` — **not `strip_zeros`**, which adds false matches and finds nothing |
| **scope** | the book's own `long_portfolio_id`, or global |

About 60 combinations — small enough to test exhaustively per deal, which is
what a prober should do. New normalisations get added only when a real deal
needs one; the Spanish leading-zero case is exactly that shape.

### Store the rule as data, not as a file

A rule is a row, so it belongs in a table rather than a YAML on someone's laptop:

```
BRIDGE_RULE
  portfolio_id, left_field, right_field, normalise, scope,
  expect_min_coverage, measured_coverage, measured_at, approved_by, note
```

One SQL model then applies every rule with no branching: unpivot both sides into
`(entity, key_kind, key_value)`, join `our keys → rule → their keys`, and apply
the normalisation identically to both sides. Add a deal, add a row.

Two rules about the rules:

- **Declare it, never infer it at runtime.** If the builder picks the best rule
  each run, a data change silently alters what the bridge means.
- **Carry `expect_min_coverage`.** If a refresh drops a book from 60% to 5%, the
  build must fail rather than quietly produce a thinner bridge.

### What we know today

| Deal | Our field | Their field | Matches | Coverage |
|---|---|---|---|---|
| DE25010 | `case_id` | `client_ref_1` | 8,871 | 69% |
| DE25021 | `case_id` | `client_ref_1` | 760 | 70% |
| DE25023 | `case_id` | `client_ref_1` | 4,245 | 60% |
| **UK24020** | `case_id` | `client_ref_1` | 1,617 | 64% |
| **UK26004** | `case_id` | `client_ref_2` | 1,095 | 93% |
| ES26101 | `counterparty_id` | `client_ref_1` | 1,665 | 7% |
| ES26106 | `counterparty_id` | `client_ref_1` | 252 | 11% |
| ES25021 | `counterparty_id` | `client_ref_1` | 148 | 4% |

The two in bold have **no bridge today** — these rules would create one, worth
about 2,700 loans. Where a servicer file already exists, prefer it: DE25023's
file finds 4,936 against the rule's 4,243.

The Spanish three are technically rules but cover 4–11%; understand why they are
so thin before building on them.

---

## 6. Traps

Each of these has produced a wrong answer at least once.

**`DIM_CASE` is a slowly-changing dimension.** Without `is_current_flag = TRUE`
you get one row per historical version and every count multiplies.

**Raw CAT `CASES` is a change-history feed** — roughly 147 rows per case. Always
reduce to distinct values before matching or counting.

**CAT case ids are unique only per system.** Joining `case_id` without the system
returns collisions: looking up SE25008's 6,267 cases also hit 234 unrelated
portfolios in FI, PT and CH, mostly one case each. Scope by system, or read small
counts as noise.

**The mapping is many-to-one.** 21,066 matched rows resolved to 20,456 distinct
`case_sk`; one CAT loan was claimed by seven asset-index cases. Collapse to
`case_sk` before joining any fact, or collections repeat per claimant.

**CAT's portfolio id is independently assigned too.** Our `SE25008` is
`SE25018D020000` in CAT — even the number differs. You cannot find a book in CAT
by name; you can only learn its id once you have a mapping, so ask for it.

**`DE` here is `GE` there.** Any comparison of the two id spaces fails silently
without that translation.

**Long numeric ids float-round.** Read them as text. Massey's `EXTERNAL_ID` is a
FLOAT for this reason — prefer its `CASE_ID`.

**Collection dates run to the year 4570.** Bound every collection query with
`collection_date <= CURRENT_DATE()`.

**`FCT_CASE_COLLECTION` undercounts.** An SCD inner join upstream cuts it; on the
Portuguese book it returns about 42% of what PAM reports. Check before quoting a
collection figure.

---

## 7. Bridging a new deal

1. **Find the book in CAT.** You cannot derive its `long_portfolio_id` — ask, or
   recover it from an existing mapping. Country+number matching works only
   sometimes and produces cross-country collisions (`IT25019` "matches"
   Polish `PL25019` books).
2. **Run the rule grid scoped to that portfolio.** Scoped, the haystack is
   thousands rather than 20 million and a weak signal becomes verifiable.
3. **If a rule fires, verify it against something.** Where a servicer file
   exists, compare pair by pair, not by count. Where none does, check the hit
   rate is high and the misses look like absence rather than error.
4. **Record the rule and its measured coverage.** A rule without a number
   against it cannot be monitored.
5. **If nothing fires, ask the servicer** — and make the ask precise: name their
   portfolio id, the case count you expect, and the columns you have already
   ruled out.

---

## 8. Where it cannot work, and why

For five books — IT24010, IT24006, IT25014, DE24016, UK26004 — we can see the
CAT portfolio exists with 186–2,143 cases, the references are not hashed, and
**no combination of our ids against their columns matches a single row.** The
loans are there; the servicer keyed them on something we never receive.

No method recovers information that is not in the data. That is absence, not a
gap in cleverness, and it is what the 2024 work concluded.

For eleven more books there is no trace in Intrum CAT, Cerved, Gescobro or
Massey under any reference tested.

**Before chasing mappings for all of them:** nothing in the warehouse records
which of these books Brocc actually bought. The asset-index portfolio id appears
nowhere in `DIM_PORTFOLIO.DEAL_ID` (a hash) or `DIM_DEAL.deal_name`. A book we
only ran diligence on will never have servicer data, so part of the gap may be
unbridgeable by definition. Someone who knows the deal book can settle this in
minutes; the warehouse cannot.

---

## 9. Status of all 23 books

| Book | Seller | Cases | Bridged | Collections | Route |
|---|---|---|---|---|---|
| DE25010 | Deutsche Bank | 12,815 | 8,871 | 1,267 | file + derivable |
| DE25020 | Santander | 12,685 | 8,293 | 1,053 | file only |
| DE25023 | BAWAG | 7,052 | 4,936 | 1,014 | file + partly derivable |
| SE25008 | Santander | 12,160 | 6,267 | **0** | file only |
| CH25007 | Cembra | 4,439 | 3,064 | 182 | file only |
| ES25021 | Norwegian bank | 4,046 | 2,832 | 202 | file only |
| DE25021 | Ferratum | 1,085 | 760 | 207 | file + derivable |
| UK24020 | Shawbrook | 2,513 | — | — | **derivable, not built** |
| UK26004 | Abound | 1,175 | — | — | **derivable, not built** |
| IT24010 | ICCREA | 1,161 | — | — | in CAT, no key |
| IT24006 | Cariparma | 1,232 | — | — | in CAT, no key |
| IT25014 | BPER | 171 | — | — | in CAT, no key |
| DE24016 | Deutsche Bank | 19,644 | — | — | in CAT, no key |
| BE25002 | Hoist | 70,182 | — | — | no trace |
| UK26003 | Arrow | 47,913 | — | — | no trace |
| ES26101 | ING | 31,973 | — | — | weak rule (7%) |
| IT25019 | Intesa | 28,413 | — | — | no trace |
| UK26002 | Arrow | 12,037 | — | — | no trace |
| ES26106 | ING | 3,682 | — | — | weak rule (11%) |
| SE25013 | Norion | 3,325 | — | — | no trace |
| NL25004 | Santander | 745 | — | — | no trace |
| DE25015 | Funding Circle | 294 | — | — | no trace |
| NL25005 | Funding Circle | 190 | — | — | no trace |

⚠ **SE25008 has 6,267 bridged loans and zero collections**, unchanged since it
was first flagged a month ago. Either that book does not report into CAT or its
mapping is wrong. It is the largest single recoverable chunk here.

---

## 10. Queries

| File | Answers |
|---|---|
| `bridge_coverage_by_portfolio.sql` | how many deals, how many loans reach our case data |
| `collections_on_bridged_loans.sql` | which bridged loans actually have collections |
| `clientref_match_feasibility.sql` | which books `client_ref_1/_2` can reach |
| `cascade_match_feasibility.sql` | what a tiered waterfall adds over one rule |
| `scoped_amount_match.sql` | amount matching scoped to a portfolio, precision verified per book |
| `ref_case_bridge.sql` | the mapping to CAT with its gaps made visible |
| `benchmark_case_payments_monthly.sql` | the underwriting dataset, seller history + ours |

All read **brocc-sandbox**, not production. `mise` pins `SNOWFLAKE_WAREHOUSE` to
a prod warehouse that does not exist there and re-applies it inside `uv run`, so
bypass both:

```sh
cd ~/data-warehouse/local-workspace
env SNOWFLAKE_WAREHOUSE=DEV_WH .venv/bin/python \
    scripts/run_sql.py work/asset-index/cloud/<file>.sql --connection dev
```
