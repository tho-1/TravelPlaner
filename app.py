import re

import streamlit as st

from data_utils import (
    DATA_PATH,
    load_destinations,
    load_open_destinations,
    save_open_destinations,
)
from environment import is_cloud_mode, is_local_mode
from pages.destination_detail import render_destination
from pages.itinerary import render_itinerary, render_sidebar_trips
from pages.overview import render_overview
from pages.weekend_finder import render_weekend_finder
from pages.world_map import render_world_map


def slugify(value: str) -> str:
    value = str(value).strip().lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-")


st.set_page_config(page_title="Travel Planner", page_icon="✈️", layout="wide", initial_sidebar_state="expanded")

# Display environment indicator (local vs cloud)
if is_cloud_mode():
    st.info("☁️ **Cloud Mode** — Changes saved to cloud only", icon="☁️")
elif is_local_mode():
    st.warning("💻 **Local Mode** — Changes saved locally only", icon="💻")

df, metadata = load_destinations(DATA_PATH)
destination_col = metadata["destination_col"]
nearer_col = metadata.get("nearer_col")
all_destinations = [str(v) for v in df[destination_col].dropna().astype(str).unique()]

favorite_destinations = set()
if nearer_col and nearer_col in df.columns:
    nearer_series = df[nearer_col]
    # .eq(True) rather than `== True`: the column is object dtype (True/"x"),
    # and a bare truthiness test on a Series raises.
    is_fav = nearer_series.eq(True).fillna(False) | nearer_series.astype(str).str.lower().str.contains("x", na=False)
    favorite_destinations = set(df.loc[is_fav, destination_col].dropna().astype(str).unique())

if "open_destinations" not in st.session_state:
    # Initially re-open the last opened tabs (persisted to disk), falling back
    # to all favorites on first run.
    persisted = [d for d in load_open_destinations() if d in all_destinations]
    st.session_state["open_destinations"] = persisted or list(favorite_destinations)

open_destinations = st.session_state["open_destinations"]

# Pre-register a page for every destination. Pages for destinations that have
# not been opened yet are hidden from the navigation menu but remain reachable
# via st.switch_page. Once a destination is opened, its page becomes visible so
# it shows up as its own labeled navigation entry.
detail_pages = {}
detail_urls = {}
used_slugs = set()
for dest in all_destinations:
    slug = slugify(dest)
    base_slug = slug
    counter = 1
    while slug in used_slugs:
        counter += 1
        slug = f"{base_slug}-{counter}"
    used_slugs.add(slug)

    url_path = f"destination-{slug}"
    detail_urls[dest] = url_path
    visibility = "visible" if dest in open_destinations else "hidden"
    icon = "⭐" if dest in favorite_destinations else "📍"
    detail_pages[dest] = st.Page(
        lambda d=dest: render_destination(d),
        title=dest,
        url_path=url_path,
        icon=icon,
        visibility=visibility,
    )

# Expose the page objects and urls so overview and map pages can navigate on click.
st.session_state["_detail_pages"] = detail_pages
st.session_state["_detail_urls"] = detail_urls

world_map_page = st.Page(render_world_map, title="World Map", icon="🌍", default=True)
overview_page = st.Page(render_overview, title="Overview", icon="🗺️")
itinerary_page = st.Page(render_itinerary, title="Itinerary Planner", icon="🧭",
                         url_path="itinerary")
weekend_page = st.Page(render_weekend_finder, title="Weekend Finder", icon="🗓️",
                       url_path="weekend-finder")

# Expose the overview/map page objects so detail pages can switch back on close.
st.session_state["_overview_page"] = overview_page
st.session_state["_world_map_page"] = world_map_page

pages = ([world_map_page, overview_page, itinerary_page, weekend_page]
         + list(detail_pages.values()))

# Hide the built-in nav menu and render a custom sidebar instead, so every open
# destination tab can have its own close (✖) button next to it.
pg = st.navigation(pages, position="hidden")

with st.sidebar:
    st.html(
        """
        <style>
        /* Open destination tabs: match the tight spacing of the World Map /
           Overview links (they sit ~4px apart). The sidebar's vertical block
           adds a 16px row-gap between tabs, so we wrap the tabs in their own
           keyed container, zero its gap, and compress the column margins. */
        [data-testid="stSidebar"] .st-key-open_tabs {
            row-gap: 0px !important;
            padding-top: 0px !important;
            padding-bottom: 0px !important;
        }
        [data-testid="stSidebar"] .st-key-open_tabs [data-testid="stColumn"] {
            margin-top: -2px !important;
            margin-bottom: -2px !important;
        }
        [data-testid="stSidebar"] .st-key-open_tabs [data-testid="stColumn"] > div {
            justify-content: center !important;
        }
        [data-testid="stSidebar"] .st-key-open_tabs [data-testid="stHorizontalBlock"] {
            margin-top: 0px !important;
            margin-bottom: 0px !important;
        }
        /* Travel Itineraries list: keep each trip (button + stats caption)
           visually together with minimal gaps between rows. */
        [data-testid="stSidebar"] .st-key-itin_trips {
            row-gap: 2px !important;
            padding-top: 0px !important;
            padding-bottom: 0px !important;
        }
        [data-testid="stSidebar"] .st-key-itin_trips [data-testid="stVerticalBlock"] {
            row-gap: 2px !important;
        }
        </style>
        """
    )
    st.markdown("### ✈️ Travel Planner")
    st.page_link(world_map_page, width="stretch")
    st.page_link(overview_page, width="stretch")
    st.page_link(itinerary_page, width="stretch")
    st.page_link(weekend_page, width="stretch")
    st.markdown("---")

    if open_destinations:
        st.markdown("**Open destinations**")
        current_url = pg.url_path
        with st.container(key="open_tabs"):
            for dest in list(open_destinations):
                if dest not in detail_pages:
                    continue
                dest_url = detail_urls[dest]
                col_link, col_close = st.columns([5, 1], vertical_alignment="center")
                with col_link:
                    st.page_link(detail_pages[dest], width="stretch")
                with col_close:
                    if st.button("✖", key=f"close_nav_{dest}", help=f"Close {dest} tab", type="tertiary"):
                        if dest in open_destinations:
                            open_destinations.remove(dest)
                            st.session_state["open_destinations"] = open_destinations
                            save_open_destinations(open_destinations)
                        if current_url == dest_url:
                            st.switch_page(overview_page)
                        else:
                            st.rerun()
    else:
        st.caption("No open destinations")

    st.markdown("---")
    render_sidebar_trips(pg, itinerary_page)

    # One-click copy of the live workbook: cloud edits live on an ephemeral
    # container, so a downloadable backup prevents losing them to a redeploy.
    try:
        st.download_button(
            "⬇ Download workbook",
            data=DATA_PATH.read_bytes(),
            file_name=DATA_PATH.name,
            mime="application/vnd.openxmlformats-officedocument"
                 ".spreadsheetml.sheet",
            help="Save a copy of the current destinations workbook "
                 "(recommended before reinstalls or redeploys)",
        )
    except OSError as exc:
        st.caption(f"Workbook download unavailable: {exc}")

    try:
        from sync.ui import render_sync_sidebar

        render_sync_sidebar()
    except Exception as exc:
        st.caption(f"Sync unavailable: {exc}")

pg.run()
