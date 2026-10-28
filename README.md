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
> [`archive/docs/NATIVE_HTML_PLAN.md`](archive/docs/NATIVE_HTML_PLAN.md).

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
for the user-triggered destination gallery. The FlightRoutes token is the
sibling project's own read-write credential (the Finder reads complete boards
and writes complete full-day boards back — README "Shared FlightRoutes
departure boards"); never reuse the destinations database token.

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

**The fly-to search** (`ui/fly_to_field.dart`) offers the plotted cities
and the countries holding them as you type, and every pick is an *event*:
open a city, come back, tap the same suggestion again and it opens again.
It is deliberately not Flutter's `Autocomplete`, whose `_select` drops a
pick that equals its last selection — the search is a command, not a value
(the report, 2026-10-28: "tried clicking on it again, but nothing
happened"). The query stays in the field after a pick, so the list reopens
on the next tap; the ✕ empties it, and the keyboard's search key picks the
exact match.

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

**Tapping a month on either chart** (`ui/climate_chart.dart`,
`ui/aqi_chart.dart`) answers three ways at once, because on a phone one
small grey line was too easy to miss (the report, 2026-10-28: "I
initially thought the feature wasn't working"): the column gets a
highlight band, its label turns bold in the accent colour and its dots
are ringed, and a filled readout card below names the month and its
figures (one labelled row per series, each with the series' colour). A
month with no value shows an em dash, never a zero. Before the first tap
the chart says *"Tap a month to see its values."* — the affordance is
stated rather than discovered. The tap is a haptic click on a phone, and
the month under the finger is computed in `models/month_axis.dart` (one
rule for both charts; a tap on the axis strip is not a month).

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

**Offline reads** (Phase 5, Option A — `archive/docs/OFFLINE_SYNC_PLAN.md`): the catalogue
and the trips are snapshotted on every successful full read into the
per-device `state_dir` (`offline_snapshot/`). When the live read fails — no
network, no token — those snapshots answer instead, with a note that says so
and shows the snapshot's save time; a one-row read never writes a snapshot,
and a missing or corrupt snapshot file leaves the plain failure message in
place. Writes still return `false` offline (the write journal is the next
strand).

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
2026-10-09: 597 rows, 7 qualifying (CX, JL, KC, LH, VL, VN, ZH). The reader
lives in `mobile/lib/data/benefits_repository.dart` (the archived
`archive/streamlit/benefits_turso.py` is the Python original); the full
contract, with its history, is `archive/docs/TURSO_PLAN.md`.

**The semantics that must not drift:**

* **Any `yes` qualifies** — "at least one of the three" is the rule.
* `no`, `unknown`, `NULL` and empty **do not**. `unknown` is not a yes.
* **An empty read is a failure**, not "nobody qualifies": an empty flag map
  would remove every destination from the finder with no visible cause, so it
  is reported as a problem and the reader falls through.
* Airlines are registered under **both** the IATA code and the canonical name,
  so a flight resolves whichever spelling the source gives.
* Column names are matched with `_`/space/case ignored, so a cosmetic rename
  upstream does not break the read.
* The token is never logged, printed or committed.

**The ladder is Turso → offline snapshot → the built-in seed list.** The
snapshot is the table as last read (`offline_benefits.json`, written on every
full read); it answers a *transport* failure, so the finder's airline filter
keeps working with no network — and keeps the real table's answer, not the
24-carrier default, which would qualify carriers the database says are
`unknown`. An **empty** table is a different signal and is not answered from
the snapshot; it falls back to the seed list and says so. Offline the finder
still has no *flight boards* (every board source needs the network), so a
search reports that instead of inventing results.

**Every failure is a reported problem, never an exception:**

| Failure | Behaviour |
|---|---|
| no token / not configured | the seed list, and the reason |
| 401 / 403 | the seed list, naming the likely cause (a bad token) |
| 5xx or timeout | the seed list, the error class named, never retried |
| `{"type": "error"}` in a 200 | the seed list, quoting the server's message |
| table/column missing | the seed list, listing what was expected vs found |
| empty result set | **treated as a failure**, never as "no airlines qualify" |

## The weekend finder

The finder answers *"where can I fly from Frankfurt for the weekend?"*: it
takes an outbound window and a return window, searches the FRA departure and
arrival boards, and lists every reachable city.

**The days.** The user picks a travel **period** (a range picker with "this
weekend" / "next weekend" presets), which produces the candidate days. Each
day is then "out on" or "back on", and each selected day carries one rule —
any time, **departs after** HH:MM (out) or **lands before** HH:MM (back). The
presets keep the classic rules: out **Friday ≥ 14:00** or **Saturday
< 12:00**; back **Saturday ≥ 12:00**, **Sunday any time** or **Monday
< 09:00**. All times are Europe/Berlin.

Day arithmetic is **calendar** arithmetic (`addCalendarDays` in
`models/travel_days.dart`), never `DateTime.add(Duration(days: n))`: the
latter adds absolute time, so across a DST change the clock shifts an hour and
a date comes out a day early (2026-10-21: "next weekend" in the DST week
landed on a Thursday at 23:00, which no day chip could match — the day looked
unselected, its rule row stayed, and the search still used it). Changing the
selection **re-runs the search**, because an answer drawn for the old
selection must not stay on screen under new chips.

**What the boards may cost.** Fraport is free and unlimited, so it is asked
every time and never cached or shared. The credentialed fallbacks
(AeroDataBox, AirLabs) have request caps, so the finder asks them **only for
days it does not already have**: a per-device cache
(`<state_dir>/board_cache`, keyed by day, direction *and* window — a changed
time rule must not read the old window's flights) answers a repeated search, a
truncated walk is never cached, and the share to the shared board cache reads
that cache before spending the credential again. AeroDataBox and AirLabs charge
per call, not per hour, so asking for the whole day costs what one window did
and covers every window of that day; AeroAPI (`max_pages: 1`) answers a
**page**, not a day, so it is asked for the window only and is never
shared — writing a page as a whole-day board would tell the sibling's readers
that a short board is the day.

**The matcher rules that matter** (the ports kept them rule for rule):

* **Both legs must qualify** — a city reachable from FRA by a benefit airline
  only one way is *excluded*, but shown in a collapsed "one way only" section
  so the near miss is visible rather than hidden.
* The **operating carrier** governs the benefits check (staff standby rides on
  the operator, not the marketing one); codeshare duplicates collapse to one
  flight, shown as `LH 400 (Lufthansa, operated by …)` when they differ.
* One result row per **city**; multi-airport cities (London, Paris, Milan …)
  are merged. Each row expands into its viable (out, back) pairs.
* **Overnight flights** (arriving the next day), **DST** and live delays are
  handled: the rules use *scheduled* times, and delays are shown, not filtered.
* A **Saturday out and Saturday back** day trip is kept (it was wanted
  explicitly) — the return must land ≥ 12:00, so there is time on the
  ground.
* An airport the city table does not know is listed under "unmapped" with the
  board's own name for it, never a `?CODE` placeholder.
* The ranking is earliest departure first, then fewest nights, then the name;
  at most two ways home per outbound.

**The airline filter is one card.** The scope (Lufthansa Group / all
Lufthansa-named / every airline with benefits / all), the benefits answer and
the per-flight limit sit together, because they are the same question. The
Lufthansa Group's eleven carriers do not fit under the control, so the card
says "Only the Lufthansa Group carriers." with a **?** beside it — hovering on
the desktop, tapping on a phone, shows them. The list is one table
(`lufthansaGroupCarriers` in `models/airline_benefits.dart`) read by the
membership test *and* the **?**, with a test that pins the two together: a
caption naming a different set than the code filters on is a lie the reader
cannot see.

**When the boards are bad, the finder says so.** A board window that failed or
looks implausibly thin is a **visible note** with a warning icon, not a
shorter answer; the report says how many outbound and return flights were
actually read, so "nothing found" and "nothing read" never look the same. The
incidents are also logged to the per-device error log (⚙ Settings → Error log).
The full rule book, with its history, is `archive/docs/WEEKEND_FINDER_PLAN.md`.

## Shared FlightRoutes departure boards

The Finder reads *and writes* exact-day, full-day **schema-v2** departure
boards in the FlightRoutes Turso database (`schedule_boards`). FlightRoutes
remains the producer for its own AeroDataBox/AirLabs boards; Travel Planner
reads complete boards for outbound (FRA) and, for suspicious return windows,
candidate-airport days. The reader rejects legacy v1, partial AirLabs, corrupt,
and timestamp-incomplete rows; those fall back to the existing
Fraport/FlightAware path. It applies flight-day rules using airport-local
timestamps and duration caps using UTC timestamps. A departure-stamped board
without trustworthy arrival stamps (Fraport-sourced) still answers outbound
queries; its flights carry no leg duration, like live Fraport flights.

Travel Planner also feeds boards **back**, but only the ones that *cost* a
credential: after a Finder search, each out day the **fallback** answered for
gets a v2 board write in FlightRoutes' own format (`utils/sync.py` upserts —
the remote board's stamp is read first and a write is only sent when this
fetch is newer, with the conditional `updated_at` comparison kept in the SQL
as race insurance) plus its `schedule_provenance` row, labelled with the
fallback's own name (`aerodatabox`, `airlabs`). The **Fraport** board is never
written: it is free and unlimited, so it can always be re-grabbed and there is
no reason to spend Turso space on it (the user's decision, 2026-10-21; the
four `fraport` rows written under the old rule were deleted the same day). Only
genuinely complete whole-day fetches are written — a windowed or truncated
fetch never masquerades as a full day, and a zero-flight answer is never
cached. FRA *arrivals* are not written: the shared schema is
departures-boards only. Sharing runs after the results are shown, and the
skip/failure reasons land in the ErrorLog. The write path was verified against
the live remote with a zero-mutation probe (`BEGIN` → upsert → `SELECT` →
`ROLLBACK` → `SELECT`: accepted, no rows remain, 2026-10-18).

`flight_routes_url` and `flight_routes_token` point at the sibling database
(the same one hosting the `airlines` benefits table — separate credentials,
never the destinations database). The token ships in the app bundle like the
other credentials (the user's 2026-10-08 decision); the current one is the
sibling's read-write token, copied per the user's request, so the write-back
works out of the box. Leaks are revocable in the Turso console; for a wider
distribution, mint a narrower token. No credentials are committed.

If shared DB settings are missing or unreadable, the Finder still uses its
existing providers and reports the read problem; nothing is shared.

### What a result line says

Each result city shows its facts on their own lines, so a phone can read them
all:

```
Malaga (Spain)
4 options · earliest out Sat 09:20 · 1🛏
latest return Sunday 19:00 (takeoff) or Monday 08:00 (landing)
```

The *latest Sunday return* is its **takeoff** — the moment you have to leave
the far end — and the *earliest Monday return* is its **landing** in
Frankfurt; a Monday morning landing is what turns the weekend into a
three-day one. When a city has neither (its only return is a Saturday one),
the latest return is named under its own day rather than left out. The lines
**wrap** instead of being cut: an ellipsised "earliest out Sat 09:20 · 1 n…"
says nothing (the phone screenshot, 2026-10-20). The logic is pure and lives
in `lib/models/weekend_match.dart` (`citySummary`, `cityDepartureSummary`,
`cityReturnSummary`).

Tapping a result expands it into the option tiles: one tile per way, each
with the outbound and the return leg.

## Destination photos

The detail gallery offers user-initiated Unsplash search and per-photo replace.
It hotlinks the official API's image URLs and stores attributed metadata only in
per-device app storage. Set `unsplash_access_key` in the git-ignored config to
enable searches; opening destinations does not search. Existing legacy
`Pictures/` gallery caches remain readable. The top banner prefers a matching
curated desktop photo, then a credited gallery photo, then the typography
fallback. See [`archive/docs/PROPOSAL_PICTURES.md`](archive/docs/PROPOSAL_PICTURES.md)
for provider/rights and cache details.

## The open-destination drawer

The catalogue, the map and the finder can all open a destination's detail page.
Opening a page does **not** add the destination to the drawer: the detail page
carries an **"Add to drawer"** button, and only that button adds it. A
destination that is already in the drawer shows **"Shown on the drawer"** on a
different background, and the button is inert — the drawer is the one list of
"places I am looking at", so it must never grow by accident (the user's
2026-10-20 request).

The drawer is the floating button at the bottom right (desktop) or the chip
strip (phone); it lists the open destinations, and each one can be closed
again. The list is stored in Turso (`open_tabs`) and mirrored in the offline
snapshot, so it survives a restart and works on a train. ⚙ Settings has the
on/off switch: with the feature off, the button and the drawer are gone and
the detail page offers no "Add to drawer".

## Offline-first (Phase 5, Option A)

The Turso pipeline is HTTP-only, so with no network every read fails and
every write returns false. That stays honest — a failed read is a *stated*
failure — but the app now also works on a train:

* **Snapshot reads.** Every successful *full* read of the catalogue, the
  trips, the open-tab list and the airline-benefits table is saved to
  `<state dir>/offline_snapshot/offline_<dataset>.json`. When a live read
  fails, the snapshot answers, labelled with its save time and the reason
  the live read failed ("offline: the live read failed (…); showing the
  destination catalogue snapshot from 2026-10-18 21:14"). A missing or
  corrupt snapshot is *no snapshot*: the original failure surfaces exactly
  as before. Only full reads write snapshots — a one-row read never
  overwrites a dataset with a fragment.
* **Write journal.** A write that fails for *transport* reasons (no
  connection, 5xx, a captive portal) is queued in
  `<state dir>/write_journal/pending.jsonl` — the exact SQL the repository
  would have sent, with its last-write-wins guard baked in. A rejected
  token (401/403) or a statement error is never queued: retrying those
  would hide a real problem. A newer write for the same value supersedes an
  older one; the queue is capped at 500 ops.
* **Drain.** The queue replays on app start after the first successful
  read, after any successful write, and from **Sync now** in settings or
  the sync line. Sequential, in order. A transport failure stops the drain
  and keeps the rest queued; a statement error drops the op (logged); a
  refused guard — a trip whose `updated_at` moved underneath — moves the
  op to `write_journal/conflicts.jsonl` and is never auto-retried.
* **What the user sees.** A thin bar above the content when there are owed
  writes ("2 changes waiting to sync — Sync now") or a change that could
  not sync. A queued write never looks saved: `saveTrip` reports `queued`,
  and the pages say so.

Nothing here polls. There is no connectivity event on an HTTP client, so a
successful request is the signal that the database is reachable again.

**What the offline mode deliberately does not do** (the plan that specified it
is archived in `archive/docs/OFFLINE_SYNC_PLAN.md`):

* **The journal is not a local write-through cache.** A queued edit is *owed*,
  not *shown*: after a restart without a network the catalogue and the trips
  come from the snapshot, which still holds the pre-edit value, until a drain
  applies the queue. Doing this properly means applying the queued ops to the
  snapshot as they are enqueued — worth a commit of its own, and worth doing
  for trips and destinations together rather than for one of them.
* **Conflicts are recorded, not resolved.** They are counted, named in the sync
  line and kept in `conflicts.jsonl` with their statements; choosing "keep
  mine" or "keep theirs" is a product decision, not a bug fix.
* **A partial batch cannot be repaired.** If a variant/stop/leg batch dies
  mid-way, the op is surfaced as failed and is not queued (the trip row
  already landed). Recovery is the user's: reload, then re-save.
* **Derived caches stay online-only** (geocode, flight boards, AQI): they are
  per-device files with their own rules, and the benefits and FlightRoutes
  databases are read-only.

## Release build and signing (Android)

```powershell
cd mobile
& "C:\src\flutter\bin\flutter.bat" build apk --release
```

Without a keystore the release build is **debug-signed** — that is the
long-standing default, kept so a fresh clone can still run. To sign for
real, create the key **once** and wire it in:

```powershell
keytool -genkey -v -keystore C:\path\to\travel-planner.jks -keyalg RSA `
        -keysize 2048 -validity 10000 -alias travel-planner
copy mobile\android\key.properties.example mobile\android\key.properties
# then fill in the four values in key.properties
```

`key.properties` and the keystore are git-ignored — commit neither. Do this
before the first release install on a device: Android refuses to upgrade an
app whose signing key changed, and the offline snapshot plus the write
journal live in the app's state dir, so a late key change costs that device
its offline copy. `applicationId` is still the Flutter default
(`com.example.travel_planner`); changing it is a separate, one-way decision.

## Tests, analyze, build

```powershell
cd mobile
& "C:\src\flutter\bin\flutter.bat" pub get
& "C:\src\flutter\bin\flutter.bat" analyze   # must be clean
& "C:\src\flutter\bin\flutter.bat" test      # 844 tests, no credentials
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
