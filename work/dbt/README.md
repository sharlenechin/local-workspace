# `work/dbt/` — models staged for promotion into `brocc-data`

**Nothing here is built, and nothing here runs from this workspace.** dbt models
only build from the tracked repo. This folder is where a model is written in
`brocc-data`'s conventions and folder shape, so that approving it is a
drag-and-drop plus one commit. Per `CLAUDE.md` Rules 1 and 3, nothing is written
into `brocc-data` without an explicit request that starts with its own reading
list.

```
work/dbt/                    → maps onto brocc-data/transformation/dbt/
└── models/marts/
    ├── mart_servicing/      portfolio × month, for the servicing dashboard
    │   └── dbt/             one model + models.yml
    └── mart_underwriting/   loan grain, for npl-underwriting
        ├── mart_npl_underwriting_accounts.sql
        └── mart_npl_underwriting_collections.sql
```

⚠ **The two marts are deliberately separate and must not be merged.**
`mart_servicing` answers *how is the book performing this month*;
`mart_underwriting` answers *what we bought and what it has paid back*, at loan
grain, in the shape the pricing pipeline expects.

## What is in this folder

| File | What it is |
|---|---|
| [`models/marts/mart_servicing/`](models/marts/mart_servicing/) | the servicing model. ⚠ **Shipped to `brocc-data` on branch `add/servicing-mart` as `mart_npl_servicing_agg_cases_monthly`, not merged.** The copy here is the draft that produced the PR, and its column names are already out of date — treat `brocc-data` as the source of truth. Its README has the mapping |
| [`models/marts/mart_underwriting/`](models/marts/mart_underwriting/) | two models for `npl-underwriting` |
| [`NPL-UNDERWRITING-DESIGN.md`](NPL-UNDERWRITING-DESIGN.md) | what to change and what to build on `NPL_COMMON` for underwriting. A proposal for the data team, written 2026-10-02 |
| [`DBT-HANDOFF.md`](DBT-HANDOFF.md) | which `work/servicing` queries earned a model and which did not, plus the four models the stakeholder's metrics need from RAW |
| [`PLATINUM-FINDINGS.md`](PLATINUM-FINDINGS.md) | the four design findings from the retired platinum layer. Read before proposing any new history or event-shaped model |
| [`WHO-IS-WHO.md`](WHO-IS-WHO.md) | originator vs seller vs servicer vs agency: what each role carries, why one company table beats two, and the two hops a secondary transaction can be traced over |
| `proof_status_change_phase_logic.sql` | proof that the proposed status-change logic is buildable Snowflake SQL, run against `PROD.DIM_CASE` because the staging model it would read is invisible to `NPL_ANALYST` |

## ⚠ The platinum layer was deleted on 2026-10-02

`npl_platinum`, `npl_platinum_snowflake`, `npl_platinum_updated`,
`npl_platinum_updated_snowflake`, `work/platinum/` and the `platinum-sql` /
`platinum-xlsx` mise tasks are all gone, to
`work/.archive/2026-10-02-platinum/`. Nothing ever consumed the layer, every
model existed twice (dbt dialect plus a generated Snowflake copy), and the one
model genuinely needed was built directly as the servicing mart instead.

**[`PLATINUM-FINDINGS.md`](PLATINUM-FINDINGS.md) is what survived** — dense
event rows, no `LATEST` phase, currency in the grain, and the three forecasts.
Those four lessons apply to the next model whatever it is called.

## Before proposing anything here

Read, in this order:

1. `brocc-data/AGENTS.md` — monorepo layout, domain context, agent conduct
2. `brocc-data/transformation/dbt/AGENTS.md` — the four model layers, naming,
   business abbreviations
3. `brocc-data/transformation/dbt/.claude/agents/dbt-agent.md` — the authority
   on how a model is written

Their conventions win over anything in this file, and CI enforces them.
**Placement is the data engineer's call**; this folder is about content and
sequencing, not about overriding their structure.
