# ADR: Project Sources, Reconciliation, and Freshness Projection Consistency

Status: Accepted; MVP implemented in schema 22

Date: 2026-07-15

## Context

Project Atlas currently has two related but distinct concepts:

- canonical Atlas projects, stored as `projects`
- local discovery and source records, stored as `project_registry`

The current Operations UI still presents registry rows as "Registered Projects",
which makes source records look like a second project portfolio. The live store
also demonstrates why this is misleading: registry rows can outnumber canonical
projects, and multiple registry rows can point at one Atlas project.

The current registry schema is path-keyed. `project_registry.id` is the stable
row identity, while `local_path` is unique. Refresh provenance is stored in
`local_project_refresh_items` by `registry_id`, `source_kind`, and `source_key`.
GitHub status already has a separate typed model in `project_git_remotes`.

There is also a freshness projection defect. `get_project_status` and
`atlas.project_planning_context` both use `ProjectFreshnessService`, but they
do not supply the same inputs. The status path builds freshness without capsule
metadata, while planning context builds freshness with capsule metadata. This
can make one projection report a project as current and another report the same
project as stale due to `capsule_metadata_missing`.

## Decision

Project Atlas will introduce an explicit `ProjectSource` concept and a
project-scoped reconciliation contract. A source is evidence for a project; it
is not itself a project.

The schema 22 implementation keeps the persisted table name
`project_registry`, adds explicit source-topology fields, exposes Project
Sources in Operations, adds an Atlas-only reconciliation preview, and keeps
semantic identity writes proposal-first.

`General Tasks` remains a normal project. It is miscellaneous work, not a
system container, and should be counted in project totals.

Project freshness and planning packet completeness are separate concepts:

- `projectFreshness` answers whether project evidence is current enough.
- `planningContextCompleteness` answers whether an agent planning packet has
  the required capsule, manifest, handoff, and verification context.

Missing capsule metadata must not make the whole project stale by default. It
should make planning context incomplete unless the project's reconciliation
policy explicitly requires capsule metadata for freshness.

## Source Model

Each source has an explicit role. Initial roles:

- `primary_working`: authoritative local working repository or folder
- `public_mirror`: public or sanitized mirror derived from another source
- `supporting_knowledge`: supporting documents or knowledge, not identity
  authority
- `remote_authority`: remote repository used when no local checkout exists
- `archive_snapshot`: historical source retained for lineage
- `generated_export`: derived package, export, build, or release artifact
- `retired_source`: former source retained for history
- `ignored_candidate`: scanner observation intentionally excluded
- `unresolved_candidate`: source row that must be reviewed before it can carry
  project identity authority

A portfolio project may have many sources, but only one active
`primary_working` source. If there is no active primary source or more than one
unresolved primary candidate, identity reconciliation is blocked.

## Authority Rules

Observed facts can be auto-applied when their source is authoritative:

- local path availability
- Git root
- branch and HEAD observation
- dirty count
- API-verified GitHub owner, repository, visibility, default branch, and remote
  timestamps

Semantic project fields are proposal-first:

- title
- description
- desired outcome
- success criteria
- phase
- priority
- scope
- outcome summary
- lessons learned

Derived tags may be replaced as a derived set. Manually assigned tags must not
be overwritten by reconciliation.

Public mirrors provide publication and remote-visibility evidence. They do not
drive canonical identity unless the project has no local primary source and the
operator explicitly marks the mirror as `remote_authority`.

## Reconciliation Outcomes

Reconcile Project returns a structured result with channel-level status and a
final outcome.

Channel statuses:

- source topology
- local repository observation
- local evidence refresh
- GitHub remote evidence
- identity
- planning context completeness
- open findings and proposals

Final outcomes:

- `current`
- `current_with_declared_exclusions`
- `partial`
- `blocked`
- `failed`

Existing bounded refresh can be used for the MVP. Source-index redesign is not
a prerequisite. The MVP must report coverage honestly:

- eligible
- processed
- unchanged
- excluded by policy
- deferred by cap
- failed
- missing since previous run

## Freshness Projection Contract

For the same project and snapshot time, UI, Project Health, local MCP, and
remote MCP projections must agree on:

- `projectFreshness.status`
- `dataRefreshRequired`
- stale or refresh reason classes
- whether the project needs operator attention

A projection may redact details, but it must not independently calculate a
contradictory status. If a projection intentionally downgrades status because
of its narrower surface, it must expose a named downgrade reason.

`capsule_metadata_missing` is planning-context debt by default. It should not
be an overall project freshness stale reason unless the project policy marks
capsule metadata as required evidence.

The gateway and connector health checks should eventually expose a non-secret
build or source revision fingerprint. Current checks can prove the gateway is
healthy, but not that the running executable matches the current source tree.

## Migration Invariants

Future schema work must preserve these invariants:

- Preserve every existing `project_registry.id`.
- Preserve `local_project_refresh_items` provenance:
  `registry_id`, `source_kind`, `source_key`, `target_type`, `target_id`, and
  `source_fingerprint`.
- Keep `project_git_remotes.registry_id` optional but populate it when the
  remote status is source-derived.
- Treat remote URLs stored in `local_path` as legacy source rows requiring
  classification or replacement, not as valid local filesystem sources.
- Do not infer source role from registry `classification`, project `category`,
  path depth, or most-recent update time.
- Duplicate repository/source rows must remain reviewable after migration.
- Ambiguous source classifications become proposals; they are not guessed.
- Preserve timestamp unit contracts unless a dedicated migration and tests
  intentionally change them.

## Implementation Order

1. Terminology and metrics:
   - rename "Registered Projects" to "Project Sources"
   - rename run-level `linkedProjects` to `linkedSources`
   - add distinct linked-project count
   - display total, filtered, linked, unlinked, ignored, and unresolved counts

2. Source topology schema and migration:
   - add source role, type, lifecycle state, authority, precedence, and
     normalized identity
   - preserve registry IDs and refresh-ledger provenance
   - generate proposals for ambiguous source classifications

3. Topology preflight:
   - detect missing primary source
   - detect multiple primary candidates
   - detect duplicate repositories
   - detect public mirrors, archive snapshots, generated exports, remote URLs
     in local fields, and missing paths
   - block identity writes when authority is unresolved

4. Reconcile Project MVP:
   - project-scoped command from Project Detail
   - preview-first local refresh using existing bounded refresh
   - explicit coverage reporting
   - separate GitHub refresh stage or call-to-action
   - proposal-first semantic identity changes
   - final reconciliation outcome

5. Source-index optimization:
   - add lightweight source inventory
   - separate source-file indexing from selected Library document promotion
   - add resumable changed-first processing

6. Verification:
   - synthetic duplicate-source fixtures
   - remote URL in `local_path`
   - missing source paths
   - public mirror plus primary working source
   - archive/export rows
   - stale/deleted source files
   - representative local-project dry runs
   - MCP agreement checks across remote projections

## Acceptance Criteria

- `General Tasks` is counted as a project.
- Missing capsule metadata does not make `projectFreshness` stale by default.
- Planning packet incompleteness is represented separately from project
  freshness.
- Reconcile Project never mutates source repositories.
- Reconcile Project is scoped to one canonical Atlas project.
- Local refresh remains preview-first and selectable.
- Existing source/card caps remain visible as coverage and deferred counts.
- GitHub refresh remains explicit or opt-in.
- Identity writes are blocked when source authority is unresolved.
- Semantic identity changes are reviewable proposals by default.
- All MCP projections agree on project freshness or declare a named projection
  downgrade.
- Migration tests preserve registry, observation, Git remote, and refresh
  provenance row counts.
