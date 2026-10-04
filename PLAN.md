# Travel Planner — Plan & Handoff

Last updated: 2026-10-03 (after the full code review + the first fix batch).

**Read `README.md` first** — it documents where runtime data is written, the
test/lint commands, and the five data-safety rules that must not be broken.
This file is the history and the open-issues list.

This document records what is finished, what is still open, the decisions already made,
and the verified commands for testing. It is the authoritative handoff for the next session.

---

## 0. Status after the review + fix batches — supersedes §1–§4 below

A full review found 38 issues (5 Critical, 10 High, 14 Medium, 9 Low). Two
implementation batches are done and verified by **188 automated tests**:

* **2026-10-03 batch 1** (commits `0b2c332`, `2010541`, `d95a073`, `9dc90a4`)
* **2026-10-04 batch 2** (this section)

| Area | Fixed |
|---|---|
| Detail page crash | `img_base64`/`is_visited` were defined inside `if image_path:` but used unconditionally — **112 of 144 destination pages** raised `NameError`. Flags hoisted, header block de-indented, banner-less layout now reachable |
| Silent itinerary data loss | two tabs saving `trips.json` → last writer wins. Signature-based stale guard (`storage.TripsFileChanged` + *Reload latest data*), unique temp names, retry on Windows locks, no silent `OSError` |
| Cloud writability | runtime paths moved behind `runtime_paths.py` (env var → repo → per-user dir); Cloud edits a writable copy of the workbook; cache `mkdir`s degrade instead of crashing |
| Filters hiding rows | `filters.py` (new, tested): a filter may only remove rows whose field is populated. Mumbai/Delhi safety filled with **7.0** (matches Kerala/Chennai/Bangalore) |
| Writers doing nothing | every writer returns `True`/`False`; the UI reports "nothing was written"; writers and readers share one alias vocabulary |
| Numeric crashes | one `filters.coerce_number` for climate, AQI, ratings, population, cost — `22 °C` or `8/10` no longer blanks a page |
| Feedback | `st.success` + `st.rerun()` pairs replaced by `st.toast`; deleting a comment now asks first |
| Sync integrity | journal files belong to the writing device; the transport unions the remote journal; one workbook write per sync; conflict radios keyed by sync key |
| **Bulk data now syncs** | the `populate_*` scripts and the AI populate journal every cell they write (`data_utils.journal_cell_changes`), so climate/AQI/cost/food reach the other device. A destination that does not exist locally is reported as *skipped* instead of vanishing |
| **Broken scripts repaired** | `populate_new_destinations.py` and `write_climate_data.py` wrote to `wb.active`, which is the **Airlines** sheet — they now target the destinations sheet explicitly and raise a clear error instead of crashing. `ratings.csv` is merged, not overwritten |
| **No more fake success** | a failed Open-Meteo fetch no longer overwrites the `AQI Source` provenance; the runners no longer print ✓ for a write that never happened. A malformed provenance string (`…))`) is fixed |
| Sample trip | arrived in Beijing on the day it left Frankfurt and typed Shanghai→Frankfurt as a *train*; both variants are now physically plausible, and a new warning flags any leg that arrives before it departs |
| Transpacific map | longitudes are unwrapped, so Tokyo→Los Angeles renders on a 114° axis instead of a 398° one; the arrowhead no longer drags a stray line back to the path end |
| Caches | geocode no longer caches empty results (and treats HTTP 200 + `{"error": true}` as a failure); the AQI cache is invalidated when a coordinate changes and a failed ground retry no longer resets its age; a truncated IQAir scrape is no longer stored as `complete` |
| Matching | IQAir country matching requires equal token sets (Guinea ≠ Equatorial Guinea); `find_column` no longer binds a short column name inside a longer alias; flight-route cache keys keep the province qualifier so two same-named cities stop sharing data |
| Tooling | `pyproject.toml` (deps + pytest + ruff), `tests/conftest.py` sandbox, 128 new tests, `tests/run_all.py`, `.github/workflows/ci.yml` (Linux + Windows), `requirements.txt` floors corrected |
| Dead code | deleted `populate_destination_details.py` (writes removed columns, non-atomic save), `check_rows.py` and `inspect_workbook.py` (scratch scripts with paths from another machine) |

**Still open:**

