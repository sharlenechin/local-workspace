# Your stakeholder's metric pack — what we can build, and what we cannot

Every metric in the January 2025 servicer pack, checked against **RAW and
PROD** on 2026-09-14.

## The headline

**No — not everything is there from PROD. But far more is there in RAW than
anyone has modelled.**

That is the important finding. PROD models **26 tables**. RAW's Intrum CAT feed
has **35**, and the nine that are missing are exactly the nine the stakeholder
is asking about:

| RAW table | Rows | Holds | Modelled in PROD? |
|---|---|---|---|
| `ACTIONS` | **10,634,995,035** | attempts, contacts, SMS, mail, letters, RPC | ❌ |
| `GROUP_CASE_PHASE` | 345,991,377 | **amicable / legal / other phase** | ❌ |
| `INSTALLMENT` | 1,066,880,383 | **payment plans** — created, cancelled, ended | ⚠️ staging exists but drops the dates |
| `INSTALLMENT_PLAN_ITEM` | 757,912,850 | plan instalments | ❌ |
| `CASE_STATUS_CHANGE_HISTORY` | 6,074,801,423 | status over time | ❌ |
| `LEGAL_STEPS` | 41,089,199 | legal track | ❌ |
| `LEGAL_INFO` / `LEGAL_RESULT_INFO` | 24.5m / 35.2m | legal detail and outcome | ❌ |
| `BANKRUPTCY_RECORD` | 3,737,954 | **BK track** | ❌ |
| `SETTLEMENT` | 8,689,953 | settlements | ❌ |
| `ORANGE_SLA_BP` / `NEW_ORANGE_SLA_BP` | 36.9m / 6.9m | **the servicer business plan (% BP)** | ❌ |

So the answer to "is everything there from raw" is: **the rows exist; the
models and, critically, the code dictionaries do not.**

---

## The three dictionaries that unblock almost everything

Three lookup files from Intrum would move most of the ❌ rows below to ✅.
None of them is a big ask, and each one is worth a page of the dashboard.

### 1. `GROUP_PHASE_CODE` — the amicable / legal split ⭐ closest to ready

This is the promising one. The codes have a **readable prefix structure**:

| Prefix | Codes seen | Cases (largest instances) | Reads as |
|---|---|---|---|
| `A` | A000, A001, A002, A006 | 3.28m (7006), 3.14m (4042), 1.80m (3010) | **Amicable** |
| `L` | L000, L002, L003 | 1.67m (1033), 481k (4042), 464k (7006) | **Legal** |
| `E` | E002, E003, E005, E006 | 1.68m (1033), 579k (2020) | **unknown — third track** |
| `NA` | — | 2.77m (1033), 1.52m (2080) | not assigned |

⚠ **A = Amicable and L = Legal is my reading of the prefixes, not a documented
fact.** It is a strong reading, and `E` is genuinely unknown — it could be
enforcement, insolvency, or something else entirely. **Do not put this split on
a dashboard until Intrum confirms the mapping.** One email.

⚠ Also note **instance 4050 (Portugal) has only `A000`** — a single phase, no
differentiation at all. The split is rich in Spain, Greece and Italy and
absent in Portugal. So this metric will be blank for some books whatever
happens.

### 2. `ACTION_CODE` / `ACTION_CLASSIFICATION` — the whole Activity block

**Completely opaque, and there is no pattern to read.** Sampled on Portugal:

```
ACTION_CODE:            G_1, G_16, G_28, G_36, G_10001, G_10000, 99997, 1001
ACTION_CLASSIFICATION:  5, 3, 12, 1, 7, 9, 23, 15
```

980m rows carry no classification at all. Without the dictionary there is no
way to tell an SMS from a letter from a phone call, so **every metric in the
Activity section is blocked** — attempts, contacts, accounts contacted, spin
rate, RPC, SMS, mail, letter.

The data is there — 10.6bn rows of it. Only the labels are missing.

### 3. `STATUS_CODE` — 76 codes, and **part of the dictionary is already in-house**

