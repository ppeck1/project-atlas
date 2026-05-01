import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Core tables
// ---------------------------------------------------------------------------

class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get owner => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class AppMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

class Stages extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text()();
  TextColumn get title => text()();
  TextColumn get owner => text().nullable()();
  IntColumn get position => integer()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Work items ��� extended in schema v4
// status: inbox | next | doing | waiting | done | archived
// priority: low | normal | high | urgent
// ---------------------------------------------------------------------------

class WorkItems extends Table {
  TextColumn get id => text()();
  TextColumn get stageId => text()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get owner => text().nullable()();
  TextColumn get status =>
      text().withDefault(const Constant('next'))();
  TextColumn get priority =>
      text().withDefault(const Constant('normal'))();
  DateTimeColumn get dueAt => dateTime().nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get blockedReason => text().nullable()();
  TextColumn get source => text().nullable()();
  BoolColumn get phoneQueue =>
      boolean().withDefault(const Constant(false))();
  // Kept for backwards compat; status='done' is canonical.
  BoolColumn get completed =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// AI drafts (human-in-the-loop ��� user must approve before use)
// kind: project_summary | today_summary | email_draft | task_extract | custom
// ---------------------------------------------------------------------------

class Drafts extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().nullable()();
  TextColumn get workItemId => text().nullable()();
  TextColumn get kind => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get inputJson => text().nullable()();
  BoolColumn get accepted =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Daily review snapshots (deterministic ��� no LLM required)
// ---------------------------------------------------------------------------

class DailyReviews extends Table {
  TextColumn get id => text()();
  DateTimeColumn get reviewDate => dateTime()();
  TextColumn get summary => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Outbox ��� tracks attempted sends (e.g. Telegram)
// channel: telegram
// status: pending | sent | failed
// ---------------------------------------------------------------------------

class OutboxMessages extends Table {
  TextColumn get id => text()();
  TextColumn get channel => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  DateTimeColumn get sentAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get status =>
      text().withDefault(const Constant('pending'))();
  TextColumn get error => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Backend/event log
// ---------------------------------------------------------------------------

class EventLog extends Table {
  TextColumn get id => text()();
  DateTimeColumn get timestamp => dateTime()();
  TextColumn get level => text()();
  TextColumn get area => text()();
  TextColumn get action => text()();
  TextColumn get entityType => text().nullable()();
  TextColumn get entityId => text().nullable()();
  TextColumn get inputJson => text().nullable()();
  TextColumn get outputJson => text().nullable()();
  TextColumn get error => text().nullable()();
  TextColumn get stackTrace => text().nullable()();
  TextColumn get correlationId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Document library
// ---------------------------------------------------------------------------

class Documents extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get originalFilename => text()();
  TextColumn get storedPath => text().nullable()();
  TextColumn get mimeType => text().nullable()();
  TextColumn get extension => text().nullable()();
  TextColumn get projectId => text().nullable()();
  TextColumn get source => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('imported'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get metadataJson => text().nullable()();
  TextColumn get extractedText => text().nullable()();
  TextColumn get renderedMarkdown => text().nullable()();
  TextColumn get parseError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class DocumentLinks extends Table {
  TextColumn get id => text()();
  TextColumn get documentId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class WorkItemNotes extends Table {
  TextColumn get id => text()();
  TextColumn get workItemId => text()();
  TextColumn get body => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('WorkItemAnalysis')
class WorkItemAnalyses extends Table {
  TextColumn get id => text()();
  TextColumn get workItemId => text()();
  TextColumn get prompt => text()();
  TextColumn get output => text()();
  TextColumn get model => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
