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

/// One gallery photo. Unsplash entries keep only the API's hotlinked URL;
/// legacy entries continue to use their local image path.
class GalleryEntry {
  final String imagePath;
  final String imageUrl;
  final String photoId;
  final String caption;
  final String source;
  final String photographerUrl;
  final String photoPageUrl;
  final String sourceUrl;

  const GalleryEntry({
    this.imagePath = '',
    this.imageUrl = '',
    this.photoId = '',
    required this.caption,
    required this.source,
    this.photographerUrl = '',
    this.photoPageUrl = '',
    this.sourceUrl = '',
  });

  bool get isUnsplash => source.toLowerCase() == 'unsplash';

  bool get hasRemoteImage {
    final uri = Uri.tryParse(imageUrl);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'images.unsplash.com';
  }

  bool get hasCredit => isUnsplash && caption.trim().isNotEmpty;
}

/// Slugify a destination name for the cache folder
/// (`San José` -> `san-jose`, `Ürümqi` -> `urumqi`).
String slugify(String value) {
  final ascii = stripDiacritics(value.trim().toLowerCase());
  final slug = ascii.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return slug.replaceAll(RegExp(r'^-+'), '').replaceAll(RegExp(r'-+$'), '');
}

/// The Unsplash gallery cache folder for a destination.
String galleryDir(String destinationName, String picturesDir) =>
    '$picturesDir/gallery/${slugify(destinationName)}';

/// The DuckDuckGo gallery cache folder for a destination.
String ddgGalleryDir(String destinationName, String picturesDir) =>
    '$picturesDir/gallery_ddg/${slugify(destinationName)}';

/// Parse a legacy provider sidecar or a portable metadata cache.
/// DuckDuckGo entries remain local-file readers; new Unsplash entries
/// contain a hotlinked URL and attribution, never downloaded bytes.
List<GalleryEntry> parseGalleryMetadata(String jsonText) {
  final decoded = _decode(jsonText);
  if (decoded is! List) return const [];
  final entries = <GalleryEntry>[];
  for (final entry in decoded) {
    if (entry is! Map<String, dynamic>) continue;
    final imagePath = _string(entry['image_path']);
    final imageUrl = _string(entry['image_url']);
    if (imagePath.isEmpty && !_validRemoteImage(imageUrl)) continue;
    final provider = _string(entry['provider']).isNotEmpty
        ? _string(entry['provider'])
        : _string(entry['source']);
    final isDdg =
        provider.toLowerCase().contains('duckduckgo') ||
        provider.toLowerCase() == 'ddg';
    final source = provider.isEmpty ? 'Unsplash' : provider;
    final caption = isDdg
        ? _string(entry['title'])
        : _firstString(entry, ['photographer_name', 'caption', 'title']);
    entries.add(
      GalleryEntry(
        imagePath: imagePath,
        imageUrl: imageUrl,
        photoId: _string(entry['photo_id']),
        caption: caption,
        source: source,
        photographerUrl: _string(entry['photographer_url']),
        photoPageUrl: _firstString(entry, ['photo_page_url', 'photo_url']),
        sourceUrl: _firstString(entry, [
          'source_url',
          'source_page_url',
          'url',
        ]),
      ),
    );
  }
  return entries;
}

/// Encode metadata only. In particular, the Unsplash image URL is retained
/// verbatim and no image bytes are copied into the portable cache.
String encodeGalleryMetadata(Iterable<GalleryEntry> entries) => jsonEncode([
  for (final entry in entries)
    {
      'image_path': entry.imagePath,
      'image_url': entry.imageUrl,
      'photo_id': entry.photoId,
      'photographer_name': entry.caption,
      'photographer_url': entry.photographerUrl,
      'photo_page_url': entry.photoPageUrl,
      'source_url': entry.sourceUrl,
      'provider': entry.source,
    },
]);

String _string(Object? value) => value is String ? value : '';

String _firstString(Map<String, dynamic> entry, List<String> keys) {
  for (final key in keys) {
    final value = _string(entry[key]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

bool _validRemoteImage(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'images.unsplash.com';
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
