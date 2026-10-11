/// The banner-photo reader: the I/O half of the
/// legacy `destination_detail.py` header.
///
/// The legacy page folds the destination name into
/// a key and looks for a photo in the `Pictures/`
/// folder next to the workbook (accent-, case-
/// and spacing-insensitive). This module performs
/// the same match on the desktop, reading the
/// folder with `dart:io`.
///
/// The Pictures folder is a PC concept: on Android
/// the configured path simply does not exist, so
/// the banner stays hidden and the header falls
/// back to typography — the same per-device
/// pattern as the IQAir snapshot. A missing or
/// unreadable folder is a normal state, never a
/// crash. The panoramic crop the legacy performs
/// with PIL is achieved in the UI instead
/// (a fixed-height `BoxFit.cover` container), so
/// no image library is needed here.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'photo_cache.dart';

class PhotoRepository {
  /// The `Pictures/` folder, from `turso_config.json`
  /// (`pictures_dir`). Empty means unconfigured — no
  /// folder is ever assumed.
  final String picturesDir;

  const PhotoRepository(this.picturesDir);

  bool get isConfigured => picturesDir.trim().isNotEmpty;

  /// The file to show as the destination banner, or
  /// null when the folder is missing, unconfigured, or
  /// holds no matching photo. Never raises.
  Future<File?> findBanner(
    String destTitle,
    String destinationName,
  ) async {
    if (!isConfigured) return null;
    final dir = Directory(picturesDir);
    if (!await dir.exists()) return null;

    final names = <String>[];
    final files = <String, File>{};
    try {
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = p.basename(entity.path);
          names.add(name);
          files[name] = entity;
        }
      }
    } on FileSystemException {
      return null;
    }

    final match = findBannerName(destTitle, destinationName, names);
    if (match == null) return null;
    final file = files[match];
    return file != null && await file.exists() ? file : null;
  }
}
