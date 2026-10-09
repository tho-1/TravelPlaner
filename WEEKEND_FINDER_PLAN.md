# Weekend Trip Finder — build plan (2026-10-05)

## What it does

A new page, **Weekend finder**, that answers: *"Where can I fly from Frankfurt
for the weekend?"* It takes an outbound window and a return window, searches
outbound FRA departures and matching returns, and lists every reachable city as
`City (Country)`, grouped with catalogue hits linked to their destination pages.

## Decisions (from user answers 2026-10-05)

| # | Decision |
|---|---|
| 1 | Data: **both** — live Fraport board for the upcoming weekend, timetable-site scrape as fallback / for any Friday date |
| 2 | Benefit model: **single flag per airline** ("has staff benefits"); a new `Airline Benefits` workbook sheet the user ticks off |
| 3 | Timetable source: **scrape timetable sites** (accepted: brittle + ToS-grey, see risks) |
| 4 | Times: **Fri out after 14:00, Sat out before 12:00**; return **Sat landing after 12:00, Sun anytime, Mon landing before 09:00** — all adjustable in the UI |
| 5 | Flights: **direct + benefit airline both ways** |
| 6 | Scope: **all served cities**, catalogue matches linked; multi-airport cities merged (London, Paris, Milan, …) |
| 7 | Mapping: **static airport→city→country table** in the repo (OurAirports/IATA seed) |

Exact filter rules:

- **Outbound** (direct FRA→X, benefit airline): departs **Friday ≥ 14:00** OR **Saturday < 12:00**.
- **Return** (direct X→FRA, benefit airline): lands **Saturday ≥ 12:00** OR **Sunday (any time)** OR **Monday < 09:00**.
- One result row per **city**; each row expands to its viable (out, back) flight pairs.
- Times are Europe/Berlin; all six bounds are UI inputs with the defaults above.

## STATUS 2026-10-08: complete — Fraport provider implemented and tested

All seven steps are done and tested. Step 4 (the Fraport board provider) was
implemented on 2026-10-07 after the endpoint was verified; `csv` upload stays
as the fallback/escape hatch that keeps the page usable with no network.

| Step | State |
|---|---|
| 1. Airport -> city -> country | **done** — `airport_city.py` + `data/airports.csv` (4568 airports) |
| 2. Airline Benefits | **done, reads your real file** — `airline_benefits.py` imports `airlines_benefits.xlsx` and mirrors it into the workbook |
| 3. Matcher | **done** — `weekend_match.py`, 37 tests |
| 4. Frapart board | **done, implemented** — `FraportBoardProvider` in `timetable.py` |
| 5. Timetable scrape | **not needed** — the Fraport endpoint answers any date |
| 6. Page | **done** — `pages/weekend_finder.py`, defaults to the live provider, CSV upload as optional override |
| 7. Docs/CI | **done** |

### Fraport endpoint (verified 2026-10-07 — and my earlier "blocked" was wrong)

I previously concluded Fraport could not be scraped. **That was a mistake**, and
the cause is worth recording: I inspected only the *rendered HTML* (which really
does contain zero flight rows) and then *guessed* endpoint paths under `/api`.
The endpoint is not under `/api` at all — it is advertised in the page's own
markup. Reading `data-*` attributes first would have found it immediately.

**The homepage I read:**

| | |
|---|---|
| Departures page | `https://www.frankfurt-airport.com/en/flights-and-transfer/departures.html` |
| Arrivals page | `https://www.frankfurt-airport.com/en/flights-and-transfer/arrivals.html` |
| JSON endpoint | `https://www.frankfurt-airport.com/en/_jcr_content.flights.json/filter` |
| Where it comes from | a `data-api-url` attribute on the board component in that page's markup |
| German locale | `https://www.frankfurt-airport.com/de/_jcr_content.flights.json/filter` (also works) |

Evidence: both pages return **HTTP 200, ~122 KB**, containing **0** flight
numbers and 3 layout `<tr>`s — which is why the HTML looks empty. The same pages
contain `<fra-m-flights-search … data-api-url="…/_jcr_content.flights.json/filter">`.

