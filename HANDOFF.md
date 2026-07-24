# Public Maintainer Handoff

## Live audit follow-up

The canonical status ledger for the July 21 second-pass audit is
[`docs/PROJECT_ATLAS_FOLLOW_UP_MATRIX.md`](docs/PROJECT_ATLAS_FOLLOW_UP_MATRIX.md).
It tracks all 51 findings and supersedes the parent-folder July 20 assessment
matrix for operational status. The uploaded audit is preserved unchanged under
[`docs/audits/`](docs/audits/README.md). The supported local security boundary
for the guarded worker is recorded in the
[`live recovery handoff threat model`](docs/RECOVERY_HANDOFF_THREAT_MODEL.md).
The database-plus-owned-files consistency boundary is defined in the
[`full backup snapshot contract`](docs/FULL_BACKUP_SNAPSHOT_CONTRACT.md).

Recovery findings R-01 through R-13 and agent-integrity findings A-01 through
A-11 are closed. R-14 remains open, so WP2 is not fully closed.
The attended single-worker operating constraint was retired only after
A-03/A-04 merged and their post-merge proof passed. A-11's exact-main proof
also passed, so WP3 is closed. A-08/A-09 exact-main proof passed, PR #45
merged the canonical closure evidence, and WP4 is closed. The package-specific
attended single-worker constraint for WP4 is retired. Keep the remaining WP2
follow-up queue attended and single-worker until R-14 has hosted merge and
exact-main proof.

This handoff records the public, portfolio-facing maintenance boundary for
Project Atlas. It is intentionally free of private workspace records, personal
contact data, machine-specific paths, and unrelated project references.

Last updated: 2026-07-24.

## Audit resume checkpoint

Use `b541724` (`Bound portable export resource use (#52)`) as the current
implementation anchor. It is a clean descendant of the R-12 closure anchor
`a1fa583` and contains the R-13 implementation after its hosted PR proof.
Verify that current `main` is a clean descendant of this anchor and that
exact-main push run `30064872862` passed before resuming.

The canonical matrix contains 51 findings: 24 Closed and 27 Open. The
completed integrity sequence is:

- PR #30 / `1e18ebd`: R-01 through R-05 recovery replacement atomicity,
  rollback, final verification, child acknowledgement, and handoff security.
- PR #31 / `31f966c`: R-06 point-in-time database-plus-owned-files backup
  coordination and source-stability checks.
- PR #32 / `3b75760`: R-06 post-merge closure evidence.
- PR #33 / `8a90d6e`: A-01/A-02/A-05 atomic claims, authenticated and
  generation-bound terminal CAS, and transactional retry-idempotent handoff
  drafts.
- PR #34 / `c9a5e36`: A-01/A-02/A-05 post-merge proof and canonical closure
  evidence.
- PR #35 / `a3c88f6`: A-03/A-04 transactional proposal acceptance, stable
  replay, canonical task/tag freshness tokens, typed conflicts, and fault and
  contention proof.
- PR #36 / `5574b77`: A-03/A-04 post-merge proof, canonical closure, and
  retirement of the audit-specific attended single-worker constraint.
- PR #37 / `9d0e792`: R-07 through R-10 exact full-backup inventory, bounded
  two-pass ZIP recovery, project-manifest v2 integrity, and Windows-safe
  staging validation.
- PR #38 / `008ed8d`: R-07 through R-10 post-merge proof and canonical
  closure evidence.
- PR #39 / `9d753cb`: A-11 schema v26 queue constraints plus exact-main
  post-merge proof.
- PR #40 / `f8fed5f`: A-11 evidence-only closure and WP3 completion.
- PR #41 / `393ab6b`: A-06/A-07/A-10 accepted-truth, supplemental metadata,
  verified-source, and composite manifest/tag integrity plus exact-main proof.
- PR #42: A-06/A-07/A-10 canonical closure evidence plus scoped Windows CI
  bounds for the four intentional two-connection proposal contention tests.
