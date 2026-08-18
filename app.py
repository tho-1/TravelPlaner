import re

import streamlit as st

from data_utils import DATA_PATH, load_destinations
from pages.destination_detail import render_destination
from pages.info import render_info
from pages.overview import render_overview
from pages.world_map import render_world_map


def slugify(value: str) -> str:
    value = str(value).strip().lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-")


st.set_page_config(page_title="Travel Planner", page_icon="✈️", layout="wide", initial_sidebar_state="expanded")

df, metadata = load_destinations(DATA_PATH)
destination_col = metadata["destination_col"]
nearer_col = metadata.get("nearer_col")
all_destinations = [str(v) for v in df[destination_col].dropna().astype(str).unique()]

favorite_destinations = set()
if nearer_col and nearer_col in df.columns:
    nearer_series = df[nearer_col]
    is_fav = (nearer_series == True) | nearer_series.astype(str).str.lower().str.contains("x", na=False)
    favorite_destinations = set(df.loc[is_fav, destination_col].dropna().astype(str).unique())

if "open_destinations" not in st.session_state:
    # Initially re-open all favorites in tabs
    st.session_state["open_destinations"] = list(favorite_destinations)

open_destinations = st.session_state["open_destinations"]

# Pre-register a page for every destination. Pages for destinations that have
# not been opened yet are hidden from the navigation menu but remain reachable
# via st.switch_page. Once a destination is opened, its page becomes visible so
# it shows up as its own labeled navigation entry.
detail_pages = {}
used_slugs = set()
for dest in all_destinations:
    slug = slugify(dest)
    base_slug = slug
    counter = 1
    while slug in used_slugs:
        counter += 1
        slug = f"{base_slug}-{counter}"
    used_slugs.add(slug)

    visibility = "visible" if dest in open_destinations else "hidden"
    icon = "⭐" if dest in favorite_destinations else "📍"
    detail_pages[dest] = st.Page(
        lambda d=dest: render_destination(d),
        title=dest,
        url_path=f"destination-{slug}",
        icon=icon,
        visibility=visibility,
    )

# Expose the page objects so the overview and map pages can switch to them on click.
st.session_state["_detail_pages"] = detail_pages

world_map_page = st.Page(render_world_map, title="World Map", icon="🌍", default=True)
overview_page = st.Page(render_overview, title="Overview", icon="🗺️")
info_page = st.Page(render_info, title="How to use", icon="ℹ️")

# Expose the overview/map page objects so detail pages can switch back on close.
st.session_state["_overview_page"] = overview_page
st.session_state["_world_map_page"] = world_map_page

pages = [world_map_page, overview_page, info_page] + list(detail_pages.values())

pg = st.navigation(pages, position="sidebar")
pg.run()
