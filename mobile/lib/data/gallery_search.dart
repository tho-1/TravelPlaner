/// User-initiated photo search through the official Unsplash API.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'gallery_cache.dart';

abstract interface class PhotoSearchProvider {
  Future<List<GalleryEntry>> search(
    String query, {
    int page = 1,
    int perPage = 8,
  });
}

class PhotoSearchException implements Exception {
  final String message;

  const PhotoSearchException(this.message);

  @override
  String toString() => message;
}

class UnsplashPhotoSearchProvider implements PhotoSearchProvider {
  final String accessKey;
  final http.Client? _providedClient;

  UnsplashPhotoSearchProvider(this.accessKey, {http.Client? client})
    : _providedClient = client;

  @override
  Future<List<GalleryEntry>> search(
    String query, {
    int page = 1,
    int perPage = 8,
  }) async {
    if (accessKey.trim().isEmpty) {
      throw const PhotoSearchException(
        'Add an Unsplash access key to the app configuration to find photos.',
      );
    }
    final uri = Uri.https('api.unsplash.com', '/search/photos', {
      'query': query,
      'page': '$page',
      'per_page': '$perPage',
    });
    final client = _providedClient ?? http.Client();
    try {
      final response = await client.get(
        uri,
        headers: {
          'Authorization': 'Client-ID ${accessKey.trim()}',
          'Accept-Version': 'v1',
        },
      );
      if (response.statusCode != 200) {
        final message = response.statusCode == 429
            ? 'Unsplash rate limit reached. Try again later.'
            : 'Unsplash photo search failed (${response.statusCode}).';
        throw PhotoSearchException(message);
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['results'] is! List) {
        throw const PhotoSearchException(
          'Unsplash returned an invalid response.',
        );
      }

      final entries = <GalleryEntry>[];
      for (final result in decoded['results'] as List) {
        if (result is! Map<String, dynamic>) continue;
        final urls = result['urls'];
        final user = result['user'];
        final links = result['links'];
        if (urls is! Map<String, dynamic> ||
            user is! Map<String, dynamic> ||
            links is! Map<String, dynamic>) {
          continue;
        }
        final imageUrl = _string(urls['small']);
        final photoId = _string(result['id']);
        final photographer = _string(user['name']);
        final photographerUrl = _attributionUrl(
          (user['links'] as Map?)?['html'],
        );
        final photoPageUrl = _attributionUrl(links['html']);
        if (!_isUnsplashImage(imageUrl) ||
            photoId.isEmpty ||
            photographer.isEmpty ||
            photographerUrl.isEmpty ||
            photoPageUrl.isEmpty) {
          continue;
        }
        entries.add(
          GalleryEntry(
            imageUrl: imageUrl,
            photoId: photoId,
            caption: photographer,
            source: 'Unsplash',
            photographerUrl: photographerUrl,
            photoPageUrl: photoPageUrl,
            sourceUrl: photoPageUrl,
          ),
        );
      }
      return entries;
    } finally {
      if (_providedClient == null) client.close();
    }
  }

  static String _string(Object? value) => value is String ? value.trim() : '';

  static bool _isUnsplashImage(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'images.unsplash.com';
  }

  static String _attributionUrl(Object? value) {
    final raw = _string(value);
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        (uri.host != 'unsplash.com' && uri.host != 'www.unsplash.com')) {
      return '';
    }
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParameters,
            'utm_source': 'travel_planner',
            'utm_medium': 'referral',
          },
        )
        .toString();
  }
}
