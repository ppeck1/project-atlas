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
        legacy.execute('DROP TABLE project_capsule_revisions');
        legacy.execute('PRAGMA user_version = 23');
      } finally {
        legacy.dispose();
      }

      final migrated = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        expect(migrated.schemaVersion, 24);
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
        expect(after.userVersion, 24);
        expect(
          after
              .select(
                "SELECT name FROM sqlite_master WHERE type='index' "
                "AND name='idx_project_capsule_revisions_head'",
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
}
