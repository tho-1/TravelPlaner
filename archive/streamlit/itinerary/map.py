"""Plotly map for the active variant — same LIGHT theme as the world map.

One traces per transport mode (dashed for flight/other), arrowhead wings on
each leg, gold stop markers numbered in visit order, gray diamond gateways,
and a cyan open-circle halo on the selected stop. The figure auto-fits to the
route's bounding box (with padding), so a China trip doesn't show Frankfurt.
"""

from __future__ import annotations

import plotly.graph_objects as go

from . import geo
from . import itinerary as ops

MODE_STYLES = {
    "flight": {"color": "#3b82f6", "dash": "dash", "label": "✈ Flight",
               "width": 2.0},
    "train":  {"color": "#f59e0b", "dash": "solid", "label": "🚆 Train",
               "width": 2.4},
    "bus":    {"color": "#3ecf8e", "dash": "solid", "label": "🚌 Bus",
               "width": 2.2},
    "car":    {"color": "#8b98ab", "dash": "solid", "label": "🚗 Car",
               "width": 2.2},
    "boat":   {"color": "#2dd4bf", "dash": "solid", "label": "⛴ Boat",
               "width": 2.2},
    "other":  {"color": "#94a3b8", "dash": "dash", "label": "• Other",
               "width": 2.0},
}
STOP_COLOR = "#fbbf24"          # gold
STOP_FINAL_OUTLINE = "#b45309"  # darker outline for the last stop
GATEWAY_COLOR = "#8b98ab"       # gray diamonds
SELECT_COLOR = "#40c4ff"        # cyan halo on the selected stop


def _geo_theme() -> dict:
    return dict(
        showcountries=True, countrycolor="#c8d6e5",
        showocean=True, oceancolor="#eef2f7",
        showland=True, landcolor="#f5f6fa",
        showlakes=True, lakecolor="#eef2f7",
        showrivers=False,
        showcoastlines=True, coastlinecolor="#c8d6e5",
        projection_type="natural earth",
    )


def _align_lon(lon: float, center_lon: float) -> float:
    """Shift ``lon`` by whole turns so it sits closest to the view centre.

    The view frame may be unwrapped (e.g. 140..242° for a Tokyo -> Los Angeles
    route); markers must be shifted into that same frame or they end up a full
    turn away from the line they belong to.
    """
    return lon + 360.0 * round((center_lon - lon) / 360.0)


