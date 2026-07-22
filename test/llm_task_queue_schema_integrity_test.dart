import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  group('LLM task queue schema integrity', () {
    test('fresh schema rejects foreign-key and invalid-state writes', () async {
      final db = AppDb.withExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      await db.createProject('project-a', 'A', DateTime(2026, 1, 1));
      final id = await db.enqueueLlmTask(
        projectId: 'project-a',
        title: 'Valid task',
        objective: 'Stay valid.',
        contextJson: '{}',
      );

      final foreignKeys = await db
          .customSelect("PRAGMA foreign_key_list('llm_task_queue')")
          .get();
      expect(foreignKeys.map((row) => row.data['table']).toSet(), {
        'projects',
        'work_items',
      });
      await expectLater(
        db.customStatement(
          'UPDATE llm_task_queue SET status = ? WHERE id = ?',
          ['invented', id],
        ),
        throwsA(isA<SqliteException>()),
      );
      await expectLater(
        db.customStatement(
          "UPDATE llm_task_queue SET status = 'leased' WHERE id = ?",
          [id],
        ),
        throwsA(isA<SqliteException>()),
      );
      await expectLater(
        db.enqueueLlmTask(
          projectId: 'missing-project',
          title: 'Orphan',
          objective: 'Must fail.',
          contextJson: '{}',
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(
        await db
            .customSelect("PRAGMA foreign_key_check('llm_task_queue')")
            .get(),
        isEmpty,
      );
    });

    test(
      'boundary rejects cross-project links and non-positive leases',
      () async {
        final db = AppDb.withExecutor(NativeDatabase.memory());
        addTearDown(db.close);
        await db.createProject('project-a', 'A', DateTime(2026, 1, 1));
        await db.createProject('project-b', 'B', DateTime(2026, 1, 1));
        final stage = (await db.getStagesForProject('project-b')).single;
        final workItemId = await db.addWorkItem(
          stageId: stage.id,
          title: 'Belongs to B',
        );
        final id = await db.enqueueLlmTask(
          projectId: 'project-a',
          title: 'Project A task',
          objective: 'Remain in A.',
          contextJson: '{}',
        );

        await expectLater(
          db.linkLlmTaskToWorkItem(id: id, workItemId: workItemId),
          throwsArgumentError,
        );
        await expectLater(
          db.claimLlmTask(
            taskId: id,
            leasedBy: 'worker',
            leaseDuration: Duration.zero,
          ),
          throwsArgumentError,
        );
        expect((await db.getLlmTask(id))!.status, 'pending');
      },
    );

    test('raw SQL ownership triggers reject links and reparenting', () async {
      final db = AppDb.withExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      await db.createProject('project-a', 'A', DateTime(2026, 1, 1));
      await db.createProject('project-b', 'B', DateTime(2026, 1, 1));
      final stageA = (await db.getStagesForProject('project-a')).single;
      final stageB = (await db.getStagesForProject('project-b')).single;
      final workA = await db.addWorkItem(stageId: stageA.id, title: 'A work');
      final workB = await db.addWorkItem(stageId: stageB.id, title: 'B work');
      await _insertPendingRaw(db, 'linked', 'project-a', workA);

      for (final write in <Future<void> Function()>[
        () => _insertPendingRaw(db, 'cross-insert', 'project-a', workB),
        () => _insertPendingRaw(db, 'orphan-work', 'project-a', 'missing'),
        () => db.customStatement(
          'UPDATE llm_task_queue SET work_item_id = ? WHERE id = ?',
          [workB, 'linked'],
        ),
        () => db.customStatement(
          'UPDATE llm_task_queue SET project_id = ? WHERE id = ?',
          ['project-b', 'linked'],
        ),
        () => db.customStatement(
          'UPDATE work_items SET stage_id = ? WHERE id = ?',
          [stageB.id, workA],
        ),
        () => db.customStatement(
          'UPDATE stages SET project_id = ? WHERE id = ?',
          ['project-b', stageA.id],
        ),
      ]) {
        await expectLater(write(), throwsA(isA<SqliteException>()));
      }

      await db.customStatement('DELETE FROM work_items WHERE id = ?', [workA]);
      expect((await db.getLlmTask('linked'))!.workItemId, isNull);
      await db.customStatement(
        'INSERT INTO projects (id, title, created_at) VALUES (?, ?, ?)',
        ['queue-only-project', 'Queue only', 1],
      );
      await _insertPendingRaw(db, 'project-delete', 'queue-only-project', null);
      await expectLater(
        db.customStatement('DELETE FROM projects WHERE id = ?', [
          'queue-only-project',
        ]),
        throwsA(isA<SqliteException>()),
      );
      expect(
        await db
            .customSelect('PRAGMA foreign_keys')
            .getSingle()
            .then((row) => row.data['foreign_keys']),
        1,
      );
    });

    test('raw SQL enforces every enum and scalar affinity', () async {
      final db = AppDb.withExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      await db.createProject('project-a', 'A', DateTime(2026, 1, 1));
      await _insertPendingRaw(db, 'enums', 'project-a', null);
      const enumValues = <String, List<String>>{
        'priority': ['low', 'normal', 'high', 'urgent'],
        'readiness': [
          'ready',
          'blocked',
          'needs_decision',
          'needs_context',
          'review_needed',
        ],
        'size': ['tiny', 'small', 'medium', 'large'],
        'risk': [
          'docs_only',
          'low_code',
          'medium_code',
          'db_schema',
          'release',
          'external_facing',
        ],
        'suggested_actor': [
          'user',
          'codex',
          'claude',
          'local_llm',
          'manual_review',
        ],
        'verification_needed': ['none', 'tests', 'smoke', 'build', 'manual_ui'],
      };
      for (final field in enumValues.entries) {
        for (final allowed in field.value) {
          await db.customStatement(
            'UPDATE llm_task_queue SET ${field.key} = ? WHERE id = ?',
            [allowed, 'enums'],
          );
        }
        await expectLater(
          db.customStatement(
            'UPDATE llm_task_queue SET ${field.key} = ? WHERE id = ?',
            ['invented', 'enums'],
          ),
          throwsA(isA<SqliteException>()),
        );
      }
      for (final statement in <String>[
        "UPDATE llm_task_queue SET id = '' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET project_id = '' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET title = '' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET objective = '' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET created_by = '' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET context_json = 'not-json' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET attempts = -1 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET attempts = 'text' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET attempts = 1.5 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET created_at = 'text' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET updated_at = 0 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET last_reviewed_at = 1.5 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'completed' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'failed' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'cancelled' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET result_json = '{}' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET error = 'residual' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET review_draft_id = 'residual' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'leased', leased_by = '', leased_at = 2, lease_expires_at = 3, attempts = 1 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'leased', leased_by = 'worker', leased_at = 3, lease_expires_at = 3, attempts = 1 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'failed', leased_by = 'worker', leased_at = 2, attempts = 1, completed_at = 3, error = ' ' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'cancelled', completed_at = 2, review_draft_id = 'draft' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET context_json = '[1]' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET context_json = '1' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET context_json = 'null' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET context_json = x'7B7D' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET last_reviewed_at = 0 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'leased', leased_by = 'worker', leased_at = 0, lease_expires_at = 3, attempts = 1, updated_at = 3 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'leased', leased_by = 'worker', leased_at = 2, lease_expires_at = 3, attempts = 1, updated_at = 1 WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'completed', leased_by = 'worker', leased_at = 2, attempts = 1, completed_at = 3, updated_at = 2, result_json = '{}' WHERE id = 'enums'",
        "UPDATE llm_task_queue SET status = 'cancelled', completed_at = 0 WHERE id = 'enums'",
      ]) {
        await expectLater(
          db.customStatement(statement),
          throwsA(isA<SqliteException>()),
        );
      }
      for (final column in <String>[
        'id',
        'project_id',
        'title',
        'objective',
        'context_json',
        'priority',
        'status',
        'created_by',
        'readiness',
        'size',
        'risk',
        'suggested_actor',
        'verification_needed',
        'work_item_id',
        'leased_by',
        'result_json',
        'error',
        'review_draft_id',
        'next_action',
        'blocker_reason',
        'planning_notes',
      ]) {
        await expectLater(
          db.customStatement(
            "UPDATE llm_task_queue SET $column = x'61' WHERE id = 'enums'",
          ),
          throwsA(isA<SqliteException>()),
          reason: column,
        );
      }
    });

    test('runtime transitions satisfy every valid state shape', () async {
      final db = AppDb.withExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      await db.createProject('project-a', 'A', DateTime(2026, 1, 1));
      final created = DateTime.utc(2026, 1, 1);
      Future<String> enqueue(String title) => db.enqueueLlmTask(
        projectId: 'project-a',
        title: title,
        objective: 'Exercise state shape.',
        contextJson: '{}',
        createdAt: created,
      );

      final completedId = await enqueue('complete');
      final completedLease = await db.claimLlmTask(
        taskId: completedId,
        leasedBy: 'worker',
        now: created.add(const Duration(minutes: 1)),
      );
      await db.completeLlmTask(
        id: completedId,
        workerId: 'worker',
        leaseAttempt: completedLease!.attempts,
        resultJson: '{"ok":true}',
        handoffDraft: const LlmTaskCompletionDraftPayload(
          id: 'completion-draft',
          kind: 'agent_proposal',
          title: 'Review completion',
          body: 'Review it.',
          inputJson: '{}',
          projectId: null,
          workItemId: null,
        ),
        now: created.add(const Duration(minutes: 2)),
      );

      final failedId = await enqueue('fail');
      final failedLease = await db.claimLlmTask(
        taskId: failedId,
        leasedBy: 'worker',
        now: created.add(const Duration(minutes: 1)),
      );
      await db.failLlmTask(
        id: failedId,
        workerId: 'worker',
        leaseAttempt: failedLease!.attempts,
        error: 'expected failure',
        resultJson: '{"partial":true}',
        now: created.add(const Duration(minutes: 2)),
      );
      await db.requeueLlmTask(
        id: failedId,
        updatedAt: created.add(const Duration(minutes: 3)),
      );

      final leasedCancelId = await enqueue('cancel leased');
      await db.claimLlmTask(
        taskId: leasedCancelId,
        leasedBy: 'worker',
        now: created.add(const Duration(minutes: 1)),
      );
      await db.cancelLlmTask(
        id: leasedCancelId,
        cancelledAt: created.add(const Duration(minutes: 2)),
      );

      final failedCancelId = await enqueue('cancel failed');
      final failedCancelLease = await db.claimLlmTask(
        taskId: failedCancelId,
        leasedBy: 'worker',
        now: created.add(const Duration(minutes: 1)),
      );
      await db.failLlmTask(
        id: failedCancelId,
        workerId: 'worker',
        leaseAttempt: failedCancelLease!.attempts,
        error: 'retained error',
        resultJson: '{"retained":true}',
        now: created.add(const Duration(minutes: 2)),
      );
      await db.cancelLlmTask(
        id: failedCancelId,
        cancelledAt: created.add(const Duration(minutes: 3)),
      );

      final cancelledId = await enqueue('cancel');
      await db.cancelLlmTask(
        id: cancelledId,
        cancelledAt: created.add(const Duration(minutes: 1)),
      );
      await db.requeueLlmTask(
        id: cancelledId,
        updatedAt: created.add(const Duration(minutes: 2)),
      );

      expect((await db.getLlmTask(completedId))!.status, 'completed');
      expect((await db.getLlmTask(failedId))!.status, 'pending');
      expect((await db.getLlmTask(cancelledId))!.status, 'pending');
      expect((await db.getLlmTask(leasedCancelId))!.status, 'cancelled');
      final cancelledFailure = await db.getLlmTask(failedCancelId);
      expect(cancelledFailure!.status, 'cancelled');
      expect(cancelledFailure.error, isNull);
      expect(cancelledFailure.resultJson, '{"retained":true}');
      await expectLater(
        db.customStatement(
          "UPDATE llm_task_queue SET result_json = 'bad' WHERE id = ?",
          [completedId],
        ),
        throwsA(isA<SqliteException>()),
      );
      for (final value in ["'[1]'", "'1'", "'null'", "x'7B7D'"]) {
        await expectLater(
          db.customStatement(
            'UPDATE llm_task_queue SET result_json = $value WHERE id = ?',
            [completedId],
          ),
          throwsA(isA<SqliteException>()),
          reason: value,
        );
      }
    });

    test(
      'valid v25 queue rebuild preserves rows and passes FK check',
      () async {
        final fixture = await _v25Fixture();
        addTearDown(() => fixture.directory.delete(recursive: true));
        _addValidLegacyStateRows(fixture.file);
        final db = _open(fixture.file);
        addTearDown(db.close);

        expect((await db.getLlmTask('legacy-task'))!.status, 'pending');
        final migrated = await db.getLlmTasks(projectId: 'legacy-project');
        expect(migrated, hasLength(10));
        expect(
          migrated.map((row) => row.status).toSet(),
          containsAll([
            'pending',
            'leased',
            'completed',
            'failed',
            'cancelled',
          ]),
        );
        expect(migrated.firstWhere((row) => row.id == 'requeued').attempts, 2);
        expect(
          migrated
              .firstWhere((row) => row.id == 'completed-draft')
              .reviewDraftId,
          'legacy-draft',
        );
        expect(
          migrated.firstWhere((row) => row.id == 'cancelled-failed').resultJson,
          '{}',
        );
        expect(db.schemaVersion, 26);
        expect(
          await db
              .customSelect("PRAGMA foreign_key_check('llm_task_queue')")
              .get(),
          isEmpty,
        );
      },
    );

    test(
      'invalid v25 queue aborts atomically and preserves v25 bytes',
      () async {
        final fixture = await _v25Fixture(invalidKind: 'status');
        addTearDown(() => fixture.directory.delete(recursive: true));
        final db = _open(fixture.file);
        await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
        await db.close();

        final raw = sqlite3.open(fixture.file.path);
        addTearDown(raw.dispose);
        expect(raw.userVersion, 25);
        expect(
          raw.select('SELECT status FROM llm_task_queue WHERE id = ?', [
            'legacy-task',
          ]).single['status'],
          'invented',
        );
      },
    );

    test(
      'v25 rebuild replaces retained cross-table triggers atomically',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'atlas_queue_v25_triggers_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File(p.join(directory.path, 'atlas.sqlite'));
        final current = _open(file);
        await current.createProject(
          'legacy-project',
          'Legacy',
          DateTime(2026, 1, 1),
        );
        await current.enqueueLlmTask(
          projectId: 'legacy-project',
          title: 'Retain triggers',
          objective: 'Exercise partial migration recovery.',
          contextJson: '{}',
        );
        await current.close();

        final raw = sqlite3.open(file.path);
        raw.userVersion = 25;
        raw.dispose();

        final migrated = _open(file);
        addTearDown(migrated.close);
        expect(
          await migrated.getLlmTasks(projectId: 'legacy-project'),
          hasLength(1),
        );
        final triggers = await migrated.customSelect('''
        SELECT name FROM sqlite_master
        WHERE type = 'trigger' AND name LIKE 'guard_llm_task_queue_%'
      ''').get();
        expect(triggers, hasLength(4));
        expect(migrated.schemaVersion, 26);
      },
    );

    test('v25 migration rejects TEXT and REAL integer storage', () async {
      for (final kind in ['attemptsText', 'attemptsReal', 'createdReal']) {
        final fixture = await _v25Fixture(invalidKind: kind);
        final db = _open(fixture.file);
        await expectLater(
          db.customSelect('SELECT 1').get(),
          throwsA(anything),
          reason: kind,
        );
        await db.close();
        final raw = sqlite3.open(fixture.file.path);
        expect(raw.userVersion, 25, reason: kind);
        expect(
          raw
              .select('SELECT count(*) AS count FROM llm_task_queue')
              .single['count'],
          1,
          reason: kind,
        );
        raw.dispose();
        await fixture.directory.delete(recursive: true);
      }
    });

    test(
      'v25 migration rejects ownership, JSON, text, and state corruption',
      () async {
        for (final kind in [
          'orphanStage',
          'contextBlob',
          'contextArray',
          'contextScalar',
          'contextNull',
          'resultArray',
          'requiredBlob',
          'nullableBlob',
          'chronology',
          'invalidLeaseState',
        ]) {
          final fixture = await _v25Fixture(invalidKind: kind);
          final db = _open(fixture.file);
          await expectLater(
            db.customSelect('SELECT 1').get(),
            throwsA(anything),
            reason: kind,
          );
          await db.close();
          final raw = sqlite3.open(fixture.file.path);
          expect(raw.userVersion, 25, reason: kind);
          expect(
            raw
                .select('SELECT count(*) AS count FROM llm_task_queue')
                .single['count'],
            1,
            reason: kind,
          );
          raw.dispose();
          await fixture.directory.delete(recursive: true);
        }
      },
    );
  });
}

