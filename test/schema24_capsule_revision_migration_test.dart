import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/project_capsule_truth_service.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

void main() {
  test('v23 database gains a preserved Capsule truth baseline', () async {
    final temp = await Directory.systemTemp.createTemp('atlas_schema24_');
    final path = p.join(temp.path, 'migration.sqlite');
    try {
      final initial = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        await initial.createProject(
          'atlas',
          'Project Atlas',
          DateTime.utc(2026),
        );
        await initial.updateProjectMeta('atlas', {
          'desiredOutcome': 'Preserve this accepted project outcome.',
          'description':
              'Imported from the Local Operations Registry.\n'
              'Local path: C:\\private\\atlas\n'
              'Classification: software\n'
              'Git root: C:\\private\\atlas',
          'scopeIncluded': 'Local project root: C:\\private\\atlas',
          'scopeExcluded': 'Capsule truth migration.',
        });
      } finally {
        await initial.close();
      }

      final legacy = sqlite3.sqlite3.open(path);
      try {
        legacy.execute('DROP TABLE project_capsule_ledger_checkpoints');
        legacy.execute('DROP TABLE project_capsule_revisions');
        legacy.execute('PRAGMA user_version = 23');
      } finally {
        legacy.dispose();
      }

      final migrated = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        expect(migrated.schemaVersion, 27);
        final project = await migrated.getProjectFull('atlas');
        final truth = await ProjectCapsuleTruthService(migrated).load('atlas');
        final revisions = await ProjectCapsuleTruthService(
          migrated,
        ).listRevisions('atlas');

        expect(
          project!.desiredOutcome,
          'Preserve this accepted project outcome.',
        );
        expect(truth!.headMatchesCurrent, isTrue);
        expect(truth.revisionNumber, 1);
        expect(revisions.single.sourceKind, 'migration_baseline');
        expect(
          revisions.single.truth.scopeExcluded,
          'Capsule truth migration.',
        );
        expect(revisions.single.truth.scopeIncluded, isNull);
        expect(
          revisions.single.truth.description,
          'Imported from the Local Operations Registry.\n'
          'Classification: software',
        );
        expect(
          revisions.single.truth.toJson().toString(),
          isNot(contains('C:\\private\\atlas')),
        );
      } finally {
        await migrated.close();
      }

      final after = sqlite3.sqlite3.open(path);
      try {
        expect(after.userVersion, 27);
        final checkpoint = after.select(
          'SELECT head_revision_number, revision_count, dirty '
          "FROM project_capsule_ledger_checkpoints WHERE project_id='atlas'",
        );
        expect(checkpoint.single['head_revision_number'], 1);
        expect(checkpoint.single['revision_count'], 1);
        expect(checkpoint.single['dirty'], 0);
        expect(
          after
              .select(
                "SELECT name FROM sqlite_master WHERE type='index' "
                "AND name='idx_project_capsule_revisions_head'",
              )
              .length,
          1,
        );
        expect(
          after
              .select(
                "SELECT name FROM sqlite_master WHERE type='trigger' "
                "AND name='dirty_project_capsule_checkpoint_insert'",
              )
              .length,
          1,
        );
        expect(
          after
              .select(
                "SELECT name FROM sqlite_master WHERE type='trigger' "
                "AND name='guard_project_capsule_revisions_update'",
              )
              .length,
          1,
        );
        expect(after.select('PRAGMA quick_check').first.values.first, 'ok');
      } finally {
        after.dispose();
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('v24 migration fails closed for a malformed existing ledger', () async {
    final temp = await Directory.systemTemp.createTemp('atlas_schema24_bad_');
    final path = p.join(temp.path, 'migration.sqlite');
    try {
      final initial = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        await initial.createProject(
          'atlas',
          'Project Atlas',
          DateTime.utc(2026),
        );
      } finally {
        await initial.close();
      }

      final legacy = sqlite3.sqlite3.open(path);
      try {
        legacy.execute('DROP TABLE project_capsule_revisions');
        legacy.execute('CREATE TABLE project_capsule_revisions (id TEXT)');
        legacy.execute('PRAGMA user_version = 23');
      } finally {
        legacy.dispose();
      }

      final migrated = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        await expectLater(
          migrated.getProjectFull('atlas'),
          throwsA(
            predicate<Object>(
              (error) => '$error'.contains('project_capsule_revisions'),
            ),
          ),
        );
      } finally {
        await migrated.close();
      }

      final after = sqlite3.sqlite3.open(path);
      try {
        expect(after.userVersion, 23);
      } finally {
        after.dispose();
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('v27 checkpoint migration fails closed on ledger corruption', () async {
    final temp = await Directory.systemTemp.createTemp('atlas_schema27_bad_');
    final path = p.join(temp.path, 'migration.sqlite');
    try {
      final initial = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        await initial.createProject(
          'atlas',
          'Project Atlas',
          DateTime.utc(2026),
        );
      } finally {
        await initial.close();
      }

      final legacy = sqlite3.sqlite3.open(path);
      try {
        legacy.execute('DROP TRIGGER guard_project_capsule_revisions_update');
        legacy.execute(
          "UPDATE project_capsule_revisions SET changed_fields_json = "
          "'{\"title\":{\"before\":null,\"after\":\"Forged\"}}'",
        );
        legacy.execute('DROP TABLE project_capsule_ledger_checkpoints');
        legacy.execute('PRAGMA user_version = 26');
      } finally {
        legacy.dispose();
      }

      final migrated = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        await expectLater(
          migrated.getProjectFull('atlas'),
          throwsA(
            predicate<Object>(
              (error) => '$error'.contains('failed verification'),
            ),
          ),
        );
      } finally {
        await migrated.close();
      }

      final after = sqlite3.sqlite3.open(path);
      try {
        expect(after.userVersion, 26);
      } finally {
        after.dispose();
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('v27 preserves multi-project multi-revision v26 ledgers', () async {
    final temp = await Directory.systemTemp.createTemp('atlas_schema27_many_');
    final path = p.join(temp.path, 'migration.sqlite');
    try {
      final initial = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        await initial.createProject('alpha', 'Alpha', DateTime.utc(2026));
        await initial.createProject('beta', 'Beta', DateTime.utc(2026));
        final service = ProjectCapsuleTruthService(initial);
        var alpha = (await service.load('alpha'))!.revisionId;
        alpha = (await service.acceptPatch(
          projectId: 'alpha',
          expectedRevisionId: alpha,
          fields: const {'description': 'Alpha second revision.'},
        )).state.revisionId;
        await service.acceptPatch(
          projectId: 'alpha',
          expectedRevisionId: alpha,
          fields: const {'desiredOutcome': 'Alpha third revision.'},
        );
        await service.acceptPatch(
          projectId: 'beta',
          expectedRevisionId: (await service.load('beta'))!.revisionId,
          fields: const {'description': 'Beta second revision.'},
        );
      } finally {
        await initial.close();
      }

      final legacy = sqlite3.sqlite3.open(path);
      try {
        _downgradeCheckpointSchema(legacy);
      } finally {
        legacy.dispose();
      }

      final migrated = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        final service = ProjectCapsuleTruthService(migrated);
        expect(migrated.schemaVersion, 27);
        expect(await service.auditLedger('alpha'), 3);
        expect(await service.auditLedger('beta'), 2);
        expect(
          (await service.load('alpha'))!.truth.desiredOutcome,
          'Alpha third revision.',
        );
        expect(
          (await service.load('beta'))!.truth.description,
          'Beta second revision.',
        );
        expect(
          await migrated.select(migrated.projectCapsuleLedgerCheckpoints).get(),
          hasLength(2),
        );
      } finally {
        await migrated.close();
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test(
    'v27 rolls back all checkpoints when one v26 ledger is corrupt',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'atlas_schema27_many_bad_',
      );
      final path = p.join(temp.path, 'migration.sqlite');
      try {
        final initial = AppDb.withExecutor(NativeDatabase(File(path)));
        try {
          await initial.createProject('good', 'Good', DateTime.utc(2026));
          await initial.createProject('bad', 'Bad', DateTime.utc(2026));
          final service = ProjectCapsuleTruthService(initial);
          for (final projectId in ['good', 'bad']) {
            await service.acceptPatch(
              projectId: projectId,
              expectedRevisionId: (await service.load(projectId))!.revisionId,
              fields: {'description': '$projectId second revision.'},
            );
          }
        } finally {
          await initial.close();
        }

        final legacy = sqlite3.sqlite3.open(path);
        try {
          legacy.execute('DROP TRIGGER guard_project_capsule_revisions_update');
          legacy.execute(
            "UPDATE project_capsule_revisions SET changed_fields_json = "
            "'{\"description\":{\"before\":null,\"after\":\"Forged\"}}' "
            "WHERE project_id = 'bad' AND revision_number = 2",
          );
          _downgradeCheckpointSchema(legacy);
        } finally {
          legacy.dispose();
        }

        final migrated = AppDb.withExecutor(NativeDatabase(File(path)));
        try {
          await expectLater(
            migrated.getProjectFull('good'),
            throwsA(
              predicate<Object>(
                (error) => '$error'.contains('failed verification'),
              ),
            ),
          );
        } finally {
          await migrated.close();
        }

        final after = sqlite3.sqlite3.open(path);
        try {
          expect(after.userVersion, 26);
          expect(
            after.select(
              "SELECT name FROM sqlite_master WHERE type='table' "
              "AND name='project_capsule_ledger_checkpoints'",
            ),
            isEmpty,
          );
          expect(
            after
                .select(
                  'SELECT COUNT(*) AS count FROM project_capsule_revisions',
                )
                .single['count'],
            4,
          );
        } finally {
          after.dispose();
        }
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}

void _downgradeCheckpointSchema(sqlite3.Database database) {
  for (final operation in ['insert', 'update', 'delete']) {
    database.execute(
      'DROP TRIGGER IF EXISTS dirty_project_capsule_checkpoint_$operation',
    );
  }
  database.execute('DROP TABLE project_capsule_ledger_checkpoints');
  database.execute('PRAGMA user_version = 26');
}
