"""DuckDuckGo image gallery fetcher + disk cache for destination detail pages.

Fetches web images per destination from DuckDuckGo Image search,
persisting them to ``Pictures/gallery_ddg/<slug>/`` with metadata.json sidecar.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import unicodedata
from pathlib import Path
from typing import Optional

import openpyxl
import requests

from data_utils import DATA_PATH, _find_destination_sheet

DDG_GALLERY_COUNT = 12
REQUEST_TIMEOUT = 12
THUMBNAIL_WIDTH = 600
THUMBNAIL_HEIGHT = 400


def _crop_and_save_thumbnail(image_data: bytes | Path, target_path: Path) -> bool:
    """Crop image to uniform 3:2 landscape thumbnail (600x400) and save as JPEG."""
    try:
        import io

        from PIL import Image, ImageOps
        if isinstance(image_data, bytes):
            im = Image.open(io.BytesIO(image_data))
        else:
            im = Image.open(image_data)

        if im.mode not in ("RGB", "L"):
            im = im.convert("RGB")
        cropped = ImageOps.fit(
            im,
            (THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT),
            method=Image.Resampling.LANCZOS,
            centering=(0.5, 0.5),
        )
        target_path.parent.mkdir(parents=True, exist_ok=True)
        cropped.save(target_path, "JPEG", quality=90)
        return True
    except Exception as exc:
        print(f"Failed to crop thumbnail for {target_path}: {exc}", flush=True)
        return False


def _slugify(value: str) -> str:
    """Lowercase, transliterate accents to ASCII, non-alphanumeric runs to ``-``."""
    value = str(value).strip().lower()
    value = unicodedata.normalize("NFKD", value)
    value = value.encode("ascii", "ignore").decode("ascii")
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-")


def ddg_gallery_dir(destination_name: str, pictures_dir: Path) -> Path:
    """Return the per-destination DuckDuckGo gallery cache folder."""
    return pictures_dir / "gallery_ddg" / _slugify(destination_name)


def load_cached_ddg_gallery(
    destination_name: str,
    pictures_dir: Path,
    min_count: int = DDG_GALLERY_COUNT,
    truncate: bool = True,
) -> Optional[list[dict]]:
    """Return cached DuckDuckGo gallery entries, or ``None`` if incomplete.

    ``truncate=False`` returns every valid cached entry (used when a caller
    needs to address photo N of a partially cached gallery). ``min_count``
    stays the "is the cache complete enough?" threshold.
    """
    folder = ddg_gallery_dir(destination_name, pictures_dir)
    meta_path = folder / "metadata.json"
    if not meta_path.exists():
        return None

    try:
        with open(meta_path, "r", encoding="utf-8") as fh:
            entries = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None

    if not isinstance(entries, list) or not entries:
        return None

    valid = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        p = Path(entry.get("image_path", ""))
        if not p.exists():
            # try relative to folder
            p = folder / Path(entry.get("image_path", "")).name
        if p.exists():
            try:
                from PIL import Image
                with Image.open(p) as img_check:
                    if img_check.size != (THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT):
                        _crop_and_save_thumbnail(p, p.with_suffix(".jpg"))
                        p = p.with_suffix(".jpg")
            except Exception:
                pass
            copy = dict(entry)
            copy["image_path"] = p
            valid.append(copy)

    if not valid:
        return None
    if truncate and len(valid) < min_count:
        # A partially filled gallery is still worth showing; the page adds
        # the missing photos once instead of re-downloading on every rerun.
        return None
    return valid[:min_count] if truncate else valid


def _search_query(destination_name: str, country: Optional[str]) -> str:
    clean_dest = re.sub(r"\s*\([^)]*\)", "", str(destination_name).strip()).strip()
    if country and str(country).strip() and str(country).strip().lower() not in {"nan", "none", "null"}:
        return f"{clean_dest}, {str(country).strip()} tourist attractions landmarks"
    return f"{clean_dest} tourist attractions landmarks"


def build_ddg_gallery(
    destination_name: str,
    country: Optional[str],
    pictures_dir: Path,
    count: int = DDG_GALLERY_COUNT,
    force_refresh: bool = False,
) -> list[dict]:
    """Fetch and cache DuckDuckGo images for a destination (cache-first)."""
    # A partially filled gallery must be *served*, not re-downloaded on every
    # rerun: the page renders on each widget interaction, so re-fetching here
    # meant a live search plus dozens of downloads per keystroke.
    existing: list[dict] = []
    if not force_refresh:
        cached = load_cached_ddg_gallery(destination_name, pictures_dir, min_count=count)
        if cached is not None:
            return cached
        existing = load_cached_ddg_gallery(destination_name, pictures_dir,
                                           min_count=1, truncate=False) or []
        if len(existing) >= count:
            return existing[:count]

    folder = ddg_gallery_dir(destination_name, pictures_dir)
    try:
        folder.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        # Read-only deployment: serve what is cached rather than crashing.
        print(f"DuckDuckGo gallery cache unavailable for "
              f"'{destination_name}': {exc}", flush=True)
        return existing

    missing = count - len(existing)
    if missing <= 0:
        return existing[:count]

    query = _search_query(destination_name, country)

    try:
        from ddgs import DDGS
    except ImportError:
        try:
            from duckduckgo_search import DDGS
        except ImportError:
            return existing

    try:
        with DDGS() as ddgs:
            raw_results = list(ddgs.images(query, max_results=missing * 3))
    except Exception as exc:
        print(f"DuckDuckGo image search failed for '{query}': {exc}", flush=True)
        return existing

    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        )
    }

    entries: list[dict] = list(existing)
    saved = len(existing)
    known_urls = {e.get("image_url") for e in entries}
    for r in raw_results:
        if saved >= count:
            break
        img_url = r.get("image")
        if not img_url or img_url in known_urls:
            continue
        try:
            resp = requests.get(img_url, headers=headers, timeout=REQUEST_TIMEOUT)
            if resp.status_code == 200 and len(resp.content) > 5000:
                img_path = folder / f"{saved + 1}.jpg"
                if _crop_and_save_thumbnail(resp.content, img_path):
                    saved += 1
                    known_urls.add(img_url)
                    entries.append({
                        "image_path": str(img_path),
                        "title": r.get("title", ""),
                        "source_url": r.get("url", ""),
                        "image_url": img_url,
                        "provider": "DuckDuckGo",
                    })
        except Exception:
            continue

    if entries:
        meta_path = folder / "metadata.json"
        try:
            meta_path.write_text(
                json.dumps(entries, indent=2, ensure_ascii=False), encoding="utf-8"
            )
        except OSError as exc:
            print(f"Could not write DDG gallery metadata for "
                  f"'{destination_name}': {exc}", flush=True)

    return entries


def refresh_single_ddg_image(
    destination_name: str,
    country: Optional[str],
    pictures_dir: Path,
    index: int,
) -> Optional[dict]:
    """Replace a single DuckDuckGo gallery image at index with a fresh one."""
    # NOTE: the cached list must NOT be truncated to one entry — the caller
    # passes the absolute photo index, so loading with min_count=1 made every
    # photo except the first un-replaceable (index >= len(cached)).
    cached = load_cached_ddg_gallery(destination_name, pictures_dir,
                                     min_count=DDG_GALLERY_COUNT, truncate=False)
    if not cached or index >= len(cached):
        return None

    folder = ddg_gallery_dir(destination_name, pictures_dir)
    try:
        folder.mkdir(parents=True, exist_ok=True)
    except OSError:
        return None
    query = _search_query(destination_name, country)
    existing_urls = {e.get("image_url") for e in cached}

    try:
        from ddgs import DDGS
    except ImportError:
        try:
            from duckduckgo_search import DDGS
        except ImportError:
            return None

    try:
        with DDGS() as ddgs:
            raw_results = list(ddgs.images(query, max_results=35))
    except Exception:
        return None

    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        )
    }

    for r in raw_results:
        img_url = r.get("image")
        if not img_url or img_url in existing_urls:
            continue
        try:
            resp = requests.get(img_url, headers=headers, timeout=REQUEST_TIMEOUT)
            if resp.status_code == 200 and len(resp.content) > 5000:
                img_path = folder / f"{index + 1}.jpg"
                for old_ext in (".png", ".webp"):
                    old_f = folder / f"{index + 1}{old_ext}"
                    if old_f.exists() and old_f != img_path:
                        try:
                            old_f.unlink()
                        except Exception:
                            pass
                if _crop_and_save_thumbnail(resp.content, img_path):
                    new_entry = {
                        "image_path": str(img_path),
                        "title": r.get("title", ""),
                        "source_url": r.get("url", ""),
                        "image_url": img_url,
                        "provider": "DuckDuckGo",
                    }
                    cached[index] = new_entry
                    meta_path = folder / "metadata.json"
                    meta_path.write_text(
                        json.dumps(cached, indent=2, ensure_ascii=False), encoding="utf-8"
                    )
                    return new_entry
        except Exception:
            continue

    return None


def load_destinations_from_workbook(path=DATA_PATH) -> list[tuple[str, Optional[str]]]:
    sheet_name = _find_destination_sheet(path)
    wb = openpyxl.load_workbook(path, read_only=True)
    ws = wb[sheet_name]
    headers = {str(cell.value).strip(): i for i, cell in enumerate(next(ws.iter_rows(max_row=1))) if cell.value}
    dest_col = headers.get("Destination")
    country_col = headers.get("Country")

    out = []
    for row in ws.iter_rows(min_row=2, values_only=True):
        if dest_col is not None and row[dest_col]:
            dest = str(row[dest_col]).strip()
            country = str(row[country_col]).strip() if country_col is not None and row[country_col] else None
            out.append((dest, country))
    wb.close()
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fetch and cache DuckDuckGo images for travel planner destinations.")
    parser.add_argument("cities", nargs="*", help="Specific destination names to fetch")
    parser.add_argument("--all", action="store_true", help="Process all destinations in the workbook")
    parser.add_argument("--count", type=int, default=DDG_GALLERY_COUNT, help="Number of images per destination (default: 12)")
    parser.add_argument("--refresh", action="store_true", help="Force refresh even if already cached")
    args = parser.parse_args(argv)

    pictures_dir = DATA_PATH.parent / "Pictures"
    all_dests = load_destinations_from_workbook()
    dest_map = {d.lower(): (d, c) for d, c in all_dests}

    if args.all:
        targets = all_dests
    elif args.cities:
        targets = []
        for name in args.cities:
            match = dest_map.get(name.strip().lower())
            if match:
                targets.append(match)
            else:
                targets.append((name.strip(), None))
    else:
        parser.print_usage()
        return 2

    print(f"Starting DuckDuckGo gallery population for {len(targets)} destinations ({args.count} images each)...", flush=True)
    done, skipped, failed = 0, 0, 0
    for i, (dest, country) in enumerate(targets, 1):
        if not args.refresh:
            cached = load_cached_ddg_gallery(dest, pictures_dir, min_count=args.count)
            if cached is not None and len(cached) >= args.count:
                print(f"[{i}/{len(targets)}] {dest}: already cached ({len(cached)} images)", flush=True)
                skipped += 1
                continue

        print(f"[{i}/{len(targets)}] {dest} (country: {country or '—'}) …", flush=True)
        entries = build_ddg_gallery(dest, country, pictures_dir, count=args.count, force_refresh=args.refresh)
        if len(entries) >= min(4, args.count):
            print(f"   -> Saved {len(entries)} images", flush=True)
            done += 1
        else:
            print(f"   -> Warning: only {len(entries)} images retrieved", flush=True)
            failed += 1
        time.sleep(1.0)  # polite pacing between destinations

    print(f"\nCompleted: {done} fetched, {skipped} skipped (already cached), {failed} failed/partial.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
