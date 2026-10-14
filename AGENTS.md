# AGENTS.md — start here

**You are working on "Travel Planner".** The app is the **Flutter app in
`mobile/`** (native desktop + Android, on the Turso data layer) — it is the
only app in this repository, and the only thing to run or build. The original
Streamlit app and the Phase-3 web prototype are **physically archived** under
`archive/` (frozen reference, restorable via the git tag
`legacy-streamlit`). Do not start them from the working tree — they are not
maintained here any more. Decided 2026-10-10 (move off Streamlit), archived
2026-10-13; the decision, phases and status are in `NATIVE_HTML_PLAN.md`.

| Document | What it is for |
|---|---|
| **`AGENTS.md`** (this file) | orientation, invariants, open items |
| `HANDOFF.md` | in-flight native-rebuild work and next steps (delete when the native phases are done) |
| `README.md` | how to run it, data locations, the Turso contract, data-safety rules |
| `PLAN.md` | the full history: every review finding, every fix, every decision, with dates and commit hashes |
| `WEEKEND_FINDER_PLAN.md` | the weekend trip finder: spec, status, what is blocked and why |
| `TURSO_PLAN.md` | the airline-benefits Turso database: access contract, fallback ladder, open items |
| `NATIVE_HTML_PLAN.md` | the architecture decision: off Streamlit, onto native desktop + Android on Turso — phases and status |
| `archive/README.md` | what is archived, why, and how to restore it |

---

## 1. Sixty-second orientation

* **Status (2026-10-13): the Flutter app is the app.** It reached feature
  parity with the retired Streamlit app (catalogue, trips, destination
  detail, weekend finder, world map, AI populate) and then took a UX pass
  (light mode, colour nav icons, map zoom/pan/borders/hover, a Trips
  accordion, finder day pickers — see `PLAN.md` §0o). Phase 6 (cutover) is
  effectively done: the legacy moved to `archive/`.
* A personal travel catalogue and trip planner: 144 destinations on Turso,
  a multi-stop itinerary planner, a weekend finder from FRA, and a world map.
* **Run it (desktop):**

```powershell
cd mobile
& "C:\src\flutter\bin\flutter.bat" run -d windows          # dev
& "C:\src\flutter\bin\flutter.bat" build windows --release # or build once:
& .\build\windows\x64\runner\Release\travel_planner.exe
```

* **Verify your work:**

```powershell
cd mobile
& "C:\src\flutter\bin\flutter.bat" analyze   # must be clean
& "C:\src\flutter\bin\flutter.bat" test      # 395 tests, no credentials needed
```

CI (`.github/workflows/ci.yml`) runs exactly these two on every push to
`main`. There is no other gate and no other app.

* **The legacy world** (Streamlit app, web prototype, their 511-test Python
  suite, ruff/pytest config, the populate/maintenance scripts) lives in
  `archive/streamlit/` and `archive/web-prototype/`. It is **frozen**: do not
  fix, extend or run it here. To run or modify it, restore first:

```powershell
git switch legacy-streamlit    # the full old world, runnable as documented
```

* `mobile/assets/turso_config.json` is **git-ignored** and required; without
  it the app runs unconfigured and explains itself (template:
  `turso_config.example.json`). A fresh clone needs it copied in before the
  app shows data.

## 2. Where the data lives

* **The live database is Turso** (`travel-tz123`; destinations, trips, open
  tabs — migrated 2026-10-08). The Flutter app talks to it directly over the
  SQL-over-HTTP pipeline API; the read-write token ships in the app bundle
  (a decision, 2026-10-08/11, for a single-user app — see README).
* **The airline-benefits database** is a second Turso database
  (`flightconnections-tz123`): 597 airlines, 7 qualifying
  (CX, JL, KC, LH, VL, VN, ZH). The contract that must not drift:
  **`unknown` never counts as a yes**, and **an empty read is a failure**,
  never "nobody qualifies". Full contract: `TURSO_PLAN.md`.
* **`Destinations-local.xlsx`** (git-ignored) is the reference workbook —
  the artifact the data was migrated *from* and the export target. It is no
  longer written at runtime. `Destinations-cloud.xlsx` (committed) was the
  Streamlit Cloud deploy seed; it is archive-era too.
* **Per-device state** (git-ignored, at the repo root): `Pictures/`
  (gallery photos, read by the app), `flight_routes_cache/` and
  `iqair_cache/` (read by the app), `trips.json`, `sync_journals/`,
  `itinerary_cache/`, `weekend_cache/`, `aqi_cache/`, `workbook_backups/`,
  `trips_backups/` (legacy runtime state, kept for the fall-back).
* **Secrets:** `mobile/assets/turso_config.json` (Turso tokens, DeepSeek key)
  and `.streamlit/secrets.toml` (legacy, still live tokens) are git-ignored;
  never commit them. The retired API-key modules
  (`deepseek_secrets.py` etc.) moved to `archive/streamlit/`.

A `git clone` is still **not** enough to move this project to another
machine — the git-ignored files above must come along (encrypted USB or
cable, never a share link).

## 3. Invariants — do not break these

These were paid for with lost or corrupted data. Most originated in the
archived Python code; their Dart translations are binding in `mobile/` today.

1. **A failed read is not an empty result.** In Dart: a failed read returns
   an empty list *with* problems; an empty list without problems means the
   database is genuinely empty. Never conflate the two.
2. **A failed write returns `false`** — surface it, never report it as
   success.
3. **Every field edit is a read-modify-write** that updates the typed core
   *and* the lossless `data` tail (Dart: `Destination.withField` /
   `withTail`; Python-era: `repository._set_field`). A targeted UPDATE that
   touches only the typed column leaves every other reader stale.
