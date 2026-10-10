# AGENTS.md — start here

**You are working on "Travel Planner".** The Streamlit app in this
repository is **legacy**: it is archived as a source of knowledge and
as a potential fall-back in case the new development does not go as
planned. The target architecture moves away from Streamlit — a native
desktop + Android app on the Turso data layer (decided 2026-10-10;
the decision, phases and status are in `NATIVE_HTML_PLAN.md`). This
file is the entry point: what the project is, where everything lives,
what must not break, and what is still open. Read it before touching
code.

| Document | What it is for |
|---|---|
| **`AGENTS.md`** (this file) | orientation, invariants, open items |
| `HANDOFF.md` | in-flight native-rebuild work and next steps (delete when the native phases are done) |
| `README.md` | how to run it, data locations, architecture, data-safety rules |
| `PLAN.md` | the full history: every review finding, every fix, every decision, with dates and commit hashes |
| `WEEKEND_FINDER_PLAN.md` | the weekend trip finder: spec, status, what is blocked and why |
| `TURSO_PLAN.md` | the airline-benefits Turso database: access contract, fallback ladder, open items |
| `NATIVE_HTML_PLAN.md` | the target architecture: move off Streamlit to native desktop + Android on Turso — the decision, the phases, what is done (Phase 1) and what is open |

---

## 1. Sixty-second orientation

* **Status (2026-10-10): the Streamlit version is legacy.** It is
  archived as a source of knowledge and as a potential fall-back in
  case the native development does not go as planned. The target
  architecture moves away from Streamlit — a native desktop + Android
  app on the Turso data layer (`NATIVE_HTML_PLAN.md`; Phase 1, the
  Turso data layer, is done).
* A personal travel catalogue and trip planner. 144 destinations in an Excel
  workbook, one Streamlit page per destination, a multi-stop itinerary planner,
  and a PC↔phone (Streamlit Cloud) sync that merges instead of overwriting.
* Python 3.11+ (the dev machine runs 3.14). Dependencies: `requirements.txt`
  (runtime) and `requirements-dev.txt` (pytest, ruff).
* **This is an application, not a library.** Run it from a checkout. Never
  `pip install -e .` expecting imports to work — it is a deliberate no-op.
* `Destinations-local.xlsx` is the **source of truth** and is **git-ignored**.
  `Destinations-cloud.xlsx` is the committed deploy seed for Streamlit Cloud.

```powershell
python -m pip install -r requirements.txt -r requirements-dev.txt
python -m streamlit run app.py --server.port 8507
```

## 2. Verify your work before saying it works

```powershell
python -m pytest                    # 511 tests, ~3 min (the 144-page render dominates)
python -m ruff check .              # lint, must be clean
python -m compileall -q . -x '(^|/)(\.venv|archive|Pictures|__pycache__)(/|$)'
python tests/run_all.py --no-pytest # dependency-free path, must exit 0
```

CI runs all four on every push to `main`, on Linux **and** Windows
(`.github/workflows/ci.yml`); Windows is there because atomic file replace and
file locking are platform specific. Check the result at **GitHub → Actions →
CI** — it was green at the last commit.

A useful discipline: reproduce a fresh-checkout failure before assuming your
change caused it. `git clone . <tmp> && cd <tmp> && python -m pytest` is what CI
actually runs, and it catches "works on my machine" bugs (a missing git-ignored
file, a machine-specific path).

## 3. Where the data lives

`runtime_paths.py` resolves this at import time, in order:

1. `$TRAVEL_PLANNER_DATA_DIR`
2. the repository directory (normal local use)
3. `%LOCALAPPDATA%\travel-planner` / `~/.local/share/travel-planner` (when the
   repo is read-only, i.e. Streamlit Cloud)

The sidebar prints the resolved path. Everything written at runtime goes there.

### Files that MUST travel with the folder (all git-ignored)

A `git clone` is **not** enough to move this project to another machine. Copy the
folder.

| File | What it holds |
|---|---|
| `Destinations-local.xlsx` | **the source of truth** — all destination data |
| `trips.json` | every itinerary |
| `sync_journals/` | unsynced changes + `last_sync.json` |
| `itinerary_cache/`, `workbook_backups/`, `trips_backups/`, `open_destinations.json` | UI state and restorable backups |
| `.streamlit/secrets.toml` | GitHub PAT (sync) — **secret** |
| `deepseek_secrets.py`, `openaq_secrets.py`, `unsplash_secrets.py` | API keys — **secret** |
| `Pictures/` | 181 MB of photos; regenerable but slow |
| `aqi_cache/`, `iqair_cache/`, `weekend_cache/` | rebuildable caches |

