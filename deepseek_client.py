"""DeepSeek API client that generates a full destination profile as JSON.

This module only talks to the DeepSeek chat-completions API (OpenAI-compatible)
and returns the parsed JSON payload. The workbook row is written by
``deepseek_populator``, which also turns the review aspects into a standardized
score using ``review_analyzer``.

API key resolution order:
1. ``deepseek_secrets.py`` (local, gitignored module) -> ``DEEPSEEK_API_KEY``
2. ``DEEPSEEK_API_KEY`` environment variable
3. Streamlit secrets (``st.secrets["DEEPSEEK_API_KEY"]``)
"""

from __future__ import annotations

import json
import os
import re
from typing import Any, Dict, Optional

import requests

DEEPSEEK_API_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_DEFAULT_MODEL = "deepseek-chat"
REQUEST_TIMEOUT = 180  # seconds; profile JSON + climate arrays can be slow


def get_api_key() -> Optional[str]:
    """Return the configured DeepSeek API key, or ``None`` if not configured."""
    key = ""
    try:
        import deepseek_secrets  # local, gitignored module
    except Exception:
        deepseek_secrets = None
    if deepseek_secrets is not None:
        key = getattr(deepseek_secrets, "DEEPSEEK_API_KEY", "") or ""
    if not key:
        key = os.environ.get("DEEPSEEK_API_KEY", "") or ""
    if not key:
        try:
            import streamlit as st

            key = st.secrets.get("DEEPSEEK_API_KEY", "") or ""
        except Exception:
            key = ""
    if isinstance(key, str):
        key = key.strip()
    return key or None


def get_model() -> str:
    """Return the configured model name (default ``deepseek-chat``)."""
    try:
        import deepseek_secrets  # local, gitignored module
    except Exception:
        deepseek_secrets = None
    model = ""
    if deepseek_secrets is not None:
        model = getattr(deepseek_secrets, "DEEPSEEK_MODEL", "") or ""
    if isinstance(model, str):
        model = model.strip()
    return model or DEEPSEEK_DEFAULT_MODEL


def _extract_json(text: str) -> Dict[str, Any]:
    """Parse a JSON object out of a chat response (tolerates ```json fences)."""
    text = (text or "").strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL | re.IGNORECASE)
    if fence:
        text = fence.group(1).strip()
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end > start:
        text = text[start:end + 1]
    return json.loads(text)


_SYSTEM_PROMPT = (
    "You are a meticulous travel-research assistant. Given a destination, you "
    "return exactly one JSON object containing everything needed for a travel "
    "planner workbook: a written destination profile, a review sentiment "
    "breakdown, and monthly climate data. Output ONLY valid JSON — no prose, "
    "no markdown, no code fences."
)