- PR #43 / `13ff42e`: A-08 schema v27 durable ledger checkpoints, bounded
  reads and explicit full audit, plus A-09 versioned absent/empty task-tag
  intent and contention proof.
- PR #44 / `f73c081`: residual fail-closed fix and exact-main A-08/A-09 proof.
- PR #45 / `ff03b34`: A-08/A-09 canonical closure evidence, WP4 completion,
  and retirement of the package-specific attended single-worker constraint.
- PR #46 / `fce3769`: R-11 typed incomplete/failed artifact lifecycle,
  Windows alias and reparse-point hardening, no-follow marker validation,
  active-operation race closure, hosted CI, and exact-main proof.
- PR #47 / `f228b62`: R-11 canonical closure evidence after the implementation
  and exact-main proof passed.
- PR #50 / `6f59203`: R-12 two-phase bounded recovery-artifact retention,
  active-plan and newest-safety-backup preservation, exact snapshot
  revalidation, shared recovery locking, hosted CI, and exact-main proof.
- PR #51 / `a1fa583`: R-12 canonical closure evidence after the
  implementation and exact-main proof passed.
- PR #52 / `b541724`: R-13 bounded dedicated-isolate portable export,
  incremental manifest emission, progress and cancellation, exact source
  revalidation, typed partial cleanup, hosted CI, and exact-main proof.
- PR #53: R-13 canonical closure evidence after the implementation and
  exact-main proof passed.

Current verification baseline on exact implementation `main` at `b541724`:

- focused portable-export and document-import suite: 41/41;
- broader portable-export/document-import/operation-status/registry selection:
  103/103;
- full Flutter suite: 622 passed with 1 intentional skip;
- static analysis: clean;
- Python policy/maintenance suite: 30/30;
- Windows release build: passed; and
- hosted PR CI run `30064193299` passed; and
- exact-main push run `30064872862`, including generation, policy, analysis,
  MCP adapter, full tests, Windows release, seeded fixture, and gateway smoke,
  passed on `b541724`.

### Recommended resume sequence

Do not begin implementation until the canonical matrix and current status have
been reviewed. Keep the WP2 queue attended and single-worker throughout:

1. R-14: verify DOCX/HTML extraction behavior, then implement async/isolate
   extraction with source and expanded-size limits. Obtain hosted merge and
   exact-main proof before retiring the WP2 constraint.

### Hosted full-suite serialization

After the handoff-only PR #48 merged, exact-main Actions run `30036321757`
reproduced the hosted Windows queue-isolate timing problem on both attempts.
The failures were confined to `llm_queue_lease_integrity_test.dart`: 30-second
timeouts, Drift channel closure, and locked per-test temporary directories.
The unchanged PR attempt had already passed the full suite, and the focused
queue-lease suite had passed 13/13 with `--concurrency=1`.

The CI full-suite command is therefore serialized with
`flutter test --concurrency=1`. This is test-runner hardening only: it changes
no production behavior and does not reopen A-01, A-02, or A-05. Before
starting R-14, verify that R-13 implementation commit `b541724` and its
exact-main run `30064872862` passed, and keep the WP2 attended single-worker
constraint in force.

### Closed bundle-integrity package

R-07 through R-10 closed after PR #37 merged as `9d0e792`, exact-main
post-merge proof passed, and PR #38 merged as `008ed8d`. The implementation
provides two explicit
subcontracts: exact full-backup v1 directory inventory, and bounded,
checksummed, Windows-safe project-bundle v2 recovery. Historical valid
full-backup v1 bundles remain supported. Project manifest v1 cannot provide
per-file cryptographic proof and therefore fails closed with re-export
guidance; `project_bundle.json` remains schema v1.

The limits, manifest, path, and staging boundary are specified in the
[`bundle recovery integrity contract`](docs/BUNDLE_RECOVERY_INTEGRITY_CONTRACT.md).
R-13 subsequently closed; R-14 remains open, so WP2 is not closed. A-08 and
A-09 are closed,
so WP4 is complete.

### Closed R-11 artifact-lifecycle package

