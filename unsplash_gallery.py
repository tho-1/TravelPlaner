"""Unsplash image gallery fetcher + disk cache for destination detail pages.

Design goals
------------
- Fetch a small set of landscape photos per destination from the Unsplash
  search API (`<destination>, <country>` query).
- Persist them to a per-destination slugified subfolder under ``Pictures/gallery``
  so that opening the same destination a second time triggers **zero** new API
  requests (pure disk cache, survives app restarts).
- Provide a single ``GALLERY_IMAGE_COUNT`` knob so the count can be raised
  (e.g. 3 -> 10) later with no file-renaming refactor.
- Never raise into the UI: all failures degrade to an empty list + a graceful
  message rendered by the caller.

The only call that counts against the Unsplash 50 req/hour demo limit is the
single ``search/photos`` request per (re)fetch. Downloading the image bytes
from ``images.unsplash.com`` does not count against that limit.
"""

from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path
from typing import Optional

import requests

# ── Configuration ────────────────────────────────────────────────────────────
# Single knob for the number of gallery images per destination. Raise this
# (e.g. to 20) to extend the gallery with no other code changes needed.
GALLERY_IMAGE_COUNT = 20

UNSPLASH_SEARCH_URL = "https://api.unsplash.com/search/photos"
UNSPLASH_IMAGE_SIZE = "regular"  # ~1080px; see urls.* in the API response
REQUEST_TIMEOUT = 20  # seconds per HTTP call


# ── Secrets ──────────────────────────────────────────────────────────────────
def get_access_key() -> Optional[str]:
    """Return the Unsplash Access Key from ``unsplash_secrets.py``.

    Returns ``None`` if the module or key is missing (the caller degrades
    gracefully to an empty gallery).
    """
    try:
        import unsplash_secrets  # local, gitignored module
    except Exception:
        return None
    key = getattr(unsplash_secrets, "UNSPLASH_ACCESS_KEY", None)
    if isinstance(key, str):
        key = key.strip()
    return key or None


# ── Slugify (mirrors app.slugify so this module stays Streamlit-free) ─────────
def _slugify(value: str) -> str:
    """Lowercase, transliterate accents to ASCII, non-alphanumeric runs to ``-``.

    ``San José`` -> ``san-jose``, ``Ürümqi`` -> ``urumqi``, ``Mexico City`` -> ``mexico-city``.
    Re-implemented here to avoid importing the Streamlit-coupled ``app.py``.
    """
    value = str(value).strip().lower()
    # Transliterate accented chars to their ASCII base (é -> e, ü -> u) before
    # dropping remaining non-ASCII, so "San José" -> "san-jose", "Ürümqi" -> "urumqi".
    value = unicodedata.normalize("NFKD", value)
    value = value.encode("ascii", "ignore").decode("ascii")
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-")


# ── Cache layout ─────────────────────────────────────────────────────────────
def gallery_dir(destination_name: str, pictures_dir: Path) -> Path:
    """Return the per-destination gallery cache folder, e.g.
    ``<pictures_dir>/gallery/san-jose``.

    The folder is not created here; ``build_destination_gallery`` creates it on demand.
    """
    return pictures_dir / "gallery" / _slugify(destination_name)


def gallery_cache_paths(destination_name: str, pictures_dir: Path) -> dict:
    """Return the expected cache paths for a destination.

    Keys: ``images`` (list of ``1.jpg, 2.jpg, ...``) and ``metadata`` (the
    sidecar JSON path). The folder name is slugified for cross-platform safety.
    """
    folder = gallery_dir(destination_name, pictures_dir)
    images = [folder / f"{i + 1}.jpg" for i in range(GALLERY_IMAGE_COUNT)]
    return {"folder": folder, "images": images, "metadata": folder / "metadata.json"}


