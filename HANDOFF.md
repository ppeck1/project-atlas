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

Recovery findings R-01 through R-06 and queue findings A-01, A-02, and A-05
are closed. The LLM queue remains restricted to an attended single-worker
operating assumption while P0 proposal findings A-03 and A-04 remain open.

This handoff records the public, portfolio-facing maintenance boundary for
Project Atlas. It is intentionally free of private workspace records, personal
contact data, machine-specific paths, and unrelated project references.

Last updated: 2026-07-21.

## Audit resume checkpoint

Start from current `main` at `c9a5e36` (`Close LLM queue findings after
post-merge proof (#34)`). The working tree was clean and synchronized with
`origin/main` when this handoff was written.

The canonical matrix contains 51 findings: 9 Closed, 2 In progress, and 40
Open. The completed integrity sequence is:

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

Current verification baseline after A-01/A-02/A-05:

- focused recovery suite: 18/18;
- focused full-backup suite: 10/10 on merged `main`;
- focused queue/service/MCP suite: 52/52 on merged `main`;
- full Flutter suite: 477 passed with 1 intentional skip on merged `main`;
- static analysis: clean;
- Python policy/maintenance suite: 30/30;
- Windows release build: passed; and
- hosted CI, including seeded isolated MCP smoke: passed.

### Recommended next implementation

Take A-03 and A-04 as the next P0 proposal-acceptance package. Keep the
attended single-worker constraint until both have merged and passed post-merge
proof.

Active implementation branch: `fix/proposal-acceptance-integrity`. A-03 and
A-04 are in progress; neither finding is closed and the operating constraint
is unchanged.

1. Make proposal side effects and review approval one crash-idempotent SQLite
   transaction with an UPDATE-first pending-draft claim.
2. Persist server-generated canonical task and exact-tag-set hashes for
   existing-task proposals.
3. Reject stale proposal application with a typed conflict before any side
   effect occurs.
4. Prove crash-after-side-effect retry applies exactly once and stale task/tag
   proposals change nothing.
5. Keep A-06 through A-10 and A-11 separately tracked unless implementation
   evidence shows a shared atomicity or schema boundary.

The active lifecycle and hash boundary are specified in the
[`proposal acceptance integrity contract`](docs/PROPOSAL_ACCEPTANCE_INTEGRITY_CONTRACT.md).

Current pre-merge proof for the active package:

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
and post-merge proof passed on `8a90d6e`. A-11 remains open, so WP3 is not
fully closed.

## Current public state

- Repository: `ppeck1/project-atlas`
- Default branch: `main`
- Current release line: `v1.4.2` (`1.4.2+3` application build)
- Merge policy: pull request, passing `build` check, linear history, resolved
  conversations, and squash merge
- Public authorship: Paul Peck / `ppeck1`
- README images: captures of the real Windows application using an isolated
  public-safe demo database
- Current database line: schema `25`. Version 23 added
  `documents.deleted_at` soft delete with undo and deferred purge; version 24
  adds the immutable accepted Project Capsule revision ledger and baseline
  migration; version 25 enforces update/delete immutability guards on that
  ledger. Project Sources retains reconciliation preview, local/remote source
  roles, and Atlas-only source bookkeeping updates.
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
