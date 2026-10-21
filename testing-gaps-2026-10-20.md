# Testing Gaps — 2026-10-20 (Comprehensive)

Coverage from `flutter test --coverage`. This document lists every file in
`mobile/lib/` that has **no dedicated test coverage**, plus additional
high-value tests for files that already have some coverage but leave gaps.

The suites that exist cover many core paths, but a large fraction of the
codebase — including several high-value data paths — has no test at all.
Items are grouped by priority: **critical** (data paths that can corrupt or
mislead), **medium** (models and repositories that should be exercised
directly), and **low** (UI/widget files and edge cases that are nice to
have but lower risk).

Each entry names the file, what it does, and the specific behavior a test
should pin down.

---

## Critical (core data paths — must be covered)

### 1. `mobile/lib/data/app_settings.dart` — no test at all
The `AppSettings` class is the per-device settings store. It reads and
writes `app_settings.json` atomically (tmp + rename), handles missing or
corrupt files gracefully (returns defaults, never crashes), and exposes
per-device API key overrides that shadow the bundled config.

**Tests to add:**
- Load from a valid JSON file returns all fields correctly.
- Missing file returns default `AppSettings()` (all fields default).
- Corrupt JSON returns defaults, never throws.
- `save()` writes valid JSON and can be re-read (`round-trip`).
- `save()` returns `false` when the directory is unwritable (simulate by
  passing a read-only directory).
- Atomic write: no truncated file is ever left on disk (write to tmp,
  rename).
- `setConfigOverrides()` / `configOverrides` getter: setting overrides
  makes them visible to config loaders; clearing restores defaults.

