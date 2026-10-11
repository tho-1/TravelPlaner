/// The shared diacritic stripping: the accented
/// Latin and Vietnamese letters decompose to their
/// ASCII base, and ASCII passes through untouched.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/text_norm.dart';

void main() {
  group('stripDiacritics', () {
    test('decomposes the accented Latin names', () {
      expect(stripDiacritics('Cancún'), 'Cancun');
      expect(stripDiacritics('Montréal'), 'Montreal');
      expect(stripDiacritics('Zürich'), 'Zurich');
      expect(stripDiacritics('Kraków'), 'Krakow');
    });

    test('decomposes the Vietnamese letters', () {
      expect(stripDiacritics('Đà Nẵng'), 'Da Nang');
      expect(stripDiacritics('Hồ Chí Minh'), 'Ho Chi Minh');
    });

    test('the special cases keep their multi-char base', () {
      expect(stripDiacritics('Straße'), 'Strasse');
      expect(stripDiacritics('ærø'), 'aero');
    });

    test('ASCII passes through untouched', () {
      expect(stripDiacritics('New York'), 'New York');
      expect(stripDiacritics(''), '');
    });
  });
}
