# Proposal acceptance integrity contract

Status: implementation proof in progress on
`fix/proposal-acceptance-integrity`.

This contract defines the A-03/A-04 boundary for human approval of Atlas agent
proposal drafts. It does not expand the trusted-local MCP boundary and does not
permit an agent to approve its own proposal.

## Atomic lifecycle

A proposal draft starts in `pending`. Approval performs an UPDATE-first compare
and swap on the exact pending draft envelope before reading or changing domain
state. The winning transaction validates the proposal, applies every SQLite
side effect, stores the review message and resulting entity ID, marks the draft
accepted, and records the approval event. These writes commit or roll back
together.

Rejection uses the same pending-draft compare and swap and commits only the
review transition and rejection event. An approval/rejection race therefore
has one terminal winner. A rolled-back attempt restores `pending`; the
transaction-private `applying` marker is never committed.

An approved retry returns the stored `reviewEntityId` and review message. It
does not reapply the proposal. This is required for created tasks, handoff
drafts, and closeout drafts, whose result entity differs from the project ID.

## Existing-task freshness token

An existing-task proposal stores a server-generated
`atlas.task_proposal_base.v1` snapshot in its payload. It contains two SHA-256
digests:

- `taskHash` covers the work-item identity, owning project and stage, and all
  semantic task fields; and
- `tagSetHash` covers the exact sorted assigned-tag identity, normalized name,
  and color projection.

Maps are recursively key-sorted before JSON encoding. Tag rows are sorted by
stable ID. Dates use UTC ISO-8601 strings. Volatile `updatedAt` is excluded: it
does not change for tag-only writes and is not a sufficient concurrency token.

Approval recomputes both digests inside the owning transaction after the draft
CAS and before tag lookup or creation. Missing/malformed tokens, a deleted task,
changed project ownership, changed task state, or a changed tag set raises a
typed conflict. The transaction then rolls back to `pending` with no task,
tag, event, truth-revision, handoff, or review side effect.

New-task proposals have no existing entity to hash. Their deterministic
single-application guarantee comes from the atomic pending-draft CAS and the
stored approval result.

## Scope exclusions

- A-09 remains open: this package does not redefine absent versus explicitly
  empty task-tag input.
- A-10 remains open: making manifest truth and project-tag writes share the
  approval transaction does not add the required project-tag concurrency
  token.
- A-06 through A-08 and A-11 remain independently tracked.
- WP4 remains open after A-03/A-04 because A-06 through A-10 remain open.

The attended single-worker operating constraint remains in force until A-03
and A-04 merge and their post-merge proof passes on `main`.
