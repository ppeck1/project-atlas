# Project Atlas follow-up matrix

Status date: 2026-07-24
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

- Do not record formal Capsule Edit Truth v1 acceptance until WP6 completes.
- Keep the WP2 follow-up queue attended and single-worker until R-13 and R-14
  each have hosted merge and exact-main proof.

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

WP3 findings A-01, A-02, and A-05 closed after PR #33 merged as `8a90d6e`.
A-03 and A-04 closed after PR #35 merged as `a3c88f6` and post-merge proof
passed on current `main`. The attended single-worker constraint is therefore
retired. A-11 closed after PR #39 merged as `9d753cb` and exact-main proof
passed, so WP3 is closed. A-06, A-07, and A-10 closed after PR #41 merged as
`393ab6b` and exact-main proof passed. A-08 and A-09 closed after PR #43 merged
as `13ff42e`, PR #44 merged the residual duplicate-ingress correction as
`f73c081`, and hosted plus exact-main proof passed. PR #45 merged the canonical
closure evidence as `ff03b34`, so WP4 is closed and its package-specific
attended single-worker constraint is retired.

R-07 through R-10 closed after PR #37 merged as `9d0e792` and exact-main
post-merge proof passed. They provide exact full-backup directory inventory
and bounded, checksummed, Windows-safe project-bundle v2 recovery. R-11 closed
after PR #46 merged as `fce3769`, hosted PR CI run 144 and exact-main push run
145 passed, and local exact-main proof passed. PR #47 merged the canonical
closure evidence as `f228b62`, and exact-closure-main push run 147 passed all
jobs. R-12 closed after PR #50 merged as `6f59203`, its hosted PR check passed
on unchanged retry, and exact-main push run `30056513672` passed. R-13 and
R-14 remain open, so WP2 is not closed. The ledger contains 23 Closed and 28
Open findings.

## Finding ledger

