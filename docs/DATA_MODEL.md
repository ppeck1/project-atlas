# Data model

Project Atlas uses SQLite through Drift. The current schema version is `27`.

## Core records

- Projects: lifecycle, priority, category, ownership label, scope, and summary.
- Work items: status, priority, dates, blockers, project scope, and attribution.
- Decisions and risks: structured project context with reviewable history.
- Documents and media: app-owned copies, extracted text, metadata, and links.
  Document deletion is soft (`documents.deleted_at`, added in v23): deleted
  documents are hidden from queries and undoable; a startup purge removes the
  app-owned file and row after a retention window. DOCX and HTML extraction is
  isolated and bounded; non-fatal extraction warnings use versioned JSON in
  `documents.parse_error` while the owned copy and imported row remain valid.
  The boundary is defined by the
  [`bounded document extraction contract`](DOCUMENT_EXTRACTION_CONTRACT.md).
- Activity events: operator-visible history for important actions.
- Project Capsule revisions: immutable accepted-history rows containing a
  project-scoped revision number and parent, canonical truth hash, accepted
  truth JSON, field diff, actor/source/reason attribution, and acceptance time.
  Existing project columns remain the mutable accepted truth; the ledger is
  not a competing project record.
- Project Capsule ledger checkpoints: one verified head per project containing
  the exact revision count, head identity/hash, cumulative ledger digest, and
  dirty state used for bounded current-state and history-page reads.

## Operational records

- Scan runs, observations, and registry entries support manual local discovery.
- Project source topology records source role, source type, lifecycle state,
  authority level, precedence, and normalized identity so Atlas can distinguish
  canonical projects from local folders, public mirrors, legacy remote URLs,
  archives, and ignored candidates.
- Refresh ledgers and enrichment findings preserve provenance and review state.
- Project reconciliation previews report channel-level coverage and blockers
  before Atlas applies any local refresh work.
- Runtime profiles and run history store only operator-supplied commands and
  execution results.
- Git remote status stores explicitly refreshed repository metadata.

## AI and review records

- AI drafts keep generated text separate from accepted project records.
- LLM queue items track pending, leased, completed, failed, and cancelled work.
- Proposals carry the requested mutation as reviewable data before application.
- Summary packets record evidence selection, freshness warnings, and validation
  results.

## Time and migration rules

Database timestamps use one explicit unit contract and are covered by migration
and regression tests. Schema changes are implemented in `lib/db/app_db.dart`;
generated Drift code must be refreshed and committed with table changes.

The v23-to-v24 migration creates `project_capsule_revisions` and records one
baseline revision for each existing project without changing its project
fields. Newly created projects receive the same baseline. Later accepted
Capsule edits update the project fields and append the next revision in one
transaction. Known registry-generated local-path markers are excluded from the
authored baseline; source locations remain in the operational registry.

The v24-to-v25 migration installs SQLite triggers that reject ordinary
`UPDATE` and `DELETE` operations on accepted revisions. Ledger reads strictly
validate hashes, parent links, contiguous revision numbers, and recorded
parent-to-child diffs before exposing history.

The v25-to-v26 migration rebuilds the hand-managed LLM task queue with
foreign-key, enum, scalar, lease-state, and project/work-item ownership
constraints. Invalid legacy rows fail migration without replacing the v25
table or advancing its schema version.

The v26-to-v27 migration verifies every complete Capsule revision chain before
creating a clean durable checkpoint. Checkpoint DDL, backfill, and invalidation
triggers are one transaction: any malformed ledger rolls the entire migration
back to v26. Normal revision inserts dirty the checkpoint, and the accepted
writer advances revision plus checkpoint atomically. Current-state reads use
the checkpoint and exact head; history uses bounded SQL pages; explicit audits
and source-recovery evidence retain full-chain verification.

The database is local and currently plaintext. The Settings portable export is
not a complete backup and cannot restore an Atlas instance; full backup and
restore remain separate recovery work. Its bounded isolate, streaming,
cancellation, and limit boundary is defined by the
[`portable export contract`](PORTABLE_EXPORT_CONTRACT.md).
