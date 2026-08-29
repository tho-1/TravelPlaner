import base64
import html
import io
import re
import unicodedata
from contextlib import nullcontext
from pathlib import Path

from PIL import Image

import pandas as pd
import streamlit as st

from data_utils import (
    DATA_PATH,
    WorkbookLockedError,
    load_destinations,
    save_open_destinations,
    update_comment,
    update_favorite_status,
    update_prio_thorsten,
    update_food,
    update_visited_status,
    update_to_be_researched_status,
)
from deepseek_client import generate_food_profile
from deepseek_populator import populate_existing_destination_with_ai
from unsplash_gallery import (
    build_destination_gallery,
    get_access_key,
    refresh_single_gallery_image,
)
from flight_routes import render_flight_routes_section


def _normalize_picture_key(value: object) -> str:
    """Normalize a destination or file name for picture matching.

    Lowercases, strips accents (San José -> sanjose, Ürümqi -> urumqi), and
    removes all non-alphanumeric characters so spacing/case differences still
    match (e.g. "Mexico city" vs "MexicoCity", "Panama City" vs "PanamaCity").
    Parenthetical disambiguators are dropped first so "San José (Costa Rica)"
    still matches "San José_1.jpg".
    """
    if value is None:
        return ""
    text = str(value)
    text = re.sub(r"\([^)]*\)", "", text)
    text = unicodedata.normalize("NFKD", text)
    text = text.encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^a-z0-9]+", "", text.lower())
    return text


def _country_text(selected_row: pd.Series, metadata: dict) -> str:
    """Return the destination's country as a clean string, or ``""`` if missing."""
    country_col = metadata.get("country_col")
    if not country_col or country_col not in selected_row.index:
        return ""
    raw_country = selected_row[country_col]
    if pd.isna(raw_country) or not str(raw_country).strip():
        return ""
    return str(raw_country).strip()


def _st_key_class(widget_key: str) -> str:
    """Return the CSS class Streamlit applies to a widget's container for a key.

    Streamlit exposes ``st-key-<key>`` as a class on the widget's element
    container, sanitizing the key with
    ``key.trim().replace(/[^a-zA-Z0-9_-]/g, "-")`` (see the frontend
    ``st-key-`` helper). Reproducing that here lets us style a specific widget
    purely via CSS — no JS required.
    """
    return "st-key-" + re.sub(r"[^a-zA-Z0-9_-]", "-", widget_key.strip())


def _footsteps_data_uri(visited: bool) -> str:
    """Base64 data-URI of the footsteps SVG for the given visited state.

    Uses the project's SVG files (``Pictures/footsteps-visited.svg`` = dark
    blue, ``Pictures/footsteps_not-visited.svg`` = pale grey). Falls back to a
    small embedded copy if a file is missing, so the button never renders empty.
    """
    pictures_dir = DATA_PATH.parent / "Pictures"
    filename = "footsteps-visited.svg" if visited else "footsteps_not-visited.svg"
    path = pictures_dir / filename
    if path.exists():
        return "data:image/svg+xml;base64," + base64.b64encode(path.read_bytes()).decode()

    color = "#2563eb" if visited else "#D1D5DB"
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" '
        f'fill="{color}" stroke="{color}" stroke-width="0.8" stroke-linecap="round" '
        'stroke-linejoin="round"><path d="M4 16v-2.38C4 11.5 2.97 10.5 3 8c.03-2.72 1.49-6 4.5-6'
        'C9.37 2 10 3.8 10 5.5c0 3.11-2 5.66-2 8.5v2"/><path d="M20 20v-2.38c0-2.12 1.03-3.12 1-5.62'
        '-.03-2.72-1.49-6-4.5-6C14.63 6 14 7.8 14 9.5c0 3.11 2 5.66 2 8.5v2"/><path d="M16 17h4"/>'
        '<path d="M4 13h4"/></svg>'
    )
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()


def _interpolate_color(start_hex: str, end_hex: str, ratio: float) -> str:
    ratio = max(0.0, min(1.0, ratio))

    def hex_to_rgb(value: str):
        value = value.lstrip("#")
        return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))

    start = hex_to_rgb(start_hex)
    end = hex_to_rgb(end_hex)
    rgb = tuple(int(start[i] + (end[i] - start[i]) * ratio) for i in range(3))
    return "#" + "".join(f"{part:02x}" for part in rgb)


def _metric_color(value: object, mode: str, label: str = "") -> str:
    if pd.isna(value) or str(value).strip() == "" or str(value).strip().lower() in {"nan", "none", "null"}:
        if "prio" in label.lower():
            return "#e74c3c"
        return "#95a5a6"

    if mode == "visa":
        text = str(value).strip().lower()
        if any(token in text for token in ["not at all", "free", "no visa", "visa free", "schengen", "none"]):
            return "#2ecc71"
        if any(token in text for token in ["eta", "etaa", "e-ta", "e ta", "travel authorization"]):
            return "#f1c40f"
        if any(token in text for token in ["required", "visa needed", "need visa", "apply", "approval"]):
            return "#d64545"
        return "#f1c40f"

    try:
        numeric_value = float(value)
    except (TypeError, ValueError):
        return "#2ecc71"

    if mode == "population":
        if numeric_value >= 3.0:
            return "#2ecc71"
        ratio = numeric_value / 3.0
        return _interpolate_color("#d64545", "#2ecc71", ratio)

    if mode == "high":
        ratio = numeric_value / 10.0
        return _interpolate_color("#d64545", "#2ecc71", ratio)

    return "#2ecc71"


def _format_metric_box(label: str, value: object, suffix: str, mode: str, edit_badge: bool = False) -> str:
    is_missing = pd.isna(value) or str(value).strip() == "" or str(value).strip().lower() in {"nan", "none", "null"}

    if is_missing:
        if "prio" in label.lower():
            color = "#e74c3c"
            display = "<span style='color: #e74c3c; font-weight: 700;'>n/a</span>"
        else:
            color = "#95a5a6"
            display = "<span style='color: #95a5a6;'>—</span>"
    elif mode == "visa":
        text = str(value).strip().lower()
        if any(token in text for token in ["not at all", "free", "no visa", "visa free", "schengen", "none"]):
            display = "🙂"
        elif any(token in text for token in ["eta", "etaa", "e-ta", "e ta", "travel authorization"]):
            display = "😐"
        elif any(token in text for token in ["required", "visa needed", "need visa", "apply", "approval"]):
            display = "☹️"
        else:
            display = "😐"
        color = _metric_color(value, mode, label)
    elif mode == "stay":
        # Parse upper bound: "5-10 days" → 10, "1 week" → 7, "2 weeks" → 14
        import re as _re
        raw = str(value).strip().lower()
        upper = None
        # Range like "5-10" or "5 to 10"
        range_m = _re.search(r'(\d+(?:\.\d+)?)\s*[-–to]+\s*(\d+(?:\.\d+)?)', raw)
        if range_m:
            upper = float(range_m.group(2))
        else:
            # Single number
            single_m = _re.search(r'(\d+(?:\.\d+)?)', raw)
            if single_m:
                upper = float(single_m.group(1))
        # Convert weeks/months
        if upper is not None:
            if 'week' in raw:
                upper *= 7
            elif 'month' in raw:
                upper *= 30
        # Color: ≤2 red, 3-4 yellow, 5-7 light green, 8+ green
        if upper is None:
            color = "#95a5a6"
        elif upper <= 2:
            color = "#e74c3c"
        elif upper <= 4:
            color = "#f1c40f"
        elif upper <= 7:
            color = "#2ecc71"
        else:
            color = "#16a34a"
        display = html.escape(str(value).strip())
    else:
        try:
            numeric_value = float(value)
        except (TypeError, ValueError):
            numeric_value = None

        if numeric_value is not None:
            color = _metric_color(numeric_value, mode, label)
            text = f"{numeric_value:.1f}" if numeric_value % 1 else f"{numeric_value:.0f}"
            display = f"{text}{suffix}"
        else:
            color = "#2ecc71"
            display = f"{value}{suffix}"

    edit_icon_html = (
        " <span style='font-size:0.9rem; opacity:0.55; vertical-align:middle;' "
        "title='Click to edit'>✏️</span>"
        if edit_badge else ""
    )

    extra_class = ' class="prio-metric-box"' if edit_badge else ""

    return f"""
    <div{extra_class} style="padding: 12px 14px; border-radius: 10px; border-left: 6px solid {color}; background: #f8f9fb; margin-bottom: 12px;">
        <div style="font-size: 0.8rem; color: #4a5568; margin-bottom: 4px;">{html.escape(label)}</div>
        <div style="font-size: 1.3rem; font-weight: 700; color: #111827;">{display}{edit_icon_html}</div>
    </div>
    """


