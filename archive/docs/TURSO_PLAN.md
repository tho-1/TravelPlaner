# Airline benefits from Turso — access contract and status

**Decision (2026-10-07):** the benefits live in a Turso (libSQL) database, not in
`airlines_benefits.xlsx`. `benefits_turso.py` is implemented and wired in as the
primary source. What is left is one thing: a token.

## The contract (from the other project, then verified here)

| | |
|---|---|
| Remote | `https://flightconnections-tz123.aws-eu-north-1.turso.io` |
| Table | `airlines` |
| Columns | `iata, name, discount_eligible, business_class, confirmed_booking, comments, updated_at` |
| Values | lowercase `yes` / `no` / `unknown` |
| Auth | `Authorization: Bearer <token>` |
| Local copy | the sibling's `flightroutes-app/data/flightroutes.db` (Python era); the app's own copy is the offline snapshot `offline_benefits.json` |
| Write rule | a writer **must** set `updated_at` (UTC ISO) so last-write-wins holds |

### Verified, not assumed

* The local `flightroutes.db` was opened read-only and inspected: **597** rows,
  columns exactly as listed, `discount_eligible` 7 yes / 590 unknown,
  `business_class` 4 yes, `confirmed_booking` 2 yes, `updated_at` populated on
  all 597. The 7 qualifying carriers are CX, JL, KC, LH, VL, VN, ZH — the same
  set the Excel file produced.
* The remote host answers: `/health` → 200, `/v2/pipeline` with no token → 401
  (`empty JWT token`), with a dummy token → 400 (`JWT error: InvalidToken`). So
  the URL and the auth path are right; only a real token is missing.

## Transport: raw HTTP, no new dependency

Turso's SQL-over-HTTP pipeline API, documented and stable, and this project needs
exactly one read query — so no reason to add a native driver to `requirements.txt`:

```
POST <host>/v2/pipeline
Authorization: Bearer <token>
{"requests": [{"type": "execute", "stmt": {"sql": "SELECT * FROM airlines"}},
              {"type": "close"}]}
```

Two details that matter:

* **An error arrives as `{"type": "error"}` inside a 200 response.** HTTP status
  alone does not say whether the query worked, so the reader checks the body.
* **`close` must be sent last**, or the server holds the connection until it
  times out.

Tests use stdlib `sqlite3` against a temporary file built to this exact schema,
which exercises the real SQL text and the real column names without a network
call or a credential.

## Semantics that must not drift

* **Any `yes` qualifies** — the user's rule is "at least one of the three".
* `no`, `unknown`, `NULL` and empty **do not**. An unverified airline is not one
  you can book on, and treating `unknown` as a yes would silently widen the
  finder's results.
* **An empty read is a failure, not "nobody qualifies".** An empty flag map would
  remove every destination from the finder with no visible cause, so it is
  reported as a problem and the resolver falls through.
* Airlines are registered under **both** the IATA code and the canonical name, so
  a flight resolves whichever spelling the source gives.
* Column names are matched with `_`/space/case ignored, so a cosmetic rename
  upstream does not break the read.
* The token is read from the environment, never logged, printed, or committed.
  The cache key stores a 12-character SHA-256 **fingerprint**, not the token.

## Fallback ladder

**The app (the only live app) reads Turso -> offline snapshot -> the built-in
seed list.** The Python ladder below was longer because the legacy app could
still open a workbook; the Flutter app has no workbook and no Excel file, and
the Excel rung is retired (see "Remaining").

| Rung | What it is | When it is used |
|---|---|---|
| 1. **Turso** | the source of truth | whenever the read works |
| 2. **Offline snapshot** | the table as last read, in `<state dir>/offline_snapshot/offline_benefits.json` | the live read failed for *transport* reasons (no network, 5xx) — the answer is labelled "offline snapshot from …" |
| 3. **The built-in seed list** | 24 documented default carriers | the table is empty, the schema is unreadable, or the device has no snapshot |

The distinction between rungs 2 and 3 is deliberate. A **transport** failure
is the network's problem, and the stored copy of the table answers it. An
**empty table** is a signal (something emptied it), and answering from the
snapshot would hide that — so it keeps the seed list and says so. The seed
list is also wider than the live answer (24 carriers against the 7 that
qualify), which is exactly why the snapshot, not the seed list, is rung 2:
offline the finder must use the *real* table, because qualifying a carrier
the database says is `unknown` breaks the "unknown is never a yes" rule.

The Python ladder, for the record: Turso -> the workbook's `Airline Benefits`
sheet -> `airlines_benefits.xlsx` (legacy) -> the seed list.

Every failure (no token, 401/403, 5xx, timeout, `error` result, missing table,
empty table) is caught and turned into a readable problem string. None of them
raises. The reader additionally wraps the Turso call so even a bug in the
module cannot take the page down.

