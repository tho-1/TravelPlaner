import streamlit as st
import pandas as pd

from data_utils import DATA_PATH, add_new_destination, load_destinations
from pages.world_map import COUNTRY_ISO3_MAP


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
    safety_col = metadata["safety_col"]
    cost_col = metadata["cost_col"]
    month_columns = metadata.get("month_columns", [])

    st.title("Travel destinations overview")
    st.caption("Filter the catalog and click a destination to open its own detail tab.")

    st.markdown("---")
    btn_col1, btn_col2, _ = st.columns([1.5, 1.8, 4])
    with btn_col1:
        if st.button("⭐ Show favorites", help="Opens a detail tab for every destination marked with an 'x' in 'In näherer Auswahl 2025?'.", use_container_width=True):
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
        if st.button("➕ Add New Destination", help="Add a new destination to the Excel database.", use_container_width=True):
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
        continent_options = ["All"] + sorted([str(value) for value in df[continent_col].dropna().astype(str).unique()])
        selected_continent = st.selectbox("Continent", continent_options)

        if country_col and country_col in df.columns:
            country_df = df
            if selected_continent != "All":
                country_df = df[df[continent_col].astype(str).str.lower() == selected_continent.lower()]
            country_options = ["All"] + sorted([str(value) for value in country_df[country_col].dropna().astype(str).unique()])
            selected_country = st.selectbox("Country", country_options)
        else:
            selected_country = "All"

        eu_filter = st.selectbox("EU?", ["All", "Yes", "No"])

        month_options = ["None"]
        if month_columns:
            ordered_months = sorted([str(col) for col in month_columns], key=_month_sort_key)
            month_options += ordered_months
        selected_weather_month = st.selectbox("Weather at least ok in", month_options)

        safety_min = 0.0
        safety_max = 5.0
        if safety_col and pd.notna(df[safety_col]).any():
            safety_min = float(df[safety_col].dropna().min())
            safety_max = float(df[safety_col].dropna().max())
        min_safety = st.slider("Minimum safety rating", min_value=float(safety_min), max_value=float(safety_max), value=float(safety_min))

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

    for index, row in filtered.iterrows():
        destination_name = str(row[destination_col])
        label = f"{row[country_col]} - {destination_name}" if country_col and pd.notna(row[country_col]) else destination_name
        if st.button(label, key=f"dest_{index}_{destination_name}", use_container_width=True):
            open_destinations = st.session_state.get("open_destinations", [])
            if destination_name not in open_destinations:
                open_destinations.append(destination_name)
                st.session_state["open_destinations"] = open_destinations
            target_page = detail_pages.get(destination_name)
            if target_page is not None:
                st.switch_page(target_page)
