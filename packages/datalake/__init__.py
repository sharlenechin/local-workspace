"""Query Brocc's Snowflake warehouse from a notebook, into pandas.

Connections are read from ``~/.snowflake/config.toml``, which defines two
SSO (``externalBrowser``) profiles:

===========  ==============  =============  ==========================
profile      account         role           use for
===========  ==============  =============  ==========================
``prod``     brocc-prod      NPL_ANALYST    reading production marts
``sandbox``  brocc-sandbox   PUBLIC         scratch / dbt dev schemas
===========  ==============  =============  ==========================

The first connect opens a browser for SSO; the token is then cached in the
macOS Keychain, so later calls are silent until it expires.

``connection_name=`` is used here rather than the JWT/private-key dance
described in brocc-data's ``analytics-wizard`` agent doc. That doc's
warning applies to key-pair auth — this machine's profiles are SSO, where
``connection_name`` resolves the profile correctly.

Where a dbt model lands depends on the target that built it:

===========================  =======  ===================================
model                        target   object to query
===========================  =======  ===================================
``my_customer_model.sql``    prod     ``prod.my_schema.dim_customer``
(alias ``dim_customer``)     dev      ``dev.dev_schema.my_customer_model``
===========================  =======  ===================================

i.e. prod exposes the *alias*, dev exposes the *filename*.

Note that Snowflake returns column names upper-cased, so expect
``df["COLLECTED"]`` rather than ``df["collected"]``. Pass ``lower=True`` to
:func:`q` to get lower-cased columns instead.
"""

from __future__ import annotations

import datetime as dt
import decimal
import io
import os
import re
from pathlib import Path
from typing import Any

import pandas as pd
import snowflake.connector as sf
from snowflake.connector.errors import NotSupportedError
from snowflake.connector.util_text import split_statements

__all__ = [
    "connect",
    "q",
    "execute",
    "read_sql",
    "queries_dir",
    "session_info",
    "warehouses",
    "tables",
    "dictionary",
    "describe_column",
    "find_columns",
    "apply_variables",
    "session_var_names",
    "placeholder_names",
    "reset",
]

# Where the NPL marts live. NPL_ANALYST can read PROD and RAW only.
DEFAULT_DB = "PROD"
DEFAULT_SCHEMA = "NPL_COMMON"

# Workspace root: this file is <root>/packages/datalake/__init__.py
WORKSPACE_ROOT = Path(__file__).resolve().parents[2]

_CONNECTIONS: dict[tuple[str, str], sf.SnowflakeConnection] = {}


def _defaults(connection: str | None, warehouse: str | None) -> tuple[str, str]:
    return (
        connection or os.environ.get("SNOWFLAKE_CONNECTION", "prod"),
        warehouse or os.environ.get("SNOWFLAKE_WAREHOUSE", ""),
    )


def connect(
    connection: str | None = None,
    warehouse: str | None = None,
) -> sf.SnowflakeConnection:
    """Return a live connection for ``connection``, reusing an open one.

    Connections are cached per (profile, warehouse) so a notebook that
    calls :func:`q` in twenty cells still authenticates once.
    """
    name, wh = _defaults(connection, warehouse)
    key = (name, wh)

    cached = _CONNECTIONS.get(key)
    if cached is not None and not cached.is_closed():
        return cached

    con = sf.connect(connection_name=name)
    if wh:
        # Neither profile sets a warehouse, and Snowflake refuses to run a
        # query without an active one ("No active warehouse selected").
        con.cursor().execute(f"use warehouse {wh}")
    _CONNECTIONS[key] = con
    return con


def queries_dir() -> Path:
    """The workspace-wide ``work/`` folder."""
    return WORKSPACE_ROOT / "work"


