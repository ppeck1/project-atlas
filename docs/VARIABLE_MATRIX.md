# Variable Matrix

Secret policy: names only. Secret values must never be recorded.

| Name | Type | Location | Default | Required | Secret | Used By | Notes | Last Verified |
|---|---|---|---|---|---|---|---|---|
| project_id | string | `.project/project_manifest.json` | `project-atlas` | yes | no | Capsule, Atlas outbox, BOH packet | Stable project identifier. | 2026-07-01 |
| display_name | string | `.project/project_manifest.json` | `Project Atlas` | yes | no | Capsule, operator docs | Human-readable project name. | 2026-07-01 |
| root | path | `.project/project_manifest.json` | `.` | yes | no | Capsule doctor | Repo-local root. | 2026-07-01 |
| visibility | enum | `.project/project_manifest.json` | `public` | yes | no | Public safety policy | GitHub remote visibility is public. | 2026-07-01 |
| profiles | string array | `.project/project_manifest.json`, `.project/ops_capsule.json` | `public_repo`, `software_project` | yes | no | Capsule doctor | Matches public Flutter software repo. | 2026-07-01 |
| validation.required | string array | `.project/project_manifest.json` | analyze, test | yes | no | Verification loop | Required validation commands. | 2026-07-01 |
| atlas_sync | object | `.project/project_manifest.json` | outbox enabled | yes | no | Capsule sync | Creates local Atlas packet only. | 2026-07-01 |
| boh_sync | object | `.project/project_manifest.json` | outbox/evidence-only | yes | no | Capsule sync | No BOH promotion authority. | 2026-07-01 |
| git_policy | object | `.project/project_manifest.json` | manual push, no unrelated dirty | yes | no | Capsule closeout | Commit only after scoped/signable review. | 2026-07-01 |
| raw_run_ledger | local path | `.project/runs/` | local-only | yes | may contain local paths | Capsule evidence | Ignored in public repo. | 2026-07-01 |
| atlas_outbox | local path | `.project/atlas_outbox/` | local-only | yes | may contain local paths | Atlas sync queue | Ignored in public repo. | 2026-07-01 |
| boh_outbox | local path | `.project/boh_outbox/` | local-only | yes | may contain local paths | BOH sync queue | Ignored in public repo. | 2026-07-01 |
| atlas.project_identity.v1 | DTO schema | `ProjectIdentityResolver` | generated on read | no | may contain local paths | Agent bootstrap, MCP reads | Wraps Atlas project, registry, GitHub, and capsule identity without mutating capsule JSON. | 2026-07-03 |
| atlas.project_capsule_status.v1 | DTO schema | `ProjectIdentityResolver` | generated on read | no | may contain local paths | Agent bootstrap, MCP reads | Reports metadata/evidence availability and counts local-only evidence without embedding raw ledger/outbox contents. | 2026-07-03 |
| atlas.project_bootstrap_context.v1 | DTO schema | `AtlasAgentService.getProjectBootstrapContext` | generated on read | no | may contain local paths | Agent startup packet | Combines project brief, identity, capsule status, pending tasks/proposals, confidence, gaps, and next action. | 2026-07-03 |
| atlas.llm_task_bootstrap_context.v1 | DTO schema | `AtlasAgentService.getLlmTaskBootstrap` | generated on read | no | may contain local paths | Queue-bound worker startup | Combines one active LLM queue task, attached media metadata, and its project bootstrap packet. | 2026-07-03 |
| atlas.workload_snapshot.v1 | DTO schema | `WorkloadSnapshot` | generated on read | no | may contain local paths | Workboard, MCP reads | Cards, grouped counts, actor/risk breakdowns, stale count, ready-only execution candidates, separate planning candidates, and review-needed cards. | 2026-07-04 |
| workload_planning_columns | DB columns | `work_items`, `llm_task_queue` | v20 defaults | no | no | Workboard | Readiness, size, risk, suggested actor, verification needed, next action, planning notes, and last reviewed timestamp. Queue rows also store `blocker_reason`; work items use existing `blocked_reason`. | 2026-07-04 |
| atlas.workload_* MCP tools | MCP tools | `AtlasMcpAdapter` | read-only | no | may contain local paths | MCP clients | `atlas.workload_snapshot`, `atlas.project_workload`, `atlas.suggest_next_work`, and `atlas.work_item_context_bundle`; no state mutation or harness execution. | 2026-07-04 |
| atlas.agent.proposal.closeout_record | proposal type | `AtlasAgentService.proposeCloseout` | review draft | no | may contain local paths | Agent closeout review | Captures run state, validation, capsule, packet, git, risk, and next-action evidence for human approval. | 2026-07-03 |
| includeBootstrapContext | export option | `AppState.exportProjectBundleToZip` | true | no | may contain local paths | Project bundle export | Adds `bootstrap/project_bootstrap_context.json` and `.md` to exported ZIP bundles. | 2026-07-03 |
| includeChangeLog | export option | `AppState.exportProjectBundleToZip` | false | no | may contain local paths | Project bundle export | Adds normalized project changes, change-summary evidence, and latest saved change-summary draft/input JSON when selected. | 2026-07-03 |
| project_change_summary | draft kind | `drafts.kind` | generated on success | no | may contain local paths | Project Detail Change Log, export wizard | Stores the latest successful AI change summary for a project; failed/timeout Ollama output is not saved as this kind. | 2026-07-03 |
| project_change_summary_evidence_packet_v1 | JSON schema | `AppState.summarizeProjectChanges`, export bundle | generated on run/export | no | may contain local paths | Audit/export evidence | Full evidence packet saved in draft input and exported as `change_log/project_change_summary_evidence.json`. | 2026-07-03 |
| project_change_summary_prompt_evidence_packet_v1 | JSON schema | `AppState.summarizeProjectChanges` | generated on run | no | may contain local paths | Ollama prompt | Compact prompt packet with raw payload blocks stripped to reduce local-model timeouts. | 2026-07-03 |
| project_change_summary_timeout | duration | `OllamaService.summarizeProjectChanges` | 12 minutes | no | no | Ollama change summaries | Longer timeout for local change-log summaries; default chat timeout remains 300 seconds. | 2026-07-03 |
| project_runtime_default_* | AppMeta keys | `AppDb` / Settings Integrations | machine defaults | no | may contain local paths | Runtime profiles | Stores Dev Launchpad YAML path and Project Ops Capsule defaults; launch/test commands remain per-project only. | 2026-07-03 |
| detailed_app_variable_map | doc path | `VARIABLE_MAP.md` | existing app doc | yes | names only | App maintainers | Detailed app schema/data-flow map. | 2026-07-01 |
