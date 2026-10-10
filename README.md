# Travel Planner

> **Status (2026-10-10): the Streamlit version in this repository is
> legacy.** It is archived as a source of knowledge and as a potential
> fall-back in case the new development does not go as planned. The
> target architecture moves away from Streamlit — a native desktop +
> Android app on the Turso data layer. The decision, the phases and
> the current status: `NATIVE_HTML_PLAN.md`.

A personal travel catalogue: browse destinations on a world map, read a
detail page per city, and plan multi-stop trips with variants, dates,
transport legs and a route map. Edits made on the PC and on the phone
(Streamlit Cloud) are merged through change journals instead of
overwriting each other.

> **Working on this codebase? Read [`AGENTS.md`](AGENTS.md) first** — it is the
> entry point: where everything lives, the data-safety rules that must not break,
> how to verify a change, and the open items.

## Running it (the legacy Streamlit version)

```powershell
# Local (workbook: Destinations-local.xlsx)
python -m streamlit run app.py --server.port 8507
```

The Cloud deployment uses `Destinations-cloud.xlsx` and shows a banner telling
you which mode you are in. See `environment.py`.

## Where your data lives

**Source of truth: `Destinations-local.xlsx` on the PC** (decided 2026-10-03).
`Destinations-cloud.xlsx` is the *deploy seed* Streamlit Cloud starts from, and
the phone edits a writable copy of it. Bulk data (climate, AQI, costs, safety,
food) is only ever produced locally, so it has to be copied into the Cloud seed
and committed before the phone can see it:

```powershell
python refresh_cloud_workbook.py            # report what would change
python refresh_cloud_workbook.py --apply    # back up first, then copy local -> cloud
```

Interactive edits (favourite / visited / ❔ / Prio / comment / reviews / food)
travel the other way through the sync journals, so a phone edit still reaches
the PC without a redeploy.

What a sync can move, and at what size:

| Thing | Journal key | Example |
|---|---|---|
| a workbook cell | `(destination, column)` | a comment on Naples |
| a new destination | `(destination, "#row")` | added on the PC, created on the phone, then its cells land in the new row |
| a trip variant's own fields | `(trip, variant, "meta")` | name, rating, months, comment |
| one stop | `(trip, variant, "stop:<id>")` | two devices editing *different* stops of one trip both keep their change |
| stop order | `(trip, variant, "order")` | drag a stop to position 1 |
| one leg | `(trip, variant, "leg:<n>")` | change the second leg to a train |
| one open tab | `("tab", destination)` | a tab opened on the phone appears on the PC after sync (and vice versa) |

Entries are applied in timestamp order, so a row creation always precedes the
cell writes that target it. A whole-variant key `(trip, variant)` from a journal
written before 2026-10-04 is still replayable. Open tabs are the exception to
the conflict rule: an open against a close of the same tab resolves to the
newest change without asking, so tabs never appear in the conflict list.

`runtime_paths.py` decides where runtime state is written:

| Order | Location | When |
|---|---|---|
| 1 | `$TRAVEL_PLANNER_DATA_DIR` | always wins, if set |
| 2 | the repository directory | local development (the existing git-ignored files) |
| 3 | `%LOCALAPPDATA%\travel-planner` / `~/.local/share/travel-planner` | the repository is read-only (Streamlit Cloud mounts it read-only) |

Everything the app writes at runtime goes there: `trips.json` + its backups,
`itinerary_cache/ui_state.json`, `open_destinations.json`, `sync_journals/`,
the gallery/flight/AQI caches — and, **on Cloud only**, an editable copy of
`Destinations-cloud.xlsx` seeded from the committed file.

The sidebar shows the resolved path; if it is not writable the app says so
instead of silently forgetting your changes.

## The data layer: Turso first, workbook fallback

Destinations and open tabs live in the **Turso database
`travel-tz123`** (migrated 2026-10-08; `NATIVE_HTML_PLAN.md`
Phase 1). Every page reads through `repository.py`:

* **Reads** prefer Turso (`TRAVEL_PLANNER_TURSO_URL` +
  `TRAVEL_PLANNER_TURSO_TOKEN`, read from the environment or
  `.streamlit/secrets.toml`) and fall back to the workbook when
  Turso is unreachable or unconfigured — an outage degrades to
  the old behaviour instead of an empty catalogue.
* **Writes** go to Turso as a read-modify-write and return
  `True`/`False`; a failed write is *surfaced*, never silently
  redirected to the workbook (that would diverge from Turso).
* Each destination row keeps a typed core (the fields the app
  filters/sorts on) plus a lossless JSON tail with all 145
  workbook columns in order — duplicate column names included.
