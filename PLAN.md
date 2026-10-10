# Travel Planner — Plan & Handoff

Last updated: 2026-10-10.

**Read `AGENTS.md` first** (orientation, invariants, open items), then
`README.md` (how to run it, where runtime data is written, the data-safety
rules). This file is the **history**: every review finding, every fix, every
decision, with dates and commit hashes.

Sections §1–§4 below are historical (they describe the state *before* the
2026-10-03 batches) and are superseded by §0. Where they disagree with §0 or
`AGENTS.md`, believe those.

---

## Status 2026-10-10 — the Streamlit version is legacy

Decision (user, 2026-10-10): the Streamlit app in this repository is
**legacy**. It is archived as a **source of knowledge** (the reference
implementation of the feature set and its data-safety rules) and as a
**potential fall-back** in case the native development does not go as
planned. The **target architecture moves away from Streamlit** — a
native desktop + Android app on the Turso data layer, per
`NATIVE_HTML_PLAN.md` (decision in §5–§6 there; Phase 1, the Turso
data layer, is already done and verified).

Post-plan audit (same day): the only commit after `NATIVE_HTML_PLAN.md`
was created (`e3c4191`, 2026-10-09) is `a980690` "Map Fraport rail
station codes to city names" — a weekend-finder improvement
(`airport_city.py`, +21 lines) that the plan explicitly keeps. Nothing
since the plan contradicts it or changes its assumptions; the working
tree was clean apart from the untracked `.kilo/` tooling directory.

Documentation updated to match: `AGENTS.md` (the entry point now states the
legacy status and the target architecture), `README.md` (intro and
"Running it" marked legacy), `NATIVE_HTML_PLAN.md` (status block: decided,
Phase 1 done, Phases 2–6 not started).

---

## Native rebuild 2026-10-10 — Phases 2 to 5 in flight

Work continues on `NATIVE_HTML_PLAN.md` §7 (the user asked for it
autonomously; the full record lives in `HANDOFF.md` while the work is
in flight).

**Phase 2 — backend API** (`2a066fb`). `api.py`: a FastAPI app over the
repository layer — destinations (list with the shared filters, detail with
the lossless column tail, PATCH of the editable flags), trips CRUD, open
tabs, the weekend finder (live Fraport), provider status, the workbook
export, and the legacy journal-sync trigger. It is the first Streamlit-free
entry point: it sets `TRAVEL_PLANNER_API` before importing the repository,
which turns the repository's `st.cache_data` into a passthrough so every
request reads fresh data. The workbook's NaN cells needed
`_jsonable()` — JSON refuses them, the Streamlit UI hid the problem.
`tests/test_api.py` (23 tests).

**Phase 3 — native HTML frontend** (`2a066fb`). `web/`: hash-routed
catalogue / destination / trips / weekend-finder views in vanilla JS over
the API, a PWA manifest and a service worker that caches the shell but
never an API response. Filters are applied server-side, so the filter
semantics stay in `filters.py`.

**Benefits credentials bug** (`2a066fb`). `benefits_turso` read the token
from `os.environ` only, while `turso_db` and ` GitHub transport` fall back to
`.streamlit/secrets.toml`. Any non-Streamlit process therefore read the seed
list instead of the database, and the weekend finder emptied itself
silently: 260 LH flights rejected, 0 cities. Fixed with the same env→file
fallback, an autouse conftest fixture that keeps the suite hermetic on a
machine with the real secrets file, and a test.

**Phase 4 — trips runtime cutover** (`7fadbbc`). `itinerary/storage.py` now
loads from Turso and falls back to `trips.json`; `save_trips` upserts every
trip and deletes the ones the structure no longer lists, returning True/False
(the empty flag map stays a failure, never a silent success). The ladder
lives in the storage module — not in `repository.py` — so the legacy
Streamlit app and the API share one data path and the fallback story holds.
Verified live: an API create+delete round-tripped through Turso while
`trips.json` was never touched.

**Phase 5 — Flutter app** (in progress). `mobile/`: the Turso pipeline
client, the destination and trip models, and the UI shell are written;
`flutter analyze` / `flutter test` have not been run yet. See `HANDOFF.md`.

