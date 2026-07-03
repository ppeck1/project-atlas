# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder. The current uncommitted implementation slice completes the Atlas/capsule/MCP control-plane path through WO-8:

- Project identity, capsule status, and project bootstrap reads.
- Queue-bound LLM task bootstrap reads.
- Local release-build stdio MCP wrapper over the Atlas MCP adapter.
- Proposal-first agent closeout records.
- Project bundle bootstrap JSON/Markdown export.
- Settings-backed Dev Launchpad and Project Ops Capsule runtime defaults.
- Repeatable preflight freshness gate script.

No commit or push has been made in this slice. The live Atlas queue rows are still pending so the operator can review the code and evidence first.

## Last Run

| Field | Value |
|---|---|
| Run ID | 20260703-agent-control-plane-rest |
| Run State | VALIDATED_LOCAL_AUTOMATED |
| Last Verified At | 2026-07-03T15:48:00-04:00 |
| Validation State | pass with manual review pending |
| Git Head | `ea3c8ac Record CI green closeout` |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- `dart format --output=none --set-exit-if-changed lib test`: pass, 0 files changed.
- `flutter analyze`: pass, no issues found.
- `flutter test test\project_identity_resolver_test.dart test\atlas_agent_service_test.dart test\atlas_mcp_adapter_test.dart test\atlas_mcp_stdio_server_test.dart test\local_operations_registry_test.dart test\project_runtime_service_test.dart --concurrency=1`: pass, 89 tests passed.
- `flutter test --concurrency=1`: pass, 204 tests passed.
- `flutter build windows --release`: pass, built `build\windows\x64\runner\Release\project_atlas.exe`.
- `python .project\verification\smoke_mcp_stdio.py`: pass against the release executable and live app-data DB; 3 JSON-RPC responses, 28 MCP tools, clean stdout protocol.
- `python tools\preflight_freshness_gate.py --json`: expected blocked because the working tree is dirty; all other checks passed, including local HEAD matching origin/main, latest GitHub main CI run `28667715821` success, capsule JSON parse, docs present, and README screenshots non-trivial.
- `python B:\Projects\LLM_Modules\Project_Ops_Capsule\scripts\capsule_doctor.py B:\dev\Project_Atlas\project-atlas-main`: pass, result healthy.
- `git diff --check`: pass, only normal CRLF conversion warnings.

## Implemented Slice

`AtlasAgentService` exposes stable bootstrap DTOs for both projects and individual active LLM queue tasks. `get_llm_task_bootstrap` returns task detail, attached media metadata, and the owning project bootstrap context without claiming or mutating the task. Completed and cancelled tasks fail closed.

`lib/mcp/atlas_mcp_stdio_server.dart` and `lib/mcp/atlas_mcp_stdio.dart` add a local JSON-RPC stdio server for release Windows builds. It supports `initialize`, `notifications/initialized`, `tools/list`, and `tools/call`. Debug builds are not suitable for stdio smoke because Flutter prints the Dart VM service banner to stdout.

`propose_closeout` records agent closeout evidence as a reviewable `closeout_record` proposal. Approval creates a `project_handoff` draft and event-log evidence; it does not bypass the human review queue.

Project bundle export can include `bootstrap/project_bootstrap_context.json` and `bootstrap/project_bootstrap_context.md` by default. The Settings export wizard exposes a Bootstrap toggle.

Settings -> Integrations now includes Project runtime defaults for Dev Launchpad YAML path and Project Ops Capsule defaults. These settings feed first-time manual runtime profiles and Dev Launchpad imports without inventing launch/test commands.

`tools/preflight_freshness_gate.py` is the repeatable WO-0 gate. It checks git cleanliness, origin/main, latest GitHub Actions main run, capsule metadata, required docs, and README screenshots.

## Live Atlas Queue State

The live app-data queue still lists `Live Ollama sampling against Library-backed summaries` and WO-0 through WO-8 as pending. Code now covers WO-0 through WO-8, but the queue was intentionally not mutated because this run remains uncommitted and awaiting operator review.

The live Ollama sampling task remains real follow-up work. This implementation did not run live local-model sampling against representative Library sets.

## Known Risks

- Manual UI/program verification is still deferred by operator constraint.
- Settings -> Integrations runtime-default layout should be visually checked on the user's machine.
- The stdio MCP smoke is validated against the release executable; debug builds print non-protocol output on stdout.
- Live queue rows need closeout/approval after review, commit, and any desired push.

## Next Best Action

Review the uncommitted diff, then decide whether to commit/push this control-plane slice and close the corresponding live Atlas queue rows with the validation evidence above. After that, the next substantive product task is live Ollama sampling against real project-linked Library sets.
