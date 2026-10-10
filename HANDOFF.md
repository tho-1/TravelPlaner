# HANDOFF — native rebuild, in-flight work (2026-10-10)

**For the next agent.** This file tracks work that is *in progress*.
`PLAN.md` is the history; `NATIVE_HTML_PLAN.md` is the plan; `AGENTS.md` is the
orientation. Delete this file when the native phases are done.

## Where the work stands

| Phase | State | Where |
|---|---|---|
| 1 — Turso data layer | done before this session | `turso_db.py`, `storage_turso.py`, `repository.py` |
| 2 — FastAPI backend | **done, committed `2a066fb`** | `api.py`, `tests/test_api.py` |
| 3 — native HTML frontend | **done, committed `2a066fb`** | `web/` (index.html, app.js, styles.css, sw.js, manifest) |
| — benefits credentials bug | **fixed, committed `2a066fb`** | `benefits_turso.py`, `tests/conftest.py` |
| 4 — trips runtime cutover | **done, committed `7fadbbc`** | `itinerary/storage.py`, `tests/test_trips_turso.py` |
| 5 — Flutter app (desktop + Android) | **in progress — scaffold written, NOT yet compiled** | `mobile/` (uncommitted) |
| 6 — cutover/cleanup | **not started — see the decision below** | — |

Commits this session (all on `main`, pushed nowhere yet — the user was not
asked to push):

```
7fadbbc  Trips runtime cutover to Turso (Phase 4): storage ladder, Turso-first
         with trips.json fallback
2a066fb  Backend API and native HTML frontend (Phases 2-3); benefits secrets
         file fallback
301832b  Declare the Streamlit version legacy; target architecture is native
```

Working tree at handoff time: `mobile/` (untracked), `.gitignore` (modified:
Flutter build artifacts + `mobile/assets/turso_config.json`). Waiting on the
commit of Phase 5.

## Next steps (Phase 5, in order)

1. **`mobile/lib/data/destination_repository.dart`** — `loadDestinations()`,
   `getDestination(name)`, `updateField(name, field, value)`. Mirror
   `storage_turso.py`: the flag editors must do a read-modify-write that sets
   the typed column **and** the matching entry of the lossless `data` tail
   (this is exactly what `repository.py:_set_field` does; a targeted UPDATE
   that only touches the typed column would leave the tail stale).
