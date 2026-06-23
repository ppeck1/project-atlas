import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart' show SqliteException;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'db_open.dart';
import 'tables.dart';

part 'app_db.g.dart';

// ---------------------------------------------------------------------------
// Convenience type aliases
// Drift auto-generates a data class per table, e.g. Project for Projects,
// Stage for Stages, etc. These aliases let the rest of the app use the
// names that the UI code already references.
// ---------------------------------------------------------------------------

/// Full project data. Since we added description/desiredOutcome/successCriteria
/// directly to the Projects table, the Drift-generated [Project] class already
/// carries them. This typedef keeps call-sites unchanged.
typedef ProjectFull = Project;

// Drift generates:
//   ProjectPeopleData  (from ProjectPeople — doesn't end in 's', so adds 'Data')
//   ProjectRisk        (from ProjectRisks  — removes 's')
//   ProjectDecision    (from ProjectDecisions — removes 's')
//   EventLogData       (from EventLog — no 's', adds 'Data')
//   OutboxMessage      (from OutboxMessages — removes 's')
typedef ProjectPerson = ProjectPeopleData;

// ---------------------------------------------------------------------------
// AppDb
// ---------------------------------------------------------------------------

@DriftDatabase(
  tables: [
    Projects,
    AppMeta,
    Stages,
    WorkItems,
    WorkItemNotes,
    WorkItemAnalyses,
    Drafts,
    DailyReviews,
    OutboxMessages,
    EventLog,
    Documents,
    DocumentLinks,
    Contacts,
    ProjectPeople,
    ProjectRisks,
    ProjectDecisions,
    Tags,
    ProjectTags,
    ProjectMedia,
  ],
)
class AppDb extends _$AppDb {
  AppDb() : super(openEncryptedExecutor());
  AppDb.withExecutor(QueryExecutor executor) : super(executor);

  // ── AppMeta keys ──────────────────────────────────────────────────────────
  static const kActiveProjectId = 'active_project_id';
  static const kOllamaHost = 'ollama_host';
  static const kOllamaModel = 'ollama_model';
  static const kTelegramBotToken = 'telegram_bot_token';
  static const kTelegramChatId = 'telegram_chat_id';
  static const kTelegramEnabled = 'telegram_enabled';