**Phase 6 is deliberately deferred**: deleting the Streamlit pages, the
workbook writers and the sync stack would delete the fallback the user
decided to keep (2026-10-10).

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
| **Batch 3** (2026-10-04, `ec4d0a2` + this commit) | CI actually installs its dependencies; new destinations sync; trip sync is per stop; one rainy-day definition; transient Windows locks are retried |
| **Batch 4** (2026-10-05, `f9ab036`) | the suite and a fresh clone work without the git-ignored local workbook — **CI is green** |

### Batch 3 (2026-10-04)

| Area | Fixed |
|---|---|
| **CI never installed anything** | all three workflow runs died in ~18 s: `pip install -e ".[dev]"` trips setuptools' flat-layout package discovery on this app's four sibling top-level packages. `pyproject.toml` is now tool config + metadata that installs nothing; deps live in `requirements.txt` / new `requirements-dev.txt`. `pip install -e .` is now a harmless no-op |
| **A destination added on the PC never reached the phone** | new journal entry `(destination, "#row")` (`journal.record_destination_row`, written *before* the row's cells so timestamp order creates the row first). `merge._create_destination_row` appends the row; an existing row is left untouched, so it can never clobber the other device's newer edits |
| **Trip sync is per stop** (F14) | `storage._collect_trips_diffs` now emits one entry per part — `meta`, `order`, `stop:<id>`, `leg:<n>` — instead of one whole-variant entry. A phone edit to stop A and a PC edit to stop B both survive. Deletions are expressible (`op="delete"` per part). Legacy 2-element keys stay replayable |
| **One rainy-day definition** (F37) | `rainy_days.py` holds `RAINY_DAY_THRESHOLD_MM = 1.0` (WMO); `aqi_api.py` imports it, so no writer hardcodes a threshold. The 7 rows still holding curated (trace-precipitation) values are **not** regenerated, by decision; `python write_climate_data.py --list-legacy-rainy-days` names them without an API call |
| **Regression from my own cleanup** | deleting `populate_destination_details.py` in `89b777c` left `write_climate_data.preserved_destination_climate` importing a module that no longer existed, so `python write_climate_data.py` raised `ModuleNotFoundError`. Its `CLIMATE_DATA` table is restored in-module as `CURATED_CLIMATE` |
| **Flaky CI / misleading error** | a transient Windows `PermissionError` (AV or the indexer holding the just-written temp file) surfaced as "open it in Excel and press Retry". `data_utils.retry_while_locked` retries the copy and the replace (~0.75 s total) and a permanently locked file still fails fast. A real flake, not a logic bug |

Measured with the new command, no API calls: 7 curated rows, 137 canonical,
0 partially-overwritten rows, 0 rows without rainy-day data.

### Batch 4 (2026-10-05) — CI is green

Once the install step was fixed, pytest ran for the first time in CI and failed
on both runners: `FileNotFoundError: Destinations-local.xlsx`.
`Destinations-local.xlsx` is **git-ignored**, so a clean checkout only has the
committed `Destinations-cloud.xlsx`, and `get_workbook_path()` asked for the
local file unconditionally.

| Area | Fixed |
|---|---|
| A fresh clone could not start | `get_workbook_path()` falls back to the committed cloud seed in local mode. With neither file present it still returns the local name, so the error message can name the missing file. Three tests, incl. the "neither exists" case |
| Test hygiene gap | `conftest` now redirects `data_utils.DATA_PATH` / `environment.WORKBOOK_PATH` (the default argument of most writers, imported by value in `app.py`) to a disposable copy, so no test can write to the real or the committed workbook. Verified: after a full run in a clean clone, `git status` shows no `.xlsx` change |
| F18 closed by measurement | `load_trips()` costs **0.29 ms** on the 6.8 KB `trips.json` — ~3 ms per rerun even at ten calls. The remaining "sidebar re-reads trips.json" item is not worth a cache, and a `(mtime, size)`-keyed cache would reintroduce exactly the stale-read data loss that `TripsFileChanged` exists to prevent. **Closed, no code** |

Verified: `ruff check .` clean, `compileall` clean, **221 pytest tests pass**,
`tests/run_all.py --no-pytest` passes — and the same four commands pass in a
fresh `git clone`, which is what CI runs. GitHub Actions run #6: **success**
on Linux and Windows.

**Still open:** see the consolidated list in `AGENTS.md` §6. As of this batch it
was the Cloud-persistence check (Q1) and the 7 curated rainy-day rows; later
batches added the weekend finder's blocked flight scraping and the partly filled
airline-benefits file.

### Batch 5 (2026-10-05) — open tabs sync (F33 closed)

| Area | Done |
|---|---|
| Tabs sync | each tab is its own journal key `("tabs", "tab", destination)` — opened journals `upsert`, closed journals `delete`. Concurrent opens on both devices are different keys, so both survive with no conflict; an open against a close of the same tab resolves to the newest change, so tabs never appear in the conflict list |
| Backfill | the first journalled save asserts the whole tab list (pre-existing tabs reach the other device); afterwards only deltas travel, so a tab closed on one device is not resurrected by the other device's next save |
| Session | after a sync the running app adopts the synced tab list into `st.session_state` before rerunning, instead of showing the pre-sync layout until reload |
| Suite hygiene (real bug found by this work) | the page smoke tests render through `save_open_destinations` without the `sandbox` fixture, and one of them mocks `Path.exists` globally — a full run overwrote the real `open_destinations.json` with test tabs and journalled ~10k test entries into the real `sync_journals/` (which would then have synced to the phone). The session fixture now redirects the tabs path and the journal dir to temp for the whole session, plus an in-process backfill guard; a regression test pins the redirect. Test pollution in the real dirs was removed; the real tabs file held only a test remnant, so it was deleted and the app falls back to favorites |

Validation: `ruff check .` clean, **233 pytest tests pass**, `tests/run_all.py --no-pytest` passes — and a full run leaves the real `sync_journals/` and the tabs file untouched (verified).

### Batch 6 (2026-10-05) — weekend trip finder (plan-driven, unsupervised)

Built from `WEEKEND_FINDER_PLAN.md`. 339 tests, all passing; `streamlit run`
boots healthy (HTTP 200).

| Area | State |
|---|---|
| Airport → city → country | `airport_city.py` + generated `data/airports.csv` (4568 airports, OurAirports, public domain) via `build_airport_table.py`. Multi-airport cities merged (London's 6, Paris' 3, Tokyo, Milan, New York, …); districts like "Marignane, Bouches-du-Rhone" are overridden or dropped rather than shown as a city name |
| Airline benefit flag | `airline_benefits.py`. Reads the user's `airlines_benefits.xlsx` from the *other* project (IATA-keyed, `Yes`/`No`/`Unknown` per benefit column) as the source of truth; the workbook `Airline Benefits` sheet is a mirror/fallback and the seed list the last resort |
| Benefits import | any single `Yes` qualifies; `Unknown` does not (an unverified airline is not bookable, and treating Unknown as yes would silently widen the list). Matched by IATA code first, then name. Cached 5 min, invalidated on mtime/size. `python airline_benefits.py` imports and reports; the page has a re-read button |
| Matcher | `weekend_match.py` — pure, no I/O, 37 tests covering all six bounds, overnight flights, Monday-before-09:00 returns, multi-airport merging, codeshare/operator logic, and the one-way-only bucket |
| Page | `pages/weekend_finder.py`, sidebar entry "Weekend Finder" |
| **Scraping** | **blocked, verified not assumed** — Fraport's departures page is a JavaScript shell with zero flight rows and no public JSON endpoint (`/api/flight/*` and `/api/flights/*` 404); FlightStats is behind AWS WAF + captcha. Both registered as unavailable *with the reason recorded*, so the finding is testable and not repeated |
| Escape hatch | `csv` provider: upload or paste, header aliases accepted, bad rows reported not fatal. This is why the feature is usable at all today |

Design calls worth remembering:

* **Benefits follow the operating carrier**, not the marketing one: a
  LH-numbered flight operated by Vueling does not qualify.
* **Multi-airport cities merge by city, not by airport** — the user asked for
  this, and it also stops a codeshare from listing the same city twice.
* **Genuinely different cities that share a name stay separate** (Ubud vs
  Denpasar, Fez vs Saïss, two Khivas). A metro merge that hid those would
  silently delete a destination.
* The workbook's `Sri Lanka` row is a **country**, so it is refused as a match:
  "Sri Lanka (LK)" must not appear in a list of cities.
* An **unticked airline silently removes destinations**, so the results header
  always states how many carriers are flagged. (Later the same day the user
  pointed out the real source: `airlines_benefits.xlsx` in their *other*
  project. That is now the primary source, read by IATA code — see README,
  "Which airlines have benefits". The seeded 24-airline list is gone; today the
  file yields 7 of 597.)

Validation: `ruff check .` clean, `compileall` clean, **339 pytest tests pass**
(~50 s), `tests/run_all.py --no-pytest` passes.

### Decisions added on 2026-10-03

- Sync granularity: **per cell for the workbook, per trip variant for itineraries**
  (whole-file transport was considered and rejected). *Superseded 2026-10-04:
  trips are now per **stop**, see batch 3.*
- **"Only show unvisited" stays ON by default**, but no filter ever hides a row
  whose field is blank.
- The DDG/Unsplash gallery is **essential** and stays; the banner falls back to a
  plain title when a destination has no photo.

### Decisions added on 2026-10-04

- **A destination added on one device is journaled as a row creation**, so the
  other device appends the row and then receives the cell changes. (Without it
  the cells could only ever be reported as "skipped".)
- **Trips sync per stop** (`meta` / `order` / `stop:<id>` / `leg:<n>`) instead of
  per variant, so concurrent edits to different stops both survive. Whole-file
  `trips.json` transport was considered and rejected again.
- **Rainy days are unified going forward at ≥1 mm/day (WMO)** — but the existing
  curated rows are **not** regenerated: that would mean re-fetching climate data,
  which was declined. The affected rows are listed instead, without API calls.

### 2026-10-07 batch: airline benefits move to Turso, and Fraport is not blocked

**A wrong conclusion, corrected.** The 2026-10-05 batch recorded Fraport as
impossible to scrape, on the grounds that the departures page is a JavaScript
shell with no public JSON endpoint. Both halves of that were artefacts of how I
looked: I inspected only the *rendered HTML* (which genuinely has zero flight
rows) and then *guessed* paths under `/api`, which all 404. The endpoint is not
under `/api` — it is advertised in the page's own markup as a `data-api-url`
attribute. **Lesson: read the markup for `data-*` attributes before concluding a
page is client-side only.**

The endpoint, verified against live data:

```
https://www.frankfurt-airport.com/en/_jcr_content.flights.json/filter
  ?flighttype=departures|arrivals
  &time=2026-10-09T00:00:00+02:00     # full ISO datetime WITH tz offset
  &perpage=50&page=1&lang=en
```

* `time` must be a **full ISO datetime with a timezone offset**. `?date=2026-10-09`,
  `?time=2026-10-09` and `?time=09.10.2026` are silently ignored.
* `time` is a **cursor, not a filter**: paging walks forward through the whole
  ~88 600-record archive. Any date works (tested −7 to +60 days).
* Berlin is +01:00 in summer and +02:00 in winter — getting the offset wrong
  returns the wrong day.
* A weekend costs **~39 requests** if the cursor starts at the first moment
  needed (14 for outbound from Fri 14:00, 25 for returns from Sat 12:00).
* End-to-end check for Fri 2026-10-09 → Mon 2026-10-12: 700 outbound and 1250
  inbound flights scanned, 399/683 on benefit airlines, **123 cities reachable
  both ways**.

Consequences in the code: `timetable.FraportBoardProvider`'s reason text now says
*endpoint verified, not implemented* instead of *unreachable* (a false claim in a
docstring is worse than a missing feature — it stops the next agent looking), the
endpoint and both page URLs are pinned as class attributes, and
`test_the_blocked_providers_document_why` became
`test_the_unavailable_providers_document_why`, which asserts the reason says
"verified working" and **not** "JavaScript shell".

**Airline benefits now come from a Turso database**, at the user's decision,
replacing the `airlines_benefits.xlsx` import:

| | |
|---|---|
| Remote | `https://flightconnections-tz123.aws-eu-north-1.turso.io` |
| Table | `airlines(iata, name, discount_eligible, business_class, confirmed_booking, comments, updated_at)` |
| Values | lowercase `yes` / `no` / `unknown` |
| Local copy | `flightroutes-app/data/flightroutes.db` |

Verified rather than assumed: the local `.db` has **597** rows with exactly those
columns, 7/4/2 yes/unknown splits, `updated_at` on all rows, and the same 7
qualifying carriers (CX, JL, KC, LH, VL, VN, ZH) the Excel file produced. The
remote answers `/health` 200, `/v2/pipeline` 401 without a token and 400 with a
bad one — so the host and auth path are right and only a token is missing.

Decisions:

* **Raw HTTP over Turso's SQL-over-HTTP pipeline API**, not the `libsql` driver:
  one read query does not justify a native dependency in `requirements.txt`.
  Tests use stdlib `sqlite3` against a temporary file built to the same schema, so
  the real SQL and the real column names are exercised with no network and no
  credential.
* **Column matching and the meaning of "yes" are defined once.** `shape_records`
  and `records_to_flags` were extracted from `parse_external_rows` so the Excel
  and Turso paths cannot drift apart — the Excel reader had been carrying its own
  copy of the same rules.
* **An empty read is a failure, not "nobody qualifies."** An empty flag map would
  remove every destination from the finder with no visible cause.
* **Fallback ladder:** Turso → workbook `Airline Benefits` sheet (the only source
  on Cloud) → the Excel file, but *only* when Turso is not configured at all →
  the built-in seed list. Every failure returns a problem string; none raises.
* `benefit_source_name` / `benefit_summary` / `benefit_names` were reading the
  Excel file directly and would have *described a source the flags did not come
  from*. They now go through `_qualifying_rows()`, which returns the label
  alongside the data.
* The token is never logged or printed, and the cache key holds a 12-character
  SHA-256 fingerprint rather than the token.
* The weekend finder's benefits expander names the real source and offers the
  right button for it (clear the cache for Turso, re-read the file for legacy).

A bug worth recording: `ENV_LOCAL_DB` was first written
`TRAVEL_PLANER_FLIGHTROUTES_DB` — one letter from `TRAVEL_PLANNER_DATA_DIR`,
which is the spelling every other variable in this project uses. An unset
misspelled variable is completely silent: it reads as "the offline fallback does
not exist" rather than as a typo, and it cost a confusing debugging pass. There is
now a test asserting the PLANNER spelling, plus one asserting the local fallback
actually engages.

Validation: `ruff check .` clean, `compileall` clean, **405 pytest tests pass**,
`tests/run_all.py --no-pytest` exits 0.

### Decisions added on 2026-10-07

- **Benefits are read from a Turso database**, not a spreadsheet. A database is
  the right shape for something the user edits per-airline on two machines.
- **Any one of the three benefit columns being `yes` qualifies an airline**;
  `unknown` never does.
- A **remote outage must degrade to the workbook mirror, never to an empty list.**
- Fraport's endpoint is undocumented, so the CSV fallback stays and a recorded
  response fixture should fail a test loudly if their markup changes.

### 2026-10-08 batch: the main data layer moves to Turso (native rebuild, Phase 1)

Built from `NATIVE_HTML_PLAN.md` §7 Phase 1. The user's decisions
(2026-10-08): last-push-wins for conflicts (no conflict list), the
workbook survives as an *export* artifact, the PC goes native (Flutter)
eventually but **the Streamlit version is retained as the fallback**
during the transition, and the provided Turso database is used as-is
(no new free-tier account, no money).

| Area | Done |
|---|---|
| Client | `turso_db.py` — Turso's documented SQL-over-HTTP pipeline API over `requests` (deliberately *not* `pyturso`/`turso.sync`: the Rust extension pip-builds from source and trips the user's antivirus as `build-script-build.exe`). Cell normalisation (`{type, value}` → plain Python), error-in-200 handling, `close` last, token fingerprinting, credentials from env → `.streamlit/secrets.toml` |
| Schema | typed core (`destinations`: the 13 fields the app filters/sorts/searches on) + a lossless `data` JSON tail holding **all 145 workbook columns as an ordered `[name, value]` array** — the workbook has duplicate column names (positions 139/143, 140/144) and object-typed cells, so a flat typed table would drop data. Plus `trips`/`variants`/`stops`/`legs` (legs positional: `legs[i]` sits between `stops[i]` and `stops[i+1]`) and `open_tabs` |
| Storage | `storage_turso.py` — the project's writer contract (returns `True`/`False`, never raises on a quiet failure), single-pipeline-request atomic trip writes, upserts with `updated_at` (last-write-wins), `.xlsx` export that recovers the column order from the tail |
| Repository | `repository.py` — the one data-access point the pages now call. **Reads** prefer Turso and fall back to the workbook (an empty/unreachable Turso read is a *failure*, not an empty catalogue — the same rule as the benefits ladder). **Writes** are read-modify-write upserts and fail loudly (`False`) rather than silently diverging from Turso. `data_utils._prepare_dataframe` was extracted so both sources produce an identical `(DataFrame, metadata)` pair |
| Migration | `migrate_to_turso.py` — one-shot, idempotent (upserts), openpyxl-based (pandas collides the duplicate column names), alias-resolved typed core via the app's own `find_column` alias sets, row-count + column-count verification. **Run against the live database 2026-10-08: 144 destinations (145-column tails), 2 trips (Naples: 1 variant/3 stops/2 legs; China Trip 2027: 2 variants/9 stops/7 legs), 0 open tabs. Read, idempotent write round-trip and the `.xlsx` export verified against the live DB** |
| Tests | 87 new (`test_storage_turso.py` fakes `turso_db.run_pipeline` with an in-memory SQLite built to the real schema, so the emitted SQL is really exercised; `test_repository.py` pins both branches of the ladder). **492 total, green** |

