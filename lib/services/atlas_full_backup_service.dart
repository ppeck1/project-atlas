import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/db_open.dart';
import '../shared/atlas_owned_file_snapshot_coordinator.dart';

/// The on-disk contract for a full Atlas recovery bundle.
const atlasFullBackupManifestSchema = 'project_atlas_full_backup_v1';
const atlasFullBackupSnapshotContract = 'atlas_owned_roots_quiesced_v1';
const _atlasFullBackupCompletionSchema =
    'project_atlas_full_backup_completion_v1';
const _atlasFullBackupCompletionFile = 'backup_complete.json';

enum AtlasFullBackupPhase {
  preparing,
  snapshotting,
  copyingFiles,
  writingManifest,
  validating,
  complete,
  failed,
}

/// A point-in-time update for the app-owned full-backup operation.
class AtlasFullBackupProgress {
  final AtlasFullBackupPhase phase;
  final String message;
  final int copiedFiles;
  final int totalFiles;

  const AtlasFullBackupProgress({
    required this.phase,
    required this.message,
    this.copiedFiles = 0,
    this.totalFiles = 0,
  });

  bool get isTerminal =>
      phase == AtlasFullBackupPhase.complete ||
      phase == AtlasFullBackupPhase.failed;

  String? get fileProgressLabel =>
      totalFiles > 0 ? '$copiedFiles/$totalFiles files' : null;

  /// Approximate whole-operation progress. File copying reports exact counts;
  /// snapshot and integrity work are intentionally shown as named stages.
  double? get fraction => switch (phase) {
    AtlasFullBackupPhase.preparing => 0.04,
    AtlasFullBackupPhase.snapshotting => 0.16,
    AtlasFullBackupPhase.copyingFiles =>
      totalFiles == 0
          ? 0.70
          : 0.20 + (0.50 * (copiedFiles.clamp(0, totalFiles) / totalFiles)),
    AtlasFullBackupPhase.writingManifest => 0.72,
    AtlasFullBackupPhase.validating => 0.84,
    AtlasFullBackupPhase.complete => 1.0,
    AtlasFullBackupPhase.failed => null,
  };
}

typedef AtlasFullBackupProgressCallback =
    void Function(AtlasFullBackupProgress progress);

/// Raised when a requested backup or validation operation is unsafe.
class AtlasFullBackupException implements Exception {
  final String message;

  const AtlasFullBackupException(this.message);

  @override
  String toString() => 'AtlasFullBackupException: $message';
}

class AtlasFullBackupCreation {
  final Directory bundle;
  final Map<String, Object?> manifest;

  const AtlasFullBackupCreation({required this.bundle, required this.manifest});
}

class AtlasFullBackupValidationReport {
  final Directory bundle;
  final List<String> errors;
  final Map<String, Object?>? manifest;

  const AtlasFullBackupValidationReport({
    required this.bundle,
    required this.errors,
    required this.manifest,
  });

  bool get isValid => errors.isEmpty;
}

/// A validated copy of a recovery bundle restored away from the live instance.
class AtlasFullBackupStagingRestore {
  final Directory bundle;
  final AtlasFullBackupValidationReport validation;

  const AtlasFullBackupStagingRestore({
    required this.bundle,
    required this.validation,
  });
}

/// Evidence that a completed bundle can be restored byte-for-byte into an
/// isolated staging location. It never authorizes live-instance replacement.
class AtlasFullBackupRoundTripReport {
  final Directory sourceBundle;
  final Directory stagedBundle;
  final String sourceFingerprint;
  final String stagedFingerprint;
  final AtlasFullBackupValidationReport sourceValidation;
  final AtlasFullBackupValidationReport stagedValidation;

  const AtlasFullBackupRoundTripReport({
    required this.sourceBundle,
    required this.stagedBundle,
    required this.sourceFingerprint,
    required this.stagedFingerprint,
    required this.sourceValidation,
    required this.stagedValidation,
  });

