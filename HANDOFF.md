# HANDOFF — native rebuild, in-flight work (2026-10-10)

**For the next agent.** This file tracks work that is *in progress*.
`PLAN.md` is the history; `NATIVE_HTML_PLAN.md` is the plan; `AGENTS.md` is the
orientation. Delete this file when the native phases are done.

## Where the work stands

| Phase | State | Where |
|---|---|---|
| 1 — Turso data layer | done before this session | `turso_db.py`, `storage_turso.py`, `repository.py` |
| 2 — FastAPI backend | done, committed `2a066fb` | `api.py`, `tests/test_api.py` |
| 3 — native HTML frontend | done, committed `2a066fb` | `web/` (index.html, app.js, styles.css, sw.js, manifest) |
| — benefits credentials bug | fixed, committed `2a066fb` | `benefits_turso.py`, `tests/conftest.py` |
| 4 — trips runtime cutover | done, committed `7fadbbc` | `itinerary/storage.py`, `tests/test_trips_turso.py` |
| 5 — Flutter app (desktop + Android) | **parity pushed: weekend finder, destination richness, world map, AI populate, UX pass — `fb90956`, `c55d801`, `c02008b`, `80d1f6c`, `33379ce`** | `mobile/` |
| 6 — cutover/cleanup | **deferred — do not run** (it would delete the Streamlit fallback the user decided to keep, 2026-10-10) | — |

## What the parity session added (2026-10-11)

* **Weekend finder, ported rule for rule**: `mobile/lib/models/timetable.dart`
  (the Fraport board — cursor paging, naive wall-clocks whose offsets are read
  and never applied, direct flights only with a missing `stops` kept, a loud
  failure on a shape change, Berlin DST from the last-Sunday rule),
  `models/airline_benefits.dart` (yes-only flags, code+name keys,
  `data/benefits_repository.dart`: benefits Turso → seed list, **an empty read
  is a failure, never "nobody qualifies"**), `data/weekend_repository.dart`
  (the five windowed queries; a failed window becomes a note and the legs that
  arrived are kept), `data/catalogue_match.dart` + the generated assets
  (`mobile/tools/generate_assets.py` is the documented regeneration path),
  `ui/weekend_finder_page.dart`. Throttle is 1.5 s, not the legacy 5 s —
  a phone search walks ~39 requests.
* **Destination detail richness** from the data tail:
  `models/destination_profile.dart` (blank/coerce rules, month-rating buckets,
  the avoid-text reason parser, the climate KPIs), `ui/climate_chart.dart`
  (a CustomPainter chart — no chart dependency, gaps stay gaps).
  Verified live against the real Alexandria row: the same numbers the
  Streamlit page shows.
* **World map + detail mini-map**: `models/geo.dart` (Web Mercator, tile
  addressing, spherical distance), `data/city_coordinates.dart` (the lookup
  contract *both* Python readers use — `normalize_text` first, then the
  parenthetical-stripped name; verified 144/144), `ui/world_map_page.dart`
  (slippy-map tiles, region presets, visited/favourites filter, an offline
  caption when a tile fails).
* **AI populate, key-gated**: `data/ai_config.dart` (the key in the bundled
  config), `data/deepseek_client.dart` (the legacy prompt verbatim),
  `models/review_score.dart` (the Bayesian review arithmetic),
  `data/ai_populator.dart` (the legacy field map, gaps included), and the UI
  in both the detail page's status banner and the catalogue's add dialog.
* **UX pass** (the user's request, 2026-10-11): `ui/theme.dart` (teal seed,
  light+dark, consistent cards/nav), a destination header + fact grid instead
  of five cramped metric cards, catalogue quick filters + count, icon empty
  states, dated finder chips, map offline caption. Two layout bugs found and
  fixed: the problem cards overflowed a phone-width screen (a `Row` without
  `Expanded`), and the fact grid's stretched row asked a scrolling list for an
  infinite height. `screens_test.dart` renders every screen at phone width and
  asserts the framework throws nothing — that is what caught both.

Verified: `flutter analyze` clean, **158/158 tests**, live checks against the
real board (644 flights in one Sunday window), the real benefits database (597
records, the same seven qualifying airlines), the real catalogue (144/144
coordinates) and the real Alexandria profile. `turso_config.json` now also
carries `benefits_*` and `deepseek_api_key`.

## Bugs found and fixed this session (don't re-litigate)

* **`normalize_text` is lossy on both sides.** `data_utils.normalize_text`
  drops everything that is not a-z0-9 — so "Bogotá" reaches the slug "bogot",
  not "bogota". The Dart coordinate index must be as lossy as the keys it
  looks up; a "smart" accent-folding rewrite broke 144/144.
* **`rootBundle` and a live request cannot share one Flutter test.** Once the
  test binding is active it installs an HTTP override that answers every
  request with **400** — which looks exactly like a server-side bug. A live
  check that needs assets is a `testWidgets` with no network; one that needs
  network is a plain `test` reading the config with `dart:io`.
* **`TestWidgetsFlutterBinding.ensureInitialized()` in a plain `test` installs
  the same override.** Same symptom, same lesson.
