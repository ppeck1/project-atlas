import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

const _trackedTables = <String>[
  'projects',
  'app_meta',
  'stages',
  'work_items',
  'work_item_tags',
  'drafts',
  'daily_reviews',
  'outbox_messages',
  'event_log',
  'documents',
  'document_links',
  'contacts',
  'project_people',
  'project_risks',
  'project_decisions',
  'tags',
  'project_tags',
  'project_media',
  'media_links',
  'project_registry',
  'project_observations',
  'project_scan_runs',
  'local_project_refresh_items',
  'project_git_remotes',
  'project_enrichment_runs',
  'project_enrichment_findings',
  'project_enrichment_steps',
  'project_enrichment_proposals',
  'llm_task_queue',
  'project_runtime_profiles',
  'project_runtime_runs',
];

const _workItemPlanningColumns = <String>[
  'readiness',
  'size',
  'risk',
  'suggested_actor',
  'verification_needed',
  'next_action',
  'planning_notes',
  'last_reviewed_at',
];

const _queuePlanningColumns = <String>[
  'readiness',
  'size',
  'risk',
  'suggested_actor',
  'verification_needed',
  'next_action',
  'blocker_reason',
  'planning_notes',
  'last_reviewed_at',
];

void main() {
  const sourcePath = String.fromEnvironment('ATLAS_SCHEMA21_SOURCE_DB');
  const evidencePath = String.fromEnvironment('ATLAS_SCHEMA21_EVIDENCE_PATH');
  const shouldRun = sourcePath != '';

  test(
    'real v1.3 schema 19 database migrates to schema 21',
    () async {
      final source = File(sourcePath);
      expect(source.existsSync(), isTrue, reason: source.path);

      final evidenceFile = evidencePath.trim().isEmpty
          ? null
          : File(evidencePath);
      final workDir = Directory(
        evidenceFile == null
            ? p.join(Directory.systemTemp.path, 'atlas_schema21_migration')
            : p.join(evidenceFile.parent.path, 'schema21_migration_work'),
      )..createSync(recursive: true);
      evidenceFile?.parent.createSync(recursive: true);

      final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final copyPath = p.join(
        workDir.path,
        '${p.basenameWithoutExtension(source.path)}_schema21_$stamp.sqlite',
      );
      // This test is normally skipped; progress prints make explicit release
      // runs diagnosable for large private DB copies.
      // ignore: avoid_print
      print('schema21 checkpoint: copying ${source.path}');
      await source.copy(copyPath);

      // ignore: avoid_print
      print('schema21 checkpoint: inspecting schema 19 copy');
      final before = _inspectSqlite(copyPath);
      expect(before.userVersion, 19);
      expect(
        before.hasColumns('work_items', _workItemPlanningColumns),
        isFalse,
      );

      // ignore: avoid_print
      print('schema21 checkpoint: opening copy through AppDb migration');
      final migrated = AppDb.withExecutor(NativeDatabase(File(copyPath)));
      try {
        await migrated.customSelect('SELECT 1').get();
      } finally {
        await migrated.close();
      }

      // ignore: avoid_print
      print('schema21 checkpoint: inspecting migrated schema 21 copy');
      final after = _inspectSqlite(copyPath);
      final rowCountsPreserved = <String, bool>{};
      for (final table in _trackedTables) {
        final beforeCount = before.rowCounts[table];
        if (beforeCount == null) continue;
        rowCountsPreserved[table] = after.rowCounts[table] == beforeCount;
      }

      final evidence = <String, Object?>{
        'schema': 'project_atlas_schema21_migration_checkpoint.v1',
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'source': _fileFacts(source),
        'migratedCopy': _fileFacts(File(copyPath)),
        'before': before.toJson(),
        'after': after.toJson(),
        'checks': {
          'sourceUserVersionIs19': before.userVersion == 19,
          'migratedUserVersionIs23': after.userVersion == 23,
          'workItemPlanningColumnsPresent': after.hasColumns(
            'work_items',
            _workItemPlanningColumns,
          ),
          'queuePlanningColumnsPresent': after.hasColumns(
            'llm_task_queue',
            _queuePlanningColumns,
          ),
          'existingRowCountsPreserved': rowCountsPreserved.values.every(
            (value) => value,
          ),
        },
      };
      evidence['passed'] = (evidence['checks'] as Map<String, Object?>).values
          .every((value) => value == true);

      if (evidenceFile != null) {
        await evidenceFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(evidence),
        );
      }

      expect(after.userVersion, 26);
      expect(after.hasColumns('work_items', _workItemPlanningColumns), isTrue);
      expect(after.hasColumns('documents', ['deleted_at']), isTrue);
      expect(after.hasColumns('llm_task_queue', _queuePlanningColumns), isTrue);
      expect(rowCountsPreserved.values, everyElement(isTrue));
    },
    skip: shouldRun
        ? false
        : 'Set --dart-define=ATLAS_SCHEMA21_SOURCE_DB=<real schema 19 DB>.',
  );
}

_SqliteSnapshot _inspectSqlite(String path) {
  final db = sqlite3.sqlite3.open(path);
  try {
    final userVersion =
        db.select('PRAGMA user_version').first.values.first as int;
    final tables =
        db
            .select("SELECT name FROM sqlite_master WHERE type = 'table'")
            .map((row) => row['name'] as String)
            .where((name) => !name.startsWith('sqlite_'))
            .toList()
          ..sort();
    final tableSet = tables.toSet();
    final columns = <String, List<String>>{};
    final rowCounts = <String, int?>{};
    for (final table in _trackedTables) {
      if (!tableSet.contains(table)) {
        rowCounts[table] = null;
        continue;
      }
      columns[table] = db
          .select('PRAGMA table_info("$table")')
          .map((row) => row['name'] as String)
          .toList(growable: false);
      rowCounts[table] =
          db.select('SELECT COUNT(*) AS count FROM "$table"').first['count']
              as int;
    }
    return _SqliteSnapshot(
      path: path,
      userVersion: userVersion,
      tables: tables,
      columns: columns,
      rowCounts: rowCounts,
    );
  } finally {
    db.dispose();
  }
}

Map<String, Object?> _fileFacts(File file) => {
  'path': file.path,
  'bytes': file.lengthSync(),
  'modifiedAt': file.lastModifiedSync().toUtc().toIso8601String(),
};

class _SqliteSnapshot {
  final String path;
  final int userVersion;
  final List<String> tables;
  final Map<String, List<String>> columns;
  final Map<String, int?> rowCounts;

  const _SqliteSnapshot({
    required this.path,
    required this.userVersion,
    required this.tables,
    required this.columns,
    required this.rowCounts,
  });

  bool hasColumns(String table, List<String> requiredColumns) {
    final present = columns[table]?.toSet() ?? const <String>{};
    return requiredColumns.every(present.contains);
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'userVersion': userVersion,
    'tableCount': tables.length,
    'tables': tables,
    'columns': columns,
    'rowCounts': rowCounts,
  };
}
