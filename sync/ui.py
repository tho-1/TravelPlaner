"""Sidebar Sync UI (Phase 2).

⟳ Sync button with last-sync caption plus a conflicts review list with
per-key choice and keep-all-local / keep-all-cloud bulk actions.
"""

from __future__ import annotations


def _short_ts(ts: str) -> str:
    try:
        return str(ts)[:16].replace("T", " ")
    except Exception:
        return str(ts)


def render_sync_sidebar() -> None:
    import json

    import streamlit as st

    from sync import journal as _journal
    from sync import merge as _merge
    from sync import sync as _sync

    st.markdown("---")
    st.markdown("**Device sync**")
    pending = len(_journal.read_entries())
    conflicts = _merge.load_conflicts()
    last_path = _journal.DEFAULT_JOURNAL_DIR / "last_sync.json"
    caption = f"{pending} queued change{'s' if pending != 1 else ''}"
    try:
        last_sync_utc = json.loads(last_path.read_text(encoding="utf-8")).get(
            "last_sync_utc", ""
        )
        if last_sync_utc:
            caption += f" · last sync {_short_ts(last_sync_utc)}"
    except Exception:
        pass
    if conflicts:
        caption += f" · ⚠️ {len(conflicts)} conflict{'s' if len(conflicts) != 1 else ''}"
    st.caption(caption)
    if st.button("⟳ Sync", key="sync_now", width="stretch"):
        with st.spinner("Syncing…"):
            result = _sync.sync_now()
        if not result.get("ok"):
            st.warning(
                f"Sync unavailable ({result.get('error', 'offline')}). "
                "Changes stay queued locally."
            )
        else:
            bits = [f"applied {result.get('applied', 0)}"]
            if result.get("conflicts"):
                bits.append(f"⚠️ {result['conflicts']} conflicts")
            if result.get("uploaded"):
                bits.append(f"pushed {result['uploaded']}")
            if result.get("push_error"):
                bits.append("push failed (queued)")
            st.session_state["sync_result"] = ", ".join(bits)
            if result.get("skipped"):
                st.session_state["sync_skipped"] = result["skipped"]
            conflicts = _merge.load_conflicts()
            st.rerun()
    if st.session_state.get("sync_result"):
        st.toast(f"Sync done: {st.session_state.pop('sync_result')}", icon="✅")
    if st.session_state.get("sync_skipped"):
        skipped = st.session_state.pop("sync_skipped")
        with st.expander(f"⚠️ {len(skipped)} change(s) could not be applied",
                         expanded=True):
            st.caption(
                "These journal entries had no target on this device — most "
                "often a destination that was added on the other device (or "
                "renamed here). Refresh the workbook from the other device, or "
                "add the destination here, then sync again."
            )
            for line in skipped[:25]:
                st.markdown(f"- {line}")
            if len(skipped) > 25:
                st.caption(f"… and {len(skipped) - 25} more")
    if conflicts:
        with st.expander(f"⚠️ Conflicts ({len(conflicts)})", expanded=False):
            st.caption(
                "The same trip variant was changed on both devices since the "
                "last sync. Pick a winner per entry — the winner replaces that "
                "whole variant, including stops the other device added."
            )
            for i, conflict in enumerate(conflicts):
                key = conflict.get("key", [])
                label = " / ".join(str(k) for k in key)
                # Keyed by the sync key, never by list index: resolving one
                # conflict shifts the list and used to hand the next radio a
                # stale, pre-selected choice.
                choice_key = "sync_conf_" + "_".join(str(k) for k in key)[:80]
                st.markdown(f"**{label}**")
                local = conflict.get("local", {})
                remote = conflict.get("remote", {})
                st.caption(
                    f"local ({local.get('device')}, {_short_ts(local.get('ts', ''))}): "
                    f"`{str(local.get('value'))[:80]}`"
                )
                st.caption(
                    f"cloud ({remote.get('device')}, {_short_ts(remote.get('ts', ''))}): "
                    f"`{str(remote.get('value'))[:80]}`"
                )
                choice = st.radio(
                    "Winner",
                    ("local", "cloud"),
                    key=choice_key,
                    horizontal=True,
                    label_visibility="collapsed",
                )
                if st.button("Apply choice", key=f"{choice_key}_go"):
                    winner = local if choice == "local" else remote
                    summary = _merge.apply_entries([winner])
                    _merge.save_last_applied([winner])
                    remaining = [c for c in conflicts
                                 if json.dumps(c.get("key")) != json.dumps(key)]
                    _merge.save_conflicts(remaining)
                    st.session_state.pop(choice_key, None)
                    st.toast(f"Applied {choice} ({summary.get('applied', 0)}).",
                             icon="✅")
                    st.rerun()
            col_a, col_b = st.columns(2)
            with col_a:
                if st.button("Keep all local", key="sync_keep_local"):
                    winners = [c["local"] for c in conflicts]
                    summary = _merge.apply_entries(winners)
                    _merge.save_last_applied(winners)
                    _merge.save_conflicts([])
                    st.session_state["sync_result"] = (
                        f"Applied local ({summary.get('applied', 0)}).")
                    st.rerun()
            with col_b:
                if st.button("Keep all cloud", key="sync_keep_cloud"):
                    winners = [c["remote"] for c in conflicts]
                    summary = _merge.apply_entries(winners)
                    _merge.save_last_applied(winners)
                    _merge.save_conflicts([])
                    st.session_state["sync_result"] = (
                        f"Applied cloud ({summary.get('applied', 0)}).")
                    st.rerun()