def _resolve_sql_path(path: str | Path) -> Path:
    """Find a ``.sql`` file, trying the obvious places in order.

    Looks at the path as given (absolute, or relative to the current
    working directory — i.e. the notebook's own folder), then in the
    workspace-wide ``work/`` folder. A missing ``.sql`` suffix is added,
    so ``read_sql("collections_by_servicer")`` works.
    """
    candidate = Path(path)
    if candidate.suffix.lower() != ".sql":
        # Appending beats with_suffix, which would eat the last dotted
        # segment of a name like "2026-09-09.collections".
        candidate = candidate.with_name(candidate.name + ".sql")

    if candidate.is_absolute():
        if candidate.is_file():
            return candidate
        raise FileNotFoundError(f"No SQL file at {candidate}")

    tried: list[Path] = []
    for base in (Path.cwd(), queries_dir(), WORKSPACE_ROOT):
        resolved = base / candidate
        tried.append(resolved)
        if resolved.is_file():
            return resolved

    locations = "\n".join(f"    {p}" for p in tried)
    raise FileNotFoundError(
        f"No SQL file matching {path!r}. Looked in:\n{locations}"
    )


def read_sql(path: str | Path, **variables: Any) -> str:
    """Read a ``.sql`` file and return its text.

    Object names (database, schema, table) cannot be bound as query
    parameters, so they are substituted with ``str.format`` instead. Write
    them as ``{db}`` in the file::

        -- work/collections.sql
        select * from {db}.npl_common.fct_npl_case_collection

        read_sql("collections", db="PROD")

    Any literal ``{`` or ``}`` in a file you substitute into must be
    doubled (``{{``). Files read without ``variables`` are returned
    verbatim, braces and all.
    """
    text = _resolve_sql_path(path).read_text()
    return apply_variables(text, variables)


def _as_sql_text(sql: str | Path, variables: dict[str, Any]) -> str:
    """Resolve the ``sql`` argument of :func:`q` / :func:`execute` to text.

    A ``Path``, or a string ending in ``.sql``, is always read as a file.
    A bare single token (``"collections_by_servicer"``) is read as a file
    *if* one resolves — otherwise it falls through and is treated as query
    text, so single-word statements like ``commit`` still work. Anything
    containing whitespace is query text.
    """
    if isinstance(sql, Path):
        return read_sql(sql, **variables)

    text = str(sql)
    token = text.strip()
    names_a_file = token.lower().endswith(".sql") or (
        token and not any(ch.isspace() for ch in token)
    )
    if names_a_file:
        try:
            return read_sql(token, **variables)
        except FileNotFoundError:
            # An explicit ".sql" was unambiguously meant as a file.
            if token.lower().endswith(".sql"):
                raise

    return apply_variables(text, variables)


def _convert_types(df: pd.DataFrame) -> pd.DataFrame:
    """Turn Snowflake's Python objects into native pandas dtypes.

    The driver returns ``NUMBER`` as :class:`decimal.Decimal` and dates as
    :class:`datetime.date`, both of which land in ``object`` columns. That
    means ``display.float_format`` never applies, plotly mishandles the
    values, ``.dt`` accessors are unavailable, and mixing a Decimal with a
    float raises. Converting up front avoids all of it.

    Decimal becomes float64, which is lossy beyond ~15 significant digits.
    For exact decimal arithmetic on money, pass ``convert=False`` to
    :func:`q` and keep the Decimals.
    """
    for col in df.columns:
        series = df[col]
        if series.dtype != "object":
            continue
        present = series.dropna()
        if present.empty:
            continue
        sample = present.iloc[0]
        if isinstance(sample, decimal.Decimal):
            df[col] = pd.to_numeric(series, errors="coerce")
        elif isinstance(sample, (dt.datetime, dt.date)):
            df[col] = pd.to_datetime(series, errors="coerce")
    return df


_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")


def _identifier(name: str, what: str) -> str:
    """Validate a database/schema name that has to be interpolated.

    Snowflake's ``identifier()`` cannot stand in for the database part of a
    qualified name like ``db.information_schema.columns``, so these are
    interpolated as text. Everything compared as a *value* is still bound
    as a parameter; this only guards the two that cannot be.
    """
    if not _IDENTIFIER.match(name):
        raise ValueError(f"{what} {name!r} is not a valid Snowflake identifier")
    return name.upper()


_NUMERIC_LITERAL = re.compile(r"^-?\d+(\.\d+)?$")


def _sql_literal(value: Any) -> str:
    """Render a value as a SQL literal: bare if numeric, else quoted."""
    text = str(value)
    if _NUMERIC_LITERAL.match(text):
        return text
    return "'" + text.replace("'", "''") + "'"