**Request shape** (recovered from the site's own JS: `requestData()` builds
`{perpage, lang, page, ...formData}` and the search form's `formData` is
`{flighttype, q, time, key, type}`):

```
GET …/en/_jcr_content.flights.json/filter
      ?flighttype=departures|arrivals
      &time=2026-10-09T00:00:00+02:00      # full ISO datetime WITH tz offset
      &perpage=50                          # server caps at 50
      &page=1..N
      &lang=en
```

* **`time` is a full ISO datetime with a timezone offset.** `?date=2026-10-09`,
  `?time=2026-10-09` and `?time=09.10.2026` are all silently **ignored**;
  `?time=2026-10-09T00:00:00+02:00` works. Europe/Berlin is +01:00 in summer,
  +02:00 in winter — getting this wrong returns the wrong day.
* **`time` is a cursor, not a filter.** Paging walks *forward through the whole
  archive* from that instant (≈88 600 records). There is no `date=` filter and no
  backwards cursor (`page=-1` walks back one page from page 1).
* Any date works: verified from −7 to **+60 days**.
* One day ≈ **751 departures** (16 pages). A whole weekend costs **≈39 requests**
  if the cursor is aimed at the first moment actually needed — 14 for the
  outbound windows (start Fri 14:00) and 25 for the returns (start Sat 12:00).

**Record fields** (everything the finder needs): `fnr` flight number, `al`
airline IATA code, `alname` airline name, `iata` the *other* airport, `apname`
its city name, `sched` the relevant local time (departure, or arrival on the
arrivals board), `schedArr` scheduled arrival, `stops`, `terminal`, `ac`
aircraft type, `reg` registration, `typ`. `cs` (codeshare) appears on some
records and not others, so it cannot be relied on — which matters, because
benefits follow the operator.

**Verified end-to-end**: for Friday 2026-10-09 → Monday 2026-10-12, 700 outbound
and 1250 inbound flights scanned, 399/683 on benefit airlines, **123 cities
reachable both ways**. That is the feature working with real data.

**What remains:** nothing. The `FraportBoardProvider` is implemented in
`timetable.py` (cursor paging, wall-clock parsing, stops filter, shape-change
loud-fail), and `weekend_match.py` consumes its output. FlightStats stays
blocked (Next.js + AWS WAF captcha) and does not need to be unblocked.

## Architecture

```
pages/weekend_finder.py   UI: date pickers (Friday date), 6 time inputs, results
timetable.py              flight providers: fraport JSON board, csv fallback
airline_benefits.py       reads the Airline Benefits sheet (flag per airline)
airport_city.py           static airport→city→country map + multi-airport merge
weekend_match.py          pure, tested matcher: flights × windows → city list
```

- The Fraport board is a JS shell (verified: no flight rows in static HTML), so
  step 0 is a **spike**: find the JSON endpoint the board itself calls. If none
  exists, the live leg uses the timetable-site scraper for near dates instead.
- Both scrapers cache by (date, direction) for ~6h in `runtime_paths` state dir,
  rate-limited, with a normal user-agent. No API keys needed.
- **Escape hatch (built in, not optional):** manual CSV upload
  (`flight_no, date, dep, arr, from, to, airline`) that feeds the same matcher.
  If every scrape breaks, the feature still works.
- Benefit flags live in the workbook (`Airline Benefits` sheet:
  `Airline | Has Benefits`). Run `python airline_benefits.py` for the current
  state; `write_seed_sheet()` creates it. Note: it is **local config** — it
  travels to Cloud via `refresh_cloud_workbook.py`, not via sync (sync covers
  the destinations sheet, trips, tabs only).
- Operating carrier governs the benefit check (staff standby rides on the
  operator); codeshare duplicates collapse to one flight, shown as
  `LH 400 (Lufthansa, operated by …)` when they differ.

## Edge cases handled

- Overnight flights (arrive next day), DST, cancellations/delays on live data
  (scheduled times rule; delays shown, not filtered).
- Saturday-out + Saturday-back = day trip (explicitly wanted): kept, return
  must land ≥ 12:00 so there is time on the ground.
