/// The AI populate pipeline: the review score, the
/// profile -> destination mapping, and the DeepSeek
/// request. The API is faked, so no network and no key.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_planner/data/ai_config.dart';
import 'package:travel_planner/data/ai_populator.dart';
import 'package:travel_planner/data/deepseek_client.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/review_score.dart';

Destination _placeholder() => Destination(
      core: {
        'destination': 'San Gimignano',
        'country': 'Italy',
        'continent': 'Europe',
        'data_status': 'PLACEHOLDER - UPDATE REQUIRED',
        'to_be_researched': true,
      },
      columns: const [
        ('Destination', 'San Gimignano'),
        ('Continent', 'Europe'),
        ('Country', 'Italy'),
        ('Data Status', 'PLACEHOLDER - UPDATE REQUIRED'),
      ],
    );

/// A profile in the shape DeepSeek produces: every field
/// present, month ratings and climate arrays full.
Map<String, dynamic> _profile() => {
      'destination': 'San Gimignano',
      'country': 'Italy',
      'continent': 'Europe',
      'profile': {
        'why_to_go': 'A hill town of towers.',
        'what_to_expect': 'Steep streets and views.',
        'ideal_time_to_go': 'Spring and Autumn',
        'avoid_going': 'Winter (December-February) (cold)',
        'recommended_stay': '1-2 days',
        'avg_cost_per_day_eur': '65',
        'rent_a_car': 'Yes',
        'highlights': 'Torri, the Duomo',
        'population_metro': 7800,
        'visa_requirement': 'Not at all',
        'flight_time_hours': 1.5,
        'safety_rating_10': 8,
        'introduction_sentence': 'A medieval skyline.',
        'in_eu': true,
        'month_ratings': {
          'January': 'ok',
          'February': 'ok',
          'March': 'ideal',
          'April': 'ideal',
          'December': 'bad',
        },
      },
      'reviews': {
        'praise': 'The views are wonderful.',
        'dislikes': 'The crowds at midday.',
        'total_reviews_analyzed': 100,
        'date_range': 'Feb 2024 - Feb 2026',
        'aspects': {
          'Scenery & atmosphere': {'pos': 80, 'neutral': 15, 'neg': 5},
          'Things to do': {'pos': 60, 'neutral': 30, 'neg': 10},
          'Food & drink': {'pos': 70, 'neutral': 20, 'neg': 10},
          'Value for money': {'pos': 40, 'neutral': 40, 'neg': 20},
          'Crowds & overtourism': {'pos': 20, 'neutral': 20, 'neg': 60},
          'Safety & cleanliness': {'pos': 75, 'neutral': 20, 'neg': 5},
          'Getting around / accessibility': {'pos': 30, 'neutral': 30, 'neg': 40},
        },
        'platform_ratings': [
          {'source_name': 'Google Maps', 'avg_rating': 4.6, 'review_count': 900},
          {'source_name': 'TripAdvisor', 'avg_rating': 4.5, 'review_count': 3200},
        ],
      },
      'climate': {
        'high_c': [for (var i = 0; i < 12; i++) 10 + i],
        'low_c': [for (var i = 0; i < 12; i++) 2 + i],
        'rainy_days': [for (var i = 0; i < 12; i++) i],
        'rain_mm': [for (var i = 0; i < 12; i++) i * 10],
        'aqi': [for (var i = 0; i < 12; i++) 40 + i],
      },
    };

