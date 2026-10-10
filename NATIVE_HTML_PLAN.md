# Target architecture: move off Streamlit — native desktop + Android, Turso storage/sync

**Status (2026-10-10): decided — the Streamlit version is legacy.**
It is archived as a source of knowledge and as a potential fall-back
in case the native development does not go as planned; it stays green
and runnable, and nothing in it is deleted.

**Phase 1 implemented and verified (2026-10-08).** The data
layer is on Turso behind the existing Streamlit UI: `turso_db.py`
(SQL-over-HTTP client + schema), `storage_turso.py` (destinations /
trips / tabs, writer contract), `repository.py` (Turso first, workbook
fallback — the pages call it), `migrate_to_turso.py` (one-shot,
idempotent). The live database holds all 144 destinations (145-column
lossless tails), 2 trips and the open tabs; read, idempotent write
round-trip and the `.xlsx` export were verified against it. 492 tests
green (87 new), ruff/compileall/dependency-free path clean.
The app was green and pushed at the time (`00cb16f`, CI run
37658099197 passed on Linux and Windows).

**Status of §7 (updated 2026-10-11):**

| Phase | State |
|---|---|
| 0 — spike & decisions | done — sec. 6 answered; the pipeline API was proven by `benefits_turso.py` before this plan was written |
| 1 — data layer on Turso | done 2026-10-08, verified live (above). The "delete the sync stack" step was **superseded**: the stack stays as the legacy fallback per the 2026-10-10 decision |
| 2 — backend API | done 2026-10-10 (`2a066fb`): `api.py`, Streamlit-free, 23 tests; runs locally via uvicorn — no external host needed for this use |
| 3 — native HTML frontend | done 2026-10-10 (`2a066fb`): `web/` PWA served by the API on the PC; "[needs a host]" became moot because the phone went native instead |
| 4 — sync on Turso | **half-done, by a different route**: every surface (Streamlit, API, Flutter) talks to the same database directly, last-write-wins via `updated_at` (the trips runtime cutover is `7fadbbc`). The offline-first push/pull layer was consciously traded away and is this plan's biggest open gap |
| 5 — Android/desktop native | **code complete, not yet runnable**: `mobile/` (`accd28f` scaffold, `573f235` repositories, UI, tests — analyze clean, 31/31 pass). Missing: platform folders (`flutter create`), a JDK for `flutter build apk`, a first live run, and feature parity — map, galleries, AQI and AI populate are still PC-side only |
| 6 — cutover/cleanup | **deferred with a trigger** (decision 2026-10-10, trigger set 2026-10-11): retire the Streamlit fallback when the Flutter app reaches **full parity** and has been used daily without falling back |

The immediate next steps live in `HANDOFF.md`. The remaining work beyond
them is decision-shaped, not volume-shaped:

1. **Make Phase 5 runnable.** Platform folders, JDK, `flutter run -d
   windows`, one live edit round-trip against Turso, then the sideloaded APK.
2. **Build toward full parity.** Parity with the legacy app is the declared
   end goal (user, 2026-10-11), not a scoping choice — the only open
   question is order. Agreed order: destination detail richness first
   (map, galleries, climate, reviews), then the weekend finder (key-free),
   then the key-gated features (AI populate, keys in the APK per sec. 6
   Q8), until nothing is PC-side only.
3. **Decide the offline-first story.** Staying online-only is defensible
   for one user with two devices and a free-tier database; if offline
   matters, sec. 10's local file + `push()`/`pull()` is the design to pick
   up (in Flutter: `@tursodatabase/sync`, not `libsql_dart`).
4. **Phase 6 trigger — set (2026-10-11).** Full parity of the Flutter app
   (item 2) plus a period of daily native use without falling back. No
   further decision needed; revisit when item 2 completes.

This document evaluates the three-part proposal:

1. **Dump Streamlit and move to native HTML.**
2. **Create an Android version based on the desktop version.**
3. **Use Turso to store and synchronise data.**

---

## 1. What exists today (verified, not assumed)

