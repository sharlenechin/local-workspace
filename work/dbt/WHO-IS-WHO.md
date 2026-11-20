# Who is who — originator, seller, servicer, and what we can actually prove

Measured **2026-10-09** against PROD and RAW, plus the Atlas source definition in
`brocc-data/transformation/dbt/models/staging/atlas/source.yml`.

Written because the review asked whether `dim_npl_counterparty` should become
`dim_npl_servicer` + `dim_npl_originator`. The answer turns on what each role
actually carries, and the four roles are not alike.

---

## The picture

```
                  WHO MADE THE LOAN            WHO SOLD IT TO US         WHO COLLECTS IT
                  ──────────────────           ─────────────────         ───────────────
                      ORIGINATOR          →         SELLER         →        SERVICER
                   (the bank)                   (anyone in the chain)   (contracted, or appointed)


  62 of 74 deals ── we bought DIRECT from the bank ───────────────────────────────────
                                                                   
        BANK  ═══════════════════════════════════▶  BROCC          serviced by Intrum (39)
         │                                                         or Massey (2)
         └── originator AND seller are the SAME company            or nothing yet (21)
             Atlas seller_id ✓  a real company key
             lands today as DIM_DEAL.SELLER_NAME


  12 of 74 deals ── Intrum bought it first, then sold to us ─────────────────────────
                                                                   
        BANK  ─ ─ ─ ─ ─ ▶  INTRUM  ═══════════════▶  BROCC          serviced by Intrum
         │       hop 1       │        hop 2
         │                   └── seller = Intrum.  Atlas seller_id ✓
         │
         └── originator is NOT in Atlas at all.
             Only PAM.SELLER_NAME — free text, no id,
             and it means "whoever Intrum bought from",
             which may not be the bank.

        ╳ anything before hop 1 is UNOBSERVABLE — all six CAT fields are 100% empty
```

**The one-line version:** the originator is a proper company key on 84% of deals
and an unjoinable string on the other 16% — and that 16% is Portugal, the book
being underwritten.

---

## What each role carries

| Role | Key? | Attributes beyond the name | Source | Reaches a mart today? |
|---|---|---|---|---|
| **Seller** (sold to us) | ✅ `seller_id` | name, address | Atlas | ✅ `DIM_DEAL.SELLER_NAME` |
| **Servicer** (contracted) | ✅ `servicer_id` | name, address | Atlas | ❌ **dies at staging** |
| **Originator** (made the loan) | ❌ **none** | **none** | PAM `SELLER_NAME`, text | ❌ dropped at `dim_npl_batch` |
| **Agency** (appointed) | ✅ `external_collector_id` | **none — a bare number** | CAT | ❌ not modelled |
| **Internal team** | ✅ `collector_ij` | **none** | CAT | ❌ not modelled |

⚠ **`companies_company` in Atlas has exactly three columns: `id`, `name`,
`address`.** Its own description says *"Can be any type of entity: sellers,
buyers, servicers, etc."* — **one list, role assigned by whichever FK points at
it.**

So `dim_npl_servicer` and `dim_npl_originator` would be **the same three
columns**. Role is a property of the relationship, not of the company.

---

## The issues, in order of how much they cost

**1 · Atlas records no originator and no prior owner.** Searched the whole
source definition for `origin`, `prior`, `previous`, `creditor`, `chain`,
`transfer` — **zero matches**. The seven company fields are `seller_id`,
`servicer_id`, `second_servicer_id`, `legal_buyer_id`, `coinvestor_id` on the
deal, and `servicer_id`, `legal_buyer_id` on the batch-segment. That is all.

**2 · The originator has no key, and its names are dirty.** PAM carries
`SELLER_NAME` and **no seller id**. 1,360 distinct names, **1,348** once
uppercased and trimmed — 12 are pure casing duplicates. In Portugal alone
`MILLENNIUM` (11 batches) sits beside `Millennium` (3), and `Barclays` (20)
beside `Barclaycard` (14). Left as raw text these never add up.

**3 · A secondary transaction can be traced two hops at most**, and the second
hop only on the 12 Intrum deals, as a name and a date
(`PAM.SELLER_NAME` + `legacy_capex_date`). Earlier hops are unobservable:
`init_creditor_id`, `int_creditor_id`, `case_buyer`, `real_client_name`,
`contract_entity`, `ownership_transfer_date` are **all 100% empty across
1,156,769 Portuguese cases**. The model must not claim a chain length it cannot
see.

**4 · The servicer key we already receive is thrown away.**
`servicer_id`, `second_servicer_id` and `coinvestor_id` are selected in
`stg_atlas__deals_deal` and read by **no** non-staging model.
(⚠ `seller_id` **is** read — see the correction below.)

**5 · Agencies are ids with no names.** 190 distinct `external_collector_id` on
374,544 of 1,156,769 loans (32.38%), and **261 have appeared across the feed's
history** — so they change. 79 internal teams now, 127 ever. No name anywhere
in the feed, so no dimension can be built until Intrum sends a lookup.

---

## What this implies for the model

- **One company table, not two.** Call it `dim_npl_company` rather than
  counterparty — plainer, and it stops implying a role. Three columns, because
  that is all Atlas has.
- **Role on the relationship:** `seller_company_sk` on the deal,
  `servicer_company_sk` on the portfolio version.
- **Originator is NOT a company reference.** It is a conformed *name* from the
  servicer's feed and needs a seed mapping the raw strings to canonical
  originators. This is the part of the review's instinct the data supports.
- **The servicer dimension comes from `deals_batch_segment.servicer_id`**,
  resolved through `companies_company`. Keyed, Atlas-mastered, and at
  batch-segment grain — the finest level Atlas sets anything at, so two
  portfolios in one deal can differ. This is recovering a key we already
  receive, not sourcing something new.
- **Agency stays degenerate** — the id on the case, no table.

---

## ⚠ A correction to the NPL Pipeline Change Map

The `atlas` box on the architecture map says:

> *Three of its company keys die at staging: `servicer_id`, `second_servicer_id`
> and `seller_id` are selected and read by nothing. Only `legal_buyer_id`
> reaches a mart.*

**`seller_id` does reach a mart.** `int_npl_deal_atlas` left-joins it to
`companies_company` and surfaces the name as `DIM_DEAL.SELLER_NAME` — the column
the 62/12 split above is measured from. It is **two** keys that die
(`servicer_id`, `second_servicer_id`), plus `coinvestor_id`.

---

## Not yet verified

**What PAM's `SELLER_NAME` contains for the 39 deals we bought direct but Intrum
services.** Intrum never bought those books, so the field may name the bank
(corroborating Atlas), name us, or be empty. Measure before treating PAM as an
originator source for anything but the 12 Intrum-purchased deals.
