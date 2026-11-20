"""Generate runnable Snowflake copies of the npl_platinum dbt models.

The models under `models/marts/npl_platinum/` are written for dbt and cannot be
run from here: `{{ ref('x') }}` means nothing to Snowflake. This resolves every
ref to its PROD object so each model runs as plain SQL.

    mise run platinum-sql        # regenerate everything

Output goes to `models/marts/npl_platinum_snowflake/`. NEVER EDIT THOSE FILES --
edit the dbt model and regenerate, or the two drift. And never move that folder
into brocc-data: the filenames duplicate the originals and two models with the
same name break `dbt parse`.

A model that refs a SIBLING platinum model has it inlined as a subquery, because
the sibling is not a table yet. Those files are long and run slower than the dbt
version would; that is expected.

⚠ GOLDEN below must stay in step with the models. An unknown ref raises rather
than silently emitting a subquery of the wrong thing.
"""

import os, re

BASE = "/Users/sharlenechin/data-warehouse/local-workspace/work/dbt/models/marts/"
SRC_A, OUT_A = BASE + "npl_platinum/", BASE + "npl_platinum_snowflake/"
SRC, OUT = SRC_A, OUT_A
# the updated layer generates alongside, into its own mirror folder
SRC_B, OUT_B = BASE + "npl_platinum_updated/", BASE + "npl_platinum_updated_snowflake/"

GOLDEN = {
    "dim_npl_portfolio": "PROD.NPL_COMMON.DIM_PORTFOLIO",
    "dim_npl_case": "PROD.NPL_COMMON.DIM_CASE",
    "dim_npl_deal": "PROD.NPL_COMMON.DIM_DEAL",
    "dim_npl_deal_source": "PROD.NPL_COMMON.DIM_DEAL_SOURCE",
    "dim_npl_legal_buyer": "PROD.NPL_COMMON.DIM_LEGAL_BUYER",
    "dim_npl_batch": "PROD.NPL_COMMON.DIM_BATCH",
    "dim_npl_reporting_system": "PROD.NPL_COMMON.DIM_REPORTING_SYSTEM",
    "dim_country": "PROD.COMMON.DIM_COUNTRY",
    "fct_npl_portfolio_snapshot_monthly": "PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY",
    "fct_npl_case_collection": "PROD.NPL_COMMON.FCT_CASE_COLLECTION",
    "fct_npl_case_snapshot_daily": "PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY",
    "fct_npl_carrying_amount": "PROD.NPL_COMMON.FCT_CARRYING_AMOUNT",
    "fct_exchange_rate_monthly": "PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY",
    "fct_exchange_rate_daily": "PROD.COMMON.FCT_EXCHANGE_RATE_DAILY",
    "fct_npl_portfolio_forecast_servicer_snapshot_monthly":
        "PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY",
    "fct_npl_portfolio_forecast_accounting_snapshot_monthly":
        "PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY",
    "fct_npl_portfolio_forecast_underwriting_snapshot_monthly":
        "PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY",
}

REF = re.compile(r"\{\{\s*ref\('([a-z0-9_]+)'\)\s*\}\}")


def strip_header(sql):
    return re.sub(r"^/\*.*?\*/\s*", "", sql, flags=re.S)


def read(name):
    for d in (SRC_A, SRC_B):
        if os.path.exists(d + name + ".sql"):
            return strip_header(open(d + name + ".sql").read())
    raise FileNotFoundError(name)


def split_with(sql):
    """Return (cte_block, final_select) for a model whose body starts with WITH.

    The CTEs are lifted so a dependency can be inlined ONCE as a named CTE
    instead of being pasted in at every ref -- which is both unreadable and,
    where a model refs the same dependency twice, a duplicated table scan.
    """
    body = sql.lstrip()
    if not body.upper().startswith("WITH"):
        return "", body
    body = body[4:].lstrip()
    # the final SELECT is the last one sitting at column 0
    m = list(re.finditer(r"^SELECT\b", body, flags=re.M))
    assert m, "no top-level SELECT found"
    cut = m[-1].start()
    ctes = body[:cut].rstrip().rstrip(",")
    return ctes, body[cut:]


