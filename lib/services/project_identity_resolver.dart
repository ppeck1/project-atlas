import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String? _clean(Object? value) {
  if (value == null) return null;
  final trimmed = '$value'.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, value) => MapEntry('$key', value));
}

Map<String, Object?> _secondarySyncMap(Object? value) {
  final manifest = _objectMap(value);
  if (manifest.containsKey('secondary_sync')) {
    return _objectMap(manifest['secondary_sync']);
  }

  final candidates =
      manifest.entries
          .where(
            (entry) =>
                entry.key.toLowerCase().endsWith('_sync') &&
                entry.key.toLowerCase() != 'secondary_sync' &&
                entry.key.toLowerCase() != 'atlas_sync',
          )
          .toList()
        ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  final compatible = candidates
      .where((entry) => entry.value is Map)
      .map((entry) => _objectMap(entry.value))
      .toList(growable: false);
  return compatible.length == 1 ? compatible.single : const {};
}

List<String> _stringList(Object? value) {
  if (value is! Iterable) return const [];
  return value.map((item) => '$item').toList(growable: false);
}

class AtlasProjectIdentity {
  final String schema;
  final String projectId;
  final String title;
  final String status;
  final Map<String, Object?>? localRegistry;
  final String? localPath;
  final String? repoRoot;
  final Map<String, Object?>? githubRemote;
  final String? capsuleProjectId;
  final String? capsuleDisplayName;
  final List<String> capsuleProfiles;
  final List<String> issues;

  const AtlasProjectIdentity({
    this.schema = 'atlas.project_identity.v1',
    required this.projectId,
    required this.title,
    required this.status,
    required this.localRegistry,
    required this.localPath,
    required this.repoRoot,
    required this.githubRemote,
    required this.capsuleProjectId,
    required this.capsuleDisplayName,
    required this.capsuleProfiles,
    required this.issues,
  });

  Map<String, Object?> toJson() => {
    'schema': schema,
    'projectId': projectId,
    'title': title,
    'status': status,
    'localRegistry': localRegistry,
    'localPath': localPath,
    'repoRoot': repoRoot,
    'githubRemote': githubRemote,
    'capsuleProjectId': capsuleProjectId,
    'capsuleDisplayName': capsuleDisplayName,
    'capsuleProfiles': capsuleProfiles,
    'issues': issues,
  };
}

class AtlasCapsuleStatus {
  final String schema;
  final String projectId;
  final String? localPath;
  final String evidenceAvailability;
  final Map<String, Object?>? projectManifest;
  final Map<String, Object?>? opsCapsule;
  final Map<String, Object?> counts;
  final List<String> warnings;
  final List<String> errors;

  const AtlasCapsuleStatus({
    this.schema = 'atlas.project_capsule_status.v1',
    required this.projectId,
    required this.localPath,
    required this.evidenceAvailability,
    required this.projectManifest,
    required this.opsCapsule,
    required this.counts,
    required this.warnings,
    required this.errors,
  });

  bool get hasMetadata => projectManifest != null || opsCapsule != null;

  Map<String, Object?> toJson() => {
    'schema': schema,
    'projectId': projectId,
    'localPath': localPath,
    'evidenceAvailability': evidenceAvailability,
    'projectManifest': projectManifest,
    'opsCapsule': opsCapsule,
    'canonicalDocs': _objectMap(projectManifest?['canonical_docs']),
    'validation': _objectMap(projectManifest?['validation']),
    'gitPolicy': _objectMap(projectManifest?['git_policy']),
    'atlasSync': _objectMap(projectManifest?['atlas_sync']),
    'secondarySync': _secondarySyncMap(projectManifest),
    'profiles': _stringList(projectManifest?['profiles']),
    'counts': counts,
    'warnings': warnings,
    'errors': errors,
  };
}

class ProjectIdentityResolver {
  const ProjectIdentityResolver();

  Future<AtlasProjectIdentity> resolveIdentity({
    required String projectId,
    required String title,
    required String status,
    required Map<String, Object?>? localRegistry,
    required String? localPath,
    required String? repoRoot,
    required Map<String, Object?>? githubRemote,
  }) async {
    final capsule = await resolveCapsuleStatus(
      projectId: projectId,
      localPath: localPath,
    );
    final manifest = capsule.projectManifest;
    return AtlasProjectIdentity(
      projectId: projectId,
      title: title,
      status: status,
      localRegistry: localRegistry,
      localPath: localPath,
      repoRoot: repoRoot ?? localPath,
      githubRemote: githubRemote,
      capsuleProjectId: _clean(manifest?['project_id']),
      capsuleDisplayName: _clean(manifest?['display_name']),
      capsuleProfiles: _stringList(manifest?['profiles']),
      issues: [...capsule.warnings, ...capsule.errors],
    );
  }

