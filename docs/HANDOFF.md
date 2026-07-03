# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder. The latest stabilization pass repaired the GitHub CI path assertion, refreshed the public README screenshots, and closed two small product correctness gaps found in review: Telegram sends now respect the enable toggle, and deleting app-owned project media removes its copied file best-effort.

## Last Run

| Field | Value |
|---|---|
| Run ID | 20260703-ci-screenshots-product-stabilization |
| Run State | VALIDATED_LOCAL |
| Last Verified At | 2026-07-03T10:45:16-04:00 |
| Validation State | pass |
| Git Head | working tree based on `7c7d0eb Add project runtime profiles (schema v19); refresh docs and screenshots` |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- `C:\Users\peckm\AppData\Local\Programs\Python\Python311\python.exe tools\generate_readme_screenshots.py`: pass, regenerated five README screenshots at 1440x900.
- `C:\Users\peckm\AppData\Local\Programs\Python\Python311\python.exe -m py_compile tools\generate_readme_screenshots.py`: pass.
- `dart format lib\db\app_db.dart lib\shared\models\app_state.dart test\document_import_test.dart test\local_operations_registry_test.dart`: pass, 0 files changed.
- `flutter test test\local_operations_registry_test.dart --plain-name "project bundle clean git export uses a clean linked child registry repo"`: pass.
- `flutter test test\document_import_test.dart test\schema_media_test.dart`: pass, 36 tests passed.
- `flutter analyze`: pass, no issues found.
- Full `flutter test`: pass, 188 tests passed.
- `git diff --check`: pass, only normal CRLF conversion warnings.
- GitHub Actions CI run `28667317914` for commit `ade5634`: pass, including Analyze, Test, and Windows release build.

## Latest Stabilization Pass

Project AI summaries remain behind an explicit Settings -> AI Summaries wizard with Disabled, Manual review, and Manual review + bulk refresh modes. Manual summaries can default to linked Library evidence, bulk refresh remains separately gated, and project summaries can use either the global Ollama model or a summary-specific installed model. The evidence packet classifies docs into operational categories, ranks marker docs before raw source files, surfaces aggregate packet warnings in Project Detail, includes category/reason lines in the LLM prompt, emits deterministic evaluation JSON, and tells the model not to infer from metadata-only document titles. Structured summary output still validates schema, ownership, document IDs, and unsupported generic next actions before acceptance.

The public screenshot generator now creates a cleaner 1440x900 schema v19 README set for Today, Projects, Operations, Library, and Settings. The screenshots use demo data but intentionally show operator-facing workflows: daily focus, project runtime actions, Operations review/project-health signals, Library AI drafts/proposals, and opt-in AI summary settings.

The July 3 CI-only failure on GitHub was the local git archive export test comparing raw Windows path spellings (`RUNNER~1` versus `runneradmin`). The test now compares filesystem identity first, with normalized path comparison as a fallback.

Telegram sending now fails closed when `telegram_enabled` is disabled or unset, without creating an outbox row or attempting a send. Project media deletion now removes the app-owned copied file from the `project_media/<projectId>` vault best-effort after removing media links and the DB row; external paths are left alone.

## Live Atlas Queue Cleanup

The local Atlas LLM queue was reconciled after the pushed code closeout. Four Project Atlas rows were marked completed with result evidence tied to `db189a6` and CI run `28553381256`: `Project status cleanup`, `Subdivide projects by set types`, `Add media to tasks`, and `Category fix`. The remaining pending row is the Bag of Holding `test review` item; it was intentionally left open because it is not a completed Project Atlas code task.

## Known Risks

- Manual UI smoke of the Settings -> AI Summaries tab is still useful to inspect layout and local Ollama model dropdown behavior.
- Live Ollama sampling against real project-linked Library sets remains a separate review task; this work order intentionally keeps the regression harness deterministic.
- Raw capsule run ledgers and outboxes are local-only for public-repo safety.
- GitHub Actions passed for the stabilization commit; the only annotation was the upstream Node.js 20 deprecation notice from GitHub Actions.

## Project Atlas Status

Atlas sync is outbox-first. The install event is queued locally at `.project/atlas_outbox/20260701-080143-project-atlas-ops-capsule.json`.

## BOH Status

BOH sync is outbox-first and evidence-only. The packet is queued locally at `.project/boh_outbox/20260701-080143-project-atlas-ops-capsule.json`. No BOH promotion was performed.

## Git Status

Git repo verified on branch `main`, remote `https://github.com/ppeck1/project-atlas.git`. This handoff records the locally and remotely validated state after the stabilization commit was pushed.

## Next Best Action

The next substantive product slice is either settings-backed runtime defaults or restore/import flows.
