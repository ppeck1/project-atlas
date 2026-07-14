# MCP Portfolio Inventory Disclosure Work Order

- Status: **COMPLETE**
- Work order ID: `WO-RPI-1`
- Created: 2026-07-14
- Basis: accepted `origin/main` commit `242914c3db034da862881192876d78395ad49307`
- Planning branch: `planning/mcp-portfolio-inventory-20260714`
- Atlas queue task: active and verified as `pending`, `ready`, and high priority; the local task ID is retained only in Atlas and the ignored run ledger
Implementation state: v2 portfolio inventory is active on the retained ChatGPT tunnel from accepted commit `e938f0a0096772df5ea6f2d31931dc44ed86cc8c`; authenticated readback, detail isolation, shared audit routing, and v1 rollback artifacts are verified

## Goal

Make the ChatGPT-facing Project Atlas MCP useful for portfolio management by
returning the complete current, operator-reviewed project inventory from a
normal `list_projects` call while preserving a narrower approval boundary for
detailed project reads.

The completed behavior must let ChatGPT discover every currently eligible Atlas
project through compact, sanitized metadata without exposing local IDs, local
paths, private notes, commands, raw evidence, hidden inventory, or any write
authority.

## Current Evidence

- Local Atlas, local stdio MCP, and the authenticated ChatGPT inventory expose
  the same 49 operator-approved normal visible projects.
- The production v2 policy grants detailed reads to `project-atlas` and
  `project-capsule`; the other 47 approved aliases are inventory-only.
- The remote gateway is OAuth `atlas.read`, `remote_readonly`, deny-by-default,
  and exposes exactly four read tools.
- Valid v1 rows remain compatible as both inventory and detail capabilities,
  and the backed-up v1 two-project policy remains the verified rollback path.
- Project names can themselves be sensitive. Regex cleanup or slug generation
  is not a substitute for operator approval of the remote label.

## Product Decision

Adopt two independent remote disclosure capabilities:

| Capability | Purpose | Initial scope |
|---|---|---|
| Portfolio inventory | Compact discovery through `list_projects` | Every currently eligible project whose alias and label are explicitly operator-approved |
| Detailed reads | Status, workload, and planning context | Existing approved detail projects, initially Project Atlas and Project Capsule |

Inventory membership must not imply detailed-read access. Future projects are
not enrolled automatically in this first slice; Settings must identify them for
operator review.

## Frozen Remote Tool Boundary

