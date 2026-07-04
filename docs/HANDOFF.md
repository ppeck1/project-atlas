# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder.

This v1.4 slice adds the Workboard Planning Layer:

- Work items now carry planning metadata: readiness, size, risk, suggested actor, verification needed, next action, planning notes, and last reviewed timestamp.
- Existing work-item `blocked_reason` remains the blocker source of truth for work items.
- LLM queue rows now carry the same planning metadata plus `blocker_reason`.
- `/work` is now a primary Workboard view in the left rail, grouped into Ready, Needs Decision, Blocked, In Progress, Review Needed, and Done / Closed.
- Workboard cards show project, task title, owner/contact, readiness, size, risk, suggested actor, verification needed, due/priority/status, LLM queue linkage, blocker reason, and next action.
- Filters cover project, readiness, actor, risk, size, blocked only, review needed, stale/unreviewed, and high priority.
- Bulk planning actions are explicit operator actions: mark ready, mark blocked, assign suggested actor, set size/risk/verification, mark reviewed today, create LLM queue item from work item, and link existing LLM queue item.
- Planning Snapshot shows ready/blocked/review/stale counts, actor/risk breakdowns, ready-only execution candidates, and separate planning/decision candidates.
- MCP adds read-only planning tools: `atlas.workload_snapshot`, `atlas.project_workload`, `atlas.suggest_next_work`, and `atlas.work_item_context_bundle`.

## Last Run

| Field | Value |
|---|---|
| Run ID | `20260704-workboard-planning-layer-v1.4-hardening` |
| Run State | uncommitted hardening diff in current worktree for review |
| Last Verified At | 2026-07-04 |
| Validation State | complete: format, analyze, focused tests, full suite, and diff whitespace checks passed |
| Git Head Before Hardening | `410c8f8 Add v1.4 Workboard planning layer` |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- `dart format --output=none --set-exit-if-changed lib test`: pass, 69 files checked, 0 changed.
- `flutter analyze`: pass, no issues found.
- `flutter test test\workload_planning_test.dart test\atlas_mcp_adapter_test.dart test\create_work_item_dialog_test.dart --concurrency=1`: pass, 16 tests passed.
- `flutter test --concurrency=1`: pass, 215 tests passed.
- `git diff --check`: pass.

## Implemented Slice

`lib/services/workload_planning_service.dart` centralizes planning enums, normalization, board grouping, filters, stale detection, deterministic scoring, snapshot counts, and JSON-safe card output. Execution suggestions are ready-only; needs-context and needs-decision cards are surfaced separately as planning candidates, while blocked and review-needed cards are not execution candidates.

`work_items` moved to schema v20 with planning metadata columns. Existing `blocked_reason` is preserved for work-item blockers. The app startup repair path adds these columns defensively for older or partially migrated local DBs.

`llm_task_queue` now has planning metadata columns and a planning-only update path. This does not alter lease, completion, result, or harness lifecycle semantics.

`AppState` exposes workload snapshot reads, bulk planning writes, reviewed-today marking, queue item creation from selected work items, queue linking, and a read-only work-item context bundle. MCP calls use only the read side for the new planning tools.

`WorkScreen` is now the operator Workboard. It is on the main navigation rail and supports selection-driven bulk planning actions. Work-item detail also exposes planning fields for single-item edits.

Create flows now expose the workload fields consistently from Workboard, Project Detail, and Today quick-add. The shared owner picker and planning dropdowns use expanded, ellipsized menu rows to avoid overflow in real dialog widths.

`AtlasMcpAdapter` registers the new `atlas.*` read tools. They do not claim queue tasks, complete work, run harness jobs, or mutate queue state.

## Known Risks

- Generated Drift output is intentionally ignored by this repo. It was regenerated locally with `dart run build_runner build`; future checkouts must regenerate after schema changes.
- The Workboard is operator-driven only. There is no LLM Harness execution integration in this slice.
- The deterministic scoring is intentionally simple and may need tuning after live planning use.

## Next Best Action

Review the v1.4 hardening diff, then commit it separately from the initial Workboard planning layer.
