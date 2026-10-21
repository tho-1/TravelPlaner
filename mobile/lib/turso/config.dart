/// Where the Turso credentials come from.
///
/// The Python side reads `.streamlit/secrets.toml` (or the
/// environment); the app reads `assets/turso_config.json`
/// (git-ignored, template committed as `.example`). Both
/// hold the same URL and token. Without the file the app
/// runs unconfigured -- the same state as the Python side
/// without a token, never a crash.
///
/// The weekend finder needs a *second* database: the
/// airline-benefits database the legacy app reads via
/// `benefits_turso.py` (`TURSO_DATABASE_URL` /
/// `TURSO_AUTH_TOKEN`). Its credentials live in the same
/// file under `benefits_url` / `benefits_token`, and are
/// optional: without them the finder falls back to the
/// built-in seed list -- the same fallback the Python
/// ladder ends with.
///
/// The token ships in the APK: the user's decision
/// (2026-10-08) for a personal app -- obfuscation is
/// enough, and Turso's token can be revoked any time.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../data/app_settings.dart' show configOverrides;

class TursoConfig {
  final String url;
  final String token;

  /// The airline-benefits database (optional; the finder's
  /// seed list covers its absence).
  final String benefitsUrl;
  final String benefitsToken;

  /// The FlightRoutes schedule database credentials. The
  /// endpoint is the sibling project's own database (the
  /// same one hosting the `airlines` benefits table);
  /// the token is the sibling's read-write token by
  /// decision (2026-10-18, PLAN §0w): the Finder reads
  /// complete boards *and* feeds complete full-day boards
  /// back for their next sync. Never the destinations
  /// database's credentials.
  final String flightRoutesUrl;
  final String flightRoutesToken;

  /// The local IQAir ranking snapshot
  /// (`iqair_cache/world_cities.json`), read with
  /// `dart:io` on the desktop. Optional: without it
  /// the PM2.5 history table stays hidden — the
  /// same per-device pattern as the banner photos.
  final String iqairSnapshot;

  /// The `Pictures/` folder the desktop app reads
  /// banner photos from (the legacy app's folder,
  /// next to the workbook). Optional: without it —
  /// on Android, or a machine without the folder —
  /// the destination header stays typography, which
  /// is the same per-device pattern as the IQAir
  /// snapshot. The path is a PC path, so it simply
  /// does not exist on the phone and the banner
  /// stays hidden there.
  final String picturesDir;

  /// The transport routes cache folder
  /// (`flight_routes_cache/`), read and
  /// written with `dart:io` on the desktop.
  /// Optional: without it every open
  /// researches afresh — the same per-device
  /// pattern as the Pictures folder.
  final String flightRoutesCache;

  /// The itinerary geocode cache folder
  /// (`itinerary_cache/`), read and written
  /// with `dart:io` on the desktop. Optional:
  /// without it every custom-city search
  /// queries Open-Meteo again — the same
  /// per-device pattern as the routes cache.
  final String geocodeCache;

  /// The folder per-device app state is written to
  /// (`app_settings.json`). Optional: the desktop names
  /// the repo root, next to the other per-device state;
  /// the phone, which configures no paths, falls back to
  /// its documents directory.
  final String stateDir;

  /// The optional Unsplash API access key used only after a user requests
  /// gallery photos. Opening a destination never makes a search request.
  final String unsplashAccessKey;

  /// Optional AeroDataBox (RapidAPI) key for the weekend
  /// finder's fallback board provider. Without it, the
  /// finder relies on Fraport + the shared cache.
  final String aeroDataBoxApiKey;

  /// Optional AirLabs key (secondary fallback).
  final String airLabsApiKey;

  /// The FlightAware AeroAPI key (report j, 2026-10-16).
  /// Optional: with it, the finder fills board windows that
  /// failed or look incomplete from the licensed API;
  /// without it, the Fraport board is the only source. The
  /// key is never required -- it is a fallback, not a
  /// dependency.
  final String flightAwareApiKey;

  const TursoConfig({
    required this.url,
    required this.token,
    this.benefitsUrl = '',
    this.benefitsToken = '',
    this.flightRoutesUrl = '',
    this.flightRoutesToken = '',
    this.iqairSnapshot = '',
    this.picturesDir = '',
    this.flightRoutesCache = '',
    this.geocodeCache = '',
    this.stateDir = '',
    this.unsplashAccessKey = '',
    this.aeroDataBoxApiKey = '',
    this.airLabsApiKey = '',
    this.flightAwareApiKey = '',
  });

  bool get isConfigured => url.trim().isNotEmpty && token.trim().isNotEmpty;

  bool get benefitsConfigured =>
      benefitsUrl.trim().isNotEmpty && benefitsToken.trim().isNotEmpty;

  bool get flightRoutesConfigured =>
      flightRoutesUrl.trim().isNotEmpty && flightRoutesToken.trim().isNotEmpty;

  bool get fallbackFlightsConfigured =>
      flightAwareApiKey.trim().isNotEmpty;

  static const defaultUrl = 'https://travel-tz123.aws-eu-north-1.turso.io';

  /// The documented benefits database, used when the config
  /// file omits the URL but carries the token.
  static const defaultBenefitsUrl =
      'https://flightconnections-tz123.aws-eu-north-1.turso.io';

  /// Load the bundled config. A missing or malformed file
  /// leaves the app unconfigured rather than failing --
  /// the caller decides what an unconfigured app shows.
  static Future<TursoConfig> load() async {
    try {
      final text =
          await rootBundle.loadString('assets/turso_config.json');
      final map = jsonDecode(text) as Map<String, dynamic>;
      return TursoConfig(
        url: (map['url'] as String?)?.trim() ?? defaultUrl,
        token: _effective(map, 'token', configOverrides?.tursoToken),
        benefitsUrl: (map['benefits_url'] as String?)?.trim() ??
            defaultBenefitsUrl,
        benefitsToken: _effective(
            map, 'benefits_token', configOverrides?.benefitsToken),
        flightRoutesUrl:
            (map['flight_routes_url'] as String?)?.trim() ?? '',
        flightRoutesToken:
            (map['flight_routes_token'] as String?)?.trim() ?? '',
        iqairSnapshot:
            (map['iqair_snapshot'] as String?)?.trim() ?? '',
        picturesDir:
            (map['pictures_dir'] as String?)?.trim() ?? '',
        flightRoutesCache:
            (map['flight_routes_cache'] as String?)?.trim() ?? '',
        geocodeCache:
            (map['geocode_cache'] as String?)?.trim() ?? '',
        stateDir: (map['state_dir'] as String?)?.trim() ?? '',
        unsplashAccessKey:
            (map['unsplash_access_key'] as String?)?.trim() ?? '',
        flightAwareApiKey: _effective(
            map, 'flightaware_api_key', configOverrides?.flightAwareApiKey),
        aeroDataBoxApiKey:
            (map['aerodatabox_api_key'] as String?)?.trim() ?? '',
        airLabsApiKey: (map['airlabs_api_key'] as String?)?.trim() ?? '',
      );
    } catch (_) {
      return const TursoConfig(
        url: defaultUrl,
        token: '',
        benefitsUrl: defaultBenefitsUrl,
      );
    }
  }

  /// The bundled value, replaced by the per-device override
  /// when one is present (and non-empty).
  static String _effective(
    Map<String, dynamic> map,
    String key,
    String? override,
  ) {
    if (override != null && override.trim().isNotEmpty) return override;
    return (map[key] as String?)?.trim() ?? '';
  }
}