PR #46 merged R-11 as `fce3769`, and PR #47 merged its canonical closure
evidence as `f228b62`. The implementation provides typed incomplete/failed
sibling paths, operation-owned lifecycle markers, serialized terminal
transitions, and bounded persisted cleanup for full backups, full-backup
staging restores, and project-bundle staging. Windows validation rejects
reparse points without misclassifying safe 8.3 aliases, lifecycle markers are
no-follow regular files, and active operation IDs are registered before
publication and released on every begin failure. Hosted implementation PR CI
run 144, exact-implementation-main push run 145, and exact-closure-main push
run 147 passed. Local exact-main proof at `fce3769` passed the focused suite
(63/63), full Flutter suite (598 passed, 1 intentional skip), static analysis,
30 Python policy/maintenance tests, and the Windows release build. R-11 is
closed.

### Closed R-12 artifact-retention package

PR #50 merged R-12 as `6f59203`. Retention is an explicit two-phase local
operator action: preview discovers bounded managed candidates, and apply
repeats discovery under the recovery-artifact lock before deleting only exact
unchanged selections. Age and aggregate-size policy never delete malformed or
unmanaged content, never follow links, retain every registered active plan and
its rollback/staging state, and retain the newest valid safety backup per root.

Local proof passed the focused retention/locking/live-plan suite (35/35), the
broader recovery/export/import selection (130/130), full Flutter suite (615
passed, 1 intentional skip), static analysis, 30 Python policy/maintenance
tests, and the Windows release build. Hosted PR run `30052185036` passed on an
unchanged retry after an unrelated existing migration test hit its fixed
30-second timeout. Exact-main push run `30056513672` then passed generation,
policy, analysis, MCP adapter, all tests, Windows release, seeded fixture, and
gateway smoke on `6f59203`. R-12 is closed; R-13 subsequently closed and R-14
remains open.

### Closed R-13 bounded portable-export package

PR #52 merged R-13 as `b541724`. Portable export now writes a store-mode ZIP
from a dedicated isolate, streams source files without building full payload
or archive buffers, and emits the manifest incrementally to bounded temporary
storage. Hard entry, file, aggregate, manifest, record, and path limits fail
closed; source type, length, and SHA-256 are revalidated around worker reads.
Progress is visible, cancellation waits for the worker resource barrier, typed
partials are removed, and an existing destination is preserved or restored.

Local proof passed the focused portable-export/document-import suite (41/41),
the broader operation integration selection (103/103), full Flutter suite
(622 passed, 1 intentional skip), static analysis, 30 Python
policy/maintenance tests, generated-code verification, and the Windows
release build. Hosted PR run `30064193299` passed. Exact-main push run
`30064872862` then passed generation, policy, analysis, MCP adapter, all
tests, Windows release, seeded fixture, and gateway smoke on `b541724`.
PR #53 records the canonical closure evidence. R-13 is closed; R-14 remains
open.

Earlier R-07 through R-10 post-merge proof on exact implementation `main` at
`9d0e792`:

- focused full-backup and hostile project-recovery suite: 28/28;
- production project-export suite, including export-to-staging recovery: 5/5;
- full Flutter suite: 511 passed with 1 intentional skip;
- static analysis: clean;
- Python policy/maintenance suite: 30/30; and
- Windows release build: passed; and
- hosted PR #37 CI, including seeded isolated MCP smoke: passed.

The recovery lifecycle and hash boundary are specified in the
[`bundle recovery integrity contract`](docs/BUNDLE_RECOVERY_INTEGRITY_CONTRACT.md).

The proposal acceptance boundary is specified in the
[`proposal acceptance integrity contract`](docs/PROPOSAL_ACCEPTANCE_INTEGRITY_CONTRACT.md).

Post-merge proof for the closed A-03/A-04 package on `a3c88f6`:

- proposal-integrity suite: 18/18;
- focused proposal/service/MCP suite: 54/54;
- full Flutter suite: 495 passed with 1 intentional skip;
- static analysis: clean;
- Python policy/maintenance suite: 30/30; and
- Windows release build: passed.

