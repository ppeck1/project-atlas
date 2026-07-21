import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'atlas_full_backup_service.dart';
import '../db/db_open.dart';

/// A restart-only, replace-active-instance recovery handoff.
///
/// It is deliberately separate from [AtlasFullBackupService]: applying a full
/// snapshot while Atlas has SQLite open is unsafe. The UI writes a plan only
/// after an explicit typed confirmation; a fresh process applies that plan
/// after the UI process exits.
class AtlasLiveRecoveryService {
  static const planSchema = 'project_atlas_live_recovery_plan_v1';
  final Future<AtlasFullBackupService> Function()? _backupService;
  final Future<AtlasLiveRecoveryPaths> Function()? _paths;
  final Future<void> Function(Duration) _delay;

  AtlasLiveRecoveryService({
    Future<AtlasFullBackupService> Function()? backupService,
    Future<AtlasLiveRecoveryPaths> Function()? paths,
    Future<void> Function(Duration)? delay,
  }) : _backupService = backupService,
       _paths = paths,
       _delay = delay ?? Future<void>.delayed;

  Future<AtlasFullBackupService> _backup() =>
      _backupService?.call() ?? AtlasFullBackupService.forCurrentAtlasApp();

  Future<AtlasLiveRecoveryPaths> _managedPaths() async {
    final override = _paths;
    if (override != null) return override();
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    return AtlasLiveRecoveryPaths(
      database: await resolveAtlasDatabaseFile(),
      documents: Directory(p.join(documents.path, 'atlas_documents')),
      media: Directory(p.join(support.path, 'project_media')),
    );
  }

  Future<AtlasLiveRecoveryPlan> preparePlan({
    required Directory sourceBundle,
    required Directory safetyBackupRoot,
    required String executablePath,
  }) async {
    final backup = await _backup();
    final validation = await backup.validateBundle(sourceBundle);
    if (!validation.isValid) {
      throw AtlasFullBackupException(
        'Refusing live recovery from an invalid backup: '
        '${validation.errors.join('; ')}',
      );
    }
    final support = await getApplicationSupportDirectory();
    final planRoot = Directory(p.join(support.path, 'recovery_handoffs'));
    await planRoot.create(recursive: true);
    final id = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final planFile = File(p.join(planRoot.path, 'live-recovery-$id.json'));
    final manifest = validation.manifest!;
    final files = manifest['files'] is List
        ? manifest['files'] as List
        : const [];
    final plan = AtlasLiveRecoveryPlan(
      planFile: planFile,
      sourceBundle: sourceBundle,
      safetyBackupRoot: safetyBackupRoot,
      executablePath: executablePath,
      managedFileCount: files.length,
      databaseInventory: manifest['databaseInventory'],
    );
    await plan.write();
    return plan;
  }

  /// Called before Flutter opens the database in a fresh process.
  Future<void> applyPlan(File planFile) async {
    final plan = await AtlasLiveRecoveryPlan.read(planFile);
    final backup = await _backup();
    final validation = await backup.validateBundle(plan.sourceBundle);
    if (!validation.isValid) {
      throw AtlasFullBackupException(
        'Confirmed recovery stopped: source backup is no longer valid.',
      );
    }
    // The current UI has just exited. A small delay allows Windows to release
    // its SQLite handles before the safety snapshot and replacement begin.
    await _delay(const Duration(seconds: 2));
    final safety = await backup.createBundle(plan.safetyBackupRoot);
    final handoffRoot = Directory(p.join(plan.planFile.parent.path, 'staging'));
    final staged = await backup.restoreToStaging(
      plan.sourceBundle,
      handoffRoot,
    );
    await _replaceManagedAtlasFiles(staged.bundle, plan.planFile.parent);
    await File(
      p.join(plan.planFile.parent.path, 'live_recovery_complete.json'),
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 'project_atlas_live_recovery_complete_v1',
        'sourceBundle': plan.sourceBundle.path,
        'safetyBackup': safety.bundle.path,
        'stagedBundle': staged.bundle.path,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    await plan.planFile.delete();
  }

  Future<void> _replaceManagedAtlasFiles(
    Directory stagedBundle,
    Directory handoffRoot,
  ) async {
    final paths = await _managedPaths();
    final liveDatabase = paths.database;
    final replacements = <_ReplacementTarget>[
      _ReplacementTarget(
        source: File(
          p.join(stagedBundle.path, 'database', 'project_atlas.sqlite'),
        ),
        target: liveDatabase,
      ),
      _ReplacementTarget(
        source: Directory(
          p.join(stagedBundle.path, 'files', 'atlas_documents'),
        ),
        target: paths.documents,
      ),
      _ReplacementTarget(
        source: Directory(p.join(stagedBundle.path, 'files', 'project_media')),
        target: paths.media,
      ),
    ];
    final rollback = Directory(
      p.join(
        handoffRoot.path,
        'rollback-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}',
      ),
    );
    await rollback.create(recursive: true);
    final sqliteSidecars = [
      File('${liveDatabase.path}-wal'),
      File('${liveDatabase.path}-shm'),
    ];
    for (final replacement in replacements) {
      await replacement.moveCurrentTo(rollback);
    }
    // A recovered database must never see the WAL/SHM pair from the replaced
    // instance. Keep them for rollback rather than deleting them.
    for (final sidecar in sqliteSidecars) {
      if (await sidecar.exists()) {
        await sidecar.rename(p.join(rollback.path, p.basename(sidecar.path)));
      }
    }
    try {
      for (final replacement in replacements) {
        await replacement.copyIntoPlace();
      }
    } catch (_) {
      for (final replacement in replacements.reversed) {
        await replacement.restoreFrom(rollback);
      }
      for (final sidecar in sqliteSidecars) {
        final saved = File(p.join(rollback.path, p.basename(sidecar.path)));
        if (await saved.exists()) await saved.rename(sidecar.path);
      }
      rethrow;
    }
  }
}

class AtlasLiveRecoveryPaths {
  final File database;
  final Directory documents;
  final Directory media;

