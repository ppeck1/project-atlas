import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/atlas_live_recovery_service.dart';
import 'package:project_atlas/services/recovery_artifact_lifecycle.dart';
import 'package:project_atlas/services/recovery_artifact_retention_service.dart';

void main() {
  late Directory root;
  late Directory handoffRoot;
  late Directory safetyRoot;
  late DateTime now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('atlas_retention_test_');
    handoffRoot = Directory(p.join(root.path, 'handoff'));
    safetyRoot = Directory(p.join(root.path, 'safety'));
    await handoffRoot.create();
    await safetyRoot.create();
    now = DateTime.now().toUtc().add(const Duration(days: 100));
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  RecoveryArtifactRetentionService service({
    Set<String> activePlanPaths = const {},
  }) => RecoveryArtifactRetentionService(
    handoffRoot: handoffRoot,
    clock: () => now,
    isPreparedPlanActive: (plan) =>
        activePlanPaths.contains(p.normalize(p.absolute(plan.path))),
    inspectBackup: (bundle) async {
      final marker = File(p.join(bundle.path, 'test_valid_backup.json'));
      if (!await marker.exists()) return null;
      final decoded =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      return RecoveryBackupInspection(
        createdAt: DateTime.parse(decoded['createdAt'] as String).toUtc(),
      );
    },
  );

  test(
    'preview preserves every active plan, related recovery state, and newest safety backup',
    () async {
      final plan = AtlasLiveRecoveryPlan(
        planFile: File(p.join(handoffRoot.path, 'live-recovery-active.json')),
        handoffId: 'active',
        sourceBundle: Directory(p.join(root.path, 'source')),
        safetyBackupRoot: safetyRoot,
        managedFileCount: 1,
        databaseInventory: null,
      );
      await plan.write();
      await plan.writeAcceptance();
      final rollback = Directory(
        p.join(handoffRoot.path, 'rollback-2026-06-01T00-00-00.000Z'),
      );
      await _writeOldDirectory(
        rollback,
        now.subtract(const Duration(days: 50)),
      );
      final staging = Directory(p.join(handoffRoot.path, 'staging', 'restore'));
      await _writeOldDirectory(staging, now.subtract(const Duration(days: 50)));
      final older = await _writeBackup(
        safetyRoot,
        'older',
        now.subtract(const Duration(days: 60)),
        bytes: 12,
      );
      final newest = await _writeBackup(
        safetyRoot,
        'newest',
        now.subtract(const Duration(days: 40)),
        bytes: 12,
      );

      final preview = await service(
        activePlanPaths: {p.normalize(p.absolute(plan.planFile.path))},
      ).preview();

      expect(
        preview.candidates.map((item) => item.path),
        contains(p.normalize(p.absolute(older.path))),
      );
      expect(
        preview.candidates.map((item) => item.path),
        isNot(contains(p.normalize(p.absolute(newest.path)))),
      );
      expect(
        preview.retained
            .where(
              (item) =>
                  item.disposition ==
                  RecoveryRetentionDisposition.retainedActivePlan,
            )
            .map((item) => item.path),
        containsAll([
          p.normalize(p.absolute(plan.planFile.path)),
          p.normalize(p.absolute(plan.acceptanceFile.path)),
          p.normalize(p.absolute(rollback.path)),
          p.normalize(p.absolute(staging.path)),
        ]),
      );
      expect(
        preview.retained
            .singleWhere(
              (item) => item.path == p.normalize(p.absolute(newest.path)),
            )
            .disposition,
        RecoveryRetentionDisposition.retainedNewestSafetyBackup,
      );
    },
  );

  test(
    'failed plan, diagnostic, orphan acknowledgement, and marker are aged',
    () async {
      final plan = AtlasLiveRecoveryPlan(
        planFile: File(p.join(handoffRoot.path, 'live-recovery-failed.json')),
        handoffId: 'failed',
        sourceBundle: Directory(p.join(root.path, 'source')),
        safetyBackupRoot: safetyRoot,
        managedFileCount: 1,
        databaseInventory: null,
      );
      await plan.write();
      final diagnostic = File('${plan.planFile.path}.failed.txt');
      await diagnostic.writeAsString('failed');
      final orphan = File(
        p.join(handoffRoot.path, 'live-recovery-orphan.accepted.json'),
      );
      await orphan.writeAsString('{}');
      final completion = File(
        p.join(handoffRoot.path, 'live_recovery_complete.json'),
      );
      final newest = await _writeBackup(
        safetyRoot,
        'newest',
        now.subtract(const Duration(days: 60)),
      );
      await completion.writeAsString(
        jsonEncode({
          'schema': 'project_atlas_live_recovery_complete_v1',
          'sourceBundle': p.join(root.path, 'source'),
          'safetyBackup': newest.path,
          'stagedBundle': p.join(root.path, 'staged'),
          'completedAt': now
              .subtract(const Duration(days: 60))
              .toIso8601String(),
        }),
      );
      final old = now.subtract(const Duration(days: 60));
      for (final file in [plan.planFile, diagnostic, orphan, completion]) {
        await file.setLastModified(old);
      }

      final preview = await service().preview();
      final paths = preview.candidates.map((item) => item.path).toSet();

      expect(
        paths,
        containsAll([
          p.normalize(p.absolute(plan.planFile.path)),
          p.normalize(p.absolute(diagnostic.path)),
          p.normalize(p.absolute(orphan.path)),
          p.normalize(p.absolute(completion.path)),
        ]),
      );
      expect(
        preview.retained
            .singleWhere(
              (item) => item.path == p.normalize(p.absolute(newest.path)),
            )
            .disposition,
        RecoveryRetentionDisposition.retainedNewestSafetyBackup,
      );
    },
  );

  test(
    'abandoned consumed plan is eligible after retention owns the lock',
    () async {
      final original = File(
        p.join(handoffRoot.path, 'live-recovery-abandoned.json'),
      );
      final plan = AtlasLiveRecoveryPlan(
        planFile: original,
        handoffId: 'abandoned',
        sourceBundle: Directory(p.join(root.path, 'source')),
        safetyBackupRoot: safetyRoot,
        managedFileCount: 1,
        databaseInventory: null,
      );
      await plan.write();
      final consumed = await original.rename('${original.path}.consuming-4242');
      await consumed.setLastModified(now.subtract(const Duration(days: 60)));

      final preview = await service().preview();

      expect(
        preview.candidates.map((item) => item.path),
        contains(p.normalize(p.absolute(consumed.path))),
      );
    },
  );

  test('unregistered stale pending plan is eligible', () async {
    final plan = AtlasLiveRecoveryPlan(
      planFile: File(p.join(handoffRoot.path, 'live-recovery-stale.json')),
      handoffId: 'stale',
      sourceBundle: Directory(p.join(root.path, 'source')),
      safetyBackupRoot: safetyRoot,
      managedFileCount: 1,
      databaseInventory: null,
    );
    await plan.write();
    await plan.planFile.setLastModified(now.subtract(const Duration(days: 60)));

    final preview = await service().preview();

    expect(
      preview.candidates.map((item) => item.path),
      contains(p.normalize(p.absolute(plan.planFile.path))),
    );
  });

  test('aggregate size selects oldest young artifacts', () async {
    final older = Directory(
      p.join(handoffRoot.path, 'rollback-2026-07-20T00-00-00.000Z'),
    );
    final newer = Directory(
      p.join(handoffRoot.path, 'rollback-2026-07-21T00-00-00.000Z'),
    );
    await _writeOldDirectory(
      older,
      now.subtract(const Duration(days: 3)),
      bytes: 8,
    );
    await _writeOldDirectory(
      newer,
      now.subtract(const Duration(days: 2)),
      bytes: 8,
    );

    final preview = await service().preview(
      policy: const RecoveryArtifactRetentionPolicy(
        maximumAge: Duration(days: 1000),
        maximumRetainedBytes: 10,
      ),
    );

    expect(preview.candidates, hasLength(1));
    expect(preview.candidates.single.path, p.normalize(p.absolute(older.path)));
    expect(preview.candidates.single.triggers, {RecoveryRetentionTrigger.size});
    expect(
      preview.retained.map((item) => item.path),
      contains(p.normalize(p.absolute(newer.path))),
    );
  });

  test('apply deletes an unchanged previewed candidate', () async {
    final rollback = Directory(
      p.join(handoffRoot.path, 'rollback-2026-06-01T00-00-00.000Z'),
    );
    await _writeOldDirectory(rollback, now.subtract(const Duration(days: 60)));
    final retention = service();
    final preview = await retention.preview();

    final report = await retention.apply(preview);

    expect(report.deletedCount, 1);
    expect(await rollback.exists(), isFalse);
  });

  test('apply refuses a candidate changed after preview', () async {
    final rollback = Directory(
      p.join(handoffRoot.path, 'rollback-2026-06-01T00-00-00.000Z'),
    );
    await _writeOldDirectory(rollback, now.subtract(const Duration(days: 60)));
    final retention = service();
    final preview = await retention.preview();
    await File(p.join(rollback.path, 'raced.txt')).writeAsString('new');

    final report = await retention.apply(preview);

    expect(report.deletedCount, 0);
    expect(
      report.results.single.disposition,
      RecoveryArtifactCleanupDisposition.refusedMutation,
    );
    expect(await rollback.exists(), isTrue);
  });

  test(
    'apply fingerprints same-size same-mtime failed-plan mutations',
    () async {
      final diagnostic = File(
        p.join(handoffRoot.path, 'live-recovery-mutated.json.failed.txt'),
      );
      await diagnostic.writeAsString('first');
      final old = now.subtract(const Duration(days: 60));
      await diagnostic.setLastModified(old);
      final retention = service();
      final preview = await retention.preview();
      expect(preview.candidates, hasLength(1));

      await diagnostic.writeAsString('other');
      await diagnostic.setLastModified(old);
      final report = await retention.apply(preview);

      expect(report.deletedCount, 0);
      expect(
        report.results.single.disposition,
        RecoveryArtifactCleanupDisposition.refusedMutation,
      );
      expect(await diagnostic.readAsString(), 'other');
    },
  );

  test('apply refuses a rollback when an active plan appears', () async {
    final rollback = Directory(
      p.join(handoffRoot.path, 'rollback-2026-06-01T00-00-00.000Z'),
    );
    await _writeOldDirectory(rollback, now.subtract(const Duration(days: 60)));
    final activePaths = <String>{};
    final retention = service(activePlanPaths: activePaths);
    final preview = await retention.preview();
    final plan = AtlasLiveRecoveryPlan(
      planFile: File(p.join(handoffRoot.path, 'live-recovery-raced.json')),
      handoffId: 'raced',
      sourceBundle: Directory(p.join(root.path, 'source')),
      safetyBackupRoot: safetyRoot,
      managedFileCount: 1,
      databaseInventory: null,
    );
    await plan.write();
    activePaths.add(p.normalize(p.absolute(plan.planFile.path)));

    final report = await retention.apply(preview);

    expect(report.deletedCount, 0);
    expect(
      report.results.single.disposition,
      RecoveryArtifactCleanupDisposition.refusedMutation,
    );
    expect(await rollback.exists(), isTrue);
  });

  test(
    'newest safety backup remains protected when all are over age',
    () async {
      final older = await _writeBackup(
        safetyRoot,
        'older',
        now.subtract(const Duration(days: 80)),
      );
      final newest = await _writeBackup(
        safetyRoot,
        'newest',
        now.subtract(const Duration(days: 70)),
      );

      final preview = await service().preview(safetyBackupRoots: [safetyRoot]);
      final report = await service().apply(preview);

      expect(report.deletedCount, 1);
      expect(await older.exists(), isFalse);
      expect(await newest.exists(), isTrue);
    },
  );

  test(
    'invalid and unmanaged safety-root children are never candidates',
    () async {
      final foreign = Directory(p.join(safetyRoot.path, 'foreign'));
      await _writeOldDirectory(foreign, now.subtract(const Duration(days: 90)));

      final preview = await service().preview(safetyBackupRoots: [safetyRoot]);

      expect(
        preview.candidates.map((item) => item.path),
        isNot(contains(p.normalize(p.absolute(foreign.path)))),
      );
      expect(await foreign.exists(), isTrue);
    },
  );

  test('policy hard bounds fail before scanning', () async {
    const invalid = [
      RecoveryArtifactRetentionPolicy(maximumAge: Duration.zero),
      RecoveryArtifactRetentionPolicy(maximumRetainedBytes: 0),
      RecoveryArtifactRetentionPolicy(maxScannedEntities: 0),
      RecoveryArtifactRetentionPolicy(maxCandidates: 0),
      RecoveryArtifactRetentionPolicy(
        perArtifactDeletionLimits: RecoveryArtifactDeletionLimits(
          maxEntries: 0,
        ),
      ),
    ];

    for (final policy in invalid) {
      await expectLater(service().preview(policy: policy), throwsArgumentError);
    }
  });

  test('apply rejects candidate IDs outside the supplied preview', () async {
    final rollback = Directory(
      p.join(handoffRoot.path, 'rollback-2026-06-01T00-00-00.000Z'),
    );
    await _writeOldDirectory(rollback, now.subtract(const Duration(days: 60)));
    final retention = service();
    final preview = await retention.preview();

    await expectLater(
      retention.apply(preview, candidateIds: const ['foreign']),
      throwsArgumentError,
    );
    expect(await rollback.exists(), isTrue);
  });

  test('scan exhaustion suppresses every candidate', () async {
    final rollback = Directory(
      p.join(handoffRoot.path, 'rollback-2026-06-01T00-00-00.000Z'),
    );
    await _writeOldDirectory(rollback, now.subtract(const Duration(days: 60)));

    final preview = await service().preview(
      policy: const RecoveryArtifactRetentionPolicy(maxScannedEntities: 1),
    );

    expect(preview.scanLimitReached, isTrue);
    expect(preview.candidates, isEmpty);
    expect(
      preview.issues.map((issue) => issue.message),
      contains(contains('deletion set was suppressed')),
    );
    expect(await rollback.exists(), isTrue);
  });

  test('malformed plan and completion metadata are retained', () async {
    final plan = File(p.join(handoffRoot.path, 'live-recovery-malformed.json'));
    final completion = File(
      p.join(handoffRoot.path, 'live_recovery_complete.json'),
    );
    await plan.writeAsString('{}');
    await completion.writeAsString(
      jsonEncode({
        'schema': 'project_atlas_live_recovery_complete_v1',
        'safetyBackup': p.join(safetyRoot.path, 'unknown'),
      }),
    );
    final old = now.subtract(const Duration(days: 60));
    await plan.setLastModified(old);
    await completion.setLastModified(old);

    final preview = await service().preview();
    final candidatePaths = preview.candidates.map((item) => item.path);
    final retainedPaths = preview.retained.map((item) => item.path);

    expect(candidatePaths, isNot(contains(p.normalize(p.absolute(plan.path)))));
    expect(
      candidatePaths,
      isNot(contains(p.normalize(p.absolute(completion.path)))),
    );
    expect(
      retainedPaths,
      containsAll([
        p.normalize(p.absolute(plan.path)),
        p.normalize(p.absolute(completion.path)),
      ]),
    );
  });
}

Future<Directory> _writeBackup(
  Directory root,
  String name,
  DateTime createdAt, {
  int bytes = 4,
}) async {
  final directory = Directory(p.join(root.path, name));
  await directory.create(recursive: true);
  final marker = File(p.join(directory.path, 'test_valid_backup.json'));
  await marker.writeAsString(
    jsonEncode({'createdAt': createdAt.toIso8601String()}),
  );
  await File(
    p.join(directory.path, 'payload.bin'),
  ).writeAsBytes(List.filled(bytes, 7));
  await _setTreeModified(directory, createdAt);
  return directory;
}

Future<void> _writeOldDirectory(
  Directory directory,
  DateTime modifiedAt, {
  int bytes = 4,
}) async {
  await directory.create(recursive: true);
  await File(
    p.join(directory.path, 'payload.bin'),
  ).writeAsBytes(List.filled(bytes, 1));
  await _setTreeModified(directory, modifiedAt);
}

Future<void> _setTreeModified(Directory directory, DateTime modifiedAt) async {
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) await entity.setLastModified(modifiedAt);
  }
}
