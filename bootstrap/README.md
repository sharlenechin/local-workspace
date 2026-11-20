# bootstrap/

Files that belong somewhere a clone of this repo can't reach, kept here so a new machine can be
set up from one place.

| File | Where it goes | Why it's here |
|---|---|---|
| `CLAUDE.md` | `~/data-warehouse/CLAUDE.md` | The rules both workspaces follow. It sits above both repos, so neither can track it |
| `data-warehouse.code-workspace` | `~/data-warehouse/` | The VS Code workspace that opens both repos. Same reason |
| `brocc-data-vscode-settings.json` | `brocc-data/.vscode/settings.json` | See below |
| `sitecustomize.py` | the dbt venv's `site-packages/` | See below |

The first two are copied into place by Step 1 of [SETUP.md](../SETUP.md). If you change either
one, copy it back here.

The last two **belong to `brocc-data` but cannot live there**:

`brocc-data`'s root `.gitignore` ignores all of `.vscode/` (only
`.vscode/mcp.json` is force-tracked) and all of `.venv/`. So both files below
are invisible to git: they do not arrive with `git clone`, and deleting and
re-cloning that repo destroys them. Nothing in `local-workspace` reads them —
they sit here purely so a new machine can be set up from one place.

| File | Where it goes | What breaks without it |
|---|---|---|
| `brocc-data-vscode-settings.json` | `brocc-data/.vscode/settings.json` | dbt Power User has no interpreter and no deferral; "Preview SQL" and lineage misbehave |
| `sitecustomize.py` | `brocc-data/transformation/dbt/.venv/lib/python3.12/site-packages/` | dbt Power User reports `Could not find profile named 'brocc-snowflake'` whenever VS Code is launched from the Dock |

Both are installed by [Step 11 of the README](../README.md#step-11--dbt-only-if-you-will-touch-models).

Two things to remember about them:

- **They contain absolute paths** (`/Users/sharlenechin/...`). SETUP.md rewrites
  them with `sed`. The paths are absolute on purpose — dbt Power User validates
  interpreter and manifest paths with a raw `existsSync()`, so a
  `${workspaceFolder}` placeholder fails the check and dbt is reported as "not
  installed". Both files explain this in their own comments.
- **`sitecustomize.py` must be re-copied every time the dbt venv is rebuilt.**
  It survives `uv sync`, but not `rm -rf .venv`.

If either file is changed in `brocc-data`, copy the new version back here, or
the next person to set up a machine gets the old one.
