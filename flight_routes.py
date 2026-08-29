"""Flight & Train route lookup, caching, and visualization module.

Queries direct passenger flights (inbound & outbound) and high-speed rail
connections (for Chinese destinations), caches them locally as JSON, syncs
discovered airlines to the 'Airlines' Excel sheet, and presents interactive
tables with travel durations, Prio Thorsten, and Review scores.
"""

from __future__ import annotations

import html
import json
import re
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import pandas as pd
import streamlit as st

from data_utils import DATA_PATH, load_airlines_color_map, sync_airlines_to_excel
from deepseek_client import generate_flight_routes


def _normalize_key(value: object) -> str:
    """Normalize destination or airline name for caching and matching."""
    if value is None:
        return ""
    text = str(value)
    text = re.sub(r"\([^)]*\)", "", text)
    text = unicodedata.normalize("NFKD", text)
    text = text.encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^a-z0-9]+", "", text.lower())
    return text


def _parse_duration_minutes(text: object) -> float:
    """Convert duration string (e.g. '1h 45m', '2h', '45m', '1h 20m - 1h 40m') into minutes for sorting."""
    if text is None:
        return float("inf")
    raw = str(text).strip().lower()
    if not raw or raw in {"—", "-", "n/a", "none", "null"}:
        return float("inf")

    # Take the first lower-bound time segment
    first_part = raw.split("-")[0].split("–")[0].split("to")[0].strip()

    hours = 0.0
    minutes = 0.0

    h_match = re.search(r"(\d+(?:\.\d+)?)\s*h", first_part)
    if h_match:
        hours = float(h_match.group(1))

    m_match = re.search(r"(\d+(?:\.\d+)?)\s*m", first_part)
    if m_match:
        minutes = float(m_match.group(1))

    if not h_match and not m_match:
        num_match = re.search(r"(\d+(?:\.\d+)?)", first_part)
        if num_match:
            val = float(num_match.group(1))
            return val * 60 if val <= 18 else val
        return float("inf")

    return hours * 60 + minutes


def _format_score_display(value: object, is_prio: bool = False) -> str:
    """Format Prio or Review score nicely for the table cell."""
    if pd.isna(value) or str(value).strip() == "" or str(value).strip().lower() in {"nan", "none", "null"}:
        return "<span style='color:#94a3b8;'>—</span>"
    try:
        num = float(value)
        num_str = f"{num:.1f}" if num % 1 else f"{num:.0f}"
    except (ValueError, TypeError):
        num_str = str(value).strip()

    if is_prio:
        return f"<span style='font-weight:700;color:#0f172a;'>{html.escape(num_str)}<span style='font-size:0.75rem;color:#64748b;'>/10</span></span>"
    return f"<span style='font-weight:600;color:#0f172a;'>{html.escape(num_str)}<span style='font-size:0.75rem;color:#64748b;'>/10</span></span>"


def _get_cache_dir() -> Path:
    """Return the transport routes cache directory, creating it if needed."""
    cache_dir = DATA_PATH.parent / "flight_routes_cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir


