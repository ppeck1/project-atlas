import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Core tables
// ---------------------------------------------------------------------------

class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get owner => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  // v5 additions — nullable so existing rows survive migration
  TextColumn get description => text().nullable()();
  TextColumn get desiredOutcome => text().nullable()();
  TextColumn get successCriteria => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get category => text().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get deleteReason => text().nullable()();

  // v6 additions — project lifecycle metadata
  TextColumn get phase =>
      text().nullable()(); // idea/design/build/test/ship/stabilize
  TextColumn get priority => text().nullable()(); // low/normal/high/urgent
  TextColumn get scopeIncluded => text().nullable()();
  TextColumn get scopeExcluded => text().nullable()();
  TextColumn get outcomeSummary => text().nullable()();
  TextColumn get lessonsLearned => text().nullable()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

class AppMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key}; // ignore: override_on_non_overriding_member
}

class Stages extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get title => text()();
  TextColumn get owner => text().nullable()();
  IntColumn get position => integer()();
  DateTimeColumn get createdAt => dateTime()();

  // v5 additions
  TextColumn get bottleneckOwner => text().nullable()();
  BoolColumn get isBottleneck => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

// ---------------------------------------------------------------------------
// Work items — extended in schema v4
// status: inbox | next | doing | waiting | done | archived
// priority: low | normal | high | urgent
// ---------------------------------------------------------------------------

