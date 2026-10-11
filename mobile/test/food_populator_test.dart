/// The food populate pipeline: the food profile
/// parsing and validation, the profile -> destination
/// mapping, and the DeepSeek request. The API is
/// faked, so no network and no key.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_planner/data/ai_config.dart';
import 'package:travel_planner/data/deepseek_client.dart';
import 'package:travel_planner/data/food_populator.dart';
import 'package:travel_planner/models/destination.dart';

/// A food profile in the shape DeepSeek produces.
Map<String, dynamic> _validFood() => {
      'spiciness': 6,
      'dishes': ['Pad Thai', 'Tom Yum Goong', 'Som Tum', 'Khao Soi'],
      'description': 'One. Two. Three. Four. Five.',
    };

Destination _destination() => Destination(
      core: {
        'destination': 'Bangkok',
        'country': 'Thailand',
        'continent': 'Asia',
        'data_status': 'PLACEHOLDER - UPDATE REQUIRED',
      },
      columns: const [
        ('Destination', 'Bangkok'),
        ('Country', 'Thailand'),
        ('Continent', 'Asia'),
        ('Data Status', 'PLACEHOLDER - UPDATE REQUIRED'),
      ],
    );

void main() {
  group('parseFoodProfile', () {
    test('a valid profile parses', () {
      final food = parseFoodProfile(_validFood());
      expect(food.spiciness, 6);
      expect(food.description, 'One. Two. Three. Four. Five.');
      expect(food.dishes,
          ['Pad Thai', 'Tom Yum Goong', 'Som Tum', 'Khao Soi']);
    });

    test('a spiciness sent as a string still parses', () {
      final profile = _validFood();
      profile['spiciness'] = '7';
      expect(parseFoodProfile(profile).spiciness, 7);
    });

    test('a string of dishes is split on separators', () {
      final profile = _validFood();
      profile['dishes'] = 'Pad Thai; Tom Yum Goong\nSom Tum';
      expect(parseFoodProfile(profile).dishes,
          ['Pad Thai', 'Tom Yum Goong', 'Som Tum']);
    });

    test('a missing spiciness is rejected', () {
      final profile = _validFood();
      profile.remove('spiciness');
      expect(
        () => parseFoodProfile(profile),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('spiciness'))),
      );
    });

    test('a negative spiciness is rejected', () {
      final profile = _validFood();
      profile['spiciness'] = -1;
      expect(
        () => parseFoodProfile(profile),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('spiciness'))),
      );
    });

    test('an empty description is rejected', () {
      final profile = _validFood();
      profile['description'] = '   ';
      expect(
        () => parseFoodProfile(profile),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('5-10 sentence'))),
      );
    });

    test('a description of four sentences is rejected', () {
      final profile = _validFood();
      profile['description'] = 'One. Two. Three. Four.';
      expect(
        () => parseFoodProfile(profile),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('5-10 sentence'))),
      );
    });

    test('a description of eleven sentences is rejected', () {
      final profile = _validFood();
      profile['description'] =
          'One. Two. Three. Four. Five. Six. Seven. Eight. Nine. Ten. Eleven.';
      expect(
        () => parseFoodProfile(profile),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('5-10 sentence'))),
      );
    });
  });

  group('countFoodSentences', () {
    test('counts the sentences the legacy regex counts', () {
      expect(countFoodSentences('One. Two. Three. Four. Five.'), 5);
      expect(countFoodSentences('One! Two? Three. Four. Five.'), 5);
      expect(countFoodSentences(''), 0);
    });
  });

  group('FoodPopulator', () {
    test('the profile lands in the three Food columns', () {
      final updated = FoodPopulator(_destination()).apply(const FoodProfile(
        spiciness: 6.5,
        description: 'One. Two. Three. Four. Five.',
        dishes: ['Pad Thai', 'Tom Yum Goong'],
      ));
      expect(updated.column('Food - Spicyness'), 6.5);
      expect(updated.column('Food - Description'),
          'One. Two. Three. Four. Five.');
      expect(updated.column('Food - Main Dishes'), 'Pad Thai, Tom Yum Goong');
      // The typed core is untouched, and the placeholder
      // status survives -- only the full populate clears it.
      expect(updated.name, 'Bangkok');
      expect(updated.dataStatus, 'PLACEHOLDER - UPDATE REQUIRED');
    });
  });

  group('DeepSeekClient', () {
    test('the request mirrors the legacy payload', () async {
      Map<String, dynamic>? sent;
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': jsonEncode(_validFood())},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final food = await client.generateFoodProfile(
        destination: 'Bangkok',
        country: 'Thailand',
      );
      expect(sent!['model'], 'deepseek-chat');
      expect((sent!['response_format'] as Map)['type'], 'json_object');
      expect(sent!['temperature'], 0.3);
      final messages = sent!['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      expect((messages.first as Map)['content'],
          contains('travel food researcher'));
      final user = (messages.last as Map)['content'] as String;
      expect(user, contains('Bangkok'));
      expect(user, contains('Thailand'));
      expect(user, isNot(contains('__DEST__')));
      expect(user, contains('spiciness'));
      expect(food.spiciness, 6);
      expect(food.dishes,
          ['Pad Thai', 'Tom Yum Goong', 'Som Tum', 'Khao Soi']);
    });

    test('a description that is not 5-10 sentences is rejected', () async {
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient: MockClient((request) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode({
                        'spiciness': 6,
                        'dishes': ['Pad Thai'],
                        'description': 'Too short.',
                      }),
                    },
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      await expectLater(
        client.generateFoodProfile(destination: 'X', country: 'Y'),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('5-10 sentence'))),
      );
    });

    test('without a key the error says how to configure', () async {
      final client = DeepSeekClient(const AiConfig());
      await expectLater(
        client.generateFoodProfile(destination: 'X', country: 'Y'),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('deepseek_api_key'))),
      );
    });

    test('an HTTP error carries the status', () async {
      final client = DeepSeekClient(
        const AiConfig(apiKey: 'sk-test'),
        httpClient:
            MockClient((request) async => http.Response('rate limited', 429)),
      );
      await expectLater(
        client.generateFoodProfile(destination: 'X', country: 'Y'),
        throwsA(isA<DeepSeekError>()
            .having((e) => e.message, 'message', contains('HTTP 429'))),
      );
    });
  });
}