The remote tool list remains exactly:

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`
- `atlas.project_planning_context`

No queue, proposal, enrichment, GitHub refresh, bootstrap, shell, filesystem,
raw-file, execution, approval, or write tool may be added.

Tool authorization after this work order:

| Tool | Inventory-visible project | Detail-approved project |
|---|---|---|
| `list_projects` | Included | Included |
| `get_project_status` | Denied uniformly | Allowed |
| `atlas.workload_snapshot` | Excluded from global/project results | Allowed |
| `atlas.project_planning_context` | Denied uniformly | Allowed |

## Proposed Policy Contract

Introduce a fail-closed v2 ignored local policy with explicit per-project
capabilities. The exact property names may change during implementation review,
but the security semantics may not.

```json
{
  "schema": "project_atlas.remote_disclosure_policy.v2",
  "projects": [
    {
      "projectId": "local-id-never-returned-remotely",
      "alias": "project-atlas",
      "label": "Project Atlas",
      "access": ["inventory", "detail"]
    },
    {
      "projectId": "another-local-id-never-returned-remotely",
      "alias": "inventory-only-alias",
      "label": "Operator Approved Label",
      "access": ["inventory"]
    }
  ]
}
```

Required policy behavior:

- Parse only known root and row fields; reject unknown capabilities.
- Require unique local IDs and aliases.
- Keep aliases stable, persisted, and unrelated to local IDs or ID-derived
  hashes.
- Require every remote label to be an operator-approved snapshot.
- Treat title changes as local disclosure drift requiring review; do not
  silently replace approved labels.
- Retain safe v1 compatibility during the staged migration by interpreting each
  valid v1 entry as both `inventory` and `detail` until the v2 policy is
  explicitly activated.
- Set the v2 policy capacity to 256 inventory entries and no more than 64
  detail-approved entries. Exceeding either bound is a hard preview/startup
  failure, not a pagination condition.
- Fail startup or preview visibly on malformed entries, duplicate aliases,
  capacity overflow, unresolved local IDs, or unsafe policy location.

## Inventory Eligibility

The inventory source must independently exclude:

- rows with `deleted_at` set;
- rows whose lifecycle status is deleted or archived;
- the canonical General Tasks sentinel ID;
- legacy General Tasks sentinel-marker rows;
- malformed rows that cannot be projected safely.

Paused and completed projects remain eligible unless a later operator decision
changes that rule. Deleted, archived, and sentinel projects must also remain
unavailable to every detailed remote tool.

The local `includeArchived` semantic discrepancy must be fixed or explicitly
contained before bulk policy activation. Remote filtering remains authoritative
even after the local query is corrected.

## Compact Inventory Response

`list_projects` must rebuild a new compact
`project_atlas.remote_project_inventory.v2` DTO. It must not forward the local
project object and then redact fields. Its disclosure notice must identify an
operator-approved portfolio inventory, state that detailed reads require
separate approval, and keep `denyByDefault=true` without reporting hidden
counts.

Each inventory row may contain only:

- `projectId`: stable approved remote alias;
- `title`: approved remote label;
- `status`;
- `phase`;
- `priority`;
- `needsAttention`;
- `freshness.status`;
- `workItems.active`;
- `workItems.blocked`;
- `workItems.blocksProgress`;
- `detailsAvailable`: whether detailed tools are approved for the alias.

Move document/media/risk/decision counts, freshness reason arrays, confidence,
and richer workload details out of the portfolio list. They remain available
only where the existing detail policy permits them.

No-argument `list_projects` must behave as `offset=0, limit=64`, returning the
complete current eligible inventory in one compact page at the present
49-project scale. Explicit `limit` accepts 1 through 64 and is
never silently raised above the requested value; explicit `offset` remains
nonnegative and bounded. Preserve deterministic alias ordering, `total`,
`returned`, `truncated`, and `nextOffset`. If disclosed inventory is 65 through
256 projects, the first no-argument call returns exactly the first 64 rows with
`truncated=true` and `nextOffset=64`; the local preview must flag that multiple
pages are required, and subsequent explicit pages must produce a complete
result without duplicates or gaps. A candidate above the 256-entry v2 policy
capacity is rejected before activation. `total` means disclosed eligible
inventory only; never return local totals, hidden counts, excluded counts, or
detail-approved counts.

## Settings And Operator Review

Enhance the existing local-only disclosure preview rather than creating a
second diagnostics page.

It must show:

- inventory-visible count and exact proposed remote aliases/labels;
- detail-approved count and exact detail aliases;
- eligible-but-not-enrolled projects;
- unresolved entries, duplicate/colliding aliases, title drift, multi-page
  inventory, and policy-capacity overflow;
- exact compact inventory sample and estimated response bytes;
- current versus candidate policy fingerprint and restart-required state;
- gateway policy identity after restart.

The operator must review the complete candidate label list before the ignored
v2 policy is written or activated. This work order does not authorize automatic
future-project enrollment.

## Files And Surfaces

Primary implementation targets:

- `tools/atlas_mcp_remote_policy.py`
- `tools/atlas_mcp_gateway.py`
- `tools/test_atlas_mcp_remote_policy.py`
- `tools/smoke_mcp_gateway.py`
- `lib/services/atlas_agent_service.dart` and/or `lib/db/app_db.dart` for the
  local archived/deleted/sentinel eligibility correction
- `lib/services/mcp_disclosure_preview_service.dart`
- `lib/features/settings/mcp_disclosure_preview_panel.dart`
- `test/mcp_disclosure_preview_service_test.dart`
- `test/mcp_disclosure_preview_panel_test.dart`
- `test/atlas_agent_service_test.dart`
- `docs/MCP_ACCESS.md`
- `docs/MCP_CONNECTOR_PATH.md`
- `docs/MCP_CONNECTOR_AUTOSTART.md`
- `docs/MCP_AUTH0_JWKS_CONNECTOR_SETUP.md`
- `docs/VARIABLE_MATRIX.md`
- `VARIABLE_MAP.md`
- `README.md`
- `HANDOFF.md` and `docs/HANDOFF.md`

The populated disclosure policy, policy backups, audit log, live DB, raw
project inventory, and machine-specific process configuration remain ignored
and must not be committed.

## Execution Sequence

### Wave 0 - preflight and frozen evidence

1. Verify the inner repo, branch, accepted `origin/main`, clean baseline, and
   live gateway/tunnel identities.
2. Back up the ignored v1 disclosure policy and record its SHA-256.
3. Capture the current two-project response, response bytes, per-project bytes,
   gateway duration, and policy metadata.
4. Confirm local eligible inventory and separately enumerate deleted, archived,
   canonical-sentinel, and legacy-sentinel exclusions.

### Wave 1 - tests-first eligibility and policy v2

1. Add adversarial eligibility fixtures before changing policy behavior.
2. Implement the v2 capability model and safe v1 normalization.
3. Split inventory alias resolution from detail authorization.
4. Keep global workload visibility restricted to detail-approved projects.
5. Prove inventory-only aliases receive the same unavailable response as
   unknown aliases and guessed local IDs.

### Wave 2 - compact projection and token budget

1. Create a dedicated compact inventory summary separate from detailed status.
2. Increase the no-argument page behavior only after measuring the full
   projected portfolio under the hard response cap.
3. Add deterministic sorting, pagination metadata, capacity checks, and
   response-size enforcement.
4. Preserve exact four-tool metadata and OAuth behavior.

### Wave 3 - operator preview and policy candidate

1. Extend Settings disclosure preview with inventory/detail tiers and exact
   candidate labels.
2. Generate stable candidate aliases, flag collisions and unsafe labels, and
   require explicit operator confirmation.
3. Write only the ignored local policy after approval; never seed personal
   project names or IDs into tracked fixtures or documentation.
4. Verify the local preview matches a controlled gateway projection before
   production activation.

### Wave 4 - release, activation, and authenticated readback

1. Run the full verification loop and build a clean accepted release artifact.
2. Back up the live ignored policy again immediately before activation.
3. Restart the gateway from the accepted artifact with the v2 policy while
   retaining the existing tunnel.
4. Verify command-line artifact identity, policy digest, OAuth metadata, audit
   routing, exact tools, and listener/tunnel health.
5. Run an authenticated ChatGPT `list_projects` readback, one inventory-only
   detail denial, and successful Atlas/Capsule detailed reads.
6. Record the accepted commit, artifact hashes, policy fingerprint, response
   measurements, rollback backup, and Atlas handoff.

## Token-Saving Swarm Protocol

Use bounded agents only where they reduce repeated repository reads:

1. **Policy scout - read-only:** policy schema, request preparation, projection,
   audit, and adversarial-test map.
2. **Eligibility/privacy scout - read-only:** local visibility semantics,
   sentinel/deletion cases, unsafe labels, and leak probes.
3. **Preview/docs scout - read-only:** Settings preview, docs, variable matrix,
   and operator-flow impact.
4. **Single implementation lane:** one agent owns all edits and resolves scout
   findings into a coherent contract. No parallel edits to shared policy,
   gateway, preview, or test files.
5. **Independent verifier - read-only:** reviews the completed diff, runs the
   focused security matrix, and reports findings before full build/deployment.
6. **Orchestrator:** owns scope, integrates findings, runs final verification,
   and permits at most two repair iterations as required by the installed
   Project Ops Capsule.

Each scout returns paths, symbols, evidence, and at most five actionable
findings. The implementation agent receives only the converged work order and
those findings, not duplicate transcripts.

## Verification Loop

Run in this order and stop at the first failing gate:

```powershell
python -m py_compile tools\atlas_mcp_gateway.py tools\atlas_mcp_remote_policy.py tools\smoke_mcp_gateway.py tools\test_atlas_mcp_remote_policy.py
python -m unittest discover -s tools -p "test_*.py" -v
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test test\mcp_disclosure_preview_service_test.dart test\mcp_disclosure_preview_panel_test.dart test\atlas_agent_service_test.dart test\atlas_mcp_adapter_test.dart test\atlas_mcp_stdio_server_test.dart --concurrency=1
flutter test
dart run build_runner build --delete-conflicting-outputs
flutter build windows --release
python tools\smoke_mcp_gateway.py --exe build\windows\x64\runner\Release\project_atlas.exe
git diff --check
git status --short --branch
```

Required adversarial cases:

- active status with `deleted_at`, deleted status without `deleted_at`, archived
  status, canonical sentinel, and legacy sentinel;
- duplicate titles, alias collisions, title rename drift, Unicode/control/bidi
  characters, email-like titles, Windows paths, URLs, and token-shaped labels;
- negative, boolean, oversized, and past-total pagination arguments;
- a 65-row multi-page inventory, 256-row boundary, 257-row policy-capacity
  failure, and malformed/unknown policy capabilities;
- inventory-only alias attempts against all detailed reads;
- local ID, alias case variant, and unknown alias probes;
- poisoned upstream fields, counts, hidden workload cards, raw JSON, paths,
  commands, tokens, owner names, emails, URLs, and SHAs;
- direct calls to every denied tool;
- audit-log checks proving no request bodies, tokens, local IDs, or project
  labels are recorded;
- stale gateway/policy digest mismatch and rollback-policy startup.

## Optimization Loop

Measure before and after each repair iteration:

- response bytes and estimated tokens;
- bytes per project;
- calls needed for the current eligible inventory;
- p50 and p95 gateway duration;
- duplicate/gap count across pagination;
- inventory classification and count parity against the approved preview.

Targets:

- complete current eligible inventory from a no-argument call;
- no duplicates, gaps, classification drift, or hidden-count leakage;
- no more than 24 KiB canonical JSON for the current full portfolio and always
  below the existing 64 KiB hard cap;
- no more than roughly 6,000 estimated tokens for the current full portfolio;
- no greater than 10% p95 duration regression from the measured baseline;
- no redundant record counts or detailed freshness arrays in the inventory DTO.

Optimization may remove redundant inventory keys or reduce repeated nesting.
It may not weaken eligibility, detail authorization, OAuth, audit, or response
caps. Long-lived stdio children, process pools, transport changes, and cache
redesign are separate work orders.

## Exit Criteria

The work order is complete only when:

- the operator has reviewed every remote alias and label in the current
  inventory candidate;
- a no-argument authenticated `list_projects` returns every approved eligible
  project and nothing else;
- deleted, archived, and both sentinel forms are absent from list and detailed
  reads;
- inventory-only projects are listed but uniformly denied detailed access;
- Project Atlas and Project Capsule retain successful detailed reads;
- global workload data contains only detail-approved projects;
- the response meets the byte/token/latency targets;
- Settings preview and the live ChatGPT result agree;
- the gateway still exposes exactly four read-only tools and every write probe
  fails;
- no local IDs, paths, notes, titles not explicitly approved, hidden totals, or
  other forbidden fields appear in responses or audit logs;
- focused tests, full tests, analysis, release build, clean-checkout gateway
  smoke, tunnel health, OAuth checks, and authenticated ChatGPT readback pass;
- accepted source, artifact hashes, policy fingerprint, backup, measurements,
  and Atlas handoff are recorded.

## Non-Goals

- No remote writes, queue mutation, proposal approval, GitHub mutation, shell,
  filesystem, or raw evidence access.
- No automatic enrollment of future projects in this first slice.
- No archived, deleted, sentinel, or raw local inventory disclosure.
- No raw project briefs, work-item titles, notes, owners, contacts, tags,
  descriptions, paths, URLs, branches, SHAs, commands, or evidence excerpts.
- No OAuth provider, tunnel, or four-tool-surface redesign.
- No database schema migration unless eligibility cannot be corrected without
  one and the operator approves that expanded scope.
- No long-lived stdio child, process pool, caching, or unrelated performance
  work.
- No cleanup or reprioritization of older Atlas queue rows in this work order.

## Rollback

1. Stop only the replacement gateway after identity verification.
2. Restore the backed-up v1 two-project policy.
3. Restart the last accepted `242914c` gateway/executable pair on loopback port
   4874 while retaining the existing tunnel.
4. Verify the restored policy digest, OAuth metadata, exact four tools, and the
   prior two-project result.
5. Preserve failed v2 audit/test evidence locally and record the blocker in an
   Atlas handoff; do not silently fall back or broaden disclosure.