- A city served from FRA by a benefit airline out but only others back (or vice
  versa) is **excluded** — both legs must qualify — but shown in a collapsed
  "one way only" section so near-misses are visible.
- Non-catalogue cities show `City (Country)` from the static map; catalogue
  cities link to their pages. Unknown airport codes are listed under
  "unmapped" instead of silently dropped.

## Testing

- `test_weekend_match.py`: window logic (all 6 bounds, overnight, Mon<09:00),
  multi-airport merge, codeshare collapse, one-way-only bucketing — fixtures,
  no network, dual-mode runnable.
- `test_airport_city.py`: every IATA code in fixtures resolves; merge table has
  no orphan airports.
- Parser tests with saved HTML/JSON fixtures for each scraper (record once,
  replay forever).
- Page smoke: results render with empty results and with fixture results.

## Build order (each step independently committable)

1. Static airport→city→country seed + merge table + tests (~small).
2. `Airline Benefits` sheet + reader + UI toggle (~small).
3. Matcher + tests on fixture flights (~medium). *First visible logic; CSV upload
   already makes it usable here.*
4. Fraport JSON-endpoint spike; live scraper or documented fallback (~medium).
5. Timetable scraper + cache (~medium, riskiest — time-boxed).
6. Results page wired into nav + smoke tests (~small).
7. Docs (README + PLAN.md), commit, CI green.

## Risks (stated plainly)

- Timetable sites actively resist scraping (blocks, markup churn). Mitigations:
  cache + rate limit, parser fixtures that fail loudly in CI, CSV fallback.
- **Fraport's endpoint is undocumented and could change or disappear.** It is a
  `data-api-url` in their markup, not a public API contract. Mitigations: keep the
  CSV fallback, record one real response as a fixture so a markup change fails a
  test loudly instead of silently returning zero flights, and cache hard so a
  breakage costs one bad page load rather than the feature.
- Benefit list correctness is on the user: an unticked airline silently removes
  destinations. Mitigation: the results header states how many airlines are
  flagged, linking to the sheet.

## Still needs from the user

1. **Go-ahead to implement `FraportBoardProvider`** — the endpoint is verified, so
   this is now ordinary work rather than an open question. No credentials needed.
2. Confirm the Monday-return reading is right: *land Monday before 09:00*
   (i.e. Sunday-night/Monday-early flights home), Sunday itself unbounded.

## Airline benefits: where the answers come from

The single source of truth is **your** file, not this project:

```
C:\Users\Thors\OneDrive\Documents\VS Code - Flights\flightroutes-app\data\airlines_benefits.xlsx
```

* Read on every run, cached for 5 minutes and invalidated immediately when the
  file's mtime or size changes — so editing it in the other project shows up
  without a restart.
* An airline qualifies when **any** of `discount_eligible`, `business_class`,
  `confirmed_booking` is `Yes`. `Unknown` and `No` both mean no: an unverified
  airline is not one you can book on, and treating `Unknown` as a yes would
  silently widen the result list.
* Matched by **IATA code first** (boards say `LH`, CSV exports say `Lufthansa`),
  then by normalised name.
* Mirrored into the workbook's `Airline Benefits` sheet on import, so the app
  still works on a machine that cannot see the OneDrive folder (e.g. Cloud).
* Override the path with the environment variable
  `TRAVEL_PLANNER_AIRLINE_BENEFITS`.

```powershell
python airline_benefits.py    # import + report, no Streamlit needed
```

The page shows the qualifying airlines in an expander and has a
**Re-read the benefits file** button.

Today that yields 7 of 597: CX Cathay Pacific, JL JAL, KC Air Astana,
LH Lufthansa, VL Lufthansa City Airlines, VN Vietnam Airlines, ZH Shenzhen
Airlines. Everything else is `Unknown`, which means the finder will show very
few destinations until you fill the file in — that is the honest result, not a
bug.

## Try it

```powershell
streamlit run app.py
# sidebar -> Weekend Finder -> paste CSV -> "Find weekends"
```

Or from the command line:

```powershell
python timetable.py        # which flight sources work, and a sample CSV
python airline_benefits.py # import your airline benefits file
python -m pytest tests/test_weekend_match.py tests/test_timetable.py
```
