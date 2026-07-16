# Public Maintainer Handoff

This handoff records the public, portfolio-facing maintenance boundary for
Project Atlas. It is intentionally free of private workspace records, personal
contact data, machine-specific paths, and unrelated project references.

Last updated: 2026-07-15.

## Current public state

- Repository: `ppeck1/project-atlas`
- Default and only public branch: `main`
- Current release line: `v1.4.2` (`1.4.2+3` application build)
- Merge policy: pull request, passing `build` check, linear history, resolved
  conversations, and squash merge
- Public authorship: Paul Peck / `ppeck1`
- README images: captures of the real Windows application using an isolated
  public-safe demo database
- Current source-topology line: schema `22` with Project Sources,
  reconciliation preview, local/remote source roles, and Atlas-only source
  bookkeeping updates

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

4. Relaunch the same build and capture the Today, Projects, Workboard, and
   Library surfaces.
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
- The Today screen's midnight rollover uses a wall-clock `Timer`; wall-clock
  timers do not reliably survive OS sleep/resume, so the date header may lag
  until the next rebuild after a resume.
