# Capsule product plan

Status: Product sequence, not an active implementation work order.

## North star

Atlas should let a human and an LLM resume a project from governed shared
truth, choose the next justified action, and carry that action through explicit
acceptance. The primary benchmark is time from opening Capsule to choosing
meaningful work after the project has been untouched for 30 days.

## Product shape

- Capsule is the canonical collaboration contract and primary resume surface.
- Workboard becomes an attention and agency projection of Capsule state; it is
  not a competing source of project truth.
- Operations remains a secondary Sources & Health surface for reconciliation,
  runtimes, and evidence posture.
- Workflow loops are user-editable templates. Atlas may ship useful defaults,
  but it must not encode one person's names or operating habits as the product.
- Accepted state and proposed changes remain visibly separate.

## Sequence

| Phase | Outcome | Delivery boundary |
| --- | --- | --- |
| 0. Resume | Establish intent, accepted state, the frontier, and evidence in one read-only snapshot. | Complete in Capsule Resume v0. |
| 1. Edit truth | Edit structured Capsule fields, review proposed values, and inspect version-to-version changes. | Implemented in Capsule Edit Truth v1 (schema 24); operator acceptance pending. |
| 2. Orchestrate attention | Derive human decision, human action, agent action, acceptance, evidence, and defer lanes from the same contract. | Replace fixed Workboard categories only after user testing. |
| 3. Template loops | Create, copy, reorder, disable, and customize stages such as Observe, Reconcile, Decide, Delegate, Execute, Verify, Accept, and Update Truth. | Templates describe transitions and gates, not autonomous execution. |
| 4. Close one agent loop | Produce a Capsule-scoped handoff, ingest the result as a proposal, attach verification, and accept or revise it. | One polished Codex workflow before adding more agent types. |
| 5. Compact MCP access | Let approved callers request the same Act, Understand, or Audit projection with strict limits and revision awareness. | Trusted local first; remote disclosure remains separately allowlisted. |
| 6. Measure usefulness | Record local-only resume time, recommendation choice, delegation outcome, acceptance, and rework. | No telemetry or private-data export. |

Each phase gets its own governed work order, tests, stop conditions, and
acceptance review. A schema bump, remote disclosure change, or expanded agent
authority always requires explicit approval.

## Context and token budget

1. Default to the `act` projection; request `understand` or `audit` only when
   the decision needs them.
2. Send one revision ID and content hash. Callers that already know the
   revision should receive no duplicate project packet.
3. Bound every lane and record list, report omitted counts, and fetch detail by
   stable ID only when needed.
4. Never save tokens by hiding warnings, uncertainty, evidence posture, or the
   human-acceptance boundary.
5. Exclude raw proposal payloads, queue context/results, local paths, source
   excerpts, and stack traces from compact projections.
6. Use inexpensive models for review and suggestions only after deterministic
   Atlas logic has assembled the contract. Model output remains a proposal.
7. Escalate to a more capable model only for ambiguity, conflict, or a task
   whose verification cost justifies it.

## Usability gates

- A returning user can identify meaningful work without reconstructing the
  project from documents or chat history.
- Every surfaced item states why it is present, who owns the transition, and
  what moves it forward.
- A user can tailor templates and lanes without changing code.
- A delegated result cannot silently change accepted project state.
- Compact context demonstrably reduces payload size without lowering decision
  quality or concealing risk.

Competition packaging is optional evidence of this product loop, not a reason
to distort the sequence.