def build_figure(variant: dict, selected_stop_id: str | None = None,
                 visible_modes: set[str] | None = None,
                 show_gateways: bool = True,
                 fit_points: list | None = None) -> go.Figure:
    """Build the route map.

    visible_modes: None = all, else a set like {"flight", "train"}.
    show_gateways: toggle the gray diamond gateway markers.
    fit_points: override the auto bounding box (e.g. country focus).
    Each trace carries meta=[tag] (mode name or "gateway"/"stop") so callers
    can filter figure traces further if needed.
    """
    fig = go.Figure()

    # Resolve coordinates once so totals/warnings and the map agree.
    ops.resolve_variant_coords(variant)

    stops = variant.get("stops", [])
    legs = variant.get("legs", [])

    # ── view first: everything is drawn in this (possibly unwrapped) frame ──
    if fit_points is None:
        framed = ([s for s in stops
                   if s["ref"].get("kind") != "gateway"] or stops)
        pts = []
        for stop in framed:
            ref = stop["ref"]
            if None not in (ref.get("lat"), ref.get("lon")):
                pts.append((ref["lat"], ref["lon"]))
    else:
        pts = fit_points
    view = geo.fit_view(pts)
    center_lon = view["center"]["lon"]

    def _in_frame(lon: float) -> float:
        """Shift one longitude into the view frame (constant per point)."""
        return _align_lon(lon, center_lon)

    # ── group legs by mode so each mode becomes one legend entry ────────────
    by_mode: dict[str, list] = {}
    mode_leg_count: dict[str, int] = {}
    for i, leg in enumerate(legs):
        if i + 1 >= len(stops):
            break
        a = stops[i]["ref"]
        b = stops[i + 1]["ref"]
        if None in (a.get("lat"), a.get("lon"), b.get("lon"), b.get("lon")):
            continue
        mode = leg.get("mode", "other")
        mode_leg_count[mode] = mode_leg_count.get(mode, 0) + 1
        segs = by_mode.setdefault(mode, [])
        # One constant shift per leg keeps the polyline continuous: a
        # transpacific hop keeps running past 180° instead of snapping back to
        # -180° and drawing a line across the whole map.
        shift = _in_frame(a["lon"]) - a["lon"]
        pts = geo.great_circle_points(a["lat"], a["lon"], b["lat"], b["lon"])
        pts = geo.unwrap_longitudes([(lat, lon + shift) for lat, lon in pts])
        segs.append(pts)
        wings = geo.arrow_wings(pts)
        if wings:
            # arrow_wings() returns normalised longitudes; re-anchor them to
            # the (possibly unwrapped) tip so the head does not jump a turn.
            wings = geo.unwrap_longitudes(wings)
            # A gap before the head as well: the tip sits mid-path, so without
            # it Plotly draws a stray line from the leg's end back to the tip.
            segs.extend([None, wings[:3], None, [wings[2], wings[3]]])
        segs.append(None)

    for mode, segs in by_mode.items():
        if visible_modes is not None and mode not in visible_modes:
            continue
        style = MODE_STYLES.get(mode, MODE_STYLES["other"])
        xs: list = []
        ys: list = []
        for seg in segs:
            if seg is None:
                xs.append(None)
                ys.append(None)
            else:
                for lat, lon in seg:
                    xs.append(lon)
                    ys.append(lat)
        fig.add_trace(go.Scattergeo(
            lon=xs, lat=ys, mode="lines",
            line=dict(width=style["width"], color=style["color"],
                      dash=style["dash"]),
            name=f"{style['label']} ({mode_leg_count[mode]})",
            hoverinfo="skip", showlegend=True, meta=[mode],
        ))

    # ── gateways ────────────────────────────────────────────────────────────
    gx: list[float] = []
    gy: list[float] = []
    gtext: list[str] = []
    for stop in stops:
        ref = stop["ref"]
        if ref.get("kind") == "gateway" and None not in (ref.get("lat"),
                                                         ref.get("lon")):
            gx.append(_in_frame(ref["lon"]))
            gy.append(ref["lat"])
            gtext.append(ref["name"])
    if gx and show_gateways:
        fig.add_trace(go.Scattergeo(
            lon=gx, lat=gy, mode="markers+text",
            marker=dict(symbol="diamond", size=11, color=GATEWAY_COLOR,
                        line=dict(width=1, color="#6b7688")),
            text=gtext, textposition="bottom center",
            textfont=dict(size=11, color="#42506b"),
            name="Gateway", hoverinfo="text", meta=["gateway"],
        ))

    # ── stops (only those with coordinates, kind != gateway) ─────────────────
    visible = [s for s in stops
               if s["ref"].get("kind") != "gateway"
               and None not in (s["ref"].get("lat"), s["ref"].get("lon"))]
    if visible:
        lats = [s["ref"]["lat"] for s in visible]
        lons = [_in_frame(s["ref"]["lon"]) for s in visible]
        nums = [str(i + 1) for i in range(len(visible))]
        names = [s["ref"].get("name", "?") for s in visible]
        outline_colors = [STOP_FINAL_OUTLINE if s is visible[-1] else "#ffffff"
                          for s in visible]
        fig.add_trace(go.Scattergeo(
            lon=lons, lat=lats, mode="markers+text",
            marker=dict(size=12, color=STOP_COLOR,
                        line=dict(width=2, color=outline_colors)),
            text=nums, textposition="middle center",
            textfont=dict(size=10, color="#42506b"),
            customdata=[s.get("id") for s in visible],
            name="Stop", hoverinfo="text", hovertext=names, meta=["stop"],
        ))
        # selection halo
        if selected_stop_id:
            for i, stop in enumerate(visible):
                if stop.get("id") == selected_stop_id:
                    fig.add_trace(go.Scattergeo(
                        lon=[lons[i]], lat=[lats[i]], mode="markers",
                        marker=dict(size=22, color="rgba(0,0,0,0)",
                                    line=dict(width=2.5, color=SELECT_COLOR)),
                        hoverinfo="skip", showlegend=False,
                    ))
                    break

    fig.update_layout(
        height=560,
        margin=dict(l=0, r=0, t=0, b=0),
        legend=dict(orientation="h", yanchor="bottom", y=0.01,
                    xanchor="left", x=0.01,
                    bgcolor="rgba(255,255,255,0.7)",
                    bordercolor="#c8d6e5", borderwidth=1),
        geo=dict(
            **_geo_theme(),
            **view,
        ),
        showlegend=True,
    )
    return fig
