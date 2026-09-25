"""Itinerary Planner page — trips → variants → ordered stops with a map.

Data lives in trips.json next to app.py (autosaved on every mutation via
load → mutate → save → rerun). All route logic lives in the streamlit-free
`itinerary` package and is covered by tests/test_itinerary.py.

Widget-key safety: keys that hold per-variant values (leg modes, visible
modes, focus country) are namespaced by variant id, so switching variants
can never feed stale widget values into a new variant.
"""

from __future__ import annotations

import re
from datetime import date, timedelta

import pandas as pd
import streamlit as st

from data_utils import DATA_PATH, load_destinations
from itinerary import geo, geocode, itinerary as ops, map as itmap, models, storage

MONTHS = ops.MONTHS
TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")

_ROLE_BADGE = {"origin": "▶", "stop": "📍", "return": "🏁"}


# ── data access ──────────────────────────────────────────────────────────────

@st.cache_data(ttl=600)
def _coords_index_cached() -> dict:
    return geo.load_coords_index()


def _clear_trip_widgets() -> None:
    """Drop every trip-selector widget key.

    Streamlit re-sends a widget's previous value from the browser on later
    runs, so a shared key would let a stale selection silently switch the
    active trip. Keys are therefore per-trip (and cleared on every switch).
    """
    for key in [k for k in st.session_state if str(k).startswith("itin_trip_sel")]:
        st.session_state.pop(key, None)


def _resolve_active_id(trips: list[dict]) -> str | None:
    """Which trip is open: session state, else the last one used (persisted),
    else the first trip."""
    if not trips:
        return None
    ids = {t["id"] for t in trips}
    wanted = st.session_state.get("itin_active_trip_id")
    if wanted not in ids:
        wanted = storage.load_ui_state().get("active_trip_id")
    return wanted if wanted in ids else trips[0]["id"]


def _active_trip(data: dict) -> dict | None:
    trips = data.get("trips", [])
    active_id = _resolve_active_id(trips)
    if active_id is None:
        return None
    if st.session_state.get("itin_active_trip_id") != active_id:
        _set_active_trip(active_id)
    return next(t for t in trips if t["id"] == active_id)


def _set_active_trip(trip_id: str | None) -> None:
    """Remember the open trip for this session AND for the next page load."""
    st.session_state["itin_active_trip_id"] = trip_id
    storage.save_ui_state({"active_trip_id": trip_id})


def _save_and_rerun(data: dict) -> None:
    storage.save_trips(data)
    st.rerun()


def _switch_trip(trip_id: str) -> None:
    # Pure UI state: which trip is open. Clearing the Trip selectbox keys makes
    # it re-initialise from the new active trip on the next run.
    _set_active_trip(trip_id)
    _clear_trip_widgets()
    st.session_state.pop("itin_del_trip_pending", None)
    st.session_state.pop("itin_del_var_pending", None)
    st.session_state.pop("itin_del_stop_pending", None)
    st.session_state["itin_selected_stop_id"] = None
    st.rerun()


# ── mutation callbacks (load → mutate → save → rerun) ───────────────────────

def _new_trip(name: str) -> None:
    data = storage.load_trips()
    trip = ops.create_trip(data, name or "New trip")
    _set_active_trip(trip["id"])
    _clear_trip_widgets()
    st.session_state["itin_selected_stop_id"] = None
    _save_and_rerun(data)


def _duplicate_trip(trip_id: str) -> None:
    data = storage.load_trips()
    clone = ops.duplicate_trip(data, trip_id)
    if clone:
        _set_active_trip(clone["id"])
        _clear_trip_widgets()
        st.session_state["itin_selected_stop_id"] = None
    _save_and_rerun(data)


def _delete_trip(trip_id: str) -> None:
    data = storage.load_trips()
    ops.delete_trip(data, trip_id)
    _set_active_trip(None)
    _clear_trip_widgets()
    st.session_state["itin_selected_stop_id"] = None
    _save_and_rerun(data)


def _rename_trip(trip_id: str, name: str) -> None:
    data = storage.load_trips()
    trip = models.find_trip(data, trip_id)
    if trip:
        ops.rename_trip(trip, name)
        _save_and_rerun(data)