def load_cached_gallery(destination_name: str, pictures_dir: Path) -> Optional[list[dict]]:
    """Return cached gallery entries, or ``None`` if the cache is incomplete.

    A valid cache requires at least one cached image and the ``metadata.json``
    sidecar to exist. Partial galleries are valid because some Unsplash
    downloads may fail; each returned entry has:
    ``image_path`` (Path), ``photographer_name``, ``photographer_url``,
    ``photo_url``, ``alt``.
    """
    paths = gallery_cache_paths(destination_name, pictures_dir)
    if not paths["metadata"].exists():
        return None

    try:
        with open(paths["metadata"], "r", encoding="utf-8") as fh:
            entries = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None

    if not isinstance(entries, list) or not entries:
        return None

    # Re-attach resolved, up-to-date image paths (defensive: sidecar may hold
    # stringified paths from a previous run / different machine).
    result = []
    for i, entry in enumerate(entries[:GALLERY_IMAGE_COUNT]):
        if not isinstance(entry, dict):
            return None
        if not paths["images"][i].exists():
            return None
        copy = dict(entry)
        copy["image_path"] = paths["images"][i]
        result.append(copy)
    return result


# ── API ───────────────────────────────────────────────────────────────────────
# Unsplash search/photos caps per_page at 30.
UNSPLASH_MAX_PER_PAGE = 30


def fetch_unsplash_search(query: str, per_page: int, access_key: str, page: int = 1) -> list[dict]:
    """Call the Unsplash search endpoint and return the ``results`` array.

    ``per_page`` is capped at ``UNSPLASH_MAX_PER_PAGE`` (30). ``page`` is 1-based.
    Returns ``[]`` on any HTTP error, rate limit, or empty result so the caller
    never has to handle exceptions.
    """
    per_page = min(per_page, UNSPLASH_MAX_PER_PAGE)
    headers = {"Accept": "application/json"}
    params = {
        "query": query,
        "per_page": per_page,
        "orientation": "landscape",
        "content_filter": "high",  # filter out low-quality / sensitive content
        "client_id": access_key,  # Access Key as a query param (NOT Basic auth)
        "page": page,
    }
    try:
        resp = requests.get(
            UNSPLASH_SEARCH_URL,
            params=params,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception:
        return []

    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list):
        return []
    return results


def _extract_entry(photo: dict, image_path: Path) -> dict:
    """Build one gallery entry dict from a raw Unsplash photo JSON object."""
    urls = photo.get("urls") or {}
    user = photo.get("user") or {}
    links = photo.get("links") or {}
    return {
        "image_path": str(image_path),
        "photo_id": photo.get("id", ""),
        "photographer_name": user.get("name", "Unsplash"),
        "photographer_url": user.get("links", {}).get("html", "https://unsplash.com"),
        "photo_url": links.get("html", "https://unsplash.com"),
        "alt": photo.get("alt_description") or photo.get("description") or "",
        "thumb_url": urls.get("thumb", ""),
    }


