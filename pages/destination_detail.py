import base64
import html
import io
import re
import unicodedata
from pathlib import Path

from PIL import Image

import pandas as pd
import streamlit as st

from data_utils import (
    DATA_PATH,
    WorkbookLockedError,
    load_destinations,
    update_comment,
    update_favorite_status,
    update_prio_thorsten,
    update_food,
    update_visited_status,
)
from deepseek_client import generate_food_profile
from deepseek_populator import populate_existing_destination_with_ai
from unsplash_gallery import (
    build_destination_gallery,
    get_access_key,
    refresh_single_gallery_image,
)


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


def _format_metric_box(label: str, value: object, suffix: str, mode: str) -> str:
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

    return f"""
    <div style="padding: 12px 14px; border-radius: 10px; border-left: 6px solid {color}; background: #f8f9fb; margin-bottom: 12px;">
        <div style="font-size: 0.8rem; color: #4a5568; margin-bottom: 4px;">{html.escape(label)}</div>
        <div style="font-size: 1.3rem; font-weight: 700; color: #111827;">{display}</div>
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
                    margin-bottom: 16px;
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
                        ">{html.escape(dest_title)}</h1>
                    </div>
                </div>
                """,
                unsafe_allow_html=True
            )
        else:
            st.title(dest_title)

        close_col, fav_col, visited_col_btn, comment_col_btn, _ = st.columns([1, 1.5, 1.5, 1.5, 4.5])
        with close_col:
            if st.button("✖ Close tab", key=f"close_{destination_name}"):
                open_destinations = st.session_state.get("open_destinations", [])
                if destination_name in open_destinations:
                    open_destinations.remove(destination_name)
                    st.session_state["open_destinations"] = open_destinations
                overview_page = st.session_state.get("_overview_page")
                if overview_page is not None:
                    st.switch_page(overview_page)

        with fav_col:
            is_favorite = False
            if nearer_col and nearer_col in selected_row:
                val = selected_row[nearer_col]
                if pd.notna(val):
                    val_str = str(val).strip().lower()
                    if val is True or "x" in val_str or val_str in {"yes", "y", "true", "1", "ja", "j"}:
                        is_favorite = True

            fav_label = "Remove from Favorities" if is_favorite else "Add to Favorites"
            if st.button(fav_label, key=f"fav_{destination_name}"):
                update_favorite_status(destination_name, add=not is_favorite)
                st.rerun()

        with visited_col_btn:
            visited_value = selected_row.get(visited_col) if visited_col else None
            is_visited = pd.notna(visited_value) and str(visited_value).strip().lower() in {
                "true", "yes", "y", "1", "ja", "j", "x"
            }
            visited_label = "Mark as not visited" if is_visited else "Mark as visited"
            if st.button(visited_label, key=f"visited_{destination_name}"):
                update_visited_status(destination_name, visited=not is_visited)
                st.rerun()

        with comment_col_btn:
            _render_comment_toggle(destination_name, comment_value)
    else:
        st.title(dest_title)
        close_col, fav_col, visited_col_btn, comment_col_btn, _ = st.columns([1, 1.5, 1.5, 1.5, 4.5])
        with close_col:
            if st.button("✖ Close tab", key=f"close_{destination_name}"):
                open_destinations = st.session_state.get("open_destinations", [])
                if destination_name in open_destinations:
                    open_destinations.remove(destination_name)
                    st.session_state["open_destinations"] = open_destinations
                overview_page = st.session_state.get("_overview_page")
                if overview_page is not None:
                    st.switch_page(overview_page)

        with fav_col:
            is_favorite = False
            if nearer_col and nearer_col in selected_row:
                val = selected_row[nearer_col]
                if pd.notna(val):
                    val_str = str(val).strip().lower()
                    if val is True or "x" in val_str or val_str in {"yes", "y", "true", "1", "ja", "j"}:
                        is_favorite = True

            fav_label = "Remove from Favorities" if is_favorite else "Add to Favorites"
            if st.button(fav_label, key=f"fav_{destination_name}"):
                update_favorite_status(destination_name, add=not is_favorite)
                st.rerun()

        with visited_col_btn:
            visited_value = selected_row.get(visited_col) if visited_col else None
            is_visited = pd.notna(visited_value) and str(visited_value).strip().lower() in {
                "true", "yes", "y", "1", "ja", "j", "x"
            }
            visited_label = "Mark as not visited" if is_visited else "Mark as visited"
            if st.button(visited_label, key=f"visited_{destination_name}"):
                update_visited_status(destination_name, visited=not is_visited)
                st.rerun()

        with comment_col_btn:
            _render_comment_toggle(destination_name, comment_value)

    # Small icon-button styling for the "✏️ Edit Prio Thorsten" button so the
    # pen is centered and the default bordered box is removed (matches the
    # gallery's 🔄 replace buttons). A MutationObserver re-tags on every rerun.
    st.html(
        """
        <style>
            button.prio-edit-btn {
                padding: 0 !important;
                min-height: 0 !important;
                min-width: 24px !important;
                height: 2em !important;
                width: 100% !important;
                border: none !important;
                background: transparent !important;
                box-shadow: none !important;
                display: inline-flex !important;
                align-items: center !important;
                justify-content: center !important;
                line-height: 1 !important;
                cursor: pointer !important;
            }
            button.prio-edit-btn p {
                margin: 0 !important;
                padding: 0 !important;
                line-height: 1 !important;
                font-size: 1.1rem !important;
            }
            button.prio-edit-btn:hover {
                background: rgba(0,0,0,0.06) !important;
                border-radius: 6px !important;
            }
        </style>
        <script>
            (function() {
                function tagPrioEditButtons() {
                    document.querySelectorAll('button').forEach(function(btn) {
                        var text = (btn.textContent || '').trim();
                        if (text === '✏️') {
                            btn.classList.add('prio-edit-btn');
                        }
                    });
                }
                tagPrioEditButtons();
                var observer = new MutationObserver(function() {
                    tagPrioEditButtons();
                });
                observer.observe(document.body, { childList: true, subtree: true });
            })();
        </script>
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
    if cost_col:
        metrics.append(("Avg. Cost/Day", selected_row.get(cost_col), "€", "high"))
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

                col_left, col_right = st.columns([5, 1])
                with col_left:
                    st.markdown(_format_metric_box(column, value, suffix, mode), unsafe_allow_html=True)
                with col_right:
                    if st.button("✏️", key=edit_button_key, help="Edit Prio Thorsten"):
                        st.session_state[edit_state_key] = True

                if st.session_state.get(edit_state_key):
                    current_value = 0
                    if pd.notna(value) and str(value).strip() != "":
                        try:
                            current_value = int(float(value))
                        except (ValueError, TypeError):
                            current_value = 0
                    new_value = st.number_input("Prio Thorsten", min_value=0, max_value=10, value=current_value, step=1, key=input_key)
                    if st.button("Save", key=save_key):
                        update_prio_thorsten(destination_name, new_value)
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
    logistics_col1, logistics_col2 = st.columns(2)
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

    _render_food_section(
        destination_name,
        dest_title,
        selected_row,
        metadata,
        food_spiciness,
        food_description,
    )

    if month_columns:
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

            html_parts = ["<div style='display:grid;grid-template-columns:repeat(4, minmax(140px, 1fr));gap:10px'>"]
            for label, level in month_values:
                color = "#f4f4f4"
                if level in {"ideal", "good", "great", "best", "green"}:
                    color = "#2ecc71"
                elif level in {"ok", "okay", "medium", "yellow"}:
                    color = "#f1c40f"
                elif level in {"bad", "poor", "red", "worst"}:
                    color = "#e74c3c"
                html_parts.append(f"<div style='padding:12px;border-radius:10px;background:{color};color:#111;text-align:center'><strong>{label}</strong><br>{level.title() if level else '—'}</div>")
            html_parts.append("</div>")
            st.markdown("".join(html_parts), unsafe_allow_html=True)

        if "Avoid Going There" in df.columns and pd.notna(selected_row["Avoid Going There"]):
            avoid_text = html.escape(str(selected_row["Avoid Going There"]).strip())
            st.markdown(
                f"<div style='margin-top:12px;'><strong>Avoid Going There</strong><br>{avoid_text}</div>",
                unsafe_allow_html=True,
            )

    # ── Climate Dashboard ───────────────────────────────────────────────────
    render_climate_dashboard(str(selected_row[destination_col]).strip(), selected_row, df)

    # ── Destination Gallery (Unsplash) ──────────────────────────────────────
    render_destination_gallery(dest_title, selected_row, metadata)


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
