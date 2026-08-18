import datetime
import html
from typing import Dict, List, Optional, Tuple

import pandas as pd
import plotly.express as px
import streamlit as st

from data_utils import DATA_PATH, add_new_destination, load_destinations, normalize_text


@st.dialog("➕ Add New Destination")
def _show_add_destination_dialog():
    st.write("Enter the details for the new destination to append to **Destinations.xlsx**:")
    new_dest = st.text_input("Destination / City Name *", placeholder="e.g. Kyoto, Porto, Queenstown")
    new_country = st.text_input("Country *", placeholder="e.g. Japan, Portugal, New Zealand")
    new_continent = st.selectbox(
        "Continent",
        options=["Asia", "Europe", "North America", "South America", "Africa", "Oceania", "Unknown"],
        index=0
    )

    if st.button("Save Destination", type="primary", use_container_width=True):
        if not new_dest.strip():
            st.error("Please enter a destination name.")
            return
        if not new_country.strip():
            st.error("Please enter a country name.")
            return

        success, msg = add_new_destination(new_dest, new_country, new_continent)
        if success:
            st.success(msg)
            # Add to open destinations so user can view it immediately
            open_destinations = st.session_state.get("open_destinations", [])
            if new_dest.strip() not in open_destinations:
                open_destinations.append(new_dest.strip())
                st.session_state["open_destinations"] = open_destinations
            st.rerun()
        else:
            st.error(msg)

# Comprehensive Country name / aliases to ISO-3 standard mapping
COUNTRY_ISO3_MAP: Dict[str, str] = {
    "vietnam": "VNM",
    "vn": "VNM",
    "usa": "USA",
    "united states": "USA",
    "united states of america": "USA",
    "us": "USA",
    "china": "CHN",
    "cn": "CHN",
    "colombia": "COL",
    "mexico": "MEX",
    "peru": "PER",
    "chile": "CHL",
    "costa rica": "CRI",
    "poland": "POL",
    "india": "IND",
    "japan": "JPN",
    "estonia": "EST",
    "nepal": "NPL",
    "philippines": "PHL",
    "malaysia": "MYS",
    "norway": "NOR",
    "iceland": "ISL",
    "canada": "CAN",
    "south africa": "ZAF",
    "bolivia": "BOL",
    "puerto rico": "PRI",
    "algeria": "DZA",
    "spain": "ESP",
    "indonesia": "IDN",
    "finland": "FIN",
    "turkey": "TUR",
    "laos": "LAO",
    "uzbekistan": "UZB",
    "thailand": "THA",
    "nicaragua": "NIC",
    "australia": "AUS",
    "greece": "GRC",
    "new zealand": "NZL",
    "cyprus": "CYP",
    "france": "FRA",
    "united kingdom": "GBR",
    "uk": "GBR",
    "qatar": "QAT",
    "papua new guinea": "PNG",
    "bangladesh": "BGD",
    "sri lanka": "LKA",
    "austria": "AUT",
    "ecuador": "ECU",
    "paraguay": "PRY",
    "brazil": "BRA",
    "mongolia": "MNG",
    "bosnia and herzegovina": "BIH",
    "romania": "ROU",
    "germany": "DEU",
    "italy": "ITA",
    "portugal": "PRT",
    "switzerland": "CHE",
    "sweden": "SWE",
    "denmark": "DNK",
    "netherlands": "NLD",
    "belgium": "BEL",
    "croatia": "HRV",
    "morocco": "MAR",
    "egypt": "EGY",
    "kenya": "KEN",
    "tanzania": "TZA",
    "argentina": "ARG",
}

# Standardized color map matching the app's design
COLOR_PALETTE = {
    "Ideal": "#2ecc71",
    "Ok": "#f1c40f",
    "Bad": "#e74c3c",
    "Unknown": "#95a5a6",
}

MONTHS = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
]


def _normalize_condition(value: object) -> str:
    """Normalize raw month rating values to standard categories (Ideal, Ok, Bad, Unknown)."""
    if pd.isna(value):
        return "Unknown"
    text = str(value).strip().lower()
    if text in {"ideal", "good", "great", "best", "green"}:
        return "Ideal"
    if text in {"ok", "okay", "medium", "yellow"}:
        return "Ok"
    if text in {"bad", "poor", "red", "worst"}:
        return "Bad"
    return "Unknown"


def _navigate_to_destination(destination_name: str):
    """Add destination to session state and switch to its detail page."""
    open_destinations = st.session_state.get("open_destinations", [])
    if destination_name not in open_destinations:
        open_destinations.append(destination_name)
        st.session_state["open_destinations"] = open_destinations

    detail_pages = st.session_state.get("_detail_pages", {})
    target_page = detail_pages.get(destination_name)
    if target_page is not None:
        st.switch_page(target_page)
    else:
        st.error(f"Page for destination '{destination_name}' could not be found.")


