# Setup

One-time setup for a new machine. If `mise run check` already prints `CONNECTED`, you're set up
and want [README.md](README.md) instead.

macOS and zsh. You need Homebrew, VS Code, membership of the `brocc-ab` GitHub org and your
Snowflake roles before you start. The roles take someone else's time, so ask first
([Step 0](#step-0--ask-for-the-three-things-no-command-can-give-you)).

## Quick start

If you have all of the above, this is the whole setup:

```bash
# 1. Both repos side by side, plus the two files that sit above them
mkdir -p ~/data-warehouse && cd ~/data-warehouse
git clone https://github.com/brocc-ab/brocc-data.git
git clone https://github.com/sharlenechin/local-workspace.git
cp local-workspace/bootstrap/CLAUDE.md local-workspace/bootstrap/data-warehouse.code-workspace .

# 2. Point the editor settings at your home folder, and keep git from tracking that change
sed -i '' "s|/Users/sharlenechin|$HOME|g" data-warehouse.code-workspace local-workspace/.vscode/settings.json
cd local-workspace && git update-index --skip-worktree .vscode/settings.json

# 3. Python and packages
brew install mise && echo 'eval "$(mise activate zsh)"' >> ~/.zshrc && exec zsh
mise trust && mise install && uv sync
uv run nbstripout --install && uv run pre-commit install
mise run kernel

# 4. Snowflake (then replace CHANGE_ME@brocc.com with your email in that file)
mkdir -p ~/.snowflake && cp examples/snowflake-config.toml.example ~/.snowflake/config.toml
chmod 0600 ~/.snowflake/config.toml

# 5. Check
mise run check    # opens a browser to sign in, then prints CONNECTED
```

Then open `~/data-warehouse/data-warehouse.code-workspace` in VS Code (the file, not the folder)
and install the extensions it recommends.

If a step fails, or you'll be working on dbt models, use the full steps below. The
[workspace-setup agent](.claude/agents/workspace-setup.md) can also do steps 5 onwards for you:
start Claude Code in `local-workspace` and ask it to set up the workspace.

## Full steps

To do it by hand, work down this table. Each step assumes the ones above it.

| # | Step | Done when |
|---|---|---|
| 0 | [Ask for the three things no command can give you](#step-0--ask-for-the-three-things-no-command-can-give-you) | Someone has confirmed your GitHub and Snowflake access |
| 1 | [Get the files into place](#step-1--get-the-files-into-place) | `ls ~/data-warehouse` shows four entries |
| 2 | [Make the machine-local paths yours](#step-2--make-the-machine-local-paths-yours) | `grep` for the old username finds nothing |
| 3 | [Open the workspace file, not the folder](#step-3--open-the-workspace-file-not-the-folder) | The sidebar lists two roots: `local-workspace` and `brocc-data` |
| 4 | [Install the VS Code extensions](#step-4--install-the-vs-code-extensions) | Six extensions installed |
| 5 | [Install mise](#step-5--install-mise) | `mise doctor` runs |
| 6 | [Install Python and the packages](#step-6--install-python-and-the-packages) | `uv sync` finishes |
| 7 | [Register the notebook kernel](#step-7--register-the-notebook-kernel) | **Python (local-workspace)** is in the kernel picker |
| 8 | [Write your Snowflake connection file](#step-8--write-your-snowflake-connection-file) | `~/.snowflake/config.toml` holds your email |
| 9 | [Check the connection](#step-9--check-the-connection) | `mise run check` prints `CONNECTED` |
| 10 | [Start Claude Code in the right directory](#step-10--start-claude-code-in-the-right-directory) | `/agents` lists six agents |
| 11 | [dbt, only if you will touch models](#step-11--dbt-only-if-you-will-touch-models) | `mise run lint` runs |
| 12 | [Verify the whole thing](#step-12--verify-the-whole-thing) | Every row of the last table passes |

Steps 0–9 give you working notebooks against production data. Step 10 is
optional. Step 11 is where most people lose an afternoon, and the reason is
in the step.

### What you are aiming at

```
~/data-warehouse/
├─ CLAUDE.md                      the rules both workspaces follow
├─ data-warehouse.code-workspace  ← you open THIS FILE in VS Code
├─ brocc-data/                    the team's dbt/Airflow/dlt monorepo (git)
└─ local-workspace/               notebooks and ad-hoc analysis (this folder)
```

Two folders side by side, one VS Code window, one Claude Code session started
in `local-workspace`. The layout is load-bearing: [../CLAUDE.md](../CLAUDE.md)
refers to `brocc-data`'s files by relative path, so a clone nested anywhere
else breaks those references.

### Step 0 — Ask for the three things no command can give you

These need another human, and Step 9 cannot pass without the second one. Ask
now, then carry on with the rest while you wait.

| What | Where | Who |
|---|---|---|
| Membership of the **`brocc-ab`** GitHub org | github.com | Whoever manages GitHub |
| The **`NPL_ANALYST`** role on the **`brocc-prod`** Snowflake account | Snowflake | The data team |
| The **`DEVELOPER`** role on **`brocc-sandbox`**, plus a dev schema named after you | Snowflake | The data team — Step 11 only |

On the third: ask for **`DEVELOPER`** by name. `brocc-data`'s example config
asks for `ROLE_DBT`, but that role is not granted to people directly here —
`DEVELOPER` is, and it inherits `ROLE_DBT`. If you are given something
read-only like `SANDBOX_RO` instead, dbt will compile, lint and draw lineage,
but `dbt run` and `dbt build` fail for want of `CREATE`. That is a grant
problem, not a setup problem.

### Step 1 — Get the files into place

```bash
mkdir -p ~/data-warehouse
cd ~/data-warehouse
git clone https://github.com/brocc-ab/brocc-data.git
```

Then clone `local-workspace` beside it, and copy the two files that belong one level up:

```bash
git clone https://github.com/sharlenechin/local-workspace.git
cp local-workspace/bootstrap/CLAUDE.md local-workspace/bootstrap/data-warehouse.code-workspace .
ls
# expect exactly: CLAUDE.md  brocc-data  data-warehouse.code-workspace  local-workspace
```

`CLAUDE.md` and `data-warehouse.code-workspace` sit at `~/data-warehouse/`, above both repos,
so neither repo can hold them in place. `bootstrap/` keeps the current copies. If you change
either file, copy it back into `bootstrap/` so the next person gets your version.

**If `local-workspace` arrived with a `.venv` directory, delete it now.** A
venv is not portable: its `pyvenv.cfg` points at the Python install of
whoever built it, and every script in `.venv/bin` carries their path in its
shebang. Step 6 builds you a fresh one.

```bash
rm -rf ~/data-warehouse/local-workspace/.venv
```

If the clone fails on authentication, that is Step 0's first row, not a
command you can fix.

### Step 2 — Make the machine-local paths yours

Two settings files hold absolute paths with the previous owner's username in
them. Both explain in their own comments why the paths are absolute rather
than `${workspaceFolder}`: VS Code's `files.associations` is window-scoped and
registers every pattern in one flat global registry, so `"*.sql"` cannot mean
two things in one window and each pattern has to carry its own path; and dbt
Power User validates paths with a raw `existsSync()`, which a `${...}`
placeholder fails.

Rewrite them for your account — `$HOME` expands to whatever your home
directory actually is:

```bash
cd ~/data-warehouse
sed -i '' "s|/Users/sharlenechin|$HOME|g" \
  data-warehouse.code-workspace \
  local-workspace/.vscode/settings.json
```

Then confirm nothing was missed. This should print **nothing at all**:

```bash
grep -rn "sharlenechin" \
  data-warehouse.code-workspace \
  local-workspace/.vscode/settings.json
```

A third file, `brocc-data/.vscode/settings.json`, needs the same treatment but
does not exist yet — it is gitignored in that repo, so no clone brings it.
[Step 11](#step-11--dbt-only-if-you-will-touch-models) installs it.

Moving the folders after this point means running the `sed` again.

If you cloned `local-workspace` from git, tell git to leave your rewritten
settings file alone, so your paths never show up as a change to commit:

```bash
cd ~/data-warehouse/local-workspace
git update-index --skip-worktree .vscode/settings.json
```

### Step 3 — Open the workspace file, not the folder

If all you have open is VS Code, start here.

1. **File → Open Workspace from File…**
2. Pick `~/data-warehouse/data-warehouse.code-workspace`.

Open that **file**, not the `~/data-warehouse` folder. VS Code only reads
`.vscode/settings.json` from a directory that is a workspace *root*. Open the
parent folder and `local-workspace/.vscode/settings.json` never loads — so
notebooks get no default interpreter and the Snowflake extension cannot find
your connections. Those two account for most of the time people lose here.
The workspace file makes each directory its own root, which avoids both.

The sidebar should now list two top-level folders, `local-workspace` and
`brocc-data`. If `brocc-data` is missing or greyed out it is not cloned yet —
Step 1 fixes that, then reload the window.

3. **Open the built-in terminal**: ⌃` (Control-backtick), or **View →
   Terminal**. Every command below runs there, from the workspace root:

```bash
cd ~/data-warehouse/local-workspace
```

### Step 4 — Install the VS Code extensions

Six, and each is load-bearing for something:

| Extension | ID | What it gives you |
|---|---|---|
| Python | `ms-python.python` | Interpreter selection, Pylance |
| Jupyter | `ms-toolsai.jupyter` | Notebooks in VS Code |
| Snowflake | `snowflake.snowflake-vsc` | The **Run** button on `.sql` files, and a results panel |
| mise | `hverlin.mise-vscode` | `mise: run task` in the Command Palette |
| dbt Power User | `innoverio.vscode-dbt-power-user` | dbt lineage, compile, preview — **Step 11 only** |
| Jinja | `samuelcolvin.jinjahtml` | The `jinja-sql` language ID that `brocc-data` models open as |

```bash
for id in ms-python.python ms-toolsai.jupyter snowflake.snowflake-vsc \
          hverlin.mise-vscode innoverio.vscode-dbt-power-user \
          samuelcolvin.jinjahtml; do
  code --install-extension "$id"
done
```

If `code` is not a command: Command Palette (⇧⌘P) → *Shell Command: Install
'code' command in PATH*. Or install them by name from the Extensions pane.

**Why the Jinja one matters even though you are not writing Jinja.** The
workspace file maps `brocc-data/**/*.sql` to `jinja-sql` and
`local-workspace/**/*.sql` to `snowflake-sql`. Those language IDs are not
interchangeable: every command the Snowflake extension ships is gated on
`editorLangId == 'snowflake-sql'`, so a `.sql` file opened as plain `sql` gets
no Run button — and a dbt model opened as anything but `jinja-sql` gets no
`ref()` resolution.

### Step 5 — Install mise

```bash
brew install mise
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
```

The second line is what puts mise on your PATH; skip it and nothing below
works. **Then close and reopen the terminal** — bin icon on the terminal
panel, then ⌃` again — and check:

```bash
mise doctor
```

### Step 6 — Install Python and the packages

```bash
cd ~/data-warehouse/local-workspace
mise trust      # approve this folder's config
mise install    # Python 3.12 + uv, and creates .venv
uv sync         # pandas, the Snowflake driver, Jupyter, plotly
```

`mise trust` reads like an error the first time. It isn't — mise won't load
settings from a directory until you confirm it's yours.

You never need `source .venv/bin/activate`. mise activates the venv when you
`cd` in. To check it did, `which python` should print a path inside
`local-workspace/.venv`.

If you cloned this from git, run these once as well:

```bash
uv run nbstripout --install   # strips notebook outputs from what you commit, keeps yours
uv run pre-commit install     # blocks data files, big files and keys at commit time
```

Data files of every kind (spreadsheets, CSVs, parquet, PDFs, seller tapes) are
kept out by `.gitignore`, and the pre-commit check refuses them even if one is
force-added. Keep them in a folder git ignores.

### Step 7 — Register the notebook kernel

```bash
mise run kernel
```

Open [examples/example_servicing-dashboard.ipynb](examples/example_servicing-dashboard.ipynb),
click the kernel name at the top right, and pick **Python
(local-workspace)**. Not listed? Reload the window (⇧⌘P → *Developer: Reload
Window*).

#### Pick the right entry — there are two, and they are not equivalent

The picker offers **two** things that both point at this venv:

| Entry in the picker | What it is | Use it? |
|---|---|---|
| **Python (local-workspace)** | The kernel `mise run kernel` registered. Launches `.venv/bin/python` by absolute path. | ✅ Yes |
| **.venv (3.12.14)** *(or similar)* | VS Code spotting the folder's venv by itself | ⚠️ Usually works, but see below |

Both run the same Python. The registered kernel is the reliable one because
VS Code starts it from the recorded path and skips its own environment
probing.

#### "Running cells requires the ipykernel package" — and then it asks for pip

You will probably hit this, and it is misleading on both counts.

**`ipykernel` is already installed.** It's a declared dependency in
[pyproject.toml](pyproject.toml), so `uv sync` puts it in the venv. Confirm
it yourself:

```bash
uv run python -c "import ipykernel; print(ipykernel.__version__)"
```

A version means nothing is missing — VS Code probed the wrong interpreter, or
cached its view of the environment from before `uv sync` ran.

**`pip` genuinely is absent, and that's correct.** `uv` creates virtual
environments without pip on purpose; packages come from `uv add` and
`uv sync` instead. So VS Code's **Install** button shells out to a pip that
was never there and fails. Don't chase the pip error — you don't need pip in
this workspace.

What to do, in order:

1. Pick **Python (local-workspace)** rather than the auto-detected `.venv`
   entry.
2. Reload the window, to clear VS Code's cached view of the environment.
3. If the kernel isn't offered at all, run `mise run kernel` and reload
   again.

Only if you want VS Code's Install buttons to work at all, `uv pip install
pip` adds pip to the venv. Nothing here needs it, and the next `uv sync`
removes it again since it isn't in the lockfile. Don't add it to
`pyproject.toml` to make it stick.

### Step 8 — Write your Snowflake connection file

The only file you have to create yourself, and it lives outside the workspace
entirely — in your home directory, which is why no amount of copying a
workspace ever brings it with it:

```bash
cd ~/data-warehouse/local-workspace
mkdir -p ~/.snowflake
cp examples/snowflake-config.toml.example ~/.snowflake/config.toml
chmod 0600 ~/.snowflake/config.toml
```

Now open `~/.snowflake/config.toml` and replace `CHANGE_ME@brocc.com` with
your own Brocc email **in both places**:

```toml
default_connection_name = "prod"

[connections.prod]
account = "brocc-prod"
user = "your.name@brocc.com"
authenticator = "externalBrowser"
role = "NPL_ANALYST"

[connections.sandbox]
account = "brocc-sandbox"
user = "your.name@brocc.com"
authenticator = "externalBrowser"
role = "PUBLIC"
```

If you are doing Step 11, add a third profile now — dbt and the Snowflake
extension both use it for sandbox work:

```toml
[connections.dev]
account = "brocc-sandbox"
user = "your.name@brocc.com"
authenticator = "externalbrowser"
role = "DEVELOPER"
warehouse = "DEV_WH"
database = "DEV"
schema = "DBT_YOURNAME"
```

Two things worth understanding:

- **There is no password and no private key.** `externalBrowser` means
  single sign-on — Snowflake logs you in through a browser tab, exactly like
  its web UI. Nobody should ever ask you to put a Snowflake password in a
  file.
- **`chmod 0600` is not optional.** Snowflake refuses to read a config file
  other users on your Mac could read, and the resulting error looks like a
  connection failure rather than a permissions one.

### Step 9 — Check the connection

```bash
mise run check
```

**Two prompts appear, and both surprise people:**

1. **A browser tab opens** asking you to log in. That's SSO working. Log in
   as normal.
2. **macOS asks for a password** to let Python use your Keychain. That's your
   **Mac login password** — *not* your Snowflake one. Click **Always Allow**,
   not Allow; Allow grants access once, so the box returns on every run.

The Keychain stores your Snowflake token, which is why you sign in about
once a day rather than once a query.

A working result:

```
  CONNECTED

    account    NF61585
    user       YOUR_NAME
    role       NPL_ANALYST
    warehouse  NPL_ANALYST_WH
```

If `warehouse` is `(not set)`, the check lists what your role can use — put
the right one in [mise.toml](mise.toml) as `SNOWFLAKE_WAREHOUSE`. Connecting
works without it, but real queries fail with "No active warehouse selected".

**You can now query, three ways — and that one file is the whole Snowflake
setup for all of them.** There is nothing further to configure per route:

| Route | How it reaches Snowflake |
|---|---|
| Notebook | `import datalake` → `datalake.q()` reads `~/.snowflake/config.toml` |
| Terminal | `mise run sql -- <file>` → [scripts/run_sql.py](scripts/run_sql.py), which imports the same `datalake` |
| VS Code | The Snowflake extension, pointed at the same file by `snowflake.connectionsConfigFile` in [.vscode/settings.json](.vscode/settings.json) |

`mise run check` has already proved the middle one, since
[scripts/check_connection.py](scripts/check_connection.py) is an
ordinary script importing `datalake` — no notebook involved. Try all three on
[examples/example_collections_by_servicer.sql](examples/example_collections_by_servicer.sql),
which is plain SQL written to run unedited by any of them. Everything below is
tooling around these.

### Step 10 — Start Claude Code in the right directory

Install it, if the VS Code extension is not enough for you:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Then — the part that is easy to get wrong — **start it from
`local-workspace`**:

```bash
cd ~/data-warehouse/local-workspace
claude --add-dir ../brocc-data
```

Why that directory and not the parent:

- **The rules come from the parent either way.** Claude Code reads
  `CLAUDE.md` from the current directory upwards, so starting in
  `local-workspace` still picks up `~/data-warehouse/CLAUDE.md`. Starting one
  level up gains you nothing.
- **The agents do not.** The five agents in [.claude/agents/](.claude/agents/)
  load only when `local-workspace` is the project root. Start in
  `~/data-warehouse` and `/agents` is empty — silently — and every finding,
  guard and gap those agents hold is unavailable.
- **`--add-dir ../brocc-data`** makes that repo readable in the same session,
  which you want: it is the source of truth for what a model contains and how
  a column is derived. Reading it is encouraged; writing to it is a different
  kind of request with its own reading list.

Verify with `/agents` — five entries: `query-helper`, `benchmark-post-registration-analyst`,
`benchmark-post-registration-builder`, `sigma-dashboard-builder`, `workspace-setup`. In VS Code the
extension follows the folder you have active, so open a terminal at the
`local-workspace` root and launch from there.

Two rules from [../CLAUDE.md](../CLAUDE.md) worth knowing before your first
session, because they surprise people otherwise: **Claude never commits or
pushes** in either repo, and **a local analysis question is never answered by
editing a dbt model**. Both are deliberate.

### Step 11 — dbt, only if you will touch models

Skip this unless you are going to open `brocc-data` models. It is where people
lose an afternoon, and the reason is structural: that repo gitignores all of
`.vscode/` and all of `.venv/`, so **four of the five things below never
arrive with `git clone`, and re-cloning destroys them.** Nothing warns you;
dbt simply reports a missing profile.

Work from the dbt project root:

```bash
cd ~/data-warehouse/brocc-data/transformation/dbt
```

**a. Your Snowflake variables.** Gitignored — copy the example and fill it in:

```bash
cp mise.local.toml.example mise.local.toml
```

Edit three lines: `DBT_SNOWFLAKE_USER` to your Brocc email,
`DBT_SNOWFLAKE_DEV_SCHEMA` to `DBT_YOURNAME`, `DBT_SNOWFLAKE_TAG_SCHEMA` to
`DBT_TAG_YOURNAME`. Set `DBT_SNOWFLAKE_DEV_ROLE` to whichever role you were
actually granted in Step 0. Nothing in the file is a secret — it is all SSO —
but it stays out of git because it is per-person.

**b. The dbt venv and packages:**

```bash
mise trust
mise install
mise run install-dev      # uv sync --frozen --group dev --extra llm-agents, then dbt deps
```

**c. The profile-discovery patch.** dbt finds its profile through
`DBT_PROFILES_DIR`, which that project's `mise.toml` sets — but mise only
exports it to a shell, and dbt Power User spawns the venv's Python directly
with VS Code's own environment. Launched from the Dock, VS Code has neither
that variable nor the Snowflake ones, and the extension reports:

```
Could not find profile named 'brocc-snowflake'
```

The extension has no setting for it — 33 `dbt.*` keys, none of which inject
environment variables — so the fix lives on the interpreter instead:

```bash
cp ~/data-warehouse/local-workspace/bootstrap/sitecustomize.py \
   ~/data-warehouse/brocc-data/transformation/dbt/.venv/lib/python3.12/site-packages/
```

Python imports `sitecustomize` automatically at startup, so every process
using that venv gets the variables however VS Code was launched. It only sets
`DBT_*` variables that are not already set, so a real shell always wins. **It
survives `uv sync` but not deleting the venv** — if dbt suddenly cannot find
the profile again, this file is the first thing to check. It explains itself
in full at the top.

**d. The folder-level VS Code settings**, also gitignored there:

```bash
mkdir -p ~/data-warehouse/brocc-data/.vscode
cp ~/data-warehouse/local-workspace/bootstrap/brocc-data-vscode-settings.json \
   ~/data-warehouse/brocc-data/.vscode/settings.json
sed -i '' "s|/Users/sharlenechin|$HOME|g" \
   ~/data-warehouse/brocc-data/.vscode/settings.json
```

Do not skip the `sed`. Power User validates those paths with `existsSync()`
and silently reports dbt as "not installed" when they are wrong.

**e. The deferral manifest** (optional, ~3 MB, not in git). It makes unbuilt
`ref()`s resolve to a real existing build rather than your empty dev schema:

```bash
cd ~/data-warehouse/brocc-data/transformation/dbt
DBT_SNOWFLAKE_DEV_SCHEMA=PROD mise exec -- dbt parse
mkdir -p prod-state && cp target/manifest.json prod-state/
```

Note the limit, documented at length in the settings file you just copied:
deferral applies to dbt commands Power User shells out to (`run`, `build`,
`test`), **not** to "Preview SQL Query" on a model — that path compiles
in-process and does not apply deferral, and no configuration fixes it. To
just run a query, use `explorations/scratch.sql`, which is plain SQL with no
`ref()` to resolve.

**Then verify:**

```bash
cd ~/data-warehouse/brocc-data/transformation/dbt
mise run lint      # sqlfluff — its dbt templater compiles the project, so it
                   # needs the Snowflake vars even though it only lints
mise run format
```

Both gate CI, and both are the last thing to run before handing over any
change to a model.

### Step 12 — Verify the whole thing

| Check | Command or action | Expected |
|---|---|---|
| Folder layout | `ls ~/data-warehouse` | `CLAUDE.md`, `brocc-data`, `data-warehouse.code-workspace`, `local-workspace` |
| No leftover paths | `grep -rn sharlenechin ~/data-warehouse --include="*.json" --include="*.code-workspace"` | nothing |
| VS Code roots | Look at the sidebar | two folders, not one |
| Python | `cd ~/data-warehouse/local-workspace && which python` | a path inside `local-workspace/.venv` |
| Snowflake | `mise run check` | `CONNECTED`, role `NPL_ANALYST` |
| A real query, in a notebook | Run the first cells of `examples/example_servicing-dashboard.ipynb` | a DataFrame |
| A real query, from a script | `mise run sql -- examples/example_collections_by_servicer.sql --limit 5` | five rows in a table |
| `.sql` Run button | Open any `.sql` file in `local-workspace` | a **Run** button, top right |
| Claude agents *(Step 10)* | `claude` from `local-workspace`, then `/agents` | five agents listed |
| dbt *(Step 11)* | `mise run lint` in `transformation/dbt` | sqlfluff runs |
| dbt lineage *(Step 11)* | Open a model in `brocc-data`, check the lineage panel | a graph, no "profile not found" |

### What you still will not have

**Anyone's finished work, or the data behind it.** `work/` arrives empty and
no CSV exports are shared: they are loan-level data, they go stale, and they
regenerate from the `.sql` files that produced them — `mise run sql -- <file>`,
or the notebook top to bottom. If you need a particular piece of finished work,
ask for that folder specifically rather than expecting it here.

**Anyone else's Snowflake grants.** Roles are per-person. If a query returns
"Object does not exist or not authorized" and the table plainly does exist,
that is Step 0's second or third row, not a broken setup.

Stuck anywhere? [**When something breaks**](README.md#when-something-breaks)
in the README translates the error messages this stack actually produces,
including the misleading ones.