def _variant_action(action: str, arg: str | None = None) -> None:
    data = storage.load_trips()
    trip = _active_trip(data)
    if trip is None:
        return
    st.session_state.pop("itin_del_var_pending", None)
    if action == "new":
        variant = models.make_variant(arg or f"Variant {len(trip['variants']) + 1}")
        trip["variants"].append(variant)
        trip["active_variant_id"] = variant["id"]
    elif action == "duplicate":
        clone = ops.duplicate_variant(trip, trip["active_variant_id"])
        if clone:
            trip["active_variant_id"] = clone["id"]
    elif action == "rename" and arg:
        variant = models.active_variant(trip)
        if variant:
            variant["name"] = arg.strip() or variant["name"]
    elif action == "delete":
        ops.delete_variant(trip, arg or trip["active_variant_id"])
    elif action == "activate" and arg:
        ops.set_active_variant(trip, arg)
    st.session_state["itin_selected_stop_id"] = None
    _save_and_rerun(data)


def _add_stop(ref: dict, role: str, nights: int | None = None,
              arrival: str | None = None) -> None:
    data = storage.load_trips()
    trip = _active_trip(data)
    if trip is None:
        return
    variant = models.active_variant(trip)
    # fill workbook coords at creation time (custom refs keep geocode lat/lon)
    ref = geo.resolve_ref(ref, _coords_index_cached())
    ops.add_stop(variant, ref, role=role, nights=nights, arrival_date=arrival)
    st.session_state["itin_selected_stop_id"] = None
    _save_and_rerun(data)


def _remove_stop(stop_id: str) -> None:
    data = storage.load_trips()
    trip = _active_trip(data)
    if trip is None:
        return
    variant = models.active_variant(trip)
    for i, stop in enumerate(variant["stops"]):
        if stop["id"] == stop_id:
            ops.remove_stop(variant, i)
            break
    if st.session_state.get("itin_selected_stop_id") == stop_id:
        st.session_state["itin_selected_stop_id"] = None
    _save_and_rerun(data)


def _move_stop(stop_id: str, direction: int) -> None:
    data = storage.load_trips()
    trip = _active_trip(data)
    if trip is None:
        return
    variant = models.active_variant(trip)
    for i, stop in enumerate(variant["stops"]):
        if stop["id"] == stop_id:
            ops.move_stop(variant, i, direction)
            break
    _save_and_rerun(data)


def _select_stop(stop_id: str | None) -> None:
    st.session_state["itin_selected_stop_id"] = stop_id
    st.rerun()


def _update_stop(stop_id: str, **fields) -> None:
    data = storage.load_trips()
    trip = _active_trip(data)
    if trip is None:
        return
    variant = models.active_variant(trip)
    for stop in variant["stops"]:
        if stop["id"] == stop_id:
            stop.update(fields)
            break
    storage.save_trips(data)  # no rerun: widget value already on screen


def _set_leg_mode(variant_id: str, leg_index: int, mode: str) -> None:
    data = storage.load_trips()
    trip = _active_trip(data)
    if trip is None:
        return
    variant = models.find_variant(trip, variant_id)
    if variant:
        ops.set_leg_mode(variant, leg_index, mode)
        storage.save_trips(data)


def _update_variant(variant_id: str, **fields) -> None:
    data = storage.load_trips()
    trip = _active_trip(data)
    if trip is None:
        return
    variant = models.find_variant(trip, variant_id)
    if variant:
        variant.update(fields)
        storage.save_trips(data)


# ── small UI helpers ─────────────────────────────────────────────────────────

def _date_or_none(iso: str | None):
    if not iso:
        return None
    try:
        return date.fromisoformat(iso)
    except ValueError:
        return None


def _stop_header(stop: dict, index: int, total: int) -> None:
    ref = stop["ref"]
    selected = st.session_state.get("itin_selected_stop_id") == stop["id"]
    head_l, head_r = st.columns([1, 2.2], vertical_alignment="center")
    with head_l:
        st.markdown(
            f"**{index + 1}. {_ROLE_BADGE.get(stop.get('role'), '📍')} "
            f"{ref.get('name', '?')}**"
            + (f" · {ref['country']}" if ref.get("country") else "")
        )
    with head_r:
        cols = st.columns(4)
        if cols[0].button("↑", key=f"up_{stop['id']}",
                          disabled=index == 0, use_container_width=True,
                          help="Move up"):
            _move_stop(stop["id"], -1)
        if cols[1].button("↓", key=f"down_{stop['id']}",
                          disabled=index == total - 1, use_container_width=True,
                          help="Move down"):
            _move_stop(stop["id"], +1)
        eye = "👁️" if selected else "👁"
        if cols[2].button(eye, key=f"eye_{stop['id']}",
                          use_container_width=True,
                          help="Highlight on map"):
            _select_stop(None if selected else stop["id"])
        if cols[3].button("🗑", key=f"del_{stop['id']}",
                          use_container_width=True, type="primary",
                          help="Remove stop"):
            st.session_state["itin_del_stop_pending"] = stop["id"]
            st.rerun()
    # removing a stop also drops its leg — always ask first
    if st.session_state.get("itin_del_stop_pending") == stop["id"]:
        st.warning(f"Remove stop **{ref.get('name', '?')}** from this trip?")
        sc1, sc2, _sc3 = st.columns([1, 1, 3])
        with sc1:
            if st.button("🗑 Really remove", key=f"del_yes_{stop['id']}",
                         type="primary"):
                st.session_state.pop("itin_del_stop_pending", None)
                _remove_stop(stop["id"])
        with sc2:
            if st.button("Cancel", key=f"del_no_{stop['id']}"):
                st.session_state.pop("itin_del_stop_pending", None)
                st.rerun()
    if selected:
        st.markdown(":blue[_highlighted on the Map tab_]")


