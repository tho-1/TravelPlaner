# Shared FlightRoutes departure boards (item k)

**Implemented and locally configured; live remote verification remains pending.**
The adapter, schema-v2 timestamp fields, and fake-client regression tests are in
place. Per the user's request, the FlightRoutes endpoint/token were copied only
to the git-ignored app config; no credential values are in tracked source and
no remote data was modified.

Travel Planner uses the FlightRoutes database as a **read-only cache**. The
FlightRoutes app remains the producer and continues writing through its existing
`schedule_boards` / `schedule_provenance` sync. This is deliberate: the Finder's
Fraport queries are filtered windows, not complete airport/day boards, so writing
them as full schedules would poison the shared cache. No parallel
`flight_schedules` or `airports` table was added.

The FlightRoutes URL is distinct from both Travel Planner databases: `travel-tz123`
stores destinations/trips/open tabs and `flightconnections-tz123` stores airline
benefits. The FlightRoutes schedule endpoint must therefore be supplied
separately in the git-ignored `mobile/assets/turso_config.json` using
`flight_routes_url` and a **read-only** `flight_routes_token`. The checked-in
example contains placeholders. The implementation safely falls back to the
Fraport/FlightAware path when these settings are absent or the shared read fails.

## Verified existing contract

The relational Turso schema is unchanged because the board table stores JSON;
`utils/schema.sql` still defines the shared contract:

- `schedule_boards(iata, day, payload, updated_at)`, primary key `(iata, day)`.
  The payload is JSON shaped as `{meta, flights}`.
- `schedule_provenance(key, source, obtained_at, n_flights, updated_at)`, with
  `key` shaped as `IATA|YYYY-MM-DD`.
- `airlines` is the benefits table; it is not a schedule table.

The Python and mobile FlightRoutes writers now emit **payload schema v2**:
`meta.schema_version = 2`, plus each flight's airport-local and UTC timestamps
(`dep_at_local`, `arr_at_local`, `dep_at_utc`, `arr_at_utc`). Existing display
fields `dep_time` / `arr_time` stay unchanged, and v1 readers ignore the additive
fields. The PC and mobile schedule loaders continue to sync the same rows with
row-level `updated_at`.

AirLabs remains a partial same-day source and is rejected by the Travel Planner
cache reader. It never means that a missing departure is “no flight.” Legacy v1
boards are also ignored by the new reader until refreshed by FlightRoutes.

## Implemented data flow

1. FlightRoutes writes its fetched AeroDataBox boards to Turso using its
   existing PC/mobile sync. Travel Planner has separate optional
   `flight_routes_url` and `flight_routes_token` settings; use a least-privilege,
   read-only token there. Do not reuse/copy AeroDataBox or AirLabs API keys.
2. `FlightRoutesScheduleRepository` reads only exact-day rows and validates the
   row key, payload key, v2 schema, counts, and timestamps. Empty query results
   are cache misses; database errors and corrupt rows stay distinguishable and
   visible. SQL filters are built only from validated airport codes/dates.
3. Outbound legs use a complete FRA departure board for that exact date when
   available; otherwise the existing Fraport provider runs. Return legs retain
   the existing FRA-arrival source and use the shared origin-airport boards
   only to fill suspicious/empty windows, checking both the landing date and
   prior local date for overnight flights.
4. The matcher uses airport-local timestamps for day/time rules and the UTC
   timestamps for the max-leg-duration calculation, avoiding DST errors.
   Partial, v1, malformed, or timestamp-incomplete boards fall back to the
   existing provider. Travel Planner **does not write** Fraport result windows
   into `schedule_boards`, because they are not complete airport-day datasets.
5. Provider API keys remain in FlightRoutes' own local settings. The shared
   database contains schedule payloads/provenance only; both apps reuse the
   FlightRoutes-produced data rather than spending duplicate API calls.

## Provider reuse and limits

- **AeroDataBox** is the sibling app's primary arbitrary-date departure source
  and the best shared-board candidate. Preserve the RapidAPI source label and
  its current request-unit/rate limits.
- **AirLabs** is a same-day live-queue fallback with partial coverage only. Keep
  its coverage metadata and never use it as a full-day “no flights” answer or a
  seasonal proxy.
- **Kiwi Tequila** is present but signup is partner-gated; do not make it a
  prerequisite.
- Travel Planner already has Fraport plus an optional FlightAware AeroAPI
  fallback. They are separate providers with different payloads/keys; add an
  explicit normalizer only if terms and coverage are verified. The sibling's
  static route dataset is not a departure schedule and should not be put in
  `schedule_boards`.

API credentials stay in each app's existing local secret/settings mechanism;
Turso stores normalized schedule data and provenance only. The database should
not become a key-sharing mechanism.

## Configuration and verification

- Add the FlightRoutes DB URL and a **read-only** Turso token to the local,
  git-ignored `mobile/assets/turso_config.json` as `flight_routes_url` and
  `flight_routes_token`. The checked-in `mobile/assets/turso_config.example.json`
  documents these keys without credential values.
- The FlightRoutes URL/token are now present in the git-ignored local config,
  copied from the sibling app as requested. The token's scope is not confirmed;
  Travel Planner only issues `SELECT`s, but the same credential may permit
  writes. Replace it with a dedicated read-only token before distributing the
  app. The live remote schema was not queried. If shared reads fail, the Finder
  logs a note and continues through Fraport/FlightAware.
- Fake-client tests cover the v2 format, v1/partial rejection, empty vs failed
  reads, bad rows/dates/codes, overnight return lookup, and local-vs-UTC duration.
  FlightRoutes' Dart and Python tests verify timestamp persistence and v1
  compatibility without network or real credentials.