# Plain template (not an f-string) so the JSON braces don't need escaping.
# Destination / country / continent are injected with .replace() below.
_USER_TEMPLATE = """Return ONLY a JSON object for the travel destination "__DEST__" in __COUNTRY__ (__CONTINENT__).

Use exactly this schema:
{
  "destination": "__DEST__",
  "country": "__COUNTRY__",
  "continent": "__CONTINENT__",
  "profile": {
    "why_to_go": "2-3 sentence pitch",
    "what_to_expect": "3-4 sentence description of what it is like there",
    "ideal_time_to_go": "e.g. Spring (April-May) and Autumn (September-October)",
    "avoid_going": "e.g. Winter (December-February) (very cold)",
    "recommended_stay": "e.g. 3-4 days",
    "avg_cost_per_day_eur": number,
    "rent_a_car": "No" or "Yes" or "Sometimes",
    "highlights": "a sentence listing the top highlights",
    "population_metro": number of people (metro area, NOT millions),
    "reachable_via": "e.g. High-speed rail, Flights to XXX",
    "visa_requirement": "for German citizens, one of: 'Not at all' / 'ETA' / 'Visa on arrival' / 'Apply beforehand'",
    "flight_time_hours": number (flight time from Frankfurt),
    "safety_rating_10": number from 0 to 10 (10 = safest),
    "introduction_sentence": "one catchy introductory sentence",
    "in_eu": true or false,
    "month_ratings": {
      "January": "ideal|ok|bad", "February": "ideal|ok|bad", "March": "ideal|ok|bad",
      "April": "ideal|ok|bad", "May": "ideal|ok|bad", "June": "ideal|ok|bad",
      "July": "ideal|ok|bad", "August": "ideal|ok|bad", "September": "ideal|ok|bad",
      "October": "ideal|ok|bad", "November": "ideal|ok|bad", "December": "ideal|ok|bad"
    }
  },
  "reviews": {
    "praise": "detailed paragraph of 5 to 10 complete sentences about what travelers praise",
    "dislikes": "detailed paragraph of 5 to 10 complete sentences about recurring criticisms and dislikes",
    "total_reviews_analyzed": 100,
    "date_range": "Feb 2024 - Feb 2026",
    "aspects": {
      "Scenery & atmosphere": {"pos": int, "neutral": int, "neg": int},
      "Things to do": {"pos": int, "neutral": int, "neg": int},
      "Food & drink": {"pos": int, "neutral": int, "neg": int},
      "Value for money": {"pos": int, "neutral": int, "neg": int},
      "Crowds & overtourism": {"pos": int, "neutral": int, "neg": int},
      "Safety & cleanliness": {"pos": int, "neutral": int, "neg": int},
      "Getting around / accessibility": {"pos": int, "neutral": int, "neg": int}
    },
    "platform_ratings": [
      {"source_name": "Google Maps", "avg_rating": number 1-5, "review_count": int},
      {"source_name": "TripAdvisor", "avg_rating": number 1-5, "review_count": int}
    ]
  },
  "climate": {
    "high_c": [12 numbers, January to December],
    "low_c": [12 numbers, January to December],
    "rainy_days": [12 numbers, January to December],
    "rain_mm": [12 numbers, January to December],
    "aqi": [12 numbers, January to December]
  }
}

Rules:
- month_ratings values must be exactly "ideal", "ok", or "bad".
- "praise" and "dislikes" must each be a detailed, comprehensive paragraph containing 5 to 10 complete sentences.
- Each aspect's pos+neutral+neg should be realistic; the positive share should
  reflect how much travelers like that aspect for this destination.
- Each climate array must contain exactly 12 numbers, ordered January through December.
- avg_cost_per_day_eur is for a 3-star hotel plus food, in EUR.
- population_metro is the metro-area population in people (not millions).
- All values must be plausible for the real destination (real climate, real visa
  rules, real safety, real flight times from Frankfurt, Germany).
"""


def _user_prompt(destination: str, country: str, continent: str) -> str:
    return (
        _USER_TEMPLATE.replace("__DEST__", str(destination).strip())
        .replace("__COUNTRY__", str(country).strip())
        .replace("__CONTINENT__", str(continent).strip())
    )


def generate_destination_profile(destination: str, country: str, continent: str) -> Dict[str, Any]:
    """Call DeepSeek and return the parsed JSON profile dict.

    Raises ``RuntimeError`` with a user-friendly message on any failure
    (missing key, HTTP error, timeout, unparseable response).
    """
    key = get_api_key()
    if not key:
        raise RuntimeError(
            "The DeepSeek API key is not configured. Create a `deepseek_secrets.py` "
            "file in the project folder with `DEEPSEEK_API_KEY = \"...\"` (or set the "
            "DEEPSEEK_API_KEY environment variable) and try again."
        )

    payload = {
        "model": get_model(),
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": _user_prompt(destination, country, continent)},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.3,
    }
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }

    try:
        resp = requests.post(
            DEEPSEEK_API_URL, json=payload, headers=headers, timeout=REQUEST_TIMEOUT
        )
    except requests.exceptions.Timeout:
        raise RuntimeError("The DeepSeek API request timed out. Please try again.") from None
    except requests.exceptions.RequestException as exc:
        raise RuntimeError(f"Could not reach the DeepSeek API: {exc}") from exc

    if resp.status_code != 200:
        raise RuntimeError(
            f"DeepSeek API request failed (HTTP {resp.status_code}): {resp.text[:300]}"
        )

    try:
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        return _extract_json(content)
    except (KeyError, IndexError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"DeepSeek returned an unparseable response: {exc}") from exc