void main() {
  group('review score', () {
    test('an aspect nobody mentioned scores 0', () {
      expect(const AspectSentiment().score, 0);
      expect(const AspectSentiment(pos: 8, neg: 2).score, closeTo(0.6, 1e-9));
    });

    test('a 5.0 from 12 reviews is pulled towards the prior', () {
      final few = DestinationReviewData(
        destinationName: 'X',
        country: 'Y',
        platformRatings: const [
          PlatformRating(sourceName: 'G', avgRating: 5.0, reviewCount: 12),
        ],
      );
      final many = DestinationReviewData(
        destinationName: 'X',
        country: 'Y',
        platformRatings: const [
          PlatformRating(sourceName: 'G', avgRating: 4.6, reviewCount: 900),
        ],
      );
      expect(few.calculatePlatformScore(), lessThan(many.calculatePlatformScore()));
    });

    test('the final score is the weighted combination, clamped', () {
      final data = DestinationReviewData(
        destinationName: 'X',
        country: 'Y',
        aspectCounts: const {
          'Scenery & atmosphere': AspectSentiment(pos: 100, neg: 0),
          'Things to do': AspectSentiment(pos: 100, neg: 0),
          'Food & drink': AspectSentiment(pos: 100, neg: 0),
          'Value for money': AspectSentiment(pos: 100, neg: 0),
          'Crowds & overtourism': AspectSentiment(pos: 100, neg: 0),
          'Safety & cleanliness': AspectSentiment(pos: 100, neg: 0),
          'Getting around / accessibility': AspectSentiment(pos: 100, neg: 0),
        },
        platformRatings: const [
          PlatformRating(sourceName: 'G', avgRating: 4.8, reviewCount: 500),
        ],
      );
      final scores = data.calculateFinalScores();
      expect(scores['Final Score (0-100)'], greaterThan(80));
      expect(scores['Confidence'], 'High');
    });
  });

  group('AiPopulator', () {
    test('the profile lands in the typed core and the tail', () {
      final updated = AiPopulator(_placeholder()).apply(_profile());
      expect(updated.avgCostDay, 65);
      expect(updated.flightTimeFra, 1.5);
      expect(updated.safetyRating, 8);
      expect(updated.column('Why to Go There'), 'A hill town of towers.');
      expect(updated.column('Recommended Stay'), '1-2 days');
      expect(updated.column('Population (Metro Area)'), 7800);
      expect(updated.column('Visa Requirement'), 'Not at all');
      expect(updated.column('Visa?'), 'Not at all');
      expect(updated.column('Introduction Sentence'), 'A medieval skyline.');
      expect(updated.column('Yes?'), isTrue);
      expect(updated.column('March'), 'ideal');
      expect(updated.column('December'), 'bad');
      // The climate arrays land per month, and the average
      // AQI too (46.5 = mean of 40..51).
      expect(updated.column('Jan High (C)'), 10);
      expect(updated.column('Dec Low (C)'), 13);
      expect(updated.column('Jun Rain (mm)'), 50);
      expect(updated.column('Avg AQI'), 45.5);
      // "Reachable via" is deliberately not written.
      expect(updated.column('Reachable via'), isNull);
    });

    test('the reviews land, with the summary line', () {
      final updated = AiPopulator(_placeholder()).apply(_profile());
      final reviews = updated.column('Reviews');
      expect(reviews, isA<double>());
      expect(reviews as double, greaterThan(5));
      expect(updated.column('What do the reviews praise?'),
          'The views are wonderful.');
      expect(updated.column('What do they dislike?'),
          'The crowds at midday.');
      expect(updated.column('Tourist Reviews'),
          'The views are wonderful. Recurring criticisms mention '
          'The crowds at midday.');
    });

    test('the placeholder status clears', () {
      final updated = AiPopulator(_placeholder()).apply(_profile());
      expect(updated.dataStatus, isNull);
      expect(updated.column('Data Status'), isNull);
      // The populate does not touch the other flag -- the
      // legacy flow clears only the status.
      expect(updated.toBeResearched, isTrue);
    });

    test('a blank value is skipped, never overwritten', () {
      final profile = _profile();
      (profile['profile'] as Map)['recommended_stay'] = '   ';
      final updated = AiPopulator(_placeholder()).apply(profile);
      expect(updated.column('Recommended Stay'), isNull);
    });

    test('a malformed review section never blocks the rest', () {
      final profile = _profile();
      profile['reviews'] = 'not an object';
      final updated = AiPopulator(_placeholder()).apply(profile);
      expect(updated.column('Reviews'), isNull);
      expect(updated.column('Why to Go There'), 'A hill town of towers.');
      expect(updated.column('Mar High (C)'), 12);
    });

    test('a short climate array is not padded', () {
      final profile = _profile();
      (profile['climate'] as Map)['aqi'] = [40, 41];
      final updated = AiPopulator(_placeholder()).apply(profile);
      // The monthly columns need all twelve values; the
      // average is of whatever the array holds (the legacy
      // _avg behaves the same way).
      expect(updated.column('Jan AQI'), isNull);
      expect(updated.column('Avg AQI'), 40.5);
    });
  });

  group('DeepSeekClient', () {
    test('the request mirror the legacy payload', () async {
      Map<String, dynamic>? sent;
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"profile": {"why_to_go": "x"}}'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final profile = await client.generateDestinationProfile(
        destination: 'Test City',
        country: 'Testland',
        continent: 'Europe',
      );
      expect(sent!['model'], 'deepseek-chat');
      expect((sent!['response_format'] as Map)['type'], 'json_object');
      expect(sent!['temperature'], 0.3);
      final messages = sent!['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      final user = (messages.last as Map)['content'] as String;
      expect(user, contains('Test City'));
      expect(user, contains('Testland'));
      expect(user, contains('Europe'));
      expect(user, contains('month_ratings'));
      expect((profile['profile'] as Map)['why_to_go'], 'x');
    });

    test('a fenced response still parses', () async {
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content':
                          'Here you go:\n```json\n{"profile": {}}\n```\nDone.',
                    },
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      final profile =
          await client.generateDestinationProfile(
        destination: 'X',
        country: 'Y',
        continent: 'Z',
      );
      expect(profile.containsKey('profile'), isTrue);
    });

    test('without a key the error says how to configure', () async {
      final client = DeepSeekClient(const AiConfig());
      await expectLater(
        client.generateDestinationProfile(
            destination: 'X', country: 'Y', continent: 'Z'),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('deepseek_api_key'))),
      );
    });

    test('an HTTP error carries the status', () async {
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async =>
            http.Response('rate limited', 429)),
      );
      await expectLater(
        client.generateDestinationProfile(
            destination: 'X', country: 'Y', continent: 'Z'),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('HTTP 429'))),
      );
    });

    test('an unparseable response is an error, not a crash', () async {
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async => http.Response(
              jsonEncode({
                'choices': [
                  {'message': {'content': 'I cannot help with that.'}},
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      await expectLater(
        client.generateDestinationProfile(
            destination: 'X', country: 'Y', continent: 'Z'),
        throwsA(isA<DeepSeekError>()),
      );
    });
  });

  group('user prompt', () {
    test('the template placeholders are substituted', () {
      final prompt =
          DeepSeekClient.userPrompt('A, B', 'C', 'D');
      expect(prompt, isNot(contains('__DEST__')));
      expect(prompt, contains('A, B'));
      expect(prompt, contains('"aqi": [12 numbers'));
    });
  });
}