2. **`mobile/lib/data/trip_repository.dart`** — port `storage_turso`:
   `loadTrips()` (trips → variants → stops → legs, grouped in Dart),
   `saveTrip(trip)` (one pipeline: upsert trip, upsert variants, delete +
   re-insert that variant's stops/legs), `deleteTrip(id)`.
3. **`mobile/lib/ui/main.dart`** — app shell, bottom nav (Catalogue, Trips),
   loads `TursoConfig` once and hands the repositories down.
4. **`mobile/lib/ui/catalogue_page.dart`** — list + text search.
   **`destination_page.dart`** — metrics + the flag editors.
   **`trips_page.dart`** — trips list with variants/stops/legs.
5. **`mobile/test/*_test.dart`** — `pipeline_client_test.dart`
   (fake `http.Client`: typed cells, error-inside-200, 401, timeout),
   `models_test.dart`, one fake-client repository test each.
6. Verify, in `mobile/`:
   ```powershell
   & "C:\src\flutter\bin\flutter.bat" pub get
   & "C:\src\flutter\bin\flutter.bat" analyze
   & "C:\src\flutter\bin\flutter.bat" test
   ```
7. Put the real credentials in **`mobile/assets/turso_config.json`**
   (git-ignored; copy `TRAVEL_PLANNER_TURSO_URL` / `TRAVEL_PLANNER_TURSO_TOKEN`
   from `.streamlit/secrets.toml`, template: `turso_config.example.json`).
   `flutter analyze`/`test` work without it — the app runs unconfigured.
8. Commit Phase 5.

Then: Phase 6 (see below), the docs pass, and the full verification.

## Bugs found and fixed this session (don't re-litigate)

* **`benefits_turso` ignored the secrets file.** It read `TURSO_AUTH_TOKEN`
  from `os.environ` only, while `turso_db` and `sync/transport_github` both fall
  back to `.streamlit/secrets.toml`. In any non-Streamlit process (the API, a
  script) the benefits ladder therefore fell through to the seed list, LH was
  rejected, and the weekend finder returned **0 cities from 556 outbound
  flights** — silently. Fixed with the same env→file fallback, plus an autouse
  conftest fixture (`_isolate_benefits_turso_secrets`) so the suite stays
  hermetic on a machine that has the real secrets file, plus a test.
* **`repository._clear_cache()` broke under the API's cache passthrough.**
  `TRAVEL_PLANNER_API` makes `_cache_data` return the raw function, which has
  no `.clear()`; `_clear_cache` now guards with `getattr`.
* **`fastapi.background.BackgroundTask` no longer exists in FastAPI 0.143.**
  Import the singular class from `starlette.background` instead.
* **The workbook's empty cells read as `NaN`, which JSON refuses to
  serialize.** `api._jsonable()` sanitises every cell (NaN/NaT → null, numpy
  scalars → plain).

## Decisions taken (and why)

* **Streamlit is the legacy fallback; Phase 6 is deferred.** The user's decision
  (2026-10-10): archive it as a source of knowledge and a fall-back. So the
  "delete Streamlit pages + workbook writers + sync stack" phase of
  `NATIVE_HTML_PLAN.md` §7 must **not** run yet — it would delete the fallback.
  The journal sync stack and `refresh_cloud_workbook.py` stay.
* **The trips cutover lives inside `itinerary/storage.py`, not in
  `repository.py`.** Every consumer (legacy pages, the API, the tests) then
  shares one path, so the legacy app stays a *true* fallback that sees the same
  trips as the API. Verified live: an API create+delete round-tripped through
  Turso while `trips.json`'s mtime stayed at 2026-09-20.
* **The API is Streamlit-free.** `api.py` sets `TRAVEL_PLANNER_API=1` before
  importing the repository, which turns the repository's `st.cache_data`
  decorator into a passthrough (fresh data per request). `data_utils`' own
  cache is mtime-keyed and cleared on every write, so it is safe as-is.
* **The Flutter app talks to Turso directly** (pipeline API, per
  `NATIVE_HTML_PLAN.md`), not through the FastAPI backend, and the read-write
  token ships in the APK — the user's decision (2026-10-08), personal app.

## Verified live (this session)

* `uvicorn api:app --port 8508` reads Turso: 144 destinations, 2 trips, 10 open
  tabs; `/api/weekend?friday=2026-10-16` returns **119 cities / 377 options**
  from the live Fraport boards in 8.4 s (cold), ~1.3 s from cache.
* Trips CRUD through the API writes Turso, not `trips.json`.
* Python tests: `tests/test_api.py tests/test_trips_turso.py
  tests/test_benefits_turso.py tests/test_repository.py tests/test_trips_safety.py
  tests/test_itinerary.py tests/test_sync_*.py tests/test_storage_turso.py` all
  pass. **The full suite has NOT been run since Phase 1 — run it once at the
  end** (511+ tests, ~3 min).

## Machine notes (this machine, Windows)

* Run the API: `& ".\.venv\Scripts\python.exe" -m uvicorn api:app --host
  127.0.0.1 --port 8508` (from the repo root). Frontend served at `/`.
* RAM is tight (other agents on this machine) — prefer targeted test files over
  the full suite, and stop background servers when done.
* `background_process` needs the quoted call operator (`& "path" -m ...`) on
  paths with spaces; "could not be verified" warnings still mean it ran; kill
  via the `netstat -ano | findstr ":8508"` listener PID (uvicorn's real worker
  PID differs from the reported one).
* PowerShell's console mangles UTF-8 in `Invoke-WebRequest` output — use
  `curl.exe` to check actual response bytes.
* Credentials live in `.streamlit/secrets.toml` (git-ignored): `TURSO_*` for
  the benefits DB, `TRAVEL_PLANNER_TURSO_*` for the app DB. Non-Streamlit
  processes need the file fallback (see the bug above).
* Flutter/Dart: `C:\src\flutter\bin\flutter.bat` (3.47.2 / Dart 3.13.2). The
  Android SDK exists (`%LOCALAPPDATA%\Android\Sdk`); **`flutter build apk` has
  not been tried** (no `JAVA_HOME`; Gradle is heavy on this machine).