Primary inspection points:

- `lib/services/atlas_agent_service.dart` around proposal approval and
  `_applyProposal` dispatch;
- `lib/shared/models/app_state.dart` proposal side effects and transaction
  boundaries;
- task, tag, truth, and draft persistence in `lib/db/`;
- trusted-local MCP proposal schemas and dispatch in `lib/mcp/`; and
- `test/atlas_agent_service_test.dart` plus MCP proposal integration tests.

### Closed queue-integrity package

Atomic claims, worker-plus-attempt terminal CAS, typed conflicts, and
transactional deterministic handoff drafts are implemented end to end through
AppState and trusted-local MCP. A-01, A-02, and A-05 closed after PR #33 merged
and post-merge proof passed on `8a90d6e`. A-11 closed after PR #39 merged and
exact-main proof passed on `9d753cb`, so WP3 is closed.

### Closed queue-schema integrity package

A-11 merged in PR #39 as `9d753cb`. Schema v26 rebuilds the raw
LLM queue with foreign keys, exact enum/scalar/JSON/state/chronology checks,
and database triggers that preserve project/work-item ownership across raw
writes and reparenting. Invalid v25 rows fail closed without advancing the
schema or replacing the original queue table.

The boundary is specified in the
[`queue schema integrity contract`](docs/QUEUE_SCHEMA_INTEGRITY_CONTRACT.md).
A-11 is closed after exact-main post-merge proof. A-06, A-07, and A-10 are
also closed after PR #41 and exact-main proof at `393ab6b`.

Post-merge proof on exact `main` at `9d753cb`:

- queue schema, lease, and stream suite: 26/26;
- schema and migration regression suite: 77 passed with 1 intentional skip;
- independent hostile and migration selection: 15 passed with 1 intentional
  external-fixture skip;
- full Flutter suite: 521 passed with 1 intentional skip; and
- full static analysis: clean;
- Python policy/maintenance suite: 30/30; and
- Windows release build: passed.

### Closed accepted-truth integrity package

A-06, A-07, and A-10 merged in PR #41 as `393ab6b`. Accepted
truth now rejects non-truth keys; `lessonsLearned` uses a narrow supplemental
service; mixed AppState and identity-enrichment writes share one transaction.
Source recovery selects evidence only from a fully verified revision chain.

Manifest proposals store a server-owned composite truth/project-tag snapshot.
Approval revalidates both halves before truth, supplemental, tag, review, or
audit writes. Raw assignments, dangling tag IDs, ambiguous case variants,
absent-versus-empty tags, stale cross-domain races, deleted projects, and
unverifiable partial replay fail closed with typed conflicts.

The boundary is specified in the
[`accepted truth integrity contract`](docs/ACCEPTED_TRUTH_INTEGRITY_CONTRACT.md).
A-06, A-07, and A-10 are closed after exact-main post-merge proof. A-08 and
A-09 subsequently closed after PR #43 merged as `13ff42e`, PR #44 merged as
`f73c081`, hosted CI passed, and exact-main proof passed. PR #45 merged as
`ff03b34`, WP4 is closed, and the A-08/A-09 package-specific attended
single-worker constraint is retired.

Post-merge proof on exact implementation `main` at `393ab6b`:

- combined truth, metadata, proposal, agent, MCP, and enrichment suite:
  159/159;
- independent A-06/A-07 review: GO;
- independent A-10 review found and drove fail-closed fixes for partial replay,
  case-ambiguous tag rows, and dangling assignments; and
- full Flutter suite: 545 passed with 1 intentional skip;
- full static analysis: clean;
- Python policy/maintenance suite: 30/30;
- generated-code build: passed with no tracked generated diff; and
- Windows release build: passed; and
- hosted PR #41 CI passed, including generation, policy, analysis, full tests,
  Windows release, seeded MCP fixture, and gateway smoke.

### Closed ledger-read and task-tag intent package