def _apply_session_var(sql: str, name: str, value: Any) -> tuple[str, bool]:
    """Substitute a Snowflake session variable with a literal.

    A file can declare ``set months = 12;`` and use ``$months`` below, which
    makes it valid standalone SQL that a SQL editor can run. To override the
    value we replace **the literal text**, both in the ``set`` line and at
    every ``$name`` use, rather than just re-setting the variable.

    That matters for correctness, not neatness. Snowflake's result cache
    keys on the query text *before* session variables are resolved, so two
    runs that differ only in a variable's value look identical to the cache
    and the second silently gets the first one's rows. Substituting the
    literal changes the text, so each value gets its own cache entry.
    """
    set_line = re.compile(
        r"^([ \t]*set[ \t]+" + re.escape(name) + r"[ \t]*=[ \t]*)(.+?)(;[ \t]*)$",
        re.IGNORECASE | re.MULTILINE,
    )
    literal = _sql_literal(value)
    sql, set_hits = set_line.subn(lambda m: m.group(1) + literal + m.group(3), sql)

    use = re.compile(r"\$" + re.escape(name) + r"\b", re.IGNORECASE)
    sql, use_hits = use.subn(literal, sql)

    return sql, bool(set_hits or use_hits)


def session_var_names(sql: str) -> list[str]:
    """Session variables a piece of SQL declares with ``set name = ...;``."""
    return sorted(
        set(
            m.lower()
            for m in re.findall(
                r"^[ \t]*set[ \t]+(\w+)[ \t]*=", sql, re.IGNORECASE | re.MULTILINE
            )
        )
    )


def placeholder_names(sql: str) -> list[str]:
    """Python placeholders a piece of SQL uses, as in ``{db}``."""
    return sorted(set(re.findall(r"\{(\w+)\}", sql)))


def apply_variables(sql: str, variables: dict[str, Any]) -> str:
    """Fill a query's variables, whichever style it was written in.

    ``{name}`` is a Python placeholder; ``set name = ...;`` with ``$name``
    is a Snowflake session variable. A name that matches neither is an
    error rather than a silent no-op — a typo would otherwise return a full
    unfiltered result that looks plausible.
    """
    if not variables:
        return sql

    placeholders = placeholder_names(sql)
    fmt: dict[str, Any] = {}
    unknown: list[str] = []

    for name, value in variables.items():
        if name in placeholders:
            fmt[name] = value
            continue
        sql, applied = _apply_session_var(sql, name, value)
        if not applied:
            unknown.append(name)

    if unknown:
        accepted = ", ".join(
            [f"{{{p}}}" for p in placeholders]
            + [f"set {s}" for s in session_var_names(sql)]
        ) or "none"
        raise KeyError(
            f"{unknown[0]!r} is not a variable of this query, so passing it "
            f"would change nothing. Accepted: {accepted}"
        )

    return sql.format(**fmt) if fmt else sql


def _statement_count(sql: str) -> int:
    """How many statements are in ``sql``.

    Uses the connector's own splitter rather than counting semicolons, so a
    ``;`` inside a string literal or comment does not inflate the count.
    """
    try:
        return sum(1 for _ in split_statements(io.StringIO(sql)))
    except Exception:
        # If the splitter cannot parse it, treat it as one statement and let
        # Snowflake report the real problem.
        return 1


def _to_frame(cur: Any, lower: bool, convert: bool) -> pd.DataFrame:
    try:
        df = cur.fetch_pandas_all()
    except NotSupportedError:
        # SHOW/DESCRIBE and DDL do not come back as Arrow batches, so the
        # fast path is unavailable and we build the frame by hand.
        rows = cur.fetchall()
        names = [c.name for c in cur.description]
        df = pd.DataFrame(rows, columns=names)
    if convert:
        df = _convert_types(df)
    if lower:
        df.columns = [c.lower() for c in df.columns]
    return df


