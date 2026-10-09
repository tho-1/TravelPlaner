"""Airline benefits, read from a Turso (libSQL) database.

Decision 2026-10-07: the benefits live in a Turso database, which is the source
of truth. ``airlines_benefits.xlsx`` (in another project) is no longer the
primary source; see ``TURSO_PLAN.md`` for the access contract and the fallback
ladder.

Access contract
----------------
Remote  ``https://<db>.turso.io`` + a read-only bearer token, over the
        documented SQL-over-HTTP pipeline API::

            POST <host>/v2/pipeline
            Authorization: Bearer <token>
            {"requests": [{"type": "execute", "stmt": {...}}, {"type": "close"}]}

        An error arrives as ``{"type": "error"}`` *inside* a 200 response, so the
        HTTP status alone does not say whether the query worked. Always send
        ``close`` last, or the server holds the connection until it times out.
Local   ``flightroutes.db`` in the other project, opened read-only via
        ``sqlite3`` (stdlib). Both stores hold the same rows; the local file is
        what makes this testable without any secret.

Table ``airlines(iata, name, discount_eligible, business_class,
confirmed_booking, comments, updated_at)``; the three benefit columns hold
lowercase ``yes`` / ``no`` / ``unknown``.

Semantics that must not drift
-----------------------------
* **Any ``yes`` qualifies** — the user's rule is "at least one of them".
* ``no``, ``unknown``, ``NULL`` and empty do **not** qualify. An unverified
  airline is not one you can book on, and treating ``unknown`` as a yes would
  silently widen the finder's result list.
* **An empty read is a failure, not "nobody qualifies".** An empty flag map would
  remove every destination from the weekend finder, so it is reported as a
  problem and the resolver falls through to the next source.
* The token is read from the environment and never logged, printed, or stored in
  the repository.
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
from pathlib import Path

#: Column -> the aliases accepted, normalised (lower, ``_``/space removed).
CODE_COLUMNS = ("iata", "iata_code", "code", "airline_code")
NAME_COLUMNS = ("name", "airline", "airline_name", "carrier")
BENEFIT_COLUMNS = ("discount_eligible", "business_class", "confirmed_booking")

#: Values that mean "this airline has the benefit". Everything else does not.
YES_VALUES = frozenset({"yes", "y", "true", "1", "x"})

#: Where the remote lives. Overridable for a different database or a replica.
DEFAULT_REMOTE = "https://flightconnections-tz123.aws-eu-north-1.turso.io"
DEFAULT_TABLE = "airlines"

ENV_URL = "TURSO_DATABASE_URL"
ENV_TOKEN = "TURSO_AUTH_TOKEN"
ENV_TABLE = "TURSO_AIRLINE_TABLE"
ENV_LOCAL_DB = "TRAVEL_PLANNER_FLIGHTROUTES_DB"

#: Seconds. The data changes when the user edits it, which is rare, so this is
#: generous: a page rerun should never touch the network.
CACHE_TTL_S = 3600.0
HTTP_TIMEOUT_S = 5.0


def is_yes(value: object) -> bool:
    """True only for an explicit yes. ``unknown`` is not a yes."""
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value == 1
    return str(value).strip().lower() in YES_VALUES


def _cell_value(cell: object) -> object:
    """Normalise one pipeline-API cell to a plain Python value.

    The pipeline API returns each cell as
    ``{"type": "text"|"integer"|"real"|"null"|"blob", "value": ...}``.
    Without this, every read would hand the caller a dict of
    ``{type, value}`` objects instead of strings/ints, and no
    benefit column would ever compare equal to ``yes`` -- the
    remote source would silently read as "nobody qualifies".
    """
    if cell is None:
        return None
    if isinstance(cell, dict):
        kind = cell.get("type")
        value = cell.get("value")
        if kind == "null" or value is None:
            return None
        if kind == "integer":
            try:
                return int(value)
            except (TypeError, ValueError):
                return value
        if kind == "real":
            try:
                return float(value)
            except (TypeError, ValueError):
                return value
        if kind == "blob":
            import base64
            return base64.b64decode(value) if isinstance(value, str) else value
        return value
    return cell


def _normalise_header(name: object) -> str:
    return "".join(str(name or "").lower().split()).replace("_", "").replace(" ", "")


def pick_columns(fieldnames) -> dict[str, int]:
    """Map canonical column name -> column index, tolerating naming drift.

    ``discount eligible``, ``discount_eligible`` and ``DiscountEligible`` all
    resolve to the *same* key, ``discount_eligible``, so a cosmetic rename
    upstream does not break us and the UI can always name the benefit that
    qualified an airline in the project's own spelling.

    Key order follows :data:`BENEFIT_COLUMNS`, not the file's column order, so
    ``which`` is deterministic regardless of how the source is laid out.
    """
    normalised = {_normalise_header(name): index
                  for index, name in enumerate(fieldnames or [])}
    mapping: dict[str, int] = {}
    for canonical in CODE_COLUMNS + NAME_COLUMNS + BENEFIT_COLUMNS:
        index = normalised.get(_normalise_header(canonical))
        if index is not None:
            mapping.setdefault(canonical, index)
    return mapping


def rows_to_records(rows, fieldnames) -> tuple[list[dict], list[str]]:
    """Turn a result set into one dict per airline, plus any problems.

    Returns ``([], [problem])`` when the columns are not recognisable, so a
    schema change is reported rather than silently read as "no benefits".
    """
    mapping = pick_columns(fieldnames)
    code_at = next((mapping[column] for column in CODE_COLUMNS
                    if column in mapping), None)
    benefit_at = [(column, mapping[column]) for column in BENEFIT_COLUMNS
                  if column in mapping]
    if code_at is None or not benefit_at:
        found = ", ".join(str(name) for name in fieldnames or [])
        return [], [f"expected a code column ({'/'.join(CODE_COLUMNS)}) and at "
                    f"least one benefit column ({'/'.join(BENEFIT_COLUMNS)}); "
                    f"found: {found}"]

    name_at = next((mapping[column] for column in NAME_COLUMNS
                    if column in mapping), None)
    out: list[dict] = []
    seen: set[str] = set()
    for raw in rows or []:
        values = list(raw)
        if not values or code_at >= len(values):
            continue
        code = str(values[code_at] or "").strip().upper()
        if not code or code in seen:
            continue
        seen.add(code)
        name = ""
        if name_at is not None and name_at < len(values):
            name = str(values[name_at] or "").strip()
        which = [column for column, index in benefit_at
                 if index < len(values) and is_yes(values[index])]
        out.append({"code": code, "name": name or code,
                    "benefits": bool(which), "which": which})
    return out, []


def records_to_flags(records) -> dict[str, bool]:
    """``{key: has benefits}`` keyed by IATA code *and* canonical name.

    Boards say ``LH``, exports say ``Lufthansa``; registering both means the
    lookup works whichever spelling arrives. Delegated to
    :func:`airline_benefits.records_to_flags` so the Excel and Turso sources
    cannot drift apart on this rule.
    """
    import airline_benefits

    return airline_benefits.records_to_flags(records)


# ── local SQLite (stdlib; also how the tests run) ───────────────────────────

def fetch_local(db_path: Path | str, table: str = DEFAULT_TABLE
                ) -> tuple[list[dict], list[str]]:
    """Read the table from a local SQLite file, opened read-only."""
    path = Path(db_path)
    if not path.exists():
        return [], [f"{path} does not exist"]
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except Exception as exc:
        return [], [f"could not open {path.name}: {exc}"]
    try:
        cursor = connection.execute(f"SELECT * FROM {table}")  # noqa: S608
        fieldnames = [description[0] for description in cursor.description]
        return rows_to_records(cursor.fetchall(), fieldnames)
    except sqlite3.Error as exc:
        return [], [f"query failed on {path.name}: {exc}"]
    finally:
        connection.close()


# ── remote Turso over SQL-over-HTTP ──────────────────────────────────────────

def config_from_env() -> dict:
    return {
        "url": (os.environ.get(ENV_URL) or DEFAULT_REMOTE).strip(),
        "token": (os.environ.get(ENV_TOKEN) or "").strip(),
        "table": (os.environ.get(ENV_TABLE) or DEFAULT_TABLE).strip(),
    }


def fetch_remote(url: str, token: str, table: str = DEFAULT_TABLE,
                 timeout: float = HTTP_TIMEOUT_S) -> tuple[list[dict], list[str]]:
    """Run one SELECT against the remote database and parse the result.

    Returns ``(records, problems)``. Never raises: every failure mode — no
    token, rejected token, timeout, HTTP error, an ``error`` result inside a 200,
    an empty table — comes back as a problem string so the caller can fall
    through to the next source.
    """
    if not token:
        return [], [f"{ENV_TOKEN} is not set — cannot read the Turso database"]
    if not table.isidentifier():
        return [], [f"'{table}' is not a usable table name"]

    host = url.rstrip("/")
    endpoint = host if host.endswith("/v2/pipeline") else host + "/v2/pipeline"
    try:
        import requests
    except ImportError:                                  # pragma: no cover
        return [], ["the 'requests' package is required to read Turso"]

    # `table` is configuration (an env var or a default), not user input, and is
    # restricted to an identifier above so it cannot inject SQL.
    sql = f"SELECT * FROM {table}"
    payload = {"requests": [
        {"type": "execute", "stmt": {"sql": sql}},
        {"type": "close"},
    ]}
    try:
        response = requests.post(
            endpoint,
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {token}"},
            json=payload,
            timeout=timeout,
        )
    except Exception as exc:
        return [], [f"could not reach {host}: {type(exc).__name__}"]

    if response.status_code == 401:
        return [], [f"Turso rejected the token (401) — check {ENV_TOKEN}"]
    if response.status_code == 403:
        return [], ["Turso denied access (403) — the token may not be read-only "
                    "for this database, or lacks read permission"]
    if response.status_code >= 500:
        return [], [f"Turso is unavailable ({response.status_code}) — retry "
                    f"later"]
    if response.status_code != 200:
        return [], [f"Turso returned {response.status_code}: "
                    f"{response.text[:120]}"]

    try:
        body = response.json()
    except Exception:
        return [], ["Turso returned a non-JSON response"]

    results = body.get("results") or []
    if not results:
        return [], ["Turso returned no results"]
    first = results[0]
    if first.get("type") == "error":
        message = (first.get("error") or {}).get("message", "unknown error")
        return [], [f"query error: {str(message)[:160]}"]
    result = ((first.get("response") or {}).get("result")) or {}
    columns = [column.get("name") for column in (result.get("cols") or [])]
    rows = [[_cell_value(cell) for cell in row]
            for row in (result.get("rows") or [])]
    if not rows:
        return [], [f"the table '{table}' is empty — treated as a failure so the "
                    f"airline list cannot silently become empty"]
    return rows_to_records(rows, columns)


# ── one entry point, with the local file as an offline fallback ──────────────

_CACHE: tuple[str, float, list[dict], list[str]] | None = None


def clear_cache() -> None:
    global _CACHE
    _CACHE = None


def fetch_benefit_records(use_cache: bool = True
                          ) -> tuple[list[dict], list[str]]:
    """Read the airlines table from Turso, or the local file, or explain why not.

    Order: remote database, then the local ``flightroutes.db`` when
    ``TRAVEL_PLANER_FLIGHTROUTES_DB`` points at one. The local file exists so the
    feature still works offline and so the tests exercise the real query.
    """
    global _CACHE
    import time

    config = config_from_env()
    # Hashed, not stored: the key has to distinguish two tokens (a different
    # token may point at a different database) but the token itself must never
    # sit in a string that could be logged or shown in the UI.
    token_fingerprint = hashlib.sha256(
        config["token"].encode("utf-8")).hexdigest()[:12] if config["token"] else ""
    cache_key = (f"{config['url']}|{config['table']}|{token_fingerprint}|"
                 f"{os.environ.get(ENV_LOCAL_DB, '').strip()}")
    if use_cache and _CACHE and _CACHE[0] == cache_key \
            and time.monotonic() - _CACHE[1] < CACHE_TTL_S:
        return _CACHE[2], _CACHE[3]

    problems: list[str] = []
    records: list[dict] = []
    if config["token"]:
        records, problems = fetch_remote(config["url"], config["token"],
                                         config["table"])
    else:
        problems = [f"{ENV_TOKEN} is not set"]

    if not records:
        local = os.environ.get(ENV_LOCAL_DB, "").strip()
        if local:
            local_records, local_problems = fetch_local(local, config["table"])
            if local_records:
                records = local_records
                problems = [f"remote unavailable ({'; '.join(problems)}); "
                            f"using the local {Path(local).name}"]
            else:
                problems.extend(local_problems)

    if use_cache:
        _CACHE = (cache_key, time.monotonic(), records, problems)
    return records, problems


def fetch_benefit_flags(use_cache: bool = True) -> tuple[dict[str, bool],
                                                         list[str]]:
    records, problems = fetch_benefit_records(use_cache=use_cache)
    return records_to_flags(records), problems


def benefit_names(use_cache: bool = True) -> list[str]:
    records, _ = fetch_benefit_records(use_cache=use_cache)
    return [f'{r["code"]} {r["name"]}' for r in sorted(
        records, key=lambda item: item["code"]) if r["benefits"]]


def summary(use_cache: bool = True) -> str:
    """One line naming the source and the count, for the results header."""
    records, problems = fetch_benefit_records(use_cache=use_cache)
    if not records:
        return ("Could not read the airline benefits database"
                + (f": {'; '.join(problems[:2])}" if problems else "")
                + ". Falling back to the workbook.")
    qualified = sum(1 for record in records if record["benefits"])
    return (f"{qualified} of {len(records)} airlines have benefits "
            f"(Turso database); 'unknown' counts as no.")


if __name__ == "__main__":  # pragma: no cover - manual helper
    print(summary())
    records, issues = fetch_benefit_records()
    for issue in issues:
        print(f"  [note] {issue}")
    for name in benefit_names():
        print(f"  ✓ {name}")