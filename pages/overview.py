import html

import streamlit as st
import pandas as pd

from data_utils import DATA_PATH, WorkbookLockedError, add_new_destination, load_destinations
from deepseek_populator import add_destination_with_deepseek
from pages.world_map import COUNTRY_ISO3_MAP


@st.dialog("➕ Add New Destination")
def _show_add_destination_dialog():
    st.write("Enter the details for the new destination to append to **Destinations.xlsx**:")
    st.warning(
        "This creates a clearly marked placeholder. Only the destination, country, "
        "and continent are saved; all other fields remain blank until researched."
    )
    new_dest = st.text_input("Destination / City Name *", placeholder="e.g. Kyoto, Porto, Queenstown")
    new_country = st.text_input("Country *", placeholder="e.g. Japan, Portugal, New Zealand")
    new_continent = st.selectbox(
        "Continent",
        options=["Asia", "Europe", "North America", "South America", "Africa", "Oceania", "Unknown"],
        index=0
    )

    add_mode = st.radio(
        "How should the new destination be added?",
        options=["Add placeholder only", "Add & auto-populate with DeepSeek AI"],
        index=0,
        help=(
            "**Add placeholder only**: creates a row with just the destination, country, "
            "and continent; everything else stays blank until researched.\n\n"
            "**Add & auto-populate with DeepSeek AI**: also calls the DeepSeek API to fill "
            "in the full profile (details, reviews, and monthly climate) for the new destination."
        ),
    )

    retry_key = "add_destination_retry_pending"

    def _attempt_add():
        if not new_dest.strip():
            st.error("Please enter a destination name.")
            return
        if not new_country.strip():
            st.error("Please enter a country name.")
            return

        try:
            if add_mode == "Add placeholder only":
                success, msg = add_new_destination(new_dest, new_country, new_continent)
            else:
                with st.spinner(
                    "Calling the DeepSeek API to generate the destination profile "
                    "(details, reviews, climate)..."
                ):
                    success, msg = add_destination_with_deepseek(
                        new_dest, new_country, new_continent
                    )
        except WorkbookLockedError:
            st.session_state[retry_key] = True
            return
        except Exception as exc:
            st.error(f"Could not add the destination: {exc}")
            return

        st.session_state.pop(retry_key, None)
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

    if st.button("Save Destination", type="primary", width="stretch"):
        _attempt_add()

    if st.session_state.get(retry_key):
        st.error(
            "**Destinations.xlsx is currently open in another program** (e.g. Excel). "
            "Please close the file and press **Retry**."
        )
        if st.button("Retry", type="primary", width="stretch"):
            _attempt_add()


