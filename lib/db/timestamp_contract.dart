/// SQLite columns generated from Drift `DateTimeColumn` declarations.
///
/// Drift stores these values as integer epoch seconds. This explicit manifest
/// is intentionally separate from custom local-operation tables whose time
/// contract is epoch milliseconds (for example
/// `project_git_remotes.checked_at`).
final class DriftTimestampField {
  final String table;
  final String column;

  const DriftTimestampField(this.table, this.column);

  String get triggerStem => '${table}_${column}_epoch_seconds';
}

const driftEpochSecondThreshold = 100000000000;
const legacyMillisecondUpperBound = 100000000000000;
const legacyRepairMinEpochSeconds = 946684800; // 2000-01-01 UTC
const legacyRepairMaxEpochSeconds = 4133980800; // 2101-01-01 UTC

/// Complete, auditable allowlist of Drift `DateTimeColumn` storage fields.
const driftTimestampFields = <DriftTimestampField>[
  DriftTimestampField('projects', 'created_at'),
  DriftTimestampField('projects', 'deleted_at'),
  DriftTimestampField('stages', 'created_at'),
  DriftTimestampField('work_items', 'due_at'),
  DriftTimestampField('work_items', 'updated_at'),
  DriftTimestampField('work_items', 'created_at'),
  DriftTimestampField('work_items', 'last_reviewed_at'),
  DriftTimestampField('work_item_notes', 'created_at'),
  DriftTimestampField('work_item_notes', 'updated_at'),
  DriftTimestampField('work_item_analyses', 'created_at'),
  DriftTimestampField('drafts', 'created_at'),
  DriftTimestampField('drafts', 'updated_at'),
  DriftTimestampField('daily_reviews', 'review_date'),
  DriftTimestampField('daily_reviews', 'created_at'),
  DriftTimestampField('outbox_messages', 'sent_at'),
  DriftTimestampField('outbox_messages', 'created_at'),
  DriftTimestampField('event_log', 'timestamp'),
  DriftTimestampField('documents', 'created_at'),
  DriftTimestampField('documents', 'updated_at'),
  DriftTimestampField('documents', 'deleted_at'),
  DriftTimestampField('document_links', 'created_at'),
  DriftTimestampField('contacts', 'created_at'),
  DriftTimestampField('contacts', 'updated_at'),
  DriftTimestampField('project_people', 'created_at'),
  DriftTimestampField('project_risks', 'created_at'),
  DriftTimestampField('project_decisions', 'created_at'),
  DriftTimestampField('tags', 'created_at'),
  DriftTimestampField('tags', 'updated_at'),
  DriftTimestampField('project_tags', 'created_at'),
  DriftTimestampField('project_media', 'file_modified_at'),
  DriftTimestampField('project_media', 'created_at'),
  DriftTimestampField('project_media', 'updated_at'),
  DriftTimestampField('media_links', 'created_at'),
  DriftTimestampField('project_registry', 'created_at'),
  DriftTimestampField('project_registry', 'updated_at'),
  DriftTimestampField('project_registry', 'last_reviewed_at'),
  DriftTimestampField('project_observations', 'observed_at'),
  DriftTimestampField('project_scan_runs', 'started_at'),
  DriftTimestampField('project_scan_runs', 'completed_at'),
  DriftTimestampField('local_project_refresh_items', 'last_imported_at'),
  DriftTimestampField('project_runtime_profiles', 'last_imported_at'),
  DriftTimestampField('project_runtime_profiles', 'created_at'),
  DriftTimestampField('project_runtime_profiles', 'updated_at'),
  DriftTimestampField('project_runtime_runs', 'started_at'),
  DriftTimestampField('project_runtime_runs', 'completed_at'),
];