  const AtlasLiveRecoveryPaths({
    required this.database,
    required this.documents,
    required this.media,
  });
}

class AtlasLiveRecoveryPlan {
  final File planFile;
  final Directory sourceBundle;
  final Directory safetyBackupRoot;
  final String executablePath;
  final int managedFileCount;
  final Object? databaseInventory;

  const AtlasLiveRecoveryPlan({
    required this.planFile,
    required this.sourceBundle,
    required this.safetyBackupRoot,
    required this.executablePath,
    required this.managedFileCount,
    required this.databaseInventory,
  });

  Map<String, Object?> toJson() => {
    'schema': AtlasLiveRecoveryService.planSchema,
    'sourceBundle': sourceBundle.path,
    'safetyBackupRoot': safetyBackupRoot.path,
    'executablePath': executablePath,
    'managedFileCount': managedFileCount,
    'databaseInventory': databaseInventory,
  };

  Future<void> write() => planFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(toJson()),
    flush: true,
  );

  static Future<AtlasLiveRecoveryPlan> read(File file) async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['schema'] != AtlasLiveRecoveryService.planSchema) {
      throw const AtlasFullBackupException(
        'Invalid live recovery handoff plan.',
      );
    }
    String text(String key) {
      final value = decoded[key];
      if (value is String && value.trim().isNotEmpty) return value;
      throw AtlasFullBackupException('Live recovery plan is missing $key.');
    }

    return AtlasLiveRecoveryPlan(
      planFile: file,
      sourceBundle: Directory(text('sourceBundle')),
      safetyBackupRoot: Directory(text('safetyBackupRoot')),
      executablePath: text('executablePath'),
      managedFileCount: (decoded['managedFileCount'] as num?)?.toInt() ?? 0,
      databaseInventory: decoded['databaseInventory'],
    );
  }
}

class _ReplacementTarget {
  final FileSystemEntity source;
  final FileSystemEntity target;

  const _ReplacementTarget({required this.source, required this.target});

  String get _name => p.basename(target.path);

  Future<void> moveCurrentTo(Directory rollback) async {
    if (!await target.exists()) return;
    final destination = p.join(rollback.path, _name);
    if (target is File) {
      await (target as File).rename(destination);
    } else {
      await (target as Directory).rename(destination);
    }
  }

  Future<void> copyIntoPlace() async {
    if (source is File) {
      final output = target as File;
      await output.parent.create(recursive: true);
      await (source as File).copy(output.path);
      return;
    }
    final sourceDirectory = source as Directory;
    if (!await sourceDirectory.exists()) return;
    final output = target as Directory;
    await for (final entity in sourceDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: sourceDirectory.path);
      final destination = File(p.join(output.path, relative));
      await destination.parent.create(recursive: true);
      await entity.copy(destination.path);
    }
  }

  Future<void> restoreFrom(Directory rollback) async {
    final saved = FileSystemEntity.typeSync(p.join(rollback.path, _name));
    if (saved == FileSystemEntityType.notFound) return;
    if (target is File) {
      final current = target as File;
      if (await current.exists()) await current.delete();
      await File(p.join(rollback.path, _name)).rename(current.path);
    } else {
      final current = target as Directory;
      if (await current.exists()) await current.delete(recursive: true);
      await Directory(p.join(rollback.path, _name)).rename(current.path);
    }
  }
}
