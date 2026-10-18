import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:travel_planner/data/gallery_cache.dart';
import 'package:travel_planner/data/gallery_repository.dart';
import 'package:travel_planner/data/gallery_search.dart';

void main() {
  group('UnsplashPhotoSearchProvider', () {
    test(
      'uses the official search API and hotlinks credited result URLs',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'id': 'photo-1',
                  'urls': {'small': 'https://images.unsplash.com/photo-1'},
                  'links': {'html': 'https://unsplash.com/photos/photo-1'},
                  'user': {
                    'name': 'Photo Maker',
                    'links': {'html': 'https://unsplash.com/@maker'},
                  },
                },
                {
                  'id': 'incomplete',
                  'urls': {'small': 'https://images.unsplash.com/incomplete'},
                  'links': {'html': 'https://unsplash.com/photos/incomplete'},
                  'user': {'name': 'No profile link'},
                },
              ],
            }),
            200,
          );
        });
        final provider = UnsplashPhotoSearchProvider(
          'test-access-key',
          client: client,
        );

        final entries = await provider.search('San José', page: 2, perPage: 4);

        expect(requests, hasLength(1));
        expect(requests.single.url.host, 'api.unsplash.com');
        expect(requests.single.url.path, '/search/photos');
        expect(requests.single.url.queryParameters, {
          'query': 'San José',
          'page': '2',
          'per_page': '4',
        });
        expect(
          requests.single.headers['Authorization'],
          'Client-ID test-access-key',
        );
        expect(requests.single.headers['Accept-Version'], 'v1');
        expect(entries, hasLength(1));
        expect(entries.single.imageUrl, 'https://images.unsplash.com/photo-1');
        expect(entries.single.photoId, 'photo-1');
        expect(entries.single.caption, 'Photo Maker');
        expect(
          entries.single.photographerUrl,
          contains('utm_source=travel_planner'),
        );
        expect(entries.single.photoPageUrl, contains('utm_medium=referral'));
        // Only the search endpoint was requested; image bytes are hotlinked by URL.
        expect(requests.map((request) => request.url.host), [
          'api.unsplash.com',
        ]);
      },
    );

    test('reports HTTP errors without exposing response contents', () async {
      final provider = UnsplashPhotoSearchProvider(
        'test-access-key',
        client: MockClient(
          (_) async => http.Response('private error body', 401),
        ),
      );
      await expectLater(
        provider.search('Rome'),
        throwsA(
          isA<PhotoSearchException>().having(
            (error) => error.message,
            'message',
            contains('401'),
          ),
        ),
      );
    });

    test('does not send a request without a configured access key', () async {
      var requests = 0;
      final provider = UnsplashPhotoSearchProvider(
        '',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        provider.search('Rome'),
        throwsA(isA<PhotoSearchException>()),
      );
      expect(requests, 0);
    });
  });

  test(
    'portable cache round-trips metadata only and supports repository seams',
    () async {
      final root = Directory.systemTemp.createTempSync('photo_metadata_');
      addTearDown(() => root.deleteSync(recursive: true));
      final cache = FileGalleryMetadataCache(root.path);
      final entry = GalleryEntry(
        imageUrl: 'https://images.unsplash.com/photo-portable',
        photoId: 'portable-1',
        caption: 'A Photographer',
        source: 'Unsplash',
        photographerUrl:
            'https://unsplash.com/@photographer?utm_source=travel_planner',
        photoPageUrl:
            'https://unsplash.com/photos/portable?utm_source=travel_planner',
        sourceUrl:
            'https://unsplash.com/photos/portable?utm_source=travel_planner',
      );
      final repo = GalleryRepository(
        '',
        cache: cache,
        provider: _FakeProvider([entry]),
      );

      await repo.save('San José', [entry]);
      final loaded = await repo.load('San José');
      final searched = await repo.search('San José');
      final cachedFile = File(cache.filePath('San José'));
      final text = await cachedFile.readAsString();

      expect(loaded, hasLength(1));
      expect(loaded!.single.imageUrl, entry.imageUrl);
      expect(loaded.single.caption, 'A Photographer');
      expect(loaded.single.photographerUrl, entry.photographerUrl);
      expect(searched.single.photoId, 'portable-1');
      expect(text, contains(entry.imageUrl));
      expect(text, isNot(contains('image_bytes')));

      final replacement = GalleryEntry(
        imageUrl: 'https://images.unsplash.com/photo-replacement',
        photoId: 'replacement',
        caption: 'Replacement Photographer',
        source: 'Unsplash',
        photographerUrl: 'https://unsplash.com/@replacement',
        photoPageUrl: 'https://unsplash.com/photos/replacement',
      );
      await repo.save('San José', [replacement]);
      expect(
        (await cache.load('San José'))?.single.photoId,
        'replacement',
      );
      final cachedFiles = root.listSync(recursive: true).whereType<File>();
      expect(cachedFiles, hasLength(1));
      expect(cachedFiles.single.path, endsWith('.json'));
    },
  );
}

class _FakeProvider implements PhotoSearchProvider {
  final List<GalleryEntry> entries;

  const _FakeProvider(this.entries);

  @override
  Future<List<GalleryEntry>> search(
    String query, {
    int page = 1,
    int perPage = 8,
  }) async => entries;
}
