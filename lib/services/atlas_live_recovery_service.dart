import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
  final Future<void> Function(String step)? _replacementStepHook;
  final DateTime Function() _clock;

  AtlasLiveRecoveryService({
    Future<AtlasFullBackupService> Function()? backupService,
    Future<AtlasLiveRecoveryPaths> Function()? paths,
    Future<void> Function(Duration)? delay,
    Future<void> Function(String step)? replacementStepHook,
    DateTime Function()? clock,
  }) : _backupService = backupService,
       _paths = paths,
       _delay = delay ?? Future<void>.delayed,
       _replacementStepHook = replacementStepHook,
       _clock = clock ?? DateTime.now;

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
    await plan.writeAcceptance();
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
    if (await plan.acceptanceFile.exists()) {
      await plan.acceptanceFile.delete();
    }
  }

  Future<void> awaitPlanAcceptance(
    AtlasLiveRecoveryPlan plan, {
    required Future<int> workerExitCode,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    int? exitedWith;
    workerExitCode.then((code) => exitedWith = code);
    final deadline = _clock().add(timeout);
    while (_clock().isBefore(deadline)) {
      if (await plan.acceptanceFile.exists()) {
        await plan.validateAcceptance();
        return;
      }
      if (exitedWith != null) {
        throw AtlasFullBackupException(
          'Recovery worker exited with code $exitedWith before accepting the plan.',
        );
      }
      await _delay(const Duration(milliseconds: 50));
    }
    throw const AtlasFullBackupException(
      'Recovery worker did not acknowledge the plan before timeout.',
    );
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
      await replacement.captureOriginalState();
    }
    final sidecarExistedBefore = <String, bool>{
      for (final sidecar in sqliteSidecars)
        sidecar.path: await sidecar.exists(),
    };
    try {
      await _replacementStepHook?.call('begin-replacement');
      for (final replacement in replacements) {
        await replacement.moveCurrentTo(rollback);
        await _replacementStepHook?.call('move:${replacement.name}');
      }
      // A recovered database must never see the WAL/SHM pair from the replaced
      // instance. Keep them for rollback rather than deleting them.
      for (final sidecar in sqliteSidecars) {
        if (await sidecar.exists()) {
          await sidecar.rename(p.join(rollback.path, p.basename(sidecar.path)));
          await _replacementStepHook?.call('move:${p.basename(sidecar.path)}');
        }
      }
      for (final replacement in replacements) {
        await replacement.copyIntoPlace(_replacementStepHook);
        await _replacementStepHook?.call('copy:${replacement.name}');
      }
      // The staged bundle has already passed SQLite and manifest validation.
      // Byte-for-byte verification here proves that the final live targets are
      // the same validated database and exact managed-file inventory.
      for (final replacement in replacements) {
        await replacement.verifyCopy();
        await _replacementStepHook?.call('verify:${replacement.name}');
      }
    } catch (error, stackTrace) {
      final rollbackErrors = <Object>[];
      for (final replacement in replacements.reversed) {
        try {
          await replacement.restoreFrom(rollback);
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      for (final sidecar in sqliteSidecars.reversed) {
        try {
          await _restoreSidecar(
            sidecar,
            rollback,
            existedBefore: sidecarExistedBefore[sidecar.path]!,
          );
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      if (rollbackErrors.isNotEmpty) {
        throw AtlasFullBackupException(
          'Live recovery failed ($error) and rollback was incomplete: '
          '${rollbackErrors.join('; ')}',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _restoreSidecar(
    File sidecar,
    Directory rollback, {
    required bool existedBefore,
  }) async {
    final saved = File(p.join(rollback.path, p.basename(sidecar.path)));
    if (await saved.exists()) {
      if (await sidecar.exists()) await sidecar.delete();
      await saved.rename(sidecar.path);
      return;
    }
    if (!existedBefore) {
      if (await sidecar.exists()) await sidecar.delete();
      return;
    }
    if (!await sidecar.exists()) {
      throw AtlasFullBackupException(
        'Rollback could not restore SQLite sidecar ${sidecar.path}.',
      );
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

  File get acceptanceFile => File('${planFile.path}.accepted.json');

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

  Future<void> writeAcceptance() async {
    final temporary = File('${acceptanceFile.path}.tmp-$pid');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 'project_atlas_live_recovery_acceptance_v1',
        'planFile': planFile.path,
        'acceptedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    await temporary.rename(acceptanceFile.path);
  }

  Future<void> validateAcceptance() async {
    final decoded = jsonDecode(await acceptanceFile.readAsString());
    if (decoded is! Map ||
        decoded['schema'] != 'project_atlas_live_recovery_acceptance_v1' ||
        decoded['planFile'] != planFile.path) {
      throw const AtlasFullBackupException(
        'Recovery worker wrote an invalid plan acknowledgement.',
      );
    }
  }

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
  bool? _targetExistedBefore;

  _ReplacementTarget({required this.source, required this.target});

  String get name => p.basename(target.path);

  Future<void> captureOriginalState() async {
    _targetExistedBefore = await target.exists();
  }

  Future<void> moveCurrentTo(Directory rollback) async {
    if (!await target.exists()) return;
    final destination = p.join(rollback.path, name);
    if (target is File) {
      await (target as File).rename(destination);
    } else {
      await (target as Directory).rename(destination);
    }
  }

  Future<void> copyIntoPlace(
    Future<void> Function(String step)? stepHook,
  ) async {
    if (source is File) {
      final output = target as File;
      await output.parent.create(recursive: true);
      await (source as File).copy(output.path);
      await stepHook?.call('copy-file:$name');
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
      await stepHook?.call('copy-file:$name:$relative');
    }
  }

  Future<void> verifyCopy() async {
    final sourceType = await FileSystemEntity.type(source.path);
    final targetType = await FileSystemEntity.type(target.path);
    if (sourceType != targetType) {
      throw AtlasFullBackupException(
        'Live recovery target type differs from staging for $name.',
      );
    }
    if (sourceType == FileSystemEntityType.notFound) return;
    if (sourceType == FileSystemEntityType.file) {
      await _verifyFile(source as File, target as File, name);
      return;
    }
    if (sourceType != FileSystemEntityType.directory) {
      throw AtlasFullBackupException(
        'Unsupported staged recovery entity for $name.',
      );
    }
    final sourceFiles = await _directoryFiles(source as Directory);
    final targetFiles = await _directoryFiles(target as Directory);
    if (sourceFiles.keys.join('\n') != targetFiles.keys.join('\n')) {
      throw AtlasFullBackupException(
        'Live recovery inventory differs from staging for $name.',
      );
    }
    for (final relative in sourceFiles.keys) {
      await _verifyFile(
        sourceFiles[relative]!,
        targetFiles[relative]!,
        '$name/$relative',
      );
    }
  }

  Future<void> restoreFrom(Directory rollback) async {
    final existedBefore = _targetExistedBefore;
    if (existedBefore == null) {
      throw StateError('Replacement state was not captured for $name.');
    }
    final savedPath = p.join(rollback.path, name);
    final saved = await FileSystemEntity.type(savedPath);
    if (saved == FileSystemEntityType.notFound) {
      if (!existedBefore) {
        await _deleteTargetIfPresent();
        return;
      }
      if (!await target.exists()) {
        throw AtlasFullBackupException(
          'Rollback could not restore original target ${target.path}.',
        );
      }
      return;
    }
    await _deleteTargetIfPresent();
    if (target is File) {
      await File(savedPath).rename(target.path);
    } else {
      await Directory(savedPath).rename(target.path);
    }
  }

  Future<void> _deleteTargetIfPresent() async {
    final type = await FileSystemEntity.type(target.path);
    if (type == FileSystemEntityType.file) {
      await File(target.path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(target.path).delete(recursive: true);
    }
  }

  static Future<Map<String, File>> _directoryFiles(Directory root) async {
    final entries = <String, File>{};
    if (!await root.exists()) return entries;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      entries[p.relative(entity.path, from: root.path)] = entity;
    }
    return Map.fromEntries(
      entries.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  static Future<void> _verifyFile(
    File source,
    File target,
    String label,
  ) async {
    if (await source.length() != await target.length() ||
        await _sha256(source) != await _sha256(target)) {
      throw AtlasFullBackupException(
        'Live recovery bytes differ from staging for $label.',
      );
    }
  }

  static Future<String> _sha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}
