# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder. The local `main` branch is clean and synced to `origin/main`.

## Last Run

| Field | Value |
|---|---|
| Run ID | db189a6-project-status-cleanup |
| Run State | PUSHED |
| Last Verified At | 2026-07-01T19:18:21-04:00 |
| Validation State | pass |
| Git Head | `db189a6 Clarify project status handling` |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- `dart format lib\shared\models\project_metadata.dart lib\db\app_db.dart lib\features\projects\projects_screen.dart lib\features\projects\project_metadata_dialog.dart lib\features\projects\project_detail_screen.dart test\dropdown_normalization_test.dart test\schema_media_test.dart`: pass.
- `flutter test test\dropdown_normalization_test.dart`: pass, 4 tests passed.
- `flutter test test\schema_media_test.dart`: pass, 9 tests passed.
- `flutter analyze`: pass, no issues found.
- `git diff --check`: pass.
- Full `flutter test`: pass, 146 tests passed.
- `flutter build windows`: pass.
- GitHub CI run `28553381256`: pass, including Drift codegen, analyze, tests, and Windows release build.

## Latest Stabilization Pass

The Windows temp-directory lock seen in the local Operations scanner test was fixed by waiting for timed-out read-only git probe processes to exit after killing them. The same timeout cleanup pattern was applied to Local Git Visibility inspection. The MCP adapter regression test now also covers project category metadata in `list_projects` and attached media metadata in `get_llm_task`.

## Latest Product Cleanup

Project status display now uses centralized lifecycle descriptors: Open, Review, Inactive, and Closed. Status alias normalization was extended for values such as `Needs Review`, `needs-review`, and `local only`; Projects filtering, attention sorting, summary eligibility, the metadata dialog, and Project Detail status pills all use the shared helpers. Project-task count wording now uses "Open" where the count refers to open work items rather than project lifecycle status.

## Live Atlas Queue Cleanup

The local Atlas LLM queue was reconciled after the pushed code closeout. Four Project Atlas rows were marked completed with result evidence tied to `db189a6` and CI run `28553381256`: `Project status cleanup`, `Subdivide projects by set types`, `Add media to tasks`, and `Category fix`. The remaining pending row is the Bag of Holding `test review` item; it was intentionally left open because it is not a completed Project Atlas code task.

## Known Risks

- Manual UI smoke is still recommended for Projects category/status display and media attachment on a queued LLM task.
- Raw capsule run ledgers and outboxes are local-only for public-repo safety.
- GitHub Actions currently emits a non-blocking warning that `actions/checkout@v4` targets Node.js 20 while GitHub forces Node.js 24.

## Project Atlas Status

Atlas sync is outbox-first. The install event is queued locally at `.project/atlas_outbox/20260701-080143-project-atlas-ops-capsule.json`.

## BOH Status

BOH sync is outbox-first and evidence-only. The packet is queued locally at `.project/boh_outbox/20260701-080143-project-atlas-ops-capsule.json`. No BOH promotion was performed.

## Git Status

Git repo verified on branch `main`, remote `https://github.com/ppeck1/project-atlas.git`. Latest public head is `db189a6` and local status is clean/synced.

## Next Best Action

Manually smoke the Projects category/status UI and media attachment flow, then triage Operations warning findings starting with registry and repository warnings.