def load_cached_flight_routes(destination_name: str) -> Optional[Dict[str, Any]]:
    """Load cached transport routes for a destination if available."""
    key = _normalize_key(destination_name)
    if not key:
        return None
    file_path = _get_cache_dir() / f"{key}.json"
    if not file_path.exists():
        return None
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def save_cached_flight_routes(destination_name: str, data: Dict[str, Any]) -> None:
    """Save transport routes data to the local cache."""
    key = _normalize_key(destination_name)
    if not key:
        return
    file_path = _get_cache_dir() / f"{key}.json"
    with open(file_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def fetch_and_cache_routes(destination_name: str, country: str) -> Dict[str, Any]:
    """Fetch transport routes from DeepSeek, sync airlines to Excel, and persist cache."""
    data = generate_flight_routes(destination_name, country)
    save_cached_flight_routes(destination_name, data)

    # Extract all discovered airlines and sync to Excel
    discovered_airlines = set()
    for r in data.get("routes", []):
        airlines = r.get("airlines", [])
        if isinstance(airlines, list):
            for a in airlines:
                if str(a).strip():
                    discovered_airlines.add(str(a).strip())
        elif isinstance(airlines, str) and airlines.strip():
            for a in airlines.split(","):
                if a.strip():
                    discovered_airlines.add(a.strip())

    if discovered_airlines:
        try:
            sync_airlines_to_excel(list(discovered_airlines))
        except Exception:
            pass

    return data


def _format_airline_html(airline_name: str, color_map: dict) -> str:
    """Format an airline name with color and bold styling based on the Airlines sheet."""
    clean_name = str(airline_name).strip()
    if not clean_name:
        return ""
    key = _normalize_key(clean_name)
    color_info = color_map.get(key)
    color = color_info.get("color") if color_info else None

    if not color or pd.isna(color):
        return f"<span style='color:#334155;'>{html.escape(clean_name)}</span>"

    color_str = str(color).strip().lower()
    is_bold = color_str in {"green", "blue"}

    color_palette = {
        "red": "#dc2626",
        "blue": "#2563eb",
        "green": "#16a34a",
        "yellow": "#d97706",
        "orange": "#ea580c",
        "purple": "#9333ea",
        "pink": "#db2777",
        "black": "#0f172a",
        "gray": "#64748b",
        "grey": "#64748b",
    }
    hex_color = color_palette.get(color_str, color_str)
    bold_style = "font-weight:700;" if is_bold else "font-weight:500;"

    return f"<span style='color:{hex_color};{bold_style}'>{html.escape(clean_name)}</span>"


def render_flight_routes_section(
    destination_name: str,
    country: str,
    df_all_destinations: pd.DataFrame,
    destination_col: str,
    metadata: Optional[dict] = None,
) -> None:
    """Render the Transport Connections (Flights & High-Speed Trains) section."""
    st.divider()
    st.subheader("🛫 Transport & Direct Connections")
    st.caption("Direct non-stop flight connections (inbound & outbound) and high-speed rail transit, sorted by duration.")

    cached_data = load_cached_flight_routes(destination_name)

    is_china = any(
        c in str(country).strip().lower() for c in ["china", "peoples republic of china", "prc", "cn"]
    ) or str(destination_name).strip().lower() in {
        "nanchang", "beijing", "shanghai", "guangzhou", "shenzhen", "chengdu", "chongqing",
        "hangzhou", "xian", "xi'an", "wuhan", "nanjing", "tianjin", "suzhou", "changsha",
        "zhengzhou", "qingdao", "dalian", "kunming", "xiamen", "fuzhou", "harbin", "guilin",
        "sanya", "haikou", "urumqi", "lhasa", "guiyang", "nanning", "hefei", "jinan"
    }

    col_btn1, col_btn2 = st.columns([3, 5])
    with col_btn1:
        if cached_data is None:
            btn_label = "🛫 Research Flights & Trains" if is_china else "🛫 Research Flight Connections"
            btn_type = "primary"
        else:
            btn_label = "🔄 Re-research Transport Connections"
            btn_type = "secondary"

        if st.button(btn_label, key=f"btn_flights_{destination_name}", type=btn_type):
            with st.spinner(f"Researching direct connections for {destination_name}..."):
                try:
                    cached_data = fetch_and_cache_routes(destination_name, country)
                    st.success("Transport connections updated successfully!")
                    st.rerun()
                except Exception as exc:
                    st.error(f"Could not research routes: {exc}")
                    return

    if cached_data is None:
        st.info(
            f"Click **{btn_label}** above to research all direct flight routes "
            f"(inbound & outbound){' and high-speed rail connections' if is_china else ''} for {destination_name}."
        )
        return

    # Last Updated info
    last_updated = cached_data.get("last_updated") or datetime.now().strftime("%d %b %Y")
    with col_btn2:
        st.markdown(
            f"<div style='padding-top:8px;font-size:0.85rem;color:#64748b;'>"
            f"🕒 <strong>Last updated:</strong> {html.escape(last_updated)}"
            f"</div>",
            unsafe_allow_html=True,
        )

    # Sync discovered airlines
    routes: List[Dict[str, Any]] = cached_data.get("routes", [])
    cached_airlines = set()
    for r in routes:
        airlines = r.get("airlines", [])
        if isinstance(airlines, list):
            for a in airlines:
                if str(a).strip():
                    cached_airlines.add(str(a).strip())
        elif isinstance(airlines, str) and airlines.strip():
            for a in airlines.split(","):
                if a.strip():
                    cached_airlines.add(a.strip())
    if cached_airlines:
        try:
            sync_airlines_to_excel(list(cached_airlines))
        except Exception:
            pass

    # Load color map from Excel Airlines sheet
    color_map = load_airlines_color_map()

    # Build catalog destination lookup map: key -> {prio, reviews, name}
    planner_lookup = {}
    prio_col = metadata.get("prio_col") if metadata else None
    reviews_col = metadata.get("reviews_col") if metadata else None

    if df_all_destinations is not None and destination_col in df_all_destinations.columns:
        for _, row in df_all_destinations.iterrows():
            dest_val = row.get(destination_col)
            if pd.notna(dest_val) and str(dest_val).strip():
                k = _normalize_key(str(dest_val))
                prio_val = row.get(prio_col) if prio_col and prio_col in row else None
                rev_val = row.get(reviews_col) if reviews_col and reviews_col in row else None
                planner_lookup[k] = {
                    "name": str(dest_val).strip(),
                    "prio": prio_val,
                    "reviews": rev_val,
                }

    hsr_routes: List[Dict[str, Any]] = cached_data.get("hsr_routes", [])
    airport_name = cached_data.get("airport_name", "")
    iata_code = cached_data.get("iata_code", "")
    train_stations = cached_data.get("train_stations", [])

    has_trains = bool(hsr_routes or (is_china and train_stations))

    if has_trains:
        tab_flights, tab_trains = st.tabs([
            f"🛫 Direct Flights ({len(routes)})",
            f"🚄 High-Speed Trains ({len(hsr_routes)})",
        ])
        with tab_flights:
            _render_flights_tab(
                destination_name,
                country,
                routes,
                airport_name,
                iata_code,
                planner_lookup,
                color_map,
            )
        with tab_trains:
            _render_trains_tab(
                destination_name,
                hsr_routes,
                train_stations,
                planner_lookup,
            )
    else:
        _render_flights_tab(
            destination_name,
            country,
            routes,
            airport_name,
            iata_code,
            planner_lookup,
            color_map,
        )


def _slugify(value: str) -> str:
    value = str(value).strip().lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-")


def _format_wishlist_link(planner_info: Optional[dict]) -> str:
    """Format Wishlist cell as a clickable link to destination detail in a new tab."""
    if not planner_info:
        return "<span style='color:#94a3b8;'>—</span>"
    dest_name = planner_info.get("name", "")
    slug = _slugify(dest_name)
    url = f"./destination-{slug}"
    return f"<a href='{url}' target='_blank' style='color:#2563eb;font-weight:600;text-decoration:underline;'>In Planner</a>"


def _render_flights_tab(
    destination_name: str,
    country: str,
    routes: List[Dict[str, Any]],
    airport_name: str,
    iata_code: str,
    planner_lookup: dict,
    color_map: dict,
) -> None:
    """Render the direct flights table sorted by duration, with Wishlist, Prio, and Reviews at the far right."""
    iata_badge = (
        f" <span style='background:#e0e7ff;color:#3730a3;padding:2px 8px;border-radius:6px;font-size:0.9rem;font-weight:700;'>{html.escape(iata_code)}</span>"
        if iata_code else ""
    )
    st.markdown(
        f"""
        <div style="background:#f8f9fc;border:1px solid #e2e8f0;border-left:5px solid #3b82f6;border-radius:10px;padding:12px 18px;margin-bottom:14px;">
            <div style="font-size:0.82rem;color:#64748b;text-transform:uppercase;letter-spacing:0.05em;font-weight:600;">Primary Airport (Inbound & Outbound Direct Flights)</div>
            <div style="font-size:1.15rem;font-weight:700;color:#0f172a;margin-top:2px;">
                {html.escape(airport_name or destination_name)}{iata_badge}
            </div>
        </div>
        """,
        unsafe_allow_html=True,
    )

    if not routes:
        st.warning("No direct flight routes were found for this destination.")
        return

    processed_rows = []
    wishlist_count = 0

    for r in routes:
        city = str(r.get("destination_city", "")).strip()
        dest_country = str(r.get("destination_country", "")).strip()
        dest_iata = str(r.get("destination_iata", "")).strip()
        flight_time = str(r.get("flight_time", "")).strip() or "—"
        duration_mins = _parse_duration_minutes(flight_time)

        airlines = r.get("airlines", [])
        raw_airlines_list = []
        if isinstance(airlines, list):
            raw_airlines_list = [str(a).strip() for a in airlines if str(a).strip()]
        elif isinstance(airlines, str) and airlines.strip():
            raw_airlines_list = [a.strip() for a in airlines.split(",") if a.strip()]

        plain_airlines_str = ", ".join(raw_airlines_list) if raw_airlines_list else "—"

        styled_airlines_html = ", ".join(
            _format_airline_html(a, color_map) for a in raw_airlines_list
        ) if raw_airlines_list else "—"

        # Lookup in planner for Wishlist, Prio and Reviews
        key = _normalize_key(city)
        planner_info = planner_lookup.get(key)
        is_in_planner = planner_info is not None

        if is_in_planner:
            wishlist_count += 1
            prio_val = planner_info.get("prio")
            reviews_val = planner_info.get("reviews")
        else:
            prio_val = None
            reviews_val = None

        freq = str(r.get("frequency_notes", "")).strip()
        wishlist_link_html = _format_wishlist_link(planner_info)

        processed_rows.append({
            "Destination City": city,
            "Country": dest_country,
            "Airport": dest_iata or "—",
            "Flight Time": flight_time,
            "_duration_mins": duration_mins,
            "Operating Airlines": plain_airlines_str,
            "_styled_airlines": styled_airlines_html,
            "Frequency": freq or "—",
            "_wishlist_html": wishlist_link_html,
            "Prio": prio_val,
            "Reviews": reviews_val,
            "_is_in_planner": is_in_planner,
        })

    df_routes = pd.DataFrame(processed_rows)

    # Always sort by flight duration ascending
    df_routes = df_routes.sort_values(by="_duration_mins", ascending=True)

    # Search & Filter
    st.markdown("<div style='height:4px;'></div>", unsafe_allow_html=True)
    f_col1, f_col2 = st.columns([3, 2])
    with f_col1:
        filter_options = [
            f"All Routes ({len(routes)})",
            f"In Planner ({wishlist_count})",
        ]
        selected_filter = st.radio(
            "Filter Flights",
            filter_options,
            index=0,
            horizontal=True,
            key=f"flight_filter_{destination_name}",
            label_visibility="collapsed",
        )
    with f_col2:
        search_query = st.text_input(
            "Search Flights",
            placeholder="🔍 Search city, airport, airline...",
            key=f"flight_search_{destination_name}",
            label_visibility="collapsed",
        )

    # Apply filters
    filtered_df = df_routes.copy()
    if selected_filter and "In Planner" in selected_filter:
        filtered_df = filtered_df[filtered_df["_is_in_planner"]]

    if search_query.strip():
        q = search_query.strip().lower()
        filtered_df = filtered_df[
            filtered_df["Destination City"].str.lower().str.contains(q, na=False)
            | filtered_df["Country"].str.lower().str.contains(q, na=False)
            | filtered_df["Airport"].str.lower().str.contains(q, na=False)
            | filtered_df["Flight Time"].str.lower().str.contains(q, na=False)
            | filtered_df["Operating Airlines"].str.lower().str.contains(q, na=False)
        ]

    # Render Styled HTML Table with Prio and Reviews at the far right
    table_rows_html = []
    for _, row in filtered_df.iterrows():
        dest_display = html.escape(str(row["Destination City"]))
        country_display = html.escape(str(row["Country"]))
        airport_display = html.escape(str(row["Airport"]))
        time_display = html.escape(str(row["Flight Time"]))
        airlines_html = row["_styled_airlines"]
        freq_display = html.escape(str(row["Frequency"]))
        wishlist_html = row["_wishlist_html"]
        prio_html = _format_score_display(row["Prio"], is_prio=True)
        reviews_html = _format_score_display(row["Reviews"], is_prio=False)

        table_rows_html.append(
            f"<tr style='border-bottom:1px solid #f1f5f9;'>"
            f"<td style='padding:10px 14px;font-weight:600;color:#0f172a;'>{dest_display}</td>"
            f"<td style='padding:10px 14px;color:#475569;'>{country_display}</td>"
            f"<td style='padding:10px 14px;color:#475569;font-family:monospace;font-weight:600;'>{airport_display}</td>"
            f"<td style='padding:10px 14px;color:#0f172a;'>{time_display}</td>"
            f"<td style='padding:10px 14px;line-height:1.5;'>{airlines_html}</td>"
            f"<td style='padding:10px 14px;color:#64748b;font-size:0.83rem;'>{freq_display}</td>"
            f"<td style='padding:10px 14px;text-align:center;'>{wishlist_html}</td>"
            f"<td style='padding:10px 14px;text-align:center;'>{prio_html}</td>"
            f"<td style='padding:10px 14px;text-align:center;'>{reviews_html}</td>"
            f"</tr>"
        )

    if not table_rows_html:
        st.info("No flight routes match the current filter/search.")
        return

    full_table_html = (
        "<div style='overflow-x:auto; max-height: 540px; border: 1px solid #e2e8f0; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.04); margin-top: 8px;'>"
        "<table style='width:100%; border-collapse:collapse; font-size:0.88rem; text-align:left;'>"
        "<thead style='position:sticky; top:0; background:#f8fafc; border-bottom:2px solid #e2e8f0; z-index:1;'>"
        "<tr style='color:#475569; font-weight:700;'>"
        "<th style='padding:10px 14px;'>Destination</th>"
        "<th style='padding:10px 14px;'>Country</th>"
        "<th style='padding:10px 14px;'>Airport Code</th>"
        "<th style='padding:10px 14px;'>Flight Duration</th>"
        "<th style='padding:10px 14px;'>Operating Airlines</th>"
        "<th style='padding:10px 14px;'>Schedule / Frequency</th>"
        "<th style='padding:10px 14px; text-align:center;'>Wishlist</th>"
        "<th style='padding:10px 14px; text-align:center;'>Prio Thorsten</th>"
        "<th style='padding:10px 14px; text-align:center;'>Review Score</th>"
        "</tr>"
        "</thead>"
        f"<tbody>{''.join(table_rows_html)}</tbody>"
        "</table>"
        "</div>"
    )
    if hasattr(st, "html"):
        st.html(full_table_html)
    else:
        st.markdown(full_table_html, unsafe_allow_html=True)


def _render_trains_tab(
    destination_name: str,
    hsr_routes: List[Dict[str, Any]],
    train_stations: List[str],
    planner_lookup: dict,
) -> None:
    """Render the High-Speed Railway (HSR) connections table sorted by travel time, with Wishlist, Prio, and Reviews at the far right."""
    station_names = ", ".join(train_stations) if train_stations else f"{destination_name} Railway Station"
    st.markdown(
        f"""
        <div style="background:#f0fdf4;border:1px solid #bbf7d0;border-left:5px solid #16a34a;border-radius:10px;padding:12px 18px;margin-bottom:14px;">
            <div style="font-size:0.82rem;color:#166534;text-transform:uppercase;letter-spacing:0.05em;font-weight:600;">China High-Speed Rail Hub (CRH / 高铁)</div>
            <div style="font-size:1.15rem;font-weight:700;color:#14532d;margin-top:2px;">
                🚄 {html.escape(station_names)}
            </div>
        </div>
        """,
        unsafe_allow_html=True,
    )

    if not hsr_routes:
        st.info("No direct high-speed rail connections were recorded for this destination.")
        return

    processed_trains = []
    wishlist_count = 0

    for r in hsr_routes:
        city = str(r.get("destination_city", "")).strip()
        arrival_station = str(r.get("destination_station", "")).strip()
        duration = str(r.get("duration", "")).strip() or "—"
        duration_mins = _parse_duration_minutes(duration)
        train_types = str(r.get("train_types", "G-Train")).strip()
        freq = str(r.get("frequency_notes", "")).strip() or "—"

        key = _normalize_key(city)
        planner_info = planner_lookup.get(key)
        is_in_planner = planner_info is not None

        if is_in_planner:
            wishlist_count += 1
            prio_val = planner_info.get("prio")
            reviews_val = planner_info.get("reviews")
        else:
            prio_val = None
            reviews_val = None

        wishlist_link_html = _format_wishlist_link(planner_info)

        processed_trains.append({
            "Destination City": city,
            "Arrival Station": arrival_station or "—",
            "Travel Time": duration,
            "_duration_mins": duration_mins,
            "Train Type": train_types,
            "Daily Frequency": freq,
            "_wishlist_html": wishlist_link_html,
            "Prio": prio_val,
            "Reviews": reviews_val,
            "_is_in_planner": is_in_planner,
        })

    df_trains = pd.DataFrame(processed_trains)

    # Always sort by travel time ascending
    df_trains = df_trains.sort_values(by="_duration_mins", ascending=True)

    st.markdown("<div style='height:4px;'></div>", unsafe_allow_html=True)
    t_col1, t_col2 = st.columns([3, 2])
    with t_col1:
        train_filter_options = [
            f"All Train Routes ({len(hsr_routes)})",
            f"In Planner ({wishlist_count})",
        ]
        selected_train_filter = st.radio(
            "Filter Trains",
            train_filter_options,
            index=0,
            horizontal=True,
            key=f"train_filter_{destination_name}",
            label_visibility="collapsed",
        )
    with t_col2:
        train_search = st.text_input(
            "Search Trains",
            placeholder="🔍 Search city or station...",
            key=f"train_search_{destination_name}",
            label_visibility="collapsed",
        )

    filtered_trains = df_trains.copy()
    if selected_train_filter and "In Planner" in selected_train_filter:
        filtered_trains = filtered_trains[filtered_trains["_is_in_planner"]]

    if train_search.strip():
        q = train_search.strip().lower()
        filtered_trains = filtered_trains[
            filtered_trains["Destination City"].str.lower().str.contains(q, na=False)
            | filtered_trains["Arrival Station"].str.lower().str.contains(q, na=False)
            | filtered_trains["Travel Time"].str.lower().str.contains(q, na=False)
            | filtered_trains["Train Type"].str.lower().str.contains(q, na=False)
        ]

    train_rows_html = []
    for _, row in filtered_trains.iterrows():
        dest_display = html.escape(str(row["Destination City"]))
        arr_display = html.escape(str(row["Arrival Station"]))
        time_display = html.escape(str(row["Travel Time"]))
        train_type_display = html.escape(str(row["Train Type"]))
        freq_display = html.escape(str(row["Daily Frequency"]))
        wishlist_html = row["_wishlist_html"]
        prio_html = _format_score_display(row["Prio"], is_prio=True)
        reviews_html = _format_score_display(row["Reviews"], is_prio=False)

        train_rows_html.append(
            f"<tr style='border-bottom:1px solid #f1f5f9;'>"
            f"<td style='padding:10px 14px;font-weight:600;color:#0f172a;'>{dest_display}</td>"
            f"<td style='padding:10px 14px;color:#475569;'>{arr_display}</td>"
            f"<td style='padding:10px 14px;color:#0f172a;'>{time_display}</td>"
            f"<td style='padding:10px 14px;color:#0f172a;font-weight:500;'>{train_type_display}</td>"
            f"<td style='padding:10px 14px;color:#64748b;font-size:0.83rem;'>{freq_display}</td>"
            f"<td style='padding:10px 14px;text-align:center;'>{wishlist_html}</td>"
            f"<td style='padding:10px 14px;text-align:center;'>{prio_html}</td>"
            f"<td style='padding:10px 14px;text-align:center;'>{reviews_html}</td>"
            f"</tr>"
        )

    if not train_rows_html:
        st.info("No train routes match the current filter/search.")
        return

    full_train_table_html = (
        "<div style='overflow-x:auto; max-height: 540px; border: 1px solid #bbf7d0; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.04); margin-top: 8px;'>"
        "<table style='width:100%; border-collapse:collapse; font-size:0.88rem; text-align:left;'>"
        "<thead style='position:sticky; top:0; background:#f0fdf4; border-bottom:2px solid #bbf7d0; z-index:1;'>"
        "<tr style='color:#166534; font-weight:700;'>"
        "<th style='padding:10px 14px;'>Destination</th>"
        "<th style='padding:10px 14px;'>Arrival Station</th>"
        "<th style='padding:10px 14px;'>Travel Time</th>"
        "<th style='padding:10px 14px;'>Train Category</th>"
        "<th style='padding:10px 14px;'>Frequency / Trains</th>"
        "<th style='padding:10px 14px; text-align:center;'>Wishlist</th>"
        "<th style='padding:10px 14px; text-align:center;'>Prio Thorsten</th>"
        "<th style='padding:10px 14px; text-align:center;'>Review Score</th>"
        "</tr>"
        "</thead>"
        f"<tbody>{''.join(train_rows_html)}</tbody>"
        "</table>"
        "</div>"
    )
    if hasattr(st, "html"):
        st.html(full_train_table_html)
    else:
        st.markdown(full_train_table_html, unsafe_allow_html=True)
