# Data Landscape — the workbook, and how to get the data yourself

Two things in one file:

- **Part A** — how to read `data_landscape.xlsx`, and what its words mean.
- **Part B** — **where every attribute physically lives and how to query it.** Templates
  you can paste and adapt. This is the part the workbook does not contain.

The workbook is a snapshot measured **2026-11-04**. Part B is how you refresh any of it,
or go past it.

---

# Part A — reading the workbook

## The answer, in three numbers

| | Deals | Why |
|---|---:|---|
| We own | **2,674** | Every book in the portfolio |
| Modellable **from the day we bought** | **1,043** | Servicer sends loan-level data and it reconciles |
| Modellable **from origination** | **8** | The above, plus a seller tape that joins and carries earlier payments |

| Measure | Owned | Modellable from purchase | Share |
|---|---:|---:|---:|
| Deals | 2,674 | 1,043 | 39.0% |
| Cases (individual loans) | 26,384,197 | 15,694,190 | 59.5% |
| Balance (EUR at acquisition) | €45.81bn | €22.22bn | 48.5% |

The modellable deals are the **larger** books, so deals understate coverage and cases
overstate it. Say which you mean.

## Two timelines: (R) and (F)

Several tabs come in an **(R)** and an **(F)** pair. Two populations, not two views.

| | **(R) post-Registration** | **(F) Full timeline** |
|---|:---:|:---:|
| Servicer sends a row per loan | ✓ | ✓ |
| Collections reconcile to the servicer's own report | ✓ | ✓ |
| We hold the seller's diligence tape | — | ✓ |
| That tape links to 80%+ of the loans | — | ✓ |
| Dated payments from before registration | — | ✓ |
| **Deals** | **1,043** | **8** |
| **Markets with at least one** | 34 of 39 | 7 of 39 |

(F) is a strict subset of (R). **"Ready" always means whichever timeline the tab is
about** — it is never an absolute.

### The six gates

| Step | Deals | Cases | Balance | Median debt age | Median attributes |
|---|---:|---:|---:|---:|---:|
| 1. Deals we own | 2,674 | 26,384,197 | €45.81bn | 16.0 yrs | 10 |
| 2. Servicer sends loan-level data | 2,378 | 25,001,923 | €32.83bn | 16.1 yrs | 10 |
| 3. Collections reconcile ← **(R)** | 1,043 | 15,694,190 | €22.22bn | 14.3 yrs | 14 |
| 4. We hold the seller tape | 32 | 812,055 | €3.53bn | 7.7 yrs | 20 |
| 5. Tape links to 80% of loans | 15 | 695,384 | €2.83bn | 7.7 yrs | 20 |
| 6. Payments from before registration ← **(F)** | 8 | 392,218 | €837.4m | 4.0 yrs | 24 |

⚠ **Step 4 says 32, but we hold 60 tapes.** The other 28 failed step 2 or 3 — 5 have no
feed, 23 have one whose collections don't reconcile. Ungated, 23 of the 60 bridge 80%+
and **27 carry pre-registration payments**. So the early history exists on 27 deals and
is usable on 8. **The blocker is reconciliation and bridging, not missing tapes.**

⚠ **The 8 full-timeline deals are 4-year-old debt against a book median of 16 years.**
Not a representative sample.

## Tabs

**Answers:** `Summary` · `1a Deal Readiness` (per deal) · `1b By Market (R)` / `(F)`
(per market, 39) · `2a By Attribute` (per country × attribute, 136) ·
`2b By Market and Attribute (R)` (2,390) · `2c … (F)` (494).

**Reference:** `A Country Attributes` (legal, per country) · `B General Attributes` ·
`C Deals We Own` (per deal: price, cases, balance).

**Evidence grids** — D is the seller's tape, E is the servicer feed and our warehouse:
`D1 Found` · `D2 Filled` · `D3 Fill Rates` · `D4 Evidence` · `D5 Unreadable Files` ·
`E1 Servicer Feed` · `E2 Warehouse` · `E3 Warehouse Filled` · `E4 Reconciliation` ·
**`E5 Column Map`**.

**`Guide`** defines every cell label. **`Data Dictionary`** defines every column of every
tab — read it before interpreting anything.

> **`E5 Column Map` is the tab that matters for Part B.** It lists, per attribute, the
> raw servicer column and the warehouse column. Part B tells you how to query them.

## Terms

