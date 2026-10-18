# Destination gallery and hero photos (items q/s)

**Implemented in the Flutter app.** The photos disappeared because the old
Flutter port only read per-PC `Pictures/` files and legacy cache sidecars. It
never fetched new photos; on a fresh phone those paths were absent, and the
empty gallery was hidden. The Streamlit image search/replace flow had not been
ported.

## q — detail gallery

- The gallery heading and an empty state now remain visible. **Find photos** and
  **Find more photos** perform an explicit, user-initiated search; opening a
  destination stays cache-only. Queries include the destination and country.
- A photo can be replaced independently. Search progress, missing-key, rate
  limit, and fetch/cache errors are surfaced in the page.
- Searches use the official Unsplash API. The result's `images.unsplash.com`
  URL is hotlinked directly (image bytes are not downloaded), and portable
  per-device metadata retains the photographer, photo page, and referral links.
  A source/photographer credit is rendered with each image.
- Existing Unsplash and DuckDuckGo folders under `Pictures/` remain readable.
  New DuckDuckGo fetching is intentionally not added: image search results do
  not establish reuse rights. Only already-cached legacy files are displayed.
- Metadata lives under the app's documents directory on desktop and Android;
  no image bytes or API keys are stored in Turso. The optional
  `unsplash_access_key` belongs in the git-ignored `mobile/assets/turso_config.json`
  (placeholder documented in `mobile/assets/turso_config.example.json`). Without
  a key, the action explains how to configure one rather than silently failing.

## s — top destination photo

The detail header now resolves its image in this order:

1. matching, manually curated desktop image in `Pictures/` (exact qualified
   destination match before the legacy qualifier-insensitive fallback);
2. first valid, credited image in the destination gallery cache;
3. the existing typography/location header.

Gallery-backed hero images use the same cached Unsplash URL and include the
same photographer/Unsplash attribution links. They use the wide `BoxFit.cover`
crop and readable title scrim; the header does not trigger an API request.

## Verification

Fake API-provider and metadata-cache seams keep tests credential- and
network-free. Regressions cover API URL/auth/attribution, hotlinking without
byte downloads, metadata-only persistence, explicit search/replace, cached
hero fallback, and curated-banner precedence. Legacy cache readers and their
stale-path recovery remain covered by the repository tests.
