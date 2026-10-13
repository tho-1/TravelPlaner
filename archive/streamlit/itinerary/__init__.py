"""Itinerary planner core package.

Pure-logic modules (no Streamlit imports) so everything is unit-testable:

- models      trip/variant/stop/leg dict builders + normalization
- storage     atomic trips.json load/save + export
- geo         coordinates, great-circle math, arrowheads, view fitting
- geocode     Open-Meteo geocoding with a small disk cache
- itinerary   variant/stop operations, totals, warnings, suggested months
- map         Plotly figure builder for the active variant
- sample      bundled seed trip (China 2027, no network needed)
"""

from __future__ import annotations