def q(
    sql: str | Path,
    params: Any = None,
    *,
    connection: str | None = None,
    warehouse: str | None = None,
    lower: bool = False,
    convert: bool = True,
    **variables: Any,
) -> pd.DataFrame:
    """Run a query and return the rows as a pandas DataFrame.

    ``sql`` is either the query text, or a path to a ``.sql`` file — a
    ``Path``, or a string ending in ``.sql``::

        q("select 1 as x")
        q("collections_by_servicer", db="PROD")   # work/*.sql
        q("work/collections.sql", db="PROD")
        q(Path("collections.sql"))

    ``params`` is passed straight to the driver, so bind *values* rather
    than interpolating them::

        q("select * from f where dt >= %s", ["2026-01-01"])

    ``variables`` are ``str.format`` substitutions for object names, which
    cannot be bound (see :func:`read_sql`). ``lower=True`` lower-cases the
    returned column names.

    ``convert=True`` (the default) maps Snowflake's ``Decimal`` and ``date``
    objects onto float64 and datetime64. Pass ``convert=False`` to keep
    exact ``Decimal`` values for money arithmetic.
    """
    text = _as_sql_text(sql, variables)
    con = connect(connection, warehouse)

    if _statement_count(text) > 1:
        # A file that sets up its own session state — `set months = 12;`
        # ahead of the query — so the same file also runs unchanged in a SQL
        # editor. Snowflake rejects several statements in one execute(), so
        # run them in order and return the last result set.
        cursors = con.execute_string(text, remove_comments=False)
        if not cursors:
            return pd.DataFrame()
        try:
            return _to_frame(cursors[-1], lower, convert)
        finally:
            for cursor in cursors:
                cursor.close()

    with con.cursor() as cur:
        cur.execute(text, params)
        return _to_frame(cur, lower, convert)


def execute(
    sql: str | Path,
    params: Any = None,
    *,
    connection: str | None = None,
    warehouse: str | None = None,
    **variables: Any,
) -> None:
    """Run a statement whose result you don't need (``use``, ``create``…)."""
    text = _as_sql_text(sql, variables)
    con = connect(connection, warehouse)

    if _statement_count(text) > 1:
        for cursor in con.execute_string(text, remove_comments=False):
            cursor.close()
        return

    with con.cursor() as cur:
        cur.execute(text, params)


def session_info(
    connection: str | None = None,
    warehouse: str | None = None,
) -> pd.DataFrame:
    """Who am I, and what is this session pointed at?"""
    return q(
        """
        select current_account()   as account,
               current_user()      as user,
               current_role()      as role,
               current_warehouse() as warehouse,
               current_database()  as database,
               current_schema()    as schema
        """,
        connection=connection,
        warehouse=warehouse,
    )


def warehouses(connection: str | None = None) -> pd.DataFrame:
    """Warehouses the current role can see — use this to fill in
    ``SNOWFLAKE_WAREHOUSE`` in ``mise.toml``."""
    # No warehouse needed: SHOW runs on the metadata layer, not compute.
    return q("show warehouses", connection=connection, warehouse="")


def tables(
    schema: str = DEFAULT_SCHEMA,
    db: str = DEFAULT_DB,
    connection: str | None = None,
) -> pd.DataFrame:
    """Every table in a schema, with row count and description.

    The descriptions are dbt model docs: `dbt_project.yml` sets
    ``persist_docs`` for relations and columns, so dbt pushes them into
    Snowflake as native ``COMMENT``s on each build. That makes Snowflake
    itself the data dictionary — no separate catalog needed.
    """
    return q(
        f"""
        select table_name,
               row_count,
               coalesce(nullif(trim(comment), ''), '') as description
        from {_identifier(db, "database")}.information_schema.tables
        where table_schema = %s
          and table_type = 'BASE TABLE'
        order by table_name
        """,
        [_identifier(schema, "schema")],
        connection=connection,
    )