99.6% populated, `STATUS_DESCRIPTION` 100% NULL in the warehouse. But
`int_npl_forbearance_intrum.sql` in `brocc-data` carries seven decoded codes
**in its comments** — `23` Settlement payment plan, `24` Settlement, `29`
Payment plan, `313` Settlement offer, `315` Restructuring of debt, `35` Debt
reconstruction plan, `56` Payment plan.

Someone on the data team got that from Intrum. **Ask them for the full list
before emailing Intrum** — it may already exist, and every one of those seven
is amicable-track.

---

## Metric by metric

**✅ buildable now** · **⚠️ buildable from RAW, needs new models** ·
**❌ blocked on a dictionary**

### Performance

| Metric | Status | Source |
|---|---|---|
| Collections | ✅ | `dash_servicer_scorecard.sql` |
| % BP | ✅ | vs underwriting plan — ⚠️ **from 2025-06 only** ([FLAGS.md §3](FLAGS.md)) |
| Decay | ✅ | `collections_prior_month_eur` on the same row |

⚠ "% BP" in the servicer's own pack probably means **their** business plan
(`ORANGE_SLA_BP` in RAW), not our underwriting plan. Those are different
numbers and will not agree. Confirm which one the stakeholder means.

### Split collections — **the section the pack is built around**

| Metric | Status | Source |
|---|---|---|
| € / % Amicable, Legal, BK | 🟡 **built, labels unconfirmed** | `raw/dash_phase_collections.sql` |
| # payments, Avg payment | ✅ | `prod/dash_servicer_scorecard.sql` |
| # / Avg Legal, Amicable, BK payments | 🟡 **built, labels unconfirmed** | same file |

### 🟡 The split now EXISTS — built and run 2026-09-14

