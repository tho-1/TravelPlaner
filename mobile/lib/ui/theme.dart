/// The app's visual language: one place for the colour
/// scheme, the card shapes and the type scale, so every
/// screen is consistent.
///
/// The seed is a travel-appropriate teal (the sea-and-map
/// palette the Streamlit app's own visuals lean towards)
/// and both a light and a dark scheme are defined, because
/// the desktop app follows the system setting and the
/// phone often does not.
library;

import 'package:flutter/material.dart';

/// The teal every scheme is seeded from.
const seedColour = Color(0xFF0E7C86);

/// Accents used across the app — the palette the colour
/// icons and the stat tiles share.
const accentSafety = Color(0xFF2E9E6B);
const accentCost = Color(0xFFE3A857);
const accentFlight = Color(0xFF4FA3D1);
const accentPopulation = Color(0xFF9575CD);
const accentFavourite = Color(0xFFF6B100);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColour,
    brightness: brightness,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
  );
  return base.copyWith(
    cardTheme: CardThemeData(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      filled: true,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
    ),
  );
}
