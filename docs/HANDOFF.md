# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder. The current work order validates project AI summary source-packet quality: categorized Library evidence ranking, packet warnings, deterministic evaluation JSON, and prompt guards for metadata-only documents.

## Last Run

| Field | Value |
|---|---|
| Run ID | 20260702-ai-summary-source-packet-quality |
| Run State | VALIDATED_LOCAL |
| Last Verified At | 2026-07-02T09:11:53-04:00 |
| Validation State | pass |
| Git Head | working tree based on `a7ec534 Add project summary evidence provenance` |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- `dart format lib\services\project_summary_models.dart lib\shared\models\app_state.dart lib\features\projects\project_detail_screen.dart test\smoke_test.dart test\project_summary_models_test.dart`: pass.
- `flutter analyze`: pass, no issues found.
- `flutter test test\project_summary_models_test.dart test\smoke_test.dart`: pass, 34 tests passed.
- Full `flutter test`: pass, 162 tests passed.
- `git diff --check`: pass, only normal CRLF conversion warnings.

## Latest Stabilization Pass

Project AI summaries now sit behind an explicit Settings -> AI Summaries wizard with Disabled, Manual review, and Manual review + bulk refresh modes. Manual summaries can default to linked Library evidence, bulk refresh remains separately gated, and project summaries can use either the global Ollama model or a summary-specific installed model. The evidence packet now classifies docs into operational categories, ranks marker docs before raw source files, surfaces aggregate packet warnings in Project Detail, includes category/reason lines in the LLM prompt, emits deterministic evaluation JSON, and tells the model not to infer from metadata-only document titles. Structured summary output still validates schema, ownership, document IDs, and unsupported generic next actions before acceptance.

## Live Atlas Queue Cleanup

The local Atlas LLM queue was reconciled after the pushed code closeout. Four Project Atlas rows were marked completed with result evidence tied to `db189a6` and CI run `28553381256`: `Project status cleanup`, `Subdivide projects by set types`, `Add media to tasks`, and `Category fix`. The remaining pending row is the Bag of Holding `test review` item; it was intentionally left open because it is not a completed Project Atlas code task.

## Known Risks

- Manual UI smoke of the Settings -> AI Summaries tab is still useful to inspect layout and local Ollama model dropdown behavior.
- Live Ollama sampling against real project-linked Library sets remains a separate review task; this work order intentionally keeps the regression harness deterministic.
- Raw capsule run ledgers and outboxes are local-only for public-repo safety.

## Project Atlas Status

Atlas sync is outbox-first. The install event is queued locally at `.project/atlas_outbox/20260701-080143-project-atlas-ops-capsule.json`.

## BOH Status

BOH sync is outbox-first and evidence-only. The packet is queued locally at `.project/boh_outbox/20260701-080143-project-atlas-ops-capsule.json`. No BOH promotion was performed.

## Git Status

Git repo verified on branch `main`, remote `https://github.com/ppeck1/project-atlas.git`. This handoff records the validated local state for the AI summary source-packet quality work order.

## Next Best Action

Commit and push the source-packet quality work, then perform a separate live Ollama sampling pass against real project-linked Library sets.