def generate_malaria_risk(destination: str, country: str) -> Dict[str, Any]:
    """Ask DeepSeek for city-specific malaria guidance as structured JSON."""
    key = get_api_key()
    if not key:
        raise RuntimeError(
            "The DeepSeek API key is not configured. Create a `deepseek_secrets.py` "
            "file with `DEEPSEEK_API_KEY = \"...\"` or set the environment variable."
        )

    system_prompt = (
        "You are a careful travel-health research assistant. Assess malaria risk "
        "for the named destination city, not merely its country. Return only valid "
        "JSON and never invent city-level certainty."
    )
    user_prompt = f"""Assess malaria risk for the destination city "{str(destination).strip()}" in {str(country).strip()}.

Return exactly this JSON schema:
{{
  "status": "no" | "near zero" | "yes" | "unknown",
  "description": "short city-specific explanation",
  "city_specific": true | false,
  "source_note": "brief note about the guidance used"
}}

Rules:
- Use current WHO or CDC-style travel-health guidance where possible.
- Assess the city or immediate urban area separately from rural or regional areas.
- "near zero" is appropriate when urban risk is minimal but risk exists outside the city.
- Use "unknown" or city_specific false if you cannot support a city-level answer.
- Do not infer the city's risk solely from the country's overall malaria status.
- Keep description and source_note concise.
"""
    payload = {
        "model": get_model(),
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.1,
    }
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }

    try:
        resp = requests.post(
            DEEPSEEK_API_URL, json=payload, headers=headers, timeout=REQUEST_TIMEOUT
        )
    except requests.exceptions.Timeout:
        raise RuntimeError("The DeepSeek API request timed out. Please try again.") from None
    except requests.exceptions.RequestException as exc:
        raise RuntimeError(f"Could not reach the DeepSeek API: {exc}") from exc

    if resp.status_code != 200:
        raise RuntimeError(
            f"DeepSeek API request failed (HTTP {resp.status_code}): {resp.text[:300]}"
        )

    try:
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        result = _extract_json(content)
    except (KeyError, IndexError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"DeepSeek returned an unparseable response: {exc}") from exc

    status = str(result.get("status", "")).strip().lower()
    description = str(result.get("description", "")).strip()
    city_specific = result.get("city_specific") is True
    if status not in {"no", "near zero", "yes"} or not description or not city_specific:
        raise RuntimeError(
            "DeepSeek did not return a sufficiently supported city-level malaria assessment."
        )
    return {"status": status, "description": description}


def generate_food_profile(destination: str, country: str) -> Dict[str, Any]:
    """Ask DeepSeek for a city-specific food description and spice rating."""
    key = get_api_key()
    if not key:
        raise RuntimeError(
            "The DeepSeek API key is not configured. Create a `deepseek_secrets.py` "
            "file with `DEEPSEEK_API_KEY = \"...\"` or set the environment variable."
        )

    system_prompt = (
        "You are a precise travel food researcher. Return only valid JSON. "
        "Write grounded, specific information about local food in the named city."
    )
    user_prompt = f"""Describe the local food in {str(destination).strip()}, {str(country).strip()}.

Return exactly this JSON object:
{{
  "spiciness": number,
  "description": "one paragraph of 5 to 10 sentences"
}}

Rules:
- Focus especially on how spicy the local food is and mention representative dishes.
- Rate spiciness from 0 (not spicy at all) to 10 (Sichuan spicy); values above 10 are allowed.
- The description must be one paragraph containing 5 to 10 complete sentences.
- Discuss the typical local food, not only one restaurant or isolated dish.
"""
    payload = {
        "model": get_model(),
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.3,
    }
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}

    try:
        resp = requests.post(
            DEEPSEEK_API_URL, json=payload, headers=headers, timeout=REQUEST_TIMEOUT
        )
    except requests.exceptions.Timeout:
        raise RuntimeError("The DeepSeek API request timed out. Please try again.") from None
    except requests.exceptions.RequestException as exc:
        raise RuntimeError(f"Could not reach the DeepSeek API: {exc}") from exc

    if resp.status_code != 200:
        raise RuntimeError(
            f"DeepSeek API request failed (HTTP {resp.status_code}): {resp.text[:300]}"
        )

    try:
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        result = _extract_json(content)
    except (KeyError, IndexError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"DeepSeek returned an unparseable response: {exc}") from exc

    try:
        spiciness = float(result["spiciness"])
    except (KeyError, TypeError, ValueError) as exc:
        raise RuntimeError("DeepSeek returned an invalid food spiciness rating.") from exc
    description = str(result.get("description", "")).strip()
    sentence_count = len(re.findall(r"[^.!?]+[.!?](?:\s|$)", description))
    if spiciness < 0 or not description or not 5 <= sentence_count <= 10:
        raise RuntimeError(
            "DeepSeek returned an invalid food profile; expected a 5-10 sentence "
            "paragraph and a non-negative spiciness rating."
        )
    return {"spiciness": spiciness, "description": description}


