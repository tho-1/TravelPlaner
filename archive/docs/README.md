# Archived documents

The plans, proposals, reports and review documents that drove the Flutter
app's build. They are **frozen history**, not instructions: every item in
them is implemented, or explicitly closed with a reason (the two exceptions
are named in the table below). The live description of the app is
[`../../README.md`](../../README.md) and [`../../AGENTS.md`](../../AGENTS.md).
Keep them for the *why* — the reasoning, the rejected alternatives and the
probes that decided them.

| Document | What it decided | Where the live content went |
|---|---|---|
| `NATIVE_HTML_PLAN.md` | The architecture: off Streamlit, onto a native desktop + Android app talking to Turso directly; the six build phases | `AGENTS.md` §1 (the orientation) and `archive/README.md` (the frozen apps) |
| `OFFLINE_SYNC_PLAN.md` | Offline-first Phase 5 (Option A): snapshot reads, the write journal, the drain contract, and the limits it deliberately does not cross | `README.md` §"Offline-first (Phase 5, Option A)" — including the "known limits" list, which is still true |
| `TURSO_PLAN.md` | The airline-benefits contract: the table, the semantics that must not drift (a `yes` qualifies, `unknown` never does, an empty read is a failure), the fallback ladder and the failure handling | `README.md` §"The airline-benefits database" |
| `WEEKEND_FINDER_PLAN.md` | The finder's rule book: the day model, the six time bounds, the matcher semantics, the edge cases | `README.md` §"The weekend finder" |
| `PROPOSAL_SHARED_TURSO.md` | Sharing the sibling project's exact-day departure boards (read *and* write-back), the schema-v2 contract, the credential rules | `README.md` §"Shared FlightRoutes departure boards" |
| `PROPOSAL_PICTURES.md` | The destination gallery and hero photo: Unsplash hotlinking, metadata-only persistence, the rights position on scraped images | `README.md` §"Destination photos" |
| `PROJECT_REVIEW.md` | The F1–F10 review of the app (and of the earlier Flutter port): every finding, its severity and its fix. F2 is the one that was closed *with a reason*: the Turso endpoint has no usable transaction, so a partial batch is a surfaced failure mode, not a bug | `AGENTS.md` §5 (the open-items table, row 7) and `PLAN.md` §0y |
| `MOBILE_REPORTS_2026-10-16.md` | The first bug-report batch from the phone (a–j) and the decisions taken on it | `PLAN.md` §0s; the app itself |
| `MOBILE_REPORTS_2026-10-17.md` | The second bug-report batch from the phone (a–ab) and the decisions taken on it — all of them closed by 2026-10-20 | `PLAN.md` §0s/§0t; the app itself |
| `PLAN_TO_FINISH.md` | The 2026-10-18 sweep that closed the review findings and the offline strand | `AGENTS.md` §5 (open items) and `PLAN.md` §0y/§0z |
| `codereview.md` | The review *prompt* used for the 2026-10-10 pass (never committed; kept as the question list) | `PROJECT_REVIEW.md` above |

The session transcripts (`../chat-logs/session-ses_*.md`) are the raw
conversations behind the reports above; they are kept for the same reason
and are not read by anyone.

**Still live, and therefore *not* in this folder:** `PLAN.md` (the full
history) and `testing-gaps-2026-10-20.md`. Everything else in the repository
root is one of the four documents above.
