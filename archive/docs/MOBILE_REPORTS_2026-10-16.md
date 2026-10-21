# Mobile bug reports 2026-10-16 — answers, proposals and decisions

Ten reports from testing the Flutter app on the phone: nine (a–i) in the
first batch plus (j), the flight-fallback source requested the same day.
This file is the **answers** to the open questions in them: the redesign
proposals for (b) and (i) with the brainstorming and the challenges asked
for, the diagnosis for (f)'s "is that possible?", and the source research
for (j). The implementation record lives in `PLAN.md` §0s; the finder's
rule book stays in `WEEKEND_FINDER_PLAN.md`.

Status legend: **reported** → recorded, not touched · **decided** → the
design is settled here · **done** → implemented and tested (see PLAN §0s).

| # | Report | Status |
|---|---|---|
| a | App name "travel_planner" → "Travel Planner", new logo | done |
| b | Finder "out on"/"back on": free day selection | done |
| c | CSV override: remove | done |
| d | Airlines filter: four-option dropdown | done |
| e | Exclude 1-night results (clarified: a visible, changeable filter, default ≥ 1 night) | done |
| f | Error log, Sunday-returns mystery, `?MKF`/`?QKL`/`?ZWS` | done |
| g | Destination cards: Review Rating, Prio, Population | done |
| h | "Trips" → "Planner" | done |
| i | Open tabs → floating widget | done |
| j | Fallback flight data source | done |

---

## (a) App name and logo

**Name.** "travel_planner" is the *internal* identifier (the Dart package
name, the Android application id, the `.exe`). The *displayed* name is what
you saw — the window title, the Windows version strings and the Android
label — and those are now "Travel Planner". The internal ids stay
`travel_planner`: renaming the package would touch 146 imports for zero
visible gain and would break the documented `travel_planner.exe` path.

**Logo.** The old icon was the "wrong drawing" you saw (a lopsided dark
triangle that only read as a plane by accident). The new one is generated
from geometric primitives, so it is symmetric and crisp at every size: a
teal tile (the app's theme colour), a white paper plane, and a gold dotted
flight arc behind it. `mobile/tools/generate_app_icons.py` is the
regeneration path; the same drawing is exported as the Windows `.ico`
(16–256 px), the Android launcher mipmaps and a 1024 px master
(`mobile/app_icon.png`).

## (b) "Out on"/"back on" — free day selection

### Your proposal, restated

1. Pick a travel **period** on a calendar (e.g. 10–15 Dec).
2. That populates the candidate days for "out on" and "back on": each day
   of the period **plus the day before and the day after**.
3. Each candidate date can be **selected and deselected** individually.
4. For each selected day, choose **before or after** and then the time the
   bound applies to.

### Brainstorm — what else could work?

* **A. Your period ± 1 day** (restated above). The ±1 is the "flex" the
  finder needs: your period is the *core* travel span, the neighbours are
  the "I could sneak out Thursday evening / come back Tuesday morning"
  escape hatches. For a contiguous period, per-day ±1 and whole-period ±1
  produce the same candidate set — the two readings of your sentence agree.
* **B. Pure free-form date checklist** — no period at all, just "add a day"
  buttons. Maximum freedom, but every search starts with a blank form; the
  period is what makes one tap answer "next weekend-ish".
* **C. "Trip length" model** — pick the *nights* (2–4) and an anchor
  weekend; the days fall out. Very fast for the common case, but it cannot
  express "any three days around Christmas" — the thing you actually asked
  for.
* **D. Two-colour calendar (drag to mark out-days and back-days)** — the
  nicest interaction, the heaviest widget; `showDateRangePicker` already
  gives 90 % of it for free and stays platform-native.

### Challenge to your proposal (the sharp edges)

1. **"The day before and after" is the right flex, but it needs a story.**
   Silently offering Dec 9–16 when you asked for Dec 10–15 invites "why is
   Dec 9 here?" — so the candidate days are labelled as *flex days* (the
   ones outside your period) and the picker states the rule in one line.