1. **F14 (partly)** Trip conflicts are resolved per variant: "keep cloud"
   replaces the whole variant, including stops the other device added. A
   per-stop union was implemented and **reverted** — it cannot express a
   deletion, so removed stops came back. The fix is per-stop journal keys in
   `storage._collect_trips_diffs`; the conflict panel states the consequence.
2. **F18 (partly)** The sidebar still re-reads `trips.json` on every rerun of
   every page (the backup-snapshot part is cached now).
3. **F37** Two writers still define a "rainy day" differently (0.1 mm in
   `write_climate_data.py`, WMO ≥1 mm in `aqi_api.py`), so the same column can
   mix both definitions. Pick one and regenerate the affected rows.
4. **F33** `open_destinations.json` is per device; Cloud loses the tab layout on
   redeploy. Documented instead of synced.
5. **Q1 (open)** Whether the Cloud deployment can persist anything is still
   unverified by the user. The code no longer depends on the answer, and the
   sidebar names the directory in use.

Validation: `ruff check .` clean, `compileall` clean, **188 pytest tests pass**
(~30 s), and `python tests/run_all.py --no-pytest` passes.

### Decisions added on 2026-10-03

- Sync granularity: **per cell for the workbook, per trip variant for itineraries**
  (whole-file transport was considered and rejected).
- **"Only show unvisited" stays ON by default**, but no filter ever hides a row
  whose field is blank.
- The DDG/Unsplash gallery is **essential** and stays; the banner falls back to a
  plain title when a destination has no photo.

---

## 1. Where things stood before the 2026-10-03 batch (historical)

### Committed and pushed (origin/main = `cff9c30`)

| Commit | What it delivered |
|---|---|
| `2e1c641` | Unsplash galleries for Alexandria, Bangalore, Muscat, Sri Lanka |
| `49b14a8` | Committed Cloud workbook `Destinations-cloud.xlsx`, gitignore rules, `ddgs` dependency |
| `76137c2` | Pages wired to the local/cloud workbook split; Itineraries sidebar; workbook download button |
| `81f0c20` | AQI / IQAir / DDG tooling + `environment.py` split |
| `96cc83e` | Itinerary Planner package + `pages/itinerary.py` + tests, with safety fixes |
| `91048e4` | gitignore DDG gallery cache (81 MB, refetchable) |
| `b15e553` | **Hotfix:** Streamlit Cloud detection (app failed to start in Cloud mode) |
| `cff9c30` | Cloud workbook synced from the local master |

### Uncommitted — Phase 1, code complete and verified, **not yet committed**

Twelve modified files plus one new test file. Working tree:

```
 M .gitignore  aqi_api.py  data_utils.py  deepseek_populator.py  iqair_ranking.py
 M pages/destination_detail.py  pages/overview.py  pages/world_map.py
 M populate_all_climate.py  populate_malaria_risk.py
 M populate_new_destinations.py  write_climate_data.py
?? tests/test_data_utils.py
?? pages/info.py          <- dead page, intentionally NOT committed (Phase 3 deletes it)
```

Phase 1 delivered **safe, atomic workbook persistence**:

- `data_utils.load_workbook_for_update()` — loads for mutation and records the source
  mtime; raises `WorkbookLockedError` on lock.
- `data_utils.save_workbook_atomic()` — stale-write check before **and** after
  serialization, snapshot of the outgoing file, then `os.replace` (atomic).
- `data_utils.WorkbookChangedError` — subclass of `WorkbookLockedError` for
  "file changed on disk" (stale edit) cases.
- Rolling snapshots in `workbook_backups/` (newest 12; ignored by git).
- All 9 interactive writers in `data_utils.py`, plus the AI/AQI/IQAir/malaria/climate
  scripts, now route through these helpers — **no direct `wb.save(...)` remains**.
- Page-level lock errors show the *real* error text (previously a hard-coded
  "Destinations.xlsx" message, wrong for local/cloud files), and ❤️ / ❔ / visited /
  Prio-Save now catch lock errors and offer **Retry** instead of raising tracebacks.
- `typing.Union` import fixed; `wb.close()` now also happens on failed saves.

**Verification already run and passing:** 39 tests (5 data-utils + 3 environment +
31 itinerary), `compileall` clean, writer-module imports clean, local app smoke-tested
in Local Mode with no exceptions.

