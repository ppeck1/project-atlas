import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/atlas_full_backup_service.dart';
import 'package:project_atlas/services/atlas_live_recovery_service.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'replaces only disposable Atlas paths after a fresh safety backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'atlas_live_recovery_',
      );
      addTearDown(() => root.delete(recursive: true));
      final live = File(p.join(root.path, 'live', 'project_atlas.sqlite'));
      final documents = Directory(p.join(root.path, 'live', 'atlas_documents'));
      final media = Directory(p.join(root.path, 'live', 'project_media'));
      await live.parent.create(recursive: true);
      await documents.create(recursive: true);
      await media.create(recursive: true);
      _writeDatabase(live, 'Recovered Atlas');
      await File(
        p.join(documents.path, 'brief.txt'),
      ).writeAsString('recovered document');
      await File(
        p.join(media.path, 'image.txt'),
      ).writeAsString('recovered media');

      AtlasFullBackupService backupService() => AtlasFullBackupService(
        sourceDatabase: live,
        appOwnedRoots: {'atlas_documents': documents, 'project_media': media},
        clock: () => DateTime.utc(2026, 7, 21, 9),
        random: Random(11),
      );
      final source = await backupService().createBundle(
        Directory(p.join(root.path, 'source_backups')),
      );

      _writeDatabase(live, 'Mutated live Atlas');
      await File(
        p.join(documents.path, 'brief.txt'),
      ).writeAsString('mutated document');
      await File(
        p.join(media.path, 'image.txt'),
      ).writeAsString('mutated media');
      await File('${live.path}-wal').writeAsString('old wal');
      await File('${live.path}-shm').writeAsString('old shm');
      final plan = AtlasLiveRecoveryPlan(
        planFile: File(
          p.join(root.path, 'handoff', 'live-recovery-success.json'),
        ),
        handoffId: 'success',
        sourceBundle: source.bundle,
        safetyBackupRoot: Directory(p.join(root.path, 'safety_backups')),
        managedFileCount: 3,
        databaseInventory: null,
      );
      await plan.planFile.parent.create(recursive: true);
      await plan.write();

      final service = AtlasLiveRecoveryService(
        backupService: () async => backupService(),
        paths: () async => AtlasLiveRecoveryPaths(
          database: live,
          documents: documents,
          media: media,
        ),
        delay: (_) async {},
        handoffRoot: () async => plan.planFile.parent,
      );
      await service.applyPlan(plan.planFile);

      expect(_readTitle(live), 'Recovered Atlas');
      expect(
        await File(p.join(documents.path, 'brief.txt')).readAsString(),
        'recovered document',
      );
      expect(
        await File(p.join(media.path, 'image.txt')).readAsString(),
        'recovered media',
      );
      expect(await File('${live.path}-wal').exists(), isFalse);
      expect(await File('${live.path}-shm').exists(), isFalse);
      expect(await plan.planFile.exists(), isFalse);
      expect(
        await File(
          p.join(root.path, 'handoff', 'live_recovery_complete.json'),
        ).exists(),
        isTrue,
      );

      final safety = (await Directory(
        p.join(root.path, 'safety_backups'),
      ).list().toList()).whereType<Directory>().single;
      expect((await backupService().validateBundle(safety)).isValid, isTrue);
      final safetyDb = File(
        p.join(safety.path, 'database', 'project_atlas.sqlite'),
      );
      expect(_readTitle(safetyDb), 'Mutated live Atlas');
      final rollback =
          (await Directory(
            p.join(root.path, 'handoff'),
          ).list().toList()).whereType<Directory>().firstWhere(
            (item) => p.basename(item.path).startsWith('rollback-'),
          );
      expect(
        await File(p.join(rollback.path, 'project_atlas.sqlite-wal')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(rollback.path, 'project_atlas.sqlite-shm')).exists(),
        isTrue,
      );
    },
  );

  for (final failedStep in [
    'move:project_atlas.sqlite',
    'move:atlas_documents',
    'move:project_media',
    'move:project_atlas.sqlite-wal',
    'move:project_atlas.sqlite-shm',
    'copy-file:project_atlas.sqlite',
    'copy-file:atlas_documents:brief.txt',
    'copy-file:project_media:image.txt',
  ]) {
    test(
      'restores the exact live state after failure at $failedStep',
      () async {
        final fixture = await _RecoveryFixture.create();
        addTearDown(fixture.dispose);
        var injected = false;
        final service = fixture.service(
          stepHook: (step) async {
            if (!injected && step == failedStep) {
              injected = true;
              throw StateError('Injected failure at $step');
            }
          },
        );

        await expectLater(
          service.applyPlan(fixture.plan.planFile),
          throwsA(isA<StateError>()),
        );

        expect(injected, isTrue);
        await fixture.expectMutatedLiveState();
        expect(await fixture.plan.planFile.exists(), isFalse);
        expect(await fixture.hasConsumedDiagnostic(), isTrue);
        expect(await fixture.completionMarker.exists(), isFalse);
      },
    );
  }

  test(
    'removes a partial copied target when that target did not exist before',
    () async {
      final fixture = await _RecoveryFixture.create();
      addTearDown(fixture.dispose);
      await fixture.documents.delete(recursive: true);
      await fixture.media.delete(recursive: true);
      var injected = false;
      final service = fixture.service(
        stepHook: (step) async {
          if (!injected && step == 'copy-file:atlas_documents:brief.txt') {
            injected = true;
            throw StateError('Injected partial-directory failure');
          }
        },
      );

      await expectLater(
        service.applyPlan(fixture.plan.planFile),
        throwsA(isA<StateError>()),
      );

      expect(injected, isTrue);
      expect(_readTitle(fixture.live), 'Mutated live Atlas');
      expect(await fixture.documents.exists(), isFalse);
      expect(await fixture.media.exists(), isFalse);
      await fixture.expectSidecarsRestored();
    },
  );

  test('live-byte verification failure rolls back before completion', () async {
    final fixture = await _RecoveryFixture.create();
    addTearDown(fixture.dispose);
    var corrupted = false;
    final service = fixture.service(
      stepHook: (step) async {
        if (!corrupted && step == 'copy:project_media') {
          corrupted = true;
          await File(
            p.join(fixture.documents.path, 'brief.txt'),
          ).writeAsString('corrupted after copy');
        }
      },
    );

    await expectLater(
      service.applyPlan(fixture.plan.planFile),
      throwsA(
        isA<AtlasFullBackupException>().having(
          (error) => error.message,
          'message',
          contains('bytes differ from staging'),
        ),
      ),
    );

    expect(corrupted, isTrue);
    await fixture.expectMutatedLiveState();
    expect(await fixture.completionMarker.exists(), isFalse);
  });

  test('parent observes a valid child plan acknowledgement', () async {
    final fixture = await _RecoveryFixture.create();
    addTearDown(fixture.dispose);
    final service = fixture.service();
    await fixture.plan.writeAcceptance();

    await service.awaitPlanAcceptance(
      fixture.plan,
      workerExitCode: Completer<int>().future,
    );
  });

  test('parent rejects worker exit before plan acknowledgement', () async {
    final fixture = await _RecoveryFixture.create();
    addTearDown(fixture.dispose);
    final service = fixture.service();

    await expectLater(
      service.awaitPlanAcceptance(
        fixture.plan,
        workerExitCode: Future<int>.value(7),
      ),
      throwsA(
        isA<AtlasFullBackupException>().having(
          (error) => error.message,
          'message',
          contains('exited with code 7'),
        ),
      ),
    );
  });

  test('rejects a plan outside the Atlas-owned handoff directory', () async {
    final fixture = await _RecoveryFixture.create();
    addTearDown(fixture.dispose);
    final outside = File(
      p.join(fixture.root.path, 'outside', 'live-recovery-x.json'),
    );
    await outside.parent.create(recursive: true);
    await fixture.plan.planFile.copy(outside.path);

    await expectLater(
      fixture.service().applyPlan(outside),
      throwsA(
        isA<AtlasFullBackupException>().having(
          (error) => error.message,
          'message',
          contains('Atlas-owned handoff directory'),
        ),
      ),
    );
    expect(await outside.exists(), isTrue);
  });

  test(
    'rejects a tampered payload and retains the consumed diagnostic',
    () async {
      final fixture = await _RecoveryFixture.create();
      addTearDown(fixture.dispose);
      final decoded =
          jsonDecode(await fixture.plan.planFile.readAsString())
              as Map<String, dynamic>;
      decoded['sourceBundle'] = p.join(fixture.root.path, 'tampered');
      await fixture.plan.planFile.writeAsString(
        jsonEncode(decoded),
        flush: true,
      );

      await expectLater(
        fixture.service().applyPlan(fixture.plan.planFile),
        throwsA(
          isA<AtlasFullBackupException>().having(
            (error) => error.message,
            'message',
            contains('checksum does not match'),
          ),
        ),
      );
      expect(await fixture.hasConsumedDiagnostic(), isTrue);
    },
  );

  test('rejects a handoff identity that does not match its filename', () async {
    final fixture = await _RecoveryFixture.create();
    addTearDown(fixture.dispose);
    final invalid = AtlasLiveRecoveryPlan(
      planFile: fixture.plan.planFile,
      handoffId: 'different',
      sourceBundle: fixture.plan.sourceBundle,
      safetyBackupRoot: fixture.plan.safetyBackupRoot,
      managedFileCount: fixture.plan.managedFileCount,
      databaseInventory: fixture.plan.databaseInventory,
    );
    await invalid.write();

    await expectLater(
      fixture.service().applyPlan(invalid.planFile),
      throwsA(
        isA<AtlasFullBackupException>().having(
          (error) => error.message,
          'message',
          contains('identity does not match'),
        ),
      ),
    );
  });

  test('plan schema excludes executable paths and writes atomically', () async {
    final fixture = await _RecoveryFixture.create();
    addTearDown(fixture.dispose);
    final decoded =
        jsonDecode(await fixture.plan.planFile.readAsString())
            as Map<String, dynamic>;

    expect(decoded.containsKey('executablePath'), isFalse);
    expect(decoded['payloadSha256'], isA<String>());
    expect(
      await File('${fixture.plan.planFile.path}.tmp-$pid').exists(),
      isFalse,
    );
  });

  test('rejects overlapping source and safety roots', () async {
    final fixture = await _RecoveryFixture.create();
    addTearDown(fixture.dispose);
    final invalid = AtlasLiveRecoveryPlan(
      planFile: fixture.plan.planFile,
      handoffId: fixture.plan.handoffId,
      sourceBundle: fixture.plan.sourceBundle,
      safetyBackupRoot: Directory(
        p.join(fixture.plan.sourceBundle.path, 'nested-safety'),
      ),
      managedFileCount: fixture.plan.managedFileCount,
      databaseInventory: fixture.plan.databaseInventory,
    );
    await invalid.write();

    await expectLater(
      fixture.service().applyPlan(invalid.planFile),
      throwsA(
        isA<AtlasFullBackupException>().having(
          (error) => error.message,
          'message',
          contains('separate folders'),
        ),
      ),
    );
  });
}