**Deal** — one purchased portfolio, keyed `VEHICLE-ID` (`HEI-PT13982`). 2,674.
**Case** — one loan within a deal. 26.4m. Six deals have no case count recorded.
**Market** — country × sector, e.g. `SE · Financial Services`. 39.
**Sector** — *Financial Services* (debt began as credit), *Non-Financial Services* (began
as an unpaid bill; insurance sits here, the claim being an unpaid premium), or
*Unclassified*. ⚠ Unclassified is 757 deals — **28% of the book** — so sector comparisons
are really over 1,917 deals.
**Attribute** — one fact we want about a loan or borrower. 107 of them; 56–61 apply to any
one deal, depending on country.
**In scope** — could apply to this deal given its country.
**Usable** — present **and populated**: *Found* on the tape, or *Found in a Table* and
90%+ populated in the feed.
**Either side counts** — tape OR feed. The tape and feed columns overlap and can sum to
more than the total.
**Bridge** — the join between the seller's loan ids and the servicer's case ids. 80% is
the threshold used here.
**Registration** — when the servicer registered the case, roughly when we took the book on.
**Debt age** — years from the borrower's default to today. Median 16.0. ⚠ Not how long
we have held it (median 13.9).
**Median attributes** — the **middle deal's** count, excluding the 13 payment columns.
Not a total, not a mean.

---

# Part B — getting the data

## B1. Start in NPL_COMMON

**`PROD.NPL_COMMON` is the default. Go to the raw feed only for what dbt does not carry,
and say so when you do.**

That is not a style preference. The raw feed is a change history with ~147× the case rows
and ~11× the transaction rows of the current state, amounts sign-flipped against the
warehouse, a third of payment dates null, and `case_id` values that repeat across servicer
instances. dbt has already deduplicated, conformed and bounded all of that. Querying raw
means re-implementing those guards yourself, and getting one wrong is silent.

| Source | What it is | Grain | Reach for it when |
|---|---|---|---|
| **`PROD.NPL_COMMON`** | The servicer feed, modelled by dbt | case / batch | **Always first** |
| `RAW.HYPERION_INTRUM_CAT` | The same feed, unmodelled | case, change history | The warehouse has dropped the column |
| PAM tables in `PROD.NPL_COMMON` | The servicer's own monthly report | batch × month | Reconciling, or a batch-level figure |
| Seller diligence tapes | Pre-purchase files, 60 deals | loan | Anything before we bought |

All read-only. Tables are built by the dbt project, never from a notebook or ad-hoc SQL.

### The NPL_COMMON tables you will actually use

| Table | Grain | What it answers | Attributes it carries |
|---|---|---|---|
| `DIM_CASE` | one row per case **per SCD version** | Dates, balances, status, secured flag | 13 |
| `FCT_CASE_COLLECTION` | one row per payment | All cash: sums, counts, first and last payment | 12 |
| `FCT_CASE_SNAPSHOT_DAILY` | **month-end**, per case | Product, segment, currency, country, forbearance — **and the only case→deal link** | 5 |
| `DIM_BATCH` | one row per batch | Seller, servicer, deal type, capex date and amount | 5 |
| `DIM_BORROWER` | one row per borrower | Gender, legal type, credit rating | 4 |
| `BRG_CASE_BORROWER` | case ↔ borrower | Co-borrowers, borrowers with several cases | 1 |
| `DIM_PORTFOLIO` | one row per portfolio | Purchase price | 1 |
| `FCT_PORTFOLIO_SNAPSHOT_MONTHLY` | batch × month | The servicer's own reported collections — the reconciliation yardstick | 1 |

⚠ Three names that mislead: `FCT_CASE_SNAPSHOT_DAILY` is **month-end**, not daily;
`DIM_CASE` is an **SCD**, so it has several rows per case; and `CASE_BK` is **not** a row
key — join on `case_id`.

### How much of the 107 attributes NPL_COMMON covers

| | Attributes | What it means |
|---|---:|---|
| In NPL_COMMON | **42** | Query the warehouse; 36 of these are also in raw |
| Raw only — dbt drops them | **53** | The warehouse cannot answer; see B7 |
| In neither | 12 | Not recoverable from the servicer at all |

By grain, of the 42: **23 are case level**, 12 are collections, 6 are batch level, 1 is
the servicer's monthly report. Only the case-level ones can be modelled per loan without
an allocation.

> The workbook's `Summary` tab says **51** attributes are dropped, against 53 here. The
> two count slightly differently — `E2` counts what its own labels classify as dropped,
> this counts every attribute with a raw column and no warehouse column. Use 53 when
> deciding what to query, 51 when quoting the workbook.

