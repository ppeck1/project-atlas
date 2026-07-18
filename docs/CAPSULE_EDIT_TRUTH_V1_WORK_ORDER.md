# Capsule Edit Truth v1 work order

Status: Active on 2026-07-18

## Authorization

The owner explicitly authorized continuation after reviewing Capsule Resume v0:
"Proceed."

## Objective

Turn Capsule from a derived resume packet into an editable, versioned
collaboration contract without allowing a form or an agent proposal to silently
change accepted project truth.

## Scope

- Add one immutable accepted-revision ledger for authored Capsule truth.
- Keep existing project fields authoritative for intent, lifecycle, and scope.
- Keep derived frontier, evidence, decisions, risks, and collaboration safety
  constraints read-only in this slice.
- Let a human review a field-level diff before explicitly saving accepted truth.
- Keep agent-originated changes inside Atlas's existing proposal draft boundary.
- Apply accepted fields and record their immutable revision atomically.
- Detect stale proposals with an authored-contract content hash.
- Show pending proposed changes and accepted revision history in Capsule.
- Preserve direct project-metadata editing while recording Capsule-relevant
  accepted revisions through the shared state boundary.
- Bump the local schema from 23 to 24 and prove a real v23-to-v24 migration.

## Non-goals

- No workflow templates, loop runner, Workboard lane redesign, or automation.
- No MCP tool, remote disclosure, or token-projection change.
- No autonomous execution or agent acceptance authority.
- No source-reconciliation, runtime, evidence, or acceptance-policy weakening.
- No dependency addition or broad architecture refactor.

## Coherence rules

1. Existing project columns remain the accepted source for overlapping fields;
   a revision is immutable history, not a competing mutable project record.
2. Revisions are immutable history and never override newer project columns.
3. Human UI input does not mutate truth until the review step is explicitly
   saved; agent input always remains a proposal until approved.
4. Acceptance updates project fields and records the accepted revision in one
   transaction; proposal review is idempotent and recoverable around it.
5. Proposal concurrency uses the authored-contract hash, not volatile work,
   freshness, or generation-time state.
6. Revisions store no raw source excerpts, queue results, stack traces, or
   machine-derived local paths.
7. Screen code renders domain diffs and invokes domain actions; it does not
   independently decide truth or proposal validity.

## Acceptance criteria

- A user can edit the existing authored identity, intent, lifecycle, scope, and
  outcome-summary fields from Capsule.
- Opening, editing, reviewing, or cancelling leaves accepted truth unchanged.
- The review step shows every changed field before an explicit accepted save.
- Accepting a current proposal atomically updates truth and creates the next
  immutable accepted revision.
- Rejecting a proposal preserves accepted truth and leaves an auditable result.
- A stale proposal cannot overwrite a newer accepted contract.
- Capsule distinguishes its live snapshot hash from the accepted authored
  contract revision and shows accepted history.
- Existing project-detail metadata edits remain functional and enter revision
  history when they change Capsule-authored fields.
- Empty, invalid, missing-project, duplicate-review, and migration paths are
  explicit and tested.
- Existing proposal-first and human-acceptance boundaries remain unchanged.
- Schema is exactly 24.

## Verification

```powershell
dart run build_runner build
dart format --output=none --set-exit-if-changed <touched Dart files>
flutter analyze
flutter test test\project_capsule_truth_service_test.dart
flutter test test\project_capsule_service_test.dart test\capsule_screen_test.dart
flutter test test\schema24_capsule_revision_migration_test.dart
flutter test
python -m unittest discover -s tools -p "test_*.py"
```

The Windows release build and isolated-database launch remain the final review
gate. Do not upgrade the live database while an older Atlas process is open.

## Implementation status

Engineering implementation and verification are complete; operator acceptance
of the opened review build is pending.

- Drift generation completed with schema 24 outputs.
- `flutter analyze` completed with no issues.
- Focused Capsule, agent, migration, metadata-dialog, attribution, and
  Operations tests passed.
- The full Flutter suite passed: 414 tests, with 1 intentional skip.
- The full Python policy and timestamp suite passed: 30 tests.
- The Windows release build completed successfully.
- A SQLite online backup of the working schema-23 database migrated to schema
  24 in the isolated review instance; `quick_check` passed and every cloned
  project received a baseline revision.

## Stop conditions

Stop if implementation would create two mutable accepted truths, allow a stale
proposal to apply, make agent approval implicit, expose Capsule data remotely,
silently truncate warnings or uncertainty, require a dependency, or require a
live database migration while an older Atlas instance is running.
