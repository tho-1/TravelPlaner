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
| 5 — Flutter app (desktop + Android) | **code complete and verified — repositories, UI and 31 tests, `flutter analyze` clean (`9693e28`)** | `mobile/` |
| 6 — cutover/cleanup | **deferred — do not run** (it would delete the Streamlit fallback the user decided to keep, 2026-10-10) | — |

## What this session added (Phase 5 completion)

* `mobile/lib/data/destination_repository.dart` — `loadDestinations()`,
  `getDestination()` (single-quote escaping, unknown ≠ failed),
  `updateField()` as the read-modify-write that sets the typed column **and**
  the matching entry of the lossless `data` tail (the Dart
  `repository._set_field`), `saveDestination()` (the full
  `storage_turso.save_destination` upsert).
* `mobile/lib/data/trip_repository.dart` — `loadTrips()` (the four SELECTs in
  **one** pipeline request, grouped in Dart), `saveTrip()` (one atomic
  pipeline: upsert trip → upsert variants → delete + re-insert that
  variant's stops/legs; stops without an id get one in the
  `stop-<10 hex>` shape `itinerary.models.new_id` uses), `deleteTrip()`
  (legs → stops → variants → trip, id escaped).
* `mobile/lib/ui/` — `main.dart` (config load once, bottom nav
  Catalogue/Trips, an explicit "not configured" screen),
  `catalogue_page.dart` (list + text search; empty says whether the
  database is empty or the search dropped everything),
  `destination_page.dart` (metrics, visited/favourite/❔ switches, prio
  dialog, comment editor; a `false` write is surfaced, never reported as
  success), `trips_page.dart` (trips → variants → stops/legs, trip delete
  with confirm).
* `mobile/test/` — `fake_turso.dart` (a scripted pipeline endpoint that
  captures SQL; built on `MockClient.streaming`, because the plain
  `MockClient` finalizes the request and a second `finalize()` throws),
  `pipeline_client_test.dart`, `models_test.dart`,
  `destination_repository_test.dart`, `trip_repository_test.dart`.

Verified this session: `flutter pub get`, `flutter analyze` (**no issues**),
`flutter test` (**31/31 pass**). `mobile/assets/turso_config.json` is written
(git-ignored) from `.streamlit/secrets.toml` — it holds the live
`libsql://travel-tz123...` URL and token; the client upgrades the scheme to
`https://` and appends `/v2/pipeline`.

## Bugs found and fixed (Phase 5 completion; don't re-litigate)

* **The `Destination` model must keep the *raw* typed core, not parsed
  fields.** The live `Prio Thorsten` column holds ints, a float (0.5) and
  strings (`"n/a"`, `"3 (Medellin seems better)"`); `Malaria risk?` holds
  free text. A model with `int? prio` would have written NULL over `"n/a"`
  on the next flag edit. The model now keeps the raw row values and parses
  only for display (`prioInt`, `truthy`, `text`).
* **Response bodies are decoded as UTF-8 explicitly.** The http package's
  `Response(String, ...)` validates latin1, and `Response.body` decodes with
  the header charset (latin1 default) — real JSON is UTF-8 by definition,
  so non-ASCII column names ("In näherer Auswahl 2025?") would mangle.
  `utf8.decode(bodyBytes)` in the client; the test fake builds
  `Response.bytes` with a UTF-8 charset header.
* **Connection failures mirror `turso_db.py`'s wording**: `could not reach
  Turso: <ExceptionType>` — the type only, never the full text (a URL could
  leak into it).
* Earlier session bugs (Phases 2–4) are recorded in `PLAN.md` and stay
  fixed: the benefits secrets-file fallback, the `_clear_cache` guard, the
  FastAPI background import, the NaN JSON sanitiser.

## Next steps

1. **Platform folders are missing.** `mobile/` has no `android/`, `windows/`,
   `ios/` etc., so `flutter run` / `flutter build apk` cannot work yet. Run
   `flutter create --platforms=android,windows .` inside `mobile/` (it only
   writes missing files — check `git status` afterwards), then try
   `flutter build apk`. **`flutter build apk` has never succeeded on this
   machine: no `JAVA_HOME`.** Install a JDK or set it first.
2. **Run the app on this PC** (`flutter run -d windows` after the platform
   folders exist) and do one live edit round-trip against Turso: toggle a
   favourite, check it appears on the legacy app / the API.
3. **Phase 6 is deferred by decision** (2026-10-10): do not delete the
   Streamlit pages, the workbook writers, the `sync/` stack or
   `refresh_cloud_workbook.py` — they are the fallback and the workbook
   branch's path to the phone.
4. **Push.** The commits `301832b`, `2a066fb`, `7fadbbc`, `accd28f` and the
   Phase 5 completion commit on top of it are on local `main`, pushed
   nowhere yet — the user was not asked. The branch `data-sync` must not
   be touched.
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
