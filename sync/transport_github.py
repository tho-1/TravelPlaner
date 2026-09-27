"""GitHub transport for sync journals (Phase 2).

Moves journal files to/from the ``data-sync`` branch via the GitHub Contents
API using a fine-grained PAT (Contents read/write on tho-1/TravelPlaner).

Token sources (in order): ``GITHUB_TOKEN`` env var, then
``.streamlit/secrets.toml`` (``GITHUB_TOKEN = "..."``). That file is
gitignored and is never committed. The token is never logged.
"""

from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = "tho-1/TravelPlaner"
SYNC_BRANCH = "data-sync"
REMOTE_JOURNAL_DIR = "journals"
API_BASE = "https://api.github.com"


class TransportError(RuntimeError):
    pass


def get_token(token: str | None = None) -> str | None:
    if token and token.strip():
        return token.strip()
    env = os.environ.get("GITHUB_TOKEN")
    if env and env.strip():
        return env.strip()
    secrets_path = ROOT / ".streamlit" / "secrets.toml"
    try:
        text = secrets_path.read_text(encoding="utf-8")
    except OSError:
        return None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("GITHUB_TOKEN"):
            _, _, value = stripped.partition("=")
            value = value.strip().strip('"').strip("'")
            if value:
                return value
    return None


def _api(
    method: str,
    api_path: str,
    token: str,
    payload: dict | None = None,
) -> tuple[int, object]:
    url = API_BASE + api_path
    data = None
    headers = {
        "Authorization": "Bearer REDACTED",
        "Accept": "application/vnd.github+json",
        "User-Agent": "travel-planner-sync",
    }
    # Build the real request separately so the token never appears in logs.
    req_headers = dict(headers)
    req_headers["Authorization"] = "Bearer " + token
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        req_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8") or "null"
            return resp.status, json.loads(body)
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8")[:500]
        except Exception:
            detail = ""
        raise TransportError(f"GitHub API {method} {api_path}: HTTP {exc.code} {detail}")


def ensure_branch(token: str | None = None) -> str:
    """Ensure the data-sync branch exists. Returns the branch name.

    Uses only the Contents API (PUT creates the branch), so a fine-grained
    PAT with Contents read/write suffices — no git/refs permission needed.
    """
    tok = get_token(token)
    if not tok:
        raise TransportError("missing GITHUB_TOKEN")
    try:
        _, _ = _api("GET", f"/repos/{REPO}/branches/{SYNC_BRANCH}", tok)
        return SYNC_BRANCH
    except TransportError as exc:
        if "HTTP 404" not in str(exc):
            raise
    body = base64.b64encode(b"sync journals\n").decode("ascii")
    _api(
        "PUT",
        f"/repos/{REPO}/contents/{REMOTE_JOURNAL_DIR}/.keep",
        tok,
        {"message": "sync: init data-sync branch", "content": body, "branch": SYNC_BRANCH},
    )
    return SYNC_BRANCH


def list_remote_journals(token: str | None = None) -> list[str]:
    tok = get_token(token)
    if not tok:
        raise TransportError("missing GITHUB_TOKEN")
    try:
        _, data = _api(
            "GET",
            f"/repos/{REPO}/contents/{REMOTE_JOURNAL_DIR}?ref={SYNC_BRANCH}",
            tok,
        )
    except TransportError as exc:
        if "HTTP 404" in str(exc):
            return []
        raise
    if isinstance(data, dict):
        return []
    return [item["name"] for item in data if item.get("type") == "file"]


def download_file(remote_name: str, token: str | None = None) -> tuple[str, str]:
    """Download journals/<name> from data-sync. Returns (text, sha)."""
    tok = get_token(token)
    if not tok:
        raise TransportError("missing GITHUB_TOKEN")
    _, data = _api(
        "GET",
        f"/repos/{REPO}/contents/{REMOTE_JOURNAL_DIR}/{remote_name}?ref={SYNC_BRANCH}",
        tok,
    )
    content = base64.b64decode(data["content"]).decode("utf-8")
    return content, data["sha"]


def upload_file(
    remote_name: str,
    text: str,
    message: str,
    token: str | None = None,
    sha: str | None = None,
) -> None:
    tok = get_token(token)
    if not tok:
        raise TransportError("missing GITHUB_TOKEN")
    body = base64.b64encode(text.encode("utf-8")).decode("ascii")
    payload: dict = {
        "message": message,
        "content": body,
        "branch": SYNC_BRANCH,
    }
    if sha:
        payload["sha"] = sha
    _api(
        "PUT",
        f"/repos/{REPO}/contents/{REMOTE_JOURNAL_DIR}/{remote_name}",
        tok,
        payload,
    )


def push_journals(
    journal_dir: Path | str | None = None,
    token: str | None = None,
    dry_run: bool = False,
) -> list[str]:
    """Upload local *.jsonl journals to data-sync. Returns uploaded names."""
    from sync import journal as _journal

    jdir = Path(journal_dir) if journal_dir else _journal.DEFAULT_JOURNAL_DIR
    local = sorted(p for p in jdir.glob("*.jsonl") if p.is_file())
    if dry_run:
        return [p.name for p in local]
    ensure_branch(token)
    try:
        remote = set(list_remote_journals(token))
    except TransportError:
        remote = set()
    uploaded: list[str] = []
    for path in local:
        name = path.name
        text = path.read_text(encoding="utf-8")
        sha = None
        if name in remote:
            try:
                _, sha = download_file(name, token)
            except TransportError:
                sha = None
        upload_file(name, text, f"sync journals: {name}", token, sha)
        uploaded.append(name)
    return uploaded