### What is raw-only, by theme

Knowing the shape saves you looking each one up:

| Raw table | Attributes | Theme |
|---|---:|---|
| `CASES` | 32 | Cut-off balances, interest rate, origination, titles, judgements, restructuring |
| `DEBTORS` | 8 | Contactability, occupation, income, address-known, attachment |
| `LEGAL_STEPS` / `LEGAL_INFO` | 7 | **The entire legal and enforcement family** |
| `BANKRUPTCY_RECORD` | 2 | Insolvency open dates |
| `ASSIGNMENT`, `DEBTOR_ADDITIONAL_INFO`, `INVOICES` | 4 | Prior ownership, birth date, fees and last payment |

**If the question is legal or enforcement, the warehouse has nothing** — those 7 go
straight to raw. Likewise borrower detail beyond gender, legal type and credit rating.

Those 53 are a dbt change, not a servicer request: the data already arrives. That makes
them the cheapest wins on the list, and worth raising with the data team rather than
routing more consumers to raw.

## B2. The deal key — get this right first

There is no single deal id column. The key is `VEHICLE-ID`, built differently per vehicle:

```sql
-- The deal spine. Every query below starts from this.
-- GRAIN  one row per batch, carrying the deal it belongs to.
WITH batch AS (

    SELECT
        b.batch_sk,
        -- ORG batches carry no deal source of their own; the Atlas key starts with it.
        COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) AS vehicle,
        -- Heimdall's Atlas portfolio is a whole country's umbrella (HEI-SE25001 holds
        -- every Swedish Heimdall deal), so only the servicer's id names the deal there.
        -- Every other vehicle uses the Atlas id.
        COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) || '-' || IFF(
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
            b.servicer_parent_portfolio_bk,
            SUBSTR(p.portfolio_bk, 5, 7)
        ) AS deal_id
    FROM prod.npl_common.dim_batch AS b
    LEFT JOIN prod.npl_common.dim_portfolio AS p
        ON p.portfolio_sk = b.portfolio_sk
)
SELECT deal_id, COUNT(*) AS batches
FROM batch
WHERE deal_id IS NOT NULL   -- one Gescobro batch maps to no Atlas portfolio
GROUP BY 1;
```

⚠ **`DIM_CASE` does not carry the deal.** To get from a case to its deal you must go
through the snapshot fact:

```sql
-- Case to deal. The only link that exists.
    case_deal AS (

        SELECT DISTINCT
            s.case_id,
            b.deal_id
        FROM prod.npl_common.fct_case_snapshot_daily AS s
        INNER JOIN batch AS b
            ON b.batch_sk = s.batch_sk
)
```

⚠ `FCT_CASE_SNAPSHOT_DAILY` is **month-end grain** despite the name.
⚠ `DIM_CASE` is an SCD — always filter `is_current_flag` unless you want history.

## B3. Template: pull any case-level attribute for a deal

Swap the column from the map in B6.

```sql
-- One attribute, per case, for one deal.
-- GRAIN  one row per case.
WITH batch AS (...),          -- from B2
    case_deal AS (...)        -- from B2

SELECT
    d.deal_id,
    c.case_bk,
    c.default_date,           -- <- the attribute you want, from the B6 map
    c.registration_date
FROM case_deal AS d
INNER JOIN prod.npl_common.dim_case AS c
    ON c.case_id = d.case_id
    AND c.is_current_flag     -- SCD: without this you get every version
WHERE d.deal_id = 'HEI-PT13982';
```

⚠ Join `DIM_CASE` on `case_id`, **not** `case_bk`. `CASE_BK` is not a row key.

## B4. Template: collections, with the guards they need

```sql
-- Collections per deal. Three guards, each for a measured reason.
-- GRAIN  one row per deal.
WITH batch AS (...), case_deal AS (...)

SELECT
    d.deal_id,
    COUNT(DISTINCT d.case_id)                 AS paying_cases,
    SUM(f.amount)                             AS collected,
    MIN(f.collection_date)                    AS first_payment,
    MAX(f.collection_date)                    AS last_payment
FROM case_deal AS d
INNER JOIN prod.npl_common.fct_case_collection AS f
    ON f.case_id = d.case_id
-- 841 rows are dated out to the year 4570. Never leave this bound off.
WHERE f.collection_date <= CURRENT_DATE
GROUP BY 1;
```