def render_overview():
    df, metadata = load_destinations(DATA_PATH)

    if df.empty:
        st.warning("No destinations found in the workbook.")
        return

    destination_col = metadata["destination_col"]
    country_col = metadata.get("country_col")
    continent_col = metadata["continent_col"]
    eu_col = metadata["eu_col"]
    nearer_col = metadata["nearer_col"]
    visited_col = metadata.get("visited_col")
    safety_col = metadata["safety_col"]
    cost_col = metadata["cost_col"]
    reviews_col = metadata.get("reviews_col")
    month_columns = metadata.get("month_columns", [])

    st.title("Travel destinations overview")
    st.caption("Filter the catalog and click a destination to open its own detail tab.")

    st.markdown("---")
    btn_col1, btn_col2, _ = st.columns([1.5, 1.8, 4])
    with btn_col1:
        if st.button("⭐ Show favorites", help="Opens a detail tab for every destination marked with an 'x' in 'In näherer Auswahl 2025?'.", width="stretch"):
            if nearer_col:
                nearer_series = df[nearer_col]
                is_fav = (nearer_series == True) | nearer_series.astype(str).str.lower().str.contains("x", na=False)
                favorites = df.loc[is_fav, destination_col].astype(str).tolist()
            else:
                favorites = []
            if favorites:
                open_destinations = st.session_state.get("open_destinations", [])
                for destination_name in favorites:
                    if destination_name not in open_destinations:
                        open_destinations.append(destination_name)
                st.session_state["open_destinations"] = open_destinations
                st.rerun()
            else:
                st.info("No favorites found (no destination has an 'x' in 'In näherer Auswahl 2025?').")

    with btn_col2:
        if st.button("➕ Add New Destination", help="Add a new destination to the Excel database.", width="stretch"):
            _show_add_destination_dialog()

    def _month_sort_key(label: str) -> int:
        normalized = label.strip().lower()
        month_aliases = {
            1: ["jan", "january", "januar", "jänner", "janvier"],
            2: ["feb", "february", "februar", "fevrier"],
            3: ["mar", "march", "märz", "mars"],
            4: ["apr", "april", "avril"],
            5: ["may", "mai", "mai"],
            6: ["jun", "june", "juni", "juin"],
            7: ["jul", "july", "juli", "juillet"],
            8: ["aug", "august", "août"],
            9: ["sep", "sept", "september", "septembre"],
            10: ["oct", "october", "oktober", "octobre"],
            11: ["nov", "november"],
            12: ["dec", "december", "dezember", "décembre"],
        }
        for index, aliases in month_aliases.items():
            if any(alias in normalized for alias in aliases):
                return index
        return 13

    with st.container():
        f_col1, f_col2, f_col3 = st.columns(3)

        with f_col1:
            continent_options = ["All"] + sorted([str(value) for value in df[continent_col].dropna().astype(str).unique()])
            selected_continent = st.selectbox("Continent", continent_options)

        with f_col2:
            if country_col and country_col in df.columns:
                country_df = df
                if selected_continent != "All":
                    country_df = df[df[continent_col].astype(str).str.lower() == selected_continent.lower()]
                country_options = ["All"] + sorted([str(value) for value in country_df[country_col].dropna().astype(str).unique()])
                selected_country = st.selectbox("Country", country_options)
            else:
                selected_country = "All"

        with f_col3:
            eu_filter = st.selectbox("EU?", ["All", "Yes", "No"])

        f_col4, f_col5, f_col6 = st.columns(3)

        with f_col4:
            month_options = ["None"]
            if month_columns:
                ordered_months = sorted([str(col) for col in month_columns], key=_month_sort_key)
                month_options += ordered_months
            selected_weather_month = st.selectbox("Weather at least ok in", month_options)

        with f_col5:
            safety_min = 0.0
            safety_max = 5.0
            if safety_col and pd.notna(df[safety_col]).any():
                safety_min = float(df[safety_col].dropna().min())
                safety_max = float(df[safety_col].dropna().max())
            min_safety = st.slider("Minimum safety rating", min_value=float(safety_min), max_value=float(safety_max), value=float(safety_min))

        with f_col6:
            review_min = 0.0
            review_max = 10.0
            if reviews_col and reviews_col in df.columns and pd.notna(df[reviews_col]).any():
                review_min = float(df[reviews_col].dropna().min())
                review_max = float(df[reviews_col].dropna().max())
            min_review = st.slider("Minimum review score", min_value=float(review_min), max_value=float(review_max), value=float(review_min))

        if visited_col and visited_col in df.columns:
            with st.container():
                only_unvisited = st.checkbox("Only show unvisited", value=True)
        else:
            only_unvisited = False

    filtered = df.copy()
    if selected_continent != "All":
        filtered = filtered[filtered[continent_col].astype(str).str.lower() == selected_continent.lower()]
    if country_col and country_col in df.columns and selected_country != "All":
        filtered = filtered[filtered[country_col].astype(str).str.lower() == selected_country.lower()]
    if eu_col:
        eu_values = filtered[eu_col].astype(str).str.strip().str.lower()
        is_eu = eu_values.isin(["true", "yes", "ja", "y", "1", "eu", "european union"])
        if eu_filter == "Yes":
            filtered = filtered[is_eu]
        elif eu_filter == "No":
            filtered = filtered[~is_eu]

    if selected_weather_month and selected_weather_month != "None":
        weather_values = filtered[selected_weather_month].astype(str).str.strip().str.lower()
        keep = weather_values.isin(["ok", "okay", "good", "great", "ideal", "best", "green"])
        filtered = filtered[keep]

    if safety_col:
        filtered = filtered[filtered[safety_col] >= min_safety]

    if reviews_col and reviews_col in filtered.columns:
        filtered = filtered[filtered[reviews_col] >= min_review]

    if only_unvisited and visited_col and visited_col in filtered.columns:
        is_visited = filtered[visited_col].eq(True).fillna(False)
        filtered = filtered[~is_visited]

    if filtered.empty:
        st.info("No destinations match the current filters.")
        return

    if country_col and country_col in filtered.columns:
        filtered = filtered.assign(
            _country_sort=filtered[country_col].astype(str).str.lower(),
            _dest_sort=filtered[destination_col].astype(str).str.lower(),
        ).sort_values(by=["_country_sort", "_dest_sort"]).drop(columns=["_country_sort", "_dest_sort"])
    else:
        filtered = filtered.assign(_dest_sort=filtered[destination_col].astype(str).str.lower()).sort_values(by=["_dest_sort"]).drop(columns=["_dest_sort"])
    detail_pages = st.session_state.get("_detail_pages", {})

    # ── Group destinations by country ──────────────────────────────────────
    # Destinations are already sorted by country, then name. Each country gets
    # a colored header and the destination buttons are tinted with an
    # alternating background color per country so the groups are easy to scan.
    group_tints = ["#f3f7fc", "#f5f5f5"]   # light blue + light grey shading
    group_accents = ["#cfe0f4", "#cfcfcf"] # matching soft left accents / header bars

    if country_col and country_col in filtered.columns:
        groups = filtered.groupby(country_col, sort=False, dropna=False)
    else:
        groups = [(None, filtered)]

    dest_counter = 0
    for group_index, (country, group_rows) in enumerate(groups):
        tint = group_tints[group_index % len(group_tints)]
        accent = group_accents[group_index % len(group_accents)]
        marker_id = f"overview_group_marker_{group_index}"

        # Scope the tint to ONLY this group's buttons. Each group is preceded by
        # an invisible marker div; the :has() selector finds the marker's
        # stElementContainer (a direct child of the vertical block) and the ~
        # combinator tints only the buttons that follow it in this group.
        st.markdown(
            f"""
            <style>
                div.stElementContainer:has(div[id="{marker_id}"]) {{ display: none; }}
                div.stElementContainer:has(div[id="{marker_id}"]) ~ div div[data-testid="stButton"] button {{
                    background-color: {tint};
                    border-left: 5px solid {accent};
                }}
                div.stElementContainer:has(div[id="{marker_id}"]) ~ div div[data-testid="stButton"] button:hover {{
                    background-color: {accent}22;
                }}
            </style>
            """,
            unsafe_allow_html=True,
        )
        st.markdown(f'<div id="{marker_id}"></div>', unsafe_allow_html=True)

        country_name = "" if pd.isna(country) else str(country).strip()
        if country_name:
            st.markdown(
                f"""
                <div style="margin:16px 0 6px 0; padding:7px 14px; border-radius:10px;
                            background:{tint}; border-left:5px solid {accent};
                            font-weight:700; color:#1f2937; font-size:1.05rem;">
                    {html.escape(country_name)}
                    <span style="font-weight:400; color:#6b7280; font-size:0.85rem;">({len(group_rows)})</span>
                </div>
                """,
                unsafe_allow_html=True,
            )

        # Destinations in a 3-column grid within each country group.
        group_items = list(group_rows.iterrows())
        for row_start in range(0, len(group_items), 3):
            chunk = group_items[row_start:row_start + 3]
            cols = st.columns(3)
            for col_offset, (_, row) in enumerate(chunk):
                with cols[col_offset]:
                    destination_name = str(row[destination_col])
                    if st.button(destination_name, key=f"dest_{dest_counter}_{destination_name}", width="stretch"):
                        open_destinations = st.session_state.get("open_destinations", [])
                        if destination_name not in open_destinations:
                            open_destinations.append(destination_name)
                            st.session_state["open_destinations"] = open_destinations
                        target_page = detail_pages.get(destination_name)
                        if target_page is not None:
                            st.switch_page(target_page)
                    dest_counter += 1
