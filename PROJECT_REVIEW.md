# Project Review

**Date:** 2026-10-18
**Scope:** Complete application (Flutter app in `mobile/`), current `main` branch, working tree clean except untracked `lazy_agent.md`.
**Method:** Static review of source, configuration, documentation, and plans. No code, tests, configuration, or data were modified. The normal test suite and analyzer were not rerun for this review; the last recorded run is 466 tests passing.

## Summary

The application is coherent and well-documented, with strong invariants and broad test coverage. The most meaningful risk is a production-only failure of the trip-save concurrency guard, which may never detect a conflict against the live Turso endpoint. Secondary items are minor correctness, maintainability, and documentation drift.

## Findings

### F1 — Trip-save conflict detection may be ineffective in production
- **Priority:** High
- **Perspectives:** Data integrity, application correctness
- **Evidence:** `mobile/lib/data/trip_repository.dart:154` (`upserts.first.rowsAffected == 0`); `mobile/lib/data/flight_routes_schedule_writer.dart:60` states "The live pipeline does not report `rows_affected` for DML (verified 2026-10-18)".
- **Impact:** If the live endpoint does not report `rows_affected`, the value is `null`, `null == 0` is false, and a stale save is reported as saved, silently overwriting another device's edit.
- **Recommendation:** Verify the live endpoint's DML `rows_affected` reporting with a zero-mutation probe. If unreported, replace the guard with a pre-read comparison or a returned sentinel column.

### F2 — Trip save is not transactional across statements
- **Priority:** Medium
- **Perspectives:** Data integrity, recovery
- **Evidence:** `mobile/lib/data/trip_repository.dart:135-213` runs the trip upsert and all variant/stop/leg statements in one pipeline request without `BEGIN`/`COMMIT`.
- **Impact:** A mid-batch failure can leave a trip with partially replaced variants, stops, or legs.
- **Recommendation:** Wrap the batch in an explicit transaction, or document that partial results are an accepted, surfaced failure mode.

### F3 — `Destination.truthy` is over-broad
- **Priority:** Low
- **Perspectives:** Data integrity, correctness
- **Evidence:** `mobile/lib/models/destination.dart:146-158` (`raw.contains('x')`).
- **Impact:** Any text value containing "x" (e.g. "extra") is treated as true for visited/favourite/researched/malaria fields.
- **Recommendation:** Restrict the fallback to exact token matches already enumerated; drop the substring test.

### F4 — `AppSettings.copyWith` clears sibling overrides
- **Priority:** Low
- **Perspectives:** Maintainability
- **Evidence:** `mobile/lib/data/app_settings.dart:82-98` assigns nullable parameters directly.
- **Impact:** A future caller using `copyWith` for one field silently wipes all API-key overrides. Current code avoids it, but the method is a latent trap.
- **Recommendation:** Either make `copyWith` preserve omitted fields, or remove it.

### F5 — Effective config drops FlightRoutes and Unsplash credentials
- **Priority:** Low
- **Perspectives:** Configuration, maintainability
- **Evidence:** `mobile/lib/ui/main.dart:299-323` (`_effectiveConfig`) omits `flightRoutesUrl`, `flightRoutesToken`, and `unsplashAccessKey`.
- **Impact:** Per-device rotation is impossible for those keys, and `effective.unsplashAccessKey` is always empty if any code path uses it.
- **Recommendation:** Carry all bundled fields through `_effectiveConfig`, or document the omission as intentional.

### F6 — Test-count documentation drift
- **Priority:** Low
- **Perspectives:** Maintainability
- **Evidence:** `README.md:208` and `AGENTS.md` state 430 tests; the current suite runs 476.
- **Impact:** Minor confusion for agents and CI readers.
- **Recommendation:** Update the documented count.

### F7 — Deferred feature items remain unimplemented
- **Priority:** Low
- **Perspectives:** Requirements and scope
- **Evidence:** `MOBILE_REPORTS_2026-10-17.md` marks items (g) AeroAPI key, (i) finder expanded-result redesign, (k) shared Turso departure data, (q)/(s) destination pictures as deferred or proposal-only.
- **Impact:** Feature-parity gaps are tracked but not scheduled; risk of silent neglect.
- **Recommendation:** Decide whether to proceed with proposals `PROPOSAL_SHARED_TURSO.md` and `PROPOSAL_PICTURES.md`, or close them explicitly.

### F8 — Concentrated UI files
- **Priority:** Low
- **Perspectives:** Maintainability
- **Evidence:** `mobile/lib/ui/world_map_page.dart` (~69 KB) and `mobile/lib/ui/destination_page.dart` (~68 KB).
- **Impact:** Future agent edits to these files carry higher regression risk and cognitive load.
- **Recommendation:** Split only when a change touches them; do not refactor for appearance alone.

### F9 — World-map tiles have no persistent cache
- **Priority:** Low (potential bottleneck)
- **Perspectives:** Performance, resource use
- **Evidence:** `mobile/lib/ui/world_map_page.dart:471` uses `Image.network` for each tile.
- **Impact:** Repeated zoom/pan may re-fetch tiles; memory-only caching may not survive widget rebuilds.
- **Recommendation:** Measure before changing; Flutter's image cache may already cover the common case.

### F10 — Inconsistent timestamp precision
- **Priority:** Low
- **Perspectives:** Data integrity
- **Evidence:** `mobile/lib/data/open_tabs_repository.dart:59` uses `DateTime.now().toUtc().toIso8601String()` (microsecond precision, `Z`), while other writers use second precision with `+00:00`.
- **Impact:** Mixed stamp formats in one database; comparisons rely on `DateTime.tryParse`, which handles both, but consistency is lost.
- **Recommendation:** Align `saveTabs` to the shared `utcNow()` helper.

## Decisions required

1. **Trip concurrency guard:** Is conflict detection (reload-latest-on-stale-save) worth preserving, or is last-write-wins acceptable without a guard? The current guard may be a no-op in production. Recommend keeping the guard but fixing its mechanism (F1).
2. **Deferred features:** Should the shared-Turso departure-data integration and the destination-picture pipeline be implemented now, or dropped from scope? Recommend deciding explicitly and recording the outcome in `AGENTS.md`.

## Technical instructions for the next agent

- Add a test that runs `saveTrip` against a fake reporting `rows_affected: null` and asserts the resulting status; this pins the F1 behavior.
- Add unit tests for `Destination.truthy` with values containing "x" (F3).
- Align `saveTabs` timestamp format and add a regression test (F10).
- Keep `flutter analyze` and `flutter test` green; do not weaken existing tests.
- Deferred (Xiaomi 15): when the device is next connected for another reason, capture `error_log.jsonl` and verify finder date/DST and map-tap paths; add the check to the project plan as a low-priority item. Do not connect the device solely for this review.

## Permanent test-suite assessment

Coverage is strong for pure models and repositories. Worthwhile additions are limited to the items above (F1, F3, F10). No trivial, speculative, or duplicative tests are recommended.
