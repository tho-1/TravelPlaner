/// The banner-photo matching: the pure half of
/// the legacy `destination_detail.py` header.
///
/// The legacy page looks for a photo in the
/// `Pictures/` folder whose name matches the
/// destination. Matching is accent-, case- and
/// spacing-insensitive, so "Mexico city" picks
/// up "MexicoCity_1.jpg" and
/// "San José (Costa Rica)" picks up
/// "San José_1.jpg". The normalisation reuses
/// `stripDiacritics` (the shared NFKD stand-in)
/// so the keys match the Python
/// `unicodedata.normalize("NFKD")` + ASCII-fold
/// the legacy performs.
///
/// Everything here is pure: the caller supplies
/// the folder's file names, so the matching is
/// testable without touching the disk. The I/O
/// half lives in `photo_repository.dart`.
library;

import 'text_norm.dart';

/// Normalise a name for picture matching: drop
/// the parenthetical disambiguator, strip the
/// accents, lowercase, and remove every
/// non-alphanumeric run — so "San José (Costa
/// Rica)" and "San José" both fold to "sanjose".
String normalizePictureKey(String value) {
  final withoutParens = value.replaceAll(RegExp(r'\([^)]*\)'), '');
  return _fold(withoutParens);
}

/// Normalise a name *keeping* the qualifier, so a
/// city with a province can be matched to its own
/// photo. The legacy comment is explicit: this
/// fallback must not override an exact match when
/// both photos are present.
String normalizeExactKey(String value) => _fold(value);

String _fold(String value) {
  final ascii = stripDiacritics(value);
  return ascii.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Rank a file for the pick: prefer .jpg/.jpeg over
/// .png over anything else, so the choice is
/// deterministic when a destination has both
/// `Yogyakarta_1.jpg` and `Yogyakarta_1.png`.
int pictureRank(String extension) {
  final ext = extension.toLowerCase();
  if (ext == '.jpg' || ext == '.jpeg') return 0;
  if (ext == '.png') return 1;
  return 2;
}

/// The file name to use as the banner for a
/// destination, or null when no file matches.
///
/// Two passes, in order (both port of the legacy):
///
/// 1. An *exact* match (qualifier kept) always
///    wins, so "San José (Mexico)" can never be
///    shown the photo that belongs to
///    "San José (Costa Rica)".
/// 2. Otherwise the qualifier-insensitive match:
///    the file's folded key must equal a folded
///    base or that base followed by "1", so
///    "Mexico City" finds "MexicoCity_1.jpg".
///
/// Ties are broken by `pictureRank`, then by the
/// first match — the same `min(matches, key=rank)`
/// the legacy uses.
String? findBannerName(
  String destTitle,
  String destinationName,
  List<String> fileNames,
) {
  final exactBases = <String>{
    if (destTitle.isNotEmpty) normalizeExactKey(destTitle),
    if (destinationName.isNotEmpty) normalizeExactKey(destinationName),
  };

  String? exactPick;
  var exactRank = 3;
  for (final name in fileNames) {
    if (!exactBases.contains(normalizeExactKey(stemOf(name)))) continue;
    final rank = pictureRank(extensionOf(name));
    if (rank < exactRank) {
      exactPick = name;
      exactRank = rank;
    }
  }
  if (exactPick != null) return exactPick;

  final bases = <String>{
    if (destTitle.isNotEmpty) normalizePictureKey(destTitle),
    if (destinationName.isNotEmpty) normalizePictureKey(destinationName),
  };

  String? pick;
  var bestRank = 3;
  for (final name in fileNames) {
    final key = normalizePictureKey(stemOf(name));
    final matched =
        bases.any((base) => key == base || key == '${base}1');
    if (!matched) continue;
    final rank = pictureRank(extensionOf(name));
    if (rank < bestRank) {
      pick = name;
      bestRank = rank;
    }
  }
  return pick;
}

/// The file name without its final extension
/// (`San José_1.jpg` -> `San José_1`), mirroring
/// `Path.stem`.
String stemOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// The final extension including the dot
/// (`San José_1.jpg` -> `.jpg`), mirroring
/// `Path.suffix`.
String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot);
}
