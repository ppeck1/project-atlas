import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db_open.dart';
import 'tables.dart';

part 'app_db.g.dart';

@DriftDatabase(
  tables: [
    Projects,
    AppMeta,
    Stages,
    WorkItems,
    Drafts,
    DailyReviews,
    OutboxMessages,
    EventLog,
    Documents,
    DocumentLinks,
    WorkItemNotes,
    WorkItemAnalyses,
  ],
)
class AppDb extends _$AppDb {
  AppDb() : super(openEncryptedExecutor());

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        beforeOpen: (details) async {
          await repairSchema();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(stages);
          if (from < 3) await m.createTable(workItems);
          if (from < 4) {
            // Each addColumn is wrapped individually so a partially-applied
            // migration (e.g. from a prior crash) doesn't crash again on the
            // duplicate column name SQLite error.
            await _safeAddColumn(m, workItems, workItems.description);
            await _safeAddColumn(m, workItems, workItems.status);
            await _safeAddColumn(m, workItems, workItems.priority);
            await _safeAddColumn(m, workItems, workItems.dueAt);
            await _safeAddColumn(m, workItems, workItems.updatedAt);
            await _safeAddColumn(m, workItems, workItems.blockedReason);
            await _safeAddColumn(m, workItems, workItems.source);
            await _safeAddColumn(m, workItems, workItems.phoneQueue);

            await customStatement(
              "UPDATE work_items SET status = 'done' WHERE completed = 1 AND status IS NULL",
            );

            // Use IF NOT EXISTS so these are idempotent on re-runs
            await customStatement('''CREATE TABLE IF NOT EXISTS drafts (
              id TEXT NOT NULL PRIMARY KEY,
              project_id TEXT,
              work_item_id TEXT,
              kind TEXT NOT NULL,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              accepted INTEGER NOT NULL DEFAULT 0
            )''');
            await customStatement('''CREATE TABLE IF NOT EXISTS daily_reviews (
              id TEXT NOT NULL PRIMARY KEY,
              review_date INTEGER NOT NULL,
              summary TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )''');
            await customStatement('''CREATE TABLE IF NOT EXISTS outbox_messages (
              id TEXT NOT NULL PRIMARY KEY,
              channel TEXT NOT NULL,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              sent_at INTEGER,
              created_at INTEGER NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending',
              error TEXT
            )''');
          }
          if (from < 6) {
            await m.createTable(workItemNotes);
            await m.createTable(workItemAnalyses);
          }
        },
      );

  /// Ignores duplicate-column errors from prior partial migrations, but logs all other failures.
  Future<void> _safeAddColumn(
      Migrator m, TableInfo table, GeneratedColumn column) async {
    try {
      await m.addColumn(table, column);
    } catch (e, st) {
      if (!e.toString().toLowerCase().contains('duplicate column')) {
        await logError(area: 'migration', action: 'add_column', error: e, stackTrace: st, inputJson: column.name);
      }
    }
  }


  // -------------------------------------------------------------------------
  // Defensive schema repair - runs on every DB open, including already-v4 DBs.
  // -------------------------------------------------------------------------

  Future<void> repairSchema() async {
    try {
      await _ensureBaseTablesForRepair();
      await _ensureColumns('work_items', {
        'description': 'TEXT',
        'owner': 'TEXT',
        'status': "TEXT NOT NULL DEFAULT 'next'",
        'priority': "TEXT NOT NULL DEFAULT 'normal'",
        'due_at': 'INTEGER',
        'updated_at': 'INTEGER NOT NULL DEFAULT 0',
        'blocked_reason': 'TEXT',
        'source': 'TEXT',
        'phone_queue': 'INTEGER NOT NULL DEFAULT 0',
        'completed': 'INTEGER NOT NULL DEFAULT 0',
      });
      await _ensureColumns('projects', {'owner': 'TEXT'});
      await _ensureColumns('stages', {'owner': 'TEXT'});
      await _ensureColumns('drafts', {
        'project_id': 'TEXT',
        'work_item_id': 'TEXT',
        'input_json': 'TEXT',
        'updated_at': 'INTEGER NOT NULL DEFAULT 0',
        'accepted': 'INTEGER NOT NULL DEFAULT 0',
      });
      await _ensureColumns('outbox_messages', {
        'sent_at': 'INTEGER',
        'status': "TEXT NOT NULL DEFAULT 'pending'",
        'error': 'TEXT',
      });
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await customStatement("UPDATE work_items SET status = 'next' WHERE status IS NULL OR status = ''");
      await customStatement("UPDATE work_items SET priority = 'normal' WHERE priority IS NULL OR priority = ''");
      await customStatement("UPDATE work_items SET updated_at = COALESCE(created_at, $nowMs) WHERE updated_at IS NULL OR updated_at = 0");
      await customStatement('UPDATE work_items SET completed = 0 WHERE completed IS NULL');
      await customStatement('UPDATE work_items SET phone_queue = 0 WHERE phone_queue IS NULL');
      await customStatement("UPDATE drafts SET updated_at = COALESCE(created_at, $nowMs) WHERE updated_at IS NULL OR updated_at = 0");
      await customStatement('UPDATE drafts SET accepted = 0 WHERE accepted IS NULL');
      await logEvent(level: 'info', area: 'migration', action: 'schema_repair', outputJson: '{"status":"ok"}');
    } catch (e, st) {
      await logError(area: 'migration', action: 'schema_repair', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<void> _ensureBaseTablesForRepair() async {
    await customStatement('''CREATE TABLE IF NOT EXISTS event_log (
      id TEXT NOT NULL PRIMARY KEY,
      timestamp INTEGER NOT NULL,
      level TEXT NOT NULL,
      area TEXT NOT NULL,
      action TEXT NOT NULL,
      entity_type TEXT,
      entity_id TEXT,
      input_json TEXT,
      output_json TEXT,
      error TEXT,
      stack_trace TEXT,
      correlation_id TEXT
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS drafts (
      id TEXT NOT NULL PRIMARY KEY,
      project_id TEXT,
      work_item_id TEXT,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      input_json TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      accepted INTEGER NOT NULL DEFAULT 0
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS daily_reviews (
      id TEXT NOT NULL PRIMARY KEY,
      review_date INTEGER NOT NULL,
      summary TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS outbox_messages (
      id TEXT NOT NULL PRIMARY KEY,
      channel TEXT NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      sent_at INTEGER,
      created_at INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      error TEXT
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS documents (
      id TEXT NOT NULL PRIMARY KEY,
      title TEXT NOT NULL,
      original_filename TEXT NOT NULL,
      stored_path TEXT,
      mime_type TEXT,
      extension TEXT,
      project_id TEXT,
      source TEXT,
      status TEXT NOT NULL DEFAULT 'imported',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      metadata_json TEXT,
      extracted_text TEXT,
      rendered_markdown TEXT,
      parse_error TEXT
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS document_links (
      id TEXT NOT NULL PRIMARY KEY,
      document_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS work_item_notes (
      id TEXT NOT NULL PRIMARY KEY,
      work_item_id TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS work_item_analyses (
      id TEXT NOT NULL PRIMARY KEY,
      work_item_id TEXT NOT NULL,
      prompt TEXT NOT NULL,
      output TEXT NOT NULL,
      model TEXT,
      created_at INTEGER NOT NULL
    )''');
  }

  Future<void> _ensureColumns(String tableName, Map<String, String> columns) async {
    final rows = await customSelect('PRAGMA table_info($tableName)').get();
    final existing = rows.map((r) => (r.data['name'] as String).toLowerCase()).toSet();
    for (final entry in columns.entries) {
      if (existing.contains(entry.key.toLowerCase())) continue;
      try {
        await customStatement('ALTER TABLE $tableName ADD COLUMN ${entry.key} ${entry.value}');
        await logEvent(level: 'info', area: 'migration', action: 'add_column', entityType: tableName, entityId: entry.key);
      } catch (e, st) {
        await logError(area: 'migration', action: 'add_column', entityType: tableName, entityId: entry.key, error: e, stackTrace: st);
      }
    }
  }

  Future<void> logEvent({
    String level = 'info',
    required String area,
    required String action,
    String? entityType,
    String? entityId,
    String? inputJson,
    String? outputJson,
    String? error,
    StackTrace? stackTrace,
    String? correlationId,
  }) async {
    try {
      await into(eventLog).insert(EventLogCompanion.insert(
        id: '${DateTime.now().microsecondsSinceEpoch}_${area}_$action',
        timestamp: DateTime.now(),
        level: level,
        area: area,
        action: action,
        entityType: Value(entityType),
        entityId: Value(entityId),
        inputJson: Value(inputJson),
        outputJson: Value(outputJson),
        error: Value(error),
        stackTrace: Value(stackTrace?.toString()),
        correlationId: Value(correlationId),
      ));
    } catch (_) {}
  }

  Future<void> logError({
    required String area,
    required String action,
    String? entityType,
    String? entityId,
    Object? error,
    StackTrace? stackTrace,
    String? inputJson,
  }) => logEvent(level: 'error', area: area, action: action, entityType: entityType, entityId: entityId, inputJson: inputJson, error: error?.toString(), stackTrace: stackTrace);

  Stream<List<EventLogData>> watchRecentEvents() =>
      (select(eventLog)..orderBy([(t) => OrderingTerm.desc(t.timestamp)])..limit(250)).watch();
  Future<List<EventLogData>> getRecentEvents() =>
      (select(eventLog)..orderBy([(t) => OrderingTerm.desc(t.timestamp)])..limit(250)).get();
  Future<void> clearEventLog() => delete(eventLog).go();

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  String _newId() => DateTime.now().millisecondsSinceEpoch.toString();

  // -------------------------------------------------------------------------
  // AppMeta
  // -------------------------------------------------------------------------

  static const _activeProjectKey = 'active_project_id';
  static String _activeStageKeyFor(String projectId) =>
      'active_stage_id::$projectId';
  static String _isBottleneckKeyFor(String stageId) =>
      'is_bottleneck::$stageId';

  static const kTelegramBotToken = 'setting::telegram_bot_token';
  static const kTelegramChatId   = 'setting::telegram_chat_id';
  static const kTelegramEnabled  = 'setting::telegram_enabled';
  static const kOllamaHost       = 'setting::ollama_host';
  static const kOllamaModel      = 'setting::ollama_model';

  Stream<String?> watchMetaString(String key) =>
      (select(appMeta)..where((t) => t.key.equals(key)))
          .watchSingleOrNull()
          .map((row) => row?.value);

  Future<String?> getMetaString(String key) async =>
      ((await (select(appMeta)..where((t) => t.key.equals(key)))
              .getSingleOrNull()))
          ?.value;

  Future<void> setMetaString(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await (delete(appMeta)..where((t) => t.key.equals(key))).go();
    } else {
      await into(appMeta).insertOnConflictUpdate(
        AppMetaCompanion.insert(key: key, value: value),
      );
    }
  }

  Stream<bool> watchMetaBool(String key) =>
      watchMetaString(key).map((v) => (v ?? '') == '1');

  Future<void> setMetaBool(String key, bool value) =>
      setMetaString(key, value ? '1' : '0');

  // -------------------------------------------------------------------------
  // Projects
  // -------------------------------------------------------------------------

  Stream<List<Project>> watchProjects() =>
      (select(projects)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Stream<Project?> watchActiveProject() {
    final metaRow = (select(appMeta)
          ..where((t) => t.key.equals(_activeProjectKey)))
        .watchSingleOrNull();
    return metaRow.asyncMap((row) async {
      final id = row?.value;
      if (id == null || id.isEmpty) return null;
      return (select(projects)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
    });
  }

  Future<void> setActiveProjectId(String? id) async {
    if (id == null || id.isEmpty) {
      await (delete(appMeta)..where((t) => t.key.equals(_activeProjectKey)))
          .go();
      return;
    }
    await into(appMeta).insertOnConflictUpdate(
      AppMetaCompanion.insert(key: _activeProjectKey, value: id),
    );
    await _ensureDefaultStages(id);
    final current =
        await getActiveStageForProject(id) ?? await _fallbackStage0(id);
    if (current != null) await setActiveStageIdForProject(id, current.id);
  }

  Future<void> createProject(
      String id, String title, DateTime createdAt) async {
    await into(projects).insert(
      ProjectsCompanion.insert(id: id, title: title, createdAt: createdAt),
      mode: InsertMode.insertOrReplace,
    );
    await _ensureDefaultStages(id);
    await setActiveProjectId(id);
  }

  // -------------------------------------------------------------------------
  // Stages
  // -------------------------------------------------------------------------

  Stream<List<Stage>> watchStagesForProject(String projectId) =>
      (select(stages)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .watch();

  Future<List<Stage>> getStagesForProject(String projectId) =>
      (select(stages)..where((t) => t.projectId.equals(projectId))).get();

  Future<void> _ensureDefaultStages(String projectId) async {
    final countExp = stages.id.count();
    final q = selectOnly(stages)
      ..addColumns([countExp])
      ..where(stages.projectId.equals(projectId));
    final row = await q.getSingle();
    final count = row.read(countExp) ?? 0;

    if (count > 0) {
      final active = await getActiveStageForProject(projectId);
      if (active == null) {
        await setActiveStageIdForProject(projectId, '${projectId}_stage_0');
      }
      return;
    }

    final now = DateTime.now();
    const defaults = ['Idea', 'Design', 'Build', 'Test', 'Ship', 'Stabilize'];
    for (var i = 0; i < defaults.length; i++) {
      await into(stages).insert(
        StagesCompanion.insert(
          id: '${projectId}_stage_$i',
          projectId: projectId,
          title: defaults[i],
          position: i,
          createdAt: now,
        ),
        mode: InsertMode.insertOrReplace,
      );
    }
    await setActiveStageIdForProject(projectId, '${projectId}_stage_0');
  }

  Stream<Stage?> watchActiveStageForProject(String projectId) {
    final key = _activeStageKeyFor(projectId);
    return (select(appMeta)..where((t) => t.key.equals(key)))
        .watchSingleOrNull()
        .asyncMap((row) async {
      final id = row?.value;
      if (id == null || id.isEmpty) return null;
      return (select(stages)..where((t) => t.id.equals(id))).getSingleOrNull();
    });
  }

  Future<void> setActiveStageIdForProject(
      String projectId, String? stageId) async {
    final key = _activeStageKeyFor(projectId);
    if (stageId == null || stageId.isEmpty) {
      await (delete(appMeta)..where((t) => t.key.equals(key))).go();
    } else {
      await into(appMeta).insertOnConflictUpdate(
        AppMetaCompanion.insert(key: key, value: stageId),
      );
    }
  }

  Future<Stage?> getActiveStageForProject(String projectId) async {
    final key = _activeStageKeyFor(projectId);
    final row = await (select(appMeta)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    final stageId = row?.value;
    if (stageId == null || stageId.isEmpty) return null;
    return (select(stages)..where((t) => t.id.equals(stageId)))
        .getSingleOrNull();
  }

  Future<Stage?> _fallbackStage0(String projectId) =>
      (select(stages)..where((t) => t.id.equals('${projectId}_stage_0')))
          .getSingleOrNull();

  // -------------------------------------------------------------------------
  // Work items
  // -------------------------------------------------------------------------

  Stream<List<WorkItem>> watchWorkItemsForStage(String stageId) =>
      (select(workItems)
            ..where((t) => t.stageId.equals(stageId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<List<WorkItem>> getAllActiveWorkItems() =>
      (select(workItems)
            ..where((t) => t.status.isNotIn(['done', 'archived']))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  Future<List<WorkItem>> getTodayItems() async {
    final now = DateTime.now();
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return (select(workItems)
          ..where(
            (t) =>
                t.status.isNotIn(['done', 'archived']) &
                (t.status.equals('doing') |
                    t.phoneQueue.equals(true) |
                    t.priority.isIn(['high', 'urgent']) |
                    t.dueAt.isSmallerOrEqualValue(todayEnd)),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
  }

  Stream<List<WorkItem>> watchTodayItems() {
    final now = DateTime.now();
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return (select(workItems)
          ..where(
            (t) =>
                t.status.isNotIn(['done', 'archived']) &
                (t.status.equals('doing') |
                    t.phoneQueue.equals(true) |
                    t.priority.isIn(['high', 'urgent']) |
                    t.dueAt.isSmallerOrEqualValue(todayEnd)),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  Future<List<WorkItem>> getBlockedItems() =>
      (select(workItems)
            ..where(
              (t) =>
                  t.blockedReason.isNotNull() &
                  t.status.isNotIn(['done', 'archived']),
            ))
          .get();

  Future<WorkItem?> getWorkItem(String id) =>
      (select(workItems)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> addWorkItem({
    required String stageId,
    required String title,
    String? description,
    String? owner,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? source,
  }) async {
    final now = DateTime.now();
    await into(workItems).insert(
      WorkItemsCompanion.insert(
        id: _newId(),
        stageId: stageId,
        title: title,
        description: Value(description),
        owner: Value(owner?.trim().isEmpty ?? true ? null : owner?.trim()),
        status: Value(status),
        priority: Value(priority),
        dueAt: Value(dueAt),
        updatedAt: Value(now),
        createdAt: now,
        source: Value(source),
      ),
    );
  }

  Future<void> updateWorkItem({
    required String id,
    String? title,
    String? description,
    String? owner,
    String? status,
    String? priority,
    required bool clearDueAt,
    DateTime? dueAt,
    String? blockedReason,
    required bool clearBlockedReason,
    bool? phoneQueue,
  }) async {
    final now = DateTime.now();
    await (update(workItems)..where((t) => t.id.equals(id))).write(
      WorkItemsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        description: description != null
            ? Value(description.isEmpty ? null : description)
            : const Value.absent(),
        owner: owner != null
            ? Value(owner.trim().isEmpty ? null : owner.trim())
            : const Value.absent(),
        status: status != null ? Value(status) : const Value.absent(),
        priority: priority != null ? Value(priority) : const Value.absent(),
        // Explicit typed nullable Values prevent Value<dynamic> inference
        dueAt: clearDueAt
            ? const Value<DateTime?>(null)
            : (dueAt != null ? Value(dueAt) : const Value.absent()),
        blockedReason: clearBlockedReason
            ? const Value<String?>(null)
            : (blockedReason != null
                ? Value(blockedReason.isEmpty ? null : blockedReason)
                : const Value.absent()),
        phoneQueue: phoneQueue != null ? Value(phoneQueue) : const Value.absent(),
        updatedAt: Value(now),
        completed: status != null ? Value(status == 'done') : const Value.absent(),
      ),
    );
  }

  Future<void> setWorkItemStatus(String id, String status) async {
    await (update(workItems)..where((t) => t.id.equals(id))).write(
      WorkItemsCompanion(
        status: Value(status),
        completed: Value(status == 'done'),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> toggleWorkDone(String workItemId) async {
    final item = await getWorkItem(workItemId);
    if (item == null) return;
    final newDone = !item.completed;
    await (update(workItems)..where((t) => t.id.equals(workItemId))).write(
      WorkItemsCompanion(
        completed: Value(newDone),
        status: Value(newDone ? 'done' : 'next'),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Governance
  // -------------------------------------------------------------------------

  Future<String?> getWorkOwner(String workItemId) async =>
      (await getWorkItem(workItemId))?.owner;

  Stream<String?> watchWorkOwner(String workItemId) =>
      (select(workItems)..where((t) => t.id.equals(workItemId)))
          .watchSingleOrNull()
          .map((row) => row?.owner);

  Future<void> setWorkOwner(String workItemId, String? owner) async {
    final o = owner?.trim();
    await (update(workItems)..where((t) => t.id.equals(workItemId))).write(
      WorkItemsCompanion(owner: Value(o == null || o.isEmpty ? null : o)),
    );
  }

  Stream<String?> watchBottleneckOwner(String stageId) =>
      (select(stages)..where((t) => t.id.equals(stageId)))
          .watchSingleOrNull()
          .map((row) => row?.owner);

  Future<void> setBottleneckOwner(String stageId, String? owner) async {
    final o = owner?.trim();
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(owner: Value(o == null || o.isEmpty ? null : o)),
    );
  }

  Stream<bool> watchIsBottleneck(String stageId) =>
      watchMetaBool(_isBottleneckKeyFor(stageId));

  Future<void> setIsBottleneck(String stageId, bool isBottleneck) =>
      setMetaBool(_isBottleneckKeyFor(stageId), isBottleneck);

  // -------------------------------------------------------------------------
  // Drafts
  // -------------------------------------------------------------------------

  Stream<List<Draft>> watchDrafts() =>
      (select(drafts)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<void> saveDraft({
    required String kind,
    required String title,
    required String body,
    String? inputJson,
    String? projectId,
    String? workItemId,
  }) async {
    final now = DateTime.now();
    await into(drafts).insert(
      DraftsCompanion.insert(
        id: _newId(),
        kind: kind,
        title: title,
        body: body,
        inputJson: Value(inputJson),
        projectId: Value(projectId),
        workItemId: Value(workItemId),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> deleteDraft(String id) =>
      (delete(drafts)..where((t) => t.id.equals(id))).go();

  // -------------------------------------------------------------------------
  // Document library
  // -------------------------------------------------------------------------

  Future<String> importDocumentFromPath(String sourcePath, {String? projectId}) async {
    final src = File(sourcePath.trim());
    if (!await src.exists()) throw FileSystemException('File not found', sourcePath);
    final now = DateTime.now();
    final id = _newId();
    final filename = p.basename(src.path);
    final ext = p.extension(filename).replaceFirst('.', '').toLowerCase();
    final appDir = await getApplicationSupportDirectory();
    final docDir = Directory(p.join(appDir.path, 'documents', id));
    await docDir.create(recursive: true);
    final destPath = p.join(docDir.path, filename);
    await src.copy(destPath);
    String status = 'imported';
    String? extracted;
    String? rendered;
    String? parseError;
    try {
      if (['txt', 'md', 'json', 'csv'].contains(ext)) {
        extracted = await File(destPath).readAsString();
        rendered = ext == 'json'
            ? const JsonEncoder.withIndent('  ').convert(jsonDecode(extracted))
            : extracted;
        status = 'parsed';
      } else if (['pdf', 'docx'].contains(ext)) {
        rendered = 'Stored original file. External opening/parsing can be added later.';
      } else {
        rendered = 'Stored original file. No parser registered for .$ext.';
      }
    } catch (e) {
      status = 'failed';
      parseError = e.toString();
    }
    await into(documents).insert(DocumentsCompanion.insert(
      id: id,
      title: filename,
      originalFilename: filename,
      storedPath: Value(destPath),
      extension: Value(ext),
      projectId: Value(projectId),
      source: const Value('local_import'),
      status: Value(status),
      createdAt: now,
      updatedAt: now,
      metadataJson: Value(jsonEncode({'sourcePath': sourcePath, 'bytes': await src.length()})),
      extractedText: Value(extracted),
      renderedMarkdown: Value(rendered),
      parseError: Value(parseError),
    ));
    await logEvent(level: status == 'failed' ? 'warn' : 'info', area: 'documents', action: 'import', entityType: 'document', entityId: id, inputJson: sourcePath, outputJson: jsonEncode({'status': status, 'extension': ext}), error: parseError);
    return id;
  }

  Stream<List<Document>> watchDocuments() =>
      (select(documents)..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  Stream<List<Document>> watchDocumentsForWorkItem(String workItemId) {
    final query = select(documents).join([
      innerJoin(documentLinks, documentLinks.documentId.equalsExp(documents.id)),
    ])
      ..where(documentLinks.entityType.equals('work_item') &
          documentLinks.entityId.equals(workItemId))
      ..orderBy([OrderingTerm.desc(documents.createdAt)]);
    return query.watch().map(
          (rows) => rows.map((row) => row.readTable(documents)).toList(),
        );
  }

  Future<List<Document>> getDocumentsForWorkItem(String workItemId) async {
    final query = select(documents).join([
      innerJoin(documentLinks, documentLinks.documentId.equalsExp(documents.id)),
    ])
      ..where(documentLinks.entityType.equals('work_item') &
          documentLinks.entityId.equals(workItemId))
      ..orderBy([OrderingTerm.desc(documents.createdAt)]);
    final rows = await query.get();
    return rows.map((row) => row.readTable(documents)).toList();
  }

  Future<void> linkDocumentToWorkItem(String documentId, String workItemId) async {
    final existing = await (select(documentLinks)
          ..where((t) =>
              t.documentId.equals(documentId) &
              t.entityType.equals('work_item') &
              t.entityId.equals(workItemId)))
        .getSingleOrNull();
    if (existing != null) return;
    await into(documentLinks).insert(DocumentLinksCompanion.insert(
      id: _newId(),
      documentId: documentId,
      entityType: 'work_item',
      entityId: workItemId,
      createdAt: DateTime.now(),
    ));
  }

  Future<void> unlinkDocumentFromWorkItem(String documentId, String workItemId) =>
      (delete(documentLinks)
            ..where((t) =>
                t.documentId.equals(documentId) &
                t.entityType.equals('work_item') &
                t.entityId.equals(workItemId)))
          .go();

  // -------------------------------------------------------------------------
  // Work item notes and read-only analyses
  // -------------------------------------------------------------------------

  Stream<List<WorkItemNote>> watchNotesForWorkItem(String workItemId) =>
      (select(workItemNotes)
            ..where((t) => t.workItemId.equals(workItemId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<void> addWorkItemNote(String workItemId, String body) async {
    final now = DateTime.now();
    await into(workItemNotes).insert(WorkItemNotesCompanion.insert(
      id: _newId(),
      workItemId: workItemId,
      body: body,
      createdAt: now,
      updatedAt: now,
    ));
  }

  Future<void> updateWorkItemNote(String noteId, String body) =>
      (update(workItemNotes)..where((t) => t.id.equals(noteId))).write(
        WorkItemNotesCompanion(
          body: Value(body),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> deleteWorkItemNote(String noteId) =>
      (delete(workItemNotes)..where((t) => t.id.equals(noteId))).go();

  Stream<List<WorkItemAnalysis>> watchAnalysesForWorkItem(String workItemId) =>
      (select(workItemAnalyses)
            ..where((t) => t.workItemId.equals(workItemId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<void> saveWorkItemAnalysis({
    required String workItemId,
    required String prompt,
    required String output,
    String? model,
  }) async {
    await into(workItemAnalyses).insert(WorkItemAnalysesCompanion.insert(
      id: _newId(),
      workItemId: workItemId,
      prompt: prompt,
      output: output,
      model: Value(model),
      createdAt: DateTime.now(),
    ));
  }

  // -------------------------------------------------------------------------
  // Outbox ��������� returns the ID so callers can mark sent/failed
  // -------------------------------------------------------------------------

  Future<String> addOutboxMessage({
    required String channel,
    required String title,
    required String body,
  }) async {
    final id = _newId();
    await into(outboxMessages).insert(
      OutboxMessagesCompanion.insert(
        id: id,
        channel: channel,
        title: title,
        body: body,
        createdAt: DateTime.now(),
      ),
    );
    return id;
  }

  Future<void> markOutboxSent(String id) =>
      (update(outboxMessages)..where((t) => t.id.equals(id))).write(
        OutboxMessagesCompanion(
          status: const Value('sent'),
          sentAt: Value(DateTime.now()),
        ),
      );

  Future<void> markOutboxFailed(String id, String error) =>
      (update(outboxMessages)..where((t) => t.id.equals(id))).write(
        OutboxMessagesCompanion(
          status: const Value('failed'),
          error: Value(error),
        ),
      );

  Stream<List<OutboxMessage>> watchOutboxMessages() =>
      (select(outboxMessages)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(50))
          .watch();

  // -------------------------------------------------------------------------
  // Daily reviews
  // -------------------------------------------------------------------------

  Future<void> saveDailyReview(String summary) async {
    final now = DateTime.now();
    await into(dailyReviews).insert(
      DailyReviewsCompanion.insert(
        id: _newId(),
        reviewDate: DateTime(now.year, now.month, now.day),
        summary: summary,
        createdAt: now,
      ),
    );
  }

  Future<DailyReview?> getTodayReview() async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));
    return (select(dailyReviews)
          ..where(
            (t) =>
                t.reviewDate.isBiggerOrEqualValue(todayStart) &
                t.reviewDate.isSmallerThanValue(todayEnd),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(1))
        .getSingleOrNull();
  }
}
