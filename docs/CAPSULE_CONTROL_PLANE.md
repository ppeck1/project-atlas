# Capsule Control Plane Model

Project Ops Capsule is the canonical owner for cross-project operating
protocols. Project Atlas observes that protocol state, compares it to the
version adopted by each linked project, and stages upgrade work for operator
review. Atlas does not silently mutate sibling repositories.

This is a documentation and model slice only. It defines the protocol,
adoption, and upgrade-order contract that future runtime work can implement. It
does not define MCP stdio/client behavior, Project Detail UI behavior, or an
automatic multi-repo writer.

## Roles

| Surface | Responsibility | Explicit Non-Responsibility |
|---|---|---|
| Project Ops Capsule | Owns the canonical protocol catalog, protocol versions, adoption rules, upgrade notes, and validation expectations. | Does not directly edit projects through Atlas. |
| Project Atlas | Detects linked-project capsule metadata, compares adopted protocol versions to the canonical catalog, generates per-project upgrade work orders, and records adoption status. | Does not rewrite external repos, push Git changes, or mark adoption complete without operator evidence. |
| Project repository | Stores its local capsule metadata, evidence, and operator-approved upgrade results. | Does not define canonical protocol versions for other projects. |
| Operator | Approves, runs, defers, or rejects generated upgrade orders. | Is not bypassed by an agent, scheduled task, or scanner. |

## Canonical Protocol Catalog

The Capsule-owned catalog is the source of truth for protocol IDs and target
versions. A catalog entry should identify:

- `protocolId`: stable protocol key, such as `capsule.closeout` or
  `capsule.validation_state_split`.
- `version`: target semantic or dated version.
- `scope`: which project profiles the protocol applies to.
- `adoptionPolicy`: required, recommended, optional, deprecated, or blocked.
- `schemaRefs`: local or package-relative schema identifiers used by the
  protocol.
- `upgradeNotes`: concise notes for how an older project should adopt it.
- `validation`: commands or evidence required before adoption can be recorded.

Atlas may cache or import catalog snapshots, but the canonical definition stays
owned by Capsule. A cached snapshot should include a digest or source revision
so Atlas can explain why it generated an order.

## Detection

Atlas detection is read-only:

1. Resolve the Atlas project to a linked local repository.
2. Read local capsule metadata, such as `.project/project_manifest.json` and
   `.project/ops_capsule.json`, when present.
3. Read the Capsule protocol catalog snapshot supplied to Atlas.
4. Compare each applicable `protocolId` current version with the catalog target.
5. Emit a per-project upgrade work order when the project is missing,
   outdated, unsupported, or pending explicit adoption.

Detection may create Atlas records, review drafts, or queue items inside the
Atlas database, but it must not write into the linked project repository. Any
project-file mutation is a later operator-approved implementation step carried
out in that target project.

## Upgrade Work Orders

Generated work orders use the
`docs/schemas/capsule_upgrade_work_order_v1.schema.json` shape. A worked example
is in `docs/examples/capsule_upgrade_work_order_v1.example.json`.

Each work order includes:

- the Atlas project identity and capsule project identity;
- the detected protocol gap, current version, target version, and catalog
  digest;
- adoption status and status evidence;
- a guarded upgrade plan with steps and validation evidence;
- an explicit policy that `multiRepoMutationAllowed` is false and
  `operatorApprovalRequired` is true;
- forbidden actions that prevent silent sibling-repo writes, unapproved pushes,
  and broad mutation paths.

## Adoption Status

Atlas records adoption as state, not as proof of mutation. Valid statuses are:

- `not_detected`: Atlas has not read enough capsule metadata.
- `current`: the project already matches the target protocol.
- `upgrade_order_generated`: Atlas staged an order for review.
- `operator_approved`: the operator approved work against the target project.
- `in_progress`: approved upgrade work is underway.
- `adopted`: evidence shows the target project adopted the protocol.
- `blocked`: adoption is blocked by a concrete issue.
- `deferred`: the operator chose not to adopt yet.
- `not_applicable`: the protocol does not apply to the project profile.

An `adopted` record should include the protocol version, evidence reference,
validation result, and timestamp. A generated work order alone is never adoption.

## Guardrails

- No silent multi-repo mutation path. Atlas can generate work orders, not patch
  other repositories as a side effect of detection.
- No automatic Git push, publish, visibility change, clone, fetch, or remote
  edit.
- No cross-project "fix all" command without explicit per-project approval and
  evidence.
- No adoption completion without evidence from the target project.
- No use of raw local evidence packets as public protocol records; keep local
  paths and private logs in local-only evidence surfaces.
