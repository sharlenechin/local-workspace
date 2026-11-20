"""Give dbt Power User the environment mise would have given it.

WHY THIS FILE EXISTS
--------------------
dbt looks for its profile via DBT_PROFILES_DIR, which this project sets in
mise.toml (to "profile", since profiles.yml lives in profile/ rather than a
standard location). The Snowflake connection details come from mise.local.toml.

mise only exports those when a shell activates it. The VS Code extension
"dbt Power User" does not go through a shell: it spawns this venv's Python
directly with VS Code's own environment. Launched from the Dock, VS Code has
neither variable, so dbt falls back to ~/.dbt/, finds no profiles.yml, and the
extension reports:

    Could not find profile named 'brocc-snowflake'

Fixing only the path moves the failure one step along, to
"Env var required but not provided: DBT_SNOWFLAKE_ACCOUNT", because
profiles.yml is entirely env_var() calls.

The extension (v0.64.5) has no setting for either problem — 33 dbt.* settings,
none of which inject environment variables or override the profiles directory,
and it does not honour python.envFile. The only lever left is the environment
of the interpreter itself, which is what this file supplies.

Python imports `sitecustomize` automatically at startup (see the `site`
module), so every process using this venv's interpreter gets the variables —
regardless of how VS Code was launched.

WHY IT IS SAFE
--------------
  * It only ever sets variables that are NOT already set, so a real shell,
    mise, or CI always wins. Running under mise it does nothing at all.
  * It only sets DBT_* variables. PATH and VIRTUAL_ENV are deliberately left
    alone — the extension manages its own interpreter.
  * It asks mise for the values rather than parsing the TOML, so it stays
    correct as mise.toml/mise.local.toml change, and it resolves templates
    like {{config_root}} the same way mise does.
  * It can never break Python startup: everything is wrapped, the subprocess
    is given a timeout, and any failure is silent.

GIT
---
This file lives in .venv/, which transformation/dbt/.gitignore ignores, so it
is invisible to git and there is nothing to commit. It is machine-local.

It survives `uv sync` (uv manages packages, not loose modules) but NOT deleting
the venv. If you ever rebuild the venv from scratch, recreate this file.
"""

import os

def _load_mise_env() -> None:
    # Already under mise (a terminal, or CI): nothing to do, and no cost.
    if "DBT_PROFILES_DIR" in os.environ:
        return

    import json
    import subprocess

    # PATH is minimal for a GUI-launched app, so mise must be found by
    # absolute path rather than looked up.
    candidates = (
        "/opt/homebrew/bin/mise",
        os.path.expanduser("~/.local/bin/mise"),
        "/usr/local/bin/mise",
    )
    mise = next((p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)), None)
    if mise is None:
        return

    # mise resolves config by directory, so ask from the dbt project root —
    # this file is at <project>/.venv/lib/python3.12/site-packages/.
    project_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), *[os.pardir] * 4)
    )
    if not os.path.isfile(os.path.join(project_dir, "dbt_project.yml")):
        return

    result = subprocess.run(
        [mise, "env", "--json"],
        cwd=project_dir,
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        return

    # Only DBT_*, and only where unset, so nothing already in the environment
    # is ever overwritten.
    for key, value in json.loads(result.stdout).items():
        if key.startswith("DBT_") and key not in os.environ:
            os.environ[key] = str(value)


try:
    _load_mise_env()
except Exception:
    # Never break interpreter startup. A failure here just leaves the
    # environment as it was, and the extension reports its original error.
    pass
