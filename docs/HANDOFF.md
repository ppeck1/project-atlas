# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder. The current closeout validates the opt-in AI summary wizard, Library-backed summary defaults, summary-specific Ollama model selection, and fail-closed structured-summary validation. Commit/push is pending at the time this handoff evidence is written.

## Last Run

| Field | Value |
|---|---|
| Run ID | 20260702-ai-summary-wizard-validation |
| Run State | VALIDATED_LOCAL |
| Last Verified At | 2026-07-02T07:41:10-04:00 |
| Validation State | pass |
| Git Head | pre-commit working tree based on `79b0a77 Disable project AI summary workflow` |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- `dart format lib\shared\models\app_state.dart lib\services\ollama_service.dart lib\services\project_summary_models.dart lib\features\settings\settings_screen.dart test\project_summary_models_test.dart test\smoke_test.dart test\ollama_service_test.dart`: pass.
- `flutter test test\project_summary_models_test.dart test\ollama_service_test.dart`: pass, 24 tests passed.
- Focused manifest suite with schema/media/local-operations/document/smoke/project-summary/Ollama tests: pass, 98 tests passed.
- `flutter analyze`: pass, no issues found.
- Full `flutter test`: pass, 157 tests passed.
- `git diff --check`: pass, only normal CRLF conversion warnings.
- Terminal smoke: `flutter run -d windows` launched a `project_atlas` process from the terminal run loop; the process and Flutter/Dart helpers were stopped after verification.

## Latest Stabilization Pass

Project AI summaries now sit behind an explicit Settings -> AI Summaries wizard with Disabled, Manual review, and Manual review + bulk refresh modes. Manual summaries can default to linked Library evidence, bulk refresh remains separately gated, and project summaries can use either the global Ollama model or a summary-specific installed model. Structured summary output now validates schema, ownership, document IDs, and unsupported generic next actions before it is accepted; validation failures are shown to the operator instead of being treated as successful summaries. Ollama validation retries once for correctable structured-output failures and does not retry transport/model errors.

## Live Atlas Queue Cleanup

The local Atlas LLM queue was reconciled after the pushed code closeout. Four Project Atlas rows were marked completed with result evidence tied to `db189a6` and CI run `28553381256`: `Project status cleanup`, `Subdivide projects by set types`, `Add media to tasks`, and `Category fix`. The remaining pending row is the Bag of Holding `test review` item; it was intentionally left open because it is not a completed Project Atlas code task.

## Known Risks

- Manual UI smoke of the Settings -> AI Summaries tab is still useful to inspect layout and local Ollama model dropdown behavior.
- Evidence-packet preview and Library ranking are intentionally deferred to a separate work order.
- Raw capsule run ledgers and outboxes are local-only for public-repo safety.

## Project Atlas Status

Atlas sync is outbox-first. The install event is queued locally at `.project/atlas_outbox/20260701-080143-project-atlas-ops-capsule.json`.

## BOH Status

BOH sync is outbox-first and evidence-only. The packet is queued locally at `.project/boh_outbox/20260701-080143-project-atlas-ops-capsule.json`. No BOH promotion was performed.

## Git Status

Git repo verified on branch `main`, remote `https://github.com/ppeck1/project-atlas.git`. This handoff records the validated pre-commit state for the AI summary setup/validation closeout.

## Next Best Action

Commit and push the validated AI summary setup/validation work, then open the separate evidence-packet preview and Library-ranking work order.
