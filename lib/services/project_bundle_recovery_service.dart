import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Validates a project bundle and writes a separate, inspectable recovery
/// staging folder. It never imports into, replaces, or changes the live Atlas
/// database.
class ProjectBundleRecoveryService {
  static const _bundleSchema = 'project_atlas_project_bundle_v1';
  static const _manifestSchema = 'project_atlas_project_bundle_manifest_v1';

  Future<ProjectBundleStagingReport> validateAndStage(
    File bundle,
    Directory destinationRoot, {
    String? expectedProjectId,
  }) async {
    if (!await bundle.exists()) {
      throw ProjectBundleRecoveryException('Project bundle was not found.');
    }

    final archive = ZipDecoder().decodeBytes(
      await bundle.readAsBytes(),
      verify: true,
    );
    final entries = <String, ArchiveFile>{};
    for (final entry in archive) {
      final name = entry.name.replaceAll('\\', '/');
      if (!_isSafeArchivePath(name)) {
        throw ProjectBundleRecoveryException(
          'Project bundle contains an unsafe archive path: $name',
        );
      }
      if (entry.isFile && entries.putIfAbsent(name, () => entry) != entry) {
        throw ProjectBundleRecoveryException(
          'Project bundle contains a duplicate archive path: $name',
        );
      }
    }

    final payload = _readJson(entries, 'project_bundle.json');
    final manifest = _readJson(entries, 'manifest/export_manifest.json');
    if (payload['schema'] != _bundleSchema) {
      throw ProjectBundleRecoveryException(
        'Unsupported project bundle schema.',
      );
    }
    if (manifest['schema'] != _manifestSchema) {
      throw ProjectBundleRecoveryException(
        'Unsupported project bundle manifest.',
      );
    }
    final project = _map(payload['project'], 'project');
    final manifestProject = _map(manifest['project'], 'manifest project');
    final projectId = _text(project['id'], 'project id');
    final projectTitle = _text(project['title'], 'project title');
    if (manifestProject['id'] != projectId) {
      throw ProjectBundleRecoveryException(
        'The manifest and project payload identify different projects.',
      );
    }
    if (expectedProjectId != null && expectedProjectId != projectId) {
      throw ProjectBundleRecoveryException(
        'This bundle belongs to a different selected project.',
      );
    }
    _validateContents(entries, _map(manifest['contents'], 'manifest contents'));

    await destinationRoot.create(recursive: true);
    final stage = Directory(
      p.join(
        destinationRoot.path,
        'project-recovery-stage-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}-${_safeStem(projectTitle)}',
      ),
    );
    await stage.create(recursive: true);
    var stagedFiles = 0;
    for (final entry in entries.values) {
      final output = File(p.joinAll([stage.path, ...entry.name.split('/')]));
      await output.parent.create(recursive: true);
      await output.writeAsBytes(_entryBytes(entry), flush: true);
      stagedFiles++;
    }
    final report = ProjectBundleStagingReport(
      sourceBundlePath: bundle.path,
      stagingPath: stage.path,
      projectId: projectId,
      projectTitle: projectTitle,
      stagedFiles: stagedFiles,
    );
    await File(p.join(stage.path, 'project_bundle_staged.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report.toJson()),
      flush: true,
    );
    return report;
  }

  Map<String, dynamic> _readJson(
    Map<String, ArchiveFile> entries,
    String path,
  ) {
    final entry = entries[path];
    if (entry == null) {
      throw ProjectBundleRecoveryException('Project bundle is missing $path.');
    }
    try {
      final decoded = jsonDecode(utf8.decode(_entryBytes(entry)));
      return _map(decoded, path);
    } catch (error) {
      if (error is ProjectBundleRecoveryException) rethrow;
      throw ProjectBundleRecoveryException('Project bundle has invalid $path.');
    }
  }

  void _validateContents(
    Map<String, ArchiveFile> entries,
    Map<String, dynamic> contents,
  ) {
    for (final value in contents.values) {
      if (value is String && value.isNotEmpty && !entries.containsKey(value)) {
        throw ProjectBundleRecoveryException(
          'Manifest references a missing archive entry: $value',
        );
      }
    }
    final documentFiles = contents['documentFiles'];
    final mediaFiles = contents['mediaFiles'];
    if (documentFiles is int &&
        entries.keys.where((name) => name.startsWith('documents/')).length !=
            documentFiles) {
      throw ProjectBundleRecoveryException(
        'Document file count does not match the project bundle manifest.',
      );
    }
    if (mediaFiles is int &&
        entries.keys.where((name) => name.startsWith('media/')).length !=
            mediaFiles) {
      throw ProjectBundleRecoveryException(
        'Media file count does not match the project bundle manifest.',
      );
    }
  }

  bool _isSafeArchivePath(String path) {
    if (path.isEmpty || path.startsWith('/') || path.startsWith('\\')) {
      return false;
    }
    return !path
        .split('/')
        .any((part) => part.isEmpty || part == '.' || part == '..');
  }

  Map<String, dynamic> _map(Object? value, String label) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw ProjectBundleRecoveryException(
      'Project bundle has an invalid $label.',
    );
  }

  String _text(Object? value, String label) {
    if (value is String && value.trim().isNotEmpty) return value;
    throw ProjectBundleRecoveryException(
      'Project bundle has an invalid $label.',
    );
  }

  String _safeStem(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return safe.isEmpty ? 'project' : safe;
  }

  List<int> _entryBytes(ArchiveFile entry) {
    final content = entry.content;
    if (content is List<int>) return content;
    throw ProjectBundleRecoveryException(
      'Project bundle entry could not be read: ${entry.name}',
    );
  }
}

class ProjectBundleRecoveryException implements Exception {
  final String message;

  const ProjectBundleRecoveryException(this.message);

  @override
  String toString() => 'ProjectBundleRecoveryException: $message';
}

class ProjectBundleStagingReport {
  final String sourceBundlePath;
  final String stagingPath;
  final String projectId;
  final String projectTitle;
  final int stagedFiles;

  const ProjectBundleStagingReport({
    required this.sourceBundlePath,
    required this.stagingPath,
    required this.projectId,
    required this.projectTitle,
    required this.stagedFiles,
  });

  Map<String, Object?> toJson() => {
    'schema': 'project_atlas_project_bundle_stage_v1',
    'sourceBundlePath': sourceBundlePath,
    'stagingPath': stagingPath,
    'project': {'id': projectId, 'title': projectTitle},
    'stagedFiles': stagedFiles,
    'stagedAt': DateTime.now().toUtc().toIso8601String(),
    'liveAtlasChanged': false,
  };
}
