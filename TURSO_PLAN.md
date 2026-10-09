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
| Local copy | `flightroutes-app/data/flightroutes.db` — same table, same rows |
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

`airline_benefits.load_benefit_flags()` now resolves:

1. **Turso** — the source of truth.
2. the workbook's `Airline Benefits` sheet — the mirror; the only source on
   Streamlit Cloud if the token is not in `secrets.toml`.
3. `airlines_benefits.xlsx` — **legacy, read only when Turso is not configured
   at all**, so a machine that has not set up the database yet keeps working.
   Configure Turso and the Excel file is never opened again.
4. the built-in seed list — last resort.

Every failure (no token, 401/403, 5xx, timeout, `error` result, missing table,
empty table) is caught and turned into a readable problem string. None of them
raises. `load_benefit_flags` additionally wraps the Turso call so even a bug in
this module cannot take the page down.

## Configuration

| Variable | Meaning | Default |
|---|---|---|
| `TURSO_DATABASE_URL` | database host | the `flightconnections-tz123` host above |
| `TURSO_AUTH_TOKEN` | read-only bearer token | none; set in `.streamlit/secrets.toml`, live source verified 2026-10-09 |
| `TURSO_AIRLINE_TABLE` | table name | `airlines` |
| `TRAVEL_PLANNER_FLIGHTROUTES_DB` | local `.db` used offline, when the remote is unavailable | unset |

`TURSO_TABLE`/`TRAVEL_PLANNER_AIRLINE_BENEFITS` still exist but only matter on a
machine that has not switched over.

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

`tests/test_benefits_turso.py`, 50 tests, no network and no credentials:

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
  local fallback genuinely engages — both added after a one-letter typo made the
  offline path silently unreachable.

## Remaining

1. **Confirm the Excel file can be retired.** It is currently still the fallback
   for unconfigured machines. Say the word and I will remove it and the
   `TRAVEL_PLANNER_AIRLINE_BENEFITS` handling with it.
2. Optional: point `TRAVEL_PLANNER_FLIGHTROUTES_DB` at the local
   `flightroutes.db` so the finder keeps working with no network at all.

Done 2026-10-09: the token is in `.streamlit/secrets.toml` and the live
source returns 597 rows / 7 qualifying (CX, JL, KC, LH, VL, VN, ZH). Two
gotchas worth remembering: the token's `kid` is `Vl1L5Ew…` (base64
`Vmwx`, not `VlYx` — a one-character slip 401s the whole source), and
`fetch_remote` must normalise the API's `{type, value}` cells or every
benefit column reads as "unknown".

Verify with `python benefits_turso.py`, which prints the source, the count and
the qualifying carriers.
