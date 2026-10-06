# AGENTS.md — start here

**You are working on "Travel Planner", a private Streamlit app.** This file is
the entry point: what the project is, where everything lives, what must not
break, and what is still open. Read it before touching code.

| Document | What it is for |
|---|---|
| **`AGENTS.md`** (this file) | orientation, invariants, open items |
| `README.md` | how to run it, data locations, architecture, data-safety rules |
| `PLAN.md` | the full history: every review finding, every fix, every decision, with dates and commit hashes |
| `WEEKEND_FINDER_PLAN.md` | the weekend trip finder: spec, status, what is blocked and why |

---

## 1. Sixty-second orientation

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
python -m pytest                    # 355 tests, ~2 min (the 144-page render dominates)
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

### External file this project reads

`airline_benefits.py` reads **`airlines_benefits.xlsx`** from the user's *other*
project:

```
C:\Users\Thors\OneDrive\Documents\VS Code - Flights\flightroutes-app\data\airlines_benefits.xlsx
```

The user edits that file; it will keep its structure. It is IATA-keyed with
`Yes`/`No`/`Unknown` per benefit column. Override the path with
`TRAVEL_PLANNER_AIRLINE_BENEFITS`. The app degrades gracefully (workbook mirror,
then built-in seed list) if it is missing — but the results change, so do not
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
the workbook (`DATA_PATH`), `trips.json`, the journal dir, the tabs file. Two
tests assert the real files are unchanged afterwards. A full run must leave the
repository untouched — if a test writes to the live workbook, journals or tabs
file, that is a bug in the fixture, not in the test. It happened once: a
page-render test journalled 10k entries into the real `sync_journals/`.

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
itinerary/                pure, Streamlit-free trip logic + persistence
sync/                     journal → merge → GitHub transport → sidebar UI
runtime_paths.py          where runtime state is written
```

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
| 2 | **Weekend finder flight data** | Both boards are unreachable from plain HTTP (verified, see `WEEKEND_FINDER_PLAN.md`): Fraport's page is a JavaScript shell with no public JSON endpoint; FlightStats sits behind AWS WAF + captcha. The CSV upload/paste path works. **Needs a user decision:** a Lufthansa Developer API key (covers exactly the benefit carriers, any date) or another source. |
| 3 | **Airline benefits file is 7/597 filled** | The finder shows few destinations until the user fills in the file. Not a bug. `python airline_benefits.py` reports the current state. |
| 4 | **7 rainy-day rows use the old definition** | They hold trace-precipitation values instead of the project's ≥ 1 mm. Deliberately not regenerated (costs API calls). `python write_climate_data.py --list-legacy-rainy-days` is the worklist: Thessaloniki, Ubud, Ulaanbaatar, Valencia, Valparaiso, Vientiane, Vung Tau. |
| 5 | **`open_destinations.json` on Cloud** | Synced across devices now; still lost on a Cloud *redeploy* because the repo is remounted. Accepted. |

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