A-08 and A-09 merged in PR #43 as `13ff42e`; PR #44 merged the residual
fail-closed fix as `f73c081`. Schema v27 creates verified project-scoped ledger
checkpoints transactionally, invalidates them on revision writes, advances
them with the accepted revision inside one transaction, serves current state
and SQL-paged history through bounded reads, and retains an explicit read-only
full-chain audit. Source replay still verifies the complete chain.

Task proposals now carry versioned server-owned tag mutation intent. Absent
tags preserve assignments, present-empty tags clear them, and present
nonempty tags replace them. Legacy, malformed, stale, rollback, replay, MCP,
and two-connection contention cases fail closed or preserve their documented
compatibility semantics.

Post-merge proof on exact implementation `main` at `f73c081`:

- independent A-08 and A-09 review: GO;
- full Flutter suite: 563 passed with 1 intentional skip;
- full static analysis: clean;
- Python policy/maintenance suite: 30/30;
- Windows release build: passed; and
- hosted CI, including generation, policy, analysis, full tests, Windows
  release, seeded MCP fixture, and gateway smoke: passed.

The two findings and WP4 are closed. PR #45 merged the evidence-only closure,
so the attended single-worker constraint for this package is retired.

## Current public state

- Repository: `ppeck1/project-atlas`
- Default branch: `main`
- Current release line: `v1.4.2` (`1.4.2+3` application build)
- Merge policy: pull request, passing `build` check, linear history, resolved
  conversations, and squash merge
- Public authorship: Paul Peck / `ppeck1`
- README images: captures of the real Windows application using an isolated
  public-safe demo database
- Current database line: schema `27`. Version 23 added
  `documents.deleted_at` soft delete with undo and deferred purge; version 24
  adds the immutable accepted Project Capsule revision ledger and baseline
  migration; version 25 enforces update/delete immutability guards on that
  ledger; version 26 adds foreign-key, enum, and state constraints for the LLM
  task queue; version 27 adds durable verified Capsule ledger checkpoints.
  Project Sources retains reconciliation preview, local/remote source roles,
  and Atlas-only source bookkeeping updates.
- Capsule Resume is the fourth primary navigation surface. It derives Act,
  Understand, and Audit views from one versioned project snapshot; Operations
  remains available at `/operations` as Sources & Health.
- Capsule-authored project truth is editable by a human through field-level
  review and explicit acceptance. Existing project columns remain canonical;
  immutable revisions record accepted history, while derived frontier and
  evidence stay read-only. Agent changes remain proposals, and the remote MCP
  disclosure policy is unchanged.
- Reactive tag and LLM-queue consumers are stream-backed, exact navigation and
  keyboard behavior are covered by tests, project-detail decomposition is in
  progress, and shared design colors use the normalized Atlas token layer.

## Portfolio maintenance invariants

1. Keep the README product- and engineering-outcome forward.
2. Use real application captures; do not substitute illustrated UI mockups.
3. Never capture the maintainer's working Atlas database.
4. Keep personal email, machine-specific paths, operational records, secrets,
   and unrelated projects out of the current public tree and release assets.
5. Preserve Paul Peck / `ppeck1` as public authorship.
6. Keep the remote MCP projection narrower than the trusted local MCP surface.
7. Treat AI output as a proposal until an operator explicitly accepts it.
8. Prefer current generic integration names, but preserve compatible persisted
   settings and structurally valid project metadata when exactly one older
   candidate exists. Current names win; ambiguous fallbacks fail closed.
9. Reconciliation previews may update Atlas records after operator review, but
   they must not mutate the linked source repositories.

## Screenshot refresh procedure

Use an ignored local directory whose name includes `portfolio-capture`.

1. Build Atlas with an isolated database definition:

   ```powershell
   flutter build windows --release --dart-define=ATLAS_DATABASE_PATH=<ignored-capture-database>
   ```

2. Launch that build once so Atlas creates the current schema, then close it.
3. Seed the empty database:

   ```powershell
   python tools\seed_portfolio_capture.py --db <ignored-capture-database>
   ```