| Layer | Size | Notes |
|---|---|---|
| Streamlit UI (`app.py` + 5 pages) | ~218 KB | `destination_detail.py` 97 KB, `itinerary.py` 45 KB, `world_map.py` 34 KB, `weekend_finder.py` 18 KB, `overview.py` 15 KB |
| Workbook I/O (`data_utils.py`) | 52 KB | atomic saves, stale-write detection, rolling backups, every writer's True/False contract |
| Custom sync stack (`sync/`) | ~53 KB | journal -> merge -> GitHub Contents API transport to the `data-sync` branch, plus journaling hooks wired into every writer |
| Pure, Streamlit-free logic | ~256 KB | `itinerary/`, `weekend_match.py`, `filters.py`, `rainy_days.py`, `airport_city.py`, `airline_benefits.py`, `benefits_turso.py`, `timetable.py`, `aqi_api.py`, `flight_routes.py`, galleries, populators |
| Tests | 405, all green | incl. a smoke test that renders all 144 destination pages |

Data flow today: `Destinations-local.xlsx` (144 destinations x 145 columns) is
the source of truth on the PC. The phone runs the same app on **Streamlit
Cloud** from a committed `Destinations-cloud.xlsx` seed. Bulk data (climate,
AQI, cost, safety, food) reaches the phone only via `refresh_cloud_workbook.py`
(copy local -> cloud, commit, redeploy). Interactive edits (favourite/visited/
Prio/comment, trips, open tabs) travel both ways through the change journals
over the GitHub `data-sync` branch. `TURSO_AUTH_TOKEN` is **not set yet** --
the airline benefits already live in a Turso database (`benefits_turso.py`, 50
tests), but the app currently falls back to the workbook's `Airline Benefits`
sheet.

## 2. Turso facts (verified against Turso's docs, 2026-10)

* **Turso Sync** (`turso.sync` / `pyturso` Python package, sqlite3-compatible
  API): a local database file with explicit `push()` / `pull()` to Turso Cloud,
  built on logical change-data-capture. Local-first: all reads and writes hit
  the local file; sync is explicit; offline writes are safe until the next
  push. First run bootstraps from the remote (`bootstrap_if_empty`).
* **Conflict strategy is "last push wins"** -- there is no built-in three-way
  merge or conflict list.
* **Turso Cloud free tier:** $0, 100 databases, 5 GB storage, 500 M rows read /
  10 M rows written / 3 GB sync per month. This app is nowhere near any limit.
* The Turso engine is a ground-up SQLite rewrite (Rust). Its MVCC concurrent-
  write mode (`BEGIN CONCURRENT`) is explicitly flagged **"not production
  ready"** in the manual.
* The older **libSQL Embedded Replicas** (writes go to the cloud primary,
  page-level replication) are production-proven but Turso recommends Turso Sync
  for new projects.
* The **SQL-over-HTTP pipeline API** (`POST /v2/pipeline`) is what
  `benefits_turso.py` already uses. Browser-direct access (CORS) is not
  documented; treat it as unsupported and keep tokens server-side.

## 3. Pros of the proposal

1. **Interaction model.** Streamlit rerun every page script on every widget
   interaction (the full 144-page render takes ~61 s in the test harness). A
   native HTML frontend talking to a JSON API updates only what changed -- no
   full rerun, no widget-state replay. The map, filters and itinerary editing
   become snappy.
2. **Mobile UX.** Streamlit on a phone is a desktop layout scaled down. Native
   HTML can be designed mobile-first (bottom nav, touch targets, installable
   PWA with offline reads). This is the real pain behind "create an Android
   version".
3. **A real data model.** The workbook's 144x145 heterogeneous, object-typed
   columns (e.g. "Prio Thorsten" is text/object) force coercion helpers,
   atomic-save wrappers, stale-write detection and rolling backups. A SQLite
   schema is typed and constrained; most of `data_utils.py` disappears.
4. **Sync becomes a product feature instead of a bespoke stack.** The
   journal/merge/GitHub-transport stack (~53 KB + hooks in every writer +
   `refresh_cloud_workbook.py` + the `data-sync` branch + a GitHub PAT) exists
   only to move edits between two devices. Turso Sync's push/pull replaces it:
   both devices sync the same database directly. Consequences: no
   `refresh_cloud_workbook.py` step (the phone sees bulk data as soon as the PC
   pushes), no "Cloud edits lost on redeploy", no PAT transport, and offline-
   first on both devices.
5. **Cost.** Turso's free tier is orders of magnitude above this app's needs
   (144 destinations, a handful of trips).
6. **Head start.** `benefits_turso.py` already proves the Turso contract (HTTP
   pipeline API, token handling, failure ladder, 50 tests), and the ~256 KB
   pure-logic layer is Streamlit-free and reusable as-is.