def _render_comment_toggle(destination_name: str, comment_value: str) -> None:
    """Render the 'Add comment' button next to the favorites button.

    Shown only when there is no saved comment yet. Editing an existing comment
    happens via the "✏️ Edit comment" button that appears next to the comment
    itself (see ``_render_comment_editor``).
    """
    if str(comment_value or "").strip():
        return

    if st.button("💬 Add comment", key=f"comment_add_{destination_name}", help="Add a comment"):
        open_key = f"comment_editor_open_{destination_name}"
        input_key = f"comment_input_{destination_name}"
        st.session_state[open_key] = True
        st.session_state[input_key] = comment_value


def _render_comment_editor(destination_name: str, comment_value: str) -> None:
    """Render the comment section (shown right before the Overview).

    - Editor closed + a comment exists  -> show the saved comment as read-only
      text, so an existing comment is visible when the page opens.
    - Editor open                       -> show the editable box + Save/Cancel.
    - Editor closed + no comment        -> nothing (only the "Add comment"
      button next to the favorites is shown).

    The editable box uses a ``st.form`` so the text area's value is reliably
    captured when the user submits — either by clicking "💾 Save Comment" or by
    pressing Ctrl+Enter. (A plain, session-state-controlled text_area does NOT
    commit typed text before a separate Save button reads it, which made
    comments "disappear".)
    """
    open_key = f"comment_editor_open_{destination_name}"
    input_key = f"comment_input_{destination_name}"
    if not st.session_state.get(open_key, False):
        # Editor closed: display the saved comment as read-only text, if any,
        # with an "Edit comment" button right next to it.
        comment_text_value = str(comment_value or "").strip()
        if comment_text_value:
            display_col, edit_col = st.columns([7, 2])
            with display_col:
                st.markdown(
                    f"""
                    <div style="padding:10px 14px; border-radius:10px; background:#f8f9fb;
                                border-left:4px solid #cfe0f4; margin-bottom:6px;">
                        <div style="font-size:0.8rem; color:#4a5568; margin-bottom:4px;">💬 Comment</div>
                        <div style="color:#111827; white-space:pre-wrap;">{html.escape(comment_text_value)}</div>
                    </div>
                    """,
                    unsafe_allow_html=True,
                )
            with edit_col:
                if st.button("✏️ Edit comment", key=f"comment_pen_{destination_name}", help="Edit comment"):
                    st.session_state[open_key] = True
                    st.session_state[input_key] = comment_value
                    st.rerun()
        return

    cancel_key = f"comment_cancel_{destination_name}"
    lock_key = f"comment_locked_{destination_name}"

    if input_key not in st.session_state:
        st.session_state[input_key] = comment_value

    with st.form(f"comment_form_{destination_name}", border=False, clear_on_submit=False):
        st.text_area(
            "Comment",
            key=input_key,
            placeholder="Write a comment...",
            height=90,
        )
        submitted = st.form_submit_button("💾 Save Comment", type="primary")

    # Cancel must live outside the form (st.button is not allowed inside a form).
    if st.button("Cancel", key=cancel_key):
        st.session_state[open_key] = False
        st.session_state.pop(input_key, None)
        st.rerun()

    def _save(value: str) -> bool:
        try:
            update_comment(destination_name, value)
        except WorkbookLockedError:
            st.session_state[lock_key] = True
            return False
        st.session_state.pop(lock_key, None)
        st.session_state[open_key] = False
        st.session_state.pop(input_key, None)
        return True

    if submitted:
        if _save(st.session_state.get(input_key, "")):
            st.success("Comment saved.")
            st.rerun()

    if st.session_state.get(lock_key):
        st.error(
            "**Destinations.xlsx is currently open in another program** (e.g. Excel). "
            "Please close the file and press **Retry**."
        )
        if st.button("Retry", key=f"comment_retry_{destination_name}"):
            if _save(st.session_state.get(input_key, "")):
                st.rerun()


def _render_food_section(
    destination_name: str,
    dest_title: str,
    selected_row: pd.Series,
    metadata: dict,
    food_spiciness: object,
    food_description: object,
) -> None:
    st.subheader("Food")
    spice_text = f"{float(food_spiciness):g}/10" if pd.notna(food_spiciness) else "—"
    description_text = (
        html.escape(str(food_description).strip())
        if pd.notna(food_description) and str(food_description).strip()
        else "—"
    )
    st.markdown(
        f"""
        <div style="display:flex; gap:2rem; align-items:flex-start; width:100%;">
            <div style="flex:0 0 max-content;">
                <strong>Spiciness</strong><br>{html.escape(spice_text)}
            </div>
            <div style="flex:1 1 auto; min-width:0;">
                <strong>Description</strong><br>{description_text}
            </div>
        </div>
        """,
        unsafe_allow_html=True,
    )

    food_is_populated = (
        pd.notna(food_spiciness)
        or (pd.notna(food_description) and bool(str(food_description).strip()))
    )
    if food_is_populated:
        return

    if st.button("🍜 Populate Food with DeepSeek AI", key=f"food_ai_{destination_name}"):
        try:
            with st.spinner("Asking DeepSeek about the local food..."):
                food_profile = generate_food_profile(
                    dest_title, _country_text(selected_row, metadata)
                )
            update_food(
                destination_name,
                food_profile["spiciness"],
                food_profile["description"],
            )
            st.success("Food information saved.")
            st.rerun()
        except (RuntimeError, WorkbookLockedError) as exc:
            st.error(str(exc))


