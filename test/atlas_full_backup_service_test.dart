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
    final progress = <AtlasFullBackupProgress>[];
    final result = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups')),
      onProgress: progress.add,
    );

    expect(await result.bundle.exists(), isTrue);
    expect(result.bundle.path, isNot(endsWith('.incomplete')));
    expect(
      await File(p.join(result.bundle.path, 'backup_complete.json')).exists(),
      isTrue,
    );
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
    expect(
      progress.map((update) => update.phase),
      containsAll([
        AtlasFullBackupPhase.snapshotting,
        AtlasFullBackupPhase.copyingFiles,
        AtlasFullBackupPhase.writingManifest,
        AtlasFullBackupPhase.validating,
        AtlasFullBackupPhase.complete,
      ]),
    );
    expect(progress.last.copiedFiles, 1);
    expect(progress.last.totalFiles, 1);
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

  test('validation rejects a bundle without its completion marker', () async {
    final result = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups')),
    );
    await File(p.join(result.bundle.path, 'backup_complete.json')).delete();

    final validation = await service().validateBundle(result.bundle);

    expect(validation.isValid, isFalse);
    expect(validation.errors, contains('backup_complete.json is missing.'));
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

  test(
    'restores a verified bundle into staging without touching live data',
    () async {
      final backup = await service().createBundle(
        Directory(p.join(tempDir.path, 'backups')),
      );
      final liveDatabase = sqlite3.open(sourceDatabase.path);
      liveDatabase.execute("UPDATE projects SET title = 'Live state changed';");
      liveDatabase.dispose();

      final restored = await service().restoreToStaging(
        backup.bundle,
        Directory(p.join(tempDir.path, 'restores')),
      );

      expect(restored.validation.isValid, isTrue);
      expect(await restored.bundle.exists(), isTrue);
      expect(restored.bundle.path, isNot(endsWith('.incomplete')));
      expect(
        await File(
          p.join(restored.bundle.path, 'backup_complete.json'),
        ).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(restored.bundle.path, 'files', 'atlas_documents', 'brief.txt'),
        ).readAsString(),
        'This is app-owned content.',
      );
      final restoredDatabase = sqlite3.open(
        p.join(restored.bundle.path, 'database', 'project_atlas.sqlite'),
        mode: OpenMode.readOnly,
      );
      expect(
        restoredDatabase.select('SELECT title FROM projects;').single['title'],
        'Atlas',
      );
      restoredDatabase.dispose();
      final currentLive = sqlite3.open(
        sourceDatabase.path,
        mode: OpenMode.readOnly,
      );
      expect(
        currentLive.select('SELECT title FROM projects;').single['title'],
        'Live state changed',
      );
      currentLive.dispose();
    },
  );

  test('refuses to restore a corrupted bundle', () async {
    final backup = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups')),
    );
    await File(
      p.join(backup.bundle.path, 'files', 'atlas_documents', 'brief.txt'),
    ).writeAsString('tampered');
    final restoreRoot = Directory(p.join(tempDir.path, 'restores'));

    await expectLater(
      service().restoreToStaging(backup.bundle, restoreRoot),
      throwsA(isA<AtlasFullBackupException>()),
    );
    expect(await restoreRoot.exists(), isFalse);
  });
}
