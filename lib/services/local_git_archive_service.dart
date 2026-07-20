import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../db/app_db.dart';
import 'local_git_visibility_service.dart';

typedef LocalGitInspector =
    Future<LocalGitVisibilityReport> Function(String path);
typedef LocalGitArchiveRunner =
    Future<ProcessResult> Function(String workingDirectory);

class LocalGitArchiveCandidate {
  final ProjectRegistryEntry registry;
  final LocalGitVisibilityReport report;

  const LocalGitArchiveCandidate({
    required this.registry,
    required this.report,
  });
}

class LocalGitArchive {
  final List<int> bytes;
  final String archivePath;
  final Map<String, Object?> metadata;

  const LocalGitArchive({
    required this.bytes,
    required this.archivePath,
    required this.metadata,
  });
}

/// Selects a clean local checkout and creates its deterministic Git archive.
///
/// This deliberately has no AppState dependency: callers retain their public
/// export orchestration and can fall back to a cached remote archive.
class LocalGitArchiveService {
  final LocalGitInspector _inspect;
  final LocalGitArchiveRunner _runArchive;
  final bool Function(String value) _isRemotePath;

  LocalGitArchiveService({
    LocalGitInspector? inspect,
    LocalGitArchiveRunner? runArchive,
    required bool Function(String value) isRemotePath,
  }) : _inspect = inspect ?? const LocalGitVisibilityService().inspect,
       _runArchive = runArchive ?? _defaultRunArchive,
       _isRemotePath = isRemotePath;

  static Future<ProcessResult> _defaultRunArchive(String workingDirectory) =>
      Process.run(
        'git',
        const ['archive', '--format=zip', 'HEAD'],
        workingDirectory: workingDirectory,
        stdoutEncoding: null,
        stderrEncoding: utf8,
      );

  Future<LocalGitArchiveCandidate?> findCleanCandidate(
    List<ProjectRegistryEntry> registries, {
    List<String>? warnings,
  }) async {
    final failures = <String>[];
    for (final registry in _orderedRegistries(registries)) {
      if (_isRemotePath(registry.localPath)) {
        failures.add(
          'Git ${registry.displayName}: registered path is a remote URL, not a local folder.',
        );
        continue;
      }
      final report = await _inspect(registry.localPath);
      if (_isArchiveReady(report)) {
        return LocalGitArchiveCandidate(registry: registry, report: report);
      }
      failures.add(_skipReason(registry, report));
    }
    if (warnings != null && failures.isNotEmpty) {
      warnings.addAll(_cappedDistinct(failures, 5));
      if (failures.length > 5) {
        warnings.add(
          'Git: ${failures.length - 5} additional local registry candidate(s) were not archive-ready.',
        );
      }
    }
    return null;
  }

  Future<LocalGitArchive?> buildArchive(
    LocalGitArchiveCandidate candidate,
    List<String> warnings,
  ) async {
    final report = candidate.report;
    final gitRoot = report.gitRoot;
    if (gitRoot == null) return null;
    try {
      final result = await _runArchive(
        gitRoot,
      ).timeout(const Duration(seconds: 15));
      final output = result.stdout;
      if (result.exitCode == 0 && output is List<int> && output.isNotEmpty) {
        const archivePath = 'git/clean_HEAD.zip';
        return LocalGitArchive(
          bytes: output,
          archivePath: archivePath,
          metadata: {
            'source': 'local',
            'registryId': candidate.registry.id,
            'registryDisplayName': candidate.registry.displayName,
            'registryLocalPath': candidate.registry.localPath,
            'gitRoot': report.gitRoot,
            'branch': report.branch,
            'headSha': report.headSha,
            'remoteUrl': report.remoteUrl,
            'archivePath': archivePath,
          },
        );
      }
      warnings.add(
        'Clean git archive failed: ${result.stderr?.toString().trim() ?? 'empty output'}',
      );
    } on TimeoutException {
      warnings.add('Clean git archive timed out.');
    } on ProcessException catch (error) {
      warnings.add('Clean git archive failed: ${error.message}');
    }
    return null;
  }

  bool _isArchiveReady(LocalGitVisibilityReport report) =>
      report.isGitRepository &&
      report.gitRoot != null &&
      report.changedTrackedCount == 0 &&
      report.untrackedCount == 0 &&
      (report.headSha ?? '').trim().isNotEmpty;

  String _skipReason(
    ProjectRegistryEntry registry,
    LocalGitVisibilityReport report,
  ) {
    if (!report.isGitRepository || report.gitRoot == null) {
      return 'Git ${registry.displayName}: no readable git repository at ${registry.localPath}.';
    }
    if (report.changedTrackedCount > 0 || report.untrackedCount > 0) {
      return 'Git ${registry.displayName}: working tree has ${report.changedTrackedCount} changed tracked and ${report.untrackedCount} untracked path(s).';
    }
    return 'Git ${registry.displayName}: git HEAD could not be resolved.';
  }

  List<ProjectRegistryEntry> _orderedRegistries(
    List<ProjectRegistryEntry> registries,
  ) {
    final ordered = [...registries];
    int score(ProjectRegistryEntry entry) {
      var value = 0;
      if (entry.reviewState != 'linked') value += 10;
      if ((entry.gitRoot ?? '').trim().isEmpty) value += 2;
      if (_isRemotePath(entry.localPath)) value += 50;
      return value;
    }

    ordered.sort((a, b) {
      final scoreCompare = score(a).compareTo(score(b));
      if (scoreCompare != 0) return scoreCompare;
      final updatedCompare = b.updatedAt.compareTo(a.updatedAt);
      if (updatedCompare != 0) return updatedCompare;
      return a.displayName.compareTo(b.displayName);
    });
    return ordered;
  }

  List<String> _cappedDistinct(List<String> values, int limit) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      if (!seen.add(value)) continue;
      result.add(value);
      if (result.length >= limit) break;
    }
    return result;
  }
}