⚠ This feed **begins in 2014**. dbt joins collections to each case's first SCD version and
the servicer's case feed starts 2014-05-23, so a case registered earlier cannot show an
earlier payment even if one happened. This is why pre-registration payment history is
understated on old books, and it is a known upstream issue, not a query bug.

## B5. Template: reconcile against the servicer's own report

This is gate 3 — the test that decides 1,043 deals.

```sql
-- Our collections against the servicer's own monthly report, over months both cover.
-- A deal reconciles when it has 80%+ of the months AND lands within +/-10% on cash.
-- GRAIN  one row per deal.
SELECT
    deal_id,
    cat_collected,
    pam_collected,
    cat_months / NULLIF(pam_months, 0)      AS months_ratio,
    cat_collected / NULLIF(pam_collected, 0) AS collections_ratio,
    months_ratio >= 0.8
        AND ABS(collections_ratio - 1) <= 0.10 AS reconciles
FROM ...;   -- both sides summed per deal over the overlapping months only
```

⚠ **Cut the servicer's report at its own extract month.** It carries forecast months
beyond that, which would inflate the denominator.
⚠ The report collapses currency — convert before comparing across countries.

## B6. Where each attribute lives

The full 107-row map is the **`E5 Column Map`** tab. The shape of it:

| Attribute | Raw servicer feed | Warehouse (`PROD.NPL_COMMON`) |
|---|---|---|
| `age` | `DEBTOR_ADDITIONAL_INFO.birthdate / birthyear` | — *(dropped by dbt)* |
| `gender` | `DEBTORS.gender` | `DIM_BORROWER.gender` |
| `individual_vs_corporate` | `DEBTORS.legal_type` | `DIM_BORROWER.legal_eba_type` |
| `credit_score` | `CASES.score` / `DEBTORS.credit_rating` | `DIM_BORROWER.credit_rating` |
| `origination_date` | `CASES.origination_date_at_client` | `DIM_CASE.origination_date` |
| `default_date` | `CASES.default_date` | `DIM_CASE.default_date` |
| `debt_age` | `CASES.age_of_debt` | `DIM_CASE.default_date` + `registration_date` |
| `registration_date` | `CASES.registration_date` | `DIM_CASE.registration_date` |
| `registration_principal` | `CASES.original_capital` | `DIM_CASE.original_principal` |
| `cut_off_balance` | `CASES.face_value_at_cutoff` | — |
| `interest_rate` | `CASES.interest_rate` | — |
| `account_status` | `CASES.main_status_code / closing_date` | `DIM_CASE.status_code` |
| `has_collateral` | `CASES.is_secured` | `DIM_CASE.secured_flag` |
| `insolvency_flag` | `BANKRUPTCY_RECORD.insolvency_open_date` | `DIM_CASE.status_code` *(the lookup decodes it)* |
| `product_type` | `CASES.product_id` | `FCT_CASE_SNAPSHOT_DAILY.product_sk → DIM_PRODUCT` |
| `currency` / `country` | `TRANSACTIONS.currency` / `DEBTORS.country_code` | `FCT_CASE_SNAPSHOT_DAILY.currency_id` / `country_id` |
| `payment_plan_flag` | `INSTALLMENT.installment_id` | `FCT_CASE_SNAPSHOT_DAILY.forbearance_flag` |
| `seller_name` | `CASES.portfolio_sellers_name` | `DIM_BATCH.legal_seller_name` *(batch level)* |
| `purchase_price` | — *(ours is in Atlas)* | `DIM_PORTFOLIO.price_gross` *(batch level)* |
| collections, any | `TRANSACTIONS.amount` | `FCT_CASE_COLLECTION.amount` |
| legal / enforcement flags | `LEGAL_STEPS.legal_step`, `LEGAL_INFO.*`, `CASES.is_titled`, `CASES.judgement_date` | — *(none reach the warehouse)* |

Three things that map explains:

- **A dash in the warehouse column is the finding**, not a gap in the research. 51
  attributes arrive from the servicer and are dropped before our warehouse. Those are a
  dbt change, not a servicer request — the fastest wins on the list.
- **Batch-level attributes are not case-level.** Price, seller and capex live on
  `DIM_BATCH` / `DIM_PORTFOLIO`, one row per batch. Splitting them to a loan needs an
  allocation nobody has agreed, so the workbook counts them as not found at case level.
- **Every legal and enforcement attribute is raw-only.** If you need them, query
  `RAW.HYPERION_INTRUM_CAT`, not the warehouse.

