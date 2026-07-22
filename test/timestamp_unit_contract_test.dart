import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/db/timestamp_contract.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

void main() {
  test(
    'schema v24 installs insert and update guards for every Drift timestamp',
    () async {
      final db = AppDb.withExecutor(NativeDatabase.memory());
      try {
        await db.customSelect('SELECT 1').get();
        final triggers = await db.customSelect('''
        SELECT name FROM sqlite_master
        WHERE type = 'trigger' AND name LIKE 'guard_%_epoch_seconds_%'
      ''').get();
        expect(triggers, hasLength(driftTimestampFields.length * 2));

        await db.createProject('project-ok', 'Valid', DateTime(2026, 7, 13));
        await db.customStatement(
          "UPDATE projects SET title = 'Still valid' WHERE id = 'project-ok'",
        );

        await expectLater(
          db.customStatement('''
          INSERT INTO event_log (id, timestamp, level, area, action)
          VALUES ('bad-ms', 1783971458113, 'info', 'test', 'bad')
        '''),
          throwsA(
            predicate(
              (error) => error.toString().contains(
                'timestamp_unit_violation:event_log.timestamp:'
                'expected_epoch_seconds',
              ),
            ),
          ),
        );
        await expectLater(
          db.customStatement('''
          UPDATE projects SET created_at = 1783971458113
          WHERE id = 'project-ok'
        '''),
          throwsA(
            predicate(
              (error) => error.toString().contains(
                'timestamp_unit_violation:projects.created_at:'
                'expected_epoch_seconds',
              ),
            ),
          ),
        );
        await expectLater(
          db.customStatement('''
          UPDATE projects SET created_at = '2026-07-13'
          WHERE id = 'project-ok'
        '''),
          throwsA(
            predicate(
              (error) => error.toString().contains('expected_epoch_seconds'),
            ),
          ),
        );

        // This compatibility table is intentionally millisecond-based and is
        // outside the Drift DateTime contract.
        await db.customStatement('''
        INSERT INTO project_git_remotes (
          id, project_id, provider, owner, repo, remote_url, checked_at
        ) VALUES (
          'remote-ms', 'project-ok', 'github', 'owner', 'repo',
          'https://example.invalid/repo', 1783971458113
        )
      ''');
        final checkedAt = await db
            .customSelect(
              "SELECT checked_at FROM project_git_remotes WHERE id = 'remote-ms'",
            )
            .getSingle();
        expect(checkedAt.read<int>('checked_at'), 1783971458113);
      } finally {
        await db.close();
      }
    },
  );

  test(
    'schema v24 repairs legacy milliseconds once and preserves custom ms',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'atlas_timestamp_v22_',
      );
      final path = p.join(temp.path, 'migration.sqlite');
      try {
        final initial = AppDb.withExecutor(NativeDatabase(File(path)));
        try {
          await initial.createProject(
            'legacy-project',
            'Legacy',
            DateTime(2026, 7, 13),
          );
          await initial.customStatement('''
          INSERT INTO project_git_remotes (
            id, project_id, provider, owner, repo, remote_url, checked_at
          ) VALUES (
            'legacy-remote', 'legacy-project', 'github', 'owner', 'repo',
            'https://example.invalid/repo', 1783971458113
          )
        ''');
        } finally {
          await initial.close();
        }

        final legacy = sqlite3.sqlite3.open(path);
        try {
          final triggerNames = legacy
              .select(
                "SELECT name FROM sqlite_master "
                "WHERE type='trigger' AND name LIKE 'guard_%_epoch_seconds_%'",
              )
              .map((row) => row['name'] as String)
              .toList();
          for (final name in triggerNames) {
            legacy.execute('DROP TRIGGER "$name"');
          }
          legacy.execute('''
          UPDATE projects SET created_at = 1783971458113
          WHERE id = 'legacy-project'
        ''');
          legacy.execute('''
          INSERT INTO event_log (id, timestamp, level, area, action)
          VALUES ('legacy-event', 1783971458113, 'info', 'test', 'legacy')
        ''');
          legacy.execute('PRAGMA user_version = 20');
        } finally {
          legacy.dispose();
        }

        Future<List<int>> openAndRead() async {
          final migrated = AppDb.withExecutor(NativeDatabase(File(path)));
          try {
            final row = await migrated.customSelect('''
            SELECT
              (SELECT created_at FROM projects
               WHERE id = 'legacy-project') AS project_time,
              (SELECT timestamp FROM event_log
               WHERE id = 'legacy-event') AS event_time,
              (SELECT checked_at FROM project_git_remotes
               WHERE id = 'legacy-remote') AS custom_time
          ''').getSingle();
            return [
              row.read<int>('project_time'),
              row.read<int>('event_time'),
              row.read<int>('custom_time'),
            ];
          } finally {
            await migrated.close();
          }
        }

        expect(await openAndRead(), [1783971458, 1783971458, 1783971458113]);
        expect(await openAndRead(), [1783971458, 1783971458, 1783971458113]);

        final verified = sqlite3.sqlite3.open(path);
        try {
          expect(
            verified.select('PRAGMA quick_check').first.values.first,
            'ok',
          );
          expect(verified.select('PRAGMA foreign_key_check'), isEmpty);
          expect(verified.userVersion, 26);
        } finally {
          verified.dispose();
        }
      } finally {
        await temp.delete(recursive: true);
      }
    },
    // This opens and closes a file-backed SQLite database twice. On constrained
    // Windows CI runners that can exceed the default 30-second test deadline
    // while the migration itself is still deterministic and bounded.
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