AppDb _open(File file) => AppDb.withExecutor(NativeDatabase(file));

void _addValidLegacyStateRows(File file) {
  final raw = sqlite3.open(file.path);
  void clone(String id, String values) {
    raw.execute(
      "INSERT INTO llm_task_queue SELECT * FROM llm_task_queue WHERE id = 'legacy-task'",
    );
    raw.execute(
      "UPDATE llm_task_queue SET id = ?, $values WHERE rowid = last_insert_rowid()",
      [id],
    );
  }

  clone('requeued', 'attempts = 2');
  clone(
    'leased',
    "status = 'leased', leased_by = 'worker', leased_at = 2, "
        'lease_expires_at = 4, attempts = 1, updated_at = 2',
  );
  clone(
    'completed',
    "status = 'completed', leased_by = 'worker', leased_at = 2, "
        "attempts = 1, result_json = '{}', completed_at = 3, updated_at = 3",
  );
  clone(
    'completed-draft',
    "status = 'completed', leased_by = 'worker', leased_at = 2, "
        "attempts = 1, result_json = '{}', review_draft_id = 'legacy-draft', "
        'completed_at = 3, updated_at = 3',
  );
  clone(
    'failed',
    "status = 'failed', leased_by = 'worker', leased_at = 2, attempts = 1, "
        "error = 'failure', completed_at = 3, updated_at = 3",
  );
  clone(
    'failed-result',
    "status = 'failed', leased_by = 'worker', leased_at = 2, attempts = 1, "
        "result_json = '{}', error = 'failure', completed_at = 3, updated_at = 3",
  );
  clone(
    'cancelled-pending',
    "status = 'cancelled', completed_at = 2, updated_at = 2",
  );
  clone(
    'cancelled-leased',
    "status = 'cancelled', attempts = 1, completed_at = 3, updated_at = 3",
  );
  clone(
    'cancelled-failed',
    "status = 'cancelled', attempts = 1, result_json = '{}', "
        'completed_at = 3, updated_at = 3',
  );
  raw.dispose();
}