## B7. Querying the raw feed

Only when the warehouse has dropped what you need.

```sql
-- The raw servicer feed. A change history: a case appears once per extract it changed in.
SELECT
    LEFT(long_portfolio_id, 7) AS servicer_deal_id,
    COUNT(DISTINCT case_id)    AS cases
FROM raw.hyperion_intrum_cat.cases
-- _file_path as a LITERAL PREFIX is the only pruning available on this table.
-- A leading wildcard scans all 6.5bn rows.
WHERE _file_path LIKE 'data-prod-data-raw-sftp-071269be/intrum/cat.%'
GROUP BY 1;
```

⚠ **`case_id` is unique only within one servicer instance.** Two instances can hold the
same `case_id` for different cases — put the instance in the join key, never `case_id`
alone. Some books are split across two instances.
⚠ It is a **change history**: ~147× the case rows and ~11× the transaction rows of the
current state. Deduplicate, or count distinct.
⚠ **Transaction amounts are sign-flipped** against the warehouse.
⚠ **35% of raw payments have a null transaction date** — never bound the date on the raw
feed, or you silently drop a third of the cash.
⚠ The raw `DEFAULT_DATE` is 100% null. Use `DIM_CASE` for that one.
⚠ The newest extract is a delta, so "latest file" returns almost nothing.

## B8. Measuring debt age

Not in the workbook's grids — those only record whether a default date *exists*. This is
how the 16.0-year figure was measured:

```sql
-- Years from the borrower's default to today, per deal.
-- GRAIN  one row per deal. A quarter of cases carry no default date and are excluded,
--        not counted as age zero, so cases_with_default_date shows a thin denominator.
WITH batch AS (...), case_deal AS (...)

SELECT
    d.deal_id,
    COUNT(*) AS cases_with_default_date,
    -- Median, not mean: a handful of placeholder dates would drag a mean by years.
    ROUND(MEDIAN(DATEDIFF('day', c.default_date, CURRENT_DATE)) / 365.25, 5)
        AS median_debt_age_years
FROM case_deal AS d
INNER JOIN prod.npl_common.dim_case AS c
    ON c.case_id = d.case_id
    AND c.is_current_flag
WHERE c.default_date IS NOT NULL
    -- Guards, not convenience: a default cannot predate consumer credit in these
    -- markets, and cannot be in the future. Both appear in this column.
    AND c.default_date BETWEEN '1980-01-01' AND CURRENT_DATE
GROUP BY 1;
```

Runs in about 40 seconds over 2,383 deals.

## B9. Check the column against the dbt model before you trust it

**The dbt project is the authority on what any `NPL_COMMON` column means.** Everything in
this README, and everything in the workbook, is a reading of it from the outside. The
models are owned and reviewed by the data team, with CODEOWNERS and CI on the repo, so
where this file and a model disagree, **the model is right and this file is stale.**

Check before you build on a column — a name rarely tells you what a column survived.

### Finding the model behind a table

Warehouse table names drop the `npl` that the model file keeps, and the mart sets the
final name with an `alias`:

| Warehouse table | Model file |
|---|---|
| `NPL_COMMON.DIM_CASE` | `models/marts/npl_common/dimensions/dim_npl_case.sql` |
| `NPL_COMMON.DIM_BATCH` | `models/marts/npl_common/dimensions/dim_npl_batch.sql` |
| `NPL_COMMON.DIM_BORROWER` | `models/marts/npl_common/dimensions/dim_npl_borrower.sql` |
| `NPL_COMMON.FCT_CASE_COLLECTION` | `models/marts/npl_common/facts/fct_npl_case_collection.sql` |
| `NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY` | `models/marts/npl_common/facts/fct_npl_case_snapshot_daily.sql` |
| `NPL_COMMON.BRG_CASE_BORROWER` | `models/marts/npl_common/bridge/brg_case_borrower.sql` |

The `models.yml` beside each folder carries the alias and the column descriptions. That
yml is the closest thing to an official data dictionary for the warehouse — read it
before this README.

### The four layers, and what each one decides

```
staging        → intermediate     → marts          → exports
stg_<source>__ … int_npl_…          dim_/fct_/brg_   downstream feeds
```

- **staging** (`models/staging/intrum_cat/stg_intrum_cat__cases.sql` and siblings) — one
  model per source table. **This is where the raw feed's quirks are handled**: the change
  history, the sign flip, the instance-scoped `case_id`. If you are about to query raw
  because the warehouse lacks a column, read the staging model for that table first; it
  shows you the guards you would otherwise have to rediscover.
