# Plan to finish everything

**Status 2026-10-18 (evening): the work is done. Two items remain, and both
wait on a person, not on code.**

## What was still outstanding — verified, not assumed

| Item | Was it outstanding? | Now |
|---|---|---|
| Review batch F1–F6, F10 | **Yes** — fixed in the working tree but never committed (last commit `ce16fe6`) | Committed `5bfca56`, pushed; 481 tests at that point |
| F1 regression coverage | **Yes** — the guard's live field was untested | `pipeline_client_test` (four response shapes) + the live-shape conflict/saved pair in `trip_repository_test` |
| F3 coverage | **Yes** — the test still claimed "yes unless it contains an x" | `truthy('extra')` and `truthy('Malaria risk: extremely low')` are false |
| F2 "documented as partial failure" | Half — the *reason* given was wrong | Re-probed: transactions run, but errors do not halt the batch; conditional steps are rejected (400); `on_error` is ignored. Documented accurately, pinned by a test that no `BEGIN`/`COMMIT` is ever sent |
| Offline commit 2 (journal + drain) | **Yes**, and it had no spec | Spec written first, then implemented and tested |
| Offline commit 3 (guards + UI) | **Yes** | Sync-state line, "Sync now", Offline-data settings section |
| F7 (g) AeroAPI key | **No** — the plan overstated it as open coding work | The fallback is implemented, wired into settings and tested; only a key is missing. Optional |
| F7 (i) finder redesign | Partly — the raw-code removal was already done | Only the visual redesign is open, and it needs a description of what looks broken |
| F8 / F9 (perf, file size) | Correctly optional | Unchanged — deliberately not done |
| Release signing | **Yes**, and under-rated as a "nicety" | Wired: `key.properties` (git-ignored) + template; debug-signed fallback kept |
| Doc drift | Wider than F6 | `PLAN` §0y/§0z, `AGENTS` open items, `README` (offline + signing), `NATIVE_HTML_PLAN`; `HANDOFF.md` deleted as it instructed |

## What is genuinely left

1. **F7 (i) — the finder's expanded-result redesign.** Blocked since
   2026-10-17 on a description (or a text-layout paste) of what looks
   broken. Nothing else can be inferred: the raw airport-code line and the
   catalogue-name line are already gone.
2. **F7 (g) — an AeroAPI key**, if the licensed fallback is ever wanted.
   The code path is complete and tested; `config.fallbackFlightsConfigured`
   is false today, so the finder simply never calls it.
3. **A real Android keystore and `applicationId`.** The wiring is in
   place; the key must be created once, before the first release install
   on a device, or that device's offline copy is lost on a later key
   change.

## Deliberately not done

* F8 (split `world_map_page.dart` / `destination_page.dart`) — the review's
  own advice is "only when a change touches them".
* F9 (persistent map-tile cache) — measure first; Flutter's image cache
  already covers the common case.
* Conflict *resolution* UI — conflicts are recorded, counted and named;
  merging is a product decision, not a bug fix.

## Verify

```powershell
cd mobile
& "C:\src\flutter\bin\flutter.bat" analyze   # clean
& "C:\src\flutter\bin\flutter.bat" test      # 518 tests
```
