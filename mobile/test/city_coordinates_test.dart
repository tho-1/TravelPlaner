/// The coordinate table: the key scheme, the two lookup
/// half-rules, and the bundled asset. Loaded through
/// rootBundle (a widget test binding), no network.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/city_coordinates.dart';

void main() {
  group('key helpers', () {
    test('normalizeText folds everything that is not a-z0-9', () {
      // The table's slug keys are ASCII, so an accented
      // workbook name must reach the same key.
      expect(normalizeText('Bogotá'), 'bogot');
      expect(normalizeText("Xi'an (Shaanxi)"), 'xianshaanxi');
      expect(normalizeText('  Mexico   City '), 'mexicocity');
    });

    test('cleanCityName strips one qualifier', () {
      expect(cleanCityName("Xi'an (Shaanxi)"), "Xi'an");
      expect(cleanCityName('Zanzibar (Stone Town)'), 'Zanzibar');
      expect(cleanCityName('London'), 'London');
    });

    test('caseFolded keeps the accents, aliasOf drops the punctuation', () {
      expect(caseFolded('  Bogotá  City '), 'bogotá city');
      expect(aliasOf("Xi'an"), 'xian');
    });
  });

  group('the bundled table', () {
    test('the asset is bundled and holds the 144 coordinate rows', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final index = await CoordinateIndex.load();
      expect(CoordinateIndex.loadError, isNull);
      expect(index.sizeForDebug, greaterThanOrEqualTo(144));
    });

    test('a name resolves by the raw, the stripped and the folded spellings',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final index = await CoordinateIndex.load();
      final alexandria = index.lookup('Alexandria');
      expect(alexandria?.name, 'Alexandria');
      expect(alexandria?.country, 'Egypt');
      expect(alexandria?.lat, closeTo(31.2001, 1e-6));
      // The accent folds, like the legacy map's lookup.
      expect(index.lookup('Bogotá')?.lat, closeTo(4.711, 1e-6));
      // The parenthetical is stripped on the second try.
      expect(index.lookup("Xi'an (Shaanxi)")?.name, "Xi'an");
      expect(index.lookup("Xi'an")?.lat, closeTo(34.3416, 1e-6));
      // Unknown is a normal answer, not a crash.
      expect(index.lookup('Nowhere'), isNull);
      expect(index.lookup(null), isNull);
    });
  });
}