Future<void> _insertPendingRaw(
  AppDb db,
  String id,
  String projectId,
  String? workItemId,
) => db.customStatement(
  '''INSERT INTO llm_task_queue (
    id, project_id, work_item_id, title, objective, context_json, created_by,
    created_at, updated_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
  [
    id,
    projectId,
    workItemId,
    'Raw task',
    'Test constraints.',
    '{}',
    'test',
    1,
    1,
  ],
);

Future<({Directory directory, File file})> _v25Fixture({
  String? invalidKind,
}) async {
  final directory = await Directory.systemTemp.createTemp('atlas_queue_v25_');
  final file = File(p.join(directory.path, 'atlas.sqlite'));
  final current = _open(file);
  await current.customSelect('SELECT 1').get();
  await current.createProject('legacy-project', 'Legacy', DateTime(2026, 1, 1));
  await current.close();

  final raw = sqlite3.open(file.path);
  raw.execute('PRAGMA foreign_keys = OFF');
  for (final trigger in [
    'guard_llm_task_queue_project_insert',
    'guard_llm_task_queue_project_update',
    'guard_llm_task_queue_work_item_reparent',
    'guard_llm_task_queue_stage_reparent',
  ]) {
    raw.execute('DROP TRIGGER IF EXISTS $trigger');
  }
  raw.execute(
    'ALTER TABLE llm_task_queue RENAME TO llm_task_queue_constrained',
  );
  raw.execute(
    'CREATE TABLE llm_task_queue AS '
    'SELECT * FROM llm_task_queue_constrained WHERE 0',
  );
  raw.execute('DROP TABLE llm_task_queue_constrained');
  raw.execute(
    '''INSERT INTO llm_task_queue (
    id, project_id, title, objective, context_json, priority, status,
    created_by, created_at, updated_at, attempts, readiness, size, risk,
    suggested_actor, verification_needed
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
    [
      'legacy-task',
      'legacy-project',
      'Legacy task',
      'Migrate without loss.',
      '{}',
      'normal',
      invalidKind == 'status' ? 'invented' : 'pending',
      'ui',
      invalidKind == 'createdReal' ? 1.5 : 1,
      1,
      invalidKind == 'attemptsText'
          ? 'text'
          : invalidKind == 'attemptsReal'
          ? 1.5
          : 0,
      'ready',
      'medium',
      'low_code',
      'user',
      'none',
    ],
  );
  if (invalidKind == 'orphanStage') {
    raw.execute(
      'INSERT INTO work_items (id, stage_id, title, created_at) VALUES (?, ?, ?, ?)',
      ['orphan-stage-work', 'missing-stage', 'Orphan stage', 1],
    );
    raw.execute('UPDATE llm_task_queue SET work_item_id = ?', [
      'orphan-stage-work',
    ]);
  } else if (invalidKind == 'contextBlob') {
    raw.execute("UPDATE llm_task_queue SET context_json = x'7B7D'");
  } else if (invalidKind == 'contextArray') {
    raw.execute("UPDATE llm_task_queue SET context_json = '[1]'");
  } else if (invalidKind == 'contextScalar') {
    raw.execute("UPDATE llm_task_queue SET context_json = '1'");
  } else if (invalidKind == 'contextNull') {
    raw.execute("UPDATE llm_task_queue SET context_json = 'null'");
  } else if (invalidKind == 'resultArray') {
    raw.execute('''UPDATE llm_task_queue SET status = 'completed',
      leased_by = 'worker', leased_at = 2, attempts = 1,
      result_json = '[1]', completed_at = 3, updated_at = 3''');
  } else if (invalidKind == 'requiredBlob') {
    raw.execute("UPDATE llm_task_queue SET title = x'61'");
  } else if (invalidKind == 'nullableBlob') {
    raw.execute("UPDATE llm_task_queue SET next_action = x'61'");
  } else if (invalidKind == 'chronology') {
    raw.execute('''UPDATE llm_task_queue SET status = 'leased',
      leased_by = 'worker', leased_at = 0, lease_expires_at = 3,
      attempts = 1, updated_at = 3''');
  } else if (invalidKind == 'invalidLeaseState') {
    raw.execute("UPDATE llm_task_queue SET status = 'leased'");
  }
  raw.userVersion = 25;
  raw.dispose();
  return (directory: directory, file: file);
}
