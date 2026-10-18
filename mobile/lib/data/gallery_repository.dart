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
import 'gallery_search.dart';

abstract interface class GalleryMetadataCache {
  Future<List<GalleryEntry>?> load(String destinationName);
  Future<void> save(String destinationName, List<GalleryEntry> entries);
}

/// Per-device, portable metadata storage. It never downloads or writes image
/// bytes; remote Unsplash images remain hotlinked when displayed.
class FileGalleryMetadataCache implements GalleryMetadataCache {
  final String rootDirectory;

  const FileGalleryMetadataCache(this.rootDirectory);

  String filePath(String destinationName) => p.join(
    rootDirectory,
    'destination_photos',
    '${slugify(destinationName)}.json',
  );

  @override
  Future<List<GalleryEntry>?> load(String destinationName) async {
    try {
      final file = File(filePath(destinationName));
      if (!await file.exists()) return null;
      final entries = parseGalleryMetadata(await file.readAsString());
      return entries.isEmpty ? null : entries;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(String destinationName, List<GalleryEntry> entries) async {
    final file = File(filePath(destinationName));
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    try {
      await temp.writeAsString(encodeGalleryMetadata(entries), flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}

class GalleryRepository {
  final String picturesDir;
  final GalleryMetadataCache? cache;
  final PhotoSearchProvider? provider;

  const GalleryRepository(this.picturesDir, {this.cache, this.provider});

  bool get isConfigured => picturesDir.trim().isNotEmpty;

  Future<List<GalleryEntry>> search(
    String destinationName, {
    int page = 1,
    int perPage = 8,
  }) {
    final searchProvider = provider;
    if (searchProvider == null) {
      throw const PhotoSearchException('Photo search is unavailable.');
    }
    return searchProvider.search(destinationName, page: page, perPage: perPage);
  }

  Future<void> save(String destinationName, List<GalleryEntry> entries) async {
    await cache?.save(destinationName, entries);
  }

  /// Portable metadata takes precedence; legacy Pictures folders remain a
  /// read-only fallback, including existing DuckDuckGo image files.
  Future<List<GalleryEntry>?> load(String destinationName) async {
    final cached = await cache?.load(destinationName);
    if (cached != null && cached.isNotEmpty) {
      final resolved = await _resolve(cached, '');
      if (resolved.isNotEmpty) return resolved;
    }
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

  /// Keep hotlinked photos and local images that still exist, re-attaching
  /// stale legacy paths by basename inside their original cache folder.
  Future<List<GalleryEntry>> _resolve(
    List<GalleryEntry> entries,
    String folder,
  ) async {
    final resolved = <GalleryEntry>[];
    for (final entry in entries) {
      if (entry.hasRemoteImage) {
        resolved.add(entry);
        continue;
      }
      if (entry.imagePath.isEmpty) continue;
      final image = File(entry.imagePath);
      if (await image.exists()) {
        resolved.add(entry);
        continue;
      }
      if (folder.isEmpty) continue;
      final fallback = File(p.join(folder, p.basename(entry.imagePath)));
      if (await fallback.exists()) {
        resolved.add(_withImagePath(entry, fallback.path));
      }
    }
    return resolved;
  }

  GalleryEntry _withImagePath(GalleryEntry entry, String imagePath) =>
      GalleryEntry(
        imagePath: imagePath,
        imageUrl: entry.imageUrl,
        photoId: entry.photoId,
        caption: entry.caption,
        source: entry.source,
        photographerUrl: entry.photographerUrl,
        photoPageUrl: entry.photoPageUrl,
        sourceUrl: entry.sourceUrl,
      );
}
