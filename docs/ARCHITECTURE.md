# Architecture

Project Atlas is a Flutter Windows desktop application organized around a
local data store and explicit service boundaries.

## Layers

1. `lib/features` contains screen-specific presentation and interaction logic.
2. `AppState` coordinates UI state, long-running operations, and service calls.
3. `lib/services` contains domain workflows such as discovery, refresh,
   runtime execution, AI summaries, metadata lookup, and export preparation.
4. `AppDb` and Drift tables own persistence, migrations, and query boundaries.
5. `lib/mcp` adapts a limited set of application operations to a trusted local
   stdio MCP server.

The desktop process is the authority for local writes. AI and MCP callers use
proposal or queue workflows where review matters; they do not bypass the data
layer or silently mutate unrelated repositories.

Project source reconciliation is deliberately Atlas-scoped. Operations keeps
source rows separate from canonical projects, stores source topology in
`project_registry`, and blocks identity-sensitive refresh work when source
authority is unresolved. Reconcile previews can update Atlas bookkeeping after
operator review, but they do not mutate the linked source repositories.

## Project Capsule truth and projection

`ProjectCapsuleTruthService` owns the accepted authored contract boundary.
Existing project columns remain the one mutable source of accepted truth. A
human save applies those fields and appends an immutable
`project_capsule_revisions` row in one transaction; the row records the
canonical content hash, field diff, actor, source, reason, parent, and
acceptance time. The editor supplies its expected truth revision, so a newer
accepted change causes the stale save to fail instead of overwriting it.
Registry-derived filesystem locations remain source posture rather than
authored truth; Operations does not copy those paths into new revisions, and
the v24 baseline projection removes the known legacy registry path markers.

Agent-originated metadata changes still enter the existing draft review
boundary. Their base truth revision is checked when the draft is accepted.
Accepted revision history is therefore evidence of explicit acceptance, not a
second mutable copy of project state.

`ProjectCapsuleService` derives one read-only collaboration contract from the
existing project bootstrap and workload models. Its source port keeps the
projection independent from Flutter widgets and persistence details; the
current adapter delegates to `AtlasAgentService` rather than teaching the
Capsule screen to recalculate project truth.

The snapshot exposes three progressive-disclosure views:

- `act` contains the recommended next action and attention lanes.
- `understand` contains intent, accepted state, decisions, risks, and scope.
- `audit` contains freshness, source/protocol posture, warnings, gaps, and
  verification expectations.

All views carry the same deterministic snapshot content hash and derived
snapshot revision ID, plus the distinct accepted truth revision. The
generation time is reported but excluded from the snapshot hash, so selecting
a smaller view saves context without creating a contradictory revision. Agent
results remain proposals and the human-acceptance boundary is explicit in the
relevant views.

## Data flow

- UI actions call `AppState` methods.
- `AppState` validates user intent and delegates to a service or `AppDb`.
- Services return typed results, previews, findings, or drafts.
- Durable changes are recorded in SQLite, including relevant run history and
  review state.
- Screens subscribe to state changes and render the persisted result.
- Project freshness, planning-context completeness, and source topology use
  shared model paths so UI, local MCP, and remote projection views do not
  independently calculate contradictory project status.
- One-shot reads use database queries rather than awaiting the first value of a
  reactive stream; streams remain reserved for consumers that need updates.

## External boundaries

Atlas is usable without any network integration. GitHub reads, Telegram sends,
Ollama requests, runtime commands, and the remote MCP gateway are opt-in and
operator-configured. Each boundary has a deliberately narrower data contract
than the internal model.

The trusted local MCP server exposes broader read and preview tools for the
desktop process. The remote gateway remains allowlisted and read-only by
policy; source-reconciliation preview details are not automatically projected
to remote callers.

## Failure model

Parsing and remote projection fail closed when required configuration or schema
information is missing. Long-running work records status and error details, and
reviewable proposals remain separate from applied state.
