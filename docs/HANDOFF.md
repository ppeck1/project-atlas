# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder.

Active work order `WO-RPI-1` is defined in
`docs/MCP_PORTFOLIO_DISCLOSURE_WORK_ORDER.md`. It plans a tiered remote MCP
disclosure model: an operator-reviewed compact inventory for every currently
eligible project, separately approved detailed reads, the same exact four
read-only tools, and no remote writes. The work order is queued for execution;
the live gateway remains on the verified two-project policy until the staged
implementation, privacy review, optimization loop, release build, and explicit
policy-activation gate pass.

This v1.4 slice adds the Workboard Planning Layer. A later Shopify SEO hardening slice adds a draft-backed, stage-only Project Detail Shopify SEO review workflow; this document preserves the v1.4 release evidence below and should not be read as the newest feature inventory by itself.

Current MCP hardening continuation: Settings -> Integrations now includes a
local-only ChatGPT remote disclosure preview. It reads ignored connector
config/policy/audit metadata and loopback gateway metadata, shows approved
aliases, exact tools, disclosed field groups, OAuth scope/verifier shape, short
policy fingerprint, recent safe audit metadata, and synthetic redacted samples,
and does not start the gateway or tunnel. Active executable identity remains
explicitly unverified until process attestation exists.

- Work items now carry planning metadata: readiness, size, risk, suggested actor, verification needed, next action, planning notes, and last reviewed timestamp.
- Existing work-item `blocked_reason` remains the blocker source of truth for work items.
- LLM queue rows now carry the same planning metadata plus `blocker_reason`.
- `/work` is now a primary Workboard view in the left rail, grouped into Ready, Needs Decision, Blocked, In Progress, Review Needed, and Done / Closed.
- Workboard cards show project, task title, owner/contact, readiness, size, risk, suggested actor, verification needed, due/priority/status, LLM queue linkage, blocker reason, and next action.
- Project Detail now has per-project display controls from the settings icon beside Open Workboard. Section visibility is stored in `app_meta` and hides irrelevant opened-project sections without deleting data.
- Project Detail Workboard entry points route to the project-scoped Workboard, and the embedded Project Workboard section includes an explicit Open full board action.
- Project Detail bundle export now exposes the same core bundle contents as the Settings export wizard: files, AI summary, project logs, change log, clean git archive, bootstrap context, and log window.
- Project Detail Shopify SEO loading is lifecycle-safe: review snapshots load after `AppStateScope` is available during the widget lifecycle.
- Filters cover project, readiness, actor, risk, size, blocked only, review needed, stale/unreviewed, and high priority.
- Bulk planning actions are explicit operator actions: mark ready, mark blocked, assign suggested actor, set size/risk/verification, mark reviewed today, create LLM queue item from work item, and link existing LLM queue item.
- Planning Snapshot shows ready/blocked/review/stale counts, actor/risk breakdowns, ready-only execution candidates, and separate planning/decision candidates.
- MCP adds read-only planning tools: `atlas.workload_snapshot`, `atlas.project_planning_context`, `atlas.project_workload`, `atlas.suggest_next_work`, and `atlas.work_item_context_bundle`.
- Shopify SEO review now lives in Project Detail as a draft-backed import/analyze/export/queue surface. It has no live Shopify writes, no Admin API credential requirement, and no broad MCP Shopify tools.

## Last Run

| Field | Value |
|---|---|
| Run ID | `20260710-a0b-disclosure-preview` |
| Run State | A0b remote MCP disclosure preview merged |
| Last Verified At | 2026-07-10 |
| Validation State | complete locally and in CI: independent review, format, analyze, focused preview/autostart tests, Python remote-policy tests, full suite, release build, gateway smoke, and GitHub Actions CI |
| Release Commit | `c3e056d46fb87ed451f59bd47174ae95a1de0c08` (PR #8 head) |
| Accepted Public Main Hash | `583928a08058b946a826258ba889626c8d8c8f5f` (PR #8 merged 2026-07-10) |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- A0b remote MCP disclosure preview closeout: PR #8 merged to public `main`
  at `583928a08058b946a826258ba889626c8d8c8f5f`. GitHub Actions CI run
  `29114864112` passed. Local validation before merge: `flutter analyze`,
  focused preview/autostart tests (`14` passed), Python remote-policy tests
  (`15` passed), full Flutter suite (`262` passed, `1` skipped), Windows
  release build, gateway smoke on `127.0.0.1:4894`, and `git diff --check`.
- Real v1.3/schema 19 DB migration checkpoint: `flutter test --dart-define=ATLAS_SCHEMA20_SOURCE_DB=... --dart-define=ATLAS_SCHEMA20_EVIDENCE_PATH=... test\schema20_real_migration_test.dart --concurrency=1 --reporter expanded` passed. Evidence shows `userVersion` 19 -> 20, Workboard columns present on `work_items` and `llm_task_queue`, and existing row counts preserved. Source DB SHA-256: `5524F901414BC67A68BFE4E5C08B1904673C9FDAD7EAACA9BCF4F7CA3EEAE732`. Private evidence JSON SHA-256: `AE73D9F8AF20180F981960559BA2489B1865E4926038184A3B28C636BB6FD96E`.
- Screenshot file audit and visual spot-check: all README screenshots present under `docs/screenshots/` with July 3, 2026 timestamps (`today.png`, `projects.png`, `operations.png`, `library.png`, `settings.png`); Today and Projects captures show the current v1.4 navigation, Workboard/project detail actions, LLM queue, runtime controls, and Library evidence surfaces.
- `dart format --output=none --set-exit-if-changed lib test`: pass, 70 files checked, 0 changed.
- `flutter analyze`: pass, no issues found.
- Focused release tests: `flutter test test\workload_planning_test.dart test\atlas_mcp_adapter_test.dart test\create_work_item_dialog_test.dart test\schema20_real_migration_test.dart --concurrency=1 --reporter expanded`: pass, 16 tests passed and the real-DB checkpoint skipped in normal mode.
- Full suite: `flutter test --concurrency=1 --reporter expanded`: pass, 215 tests passed and 1 skipped env-gated migration checkpoint.
- `git diff --check`: pass.
- `flutter build windows --release`: pass, built `build\windows\x64\runner\Release\project_atlas.exe`.
- Windows release asset: `atlas-windows-v1.4.0.zip`, 15,901,566 bytes, SHA-256 `F365A9EC9B9E6D910E2D946D46AA6FD34C6960497E07F685C981C9F934A4A334`.

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
- Restore/import is not implemented yet and should be the next feature lane before deeper agent autonomy.

## Next Best Action

After A0b, keep the remaining audit work split into narrow lanes: R0 backup/restore, WO-A1 timestamp/path repair, A2/A3 semantics, and later process binary attestation/supervision.