**Two real bugs found and fixed by this work:**

1. `_load_open_tabs_from_turso` was a plain function but
   `_clear_cache()` called `.clear()` on it — 8 repository tests
   failed with `AttributeError`. It was missing the
   `@st.cache_data` decorator its sibling has.
2. **The page-smoke suite timed out (300 s).** Root cause: the
   detail page persists its open-tabs list on every render, and
   `repository.save_open_tabs` routes through Turso whenever
   `is_configured()` — which is true locally because
   `.streamlit/secrets.toml` holds a live token. From a machine
   that cannot reach Turso, each of the 144 page renders burned
   the 15 s HTTP timeout. Fix: `conftest._isolate_turso` (autouse)
   forces the workbook branch for every test; tests that exercise
   the Turso branch patch `is_configured`/`use_turso`/`run_pipeline`
   themselves, so nothing real is masked.

**Deliberately *not* done (transition state, by decision):** the
`sync/` stack, `refresh_cloud_workbook.py` and the workbook writers
stay — they are the workbook branch's path to the phone, and the
repository's fallback needs them. Trips still run on `trips.json` at
runtime (the migration *copied* them into Turso; the runtime cutover
is the next phase, gated on the same stale-guard/back-up reasoning as
`itinerary/storage.py`). Phase 1 of the plan said "delete the sync
stack" — that is Phase 6 (cutover), not now: deleting it would break
the fallback the user asked to keep.

