/// The gallery cache: the slug, the folder
/// names, and the sidecar parsing. Fixtures
/// are the real sidecar shapes both providers
/// write.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/gallery_cache.dart';

void main() {
  group('slugify', () {
    test('folds accents and spacing', () {
      expect(slugify('San José'), 'san-jose');
      expect(slugify('Ürümqi'), 'urumqi');
      expect(slugify('Mexico City'), 'mexico-city');
    });

    test('trims and collapses runs', () {
      expect(slugify('  New   York  '), 'new-york');
      expect(slugify('A--B'), 'a-b');
    });

    test('a name with no alphanumerics slugs to empty', () {
      expect(slugify('!!!'), '');
    });
  });

  group('cache folders', () {
    test('the two providers live in separate trees', () {
      expect(galleryDir('San José', '/pictures'), '/pictures/gallery/san-jose');
      expect(
        ddgGalleryDir('San José', '/pictures'),
        '/pictures/gallery_ddg/san-jose',
      );
    });
  });

  group('parseGalleryMetadata', () {
    test('an Unsplash sidecar credits the photographer', () {
      final entries = parseGalleryMetadata('''
        [
          {
            "image_path": "/pictures/gallery/san-jose/1.jpg",
            "photo_id": "abc",
            "photographer_name": "John Doe",
            "photographer_url": "https://unsplash.com/@john",
            "photo_url": "https://unsplash.com/photos/abc"
          }
        ]
      ''');
      expect(entries, hasLength(1));
      expect(entries.single.imagePath, '/pictures/gallery/san-jose/1.jpg');
      expect(entries.single.caption, 'John Doe');
      expect(entries.single.photographerUrl, 'https://unsplash.com/@john');
      expect(entries.single.photoPageUrl, 'https://unsplash.com/photos/abc');
      expect(entries.single.source, 'Unsplash');
    });

    test('a DuckDuckGo sidecar uses the title', () {
      final entries = parseGalleryMetadata('''
        [
          {
            "image_path": "/pictures/gallery_ddg/san-jose/1.jpg",
            "title": "A beach",
            "provider": "DuckDuckGo"
          }
        ]
      ''');
      expect(entries, hasLength(1));
      expect(entries.single.caption, 'A beach');
      expect(entries.single.source, 'DuckDuckGo');
    });

    test('a malformed sidecar is an empty list, not a crash', () {
      expect(parseGalleryMetadata('not json'), isEmpty);
      expect(parseGalleryMetadata('{"a": 1}'), isEmpty);
      expect(parseGalleryMetadata('[]'), isEmpty);
      // An entry with no image path is skipped.
      expect(parseGalleryMetadata('[{"photographer_name": "X"}]'), isEmpty);
    });
  });
}