- **intermediate** (`models/intermediate/npl_common/`) — conforming and SCD logic. The
  interesting decisions live here, and so do the surprises. `dim_npl_case` is built from
  `int_npl_case_scd_conformed` rather than `int_npl_case_conformed` precisely because the
  latter's grain repeats ~97% of rows verbatim; that is the kind of thing only the model
  tells you.
- **marts** — what you query.
- **exports** — feeds out, not for analysis.

### When a column is wrong, or missing

- **A column that exists but is wrong** is a data-quality issue. Report it to the data
  team with the evidence; do not patch around it silently in your own SQL, and never
  "fix" it in a model unasked.
- **A column the servicer sends but the warehouse drops** (53 of them, B1) is a dbt
  change: a new or widened model, raised as a PR and reviewed by the data team. That is
  the route for the whole legal and enforcement family.
- **Either way the conversation starts with the model**, not with a workaround. If a query
  of yours needs a guard, say in a comment what the problem is and name it, so the next
  reader can audit the choice instead of inheriting folklore.

## B10. The guards, as a checklist

Every one of these was found the hard way. Leave one out and the number is wrong, not
missing.

| Guard | Why |
|---|---|
| `collection_date <= CURRENT_DATE` | 841 rows dated to the year 4570 |
| `is_current_flag` on `DIM_CASE` | It is an SCD; without it you get every version |
| Join cases on `case_id`, not `case_bk` | `CASE_BK` is not a row key |
| Instance in the join key on raw CAT | `case_id` repeats across instances |
| No date bound on raw transactions | 35% have a null transaction date |
| `_file_path` literal prefix on raw CAT | The only pruning; 6.5bn rows otherwise |
| Cut the servicer report at its extract month | It carries forecast months |
| Convert currency before summing | The report collapses currency |
| Never average a ratio | Static columns repeat per month; averaging a ratio is a known 5.8× trap |
| EUR columns only, when adding across deals | Local-currency columns are not comparable |

## B11. Known data-quality issues

Report these; do not quietly work around them.

- **51 attributes** arrive from the servicer and are dropped before the warehouse.
- **Collections begin 2014**, truncating pre-registration history on older books.
- **841 collection rows** dated into the future.
- **`FCT_PORTFOLIO_SNAPSHOT_MONTHLY.REPORTING_SYSTEM_SK` is 100% null** — a join key that
  joins to nothing.
- **95.7% of portfolio-months are restated** in later extracts.
- **14 seller files, across 9 deals, cannot be opened** at all.
- **Six deals carry no case count**, so case-weighted figures quietly omit them.

---

## What is solid and what is shaky

**Solid** — counts of deals, cases and balances; which deals the servicer sends data for;
which attributes exist in a tape or feed; fill rates.

**Shaky:**

- **"Not Found" on a tape is weaker than "Found."** Detection is by column-header
  matching, so an oddly named header can be missed. *Found* is reliable; *Not Found*
  means "not detected".
- **Reconciliation is measured, not explained.** 1,047 of 2,276 reconcile; why the rest
  fail has not been diagnosed deal by deal.
- **Unclassified is 28% of the book.**

## Notes for an agent working on this

- **Read `Data Dictionary` first.** Column names are long and self-describing; do not
  infer meaning from a shortened name.
- **Check which tab a figure came from before comparing two.** The commonest error is
  comparing an (R) figure with an (F) one, or a gated count with an ungated one — which
  is how "32 tapes" and "60 tapes" are both correct.
- **Denominators move between tabs.** 2a is every deal we own; 2b is post-registration
  deals; 2c is the 8 full-timeline deals. Same column name, different question.
- **Never average a share.** Shares are summed numerator over summed denominator. Markets
  differ in size by three orders of magnitude.
- **Most denominators on the (F) tabs are 1.** Read counts, not percentages.
- **Most deals are not usable, and that is the finding**, not a data error. Do not filter
  to the clean subset and report on that.
- **Every query here is read-only.** Tables are built by the dbt project, never from a
  notebook or ad-hoc SQL.

---

*Snapshot measured 2026-11-04. The workbook describes a commercial loan portfolio and is
confidential; no personal data about any borrower is included at any grain. Part B's
queries can reach personal data — borrower names, addresses, contact details — so select
the columns you need rather than `SELECT *`, and keep personal fields out of anything you
export or share.*