def _extract_clicked_country(map_event, fig, df_map: pd.DataFrame) -> Optional[str]:
    """Robustly extract the country name from a Plotly choropleth click selection event."""
    if not map_event:
        return None

    selection = getattr(map_event, "selection", None)
    if selection is None and isinstance(map_event, dict):
        selection = map_event.get("selection")

    if not selection:
        return None

    points = getattr(selection, "points", None)
    if points is None and isinstance(selection, dict):
        points = selection.get("points")

    if not points or len(points) == 0:
        return None

    pt = points[0]

    # 1. Check customdata directly (first element is Country Name)
    customdata = pt.get("customdata") if isinstance(pt, dict) else getattr(pt, "customdata", None)
    if customdata:
        if isinstance(customdata, (list, tuple)) and len(customdata) > 0:
            return str(customdata[0])
        elif isinstance(customdata, str):
            return customdata

    # 2. Check hovertext
    hovertext = pt.get("hovertext") if isinstance(pt, dict) else getattr(pt, "hovertext", None)
    if hovertext:
        return str(hovertext)

    # 3. Check ISO3 location
    loc = pt.get("location") if isinstance(pt, dict) else getattr(pt, "location", None)
    if loc:
        matched = df_map[df_map["ISO3"] == loc]
        if not matched.empty:
            return str(matched.iloc[0]["Country"])

    # 4. Resolve via curve_number (trace index) and point_index / point_number
    curve_num = pt.get("curve_number") if isinstance(pt, dict) else getattr(pt, "curve_number", None)
    point_idx = pt.get("point_index") if isinstance(pt, dict) else getattr(pt, "point_index", None)
    if point_idx is None:
        point_idx = pt.get("point_number") if isinstance(pt, dict) else getattr(pt, "point_number", None)

    if curve_num is not None and point_idx is not None and curve_num < len(fig.data):
        tr = fig.data[curve_num]
        if hasattr(tr, "customdata") and tr.customdata is not None and point_idx < len(tr.customdata):
            cd = tr.customdata[point_idx]
            if isinstance(cd, (list, tuple, pd.Series)) and len(cd) > 0:
                return str(cd[0])
            return str(cd)
        if hasattr(tr, "hovertext") and tr.hovertext is not None and point_idx < len(tr.hovertext):
            return str(tr.hovertext[point_idx])
        if hasattr(tr, "locations") and tr.locations is not None and point_idx < len(tr.locations):
            iso = tr.locations[point_idx]
            matched = df_map[df_map["ISO3"] == iso]
            if not matched.empty:
                return str(matched.iloc[0]["Country"])

    return None