Validation: `ruff check .` clean, `compileall` clean, **492 pytest
tests pass**, `tests/run_all.py --no-pytest` exits 0.

### 2026-10-08 completion: weekend trip finder
The weekend trip finder was unblocked by the verified Fraport board
JSON endpoint (`/_jcr_content.flights.json/filter`). Decision: **live
Fraport primary, CSV upload the fallback**.

Implemented `FraportBoardProvider` in `timetable.py`:
- Cursor-based paging: each page's last `time` value seeds the next
  `time` param. The endpoint has no total count or stable offset.
- Per-direction fetch with bounds-aware cache key: only the six window
  bounds (Fri 12:00 → Mon 12:00, arrivals + departures) are queried
  once per cache slot; `time` is a cursor only.
- Six bounds mapped to `(date, direction, hint)` via `search_weekend`
  plumbing: Fri-dep, Sat-arr/dep, Sun-arr/dep, Mon-arr.
- `stops` absent treated as "keep" (arrivals never report it; an absent
  `stops` on a departure is a non-stop LH train connection like EC/EuroCity).
- `al` is the operating carrier; `cs` (marketing carrier) is ignored.
- Wall-clock parsing: `sched`/`schedArr`/`schedDep` are naive local times —
  do not rely on them as offsets. Dates are inferred from the requested day
  or the previous departure's arrival.
