import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/atlas_full_backup_service.dart';
import 'package:project_atlas/services/recovery_artifact_lifecycle.dart';
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

  test('validation rejects an undeclared regular file', () async {
    final result = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups')),
    );
    await File(
      p.join(result.bundle.path, 'undeclared.txt'),
    ).writeAsString('not in the manifest');

    final validation = await service().validateBundle(result.bundle);

    expect(validation.isValid, isFalse);
    expect(
      validation.errors,
      contains('Bundle contains an undeclared file: undeclared.txt.'),
    );
  });

  test('validation rejects a case-insensitive inventory alias', () async {
    final result = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups')),
    );
    final original = File(
      p.join(result.bundle.path, 'files', 'atlas_documents', 'brief.txt'),
    );
    final alias = File(
      p.join(result.bundle.path, 'files', 'atlas_documents', 'BRIEF.TXT'),
    );
    try {
      await alias.writeAsString('alias');
    } on FileSystemException {
      // Case-insensitive hosts cannot materialize both aliases; the policy is
      // exercised by this fixture on case-sensitive CI hosts.
      return;
    }
    if (await original.readAsString() == 'alias') return;

    final validation = await service().validateBundle(result.bundle);

    expect(validation.isValid, isFalse);
    expect(
      validation.errors.any(
        (error) => error.contains('duplicate canonical path'),
      ),
      isTrue,
    );
  });

  test(
    'validation requires one correctly typed database snapshot descriptor',
    () async {
      for (final omitDescriptor in [true, false]) {
        final suffix = omitDescriptor ? 'omitted' : 'mis-kinded';
        final result = await service().createBundle(
          Directory(p.join(tempDir.path, 'backups-$suffix')),
        );
        final manifest = await _readManifest(result.bundle);
        final files = manifest['files'] as List<dynamic>;
        final databaseDescriptor = files
            .whereType<Map<String, dynamic>>()
            .singleWhere((entry) => entry['kind'] == 'sqlite_snapshot');
        if (omitDescriptor) {
          files.remove(databaseDescriptor);
        } else {
          databaseDescriptor['kind'] = 'app_owned_file';
        }
        await _writeManifestAndRefreshCompletion(result.bundle, manifest);

        final validation = await service().validateBundle(result.bundle);

        expect(
          validation.isValid,
          isFalse,
          reason:
              '$suffix unexpectedly passed:\n${validation.errors.join('\n')}',
        );
        expect(
          validation.errors,
          contains(
            'Manifest must contain exactly one sqlite_snapshot file descriptor.',
          ),
        );
      }
    },
  );

  test('validation rejects malformed or incomplete file descriptors', () async {
    final cases = <({String name, void Function(Map<String, dynamic>) mutate})>[
      (name: 'missing-bytes', mutate: (entry) => entry.remove('bytes')),
      (name: 'negative-bytes', mutate: (entry) => entry['bytes'] = -1),
      (
        name: 'uppercase-sha',
        mutate: (entry) =>
            entry['sha256'] = (entry['sha256'] as String).toUpperCase(),
      ),
      (
        name: 'noncanonical-path',
        mutate: (entry) => entry['path'] = (entry['path'] as String)
            .replaceFirst('files', 'files//'),
      ),
      (name: 'unknown-field', mutate: (entry) => entry['unexpected'] = true),
    ];

    for (final testCase in cases) {
      final result = await service().createBundle(
        Directory(p.join(tempDir.path, 'backups-${testCase.name}')),
      );
      final manifest = await _readManifest(result.bundle);
      final descriptor = (manifest['files'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .singleWhere((entry) => entry['kind'] == 'app_owned_file');
      testCase.mutate(descriptor);
      await _writeManifestAndRefreshCompletion(result.bundle, manifest);

      final validation = await service().validateBundle(result.bundle);

      expect(
        validation.isValid,
        isFalse,
        reason:
            '${testCase.name} unexpectedly passed:\n${validation.errors.join('\n')}',
      );
    }
  });

  test('validation rejects missing and ambiguous declared inventory', () async {
    final missing = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups-missing')),
    );
    await File(
      p.join(missing.bundle.path, 'files', 'atlas_documents', 'brief.txt'),
    ).delete();
    final missingValidation = await service().validateBundle(missing.bundle);
    expect(missingValidation.isValid, isFalse);
    expect(
      missingValidation.errors.any(
        (error) => error.contains('Manifest file is missing'),
      ),
      isTrue,
    );

    for (final aliasCase in [false, true]) {
      final suffix = aliasCase ? 'case-alias' : 'duplicate';
      final result = await service().createBundle(
        Directory(p.join(tempDir.path, 'backups-$suffix')),
      );
      final manifest = await _readManifest(result.bundle);
      final files = manifest['files']! as List<dynamic>;
      final document = Map<String, dynamic>.from(
        files.cast<Map<String, dynamic>>().singleWhere(
          (entry) => entry['kind'] == 'app_owned_file',
        ),
      );
      if (aliasCase) {
        document['path'] = (document['path']! as String).toUpperCase();
      }
      files.add(document);
      await _writeManifestAndRefreshCompletion(result.bundle, manifest);

      final validation = await service().validateBundle(result.bundle);
      expect(validation.isValid, isFalse, reason: suffix);
      expect(
        validation.errors.any((error) => error.contains('duplicate file path')),
        isTrue,
        reason: suffix,
      );
    }

    final mismatched = await service().createBundle(
      Directory(p.join(tempDir.path, 'backups-db-pointer')),
    );
    final manifest = await _readManifest(mismatched.bundle);
    final files = manifest['files']! as List<dynamic>;
    manifest['databaseSnapshot'] = files
        .cast<Map<String, dynamic>>()
        .singleWhere((entry) => entry['kind'] == 'app_owned_file')['path'];
    await _writeManifestAndRefreshCompletion(mismatched.bundle, manifest);
    final validation = await service().validateBundle(mismatched.bundle);
    expect(validation.isValid, isFalse);
    expect(
      validation.errors,
      contains('Manifest sqlite_snapshot path must match databaseSnapshot.'),
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
      expect(restored.validation.bundle.path, restored.bundle.path);
      expect(restored.bundle.path, isNot(contains('.atlas-incomplete-')));
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

  test(
    'public validation rejects malformed and foreign lifecycle markers',
    () async {
      for (final malformed in [true, false]) {
        final result = await service().createBundle(
          Directory(
            p.join(
              tempDir.path,
              malformed ? 'malformed-public' : 'foreign-public',
            ),
          ),
        );
        final marker = File(
          p.join(result.bundle.path, recoveryArtifactLifecycleMarkerFile),
        );
        if (malformed) {
          await marker.writeAsString('{not-json');
        } else {
          await marker.writeAsString(
            jsonEncode({
              'schema': recoveryArtifactLifecycleSchema,
              'kind': 'full_backup',
              'state': 'incomplete',
              'operationId': '99999999999999999999999999999999',
              'createdAt': '2026-07-23T00:00:00.000Z',
              'updatedAt': '2026-07-23T00:00:00.000Z',
            }),
          );
        }

        final validation = await service().validateBundle(result.bundle);

        expect(validation.isValid, isFalse, reason: 'malformed=$malformed');
        expect(
          validation.errors,
          contains(
            'Bundle contains an undeclared file: '
            '$recoveryArtifactLifecycleMarkerFile.',
          ),
        );
      }
    },
  );

  test('mid-copy failure deletes partial backup without completion', () async {
    final backups = Directory(p.join(tempDir.path, 'backups'));
    final primary = StateError('primary mid-copy failure');
    final guarded = AtlasFullBackupService(
      sourceDatabase: sourceDatabase,
      appOwnedRoots: {'atlas_documents': documentsDir},
      clock: () => DateTime.utc(2026, 7, 23),
      random: Random(71),
      snapshotStepHook: (step) async {
        if (step.startsWith('after-copy:atlas_documents:')) throw primary;
      },
    );

    await expectLater(guarded.createBundle(backups), throwsA(same(primary)));

    expect(await backups.exists(), isTrue);
    expect(await backups.list().toList(), isEmpty);
  });

  test('post-completion-marker failure deletes the backup', () async {
    final backups = Directory(p.join(tempDir.path, 'backups'));
    final primary = StateError('primary post-marker failure');
    final guarded = AtlasFullBackupService(
      sourceDatabase: sourceDatabase,
      appOwnedRoots: {'atlas_documents': documentsDir},
      clock: () => DateTime.utc(2026, 7, 23),
      random: Random(72),
      snapshotStepHook: (step) async {
        if (step == 'completion-marker-written') throw primary;
      },
    );

    await expectLater(guarded.createBundle(backups), throwsA(same(primary)));

    expect(await backups.list().toList(), isEmpty);
  });

  test(
    'internal promotion refuses tampered lifecycle ownership and removes completion',
    () async {
      for (final malformed in [true, false]) {
        final backups = Directory(
          p.join(
            tempDir.path,
            malformed ? 'malformed-internal' : 'foreign-internal',
          ),
        );
        final guarded = AtlasFullBackupService(
          sourceDatabase: sourceDatabase,
          appOwnedRoots: {'atlas_documents': documentsDir},
          clock: () => DateTime.utc(2026, 7, 23),
          random: Random(malformed ? 721 : 722),
          snapshotStepHook: (step) async {
            if (step != 'before-completion-marker') return;
            final artifact =
                (await backups
                            .list()
                            .where((entry) => entry is Directory)
                            .toList())
                        .single
                    as Directory;
            final marker = File(
              p.join(artifact.path, recoveryArtifactLifecycleMarkerFile),
            );
            if (malformed) {
              await marker.writeAsString('{not-json');
            } else {
              final decoded =
                  jsonDecode(await marker.readAsString())
                      as Map<String, dynamic>;
              decoded['operationId'] = '99999999999999999999999999999999';
              await marker.writeAsString(jsonEncode(decoded));
            }
          },
        );

        await expectLater(
          guarded.createBundle(backups),
          throwsA(isA<AtlasFullBackupException>()),
        );

        final retained =
            (await backups.list().where((entry) => entry is Directory).toList())
                    .single
                as Directory;
        expect(
          await File(p.join(retained.path, 'backup_complete.json')).exists(),
          isFalse,
          reason: 'malformed=$malformed',
        );
        expect(
          await File(
            p.join(retained.path, recoveryArtifactLifecycleMarkerFile),
          ).exists(),
          isTrue,
        );
        expect((await guarded.validateBundle(retained)).isValid, isFalse);
      }
    },
  );

  test(
    'cleanup failure retains failed marker and preserves post-marker error',
    () async {
      final backups = Directory(p.join(tempDir.path, 'backups'));
      final primary = StateError('primary retained post-marker failure');
      final guarded = AtlasFullBackupService(
        sourceDatabase: sourceDatabase,
        appOwnedRoots: {'atlas_documents': documentsDir},
        clock: () => DateTime.utc(2026, 7, 23),
        random: Random(73),
        snapshotStepHook: (step) async {
          if (step == 'completion-marker-written') throw primary;
        },
        artifactLifecycle: RecoveryArtifactLifecycle(
          clock: () => DateTime.utc(2026, 7, 23),
          deleteArtifact: (_) async {
            throw const FileSystemException('injected cleanup denial');
          },
        ),
      );

      await expectLater(guarded.createBundle(backups), throwsA(same(primary)));

      final retained = (await backups.list().toList()).single as Directory;
      final incompleteFile = File(
        p.join(retained.path, recoveryArtifactLifecycleMarkerFile),
      );
      final failedFile = File(
        p.join(retained.path, recoveryArtifactFailedMarkerFile),
      );
      final incomplete = await RecoveryArtifactMarker.read(incompleteFile);
      final failed = await RecoveryArtifactMarker.read(failedFile);
      expect(incomplete.kind, RecoveryArtifactKind.fullBackup);
      expect(incomplete.state, RecoveryArtifactState.incomplete);
      expect(failed.kind, RecoveryArtifactKind.fullBackup);
      expect(failed.state, RecoveryArtifactState.failed);
      expect(failed.operationId, incomplete.operationId);
      final markerText =
          '${await incompleteFile.readAsString()}'
          '${await failedFile.readAsString()}';
      expect(markerText, isNot(contains(primary.message)));
      expect(markerText, isNot(contains('cleanup denial')));
      expect(
        await File(p.join(retained.path, 'backup_complete.json')).exists(),
        isFalse,
      );
      expect((await guarded.validateBundle(retained)).isValid, isFalse);
    },
  );

  test(
    'restore mid-entry failure deletes staging and leaves source and live unchanged',
    () async {
      final backup = await service().createBundle(
        Directory(p.join(tempDir.path, 'backups')),
      );
      final sourceMarker = File(
        p.join(backup.bundle.path, 'backup_complete.json'),
      );
      final sourceMarkerBefore = await sourceMarker.readAsBytes();
      final liveBefore = await sourceDatabase.readAsBytes();
      final documentBefore = await File(
        p.join(documentsDir.path, 'brief.txt'),
      ).readAsBytes();
      final restores = Directory(p.join(tempDir.path, 'restores-mid-entry'));
      final primary = StateError('primary restore mid-entry failure');
      final guarded = AtlasFullBackupService(
        sourceDatabase: sourceDatabase,
        appOwnedRoots: {'atlas_documents': documentsDir},
        clock: () => DateTime.utc(2026, 7, 23),
        random: Random(741),
        snapshotStepHook: (step) async {
          if (step.startsWith('staging-entry-copied:')) throw primary;
        },
      );

      await expectLater(
        guarded.restoreToStaging(backup.bundle, restores),
        throwsA(same(primary)),
      );

      expect(await restores.exists(), isTrue);
      expect(await restores.list().toList(), isEmpty);
      expect(await sourceMarker.readAsBytes(), sourceMarkerBefore);
      expect(await sourceDatabase.readAsBytes(), liveBefore);
      expect(
        await File(p.join(documentsDir.path, 'brief.txt')).readAsBytes(),
        documentBefore,
      );
      expect((await service().validateBundle(backup.bundle)).isValid, isTrue);
    },
  );

  test(
    'restore post-marker failure deletes staging and leaves source and live unchanged',
    () async {
      final backup = await service().createBundle(
        Directory(p.join(tempDir.path, 'backups')),
      );
      final sourceMarker = File(
        p.join(backup.bundle.path, 'backup_complete.json'),
      );
      final sourceMarkerBefore = await sourceMarker.readAsBytes();
      final liveBefore = await sourceDatabase.readAsBytes();
      final documentBefore = await File(
        p.join(documentsDir.path, 'brief.txt'),
      ).readAsBytes();
      final restores = Directory(p.join(tempDir.path, 'restores'));
      final primary = StateError('primary restore post-marker failure');
      final guarded = AtlasFullBackupService(
        sourceDatabase: sourceDatabase,
        appOwnedRoots: {'atlas_documents': documentsDir},
        clock: () => DateTime.utc(2026, 7, 23),
        random: Random(74),
        snapshotStepHook: (step) async {
          if (step == 'staging-completion-marker-copied') throw primary;
        },
      );

      await expectLater(
        guarded.restoreToStaging(backup.bundle, restores),
        throwsA(same(primary)),
      );

      expect(await restores.list().toList(), isEmpty);
      expect(await sourceMarker.readAsBytes(), sourceMarkerBefore);
      expect(await sourceDatabase.readAsBytes(), liveBefore);
      expect(
        await File(p.join(documentsDir.path, 'brief.txt')).readAsBytes(),
        documentBefore,
      );
      expect((await service().validateBundle(backup.bundle)).isValid, isTrue);
    },
  );

  test(
    'restore post-marker cleanup denial retains typed failure without mutating sources',
    () async {
      final backup = await service().createBundle(
        Directory(p.join(tempDir.path, 'backups')),
      );
      final sourceBackupBefore = <String, List<int>>{};
      await for (final entity in backup.bundle.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          sourceBackupBefore[p.relative(
            entity.path,
            from: backup.bundle.path,
          )] = await entity
              .readAsBytes();
        }
      }
      final liveBefore = await sourceDatabase.readAsBytes();
      final ownedFile = File(p.join(documentsDir.path, 'brief.txt'));
      final ownedBefore = await ownedFile.readAsBytes();
      final restores = Directory(p.join(tempDir.path, 'restores-retained'));
      final primary = StateError(
        'primary retained restore post-marker failure',
      );
      final guarded = AtlasFullBackupService(
        sourceDatabase: sourceDatabase,
        appOwnedRoots: {'atlas_documents': documentsDir},
        clock: () => DateTime.utc(2026, 7, 23),
        random: Random(742),
        snapshotStepHook: (step) async {
          if (step == 'staging-completion-marker-copied') throw primary;
        },
        artifactLifecycle: RecoveryArtifactLifecycle(
          clock: () => DateTime.utc(2026, 7, 23),
          deleteArtifact: (_) async {
            throw const FileSystemException('injected cleanup denial');
          },
        ),
      );

      await expectLater(
        guarded.restoreToStaging(backup.bundle, restores),
        throwsA(same(primary)),
      );

      final retained = (await restores.list().toList()).single as Directory;
      final incompleteFile = File(
        p.join(retained.path, recoveryArtifactLifecycleMarkerFile),
      );
      final failedFile = File(
        p.join(retained.path, recoveryArtifactFailedMarkerFile),
      );
      final incomplete = await RecoveryArtifactMarker.read(incompleteFile);
      final failed = await RecoveryArtifactMarker.read(failedFile);
      expect(incomplete.kind, RecoveryArtifactKind.fullBackupStagingRestore);
      expect(incomplete.state, RecoveryArtifactState.incomplete);
      expect(failed.kind, RecoveryArtifactKind.fullBackupStagingRestore);
      expect(failed.state, RecoveryArtifactState.failed);
      expect(failed.operationId, incomplete.operationId);
      expect(
        await File(p.join(retained.path, 'backup_complete.json')).exists(),
        isFalse,
      );

      final sourceBackupAfter = <String, List<int>>{};
      await for (final entity in backup.bundle.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          sourceBackupAfter[p.relative(entity.path, from: backup.bundle.path)] =
              await entity.readAsBytes();
        }
      }
      expect(sourceBackupAfter, sourceBackupBefore);
      expect(await sourceDatabase.readAsBytes(), liveBefore);
      expect(await ownedFile.readAsBytes(), ownedBefore);
      expect((await service().validateBundle(backup.bundle)).isValid, isTrue);
    },
  );
}

Future<Map<String, dynamic>> _readManifest(Directory bundle) async {
  return jsonDecode(
        await File(p.join(bundle.path, 'manifest.json')).readAsString(),
      )
      as Map<String, dynamic>;
}

Future<void> _writeManifestAndRefreshCompletion(
  Directory bundle,
  Map<String, dynamic> manifest,
) async {
  final manifestFile = File(p.join(bundle.path, 'manifest.json'));
  await manifestFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(manifest),
    flush: true,
  );
  final completionFile = File(p.join(bundle.path, 'backup_complete.json'));
  final completion =
      jsonDecode(await completionFile.readAsString()) as Map<String, dynamic>;
  completion['manifestSha256'] = sha256
      .convert(await manifestFile.readAsBytes())
      .toString();
  await completionFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(completion),
    flush: true,
  );
}