| ID | Pri | Disposition | Status | Package | Finding | Owner | Target PR | Required proof / closure evidence |
|---|---:|---|---|---|---|---|---|---|
| SPA-20260721-R-01 | P0 | Accepted | Closed | WP1 | Destructive recovery moves precede the rollback guard. | Codex | PR #30 | Guarded move/copy/verify transaction and every-move fault proof merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-02 | P0 | Accepted | Closed | WP1 | Rollback retains a partial new target when no original existed. | Codex | PR #30 | Original-presence tracking and missing-original rollback proof merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-03 | P1 | Accepted | Closed | WP1 | The replaced live target is not revalidated before completion. | Codex | PR #30 | Exact inventory/length/SHA-256 verification and corruption rollback proof merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-04 | P1 | Accepted | Closed | WP1 | Parent exits without child plan-acceptance acknowledgement. | Codex | PR #30 | Validated child acknowledgement and early-exit handling merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-05 | P1 | Accepted | Closed | WP1 | Mutable recovery plan carries arbitrary paths and executable path. | Codex | PR #30 | Owned-root atomic v2 plan, strict schema/checksum/identity/path validation, and threat model merged as `1e18ebd`; post-merge focused suite passed 18/18. |
| SPA-20260721-R-06 | P0 | Accepted | Closed | WP2 | Full backup may mix database and file states during concurrent mutation. | Codex | PR #31 | Exclusive backup/mutation coordination, fixed owned-root inventory, source length/SHA-256 recheck, and concurrent document/media proof merged as `31f966c`; post-merge focused suite passed 10/10. Contract: `docs/FULL_BACKUP_SNAPSHOT_CONTRACT.md`. |
| SPA-20260721-R-07 | P1 | Accepted | Closed | WP2 | Full-backup manifest inventory is not exact. | Codex | PR #37 | Strict v1 descriptors, one matching SQLite snapshot, and exact case-folded regular-file inventory reject missing, duplicate, aliased, malformed, linked, and undeclared content. Merged as `9d0e792`; exact-main post-merge proof passed. |
| SPA-20260721-R-08 | P1 | Accepted | Closed | WP2 | Project recovery decodes unbounded ZIP content in memory. | Codex | PR #37 | File-backed two-pass recovery enforces pre-decode source/directory/entry limits plus actual compressed, per-entry, metadata, and aggregate expansion bounds with forged-header proof. Merged as `9d0e792`; exact-main post-merge proof passed. |
| SPA-20260721-R-09 | P1 | Accepted | Closed | WP2 | Project bundle integrity lacks per-file cryptographic proof. | Codex | PR #37 | Manifest v2 exact path/kind/bytes/SHA-256 inventory and second-pass rebinding reject missing, extra, modified, malformed, wrong-kind, and source-swapped payloads. Merged as `9d0e792`; exact-main post-merge proof passed. |
| SPA-20260721-R-10 | P1 | Accepted | Closed | WP2 | Archive path validation is not canonical Windows containment validation. | Codex | PR #37 | Platform-independent Windows path, alias, ancestor, and containment checks reject traversal, drive, ADS, device, control, invalid-character, trailing-dot/space, and preexisting-stage inputs. Merged as `9d0e792`; exact-main post-merge proof passed. |
| SPA-20260721-R-11 | P2 | Accepted | Closed | WP2 | Failed backup/staging operations retain ambiguous partial artifacts. | Codex | PR #46/#47 | Typed incomplete/failed sibling paths, operation-owned no-follow markers, serialized terminal promotion/failure, bounded persisted cleanup, Windows reparse/8.3 validation, and active-operation race handling merged as `fce3769`; hosted PR CI run 144, exact-implementation-main push run 145, local exact-main proof, canonical closure PR #47 at `f228b62`, and exact-closure-main push run 147 passed. |
| SPA-20260721-R-12 | P2 | Accepted | Closed | WP2 | Recovery artifacts have no retention policy. | Codex | PR #50 | Two-phase bounded age/size retention, exact snapshot revalidation, newest valid safety-backup exclusion, active-plan preservation, operator preview, local audit, and recovery-mutation locking merged as `6f59203`; hosted PR CI run `30052185036` passed on unchanged retry and exact-main push run `30056513672` passed. Contract: `docs/RECOVERY_ARTIFACT_RETENTION_CONTRACT.md`. |
| SPA-20260721-R-13 | P2 | Needs verification | Open | WP2 | Portable export builds the full archive in memory. | Unassigned | TBD | Streaming/isolate export with progress, cancellation, and bounds. |
| SPA-20260721-R-14 | P2 | Needs verification | Open | WP2 | DOCX/HTML extraction uses synchronous unbounded reads. | Unassigned | TBD | Async/isolate extraction with source and expanded-size limits. |
| SPA-20260721-A-01 | P0 | Accepted | Closed | WP3 | LLM claim is a select-then-unconditional-update race. | Codex | PR #33 | Atomic specific-task and claim-next CAS merged as `8a90d6e`; two-connection contention proof passed on merged `main`. |
| SPA-20260721-A-02 | P0 | Accepted | Closed | WP3 | Complete/fail does not enforce lease owner or expiry. | Codex | PR #33 | Worker-plus-attempt CAS with strict expiry and typed conflicts merged as `8a90d6e`; wrong-owner, exact-expiry, and same-worker ABA proof passed on merged `main`. |
| SPA-20260721-A-03 | P0 | Accepted | Closed | WP4 | Proposal side effect and review approval are not atomic/idempotent. | Codex | PR #35 | One transaction claims pending review state, applies every proposal kind, and records stable review/entity/audit results. Merged as `a3c88f6`; post-merge write-boundary rollback, two-connection contention, rejection-race, and replay proof passed. |
| SPA-20260721-A-04 | P0 | Accepted | Closed | WP4 | Task proposals lack a base revision/hash. | Codex | PR #35 | Server-captured canonical task and exact-tag hashes are rechecked before any write. Merged as `a3c88f6`; post-merge missing, stale, moved, malformed, and same-base contention proof passed with typed conflicts and no partial effects. |
| SPA-20260721-A-05 | P0 | Accepted | Closed | WP3 | Completion can create an orphan/duplicate handoff draft. | Codex | PR #33 | Transactional deterministic draft completion merged as `8a90d6e`; post-insert rollback, concurrent/retry deduplication, and service replay proof passed on merged `main`. |
| SPA-20260721-A-06 | P1 | Accepted | Closed | WP4 | Accepted-truth service may mutate non-truth fields. | Codex | PR #41 | Canonical truth keys fail closed; `lessonsLearned` uses a narrow supplemental boundary; mixed AppState/enrichment writes and audits are atomic. Merged as `393ab6b`; exact-main proof passed. Contract: `docs/ACCEPTED_TRUTH_INTEGRITY_CONTRACT.md`. |
| SPA-20260721-A-07 | P1 | Accepted | Closed | WP4 | Source revision lookup bypasses complete ledger verification. | Codex | PR #41 | Source evidence is selected only from a fully verified hash/parent/number/diff chain; corrupt matching or unrelated history fails closed. Merged as `393ab6b`; exact-main proof passed. Contract: `docs/ACCEPTED_TRUTH_INTEGRITY_CONTRACT.md`. |
| SPA-20260721-A-08 | P2 | Accepted | Closed | WP4 | Repeated history reads verify the entire chain. | Codex | PR #43 | Schema-v27 clean checkpoints, atomic checkpoint advancement, bounded head/page reads, explicit full audit, and hostile migration/corruption/rollback/read-count proof merged as `13ff42e`; exact-main proof passed at `f73c081`. Contract: `docs/ACCEPTED_TRUTH_INTEGRITY_CONTRACT.md`. |
| SPA-20260721-A-09 | P2 | Accepted | Closed | WP4 | Explicit empty tags cannot clear a task's tags. | Codex | PR #43/#44 | Explicit task-tag intent distinguishes absent, empty, and non-empty values; strict current/legacy validation, MCP no-draft rejection, rollback/retry proof, and the residual case-insensitive duplicate-ingress correction merged as `13ff42e` and `f73c081`; exact-main proof passed. Contract: `docs/PROPOSAL_ACCEPTANCE_INTEGRITY_CONTRACT.md`. |
| SPA-20260721-A-10 | P1 | Accepted | Closed | WP4 | Manifest truth and tags are accepted separately. | Codex | PR #41 | Server-owned composite truth/project-tag snapshot is revalidated before atomic truth, supplemental, tag, review, and audit writes; unverifiable replay fails closed. Merged as `393ab6b`; exact-main proof passed. Contract: `docs/ACCEPTED_TRUTH_INTEGRITY_CONTRACT.md`. |
| SPA-20260721-A-11 | P1 | Accepted | Closed | WP3 | Raw queue table lacks foreign-key and state constraints. | Codex | PR #39 | Schema v26 fail-closed rebuild, foreign keys, ownership triggers, exact scalar/enum/JSON/state/chronology constraints, valid legacy-state preservation, invalid migration rollback, and `foreign_key_check` proof merged as `9d753cb`; exact-main post-merge proof passed. Contract: `docs/QUEUE_SCHEMA_INTEGRITY_CONTRACT.md`. |
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
| SPA-20260721-D-01 | P1 | Accepted | Open | WP6 | Current-schema documentation can drift from the runtime schema. | Unassigned | TBD | All current-state docs agree with code; automated drift check passes. |
| SPA-20260721-D-02 | P1 | Accepted | Open | WP6 | Capsule Edit Truth v1 lacks a recorded formal acceptance decision. | Unassigned | TBD | Current build/copied-database checklist records accepted/rejected/follow-ups. |
| SPA-20260721-D-03 | P1 | Needs verification | Open | WP6 | Real migration coverage is stale, inconsistent, and normally skipped. | Unassigned | TBD | Sanitized/deterministic old schemas prove current-schema v27 preservation, Capsule ledger guards, and queue integrity guards. |
| SPA-20260721-D-04 | P2 | Needs verification | Open | WP11 | CI is broad but incompletely pinned and self-auditing. | Unassigned | TBD | Pinned toolchain/deps, format/generation diff, privacy/freshness, artifact scans. |
| SPA-20260721-D-05 | P2 | Needs verification | Open | WP11 | Large architectural concentrations remain regression risks. | Unassigned | TBD | Extract-as-you-touch work tied to functional changes and typed diagnostics. |
| SPA-20260721-D-06 | P3 | Needs verification | Open | WP11 | Public metadata, captures, reported version, and database opener have stale residue. | Unassigned | TBD | Metadata/version/capture manifest and truthful database opener naming. |

