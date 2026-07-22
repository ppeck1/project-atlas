# Proposal acceptance integrity contract

Status: implemented by PR #35 (`a3c88f6`) and verified on merged `main`.

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

## Task-tag mutation intent

New task proposals store an explicit `tagNamesSpecified` boolean. Omitted tags
preserve assignments on existing tasks, present-empty tags clear assignments,
and a present non-empty list replaces them. The MCP adapter and approval path
require present values to be unique, nonblank string arrays.

Legacy pending proposals have no marker. A missing legacy tag field preserves
assignments, a valid empty list preserves historical behavior, and a valid
non-empty list replaces assignments. Null, scalar, mixed, blank, duplicate, or
marker/key-inconsistent envelopes fail before task or tag writes and remain
pending. Tag clearing runs inside the same proposal transaction and therefore
rolls back with the task, review state, events, and retry state.

## Scope exclusions

- A-09's implementation defines absent versus explicitly empty task-tag input;
  canonical closure still requires merge and exact-main post-merge proof.
- A-06, A-07, and A-10 are closed under the follow-up contract in
  [`ACCEPTED_TRUTH_INTEGRITY_CONTRACT.md`](ACCEPTED_TRUTH_INTEGRITY_CONTRACT.md).
  PR #41 merged as `393ab6b`, and exact-main post-merge proof passed.
- A-08 and A-09 remain canonically open pending merge proof; A-11 is closed
  independently.
- WP4 remains open after A-03/A-04 because its follow-up findings are not all
  closed.

The attended single-worker constraint attached to A-03/A-04 was retired after
post-merge proof passed on `a3c88f6`. The A-06/A-07/A-10 follow-up package did
not change that historical proof boundary, and this closure does not close
WP4.