def dictionary(
    table: str,
    schema: str = DEFAULT_SCHEMA,
    db: str = DEFAULT_DB,
    connection: str | None = None,
    documented_only: bool = False,
) -> pd.DataFrame:
    """The column dictionary for one table: name, type, description.

        datalake.dictionary("fct_case_collection")

    Coverage is partial — roughly two thirds of NPL columns carry a
    description — so an empty ``description`` means the dbt model has no
    doc for it, not that the column is unimportant.
    """
    df = q(
        f"""
        select column_name,
               data_type,
               is_nullable,
               coalesce(nullif(trim(comment), ''), '') as description
        from {_identifier(db, "database")}.information_schema.columns
        where table_schema = %s
          and table_name = %s
        order by ordinal_position
        """,
        [_identifier(schema, "schema"), table.upper()],
        connection=connection,
    )
    if df.empty:
        raise ValueError(
            f"No table {db}.{schema}.{table}. "
            f"List what exists with datalake.tables(schema={schema!r})."
        )
    if documented_only:
        df = df[df["DESCRIPTION"] != ""]
    return df


def describe_column(
    column: str,
    schema: str = DEFAULT_SCHEMA,
    db: str = DEFAULT_DB,
    connection: str | None = None,
    exact: bool = True,
) -> pd.DataFrame:
    """Every table carrying a column of this name, with both descriptions.

    Answers "where does this column live, and what does it mean there?"::

        datalake.describe_column("reporting_system_sk")

    One row per table, so a surrogate key used by eight facts gives eight
    rows. That shape is the point: it is how you notice that the same
    column name has a different type, or a different description, in
    different tables.

    This is ``work/general_queries/data_dictionary.sql`` narrowed to one column. It
    joins ``information_schema.tables``, so you get the *table's*
    description next to the *column's* — which :func:`find_columns` does
    not return. Use :func:`find_columns` when you know the concept but not
    the column name; use this when you have the exact name.

    Matching is case-insensitive and exact by default; ``exact=False``
    matches any column whose name *contains* ``column``. As everywhere
    else here, an empty description means the dbt model has no doc for
    that object, not that it is unimportant.

    Only ``BASE TABLE`` objects are listed, matching :func:`tables` and
    the ``.sql`` file — views are not included.
    """
    needle = column.strip().lower()
    if not needle:
        raise ValueError("column must not be empty")

    predicate = (
        "lower(c.column_name) = %s" if exact else "lower(c.column_name) like %s"
    )
    df = q(
        f"""
        select c.table_name,
               c.ordinal_position as position,
               c.column_name,
               c.data_type,
               c.is_nullable,
               coalesce(nullif(trim(t.comment), ''), '') as table_description,
               coalesce(nullif(trim(c.comment), ''), '') as column_description
        from {_identifier(db, "database")}.information_schema.columns as c
        inner join {_identifier(db, "database")}.information_schema.tables as t
            on  t.table_schema = c.table_schema
            and t.table_name   = c.table_name
        where c.table_schema = %s
          and t.table_type = 'BASE TABLE'
          and {predicate}
        order by c.table_name, c.ordinal_position
        """,
        [
            _identifier(schema, "schema"),
            needle if exact else f"%{needle}%",
        ],
        connection=connection,
    )
    if df.empty:
        hint = (
            f"No column named {column!r} in {db}.{schema}."
            if exact
            else f"No column matching {column!r} in {db}.{schema}."
        )
        raise ValueError(
            f"{hint} Search names and descriptions with "
            f"datalake.find_columns({column!r}), or pass exact=False here."
        )
    return df


def find_columns(
    pattern: str,
    schema: str = DEFAULT_SCHEMA,
    db: str = DEFAULT_DB,
    connection: str | None = None,
) -> pd.DataFrame:
    """Find columns by name or description, across a whole schema.

    Use it when you know the concept but not where it lives::

        datalake.find_columns("gbv")
        datalake.find_columns("servicer")

    Matching is case-insensitive and covers both the column name and its
    description.
    """
    like = f"%{pattern.lower()}%"
    return q(
        f"""
        select table_name,
               column_name,
               data_type,
               coalesce(nullif(trim(comment), ''), '') as description
        from {_identifier(db, "database")}.information_schema.columns
        where table_schema = %s
          and (lower(column_name) like %s or lower(coalesce(comment, '')) like %s)
        order by table_name, ordinal_position
        """,
        [_identifier(schema, "schema"), like, like],
        connection=connection,
    )


def reset() -> None:
    """Close every cached connection (after an SSO token expires)."""
    for con in _CONNECTIONS.values():
        try:
            con.close()
        except Exception:
            pass
    _CONNECTIONS.clear()
