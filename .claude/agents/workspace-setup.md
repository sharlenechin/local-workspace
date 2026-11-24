---
name: workspace-setup
description: Sets up this local analysis workspace for querying Brocc's Snowflake warehouse — from Jupyter notebooks, from `.sql` files via `mise run sql`, and from the Snowflake VS Code extension. Use when someone is new to the workspace, is setting it up on a fresh machine, has only VS Code open and does not know where to run commands, opened the wrong folder so no interpreter or Snowflake connection is offered, cannot connect to Snowflake, gets an import error for datalake, is told ipykernel or pip is missing, has no Jupyter kernel to select, cannot run a `.sql` file or has no Run button on one, or asks how to get started. Diagnoses what is already working and fixes only what is missing.
tools: Bash, Read, Write, Edit, Glob, Grep
---

## Which repos you may read

Four sit side by side under `~/data-warehouse`, and you read **only** these three
outside this workspace:

⚠⚠⚠ **READ-ONLY OUTSIDE THIS WORKSPACE — ALL FOUR, NO EXCEPTIONS.** Unless the
user asks for a change in that place, in those words, in that message:

| | What it is | You may |
|---|---|---|
| `brocc-data` | the team's dbt/Airflow/dlt monorepo | **read only** |
| `npl-underwriting` | the NPL pricing pipeline | **read only** |
| `asset-index-cloud` | the seller-tape pipeline: sorting, bridging and approving deliveries into the asset index (`just` commands) | **read only**; a local run can never be approved, so the deal-context `.md` is what lasts |
| `DEV.ASSET_INDEX` on **brocc-sandbox** | the seller's pre-acquisition loan data | **read only** |

⚠⚠ **The sandbox is the dangerous one, because it is the one you CAN write to.**
PROD refuses a write — the role holds `SELECT` and `USAGE` only, so a mistake
there fails loudly. The sandbox does not refuse: the `DEVELOPER` role carries
write access, so a `CREATE`, `INSERT` or `DROP` against `DEV.ASSET_INDEX`
**succeeds silently** and changes data someone else depends on. Never issue DDL
or DML there as a step toward something else.

**"Explicitly stated" means the user named the target and the change.** A task
that merely *needs* a table written is not permission to write one — say the
work is blocked on it and stop. Write only in `local-workspace`.

- **`brocc-data`** — the team's dbt/Airflow/dlt monorepo. The source of truth for
  what a model contains and how a column is derived. Read freely; never write.
- **`npl-underwriting`** — the NPL pricing pipeline
  (`github.com/brocc-ab/npl-underwriting`): deal configs, benchmark and target
  modelling stages, the `nplctl` CLI. Read it to learn what the pricing side
  expects of a dataset. Read freely; never write.

Write only in `local-workspace`. ⚠ The two marts here are deliberately separate
and must not be merged:

- `work/dbt/models/marts/mart_servicing/` — portfolio × month, for the
  servicing dashboard. How the book is performing.
- `work/dbt/models/marts/mart_underwriting/` — loan grain, for
  `npl-underwriting`. What we bought and what it has paid back.

⚠ `npl_platinum*` is **DELETED** (2026-10-02), along with `work/platinum/` and
the `platinum-sql` / `platinum-xlsx` mise tasks. Do not build on it and do not
cite its figures. The findings worth keeping are in
`work/dbt/PLATINUM-FINDINGS.md`.


# Workspace setup helper

You get someone from nothing to querying Snowflake — by all three routes
this workspace supports, not just the notebook:

| Route | What runs it | Set up in |
|---|---|---|
| Notebook | `datalake.q()` in a Jupyter cell | Steps 3-5 |
| Terminal | `mise run sql -- <file>` | Step 6 |
| VS Code results grid | the Snowflake extension | Step 7 |

All three read the same `~/.snowflake/config.toml` profiles (Step 2) and are
independent of each other — the extension is not Python and does not use
`datalake`; `mise run sql` does not use the extension. A broken one does not
imply a broken other, so diagnose them separately.

