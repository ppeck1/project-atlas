import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const defaultOperationsRoot = '.';

const localOperationsMarkerFiles = <String>{
  '.git',
  '.project',
  'README.md',
  'ACTIVE_TASK.md',
  'CURRENT_STATE.md',
  'AGENTS.md',
  'CLAUDE.md',
  'pyproject.toml',
  'package.json',
  'pubspec.yaml',
};

const localOperationsClassifications = <String>{
  'active_project',
  'knowledge_store',
  'data_root',
  'sdk_vendor',
  'archive_export',
  'needs_review',
};

bool isUnsafeOperationsScanRoot(String path) {
  final normalized = path.trim().replaceAll('/', r'\');
  if (normalized.isEmpty) return true;
  return RegExp(r'^[A-Za-z]:\\?$').hasMatch(normalized) || normalized == r'\';
}

class LocalOperationsScanner {
  final List<String> roots;
  final int maxDepth;
  final Duration gitTimeout;

  const LocalOperationsScanner({
    this.roots = const [defaultOperationsRoot],
    this.maxDepth = 2,
    this.gitTimeout = const Duration(seconds: 4),
  });

  Future<LocalOperationsScanResult> scan() async {
    final startedAt = DateTime.now();
    final observations = <LocalProjectObservationResult>[];
    final warnings = <String>[];
    var totalSeen = 0;
    var ignored = 0;

    for (final configuredRoot in roots) {
      final rootPath = configuredRoot.trim();
      if (isUnsafeOperationsScanRoot(rootPath)) {
        warnings.add('Root is too broad and was skipped: $configuredRoot');
        continue;
      }
      final root = Directory(rootPath);
      if (!root.existsSync()) {
        warnings.add('Root does not exist: $rootPath');
        continue;
      }
      final stack = <_PendingDirectory>[_PendingDirectory(root, 0)];
      while (stack.isNotEmpty) {
        final pending = stack.removeLast();
        final dir = pending.directory;
        final name = p.basename(dir.path);
        if (pending.depth > 0 && _isHardExcludedDirectoryName(name)) {
          ignored++;
          continue;
        }
        totalSeen++;

        final markerFiles = _detectMarkers(dir);
        final hasMarkers = markerFiles.isNotEmpty;
        GitFacts gitFacts = const GitFacts();
        final repoLike = markerFiles.contains('.git');
        if (repoLike) {
          gitFacts = await _readGitFacts(dir);
        }
        if (hasMarkers) {
          final classification = _classify(
            dir,
            markerFiles,
            gitFacts: gitFacts,
          );
          observations.add(
            LocalProjectObservationResult(
              observedPath: dir.path,
              displayName: _displayName(dir),
              classificationGuess: classification.classification,
              confidence: classification.confidence,
              markerFiles: markerFiles,
              branch: gitFacts.branch,
              headSha: gitFacts.headSha,
              dirtyCount: gitFacts.dirtyCount,
              remoteUrl: gitFacts.remoteUrl,
              gitRoot: gitFacts.gitRoot,
              warnings: gitFacts.warnings,
              observedAt: DateTime.now(),
            ),
          );
        }

        if (_shouldStopDescending(markerFiles, gitFacts)) continue;
        if (pending.depth >= maxDepth) continue;
        try {
          for (final child in dir.listSync(followLinks: false)) {
            if (child is Directory) {
              stack.add(_PendingDirectory(child, pending.depth + 1));
            }
          }
        } on FileSystemException catch (error) {
          warnings.add('Unable to list ${dir.path}: ${error.message}');
        }
      }
    }

    return LocalOperationsScanResult(
      roots: roots,
      startedAt: startedAt,
      completedAt: DateTime.now(),
      totalSeen: totalSeen,
      ignored: ignored,
      observations: observations,
      warnings: warnings,
    );
  }

  List<String> _detectMarkers(Directory dir) {
    final found = <String>[];
    for (final marker in localOperationsMarkerFiles) {
      final markerPath = p.join(dir.path, marker);
      if (marker == '.git') {
        if (Directory(markerPath).existsSync() ||
            File(markerPath).existsSync()) {
          found.add(marker);
        }
        continue;
      }
      if (marker == '.project') {
        if (Directory(markerPath).existsSync()) {
          found.add(marker);
        }
        continue;
      }
      if (File(markerPath).existsSync()) {
        found.add(marker);
      }
    }
    found.sort();
    return found;
  }

  bool _shouldStopDescending(List<String> markerFiles, GitFacts gitFacts) {
    if (markerFiles.contains('ACTIVE_TASK.md') ||
        markerFiles.contains('.project') ||
        markerFiles.contains('CURRENT_STATE.md') ||
        markerFiles.contains('AGENTS.md') ||
        markerFiles.contains('CLAUDE.md') ||
        markerFiles.contains('pyproject.toml') ||
        markerFiles.contains('package.json') ||
        markerFiles.contains('pubspec.yaml')) {
      return true;
    }
    if (!markerFiles.contains('.git')) return false;
    return markerFiles.any((marker) => marker != '.git');
  }

  String _displayName(Directory dir) {
    final name = p.basename(dir.path).trim();
    return name.isEmpty ? dir.path : name;
  }

  _Classification _classify(
    Directory dir,
    List<String> markerFiles, {
    required GitFacts gitFacts,
  }) {
    final lowerPath = dir.path.toLowerCase();
    final lowerName = p.basename(dir.path).toLowerCase();

    if (_looksLikeSdkVendor(lowerName, lowerPath)) {
      return const _Classification('sdk_vendor', 90);
    }
    if (_looksLikeDataRoot(lowerName, lowerPath)) {
      return const _Classification('data_root', 90);
    }
    if (_looksLikeArchiveExport(lowerName, lowerPath)) {
      return const _Classification('archive_export', 85);
    }
    if (markerFiles.contains('.git') && gitFacts.gitRoot == null) {
      return const _Classification('needs_review', 55);
    }
    if (markerFiles.contains('ACTIVE_TASK.md') ||
        markerFiles.contains('.project') ||
        markerFiles.contains('CURRENT_STATE.md') ||
        markerFiles.contains('AGENTS.md') ||
        markerFiles.contains('CLAUDE.md')) {
      return const _Classification('active_project', 92);
    }
    if (markerFiles.contains('.git') ||
        markerFiles.contains('pyproject.toml') ||
        markerFiles.contains('package.json') ||
        markerFiles.contains('pubspec.yaml')) {
      return const _Classification('active_project', 82);
    }
    if (markerFiles.contains('README.md')) {
      return const _Classification('knowledge_store', 65);
    }
    return const _Classification('needs_review', 45);
  }

  bool _looksLikeSdkVendor(String lowerName, String lowerPath) {
    return lowerName == 'flutter' ||
        lowerName == 'openhands-main' ||
        lowerPath.contains(r'\node_modules') ||
        lowerPath.contains(r'\third_party');
  }

  bool _looksLikeDataRoot(String lowerName, String lowerPath) {
    return lowerName.contains('dataroot') ||
        lowerName.contains('_watch') ||
        lowerName.contains('snapshots') ||
        lowerPath.contains(r'\boh_db_snapshots');
  }

  bool _looksLikeArchiveExport(String lowerName, String lowerPath) {
    return lowerName.contains('export') ||
        lowerName.contains('archive') ||
        lowerName.endsWith('.zip') ||
        lowerName.endsWith('.rar') ||
        lowerPath.contains(r'\exports\');
  }

  bool _isHardExcludedDirectoryName(String name) {
    final lower = name.toLowerCase();
    return lower == '.git' ||
        lower == 'node_modules' ||
        lower == '.dart_tool' ||
        lower == 'build' ||
        lower == '.venv' ||
        lower == 'venv' ||
        lower == '__pycache__' ||
        lower == 'dist' ||
        lower == 'coverage' ||
        lower == 'target' ||
        lower == '.pytest_cache' ||
        lower == '.mypy_cache' ||
        lower == '.gradle' ||
        lower == '.idea' ||
        lower == '.vs';
  }

  Future<GitFacts> _readGitFacts(Directory dir) async {
    final warnings = <String>[];
    final gitRoot = await _gitString(dir, [
      'rev-parse',
      '--show-toplevel',
    ], warnings);
    if (gitRoot == null) {
      return GitFacts(warnings: warnings);
    }
    final branch = await _gitString(dir, [
      'branch',
      '--show-current',
    ], warnings);
    final headSha = await _gitString(dir, [
      'log',
      '-1',
      '--format=%H',
    ], warnings);
    final status = await _gitString(
      dir,
      ['status', '--porcelain'],
      warnings,
      allowMultiline: true,
    );
    final remoteUrl = await _gitString(dir, [
      'remote',
      'get-url',
      'origin',
    ], warnings);

    return GitFacts(
      gitRoot: gitRoot,
      branch: branch,
      headSha: headSha,
      dirtyCount: status
          ?.split(RegExp(r'\r?\n'))
          .where((line) => line.trim().isNotEmpty)
          .length,
      remoteUrl: remoteUrl,
      warnings: warnings,
    );
  }

  Future<String?> _gitString(
    Directory dir,
    List<String> args,
    List<String> warnings, {
    bool allowMultiline = false,
  }) async {
    Process? process;
    try {
      process = await Process.start('git', args, workingDirectory: dir.path);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(gitTimeout);
      final stderrText = await stderr;
      final stdoutText = await stdout;
      if (exitCode != 0) {
        final message = _safeProcessText(stderrText);
        if (message.isNotEmpty) {
          warnings.add('git ${args.join(' ')} failed: $message');
        }
        return null;
      }
      final output = _safeProcessText(stdoutText);
      if (output.trim().isEmpty) return allowMultiline ? '' : null;
      return allowMultiline
          ? output.trimRight()
          : output.trim().split('\n').first.trim();
    } on TimeoutException {
      await _terminateTimedOutGitProcess(process);
      warnings.add('git ${args.join(' ')} timed out in ${dir.path}');
      return null;
    } on ProcessException catch (error) {
      warnings.add('git ${args.join(' ')} failed: ${error.message}');
      return null;
    }
  }

  Future<void> _terminateTimedOutGitProcess(Process? process) async {
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill();
    } on Object {
      // Best effort: the timeout path should never throw while scanning.
    }
  }

  String _safeProcessText(Object? value) =>
      value?.toString().replaceAll('\u0000', '').trim() ?? '';
}

class LocalOperationsScanResult {
  final List<String> roots;
  final DateTime startedAt;
  final DateTime completedAt;
  final int totalSeen;
  final int ignored;
  final List<LocalProjectObservationResult> observations;
  final List<String> warnings;

  const LocalOperationsScanResult({
    required this.roots,
    required this.startedAt,
    required this.completedAt,
    required this.totalSeen,
    required this.ignored,
    required this.observations,
    required this.warnings,
  });

  Map<String, Object?> toJson() => {
    'roots': roots,
    'startedAt': startedAt.toIso8601String(),
    'completedAt': completedAt.toIso8601String(),
    'totalSeen': totalSeen,
    'ignored': ignored,
    'candidates': observations.length,
    'warnings': warnings,
    'observations': observations.map((item) => item.toJson()).toList(),
  };
}

class LocalProjectObservationResult {
  final String observedPath;
  final String displayName;
  final String classificationGuess;
  final int confidence;
  final List<String> markerFiles;
  final String? branch;
  final String? headSha;
  final int? dirtyCount;
  final String? remoteUrl;
  final String? gitRoot;
  final List<String> warnings;
  final DateTime observedAt;

  const LocalProjectObservationResult({
    required this.observedPath,
    required this.displayName,
    required this.classificationGuess,
    required this.confidence,
    required this.markerFiles,
    required this.branch,
    required this.headSha,
    required this.dirtyCount,
    required this.remoteUrl,
    required this.gitRoot,
    required this.warnings,
    required this.observedAt,
  });

  Map<String, Object?> toJson() => {
    'observedPath': observedPath,
    'displayName': displayName,
    'classificationGuess': classificationGuess,
    'confidence': confidence,
    'markerFiles': markerFiles,
    'branch': branch,
    'headSha': headSha,
    'dirtyCount': dirtyCount,
    'remoteUrl': remoteUrl,
    'gitRoot': gitRoot,
    'warnings': warnings,
    'observedAt': observedAt.toIso8601String(),
  };

  String toRawJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class GitFacts {
  final String? gitRoot;
  final String? branch;
  final String? headSha;
  final int? dirtyCount;
  final String? remoteUrl;
  final List<String> warnings;

  const GitFacts({
    this.gitRoot,
    this.branch,
    this.headSha,
    this.dirtyCount,
    this.remoteUrl,
    this.warnings = const [],
  });
}

class _PendingDirectory {
  final Directory directory;
  final int depth;

  const _PendingDirectory(this.directory, this.depth);
}

class _Classification {
  final String classification;
  final int confidence;

  const _Classification(this.classification, this.confidence);
}