def render_destination(destination_name: str):
    df, metadata = load_destinations(DATA_PATH)

    if df.empty:
        st.warning("No data available.")
        return

    destination_col = metadata["destination_col"]
    eu_col = metadata["eu_col"]
    nearer_col = metadata["nearer_col"]
    visited_col = metadata.get("visited_col")
    to_be_researched_col = metadata.get("to_be_researched_col")
    safety_col = metadata["safety_col"]
    cost_col = metadata["cost_col"]
    flight_col = metadata["flight_col"]
    population_col = metadata["population_col"]
    reviews_col = metadata.get("reviews_col")
    prio_col = metadata.get("prio_col")
    visa_requirement_col = metadata.get("visa_requirement_col")
    highlights_col = metadata["highlights_col"]
    intro_col = metadata.get("intro_col")
    why_col = metadata.get("why_col")
    expect_col = metadata.get("expect_col")
    tourist_reviews_col = metadata.get("tourist_reviews_col")
    malaria_risk_col = metadata.get("malaria_risk_col")
    food_spiciness_col = metadata.get("food_spiciness_col")
    food_description_col = metadata.get("food_description_col")
    status_col = metadata.get("status_col")
    comment_col = metadata.get("comment_col")
    month_columns = metadata["month_columns"]

    matches = df[df[destination_col].astype(str).str.strip().str.lower() == str(destination_name).strip().lower()]
    if matches.empty:
        st.warning(f"Destination '{destination_name}' could not be found.")
        return

    selected_row = matches.iloc[0]
    dest_title = str(selected_row[destination_col])

    open_destinations = st.session_state.get("open_destinations", [])
    if dest_title not in open_destinations:
        open_destinations.append(dest_title)
        st.session_state["open_destinations"] = open_destinations
        save_open_destinations(open_destinations)

    # Load the saved comment (used by the header toggle and the comment editor).
    comment_value = ""
    if comment_col and comment_col in selected_row.index:
        comment_raw = selected_row[comment_col]
        if pd.notna(comment_raw) and str(comment_raw).strip():
            comment_value = str(comment_raw).strip()

    if status_col and status_col in selected_row.index:
        raw_status = selected_row[status_col]
        is_status_missing = (
            pd.isna(raw_status)
            or str(raw_status).strip() == ""
            or str(raw_status).strip().lower() in {"nan", "none", "null"}
        )
        if not is_status_missing:
            status_text = str(raw_status).strip()
            st.warning(
                f"{status_text}. The details below are incomplete until this destination is researched."
            )

            ai_lock_key = f"ai_populate_locked_{destination_name}"

            def _run_ai_populate():
                country = _country_text(selected_row, metadata)
                continent_raw = None
                continent_col = metadata.get("continent_col")
                if continent_col and continent_col in selected_row.index:
                    continent_raw = selected_row[continent_col]
                continent = (
                    str(continent_raw).strip()
                    if pd.notna(continent_raw) and str(continent_raw).strip()
                    else "Unknown"
                )
                try:
                    with st.spinner("Calling the DeepSeek API to populate this destination..."):
                        success, msg = populate_existing_destination_with_ai(
                            destination_name, country, continent
                        )
                except WorkbookLockedError:
                    st.session_state[ai_lock_key] = True
                    return
                except Exception as exc:
                    st.error(f"Could not populate the destination: {exc}")
                    return
                st.session_state.pop(ai_lock_key, None)
                if success:
                    st.success(msg)
                    st.rerun()
                else:
                    st.error(msg)

            if st.button(
                "✨ Populate with DeepSeek AI",
                key=f"ai_populate_{destination_name}",
                type="primary",
                help=(
                    "Fills in the missing details, reviews, and monthly climate for "
                    "this destination using the DeepSeek API."
                ),
            ):
                _run_ai_populate()

            if st.session_state.get(ai_lock_key):
                st.error(
                    "**Destinations.xlsx is currently open in another program** (e.g. Excel). "
                    "Please close the file and press **Retry**."
                )
                if st.button(
                    "Retry", key=f"ai_populate_retry_{destination_name}", type="primary"
                ):
                    _run_ai_populate()

    # Check for destination picture in Pictures directory (e.g. Medellin_1.jpg).
    # Matching is accent/case/spacing-insensitive so "Mexico city" picks up
    # "MexicoCity_1.jpg", "San José (Costa Rica)" picks up "San José_1.jpg", etc.
    pictures_dir = DATA_PATH.parent / "Pictures"
    image_path = None
    if pictures_dir.exists():
        candidate_bases = {
            _normalize_picture_key(dest_title),
            _normalize_picture_key(destination_name),
        }

        def _picture_rank(path: Path) -> int:
            """Rank candidate banner photos (lower = preferred).

            Prefer .jpg/.jpeg over .png/other formats so the pick is
            deterministic when a destination has several matching files
            (e.g. both Yogyakarta_1.jpg and Yogyakarta_1.png exist).
            """
            ext = path.suffix.lower()
            if ext in {".jpg", ".jpeg"}:
                return 0
            if ext == ".png":
                return 1
            return 2

        existing_files = {f.name: f for f in pictures_dir.iterdir() if f.is_file()}
        matches = [
            path for name, path in existing_files.items()
            if any(
                _normalize_picture_key(Path(name).stem) in {base, base + "1"}
                for base in candidate_bases
            )
        ]
        if matches:
            image_path = min(matches, key=_picture_rank)

    if image_path is None:
        # No local picture: fall back to the first image from the Unsplash
        # gallery at the bottom of the page (cache is reused, no extra API call).
        gallery_entries = build_destination_gallery(
            dest_title, country=_country_text(selected_row, metadata), pictures_dir=pictures_dir
        )
        if gallery_entries:
            first_path = gallery_entries[0].get("image_path")
            if first_path and Path(first_path).exists():
                image_path = Path(first_path)

    if image_path:
        # Load and encode image as base64 for full-width CSS banner container
        img_base64 = ""
        try:
            with Image.open(image_path) as pil_img:
                w, h = pil_img.size
                # Panoramic crop (e.g. 3.2:1 aspect ratio)
                new_h = int(w / 3.2) if w > h else h
                if new_h < h:
                    top = (h - new_h) // 2
                    pil_img = pil_img.crop((0, top, w, top + new_h))
                
                buffered = io.BytesIO()
                pil_img.save(buffered, format="JPEG", quality=90)
                img_base64 = base64.b64encode(buffered.getvalue()).decode()
        except Exception:
            img_base64 = ""

        # Header action-button state: Favorite (heart), Research (question mark)
        # and Visited (footsteps). The old "✖ Close tab" button was removed —
        # closing a tab now happens directly on the sidebar tab list.
        is_favorite = False
        if nearer_col and nearer_col in selected_row:
            val = selected_row[nearer_col]
            if pd.notna(val):
                val_str = str(val).strip().lower()
                if val is True or "x" in val_str or val_str in {"yes", "y", "true", "1", "ja", "j"}:
                    is_favorite = True

        is_to_be_researched = False
        if to_be_researched_col and to_be_researched_col in selected_row:
            val = selected_row[to_be_researched_col]
            if pd.notna(val):
                if isinstance(val, bool):
                    is_to_be_researched = val
                elif isinstance(val, (int, float)):
                    is_to_be_researched = (val == 1)
                else:
                    val_str = str(val).strip().lower()
                    is_to_be_researched = val_str in {"yes", "y", "true", "1", "1.0", "ja", "j", "x"} or "x" in val_str

        q_mark = " ❓" if is_to_be_researched else ""

        is_visited = False
        if visited_col:
            visited_value = selected_row.get(visited_col)
            if pd.notna(visited_value):
                if isinstance(visited_value, bool):
                    is_visited = visited_value
                elif isinstance(visited_value, (int, float)):
                    is_visited = (visited_value == 1)
                else:
                    v_str = str(visited_value).strip().lower()
                    is_visited = v_str in {"true", "yes", "y", "1", "1.0", "ja", "j", "x"} or "x" in v_str

        def _render_header_buttons(*columns):
            """Render the header action buttons (fav / research / visited /
            add-comment).

            When `columns` is provided (banner-less layout) each button is placed
            in the matching column; otherwise they're plain widgets (no wrapping
            container) so the CSS below can overlay them directly on the banner.
            """
            def _ctx(i):
                return columns[i] if i < len(columns) else None

            with (_ctx(0) or nullcontext()):
                fav_icon = "❤️" if is_favorite else "🤍"
                fav_help = "Remove from Favorites" if is_favorite else "Add to Favorites"
                if st.button(fav_icon, key=f"fav_{destination_name}", help=fav_help):
                    update_favorite_status(destination_name, add=not is_favorite)
                    st.rerun()
            with (_ctx(1) or nullcontext()):
                research_icon = "❓" if is_to_be_researched else "❔"
                research_help = "Needs research (click to mark as done)" if is_to_be_researched else "Mark as needs research"
                if st.button(research_icon, key=f"research_{destination_name}", help=research_help):
                    update_to_be_researched_status(destination_name, to_be_researched=not is_to_be_researched)
                    st.rerun()
            with (_ctx(2) or nullcontext()):
                visited_help = "Visited (click to mark as not visited)" if is_visited else "Mark as visited"
                if st.button("Visited" if is_visited else "Not visited", key=f"visited_{destination_name}", help=visited_help):
                    update_visited_status(destination_name, visited=not is_visited)
                    st.rerun()
            with (_ctx(3) or nullcontext()):
                _render_comment_toggle(destination_name, comment_value)

        with st.container(key=f"dest_header_{destination_name}"):
            if img_base64:
                st.markdown(
                    f"""
                    <div style="
                        position: relative;
                        width: 100%;
                        height: 220px;
                        border-radius: 14px;
                        overflow: hidden;
                        background-image: url('data:image/jpeg;base64,{img_base64}');
                        background-size: cover;
                        background-position: center;
                        box-shadow: 0 4px 15px rgba(0,0,0,0.1);
                        display: flex;
                        align-items: flex-end;
                        padding: 20px;
                    ">
                        <div style="
                            background: rgba(255, 255, 255, 0.94);
                            backdrop-filter: blur(8px);
                            padding: 10px 22px;
                            border-radius: 10px;
                            box-shadow: 0 4px 12px rgba(0,0,0,0.15);
                        ">
                            <h1 style="
                                margin: 0;
                                padding: 0;
                                font-size: 2.2rem;
                                font-weight: 800;
                                color: #111827;
                                line-height: 1.1;
                            ">{html.escape(dest_title)}{q_mark}</h1>
                        </div>
                    </div>
                    """,
                    unsafe_allow_html=True
                )
                _render_header_buttons()
            else:
                st.title(f"{dest_title}{q_mark}")
                _render_header_buttons(*st.columns([0.55, 0.55, 0.55, 1.4, 4.3]))

    # Styling for the header icon buttons (Favorite Heart, Research Question
    # Mark, Visited Footsteps). Pure CSS targeted via the widget key class
    # (st-key-...), so no JS is needed — Streamlit strips <script> blocks that
    # contain HTML markup, and JS-mutating widget content doesn't survive React
    # re-renders. The visited button shows the footsteps as a CSS background
    # image; the label text is hidden (the help tooltip still describes state).
    fav_key_cls = _st_key_class(f"fav_{destination_name}")
    research_key_cls = _st_key_class(f"research_{destination_name}")
    visited_key_cls = _st_key_class(f"visited_{destination_name}")
    comment_add_key_cls = _st_key_class(f"comment_add_{destination_name}")
    header_cls = _st_key_class(f"dest_header_{destination_name}")
    visited_uri = _footsteps_data_uri(is_visited)
    # Key class for the Prio Thorsten edit button — used to turn the standalone
    # ✏️ button into an invisible overlay on the metric box (see CSS below).
    edit_prio_cls = _st_key_class(f"edit_prio_button_{destination_name}")

    # When a banner image is shown, the header action buttons float over the
    # banner, to the right of the destination name, instead of occupying a row
    # under the header. The keyed header container is the positioning anchor;
    # each button's st-key class is absolutely positioned from the right edge
    # (rightmost → visited, then research, then fav; Add-comment, when visible,
    # is leftmost). Pure CSS — no JS.
    overlay_css = ""
    if img_base64:
        _right_cursor = 16
        _step = 66  # 58px button + 8px gap
        _rights = {}
        for _key_cls in (visited_key_cls, research_key_cls, fav_key_cls):
            _rights[_key_cls] = _right_cursor
            _right_cursor += _step
        if not str(comment_value or "").strip():
            _rights[comment_add_key_cls] = _right_cursor

        _overlay_group = ", ".join(
            f".{header_cls} .{k}" for k in (fav_key_cls, research_key_cls, visited_key_cls, comment_add_key_cls)
        )
        _overlay_btn_group = ", ".join(
            f".{header_cls} .{k} button" for k in (fav_key_cls, research_key_cls, visited_key_cls, comment_add_key_cls)
        )
        overlay_css = f"""
            /* Header action buttons float over the banner, right of the title.
               The header container's top aligns with the banner's top, so `top`
               is measured from the banner (220px tall). The buttons are lowered
               to roughly the level of the destination name, and their circles
               are sized to match the height of the white title surface (~58px). */
            .{header_cls} {{
                position: relative !important;
                /* Match the ~16px gap between the metric boxes and the Comment
                   box: the banner's markdown wrapper has a -16px margin quirk
                   that otherwise pulls the metrics up flush against the banner. */
                padding-bottom: 16px !important;
            }}
            {_overlay_group} {{
                position: absolute !important;
                top: 141px !important;
                margin: 0 !important;
                width: fit-content !important;
                z-index: 6 !important;
            }}
            {_overlay_btn_group} {{
                background-color: rgba(255, 255, 255, 0.92) !important;
                box-shadow: 0 2px 6px rgba(0, 0, 0, 0.25) !important;
            }}
            .{header_cls} .{fav_key_cls} button,
            .{header_cls} .{research_key_cls} button,
            .{header_cls} .{visited_key_cls} button {{
                height: 58px !important;
                width: 58px !important;
                border-radius: 50% !important;
            }}
            .{header_cls} .{fav_key_cls} button p,
            .{header_cls} .{research_key_cls} button p {{
                font-size: 2.3rem !important;
                line-height: 1 !important;
            }}
            .{header_cls} .{visited_key_cls} button {{
                background-size: 46px 46px !important;
            }}
            .{header_cls} .{comment_add_key_cls} button {{
                height: 58px !important;
                border-radius: 29px !important;
                padding: 0 20px !important;
                font-size: 1.05rem !important;
            }}
        """
        for _key_cls, _right_px in _rights.items():
            overlay_css += f".{header_cls} .{_key_cls} {{ right: {_right_px}px !important; }}\n"

    st.html(
        f"""
        <style>
            /* Unboxed icon buttons for Favorites & Research (emoji stays visible). */
            .{fav_key_cls} button,
            .{research_key_cls} button {{
                background: transparent !important;
                border: none !important;
                box-shadow: none !important;
                padding: 0 !important;
                min-height: 0 !important;
                height: 2.2rem !important;
                width: 2.2rem !important;
                cursor: pointer !important;
                display: inline-flex !important;
                align-items: center !important;
                justify-content: center !important;
                transition: transform 0.15s cubic-bezier(0.175, 0.885, 0.32, 1.275) !important;
            }}
            .{fav_key_cls} button p,
            .{research_key_cls} button p {{
                font-size: 1.85rem !important;
                line-height: 1 !important;
                margin: 0 !important;
                padding: 0 !important;
                vertical-align: middle !important;
            }}
            .{fav_key_cls} button:hover,
            .{research_key_cls} button:hover {{
                transform: scale(1.3) !important;
                background: transparent !important;
                border: none !important;
                box-shadow: none !important;
            }}
            .{fav_key_cls} button:active,
            .{research_key_cls} button:active {{
                transform: scale(0.95) !important;
            }}

            /* Visited toggle: footsteps shown as a CSS background image.
               Pale grey when not visited, dark blue when visited. */
            .{visited_key_cls} button {{
                background-color: transparent !important;
                background-image: url('{visited_uri}') !important;
                background-repeat: no-repeat !important;
                background-position: center !important;
                background-size: 26px 26px !important;
                border: none !important;
                box-shadow: none !important;
                padding: 0 !important;
                min-height: 0 !important;
                height: 2.2rem !important;
                width: 2.2rem !important;
                cursor: pointer !important;
                color: transparent !important;
                font-size: 0 !important;
                transition: transform 0.15s cubic-bezier(0.175, 0.885, 0.32, 1.275) !important;
            }}
            .{visited_key_cls} button p {{
                font-size: 0 !important;
                margin: 0 !important;
                padding: 0 !important;
            }}
            .{visited_key_cls} button:hover {{
                transform: scale(1.3) !important;
                background-color: transparent !important;
                border: none !important;
                box-shadow: none !important;
            }}
            .{visited_key_cls} button:active {{
                transform: scale(0.95) !important;
            }}

            /* Prio metric box: keep it looking clickable (visual affordance only). */
            div.prio-metric-box {{
                cursor: pointer !important;
                transition: box-shadow 0.15s ease, transform 0.1s ease;
            }}
            div.prio-metric-box:hover {{
                box-shadow: 0 2px 8px rgba(0,0,0,0.12) !important;
                transform: translateY(-1px);
            }}

            /* Prio Thorsten edit button: the standalone ✏️ button becomes an
               invisible, full-box overlay so clicking the "Prio Thorsten"
               metric box opens the editor. Pure CSS via the widget's st-key
               class — the old JS/MutationObserver tagging approach is stripped
               by Streamlit. The metric box and the button are siblings inside
               the same stVerticalBlock, so :has() scopes the overlay anchor. */
            div.stVerticalBlock:has(div.prio-metric-box) {{
                position: relative !important;
            }}
            div.stVerticalBlock:has(div.prio-metric-box) .{edit_prio_cls} {{
                position: absolute !important;
                top: 0 !important;
                left: 0 !important;
                width: 100% !important;
                height: 100% !important;
                z-index: 5 !important;
                opacity: 0 !important;
                cursor: pointer !important;
            }}
            div.stVerticalBlock:has(div.prio-metric-box) .{edit_prio_cls} button {{
                position: absolute !important;
                top: 0 !important;
                left: 0 !important;
                width: 100% !important;
                height: 100% !important;
                min-width: 0 !important;
                min-height: 0 !important;
                border-radius: 0 !important;
                opacity: 0 !important;
                border: none !important;
                background: transparent !important;
                box-shadow: none !important;
                cursor: pointer !important;
            }}
            /* Keep the clickable affordance: lift + shadow the box when the
               invisible overlay is hovered. */
            div.stVerticalBlock:has(div.prio-metric-box):has(div.{edit_prio_cls}:hover) div.prio-metric-box {{
                box-shadow: 0 2px 8px rgba(0,0,0,0.12) !important;
                transform: translateY(-1px);
            }}

            {overlay_css}
        </style>
        """,
        unsafe_allow_javascript=True,
    )

    metrics = []
    if reviews_col:
        metrics.append(("Reviews", selected_row.get(reviews_col), "/10", "high"))
    
    # Always include Prio Thorsten
    prio_val = selected_row.get(prio_col) if prio_col and prio_col in selected_row else None
    metrics.append(("Prio Thorsten", prio_val, "/10", "high"))

    if safety_col:
        metrics.append(("Safety Rating", selected_row.get(safety_col), "/10", "high"))
    if visa_requirement_col:
        metrics.append(("Visa Requirement", selected_row.get(visa_requirement_col), "", "visa"))
    # Recommended Stay replaces Avg. Cost/Day in the top metrics bar
    stay_raw = selected_row.get("Recommended Stay") if "Recommended Stay" in selected_row.index else None
    if pd.notna(stay_raw) and str(stay_raw).strip():
        metrics.append(("Recommended Stay", str(stay_raw).strip(), "", "stay"))
    if population_col:
        pop_raw = selected_row.get(population_col)
        population_millions = float(pop_raw) / 1_000_000 if pd.notna(pop_raw) else None
        metrics.append(("Population", population_millions, "M", "population"))

    metrics_col = st.columns(6)
    for index, (column, value, suffix, mode) in enumerate(metrics):
        with metrics_col[index % len(metrics_col)]:
            if column == "Prio Thorsten":
                edit_state_key = f"edit_prio_state_{destination_name}"
                edit_button_key = f"edit_prio_button_{destination_name}"
                save_key = f"save_prio_{destination_name}"
                input_key = f"prio_input_{destination_name}"

                if edit_state_key not in st.session_state:
                    st.session_state[edit_state_key] = False

                st.markdown(_format_metric_box(column, value, suffix, mode, edit_badge=True), unsafe_allow_html=True)
                # The standalone ✏️ button is styled (see the CSS above) as an
                # invisible overlay that sits on top of the metric box, so
                # clicking the box opens the editor. It's only rendered while
                # the editor is closed, and a rerun right after the click
                # removes it while the editor is open — otherwise the invisible
                # overlay would cover and block the editor's input/Save/Cancel.
                if not st.session_state.get(edit_state_key):
                    if st.button("✏️", key=edit_button_key, help="Edit Prio Thorsten"):
                        st.session_state[edit_state_key] = True
                        st.rerun()

                if st.session_state.get(edit_state_key):
                    current_str = ""
                    if pd.notna(value) and str(value).strip() != "" and str(value).strip().lower() not in {"nan", "none", "null", "—"}:
                        try:
                            current_str = f"{int(float(value))}"
                        except (ValueError, TypeError):
                            current_str = str(value).strip()

                    new_value_str = st.text_input(
                        "Prio Thorsten (0–10)",
                        value=current_str,
                        placeholder="Leave blank to clear",
                        key=input_key,
                        help="Enter a priority from 0 to 10, or leave blank and save to clear."
                    )
                    btn_c1, btn_c2 = st.columns(2)
                    with btn_c1:
                        if st.button("Save", key=save_key, type="primary", use_container_width=True):
                            val_to_save = new_value_str.strip()
                            if val_to_save == "":
                                update_prio_thorsten(destination_name, None)
                                st.session_state.pop(edit_state_key, None)
                                st.rerun()
                            else:
                                try:
                                    num_val = int(float(val_to_save))
                                    if 0 <= num_val <= 10:
                                        update_prio_thorsten(destination_name, num_val)
                                        st.session_state.pop(edit_state_key, None)
                                        st.rerun()
                                    else:
                                        st.error("Enter a number 0–10")
                                except ValueError:
                                    st.error("Please enter 0–10 or leave blank.")
                    with btn_c2:
                        if st.button("Cancel", key=f"cancel_prio_{destination_name}", use_container_width=True):
                            st.session_state.pop(edit_state_key, None)
                            st.rerun()
            else:
                st.markdown(_format_metric_box(column, value, suffix, mode), unsafe_allow_html=True)

    # ── Comment (editable, written back to the workbook) ──────────────────────
    # Hidden by default. The box + Save button only appear when the
    # "Add comment" / pen button next to the favorites button is clicked.
    _render_comment_editor(destination_name, comment_value)

    st.subheader("Overview")
    overview_texts = []
    if intro_col and intro_col in selected_row.index and pd.notna(selected_row[intro_col]):
        overview_texts.append(("Introduction Sentence", str(selected_row[intro_col]).strip()))
    if why_col and why_col in selected_row.index and pd.notna(selected_row[why_col]):
        overview_texts.append(("Why to Go There", str(selected_row[why_col]).strip()))
    if expect_col and expect_col in selected_row.index and pd.notna(selected_row[expect_col]):
        overview_texts.append(("What to Expect", str(selected_row[expect_col]).strip()))
    if tourist_reviews_col and tourist_reviews_col in selected_row.index and pd.notna(selected_row[tourist_reviews_col]):
        overview_texts.append(("Tourist Reviews", str(selected_row[tourist_reviews_col]).strip()))

    if selected_row.get("What do the reviews praise?") is not None and pd.notna(selected_row["What do the reviews praise?"]):
        overview_texts.append(("What do the reviews praise?", str(selected_row["What do the reviews praise?"]).strip()))
    if selected_row.get("What do they dislike?") is not None and pd.notna(selected_row["What do they dislike?"]):
        overview_texts.append(("What do they dislike?", str(selected_row["What do they dislike?"]).strip()))

    food_spiciness = selected_row.get(food_spiciness_col) if food_spiciness_col else None
    food_description = selected_row.get(food_description_col) if food_description_col else None
    visa_value = selected_row.get(visa_requirement_col) if visa_requirement_col else None
    malaria_value = selected_row.get(malaria_risk_col) if malaria_risk_col else None

    if overview_texts:
        for label, value in overview_texts:
            if label == "Introduction Sentence":
                st.write(value)
                continue
            if label == "Tourist Reviews":
                st.subheader(label)
                st.write(value)
                continue
            st.markdown(
                f"**{label}**<br>{html.escape(str(value))}",
                unsafe_allow_html=True,
            )
    else:
        st.write("No overview text was found in the workbook.")

    if highlights_col and pd.notna(selected_row[highlights_col]):
        highlights_text = str(selected_row[highlights_col]).strip()
        if highlights_text:
            st.markdown(
                f"**Highlights**<br>{html.escape(highlights_text)}",
                unsafe_allow_html=True,
            )
        else:
            st.write("No highlight notes were found in the workbook.")
    else:
        st.write("No highlight notes were found in the workbook.")

    st.subheader("Logistics")
    logistics_col1, logistics_col2, logistics_col3 = st.columns(3)
    with logistics_col1:
        if pd.notna(visa_value) and str(visa_value).strip():
            st.markdown(
                f"**Visa Requirement**<br>{html.escape(str(visa_value).strip())}",
                unsafe_allow_html=True,
            )
        else:
            st.markdown("**Visa Requirement**<br>—", unsafe_allow_html=True)
    with logistics_col2:
        if pd.notna(malaria_value) and str(malaria_value).strip():
            malaria_text = html.escape(str(malaria_value).strip())
            if str(malaria_value).strip().lower().startswith("yes"):
                malaria_text = f"<span style='color:#e74c3c; font-weight:700;'>{malaria_text}</span>"
            st.markdown(f"**Malaria risk?**<br>{malaria_text}", unsafe_allow_html=True)
        else:
            st.markdown("**Malaria risk?**<br>—", unsafe_allow_html=True)
    with logistics_col3:
        cost_raw = selected_row.get(cost_col) if cost_col else None
        if pd.notna(cost_raw):
            try:
                cost_display = f"{int(float(cost_raw))} €/day"
            except (ValueError, TypeError):
                cost_display = str(cost_raw).strip()
        else:
            cost_display = "—"
        st.markdown(f"**Avg. Cost/Day**<br>{cost_display}", unsafe_allow_html=True)

    _render_food_section(
        destination_name,
        dest_title,
        selected_row,
        metadata,
        food_spiciness,
        food_description,
    )

    if month_columns:
        import re as _re

        _MONTH_ABBR = {
            "jan": "January", "feb": "February", "mar": "March", "apr": "April",
            "may": "May", "jun": "June", "jul": "July", "aug": "August",
            "sep": "September", "oct": "October", "nov": "November", "dec": "December",
        }
        _MONTH_FULL = {v.lower(): v for v in _MONTH_ABBR.values()}
        _ALL_MONTHS_ORDERED = list(_MONTH_ABBR.values())

        def _parse_avoid_annotations(avoid_raw: str) -> dict:
            """Return a dict of month_name -> reason_hint for the avoid periods."""
            if not avoid_raw or not str(avoid_raw).strip():
                return {}
            text = str(avoid_raw).strip()

            def _normalize_month(m: str) -> str | None:
                m = m.strip().lower()
                if m in _MONTH_FULL:
                    return _MONTH_FULL[m]
                if len(m) >= 3 and m[:3] in _MONTH_ABBR:
                    return _MONTH_ABBR[m[:3]]
                return None

            def _months_in_range(start: str, end: str) -> list:
                s = _normalize_month(start)
                e = _normalize_month(end)
                if not s or not e:
                    return []
                si = _ALL_MONTHS_ORDERED.index(s)
                ei = _ALL_MONTHS_ORDERED.index(e)
                if si <= ei:
                    return _ALL_MONTHS_ORDERED[si:ei + 1]
                return _ALL_MONTHS_ORDERED[si:] + _ALL_MONTHS_ORDERED[:ei + 1]

            def _split_segments(t: str) -> list:
                """Split on ' and ' only when not inside parentheses."""
                segments = []
                depth = 0
                current = []
                i = 0
                while i < len(t):
                    ch = t[i]
                    if ch == '(':
                        depth += 1
                        current.append(ch)
                        i += 1
                    elif ch == ')':
                        depth = max(0, depth - 1)
                        current.append(ch)
                        i += 1
                    elif depth == 0 and t[i:].lower().startswith(' and '):
                        segments.append(''.join(current).strip())
                        current = []
                        i += 5  # skip ' and '
                    else:
                        current.append(ch)
                        i += 1
                if current:
                    segments.append(''.join(current).strip())
                return [s for s in segments if s]

            segments = _split_segments(text)
            month_to_reason: dict = {}

            for seg in segments:
                seg = seg.strip()
                parens = _re.findall(r'\(([^)]+)\)', seg)
                months_found: list = []
                reason_parts: list = []

                for p in parens:
                    p_stripped = p.strip()
                    # Month range like "June-August" or "Jun-Aug"
                    range_match = _re.match(r'([A-Za-z]+)[\-–]([A-Za-z]+)$', p_stripped)
                    if range_match:
                        ms = _months_in_range(range_match.group(1), range_match.group(2))
                        if ms:
                            months_found.extend(ms)
                            continue
                    # Comma/space list of pure month names
                    candidates = _re.split(r'[,\s]+', p_stripped)
                    if candidates and all(_normalize_month(c) for c in candidates if c):
                        for c in candidates:
                            nm = _normalize_month(c)
                            if nm:
                                months_found.append(nm)
                        continue
                    # Otherwise a descriptive reason
                    reason_parts.append(p_stripped)

                # Plain text month range outside parens: "June to September"
                plain = _re.sub(r'\([^)]*\)', '', seg).strip()
                plain_range = _re.search(
                    r'\b([A-Za-z]+)\s+(?:to|-)\s+([A-Za-z]+)\b', plain, _re.IGNORECASE
                )
                if plain_range:
                    ms = _months_in_range(plain_range.group(1), plain_range.group(2))
                    if ms:
                        months_found.extend(ms)

                # Short abbreviation range like "Jun-Aug" in plain text
                if not months_found:
                    short_range = _re.search(r'\b([A-Za-z]{3})-([A-Za-z]{3})\b', plain)
                    if short_range:
                        ms = _months_in_range(short_range.group(1), short_range.group(2))
                        if ms:
                            months_found.extend(ms)

                reason = '; '.join(reason_parts) if reason_parts else ''
                for m in months_found:
                    if m not in month_to_reason or not month_to_reason[m]:
                        month_to_reason[m] = reason
                    elif reason and reason not in month_to_reason[m]:
                        month_to_reason[m] += f'; {reason}'

            return month_to_reason

        st.markdown("<div style='height:8px;'></div>", unsafe_allow_html=True)
        st.subheader("Best months")
        month_labels = [col for col in month_columns if col in df.columns]
        if month_labels:
            month_values = []
            for col in month_labels:
                value = selected_row[col]
                if pd.isna(value):
                    month_values.append((col, ""))
                else:
                    month_values.append((col, str(value).strip().lower()))

            # Parse avoid text into per-month reason hints
            avoid_raw = (
                selected_row.get("Avoid Going There")
                if "Avoid Going There" in selected_row.index else None
            )
            avoid_annotations = _parse_avoid_annotations(avoid_raw) if pd.notna(avoid_raw) else {}

            MONTH_ABBR = {
                "January": "Jan", "February": "Feb", "March": "Mar",
                "April": "Apr", "May": "May", "June": "Jun",
                "July": "Jul", "August": "Aug", "September": "Sep",
                "October": "Oct", "November": "Nov", "December": "Dec",
            }

            LEVEL_META = {
                "ideal": ("rgba(34, 197, 94, 0.22)", "#15803d", "rgba(34, 197, 94, 0.45)", "Ideal"),
                "good":  ("rgba(34, 197, 94, 0.22)", "#15803d", "rgba(34, 197, 94, 0.45)", "Ideal"),
                "great": ("rgba(34, 197, 94, 0.22)", "#15803d", "rgba(34, 197, 94, 0.45)", "Ideal"),
                "best":  ("rgba(34, 197, 94, 0.22)", "#15803d", "rgba(34, 197, 94, 0.45)", "Ideal"),
                "green": ("rgba(34, 197, 94, 0.22)", "#15803d", "rgba(34, 197, 94, 0.45)", "Ideal"),
                "ok":    ("rgba(234, 179, 8, 0.22)", "#a16207", "rgba(234, 179, 8, 0.45)", "Ok"),
                "okay":  ("rgba(234, 179, 8, 0.22)", "#a16207", "rgba(234, 179, 8, 0.45)", "Ok"),
                "medium":("rgba(234, 179, 8, 0.22)", "#a16207", "rgba(234, 179, 8, 0.45)", "Ok"),
                "yellow":("rgba(234, 179, 8, 0.22)", "#a16207", "rgba(234, 179, 8, 0.45)", "Ok"),
                "bad":   ("rgba(239, 68, 68, 0.22)", "#b91c1c", "rgba(239, 68, 68, 0.45)", "Bad"),
                "poor":  ("rgba(239, 68, 68, 0.22)", "#b91c1c", "rgba(239, 68, 68, 0.45)", "Bad"),
                "red":   ("rgba(239, 68, 68, 0.22)", "#b91c1c", "rgba(239, 68, 68, 0.45)", "Bad"),
                "worst": ("rgba(239, 68, 68, 0.22)", "#b91c1c", "rgba(239, 68, 68, 0.45)", "Bad"),
            }

            cells = []
            for label, level in month_values:
                abbr = MONTH_ABBR.get(label, label[:3])
                bg, text_color, border_color, level_label = LEVEL_META.get(
                    level, ("rgba(148, 163, 184, 0.18)", "#475569", "rgba(148, 163, 184, 0.35)", "—")
                )
                reason = avoid_annotations.get(label, "")
                show_reason = reason and level in {
                    "bad", "poor", "red", "worst", "ok", "okay", "medium", "yellow"
                }

                reason_row = (
                    f"<div style='font-size:0.76rem;color:{text_color};opacity:0.9;"
                    f"margin-top:6px;font-style:italic;line-height:1.25;"
                    f"word-break:break-word;font-weight:500;'>{html.escape(reason)}</div>"
                    if show_reason else
                    "<div style='margin-top:6px;min-height:0.8em;'></div>"
                )

                cells.append(
                    f"<div style='"
                    f"flex:1;min-width:0;padding:12px 6px;border-radius:10px;"
                    f"background:{bg};border:1.5px solid {border_color};text-align:center;cursor:default;"
                    f"transition:all 0.15s ease;display:flex;flex-direction:column;align-items:center;' "
                    f"onmouseover=\"this.style.transform='scale(1.05)';this.style.boxShadow='0 4px 12px rgba(0,0,0,0.08)'\" "
                    f"onmouseout=\"this.style.transform='scale(1)';this.style.boxShadow='none'\">"
                    f"<div style='font-size:1.05rem;font-weight:800;color:{text_color};letter-spacing:0.02em;'>{abbr}</div>"
                    f"<div style='font-size:0.85rem;color:{text_color};margin-top:3px;font-weight:700;'>{level_label}</div>"
                    f"{reason_row}"
                    f"</div>"
                )

            strip_html = (
                "<div style='display:flex;gap:6px;align-items:stretch;margin:6px 0 14px 0;'>"
                + "".join(cells)
                + "</div>"
            )
            st.markdown(strip_html, unsafe_allow_html=True)

    # ── Climate Dashboard ───────────────────────────────────────────────────
    render_climate_dashboard(str(selected_row[destination_col]).strip(), selected_row, df)

    # ── Destination Gallery (Unsplash) ──────────────────────────────────────
    render_destination_gallery(dest_title, selected_row, metadata)

    # ── Direct Flight & Train Connections ───────────────────────────────────
    render_flight_routes_section(
        destination_name,
        _country_text(selected_row, metadata),
        df,
        destination_col,
        metadata=metadata,
    )


