# Public Maintainer Handoff

This handoff records the public, portfolio-facing maintenance boundary for
Project Atlas. It is intentionally free of private workspace records, personal
contact data, machine-specific paths, and unrelated project references.

Last updated: 2026-07-18.

## Current public state

- Repository: `ppeck1/project-atlas`
- Default and only public branch: `main`
- Current release line: `v1.4.2` (`1.4.2+3` application build)
- Merge policy: pull request, passing `build` check, linear history, resolved
  conversations, and squash merge
- Public authorship: Paul Peck / `ppeck1`
- README images: captures of the real Windows application using an isolated
  public-safe demo database
- Current database line: schema `24`. Version 23 added
  `documents.deleted_at` soft delete with undo and deferred purge; version 24
  adds the immutable accepted Project Capsule revision ledger and baseline
  migration. Project Sources retains reconciliation preview, local/remote
  source roles, and Atlas-only source bookkeeping updates.
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
contains projects, work items, or documents.

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
- Persistence: `lib/db/`
- Runtime and integrations: `lib/services/`
- Local MCP: `lib/mcp/`
- Remote MCP gateway and disclosure policy: `tools/`
- Architecture and security references: `docs/`
- Configuration reference: `docs/VARIABLE_MATRIX.md`

## Known limitations

- Windows is the supported desktop target.
- The local SQLite database and saved integration secrets are plaintext.
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
- Some `AppState.notifyListeners()` calls remain load-bearing for data with
  no Drift watcher (project people/risks/decisions) and for `projects`-table
  writes (`watchActiveProject` watches only `app_meta`). Do not remove those
  notifies until stream coverage exists for the consumers. Tag data and the
  LLM task queue are fully stream-backed; both are hand-managed (raw DDL)
  tables whose mutations signal drift via explicit `notifyUpdates`, watched
  through a controller-based helper (an `async*` generator parked in
  `await for` on `tableUpdates` would hang cancellation and `close`).