def render_world_map():
    st.title("🌍 World Map")
    st.caption("Click any country on the map (or select one below) to view its cities and open their full travel details.")

    df, metadata = load_destinations(DATA_PATH)
    if df.empty:
        st.warning("No destination data available.")
        return

    destination_col = metadata.get("destination_col", "Destination")
    country_col = metadata.get("country_col", "Country")
    continent_col = metadata.get("continent_col", "Continent")
    eu_col = metadata.get("eu_col")
    safety_col = metadata.get("safety_col", "Safety Rating")
    cost_col = metadata.get("cost_col", "Avg. Cost/Day")
    month_columns = metadata.get("month_columns", MONTHS)

    # Clean rows that have destination and country
    df_valid = df[df[destination_col].notna() & df[country_col].notna()].copy()
    if df_valid.empty:
        st.warning("No destinations with country data found.")
        return

    # Select month - default to current month
    current_month_index = max(0, min(11, datetime.date.today().month - 1))

    col_select, col_btn = st.columns([3, 1.2])
    with col_select:
        selected_month = st.selectbox(
            "📅 Select Month",
            options=MONTHS,
            index=current_month_index,
            key="world_map_selected_month"
        )
    with col_btn:
        st.write("")
        st.write("")
        if st.button("➕ Add New Destination", help="Add a new destination to the Excel database.", use_container_width=True):
            _show_add_destination_dialog()

    # ── Collapsible filter panel ────────────────────────────────────────────
    with st.expander("🔍 Filters", expanded=False):
        f_col1, f_col2, f_col3 = st.columns(3)

        with f_col1:
            continent_options = ["All"] + sorted(
                str(v) for v in df_valid[continent_col].dropna().astype(str).unique()
            ) if continent_col and continent_col in df_valid.columns else ["All"]
            map_continent = st.selectbox("Continent", continent_options, key="map_filter_continent")

        with f_col2:
            if country_col and country_col in df_valid.columns:
                _country_base = df_valid if map_continent == "All" else df_valid[
                    df_valid[continent_col].astype(str).str.lower() == map_continent.lower()
                ]
                country_options = ["All"] + sorted(
                    str(v) for v in _country_base[country_col].dropna().astype(str).unique()
                )
            else:
                country_options = ["All"]
            map_country = st.selectbox("Country", country_options, key="map_filter_country")

        with f_col3:
            map_eu = st.selectbox("EU?", ["All", "Yes", "No"], key="map_filter_eu")

        f_col4, f_col5 = st.columns(2)

        with f_col4:
            ordered_months = sorted(
                [str(c) for c in month_columns],
                key=lambda lbl: next(
                    (i for i, aliases in {
                        1: ["jan"], 2: ["feb"], 3: ["mar"], 4: ["apr"],
                        5: ["may", "mai"], 6: ["jun"], 7: ["jul"], 8: ["aug"],
                        9: ["sep"], 10: ["oct"], 11: ["nov"], 12: ["dec"]
                    }.items() if any(a in lbl.strip().lower() for a in aliases)),
                    13
                )
            )
            map_weather_month = st.selectbox(
                "Weather at least ok in",
                ["None"] + ordered_months,
                key="map_filter_weather_month"
            )

        with f_col5:
            if safety_col and safety_col in df_valid.columns and pd.notna(df_valid[safety_col]).any():
                s_min = float(df_valid[safety_col].dropna().min())
                s_max = float(df_valid[safety_col].dropna().max())
                map_min_safety = st.slider(
                    "Minimum safety rating",
                    min_value=s_min, max_value=s_max, value=s_min,
                    key="map_filter_min_safety"
                )
            else:
                map_min_safety = 0.0

    # Apply filters to df_valid
    if map_continent != "All" and continent_col and continent_col in df_valid.columns:
        df_valid = df_valid[df_valid[continent_col].astype(str).str.lower() == map_continent.lower()]
    if map_country != "All" and country_col and country_col in df_valid.columns:
        df_valid = df_valid[df_valid[country_col].astype(str).str.lower() == map_country.lower()]
    if eu_col and eu_col in df_valid.columns and map_eu != "All":
        eu_vals = df_valid[eu_col].astype(str).str.strip().str.lower()
        is_eu = eu_vals.isin(["true", "yes", "ja", "y", "1", "eu", "european union"])
        df_valid = df_valid[is_eu] if map_eu == "Yes" else df_valid[~is_eu]
    if map_weather_month and map_weather_month != "None" and map_weather_month in df_valid.columns:
        wv = df_valid[map_weather_month].astype(str).str.strip().str.lower()
        df_valid = df_valid[wv.isin(["ok", "okay", "good", "great", "ideal", "best", "green"])]
    if safety_col and safety_col in df_valid.columns:
        df_valid = df_valid[df_valid[safety_col] >= map_min_safety]
    # ────────────────────────────────────────────────────────────────────────

    matched_month_col = next(
        (c for c in month_columns if normalize_text(c) == normalize_text(selected_month)),
        None
    )
    if not matched_month_col or matched_month_col not in df_valid.columns:
        matched_month_col = next(
            (c for c in df_valid.columns if normalize_text(c) == normalize_text(selected_month)),
            None
        )

    # Group destinations by Country and compute rating per country
    country_groups = df_valid.groupby(country_col)
    map_rows = []
    destination_breakdown_rows = []
    country_to_destinations: Dict[str, List[dict]] = {}

    for country, group in country_groups:
        country_name = str(country).strip()
        iso_code = COUNTRY_ISO3_MAP.get(
            country_name.lower(),
            country_name.upper() if len(country_name) == 3 else None
        )

        dest_ratings: List[Tuple[str, str]] = []
        dest_info_list: List[dict] = []
        ratings_set = set()

        for _, row in group.iterrows():
            dest_name = str(row[destination_col]).strip()
            raw_rating = row.get(matched_month_col) if matched_month_col else None
            cond = _normalize_condition(raw_rating)
            dest_ratings.append((dest_name, cond))
            ratings_set.add(cond)

            dest_entry = {
                "Destination": dest_name,
                "Country": country_name,
                "Month": selected_month,
                "Travel Condition": cond,
                "Continent": row.get(continent_col, "—"),
                "Safety Rating": row.get(safety_col, "—"),
                "Avg Cost/Day": row.get(cost_col, "—"),
                "Reviews": row.get(metadata.get("reviews_col", "Reviews"), "—"),
                "Population": row.get(metadata.get("population_col", "Population"), "—"),
                "Highlights": row.get(metadata.get("highlights_col", "Highlights"), ""),
            }
            dest_info_list.append(dest_entry)
            destination_breakdown_rows.append(dest_entry)

        country_to_destinations[country_name] = dest_info_list

        # Determine overall country condition: Ideal > Ok > Bad > Unknown
        if "Ideal" in ratings_set:
            overall_condition = "Ideal"
        elif "Ok" in ratings_set:
            overall_condition = "Ok"
        elif "Bad" in ratings_set:
            overall_condition = "Bad"
        else:
            overall_condition = "Unknown"

        # Build clean bullet points for hover tooltip
        formatted_bullets = [f"• {name} ({c})" for name, c in dest_ratings]
        if len(formatted_bullets) <= 5:
            dest_summary = "<br>".join(formatted_bullets)
        else:
            dest_summary = "<br>".join(formatted_bullets[:5]) + f"<br>• +{len(formatted_bullets) - 5} more..."

        if iso_code:
            map_rows.append({
                "Country": country_name,
                "ISO3": iso_code,
                "Condition": overall_condition,
                "Destinations_Count": len(group),
                "Destinations_Summary": dest_summary,
                "SelectedMonth": selected_month,
            })

    df_map = pd.DataFrame(map_rows)
    df_dest_breakdown = pd.DataFrame(destination_breakdown_rows)

    # Condition counts
    ideal_dest_count = sum(1 for r in destination_breakdown_rows if r["Travel Condition"] == "Ideal")
    ok_dest_count = sum(1 for r in destination_breakdown_rows if r["Travel Condition"] == "Ok")
    bad_dest_count = sum(1 for r in destination_breakdown_rows if r["Travel Condition"] == "Bad")
    total_countries = len(df_map)

    # KPI summary cards
    kpi_col1, kpi_col2, kpi_col3, kpi_col4 = st.columns(4)
    with kpi_col1:
        st.metric("Mapped Countries", f"{total_countries}")
    with kpi_col2:
        st.metric("🌟 Ideal Destinations", f"{ideal_dest_count}")
    with kpi_col3:
        st.metric("⚖️ Ok Destinations", f"{ok_dest_count}")
    with kpi_col4:
        st.metric("⚠️ Bad / Off-season", f"{bad_dest_count}")

    # Build Choropleth figure
    if not df_map.empty:
        fig = px.choropleth(
            df_map,
            locations="ISO3",
            locationmode="ISO-3",
            color="Condition",
            color_discrete_map=COLOR_PALETTE,
            category_orders={"Condition": ["Ideal", "Ok", "Bad", "Unknown"]},
            hover_name="Country",
            custom_data=["Country", "Condition", "Destinations_Count", "Destinations_Summary", "SelectedMonth"],
            title=f"Travel Conditions for {selected_month} — Click any country on the map to display its cities"
        )

        fig.update_traces(
            hovertemplate=(
                "<b>%{customdata[0]}</b><br><br>"
                "<b>Season:</b> %{customdata[1]}<br>"
                "<b>Month:</b> %{customdata[4]}<br>"
                "<b>Cities / Destinations (%{customdata[2]}):</b><br>%{customdata[3]}<br>"
                "<i>Click country to inspect cities</i>"
                "<extra></extra>"
            )
        )

        fig.update_geos(
            showcountries=True,
            countrycolor="#c8d6e5",
            showocean=True,
            oceancolor="#eef2f7",
            showland=True,
            landcolor="#f5f6fa",
            showlakes=True,
            lakecolor="#eef2f7",
            showrivers=False,
            showcoastlines=True,
            coastlinecolor="#c8d6e5",
            projection_type="natural earth"
        )

        fig.update_layout(
            margin=dict(l=0, r=0, t=40, b=0),
            height=560,
            legend_title_text="Travel Condition",
            legend=dict(
                orientation="h",
                yanchor="bottom",
                y=1.02,
                xanchor="right",
                x=1
            )
        )

        map_event = st.plotly_chart(
            fig,
            use_container_width=True,
            on_select="rerun",
            selection_mode="points",
            key="world_map_plotly"
        )

        # Detect clicked country from Plotly selection event
        clicked_country = _extract_clicked_country(map_event, fig, df_map)
        if clicked_country and clicked_country in country_to_destinations:
            if st.session_state.get("active_country") != clicked_country:
                st.session_state["active_country"] = clicked_country
                st.rerun()
        elif map_event:
            # If map selection is cleared/empty, unselect active country
            selection = getattr(map_event, "selection", None)
            if selection is None and isinstance(map_event, dict):
                selection = map_event.get("selection")
            if selection is not None:
                pts = getattr(selection, "points", None)
                if pts is None and isinstance(selection, dict):
                    pts = selection.get("points")
                if pts is not None and len(pts) == 0 and st.session_state.get("active_country") is not None:
                    st.session_state["active_country"] = None
                    st.rerun()

    current_active_country = st.session_state.get("active_country")

    # Show the "Cities in" section ONLY if a country is currently selected
    if current_active_country and current_active_country in country_to_destinations:
        st.markdown("---")

        header_left, header_right = st.columns([5, 1])
        with header_left:
            st.subheader(f"📍 Cities in **{current_active_country}** ({selected_month})")
            st.caption("Click on any city below to open its destination details tab:")
        with header_right:
            if st.button("✖ Clear", key="btn_clear_map_selection", help="Deselect country"):
                st.session_state["active_country"] = None
                st.rerun()

        # Display city cards for the active country
        country_dests = country_to_destinations.get(current_active_country, [])
        if country_dests:
            card_cols = st.columns(min(3, max(1, len(country_dests))))
            for idx, dest_info in enumerate(country_dests):
                city_name = dest_info["Destination"]
                city_cond = dest_info["Travel Condition"]
                badge = "🟢" if city_cond == "Ideal" else ("🟡" if city_cond == "Ok" else "🔴")
                reviews = dest_info.get("Reviews", "—")
                population = dest_info.get("Population", "—")

                with card_cols[idx % len(card_cols)]:
                    with st.container(border=True):
                        st.markdown(f"#### {badge} {city_name}")
                        
                        info_items = []
                        if reviews not in ("—", None, "") and pd.notna(reviews):
                            info_items.append(f"⭐ Reviews: **{reviews}/10**")
                        if population not in ("—", None, "") and pd.notna(population):
                            pop_val = int(population) if isinstance(population, float) and population == int(population) else population
                            info_items.append(f"👥 Population: **{pop_val:,}**" if isinstance(pop_val, (int, float)) else f"👥 Population: **{pop_val}**")
                        if info_items:
                            st.caption(" • ".join(info_items))

                        if st.button(
                            f"View {city_name} Details ➔",
                            key=f"btn_city_{current_active_country}_{city_name}_{idx}",
                            use_container_width=True,
                            type="secondary"
                        ):
                            _navigate_to_destination(city_name)
        st.markdown("---")

    # Complete Clickable Destination Directory
    with st.expander(f"🧳 View All Global Destinations for {selected_month}", expanded=False):
        filter_col1, filter_col2 = st.columns([2, 2])
        with filter_col1:
            condition_filter = st.selectbox(
                "Filter by condition:",
                options=["All Conditions", "🟢 Ideal only", "🟡 Ok only", "🔴 Bad / Off-season only"],
                index=0,
                key="dest_condition_filter"
            )
        with filter_col2:
            search_query = st.text_input("🔍 Search destination or country:", "", key="dest_map_search_input")

        # Apply filters
        filtered_dest_df = df_dest_breakdown.copy()
        if condition_filter == "🟢 Ideal only":
            filtered_dest_df = filtered_dest_df[filtered_dest_df["Travel Condition"] == "Ideal"]
        elif condition_filter == "🟡 Ok only":
            filtered_dest_df = filtered_dest_df[filtered_dest_df["Travel Condition"] == "Ok"]
        elif condition_filter == "🔴 Bad / Off-season only":
            filtered_dest_df = filtered_dest_df[filtered_dest_df["Travel Condition"] == "Bad"]

        if search_query:
            q = search_query.strip().lower()
            filtered_dest_df = filtered_dest_df[
                filtered_dest_df["Destination"].str.lower().str.contains(q)
                | filtered_dest_df["Country"].str.lower().str.contains(q)
            ]

        if filtered_dest_df.empty:
            st.info("No destinations match the selected filter.")
        else:
            filtered_dest_df = filtered_dest_df.sort_values(by=["Country", "Destination"])
            dest_columns = st.columns(3)
            for idx, (_, row) in enumerate(filtered_dest_df.iterrows()):
                d_name = row["Destination"]
                c_name = row["Country"]
                cond = row["Travel Condition"]
                badge = "🟢" if cond == "Ideal" else ("🟡" if cond == "Ok" else "🔴")
                
                button_label = f"{badge} {c_name} — {d_name} ({cond})"
                with dest_columns[idx % 3]:
                    if st.button(button_label, key=f"global_dest_nav_{d_name}_{idx}", use_container_width=True):
                        _navigate_to_destination(d_name)