def generate_review_profile(destination: str, country: str) -> Dict[str, Any]:
    """Ask DeepSeek for structured, destination-specific review data."""
    key = get_api_key()
    if not key:
        raise RuntimeError(
            "The DeepSeek API key is not configured. Create a `deepseek_secrets.py` "
            "file with `DEEPSEEK_API_KEY = \"...\"` or set the environment variable."
        )

    aspects = [
        "Scenery & atmosphere", "Things to do", "Food & drink",
        "Value for money", "Crowds & overtourism", "Safety & cleanliness",
        "Getting around / accessibility",
    ]
    aspect_schema = ", ".join(
        f'"{aspect}": {{"pos": int, "neutral": int, "neg": int}}'
        for aspect in aspects
    )
    user_prompt = f"""Research genuine traveler review patterns for {str(destination).strip()}, {str(country).strip()}.

Return only this JSON object:
{{
  "praise": "detailed paragraph of 5 to 10 specific sentences about what travelers praise",
  "dislikes": "detailed paragraph of 5 to 10 specific sentences about recurring criticisms and dislikes",
  "total_reviews_analyzed": 100,
  "date_range": "e.g. Feb 2024 - Feb 2026",
  "aspects": {{{aspect_schema}}},
  "platform_ratings": [
    {{"source_name": "Google Maps", "avg_rating": number from 1 to 5, "review_count": integer}},
    {{"source_name": "TripAdvisor", "avg_rating": number from 1 to 5, "review_count": integer}}
  ]
}}

Rules:
- "praise" and "dislikes" must each be a detailed, comprehensive paragraph containing 5 to 10 complete sentences.
- Use specific, destination-relevant observations; do not use generic wording such as
  "distinctive cultural and scenic attractions" without naming what travelers praise.
- Treat the values as an evidence-based summary, not invented certainty. Keep all
  counts and ratings plausible for this destination.
- Every aspect must have integer pos, neutral, and neg counts, with realistic totals.
"""
    payload = {
        "model": get_model(),
        "messages": [
            {"role": "system", "content": "You are a meticulous travel review researcher. Return only valid JSON."},
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.2,
    }
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}

    try:
        resp = requests.post(
            DEEPSEEK_API_URL, json=payload, headers=headers, timeout=REQUEST_TIMEOUT
        )
    except requests.exceptions.Timeout:
        raise RuntimeError("The DeepSeek API request timed out. Please try again.") from None
    except requests.exceptions.RequestException as exc:
        raise RuntimeError(f"Could not reach the DeepSeek API: {exc}") from exc

    if resp.status_code != 200:
        raise RuntimeError(
            f"DeepSeek API request failed (HTTP {resp.status_code}): {resp.text[:300]}"
        )
    try:
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        result = _extract_json(content)
    except (KeyError, IndexError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"DeepSeek returned an unparseable response: {exc}") from exc

    if not str(result.get("praise", "")).strip() or not str(result.get("dislikes", "")).strip():
        raise RuntimeError("DeepSeek returned incomplete review text.")
    if not isinstance(result.get("aspects"), dict) or not isinstance(result.get("platform_ratings"), list):
        raise RuntimeError("DeepSeek returned an incomplete review breakdown.")
    return result


