# Mobile bug reports 2026-10-17 — new batch (a–ab)

Second test batch from the Xiaomi 15, fully up-to-date build. This file
records the reports as received. Status legend: **reported** → recorded, not
touched · **decided** → design settled · **done** → implemented and tested.

| # | Report (short) | Status |
|---|---|---|
| a | Finder: return lists Sunday 25.10 twice, Monday missing | done |
| b | Solid testing as a project requirement | done |
| c | Finder: hide one-leg-only results | done |
| d | Finder time picker: caption too long on mobile | done |
| e | Finder warnings: drop flight-length and airline-filter warnings | done |
| f | Finder: subheadings for known / unknown destinations | done |
| g | AeroAPI key: deferred (user will provide new key) | deferred |
| h | Finder result tap: show Rating, Prio Thorsten, Population, Recommended Stay (symbols) | done |
| i | Finder expanded result visually broken; remove "[AGP]"; proposal | deferred (image model) |
| j | Finder result: country flag; fix "1 night" truncation; bed symbol for nights | done |
| k | Share Turso DB + retrieved departure data with "E:\VS Code - Flights\" | proposed |
| l | Map: starting page; search box → destination page for cities | done |
| m | Map: bottom result text shorter, symbols, population in millions, no country, no "ideal in X" | done |
| n | Open destinations: flag symbol; remove clear all; Turso sync | done |
| o | Map filters: minimum 0 = disabled | done |
| p | Planner → Trip Planner; compare button wrap fix | done |
| q | Destination details: pictures missing; proposal | proposed |
| s | Destination details: top picture missing; proposal | proposed |
| t | Destination details: first paragraph formatting | done |
| u | Destination details: 5 stat boxes (Population & Recommended stay first) + Prio blue bubble + 3 toggles | done |
| v | Destination details: name in back-arrow row; remove continent | done |
| w | Destination details: remove coords/country below map | done |
| x | Destination details: coloured full-row backgrounds for headings | done |
| y | Destination details: "Reviews" heading for section below intro | done |
| z | Add-destination screen: remove continent; country autocomplete | done |
| aa | Temperature/AQI charts: selectable points with values | done |
| ab | Setting: editable DeepSeek model identifier | done |


---

## Clarifying questions (ask before implementing)

1. **(i)** No screenshot reached me (this model cannot read images). Please describe
   which expanded result looks broken, or paste the text layout, so I can propose a
   fix. My guess from the code: the expanded block shows `in your catalogue as …`,
   the raw airport-code list, the unmapped-airports note, and then the option
   tiles; on a narrow phone the two `Expanded` columns in each option tile
   plus the trailing `Chip` overflow. Is that the breakage?
2. **(h)** "most important figures" — I propose: ⭐ Rating, 🎯 Prio Thorsten,
   👥 Population (compact, e.g. 10.7M), 🛏 Recommended stay. Symbols as above or
   your preference? Should tapping open the destination page (it already does for
   catalogue matches) or always?
3. **(u)** For Visited/Favourite/Researched, do you want a single toggle row of
   icon-buttons (empty vs filled heart/star/eye) like Streamlit, with the count
   of the 6 boxes (Rating, Prio, Population, Recommended stay, plus the 3
   toggles = 6? or 4 toggles?). Please confirm the 6-box layout: Rating, Prio,
   Population, Recommended stay, plus Visited and Favourite (Research dropped or
   kept)? Streamlit had Visited/Favourite/Researched/Prio — that is 4 toggles.
4. **(j)** Country flag source: use a flag emoji from the country name, or an
   asset flag set? (Emoji is simplest and needs no assets.)
5. **(n)** "use the flag of the respective country as the symbol of the
   non-starred" — for destinations not in the catalogue, there is no country
   resolved; fall back to a generic icon?
6. **(k)** Please point me at the Turso connection details / schema in
   "E:\VS Code - Flights\" (config file path) so I can propose a shared
   format without guessing.
7. **(q)/(s)** For pictures: the legacy Streamlit version fetched them from a
   URL stored in the workbook/DB. Is the picture URL already in the Turso row
   (which column?), or do we need to (re)implement the fetcher? The Dart app
   already has `photo_repository.dart` / `gallery_repository.dart` — are those
   wired into the destination page?

## Notes on implementation order (proposed)

- Quick wins (no design needed): a, c, d, e, f, o, p, t, v, w, x, y.
- Medium: h, i, j, l, m, n, z, aa, ab.
- Proposals only (need your input): q, s, k, u.
- Deferred: g.
- (b) is a process/doc change plus adding tests for the finder regressions.

## (a) Finder: Sunday 25.10 listed twice, Monday missing

Likely the DST transition (clocks go back on 25 Oct 2026) causing a day
bucket to be computed twice or Monday's arrivals to be absorbed into Sunday.
Investigate in `models/timetable.dart` / `weekend_repository.dart` day
bucketing. Add a regression test once reproduced.

## (b) Solid testing requirement

Add to AGENTS.md and the project description that every change ships with
tests, and that the finder in particular keeps its rule book in
`WEEKEND_FINDER_PLAN.md` with regression tests. Create tests for the
regressions in this batch (a, etc.).

## (c) Hide one-leg-only results

Remove the "One leg only" card from `_report` in
`ui/weekend_finder_page.dart` (or gate behind a setting). Keep the data
computation (still useful for diagnostics?) — decision needed: drop
computation too, or keep for the report's "dropped" counts.