4. Relaunch the same build and capture the Today, Projects, Workboard, Capsule,
   and Library surfaces.
5. If another installed or development Atlas instance is running, give the
   capture executable a unique local filename before launch so Windows cannot
   resolve the wrong build.
6. Visually inspect every saved image and verify dimensions, metadata, visible
   text, repository diff, and privacy canaries before staging.
7. Include the Operations Project Sources surface when source topology or
   reconciliation behavior changes.

The capture seeder is fail-closed: it requires an Atlas-initialized database,
requires `portfolio-capture` in the path, and refuses a database that already
contains projects, work items, or documents. It also creates a valid immutable
Capsule baseline for every demo project, so the Resume capture exercises the
same accepted-truth contract as the current application.

## Verification baseline

```powershell
dart run build_runner build
flutter analyze
flutter test
flutter build windows --release
python -m unittest discover -s tools -p "test_*.py" -v
```

For public changes, also verify:

- `git diff --check`
- exact staged file scope
- added-line privacy canaries
- screenshot metadata and visible content
- compiled Windows artifact privacy canaries
- GitHub Actions `build`
- final remote `main`, branch, tag, and release state

## Maintainer map

- Product surfaces: `lib/features/`
- Project Detail composition: `lib/features/projects/project_detail_screen.dart`
  owns screen lifecycle and orchestration; its task header and AI summary
  presentation live in `lib/features/projects/detail/` with typed view models
  and action bundles.
- Capsule product sequence: `docs/CAPSULE_PRODUCT_PLAN.md`
- Capsule contract and projection: `lib/services/project_capsule_service.dart`
- Capsule accepted-truth boundary: `lib/services/project_capsule_truth_service.dart`
- Capsule truth and revision models: `lib/shared/models/project_capsule_truth.dart`
- Capsule revision persistence: `project_capsule_revisions` in `lib/db/`
- Design tokens: `lib/shared/theme/atlas_colors.dart`
  (`ThemeExtension<AtlasColors>`, registered in `lib/app/theme.dart`)
- App-level keyboard shortcuts: `lib/shared/widgets/atlas_shortcuts.dart`
- State and orchestration: `lib/shared/models/app_state.dart`
- Local clean-git bundle archives: `lib/services/local_git_archive_service.dart`.
  AppState owns export orchestration and cached-GitHub fallback; the service
  owns local candidate ordering, clean-tree checks, and `git archive` failure
  handling.
- Persistence: `lib/db/`
- Runtime and integrations: `lib/services/`
- Local MCP: `lib/mcp/`
- Remote MCP gateway and disclosure policy: `tools/`
- Architecture and security references: `docs/`
- Configuration reference: `docs/VARIABLE_MATRIX.md`

## Known limitations

- Windows is the supported desktop target.
- The local SQLite database remains plaintext. Telegram bot tokens are stored
  separately with Windows DPAPI protection; other project data and SQLite
  metadata are not encrypted at rest.
- The capture database override is a build-time definition, not a runtime
  profile switch.
- Historical Git objects are not rewritten by normal public-tree cleanup.
- Compatibility reads do not rename or modify linked project files.
- Capsule's derived frontier, evidence, decisions, risks, and collaboration
  constraints are currently read-only. Workflow templates, attention-lane
  redesign, and outcome instrumentation remain future product slices rather
  than implied current behavior.
- The Today screen's midnight rollover uses a wall-clock `Timer`; wall-clock
  timers do not reliably survive OS sleep/resume, so the date header may lag
  until the next rebuild after a resume.
- Some `AppState.notifyListeners()` calls remain load-bearing for
  `projects`-table writes (`watchActiveProject` watches only `app_meta`).
  Project Detail people, risks, and decisions now use Drift watchers; audit
  other consumers before removing their mutation notifications. Tag data and the
  LLM task queue are fully stream-backed; both are hand-managed (raw DDL)
  tables whose mutations signal drift via explicit `notifyUpdates`, watched
  through a controller-based helper (an `async*` generator parked in
  `await for` on `tableUpdates` would hang cancellation and `close`).