### 2. `mobile/lib/data/app_dirs.dart` — no test at all
Directory resolution: `initAppDirs()`, `perDeviceCacheDir()`,
`documentsDir()`, `stateDirFor()`. These decide where per-device state
lives and are security-relevant (a configured path must be absolute;
falling back to the documents directory when it isn't).

**Tests to add:**
- `perDeviceCacheDir` returns the configured dir when non-empty and
  absolute; falls back to documents dir otherwise.
- `stateDirFor` returns the configured dir when absolute; otherwise
  falls back to `documentsDir()`.
- `documentsDir()` returns `''` when `initAppDirs()` hasn't been called
  (test binding), and the documents dir after init.
- `initAppDirs()` sets the documents directory from the real
  `getApplicationDocumentsDirectory()`.

### 3. `mobile/lib/data/deepseek_client.dart` — no test at all
The DeepSeek API client with `DeepSeekError`. It builds JSON payloads,
parses responses, and maps HTTP/status errors to typed exceptions. The
network calls themselves can't be tested without a server, but the
request construction and response parsing can.

**Tests to add:**
- `generateDestinationProfile` builds the correct request payload
  (model, messages, response_format, temperature) for a given
  destination/country/continent.
- `generateFoodProfile` builds the correct food-profile payload.
- `generateFlightRoutes` builds the correct route-research payload
  (including HSR fields for Chinese destinations).
- `DeepSeekError` wraps messages correctly.
- Non-200 HTTP status throws `DeepSeekError` with the status code.
- Non-JSON response throws `DeepSeekError`.
- Malformed JSON in the response throws `DeepSeekError`.
- Missing `choices`/`message`/`content` fields throw `DeepSeekError`.

### 4. `mobile/lib/data/benefits_repository.dart` — partially covered
`airline_benefits_test.dart` covers the happy path and the empty-read
fallback, but **does not test:**
- A transport failure (5xx, timeout) returns the seed list with a
  problem message, not a crash.
- A malformed JSON response (`{"type": "error"}`) is handled gracefully.
- The `utcNow()` timestamp consistency across saveTabs / readTabs.

### 5. `mobile/lib/data/weekend_repository.dart` — partially covered
`weekend_repository_test.dart` exists but the **board providers** (Fraport,
shared Turso, AeroDataBox, AirLabs) and the **conditional upsert**
guards are only lightly exercised. The conditional-upsert guard
(`WHERE updated_at = ...`) that prevents lost updates is not tested.

**Tests to add:**
- A provider that returns a stale stamp causes the conditional upsert
  to skip (zero rows affected → not treated as success).
- A provider that returns a malformed board is treated as a failure,
  not silently ignored.

---

## UI pages (widget tests missing)

### 6. `mobile/lib/ui/filter_sheet.dart` — no test
The filter sheet lets users pick countries, benefits, and other criteria.
Widget test should verify filter changes propagate to the catalogue.

### 7. `mobile/lib/ui/iqair_table.dart` — no test
AQI table rendering. Widget test should verify it renders rows correctly
and handles empty data.

### 8. `mobile/lib/ui/itinerary_compare_tab.dart` — no test
The variants table in the trip planner. Widget test should verify it
renders stops/variants correctly.

### 9. `mobile/lib/ui/nav_icons.dart` — no test
Tab icon widgets. Low value but cheap to test.

### 10. `mobile/lib/ui/theme.dart` — no test
Theme data construction. Widget test or unit test for theme colors.

### 11. `mobile/lib/ui/error_log_page.dart` — no test
The error log display page. Widget test should verify it displays errors.

### 12. `mobile/lib/ui/aqi_chart.dart` and `mobile/lib/ui/climate_chart.dart` — no tests
Chart widgets. Widget tests can verify they render without crashing.

---

## Models / pure logic (no tests at all)

### 13. `mobile/lib/models/condition.dart` — no test
`Condition` enum, `normalizeCondition()`, `conditionOfMonth()`,
`countryCondition()`. Pure logic — highly testable.

**Tests to add:**
- `normalizeCondition` maps "ideal", "good", "great", "best" → Ideal;
  "ok", "okay", "medium", "yellow" → Ok; "bad", "poor", "red", "worst"
  → Bad; everything else (including null/empty) → Unknown.
- `conditionOfMonth` maps each `MonthLevel` to the correct `Condition`.
- `countryCondition` returns the best (highest priority) condition
  among a set; empty list returns `Condition.unknown`.

### 14. `mobile/lib/models/condition.dart` (review_score.dart) — no test
`AspectSentiment`, `PlatformRating`, `DestinationReviewData` with
`calculateAspectScore()`, `calculatePlatformScore()`,
`calculateFinalScores()`, and `_roundEven()` (banker's rounding).
Pure logic — highly testable.

**Tests to add:**
- `aspect.score` returns `(pos - neg) / total`, 0 when total is 0.
- `calculateAspectScore()` averages all 7 aspect scores.
- `calculatePlatformScore()` applies the Bayesian prior: a 5.0 from 1
  review is pulled toward 3.5; a 4.6 from 900 reviews stays near 4.6.
- `calculateFinalScores()` combines aspect and platform scores into a
  0–100 score and 0–10 rating.
- `_roundEven()` implements banker's rounding (half to even), distinct
  from Dart's default half-away-from-zero rounding.

### 15. `mobile/lib/models/condition.dart` (condition.dart) — see #13 above.

### 16. `mobile/lib/models/pending_write.dart` — no test
`PendingWrite` with `toJson()` / `fromJson()`. The fromJson must reject
malformed input (return null), never guess.

**Tests to add:**
- `toJson()` produces the correct JSON shape.
- `fromJson()` returns null for non-Map input, missing fields, wrong
  types (e.g. `statements` is not a List).
- `fromJson` filters out empty statements.

### 17. `mobile/lib/models/trip.dart` — partially covered
Covered indirectly by `trip_repository_test.dart`, but no dedicated test
for the `Trip`/`Variant`/`Stop`/`Leg`/`LegType` model classes
themselves.

### 18. `mobile/lib/models/destination.dart` — no dedicated test
`Destination` and related classes are covered indirectly by
`destination_repository_test.dart` and `destination_page_test.dart`, but
have no dedicated model test.

---

## Data sources (additional gaps)

### 19. `mobile/lib/data/ai_config.dart` — no test
AI config loading and validation.

### 20. `mobile/lib/data/gallery_search.dart` — no test
Photo gallery search logic.

### 21. `mobile/lib/models/trip.dart` — no dedicated test
Trip model validation.

---

## Summary of gaps by priority

| Priority | Count | Items |
|----------|-------|-------|
| Critical | 5 | app_settings, app_dirs, deepseek_client, benefits_repository (partial), weekend_repository (partial) |
| Medium | 8 | condition.dart, review_score.dart, pending_write.dart, filter_sheet.dart, iqair_table.dart, itinerary_compare_tab.dart, ai_config.dart, config.dart |
| Low | 8 | nav_icons.dart, theme.dart, error_log_page.dart, aqi_chart.dart, climate_chart.dart, condition.dart (dedicated), pending_write.dart (dedicated), review_score.dart (dedicated) |

### Total: 21 test gaps across models, repositories, and UI pages.

## Recommendation priority order

1. **app_settings.dart** — per-device settings persistence is critical; a
   bug here loses user preferences silently.
2. **app_dirs.dart** — directory resolution affects where all per-device
   state is stored.
3. **condition.dart / review_score.dart** — pure logic, trivial to test,
   high confidence value.
4. **pending_write.dart** — the offline write journal's core type; a bug
   here corrupts the sync queue.
5. **filter_sheet.dart / itinerary_compare_tab.dart / iqair_table.dart** —
   UI widgets users interact with daily.
6. **deepseek_client.dart** — API client; at minimum test request
   construction and error parsing.