def _download_image_bytes(url: str) -> Optional[bytes]:
    """Download raw image bytes from ``images.unsplash.com``. Returns ``None`` on failure."""
    try:
        resp = requests.get(url, timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
        return resp.content
    except Exception:
        return None


def _search_query(destination_name: str, country: Optional[str]) -> str:
    """Build an Unsplash query without province disambiguators in city names."""
    query = re.sub(r"\s*\([^)]*\)", "", str(destination_name).strip()).strip()
    if country and str(country).strip() and str(country).strip().lower() not in {"nan", "none", "null"}:
        query = f"{query}, {str(country).strip()}"
    return query


# ── Orchestrator ──────────────────────────────────────────────────────────────
def build_destination_gallery(
    destination_name: str,
    country: Optional[str],
    pictures_dir: Path,
    force_refresh: bool = False,
) -> list[dict]:
    """Return the gallery entries for a destination (cache-first).

    1. If not ``force_refresh`` and a complete cache exists -> return it (no API call).
    2. Otherwise query Unsplash for ``"<destination>, <country>"`` (destination-only
       fallback when country is missing), pick the first ``GALLERY_IMAGE_COUNT``
       results, download each image's ``urls.regular`` bytes, write them to
       ``1.jpg, 2.jpg, ...`` + a ``metadata.json`` sidecar, and return the entries.
    3. On any failure (no key, HTTP error, no results) return ``[]`` — never raises.

    Only the single search call counts against the Unsplash 50 req/hour limit.
    """
    # 1. Cache hit (no refresh requested)
    if not force_refresh:
        cached = load_cached_gallery(destination_name, pictures_dir)
        if cached is not None:
            return cached

    # 2. Need to fetch
    access_key = get_access_key()
    if not access_key:
        return []

    query = _search_query(destination_name, country)

    # Ask for more than we need so we still have enough if some downloads fail,
    # but cap at the Unsplash per-page maximum (30).
    per_page = min(max(GALLERY_IMAGE_COUNT * 2, 10), UNSPLASH_MAX_PER_PAGE)
    paths = gallery_cache_paths(destination_name, pictures_dir)
    folder: Path = paths["folder"]
    folder.mkdir(parents=True, exist_ok=True)

    entries: list[dict] = []
    saved_count = 0
    page = 1
    max_pages = 4  # safety cap to avoid hammering the API
    seen_ids: set[str] = set()

    while saved_count < GALLERY_IMAGE_COUNT and page <= max_pages:
        results = fetch_unsplash_search(query, per_page=per_page, access_key=access_key, page=page)
        if not results:
            break  # no more results available

        for photo in results:
            if saved_count >= GALLERY_IMAGE_COUNT:
                break
            # Skip duplicates across pages (defensive)
            photo_id = photo.get("id")
            if photo_id and photo_id in seen_ids:
                continue
            if photo_id:
                seen_ids.add(photo_id)

            urls = photo.get("urls") or {}
            image_url = urls.get(UNSPLASH_IMAGE_SIZE) or urls.get("regular") or urls.get("full")
            if not image_url:
                continue

            image_path = paths["images"][saved_count]
            data = _download_image_bytes(image_url)
            if not data:
                continue

            try:
                with open(image_path, "wb") as fh:
                    fh.write(data)
            except OSError:
                continue

            entries.append(_extract_entry(photo, image_path))
            saved_count += 1

        page += 1

    if not entries:
        # Nothing saved -> leave no empty folder behind if possible.
        try:
            folder.rmdir()
        except OSError:
            pass
        return []

    # Persist the sidecar with the entries (paths stored as strings for JSON).
    _save_metadata(paths, entries)

    return entries


def _save_metadata(paths: dict, entries: list[dict]) -> None:
    """Write the metadata.json sidecar (paths stored as strings for JSON)."""
    sidecar = [{k: (str(v) if isinstance(v, Path) else v) for k, v in e.items()} for e in entries]
    try:
        with open(paths["metadata"], "w", encoding="utf-8") as fh:
            json.dump(sidecar, fh, ensure_ascii=False, indent=2)
    except OSError:
        pass  # Non-fatal: images are cached, just no attribution sidecar.


def refresh_single_gallery_image(
    destination_name: str,
    country: Optional[str],
    pictures_dir: Path,
    index: int,
) -> Optional[dict]:
    """Replace a single gallery image at ``index`` (0-based) with a fresh one.

    For a partial gallery, rotates the next cached photo into the requested
    slot. For a full gallery, loads the cached metadata to collect all
    existing photo IDs, searches Unsplash, picks the first result whose ID
    isn't already used, downloads it to ``<index+1>.jpg``, updates the
    ``metadata.json`` sidecar entry, and returns the new entry. Returns
    ``None`` on any failure (never raises).
    """
    if index < 0 or index >= GALLERY_IMAGE_COUNT:
        return None

    paths = gallery_cache_paths(destination_name, pictures_dir)
    folder: Path = paths["folder"]
    if not folder.exists():
        return None
    history_path = folder / "replaced_photo_ids.json"

    # Load current entries from the sidecar (not via load_cached_gallery, which
    # requires ALL images to exist — here only the target slot may be missing).
    raw_entries: list = []
    try:
        if paths["metadata"].exists():
            with open(paths["metadata"], "r", encoding="utf-8") as fh:
                raw_entries = json.load(fh)
    except (OSError, json.JSONDecodeError):
        raw_entries = []
    if not isinstance(raw_entries, list):
        raw_entries = []

    # A partial gallery may not have another Unsplash result available. In
    # that case rotate the cached photos instead of repeatedly selecting the
    # same API result or rebuilding the gallery on the next rerun.
    if 0 < len(raw_entries) < GALLERY_IMAGE_COUNT:
        rotation_paths = paths["images"][index:len(raw_entries)]
        if len(rotation_paths) > 1:
            try:
                rotation_bytes = [path.read_bytes() for path in rotation_paths]
                for path, image_bytes in zip(rotation_paths, rotation_bytes[1:] + rotation_bytes[:1]):
                    path.write_bytes(image_bytes)
            except OSError:
                return None

            raw_entries[index:len(raw_entries)] = (
                raw_entries[index + 1:len(raw_entries)] + raw_entries[index:index + 1]
            )
            _save_metadata(paths, raw_entries)
            result = dict(raw_entries[index])
            result["image_path"] = paths["images"][index]
            return result

    # Exclude both current gallery photos and photos previously removed from a
    # slot. Without the history, replacing a slot can bring its old photo back.
    exclude_ids: set[str] = set()
    for entry in raw_entries:
        if isinstance(entry, dict):
            pid = entry.get("photo_id")
            if pid:
                exclude_ids.add(pid)
    try:
        with open(history_path, "r", encoding="utf-8") as fh:
            history = json.load(fh)
        if isinstance(history, list):
            exclude_ids.update(str(pid) for pid in history if pid)
    except (OSError, json.JSONDecodeError):
        history = []

    access_key = get_access_key()
    if not access_key:
        return None

    query = _search_query(destination_name, country)

    per_page = min(max(GALLERY_IMAGE_COUNT * 2, 10), UNSPLASH_MAX_PER_PAGE)
    chosen_photo: Optional[dict] = None
    page = 1
    max_pages = 4

    while chosen_photo is None and page <= max_pages:
        results = fetch_unsplash_search(query, per_page=per_page, access_key=access_key, page=page)
        if not results:
            break
        for photo in results:
            pid = photo.get("id")
            if pid and pid in exclude_ids:
                continue
            # Also skip photos already used in THIS search session's chosen set.
            chosen_photo = photo
            break
        page += 1

    if chosen_photo is None:
        return None

    image_path = paths["images"][index]
    urls = chosen_photo.get("urls") or {}
    image_url = urls.get(UNSPLASH_IMAGE_SIZE) or urls.get("regular") or urls.get("full")
    if not image_url:
        return None

    data = _download_image_bytes(image_url)
    if not data:
        return None

    try:
        with open(image_path, "wb") as fh:
            fh.write(data)
    except OSError:
        return None

    new_entry = _extract_entry(chosen_photo, image_path)

    old_entry = raw_entries[index] if index < len(raw_entries) else None
    old_photo_id = old_entry.get("photo_id") if isinstance(old_entry, dict) else None
    if old_photo_id:
        history = [str(pid) for pid in history if pid]
        if old_photo_id not in history:
            history.append(old_photo_id)
        try:
            with open(history_path, "w", encoding="utf-8") as fh:
                json.dump(history, fh, indent=2)
        except OSError:
            pass

    # Update the sidecar: grow the list if needed, replace the target entry.
    while len(raw_entries) <= index:
        raw_entries.append({})
    # Preserve the image_path that _extract_entry set (string form is fine for JSON).
    raw_entries[index] = {k: (str(v) if isinstance(v, Path) else v) for k, v in new_entry.items()}
    _save_metadata(paths, raw_entries)

    # Return entry with the resolved Path object for the caller.
    new_entry["image_path"] = image_path
    return new_entry


def clear_destination_gallery_cache(destination_name: str, pictures_dir: Path) -> bool:
    """Delete the per-destination gallery subfolder (images + sidecar).

    Used by the "Refresh images" button before re-fetching. Returns ``True`` if
    anything was removed.
    """
    import shutil

    folder = gallery_dir(destination_name, pictures_dir)
    if folder.exists():
        try:
            shutil.rmtree(folder)
            return True
        except OSError:
            return False
    return False
