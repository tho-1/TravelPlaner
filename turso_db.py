"""Turso (libSQL) client for the Travel Planner main database.

This is the data foundation for the native rebuild (see
``NATIVE_HTML_PLAN.md``). It talks to the ``travel-tz123`` Turso
database over the documented SQL-over-HTTP pipeline API -- the same
approach ``benefits_turso.py`` uses for the airline-benefits
database, but with **write** support, because this database holds
the app's own data (destinations, trips, tabs).

Why HTTP and not the ``pyturso``/``turso.sync`` native client:
the native client is a Rust extension that pip builds from source,
which trips build isolation (``build-script-build.exe``) and the
user's antivirus. The HTTP pipeline API needs only ``requests``
(already a dependency) and is trivial to fake in tests. The
**offline-first local sync** (push/pull) is the *Flutter* app's
job (via the Dart ``@tursodatabase/sync`` SDK); the Python/
Streamlit side is always online (PC and Streamlit Cloud), so HTTP
is the right transport there.

Credentials (never committed) come from, in order:
    TRAVEL_PLANNER_TURSO_URL / TRAVEL_PLANNER_TURSO_TOKEN  (env)
    .streamlit/secrets.toml                                  (file)

Semantics that must not drift (mirrors benefits_turso.py):
* An error arrives as ``{"type": "error"}`` *inside* a 200 response,
  so the HTTP status alone does not say whether the query worked.
* Always send ``close`` last, or the server holds the connection
  until it times out.
* The token is read from the environment/secrets and is never
  logged, printed, or stored in the repository.
"""

from __future__ import annotations

import hashlib
import os
import re
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent
SECRETS_PATH = ROOT / ".streamlit" / "secrets.toml"

ENV_URL = "TRAVEL_PLANNER_TURSO_URL"
ENV_TOKEN = "TRAVEL_PLANNER_TURSO_TOKEN"

HTTP_TIMEOUT_S = 15.0


def _read_secret(name: str) -> str:
    """Read a secret from the environment, then .streamlit/secrets.toml.

    Streamlit Cloud injects secrets.toml into the environment, so the
    env lookup covers Cloud; the file lookup covers local runs.
    """
    value = os.environ.get(name, "").strip()
    if value:
        return value
    try:
        for line in SECRETS_PATH.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith(name):
                _, _, value = stripped.partition("=")
                return value.strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


def config_from_env() -> dict:
    return {"url": _read_secret(ENV_URL), "token": _read_secret(ENV_TOKEN)}


def _https_host(url: str) -> str:
    """``libsql://host`` -> ``https://host`` (the HTTP API host)."""
    host = url.strip()
    host = re.sub(r"^libsql://", "https://", host)
    host = re.sub(r"^http://", "https://", host)
    return host.rstrip("/")


def _endpoint(url: str) -> str:
    host = _https_host(url)
    return host if host.endswith("/v2/pipeline") else host + "/v2/pipeline"


def token_fingerprint(token: str) -> str:
    """A 12-char SHA-256 fingerprint of the token, for cache keys and
    logs -- never the token itself."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:12] if token else ""


class TursoError(RuntimeError):
    """A Turso query failed. Carries a human-readable message only."""


def _cell_value(cell: object) -> object:
    """Normalise one pipeline-API cell to a plain Python value.

    The pipeline API returns each cell as
    ``{"type": "text"|"integer"|"real"|"null"|"blob", "value": ...}``.
    Without this, every read would hand the app a dict of
    ``{type, value}`` objects instead of strings/ints.
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


def _parse_response(body: object) -> tuple[list[dict], list[str]]:
    """Turn a pipeline response into per-statement (cols, rows).

    Returns ``(results, problems)``. An ``error`` result is a problem,
    not an exception, so a caller can fall through or report it.
    """
    results: list[dict] = []
    problems: list[str] = []
    for item in (body.get("results") or []) if isinstance(body, dict) else []:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "error":
            message = (item.get("error") or {}).get("message", "unknown error")
            problems.append(str(message)[:200])
            continue
        result = (item.get("response") or {}).get("result") or {}
        cols = [c.get("name") for c in (result.get("cols") or [])]
        rows = [[_cell_value(cell) for cell in row]
                for row in (result.get("rows") or [])]
        results.append({"cols": cols, "rows": rows})
    return results, problems