def _stop_editor(stop: dict) -> None:
    is_origin = stop.get("role") == "origin"
    label = ("🗓 Trip start — departure" if is_origin
             else "🗓 Dates, times & nights")
    with st.expander(label, icon=":material/event:"):
        if is_origin:
            # Trip start: nothing is arrived at and nobody stays the night,
            # so only the departure date/time (plus notes) make sense here.
            c1, c2 = st.columns(2)
            with c1:
                dep = st.date_input("Departure",
                                    value=_date_or_none(stop.get("departure_date")),
                                    key=f"dep_{stop['id']}", format="YYYY-MM-DD")
            with c2:
                dep_t = st.text_input("Departure time",
                                      value=stop.get("departure_time") or "",
                                      key=f"dept_{stop['id']}", placeholder="18:45",
                                      max_chars=5)
        else:
            c1, c2 = st.columns(2)
            with c1:
                arr = st.date_input("Arrival", value=_date_or_none(stop.get("arrival_date")),
                                    key=f"arr_{stop['id']}", format="YYYY-MM-DD")
            with c2:
                dep = st.date_input("Departure", value=_date_or_none(stop.get("departure_date")),
                                    key=f"dep_{stop['id']}", format="YYYY-MM-DD")
            c1, c2, c3 = st.columns([1, 1, 1.4])
            with c1:
                nights = st.number_input(
                    "Nights", min_value=0, max_value=90, step=1,
                    value=int(stop.get("nights") or 0), key=f"nights_{stop['id']}")
            with c2:
                arr_t = st.text_input("Arrival time", value=stop.get("arrival_time") or "",
                                      key=f"arrt_{stop['id']}", placeholder="09:30",
                                      max_chars=5)
            with c3:
                dep_t = st.text_input("Departure time", value=stop.get("departure_time") or "",
                                      key=f"dept_{stop['id']}", placeholder="18:45",
                                      max_chars=5)
        notes = st.text_input("Notes", value=stop.get("notes") or "",
                              key=f"notes_{stop['id']}")
        auto_clicked = False
        if is_origin:
            apply_clicked = st.button("Save stop", key=f"save_{stop['id']}",
                                      type="primary", use_container_width=True)
        else:
            b1, b2 = st.columns(2)
            apply_clicked = b1.button("Save stop", key=f"save_{stop['id']}",
                                      type="primary", use_container_width=True)
            auto_clicked = b2.button("Auto: departure = arrival + nights",
                                     key=f"auto_{stop['id']}",
                                     use_container_width=True,
                                     help="Needs an arrival date and nights > 0.")
        if apply_clicked:
            errors = []
            if is_origin:
                if dep_t.strip() and not TIME_RE.match(dep_t.strip()):
                    errors.append("Departure time: use HH:MM (24h).")
            else:
                for lbl, tv in (("Arrival time", arr_t), ("Departure time", dep_t)):
                    if tv.strip() and not TIME_RE.match(tv.strip()):
                        errors.append(f"{lbl}: use HH:MM (24h).")
                if dep and arr and dep < arr:
                    errors.append("Departure is before arrival.")
            if errors:
                st.error(" ".join(errors))
            elif is_origin:
                _update_stop(
                    stop["id"],
                    departure_date=dep.isoformat() if dep else None,
                    departure_time=dep_t.strip() or None,
                    notes=notes.strip(),
                )
                st.toast("Stop saved")
            else:
                _update_stop(
                    stop["id"],
                    arrival_date=arr.isoformat() if arr else None,
                    departure_date=dep.isoformat() if dep else None,
                    nights=int(nights),
                    arrival_time=arr_t.strip() or None,
                    departure_time=dep_t.strip() or None,
                    notes=notes.strip(),
                )
                st.toast("Stop saved")
        if auto_clicked:
            if arr and int(nights) > 0:
                auto_dep = arr + timedelta(days=int(nights))
                _update_stop(stop["id"], departure_date=auto_dep.isoformat(),
                             nights=int(nights))
                st.rerun()
            else:
                st.warning("Set an arrival date and nights > 0 first.")