def render_destination_gallery(dest_title: str, selected_row: pd.Series, metadata: dict):
    """Render cached Unsplash photos at the bottom of the detail page.

    Images are fetched once (search ``"<destination>, <country>"``, landscape,
    ``urls.regular``) and persisted to ``Pictures/gallery/<slug>/`` so reopening
    a destination triggers no new API calls. Each image has its own **🔄 Replace**
    button so you can swap out just the ones you don't like without re-fetching
    the whole gallery. Photos are laid out in a responsive grid (4 per row).
    """
    pictures_dir = DATA_PATH.parent / "Pictures"

    st.divider()
    st.subheader("📷 Gallery")
    st.caption("Photos from Unsplash. Use 🔄 Replace to swap an individual photo for a fresh one.")

    # Inject CSS + JS to shrink the 🔄 replace buttons down to just the emoji
    # size (no padding, no border, transparent background). The JS finds
    # buttons whose text content is exactly "🔄" and tags them with a class;
    # a MutationObserver re-tags them on every Streamlit rerun.
    st.html(
        """
        <style>
            button.gallery-replace-btn {
                padding: 0 !important;
                min-height: 0 !important;
                height: 1.5em !important;
                width: 1.5em !important;
                border: none !important;
                background: transparent !important;
                box-shadow: none !important;
                line-height: 1 !important;
                display: inline-flex !important;
                align-items: center !important;
                justify-content: center !important;
            }
            button.gallery-replace-btn > div {
                padding: 0 !important;
                margin: 0 !important;
                gap: 0 !important;
            }
            button.gallery-replace-btn p {
                margin: 0 !important;
                padding: 0 !important;
                line-height: 1 !important;
                font-size: 1.1rem !important;
            }
            button.gallery-replace-btn:hover {
                background: rgba(0,0,0,0.06) !important;
                border-radius: 4px !important;
            }
        </style>
        <script>
            (function() {
                function tagReplaceButtons() {
                    document.querySelectorAll('button[kind="secondary"]').forEach(function(btn) {
                        var text = btn.textContent.trim();
                        if (text === '🔄') {
                            btn.classList.add('gallery-replace-btn');
                        }
                    });
                }
                tagReplaceButtons();
                // Re-tag when Streamlit rerenders the DOM
                var observer = new MutationObserver(function() {
                    tagReplaceButtons();
                });
                observer.observe(document.body, { childList: true, subtree: true });
            })();
        </script>
        """,
        unsafe_allow_javascript=True,
    )

    country = _country_text(selected_row, metadata) or None

    entries = build_destination_gallery(dest_title, country=country, pictures_dir=pictures_dir)

    if not entries:
        access_key = get_access_key()
        if not access_key:
            st.info("Gallery images are unavailable — the Unsplash Access Key is not configured.")
        else:
            st.info("Gallery images could not be loaded for this destination.")
        return

    # Responsive grid: 4 images per row. Each cell shows the image plus an
    # attribution caption with a tiny 🔄 button on the same row (no separate
    # button row) so you can replace just that one photo.
    COLUMNS_PER_ROW = 4
    for row_start in range(0, len(entries), COLUMNS_PER_ROW):
        row_entries = entries[row_start:row_start + COLUMNS_PER_ROW]
        cols = st.columns(COLUMNS_PER_ROW)
        for col_offset, entry in enumerate(row_entries):
            absolute_index = row_start + col_offset
            with cols[col_offset]:
                try:
                    st.image(str(entry["image_path"]), width="stretch")
                except Exception:
                    st.warning("An image could not be displayed.")
                # Caption + tiny replace button share one row.
                cap_col, btn_col = st.columns([8, 1])
                with cap_col:
                    photographer = entry.get("photographer_name", "Unsplash")
                    photographer_url = entry.get("photographer_url", "https://unsplash.com")
                    photo_url = entry.get("photo_url", "https://unsplash.com")
                    st.caption(
                        f"Photo by [{photographer}]({photographer_url}) on "
                        f"[Unsplash]({photo_url})"
                    )
                with btn_col:
                    if st.button("🔄", key=f"replace_gallery_{dest_title}_{absolute_index}", help="Replace this photo"):
                        refresh_single_gallery_image(
                            dest_title, country, pictures_dir, absolute_index
                        )
                        st.rerun()