2. **Before/after must apply to the right clock.** For an *out* day the
   bound is about the **departure** ("leave after 14:00", "leave before
   12:00"); for a *back* day it is about the **landing** ("home before
   22:00", "not before noon"). Your proposal says "the time the before or
   after applies to" — the answer is: the flight time on that side, and the
   UI says so ("departs after", "lands before") instead of a bare
   "before/after".
3. **"Any time" must be a first-class state**, otherwise a normal Saturday
   return ("whenever") forces a fake bound. Three states per day: any /
   after / before. Default for days you add by hand: **any**.
4. **Unbounded selection is a foot-gun** (out Dec 15, back Dec 10 = an
   empty answer). The matcher already refuses a return before the outbound
   lands; the empty state now *says* that when it is the reason.
5. **Days alone are not enough — nights matter.** Report (e) asks for ≥ 2
   nights; that rule is part of the model now, with the drop count shown.
6. **Regression risk:** the old Thu/Fri/Sat/Sun/Mon/Tue slots were the
   tested spec. The rules that *matter* (direct both legs, benefits follow
   the operator, both legs required, near misses visible, ranking by
   nights/return-day/departure, max two ways home per outbound, honest
   empty answers) are kept rule-for-rule and re-tested against the new
   day model.

### Decision (implemented)

* **Travel period** via the native range picker, with "This weekend" and
  "Next weekend" presets. Candidates = period ± 1 day, labelled "flex"
  when outside the period.
* **Out on / Back on** are two independent multi-selects over those
  candidate days (tap to select/deselect). Presets preselect the old
  defaults — out: Fri from 14:00, Sat before 12:00; back: Sun any time,
  Mon before 09:00 — so the finder behaves exactly as before until you
  touch the days. A custom period starts with out = first day, back = last
  day, both "any time".
* **Per selected day** one rule row: direction (`any time` / `after` /
  `before`) + the time it applies to, phrased "departs after 14:00" /
  "lands before 09:00".
* The Thursday/Tuesday "holiday bridge" is no longer a special case — it
  is just days you select.

## (c) CSV override

Removed entirely: the paste fields, the template, the `CsvBoardProvider`
and its parser. The finder queries the Fraport board and says so. (It was
an escape hatch for when the board is unreachable; the error log now
covers that failure mode with a visible message instead.)

## (d) Airlines filter

A dropdown with exactly your four options:

| Option | Rule | Note |
|---|---|---|
| **Only Lufthansa Group** (default) | explicit membership table | LH, Lufthansa City(CityLine), Eurowings, Eurowings Discover, SWISS, Edelweiss, Austrian, Brussels Airlines, Air Dolomiti, ITA Airways |
| **Only Lufthansa** | airline name contains "Lufthansa" | per your definition: Lufthansa, Lufthansa City, … |
| **All with benefits** | benefit flag = yes | the old switch behaviour |
| **All** | no filter | |

**Interpretation taken (worth confirming):** the two Lufthansa options are
*identity* filters — they do **not** additionally require the benefits
flag; your parenthetical ("all airlines with Lufthansa in their name")
defines membership, not benefits. So "Only Lufthansa" shows Lufthansa City
even if the benefits database has no flag for it. If you meant "Lufthansa
Group *with benefits*", say so — it is a one-line change in
`models/airline_benefits.dart`.

## (e) Exclude 1-night results — as a visible filter

**Clarified the same evening:** this must be a filter the *user* can see
and change, not a hardcoded rule — and the default is **at least 1 night**,
not 2. That is what it does now: the finder's flight filters row has a
**"Min. nights"** dropdown (`Any / 1 night / 2 nights / 3 nights / 4
nights`), default **1 night**. The first pass hardcoded 2+; that was
corrected before it shipped.

Options shorter than the chosen minimum are dropped before ranking and the
report states "N option(s) dropped for staying fewer than X night(s)" (the
house rule: a filter that can empty a list says what it dropped). With the
default of 1, **nothing** is dropped — only zero-night/non-overnight pairs
never existed in the model. Cities whose only pairs were dropped fall back
to the "one leg only" section instead of vanishing.

## (f) Error log, Sunday returns, `?MKF`/`?QKL`/`?ZWS`

### "It didn't have any data for the return flights on Sunday — is that possible?"

**Yes — and it is the board's data, not the app's search.** Evidence from
your own cached searches (`weekend_cache/`, fetched 2026-10-12 for the
weekend 23–26 Oct) and from live probes of the Fraport endpoint on
2026-10-16:

| Window | Flights found |
|---|---|
| Fri 23 Oct departures | 316 |
| Sat 24 Oct departures | 233 |
| Sat 24 Oct arrivals | 366 |
| **Sun 25 Oct arrivals** | **1** (X3 2187 ACE→FRA, lands 23:00) |
| Mon 26 Oct arrivals | 146 |

Live probes confirm it: querying that Sunday with three different cursor
times (`00:00+02:00`, `00:00+01:00`, `12:00+01:00`) all return the same
page — the first arrival of "the day" is 23:00, then the board continues
into Monday. **Departures that Sunday are complete (50+ records in the
first morning page) and the next Sunday (1 Nov) is normal** — so it is a
gap in the *arrivals* feed for 2026-10-25 only, the day the winter
timetable starts and the clocks change. Nothing the app can do can
invent those flights.

What the app now does about it: **an empty or suspiciously thin window is
never silently "no flights"**. The report carries a warning ("only 1
flight where other days returned 366 — the board's data for this window
looks incomplete; results may be incomplete") and the incident is written
to the error log with the window and the counts. Provider failures (HTTP,
timeout, shape change) also become visible notes and log entries instead
of ending the search silently.

### The `?MKF` `?QKL` `?ZWS` entries

They were **not** destinations — they are Lufthansa **AIRail trains**,
which the Fraport board lists like flights (flight number LH 34xx/35xx/
36xx, aircraft type `TRS`) with *railway station codes* instead of IATA
codes. Verified live:

| Code | Board's own name |
|---|---|
| `QKL` | Cologne Main Station |
| `ZWS` | Stuttgart Railway |
| `ZMU` | Munich Central St. |
| `QDU` | Dusseldorf Main St. |
| `XHJ` | Aachen Central |

`?MKF` is another station code in the same family (it is not an IATA
airport; the archive's own comment documents this exact symptom for
`?QDU`). The port never learned the legacy `RAIL_STATIONS` table, so any
unknown code rendered as `?CODE` — a label the legacy comment itself calls
the bug.

Fixed three ways: (1) the known station codes are now an explicit table
(QKL → Cologne, ZWS → Stuttgart, plus the nine the legacy knew), so the
trains merge into their cities properly; (2) an unknown code no longer
renders as `?MKF` — the board's own station/airport name is used as the
label ("MKF" with a note if even that is missing); (3) every unknown code
is written to the error log with the record's name and airline, so the
next occurrence identifies itself.

### The error log

New, persistent, per device: `error_log.jsonl` next to `app_settings.json`
(repo root on the PC, the app documents dir on the phone). Every entry has
a timestamp, an area (e.g. `weekend-finder`, `flutter`), a message and a
details map. It records: search/provider failures, implausible board
windows, unknown airport/station codes, and anything uncaught (a global
hook in `main`). **⚙ Settings → Error log** shows the latest entries and
clears them.

## (g) Destination cards

The meta line (truncated "safe 8/10 · 45 €/day · 2 h to FRA") is replaced
by the three numbers you named, wrapped instead of cut off:

* **Review 8.3/10** — the workbook's `Reviews` column (the review score
  the AI populate writes),
* **Prio 8** — only when `Prio Thorsten` is populated (it is the
  object/text column: "n/a" shows as "Prio n/a", not a fake number),
* **Population 10.7M** — `Population (Metro Area)`, compact form so the
  line never overflows.

## (h) "Trips" → "Planner"

Renamed in the navigation (bottom bar and rail) and the page's app bar.

## (i) Open tabs — proposal

### Your idea

A **floating widget** the user clicks, which holds the open items.

### Brainstorm

* **A. Your floating button + sheet** (chosen): a small floating button,
  bottom-right, showing a stack-of-cards icon and the count of open
  destinations; click → the list in a bottom sheet (open / close / close
  all). Costs zero permanent screen space; on the phone it replaces the
  44 px chip strip, on the desktop the 200 px side panel.
* **B. Draggable floating stack** — the open destinations as literal
  overlapping mini-cards you can fan out and drag. Playful, but it fights
  the map and the lists for taps and is fiddly at 390 px width.
* **C. Browser-style tab bar** at the top of the content — your current
  strip, really; you asked for an alternative *because* it eats the top.
* **D. "Recent destinations" in the catalogue app bar** — discoverable,
  but hidden exactly while you are *not* on the catalogue, which is when
  you need it.
* **E. Radial menu on a long-press** of the FAB — fastest for 3–4 items,
  invisible to anyone who does not know the gesture.

### Decision (implemented)

**A**, with the parts of the panel worth keeping: the favourite star per
row, the ✖ to close one item, the active-destination highlight, and the
"could not read the list" warning (a failed read is never shown as "no
tabs"). Extra touches: a count badge on the button, "Close all" in the
sheet, and the button hides when nothing is open. The Settings switch
from PLAN §0r stays: the feature can still be turned off per device.

---

## (j) Fallback data source for the flights

**Question:** can a fallback source for the flight data be implemented?
**Answer: yes — FlightAware AeroAPI, as an optional fallback only.** The
research and the recommendation:

| Source | Verdict | Why |
|---|---|---|
| **FlightAware AeroAPI** ✅ | recommended, implemented | Licensed API, documented `/airports/{EDDF}/flights` endpoint with scheduled/actual times, operator and status. Paid, but a key can be added per device — so it is an *optional* config entry, not a dependency. |
| Fraport board (current) | stays primary | Free, complete for FRA, already mapped record-for-record. The (f) diagnosis showed its rare bad windows (like the DST Sunday) — exactly when a fallback earns its keep. |
| FlightRadar24 / flightradar-style scrapers | **no** | Their payload terms explicitly forbid scraping; not a foundation to build on. |
| Aviationstack / AviationData / similar free tiers | no | Too small for a full FRA day (hundreds of flights per window); rate limits would turn a healthy search into a slow one. |
| OAG / Cirium (legacy's `BA_OS_DP.csv` world) | not now | The right answer for schedules at scale, the wrong price for a personal app. |

**How it is wired (implemented):** `flightaware_api_key` in
`turso_config.json` (empty in the example template). Without a key nothing
changes. With a key, the repository asks the fallback **only** about
windows that failed or look incomplete (the (f) thin-window rule) — never
about healthy ones — and marks the report's rows that came from it. Network
or auth failures of the fallback are logged to the error log and surfaced
as a note, never as silently thinner results.

---

## Summary of autonomous decisions (flagged for your review)

1. **(d)** The two Lufthansa options filter by identity, not by benefit
   flags (your parenthetical defines membership).
2. **(b)** Presets keep the old Fri/Sat/Sun/Mon defaults; free selection
   is additive. Before/after applies to departure (out) / landing (back).
3. **(e)** "Min. nights" is a visible dropdown, default **1 night**
   (per your clarification — the first pass's hardcoded 2 was corrected).
4. **(a)** Display name changes; package/exe ids stay `travel_planner`.
5. **(i)** Floating button + bottom sheet, not a draggable stack.
6. **(j)** FlightAware AeroAPI as an *optional* fallback, only for failed
   or implausible windows; no scraping sources.