def _leg_row(variant: dict, i: int) -> None:
    a = variant["stops"][i]["ref"]
    b = variant["stops"][i + 1]["ref"]
    leg = variant["legs"][i]
    cap_l, sel_r = st.columns([1.6, 1], vertical_alignment="center")
    with cap_l:
        st.caption(f"{a.get('name', '?')}  →  {b.get('name', '?')}")
    with sel_r:
        sel = st.selectbox(
            "Transport", models.TRANSPORT_MODES,
            index=models.TRANSPORT_MODES.index(leg.get("mode", "flight")),
            format_func=lambda m: f"{itmap.MODE_STYLES[m]['label']}",
            key=f"leg_{variant['id']}_{i}", label_visibility="collapsed",
        )
        if sel != leg.get("mode"):
            _set_leg_mode(variant["id"], i, sel)
            st.rerun()


def _add_stop_panel(df: pd.DataFrame) -> None:
    with st.expander("➕ Add a stop", icon=":material/add_location:"):

        source = st.radio("Source", ["Workbook destination", "Custom city",
                                     "Home gateway"], horizontal=True,
                          key="itin_add_source")
        role = st.radio("Role", ["stop", "origin", "return"], horizontal=True,
                        key="itin_add_role",
                        help="Origin = trip start, Return = way back home.")
        nights = st.number_input("Nights", min_value=0, max_value=90, value=0,
                                 key="itin_add_nights")

        if source == "Workbook destination":
            dest = st.selectbox("Destination",
                                sorted(df["Destination"].astype(str).tolist()),
                                key="itin_add_dest")
            if st.button("Add stop", key="itin_add_dest_go", type="primary"):
                _add_stop({"kind": "destination", "name": dest},
                          role=role, nights=int(nights) or None)

        elif source == "Custom city":
            query = st.text_input("City name", key="itin_add_custom",
                                  placeholder="e.g. Chengdu")
            if st.button("Search", key="itin_add_search") and query.strip():
                st.session_state["itin_geocode_results"] = geocode.search(
                    query.strip(), count=5)
                st.session_state.pop("itin_add_pick", None)
                if not st.session_state["itin_geocode_results"]:
                    st.warning("No geocode match — check spelling or add the "
                               "city to the workbook first.")
            results = st.session_state.get("itin_geocode_results") or []
            if results:
                labels = [
                    f"{r['name']}"
                    + (f", {r['admin1']}" if r.get("admin1") else "")
                    + (f" · {r['country']}" if r.get("country") else "")
                    for r in results]
                pick = st.radio("Matches", labels, key="itin_add_pick")
                chosen = results[labels.index(pick)]
                if st.button("Add stop", key="itin_add_custom_go",
                             type="primary"):
                    st.session_state.pop("itin_geocode_results", None)
                    _add_stop({"kind": "custom", "name": chosen["name"],
                               "country": chosen.get("country"),
                               "lat": chosen.get("lat"),
                               "lon": chosen.get("lon")},
                              role=role, nights=int(nights) or None)

        else:  # Home gateway
            gw = geo.HOME_GATEWAY
            st.caption(f"{gw['name']}, {gw['country']}")
            if st.button("Add stop", key="itin_add_gw_go", type="primary"):
                _add_stop({"kind": "gateway", "name": gw["name"],
                           "country": gw["country"], "lat": gw["lat"],
                           "lon": gw["lon"]},
                          role=role, nights=int(nights) or None)


def _trip_wide_suggestion(suggestions: dict[str, list[str]]) -> list[str]:
    """Months the workbook rates good for EVERY stop of the variant."""
    common: set[str] | None = None
    for months in suggestions.values():
        common = set(months) if common is None else common & set(months)
    if not common:
        return []
    return [m for m in MONTHS if m in common]


