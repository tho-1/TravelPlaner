/// The banner-photo reader: the match against a
/// real folder on disk. Fixtures are written into a
/// throwaway temp directory, so the suite never
/// touches the machine's real `Pictures/`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/photo_repository.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('photo_repo_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> writeFile(String name) async {
    await File('${dir.path}/$name').writeAsBytes([0, 1, 2, 3]);
  }

  group('findBanner', () {
    test('finds the matching photo', () async {
      await writeFile('MexicoCity_1.jpg');
      await writeFile('OtherPlace_1.jpg');
      final repo = PhotoRepository(dir.path);
      final file = await repo.findBanner('Mexico City', 'Mexico City');
      expect(file, isNotNull);
      expect(file!.path, endsWith('MexicoCity_1.jpg'));
    });

    test('prefers jpg over png', () async {
      await writeFile('Yogyakarta_1.png');
      await writeFile('Yogyakarta_1.jpg');
      final repo = PhotoRepository(dir.path);
      final file = await repo.findBanner('Yogyakarta', 'Yogyakarta');
      expect(file!.path, endsWith('Yogyakarta_1.jpg'));
    });

    test('sub-folders are ignored', () async {
      await writeFile('MexicoCity_1.jpg');
      await Directory('${dir.path}/gallery').create();
      await File('${dir.path}/gallery/MexicoCity_1.jpg')
          .writeAsBytes([0]);
      final repo = PhotoRepository(dir.path);
      final file = await repo.findBanner('Mexico City', 'Mexico City');
      // Should pick the top-level file, not the copy in gallery/.
      expect(file!.path, isNot(contains('gallery')));
      expect(file.path, endsWith('MexicoCity_1.jpg'));
    });

    test('no match returns null', () async {
      await writeFile('OtherPlace_1.jpg');
      final repo = PhotoRepository(dir.path);
      final file = await repo.findBanner('Atlantis', 'Atlantis');
      expect(file, isNull);
    });
  });

  group('unconfigured', () {
    test('an empty picturesDir reads nothing', () async {
      final repo = PhotoRepository('');
      expect(repo.isConfigured, isFalse);
      expect(await repo.findBanner('Mexico City', 'Mexico City'), isNull);
    });

    test('a missing folder returns null, not a crash', () async {
      final repo = PhotoRepository('${dir.path}/does-not-exist');
      expect(repo.isConfigured, isTrue);
      expect(await repo.findBanner('Mexico City', 'Mexico City'), isNull);
    });
  });
}
