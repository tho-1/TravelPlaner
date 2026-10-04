"""One-button sync orchestration (Phase 2).

Pull remote journals -> plan merge -> apply winners -> push local journals.
Conflicts are saved for UI review, never silently resolved. Offline or auth
failures return ok=False with queued changes left intact.
"""

from __future__ import annotations

import json
from pathlib import Path


def _parse_jsonl(text: str) -> list[dict]:
    entries = []
    for line in text.splitlines():
        if line.strip():
            try:
                entries.append(json.loads(line))
            except Exception:
                continue
    return entries


def sync_now(
    dry_run: bool = False,
    journal_dir: Path | str | None = None,
) -> dict:
    from sync import journal as _journal
    from sync import merge as _merge
    from sync import transport_github as _transport

    jdir = Path(journal_dir) if journal_dir else _journal.DEFAULT_JOURNAL_DIR
    try:
        _transport.ensure_branch()
        remote_names = _transport.list_remote_journals()
    except Exception as exc:
        pending = len(_journal.read_entries(jdir))
        return {"ok": False, "error": str(exc)[:200], "pending": pending}
    remote_entries: list[dict] = []
    for name in remote_names:
        try:
            text, _ = _transport.download_file(name)
            remote_entries.extend(_parse_jsonl(text))
        except Exception:
            continue
    local_entries = _journal.read_entries(jdir)
    last = _merge.load_last_applied(jdir)
    plan = _merge.plan_merge(local_entries, remote_entries, last)
    _merge.save_conflicts(plan["conflicts"], jdir)
    if dry_run:
        return {
            "ok": True,
            "would_apply": len(plan["apply"]),
            "conflicts": len(plan["conflicts"]),
            "remote_files": len(remote_names),
        }
    applied_entries: list[dict] = []
    if plan["apply"]:
        summary = _merge.apply_entries(plan["apply"])
        applied_entries = list(plan["apply"])
        # Record remote-origin winners in THIS device's journal so the next
        # push converges. They go into our own file (append_entry uses the
        # local device id) and the remote copy is unioned on upload, so no
        # device can truncate another device's history.
        local_device = _journal.get_device_id()
        foreign = [dict(e) for e in plan["apply"] if e.get("device") != local_device]
        if foreign:
            try:
                _journal.append_entries(foreign, jdir)
            except Exception:
                pass
        _merge.save_last_applied(applied_entries, jdir)
    else:
        summary = {"applied": 0, "snapshots": [], "skipped": []}
        if not plan["conflicts"]:
            _merge.save_last_applied([], jdir)
    try:
        uploaded = _transport.push_journals(jdir)
    except Exception as exc:
        return {
            "ok": True,
            "applied": summary.get("applied", 0),
            "skipped": summary.get("skipped", []),
            "conflicts": len(plan["conflicts"]),
            "snapshots": summary.get("snapshots", []),
            "push_error": str(exc)[:200],
        }
    return {
        "ok": True,
        "applied": summary.get("applied", 0),
        "skipped": summary.get("skipped", []),
        "conflicts": len(plan["conflicts"]),
        "snapshots": summary.get("snapshots", []),
        "uploaded": len(uploaded),
        "remote_files": len(remote_names),
    }