> **Secrets:** that folder contains a live GitHub fine-grained token and API
> keys. Move it by encrypted USB or cable, not by email or a share link. They are
> git-ignored; never commit them.

### External data this project reads

**Airline benefits — a Turso database** (`benefits_turso.py`), decided 2026-10-07:

| | |
|---|---|
| Remote | `https://flightconnections-tz123.aws-eu-north-1.turso.io` |
| Table | `airlines(iata, name, discount_eligible, business_class, confirmed_booking, comments, updated_at)` |
| Values | lowercase `yes` / `no` / `unknown` |
| Token | `TURSO_AUTH_TOKEN` — set in `.streamlit/secrets.toml`; live source verified 2026-10-09: 597 rows, 7 qualifying |
| Offline copy | `flightroutes-app/data/flightroutes.db` via `TRAVEL_PLANNER_FLIGHTROUTES_DB` |

**`unknown` must never count as a yes**, and an **empty read is a failure**, not
"nobody qualifies" — an empty flag map removes every destination from the finder
with no visible cause. Verified against the live database: 597 rows, 7 qualifying
(CX, JL, KC, LH, VL, VN, ZH). Full contract in `TURSO_PLAN.md`.

**Legacy:** `airlines_benefits.xlsx` in the user's other project is still read,
but *only* when Turso is not configured at all. Once the token exists it is never
opened again; `TRAVEL_PLANNER_AIRLINE_BENEFITS` still points at it.

The fallback ladder is Turso → workbook `Airline Benefits` sheet → that Excel file
→ built-in seed list. Every failure falls through rather than raising, so a
missing source is never an exception — but the results *change*, so do not
mistake an empty result list for a bug.

## 4. Data-safety rules — do not break these

These exist because breaking them lost or corrupted the user's data.

1. **Never call `workbook.save(...)` directly.** Use
   `data_utils.load_workbook_for_update()` + `save_workbook_atomic()`. They
   refuse a stale write and snapshot the outgoing file.
2. **Writers return `True`/`False`.** `False` means "nothing was written" —
   surface it; never report it as success.
3. **Never save a stale `trips.json`.** Mutate through
   `itinerary/storage.py`; it raises `TripsFileChanged` when another session
   saved first. The UI must catch that and offer *Reload latest data*.
4. **Journal files belong to the device that writes them**, and
   `sync/transport_github.py` unions the remote copy rather than overwriting it.
5. **A filter may only remove rows whose field is populated** — use the helpers
   in `filters.py`.
6. **A newly written file must be journaled** if it should reach the other
   device (workbook cells, trips, open tabs). A write that is not journalled is
   a write that stays on one machine.

### Test hygiene

`tests/conftest.py` redirects *all* runtime state into a temporary directory:
the workbook (`DATA_PATH`), `trips.json`, the journal dir, the tabs file.
It also forces the **workbook branch** of the repository
(`_isolate_turso`: `turso_db.is_configured()` → `False`), because the
local `.streamlit/secrets.toml` holds a live Turso token and a page
render would otherwise make a real network call per write (the smoke
tests render 144 destinations — each burned the 15 s HTTP timeout and
the suite timed out). Tests that exercise the Turso branch patch
`is_configured`/`use_turso`/`run_pipeline` themselves. Two
tests assert the real files are unchanged afterwards. A full run must
leave the repository untouched — if a test writes to the live workbook,
journals or tabs file, that is a bug in the fixture, not in the test.
It happened once: a page-render test journalled 10k entries into the
real `sync_journals/`.

When adding a test that reads a file outside the repo (like
`airlines_benefits.xlsx`), isolate it — the suite must give the same result on
CI, where that file does not exist.

## 5. Architecture in one screen