## (d) Time picker caption

While selecting, show "Depart before:" / "Land before:"; after selection show
only the time (e.g. 11:00). Applies to the rule row in `_ruleRow`.

## (e) Drop two warnings

In `weekend_repository.dart` / report notes: remove notes about flights dropped
due to leg length and airline filter (those are filters in action, not errors).
Keep genuine board/provider warnings.

## (f) Subheadings

In `_cityList`, split into two groups with headings:
"Destination on your list:" and "Destinations not on your list:" (latter bold).

## (g) AeroAPI key — deferred

User will provide a new key. No action now.

## (h) Finder result tap: key figures

On tap (open destination page), surface Rating, Prio Thorsten, Population,
Recommended Stay using symbols. Possibly a small summary sheet before
navigating, or add to the destination page header (already partially there).

## (i) Expanded result visual breakage

See clarifying question 1. Remove the "[AGP]"-style raw-code label where it
adds no value (the `city.airports` list in the expanded block). Propose a
cleaner expanded layout: title row + one-line meta + option tiles with
Out/Back columns and a nights chip; drop the redundant airport-code line and
the "in your catalogue as" line (already implied by the open icon).

## (j) Country flag + nights truncation

Add a flag emoji before the city name in `_cityRow`. Fix the summary line
truncation of "1 night" when multiple options: replace "nights" with a bed
symbol (🛏) so "1 night" → "1🛏" (or "1 🛏"). Use `maxLines`/`overflow`
adjustments.

## (k) Shared Turso departure data

Proposal: define a shared schema (flights table with origin/destination,
scheduled times, operator, status) in the existing Turso DB (or a new shared
one), with a common fetcher. Need connection details from the other project.

## (l) Map as starting page

Reorder tabs in `main.dart` so Map is first. Search box: if input matches a
catalogue city name, navigate to its destination page; otherwise keep current
country behaviour.

## (m) Map bottom result text

Remove "ideal in October" (colour already conveys it). Shorten remaining text:
Population → symbol + millions ("0.8m"). Drop country (already selected).
Reviews → symbol. Keep rating etc.

## (n) Open destinations picker

Use country flag as the non-starred icon. Remove "Clear all" button. Ensure
Turso sync (already Turso-backed per §0r).

## (o) Map filters minimum 0

In `filter_sheet.dart` / map filters, allow min 0 meaning disabled.

## (p) Planner rename + compare button

Rename "Planner" → "Trip Planner" (nav + app bar). Fix compare button
wrapping on narrow screens (use icon-only or smaller label / overflow).

## (q) Pictures missing — proposal

Legacy Streamlit showed pictures and could pull more. Dart has
`photo_repository.dart` / `gallery_repository.dart`. Proposal: wire gallery
into destination page header/card; add a "fetch more" action calling the
existing photo populator. Need to confirm where picture URLs live in Turso.

## (s) Top picture missing — proposal

Legacy showed a banner photo at top of destination. Restore as a header image
above the title, falling back to placeholder. Depends on (q).

## (t) First paragraph formatting

Add spacing after the intro paragraph; review visual layout.

## (u) Box redesign — proposal

Replace Visited/Favourite/Researched text boxes with icon toggles (empty/filled
heart/star/eye). Prio and Recommended stay as coloured boxes with symbol +
number. Total 6 boxes: Rating, Prio, Population, Recommended stay, plus 2
toggles? Confirm (see question 3).

## (v) Back-arrow row

Put destination name in the same row as the back arrow; remove continent
mention.

## (w) Remove coords/country below map

Remove the coordinates + country line beneath the mini-map.

## (x) Coloured heading backgrounds

Give section headings (Food, etc.) a full-width coloured background.

## (y) "Reviews" heading

Add "Reviews" heading above the section below the intro sentence.

## (z) Add-destination screen

Remove continent field. Country: autocomplete from existing countries (dropdown
with type-ahead).

## (aa) Chart point selection

Make temperature and AQI charts tappable: select a point and show its value.

## (ab) DeepSeek model setting

Add a setting to edit the model identifier (stored in app settings / config).

---

---

## Clarifications (2026-10-17 evening)

- **(i)** Deferred — screenshot handling to be done by a different model. Remove the
  "[AGP]"-style raw code label in the expanded block regardless; rest waits.
- **(u)** Revised design: Prio moves next to Reviews at the top (a second blue
  bubble). The 4 boxes become 5: **Safety, Cost/day, FRA flight time,
  Population, Recommended stay**, reordered so **Population and Recommended
  stay come first**. Toggles (visited / favourite / researched) are separate
  icon buttons, not boxes.
- **(j)/(n)** Country represented by a flag emoji.
- **(k)** Search the "E:\VS Code - Flights\" project ourselves for Turso
  connection details and shared schema; propose a joint format.
- **(q)/(s)** No picture URL in Turso. Legacy Streamlit code is in `archive/`;
  some pictures live in the repo-root `Pictures/` folder, others were fetched
  via APIs and cached (`flight_routes_cache/`, etc.). Reuse that pipeline.

## Updated implementation order

- Quick wins: a, c, d, e, f, o, p, t, v, w, x, y, (i) raw-code removal.
- Medium: h, j, l, m, n, z, aa, ab.
- Proposals needed: u (revised), q, s, k.
- Deferred: g, i (visual redesign).
- Process/doc: b.
</content>
E:\Open Code  - Travel planner\MOBILE_REPORTS_2026-10-17.md