def _variant_meta_panel(variant: dict, df: pd.DataFrame) -> None:
    with st.expander("⭐ Rating, months & notes", icon=":material/tune:"):
        rating_raw = st.select_slider(
            "Rating (1-10)",
            options=["—"] + list(range(1, 11)),
            value=variant.get("rating") or "—",
            key=f"rate_{variant['id']}")
        rating = None if rating_raw == "—" else int(rating_raw)
        if rating != variant.get("rating"):
            _update_variant(variant["id"], rating=rating)

        stored_months = variant.get("months") or []
        suggestions = ops.suggested_months(variant, df)
        # Pre-select the workbook suggestion (months good for the WHOLE route)
        # until the user picks their own; any number of months can be selected.
        sel_months = st.multiselect(
            "Best travel months", MONTHS,
            default=stored_months or _trip_wide_suggestion(suggestions),
            key=f"months_{variant['id']}",
            help="Select any number of months that work for the whole trip.")
        if sel_months != stored_months:
            _update_variant(variant["id"], months=sel_months)

        if suggestions:
            hint = " · ".join(
                f"{name}: {', '.join(m[:3] for m in mons)}"
                for name, mons in suggestions.items())
            st.caption(f"Workbook says good: {hint}")

        comment = st.text_area("Comment", value=variant.get("comment") or "",
                               key=f"comment_{variant['id']}", height=68)
        if comment != (variant.get("comment") or ""):
            _update_variant(variant["id"], comment=comment)

        notes = st.text_area("Variant notes", value=variant.get("notes") or "",
                             key=f"vnotes_{variant['id']}", height=68)
        if notes != (variant.get("notes") or ""):
            _update_variant(variant["id"], notes=notes)


# ── tabs ─────────────────────────────────────────────────────────────────────