class WorkItems extends Table {
  TextColumn get id => text()();
  TextColumn get stageId => text().references(Stages, #id)();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get owner => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('next'))();
  TextColumn get priority => text().withDefault(const Constant('normal'))();
  DateTimeColumn get dueAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get blockedReason => text().nullable()();
  TextColumn get source => text().nullable()();
  BoolColumn get phoneQueue => boolean().withDefault(const Constant(false))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

class WorkItemNotes extends Table {
  TextColumn get id => text()();
  TextColumn get workItemId => text().references(WorkItems, #id)();
  TextColumn get body => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

@DataClassName('WorkItemAnalysis')
class WorkItemAnalyses extends Table {
  TextColumn get id => text()();
  TextColumn get workItemId => text().references(WorkItems, #id)();
  TextColumn get prompt => text()();
  TextColumn get output => text()();
  TextColumn get model => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}
// ---------------------------------------------------------------------------
// AI drafts (human-in-the-loop — user must approve before use)
// kind: project_summary | today_summary | email_draft | task_extract | custom
// ---------------------------------------------------------------------------

class Drafts extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().nullable().references(Projects, #id)();
  TextColumn get workItemId => text().nullable().references(WorkItems, #id)();
  TextColumn get kind => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get inputJson => text().nullable()();
  BoolColumn get accepted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

// ---------------------------------------------------------------------------
// Daily review snapshots (deterministic — no LLM required)
// ---------------------------------------------------------------------------

class DailyReviews extends Table {
  TextColumn get id => text()();
  DateTimeColumn get reviewDate => dateTime()();
  TextColumn get summary => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

// ---------------------------------------------------------------------------
// Outbox — tracks attempted sends (e.g. Telegram)
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
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get error => text().nullable()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
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
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
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
  TextColumn get projectId => text().nullable().references(Projects, #id)();
  TextColumn get source => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('imported'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get metadataJson => text().nullable()();
  TextColumn get extractedText => text().nullable()();
  TextColumn get renderedMarkdown => text().nullable()();
  TextColumn get parseError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

class DocumentLinks extends Table {
  TextColumn get id => text()();
  TextColumn get documentId => text().references(Documents, #id)();
  TextColumn get entityType => text()();
  // Polymorphic FK — not declared as .references() intentionally
  TextColumn get entityId => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

// ---------------------------------------------------------------------------
// Project governance — people, risks, decisions (v5)
// ---------------------------------------------------------------------------

class Contacts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get title => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get alternatePhone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get website => text().nullable()();
  TextColumn get businessName => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get photoPath => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

class ProjectPeople extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get name => text()();
  TextColumn get role => text().nullable()();
  TextColumn get authority => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

class ProjectRisks extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get title => text()();
  TextColumn get desc => text().nullable()();
  TextColumn get severity => text().withDefault(const Constant('medium'))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

class ProjectDecisions extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get title => text()();
  TextColumn get ctx => text().nullable()();
  TextColumn get decider => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

// ---------------------------------------------------------------------------
// Project tags and media (v9)
// ---------------------------------------------------------------------------

class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member

  @override
  List<String> get customConstraints => ['UNIQUE(name)'];
}

@DataClassName('ProjectTagAssignment')
class ProjectTags extends Table {
  TextColumn get projectId => text()();
  TextColumn get tagId => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {projectId, tagId}; // ignore: override_on_non_overriding_member
}

@DataClassName('ProjectMediaItem')
class ProjectMedia extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text()();
  TextColumn get title => text()();
  TextColumn get originalFilename => text()();
  TextColumn get storedPath => text()();
  TextColumn get mediaType => text().withDefault(const Constant('file'))();
  TextColumn get mimeType => text().nullable()();
  TextColumn get extension => text().nullable()();
  IntColumn get byteSize => integer().nullable()();
  DateTimeColumn get fileModifiedAt => dateTime().nullable()();
  TextColumn get caption => text().nullable()();
  BoolColumn get isCover => boolean().withDefault(const Constant(false))();
  TextColumn get source => text().nullable()();
  TextColumn get metadataJson => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

@DataClassName('MediaLink')
class MediaLinks extends Table {
  TextColumn get id => text()();
  TextColumn get mediaId => text().references(ProjectMedia, #id)();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

// ---------------------------------------------------------------------------
// Local Operations Registry (v11)
// ---------------------------------------------------------------------------

@DataClassName('ProjectRegistryEntry')
class ProjectRegistry extends Table {
  @override
  String get tableName => 'project_registry';

  TextColumn get id => text()();
  TextColumn get atlasProjectId =>
      text().nullable().references(Projects, #id)();
  TextColumn get displayName => text()();
  TextColumn get localPath => text()();
  TextColumn get gitRoot => text().nullable()();
  TextColumn get classification => text()();
  TextColumn get reviewState => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get lastReviewedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member

  @override
  List<String> get customConstraints => ['UNIQUE(local_path)'];
}

@DataClassName('ProjectObservation')
class ProjectObservations extends Table {
  @override
  String get tableName => 'project_observations';

  TextColumn get id => text()();
  TextColumn get registryId =>
      text().nullable().references(ProjectRegistry, #id)();
  TextColumn get scanRunId => text().references(ProjectScanRuns, #id)();
  TextColumn get observedPath => text()();
  TextColumn get classificationGuess => text()();
  IntColumn get confidence => integer()();
  TextColumn get branch => text().nullable()();
  TextColumn get headSha => text().nullable()();
  IntColumn get dirtyCount => integer().nullable()();
  TextColumn get remoteUrl => text().nullable()();
  TextColumn get markerFilesJson => text()();
  TextColumn get warningsJson => text()();
  TextColumn get rawJson => text()();
  DateTimeColumn get observedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

@DataClassName('ProjectScanRun')
class ProjectScanRuns extends Table {
  @override
  String get tableName => 'project_scan_runs';

  TextColumn get id => text()();
  TextColumn get rootsJson => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get status => text()();
  IntColumn get totalSeen => integer().withDefault(const Constant(0))();
  IntColumn get candidates => integer().withDefault(const Constant(0))();
  IntColumn get ignored => integer().withDefault(const Constant(0))();
  TextColumn get warningsJson => text()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}

// ---------------------------------------------------------------------------
// Local Project Refresh Profiles (v12)
// ---------------------------------------------------------------------------

@DataClassName('LocalProjectRefreshItem')
class LocalProjectRefreshItems extends Table {
  @override
  String get tableName => 'local_project_refresh_items';

  TextColumn get id => text()();
  TextColumn get registryId => text().references(ProjectRegistry, #id)();
  TextColumn get sourceKind => text()();
  TextColumn get sourceKey => text()();
  TextColumn get targetType => text()();
  TextColumn get targetId => text()();
  TextColumn get sourceFingerprint => text()();
  DateTimeColumn get lastImportedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member

  @override
  List<String> get customConstraints => [
    'UNIQUE(registry_id, source_kind, source_key)',
  ];
}

// ---------------------------------------------------------------------------
// Project Runtime Profiles (v19)
// ---------------------------------------------------------------------------

@DataClassName('ProjectRuntimeProfile')
class ProjectRuntimeProfiles extends Table {
  @override
  String get tableName => 'project_runtime_profiles';

  TextColumn get id => text()();
  TextColumn get projectId => text().references(Projects, #id)();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  TextColumn get workingDirectory => text().nullable()();
  TextColumn get launchCommand => text().nullable()();
  TextColumn get stopCommand => text().nullable()();
  TextColumn get testCommandsJson => text().withDefault(const Constant('[]'))();
  TextColumn get portsJson => text().withDefault(const Constant('[]'))();
  TextColumn get urlsJson => text().withDefault(const Constant('[]'))();
  TextColumn get healthUrlsJson => text().withDefault(const Constant('[]'))();
  TextColumn get notes => text().nullable()();
  BoolColumn get autostart => boolean().withDefault(const Constant(false))();
  BoolColumn get capsuleEnabled =>
      boolean().withDefault(const Constant(true))();
  TextColumn get capsuleMode => text().withDefault(const Constant('check'))();
  TextColumn get capsuleSourcePath => text().nullable()();
  TextColumn get capsuleProfile => text().nullable()();
  TextColumn get importSource => text().nullable()();
  DateTimeColumn get lastImportedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member

  @override
  List<String> get customConstraints => ['UNIQUE(project_id)'];
}

@DataClassName('ProjectRuntimeRun')
class ProjectRuntimeRuns extends Table {
  @override
  String get tableName => 'project_runtime_runs';

  TextColumn get id => text()();
  TextColumn get profileId => text().references(ProjectRuntimeProfiles, #id)();
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get action => text()();
  TextColumn get command => text().nullable()();
  TextColumn get status => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  IntColumn get exitCode => integer().nullable()();
  TextColumn get outputText => text().nullable()();
  TextColumn get errorText => text().nullable()();
  TextColumn get capsuleStatus => text().nullable()();
  TextColumn get capsuleOutputText => text().nullable()();
  TextColumn get metadataJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id}; // ignore: override_on_non_overriding_member
}