**Next action: commit and push Phase 1** (suggested as two commits: persistence
helpers/tests, then the page-level error handling).

### Committed decisions that shaped the work

- Cloud is for phone access on the go; local PC is the primary workstation. **Edits
  happen on both and must merge, not overwrite.**
- Sync approach chosen: **Option A — change journals + GitHub as transport**
  (details in Phase 2).
- Duplicate trip names: dropdown is id-safe. Two-step confirms exist for trip, variant
  and stop deletion. `ddgs` is a declared dependency.
- Dead Fahrenheit toggle: **remove entirely** (Celsius only).

---

## 2. Phase 1 — finish up (immediate)

1. `git add` the twelve modified files and `tests/test_data_utils.py` (never `pages/info.py`).
2. Commit in two logical chunks: persistence helpers + tests; then UI retry handling.
3. Push to `origin/main`; confirm the Cloud app still boots and stays in **Cloud Mode**.
4. Optional later: expose `workbook_backups/` contents in the UI (the download button
   covers the main need today).

---

## 3. Phase 2 — sync between local and Cloud (the main open feature)

**Goal:** edits made on the phone and on the PC merge deterministically instead of
overwriting each other.

Design (agreed):

1. `sync/journal.py` — append-only JSONL per device/day recording every successful
   write: key `(destination, column)` for the workbook, `(trip_id, variant_id)` for
   itineraries, with value + UTC timestamp + device id. Journals hang off the Phase 1
   write choke point and `itinerary/storage.save_trips`.
2. `sync/transport_github.py` — GitHub Contents API against a `data-sync` branch using
   a fine-grained PAT (Contents read/write on `tho-1/TravelPlaner`) stored in
   Streamlit secrets as `GITHUB_TOKEN` and in a gitignored local secrets file.
3. `sync/merge.py` — pull remote journal, apply newer-wins per key, apply local,
   push combined. Conflicts (same key changed on both devices since last sync with
   different values) go to `conflicts.json`.
4. UI — sidebar **⟳ Sync** button with last-sync caption, plus a conflicts review list
   (per-key choice and "keep all local" / "keep all cloud" bulk actions).
   **Never silently resolve a conflict.**
5. Safety — snapshot both stores before applying anything (reuse the Phase 1 and
   `itinerary/storage.py` backup patterns), and keep a dry-run mode.
6. Baseline — journals only record changes after the baseline; the current local master
   and `trips.json` are the starting point.

Tests to add: journal round-trip, two-device merge including a conflict and its
resolution, idempotent re-sync, offline accumulation, and "snapshot exists before apply".

**Known data caveat to carry forward:** when the Cloud workbook was rescued, the
downloaded file matched the seeded baseline exactly (all nine sheets), so any
Cloud-side edits made before the redeploy were not recovered. If the user later recalls
specific Cloud changes, check external backups before overwriting anything.

---

## 4. Phase 3 — remaining review fixes (prioritised)

Ordered roughly by risk. IDs refer to the full review report.

1. **M1** Stop editor coerces unset `nights` to `0` on every save; that silently
   disables the date-span fallback in `totals()` and cannot be undone from the UI.
2. **M10** Guard numeric parsing in the detail page (`food_spiciness`, IQAir rank) so a
   stray string like `"8/10"` cannot crash the whole page.
3. **M8** Separate retry keys for the add-destination dialog (Overview vs World Map
   currently share one key, so an error on one page shows on the other).
4. **M9** Map city cards navigate via raw `<a href>` (full reload, lost map state) and a
   fallback slug can 404 — switch to `st.switch_page` with a safe slug lookup.
5. **M12** Warn when the same city is added twice.
6. **M11** Delete dead `pages/info.py` (unregistered and documents removed UI).
7. **L1** Migrate the 21 `use_container_width=True` call sites to `width="stretch"`
   (19 in `pages/itinerary.py`, 2 in `pages/destination_detail.py`) — the deprecation
   warning floods the server log on every rerun.
8. **L2** Dead code: remove the Fahrenheit toggle (`is_f`, `_to_unit`) as decided, plus
   unused `flight_col`/`cost_col`/`nights_known`, the unreachable `months > 12` check,
   the unused `_add_stop(arrival=...)` parameter, `geocode.first_match`; consolidate the
   five month-name tables, three research-truthiness implementations and two slugify
   helpers; merge the duplicated add-destination dialog into one shared module.