## Progress evidence

### WP2 R-12 closure — 2026-07-24

PR #50 merged as `6f59203`. R-12 is closed after hosted CI and exact-main
post-merge proof passed.

- Retention is an explicit operator-driven preview/apply flow with no startup
  or scheduled deletion.
- Age and aggregate-size selection are bounded by hard scan, candidate, entry,
  byte, and metadata-read limits. Scan exhaustion, malformed metadata, links,
  unmanaged children, and invalid safety backups fail closed.
- Candidate IDs bind artifact kind, path, and a bounded content fingerprint.
  Apply repeats discovery under the shared recovery-artifact lock and deletes
  only exact, unchanged preview selections.
- Every registered active plan and its rollback/staging state are retained.
  The newest valid safety backup per root is retained regardless of age or
  aggregate pressure.
- Focused recovery retention, locking, and live-plan suite: 35/35.
- Broader recovery/export/import integration selection: 130/130.
- Full Flutter suite: 615 passed with 1 intentional skip.
- Static analysis: clean.
- Python policy/maintenance suite: 30/30.
- Windows release build: passed.
- Hosted PR run `30052185036` first hit a fixed 30-second timeout in an
  existing schema-migration test after every R-12 test passed. Its unchanged
  retry passed all gates, and exact-main push run `30056513672` repeated the
  complete proof on `6f59203`.
