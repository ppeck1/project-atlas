# Capsule Resume v0 work order

Status: Completed on 2026-07-17

## Objective

Make Atlas useful for resuming a project: select a project, establish its
current intent and accepted state, see the next justified action, understand
what is blocking progress, and inspect the evidence behind that recommendation.

The usability benchmark is the time from opening Capsule to choosing a
meaningful next action for a project that has not been visited recently.

## Scope

- Add one derived `ProjectCapsuleSnapshot` domain contract.
- Build the snapshot only from existing Atlas records and services.
- Give every surfaced work item a reason, owner, and forward transition.
- Provide compact `act`, `understand`, and `audit` projections with one shared
  revision identifier and content hash.
- Add a project-scoped Capsule screen with Act, Understand, and Audit depths.
- Move Capsule into the primary navigation position currently occupied by Ops.
- Retain Operations at `/operations` and link it from Capsule as Sources &
  Health.
- Rename the runtime-facing Capsule label to Protocol preflight where needed to
  avoid conflating runtime validation with the collaboration Capsule.
- Add focused service, widget, and navigation tests.
- Document the new service boundary and update the maintainer handoff.

## Non-goals

- No database schema or migration changes.
- No editable Capsule persistence, templates, workflow engine, or loop runner.
- No MCP disclosure expansion or new remote tools.
- No autonomous execution or agent approval path.
- No Operations deletion or source-reconciliation redesign.
- No Workboard lane redesign in this slice.

## Coherence rules

1. UI and future adapters consume the same `ProjectCapsuleSnapshot` contract.
2. Every projection carries the same revision identifier and content hash.
3. Volatile generation timestamps do not change the content hash.
4. Token reduction may omit unrelated sections, but never warnings, unknowns,
   evidence posture, or acceptance boundaries from the relevant projection.
5. Derived recommendations do not become accepted project truth.
6. Screen code renders the projection; it does not independently calculate
   Capsule semantics.

## Acceptance criteria

- A user can select any visible project from Capsule.
- Act shows one recommended next action plus ready, review, blocked, or
  decision-dependent work with an explanation and forward transition.
- Understand shows project intent, accepted state, decisions, risks, scope,
  and safe constraints.
- Audit shows freshness, source/protocol posture, warnings, gaps, and
  verification expectations.
- Empty, missing-project, loading, and error states are explicit.
- Operations remains reachable as Sources & Health.
- `act`, `understand`, and `audit` JSON views exclude unrelated heavy sections
  while preserving the shared revision metadata.
- Existing proposal-first and human-acceptance boundaries are unchanged.
- Schema remains 23.

## Verification

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
python -m unittest discover -s tools -p "test_*.py"
```

The full Windows release build and MCP smoke remain the final public-delivery
gate described in `HANDOFF.md`.

## Verification result

- Focused Capsule, widget, and navigation suite: 37 passed.
- `flutter analyze`: no issues.
- Full Flutter suite: 393 passed, 1 skipped.
- Python policy/maintenance suite: 30 passed.
- Drift generation: completed with no generated diff.
- Windows release: passed in an isolated temporary checkout because the live
  Atlas executable held the default build output open.
- MCP gateway smoke: passed with 4 projected tools, 30 hidden tools rejected,
  and both OAuth paths green.
- Repository-wide format audit identified 26 pre-existing formatting deltas
  across unrelated files. The new Capsule files are formatted; unrelated
  formatting churn was intentionally not included in this work order.

## Stop conditions

Stop if implementation would require a schema bump, weaken remote disclosure,
change acceptance authority, duplicate Capsule calculations in a screen, or
silently omit warnings or uncertainty to reduce payload size.
