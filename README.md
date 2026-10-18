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
template `mobile/assets/turso_config.example.json`). Without it the app runs
unconfigured and explains itself instead of crashing — a fresh clone needs the
file copied in before data shows up. Optional settings include
`flightaware_api_key` for the Finder fallback, `flight_routes_url` and
`flight_routes_token` for the shared departure cache, and `unsplash_access_key`
for the user-triggered destination gallery. The FlightRoutes token should be
read-only; never reuse the destinations or airline-benefits database token.

The app runs in **light mode** — the map tiles and charts are imagery
designed for light surfaces. Four tabs, each with its own colour icon
(`mobile/lib/ui/nav_icons.dart`, always in full colour — selection is
the rail pill, not a drained icon):

* **Catalogue** — search, filters, country groups under shaded header
  bands with count pills, a per-card line with review rating · prio (when
  set) · population — wrapped, never truncated — yellow favourite stars,
  add destination, AI populate.
* **Planner** — the itinerary editor (nav label "Planner", was "Trips"):
  trip/variant switchers with their actions in per-row ⋯ menus, stops as a
  timeline (each stop one line that opens its date/time editor), transport
  legs between them, a side panel with route summary/rating/best months,
  Plan / Map / Compare as segmented buttons, and a compare table that
  activates a variant on tap.
* **Finder** — the weekend finder from FRA: the Fraport board plus the
  benefits database, an airlines dropdown (Only Lufthansa Group /
  Only Lufthansa / All with benefits / All), a max-flight-time cap
  (default 6 h per leg) and a visible "Min. nights" filter (default
  1 night). Out/back days come from a travel-period picker: pick the
  period, then freely select/deselect each candidate day (period ± 1) and
  give each a time bound ("departs after 14:00" / "lands before 09:00" /
  any time). One expandable row per city; options show stacked, labeled
  outbound/return legs and stay length without repeating mapped airport codes.
  Result cities open their destination page and return to intact results.
* **Map** — the month choropleth on English-labelled tiles: pick a month
  and every country fills with its best condition, country borders and a
  hover name tooltip, wheel/pinch zoom and drag panning, a fly-to search,
  the month's stats and the legend overlaid on the map, tap a country to
  list its cities.

**Open-destination tabs** (⚙ Settings in the catalogue's app bar turns
them off and on): destinations you open collect into a closeable list,
held behind a **floating button** with a count badge (bottom-right on the
phone, beside the rail on the desktop) that opens the list as a bottom
sheet — the old side panel and chip strip are gone. The list lives in
Turso (`open_tabs`, full-replace writes — the legacy sidebar's exact
contract) and survives a restart; the switch itself is per-device state in
`app_settings.json`, stored in the `state_dir` the config names (the repo
root on the PC; the phone uses its documents directory).

A destination's detail page opens with compact **coloured stat tiles**
(safety / cost per day / FRA flight / population — one row, icon beside
the numbers) and an **Add comment** button; the comment editor only
exists once there is something in it. The profile sections follow
(overview, highlights, logistics, food, best months, climate —
temperature/rainfall with rainy-day counts, the AQI profile with
severity bands, the IQAir PM2.5 history) plus a mini-map, banner photo
and gallery from the PC's
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

## Shared FlightRoutes departure boards

The Finder can read exact-day, full-day **schema-v2** departure boards from the
FlightRoutes Turso database (`schedule_boards`). FlightRoutes remains the
producer, using its existing AeroDataBox/AirLabs setup and sync; Travel Planner
uses separate `flight_routes_url` and `flight_routes_token` settings. Use a
read-only token; do not reuse the destinations or benefits database credentials.
The current ignored local config was populated from FlightRoutes at the user's
request, but its token scope is unverified—replace it with a read-only token
before distributing the app. No credentials are committed.

The reader uses a complete FRA board for outbound flights and can supplement
suspicious return-arrival windows from complete candidate-airport boards. It
rejects legacy v1, partial AirLabs, corrupt, and timestamp-incomplete rows; those
fall back to the existing Fraport/FlightAware path. It applies flight-day rules
using airport-local timestamps and duration caps using UTC timestamps. Travel
Planner does not write its filtered Fraport windows as full airport-day boards.
If shared DB settings are missing or unreadable, the Finder still uses its
existing providers and reports the read problem.

## Destination photos

The detail gallery offers user-initiated Unsplash search and per-photo replace.
It hotlinks the official API's image URLs and stores attributed metadata only in
per-device app storage. Set `unsplash_access_key` in the git-ignored config to
enable searches; opening destinations does not search. Existing legacy
`Pictures/` gallery caches remain readable. The top banner prefers a matching
curated desktop photo, then a credited gallery photo, then the typography
fallback. See `PROPOSAL_PICTURES.md` for provider/rights and cache details.

## Tests, analyze, build

```powershell
cd mobile
& "C:\src\flutter\bin\flutter.bat" pub get
& "C:\src\flutter\bin\flutter.bat" analyze   # must be clean
& "C:\src\flutter\bin\flutter.bat" test      # 430 tests, no credentials
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
                         world map, open tabs, settings, nav icons,
                         theme, charts
  lib/data/              repositories: destinations, trips, benefits,
                         weekend, geocode, flight routes, catalogue match,
                         open tabs, app settings
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
  **Retired 2026-10-16:** these rows stay as they are — a frozen quirk of
  the migrated workbook; no regeneration is planned.
* The weekend finder fetches flights from Fraport's own JSON endpoint
  (verified 2026-10-07). Bad board windows exist (2026-10-25 arrivals held
  one flight where sibling days hold 233–366) — the finder now warns on
  thin/failed windows and logs every incident, instead of silently
  returning fewer results. An optional second source (FlightAware AeroAPI,
  `flightaware_api_key` in the config) is consulted only for those bad
  windows; without a key nothing changes. Board fixtures cover the tests —
  no network per run.
* Everything that goes wrong at runtime lands in **`error_log.jsonl`**
  (per-device, next to `app_settings.json`): search/provider failures,
  implausible board windows, unknown airport/station codes, uncaught
  errors. ⚙ Settings → Error log shows and clears it.