* Earlier session bugs (Phases 2–5) are recorded in `PLAN.md` and stay
  fixed: the raw typed core, UTF-8 body decoding, the benefits secrets
  fallback, the `_clear_cache` guard, the FastAPI background import, the
  import-time default paths, the NaN JSON sanitiser.

## Next steps

1. **Milestone reached on both targets.** Android: release APK + live
   round-trip on the Redmi Note 9S. Windows: `travel_planner.exe` builds
   (VS Build Tools 2022 on `E:\tools\vs-buildtools`) and loads the
   catalogue from Turso. Toolchain notes: JDK 21 at `E:\tools\jdk-21...`
   (`flutter config --jdk-dir`), Gradle cache at `E:\tools\gradle-home`,
   legacy `.gradle` moved to `E:\tools\gradle-legacy-home`, Developer Mode
   enabled, `shared_preferences` removed (the one native plugin — it
   forced the Developer-Mode/symlink requirement; re-add only with a
   feature that needs it).
2. **Parity remainder** (the user's end goal: nothing PC-side only):
   the destination **galleries** (Unsplash is key-gated exactly like the AI
   populate — the same pattern applies), trip **editing** (the app is
   read-only there on purpose), and the remaining world-map filters the
   legacy page has (month / travel condition). Each as repository + UI +
   tests, mirroring the legacy page's data sources.
3. **Release-signing note**: the release APK currently signs with the
   debug key (fine for sideloading a personal app; a real keystore is an
   open nicety, not a blocker).
4. **Phase 6 is deferred by decision** (2026-10-10): do not delete the
   Streamlit pages, the workbook writers, the `sync/` stack or
   `refresh_cloud_workbook.py` — they are the fallback and the workbook
   branch's path to the phone.
5. **Push.** Everything through the runnable-milestone commits is pushed
   to `origin/main`; keep pushing after every verified commit. The branch
   `data-sync` must not be touched.
5. Open items that stay open are in `AGENTS.md` §6 (Cloud persistence check,
   legacy rainy-day rows, `open_destinations.json` on Cloud redeploys) and
   `NATIVE_HTML_PLAN.md` Phase 5 (offline-first sync is unimplemented — the
   Flutter app is online-only over the pipeline API).

## Autonomous working agreements (decided by the user, 2026-10-11)

Binding for any session working without the user present:

1. **Push after every verified commit** to `origin/main` (CI is part of
   verification). `data-sync` stays untouched.
2. **Platform folders**: generate `android/` + `windows/` for `mobile/` and
   commit them (the target is a sideloaded APK plus a desktop run).
3. **Toolchain installs are allowed** (JDK etc.) — **prefer the E: drive
   over C:**; redirect tool caches (`GRADLE_USER_HOME`, JDK home) to E:
   where the tool supports it. Ask the user only for heavyweight installs
   (for example Visual Studio for the Windows desktop build).
4. **Small real writes to the live Turso database are permitted** for
   verification (toggle a favourite, edit a comment) — that is the app's
   purpose; last-write-wins is the accepted semantics. Never bulk-write.
5. **Feature parity is the end goal (user, 2026-10-11)**: the Flutter app
   must reach full parity with the legacy app — map, galleries, climate,
   reviews, weekend finder, AI populate, all of it. Order after the app
   runs: destination detail richness first (map, galleries, climate,
   reviews), then the weekend finder, then the key-gated features
   (AI populate), until nothing is PC-side only.
6. **Online-only stays**: no offline-first work; revisit only if the user
   reports it biting.
7. **Test policy**: targeted test files during work; the full pytest suite
   only when a change touches Python runtime code (CI re-runs it on push
   regardless; doc- and Dart-only changes go straight to CI). Conserve RAM.
8. **The phone is not an automation fixture**: it is in daily human use.
   Never send `adb input` taps without the user confirming the device is
   idle (2026-10-11: a restore tap landed in YouTube). Verify round-trips
   with screencap/uiautomator dumps (read-only) and the Python read-back;
   ask the user to do taps, or get an explicit go-ahead.

Everything else defaults to the docs: work top-down through
`HANDOFF.md` → the plan's remaining-work list, commit + push when green,
and **stop and report** at anything that would need a new user decision
rather than improvising one.

## Machine notes (this machine, Windows)

* Run the API: `& ".\.venv\Scripts\python.exe" -m uvicorn api:app --host
  127.0.0.1 --port 8508` (from the repo root). Frontend served at `/`.
* RAM is tight (other agents on this machine) — prefer targeted test files
  over the full suite, and stop background servers when done.
* `background_process` needs the quoted call operator (`& "path" -m ...`) on
  paths with spaces; "could not be verified" warnings still mean it ran; kill
  via the `netstat -ano | findstr ":8508"` listener PID.
* PowerShell's console mangles UTF-8 in `Invoke-WebRequest` output — use
  `curl.exe` to check actual response bytes.
* Credentials live in `.streamlit/secrets.toml` (git-ignored): `TURSO_*` for
  the benefits DB, `TRAVEL_PLANNER_TURSO_*` for the app DB — now also in
  `mobile/assets/turso_config.json`.
* Flutter/Dart: `C:\src\flutter\bin\flutter.bat` (3.47.2 / Dart 3.13.2). The
  Android SDK exists (`%LOCALAPPDATA%\Android\Sdk`).
