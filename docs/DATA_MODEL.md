# Data model

Project Atlas uses SQLite through Drift. The current schema version is `21`.

## Core records

- Projects: lifecycle, priority, category, ownership label, scope, and summary.
- Work items: status, priority, dates, blockers, project scope, and attribution.
- Decisions and risks: structured project context with reviewable history.
- Documents and media: app-owned copies, extracted text, metadata, and links.
- Activity events: operator-visible history for important actions.

## Operational records

- Scan runs, observations, and registry entries support manual local discovery.
- Refresh ledgers and enrichment findings preserve provenance and review state.
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

The database is local and currently plaintext. Backup and OS access controls
remain the operator's responsibility.