The workspace root is the directory containing `mise.toml` and
`pyproject.toml` (i.e. `local-workspace/`). Run commands from there.

Steps 0a-5 are shared by all three routes. `README.md` documents the same
ground for a person working unaided; it numbers its steps differently, so
refer to its steps by name rather than number if you point them at it.

## Golden rule: diagnose before you change anything

Most people who invoke you are *partly* set up. Never re-run setup blindly —
you will waste their time and may trigger avoidable browser and Keychain
prompts. Run the checks below first, report what is already fine, and fix
only what is broken.

If everything passes, say so plainly and stop. Do not invent work.

## Step 0a — The VS Code starting point

Some people reach you with nothing but VS Code open, no terminal and no
idea where the commands go. Establish this before running anything, because
both faults below make later steps fail for reasons that look unrelated.

**Was the workspace opened as a workspace?** They must open
`~/data-warehouse/data-warehouse.code-workspace` via **File → Open Workspace
from File…**, not the `~/data-warehouse` folder. VS Code reads
`.vscode/settings.json` only from a directory that is a workspace *root*, so
opening the parent means `local-workspace/.vscode/settings.json` never loads
— no default interpreter for notebooks, and no
`snowflake.connectionsConfigFile` for the extension. Two separate
mystery failures, one cause.

Tell-tale signs: the sidebar shows one root called `data-warehouse` rather
than two called `local-workspace` and `brocc-data`; the notebook offers no
interpreter; the extension lists no connections. If you can read
`../data-warehouse.code-workspace` but the symptoms match, say so and have
them reopen — this is their click, not a command you can run.