- R-13 and R-14 remain open, so WP2 remains open and its attended
  single-worker follow-up constraint remains in force.

### WP2 R-11 closure — 2026-07-23

PR #46 merged as `fce3769`, and PR #47 merged the canonical closure evidence
as `f228b62`. R-11 is closed after hosted CI and exact-main proof passed.

- Full backups, full-backup staging restores, and project-bundle staging use
  typed `.atlas-incomplete-<operationId>` working paths and promote only after
  ordinary completion evidence and validation succeed.
- Failure is terminal and serialized. Owned failures are quarantined under
  typed failed paths; ownership/publication collisions retain the typed
  incomplete path and never overwrite evidence.
- Persisted cleanup is bounded by direct-child scan, candidate, entry, byte,
  and minimum-age limits; links, malformed ownership, over-budget trees, and
  mutations between validation and deletion are refused.
- Windows directory validation rejects reparse points without misclassifying
  safe 8.3 aliases; markers are no-follow regular files; active operation IDs
  are registered before publication and released on every begin failure.
- Hosted run 143 exposed the Windows 8.3 alias regression. Commit `6849a2d`
  corrected it, hosted PR CI run 144 passed all jobs, and exact-main push run
  145 repeated the hosted proof on `fce3769`.
- Closure PR CI run 146 passed on retry after an isolated local 13/13
  queue-lease run confirmed the first attempt's hosted parallel SQLite
  contention was transient; no production change was required.
- Exact-closure-main push run 147 passed generation, policy, analysis, MCP
  adapter, full tests, Windows release, seeded fixture, and gateway smoke on
  `f228b62`.
- Exact-main focused lifecycle/full-backup/project-recovery suite: 63/63.
- Exact-main full Flutter suite: 598 passed with 1 intentional skip.
- Exact-main static analysis: clean.
- Exact-main Python policy/maintenance suite: 30/30.
- Exact-main Windows release build: passed.
- R-13 and R-14 remain open, so WP2 remains open and its attended
  single-worker follow-up constraint remains in force.

### WP4 A-08/A-09 closure — 2026-07-22

PR #43 merged as `13ff42e`; PR #44 merged the residual A-09
duplicate-ingress correction as `f73c081`. A-08 and A-09 are closed after
hosted and exact-main post-merge proof passed on clean `main` at `f73c081`.
PR #45 merged the canonical closure evidence as `ff03b34`.

