# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder.

This closeout slice covers Project Detail change-log usability, persistent AI change summaries, and project bundle export support:

- Change Log defaults newest-to-oldest and exposes `Newest first` / `Oldest first`.
- AI change-summary runs are owned by `AppState`, not by the widget lifecycle.
- Successful change summaries persist as `kind='project_change_summary'` drafts.
- Transport failures and Ollama timeouts are surfaced as errors and are not saved as latest summaries.
- Export presets can include change-log JSON, latest change-summary Markdown/input JSON, and full evidence JSON.
- The prompt sent to Ollama uses compact evidence, while export keeps full evidence for audit.

## Last Run

| Field | Value |
|---|---|
| Run ID | 20260703-change-log-summary-export |
| Run State | VALIDATED_LOCAL_AUTOMATED_AND_UI_CHECKED |
| Last Verified At | 2026-07-03T21:38:46-04:00 |
| Validation State | pass with operator review window open |
| Git Head Before Commit | `3b8d0da Add Atlas capsule runtime controls` |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- `dart format lib\shared\models\app_state.dart lib\features\projects\project_detail_screen.dart lib\services\ollama_service.dart test\project_update_attribution_test.dart test\ollama_service_test.dart`: pass.
- `flutter analyze lib\shared\models\app_state.dart lib\features\projects\project_detail_screen.dart lib\services\ollama_service.dart test\project_update_attribution_test.dart test\ollama_service_test.dart`: pass, no issues found.
- `flutter test test\project_update_attribution_test.dart --concurrency=1`: pass, 7 tests passed.
- `flutter test test\ollama_service_test.dart --concurrency=1`: pass, 3 tests passed.
- `flutter test test\local_operations_registry_test.dart --concurrency=1`: pass, 53 tests passed.
- `flutter build windows --debug`: pass.
- Windows UI check in fresh debug instance: Project Atlas -> Change Log showed `Newest first`, dropdown contained `Oldest first`, sort toggled successfully, and the saved latest AI change summary persisted after navigation.

## Implemented Slice

`ProjectChangeSummaryRunStatus` records per-project background summary state in `AppState`. `ProjectDetailScreen` uses it to show background progress, prevent duplicate runs, and keep failure output separate from the latest saved summary.

`AppState.getProjectEventLogs()` and `getProjectChangeLog()` support explicit `newestFirst` sorting. The UI defaults to newest-first.

`AppState.summarizeProjectChanges()` saves a successful `project_change_summary` draft with `project_change_summary_draft_input_v1`, full `project_change_summary_evidence_packet_v1`, and compact `project_change_summary_prompt_evidence_packet_v1`.

`OllamaService.summarizeProjectChanges()` uses a 12-minute timeout. `OllamaResult.isSuccess` rejects timeout/transport text so failed responses cannot masquerade as saved summaries.

Project bundle exports include the following when `includeChangeLog` is enabled:

- `change_log/project_changes.json`
- `change_log/project_change_summary_evidence.json`
- `change_log/latest_change_summary.md`
- `change_log/latest_change_summary_input.json`

## Live Atlas Project State

The live debug app was opened for review after the build. The Project Atlas project was checked in the UI, and the review window was left on Project Atlas -> Change Log with `Newest first` selected and the saved latest AI change summary visible.

## Known Risks

- A new live Ollama summary was not triggered in the final UI loop to avoid starting another long local-model request.
- Full `flutter test` was not rerun for this narrow slice; focused attribution/export/Ollama/local-operations tests passed.
- Older app-data logs can still contain prior failed summary attempts; current UI no longer presents those failures as saved summaries.

## Next Best Action

Commit and push this slice after docs and capsule metadata are updated, then record the commit SHA and validation summary back into the live Project Atlas project state.