- Shape-change (columns/rows present change) treated as a hard failure,
  not silent data — raises so a broken page is not hidden.

Page (`pages/weekend_finder.py`): `_render_data_source` defaults to the
live provider, CSV upload is the optional override. Page docstring
updated.

Fix during implementation: smoke-test suite timed out (300 s) because
page renders triggered live network calls. `tests/conftest.py` gained
an `_isolate_turso` autouse fixture that forces `is_configured() → False`
(workbook branch only); tests exercising the Turso branch patch
`is_configured`/`use_turso`/`run_pipeline` themselves. Tests that read
`airlines_benefits.xlsx` are isolated — must pass on CI where that file
does not exist.

Tests: 9 new fixture-based tests in `tests/test_timetable.py` using
recorded Fraport boards (`tests/fixtures/fraport_departures_page1.json`,
`fraport_departures_page2.json`, `fraport_arrivals_page1.json`,
`fraport_arrivals_page2.json`) — no live network per test run.

Validation: `ruff check .` clean, `compileall` clean, **501 pytest tests
pass** (492 + 9), `tests/run_all.py --no-pytest` exits 0.

### 2026-10-09: Turso tokens restored, benefits source fixed

The airline-benefits Turso source had never worked, for **two independent
reasons** — one in the credentials, one in the code. Both are now fixed.