def generate_flight_routes(destination: str, country: str) -> Dict[str, Any]:
    """Ask DeepSeek for comprehensive direct flight routes (inbound & outbound) and high-speed rail connections."""
    from datetime import datetime

    key = get_api_key()
    if not key:
        raise RuntimeError(
            "The DeepSeek API key is not configured. Create a `deepseek_secrets.py` "
            "file with `DEEPSEEK_API_KEY = \"...\"` or set the environment variable."
        )

    is_china = any(
        c in str(country).strip().lower() for c in ["china", "peoples republic of china", "prc", "cn"]
    ) or str(destination).strip().lower() in {
        "nanchang", "beijing", "shanghai", "guangzhou", "shenzhen", "chengdu", "chongqing",
        "hangzhou", "xian", "xi'an", "wuhan", "nanjing", "tianjin", "suzhou", "changsha",
        "zhengzhou", "qingdao", "dalian", "kunming", "xiamen", "fuzhou", "harbin", "guilin",
        "sanya", "haikou", "urumqi", "lhasa", "guiyang", "nanning", "hefei", "jinan"
    }

    hsr_schema = ""
    if is_china:
        hsr_schema = """
  "train_stations": ["Primary High-Speed Railway Stations (e.g. Nanchang West Railway Station / 南昌西站, Nanchang Railway Station / 南昌站)"],
  "hsr_routes": [
    {
      "destination_city": "City name (e.g. Changsha)",
      "destination_station": "Arrival Station (e.g. Changsha South)",
      "origin_station": "Departure Station (e.g. Nanchang West)",
      "duration": "Typical Travel Time (e.g. 1h 15m - 1h 35m)",
      "train_types": "G-Train (High-Speed 300-350 km/h) / D-Train",
      "frequency_notes": "e.g. 30+ daily trains (every 15-30 mins)"
    }
  ],"""

    user_prompt = f"""Research all major direct passenger flight routes (inbound and outbound) and operating airlines departing from or arriving at {str(destination).strip()}, {str(country).strip()}.
{"Also research all major High-Speed Railway (HSR / 高铁/动车) connections from this city to other Chinese cities." if is_china else ""}

Return ONLY this JSON object:
{{
  "airport_name": "Primary Airport Name (e.g. Nanchang Changbei International Airport)",
  "iata_code": "IATA code (e.g. KHN)",
  "city": "{str(destination).strip()}",
  "country": "{str(country).strip()}",{hsr_schema}
  "routes": [
    {{
      "destination_city": "City name (e.g. Shanghai)",
      "destination_country": "Country name (e.g. China)",
      "destination_iata": "Airport code(s) (e.g. SHA / PVG)",
      "airlines": ["Airline A", "Airline B"],
      "flight_time": "Estimated flight time (e.g. 1h 45m)",
      "route_type": "Domestic" | "International" | "Regional",
      "frequency_notes": "e.g. Multiple flights daily / Daily / 3x weekly / Seasonal"
    }}
  ]
}}

Rules:
- Include all major direct non-stop destinations that regularly have passenger service from this city's airport(s).
- Direct passenger routes operate bidirectionally (inbound and outbound).
- Ensure the operating airlines list and flight_time estimate (e.g. "2h 15m") are accurate for each route.
- Set route_type appropriately:
  * "Domestic" for domestic flights within the same country
  * "Regional" for Hong Kong, Macau, Taiwan (if applicable) or close regional dependencies
  * "International" for cross-border international destinations
- Provide between 15 to 45 direct flight routes if the airport is a medium/large hub, or all known direct routes if it is a smaller airport.
{"- Provide 15 to 30 major direct High-Speed Rail (HSR) connections to other prominent Chinese cities with accurate travel times." if is_china else ""}
- Return ONLY valid JSON.
"""

    payload = {
        "model": get_model(),
        "messages": [
            {
                "role": "system",
                "content": "You are a professional aviation network and high-speed rail transit analyst. Return only valid JSON.",
            },
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.1,
    }
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}

    try:
        resp = requests.post(
            DEEPSEEK_API_URL, json=payload, headers=headers, timeout=REQUEST_TIMEOUT
        )
    except requests.exceptions.Timeout:
        raise RuntimeError("The transport connections request timed out. Please try again.") from None
    except requests.exceptions.RequestException as exc:
        raise RuntimeError(f"Could not reach the DeepSeek API: {exc}") from exc

    if resp.status_code != 200:
        raise RuntimeError(
            f"DeepSeek API request failed (HTTP {resp.status_code}): {resp.text[:300]}"
        )

    try:
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        result = _extract_json(content)
    except (KeyError, IndexError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"DeepSeek returned an unparseable response: {exc}") from exc

    if not isinstance(result.get("routes"), list):
        raise RuntimeError("DeepSeek returned an invalid flight route list.")

    result["last_updated"] = datetime.now().strftime("%d %b %Y")
    return result
