import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// Simulates a real schema-22 database (documents table without deleted_at)
/// and verifies the current upgrade applies v23 soft delete while preserving rows.
/// Follows the on-disk rewrite pattern from timestamp_unit_contract_test.
void main() {
  test('v22 database gains documents.deleted_at on upgrade to v24', () async {
    final temp = await Directory.systemTemp.createTemp('atlas_schema23_');
    final path = p.join(temp.path, 'migration.sqlite');
    try {
      // Create a current-schema database with one document row.
      final initial = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        await initial.customStatement('''
          INSERT INTO documents (
            id, title, original_filename, status, created_at, updated_at
          ) VALUES (
            'doc-legacy', 'Legacy doc', 'legacy.txt', 'imported',
            1752600000, 1752600000
          )
        ''');
      } finally {
        await initial.close();
      }

      // Rewrite it into schema-22 shape: drop the deleted_at column (and its
      // timestamp guard triggers, which reference the column) and wind the
      // user_version back to 22.
      final legacy = sqlite3.sqlite3.open(path);
      try {
        for (final name in [
          'guard_documents_deleted_at_epoch_seconds_insert',
          'guard_documents_deleted_at_epoch_seconds_update',
        ]) {
          legacy.execute('DROP TRIGGER IF EXISTS "$name"');
        }
        legacy.execute('ALTER TABLE documents DROP COLUMN deleted_at');
        legacy.execute('PRAGMA user_version = 22');
      } finally {
        legacy.dispose();
      }

      // Sanity: the simulated v22 copy really lacks the column.
      final before = sqlite3.sqlite3.open(path);
      try {
        final columns = before
            .select('PRAGMA table_info(documents)')
            .map((row) => row['name'] as String)
            .toList();
        expect(columns, isNot(contains('deleted_at')));
        expect(before.userVersion, 22);
      } finally {
        before.dispose();
      }

      // Reopen through AppDb: the from < 23 step must add the column and the
      // old row must remain visible (deleted_at defaults to NULL).
      final migrated = AppDb.withExecutor(NativeDatabase(File(path)));
      try {
        final docs = await migrated.watchDocuments().first;
        expect(docs.map((d) => d.id), ['doc-legacy']);
        expect(docs.single.deletedAt, isNull);

        await migrated.softDeleteDocument('doc-legacy');
        expect(await migrated.watchDocuments().first, isEmpty);
        await migrated.restoreDocument('doc-legacy');
        expect(await migrated.watchDocuments().first, hasLength(1));
      } finally {
        await migrated.close();
      }

      final after = sqlite3.sqlite3.open(path);
      try {
        final columns = after
            .select('PRAGMA table_info(documents)')
            .map((row) => row['name'] as String)
            .toList();
        expect(columns, contains('deleted_at'));
        expect(after.userVersion, 26);
        expect(after.select('PRAGMA quick_check').first.values.first, 'ok');
      } finally {
        after.dispose();
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