def run_pipeline(sql_statements: list[str],
                 url: str | None = None,
                 token: str | None = None,
                 timeout: float = HTTP_TIMEOUT_S
                 ) -> tuple[list[dict], list[str]]:
    """Run one or more SQL statements in a single pipeline request.

    The statements execute in order in one request. Returns
    ``(results, problems)`` where each result is
    ``{"cols": [...], "rows": [[...], ...]}``. Never raises on a
    query error -- it is reported in ``problems``.
    """
    url = url if url is not None else _read_secret(ENV_URL)
    token = token if token is not None else _read_secret(ENV_TOKEN)
    if not url:
        return [], [f"{ENV_URL} is not set"]
    if not token:
        return [], [f"{ENV_TOKEN} is not set"]

    payload = {"requests": [{"type": "execute", "stmt": {"sql": sql}}
                            for sql in sql_statements]}
    payload["requests"].append({"type": "close"})
    try:
        response = requests.post(
            _endpoint(url),
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {token}"},
            json=payload,
            timeout=timeout,
        )
    except Exception as exc:                       # network failure
        return [], [f"could not reach Turso: {type(exc).__name__}"]

    if response.status_code == 401:
        return [], ["Turso rejected the token (401)"]
    if response.status_code == 403:
        return [], ["Turso denied access (403) -- the token may be "
                    "read-only for this database"]
    if response.status_code >= 500:
        return [], [f"Turso is unavailable ({response.status_code})"]
    if response.status_code != 200:
        return [], [f"Turso returned {response.status_code}: "
                    f"{response.text[:120]}"]
    try:
        body = response.json()
    except Exception:
        return [], ["Turso returned a non-JSON response"]
    return _parse_response(body)


def execute(sql: str, **kwargs) -> list[str]:
    """Run a write/DDL statement. Returns a list of problems (empty = ok)."""
    _, problems = run_pipeline([sql], **kwargs)
    return problems


def query(sql: str, **kwargs) -> tuple[list[dict], list[str]]:
    """Run a read statement. Returns ``(rows_as_dicts, problems)``."""
    results, problems = run_pipeline([sql], **kwargs)
    if problems or not results:
        return [], problems or ["no result"]
    first = results[0]
    cols = first["cols"]
    return [dict(zip(cols, row)) for row in first["rows"]], []


def is_configured() -> bool:
    """True when both the URL and token are available."""
    config = config_from_env()
    return bool(config["url"]) and bool(config["token"])


# ── schema ───────────────────────────────────────────────────────────

#: The Travel Planner schema. ``destinations`` keeps a typed core (the
#: fields the app filters/sorts/searches on) plus a lossless ``data``
#: JSON tail holding every workbook column as an ordered array of
#: [column, value] pairs -- the workbook has 145 columns including
#: duplicate names and object-typed cells, so a flat typed table would
#: be brittle and would drop data. Trips/variants/stops/legs mirror
#: ``itinerary/models.py``; ``legs`` is positional (legs[i] sits
#: between stops[i] and stops[i+1]).
SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS destinations (
  destination TEXT PRIMARY KEY,
  continent TEXT,
  country TEXT,
  visited INTEGER,
  favourite INTEGER,
  prio TEXT,
  safety_rating REAL,
  avg_cost_day REAL,
  flight_time_fra REAL,
  to_be_researched INTEGER,
  malaria_risk INTEGER,
  data_status TEXT,
  comment TEXT,
  data JSON,
  updated_at TEXT
);
CREATE TABLE IF NOT EXISTS trips (
  id TEXT PRIMARY KEY,
  name TEXT,
  created TEXT,
  active_variant_id TEXT,
  updated_at TEXT
);
CREATE TABLE IF NOT EXISTS variants (
  id TEXT PRIMARY KEY,
  trip_id TEXT,
  name TEXT,
  notes TEXT,
  rating INTEGER,
  months JSON,
  comment TEXT,
  updated_at TEXT
);
CREATE TABLE IF NOT EXISTS stops (
  id TEXT PRIMARY KEY,
  variant_id TEXT,
  position INTEGER,
  kind TEXT,
  name TEXT,
  country TEXT,
  lat REAL,
  lon REAL,
  role TEXT,
  arrival_date TEXT,
  departure_date TEXT,
  arrival_time TEXT,
  departure_time TEXT,
  nights INTEGER,
  notes TEXT,
  updated_at TEXT
);
CREATE TABLE IF NOT EXISTS legs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  variant_id TEXT,
  position INTEGER,
  mode TEXT,
  note TEXT,
  updated_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_legs_variant_position
  ON legs(variant_id, position);
CREATE TABLE IF NOT EXISTS open_tabs (
  destination TEXT PRIMARY KEY,
  updated_at TEXT
);
"""


def ensure_schema(**kwargs) -> list[str]:
    """Create the tables if they do not exist. Returns problems."""
    statements = [s.strip() for s in SCHEMA_SQL.strip().split(";") if s.strip()]
    _, problems = run_pipeline(statements, **kwargs)
    return problems


if __name__ == "__main__":  # pragma: no cover - manual helper
    print("configured:", is_configured())
    if is_configured():
        config = config_from_env()
        print("host:", _https_host(config["url"]))
        print("token fingerprint:", token_fingerprint(config["token"]))
        problems = ensure_schema()
        print("ensure_schema problems:", problems or "none")
        rows, problems = query("SELECT name FROM sqlite_master "
                               "WHERE type='table' ORDER BY name")
        print("tables:", [r["name"] for r in rows] if not problems else problems)
