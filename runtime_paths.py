"""Writable runtime locations for app state.

Everything the app writes at runtime (trips.json, its backups, the UI state,
the open-tab list, the sync journals and — on Streamlit Cloud — the editable
workbook copy) used to live next to ``app.py``. That directory is the mounted
source tree, which on Streamlit Cloud is **read-only**: every write either
fails or silently disappears on the next redeploy.

This module picks the first usable location, in order:

1. ``$TRAVEL_PLANNER_DATA_DIR`` (explicit override),
2. the repository directory, when it is actually writable (local dev — this
   keeps the existing layout and the existing git-ignored files working),
3. a per-user directory (``%LOCALAPPDATA%`` / ``~/.local/share``).

Nothing here raises: callers ask :func:`describe` / :func:`is_writable` when
they want to tell the user where their data lives.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent

ENV_DATA_DIR = "TRAVEL_PLANNER_DATA_DIR"

FALLBACK_DIRNAME = "travel-planner"


def _fallback_root() -> Path:
    """A writable per-user directory for the current platform."""
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
        if base:
            return Path(base) / FALLBACK_DIRNAME
        return Path.home() / "AppData" / "Local" / FALLBACK_DIRNAME
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg) / FALLBACK_DIRNAME
    return Path.home() / ".local" / "share" / FALLBACK_DIRNAME


def _is_writable_dir(path: Path) -> bool:
    """True when a file can actually be created in ``path``."""
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    probe = path / f".write-probe-{os.getpid()}"
    try:
        probe.write_bytes(b"ok")
    except OSError:
        return False
    finally:
        try:
            probe.unlink()
        except OSError:
            pass
    return True


def _resolve_data_root() -> tuple[Path, str]:
    """Return ``(path, reason)`` for the directory runtime state should use."""
    override = os.environ.get(ENV_DATA_DIR, "").strip()
    if override:
        candidate = Path(override).expanduser()
        try:
            candidate.mkdir(parents=True, exist_ok=True)
        except OSError:
            pass
        if _is_writable_dir(candidate):
            return candidate, f"{ENV_DATA_DIR}={candidate}"
        return _fallback_root(), f"{ENV_DATA_DIR}={candidate} is not writable"

    if _is_writable_dir(REPO_ROOT):
        return REPO_ROOT, "repository directory"

    fallback = _fallback_root()
    if _is_writable_dir(fallback):
        return fallback, "repository is read-only — using the user data directory"
    # Last resort: a temp directory. Data survives only as long as the process.
    temp_root = Path(tempfile.gettempdir()) / FALLBACK_DIRNAME
    try:
        temp_root.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return temp_root, "repository is read-only — using a temporary directory"


DATA_ROOT, DATA_ROOT_REASON = _resolve_data_root()

#: True when runtime state is written next to the sources (the local setup).
USES_REPO_ROOT = DATA_ROOT.resolve() == REPO_ROOT.resolve()


def is_writable() -> bool:
    """Whether runtime state can currently be persisted."""
    return _is_writable_dir(DATA_ROOT)


def state_path(*parts: str) -> Path:
    """Absolute path for a runtime-state file (parents created on demand)."""
    target = DATA_ROOT.joinpath(*parts)
    return target


def writable_dir(*parts: str) -> Path | None:
    """Create and return a writable directory, or ``None`` when impossible.

    Cache/gallery code calls this instead of ``Path.mkdir`` so a read-only
    filesystem degrades to "no cache" instead of a crash.
    """
    target = DATA_ROOT.joinpath(*parts)
    try:
        target.mkdir(parents=True, exist_ok=True)
    except OSError:
        return None
    return target


def writable_dir_at(base: Path, *parts: str) -> Path | None:
    """Like :func:`writable_dir` but anchored at ``base`` (may be read-only)."""
    target = base.joinpath(*parts)
    try:
        target.mkdir(parents=True, exist_ok=True)
    except OSError:
        return None
    if not os.access(target, os.W_OK):
        return None
    return target


def describe() -> str:
    """One-line human summary for the sidebar / diagnostics."""
    scope = "repo" if USES_REPO_ROOT else "external"
    return (f"data dir: {DATA_ROOT} ({scope}; {DATA_ROOT_REASON}; "
            f"writable={is_writable()}; python={sys.version.split()[0]})")