  // ── Schema ────────────────────────────────────────────────────────────────
  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(stages);
      if (from < 3) await m.createTable(workItems);
      if (from < 4) {
        // Defensive: ignore duplicate-column errors from partial migrations
        for (final col in [
          workItems.blockedReason,
          workItems.source,
          workItems.phoneQueue,
          workItems.priority,
          workItems.dueAt,
          workItems.updatedAt,
        ]) {
          try {
            await m.addColumn(workItems, col);
          } on SqliteException catch (e) {
            if (!e.message.toLowerCase().contains('already exists') &&
                !e.message.toLowerCase().contains('duplicate column')) rethrow;
          }
        }
        for (final fn in <Future<void> Function()>[
          () => m.createTable(drafts),
          () => m.createTable(dailyReviews),
          () => m.createTable(outboxMessages),
        ]) {
          try {
            await fn();
          } on SqliteException catch (e) {
            if (!e.message.toLowerCase().contains('already exists') &&
                !e.message.toLowerCase().contains('duplicate column')) rethrow;
          }
        }
      }
      if (from < 5) {
        for (final fn in <Future<void> Function()>[
          () => m.createTable(eventLog),
          () => m.createTable(documents),
          () => m.createTable(documentLinks),
          () => m.createTable(projectPeople),
          () => m.createTable(projectRisks),
          () => m.createTable(projectDecisions),
        ]) {
          try {
            await fn();
          } catch (_) {}
        }
        for (final col in [
          projects.description,
          projects.desiredOutcome,
          projects.successCriteria,
          projects.status,
          projects.deletedAt,
          projects.deleteReason,
        ]) {
          try {
            await m.addColumn(projects, col);
          } catch (_) {}
        }
        for (final col in [stages.bottleneckOwner, stages.isBottleneck]) {
          try {
            await m.addColumn(stages, col);
          } catch (_) {}
        }
      }
      if (from < 6) {
        for (final col in [
          projects.phase,
          projects.priority,
          projects.scopeIncluded,
          projects.scopeExcluded,
          projects.outcomeSummary,
          projects.lessonsLearned,
        ]) {
          try {
            await m.addColumn(projects, col);
          } catch (_) {}
        }
      }
      if (from < 7) {
        for (final fn in <Future<void> Function()>[
          () => m.createTable(workItemNotes),
          () => m.createTable(workItemAnalyses),
        ]) {
          try {
            await fn();
          } catch (_) {}
        }
      }
      if (from < 8) {
        try {
          await m.createTable(contacts);
        } catch (_) {}
      }
      if (from < 9) {
        for (final fn in <Future<void> Function()>[
          () => m.createTable(tags),
          () => m.createTable(projectTags),
          () => m.createTable(projectMedia),
        ]) {
          try {
            await fn();
          } catch (_) {}
        }
      }
      if (from < 10) {
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_reviews_date '
          'ON daily_reviews(review_date)',
        );
      }
    },
    beforeOpen: (_) async {
      await _ensureProjectCompatibilityColumns();
    },
  );

  /// Repairs older or partially migrated local databases that already report
  /// schemaVersion 5 but are missing nullable project columns used by the
  /// current Drift-generated Projects table. Without this, even a plain
  /// select(projects) can fail with: no such column: deleted_at.
  Future<void> _ensureProjectCompatibilityColumns() async {
    final addColumns = <String>[
      'ALTER TABLE projects ADD COLUMN description TEXT NULL',
      'ALTER TABLE projects ADD COLUMN desired_outcome TEXT NULL',
      'ALTER TABLE projects ADD COLUMN success_criteria TEXT NULL',
      // Use nullable here — we backfill below so the NOT NULL alias still holds.
      "ALTER TABLE projects ADD COLUMN status TEXT DEFAULT 'active'",
      'ALTER TABLE projects ADD COLUMN deleted_at INTEGER NULL',
      'ALTER TABLE projects ADD COLUMN delete_reason TEXT NULL',
      // v6 lifecycle columns
      'ALTER TABLE projects ADD COLUMN phase TEXT NULL',
      'ALTER TABLE projects ADD COLUMN priority TEXT NULL',
      'ALTER TABLE projects ADD COLUMN scope_included TEXT NULL',
      'ALTER TABLE projects ADD COLUMN scope_excluded TEXT NULL',
      'ALTER TABLE projects ADD COLUMN outcome_summary TEXT NULL',
      'ALTER TABLE projects ADD COLUMN lessons_learned TEXT NULL',
      // work_items columns that may be absent on very old schemas
      "ALTER TABLE work_items ADD COLUMN completed INTEGER NOT NULL DEFAULT 0",
      "ALTER TABLE work_items ADD COLUMN phone_queue INTEGER NOT NULL DEFAULT 0",
      // project_people compatibility columns (older local DBs may miss these)
      'ALTER TABLE project_people ADD COLUMN role TEXT NULL',
      'ALTER TABLE project_people ADD COLUMN authority TEXT NULL',
      // stages compatibility columns (legacy DBs may miss these)
      "ALTER TABLE stages ADD COLUMN is_bottleneck INTEGER NOT NULL DEFAULT 0",
      'ALTER TABLE stages ADD COLUMN bottleneck_owner TEXT NULL',
      // project_risks / project_decisions columns added after initial table creation
      // Note: "desc" must be quoted — DESC is a reserved SQL keyword.
      'ALTER TABLE project_risks ADD COLUMN "desc" TEXT NULL',
      'ALTER TABLE project_decisions ADD COLUMN "ctx" TEXT NULL',
    ];

    for (final stmt in addColumns) {
      try {
        await customStatement(stmt);
      } catch (_) {
        // Expected when column already exists — ignore.
      }
    }

    final createTables = <String>[
      '''CREATE TABLE IF NOT EXISTS contacts (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        title TEXT NULL,
        phone TEXT NULL,
        alternate_phone TEXT NULL,
        email TEXT NULL,
        website TEXT NULL,
        business_name TEXT NULL,
        notes TEXT NULL,
        photo_path TEXT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS work_item_notes (
        id TEXT NOT NULL PRIMARY KEY,
        work_item_id TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS work_item_analyses (
        id TEXT NOT NULL PRIMARY KEY,
        work_item_id TEXT NOT NULL,
        prompt TEXT NOT NULL,
        output TEXT NOT NULL,
        model TEXT NULL,
        created_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS tags (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        color TEXT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS project_tags (
        project_id TEXT NOT NULL,
        tag_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (project_id, tag_id)
      )''',
      '''CREATE TABLE IF NOT EXISTS project_media (
        id TEXT NOT NULL PRIMARY KEY,
        project_id TEXT NOT NULL,
        title TEXT NOT NULL,
        original_filename TEXT NOT NULL,
        stored_path TEXT NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'file',
        mime_type TEXT NULL,
        extension TEXT NULL,
        byte_size INTEGER NULL,
        file_modified_at INTEGER NULL,
        caption TEXT NULL,
        is_cover INTEGER NOT NULL DEFAULT 0,
        source TEXT NULL,
        metadata_json TEXT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
    ];

    for (final stmt in createTables) {
      try {
        await customStatement(stmt);
      } catch (_) {}
    }

    try {
      await customStatement(
        'ALTER TABLE project_media ADD COLUMN is_cover INTEGER NOT NULL DEFAULT 0',
      );
    } catch (_) {}

    // If project_people came from an alternate schema branch (role_type / authority_level),
    // rebuild it into the current expected shape so inserts don't fail on NOT NULL legacy cols.
    try {
      final cols = await customSelect(
        'PRAGMA table_info(project_people)',
      ).get();
      final names = cols
          .map((row) => (row.data['name']?.toString() ?? '').toLowerCase())
          .where((name) => name.isNotEmpty)
          .toSet();
      final needsRebuild =
          names.contains('role_type') || names.contains('authority_level');
      if (needsRebuild) {
        await transaction(() async {
          await customStatement(
            '''CREATE TABLE IF NOT EXISTS project_people_new (
            id TEXT NOT NULL PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            role TEXT NULL,
            authority TEXT NULL,
            created_at INTEGER NOT NULL
          )''',
          );

          final roleExpr = names.contains('role')
              ? (names.contains('role_type')
                    ? 'COALESCE(role, role_type)'
                    : 'role')
              : (names.contains('role_type') ? 'role_type' : 'NULL');
          final authorityExpr = names.contains('authority')
              ? (names.contains('authority_level')
                    ? 'COALESCE(authority, authority_level)'
                    : 'authority')
              : (names.contains('authority_level')
                    ? 'authority_level'
                    : 'NULL');

          await customStatement(
            "INSERT INTO project_people_new (id, project_id, name, role, authority, created_at) "
            "SELECT id, project_id, name, $roleExpr, $authorityExpr, "
            "COALESCE(created_at, CAST(strftime('%s','now') AS INTEGER) * 1000) "
            "FROM project_people",
          );

          await customStatement('DROP TABLE project_people');
          await customStatement(
            'ALTER TABLE project_people_new RENAME TO project_people',
          );
        });
      }
    } catch (_) {
      // If table doesn't exist yet or pragma fails, regular migrations handle creation.
    }
    // Backfill any rows where non-nullable columns ended up NULL due to
    // partial migrations or SQLite schema-default edge cases.
    final backfills = <String>[
      "UPDATE projects SET status = 'active' WHERE status IS NULL",
      "UPDATE work_items SET status = 'next' WHERE status IS NULL",
      "UPDATE work_items SET priority = 'normal' WHERE priority IS NULL",
      "UPDATE work_items SET completed = 0 WHERE completed IS NULL",
      "UPDATE work_items SET phone_queue = 0 WHERE phone_queue IS NULL",
      // Prevent null-mapping crashes for non-null Drift stage fields
      "UPDATE stages SET title = 'Tasks' WHERE title IS NULL OR TRIM(title) = ''",
      "UPDATE stages SET position = 0 WHERE position IS NULL",
      "UPDATE stages SET created_at = CAST(strftime('%s','now') AS INTEGER) * 1000 WHERE created_at IS NULL",
      "UPDATE stages SET is_bottleneck = 0 WHERE is_bottleneck IS NULL",
    ];

    for (final stmt in backfills) {
      try {
        await customStatement(stmt);
      } catch (_) {}
    }
  }

  // ── AppMeta helpers ───────────────────────────────────────────────────────

  Future<String?> getMetaString(String key) async {
    final row = await (select(
      appMeta,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setMetaString(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await (delete(appMeta)..where((t) => t.key.equals(key))).go();
    } else {
      await into(appMeta).insertOnConflictUpdate(
        AppMetaCompanion(key: Value(key), value: Value(value)),
      );
    }
  }

  Stream<String?> watchMetaString(String key) {
    return (select(appMeta)..where((t) => t.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  // ── Projects ──────────────────────────────────────────────────────────────

  Stream<List<Project>> watchProjects() =>
      (select(projects)
            ..where((t) => t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Stream<Project?> watchProject(String id) =>
      (select(projects)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Stream<Project?> watchActiveProject() {
    return watchMetaString(kActiveProjectId).asyncMap((id) async {
      if (id == null || id.isEmpty) return null;
      return (select(
        projects,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
    });
  }

  Future<void> createProject(
    String id,
    String title,
    DateTime createdAt,
  ) async {
    debugPrint('[Atlas] createProject: id=$id title="$title"');
    await into(projects).insert(
      ProjectsCompanion(
        id: Value(id),
        title: Value(title),
        createdAt: Value(createdAt),
        status: const Value('active'),
      ),
    );

    // Auto-create a default stage so the Work screen is immediately usable
    final stageId = '${DateTime.now().microsecondsSinceEpoch}_stage';
    debugPrint(
      '[Atlas] createProject: creating default stage $stageId for project $id',
    );
    await into(stages).insert(
      StagesCompanion(
        id: Value(stageId),
        projectId: Value(id),
        title: const Value('Tasks'),
        position: const Value(0),
        createdAt: Value(DateTime.now()),
      ),
    );

    // Activate if active_project_id is absent, empty, or points to a missing/deleted project
    final current = await getMetaString(kActiveProjectId);
    debugPrint('[Atlas] createProject: current active_project_id=$current');
    bool shouldActivate = current == null || current.isEmpty;
    if (!shouldActivate) {
      final existing = await (select(
        projects,
      )..where((t) => t.id.equals(current))).getSingleOrNull();
      if (existing == null) {
        debugPrint(
          '[Atlas] createProject: active project "$current" is missing/deleted – switching to $id',
        );
        shouldActivate = true;
      }
    }
    if (shouldActivate) {
      await setMetaString(kActiveProjectId, id);
      debugPrint('[Atlas] createProject: set active_project_id=$id');
    }

    try {
      final allActive = await (select(
        projects,
      )..where((t) => t.deletedAt.isNull())).get();
      final stageCount = (await getStagesForProject(id)).length;
      debugPrint(
        '[Atlas] createProject: done – total projects=${allActive.length}, stages for new=$stageCount',
      );
    } catch (e) {
      debugPrint('[Atlas] createProject: done (log query failed: $e)');
    }
  }

  Future<void> setActiveProjectId(String? id) =>
      setMetaString(kActiveProjectId, id);

  /// Ensures every non-deleted project has at least one stage.
  /// Run at startup to heal projects created before auto-stage logic existed.
  Future<void> ensureDefaultStagesForProjects() async {
    final allProjects = await (select(
      projects,
    )..where((t) => t.deletedAt.isNull())).get();
    debugPrint(
      '[Atlas] ensureDefaultStages: checking ${allProjects.length} project(s)',
    );
    for (final p in allProjects) {
      final existing = await getStagesForProject(p.id);
      debugPrint(
        '[Atlas] ensureDefaultStages: project "${p.title}" has ${existing.length} stage(s)',
      );
      if (existing.isEmpty) {
        final stageId = '${DateTime.now().microsecondsSinceEpoch}_stage';
        debugPrint(
          '[Atlas] ensureDefaultStages: creating default stage for project ${p.id}',
        );
        await into(stages).insert(
          StagesCompanion(
            id: Value(stageId),
            projectId: Value(p.id),
            title: const Value('Tasks'),
            position: const Value(0),
            createdAt: Value(DateTime.now()),
          ),
        );
      }
    }
  }

  Future<void> updateProjectMeta(String id, Map<String, Object?> fields) async {
    Value<T?> _v<T>(String key) => fields.containsKey(key)
        ? Value(fields[key] as T?)
        : const Value.absent();

    final companion = ProjectsCompanion(
      title: fields.containsKey('title')
          ? Value(fields['title'] as String)
          : const Value.absent(),
      owner: _v<String>('owner'),
      status: fields.containsKey('status')
          ? Value(fields['status'] as String? ?? 'active')
          : const Value.absent(),
      description: _v<String>('description'),
      desiredOutcome: _v<String>('desiredOutcome'),
      successCriteria: _v<String>('successCriteria'),
      phase: _v<String>('phase'),
      priority: _v<String>('priority'),
      scopeIncluded: _v<String>('scopeIncluded'),
      scopeExcluded: _v<String>('scopeExcluded'),
      outcomeSummary: _v<String>('outcomeSummary'),
      lessonsLearned: _v<String>('lessonsLearned'),
    );
    await (update(projects)..where((t) => t.id.equals(id))).write(companion);
  }

  Future<void> softDeleteProject(String id, String reason) async {
    await (update(projects)..where((t) => t.id.equals(id))).write(
      ProjectsCompanion(
        status: const Value('deleted'),
        deletedAt: Value(DateTime.now()),
        deleteReason: Value(reason),
      ),
    );
  }

  // ProjectFull is just a Project (typedef). These return all non-deleted.
  Stream<List<ProjectFull>> watchProjectsFull() => watchProjects();

  Future<List<ProjectFull>> getProjectsFull() =>
      (select(projects)..where((t) => t.status.equals('active'))).get();

  Future<ProjectFull?> getProjectFull(String id) =>
      (select(projects)..where((t) => t.id.equals(id))).getSingleOrNull();

  // ── Stages ────────────────────────────────────────────────────────────────

  Stream<List<Stage>> watchStagesForProject(String projectId) =>
      (select(stages)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .watch();

  Future<List<Stage>> getStagesForProject(String projectId) =>
      (select(stages)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

  Stream<Stage?> watchActiveStageForProject(String projectId) {
    final key = 'active_stage_$projectId';
    return watchMetaString(key).asyncMap((id) async {
      if (id == null || id.isEmpty) {
        // Default to first stage
        return (select(stages)
              ..where((t) => t.projectId.equals(projectId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)])
              ..limit(1))
            .getSingleOrNull();
      }
      return (select(stages)..where((t) => t.id.equals(id))).getSingleOrNull();
    });
  }

  Future<void> setActiveStageIdForProject(String projectId, String stageId) =>
      setMetaString('active_stage_$projectId', stageId);

  // Bottleneck / owner on Stage
  Stream<String?> watchBottleneckOwner(String stageId) =>
      (select(stages)..where((t) => t.id.equals(stageId)))
          .watchSingleOrNull()
          .map((s) => s?.bottleneckOwner);

  Future<void> setBottleneckOwner(String stageId, String? owner) async {
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(bottleneckOwner: Value(owner)),
    );
  }

  Stream<bool> watchIsBottleneck(String stageId) =>
      (select(stages)..where((t) => t.id.equals(stageId)))
          .watchSingleOrNull()
          .map((s) => s?.isBottleneck ?? false);

  Future<void> setIsBottleneck(String stageId, bool v) async {
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(isBottleneck: Value(v)),
    );
  }

  Future<void> addStage(String projectId, String title) async {
    final existing = await (select(stages)
      ..where((t) => t.projectId.equals(projectId)))
      .get();
    final nextPos = existing.isEmpty
        ? 0
        : existing.map((s) => s.position).reduce((a, b) => a > b ? a : b) + 1;
    await into(stages).insert(StagesCompanion.insert(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      projectId: projectId,
      title: title,
      position: nextPos,
      createdAt: DateTime.now(),
    ));
  }

  Future<void> updateStageTitle(String stageId, String title) async {
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(title: Value(title)),
    );
  }

  Future<void> deleteStage(String stageId) async {
    await (delete(stages)..where((t) => t.id.equals(stageId))).go();
  }

  Future<void> reorderStage(String stageId, int newPosition) async {
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(position: Value(newPosition)),
    );
  }

  // ── Work Items ────────────────────────────────────────────────────────────

  Stream<List<WorkItem>> watchWorkItemsForStage(String stageId) =>
      (select(workItems)
            ..where(
              (t) =>
                  t.stageId.equals(stageId) &
                  t.status.isNotIn(['done', 'archived']),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .watch();

  Stream<List<WorkItem>> watchTodayItems() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return (select(workItems)..where(
          (t) =>
              t.status.isNotIn(['done', 'archived']) &
              (t.status.equals('doing') |
                  t.phoneQueue.equals(true) |
                  t.dueAt.isSmallerOrEqualValue(tomorrow) |
                  t.priority.isIn(['high', 'urgent'])),
        ))
        .watch();
  }

  Future<List<WorkItem>> getTodayItems() {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    return (select(workItems)..where(
          (t) =>
              t.status.isNotIn(['done', 'archived']) &
              (t.status.equals('doing') |
                  t.phoneQueue.equals(true) |
                  t.dueAt.isSmallerOrEqualValue(tomorrow) |
                  t.priority.isIn(['high', 'urgent'])),
        ))
        .get();
  }

  Future<List<WorkItem>> getAllActiveWorkItems() => (select(
    workItems,
  )..where((t) => t.status.isNotIn(['done', 'archived']))).get();

  Future<List<WorkItem>> getBlockedItems() =>
      (select(workItems)..where(
            (t) =>
                t.blockedReason.isNotNull() &
                t.status.isNotIn(['done', 'archived']),
          ))
          .get();

  Future<WorkItem?> getWorkItem(String id) =>
      (select(workItems)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<WorkItem>> getWorkItemsForProject(String projectId) async {
    final stageList = await getStagesForProject(projectId);
    if (stageList.isEmpty) return [];
    final ids = stageList.map((s) => s.id).toList();
    return (select(workItems)..where((t) => t.stageId.isIn(ids))).get();
  }

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
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final now = DateTime.now();
    await into(workItems).insert(
      WorkItemsCompanion(
        id: Value(id),
        stageId: Value(stageId),
        title: Value(title),
        description: Value(description),
        owner: Value(owner),
        status: Value(status),
        priority: Value(priority),
        dueAt: Value(dueAt),
        createdAt: Value(now),
        updatedAt: Value(now),
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
    bool clearDueAt = false,
    DateTime? dueAt,
    String? blockedReason,
    bool clearBlockedReason = false,
    bool? phoneQueue,
  }) async {
    await (update(workItems)..where((t) => t.id.equals(id))).write(
      WorkItemsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        description: description != null
            ? Value(description)
            : const Value.absent(),
        owner: owner != null ? Value(owner) : const Value.absent(),
        status: status != null ? Value(status) : const Value.absent(),
        priority: priority != null ? Value(priority) : const Value.absent(),
        dueAt: clearDueAt
            ? const Value(null)
            : dueAt != null
            ? Value(dueAt)
            : const Value.absent(),
        blockedReason: clearBlockedReason
            ? const Value(null)
            : blockedReason != null
            ? Value(blockedReason)
            : const Value.absent(),
        phoneQueue: phoneQueue != null
            ? Value(phoneQueue)
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
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

  Future<void> toggleWorkDone(String id) async {
    final item = await getWorkItem(id);
    if (item == null) return;
    final isDone = item.status == 'done';
    await setWorkItemStatus(id, isDone ? 'next' : 'done');
  }

  // Work item owner (used in governance)
  Stream<String?> watchWorkOwner(String workItemId) =>
      (select(workItems)..where((t) => t.id.equals(workItemId)))
          .watchSingleOrNull()
          .map((i) => i?.owner);

  Future<String?> getWorkOwner(String workItemId) async {
    final item = await getWorkItem(workItemId);
    return item?.owner;
  }

  Future<void> setWorkOwner(String workItemId, String? owner) async {
    await updateWorkItem(id: workItemId, owner: owner ?? '');
  }

  // ── Drafts ────────────────────────────────────────────────────────────────

  Stream<List<Draft>> watchDrafts() => (select(
    drafts,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  Future<void> saveDraft({
    required String kind,
    required String title,
    required String body,
    String? inputJson,
    String? projectId,
    String? workItemId,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final now = DateTime.now();
    await into(drafts).insert(
      DraftsCompanion(
        id: Value(id),
        kind: Value(kind),
        title: Value(title),
        body: Value(body),
        inputJson: Value(inputJson),
        projectId: Value(projectId),
        workItemId: Value(workItemId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> deleteDraft(String id) =>
      (delete(drafts)..where((t) => t.id.equals(id))).go();

  // ── Project governance ────────────────────────────────────────────────────

  Stream<List<Contact>> watchContacts() =>
      (select(contacts)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<List<Contact>> getContacts() =>
      (select(contacts)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<Contact?> getContact(String id) =>
      (select(contacts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<String> saveContact({
    String? id,
    required String name,
    String? title,
    String? phone,
    String? alternatePhone,
    String? email,
    String? website,
    String? businessName,
    String? notes,
    String? photoPath,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('Contact name is required.');
    }
    final now = DateTime.now();
    final contactId = id ?? now.microsecondsSinceEpoch.toString();
    final existing = await getContact(contactId);
    await into(contacts).insertOnConflictUpdate(
      ContactsCompanion(
        id: Value(contactId),
        name: Value(trimmedName),
        title: Value(_blankToNull(title)),
        phone: Value(_blankToNull(phone)),
        alternatePhone: Value(_blankToNull(alternatePhone)),
        email: Value(_blankToNull(email)),
        website: Value(_blankToNull(website)),
        businessName: Value(_blankToNull(businessName)),
        notes: Value(_blankToNull(notes)),
        photoPath: Value(_blankToNull(photoPath)),
        createdAt: Value(existing?.createdAt ?? now),
        updatedAt: Value(now),
      ),
    );
    return contactId;
  }

  Future<void> deleteContact(String id) =>
      (delete(contacts)..where((t) => t.id.equals(id))).go();

  Future<Contact?> findContactForImport({
    String? id,
    String? email,
    String? name,
  }) async {
    final cleanId = _blankToNull(id);
    if (cleanId != null) {
      final byId = await getContact(cleanId);
      if (byId != null) return byId;
    }
    final cleanEmail = _blankToNull(email)?.toLowerCase();
    if (cleanEmail != null) {
      final byEmail = await (select(
        contacts,
      )..where((t) => t.email.lower().equals(cleanEmail))).getSingleOrNull();
      if (byEmail != null) return byEmail;
    }
    final cleanName = _blankToNull(name)?.toLowerCase();
    if (cleanName != null) {
      return (select(
        contacts,
      )..where((t) => t.name.lower().equals(cleanName))).getSingleOrNull();
    }
    return null;
  }

  String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<List<ProjectPerson>> getProjectPeople(String projectId) =>
      (select(projectPeople)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  Future<void> addProjectPerson(
    String projectId,
    String name,
    String? role,
    String? authority,
  ) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await into(projectPeople).insert(
      ProjectPeopleCompanion(
        id: Value(id),
        projectId: Value(projectId),
        name: Value(name),
        role: Value(role),
        authority: Value(authority),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateProjectPerson(
    String personId,
    String name,
    String? role,
    String? authority,
  ) async {
    await (update(projectPeople)..where((t) => t.id.equals(personId))).write(
      ProjectPeopleCompanion(
        name: Value(name),
        role: Value(role),
        authority: Value(authority),
      ),
    );
  }

  Future<void> deleteProjectPerson(String personId) =>
      (delete(projectPeople)..where((t) => t.id.equals(personId))).go();

  Future<List<ProjectRisk>> getProjectRisks(String projectId) =>
      (select(projectRisks)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<void> addProjectRisk(
    String projectId,
    String title,
    String? desc,
    String severity,
  ) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await into(projectRisks).insert(
      ProjectRisksCompanion(
        id: Value(id),
        projectId: Value(projectId),
        title: Value(title),
        desc: Value(desc),
        severity: Value(severity),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteProjectRisk(String riskId) =>
      (delete(projectRisks)..where((t) => t.id.equals(riskId))).go();

  Future<List<ProjectDecision>> getProjectDecisions(String projectId) =>
      (select(projectDecisions)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<void> addProjectDecision(
    String projectId,
    String title,
    String? ctx,
    String? decider,
  ) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await into(projectDecisions).insert(
      ProjectDecisionsCompanion(
        id: Value(id),
        projectId: Value(projectId),
        title: Value(title),
        ctx: Value(ctx),
        decider: Value(decider),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteProjectDecision(String decisionId) =>
      (delete(projectDecisions)..where((t) => t.id.equals(decisionId))).go();

  // Project tags

  Stream<List<Tag>> watchTags() =>
      (select(tags)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<List<Tag>> getTags() =>
      (select(tags)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<Tag?> getTag(String id) =>
      (select(tags)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Tag?> findTagByName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return Future.value(null);
    return (select(tags)
          ..where((t) => t.name.lower().equals(trimmed.toLowerCase())))
        .getSingleOrNull();
  }

  Future<String> saveTag({
    String? id,
    required String name,
    String? color,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Tag name is required.');
    }
    final now = DateTime.now();
    final tagId = id ?? now.microsecondsSinceEpoch.toString();
    final existing = await getTag(tagId);
    await into(tags).insertOnConflictUpdate(
      TagsCompanion(
        id: Value(tagId),
        name: Value(trimmed),
        color: Value(_blankToNull(color)),
        createdAt: Value(existing?.createdAt ?? now),
        updatedAt: Value(now),
      ),
    );
    return tagId;
  }

  Future<void> updateTag(String id, {String? name, String? color}) async {
    await (update(tags)..where((t) => t.id.equals(id))).write(
      TagsCompanion(
        name: name != null ? Value(name.trim()) : const Value.absent(),
        color: color != null
            ? Value(_blankToNull(color))
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteTag(String id) async {
    await transaction(() async {
      await (delete(projectTags)..where((t) => t.tagId.equals(id))).go();
      await (delete(tags)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<void> assignTagToProject(String projectId, String tagId) async {
    await into(projectTags).insertOnConflictUpdate(
      ProjectTagsCompanion(
        projectId: Value(projectId),
        tagId: Value(tagId),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> unassignTagFromProject(String projectId, String tagId) =>
      (delete(projectTags)..where(
            (t) => t.projectId.equals(projectId) & t.tagId.equals(tagId),
          ))
          .go();

  Future<void> setProjectTags(String projectId, Iterable<String> tagIds) async {
    final uniqueIds = tagIds.where((id) => id.trim().isNotEmpty).toSet();
    await transaction(() async {
      await (delete(
        projectTags,
      )..where((t) => t.projectId.equals(projectId))).go();
      for (final tagId in uniqueIds) {
        await assignTagToProject(projectId, tagId);
      }
    });
  }

  Future<List<ProjectTagAssignment>> getProjectTagAssignments(
    String projectId,
  ) => (select(projectTags)..where((t) => t.projectId.equals(projectId))).get();

  Stream<List<Tag>> watchTagsForProject(String projectId) {
    final query =
        select(
            tags,
          ).join([innerJoin(projectTags, projectTags.tagId.equalsExp(tags.id))])
          ..where(projectTags.projectId.equals(projectId))
          ..orderBy([OrderingTerm.asc(tags.name)]);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(tags)).toList(growable: false),
    );
  }

  Future<List<Tag>> getTagsForProject(String projectId) {
    final query =
        select(
            tags,
          ).join([innerJoin(projectTags, projectTags.tagId.equalsExp(tags.id))])
          ..where(projectTags.projectId.equals(projectId))
          ..orderBy([OrderingTerm.asc(tags.name)]);
    return query.get().then(
      (rows) => rows.map((row) => row.readTable(tags)).toList(growable: false),
    );
  }

  Stream<List<Project>> watchProjectsForTag(String tagId) {
    final query =
        select(projects).join([
            innerJoin(
              projectTags,
              projectTags.projectId.equalsExp(projects.id),
            ),
          ])
          ..where(projectTags.tagId.equals(tagId) & projects.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(projects.createdAt)]);
    return query.watch().map(
      (rows) =>
          rows.map((row) => row.readTable(projects)).toList(growable: false),
    );
  }

  Future<List<Project>> getProjectsForTag(String tagId) {
    final query =
        select(projects).join([
            innerJoin(
              projectTags,
              projectTags.projectId.equalsExp(projects.id),
            ),
          ])
          ..where(projectTags.tagId.equals(tagId) & projects.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(projects.createdAt)]);
    return query.get().then(
      (rows) =>
          rows.map((row) => row.readTable(projects)).toList(growable: false),
    );
  }

  Future<List<Project>> getProjectsMatchingTags(
    Iterable<String> tagIds, {
    bool matchAll = false,
  }) async {
    final ids = tagIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return getProjectsFull();
    final assignments = await (select(
      projectTags,
    )..where((t) => t.tagId.isIn(ids))).get();
    final counts = <String, int>{};
    for (final assignment in assignments) {
      counts.update(
        assignment.projectId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final projectIds = counts.entries
        .where((entry) => !matchAll || entry.value == ids.length)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (projectIds.isEmpty) return const <Project>[];
    return (select(projects)
          ..where((t) => t.id.isIn(projectIds) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  // Project media

  Stream<List<ProjectMediaItem>> watchAllProjectMedia() => (select(
    projectMedia,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  Future<List<ProjectMediaItem>> getAllProjectMedia() => (select(
    projectMedia,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();

  Stream<List<ProjectMediaItem>> watchProjectMedia(String projectId) =>
      (select(projectMedia)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<List<ProjectMediaItem>> getProjectMedia(String projectId) =>
      (select(projectMedia)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<ProjectMediaItem?> getProjectMediaItem(String id) =>
      (select(projectMedia)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<String> saveProjectMedia({
    String? id,
    required String projectId,
    required String title,
    required String originalFilename,
    required String storedPath,
    String mediaType = 'file',
    String? mimeType,
    String? extension,
    int? byteSize,
    DateTime? fileModifiedAt,
    String? caption,
    bool isCover = false,
    String? source,
    String? metadataJson,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw ArgumentError('Media title is required.');
    }
    final now = DateTime.now();
    final mediaId = id ?? now.microsecondsSinceEpoch.toString();
    final existing = await getProjectMediaItem(mediaId);
    await into(projectMedia).insertOnConflictUpdate(
      ProjectMediaCompanion(
        id: Value(mediaId),
        projectId: Value(projectId),
        title: Value(trimmedTitle),
        originalFilename: Value(originalFilename),
        storedPath: Value(storedPath),
        mediaType: Value(mediaType),
        mimeType: Value(_blankToNull(mimeType)),
        extension: Value(_blankToNull(extension)),
        byteSize: Value(byteSize),
        fileModifiedAt: Value(fileModifiedAt),
        caption: Value(_blankToNull(caption)),
        isCover: Value(isCover),
        source: Value(_blankToNull(source)),
        metadataJson: Value(_blankToNull(metadataJson)),
        createdAt: Value(existing?.createdAt ?? now),
        updatedAt: Value(now),
      ),
    );
    return mediaId;
  }

  Future<String> importProjectMediaFromPath(
    String projectId,
    String path, {
    String? title,
    String? caption,
    bool isCover = false,
    String? source,
    String? metadataJson,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', path);
    }
    final stat = file.statSync();
    final filename = p.basename(path);
    final ext = p.extension(filename).replaceFirst('.', '').toLowerCase();
    final cleanExt = ext.isEmpty ? null : ext;
    return saveProjectMedia(
      projectId: projectId,
      title: title?.trim().isNotEmpty == true ? title!.trim() : filename,
      originalFilename: filename,
      storedPath: path,
      mediaType: _mediaTypeForExtension(cleanExt),
      mimeType: _mimeTypeForExtension(cleanExt),
      extension: cleanExt,
      byteSize: stat.size,
      fileModifiedAt: stat.modified,
      caption: caption,
      isCover: isCover,
      source: source,
      metadataJson: metadataJson,
    );
  }

  Future<void> updateProjectMedia(
    String id, {
    String? title,
    String? caption,
    bool? isCover,
    String? source,
    String? metadataJson,
  }) async {
    await (update(projectMedia)..where((t) => t.id.equals(id))).write(
      ProjectMediaCompanion(
        title: title != null ? Value(title.trim()) : const Value.absent(),
        caption: caption != null
            ? Value(_blankToNull(caption))
            : const Value.absent(),
        isCover: isCover != null ? Value(isCover) : const Value.absent(),
        source: source != null
            ? Value(_blankToNull(source))
            : const Value.absent(),
        metadataJson: metadataJson != null
            ? Value(_blankToNull(metadataJson))
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteProjectMedia(String id) =>
      (delete(projectMedia)..where((t) => t.id.equals(id))).go();

  Future<void> setProjectCoverMedia(String projectId, String mediaId) async {
    await transaction(() async {
      await (update(projectMedia)..where((t) => t.projectId.equals(projectId)))
          .write(const ProjectMediaCompanion(isCover: Value(false)));
      await (update(
            projectMedia,
          )..where((t) => t.projectId.equals(projectId) & t.id.equals(mediaId)))
          .write(
            ProjectMediaCompanion(
              isCover: const Value(true),
              updatedAt: Value(DateTime.now()),
            ),
          );
    });
  }

  String _mediaTypeForExtension(String? extension) {
    const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
    const videos = {'mp4', 'mov', 'avi', 'mkv', 'webm'};
    const audio = {'mp3', 'wav', 'm4a', 'aac', 'ogg'};
    if (extension == null) return 'file';
    if (images.contains(extension)) return 'image';
    if (videos.contains(extension)) return 'video';
    if (audio.contains(extension)) return 'audio';
    return 'file';
  }

  String? _mimeTypeForExtension(String? extension) {
    const mimeTypes = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'bmp': 'image/bmp',
      'heic': 'image/heic',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'webm': 'video/webm',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'ogg': 'audio/ogg',
      'pdf': 'application/pdf',
    };
    return extension == null ? null : mimeTypes[extension];
  }

  // ── Documents ─────────────────────────────────────────────────────────────

  Stream<List<Document>> watchDocuments() => (select(
    documents,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  Stream<List<Document>> watchDocumentsForProject(String projectId) =>
      (select(documents)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<void> importDocumentFromPath(String path, {String? projectId}) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', path);
    }
    final name = file.uri.pathSegments.last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : null;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final now = DateTime.now();
    await into(documents).insert(
      DocumentsCompanion(
        id: Value(id),
        title: Value(name),
        originalFilename: Value(name),
        storedPath: Value(path),
        extension: Value(ext),
        projectId: Value(projectId),
        status: const Value('imported'),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  // ── Event log ─────────────────────────────────────────────────────────────

  Stream<List<Document>> watchDocumentsForWorkItem(String workItemId) {
    final query =
        select(documents).join([
            innerJoin(
              documentLinks,
              documentLinks.documentId.equalsExp(documents.id),
            ),
          ])
          ..where(
            documentLinks.entityType.equals('work_item') &
                documentLinks.entityId.equals(workItemId),
          )
          ..orderBy([OrderingTerm.desc(documents.createdAt)]);
    return query.watch().map(
      (rows) =>
          rows.map((row) => row.readTable(documents)).toList(growable: false),
    );
  }

  Future<List<Document>> getDocumentsForWorkItem(String workItemId) {
    final query =
        select(documents).join([
            innerJoin(
              documentLinks,
              documentLinks.documentId.equalsExp(documents.id),
            ),
          ])
          ..where(
            documentLinks.entityType.equals('work_item') &
                documentLinks.entityId.equals(workItemId),
          )
          ..orderBy([OrderingTerm.desc(documents.createdAt)]);
    return query.get().then(
      (rows) =>
          rows.map((row) => row.readTable(documents)).toList(growable: false),
    );
  }

  Future<void> linkDocumentToWorkItem(
    String documentId,
    String workItemId,
  ) async {
    final existing =
        await (select(documentLinks)..where(
              (t) =>
                  t.documentId.equals(documentId) &
                  t.entityType.equals('work_item') &
                  t.entityId.equals(workItemId),
            ))
            .getSingleOrNull();
    if (existing != null) return;
    await into(documentLinks).insert(
      DocumentLinksCompanion(
        id: Value('${documentId}_${workItemId}_work_item'),
        documentId: Value(documentId),
        entityType: const Value('work_item'),
        entityId: Value(workItemId),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> unlinkDocumentFromWorkItem(
    String documentId,
    String workItemId,
  ) async {
    await (delete(documentLinks)..where(
          (t) =>
              t.documentId.equals(documentId) &
              t.entityType.equals('work_item') &
              t.entityId.equals(workItemId),
        ))
        .go();
  }

  Stream<List<WorkItemNote>> watchNotesForWorkItem(String workItemId) =>
      (select(workItemNotes)
            ..where((t) => t.workItemId.equals(workItemId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<void> addWorkItemNote(String workItemId, String body) async {
    final now = DateTime.now();
    await into(workItemNotes).insert(
      WorkItemNotesCompanion(
        id: Value(now.microsecondsSinceEpoch.toString()),
        workItemId: Value(workItemId),
        body: Value(body),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> updateWorkItemNote(String noteId, String body) async {
    await (update(workItemNotes)..where((t) => t.id.equals(noteId))).write(
      WorkItemNotesCompanion(
        body: Value(body),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

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
    await into(workItemAnalyses).insert(
      WorkItemAnalysesCompanion(
        id: Value(DateTime.now().microsecondsSinceEpoch.toString()),
        workItemId: Value(workItemId),
        prompt: Value(prompt),
        output: Value(output),
        model: Value(model),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> logEvent({
    String level = 'info',
    required String area,
    required String action,
    String? entityType,
    String? entityId,
    String? inputJson,
    String? outputJson,
    String? correlationId,
    String? error,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await into(eventLog).insert(
      EventLogCompanion(
        id: Value(id),
        timestamp: Value(DateTime.now()),
        level: Value(level),
        area: Value(area),
        action: Value(action),
        entityType: Value(entityType),
        entityId: Value(entityId),
        inputJson: Value(inputJson),
        outputJson: Value(outputJson),
        error: Value(error),
      ),
    );
  }

  Future<void> logError({
    required String area,
    required String action,
    required Object error,
    StackTrace? stackTrace,
    String? inputJson,
    String? entityId,
    String? entityType,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await into(eventLog).insert(
      EventLogCompanion(
        id: Value(id),
        timestamp: Value(DateTime.now()),
        level: const Value('error'),
        area: Value(area),
        action: Value(action),
        entityType: Value(entityType),
        entityId: Value(entityId),
        inputJson: Value(inputJson),
        error: Value(error.toString()),
        stackTrace: Value(stackTrace?.toString()),
      ),
    );
  }

  Stream<List<EventLogData>> watchRecentEvents() =>
      (select(eventLog)
            ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
            ..limit(500))
          .watch();

  Future<List<EventLogData>> getRecentEvents() =>
      (select(eventLog)
            ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
            ..limit(500))
          .get();

  Future<void> clearEventLog() => delete(eventLog).go();

  // ── Daily Reviews ─────────────────────────────────────────────────────────

  Future<void> saveDailyReview(String summary) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    // Delete existing review for today (upsert by date)
    await (delete(dailyReviews)
      ..where((t) => t.reviewDate.isBiggerOrEqualValue(today) &
                     t.reviewDate.isSmallerThanValue(tomorrow)))
      .go();
    await into(dailyReviews).insert(DailyReviewsCompanion.insert(
      id: now.millisecondsSinceEpoch.toString(),
      reviewDate: today,
      summary: summary,
      createdAt: now,
    ));
  }

  Future<DailyReview?> getDailyReviewForDate(DateTime date) async {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));
    return (select(dailyReviews)
      ..where((t) => t.reviewDate.isBiggerOrEqualValue(start) &
                     t.reviewDate.isSmallerThanValue(end))
      ..limit(1))
      .getSingleOrNull();
  }

  Stream<List<DailyReview>> watchRecentDailyReviews({int limit = 30}) =>
      (select(dailyReviews)
        ..orderBy([(t) => OrderingTerm.desc(t.reviewDate)])
        ..limit(limit))
      .watch();

  // ── Outbox ────────────────────────────────────────────────────────────────

  Future<String> addOutboxMessage({
    required String channel,
    required String title,
    required String body,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await into(outboxMessages).insert(
      OutboxMessagesCompanion(
        id: Value(id),
        channel: Value(channel),
        title: Value(title),
        body: Value(body),
        createdAt: Value(DateTime.now()),
        status: const Value('pending'),
      ),
    );
    return id;
  }

  Future<void> markOutboxSent(String id) async {
    await (update(outboxMessages)..where((t) => t.id.equals(id))).write(
      OutboxMessagesCompanion(
        status: const Value('sent'),
        sentAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> markOutboxFailed(String id, String error) async {
    await (update(outboxMessages)..where((t) => t.id.equals(id))).write(
      OutboxMessagesCompanion(
        status: const Value('failed'),
        error: Value(error),
      ),
    );
  }

  Stream<List<OutboxMessage>> watchOutboxMessages() =>
      (select(outboxMessages)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(50))
          .watch();
}
