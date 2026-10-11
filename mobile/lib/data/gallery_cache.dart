/// The gallery cache: the pure half of the
/// legacy `unsplash_gallery.py` / `ddg_gallery.py`.
///
/// Both providers persist a per-destination
/// folder under `Pictures/` — Unsplash photos in
/// `gallery/<slug>/`, DuckDuckGo photos in
/// `gallery_ddg/<slug>/` — each with a
/// `metadata.json` sidecar. The desktop app reads
/// those caches directly (they are shared with the
/// legacy app on the PC), so the folder names and
/// the sidecar format are ported here verbatim.
///
/// The slug mirrors the Python `_slugify`:
/// lowercase, accents folded to ASCII, every
/// non-alphanumeric run to a single `-`. It reuses
/// `stripDiacritics` (the shared NFKD stand-in).
///
/// Everything here is pure: the caller supplies the
/// sidecar text, so the parsing is testable
/// without touching the disk. The I/O half lives
/// in `gallery_repository.dart`.
library;

import 'dart:convert';

import 'text_norm.dart';

/// One cached gallery photo.
class GalleryEntry {
  /// The image file, as recorded in the sidecar.
  final String imagePath;

  /// The caption: the photographer (Unsplash) or
  /// the search title (DuckDuckGo).
  final String caption;

  /// The provider that cached the photo.
  final String source;

  const GalleryEntry({
    required this.imagePath,
    required this.caption,
    required this.source,
  });
}

/// Slugify a destination name for the cache folder
/// (`San José` -> `san-jose`, `Ürümqi` -> `urumqi`).
String slugify(String value) {
  final ascii = stripDiacritics(value.trim().toLowerCase());
  final slug = ascii.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return slug.replaceAll(RegExp(r'^-+'), '').replaceAll(
        RegExp(r'-+$'),
        '',
      );
}

/// The Unsplash gallery cache folder for a destination.
String galleryDir(String destinationName, String picturesDir) =>
    '$picturesDir/gallery/${slugify(destinationName)}';

/// The DuckDuckGo gallery cache folder for a destination.
String ddgGalleryDir(String destinationName, String picturesDir) =>
    '$picturesDir/gallery_ddg/${slugify(destinationName)}';

/// Parse a `metadata.json` sidecar, in either
/// provider's format, into gallery entries.
///
/// Unsplash records `photographer_name` and no
/// `provider`; DuckDuckGo records a `title` and
/// `provider: "DuckDuckGo"`. The caption follows
/// the provider, so the grid can credit the photo.
/// A malformed sidecar parses to an empty list —
/// the caller treats that as "no cache", never a
/// crash.
List<GalleryEntry> parseGalleryMetadata(String jsonText) {
  final decoded = _decode(jsonText);
  if (decoded is! List) return const [];
  final entries = <GalleryEntry>[];
  for (final entry in decoded) {
    if (entry is! Map<String, dynamic>) continue;
    final imagePath = entry['image_path'] as String? ?? '';
    if (imagePath.isEmpty) continue;
    final provider = entry['provider'] as String? ?? '';
    final isDdg = provider.isNotEmpty;
    final caption = isDdg
        ? (entry['title'] as String? ?? '')
        : (entry['photographer_name'] as String? ?? '');
    entries.add(
      GalleryEntry(
        imagePath: imagePath,
        caption: caption,
        source: isDdg ? provider : 'Unsplash',
      ),
    );
  }
  return entries;
}

/// Decode the sidecar, or null when it is not
/// valid JSON — a malformed sidecar means "no
/// cache", never a crash.
dynamic _decode(String jsonText) {
  try {
    return jsonDecode(jsonText);
  } on FormatException {
    return null;
  }
}
