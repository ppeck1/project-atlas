# Project Atlas follow-up matrix

Status date: 2026-07-21  
Authority: canonical live follow-up ledger for the 2026-07-21 second-pass audit  
Source: [preserved audit artifact](audits/PROJECT_ATLAS_SECOND_PASS_AUDIT_2026-07-21.txt)

This matrix is the only live status authority for these findings. The source
audit remains immutable evidence, and the parent-folder July 20 assessment
matrix is historical. Finding IDs are prefixed with `SPA-20260721` to prevent
collisions with earlier `A01`-style assessment IDs.

The audit narrative reports 49 findings, but the matrices contain 51. All 51
are represented below. `Accepted` means the finding was spot-checked against
current `main`; `Needs verification` means it still requires repository-level
reproduction or design disposition before implementation.

## Immediate operating constraints

- Treat the LLM queue as single-worker and attended until SPA-20260721-A-01
  through SPA-20260721-A-05 are verified closed.
- Do not record formal Capsule Edit Truth v1 acceptance until WP6 completes.
- Start Workboard Agency work only after the P0 integrity packages close.

## Work packages and order

| Order | Package | Scope | Exit condition |
|---:|---|---|---|
| 1 | WP1 — replacement atomicity | R-01–R-05 | Fault injection covers every destructive step, rollback removes partial targets, the final live target is revalidated, and the one-time child handoff is bounded and acknowledged. |
| 2 | WP2 — backup and bundle integrity | R-06–R-14 | A point-in-time owned-file contract, exact manifests, bounded archive/extraction behavior, and incomplete-artifact handling are verified. |
| 3 | WP3 — queue lease safety | A-01–A-02, A-05, A-11 | Claims and terminal transitions use lease-owner CAS rules; retries are idempotent; invalid queue states are rejected. |
| 4 | WP4 — proposal acceptance safety | A-03–A-04, A-06–A-10 | Proposal application is crash-idempotent, stale changes fail closed, and truth/tag transactions have explicit concurrency contracts. |
| 5 | WP5 — workload semantics | A-12–A-15 | Invalid and stale planning data fail closed and recommendations preserve identity, actor, gate, verification, and WIP rationale. |
| 6 | WP6 — truth and documentation closure | D-01–D-03 | Schema documentation and migration proof agree with runtime; formal Phase 1 decision is recorded. |
| 7 | WP7 — runtime process safety | O-01–O-04, O-08–O-09 | Child processes, logs, readiness, refresh outcomes, and UI-isolate work are bounded and observable. |
| 8 | WP8 — local security and MCP | O-05–O-07, O-10 | Temporary command data and secret storage are hardened; autostart and local JSON-RPC contracts are truthful and bounded. |
| 9 | WP9 — Workboard Agency v1 | U-01–U-05 | Workboard is a responsive Capsule-derived projection with revision refresh and plain-language presentation. |
| 10 | WP10 — usefulness measurement | U-06 | A local benchmark records resume and delegation outcomes without outbound telemetry. |
| 11 | WP11 — CI and maintainability | D-04–D-06 | Reproducibility gates and bounded extract-as-you-touch cleanup are delivered. |

## Finding ledger

