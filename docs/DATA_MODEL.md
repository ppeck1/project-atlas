# Data model

Project Atlas uses SQLite through Drift. The current schema version is `24`.

## Core records

- Projects: lifecycle, priority, category, ownership label, scope, and summary.
- Work items: status, priority, dates, blockers, project scope, and attribution.
- Decisions and risks: structured project context with reviewable history.
- Documents and media: app-owned copies, extracted text, metadata, and links.
  Document deletion is soft (`documents.deleted_at`, added in v23): deleted
  documents are hidden from queries and undoable; a startup purge removes the
  app-owned file and row after a retention window.
- Activity events: operator-visible history for important actions.
- Project Capsule revisions: immutable accepted-history rows containing a
  project-scoped revision number and parent, canonical truth hash, accepted
  truth JSON, field diff, actor/source/reason attribution, and acceptance time.
  Existing project columns remain the mutable accepted truth; the ledger is
  not a competing project record.

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

The database is local and currently plaintext. Backup and OS access controls
remain the operator's responsibility.
