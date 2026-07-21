import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/atlas_full_backup_service.dart';
import 'package:project_atlas/shared/atlas_owned_file_snapshot_coordinator.dart';
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
    expect(manifest['snapshotContract'], atlasFullBackupSnapshotContract);
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

  test(
    'database and owned files stay at one point while concurrent mutations wait',
    () async {
      final mediaDir = Directory(p.join(tempDir.path, 'project_media'));
      await mediaDir.create(recursive: true);
      final mediaFile = File(p.join(mediaDir.path, 'cover.txt'));
      await mediaFile.writeAsString('old media');
      final coordinator = AtlasOwnedFileSnapshotCoordinator();
      final snapshotReached = Completer<void>();
      final releaseSnapshot = Completer<void>();
      final guardedService = AtlasFullBackupService(
        sourceDatabase: sourceDatabase,
        appOwnedRoots: {
          'atlas_documents': documentsDir,
          'project_media': mediaDir,
        },
        clock: () => DateTime.utc(2026, 7, 20, 16),
        random: Random(8),
        snapshotCoordinator: coordinator,
        snapshotStepHook: (step) async {
          if (step == 'database-snapshotted') {
            snapshotReached.complete();
            await releaseSnapshot.future;
          }
        },
      );

      final backupFuture = guardedService.createBundle(
        Directory(p.join(tempDir.path, 'backups')),
      );
      await snapshotReached.future;
      var mutationEntered = false;
      final mutationFuture = coordinator.runMutation(() async {
        mutationEntered = true;
        final liveDatabase = sqlite3.open(sourceDatabase.path);
        liveDatabase.execute("UPDATE projects SET title = 'New Atlas';");
        liveDatabase.dispose();
        await File(
          p.join(documentsDir.path, 'brief.txt'),
        ).writeAsString('new document');
        await mediaFile.writeAsString('new media');
      });
      await Future<void>.delayed(Duration.zero);
      expect(mutationEntered, isFalse);

      releaseSnapshot.complete();
      final backup = await backupFuture;
      await mutationFuture;

      final snapshotDatabase = sqlite3.open(
        p.join(backup.bundle.path, 'database', 'project_atlas.sqlite'),
        mode: OpenMode.readOnly,
      );
      expect(
        snapshotDatabase.select('SELECT title FROM projects;').single['title'],
        'Atlas',
      );
      snapshotDatabase.dispose();
      expect(
        await File(
          p.join(backup.bundle.path, 'files', 'atlas_documents', 'brief.txt'),
        ).readAsString(),
        'This is app-owned content.',
      );
      expect(
        await File(
          p.join(backup.bundle.path, 'files', 'project_media', 'cover.txt'),
        ).readAsString(),
        'old media',
      );
      expect(
        await File(p.join(documentsDir.path, 'brief.txt')).readAsString(),
        'new document',
      );
      expect(await mediaFile.readAsString(), 'new media');
    },
  );

  test('backup waits for an active owned-file mutation to finish', () async {
    final coordinator = AtlasOwnedFileSnapshotCoordinator();
    final mutationEntered = Completer<void>();
    final releaseMutation = Completer<void>();
    final mutationFuture = coordinator.runMutation(() async {
      final liveDatabase = sqlite3.open(sourceDatabase.path);
      liveDatabase.execute("UPDATE projects SET title = 'Coordinated Atlas';");
      liveDatabase.dispose();
      await File(
        p.join(documentsDir.path, 'brief.txt'),
      ).writeAsString('coordinated document');
      mutationEntered.complete();
      await releaseMutation.future;
    });
    await mutationEntered.future;
    var backupEntered = false;
    final guardedService = AtlasFullBackupService(
      sourceDatabase: sourceDatabase,
      appOwnedRoots: {'atlas_documents': documentsDir},
      clock: () => DateTime.utc(2026, 7, 20, 16),
      random: Random(9),
      snapshotCoordinator: coordinator,
      snapshotStepHook: (step) async {
        if (step == 'owned-files-locked') backupEntered = true;
      },
    );
    final backupFuture = guardedService.createBundle(
      Directory(p.join(tempDir.path, 'backups')),
    );
    await Future<void>.delayed(Duration.zero);
    expect(backupEntered, isFalse);

    releaseMutation.complete();
    await mutationFuture;
    final backup = await backupFuture;

    final snapshotDatabase = sqlite3.open(
      p.join(backup.bundle.path, 'database', 'project_atlas.sqlite'),
      mode: OpenMode.readOnly,
    );
    expect(
      snapshotDatabase.select('SELECT title FROM projects;').single['title'],
      'Coordinated Atlas',
    );
    snapshotDatabase.dispose();
    expect(
      await File(
        p.join(backup.bundle.path, 'files', 'atlas_documents', 'brief.txt'),
      ).readAsString(),
      'coordinated document',
    );
  });

  test('fails closed when an out-of-band file changes during copy', () async {
    var mutated = false;
    final guardedService = AtlasFullBackupService(
      sourceDatabase: sourceDatabase,
      appOwnedRoots: {'atlas_documents': documentsDir},
      clock: () => DateTime.utc(2026, 7, 20, 16),
      random: Random(10),
      snapshotCoordinator: AtlasOwnedFileSnapshotCoordinator(),
      snapshotStepHook: (step) async {
        if (!mutated && step.startsWith('after-copy:atlas_documents:')) {
          mutated = true;
          await File(
            p.join(documentsDir.path, 'brief.txt'),
          ).writeAsString('out-of-band change');
        }
      },
    );

    await expectLater(
      guardedService.createBundle(Directory(p.join(tempDir.path, 'backups'))),
      throwsA(
        isA<AtlasFullBackupException>().having(
          (error) => error.message,
          'message',
          contains('changed while it was being copied'),
        ),
      ),
    );
    expect(mutated, isTrue);
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

  test(
    'canonical round trip matches the completed backup in staging',
    () async {
      final backup = await service().createBundle(
        Directory(p.join(tempDir.path, 'backups')),
      );

      final report = await service().verifyRoundTrip(
        backup.bundle,
        Directory(p.join(tempDir.path, 'round-trip')),
      );

      expect(report.isCanonical, isTrue);
      expect(report.sourceFingerprint, report.stagedFingerprint);
      expect(report.sourceValidation.isValid, isTrue);
      expect(report.stagedValidation.isValid, isTrue);
      expect(await report.stagedBundle.exists(), isTrue);
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