| ID | Pri | Disposition | Status | Package | Finding | Owner | Target PR | Required proof / closure evidence |
|---|---:|---|---|---|---|---|---|---|
| SPA-20260721-R-01 | P0 | Accepted | Closed | WP1 | Destructive recovery moves precede the rollback guard. | Codex | PR #30 | Guarded move/copy/verify transaction and every-move fault proof merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-02 | P0 | Accepted | Closed | WP1 | Rollback retains a partial new target when no original existed. | Codex | PR #30 | Original-presence tracking and missing-original rollback proof merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-03 | P1 | Accepted | Closed | WP1 | The replaced live target is not revalidated before completion. | Codex | PR #30 | Exact inventory/length/SHA-256 verification and corruption rollback proof merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-04 | P1 | Accepted | Closed | WP1 | Parent exits without child plan-acceptance acknowledgement. | Codex | PR #30 | Validated child acknowledgement and early-exit handling merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-05 | P1 | Accepted | Closed | WP1 | Mutable recovery plan carries arbitrary paths and executable path. | Codex | PR #30 | Owned-root atomic v2 plan, strict schema/checksum/identity/path validation, and threat model merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-06 | P0 | Needs verification | Open | WP2 | Full backup may mix database and file states during concurrent mutation. | Unassigned | TBD | Concurrent mutation test proves one point-in-time ownership contract. |
| SPA-20260721-R-07 | P1 | Needs verification | Open | WP2 | Bundle manifest inventory is not exact. | Unassigned | TBD | Missing, duplicate, and undeclared files all fail validation. |
| SPA-20260721-R-08 | P1 | Needs verification | Open | WP2 | Project recovery decodes unbounded ZIP content in memory. | Unassigned | TBD | Source, entry-count, per-entry, and expanded-size limits with hostile fixtures. |
| SPA-20260721-R-09 | P1 | Needs verification | Open | WP2 | Project bundle integrity lacks per-file cryptographic proof. | Unassigned | TBD | Exact path/kind/size/SHA-256 manifest rejects all mutations. |
| SPA-20260721-R-10 | P1 | Needs verification | Open | WP2 | Archive path validation is not canonical Windows containment validation. | Unassigned | TBD | Traversal, drive, ADS, device-name, control, and trailing-dot/space tests. |
| SPA-20260721-R-11 | P2 | Needs verification | Open | WP2 | Failed backup/staging operations retain ambiguous partial artifacts. | Unassigned | TBD | `.incomplete` lifecycle and bounded cleanup/quarantine tests. |
| SPA-20260721-R-12 | P2 | Needs verification | Open | WP2 | Recovery artifacts have no retention policy. | Unassigned | TBD | Local previewed retention preserves newest safety backup and active plan. |
| SPA-20260721-R-13 | P2 | Needs verification | Open | WP2 | Portable export builds the full archive in memory. | Unassigned | TBD | Streaming/isolate export with progress, cancellation, and bounds. |
| SPA-20260721-R-14 | P2 | Needs verification | Open | WP2 | DOCX/HTML extraction uses synchronous unbounded reads. | Unassigned | TBD | Async/isolate extraction with source and expanded-size limits. |
| SPA-20260721-A-01 | P0 | Accepted | Open | WP3 | LLM claim is a select-then-unconditional-update race. | Unassigned | TBD | Two simultaneous connections produce exactly one winner. |
| SPA-20260721-A-02 | P0 | Accepted | Open | WP3 | Complete/fail does not enforce lease owner or expiry. | Unassigned | TBD | Wrong and expired workers receive typed lease conflicts. |
| SPA-20260721-A-03 | P0 | Accepted | Open | WP4 | Proposal side effect and review approval are not atomic/idempotent. | Unassigned | TBD | Crash after side effect plus retry applies exactly once. |
| SPA-20260721-A-04 | P0 | Needs verification | Open | WP4 | Task proposals lack a base revision/hash. | Unassigned | TBD | CAS rejects stale task and tag-set proposals. |
| SPA-20260721-A-05 | P0 | Accepted | Open | WP3 | Completion can create an orphan/duplicate handoff draft. | Unassigned | TBD | Deterministic task-attempt key makes completion retry-idempotent. |
| SPA-20260721-A-06 | P1 | Needs verification | Open | WP4 | Accepted-truth service may mutate non-truth fields. | Unassigned | TBD | Unknown truth keys fail closed or move to a separate contract. |
| SPA-20260721-A-07 | P1 | Needs verification | Open | WP4 | Source revision lookup bypasses complete ledger verification. | Unassigned | TBD | Source matches are resolved only from a verified chain. |
| SPA-20260721-A-08 | P2 | Needs verification | Open | WP4 | Repeated history reads verify the entire chain. | Unassigned | TBD | Write/checkpoint verification plus paged audit behavior and performance proof. |
| SPA-20260721-A-09 | P2 | Needs verification | Open | WP4 | Explicit empty tags cannot clear a task's tags. | Unassigned | TBD | Present-empty differs from absent and clears tags in tests. |
| SPA-20260721-A-10 | P1 | Needs verification | Open | WP4 | Manifest truth and tags are accepted separately. | Unassigned | TBD | Atomic metadata/tag acceptance with tag concurrency token. |
| SPA-20260721-A-11 | P1 | Needs verification | Open | WP3 | Raw queue table lacks foreign-key and state constraints. | Unassigned | TBD | Invalid-state migrations/tests and `foreign_key_check` pass. |
| SPA-20260721-A-12 | P1 | Needs verification | Open | WP5 | Malformed planning values fail open to executable defaults. | Unassigned | TBD | Unknown values enter a review lane and cannot become ready. |
| SPA-20260721-A-13 | P1 | Needs verification | Open | WP5 | Stale work is promoted in execution ranking. | Unassigned | TBD | Stale items require revalidation and ranking fixtures prove ordering. |
| SPA-20260721-A-14 | P2 | Needs verification | Open | WP5 | Invalid workload filters silently normalize to valid filters. | Unassigned | TBD | Invalid arguments return allowed-value diagnostics. |
| SPA-20260721-A-15 | P2 | Needs verification | Open | WP5 | Recommendation semantics do not represent shared agency/WIP. | Unassigned | TBD | Structured recommendation includes identity, actors, gate, proof, and rationale. |
| SPA-20260721-O-01 | P1 | Needs verification | Open | WP7 | Runtime timeout does not reliably terminate the process tree. | Unassigned | TBD | Bounded output and verified child-tree termination on timeout. |
| SPA-20260721-O-02 | P1 | Needs verification | Open | WP7 | Runtime stdout/stderr collection is unbounded. | Unassigned | TBD | Ring-buffer truncation and redacted retained-log tests. |
| SPA-20260721-O-03 | P2 | Needs verification | Open | WP7 | Health URLs suppress port checks and accept overly broad statuses. | Unassigned | TBD | Explicit all/any policy validates both signals and configured statuses. |
| SPA-20260721-O-04 | P2 | Needs verification | Open | WP7 | Modeled stop/autostart commands have no runtime action. | Unassigned | TBD | Implement audited actions or remove claims and inactive controls. |
| SPA-20260721-O-05 | P1 | Needs verification | Open | WP8 | Persistent temp PowerShell wrappers expose inline command data. | Unassigned | TBD | Restricted ACL, secret references, cleanup retention, and redaction. |
| SPA-20260721-O-06 | P2 | Needs verification | Open | WP8 | MCP autostart log files are not wired and result is ignored. | Unassigned | TBD | Real redirection plus durable visible last-run state. |
| SPA-20260721-O-07 | P1 | Needs verification | Open | WP8 | DPAPI store writes are non-atomic and corruption fails open to empty. | Unassigned | TBD | Atomic replace, backup, quarantine, and explicit corruption state. |
| SPA-20260721-O-08 | P1 | Needs verification | Open | WP7 | Capsule identity inspection performs synchronous filesystem work on UI isolate. | Unassigned | TBD | Async/isolate work with cancellation, timeout, bounds, and revision cache. |
| SPA-20260721-O-09 | P2 | Needs verification | Open | WP7 | Refresh partial failures and scheduled errors are inconsistent. | Unassigned | TBD | Structured outcomes, caught scheduler errors, backoff, and visible last run. |
| SPA-20260721-O-10 | P2 | Needs verification | Open | WP8 | Trusted-local MCP schemas and JSON-RPC validation are permissive. | Unassigned | TBD | Strict schemas/envelope, notification behavior, typed errors, and input cap. |
| SPA-20260721-U-01 | P1 | Needs verification | Open | WP9 | Workboard is not a Capsule-derived agency/acceptance projection. | Unassigned | TBD | Lanes derive from Capsule without becoming another authority. |
| SPA-20260721-U-02 | P1 | Needs verification | Open | WP9 | Capsule and Workboard snapshots do not react to newer revisions. | Unassigned | TBD | Project revision stream or explicit newer-state banner. |
| SPA-20260721-U-03 | P2 | Needs verification | Open | WP9 | Workboard is horizontally clipped and top-heavy. | Unassigned | TBD | Responsive capture and interaction checks at supported viewport/text scale. |
| SPA-20260721-U-04 | P2 | Needs verification | Open | WP9 | Capsule flagship presentation leads with identifiers/failure state. | Unassigned | TBD | Plain-language Act view and separate audit details with healthy primary fixture. |
| SPA-20260721-U-05 | P2 | Needs verification | Open | WP9 | Operations and Library expose internal terminology/empty states. | Unassigned | TBD | Plain-language Sources & Health and useful Library initial selection/state. |
| SPA-20260721-U-06 | P2 | Needs verification | Open | WP10 | The central productivity claim is unmeasured. | Unassigned | TBD | Local benchmark for resume, choice, delegation, acceptance, and rework. |
| SPA-20260721-D-01 | P1 | Accepted | Open | WP6 | Runtime schema 25 conflicts with documentation claiming 24. | Unassigned | TBD | All current-state docs agree with code; automated drift check passes. |
| SPA-20260721-D-02 | P1 | Accepted | Open | WP6 | Capsule Edit Truth v1 lacks a recorded formal acceptance decision. | Unassigned | TBD | Current build/copied-database checklist records accepted/rejected/follow-ups. |
| SPA-20260721-D-03 | P1 | Needs verification | Open | WP6 | Real migration coverage is stale, inconsistent, and normally skipped. | Unassigned | TBD | Sanitized/deterministic old schemas prove v25 preservation and ledger guards. |
| SPA-20260721-D-04 | P2 | Needs verification | Open | WP11 | CI is broad but incompletely pinned and self-auditing. | Unassigned | TBD | Pinned toolchain/deps, format/generation diff, privacy/freshness, artifact scans. |
| SPA-20260721-D-05 | P2 | Needs verification | Open | WP11 | Large architectural concentrations remain regression risks. | Unassigned | TBD | Extract-as-you-touch work tied to functional changes and typed diagnostics. |
| SPA-20260721-D-06 | P3 | Needs verification | Open | WP11 | Public metadata, captures, reported version, and database opener have stale residue. | Unassigned | TBD | Metadata/version/capture manifest and truthful database opener naming. |