def _render_plan_tab(data: dict, trip: dict | None, variant: dict | None,
                     df: pd.DataFrame) -> None:
    if trip is None:
        st.info("No trips yet — create one to start planning.")
        return

    # toolbars
    tb1, tb2 = st.columns([1.2, 1])
    with tb1:
        st.markdown(f"#### 🧳 {trip['name']}")
        tc1, tc2, tc3, tc4 = st.columns(4)
        with tc1:
            with st.popover("New", use_container_width=True):
                name = st.text_input("Trip name", key="itin_new_trip_name")
                if st.button("Create", key="itin_new_trip_go", type="primary"):
                    _new_trip(name)
        with tc2:
            if st.button("Copy", key="itin_copy_trip",
                         help="Duplicate this trip"):
                _duplicate_trip(trip["id"])
        with tc3:
            with st.popover("Rename", use_container_width=True):
                rname = st.text_input("Trip name", value=trip["name"],
                                      key=f"itin_rename_trip_{trip['id']}")
                if st.button("Apply", key="itin_rename_trip_go"):
                    _rename_trip(trip["id"], rname)
        with tc4:
            if st.button("🗑 Delete", key="itin_del_trip"):
                st.session_state["itin_del_trip_pending"] = trip["id"]
                st.rerun()
    with tb2:
        # Keyed per trip: a shared key would let the browser re-send a stale
        # selection and silently switch the active trip back. Labels get a
        # short id suffix whenever names collide, so a duplicate trip name can
        # never make the dropdown switch to the wrong trip.
        trip_ids = [t["id"] for t in data["trips"]]
        names = [t["name"] for t in data["trips"]]
        labels = [name if names.count(name) == 1
                  else f"{name} · {tid[-6:]}"
                  for tid, name in zip(trip_ids, names)]
        current_label = labels[trip_ids.index(trip["id"])]
        picked_label = st.selectbox("Trip", labels,
                                    index=labels.index(current_label),
                                    key=f"itin_trip_sel_{trip['id']}",
                                    help="Switch between saved itineraries")
        if picked_label != current_label:
            _switch_trip(trip_ids[labels.index(picked_label)])
        vnames = [v["name"] for v in trip["variants"]]
        current = variant["name"] if variant else None
        if current not in vnames:
            current = vnames[0] if vnames else None
        picked = st.selectbox("Variant", vnames,
                              index=vnames.index(current) if current else 0,
                              key=f"itin_variant_sel_{trip['id']}",
                              label_visibility="collapsed")
        if picked != current and picked in vnames:
            target = next(v for v in trip["variants"]
                          if v["name"] == picked)
            _variant_action("activate", target["id"])
        vc1, vc2, vc3, vc4 = st.columns(4)
        with vc1:
            with st.popover("New", use_container_width=True):
                vname = st.text_input(
                    "Variant name",
                    value=f"Variant {len(trip['variants']) + 1}",
                    key=f"itin_new_var_name_{trip['id']}_"
                        f"{len(trip['variants'])}")
                if st.button("Create", key="itin_new_var_go", type="primary"):
                    _variant_action("new", vname)
        with vc2:
            if st.button("Copy", key="itin_copy_var",
                         help="Duplicate this variant"):
                _variant_action("duplicate")
        with vc3:
            with st.popover("Rename", use_container_width=True):
                vrname = st.text_input(
                    "Variant name",
                    value=variant["name"] if variant else "",
                    key=f"itin_rename_var_"
                        f"{variant['id'] if variant else 'none'}")
                if st.button("Apply", key="itin_rename_var_go"):
                    _variant_action("rename", vrname)
        with vc4:
            if st.button("🗑 Delete", key="itin_del_var",
                         disabled=len(trip["variants"]) <= 1):
                st.session_state["itin_del_var_pending"] = (
                    variant["id"] if variant else None)
                st.rerun()

    # deleting a variant discards its stops — always ask first
    if (variant is not None and
            st.session_state.get("itin_del_var_pending") == variant["id"]):
        st.warning(f"Delete variant **{variant['name']}** with all its stops? "
                   "This cannot be undone.")
        yc, cc, _ = st.columns([1, 1, 3])
        with yc:
            if st.button("🗑 Really delete", key="itin_del_var_yes",
                         type="primary"):
                st.session_state.pop("itin_del_var_pending", None)
                _variant_action("delete")
        with cc:
            if st.button("Cancel", key="itin_del_var_no"):
                st.session_state.pop("itin_del_var_pending", None)
                st.rerun()

    # deleting a trip removes ALL its variants — always ask first
    if st.session_state.get("itin_del_trip_pending") == trip["id"]:
        st.warning(f"Delete trip **{trip['name']}** with all its variants? "
                   "This cannot be undone.")
        yc, cc, _ = st.columns([1, 1, 3])
        with yc:
            if st.button("🗑 Really delete", key="itin_del_trip_yes",
                         type="primary"):
                st.session_state.pop("itin_del_trip_pending", None)
                _delete_trip(trip["id"])
        with cc:
            if st.button("Cancel", key="itin_del_trip_no"):
                st.session_state.pop("itin_del_trip_pending", None)
                st.rerun()

    st.divider()

    if variant is None:
        st.info("This trip has no variants — create one above.")
        return

    left, right = st.columns([1.2, 1], gap="medium")
    with left:
        stops = variant["stops"]
        if not stops:
            st.info("No stops yet — add your first destination below.")
        for i, stop in enumerate(stops):
            with st.container(border=True):
                _stop_header(stop, i, len(stops))
                _stop_editor(stop)
            if i < len(stops) - 1:
                _leg_row(variant, i)
        _add_stop_panel(df)

    with right:
        t = ops.totals(variant)
        st.markdown("##### Route summary")
        m1, m2, m3 = st.columns(3)
        m1.metric("Stops", t["stops"])
        m2.metric("Nights", t["nights"])
        m3.metric("Rating", variant.get("rating") or "—")
        bits = []
        if t["flights"]:
            bits.append(f"✈ {t['flights']}")
        if t["trains"]:
            bits.append(f"🚆 {t['trains']}")
        if t["other"]:
            bits.append(f"🚌 {t['other']}")
        span = (f"**{t['start']}** → **{t['end']}**"
                if t["start"] else "no dates set")
        st.markdown(f"{span}  \n{' · '.join(bits) if bits else 'no transport set'}")

        if variant.get("comment"):
            st.markdown(f"> {variant['comment']}")

        _variant_meta_panel(variant, df)

        st.markdown("##### ⚠️ Check results")
        warnings = ops.warnings_for(variant)
        if warnings:
            for w in warnings:
                st.markdown(f"<span style='font-size:0.85em'>⚠️ {w}</span>",
                            unsafe_allow_html=True)
        else:
            st.success("All good — route is consistent.")

        st.download_button("⬇ Export trip (JSON)", storage.export_trip(trip),
                           file_name=f"{trip['name'].replace(' ', '_').lower()}.json",
                           mime="application/json",
                           use_container_width=True)