* `python migrate_to_turso.py` (re-runnable, idempotent upserts)
  copies the workbook + `trips.json` + open tabs into Turso;
  `storage_turso.export_workbook()` writes the data back to an
  openable `.xlsx`, so the Excel artifact survives.

Trips run on Turso at runtime too (the 2026-10-10 cutover:
`itinerary/storage.py` loads Turso-first and falls back to
`trips.json`), so the database now serves every surface — the
Streamlit app, the API, and the native app. The `sync/` stack and
`refresh_cloud_workbook.py` stay until the legacy version is retired:
they are the workbook branch's path to the phone.

## The native app (`mobile/`)

The Flutter app (desktop + Android) talks to Turso directly over the
SQL-over-HTTP pipeline API — no FastAPI backend in between, and the
read-write token ships in the app bundle (the user's decision,
2026-10-08, for a personal app). It is the Dart mirror of the same
contracts the Python side keeps: a failed read returns an empty list
*with* problems, a failed write returns `false`, and every field edit
is a read-modify-write that updates the typed core **and** the
lossless `data` tail.

```powershell
cd mobile
& "C:\src\flutter\bin\flutter.bat" pub get
& "C:\src\flutter\bin\flutter.bat" analyze
& "C:\src\flutter\bin\flutter.bat" test
```

Credentials come from `mobile/assets/turso_config.json`
(git-ignored; template `turso_config.example.json`, values from
`.streamlit/secrets.toml`). Without the file the app runs
unconfigured and explains itself instead of crashing.

## Tests, lint, build

```powershell
python -m pip install -r requirements.txt -r requirements-dev.txt
python -m pytest                  # full suite (511 tests, ~3 min; the 144-page render dominates)
python tests/run_all.py           # same, with a fallback for no-pytest setups
python tests/run_all.py --no-pytest   # only the dependency-free script runners
python -m ruff check .            # lint
python -m compileall -q .         # byte-compile (the project's "build")
```

`pip install -e .` is deliberately a no-op (it installs no modules) — this is
an application you run from a checkout, not a library.

`Destinations-local.xlsx` is git-ignored, so a fresh clone starts from the
committed `Destinations-cloud.xlsx`; the app and the test suite both work with
either.

CI runs on every push to `main`: **Actions → CI** on GitHub shows the result.
Both jobs (Linux and Windows) run byte-compile → ruff → pytest, plus the
dependency-free test path. Windows is included because two of the trickier bugs
(atomic replace, file locking) are platform specific. You do not need to do
anything for it — if it is red, the push broke something.

The suite never touches the live workbook, `trips.json` or the journals:
`tests/conftest.py` redirects all runtime state into a temporary directory, and
two tests assert that the real files are unchanged afterwards.

Highlights:

| File | Covers |
|---|---|
| `tests/test_page_smoke.py` | renders **all 144 destination pages** plus app.py in local and Cloud mode (this is the test that would have caught the `NameError` that broke 78 % of the catalogue) |
| `tests/test_trips_safety.py` | two-tab / two-device data loss, atomic write, retry, backups |
| `tests/test_writers.py` | every workbook writer's contract (success / nothing-written) |
| `tests/test_filters.py` | "a filter may only hide rows whose field is populated" |
| `tests/test_sync_integrity.py` | journal ownership, lossless transport, one workbook write per sync |
| `tests/test_bulk_sync.py` | the climate/AQI/food producers journal their writes; skipped changes are reported |
| `tests/test_caches_and_matching.py` | geocode/AQI/IQAir cache staleness, country matching, column matching, cache keys |
| `tests/test_sync_per_stop.py` | new-destination rows, per-stop trip keys, parallel edits on two devices |
| `tests/test_tabs_sync.py` | open-tab journaling, newest-wins, two-device convergence |
| `tests/test_weekend_match.py` | the weekend finder's time windows, pairing, city grouping |
| `tests/test_timetable.py` | CSV parsing, caching, and which flight sources are usable |
| `tests/test_airport_city.py` | airport → city → country, multi-airport cities merged |
| `tests/test_airline_benefits.py` | the per-airline benefit flag and name normalisation |
| `tests/test_benefits_turso.py` | the Turso database reader: value semantics, schema drift, every failure path |
| `tests/test_rainy_days.py` | one rainy-day definition for all writers; the provenance report |

## Architecture in one screen