## Progress evidence

### WP1 local slice — 2026-07-21

WP1 closed after PR #30 merged as `1e18ebd` and the focused recovery suite
passed 18/18 on current `main`.

- Focused recovery suite: 18 tests passed, covering the success path, every
  database/documents/media/WAL/SHM move boundary, failures during each copy,
  missing-original partial-target rollback, post-copy corruption, valid child
  acknowledgement, worker exit before acknowledgement, owned-root enforcement,
  payload tampering, filename/identity binding, atomic serialization,
  executable-path exclusion, and source/safety path separation.
- Full Flutter suite: 457 tests passed with 1 intentional skip.
- Static analysis: clean.
- Python policy/maintenance suite: 30 tests passed.
- Windows release build: passed and produced
  `build/windows/x64/runner/Release/project_atlas.exe`.
- MCP smoke: not verified in this local slice. A second isolated database-path
  rebuild was terminated after roughly four silent minutes without producing
  a smoke result; no live Atlas database was used.
- Hosted PR #30 CI passed on 2026-07-21, including the seeded isolated MCP
  gateway smoke.
- `R-01` through `R-05` are closed. The guarded-replacement experimental
  constraint has been removed; ordinary recovery still requires the existing
  validation, safety-backup, typed-confirmation, and acceptance safeguards.

## Update protocol

1. Change `Disposition` only after reproducing the finding or recording a
   reasoned duplicate/rejection decision.
2. Move a row to `In progress` only when an owner and target branch/PR exist.
3. Move a row to `Verified` only when its required proof passes on current
   `main`; record the commit or PR in the evidence cell.
4. Move a row to `Closed` only after merge and a post-merge evidence check.
5. Update the status date and package summary whenever rows change.