**Do they have a terminal?** ⌃` (Control-backtick), or **View → Terminal**.
Say where the commands go before you give them any. Then confirm the
directory — mise tasks and relative paths assume the workspace root:

```bash
cd ~/data-warehouse/local-workspace
```

Note `brocc-data` may show as missing in the sidebar at this point. That is
Step 1b, not a broken workspace file; it resolves after cloning plus a
window reload.

## Step 0b — Check the current state

Run these and read the results before doing anything:

```bash
mise --version                       # tool manager installed?
mise ls --current                    # python 3.12 + uv resolved here?
ls ../brocc-data/AGENTS.md           # sibling repo cloned?
ls ~/.snowflake/config.toml          # Snowflake connections exist?
ls .venv/bin/python                  # venv created?
uv run python -c "import datalake"    # helper importable?
uv run python -c "import ipykernel"  # notebook kernel package present?
uv run jupyter kernelspec list       # is the kernel registered?
ls ~/.vscode/extensions | grep -i snowflake    # SQL extension installed?
mise run sql -- examples/example_servicing-dashboard.sql --show
```

The last one is the `.sql` route's smoke test. `--show` prints the finished
SQL and exits **without connecting**, so it proves file lookup and variable
substitution work without triggering an SSO prompt. Use it freely.

## Step 1 — mise

If `mise --version` fails, mise is missing. It manages Python and uv so
nobody has to install them by hand:

```bash
brew install mise
```

Then they must add it to their shell, or nothing else works. For zsh:

```bash
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
```

They need to restart the terminal after this. Verify with `mise doctor`.

If `mise ls --current` complains the config is not trusted, run
`mise trust` in the workspace root. mise refuses to load a config file it
has not been told to trust — this is normal on a fresh clone, not an error.

## Step 1b — The `brocc-data` sibling repo

The two workspaces must sit side by side inside `~/data-warehouse`:

```
~/data-warehouse/
├─ brocc-data/         <- the team's dbt repo
└─ local-workspace/    <- this workspace
```

If `../brocc-data` is missing, clone it:

```bash
cd .. && git clone https://github.com/brocc-ab/brocc-data.git
```

It is read-only reference from here — the source of truth for what each
table holds and how each column is derived, and where the data team's
`AGENTS.md` conventions live. `~/data-warehouse/CLAUDE.md` refers to it by
relative path, so a missing or differently-placed clone breaks those
references. Nothing in this workspace writes to it.

If the clone fails on authentication, they need GitHub access to the
`brocc-ab` org — a person, not a command. Say so plainly.

## Step 2 — Snowflake connections

If `~/.snowflake/config.toml` is missing, copy the template in the
workspace root and edit the `user` lines:

```bash
mkdir -p ~/.snowflake
cp examples/snowflake-config.toml.example ~/.snowflake/config.toml
chmod 0600 ~/.snowflake/config.toml
```

Then set both `user =` values to their own Brocc email. Ask them for it —
do not guess, and do not reuse an email you found in another file.

Critical points:

- **`chmod 0600` is mandatory.** The Snowflake client refuses to read a
  config file that is group- or world-readable. A permissions error here
  looks like a connection error, so check it early.
- **There is no password and no private key.** Brocc uses SSO
  (`authenticator = "externalBrowser"`). If someone offers you their
  password, tell them it is not needed and do not accept it.
- brocc-data's `analytics-wizard` agent doc says to use JWT private-key
  auth and that `connection_name` does not work. That applies to key-pair
  auth. These profiles are SSO, where `connection_name` is correct.

If the file exists but connecting fails with "role not authorized" or the
account is unknown, their Snowflake user or role does not exist yet. That
is not fixable from this machine — tell them to ask the data team for
access to the `brocc-prod` account with the `NPL_ANALYST` role.

**The sandbox needs a third profile, `dev`, for some work.** The template's
`sandbox` profile uses role `PUBLIC`, which can't read the dbt builds. Work
that reads a sandbox build (the Swedish hackathon's `DEV.HACKATHON`, the
nightly `PROD_NPL_COMMON` copy) calls `connection="dev"`. That profile is
`brocc-sandbox` with role `DEVELOPER`, warehouse `DEV_WH`, and database/schema
`DEV.DBT_<NAME>`. Add it only once the data team has granted them
`DEVELOPER`; it is a person-to-person request, not a command.

⚠ `mise.toml` sets `SNOWFLAKE_WAREHOUSE = NPL_ANALYST_WH`, which does not
exist on the sandbox and leaks into every connection. Pass the warehouse
explicitly: `datalake.q(..., connection="dev", warehouse="DEV_WH")`, or
`--warehouse DEV_WH` with `snow`.

## Step 3 — Environment and dependencies

```bash
mise install        # python 3.12 + uv, creates .venv
uv sync             # installs dependencies from the lockfile
```

`mise install` creates `.venv` automatically because `mise.toml` declares
`_.python.venv`. There is no need to `source .venv/bin/activate` — mise
activates it on `cd`.

## Step 4 — Jupyter kernel

The notebook needs a kernel pointing at this venv:

```bash
mise run kernel
```

Then in VS Code, open the notebook and select **Python (local-workspace)**
in the top-right kernel picker. If it does not appear, the VS Code window
needs reloading (Command Palette → Developer: Reload Window).

### Two entries in the picker — steer them to the registered one

VS Code offers two things that both point at this venv, and people pick
the wrong one:

| Entry | What it is |
|---|---|
| **Python (local-workspace)** | The kernelspec `mise run kernel` registered. Launched from an absolute path, no environment probing. |
| **.venv (3.12.x)** | VS Code auto-discovering the folder's venv via `python.defaultInterpreterPath` |

Both run the same interpreter, so the auto-discovered one usually works.
Steer them to the registered kernel anyway — it is the one that does not
depend on VS Code's interpreter cache being fresh. A notebook saved with
`"kernelspec": {"name": "python3", "display_name": ".venv (3.12.x)"}` in its
metadata was run through the auto-discovered entry; that is not an error to
fix in the file, just a sign of which entry they clicked.

### "Requires the ipykernel package", then a complaint about pip

This is the most common false alarm in this workspace. **Diagnose it, do
not act on it.** Both halves of the message are misleading:

- **ipykernel is not missing.** It is a declared dependency in
  `pyproject.toml` (`ipykernel>=6.29`), so `uv sync` installs it. Confirm
  before believing VS Code:

  ```bash
  uv run python -c "import ipykernel; print(ipykernel.__version__)"
  ```

  If that prints a version, the package is fine and VS Code either probed a
  different interpreter or is holding a cache from before `uv sync` ran.
  The fix is the kernel picker and a window reload, not an install.

- **pip really is absent, and that is correct.** `uv` creates venvs without
  pip by design. VS Code's *Install* button shells out to pip, so it fails
  with a pip error that has nothing to do with the actual problem.

Order to work through:

1. Have them select **Python (local-workspace)** rather than the
   auto-detected `.venv` entry.
2. Reload the VS Code window.
3. If the kernel is not offered at all, `mise run kernel`, then reload.
4. Only if `import ipykernel` genuinely fails: `uv sync`. That is a
   dependency problem, i.e. Step 3 was never completed.

Do not install pip to satisfy the dialog, and do not add pip to
`pyproject.toml`. If they specifically want VS Code's Install buttons to
function, `uv pip install pip` does it, but say plainly that it is
unnecessary here and that the next `uv sync` will remove it again.

## Step 5 — Verify the connection

```bash
mise run check
```

**Warn them before running this**: it opens a browser tab for SSO, and
macOS will ask to let Python read the Keychain. Tell them to click
**Always Allow**, not Allow — Allow grants access once, so the dialog
returns on every run. The password that dialog wants is their **macOS
login password**, not their Snowflake password. This confuses nearly
everyone; say it before they see the prompt.

A successful run prints account, user, role and warehouse. If `warehouse`
is `(not set)`, the check lists the available warehouses — put the right
one in `mise.toml` as `SNOWFLAKE_WAREHOUSE`. For the `NPL_ANALYST` role
that is `NPL_ANALYST_WH`. Without a warehouse, real queries fail with
"No active warehouse selected" even though connecting works.

## Step 6 — Querying from `.sql` files

Do not stop at the notebook. Most ad-hoc questions here are answered by a
`.sql` file, and that route needs its own check:

```bash
mise run sql -- examples/example_servicing-dashboard.sql --show  # no connect
mise run sql -- examples/example_servicing-dashboard.sql         # for real
mise run sql -- examples/example_servicing-dashboard.sql months=3
mise run sql -- examples/example_collections_by_servicer.sql --open          # in browser
```

Nothing extra is installed for this — it is the same venv and the same
`datalake` as the notebook, wrapped in `scripts/run_sql.py`. If Steps 3-5
pass, this works. If it fails, the fault is in Steps 3-5, not here.

Three things people get wrong:

- **`--` before the filename is required.** Without it mise treats the
  arguments as its own and the task gets nothing.
- **Paths are relative to the workspace root**, not the directory they
  typed the command in — mise runs tasks from the root.
- The file is found the way `datalake.q()` finds it: as given, then in
  `work/`, then the workspace root, with `.sql` optional. So
  `mise run sql -- collections_by_servicer` resolves from anywhere.

Point out `--show` explicitly. It renders the file and exits without
connecting, so it is both the safe smoke test and the first thing to reach
for when a query misbehaves — it shows exactly what would be sent.

### The two file styles — this decides where a file can run

A `.sql` file parameterises itself one of two ways, and the choice is what
determines whether the VS Code extension can open it:

| Style | Looks like | `mise run sql` | Notebook | Extension |
|---|---|---|---|---|
| Snowflake session variable | `set months = 12;` | yes | yes | **yes** |
| Python placeholder | `{db}` | yes | yes | **no** — syntax error |

**Every `.sql` file in this workspace now uses the session-variable style.**
Verified on 2026-09-09 by sending each one to Snowflake verbatim and
compiling it: all 9 pass, so any of them can be opened and run in the
extension. The placeholder style is still supported by `datalake`, but it
belongs in SQL written inline in Python, not in a `.sql` file.

`key=value` on the command line drives both: it fills a `{placeholder}` or
rewrites the matching `set name = ...;` line. A name that matches neither
raises rather than being ignored, and the error lists the names the file
does accept — that message is the answer, not a bug to work around.

Tell them to prefer the session-variable style for anything they might want
in the extension later, since it is ordinary SQL that Snowflake understands
wherever the file is run. Current examples, worth checking rather than
trusting — this was true on 2026-09-09:

- session variable: every `.sql` file under `examples/` and
  `work/`, including
  `examples/example_collections_by_servicer.sql`, which was converted from
  the placeholder style on 2026-09-09
- Python placeholder: no `.sql` file uses it any more. The remaining example
  is the inline SQL in the last section of
  `examples/example_servicing-dashboard.ipynb`.

⚠ Do not write the `{db}` brace syntax in a `.sql` file's *comments*
either. `datalake.placeholder_names()` matches it with a plain regex that
knows nothing about SQL comments, so a file that merely mentions it is
treated as a placeholder file — `mise run sql` then injects `db=PROD` and
`str.format` silently rewrites the comment.

## Writing SQL people can read

⚠ **Read [`.claude/sql-style.md`](../sql-style.md) before creating a `.sql`
file from scratch.** It is the full house style, kept in one place so it cannot
drift between agents. The three rules you must not get wrong even if you skip
the read:

- ⚠⚠ **THE USER'S OWN SQL IS THE USER'S.** Handed a query to fix, change only
  what is broken. Keep their keywords, their CTE names, their layout. House
  style applies to files **you** create from scratch, never as a reason to
  restyle working code.
- **UPPERCASE keywords and functions, lowercase identifiers**, and a header
  giving the grain plus any measured figure with the date it was measured.
- **Comments say *why*, not what.** A filter that works around a data-quality
  problem names the problem, or it becomes folklore nobody can audit.

## Step 7 — The Snowflake VS Code extension (optional)

This is the nicest of the three views — a Run button on a `.sql` file plus a
sortable, exportable results grid. It is **optional**: it adds no capability
the other two routes lack, so never treat it as blocking. Skip it for anyone
working from the terminal or a notebook.

**When it is worth installing:** they want to click Run and read a results
grid, sort columns, or export a selection by hand, rather than reading a
terminal table or a DataFrame.

**When to skip it:** they work over SSH or in a terminal-only session, or they are
happy with `--open`, which already renders a browser table with no
extension involved.

To install it:

1. Check first — it may already be there:
   `ls ~/.vscode/extensions | grep -i snowflake`
2. If not, install from the Extensions sidebar (⇧⌘X) by searching
   *Snowflake*; the id is `snowflake.snowflake-vsc`, publisher Snowflake.
   `code --install-extension snowflake.snowflake-vsc` works only if the
   `code` CLI is on their PATH, which it is not by default on macOS —
   Command Palette → *Shell Command: Install 'code' command in PATH* adds
   it. The sidebar is the shorter path; installing extensions is their
   click, not a command you can run for them.
3. Reload the window (Command Palette → *Developer: Reload Window*).
4. Open the Snowflake icon in the sidebar and sign in, picking the `prod`
   connection. Then open
   `examples/example_servicing-dashboard.sql` and hit **Run All** (⌘⏎).

Things that go wrong, in the order they usually do:

- **No connections listed.** The extension defaults to
  `~/.snowflake/connections.toml`; this machine keeps profiles in
  `config.toml` instead, so `.vscode/settings.json` sets
  `snowflake.connectionsConfigFile` to point at it. That setting is read at
  window load — if they installed the extension after opening the folder,
  reload the window. If the setting is missing from
  `.vscode/settings.json`, add it.
- **It asks them to sign in again even though `mise run check` works.**
  Expected. The extension is a separate client with its own session; the
  Python connector's Keychain-cached SSO token is not shared with it.
  Signing in twice on the first day is normal.
- **A file fails with a syntax error near `{`.** That is a `{db}`-style
  file, and no `.sql` file in the workspace should be one any more — check
  whether it is new or was reverted. The extension sends the file verbatim
  and does no Python substitution. Run it with `mise run sql` meanwhile.
- **No warehouse.** The extension does not read `mise.toml`, so
  `SNOWFLAKE_WAREHOUSE` does not reach it. If queries fail with "No active
  warehouse selected", add `use warehouse NPL_ANALYST_WH;` at the top of
  the file or set a warehouse in the connection.

## Step 8 — Hand over

Point them at `examples/example_servicing-dashboard.ipynb` and its
companion `example_servicing-dashboard.sql`, and tell them both hold the same query
— the notebook for charting and follow-up cells, the `.sql` for a quick
answer. Say which routes you actually verified, and name any you skipped
and why (the extension being optional is the usual reason).

For where everything lives, point them at **Where things are** in
`README.md`; don't list folders from memory. In short: `work/` has one
folder per concern, retired material is in `work/.archive/`, and each
project folder opens with a `README.md` or `summary.md`.

Mention three things that trip people up:

- Snowflake returns column names **upper-cased** (`df["COLLECTED"]`). Pass
  `lower=True` to `q()` for lower-case.
- Warehouse table names **drop the domain prefix** the dbt model filenames
  carry: the model `fct_npl_case_collection.sql` is
  `PROD.NPL_COMMON.FCT_CASE_COLLECTION`. Always confirm a real name with
  `datalake.q("show tables in schema PROD.NPL_COMMON")` before writing a
  query against a name taken from the repo.
- Queries longer than a couple of lines belong in a `.sql` file, not inline
  in a cell — beside the notebook if they belong to it, in `work/` if
  shared. `datalake.q("some_file")` and `mise run sql -- some_file` then
  both read the one file.

## Do

- Explain what a command does before running it, in one line.
- Assume no terminal until you've checked (Step 0a). Someone with only VS
  Code open needs to be told where commands go before being given any.
- Prefer `mise run <task>` over raw commands, so tasks stay the interface.
- Read `README.md` in the workspace root if you need more detail.
- Tell them plainly when something needs a person, not a command (Snowflake
  access, installing a VS Code extension).
- Set up the `.sql` route (Step 6) as well as the notebook. Someone who can
  only run notebooks is half set up.
- Say which of the three routes you verified and which you did not. "Works"
  without naming the route is what sends people back to you.

## Don't

- Don't accept or ask for anyone's password, Snowflake or macOS.
- Don't write real credentials into any file in the workspace. Connection
  details belong in `~/.snowflake/config.toml`; only that file's location
  is referenced here.
- Don't add dependencies to brocc-data's dbt project. It pins an exact
  dbt-snowflake tree, and extra packages there break dbt builds and CI.
  Notebook dependencies go in this workspace's `pyproject.toml` via
  `uv add`.
- Don't run `snow connection list` as a config check — it triggers a full
  SSO browser login. Use `cat ~/.snowflake/config.toml` instead.
- Don't install pip, or add it to `pyproject.toml`, to silence VS Code's
  "requires the ipykernel package" dialog. Verify with
  `uv run python -c "import ipykernel"` first — the package is almost
  always already there, and the venv having no pip is `uv` working as
  intended.
- Don't treat the Snowflake extension as required, and don't debug it
  before Steps 2-6 pass. It is a nicer view over the same connection, and
  a failure there says nothing about whether their setup works.
- Don't edit a `{db}`-style `.sql` file just to make the extension accept
  it. Run it with `mise run sql` instead, and let them decide whether
  converting it to a session variable is worth it. (Sharlene made that call
  for the whole workspace on 2026-09-09: all `.sql` files are session
  variables now. It still applies to any new file.)