def _render_map_tab(variant: dict | None) -> None:
    if variant is None or not variant.get("stops"):
        st.info("Add stops in the Plan tab to see the route map.")
        return
    vid = variant["id"]
    c1, c2, c3 = st.columns([1.4, 1, 1])
    with c1:
        modes_in_use = sorted({leg.get("mode", "other")
                               for leg in variant.get("legs", [])})
        visible = st.multiselect(
            "Show transport modes", modes_in_use, default=modes_in_use,
            format_func=lambda m: itmap.MODE_STYLES.get(m, {"label": m})["label"],
            key=f"itin_visible_modes_{vid}")
    with c2:
        show_gw = st.toggle("Show gateways", value=True,
                            key=f"itin_show_gw_{vid}")
    with c3:
        countries = sorted({s["ref"].get("country") for s in variant["stops"]
                            if s["ref"].get("kind") != "gateway"
                            and s["ref"].get("country")})
        focus = st.selectbox("Focus country", ["(whole route)"] + countries,
                             key=f"itin_focus_{vid}")

    fit_points = None
    if focus != "(whole route)":
        fit_points = [(s["ref"]["lat"], s["ref"]["lon"])
                      for s in variant["stops"]
                      if s["ref"].get("kind") != "gateway"
                      and s["ref"].get("country") == focus
                      and None not in (s["ref"].get("lat"),
                                       s["ref"].get("lon"))]

    fig = itmap.build_figure(
        variant,
        selected_stop_id=st.session_state.get("itin_selected_stop_id"),
        visible_modes=set(visible) if modes_in_use else None,
        show_gateways=show_gw,
        fit_points=fit_points or None,
    )
    st.plotly_chart(fig, use_container_width=True)

    t = ops.totals(variant)
    st.caption(f"{t['stops']} stops · {t['nights']} nights · "
               f"{t['flights']} flights · {t['trains']} trains · "
               f"click 👁 on a stop in the Plan tab to highlight it here")


def _render_compare_tab(trip: dict | None) -> None:
    if trip is None:
        st.info("No trips yet.")
        return
    rows = []
    for v in trip["variants"]:
        t = ops.totals(v)
        rows.append({
            "": "✅" if v["id"] == trip["active_variant_id"] else "",
            "Variant": v["name"],
            "Rating": v.get("rating") or "—",
            "Months": ", ".join(m[:3] for m in (v.get("months") or [])) or "—",
            "Start": t["start"] or "—",
            "End": t["end"] or "—",
            "Stops": t["stops"],
            "Nights": t["nights"],
            "Flights": t["flights"],
            "Trains": t["trains"],
            "Other": t["other"],
            "Warnings": len(ops.warnings_for(v)),
            "Comment": (v.get("comment") or "")[:60],
        })
    st.dataframe(pd.DataFrame(rows), use_container_width=True, hide_index=True)

    names = [v["name"] for v in trip["variants"]]
    active = models.active_variant(trip)
    if len(names) > 1 and active is not None:
        # Labels + key include ids: a duplicate variant name can never target
        # the wrong variant, and activating elsewhere re-syncs the dropdown.
        labels = [name if names.count(name) == 1
                  else f"{name} · {v['id'][-6:]}"
                  for name, v in zip(names, trip["variants"])]
        current_label = labels[[v["id"] for v in trip["variants"]]
                               .index(active["id"])]
        picked = st.selectbox("Make active variant", labels,
                              index=labels.index(current_label),
                              key=f"itin_compare_activate_{trip['id']}"
                                  f"_{active['id']}")
        if picked != current_label:
            target = trip["variants"][labels.index(picked)]
            if st.button("Activate", key="itin_compare_go", type="primary"):
                _variant_action("activate", target["id"])


# ── sidebar trip switcher (rendered by app.py on every page) ─────────────────

def _open_trip_from_nav(trip_id: str, pg, itinerary_page) -> None:
    _set_active_trip(trip_id)
    _clear_trip_widgets()
    st.session_state.pop("itin_del_trip_pending", None)
    st.session_state.pop("itin_del_var_pending", None)
    st.session_state.pop("itin_del_stop_pending", None)
    st.session_state["itin_selected_stop_id"] = None
    if getattr(pg, "url_path", "") != "itinerary":
        st.switch_page(itinerary_page)
    else:
        st.rerun()