```
app.py                 navigation + custom sidebar (open destination tabs, trips,
                       workbook download, sync button)
pages/world_map.py     choropleth + filters + "cities in <country>" cards
pages/overview.py      filterable, country-grouped catalogue
pages/destination_detail.py   one page per city (banner, metrics, climate
                       dashboard, galleries, AI populate, flight routes)
pages/itinerary.py     trips → variants → stops → legs + route map
pages/weekend_finder.py  Fri→Mon weekend possibilities from FRA (CSV in,
                       all matching in weekend_match.py)
weekend_match.py       pure weekend matcher: flights + windows -> cities
timetable.py           flight data providers + CSV parsing + caching
airport_city.py        airport -> city -> country, metro merge (data/airports.csv)
airline_benefits.py    airline benefits: resolver, name normalisation, workbook mirror
benefits_turso.py      the benefits database reader (Turso over HTTP, local .db offline)
filters.py             shared, tested filter primitives (blank values never filter out)
rainy_days.py          the one definition of a rainy day (>= 1 mm/day)
data_utils.py          workbook I/O: atomic saves, stale-write detection, writers
repository.py          the one data-access point: Turso first, workbook fallback
storage_turso.py       destinations / trips / open tabs on the Turso database
turso_db.py            Turso SQL-over-HTTP client + the app schema
migrate_to_turso.py    one-shot workbook + trips.json -> Turso migration
itinerary/             pure, Streamlit-free trip logic + persistence (tests/geo/map)
sync/                  journal → merge → GitHub transport → sidebar UI
runtime_paths.py       where runtime state is written
```

### Data-safety rules (do not break these)

1. **Never call `workbook.save(...)` directly.** Use
   `data_utils.load_workbook_for_update()` + `save_workbook_atomic()`; they
   refuse a stale write and snapshot the outgoing file.
2. **Writers return `True`/`False`.** `False` means "nothing was written" —
   surface it, never treat it as success.
3. **Never save a stale `trips.json`.** Load → mutate → save through
   `itinerary/storage.py`; it raises `TripsFileChanged` when another session
   saved first. The page catches it and offers *Reload latest data*.
4. **Journal files belong to the device that writes them**, and the transport
   unions the remote copy instead of overwriting it.
5. **A filter may only remove rows whose field is populated** — use the helpers
   in `filters.py`.

## Which airlines have benefits

The weekend finder needs to know that, and the answers live in a **Turso
database** you maintain (changed 2026-10-07 — this used to be an Excel file):

```
table:  airlines(iata, name, discount_eligible, business_class,
                  confirmed_booking, comments, updated_at)
remote: https://flightconnections-tz123.aws-eu-north-1.turso.io
```

`benefits_turso.py` reads it over Turso's SQL-over-HTTP pipeline API and reports;
so does the app, on every run, cached one hour. `python benefits_turso.py` prints
the current state. An airline counts as having benefits when **any** of
`discount_eligible` / `business_class` / `confirmed_booking` is `yes`;
`unknown` and `no` both mean no — an unverified airline must never silently widen
the results. Airlines are matched by IATA code first, then by name.

| Variable | Purpose |
|---|---|
| `TURSO_AUTH_TOKEN` | **required** — read-only bearer token; set in `.streamlit/secrets.toml`, live source verified 2026-10-09 (597 rows, 7 qualifying) |
| `TURSO_DATABASE_URL` | override the host (defaults to the one above) |
| `TURSO_AIRLINE_TABLE` | override the table name (default `airlines`) |
| `TRAVEL_PLANNER_FLIGHTROUTES_DB` | local `flightroutes.db`, used offline if the remote is unavailable |

**Fallbacks, in order:** Turso → the workbook's `Airline Benefits` sheet (so
Cloud still works) → the old `airlines_benefits.xlsx` (read *only* when Turso is
not configured at all) → a built-in seed list. Every failure falls through rather
than raising, and an **empty** read is treated as a failure — an empty flag map
would remove every destination from the finder with no visible cause. Details and
the access contract: `TURSO_PLAN.md`.

## Known limitations

* `Destinations-cloud.xlsx` is committed, so Cloud edits are lost on redeploy
  unless they have been synced or downloaded first.
* The weekend trip finder fetches flights from **Fraport's own JSON endpoint**,
  which was verified working on 2026-10-07 and covers any date. The
  `FraportBoardProvider` (in `timetable.py`) is implemented and is the live
  default; you can still upload or paste a CSV as a fallback/escape hatch.
  Recorded board fixtures cover the test suite (no network per run). An earlier
  note in this file claimed the endpoint did not exist — that was wrong; see
  `WEEKEND_FINDER_PLAN.md` §"Fraport endpoint" for the evidence and the request
  shape.
* Seven destinations still hold `{Mon} Rainy Days` values transcribed from
  published climate normals, which count trace precipitation instead of the
  project's ≥1 mm definition. They are not re-fetched on purpose (it would cost
  API calls). Run
  `python write_climate_data.py --list-legacy-rainy-days` to see exactly which
  rows, at any time, without an API call.