class _RecoveryFixture {
  final Directory root;
  final File live;
  final Directory documents;
  final Directory media;
  final AtlasLiveRecoveryPlan plan;
  List<int>? _walAtReplacement;
  List<int>? _shmAtReplacement;

  _RecoveryFixture({
    required this.root,
    required this.live,
    required this.documents,
    required this.media,
    required this.plan,
  });

  File get completionMarker =>
      File(p.join(root.path, 'handoff', 'live_recovery_complete.json'));

  static Future<_RecoveryFixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'atlas_live_recovery_fault_',
    );
    final live = File(p.join(root.path, 'live', 'project_atlas.sqlite'));
    final documents = Directory(p.join(root.path, 'live', 'atlas_documents'));
    final media = Directory(p.join(root.path, 'live', 'project_media'));
    await live.parent.create(recursive: true);
    await documents.create(recursive: true);
    await media.create(recursive: true);
    _writeDatabase(live, 'Recovered Atlas');
    await File(
      p.join(documents.path, 'brief.txt'),
    ).writeAsString('recovered document');
    await File(
      p.join(media.path, 'image.txt'),
    ).writeAsString('recovered media');

    final source = await _backupService(
      root,
      live,
      documents,
      media,
    ).createBundle(Directory(p.join(root.path, 'source_backups')));

    _writeDatabase(live, 'Mutated live Atlas');
    await File(
      p.join(documents.path, 'brief.txt'),
    ).writeAsString('mutated document');
    await File(p.join(media.path, 'image.txt')).writeAsString('mutated media');
    await File('${live.path}-wal').writeAsString('old wal');
    await File('${live.path}-shm').writeAsString('old shm');
    final plan = AtlasLiveRecoveryPlan(
      planFile: File(
        p.join(root.path, 'handoff', 'live-recovery-fixture.json'),
      ),
      handoffId: 'fixture',
      sourceBundle: source.bundle,
      safetyBackupRoot: Directory(p.join(root.path, 'safety_backups')),
      managedFileCount: 3,
      databaseInventory: null,
    );
    await plan.planFile.parent.create(recursive: true);
    await plan.write();
    return _RecoveryFixture(
      root: root,
      live: live,
      documents: documents,
      media: media,
      plan: plan,
    );
  }

  AtlasLiveRecoveryService service({
    Future<void> Function(String step)? stepHook,
  }) => AtlasLiveRecoveryService(
    backupService: () async => _backupService(root, live, documents, media),
    paths: () async => AtlasLiveRecoveryPaths(
      database: live,
      documents: documents,
      media: media,
    ),
    delay: (_) async {},
    handoffRoot: () async => plan.planFile.parent,
    replacementStepHook: (step) async {
      if (step == 'begin-replacement') {
        _walAtReplacement = await File('${live.path}-wal').readAsBytes();
        _shmAtReplacement = await File('${live.path}-shm').readAsBytes();
      }
      await stepHook?.call(step);
    },
  );

  Future<bool> hasConsumedDiagnostic() async =>
      (await plan.planFile.parent.list().toList()).any(
        (entity) => p
            .basename(entity.path)
            .startsWith('${p.basename(plan.planFile.path)}.consuming-'),
      );

  Future<void> expectMutatedLiveState() async {
    await expectSidecarsRestored();
    expect(_readTitle(live), 'Mutated live Atlas');
    expect(
      await File(p.join(documents.path, 'brief.txt')).readAsString(),
      'mutated document',
    );
    expect(
      await File(p.join(media.path, 'image.txt')).readAsString(),
      'mutated media',
    );
  }

  Future<void> expectSidecarsRestored() async {
    expect(_walAtReplacement, isNotNull);
    expect(_shmAtReplacement, isNotNull);
    expect(await File('${live.path}-wal').readAsBytes(), _walAtReplacement);
    expect(await File('${live.path}-shm').readAsBytes(), _shmAtReplacement);
  }

  Future<void> dispose() => root.delete(recursive: true);
}

AtlasFullBackupService _backupService(
  Directory root,
  File live,
  Directory documents,
  Directory media,
) => AtlasFullBackupService(
  sourceDatabase: live,
  appOwnedRoots: {'atlas_documents': documents, 'project_media': media},
  clock: () => DateTime.utc(2026, 7, 21, 9),
  random: Random(31),
);

void _writeDatabase(File file, String title) {
  final database = sqlite3.open(file.path);
  database.execute(
    'CREATE TABLE IF NOT EXISTS projects (title TEXT NOT NULL);',
  );
  database.execute('DELETE FROM projects;');
  database.execute('INSERT INTO projects VALUES (?);', [title]);
  database.dispose();
}

String _readTitle(File file) {
  final database = sqlite3.open(file.path, mode: OpenMode.readOnly);
  final title =
      database.select('SELECT title FROM projects;').single['title'] as String;
  database.dispose();
  return title;
}
