# Handoff

## Current State

Project Atlas is a public Flutter Windows desktop repo. The active app repo is this directory, not the outer wrapper folder.

WO-PSC-1 is the current governed source-publication slice. Production runs the
verified `24054b5` release with the retained v2 disclosure policy, OAuth/JWKS,
tunnel, audit path, exact four read-only tools, 49 inventory approvals, and the
2-detail/47-inventory-only authorization split. Authenticated connector
readback verified inventory v3 plus status/workload/planning v2, calibrated
planning-versus-refresh signals, explicit workload-family counts, non-null UTC
packet timestamps, and uniform inventory-only detail denial. GitHub PR state is
authoritative for the final source-publication gate.

This v1.4 slice adds the Workboard Planning Layer. A later Shopify SEO hardening slice adds a draft-backed, stage-only Project Detail Shopify SEO review workflow; this document preserves the v1.4 release evidence below and should not be read as the newest feature inventory by itself.

Current MCP hardening continuation: Settings -> Integrations now includes a
local-only ChatGPT remote disclosure preview. It reads ignored connector
config/policy/audit metadata and loopback gateway metadata; separates inventory
and detail aliases; shows eligible unenrolled candidates, escaped unsafe labels,
stable alias proposals, title-baseline drift, bounded policy errors, page count,
byte estimates, exact tools, OAuth shape, short policy fingerprint, recent safe
audit metadata, and synthetic redacted samples. It does not start the gateway or
tunnel or serialize local IDs/unenrolled labels. Active executable identity
remains explicitly unverified until process attestation exists.

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
| Run ID | `20260714-wo-psc1-execution` |
| Run State | WO-PSC-1 production activation and authenticated connector readback verified; source publication is governed by PR merge |
| Last Verified At | 2026-07-14 |
| Validation State | production inventory v3 and status/workload/planning v2, calibrated signals, audit routing, detail isolation, timestamps, and rollback evidence verified |
| Release Commit | `24054b586ffbe0893d3381ef21dc0b7c94d9bce7` |
| Accepted Public Main Hash | `709ec6405801eebb1b646f75ded620a16b8f8b13` (WO-PSC-1 base) |
| Remote | `https://github.com/ppeck1/project-atlas.git` |

## Validation Evidence

- WO-PSC-1 production activation completed from the immutable
  `project-atlas-deploy-24054b5` checkout. Runner SHA-256:
  `CD99E3ADCF4147B73A2BF37E90CE85AB31860A472FFAB7EF6D516A3C3EFA8B63`;
  `data/app.so` SHA-256:
  `FB124577CDB72BFC7929E0E6123D52B387483B2A69905BD8792FB46762A25912`.
  The gateway-only replacement retained the existing tunnel, OAuth/JWKS,
  ignored v2 policy, and metadata-only audit path.
- Authenticated connector readback returned 49 inventory v3 rows with the
  unchanged 2-detail/47-inventory-only split. It classified 28 planning-action
  and 48 data-refresh projects; freshness stayed 2 current, 37 stale, and 10
  unknown; severity was 2 high, 33 medium, 13 low, and 1 none. Inventory-only
  detail remained unavailable.
- Status, workload, and planning returned v2. Workload/planning generated valid
  non-null UTC timestamps and separated 15 work items from 16 LLM queue items.
  The surface retained exactly four tools and did not add remote writes.
- WO-PSC-1 verification passed 29 Python tests, 51 focused Flutter tests, all
  274 runnable full-suite Flutter tests with 1 expected environment-gated skip,
  repo-wide Dart formatting with 0 changes, `flutter analyze`, Drift build
  generation, Windows release build, full OAuth/JWKS gateway smoke with all 29
  hidden tools rejected, populated-runtime probe, privacy scan, and clean-diff
  checks.

- WO-RPI-1 production activation completed from the immutable
  `project-atlas-deploy-e938f0a` checkout. The full 16-file Windows release
  directory was hash-compared with zero mismatches before activation. Runner
  SHA-256: `F3C86C08DF95D4FBF26F31D113250C225C7276D4A1DA8117487975EC71962033`;
  `data/app.so` SHA-256:
  `9D645C4357B73B6A0F683AA1D3B60C7525EC92E0B6019AE708F9F66E46E69BE7`.
- The final v2 policy contains 49 inventory approvals: 2 detail-approved and
  47 inventory-only. A conservative identifier-shaped source title received a
  curated human-readable remote label and alias before activation. The policy
  is 13,384 bytes; the authenticated no-argument inventory returned all 49
  projects in one 12,639-byte page with `nextOffset: null`.
- Production port 4874 now loads the v2 policy from the accepted deployment,
  passes the local policy-digest check, retains deny-by-default OAuth/JWKS and
  exactly four read-only tools, and routes disclosure audit events explicitly
  into the main Atlas state directory. The existing tunnel process was retained
  without restart and remained ready throughout the gateway-only replacement.
- Authenticated connector readback passed: inventory schema
  `project_atlas.remote_project_inventory.v2`, portfolio disclosure scope,
  successful Atlas and Capsule detail reads, uniform not-found denial for an
  inventory-only detail read, detail-tier-only global workload projection, and
  successful Atlas planning context. The shared audit advanced for all four
  tools under the v2 policy with no local-ID leakage.
- Immediate pre-activation backups of the ignored v1 policy and autostart
  configuration were created and hash-verified. The prior `242914c` deployment
  and the byte-identical v1 policy backup remain available for gateway-only
  rollback without restarting the tunnel.
- The final audit-routing delta passed its focused autostart suite (`8/8`),
  `flutter analyze`, the full Flutter suite (`274` passed, `1` expected skip),
  Python policy tests (`23/23`), Windows release rebuild, full deployment smoke
  (`29` hidden tools rejected; OAuth and JWKS paths passed), and the populated
  49-project pre-activation gateway check.
- WO-RPI-1 source verification passed: Python policy/gateway tests (`27/27`),
  Dart formatting (`90` files, `0` changes), `flutter analyze` (no issues),
  focused Flutter tests (`47/47`), full Flutter suite (`273` passed, `1`
  expected environment-gated skip), build runner (`119` outputs), Windows
  release build, and full temporary-gateway smoke. The smoke retained exactly
  four projected tools, rejected all 29 hidden tools, emitted 46 metadata-only
  audit events, and passed OAuth/JWKS challenge, metadata, origin, and negative
  path checks. Release executable SHA-256:
  `F3C86C08DF95D4FBF26F31D113250C225C7276D4A1DA8117487975EC71962033`.
- Before activation, the production-boundary readback confirmed that port 4874
  still served the accepted v1 two-project policy and that the live policy
  matched its pre-WO-RPI-1 backup. That frozen evidence remains the rollback
  baseline.
- WO-RPI-1 controlled portfolio measurement used a temporary localhost-only v2
  policy and audit with the accepted release executable; production port 4874,
  policy, and tunnel were unchanged. Eligible local inventory: 49. Immediately
  safe candidate inventory: 48; detail tier: 2; unsafe labels requiring review:
  1; alias safety adjustments: 1. The no-argument list returned all 48 rows in
  one page: 12,356-byte inner DTO, 14,302-byte projected response, about 3,089
  estimated tokens, 297.96 response bytes/project, gateway p50 3,101.5 ms and
  p95 3,219 ms. Baseline v1 gateway p95 was 3,375 ms.
- Independent repair verification passed the 128 KiB/256-row boundary,
  Python/Dart label-validation parity, bounded parse diagnostics, escaped
  bidi/control rendering, and source-title-fingerprint drift baseline with no
  remaining P1/P2 finding.
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