  bool get isCanonical => sourceFingerprint == stagedFingerprint;
}

/// Creates and validates self-describing Atlas recovery bundles.
///
/// The SQLite database is copied through SQLite's online-backup API, never by
/// copying the live database file. App-owned files are copied into the same
/// staged bundle and each output is protected by a SHA-256 entry in the
/// versioned manifest. Active-instance replacement is intentionally outside
/// this service; a later recovery slice restores only into staging first.
class AtlasFullBackupService {
  final File sourceDatabase;
  final Map<String, Directory> appOwnedRoots;
  final DateTime Function() _clock;
  final Random _random;
  final AtlasOwnedFileSnapshotCoordinator _snapshotCoordinator;
  final Future<void> Function(String step)? _snapshotStepHook;

  AtlasFullBackupService({
    required this.sourceDatabase,
    this.appOwnedRoots = const {},
    DateTime Function()? clock,
    Random? random,
    AtlasOwnedFileSnapshotCoordinator? snapshotCoordinator,
    Future<void> Function(String step)? snapshotStepHook,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       _snapshotCoordinator =
           snapshotCoordinator ?? AtlasOwnedFileSnapshotCoordinator.instance,
       _snapshotStepHook = snapshotStepHook {
    for (final name in appOwnedRoots.keys) {
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name)) {
        throw ArgumentError.value(
          name,
          'appOwnedRoots',
          'Root names may only contain letters, digits, underscores, and dashes.',
        );
      }
    }
  }

  /// Builds the production service around every current Atlas-owned file root.
  ///
  /// This remains path discovery only: it does not expose or perform a live
  /// database replacement.
  static Future<AtlasFullBackupService> forCurrentAtlasApp() async {
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    return AtlasFullBackupService(
      sourceDatabase: await resolveAtlasDatabaseFile(),
      appOwnedRoots: {
        'atlas_documents': Directory(p.join(documents.path, 'atlas_documents')),
        'project_media': Directory(p.join(support.path, 'project_media')),
      },
    );
  }

  /// Produces a completed recovery bundle under [destinationRoot].
  ///
  /// A completion marker is written only after the bundle validates. This
  /// avoids relying on a directory rename, which Windows can deny when an
  /// indexer, Explorer, antivirus, or sync client has the directory open.
  /// A directory without the marker is intentionally not restorable.
  Future<AtlasFullBackupCreation> createBundle(
    Directory destinationRoot, {
    AtlasFullBackupProgressCallback? onProgress,
  }) => _snapshotCoordinator.runBackup(
    () => _createBundleWithOwnedFilesLocked(
      destinationRoot,
      onProgress: onProgress,
    ),
  );