def render_climate_dashboard(destination_name: str, selected_row: pd.Series, df: pd.DataFrame):
    """Render a comprehensive monthly climate & air quality dashboard."""
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots

    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    full_months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]

    # Extract monthly series
    highs_c = [selected_row.get(f"{m} High (C)") for m in months]
    lows_c = [selected_row.get(f"{m} Low (C)") for m in months]
    rainy_days = [selected_row.get(f"{m} Rainy Days") for m in months]
    rain_mm = [selected_row.get(f"{m} Rain (mm)") for m in months]
    aqi_vals = [selected_row.get(f"{m} AQI") for m in months]

    # Check if this destination has monthly climate data populated
    has_data = any(pd.notna(v) for v in highs_c + rain_mm + aqi_vals)

    st.divider()
    st.subheader("🌍 Destination climate dashboard ☁️")

    if not has_data:
        st.info(f"Detailed monthly climate and air quality data is currently being populated for **{destination_name}**.")
        return

    is_f = False
    temp_suffix = "°F" if is_f else "°C"

    def _to_unit(c_val):
        if pd.isna(c_val):
            return None
        return round(float(c_val) * 9 / 5 + 32, 1) if is_f else round(float(c_val), 1)

    highs = [_to_unit(v) for v in highs_c]
    lows = [_to_unit(v) for v in lows_c]

    # Calculate KPI summary metrics
    # 1. Peak High
    valid_highs = [(h, m) for h, m in zip(highs, months) if h is not None]
    if valid_highs:
        max_h, max_h_m = max(valid_highs, key=lambda x: x[0])
        peak_high_str = f"{max_h:.0f}{temp_suffix} ({max_h_m})"
    else:
        peak_high_str = "—"

    # 2. Wettest Month
    valid_rain = [(r, m) for r, m in zip(rain_mm, months) if pd.notna(r)]
    if valid_rain:
        max_r, max_r_m = max(valid_rain, key=lambda x: x[0])
        wettest_str = f"{max_r:.0f}mm ({max_r_m})"
    else:
        wettest_str = "—"

    # 3. Average AQI
    valid_aqi = [float(a) for a in aqi_vals if pd.notna(a)]
    if valid_aqi:
        avg_aqi = sum(valid_aqi) / len(valid_aqi)
        if avg_aqi <= 50:
            aqi_status = "Good"
            aqi_badge = "🟢"
        elif avg_aqi <= 100:
            aqi_status = "Moderate"
            aqi_badge = "🟡"
        elif avg_aqi <= 150:
            aqi_status = "Unhealthy for Sensitive"
            aqi_badge = "🟠"
        else:
            aqi_status = "Unhealthy"
            aqi_badge = "🔴"
        aqi_str = f"{avg_aqi:.0f} ({aqi_status})"
    else:
        aqi_str = "—"
        aqi_badge = "⚪"

    # 4. Best Months
    ideal_candidates = []
    # Check spreadsheet rating columns first
    for full_m, short_m in zip(full_months, months):
        val = selected_row.get(full_m)
        if pd.notna(val) and str(val).strip().lower() in {"ideal", "good", "great", "best", "green"}:
            ideal_candidates.append(short_m)

    if not ideal_candidates and valid_rain:
        # Fallback algorithm: lowest rainfall months with moderate AQI
        sorted_by_rain = sorted(zip(months, rain_mm, aqi_vals), key=lambda x: (x[1] if pd.notna(x[1]) else 9999))
        ideal_candidates = [m for m, r, a in sorted_by_rain[:3] if pd.notna(r)]

    best_months_str = ", ".join(ideal_candidates[:4]) if ideal_candidates else "Varies"

    # Render KPI Cards in a modern grid
    kpi1, kpi2, kpi3, kpi4 = st.columns(4)
    card_style = (
        "padding: 14px 16px; border-radius: 12px; border: 1px solid #e2e8f0; "
        "background: #ffffff; box-shadow: 0 1px 3px rgba(0,0,0,0.05); margin-bottom: 16px;"
    )

    with kpi1:
        st.markdown(
            f"""<div style="{card_style}">
                <div style="font-size: 0.82rem; color: #64748b; font-weight: 600;">🌡️ PEAK HIGH</div>
                <div style="font-size: 1.45rem; font-weight: 700; color: #0f172a; margin-top: 4px;">{peak_high_str}</div>
            </div>""",
            unsafe_allow_html=True
        )

    with kpi2:
        st.markdown(
            f"""<div style="{card_style}">
                <div style="font-size: 0.82rem; color: #64748b; font-weight: 600;">💧 WETTEST MONTH</div>
                <div style="font-size: 1.45rem; font-weight: 700; color: #0284c7; margin-top: 4px;">{wettest_str}</div>
            </div>""",
            unsafe_allow_html=True
        )

    with kpi3:
        st.markdown(
            f"""<div style="{card_style}">
                <div style="font-size: 0.82rem; color: #64748b; font-weight: 600;">🍃 AVERAGE AQI</div>
                <div style="font-size: 1.35rem; font-weight: 700; color: #0f172a; margin-top: 4px;">{aqi_badge} {aqi_str}</div>
            </div>""",
            unsafe_allow_html=True
        )

    with kpi4:
        st.markdown(
            f"""<div style="{card_style}">
                <div style="font-size: 0.82rem; color: #64748b; font-weight: 600;">🎯 BEST MONTHS</div>
                <div style="font-size: 1.45rem; font-weight: 700; color: #16a34a; margin-top: 4px;">{best_months_str}</div>
            </div>""",
            unsafe_allow_html=True
        )

    # ── Chart 1: Temperature Range & Rainfall (Dual Y-Axis) ─────────────────
    st.markdown("**🌧️ Monthly Temperature & Rainfall**")
    fig_temp_rain = make_subplots(specs=[[{"secondary_y": True}]])

    # 1. Rainfall Bars on Secondary Axis
    rain_labels = [f"{int(d)}d" if (pd.notna(d) and d > 0) else "" for d in rainy_days]
    fig_temp_rain.add_trace(
        go.Bar(
            x=months,
            y=rain_mm,
            name="Rainfall",
            marker=dict(
                color="rgba(112, 187, 245, 0.65)",
                line=dict(color="#38bdf8", width=1.2)
            ),
            text=rain_labels,
            textposition="outside",
            textfont=dict(size=11, color="#0369a1", family="Arial, sans-serif"),
            hovertemplate="<b>%{x}</b><br>Rainfall: %{y} mm<br>Rainy Days: %{text}<extra></extra>"
        ),
        secondary_y=True
    )

    # 2. Low Temperature Line
    fig_temp_rain.add_trace(
        go.Scatter(
            x=months,
            y=lows,
            name="Low Temp",
            mode="lines+markers",
            line=dict(color="#3b82f6", width=2.5),
            marker=dict(size=6, color="#1d4ed8"),
            hovertemplate="<b>%{x}</b> Low: %{y}" + temp_suffix + "<extra></extra>"
        ),
        secondary_y=False
    )

    # 3. High Temperature Line + Fill Band
    fig_temp_rain.add_trace(
        go.Scatter(
            x=months,
            y=highs,
            name="High Temp",
            mode="lines+markers",
            line=dict(color="#ef4444", width=2.5),
            marker=dict(size=6, color="#b91c1c"),
            fill="tonexty",
            fillcolor="rgba(239, 68, 68, 0.18)",
            hovertemplate="<b>%{x}</b> High: %{y}" + temp_suffix + "<extra></extra>"
        ),
        secondary_y=False
    )

    # Calculate dynamic axis bounds
    all_temps = [t for t in highs + lows if t is not None]
    min_temp = min(all_temps) if all_temps else 0
    max_temp = max(all_temps) if all_temps else 35
    temp_padding = max(4, (max_temp - min_temp) * 0.18)

    max_rain = max([r for r in rain_mm if pd.notna(r)] or [100])
    rain_limit = max_rain * 1.28

    fig_temp_rain.update_layout(
        height=400,
        margin=dict(l=10, r=10, t=30, b=10),
        legend=dict(
            orientation="h",
            yanchor="bottom",
            y=1.02,
            xanchor="right",
            x=1
        ),
        hovermode="x unified",
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(248, 250, 252, 0.8)",
    )

    fig_temp_rain.update_xaxes(showgrid=True, gridcolor="#f1f5f9")
    fig_temp_rain.update_yaxes(
        title_text=f"Temperature ({temp_suffix})",
        range=[min_temp - temp_padding, max_temp + temp_padding],
        showgrid=True,
        gridcolor="#e2e8f0",
        secondary_y=False
    )
    fig_temp_rain.update_yaxes(
        title_text="Rainfall (mm)",
        range=[0, rain_limit],
        showgrid=False,
        secondary_y=True
    )

    st.plotly_chart(fig_temp_rain, width="stretch")

    # ── Chart 2: Air Quality Index (AQI) Profile ────────────────────────────
    st.markdown("**🍃 Air Quality Index (AQI) Profile**")
    fig_aqi = go.Figure()

    # AQI Trendline
    fig_aqi.add_trace(
        go.Scatter(
            x=months,
            y=aqi_vals,
            name="Monthly AQI",
            mode="lines+markers",
            line=dict(color="#78350f", width=3),
            marker=dict(size=8, color="#451a03", symbol="circle"),
            hovertemplate="<b>%{x}</b> AQI: %{y}<extra></extra>"
        )
    )

    # Calculate AQI Y-axis bounds
    valid_aqi_nums = [float(v) for v in aqi_vals if pd.notna(v)]
    top_aqi = max(valid_aqi_nums) if valid_aqi_nums else 100
    aqi_y_max = max(130, int(top_aqi * 1.25))

    # Add Color-Coded Severity Bands
    # Band 1: Good (0-50)
    fig_aqi.add_hrect(
        y0=0, y1=50,
        fillcolor="rgba(34, 197, 94, 0.22)",
        line_width=0,
        layer="below",
        annotation_text="Good (0–50)",
        annotation_position="top right",
        annotation_font=dict(size=10, color="#15803d")
    )
    # Band 2: Moderate (51-100)
    fig_aqi.add_hrect(
        y0=50, y1=100,
        fillcolor="rgba(234, 179, 8, 0.22)",
        line_width=0,
        layer="below",
        annotation_text="Moderate (51–100)",
        annotation_position="top right",
        annotation_font=dict(size=10, color="#a16207")
    )
    # Band 3: Unhealthy for Sensitive / Unhealthy (101-150)
    fig_aqi.add_hrect(
        y0=100, y1=min(150, aqi_y_max),
        fillcolor="rgba(249, 115, 22, 0.22)",
        line_width=0,
        layer="below",
        annotation_text="Unhealthy (101–150)" if aqi_y_max >= 100 else "",
        annotation_position="top right",
        annotation_font=dict(size=10, color="#c2410c")
    )
    # Band 4: Unhealthy+ (150+) if relevant
    if aqi_y_max > 150:
        fig_aqi.add_hrect(
            y0=150, y1=aqi_y_max,
            fillcolor="rgba(239, 68, 68, 0.22)",
            line_width=0,
            layer="below",
            annotation_text="Very Unhealthy (150+)",
            annotation_position="top right",
            annotation_font=dict(size=10, color="#b91c1c")
        )

    fig_aqi.update_layout(
        height=320,
        margin=dict(l=10, r=10, t=30, b=10),
        hovermode="x unified",
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(248, 250, 252, 0.8)",
        yaxis=dict(
            title="Air Quality Index (AQI)",
            range=[0, aqi_y_max],
            showgrid=True,
            gridcolor="#e2e8f0"
        ),
        xaxis=dict(showgrid=True, gridcolor="#f1f5f9"),
        showlegend=False
    )

    st.plotly_chart(fig_aqi, width="stretch")