9. **L3** Hygiene: archive `Destinations.before-*.xlsx` into an ignored `archive/` folder.
10. **L4** UX batch: "Only show unvisited" default hides visited destinations; the
    "Comment saved." toast is destroyed by the following rerun; nothing opens after a
    successful add; origin stops can hold invisible nights; Route summary does not
    refresh after "Save stop"; empty "Cities in X" panel when filters exclude the
    selected country; the add-dialog warning contradicts the AI-populate option.
11. **L5** Tests: itinerary ops edge cases (`duplicate_trip`, blank rename, invalid leg
    mode, append/insert-into-empty/remove-to-zero, moving an origin stop, warnings for
    garbage dates and negative nights, single-day totals, dates only on later stops,
    `suggested_months(df=None)`, map with 0/1 stops or all-gateway, corrupt-snapshot
    restore, prune ordering, stale `ui_state` id).

---

## 5. Environment facts and gotchas

- **Cloud URL:** `https://travelplanerusethisrepositorywhendeployingonappcommunitycloud.streamlit.app/`
  (owner `tho-1`; the shorter `travelplaner.streamlit.app` belongs to someone else).
- **Workbook split:** `environment.py` selects `Destinations-local.xlsx` locally and
  `Destinations-cloud.xlsx` on Cloud. Cloud is detected via the `/mount/src/...` mount
  path, the gating env var, or headless + `appuser` home.
- **Cloud storage is ephemeral** — runtime workbook edits vanish on redeploy. This is
  exactly what Phase 2 fixes. The sidebar download button is the current safety net.
- **Run the app:**
  `& "C:/Users/Thors/AppData/Local/Python/pythoncore-3.14-64/python.exe" -m streamlit run app.py --server.port 8507 --server.headless true`
  (PowerShell needs `&` before the quoted path; the `streamlit` CLI is not on PATH.)
- **Tests / lint / build (current — see README.md):**
  `python -m pytest` (152 tests), `python -m ruff check .`,
  `python -m compileall -q .`; or `python tests/run_all.py` for the
  dependency-free path (`python tests/run_all.py --no-pytest`).
  CI: `.github/workflows/ci.yml` (Linux + Windows).
- **Backups:** `trips_backups/` (12 newest itineraries) and `workbook_backups/`
  (12 newest workbooks), both gitignored. The pre-merge Cloud seed copy is at
  `%TEMP%\Destinations-cloud.seed-before-local-merge.xlsx`.
- **Streamlit widget gotchas learned the hard way:** a widget key reused across a
  changing entity list silently re-sends a stale value (use per-entity keys); the file
  watcher cannot be trusted after edits — restart the server; a page reload creates a
  new session, so session-only state resets.
- Two browser tabs share one `trips.json`. **Fixed 2026-10-03:** a stale save is
  refused with *Reload latest data* (`storage.TripsFileChanged`); the sync journal
  cannot recover an overwritten in-memory edit, so the guard is the protection.
- **Cloud filesystem:** unknown whether `/mount/src` is writable on the deployed
  app. The code no longer depends on the answer (`runtime_paths.py`), but the
  user's first Cloud check should be: open the app, edit a comment, reload — if
  it survived, the data dir was writable; the sidebar caption now shows it.

---

## 6. Suggested first moves for the next session

1. Push the 2026-10-03 batch (four commits, see §0) and verify the Cloud app
   still boots in Cloud Mode with no traceback.
2. Verify on the real Cloud deployment that (a) a comment edit survives a reload
   and (b) the sidebar shows a writable data dir. Then answer Q5: which workbook
   is the source of truth?
3. Next implementation batch, in order: **F13** (journal the `populate_*` scripts
   so the phone finally sees climate/AQI/cost data), **F15** (repair
   `populate_new_destinations.py` + delete the obsolete script), **F31/F17**
   (sample trip + antimeridian), **F29/F30** (cache correctness), **F24** (key
   collisions).
4. If per-stop trip merging is wanted (F14), change
   `storage._collect_trips_diffs` to emit one entry per stop first — the merge
   side is already isolated in `sync/merge._merge_variant`.
