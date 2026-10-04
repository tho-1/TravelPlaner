# Travel Planner

A Streamlit app for a personal travel catalogue: browse destinations on a world
map, read a detail page per city, and plan multi-stop trips with variants,
dates, transport legs and a route map. Edits made on the PC and on the phone
(Streamlit Cloud) are merged through change journals instead of overwriting
each other.

## Running it

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

Entries are applied in timestamp order, so a row creation always precedes the
cell writes that target it. A whole-variant key `(trip, variant)` from a journal
written before 2026-10-04 is still replayable.

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

## Tests, lint, build

```powershell
python -m pip install -r requirements.txt -r requirements-dev.txt
python -m pytest                  # full suite (221 tests, ~35 s)
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
filters.py             shared, tested filter primitives (blank values never filter out)
rainy_days.py          the one definition of a rainy day (>= 1 mm/day)
data_utils.py          workbook I/O: atomic saves, stale-write detection, writers
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

## Known limitations

* `Destinations-cloud.xlsx` is committed, so Cloud edits are lost on redeploy
  unless they have been synced or downloaded first.
* Seven destinations still hold `{Mon} Rainy Days` values transcribed from
  published climate normals, which count trace precipitation instead of the
  project's ≥1 mm definition. They are not re-fetched on purpose (it would cost
  API calls). Run
  `python write_climate_data.py --list-legacy-rainy-days` to see exactly which
  rows, at any time, without an API call.
