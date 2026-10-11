/// The gallery cache reader: the I/O half of
/// the legacy `unsplash_gallery.py` /
/// `ddg_gallery.py`.
///
/// The desktop app reads the caches the legacy
/// app already populated under `Pictures/` —
/// Unsplash photos in `gallery/<slug>/`,
/// DuckDuckGo photos in `gallery_ddg/<slug>/` —
/// so reopening a destination triggers no new
/// network requests. The Unsplash cache is
/// tried first, then the DuckDuckGo one.
///
/// The sidecar records absolute image paths. A
/// path that no longer exists (the folder moved
/// machines) falls back to the file's name
/// inside the cache folder, the same defensive
/// re-attachment the legacy performs.
///
/// The folder is a per-machine path from
/// `turso_config.json` (`pictures_dir`), so on
/// the phone it does not exist and the gallery
/// stays hidden — a missing cache is a normal
/// state, never a crash.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'gallery_cache.dart';

class GalleryRepository {
  final String picturesDir;

  const GalleryRepository(this.picturesDir);

  bool get isConfigured => picturesDir.trim().isNotEmpty;

  /// The cached gallery for a destination, or
  /// null when neither provider cached anything.
  /// Never raises.
  Future<List<GalleryEntry>?> load(
    String destinationName,
  ) async {
    if (!isConfigured) return null;
    for (final folder in [
      galleryDir(destinationName, picturesDir),
      ddgGalleryDir(destinationName, picturesDir),
    ]) {
      final meta = File(p.join(folder, 'metadata.json'));
      if (!await meta.exists()) continue;
      try {
        final text = await meta.readAsString();
        final entries = parseGalleryMetadata(text);
        if (entries.isEmpty) continue;
        final resolved = await _resolve(entries, folder);
        if (resolved.isNotEmpty) return resolved;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  /// Keep the entries whose image still exists,
  /// re-attaching a stale absolute path to the
  /// file's name inside the cache folder.
  Future<List<GalleryEntry>> _resolve(
    List<GalleryEntry> entries,
    String folder,
  ) async {
    final resolved = <GalleryEntry>[];
    for (final entry in entries) {
      final image = File(entry.imagePath);
      if (await image.exists()) {
        resolved.add(entry);
        continue;
      }
      final fallback =
          File(p.join(folder, p.basename(entry.imagePath)));
      if (await fallback.exists()) {
        resolved.add(
          GalleryEntry(
            imagePath: fallback.path,
            caption: entry.caption,
            source: entry.source,
          ),
        );
      }
    }
    return resolved;
  }
}
