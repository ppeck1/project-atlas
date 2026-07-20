import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// The on-disk contract for a full Atlas recovery bundle.
const atlasFullBackupManifestSchema = 'project_atlas_full_backup_v1';

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

  AtlasFullBackupService({
    required this.sourceDatabase,
    this.appOwnedRoots = const {},
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure() {
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

  /// Produces a completed recovery bundle under [destinationRoot].
  ///
  /// An interrupted run leaves a clearly named `.incomplete` directory in
  /// place for inspection. It is never presented as a completed backup.
  Future<AtlasFullBackupCreation> createBundle(
    Directory destinationRoot,
  ) async {
    if (!await sourceDatabase.exists()) {
      throw AtlasFullBackupException(
        'The Atlas database does not exist: ${sourceDatabase.path}',
      );
    }
    await destinationRoot.create(recursive: true);

    final name = _bundleName();
    final bundle = Directory(p.join(destinationRoot.path, name));
    final staging = Directory('${bundle.path}.incomplete');
    if (await bundle.exists() || await staging.exists()) {
      throw AtlasFullBackupException(
        'Refusing to overwrite an existing recovery bundle: ${bundle.path}',
      );
    }
    await staging.create(recursive: true);

    final snapshot = File(
      p.join(staging.path, 'database', 'project_atlas.sqlite'),
    );
    await snapshot.parent.create(recursive: true);
    await _createOnlineSnapshot(snapshot);

    final copiedFiles = <Map<String, Object?>>[
      await _fileManifestEntry(
        staging,
        snapshot,
        path: 'database/project_atlas.sqlite',
        kind: 'sqlite_snapshot',
      ),
    ];
    final roots = <Map<String, Object?>>[];
    for (final root in appOwnedRoots.entries) {
      roots.add({'name': root.key, 'sourcePresent': await root.value.exists()});
      copiedFiles.addAll(
        await _copyRootIntoBundle(staging, root.key, root.value),
      );
    }

    final inventory = _readDatabaseInventory(snapshot);
    final manifest = <String, Object?>{
      'schema': atlasFullBackupManifestSchema,
      'createdAt': _clock().toUtc().toIso8601String(),
      'databaseSnapshot': 'database/project_atlas.sqlite',
      'databaseInventory': inventory,
      'appOwnedRoots': roots,
      'files': copiedFiles,
    };
    final manifestFile = File(p.join(staging.path, 'manifest.json'));
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );

    final stagedValidation = await validateBundle(staging);
    if (!stagedValidation.isValid) {
      throw AtlasFullBackupException(
        'The staged recovery bundle failed validation: '
        '${stagedValidation.errors.join('; ')}',
      );
    }
    await staging.rename(bundle.path);
    return AtlasFullBackupCreation(bundle: bundle, manifest: manifest);
  }

  /// Validates checksums, SQLite integrity, foreign keys, and table inventory.
  Future<AtlasFullBackupValidationReport> validateBundle(
    Directory bundle,
  ) async {
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
    final staging = Directory('${restored.path}.incomplete');
    if (await restored.exists() || await staging.exists()) {
      throw AtlasFullBackupException(
        'Refusing to overwrite an existing staging restore: ${restored.path}',
      );
    }
    await staging.create(recursive: true);
    await File(
      p.join(bundle.path, 'manifest.json'),
    ).copy(p.join(staging.path, 'manifest.json'));
    for (final rawEntry in entries) {
      final entry = rawEntry as Map;
      final relativePath = entry['path'] as String;
      final source = File(p.joinAll([bundle.path, ...p.split(relativePath)]));
      final target = File(p.joinAll([staging.path, ...p.split(relativePath)]));
      await target.parent.create(recursive: true);
      await source.copy(target.path);
    }

    final stagingValidation = await validateBundle(staging);
    if (!stagingValidation.isValid) {
      throw AtlasFullBackupException(
        'The staging restore failed validation: '
        '${stagingValidation.errors.join('; ')}',
      );
    }
    await staging.rename(restored.path);
    return AtlasFullBackupStagingRestore(
      bundle: restored,
      validation: stagingValidation,
    );
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
  ) async {
    if (!await root.exists()) return const [];
    final copied = <Map<String, Object?>>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw AtlasFullBackupException(
          'App-owned files may not contain symlinks: ${entity.path}',
        );
      }
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: root.path);
      if (!_isSafeBundleRelativePath(relative)) {
        throw AtlasFullBackupException(
          'App-owned file escaped its root: ${entity.path}',
        );
      }
      final bundlePath = p.joinAll(['files', rootName, ...p.split(relative)]);
      final target = File(p.joinAll([staging.path, ...p.split(bundlePath)]));
      await target.parent.create(recursive: true);
      await entity.copy(target.path);
      copied.add(
        await _fileManifestEntry(
          staging,
          target,
          path: bundlePath,
          kind: 'app_owned_file',
        ),
      );
    }
    return copied;
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