def render_sidebar_trips(pg, itinerary_page) -> None:
    """'Travel Itineraries' sidebar section — open any saved trip.

    One clickable row per trip with trip-level stats for its active ("main")
    variant, plus a quick way to create a new trip. Rendered by app.py below
    the 'Open destinations' section.
    """
    data = storage.load_trips()
    trips = data.get("trips", [])
    if not trips:
        return
    active_id = _resolve_active_id(trips)

    st.markdown("**Travel Itineraries**")
    with st.container(key="itin_trips"):
        for trip in trips:
            is_active = trip["id"] == active_id
            clicked = st.button(("✅ " if is_active else "🧳 ") + trip["name"],
                                key=f"itin_nav_{trip['id']}",
                                type="primary" if is_active else "secondary",
                                help="Open this itinerary",
                                use_container_width=True)
            # Clicking any trip opens it in the planner — also the ACTIVE one
            # (true no-op only when already on the itinerary page with it).
            on_itinerary = getattr(pg, "url_path", "") == "itinerary"
            if clicked and not (is_active and on_itinerary):
                _open_trip_from_nav(trip["id"], pg, itinerary_page)
            variant = models.active_variant(trip)
            if variant is None:
                continue
            t = ops.totals(variant)
            if not t["stops"]:
                st.caption("No stops yet")
                continue
            n_var = len(trip["variants"])
            bits = [f"{n_var} variant{'s' if n_var != 1 else ''} · "
                    f"{t['stops']} stops · {t['nights']} nights"]
            span = f"{t['start'] or '—'} → {t['end'] or '—'}"
            warn = len(ops.warnings_for(variant))
            if warn:
                span += f" · ⚠️ {warn}"
            modes = f"✈ {t['flights']} · 🚆 {t['trains']}"
            if t["other"]:
                modes += f" · 🚌 {t['other']}"
            bits.append(f"{span} · {modes}")
            comment = (variant.get("comment") or "").strip()
            if comment:
                short = comment[:60] + ("…" if len(comment) > 60 else "")
                bits.append(f"*{short}*")
            st.caption("  \n".join(bits))

    if st.button("➕ New itinerary", key="itin_nav_new", type="tertiary",
                 use_container_width=True):
        fresh = storage.load_trips()
        trip = ops.create_trip(fresh, "New trip")
        storage.save_trips(fresh)
        _open_trip_from_nav(trip["id"], pg, itinerary_page)

    _render_backup_restore()


def _render_backup_restore() -> None:
    """Collapsed sidebar section to roll trips.json back to a snapshot.

    A snapshot is taken automatically before every save, so an accidental
    trip/variant deletion can be undone here.
    """
    backups = storage.list_backups()
    if not backups:
        return
    with st.expander(f"♻️ Restore backup ({len(backups)})", expanded=False):
        st.caption("Snapshots of `trips.json`, newest first. Restoring "
                   "replaces ALL current trips (your current version is "
                   "snapshotted first).")
        labels = []
        for b in backups:
            trips = ", ".join(b["trips"]) or "no trips"
            labels.append(f"{b['label']} — {trips}")
        # Re-key when the list changes: a persisted selectbox value would
        # otherwise keep pointing at an old snapshot once newer ones appear.
        pick = st.selectbox("Snapshot", labels,
                            key=f"itin_backup_pick_{backups[0]['path']}",
                            label_visibility="collapsed")
        chosen = backups[labels.index(pick)] if pick in labels else backups[0]
        if st.session_state.get("itin_restore_pending") != chosen["path"]:
            if st.button("♻️ Restore this backup", key="itin_restore_ask",
                         use_container_width=True):
                st.session_state["itin_restore_pending"] = chosen["path"]
                st.rerun()
        else:
            st.warning(f"Replace all current trips with the snapshot from "
                       f"**{chosen['label']}** "
                       f"({', '.join(chosen['trips']) or 'no trips'})?")
            rc1, rc2 = st.columns(2)
            with rc1:
                if st.button("♻️ Yes, restore", key="itin_restore_go",
                             type="primary", use_container_width=True):
                    storage.restore_backup(chosen["path"])
                    st.session_state.pop("itin_restore_pending", None)
                    _set_active_trip(None)
                    _clear_trip_widgets()
                    st.rerun()
            with rc2:
                if st.button("Cancel", key="itin_restore_no",
                             use_container_width=True):
                    st.session_state.pop("itin_restore_pending", None)
                    st.rerun()


# ── entry point ──────────────────────────────────────────────────────────────

def render_itinerary() -> None:
    st.markdown("### 🧭 Itinerary Planner")
    st.caption("Combine destinations into multi-stop trips — variants, dates, "
               "transport legs and a route map. Everything autosaves to "
               "`trips.json`.")

    data = storage.ensure_seed()
    df, _metadata = load_destinations(DATA_PATH)
    trip = _active_trip(data)
    variant = models.active_variant(trip) if trip else None

    plan_tab, map_tab, compare_tab = st.tabs(["Plan", "Map", "Compare"])
    with plan_tab:
        _render_plan_tab(data, trip, variant, df)
    with map_tab:
        _render_map_tab(variant)
    with compare_tab:
        _render_compare_tab(trip)
