# OFFLINE_SYNC_PLAN.md — offline-first Phase 5, Option A

**Status: in progress. Commit 1 (snapshot reads) shipped.** Decided by the
user 2026-10-18: hand-rolled, full local-first — no new dependencies, no SDK.

The Turso pipeline client is HTTP-only. With no network, every read fails and
every write returns false — honest, but a phone app that becomes useless in a
train. This plan makes the app *local-first* on both devices: reads answer
from the last known data (clearly labelled), writes queue and replay.

## Why not a Turso sync SDK (the corrected record)

The proposal-doc quotes say "(in Flutter: `@tursodatabase/sync`)". That
package is the **Node/TypeScript** sync SDK — there is **no Dart/Flutter
Turso Sync SDK** to use (corrected 2026-10-18). The remaining native options:

| Option | Why not (for this app) |
|---|---|
| `libsql_dart` embedded replicas | Rust-native toolchain, a 20 MB+ driver replacing one HTTP file; embedded-replica sync must be *enabled on the database* (unverified); the sibling project rejected it for the same reasons |
| Turso Sync via SQLite → hand-rolled push/pull in Dart | no maintained Dart SDK |
| **Hand-rolled local-first over the HTTP pipeline** | keeps the one-file-client design the whole app already uses and its tests fake cheaply; LWW semantics are already the app's contract |

## The three commits

1. **Snapshot reads (done).** `data/offline_cache.dart` keeps
   `offline_snapshot/offline_<dataset>.json` in the per-device state dir next
   to `app_settings.json`. The two "load everything" surfaces —
   destinations and trips — write through on every successful full read and
   serve the snapshot, labelled with its save time and the live failure, when
   a live read fails. Contracts kept: a failed read is a *stated* failure
   (never empty-ambiguous); an empty dataset is a real snapshot; a missing or
   corrupt snapshot file is *no snapshot* (the original failure surfaces);
   a one-row read never writes a snapshot (no fragments).
2. **Write journal + drain.** A JSONL queue in the state dir; offline write
   attempts that the user *expects to persist* (trip saves, destination field
   edits, open tabs) append an operation with the guard material they ran
   with (e.g. the trip's loaded `updated_at`), and the app replays them on
   the next successful connectivity check — each op re-checked for LWW and
   conflicts; a superseded op is dropped with a log line, a conflicted op
   surfaces as such. Nothing may replay that the current guard would refuse.
3. **Guards + UI.** A small visible sync-state line ("offline — showing the
   snapshot from HH:MM" / "2 edits waiting to sync"), wired to the same
   notes the repositories already return, and the settings page documents
   the state directory.

## Non-goals

* Derived/scratch caches (geocode, flight boards, AQI) are already per-device
  files with their own rules; they are not journaled.
* The benefits and FlightRoutes databases stay online-only reads for now
  (the offline flight decisions degrade to the live providers' own caches).
* No background polling: drain happens on app start and after any successful
  write/read surge, keeping the app as quiet as it is today.