  Future<AtlasFullBackupCreation> _createBundleWithOwnedFilesLocked(
    Directory destinationRoot, {
    AtlasFullBackupProgressCallback? onProgress,
  }) async {
    await _snapshotStepHook?.call('owned-files-locked');
    if (!await sourceDatabase.exists()) {
      throw AtlasFullBackupException(
        'The Atlas database does not exist: ${sourceDatabase.path}',
      );
    }
    await destinationRoot.create(recursive: true);
    void emit(AtlasFullBackupProgress progress) => onProgress?.call(progress);
    emit(
      const AtlasFullBackupProgress(
        phase: AtlasFullBackupPhase.preparing,
        message: 'Preparing recovery backup…',
      ),
    );

    final name = _bundleName();
    final bundle = Directory(p.join(destinationRoot.path, name));
    if (await bundle.exists()) {
      throw AtlasFullBackupException(
        'Refusing to overwrite an existing recovery bundle: ${bundle.path}',
      );
    }
    await bundle.create(recursive: true);

    final filesByRoot = <String, List<File>>{};
    final roots = <Map<String, Object?>>[];
    var totalFiles = 0;
    for (final root in appOwnedRoots.entries) {
      final files = await _listAppOwnedFiles(root.value);
      filesByRoot[root.key] = files;
      totalFiles += files.length;
      roots.add({'name': root.key, 'sourcePresent': await root.value.exists()});
    }

    emit(
      const AtlasFullBackupProgress(
        phase: AtlasFullBackupPhase.snapshotting,
        message: 'Creating a consistent SQLite snapshot…',
      ),
    );
    final snapshot = File(
      p.join(bundle.path, 'database', 'project_atlas.sqlite'),
    );
    await snapshot.parent.create(recursive: true);
    await _createOnlineSnapshot(snapshot);
    await _snapshotStepHook?.call('database-snapshotted');

    final copiedFiles = <Map<String, Object?>>[
      await _fileManifestEntry(
        bundle,
        snapshot,
        path: 'database/project_atlas.sqlite',
        kind: 'sqlite_snapshot',
      ),
    ];
    var copiedFileCount = 0;
    emit(
      AtlasFullBackupProgress(
        phase: AtlasFullBackupPhase.copyingFiles,
        message: totalFiles == 0
            ? 'No app-owned files to copy.'
            : 'Copying app-owned files…',
        totalFiles: totalFiles,
      ),
    );
    for (final root in appOwnedRoots.entries) {
      copiedFiles.addAll(
        await _copyRootIntoBundle(
          bundle,
          root.key,
          root.value,
          filesByRoot[root.key]!,
          onFileCopied: () {
            copiedFileCount++;
            emit(
              AtlasFullBackupProgress(
                phase: AtlasFullBackupPhase.copyingFiles,
                message: 'Copying app-owned files…',
                copiedFiles: copiedFileCount,
                totalFiles: totalFiles,
              ),
            );
          },
        ),
      );
    }
    await _verifyOwnedFileInventoryStable(filesByRoot);
    await _snapshotStepHook?.call('owned-files-copied');

    emit(
      AtlasFullBackupProgress(
        phase: AtlasFullBackupPhase.writingManifest,
        message: 'Recording checksums and backup inventory…',
        copiedFiles: copiedFileCount,
        totalFiles: totalFiles,
      ),
    );
    final inventory = _readDatabaseInventory(snapshot);
    final manifest = <String, Object?>{
      'schema': atlasFullBackupManifestSchema,
      'snapshotContract': atlasFullBackupSnapshotContract,
      'createdAt': _clock().toUtc().toIso8601String(),
      'databaseSnapshot': 'database/project_atlas.sqlite',
      'databaseInventory': inventory,
      'appOwnedRoots': roots,
      'files': copiedFiles,
    };
    final manifestFile = File(p.join(bundle.path, 'manifest.json'));
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );

