# Legal-type columns by country — what the deal pipelines actually use

Scraped **2026-10-08** from every `run.py`, module and notebook under
`npl-underwriting/deals/` — 18 live deals, 7 countries, 348 Python and notebook
files. One YAML per country beside this file.

## The mandatory fields are the same everywhere

This was the first thing checked, and it settles half the question: **there is
no per-country mandatory field set.** One shared pandera contract validates
every deal, in `npl-underwriting/environments/common/packages/npl-schema/`:

| `CleanedAccountsSchema` | `CleanedPaymentsSchema` |
|---|---|
| `model_id` (unique) | `model_id` |
| `registration_date` | `payment_date` |
| **`registration_balance`** | `payment_amount` |
| `extraction_date` | |

Everything else — `default_date`, `origination_date`, `pricing_segment`,
`product_type`, `customer_type` — is optional and nullable. A German deal and an
Italian deal are validated by the identical schema.

**So the country difference is not in what is mandatory. It is entirely in the
legal columns each jurisdiction carries**, and those are not in the schema at
all — they live in each deal's own cleaning and modelling code.

## What each country actually tracks

| Country | Deals | Legal terms | The shape of it |
|---|---:|---:|---|
| **Italy** | 1 | **131** | Court tiering and ODA mechanics — in a class of its own |
| **United Kingdom** | 3 | 33 | Bankruptcy **and sequestration** (Scotland), furthest legal stage |
| **Germany** | 8 | 17 | Insolvency, and almost nothing else |
| **France** | 1 | 11 | Enforceable title and its prescription |
| **Sweden** | 3 | 11 | Bailiff (Kronofogden), via the DCA's flags |
| **Poland** | 1 | 3 | Collection phase only |
| **Denmark** | 1 | 3 | Bailiff, and a legal basis field |

### Italy is not a bigger version of the others — it is a different model

131 terms against Germany's 17, from a single deal. Two structures no other
country has:

- **Court speed is a priced variable.** `court_fast`, `court_medium`,
  `court_slow`, `court_tier`, `court_province`, `court_multipliers`,
  `court_unknown`. Nowhere else is the court itself an input.
- **ODA is a whole sub-ledger.** `ordinanza di assegnazione` — the assignment
  order — carries ~30 of its own fields: `legal_oda_awarded_amount`,
  `legal_oda_instalment_amount`, `legal_oda_suspension_start_date`,
  `legal_oda_one_shot_value`, `legal_oda_queuing_date`. The book is segmented
  on it: `c. oda`, `d. pre-oda`, `e. secured-procedure`, `f. procedure`.
- Plus the native vocabulary: `decreto ingiuntivo` (payment injunction),
  `a. stragiudiziale` (out-of-court), `pignoramento immobiliare` / `mobiliare`
  (real-estate / movable attachment), `spese_legali_ante_oa`,
  `ultima_fase_legale`.

### Germany is insolvency and nothing else

Of 17 terms, 12 are `insolvency*` — `insolvency_flag`, `insolvency_date`,
`insolvency_age`, `insolvency_age_range`, `insolvency_age_to_registration`,
plus the segmentation `a1 - non-insolvent` / `b - insolvent`. The only
non-insolvency legal facts are `deceased`, `legal_balance` and
`proportion titled`. That matches the InsO regime — one structured process,
so one flag and its age carry the whole legal story.

### The UK difference worth knowing

`hassequestration`, `bankrupt_seques`, `sequestrationdate`. **Sequestration is
Scottish personal insolvency**, not English bankruptcy — the UK deals carry both
because the book spans both jurisdictions. Also `furthestlegalstage` and
`furthestlegaldate`: a *furthest-reached* concept nobody else models.

### France is about the title, not the process

`enforcement_title_status`, `titled`, `prescribed title`, `titré prescrit`,
`judiciaire`, `judicial`. The question is whether an enforceable title exists
and whether it has **prescribed** (timed out) — not which procedure is running.

### The Nordics track the bailiff, and only through the DCA

Sweden: `bailiff_flag`, `bailiff_date`, and the same facts duplicated under a
`dca_` prefix (`dca_bailiff_date`, `dca_bankruptcy_flag`, `dca_deceased_flag`)
plus unprefixed variants (`dcabankruptcyflag`). Denmark: `bailiff_flag`,
`pct_bailiff`, `legal_basis_for_collections`. Enforcement is the state's job in
both, so the only legal fact worth a column is whether it has reached them.

### Poland and Denmark are thin, and that may be collection rather than reality

Poland has `collection_phase`, `pre-legal phase`, `deceased`. One deal each,
early in the pipeline. **Do not read three terms as "this jurisdiction has no
legal process"** — read it as one deal that has not needed them yet.

## ⚠ Two things to know before using this

**`liquidation` is excluded everywhere, deliberately.** In this repo it means
the **recovery curve** — `sum_liquidations`, `log_liquidation`,
`cumulative liquidation %`, `liquidations_between_-12_0`. It is modelling
vocabulary, not the insolvency process. Counted naively it was the top "legal
term" in every country, on 8 of 8 German deals. A genuine legal liquidation
would appear as `liquidazione` (IT) or winding-up (UK); neither does.

**This is what the code references, not what the tapes shipped.** Deal assets
are gitignored and absent from the clone — 0 cleaned parquet files, 20 raw
`.gitkeep` placeholders. A column named in a notebook may have been explored and
dropped; a column in a tape nobody coded against will not appear here at all.
Treat the counts as *what the pipelines are built to handle*.

## How country was assigned

Each deal's `country_basis` is recorded in its YAML entry. Six deals are
confirmed against `PROD.NPL_COMMON.DIM_DEAL` — including three whose folder name
gives nothing away: **Korund = LOK-DE25010 Deutsche Bank**, **Neptune =
LOK-DE24016 Deutsche Bank (Neptun)**, **equinox_poplar = ORG-UK26002/26003 Arrow
Global**. The rest come from the deal code (`ge*`, `uk26006`, `lok-pl26003`) or,
for `targobank` and `iqera`, from the column language itself (`Vertragsdatum`,
`TOTAL_CREANCE` / `JUDICIAIRE`).

⚠ **`bnp_dk` is the one I could not confirm.** It is not in `DIM_DEAL`, its
columns are generic English, and the repo mentions both "danish" and "sweden"
once each. Denmark comes from the folder name alone. If that deal matters,
check it before relying on the DK file.

| File | |
|---|---|
| `de.yaml` `uk.yaml` `it.yaml` `fr.yaml` `se.yaml` `pl.yaml` `dk.yaml` | one per country: deals, mandatory fields, optional fields used, every legal term with its deal count |
