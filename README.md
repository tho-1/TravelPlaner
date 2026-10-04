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
python -m pytest                  # full suite (151+ tests, ~30 s)
python tests/run_all.py           # same, with a fallback for no-pytest setups
python tests/run_all.py --no-pytest   # only the dependency-free script runners
python -m ruff check .            # lint
python -m compileall -q .         # byte-compile (the project's "build")
```

CI (`.github/workflows/ci.yml`) runs compileall → ruff → pytest on Linux **and**
Windows on every push, because two of the trickier bugs (atomic replace, file
locking) are platform specific.

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

* A trip conflict is resolved per *variant*: "keep cloud" replaces the whole
  variant, including stops the other device added. The conflict panel states
  this. Per-stop journal keys are the planned fix.
* A destination that exists only on the other device cannot receive cell-level
  changes yet — the sync reports it under "changes that could not be applied"
  instead of dropping it silently. Add the destination (or refresh the
  workbook) and sync again.
* `Destinations-cloud.xlsx` is committed, so Cloud edits are lost on redeploy
  unless they have been synced or downloaded first.
* `{Mon} Rainy Days` is still filled by two scripts with slightly different
  definitions (0.1 mm vs WMO ≥1 mm), so a few rows may mix both.
