# Travel Planner

A personal travel catalogue and trip planner: 144 destinations on a Turso
database, browsed on a world map, a detail page per city, multi-stop trips
with variants and a route map, and a weekend finder from Frankfurt.

> **The app is the Flutter app in [`mobile/`](mobile/)** — native desktop
> (Windows) + Android, talking to Turso directly. The original Streamlit app
> and a Phase-3 web prototype are **archived** under [`archive/`](archive/)
> (frozen reference; the tag `legacy-streamlit` restores them runnable).
> Do not start them from this working tree — this is exactly the trap that
> motivated the archive (2026-10-13). Decision history:
> `NATIVE_HTML_PLAN.md`.

> **Working on this codebase? Read [`AGENTS.md`](AGENTS.md) first** — it is
> the entry point: where everything lives, the invariants that must not
> break, how to verify a change, and the open items.

## Running it

```powershell
cd mobile
# Dev: builds and opens the window in one step
& "C:\src\flutter\bin\flutter.bat" run -d windows

# Or build the release exe once and start it:
& "C:\src\flutter\bin\flutter.bat" build windows --release
& .\build\windows\x64\runner\Release\travel_planner.exe
```

Android: `flutter build apk --release` and install
`build\app\outputs\flutter-apk\app-release.apk`.

Credentials come from `mobile/assets/turso_config.json` (git-ignored;
template `turso_config.example.json`, values from
`.streamlit/secrets.toml`). Without it the app runs unconfigured and
explains itself instead of crashing — a fresh clone needs the file copied
in before data shows up.

The app runs in **light mode** — the map tiles and charts are imagery
designed for light surfaces. Four tabs, each with its own colour icon
(`mobile/lib/ui/nav_icons.dart`):

* **Catalogue** — search, filters, country-grouped sections with per-country
  counts, a per-card line with safety · cost/day · flight hours, add
  destination, AI populate.
* **Trips** — the itinerary editor: trip/variant switchers with their
  actions in per-row ⋯ menus, stops as a timeline (each stop one line that
  opens its date/time editor), transport legs between them, a side panel
  with route summary/rating/best months, Plan / Map / Compare as segmented
  buttons, and a compare table that activates a variant on tap.
* **Finder** — the weekend finder from FRA: the Fraport board plus the
  benefits database, a CSV override, an "only airlines with benefits"
  switch, a max-flight-time cap (default 6 h per leg), and out/back day
  switches — Thursday out and Tuesday back are the holiday-bridge days for
  a long weekend, each day's time bound editable. One expandable row per
  city; result cities open their destination page and return to intact
  results.
* **Map** — the month choropleth on English-labelled tiles: pick a month
  and every country fills with its best condition, country borders and a
  hover name tooltip, wheel/pinch zoom and drag panning, a fly-to search,
  the month's stats and the legend overlaid on the map, tap a country to
  list its cities.

A destination's detail page shows the profile sections (overview,
highlights, logistics, food, best months, climate — temperature/rainfall
with rainy-day counts, the AQI profile with severity bands, the IQAir
PM2.5 history) plus a mini-map, banner photo and gallery from the PC's
`Pictures/` caches, **AI populate** / **food populate** (DeepSeek, key in
the config file — without it the buttons are not offered) and
**Transport & Direct Connections**: direct flight routes (plus high-speed
rail for Chinese cities) researched on demand, cached per destination in
`flight_routes_cache/`.

## The data layer

**The live database is Turso** (`travel-tz123`, migrated 2026-10-08):
destinations, trips and open tabs. The app speaks Turso's SQL-over-HTTP
pipeline API directly — no backend in between, and the read-write token
ships in the app bundle (a decision, 2026-10-08/11: single-user app,
revocable tokens, DeepSeek has no auto-recharge, so the worst case of an
extracted AI key is ~10 EUR before rotation).

Each destination row is a **typed core** (the fields the app filters and
sorts on) plus a **lossless `data` tail** — JSON holding all 145 workbook
columns in order, duplicates included. Every field edit updates core and
tail together (`Destination.withField` / `withTail`), so the workbook
re-export never loses data. `Destinations-local.xlsx` (git-ignored) is the
reference workbook — the artifact the data was migrated from and the export
target; it is not written at runtime any more.

The contracts that must not drift (from the Python era, translated 1:1 into
Dart — full list in `AGENTS.md` §3): a failed read returns an empty list
*with* problems and is never conflated with a genuine empty database; a
failed write returns `false` and is surfaced; a filter only ever removes a
row whose field is populated; `unknown` in the benefits database never
counts as a yes.

## The airline-benefits database

The weekend finder needs to know which airlines have benefits, and the
answers live in a second **Turso database** (since 2026-10-07; before that
an Excel file):

```
table:  airlines(iata, name, discount_eligible, business_class,
                  confirmed_booking, comments, updated_at)
remote: https://flightconnections-tz123.aws-eu-north-1.turso.io
values: lowercase yes / no / unknown
```

An airline counts when **any** of the three flags is `yes`; `unknown` and
`no` both mean no — an unverified airline must never silently widen the
results. Matching is by IATA code first, then by name. Live state verified
2026-10-09: 597 rows, 7 qualifying (CX, JL, KC, LH, VL, VN, ZH). Access
contract and fallback ladder: `TURSO_PLAN.md`. The reader lives in
`mobile/lib/data/benefits_repository.dart` (the archived
`archive/streamlit/benefits_turso.py` is the Python original).

## Tests, analyze, build

```powershell
cd mobile
& "C:\src\flutter\bin\flutter.bat" pub get
& "C:\src\flutter\bin\flutter.bat" analyze   # must be clean
& "C:\src\flutter\bin\flutter.bat" test      # 395 tests, no credentials
```

The suite uses a scripted Turso fake (`mobile/test/fake_turso.dart`) — no
network, no tokens. CI (`.github/workflows/ci.yml`) runs analyze + test on
every push to `main`; if it is red, the push broke something.

The archived Python suite (511 tests) belongs to the frozen code and is
runnable from the `legacy-streamlit` tag — see `archive/README.md`.

## Architecture in one screen

```
mobile/
  lib/ui/                one file per screen: shell, catalogue, detail,
                         trips (+ plan/map/compare tabs), weekend finder,
                         world map, nav icons, theme, charts
  lib/data/              repositories: destinations, trips, benefits,
                         weekend, geocode, flight routes, catalogue match
  lib/models/            pure models: destination, trip + ops, weekend
                         match, timetable, geo, catalogue filters, condition
  lib/turso/             the SQL-over-HTTP pipeline client + config
  assets/                turso_config.json (git-ignored) + generated
                         airports/countries/coordinates tables
  test/                  unit + widget tests on the scripted Turso fake
archive/                 the retired apps, frozen (see archive/README.md)
```

The generated assets regenerate from the archived Python owners with
`python mobile/tools/generate_assets.py` — the documented path, so a
correction reaches both eras of the app.

## Known limitations

* Seven destinations hold `{Mon} Rainy Days` values counting **trace**
  precipitation instead of the project's ≥ 1 mm definition (Thessaloniki,
  Ubud, Ulaanbaatar, Valencia, Valparaiso, Vientiane, Vung Tau).
  Deliberately not re-fetched (API cost). The regeneration tool is
  archived: restore via the tag and run
  `python write_climate_data.py --list-legacy-rainy-days`.
* Trips → Map: the "Focus country" dropdown spans the full width (minor
  polish, tracked in `AGENTS.md` §5).
* The weekend finder fetches flights from Fraport's own JSON endpoint
  (verified 2026-10-07; a pasted CSV is the offline override). Board
  fixtures cover the tests — no network per run.