    emit(
      AtlasFullBackupProgress(
        phase: AtlasFullBackupPhase.validating,
        message: 'Validating checksums and database integrity…',
        copiedFiles: copiedFileCount,
        totalFiles: totalFiles,
      ),
    );
    final stagedValidation = await validateBundle(
      bundle,
      requireCompletion: false,
    );
    if (!stagedValidation.isValid) {
      throw AtlasFullBackupException(
        'The staged recovery bundle failed validation: '
        '${stagedValidation.errors.join('; ')}',
      );
    }
    await _writeCompletionMarker(bundle, manifestFile);
    emit(
      AtlasFullBackupProgress(
        phase: AtlasFullBackupPhase.complete,
        message: 'Full backup validated: ${bundle.path}',
        copiedFiles: copiedFileCount,
        totalFiles: totalFiles,
      ),
    );
    return AtlasFullBackupCreation(bundle: bundle, manifest: manifest);
  }

  /// Validates checksums, SQLite integrity, foreign keys, and table inventory.
  Future<AtlasFullBackupValidationReport> validateBundle(
    Directory bundle, {
    bool requireCompletion = true,
  }) async {
    final errors = <String>[];
    Map<String, Object?>? manifest;
    final manifestFile = File(p.join(bundle.path, 'manifest.json'));
    if (!await manifestFile.exists()) {
      return AtlasFullBackupValidationReport(
        bundle: bundle,
        errors: const ['manifest.json is missing.'],
        manifest: null,
      );
    }

    try {
      final decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map) {
        throw const FormatException('The manifest root must be an object.');
      }
      manifest = decoded.map((key, value) => MapEntry('$key', value));
    } on FormatException catch (error) {
      return AtlasFullBackupValidationReport(
        bundle: bundle,
        errors: ['manifest.json is invalid: ${error.message}'],
        manifest: null,
      );
    }

    if (manifest['schema'] != atlasFullBackupManifestSchema) {
      errors.add('Unsupported manifest schema: ${manifest['schema']}.');
    }
    if (requireCompletion) {
      await _validateCompletionMarker(bundle, manifestFile, errors);
    }
    final entries = manifest['files'];
    if (entries is! List) {
      errors.add('Manifest files must be a list.');
    } else {
      final seenPaths = <String>{};
      for (final rawEntry in entries) {
        if (rawEntry is! Map) {
          errors.add('Manifest has a non-object file entry.');
          continue;
        }
        final entry = rawEntry.map((key, value) => MapEntry('$key', value));
        final relativePath = entry['path'];
        final expectedDigest = entry['sha256'];
        if (relativePath is! String || expectedDigest is! String) {
          errors.add('Manifest file entry is missing path or SHA-256.');
          continue;
        }
        if (!_isSafeBundleRelativePath(relativePath)) {
          errors.add('Manifest contains an unsafe file path: $relativePath.');
          continue;
        }
        if (!seenPaths.add(relativePath)) {
          errors.add('Manifest contains a duplicate file path: $relativePath.');
          continue;
        }
        final file = File(p.joinAll([bundle.path, ...p.split(relativePath)]));
        if (!await file.exists()) {
          errors.add('Manifest file is missing: $relativePath.');
          continue;
        }
        final actualDigest = await _sha256File(file);
        if (actualDigest != expectedDigest) {
          errors.add('Checksum mismatch: $relativePath.');
        }
        final expectedBytes = entry['bytes'];
        if (expectedBytes is num &&
            await file.length() != expectedBytes.toInt()) {
          errors.add('Byte length mismatch: $relativePath.');
        }
      }
    }

    final databasePath = manifest['databaseSnapshot'];
    if (databasePath is! String || !_isSafeBundleRelativePath(databasePath)) {
      errors.add('Manifest databaseSnapshot is missing or unsafe.');
    } else {
      final snapshot = File(p.joinAll([bundle.path, ...p.split(databasePath)]));
      if (!await snapshot.exists()) {
        errors.add('SQLite snapshot is missing: $databasePath.');
      } else {
        try {
          final actualInventory = _readDatabaseInventory(snapshot);
          _compareInventory(
            manifest['databaseInventory'],
            actualInventory,
            errors,
          );
        } on Object catch (error) {
          errors.add('SQLite snapshot validation failed: $error');
        }
      }
    }

    return AtlasFullBackupValidationReport(
      bundle: bundle,
      errors: List.unmodifiable(errors),
      manifest: manifest,
    );
  }

  /// Restores [bundle] into a new, validated staging directory.
  ///
  /// This method never reads from, writes to, closes, or replaces
  /// [sourceDatabase]. A later recovery coordinator may decide whether a
  /// verified staging restore is eligible to replace an inactive Atlas
  /// instance.
  Future<AtlasFullBackupStagingRestore> restoreToStaging(
    Directory bundle,
    Directory destinationRoot,
  ) async {
    final sourceValidation = await validateBundle(bundle);
    if (!sourceValidation.isValid) {
      throw AtlasFullBackupException(
        'Refusing to restore an invalid backup bundle: '
        '${sourceValidation.errors.join('; ')}',
      );
    }
    final manifest = sourceValidation.manifest!;
    final entries = manifest['files']! as List;
    await destinationRoot.create(recursive: true);

    final restored = Directory(p.join(destinationRoot.path, _restoreName()));
    if (await restored.exists()) {
      throw AtlasFullBackupException(
        'Refusing to overwrite an existing staging restore: ${restored.path}',
      );
    }
    await restored.create(recursive: true);
    await File(
      p.join(bundle.path, 'manifest.json'),
    ).copy(p.join(restored.path, 'manifest.json'));
    for (final rawEntry in entries) {
      final entry = rawEntry as Map;
      final relativePath = entry['path'] as String;
      final source = File(p.joinAll([bundle.path, ...p.split(relativePath)]));
      final target = File(p.joinAll([restored.path, ...p.split(relativePath)]));
      await target.parent.create(recursive: true);
      await source.copy(target.path);
    }

    final stagingValidation = await validateBundle(
      restored,
      requireCompletion: false,
    );
    if (!stagingValidation.isValid) {
      throw AtlasFullBackupException(
        'The staging restore failed validation: '
        '${stagingValidation.errors.join('; ')}',
      );
    }
    await File(
      p.join(bundle.path, _atlasFullBackupCompletionFile),
    ).copy(p.join(restored.path, _atlasFullBackupCompletionFile));
    final completedValidation = await validateBundle(restored);
    if (!completedValidation.isValid) {
      throw AtlasFullBackupException(
        'The completed staging restore failed validation: '
        '${completedValidation.errors.join('; ')}',
      );
    }
    return AtlasFullBackupStagingRestore(
      bundle: restored,
      validation: completedValidation,
    );
  }

  /// Performs a non-destructive recovery acceptance check.
  ///
  /// Every manifest-declared file is re-hashed in both the completed backup
  /// and its staged restore. The fingerprint also includes the actual SQLite
  /// inventory, so this is stronger than merely checking that a directory was
  /// copied. The active Atlas database and owned files are never touched.
  Future<AtlasFullBackupRoundTripReport> verifyRoundTrip(
    Directory bundle,
    Directory destinationRoot,
  ) async {
    final sourceValidation = await validateBundle(bundle);
    if (!sourceValidation.isValid) {
      throw AtlasFullBackupException(
        'Refusing canonical round-trip verification of an invalid backup: '
        '${sourceValidation.errors.join('; ')}',
      );
    }
    final sourceFingerprint = await _canonicalFingerprint(
      bundle,
      sourceValidation.manifest!,
    );
    final restored = await restoreToStaging(bundle, destinationRoot);
    if (!restored.validation.isValid) {
      throw AtlasFullBackupException(
        'The staged round-trip restore failed validation: '
        '${restored.validation.errors.join('; ')}',
      );
    }
    final stagedFingerprint = await _canonicalFingerprint(
      restored.bundle,
      restored.validation.manifest!,
    );
    if (sourceFingerprint != stagedFingerprint) {
      throw const AtlasFullBackupException(
        'Canonical round-trip verification failed: staged content differs '
        'from the completed backup.',
      );
    }
    return AtlasFullBackupRoundTripReport(
      sourceBundle: bundle,
      stagedBundle: restored.bundle,
      sourceFingerprint: sourceFingerprint,
      stagedFingerprint: stagedFingerprint,
      sourceValidation: sourceValidation,
      stagedValidation: restored.validation,
    );
  }

  Future<String> _canonicalFingerprint(
    Directory bundle,
    Map<String, Object?> manifest,
  ) async {
    final entries = manifest['files'] as List;
    final files = <Map<String, Object?>>[];
    for (final rawEntry in entries) {
      final entry = (rawEntry as Map).map(
        (key, value) => MapEntry('$key', value),
      );
      final path = entry['path'] as String;
      final file = File(p.joinAll([bundle.path, ...p.split(path)]));
      files.add({
        'path': path,
        'bytes': await file.length(),
        'sha256': await _sha256File(file),
      });
    }
    files.sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    final databasePath = manifest['databaseSnapshot'] as String;
    final database = File(p.joinAll([bundle.path, ...p.split(databasePath)]));
    final canonical = <String, Object?>{
      'schema': manifest['schema'],
      'files': files,
      'databaseInventory': _readDatabaseInventory(database),
    };
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  Future<void> _writeCompletionMarker(Directory bundle, File manifest) async {
    final marker = File(p.join(bundle.path, _atlasFullBackupCompletionFile));
    final payload = <String, Object?>{
      'schema': _atlasFullBackupCompletionSchema,
      'completedAt': _clock().toUtc().toIso8601String(),
      'manifestSha256': await _sha256File(manifest),
    };
    await marker.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
  }

  Future<void> _validateCompletionMarker(
    Directory bundle,
    File manifest,
    List<String> errors,
  ) async {
    final marker = File(p.join(bundle.path, _atlasFullBackupCompletionFile));
    if (!await marker.exists()) {
      errors.add('$_atlasFullBackupCompletionFile is missing.');
      return;
    }
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map) {
        throw const FormatException('The completion marker must be an object.');
      }
      final completion = decoded.map((key, value) => MapEntry('$key', value));
      if (completion['schema'] != _atlasFullBackupCompletionSchema) {
        errors.add('Unsupported completion marker schema.');
      }
      if (completion['manifestSha256'] != await _sha256File(manifest)) {
        errors.add('Completion marker does not match manifest.json.');
      }
    } on FormatException catch (error) {
      errors.add(
        '$_atlasFullBackupCompletionFile is invalid: ${error.message}',
      );
    }
  }

  Future<void> _createOnlineSnapshot(File destination) async {
    final source = sqlite3.open(sourceDatabase.path, mode: OpenMode.readOnly);
    final target = sqlite3.open(destination.path);
    try {
      await source.backup(target, nPage: 100).drain<void>();
    } finally {
      target.dispose();
      source.dispose();
    }
  }

  Future<List<Map<String, Object?>>> _copyRootIntoBundle(
    Directory staging,
    String rootName,
    Directory root,
    List<File> sourceFiles, {
    required void Function() onFileCopied,
  }) async {
    final copied = <Map<String, Object?>>[];
    for (final entity in sourceFiles) {
      final relative = p.relative(entity.path, from: root.path);
      if (!_isSafeBundleRelativePath(relative)) {
        throw AtlasFullBackupException(
          'App-owned file escaped its root: ${entity.path}',
        );
      }
      final bundlePath = p.joinAll(['files', rootName, ...p.split(relative)]);
      final target = File(p.joinAll([staging.path, ...p.split(bundlePath)]));
      await target.parent.create(recursive: true);
      final sourceLengthBefore = await entity.length();
      final sourceHashBefore = await _sha256File(entity);
      await _snapshotStepHook?.call('before-copy:$rootName:$relative');
      await entity.copy(target.path);
      await _snapshotStepHook?.call('after-copy:$rootName:$relative');
      final sourceLengthAfter = await entity.length();
      final sourceHashAfter = await _sha256File(entity);
      final manifestEntry = await _fileManifestEntry(
        staging,
        target,
        path: bundlePath,
        kind: 'app_owned_file',
      );
      if (sourceLengthBefore != sourceLengthAfter ||
          sourceHashBefore != sourceHashAfter ||
          manifestEntry['bytes'] != sourceLengthBefore ||
          manifestEntry['sha256'] != sourceHashBefore) {
        throw AtlasFullBackupException(
          'App-owned file changed while it was being copied: ${entity.path}',
        );
      }
      copied.add(manifestEntry);
      onFileCopied();
    }
    return copied;
  }

  Future<List<File>> _listAppOwnedFiles(Directory root) async {
    if (!await root.exists()) return const [];
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        // Never follow or copy a link: it can point outside app-owned storage
        // (including Windows/OneDrive's synthetic `..` reparse point).
        continue;
      }
      if (entity is File) files.add(entity);
    }
    return files;
  }

  Future<void> _verifyOwnedFileInventoryStable(
    Map<String, List<File>> original,
  ) async {
    for (final root in appOwnedRoots.entries) {
      final before = original[root.key]!
          .map((file) => p.normalize(file.path))
          .toSet();
      final after = (await _listAppOwnedFiles(
        root.value,
      )).map((file) => p.normalize(file.path)).toSet();
      if (before.length != after.length || !before.containsAll(after)) {
        throw AtlasFullBackupException(
          'App-owned file inventory changed during backup: ${root.key}',
        );
      }
    }
  }

  Future<Map<String, Object?>> _fileManifestEntry(
    Directory staging,
    File file, {
    required String path,
    required String kind,
  }) async {
    if (!p.isWithin(staging.path, file.path) && file.path != staging.path) {
      throw AtlasFullBackupException(
        'Refusing to hash a file outside staging.',
      );
    }
    return {
      'path': path,
      'kind': kind,
      'bytes': await file.length(),
      'sha256': await _sha256File(file),
    };
  }

  Map<String, Object?> _readDatabaseInventory(File snapshot) {
    final database = sqlite3.open(snapshot.path, mode: OpenMode.readOnly);
    try {
      final quickCheck = database.select('PRAGMA quick_check;');
      final quickCheckValues = quickCheck
          .map((row) => row.values.first.toString())
          .toList(growable: false);
      final foreignKeyCheck = database.select('PRAGMA foreign_key_check;');
      final userVersion = database
          .select('PRAGMA user_version;')
          .single
          .values
          .first;
      final tableNames = database
          .select(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
          )
          .map((row) => row['name'] as String)
          .toList(growable: false);
      final tables = <Map<String, Object?>>[];
      for (final name in tableNames) {
        final count =
            database
                    .select(
                      'SELECT COUNT(*) AS count FROM ${_quoteIdentifier(name)};',
                    )
                    .single['count']
                as int;
        tables.add({'name': name, 'rowCount': count});
      }
      return {
        'quickCheck': quickCheckValues,
        'foreignKeyViolations': foreignKeyCheck.length,
        'userVersion': userVersion,
        'tables': tables,
      };
    } finally {
      database.dispose();
    }
  }

  void _compareInventory(
    Object? expectedRaw,
    Map<String, Object?> actual,
    List<String> errors,
  ) {
    if (expectedRaw is! Map) {
      errors.add('Manifest databaseInventory is missing.');
      return;
    }
    final expected = expectedRaw.map((key, value) => MapEntry('$key', value));
    if (actual['quickCheck'] is! List ||
        !(actual['quickCheck'] as List).every((value) => value == 'ok')) {
      errors.add('SQLite quick_check did not return ok.');
    }
    if (actual['foreignKeyViolations'] != 0) {
      errors.add('SQLite foreign_key_check reported violations.');
    }
    if (jsonEncode(expected['tables']) != jsonEncode(actual['tables'])) {
      errors.add('SQLite table inventory does not match the manifest.');
    }
    if (expected['userVersion'] != actual['userVersion']) {
      errors.add('SQLite user_version does not match the manifest.');
    }
  }

  String _bundleName() {
    final timestamp = _clock().toUtc().toIso8601String().replaceAll(':', '-');
    return 'atlas-full-backup-$timestamp-${_random.nextInt(1 << 32).toRadixString(16)}';
  }

  String _restoreName() {
    final timestamp = _clock().toUtc().toIso8601String().replaceAll(':', '-');
    return 'atlas-staging-restore-$timestamp-${_random.nextInt(1 << 32).toRadixString(16)}';
  }

  static Future<String> _sha256File(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static bool _isSafeBundleRelativePath(String value) {
    if (value.trim().isEmpty || p.isAbsolute(value)) return false;
    final normalized = p.normalize(value);
    return normalized != '.' &&
        !normalized.startsWith('..${p.separator}') &&
        normalized != '..';
  }

  static String _quoteIdentifier(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';
}
