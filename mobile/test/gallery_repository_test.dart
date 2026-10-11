/// The gallery cache reader: the match against
/// a real `Pictures/` folder on disk. Fixtures
/// are written into a throwaway temp directory,
/// so the suite never touches the machine's
/// real `Pictures/`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:travel_planner/data/gallery_repository.dart';

void main() {
  late Directory pictures;

  setUp(() {
    pictures = Directory.systemTemp.createTempSync('gallery_');
  });

  tearDown(() {
    if (pictures.existsSync()) {
      pictures.deleteSync(recursive: true);
    }
  });

  Future<void> writeImage(String path) async {
    await File(path).writeAsBytes([0, 1, 2, 3]);
  }

  group('load', () {
    test('reads the Unsplash cache', () async {
      final folder = '${pictures.path}/gallery/san-jose';
      await Directory(folder).create(recursive: true);
      await writeImage('$folder/1.jpg');
      await File('$folder/metadata.json').writeAsString(jsonEncode([
        {
          'image_path': '$folder/1.jpg',
          'photographer_name': 'John Doe',
        },
      ]));

      final repo = GalleryRepository(pictures.path);
      final entries = await repo.load('San José');
      expect(entries, hasLength(1));
      expect(entries!.single.caption, 'John Doe');
      expect(entries.single.source, 'Unsplash');
      expect(entries.single.imagePath, '$folder/1.jpg');
    });

    test('reads the DuckDuckGo cache', () async {
      final folder = '${pictures.path}/gallery_ddg/san-jose';
      await Directory(folder).create(recursive: true);
      await writeImage('$folder/1.jpg');
      await File('$folder/metadata.json').writeAsString(jsonEncode([
        {
          'image_path': '$folder/1.jpg',
          'title': 'A beach',
          'provider': 'DuckDuckGo',
        },
      ]));

      final repo = GalleryRepository(pictures.path);
      final entries = await repo.load('San José');
      expect(entries, hasLength(1));
      expect(entries!.single.caption, 'A beach');
      expect(entries.single.source, 'DuckDuckGo');
    });

    test('the Unsplash cache wins over the DuckDuckGo one',
        () async {
      final unsplash = '${pictures.path}/gallery/san-jose';
      await Directory(unsplash).create(recursive: true);
      await writeImage('$unsplash/1.jpg');
      await File('$unsplash/metadata.json').writeAsString(jsonEncode([
        {
          'image_path': '$unsplash/1.jpg',
          'photographer_name': 'John Doe',
        },
      ]));
      final ddg = '${pictures.path}/gallery_ddg/san-jose';
      await Directory(ddg).create(recursive: true);
      await writeImage('$ddg/1.jpg');
      await File('$ddg/metadata.json').writeAsString(jsonEncode([
        {
          'image_path': '$ddg/1.jpg',
          'title': 'A beach',
          'provider': 'DuckDuckGo',
        },
      ]));

      final repo = GalleryRepository(pictures.path);
      final entries = await repo.load('San José');
      expect(entries!.single.source, 'Unsplash');
      expect(entries.single.caption, 'John Doe');
    });

    test('a stale absolute path falls back to the cache folder',
        () async {
      final folder = '${pictures.path}/gallery/san-jose';
      await Directory(folder).create(recursive: true);
      await writeImage('$folder/1.jpg');
      // The sidecar records a path from another machine.
      await File('$folder/metadata.json').writeAsString(jsonEncode([
        {
          'image_path': '/gone/gallery/san-jose/1.jpg',
          'photographer_name': 'John Doe',
        },
      ]));

      final repo = GalleryRepository(pictures.path);
      final entries = await repo.load('San José');
      expect(entries, hasLength(1));
      // The re-attached path points at the cached
      // file, whatever separator the platform uses.
      expect(
        p.normalize(entries!.single.imagePath),
        p.normalize('$folder/1.jpg'),
      );
    });

    test('no cache returns null', () async {
      final repo = GalleryRepository(pictures.path);
      expect(await repo.load('Atlantis'), isNull);
    });
  });

  group('unconfigured', () {
    test('an empty picturesDir reads nothing', () async {
      final repo = GalleryRepository('');
      expect(repo.isConfigured, isFalse);
      expect(await repo.load('San José'), isNull);
    });
  });
}