7. **Android reuse.** A PWA or WebView wrapper reuses 100% of the web UI --
   "an Android version based on the desktop version" is literally true with one
   codebase. (A fully native Flutter app would *not* be based on the desktop
   version; it would be a second codebase.)

## 4. Cons of the proposal

1. **Rewrite scale.** ~218 KB of Streamlit UI must be rebuilt as HTML/JS: the
   choropleth world map, climate dashboards, galleries, the itinerary drag-
   drop editor, the weekend-finder inputs, the custom sidebar with closeable
   tabs. Every subtle behaviour -- above all the filter semantics ("a filter
   may only hide rows whose field is populated", `filters.py`) and the conflict
   list -- must be re-implemented and re-tested. This app's history is "I keep
   finding a lot of bugs"; a rewrite is the highest-risk way to introduce more.
2. **A backend is required.** Native HTML is not a static site: the Fraport
   scraper, AQI/IQAir, DDG/Unsplash galleries and DeepSeek populate are
   server-side Python with secrets. The proposal really means "HTML frontend +
   Python backend (FastAPI) + hosting". Streamlit Cloud (free, working today)
   is replaced by a new host (Render/Fly.io free tier or a small VPS) -- new
   ops burden and a new failure mode.
3. **Turso maturity and semantics.** The engine is a young rewrite; MVCC
   concurrent writes are flagged not-production-ready. Turso Sync resolves push
   conflicts with **last push wins**, while the current journal+merge *detects*
   conflicts and lists them for review. For one user with two devices, concurrent
   edits to the same stop are rare -- but the change is real: a simultaneous edit
   on both devices would silently resolve instead of asking.
4. **Token exposure on the phone.** A read-write Turso token in a
   browser-reachable app is extractable. The safe architecture keeps the token
   on a backend and has the browser talk only to the backend -- which also means
   the phone is not local-first (no offline writes on the phone unless the
   backend is on the LAN).
5. **Migration and the Excel workflow.** 144x145 columns -> schema design (likely
   a typed core table + a JSON column for the long tail). The workbook is also a
   human-readable artifact the user opens in Excel; losing it needs an export.
   `trips.json` -> tables; journals -> dropped or kept as audit. Every producer
   (climate, AQI, food, malaria, DeepSeek) must be retargeted.
6. **Testing re-plumbing.** The pure-logic tests survive, but the 144-page smoke
   test -- the test that caught the crash that broke 78% of the catalogue --
   must be replaced by API/UI equivalents, and CI must be re-plumbed.
7. **Time.** Weeks of work for a personal app that currently works with green CI.
   The two real pain points (rerun slowness, phone UX) have cheaper partial
   fixes (see sec. 9).

## 5. Verdict -- under "no server, no money", native Android wins

The direction is sound. Your two answers ("I sideload, no Play Store" and
"keys in the APK are fine, I'm the only user") collapse the two hardest
constraints, and that **flips the recommendation**: a native Android app +
Turso Sync is now the preferred path, not a deferred option.

**Why native is viable here and a web frontend is not.**
* A **web** frontend (native HTML + FastAPI, or even a PWA calling Turso
  directly) needs a host you run: Turso's HTTP API CORS is undocumented
  (so a browser can't talk to it), and the scrapers/API keys can't live in
  the browser. Under "no server" that is blocked.
* A **native** Android app needs no host of yours: it holds a local
  SQLite/Turso file and `push()`/`pull()`s to the **Turso free tier** (a
  SaaS like Streamlit Cloud, not your own server). With keys in the APK,
  *all* features work on the phone -- Fraport weekend finder (key-free),
  DeepSeek populate, Unsplash/DDG galleries, AQI/IQAir. Offline-first writes
  sync on the next push.

**The only real fork is on the PC side (sec. 6, Q7):**

1. **Keep the PC on Streamlit** (Streamlit Cloud, free host stays). PC and
   phone share one Turso DB, two UIs. Lowest risk; phone gains offline-first
   and full features today.
2. **Move the PC native too** (Flutter desktop + Android from one codebase --
   your choice). Truly "Android app based on the desktop version", and
   Streamlit Cloud can be dropped. Makes the libsql_dart quote relevant (use
   `@tursodatabase/sync` push/pull, not a native libsql bridge).

Your decision: **go native on the PC (Flutter), but retain the Streamlit
version as a fallback** while you compare. That means: Phase 1 (data on
Turso behind the existing Streamlit UI) now, which also serves the future
Flutter app, then build the Flutter UI alongside it and switch over.

**What to do now (zero cost, no host):**

> **Phase 1 first -- the data layer on Turso.** This is platform-
> agnostic and shippable today: design the schema, migrate the workbook +
> trips.json into Turso, and point the existing Streamlit UI at a
> repository layer over Turso (with the Streamlit Cloud app getting a
> read-write token via `secrets.toml`). This deletes the bespoke
> journal/merge/GitHub-transport stack and `refresh_cloud_workbook.py` now,
> fixes the "Cloud edits lost on redeploy" bug, and gives both the Streamlit
> phone view and a future native app the same single database to sync. It
> costs nothing to do and is a strict prerequisite for either end state.

## 6. Decisions needed before starting

| # | Question | Why it matters |
|---|---|---|
| 1 | **(answered -- last-push-wins) Accept last-push-wins for conflicting phone/PC edits, or keep an explicit conflict list?** | User chose **last-push-wins**: Turso Sync alone suffices; no conflict layer. Trade-off: simultaneous same-stop edits silently keep the later one (rare for one user, two devices) |
| 2 | **(resolved) No host needed** if the phone is native -- Turso free tier is the only server. A *web* frontend would need a free tier / paid host / LAN-only PC. Gated only on choosing the web path. | Gates Phase 2-3 only |
| 3 | **(answered -- native) Android packaging: PWA, WebView/Capacitor, or fully native?** | Native. No Play Store (sideload), keys in APK. |
| 4 | **(answered -- keep export) Must the Excel workbook survive as an openable/exportable artifact?** | Yes: export from Turso back to .xlsx; Turso is the source of truth, workbook is a convenience |
| 5 | Must the **phone** work off-LAN/on cellular? | Relevant to Phase 5 packaging only (offline-first handles it) |
| 6 | Which server-side features survive on Streamlit Cloud? (Fraport fetch, AQI/IQAir, DeepSeek populate, Unsplash/DDG galleries) | Moot under native: all keys live in the app (Q8 answered yes) |
| 7 | **(answered -- native PC, keep Streamlit fallback) If Android is native: does the PC stay Streamlit, or move to a shared native stack (e.g. Flutter desktop) too?** | **Go native on PC** (Flutter desktop + Android, one codebase); **retain the Streamlit version** as a fallback during transition. Makes the libsql_dart quote relevant -> use `@tursodatabase/sync` push/pull, not a native libsql bridge |
| 8 | **(resolved -- yes) Are API keys embeddable in a personal, single-user APK?** | Yes. DeepSeek/Unsplash/AQI/IQAir all work on a native phone |

## 7. Implementation plan

The **first shippable win under any reading is Phase 1** (data on Turso,
behind the existing Streamlit UI) -- zero cost, no host, and a strict
prerequisite for both end states. Phase 5 (native Android) then adds the
phone client with no host of its own (Turso free tier only). Phases 2-3
(the *web* native-HTML rewrite) are the only parts that still need a host,
and are marked **[needs a host]**. Under your answers they are the lowest
priority, not the plan.

**Phase 0 -- Spike and decisions (no production change). — DONE.**
Answer the decisions in sec. 6. Spike `turso.sync` (`pyturso`) against a
scratch Turso database: create the DB and a read-write token, push/pull from
Windows, measure bootstrap time for a 144-row dataset, observe behaviour when
the remote is unreachable, and document what a push conflict actually does.
*Exit criteria:* push/pull verified, conflict behaviour documented.
(The pipeline-API half of the spike was already proven by `benefits_turso.py`;
the push/pull half was superseded by the direct-to-Turso route below.)

**Phase 1 -- Data layer on Turso (behind the existing Streamlit UI). [no new host needed] — DONE 2026-10-08, verified live.**
Both the PC app and the Streamlit Cloud app get a `TURSO_AUTH_TOKEN` and sync
the same Turso database. Design the schema: `destinations` (typed core + JSON
tail for the long columns), `trips`/`variants`/`stops`/`legs`, open tabs,
settings. Write the migration script workbook -> SQLite -> Turso and
`trips.json` -> tables, with row-count and spot-value verification; keep an
Excel export. Add `storage_turso.py` implementing the project's writer
contract (returns True/False, atomic, never a stale save). Introduce a
repository layer the Streamlit pages call, so a future UI swap is mechanical.
Delete `refresh_cloud_workbook.py` (no longer needed) and the journal/merge/
GitHub transport (replaced by push/pull).
*Tests:* migration round-trip, writer contract, schema drift. **This phase
alone delivers the proposal's core benefit at zero hosting cost.**

**Phase 2 -- Backend API. [needs a host] — DONE 2026-10-10 (`2a066fb`).**
The API runs locally (uvicorn) and, since the phone went native, no external
host is needed; the bracketed caveat is obsolete for this use.
FastAPI endpoints: destinations list/filter/detail, trips CRUD, tabs, sync
trigger, weekend finder (server-side Fraport fetch), galleries, AI populate.
All secrets stay server-side. Reuse every pure module; the API becomes the
new "session state".
*Tests:* API tests replacing the page-smoke tests; contract tests pinning
the `filters.py` semantics.

**Phase 3 -- Native HTML frontend. [needs a host] — DONE 2026-10-10 (`2a066fb`).**
Served by the API on the PC; the phone went native (Phase 5) instead of
needing a hosted frontend.
Server-rendered HTML + vanilla JS -- no build step, matching the project's
no-frills style; plotly.js for the map and climate charts. Feature-parity
checklist from the five pages; the filter semantics must be preserved exactly.
PWA manifest + service worker for installability and offline reads.
*Tests:* smoke-render every destination through the API (the analogue of the
144-page test that caught the 112-page crash).

**Phase 4 -- Sync on Turso. — SUPERSEDED IN PRACTICE.** (The plan folded this
into Phase 1: both devices `push()`/`pull()` the same database; conflict
policy per sec. 6 Q1.) What actually shipped is **direct-to-Turso with
last-write-wins** (`updated_at`) from every surface — the Streamlit app, the
API and the Flutter app — so the *shared database* half is real, but the
offline-first local-file + push/pull half is **not implemented anywhere** and
remains this plan's biggest open gap (see the status block's remaining-work
list, item 3).

**Phase 5 -- Android (native). [no host needed; Turso free tier only] — IN PROGRESS: code complete and tested (`mobile/`, 2026-10-11), not yet runnable.**
A native Android app with a local Turso file + `push()`/`pull()`. Offline
first; sideloaded APK (no Play Store). With keys allowed in the APK, every
feature works on the phone. Choose the PC side per Q7: if the PC stays
Streamlit, the Android app shares only the data layer; if the PC goes native
(Flutter), share the UI too. In Flutter use `@tursodatabase/sync` push/pull,
not a native libsql bridge (Q8 answered: keys in APK are fine).

**Phase 6 -- Cutover and cleanup. — DEFERRED, with a trigger.**
Do not run while the Streamlit version is the fallback: deleting the
Streamlit pages, workbook writers, and the sync stack would delete the
fallback the user decided to keep. **The trigger is full parity** of the
Flutter app with the legacy app (user, 2026-10-11) plus a period of daily
native use without falling back; only then delete, update the docs, and
re-plumb CI.

## 8. The pending question from the previous session, answered

The other project's agent said: *"I chose SQL-over-HTTP over libsql_dart,
deliberately. The libSQL client pulls in flutter_rust_bridge,
native_toolchain_rust and prebuilt Rust binaries onto a 20 MB APK, it's
community-maintained rather than Turso-official, and it would mean replacing
sqflite across every query. Turso's documented /v2/pipeline endpoint over
package:http has none of that, and the whole remote surface becomes one file
that's trivial to fake in tests."*

**Relevant to this project: partially.**

* The **Flutter-specific** details (`libsql_dart`, `flutter_rust_bridge`,
  `sqflite`, APK size) are **not** relevant here -- this is a Python app, not
  a Dart/Flutter one.
* The **principle** is directly relevant and **already applied**:
  `benefits_turso.py` uses exactly that reasoning -- Turso's documented
  `/v2/pipeline` SQL-over-HTTP endpoint over raw `requests`, no native libsql
  driver, one file that is trivial to fake in tests.
* It becomes **fully relevant again** only if the Android version is ever
  built as a Flutter app (sec. 7, Phase 5 alternative): then the same argument
  says to use SQL-over-HTTP or the backend proxy, not `libsql_dart`. Under the
  recommended PWA/WebView path the question does not arise -- the browser talks
  to the backend, and the backend owns the Turso connection.

## 9. Alternatives considered

| Alternative | Trade-off |
|---|---|
| **Move data to Turso, keep Streamlit (recommended now)** | Gets the sync win -- no `refresh_cloud_workbook.py`, no redeploy data loss, no PAT transport -- without the UI rewrite or a new host. The phone stays on Streamlit Cloud. This is Phase 1 alone. |
| Improve the phone UX on Streamlit Cloud | Streamlit's mobile rendering is already usable; a PWA manifest is near-free. Cheaper than a rewrite; does not touch the data model. |
| Native HTML rewrite with a free-tier host (Render/Fly/HF/Vercel) | $0 at low volume but with sleep/limits and a new ops surface; trades Streamlit's simplicity for a build/deploy pipeline. Only worth it if the phone UX is genuinely painful day-to-day. |
| Static site + browser talks to Turso directly | Rejected: CORS undocumented, read-write token exposed, and server-side scrapers/API keys make it unworkable. |
| Fully native Flutter Android app | A second codebase, not "based on the desktop version"; the most work for the least reuse. |
| **Native Android + Turso Sync directly** | No Python host needed (Turso free tier is the only server); offline-first; weekend finder works (Fraport is key-free). Trade-offs: two frontends unless the PC also goes native, and API keys must be embedded or those features degrade. See sec. 10. |
| LAN-only PC-hosted backend | Phone works only at home; a no-cost option if cellular access is never needed. |

## 10. Variant: a native Android app (not a PWA)

This reframes the whole thing. A **native Android app does not need a
hosted Python backend** -- which removes the blocker I cited in sec. 5.
Instead of "phone opens a web URL", the phone becomes a first-class client
that talks to the **Turso free tier directly** (the only server needed):

* The Android app uses the Turso SDK / SQL-over-HTTP to hold a **local
  SQLite/Turso file and sync via `push()`/`pull()`** -- exactly Turso Sync's
  offline-first use case. No Python host of yours required; Turso is a SaaS
  like Streamlit Cloud.
* It works **off-line**: writes land in the local file and push later.
  (This is strictly better than a PWA here -- a browser cannot keep a local
  SQLite file.)
* **Data layer is identical to Phase 1** -- same Turso schema, same PC data
  if the PC also moves to Turso (see below).
* The **weekend finder** works too: the Fraport JSON endpoint
  (documented in `WEEKEND_FINDER_PLAN.md`) needs no key and can be called
  from the phone directly, with results cached in Turso.

The remaining costs of "native vs PWA":

| Cost | Detail |
|---|---|
| Two frontends | The phone is native (Kotlin/Java/C++) while the PC is Python/Streamlit. They share the **data layer + pure logic**, but not the **UI code** -- unless the PC also goes native. |
| API keys on the phone | DeepSeek populate, Unsplash/DDG galleries, AQI/IQAir are key-gated. For a *personal, single-user* app embedding the keys in the APK is a pragmatic compromise (you are the only attacker); otherwise those features are phone-degraded. DDG and Fraport are key-free. |
| Your time | You must build, sign and sideload the APK (or pay the $25 Play registration). A PWA is zero-build; native is not. |
| "Based on the desktop version" | If the PC stays Streamlit, the Android app does not share UI code with it -- so strictly, it is *not* "based on the desktop version". To make that phrase true, the PC should move to the same native stack. |

**So the real fork is on the *PC* side, not the phone:**

1. **Keep the PC on Streamlit (Streamlit Cloud, free host stays).** Phone
   goes native + Turso; PC stays Streamlit + Turso. Two UIs, one database.
   Lowest risk, but "based on the desktop version" is not literally true.
2. **Move the PC to a shared native stack too** (e.g. Flutter: Android +
   desktop from one codebase, or Tauri/React-Native for Windows). Now the
   Android app *is* based on the desktop version, and there is no Streamlit
   anywhere -- freeing you from Streamlit Cloud entirely. This is the only
   path that is fully faithful to "Android version based on the desktop
   version". Note the libsql_dart quote (sec. 8) becomes relevant here: in
   Flutter use `@tursodatabase/sync` (push/pull), not `libsql_dart`.

**Bottom line for this variant:** a native Android app + Turso Sync is
*more* viable under "no server, no money" than a PWA, because Turso is the
only server and it is free. The trade-off moves from "I have no host" to "I
accept two frontends (or the cost of unifying them) and the APK/key
questions."
