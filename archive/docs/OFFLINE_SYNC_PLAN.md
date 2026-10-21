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
2. **Write journal + drain.** Specification below.
3. **Guards + sync state UI.** A visible sync-state line ("offline — showing
   the snapshot from HH:MM" / "2 edits waiting to sync" / "1 change could
   not be synced") wired to the notes the repositories already return, a
   "Sync now" action next to it, and the settings page documenting the state
   directory and the journal.

## Commit 2 specification — write journal + drain

The previous draft of this plan said "append an operation with the guard
material they ran with". That is under-specified in the one place it
matters: *which* material, and what makes replay safe. This is the contract.

**What is journaled.** Only whole-value writes the user expects to persist:

| Key | Source | Journaled payload |
|---|---|---|
| `destination:<name>` | `saveDestination` (also covers `updateField`, `addDestination`) | the upsert statement |
| `trip:<id>` | `saveTrip` | the upsert + variant/stop/leg statements |
| `open_tabs` | `saveTabs` | the delete + insert statements |

Not journaled: derived caches (geocode, flight boards, AQI, photos), the
benefits and FlightRoutes databases (reads only), and AI populate (a long
network operation whose partial success is already surfaced, not a
point write).

**The payload is the SQL, not a re-encoding of the model.** Each repository
already renders its write as statements, with the LWW guard *baked into the
SQL* (the trip upsert's `WHERE trips.updated_at = …`). Journaling those
statements means replay is byte-identical to the write that failed, so
"nothing may replay that the current guard would refuse" holds by
construction — there is no second serializer to drift.

**Offline vs. refused.** A write is journaled only when the failure is
transport-shaped: `could not reach Turso: …`, `Turso is unavailable (5xx)`,
`Turso returned a non-JSON response`. A 401/403 (bad token) or a statement
error is *not* queued — retrying it would only hide a real problem.

**Status contract.** `saveTrip` gains `TripSaveStatus.queued`; the two
`bool` writers keep `false` and add an out-parameter/counter the shell reads.
`queued` is never `saved`: invariant 2 says a failed write is surfaced, and
"waiting to sync" is the surfacing.

**Superseding.** A new op with an existing key replaces the older one
(same key ⇒ whole-value write ⇒ the newest value is the only one worth
replaying). The dropped op is logged, not silently discarded.

**Drain.** Sequential, in enqueue order, triggered on: app start after the
first successful read, after any successful write, and by the manual "Sync
now" action. No timer, no polling (see non-goals). Per op:

* transport failure → stop the drain, keep this op and everything after it;
* statement error → drop it with an `ErrorLog` line (it will never succeed);
* guard refusal (a trip upsert reporting `0` affected rows) → move the op to
  `write_journal/conflicts.jsonl` and count it. Conflicts are never
  auto-replayed and never silently dropped; resolving one is the user's
  decision (reload vs. overwrite) and is out of scope for commits 2–3.

**Bounded.** The journal is capped (500 ops); past the cap the oldest is
dropped with a logged line — an unbounded queue is its own bug.

**Gap this closes from commit 1.** `open_tabs` has no snapshot, so a queued
tab change could not even be *seen* after a restart offline. Commit 2 adds
the `open_tabs` snapshot (it is a handful of rows) alongside the journal.

**Tests.** Journal round-trip and corruption; supersede; cap; each drain
outcome (applied, statement-error drop, conflict move, transport stop);
repository-level `queued` status for the three writers; open-tabs snapshot.

## Known limits (candidates for a later commit)

* **The journal is not a local write-through cache.** A queued edit is
  *owed*, not *shown*: after a restart without a network, the catalogue and
  trips come from the snapshot, which still holds the pre-edit value, until
  a drain applies the queue. Doing this properly means applying the queued
  ops to the snapshot as they are enqueued (and keeping `saved_at` honest
  while doing it) — worth a commit of its own, and worth doing for trips
  and destinations together rather than for one of them.
* **Conflicts are recorded, not resolved.** They are counted, named in the
  sync line, and kept in `conflicts.jsonl` with their statements; choosing
  "keep mine" or "keep theirs" is a product decision.
* **A partial batch cannot be repaired.** If a variant/stop/leg batch dies
  mid-way, the op is surfaced as failed and is not queued (the trip row
  already landed). Recovery is the user's: reload, then re-save.

## Non-goals

* Derived/scratch caches (geocode, flight boards, AQI) are already per-device
  files with their own rules; they are not journaled.
* The benefits and FlightRoutes databases stay online-only reads for now
  (the offline flight decisions degrade to the live providers' own caches).
* No background polling: drain happens on app start, after a successful
  read/write, and by hand — keeping the app as quiet as it is today.
* No conflict *resolution* UI in commit 3: conflicts are counted and named,
  not merged.