## Configuration

| Variable | Meaning | Default |
|---|---|---|
| `benefitsUrl` | the benefits database host (in `mobile/assets/turso_config.json`) | the `flightconnections-tz123` host above |
| `benefitsToken` | read-only bearer token | none; the bundled one is the sibling's token |
| the table name | configuration, not user input | `airlines` |
| the offline copy | `<state dir>/offline_snapshot/offline_benefits.json` | written on every full read |

The Python-era environment variables (`TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN`,
`TURSO_AIRLINE_TABLE`, `TRAVEL_PLANNER_FLIGHTROUTES_DB`, `TURSO_TABLE`,
`TRAVEL_PLANNER_AIRLINE_BENEFITS`) belong to the archived app and are not read
by the Flutter one.

## Caching

In-process, keyed on URL + table + token fingerprint + local-db path, TTL
**1 hour**. The data changes when the user edits it, which is rare, and this is a
600-row read — an hour means a page rerun never touches the network. Changing the
token busts the cache immediately, because a different token may address a
different database.

## Failure handling

| Failure | Behaviour |
|---|---|
| no token | skip Turso, use the Excel file or workbook mirror, say so |
| 401 / 403 | fall through, naming the likely cause |
| 5xx or timeout (5 s) | fall through, error class named, never retried |
| `{"type": "error"}` in a 200 | fall through, quoting the server's message |
| table/column missing | fall through, listing what was expected vs found |
| empty result set | **treated as a failure**, never as "no airlines qualify" |

## Tests

`tests/test_benefits_turso.py` (50 tests, Python era) and the app's
`test/airline_benefits_test.dart` — no network and no credentials:

* value semantics, parametrised — specifically that `unknown` is **not** a yes;
* schema drift: lower case, `Discount Eligible` with a space, missing `name`;
* duplicate codes, blank codes, short rows;
* the full remote path via a monkeypatched `requests.post`, asserting the URL,
  the `Bearer` header, the `close` sentinel and the SQL text;
* every failure mode above returns problems and an empty result, never raises;
* an empty table is rejected rather than accepted;
* the local SQLite path against the real schema;
* the ladder: Turso wins over Excel, Excel still works when Turso is unset, a
  broken Turso falls through without raising;
* the cache: one request for two calls, and a changed token busting it;
* the env-var spelling (`TRAVEL_PLANNER_…`, not `TRAVEL_PLANER_…`) and that the
  local fallback genuinely engages — both added after a one-letter typo made
  the offline path silently unreachable.

In the app (Dart), `test/airline_benefits_test.dart` covers the same rules
plus the offline snapshot: a full read fills it, a transport failure answers
from it *labelled*, an empty table does **not** answer from it, and a device
without a snapshot falls back to the seed list.

## Remaining

**Nothing.** Both items are closed (2026-10-20):

1. ~~**Confirm the Excel file can be retired.**~~ **Retired.** The live app
   never had the Excel rung: it reads Turso, and the only other source is the
   built-in seed list. The `airlines_benefits.xlsx` handling and the
   `TRAVEL_PLANNER_AIRLINE_BENEFITS` variable survive only in
   `archive/streamlit/airline_benefits.py` — frozen legacy code, kept for the
   legacy fall-back, not read by anything that runs.
2. ~~**Point `TRAVEL_PLANNER_FLIGHTROUTES_DB` at the local `flightroutes.db`
   so the finder keeps working with no network at all.**~~ **Done, in the app's
   own way.** The Dart equivalent of the local `.db` is the offline snapshot
   (`offline_benefits.json`), because reading SQLite in the app would mean a
   native driver — against the "no new dependency" rule and awkward on
   Android. The snapshot is written on every full read and answers a
   transport failure with the *real* table, so the finder's airline filter
   keeps working offline **and** keeps the "unknown is never a yes" rule,
   which the seed list alone would break (24 default carriers against the 7
   that really qualify).

   What this does *not* give: offline the finder still has no **flight
   boards** — Fraport, the shared boards and the optional APIs all need the
   network. A search without a network therefore reports "no board could be
   read" rather than inventing results. That is the honest answer, and it is
   the same shape as the "no results" note the finder already prints.

Done 2026-10-09: the token is in `.streamlit/secrets.toml` and the live
source returns 597 rows / 7 qualifying (CX, JL, KC, LH, VL, VN, ZH). Two
gotchas worth remembering: the token's `kid` is `Vl1L5Ew…` (base64
`Vmwx`, not `VlYx` — a one-character slip 401s the whole source), and
`fetch_remote` must normalise the API's `{type, value}` cells or every
benefit column reads as "unknown".

Verify with `python benefits_turso.py`, which prints the source, the count and
the qualifying carriers.
