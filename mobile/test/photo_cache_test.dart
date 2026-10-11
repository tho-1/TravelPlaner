/// The banner-photo matching: the folded keys
/// and the two-pass pick the legacy header
/// performs. Fixtures are the real `Pictures/`
/// file names the destination catalogue uses.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/photo_cache.dart';

void main() {
  group('normalise', () {
    test('the picture key drops the parenthetical', () {
      expect(normalizePictureKey('San José (Costa Rica)'), 'sanjose');
      expect(normalizePictureKey('Mexico City'), 'mexicocity');
    });

    test('the exact key keeps the qualifier', () {
      expect(normalizeExactKey('San José (Costa Rica)'),
          'sanjosecostarica');
      expect(normalizeExactKey('San José'), 'sanjose');
    });

    test('case and spacing do not matter', () {
      expect(normalizePictureKey('mexico city'),
          normalizePictureKey('MexicoCity'));
    });
  });

  group('pictureRank', () {
    test('jpg beats png beats the rest', () {
      expect(pictureRank('.jpg'), 0);
      expect(pictureRank('.jpeg'), 0);
      expect(pictureRank('.JPG'), 0);
      expect(pictureRank('.png'), 1);
      expect(pictureRank('.webp'), 2);
      expect(pictureRank(''), 2);
    });
  });

  group('findBannerName', () {
    test('a qualifier-insensitive match finds the numbered photo', () {
      final name = findBannerName(
        'Mexico City',
        'Mexico City',
        ['MexicoCity_1.jpg', 'OtherPlace_1.jpg'],
      );
      expect(name, 'MexicoCity_1.jpg');
    });

    test('an exact match beats the qualifier-insensitive photo', () {
      // Both "San José" and "San José (Costa Rica)" photos exist;
      // the qualified destination must keep its own. (The exact
      // pass fires on the unsuffixed names; the numbered files
      // only ever reach the loose pass.)
      final name = findBannerName(
        'San José (Costa Rica)',
        'San José (Costa Rica)',
        ['San José.jpg', 'San José (Costa Rica).jpg'],
      );
      expect(name, 'San José (Costa Rica).jpg');
    });

    test('jpg wins when the same name has two formats', () {
      final name = findBannerName(
        'Yogyakarta',
        'Yogyakarta',
        ['Yogyakarta_1.png', 'Yogyakarta_1.jpg'],
      );
      expect(name, 'Yogyakarta_1.jpg');
    });

    test('no match returns null', () {
      final name = findBannerName(
        'Atlantis',
        'Atlantis',
        ['MexicoCity_1.jpg', 'San José_1.jpg'],
      );
      expect(name, isNull);
    });

    test('an empty destination never matches', () {
      final name = findBannerName('', '', ['MexicoCity_1.jpg']);
      expect(name, isNull);
    });
  });

  group('stem and extension', () {
    test('split the final dot', () {
      expect(stemOf('San José_1.jpg'), 'San José_1');
      expect(extensionOf('San José_1.jpg'), '.jpg');
      expect(stemOf('README'), 'README');
      expect(extensionOf('README'), '');
    });
  });
}