4. **A filter may only remove rows whose field is populated**
   (`mobile/lib/models/catalogue_filters.dart`, ported rule-for-rule from
   the archived `filters.py`). Every filter that can empty a list states how
   many items it dropped and why.
5. **`unknown` in the benefits database never counts as a yes.**
6. **Turso is last-write-wins.** The trips editor reloads before every edit
   to keep the write window small; a save that loses the race surfaces a
   conflict instead of overwriting.

### Test hygiene

`mobile/test/fake_turso.dart` scripts the Turso pipeline so the suite needs
no credentials and no network. Widget tests inject fakes through
constructor parameters; keep it that way — a test that needs the real
database is a flake waiting to happen. The app's unconfigured state (no
`turso_config.json`) is a normal, rendered state, not a crash.

## 4. Architecture in one screen

```
mobile/                        the app (Flutter, desktop + Android)
  lib/ui/                      one file per screen + shared widgets
    main.dart                  shell: 4 tabs (Catalogue/Trips/Finder/Map),
                               rail on desktop, bottom bar on phone,
                               the open-tabs panel/strip + their wiring
    catalogue_page.dart        search, filters, country groups, cards
    destination_page.dart      one destination: header, facts, sections,
                               climate/AQI charts, gallery, transport
    trips_page.dart            trip/variant switchers + Plan/Map/Compare
    itinerary_plan_tab.dart    the stops accordion + side panel
    itinerary_map_tab.dart     the route map (view-aware overlay)
    itinerary_compare_tab.dart the variants table
    weekend_finder_page.dart   the FRA weekend finder
    world_map_page.dart        the month choropleth (tiles, borders,
                               hover, zoom/pan, fly-to)
    nav_icons.dart             the hand-drawn colour tab icons
    open_tabs.dart             the open-destination panel (desktop) /
                               chip strip (phone); settings_page.dart
                               holds the on/off switch
  lib/data/                    repositories (Turso pipeline, caches,
                               open tabs, app settings)
  lib/models/                  pure models (destination, trip, weekend
                               match, timetable, geo, filters)
  assets/                      turso_config.json (git-ignored), generated
                               airports/countries/coordinates tables
archive/                       the retired apps — frozen (see its README)
  streamlit/                   the original Streamlit app + tests + tools
  web-prototype/               the Phase-3 HTML frontend + FastAPI backend
.github/workflows/ci.yml       the one gate: flutter analyze + test
```

**The data's shape:** each destination row is a typed core (the fields the
app filters and sorts on) plus a **lossless `data` tail** — JSON holding all
145 workbook columns in order. The tail is what makes the workbook
re-exportable and keeps duplicated/odd columns from being silently dropped.
`Destination.withField` updates core and tail together; never bypass it.

**Workbook facts that keep biting** (matters for exports and the archived
tools): 144 destinations × 145 columns; the data sheet is `Result sheet`;
`wb.active` is the **`Airlines`** sheet, so never write through it;
`Prio Thorsten` is an object/text column; the population column stores
**millions**.

**Git:** work on `main` and push to `origin/main`. The branch **`data-sync`
must not be touched** — it carries the sync journals.

## 5. Open items

| # | Item | State |
|---|---|---|
| 1 | **"Open destinations" tabs in the Flutter app** | **Done (2026-10-14, PLAN §0r).** Turso-backed (`open_tabs`, full-replace writes, the `storage_turso` contract), a side panel on the desktop / chip strip on the phone, and an on/off switch under ⚙ Settings in the catalogue's app bar (per-device `app_settings.json` via the config's `state_dir`). |
| 2 | **7 rainy-day rows use the old definition** | They hold trace-precipitation values instead of the ≥ 1 mm definition (Thessaloniki, Ubud, Ulaanbaatar, Valencia, Valparaiso, Vientiane, Vung Tau). Deliberately not regenerated (costs API calls). The tool is archived: restore via the tag, run `python write_climate_data.py --list-legacy-rainy-days`, write the workbook rows, push to Turso. |
| 3 | **Trips → Map: the "Focus country" dropdown** | Still spans the full width and dominates the control rows. Minor polish. |
| 4 | **Local commits not pushed** | Resolved 2026-10-14: everything through `085ec08` is on `origin/main`. |

Retired with the Streamlit Cloud app (2026-10-13): the "cloud persistence
check" and the "open_destinations.json lost on redeploy" items — there is no
Streamlit deployment to check any more. Do not redeploy Streamlit Cloud from
this repo; the archived code predates these paths.

### House rules learned the hard way

* **Verify a claim before building on it.** Both flight boards were assumed
  scrapeable; checking cost ten minutes and saved a wasted implementation.
* **A test timeout is not a product bug** — but a flaky test that guards the
  one important invariant is still a problem; give it a real budget.
* **Never let a "no results" answer be ambiguous.** Every filter that can
  empty a list states how many items it dropped and why.
* **Prefer an explicit table to a heuristic** for names and labels.
  Heuristics for airline/city names were rewritten three times before they
  became an explicit, testable mapping.
* **Run the app you changed.** The archive exists precisely so nobody
  "verifies" a change against the wrong app ever again.

## 6. Conventions

* Comments explain *why*, especially when the obvious thing was tried and
  failed. Several comments cite the bug that motivated the code.
* New logic goes in a **pure model** with tests (`weekend_match.dart`,
  `catalogue_filters.dart`, `geo.dart`); UI files stay thin. The Dart tests
  run with `flutter test`; pure-model tests need no widgets.
* Update `README.md` (how it works) and `PLAN.md` (what changed and why) in
  the same commit as the change.
* The archived Python world keeps its own conventions (pytest-with-or-
  without, ruff `E4, E7, E9, F, B023, I`) — they apply **only** when working
  on a restored tag, not in this working tree.
