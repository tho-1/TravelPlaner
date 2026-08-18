import base64
import html
import io
from PIL import Image

import pandas as pd
import streamlit as st

from data_utils import DATA_PATH, load_destinations, update_favorite_status, update_prio_thorsten


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


def render_destination(destination_name: str):
    df, metadata = load_destinations(DATA_PATH)

    if df.empty:
        st.warning("No data available.")
        return

    destination_col = metadata["destination_col"]
    eu_col = metadata["eu_col"]
    nearer_col = metadata["nearer_col"]
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
    month_columns = metadata["month_columns"]

    matches = df[df[destination_col].astype(str).str.strip().str.lower() == str(destination_name).strip().lower()]
    if matches.empty:
        st.warning(f"Destination '{destination_name}' could not be found.")
        return

    selected_row = matches.iloc[0]
    dest_title = str(selected_row[destination_col])

    # Check for destination picture in Pictures directory
    pictures_dir = DATA_PATH.parent / "Pictures"
    image_path = None
    if pictures_dir.exists():
        # Look for <Destination>_1.jpg, <Destination>_1.jpeg, <Destination>_1.png (case-insensitive)
        candidates = [
            f"{dest_title}_1.jpg", f"{dest_title}_1.jpeg", f"{dest_title}_1.png",
            f"{destination_name}_1.jpg", f"{destination_name}_1.jpeg", f"{destination_name}_1.png",
        ]
        existing_files = {f.name.lower(): f for f in pictures_dir.iterdir() if f.is_file()}
        for cand in candidates:
            if cand.lower() in existing_files:
                image_path = existing_files[cand.lower()]
                break

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

        close_col, fav_col, _ = st.columns([1, 1.5, 6])
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
    else:
        st.title(dest_title)
        close_col, fav_col, _ = st.columns([1, 1.5, 6])
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
    if visa_requirement_col and visa_requirement_col in selected_row.index and pd.notna(selected_row[visa_requirement_col]):
        overview_texts.append(("Visa Requirement", str(selected_row[visa_requirement_col]).strip()))

    if overview_texts:
        for label, value in overview_texts:
            st.markdown(f"**{label}:**")
            st.write(value)
    else:
        st.write("No overview text was found in the workbook.")

    if highlights_col and pd.notna(selected_row[highlights_col]):
        highlights_text = str(selected_row[highlights_col]).strip()
        if highlights_text:
            st.markdown("**Highlights:**")
            st.write(highlights_text)
        else:
            st.write("No highlight notes were found in the workbook.")
    else:
        st.write("No highlight notes were found in the workbook.")

    if month_columns:
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
            st.markdown("**Avoid Going There:**")
            st.write(str(selected_row["Avoid Going There"]).strip())

    # ── Climate Dashboard ───────────────────────────────────────────────────
    render_climate_dashboard(str(selected_row[destination_col]).strip(), selected_row, df)


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

    header_col1, header_col2 = st.columns([4, 1.5])
    with header_col1:
        st.subheader("🌍 DESTINATION CLIMATE DASHBOARD ☁️")
        st.caption("Annual climate profile, monthly temperatures, precipitation, and air quality index trends.")
    with header_col2:
        unit = st.radio("Temperature Unit", ["°C", "°F"], horizontal=True, key=f"climate_unit_{destination_name}")

    if not has_data:
        st.info(f"Detailed monthly climate and air quality data is currently being populated for **{destination_name}**.")
        return

    is_f = (unit == "°F")
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
    st.markdown("#### 🌧️ Monthly Temperature & Rainfall")
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

    st.plotly_chart(fig_temp_rain, use_container_width=True)

    # ── Chart 2: Air Quality Index (AQI) Profile ────────────────────────────
    st.markdown("#### 🍃 Air Quality Index (AQI) Profile")
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

    st.plotly_chart(fig_aqi, use_container_width=True)
