import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/recovery_artifact_lifecycle.dart';

void main() {
  late Directory root;
  final createdAt = DateTime.utc(2026, 7, 23);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('atlas_artifact_lifecycle_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'complete promotes the typed sibling before removing its marker',
    () async {
      final finalDirectory = Directory(p.join(root.path, 'artifact'));
      final operation = await RecoveryArtifactLifecycle(
        clock: () => createdAt,
        operationId: () => '11111111111111111111111111111111',
      ).begin(finalDirectory, kind: RecoveryArtifactKind.fullBackup);

      expect(
        operation.artifactDirectory.path,
        '${finalDirectory.path}.atlas-incomplete-${operation.operationId}',
      );
      expect(await operation.marker.exists(), isTrue);
      await File(
        p.join(operation.artifactDirectory.path, 'payload.txt'),
      ).writeAsString('payload');

      await operation.complete();

      expect(operation.artifactDirectory.path, finalDirectory.path);
      expect(operation.finalDirectory.path, finalDirectory.path);
      expect(await finalDirectory.exists(), isTrue);
      expect(await operation.marker.exists(), isFalse);
      expect(
        await File(p.join(finalDirectory.path, 'payload.txt')).readAsString(),
        'payload',
      );
    },
  );

  test('failure deletes a bounded typed artifact', () async {
    final operation =
        await RecoveryArtifactLifecycle(
          clock: () => createdAt,
          operationId: () => '22222222222222222222222222222222',
        ).begin(
          Directory(p.join(root.path, 'artifact')),
          kind: RecoveryArtifactKind.projectBundleStaging,
        );
    await File(
      p.join(operation.artifactDirectory.path, 'partial.txt'),
    ).writeAsString('partial');

    await operation.fail();

    expect(await operation.artifactDirectory.exists(), isFalse);
    expect(await operation.finalDirectory.exists(), isFalse);
  });

  test(
    'initial marker create and write faults retain classified paths',
    () async {
      for (final createFault in [true, false]) {
        final id = createFault
            ? '33333333333333333333333333333333'
            : '44444444444444444444444444444444';
        final finalDirectory = Directory(
          p.join(root.path, createFault ? 'create-fault' : 'write-fault'),
        );
        final lifecycle = RecoveryArtifactLifecycle(
          clock: () => createdAt,
          operationId: () => id,
          createMarker: createFault
              ? (_) async {
                  throw const FileSystemException('create denied');
                }
              : null,
          writeMarker: !createFault
              ? (_, __) async {
                  throw const FileSystemException('write denied');
                }
              : null,
        );

        await expectLater(
          lifecycle.begin(
            finalDirectory,
            kind: RecoveryArtifactKind.fullBackup,
          ),
          throwsA(isA<FileSystemException>()),
        );

        final classified = Directory(
          '${finalDirectory.path}.atlas-incomplete-$id',
        );
        expect(await classified.exists(), isTrue);
        expect(await finalDirectory.exists(), isFalse);
      }
    },
  );

  test(
    'complete refuses a final-directory collision without losing work',
    () async {
      final finalDirectory = Directory(p.join(root.path, 'artifact'));
      final operation = await RecoveryArtifactLifecycle(
        clock: () => createdAt,
        operationId: () => '55555555555555555555555555555555',
      ).begin(finalDirectory, kind: RecoveryArtifactKind.fullBackup);
      await File(
        p.join(operation.artifactDirectory.path, 'payload.txt'),
      ).writeAsString('owned');
      await finalDirectory.create();
      final sentinel = File(p.join(finalDirectory.path, 'sentinel.txt'));
      await sentinel.writeAsString('foreign');

      await expectLater(
        operation.complete(),
        throwsA(isA<FileSystemException>()),
      );

      expect(await operation.artifactDirectory.exists(), isTrue);
      expect(await operation.marker.exists(), isTrue);
      expect(await sentinel.readAsString(), 'foreign');
    },
  );

  test('fail is terminal and a later complete cannot publish it', () async {
    final operation =
        await RecoveryArtifactLifecycle(
          clock: () => createdAt,
          operationId: () => '66666666666666666666666666666666',
          deleteArtifact: (_) async {
            throw const FileSystemException('retain quarantine');
          },
        ).begin(
          Directory(p.join(root.path, 'artifact')),
          kind: RecoveryArtifactKind.fullBackupStagingRestore,
        );

    await operation.fail();

    expect(operation.artifactDirectory.path, operation.failedDirectory.path);
    expect(await operation.artifactDirectory.exists(), isTrue);
    expect(
      (await RecoveryArtifactMarker.read(operation.marker)).state,
      RecoveryArtifactState.incomplete,
    );
    expect(
      (await RecoveryArtifactMarker.read(operation.failedMarker)).state,
      RecoveryArtifactState.failed,
    );
    await expectLater(operation.complete(), throwsA(isA<StateError>()));
    expect(await operation.finalDirectory.exists(), isFalse);
  });

  test(
    'concurrent complete and fail serialize to one clean terminal state',
    () async {
      final renameStarted = Completer<void>();
      final releaseRename = Completer<void>();
      final operation =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt,
            operationId: () => '77777777777777777777777777777777',
            rename: (source, destination) async {
              renameStarted.complete();
              await releaseRename.future;
              return source.rename(destination);
            },
          ).begin(
            Directory(p.join(root.path, 'artifact')),
            kind: RecoveryArtifactKind.fullBackup,
          );

      final completion = operation.complete();
      await renameStarted.future;
      final failure = operation.fail();
      releaseRename.complete();
      await Future.wait([completion, failure]);

      expect(await operation.finalDirectory.exists(), isTrue);
      expect(operation.artifactDirectory.path, operation.finalDirectory.path);
      expect(await operation.marker.exists(), isFalse);
      expect(await operation.failedMarker.exists(), isFalse);
    },
  );

  test('fail never overwrites a foreign failed marker', () async {
    final operation =
        await RecoveryArtifactLifecycle(
          clock: () => createdAt,
          operationId: () => '88888888888888888888888888888888',
        ).begin(
          Directory(p.join(root.path, 'artifact')),
          kind: RecoveryArtifactKind.projectBundleStaging,
        );
    final foreign = RecoveryArtifactMarker(
      kind: RecoveryArtifactKind.projectBundleStaging,
      state: RecoveryArtifactState.failed,
      operationId: '99999999999999999999999999999999',
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    final foreignText = jsonEncode(foreign.toJson());
    await operation.failedMarker.writeAsString(foreignText);

    await operation.fail();

    expect(await operation.failedMarker.readAsString(), foreignText);
    expect(
      operation.artifactDirectory.path,
      contains('.atlas-incomplete-${operation.operationId}'),
    );
    expect(await operation.finalDirectory.exists(), isFalse);
    await expectLater(operation.complete(), throwsA(isA<StateError>()));
  });

  test(
    'failed-marker publication fault is terminal before best effort',
    () async {
      var creates = 0;
      final operation =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt,
            operationId: () => '99999999999999999999999999999999',
            createMarker: (marker) async {
              creates++;
              if (creates == 2) {
                throw const FileSystemException('failed marker create denied');
              }
              await marker.create(exclusive: true);
            },
          ).begin(
            Directory(p.join(root.path, 'artifact')),
            kind: RecoveryArtifactKind.fullBackup,
          );

      await operation.fail();

      expect(await operation.artifactDirectory.exists(), isTrue);
      expect(await operation.marker.exists(), isTrue);
      expect(await operation.failedMarker.exists(), isFalse);
      await expectLater(operation.complete(), throwsA(isA<StateError>()));
      expect(await operation.finalDirectory.exists(), isFalse);
    },
  );

  test(
    'partial deletion leaves a typed failed residue with both markers',
    () async {
      final operation =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt,
            operationId: () => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            deleteEntry: (entity) async {
              if (p.basename(entity.path) == 'payload.txt') {
                await entity.delete();
                return;
              }
              throw const FileSystemException('delete denied');
            },
          ).begin(
            Directory(p.join(root.path, 'artifact')),
            kind: RecoveryArtifactKind.fullBackup,
          );
      await File(
        p.join(operation.artifactDirectory.path, 'payload.txt'),
      ).writeAsString('partial');

      await operation.fail();

      expect(operation.artifactDirectory.path, operation.failedDirectory.path);
      expect(await operation.artifactDirectory.exists(), isTrue);
      expect(await operation.marker.exists(), isTrue);
      expect(await operation.failedMarker.exists(), isTrue);
      expect(
        await File(
          p.join(operation.artifactDirectory.path, 'payload.txt'),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'persisted cleanup enforces budgets then deletes validated quarantine',
    () async {
      final operation =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt,
            operationId: () => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            deleteArtifact: (_) async {
              throw const FileSystemException('retain quarantine');
            },
          ).begin(
            Directory(p.join(root.path, 'artifact')),
            kind: RecoveryArtifactKind.fullBackup,
          );
      await File(
        p.join(operation.artifactDirectory.path, 'payload.txt'),
      ).writeAsString('12345');
      await operation.fail();

      final cleanup = RecoveryArtifactLifecycle(
        clock: () => createdAt.add(const Duration(hours: 2)),
      );
      final refused = await cleanup.cleanupPersistedArtifacts(
        root,
        limits: const RecoveryArtifactCleanupLimits(
          maxEntries: 2,
          maxBytes: 4,
          minimumAge: Duration(hours: 1),
        ),
      );
      expect(
        refused.results.single.disposition,
        RecoveryArtifactCleanupDisposition.refusedBudget,
      );
      expect(await operation.artifactDirectory.exists(), isTrue);

      final deleted = await cleanup.cleanupPersistedArtifacts(
        root,
        limits: const RecoveryArtifactCleanupLimits(
          maxEntries: 8,
          maxBytes: 4096,
          minimumAge: Duration(hours: 1),
        ),
      );
      expect(deleted.deletedCount, 1);
      expect(await operation.artifactDirectory.exists(), isFalse);
    },
  );

  test(
    'persisted cleanup applies deletion budgets across candidates',
    () async {
      for (final id in [
        'bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc',
        'bdbdbdbdbdbdbdbdbdbdbdbdbdbdbdbd',
      ]) {
        final operation =
            await RecoveryArtifactLifecycle(
              clock: () => createdAt,
              operationId: () => id,
              deleteArtifact: (_) async {
                throw const FileSystemException('retain quarantine');
              },
            ).begin(
              Directory(p.join(root.path, 'artifact-$id')),
              kind: RecoveryArtifactKind.fullBackup,
            );
        await File(
          p.join(operation.artifactDirectory.path, 'payload.txt'),
        ).writeAsString('payload');
        await operation.fail();
      }

      final report =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt.add(const Duration(hours: 2)),
          ).cleanupPersistedArtifacts(
            root,
            limits: const RecoveryArtifactCleanupLimits(
              maxEntries: 4,
              maxBytes: 4096,
            ),
          );

      expect(report.deletedCount, 1);
      expect(
        report.results
            .where(
              (result) =>
                  result.disposition ==
                  RecoveryArtifactCleanupDisposition.refusedBudget,
            )
            .length,
        1,
      );
      expect(
        await root
            .list()
            .where(
              (entity) => p.basename(entity.path).contains('.atlas-failed-'),
            )
            .length,
        1,
      );
    },
  );

  test('persisted cleanup retains an active long-running operation', () async {
    final operation =
        await RecoveryArtifactLifecycle(
          clock: () => createdAt,
          operationId: () => 'abababababababababababababababab',
        ).begin(
          Directory(p.join(root.path, 'artifact')),
          kind: RecoveryArtifactKind.fullBackup,
        );

    final report = await RecoveryArtifactLifecycle(
      clock: () => createdAt.add(const Duration(days: 30)),
    ).cleanupPersistedArtifacts(root);

    expect(
      report.results.single.disposition,
      RecoveryArtifactCleanupDisposition.retainedActive,
    );
    expect(await operation.artifactDirectory.exists(), isTrue);
    await operation.fail();
  });

  test(
    'persisted cleanup fingerprints same-size same-mtime mutations',
    () async {
      final operation =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt,
            operationId: () => 'acacacacacacacacacacacacacacacac',
            deleteArtifact: (_) async {
              throw const FileSystemException('retain quarantine');
            },
          ).begin(
            Directory(p.join(root.path, 'artifact')),
            kind: RecoveryArtifactKind.projectBundleStaging,
          );
      final payload = File(
        p.join(operation.artifactDirectory.path, 'payload.txt'),
      );
      await payload.writeAsString('before');
      await operation.fail();
      final retainedPayload = File(
        p.join(operation.artifactDirectory.path, 'payload.txt'),
      );

      final report = await RecoveryArtifactLifecycle(
        clock: () => createdAt.add(const Duration(hours: 2)),
        cleanupRecheckHook: (_) async {
          final modified = (await retainedPayload.stat()).modified;
          await retainedPayload.writeAsString('change', flush: true);
          await retainedPayload.setLastModified(modified);
        },
      ).cleanupPersistedArtifacts(root);

      expect(
        report.results.single.disposition,
        RecoveryArtifactCleanupDisposition.refusedMutation,
      );
      expect(await retainedPayload.readAsString(), 'change');
    },
  );

  test('persisted cleanup refuses a linked cleanup-root ancestor', () async {
    final realAncestor = Directory(p.join(root.path, 'real-ancestor'));
    final realCleanupRoot = Directory(p.join(realAncestor.path, 'cleanup'));
    await realCleanupRoot.create(recursive: true);
    final linkedAncestor = Link(p.join(root.path, 'linked-ancestor'));
    try {
      await linkedAncestor.create(realAncestor.path);
    } on FileSystemException {
      markTestSkipped('Symbolic links are unavailable on this host.');
      return;
    }

    await expectLater(
      RecoveryArtifactLifecycle().cleanupPersistedArtifacts(
        Directory(p.join(linkedAncestor.path, 'cleanup')),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('persisted cleanup refuses a substituted descendant link', () async {
    final operation =
        await RecoveryArtifactLifecycle(
          clock: () => createdAt,
          operationId: () => 'adadadadadadadadadadadadadadadad',
          deleteArtifact: (_) async {
            throw const FileSystemException('retain quarantine');
          },
        ).begin(
          Directory(p.join(root.path, 'artifact')),
          kind: RecoveryArtifactKind.fullBackup,
        );
    final nested = Directory(
      p.join(operation.artifactDirectory.path, 'nested'),
    );
    await nested.create();
    await File(p.join(nested.path, 'payload.txt')).writeAsString('owned');
    await operation.fail();
    final retainedNested = Directory(
      p.join(operation.artifactDirectory.path, 'nested'),
    );
    final outside = Directory(p.join(root.path, 'outside'));
    await outside.create();
    final sentinel = File(p.join(outside.path, 'payload.txt'));
    await sentinel.writeAsString('outside');
    var linkSupported = true;

    final report = await RecoveryArtifactLifecycle(
      clock: () => createdAt.add(const Duration(hours: 2)),
      cleanupRecheckHook: (_) async {
        await retainedNested.delete(recursive: true);
        try {
          await Link(retainedNested.path).create(outside.path);
        } on FileSystemException {
          linkSupported = false;
        }
      },
    ).cleanupPersistedArtifacts(root);

    if (!linkSupported) {
      markTestSkipped('Symbolic links are unavailable on this host.');
      return;
    }
    expect(
      report.results
          .where(
            (result) => p.equals(
              result.artifact.path,
              operation.artifactDirectory.path,
            ),
          )
          .single
          .disposition,
      RecoveryArtifactCleanupDisposition.refusedMutation,
    );
    expect(await sentinel.readAsString(), 'outside');
  });

  test(
    'cleanup accepts a valid failed transition left under incomplete name',
    () async {
      final operation =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt,
            operationId: () => 'aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae',
            rename: (_, __) async {
              throw const FileSystemException('rename interrupted');
            },
          ).begin(
            Directory(p.join(root.path, 'artifact')),
            kind: RecoveryArtifactKind.fullBackup,
          );
      await operation.fail();
      expect(operation.artifactDirectory.path, contains('.atlas-incomplete-'));
      expect(await operation.failedMarker.exists(), isTrue);

      final report = await RecoveryArtifactLifecycle(
        clock: () => createdAt.add(const Duration(hours: 2)),
      ).cleanupPersistedArtifacts(root);

      expect(report.deletedCount, 1);
      expect(await operation.artifactDirectory.exists(), isFalse);
    },
  );

  test('runtime validation enforces positive hard cleanup bounds', () async {
    final invalidCleanupLimits = <RecoveryArtifactCleanupLimits>[
      const RecoveryArtifactCleanupLimits(maxEntries: 0),
      const RecoveryArtifactCleanupLimits(maxBytes: 0),
      const RecoveryArtifactCleanupLimits(maxScannedChildren: 0),
      const RecoveryArtifactCleanupLimits(maxCandidates: 0),
      const RecoveryArtifactCleanupLimits(minimumAge: Duration.zero),
      const RecoveryArtifactCleanupLimits(
        maxEntries: recoveryArtifactMaxDeletionEntries + 1,
      ),
      const RecoveryArtifactCleanupLimits(
        maxBytes: recoveryArtifactMaxDeletionBytes + 1,
      ),
      const RecoveryArtifactCleanupLimits(
        maxScannedChildren: recoveryArtifactMaxScannedChildren + 1,
      ),
      const RecoveryArtifactCleanupLimits(
        maxCandidates: recoveryArtifactMaxCleanupCandidates + 1,
      ),
    ];
    for (final limits in invalidCleanupLimits) {
      await expectLater(
        RecoveryArtifactLifecycle().cleanupPersistedArtifacts(
          root,
          limits: limits,
        ),
        throwsA(isA<ArgumentError>()),
      );
    }
    expect(
      () => RecoveryArtifactLifecycle(
        failureDeletionLimits: const RecoveryArtifactDeletionLimits(
          maxEntries: 0,
        ),
      ),
      throwsA(isA<RangeError>()),
    );
    expect(
      () => RecoveryArtifactLifecycle(
        failureDeletionLimits: const RecoveryArtifactDeletionLimits(
          maxBytes: recoveryArtifactMaxDeletionBytes + 1,
        ),
      ),
      throwsA(isA<RangeError>()),
    );
  });

  test(
    'persisted cleanup refuses a mutation between scan and deletion',
    () async {
      final operation =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt,
            operationId: () => 'cccccccccccccccccccccccccccccccc',
            deleteArtifact: (_) async {
              throw const FileSystemException('retain quarantine');
            },
          ).begin(
            Directory(p.join(root.path, 'artifact')),
            kind: RecoveryArtifactKind.projectBundleStaging,
          );
      final payload = File(
        p.join(operation.artifactDirectory.path, 'payload.txt'),
      );
      await payload.writeAsString('before');
      await operation.fail();

      final report =
          await RecoveryArtifactLifecycle(
            clock: () => createdAt.add(const Duration(hours: 2)),
            cleanupRecheckHook: (artifact) async {
              await File(
                p.join(artifact.path, 'payload.txt'),
              ).writeAsString('after');
            },
          ).cleanupPersistedArtifacts(
            root,
            limits: const RecoveryArtifactCleanupLimits(
              minimumAge: Duration(hours: 1),
            ),
          );

      expect(
        report.results.single.disposition,
        RecoveryArtifactCleanupDisposition.refusedMutation,
      );
      expect(await operation.artifactDirectory.exists(), isTrue);
    },
  );

  test(
    'persisted cleanup scans only strict direct-child directory candidates',
    () async {
      const id = 'dddddddddddddddddddddddddddddddd';
      final candidateFile = File(
        p.join(root.path, 'artifact.atlas-failed-$id'),
      );
      await candidateFile.writeAsString('not a directory');
      final nested = Directory(p.join(root.path, 'ordinary'));
      await nested.create();
      await Directory(p.join(nested.path, 'nested.atlas-failed-$id')).create();

      final report = await RecoveryArtifactLifecycle(
        clock: () => createdAt.add(const Duration(hours: 2)),
      ).cleanupPersistedArtifacts(root);

      expect(report.scannedChildren, 2);
      expect(report.matchedCandidates, 1);
      expect(
        report.results.single.disposition,
        RecoveryArtifactCleanupDisposition.refusedLink,
      );
      expect(await candidateFile.exists(), isTrue);
    },
  );

  test('persisted cleanup reports scan and candidate bounds', () async {
    for (var index = 0; index < 3; index++) {
      final id = index.toRadixString(16).padLeft(32, '0');
      await File(
        p.join(root.path, 'artifact-$index.atlas-failed-$id'),
      ).writeAsString('candidate');
    }

    final report = await RecoveryArtifactLifecycle().cleanupPersistedArtifacts(
      root,
      limits: const RecoveryArtifactCleanupLimits(
        maxScannedChildren: 2,
        maxCandidates: 1,
      ),
    );

    expect(report.scannedChildren, 2);
    expect(report.scanLimitReached, isTrue);
    expect(report.matchedCandidates, 2);
    expect(report.candidateLimitReached, isTrue);
    expect(report.results, hasLength(1));
  });

  test('persisted cleanup bounds lifecycle marker reads', () async {
    const id = 'efefefefefefefefefefefefefefefef';
    final artifact = Directory(
      p.join(root.path, 'artifact.atlas-incomplete-$id'),
    );
    await artifact.create();
    await File(
      p.join(artifact.path, recoveryArtifactLifecycleMarkerFile),
    ).writeAsString(
      List.filled(recoveryArtifactMaxMarkerBytes + 1, 'x').join(),
    );

    final report = await RecoveryArtifactLifecycle(
      clock: () => createdAt.add(const Duration(hours: 2)),
    ).cleanupPersistedArtifacts(root);

    expect(
      report.results.single.disposition,
      RecoveryArtifactCleanupDisposition.refusedInvalidMarker,
    );
    expect(await artifact.exists(), isTrue);
  });
}