**1. Both tokens' `kid` was mistyped.** `secrets.toml` held `VlYx`
(decoding to `VV1L5Ew…`) where the account's signing key is `Vmwx`
(`Vl1L5Ew…`). A one-character transcription slip (`m`→`l`, `Y`→`w`)
invalidated the EdDSA signature, so every read 401'd with *"can't be
decoded with any of the existing keys"*. Both databases share one
signing key, so both tokens carry the same `kid`. The main token is
fixed by correcting `VlYx` → `Vmwx`; the benefits token additionally
had to be swapped — the copy in the file had been minted for a role
that no longer exists (404 *"auth role not found"*) and was replaced
with the working read-write token.

**2. `benefits_turso.fetch_remote` did not normalise pipeline cells.**
The SQL-over-HTTP API returns every cell as `{"type": "text",
"value": …}`, but the reader passed them straight to `rows_to_records`,
which does `str(cell)` — producing the dict's repr, so `is_yes` never
matched and the remote source silently read as *"nobody qualifies"*.
`turso_db.py` had a `_cell_value` helper for exactly this;
`benefits_turso.py` did not. The helper is added and applied in
`fetch_remote`. The existing tests missed the bug because the
`_pipeline_response` fixture built its rows from bare strings, not the
typed shape the real API sends — so every other test passed while the
live source returned zero qualifying airlines.

Verified against the live databases: **144 destinations** (main),
**597 airlines / 7 qualifying** (CX, JL, KC, LH, VL, VN, ZH) via
`benefits_turso.fetch_benefit_flags`, and the full
`airline_benefits.load_benefit_flags` ladder now resolves through Turso
instead of the workbook fallback.

Tests: 10 new in `tests/test_benefits_turso.py` — a parametrized
`_cell_value` unit test (text/integer/real/null/blob/plain/None) and a
`fetch_remote` regression test driven through the real typed-cell
shape, so the fixture no longer hides the bug it is meant to cover.

Validation: `ruff check .` clean, `compileall` clean, **511 pytest
tests pass** (501 + 10), `tests/run_all.py --no-pytest` exits 0.

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