`work/data-issues/intrum/queries/dash_phase_collections.sql` joins RAW
`GROUP_CASE_PHASE` (the phase in force on each payment's own date) to PROD
collections. Run over the three months to 2026-08-31:

| Phase | Collections | Payments | Avg payment |
|---|---|---|---|
| E (execution — confirmed 2026-09-15; was labelled unknown) | EUR 20,318,751.16 | 525,757 | EUR 38.65 |
| **A (amicable?)** | EUR 18,647,791.62 | 191,256 | **EUR 97.50** |
| **L (legal?)** | EUR 11,788,394.98 | 65,502 | **EUR 179.97** |
| unassigned | EUR 10,747,671.06 | 291,635 | EUR 36.85 |

⚠ **The average payment sizes corroborate the reading.** Legal recovers fewer,
larger lumps (EUR 180) and amicable more, smaller instalments (EUR 98) — which
is what those two processes actually look like. That is **evidence, not
proof**, and the labels keep their question marks until Intrum confirms.

⚠ **`E` is a third of the phased money and completely unknown** — 525,757
payments at EUR 38.65 across 15 portfolios, the highest-frequency track of all.
**This is now the single most valuable question to put to Intrum**, ahead of
the A/L confirmation.

⚠ **Coverage is ~53%** of the 3-month collections total, because it inherits
the loan feed's reach (135 of 250 portfolios). `percent_of_reported_phased` on
every row measures it. A portfolio absent here is absent from the feed, **not
at zero**.

⚠ BK may be better served by `BANKRUPTCY_RECORD` than by an `E` phase code.
On the Portugal book that table covered 4.87% of loans with **every date in a
23-month window** and a 100% NULL end date — so it is thin. Check coverage on
the books that matter before promising it.

### Payers / promises generation

| Metric | Status | Source |
|---|---|---|
| # Payers, New, Lost, Recurrent | ✅ | `dash_servicer_scorecard.sql` |
| Collections / Original Capital | ✅ | `CASES.ORIGINAL_CAPITAL` (raw) or portfolio GBV |
| # / € New payment plans | ⚠️ | `INSTALLMENT.CREATION_DATE` |
| # / € Payment plans in force | ⚠️ | `INSTALLMENT` open at month-end |
| # / € Cancelled cases | ⚠️ | `INSTALLMENT.CANCEL_DATE` |
| Average Payment Plan (€) | ⚠️ | `INSTALLMENT` |
| Average Payment Plan Length | ⚠️ | `END_DATE − CREATION_DATE` |
| # Promises generation | ❌ | no clear source; may be an `ACTION_CODE` |

The payment-plan block is the **best RAW opportunity after the phase split**:
`INSTALLMENT` carries `CREATION_DATE`, `CANCEL_DATE`, `END_DATE`,
`DATE_OF_LAST_PAYMENT` and an amount. Those five columns give six of the seven
metrics with **no dictionary needed** — dates and amounts, not codes.

⚠⚠ **And it is cheaper than it looks.** `stg_intrum_cat__installment` already
exists in `brocc-data` — it just selects seven columns and **drops
`CANCEL_DATE`, `END_DATE`, `DATE_OF_LAST_PAYMENT` and the amounts**. That is
why `FCT_CASE_FORBEARANCE` has no end date: the staging model never selected
one, not because the source lacks it. Widening that one model unlocks plan
length, cure and re-default as well as the six pack metrics.

### Activity

| Metric | Status |
|---|---|
| # Accounts | ✅ `dash_servicer_scorecard.sql` |
| # Attempts, Contacts, Accounts contacted | ❌ dictionary 2 |
| Spin rate, # RPC | ❌ dictionary 2 |
| # SMS, mail, letter | ❌ dictionary 2 |

**One dictionary unblocks this entire section.**

---

## Scoring the pack

| | Metrics | Share |
|---|---|---|
| ✅ Buildable now | 11 | ~34% |
| ⚠️ Buildable from RAW, needs new dbt models | 12 | ~38% |
| ❌ Blocked on a code dictionary | 9 | ~28% |

**About a third today, two thirds after a modelling sprint, and the last third
turns on emails to Intrum rather than engineering.**

---

## What this means for `work/servicing`

You want that folder to be the set of monthly queries that become dbt tables.
Today it is **PROD-only**, and this pack is the proof that PROD-only is not
enough — the operational half of the servicing story is in RAW and unmodelled.

So the folder needs a second tier it does not currently have:

```
work/servicing/
├─ (today)  PROD-sourced monthly + agg queries   → marts
└─ (needed) RAW-sourced operational queries      → staging + intermediate first
```

⚠ **The RAW-sourced ones cannot be written the same way.** Every RAW Intrum
table is a change-history feed with the same traps Project Elsa documented:
147× fan-out on cases, sign-flipped amounts, `CASE_ID` unique only within an
instance, `_file_path` prefix pruning as the only affordable filter. `ACTIONS`
is 10.6bn rows — larger than the transaction feed that took 9 minutes.
`work/benchmark-dataset/post-registration-benchmark/METHOD.md` already has those guards written down;
a RAW operational model set should start from them, not from scratch.

**My recommendation on sequencing**, cheapest-first and each step independently
useful:

1. **Ship the PROD third now.** `dash_servicer_scorecard.sql` exists and
   compiles. It gives the stakeholder Performance, Payers and # Accounts
   against real numbers this week.
2. **Send the three dictionary requests.** Zero engineering, and the phase one
   may come back decodable enough to unblock the whole Split Collections
   section.
3. **Model `INSTALLMENT`.** No dictionary needed — dates and amounts only —
   and it delivers six metrics.
4. **Model `GROUP_CASE_PHASE`** once the mapping is confirmed.
5. **Model `ACTIONS` last.** Biggest table, fully blocked until the dictionary
   arrives, and the least decision-relevant of the four.

---

## What to say to the stakeholder

> About a third of the pack we can show you now, from production data. Another
> third exists in the servicer's raw feed but has never been modelled — payment
> plans, the amicable/legal split, the legal and bankruptcy tracks. The last
> third, the whole activity section, is sitting in a ten-billion-row table that
> we cannot read because Intrum has never sent us the code list. Three emails
> and a modelling sprint gets you the whole pack; one email might get you the
> amicable/legal split on its own.

⚠ And one definition to settle first: **"% BP" against whose plan** — Intrum's
own business plan, or our underwriting case? Both exist, they will not agree,
and the difference is the point of the metric.