- Schema v27 creates verified project-scoped ledger checkpoints only after a
  complete legacy-chain audit. Accepted writes append and advance the
  checkpoint atomically; dirty, missing, forged, corrupt, or contended state
  fails closed without partial project or revision changes.
- Ordinary truth loads read the indexed head, history pages read at most
  `limit + 1` rows with page-boundary verification, and explicit full audits
  remain available without repairing or blessing invalid state.
- Task proposals distinguish omitted, explicitly empty, and non-empty tag
  intent. Current and legacy malformed envelopes fail pending before writes;
  MCP rejects null, scalar, mixed, blank, exact-duplicate, and trimmed
  case-insensitive duplicate arrays without creating a draft.
- Exact-main full Flutter suite: 563 passed with 1 intentional skip.
- Exact-main static analysis: clean.
- Exact-main Python policy/maintenance suite: 30/30.
- Exact-main Windows release build: passed.
- Hosted PR #43 and PR #44 checks passed, including the required build gate.
- WP4 is closed.

### WP4 A-06/A-07/A-10 closure — 2026-07-22

PR #41 merged as `393ab6b`; PR #42 records the canonical closure. A-06, A-07,
and A-10 are closed after focused and full post-merge proof passed on exact
clean `main`.

- Canonical accepted-truth routing rejects unknown and supplemental keys;
  mixed truth, supplemental metadata, derived tags, and audits are atomic.
- Source evidence is selected only from a completely verified immutable
  revision chain; corrupt matching or unrelated ancestors fail closed.
- Manifest proposals bind verified truth and exact raw project-tag state in a
  server-owned composite snapshot revalidated before every domain write.
- Hostile proof covers stale cross-domain races, absent versus empty tags,
  malformed/legacy snapshots, dangling assignments, ambiguous tag names,
  partial replay, deleted projects, rollback, replay, and contention.
- Focused truth, metadata, proposal, agent, MCP, and enrichment suite: 159/159.
- Full Flutter suite: 545 passed with 1 intentional skip.
- Static analysis: clean.
- Python policy/maintenance suite: 30/30.
- Generated-code build: passed with no tracked generated diff.
- Windows release build: passed.
- Hosted PR #41 CI passed, including generation, policy, analysis, full tests,
  Windows release, seeded MCP fixture, and gateway smoke.
- PR #42 scopes a two-minute test bound to the four intentional
  two-connection proposal contention proofs whose SQLite busy wait is 30
  seconds; production behavior and assertions are unchanged.
- A-08 and A-09 subsequently closed under the evidence above. PR #45 merged
  their canonical closure, so WP4 is closed and its package-specific attended
  single-worker constraint is retired.

### WP3 A-11 closure — 2026-07-22

PR #39 merged as `9d753cb`. A-11 is closed after focused, hostile migration,
full-suite, policy, analysis, and Windows release proof passed on exact clean
`main`.

- Queue schema, lease, and stream suite: 26/26 passed.
- Independent hostile and migration selection: 15 passed with 1 intentional
  external-fixture skip.
- Full Flutter suite: 521 passed with 1 intentional skip.
- Static analysis: clean.
- Python policy/maintenance suite: 30/30.
- Windows release build: passed.
- Hosted PR #39 CI passed, including generation, policy, analysis, full tests,
  Windows release, seeded MCP fixture, and gateway smoke.
- WP3 is closed. The then-next A-06/A-07/A-10 package subsequently closed
  under the exact-main evidence recorded above.

### WP2 R-07/R-10 closure — 2026-07-22

PR #37 merged as `9d0e792`. R-07 through R-10 are closed after focused and
full post-merge proof passed on exact current `main`.

- Full-backup v1 validation requires strict descriptors and exact regular-file
  inventory, including one matching SQLite snapshot.
- Project recovery performs bounded pre-decode ZIP structure validation and
  enforces actual compressed and expanded byte limits while streaming.
- Project-manifest v2 binds every payload path, kind, byte length, and SHA-256;
  extraction repeats preflight and rebinds the exact validated descriptors.
