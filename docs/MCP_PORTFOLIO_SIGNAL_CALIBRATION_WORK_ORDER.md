# MCP Portfolio Signal Calibration and Freshness Hygiene Work Order

- Status: **ACTIVE**
- Work order ID: `WO-PSC-1`
- Activated: 2026-07-14 by explicit operator confirmation
- Basis: public `origin/main` commit `709ec6405801eebb1b646f75ded620a16b8f8b13`
- Branch: `codex/portfolio-signal-calibration-20260714`
- Baseline matrix: `docs/MCP_PORTFOLIO_SIGNAL_REASON_MATRIX_20260714.md`

## Goal

Make remote portfolio signals selective and interpretable without changing the
approved portfolio, detail authorization, tool list, or read-only security
boundary. Planning urgency must no longer be inferred from freshness debt.

## Frozen Boundaries

- exactly four remote tools: `list_projects`, `get_project_status`,
  `atlas.workload_snapshot`, and `atlas.project_planning_context`;
- 49 operator-approved inventory rows;
- 2 detail-approved and 47 inventory-only rows;
- deny-by-default authorization and uniform detail denial;
- no remote writes, queue mutation, proposals, shell, filesystem, GitHub
  mutation, raw evidence, notes, commands, paths, secrets, or local IDs;
- no policy enrollment changes and no automatic future-project enrollment;
- no bulk freshness, lifecycle, priority, or work-queue cleanup.

Stop if implementation requires broadening any frozen boundary or if a
sanitized 49-project reason matrix cannot be produced before data cleanup.

## Accepted Signal Contract

Remote project projections expose a bounded `signals` object:

```json
{
  "planningActionRequired": false,
  "dataRefreshRequired": true,
  "severity": "low",
  "reasonClasses": ["freshness_stale", "local_evidence"]
}
```

`planningActionRequired` is limited to lifecycle review/update/block states,
blocked work, high-priority projects without active work, capsule errors, or an
explicit blocks-progress count. `dataRefreshRequired` covers stale/unknown
freshness and evidence-maintenance conditions. The legacy `needsAttention`
field remains as a compatibility alias for planning action only.

Severity is one of `none`, `low`, `medium`, or `high`. Reason classes are drawn
only from `lifecycle`, `workload`, `local_evidence`, `remote_evidence`,
`capsule`, `freshness_stale`, and `freshness_unknown`. Raw paths, commands,
evidence, identifiers, and arbitrary strings are never returned.

Freshness `stale` and `unknown` remain distinct. Neither state is cleared or
promoted to planning urgency merely to improve portfolio counts.

## Workload And Packet Contract

- Workload count objects label `workItems` and `llmQueueItems` separately while
  retaining the existing total/readiness counts.
- Workload and planning projections always emit a valid non-null UTC
  `generatedAt`. A valid upstream timestamp is preserved; missing or invalid
  upstream values fall back to the gateway projection time.
- Changed projected shapes use explicit schema versions:
  `project_atlas.remote_project_inventory.v3`,
  `project_atlas.remote_project_status.v2`,
  `project_atlas.remote_workload_snapshot.v2`, and
  `project_atlas.remote_planning_context.v2`.

## Execution Sequence

1. Capture the deployed 49-project raw freshness/attention baseline locally.
2. Project it through the approved ignored policy and write a public-safe
   alias/label matrix with only bounded signal classes.
3. Implement tests-first signal separation, severity/reason classification,
   explicit workload-family counts, and timestamp fallback.
4. Update Settings disclosure samples and public contract documentation.
5. Run focused security tests, the full Python and Flutter suites, analysis,
   Windows release build, gateway smoke, privacy scan, and clean-diff checks.
6. Publish through a reviewed pull request, require CI, merge, then refresh the
   live Atlas work item, decision, risk, handoff, remote, observation, and event
   records.

## Acceptance Criteria

- The tracked matrix contains exactly 49 approved aliases/labels and no local
  IDs or private paths.
- Freshness-only stale/unknown projects set `dataRefreshRequired=true` without
  forcing `planningActionRequired` or `needsAttention` true.
- Planning blockers remain visible and receive bounded severity/classes.
- All four projected schemas contain only allowlisted structured fields.
- Workload and planning counts explicitly separate work items from LLM queue
  items.
- Workload and planning timestamps are never null and reject arbitrary
  token-shaped upstream values.
- Inventory/detail counts, authorization split, policy capacity, OAuth,
  audit, and exact four-tool behavior do not change.
- Inventory-only aliases remain uniformly unavailable to every detail tool.
- Focused and full tests, analysis, release build, gateway smoke, privacy scan,
  reviewed PR, required CI, merge, and live Atlas closeout all pass.

## Non-Goals

- No bulk refresh or cleanup of the 37 stale and 10 unknown baseline rows.
- No accepted-truth, note, command, evidence-excerpt, or work-item-title
  disclosure.
- No policy migration, enrollment change, database schema change, OAuth/tunnel
  redesign, or gateway process-pool work.
- GitHub issue #1 remains separate.

## Rollback

Keep the accepted `e938f0a` deployment and current ignored v2 policy unchanged
until the new release passes smoke and authenticated readback. If activation
fails, restore the prior gateway executable while retaining the same policy,
tunnel, OAuth configuration, and audit path. Record the failed gate in Atlas;
do not broaden disclosure or clear data flags to force acceptance.
