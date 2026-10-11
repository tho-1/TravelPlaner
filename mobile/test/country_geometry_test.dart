/// The bundled country geometry: the asset loads, the
/// lookup answers the catalogue's spellings, and the
/// aliases resolve. Loaded through rootBundle (a widget
/// test binding), no network.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/country_geometry.dart';

void main() {
  group('the bundled geometry', () {
    test('the asset is bundled and holds the 180 features', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final geometry = await CountryGeometry.load();
      expect(CountryGeometry.loadError, isNull);
      expect(geometry.shapeCount, 182);
    });

    test('a country resolves, with the alias spellings', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final geometry = await CountryGeometry.load();
      final egypt = geometry.lookup('Egypt');
      expect(egypt?.name, 'Egypt');
      expect(egypt?.pointCount, greaterThan(10));
      // The two workbook spellings the dataset spells
      // longer — without the alias table they had no fill.
      expect(geometry.lookup('Tanzania')?.name, 'United Republic of Tanzania');
      expect(geometry.lookup('UAE')?.name, 'United Arab Emirates');
      // Unknown is a normal answer: no fill, cities still
      // plot.
      expect(geometry.lookup('Atlantis'), isNull);
      expect(geometry.lookup(null), isNull);
    });
  });
}