  Future<AtlasCapsuleStatus> resolveCapsuleStatus({
    required String projectId,
    required String? localPath,
  }) async {
    final warnings = <String>[];
    final errors = <String>[];
    if (_clean(localPath) == null) {
      warnings.add('Project is not linked to a local registry entry.');
      return AtlasCapsuleStatus(
        projectId: projectId,
        localPath: null,
        evidenceAvailability: 'not_linked',
        projectManifest: null,
        opsCapsule: null,
        counts: const {},
        warnings: warnings,
        errors: errors,
      );
    }

    final root = Directory(localPath!);
    if (!root.existsSync()) {
      errors.add('Linked local path does not exist: $localPath');
      return AtlasCapsuleStatus(
        projectId: projectId,
        localPath: localPath,
        evidenceAvailability: 'local_path_missing',
        projectManifest: null,
        opsCapsule: null,
        counts: const {},
        warnings: warnings,
        errors: errors,
      );
    }

    final projectDir = Directory(p.join(localPath, '.project'));
    if (!projectDir.existsSync()) {
      warnings.add('Linked local path has no .project capsule directory.');
      return AtlasCapsuleStatus(
        projectId: projectId,
        localPath: localPath,
        evidenceAvailability: 'metadata_missing',
        projectManifest: null,
        opsCapsule: null,
        counts: const {},
        warnings: warnings,
        errors: errors,
      );
    }

    final manifest = _readJsonObject(
      File(p.join(projectDir.path, 'project_manifest.json')),
      'project_manifest',
      warnings,
      errors,
    );
    final opsCapsule = _readJsonObject(
      File(p.join(projectDir.path, 'ops_capsule.json')),
      'ops_capsule',
      warnings,
      errors,
    );
    final secondaryOutboxCounts = _countSecondaryOutboxes(projectDir, warnings);
    final counts = <String, Object?>{
      'runLedgers': _countDirectoryFiles(
        Directory(p.join(projectDir.path, 'runs')),
      ),
      'atlasOutboxPending': _countJsonFiles(
        Directory(p.join(projectDir.path, 'atlas_outbox')),
      ),
      'atlasOutboxImported': _countJsonFiles(
        Directory(p.join(projectDir.path, 'atlas_outbox', 'imported')),
      ),
      'atlasOutboxRejected': _countJsonFiles(
        Directory(p.join(projectDir.path, 'atlas_outbox', 'rejected')),
      ),
      ...secondaryOutboxCounts,
    };
    final hasLocalEvidence = counts.values.whereType<int>().any(
      (count) => count > 0,
    );
    final availability = manifest == null && opsCapsule == null
        ? 'metadata_missing'
        : hasLocalEvidence
        ? 'local_evidence_present'
        : 'metadata_present';
    if (manifest == null && opsCapsule == null) {
      warnings.add('Capsule metadata files are missing or unreadable.');
    }

    return AtlasCapsuleStatus(
      projectId: projectId,
      localPath: localPath,
      evidenceAvailability: availability,
      projectManifest: manifest,
      opsCapsule: opsCapsule,
      counts: counts,
      warnings: warnings,
      errors: errors,
    );
  }

  Map<String, Object?>? _readJsonObject(
    File file,
    String label,
    List<String> warnings,
    List<String> errors,
  ) {
    if (!file.existsSync()) {
      warnings.add('$label file is missing: ${file.path}');
      return null;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', value));
      }
      errors.add('$label file is not a JSON object: ${file.path}');
    } on FormatException catch (error) {
      errors.add('$label file has invalid JSON: ${error.message}');
    } on FileSystemException catch (error) {
      errors.add('$label file could not be read: ${error.message}');
    }
    return null;
  }

  int _countJsonFiles(Directory directory) => _countDirectoryFiles(
    directory,
    include: (entity) => entity is File && entity.path.endsWith('.json'),
  );

  Map<String, int> _countSecondaryOutboxes(
    Directory projectDir,
    List<String> warnings,
  ) {
    var pending = 0;
    var imported = 0;
    var rejected = 0;
    try {
      final discovered = projectDir
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where((directory) {
            final name = p.basename(directory.path).toLowerCase();
            return name.endsWith('_outbox') && name != 'atlas_outbox';
          })
          .toList(growable: false);
      final preferred = discovered
          .where(
            (directory) =>
                p.basename(directory.path).toLowerCase() == 'secondary_outbox',
          )
          .toList(growable: false);
      final directories = preferred.length == 1
          ? preferred
          : preferred.length > 1
          ? const <Directory>[]
          : discovered.length == 1
          ? discovered
          : const <Directory>[];
      if (preferred.length > 1 ||
          (preferred.isEmpty && discovered.length > 1)) {
        warnings.add(
          'Multiple secondary outbox candidates were found; counts were skipped.',
        );
      }
      for (final directory in directories) {
        pending += _countJsonFiles(directory);
        imported += _countJsonFiles(
          Directory(p.join(directory.path, 'imported')),
        );
        rejected += _countJsonFiles(
          Directory(p.join(directory.path, 'rejected')),
        );
      }
    } on FileSystemException {
      // Missing or unreadable optional integration evidence is counted as 0.
    }
    return {
      'secondaryOutboxPending': pending,
      'secondaryOutboxImported': imported,
      'secondaryOutboxRejected': rejected,
    };
  }

  int _countDirectoryFiles(
    Directory directory, {
    bool Function(FileSystemEntity entity)? include,
  }) {
    if (!directory.existsSync()) return 0;
    try {
      return directory
          .listSync(followLinks: false)
          .where(include ?? (entity) => entity is File)
          .length;
    } on FileSystemException {
      return 0;
    }
  }
}