- Platform-independent Windows rules reject traversal, aliases, device names,
  invalid characters, ancestor collisions, and unsafe or reused stage roots.
- Focused full-backup and hostile project-recovery suite: 28 tests passed.
- Production project-export suite, including export-to-staging recovery: 5
  tests passed.
- Full Flutter suite: 511 tests passed with 1 intentional skip.
- Static analysis: clean.
- Python policy/maintenance suite: 30 tests passed.
- Windows release build: passed.
- Hosted PR #37 CI passed, including generated-code verification, analysis,
  full tests, Windows release build, seeded MCP fixture, and gateway smoke.
- R-12 subsequently closed under the evidence above. R-13 and R-14 remain
  open, so WP2 remains open.

### WP4 A-03/A-04 closure — 2026-07-21

PR #35 merged as `a3c88f6`. A-03 and A-04 are closed after focused and full
post-merge proof passed on current `main`.

- Proposal-integrity suite: 18 tests passed.
- Focused proposal, service, and MCP suite: 54 tests passed.
- Every proposal kind shares the pending-draft claim, domain side effects,
  stable review result, and audit event transaction; injected failures at each
  write boundary roll back without partial effects.
- Two independent SQLite connections prove one terminal approve/reject winner,
  stable approved replay, and one winner for same-base task proposals.
- Canonical server-captured task and exact-tag hashes reject missing, stale,
  moved, malformed, or changed-tag proposals before tag creation or mutation.
- Full Flutter suite: 495 tests passed with 1 intentional skip.
- Static analysis: clean.
- Python policy/maintenance suite: 30 tests passed.
- Windows release build: passed.
- Hosted PR #35 CI passed, including generated-code verification, analysis,
  full tests, Windows release build, seeded MCP fixture, and gateway smoke.
- The attended single-worker constraint was retired only after this post-merge
  evidence passed. A-06 through A-10 subsequently closed under the evidence
  above, so WP4 is closed.

### WP3 A-01/A-02/A-05 closure — 2026-07-21

PR #33 merged as `8a90d6e`. A-01, A-02, and A-05 are closed after the focused
and full post-merge proof passed on current `main`.

- Focused queue, service, MCP, and stream suite: 52 tests passed.
- Two independent SQLite connections prove exactly one winner for both a
  specific-task claim and claim-next selection.
- Worker ID, lease attempt, status, and strict lease expiry are enforced in the
  terminal CAS; wrong-owner, expired, stale-attempt, invalid-state, and
  idempotency conflicts are typed.
- Completion and deterministic handoff-draft insertion share one transaction;
  post-insert fault injection rolls both back, concurrent/retried completion
  creates one draft, and replay survives mutable project-title changes.
- Full Flutter suite: 477 tests passed with 1 intentional skip.
- Static analysis: clean.
- Python policy/maintenance suite: 30 tests passed.
- Windows release build: passed.
- Hosted PR #33 CI passed, including generated-code verification, analysis,
  full tests, Windows release build, seeded MCP fixture, and gateway smoke.
- Post-merge full Flutter suite: 477 tests passed with 1 intentional skip.
- Post-merge static analysis: clean.
- Post-merge Python policy/maintenance suite: 30 tests passed.

### WP2 R-06 local slice — 2026-07-21

R-06 closed after PR #31 merged as `31f966c` and the focused full-backup
suite passed 10/10 on current `main`.

- Focused full-backup suite: 10 tests passed.
- Concurrent database/document/media mutation waits behind the snapshot and
  changes live state only after the captured database and files are complete.
- A snapshot waits for an already-running owned-file mutation and captures its
  completed database-plus-file state.
- Out-of-band source-byte changes during copy fail closed; source inventory is
  rechecked before bundle certification.
- Full Flutter suite: 460 tests passed with 1 intentional skip.
- Static analysis: clean.
- Python policy/maintenance suite: 30 tests passed.
- Windows release build: passed.
- Hosted PR #31 CI passed on 2026-07-21, including the seeded isolated MCP
  gateway smoke.

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
