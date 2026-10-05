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

## STATUS 2026-10-05: built, with one part blocked

Steps 1-3 and 6-7 are done and tested (339 tests). **Step 4/5 (scraping) failed**
and step 2's sheet is created but needs your ticks. Details below.

| Step | State |
|---|---|
| 1. Airport -> city -> country | **done** — `airport_city.py` + `data/airports.csv` (4568 airports, built by `build_airport_table.py` from OurAirports) |
| 2. Airline Benefits sheet | **done, needs your input** — `airline_benefits.py`; the sheet was created in your local workbook with 24 seeded airlines, all ticked |
| 3. Matcher | **done** — `weekend_match.py`, 37 tests |
| 4. Fraport live board | **BLOCKED** — see below |
| 5. Timetable scrape | **BLOCKED** — same cause; `csv` is the shipped fallback |
| 6. Page | **done** — `pages/weekend_finder.py`, in the sidebar as "Weekend Finder" |
| 7. Docs/CI | **done** |

### Why the scraping is blocked (verified, not assumed)

* **Fraport**: `frankfurt-airport.com/en/flights-and-transfer/departures.html`
  returns an HTML shell containing **no flight rows at all** — the table is built
  client-side. No public JSON endpoint: `/api/flight/*`, `/api/flights/*`,
  `/_api/flights/*` all return 404. Rendering it needs a browser, which Streamlit
  Cloud does not have.
* **FlightStats**: the v2 board is Next.js behind AWS WAF with a captcha
  challenge; the JSON routes 404 without a WAF cookie.

Both are registered in `timetable.PROVIDERS` as unavailable with the reason
recorded, so the finding is testable and not repeated. `timetable.provider_status()`
returns it machine-readably and the page shows it in the sidebar.

**What works now:** upload or paste a CSV of flights and the finder does
everything else. `csv` is a first-class provider, not a placeholder.

**What would unblock it:** either an API key you are willing to hold (Lufthansa
Developer covers exactly the benefit carriers, and would give *any* date rather
than only a live board), or a data source that permits plain HTTP. Both are
your call; say the word and I will wire it up.

## Architecture

```
pages/weekend_finder.py   UI: date pickers (Friday date), 6 time inputs, results
fraport_live.py           live departures + arrivals from fraport.com
timetable.py              timetable scrape (FlightStats/FR24 schedule pages) by date
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
- Fraport may have no reachable JSON endpoint from a requests-only client
  (Cloud has no browser). Then live = timetable scraper on near dates; the
  matcher doesn't care where flights came from.
- Benefit list correctness is on the user: an unticked airline silently removes
  destinations. Mitigation: the results header states how many airlines are
  flagged, linking to the sheet.

## Still needs from the user

1. **The airline list** — this is the one thing blocking useful results. The
   sheet is in `Destinations-local.xlsx` with 24 seeded carriers ticked. Untick
   what you have no benefits with; add any missing carrier with an `x`. The
   finder only ever shows what you tick. **Note:** an unticked airline silently
   removes destinations, so the results header states how many are flagged.
2. **A flight data source** if you want the finder to fetch its own data: either
   a Lufthansa Developer API key (best fit — exactly the benefit carriers, any
   date) or approval of another source. Until then, upload/paste CSV.
3. Confirm the Monday-return reading is right: *land Monday before 09:00*
   (i.e. Sunday-night/Monday-early flights home), Sunday itself unbounded.

## Try it

```powershell
streamlit run app.py
# sidebar -> Weekend Finder -> paste CSV -> "Find weekends"
```

Or from the command line:

```powershell
python timetable.py    # shows which providers work, and parses a sample CSV
python airline_benefits.py
python -m pytest tests/test_weekend_match.py tests/test_timetable.py
```
