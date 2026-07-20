import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/atlas_full_backup_service.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File sourceDatabase;
  late Directory documentsDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('atlas_full_backup_test_');
    sourceDatabase = File(p.join(tempDir.path, 'live', 'project_atlas.sqlite'));
    await sourceDatabase.parent.create(recursive: true);
    final database = sqlite3.open(sourceDatabase.path);
    database.execute('PRAGMA foreign_keys = ON;');
    database.execute(
      'CREATE TABLE projects (id TEXT PRIMARY KEY, title TEXT NOT NULL);',
    );
    database.execute(
      'CREATE TABLE work_items ('
      'id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), '
      'title TEXT NOT NULL);',
    );
    database.execute("INSERT INTO projects VALUES ('atlas', 'Atlas');");
    database.execute(
      "INSERT INTO work_items VALUES ('task-1', 'atlas', 'Snapshot safely');",
    );
    database.dispose();

    documentsDir = Directory(p.join(tempDir.path, 'atlas_documents'));
    await documentsDir.create(recursive: true);
    await File(
      p.join(documentsDir.path, 'brief.txt'),
    ).writeAsString('This is app-owned content.');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  AtlasFullBackupService service() => AtlasFullBackupService(
    sourceDatabase: sourceDatabase,
    appOwnedRoots: {'atlas_documents': documentsDir},
    clock: () => DateTime.utc(2026, 7, 20, 16),
    random: Random(7),
  );

  test('creates a validated online SQLite snapshot with owned files', () async {
    final result = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups')),
    );

    expect(await result.bundle.exists(), isTrue);
    expect(result.bundle.path, isNot(endsWith('.incomplete')));
    expect(
      await File(
        p.join(result.bundle.path, 'files', 'atlas_documents', 'brief.txt'),
      ).readAsString(),
      'This is app-owned content.',
    );

    final manifest =
        jsonDecode(
              await File(
                p.join(result.bundle.path, 'manifest.json'),
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(manifest['schema'], atlasFullBackupManifestSchema);
    expect(manifest['databaseSnapshot'], 'database/project_atlas.sqlite');
    expect(
      manifest['databaseInventory']['tables'],
      containsAll([
        {'name': 'projects', 'rowCount': 1},
        {'name': 'work_items', 'rowCount': 1},
      ]),
    );

    final validation = await service().validateBundle(result.bundle);
    expect(validation.isValid, isTrue, reason: validation.errors.join('\n'));
  });

  test('validation detects a tampered app-owned file', () async {
    final result = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups')),
    );
    final copiedDocument = File(
      p.join(result.bundle.path, 'files', 'atlas_documents', 'brief.txt'),
    );
    await copiedDocument.writeAsString('tampered');

    final validation = await service().validateBundle(result.bundle);

    expect(validation.isValid, isFalse);
    expect(
      validation.errors,
      contains(
        'Checksum mismatch: ${p.join('files', 'atlas_documents', 'brief.txt')}.',
      ),
    );
  });

  test('validation detects a tampered SQLite snapshot', () async {
    final result = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups')),
    );
    final snapshot = File(
      p.join(result.bundle.path, 'database', 'project_atlas.sqlite'),
    );
    final database = sqlite3.open(snapshot.path);
    database.execute("UPDATE projects SET title = 'Modified after backup';");
    database.dispose();

    final validation = await service().validateBundle(result.bundle);

    expect(validation.isValid, isFalse);
    expect(
      validation.errors,
      contains('Checksum mismatch: database/project_atlas.sqlite.'),
    );
  });
}