def dependencies(name, seen=None):
    """Sibling platinum models this one needs, deepest first, each once."""
    seen = [] if seen is None else seen
    for dep in REF.findall(read(name)):
        if dep in GOLDEN or dep in seen:
            continue
        dependencies(dep, seen)
        seen.append(dep)
    return seen


def resolve(sql):
    """Point every ref at its PROD object, or at the CTE carrying that model."""
    return REF.sub(lambda m: GOLDEN.get(m.group(1), m.group(1)), sql)


def build(name):
    deps = dependencies(name)
    ctes, final = split_with(read(name))
    blocks = []
    for dep in deps:
        dep_ctes, dep_final = split_with(read(dep))
        if dep_ctes:
            blocks.append(resolve(dep_ctes))
        blocks.append(f"{dep} AS (\n{resolve(dep_final)}\n)")
    if ctes:
        blocks.append(resolve(ctes))
    return "WITH " + ",\n\n".join(b.strip() for b in blocks) + "\n\n" + resolve(final)


BANNER = """-- ============================================================================
-- ⚠⚠⚠ GENERATED MIRROR — DO NOT EDIT, AND DO NOT MOVE THIS FOLDER INTO
-- brocc-data. Every filename here duplicates one in marts/npl_platinum, and
-- two models with the same name break `dbt parse` outright.
-- ============================================================================
--   source : models/marts/npl_platinum/{name}.sql
--   this   : the same model with every {{{{ ref() }}}} resolved to its PROD
--            object, so it runs as plain Snowflake SQL:
--
--   mise run sql -- work/dbt/models/marts/npl_platinum_snowflake/{name}.sql
--
-- EDIT THE dbt MODEL AND REGENERATE. Editing this copy is how the two drift.
{extra}-- ============================================================================

"""

EXTRA = ("-- ⚠⚠ {dep} IS INLINED AS A CTE BELOW, because it is not a table yet.\n"
         "-- Inlined ONCE however many times the model refs it, so the scan is not\n"
         "-- repeated -- but this still runs slower than the dbt version, which\n"
         "-- reads it as a materialised table. Expected, not a bug.\n")

LAYERS = [(SRC_A, OUT_A), (SRC_B, OUT_B)]

for SRC, OUT in LAYERS:
  if not os.path.isdir(SRC):
    continue
  print(f"{SRC.rstrip('/').rsplit('/', 1)[-1]}:")
  os.makedirs(OUT, exist_ok=True)
  for f in sorted(os.listdir(SRC)):
      # ⚠ EXAMPLE_* files are worked queries, not models. They reference models
      # but nothing references them, so compiling one here would inline whole
      # models into a file nobody builds.
      if not f.endswith(".sql") or f.startswith("EXAMPLE_"):
          continue
      name = f[:-4]
      raw = open(SRC + f).read()
      header = re.match(r"^/\*.*?\*/", raw, flags=re.S)
      siblings = dependencies(name)
      extra = "".join(EXTRA.format(dep=d) for d in dict.fromkeys(siblings))
      body = build(name)
      text = (BANNER.format(name=name, extra=extra)
              + (header.group(0) + "\n\n" if header else "") + body)
      assert "{{" not in body, name          # the banner legitimately shows {{ ref() }}
      # ⚠ A CTE name reused by an inlined model resolves to the OUTER one and
      # fails as an invalid recursive CTE. dbt never sees this, because there the
      # refs are real tables -- so it can only be caught here.
      ctes = re.findall(r"^\s*([a-z_][a-z0-9_]*)\s+AS\s*\(", body, flags=re.M)
      dupes = {c for c in ctes if ctes.count(c) > 1}
      assert not dupes, f"{name}: CTE name(s) {sorted(dupes)} collide with an inlined model"
      open(OUT + f, "w").write(text)
      print(f"  {name:45} {len(text.splitlines()):5} lines"
            + (f"  (inlines {', '.join(siblings)})" if siblings else ""))