```
app.py                    navigation + custom sidebar (open tabs, trips,
                          workbook download, sync button)
pages/world_map.py        choropleth + filters + "cities in <country>"
pages/overview.py         filterable, country-grouped catalogue
pages/destination_detail.py  one page per city (banner, metrics, climate
                          dashboard, galleries, AI populate, flight routes)
pages/itinerary.py        trips → variants → stops → legs + route map
pages/weekend_finder.py   Fri→Mon possibilities from FRA
weekend_match.py          pure matcher: flights + windows → cities (no I/O)
timetable.py              flight providers + CSV parsing + caching
airport_city.py           airport → city → country, metro merge
airline_benefits.py       benefits, read from airlines_benefits.xlsx
filters.py                shared filter primitives
rainy_days.py             the one rainy-day definition (≥ 1 mm/day)
data_utils.py             workbook I/O: atomic saves, stale detection, writers
repository.py             the one data-access point: Turso first, workbook fallback
storage_turso.py          destinations/trips/tabs on the Turso database
turso_db.py               Turso SQL-over-HTTP client + the app schema
migrate_to_turso.py       one-shot workbook + trips.json -> Turso migration
itinerary/                pure, Streamlit-free trip logic + persistence
sync/                     journal → merge → GitHub transport → sidebar UI
runtime_paths.py          where runtime state is written
```

**The main database is Turso now** (`travel-tz123`, migrated
2026-10-08 — see `NATIVE_HTML_PLAN.md` Phase 1). The pages call
`repository.py`, which reads destinations and open tabs from Turso
when `TRAVEL_PLANNER_TURSO_URL` + `TRAVEL_PLANNER_TURSO_TOKEN` are
set, and falls back to the workbook otherwise. Reads fall through on
failure; **writes fail loudly** (return `False`) rather than silently
diverging from Turso. Trips still run on `trips.json` at runtime —
the migration copied them into Turso, and the runtime cutover is the
next phase. The `sync/` stack and `refresh_cloud_workbook.py` stay
until the cutover: they are the workbook branch's path to the phone.

**Workbook facts that keep biting:** 144 destinations × 145 columns. The data
sheet is `Result sheet`; `wb.active` is the **`Airlines`** sheet, so never write
through it. `Prio Thorsten` is an object/text column. `refresh_cloud_workbook.py`
copies local → cloud and must be run before the phone can see new bulk data.

**Git:** work on `main` and push to `origin/main`. The branch **`data-sync` must
not be touched** — it carries the sync journals.

## 6. Open items

Nothing is half-finished; these are decisions waiting on the user.

| # | Item | State |
|---|---|---|
| 1 | **Cloud persistence check (Q1)** | Unverified whether the Streamlit Cloud deployment can persist anything. Nothing depends on the answer (`runtime_paths.py` handles all three cases) but it is untested in anger. *How to check:* edit a destination comment on the phone, reload, confirm it survived. |
| 2 | **Weekend finder flight data** | **Done 2026-10-09.** The Fraport JSON endpoint is live in `timetable.py` (cursor paging, wall-clock parsing, stops filter, shape-change loud-fail); CSV upload is the optional override. The provider depends on the airline benefits, which now resolve correctly via Turso (7 qualifying airlines: CX, JL, KC, LH, VL, VN, ZH). |
| 3 | **7 rainy-day rows use the old definition** | They hold trace-precipitation values instead of the project's ≥ 1 mm. Deliberately not regenerated (costs API calls). `python write_climate_data.py --list-legacy-rainy-days` is the worklist: Thessaloniki, Ubud, Ulaanbaatar, Valencia, Valparaiso, Vientiane, Vung Tau. |
| 4 | **`open_destinations.json` on Cloud** | Synced across devices now; still lost on a Cloud *redeploy* because the repo is remounted. Accepted. |

### House rules learned the hard way

* **Verify a claim before building on it.** Both flight boards were assumed
  scrapeable; checking cost ten minutes and saved a wasted implementation.
* **A test timeout is not a product bug** — but a flaky test that guards the one
  important invariant is still a problem; give it a real budget.
* **Never let a "no results" answer be ambiguous.** Every filter that can empty
  a list states how many items it dropped and why.
* **Prefer an explicit table to a heuristic** for names and labels. Heuristics
  for airline/city names were rewritten three times before they became an
  explicit, testable mapping.

## 7. Conventions

* Comments explain *why*, especially when the obvious thing was tried and failed.
  Several comments cite the bug that motivated the code.
* New logic goes in a pure module with tests (`weekend_match.py`,
  `filters.py`, `rainy_days.py`); Streamlit files stay thin.
* Tests run **with or without pytest**: keep the `__main__` runner in a module
  and register it in `tests/run_all.py`'s `SCRIPT_RUNNABLE` list.
* `ruff` selects `E4, E7, E9, F, B023, I` — pyflakes, loop-variable closures and
  import order. Keep it clean.
* Update `README.md` (how it works) and `PLAN.md` (what changed and why) in the
  same commit as the change.