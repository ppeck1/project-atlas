import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class LocalGitVisibilityReport {
  final String requestedPath;
  final String? gitRoot;
  final String? branch;
  final String? headSha;
  final String? remoteUrl;
  final String? comparisonRef;
  final DateTime inspectedAt;
  final int localTrackedCount;
  final int remoteTrackedCount;
  final List<String> localOnlyTrackedPaths;
  final List<String> remoteOnlyTrackedPaths;
  final List<String> changedTrackedPaths;
  final List<String> untrackedPaths;
  final List<String> ignoredPaths;
  final List<String> gitignorePatterns;
  final List<String> suggestedIgnoreEntries;
  final List<String> warnings;

  const LocalGitVisibilityReport({
    required this.requestedPath,
    required this.gitRoot,
    required this.branch,
    required this.headSha,
    required this.remoteUrl,
    required this.comparisonRef,
    required this.inspectedAt,
    required this.localTrackedCount,
    required this.remoteTrackedCount,
    required this.localOnlyTrackedPaths,
    required this.remoteOnlyTrackedPaths,
    required this.changedTrackedPaths,
    required this.untrackedPaths,
    required this.ignoredPaths,
    required this.gitignorePatterns,
    required this.suggestedIgnoreEntries,
    required this.warnings,
  });

  bool get isGitRepository => gitRoot != null;
  bool get hasRemoteComparison =>
      comparisonRef != null && remoteTrackedCount > 0;
  int get localOnlyTrackedCount => localOnlyTrackedPaths.length;
  int get remoteOnlyTrackedCount => remoteOnlyTrackedPaths.length;
  int get changedTrackedCount => changedTrackedPaths.length;
  int get untrackedCount => untrackedPaths.length;
  int get ignoredCount => ignoredPaths.length;
}

class LocalGitVisibilityService {
  final Duration timeout;
  final int maxPathListEntries;

  const LocalGitVisibilityService({
    this.timeout = const Duration(seconds: 6),
    this.maxPathListEntries = 250,
  });

  Future<LocalGitVisibilityReport> inspect(String path) async {
    final warnings = <String>[];
    final requestedPath = path.trim();
    final rootResult = await _gitString(
      requestedPath,
      const ['rev-parse', '--show-toplevel'],
      warnings,
      warnOnFailure: false,
    );
    final gitRoot = rootResult == null ? null : _normalizePath(rootResult);
    if (gitRoot == null || gitRoot.isEmpty) {
      return LocalGitVisibilityReport(
        requestedPath: requestedPath,
        gitRoot: null,
        branch: null,
        headSha: null,
        remoteUrl: null,
        comparisonRef: null,
        inspectedAt: DateTime.now(),
        localTrackedCount: 0,
        remoteTrackedCount: 0,
        localOnlyTrackedPaths: const [],
        remoteOnlyTrackedPaths: const [],
        changedTrackedPaths: const [],
        untrackedPaths: const [],
        ignoredPaths: const [],
        gitignorePatterns: const [],
        suggestedIgnoreEntries: const [],
        warnings: [
          'No readable git repository was found at this path.',
          ...warnings,
        ],
      );
    }

    final branch = await _gitString(gitRoot, const [
      'branch',
      '--show-current',
    ], warnings);
    final headSha = await _gitString(gitRoot, const [
      'rev-parse',
      'HEAD',
    ], warnings);
    final remoteUrl = await _gitString(
      gitRoot,
      const ['remote', 'get-url', 'origin'],
      warnings,
      warnOnFailure: false,
    );
    final upstream = await _gitString(
      gitRoot,
      const ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'],
      warnings,
      warnOnFailure: false,
    );
    final comparisonRef = await _resolveComparisonRef(
      gitRoot,
      branch,
      upstream,
      warnings,
    );

    final localTracked = await _gitPathSet(gitRoot, const [
      'ls-files',
      '-z',
    ], warnings);
    final remoteTracked = comparisonRef == null
        ? <String>{}
        : await _gitPathSet(
            gitRoot,
            ['ls-tree', '-r', '--name-only', '-z', comparisonRef],
            warnings,
            warnOnFailure: false,
          );
    if (comparisonRef != null && remoteTracked.isEmpty) {
      warnings.add(
        'No files were read from $comparisonRef. The remote-tracking ref may be missing locally.',
      );
    }

    final status = await _readStatus(gitRoot, warnings);
    final localOnly = localTracked.difference(remoteTracked).toList()..sort();
    final remoteOnly = remoteTracked.difference(localTracked).toList()..sort();
    final changedTracked = status.changedTracked.toList()..sort();
    final untracked = status.untracked.toList()..sort();
    final ignored = status.ignored.toList()..sort();
    final patterns = await _readGitignorePatterns(gitRoot, warnings);

    return LocalGitVisibilityReport(
      requestedPath: requestedPath,
      gitRoot: gitRoot,
      branch: _blankToNull(branch),
      headSha: _blankToNull(headSha),
      remoteUrl: _blankToNull(remoteUrl),
      comparisonRef: comparisonRef,
      inspectedAt: DateTime.now(),
      localTrackedCount: localTracked.length,
      remoteTrackedCount: remoteTracked.length,
      localOnlyTrackedPaths: _cap(localOnly),
      remoteOnlyTrackedPaths: _cap(remoteOnly),
      changedTrackedPaths: _cap(changedTracked),
      untrackedPaths: _cap(untracked),
      ignoredPaths: _cap(ignored),
      gitignorePatterns: patterns,
      suggestedIgnoreEntries: _suggestIgnoreEntries(untracked, patterns),
      warnings: warnings,
    );
  }

  Future<String?> _resolveComparisonRef(
    String root,
    String? branch,
    String? upstream,
    List<String> warnings,
  ) async {
    final candidates = <String>[
      if (_blankToNull(upstream) != null) upstream!.trim(),
      if (_blankToNull(branch) != null) 'origin/${branch!.trim()}',
      'origin/main',
      'origin/master',
    ];
    for (final ref in candidates) {
      final result = await _gitString(
        root,
        ['rev-parse', '--verify', '--quiet', ref],
        warnings,
        warnOnFailure: false,
      );
      if (_blankToNull(result) != null) return ref;
    }
    if (candidates.isNotEmpty) {
      warnings.add(
        'No local remote-tracking ref was available for comparison. Fetch outside Atlas if this is stale.',
      );
    }
    return null;
  }

  Future<Set<String>> _gitPathSet(
    String root,
    List<String> args,
    List<String> warnings, {
    bool warnOnFailure = true,
  }) async {
    final output = await _gitBytes(
      root,
      args,
      warnings,
      warnOnFailure: warnOnFailure,
    );
    if (output == null || output.isEmpty) return <String>{};
    return output
        .split('\u0000')
        .map(_normalizeRelativePath)
        .whereType<String>()
        .toSet();
  }

  Future<_GitStatusSets> _readStatus(String root, List<String> warnings) async {
    final output = await _gitBytes(root, const [
      'status',
      '--porcelain=v1',
      '-z',
      '--untracked-files=all',
      '--ignored=matching',
    ], warnings);
    if (output == null || output.isEmpty) return const _GitStatusSets();
    final tokens = output.split('\u0000').where((s) => s.isNotEmpty).toList();
    final changedTracked = <String>{};
    final untracked = <String>{};
    final ignored = <String>{};
    var i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token.length < 4) {
        i++;
        continue;
      }
      final code = token.substring(0, 2);
      final path = _normalizeRelativePath(token.substring(3));
      if (path != null) {
        if (code == '??') {
          untracked.add(path);
        } else if (code == '!!') {
          ignored.add(path);
        } else {
          changedTracked.add(path);
        }
      }
      if (code.contains('R') || code.contains('C')) {
        i += 2;
      } else {
        i++;
      }
    }
    return _GitStatusSets(
      changedTracked: changedTracked,
      untracked: untracked,
      ignored: ignored,
    );
  }

  Future<List<String>> _readGitignorePatterns(
    String root,
    List<String> warnings,
  ) async {
    final file = File(p.join(root, '.gitignore'));
    if (!await file.exists()) return const [];
    try {
      final lines = await file.readAsLines();
      return lines
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .toList(growable: false);
    } catch (error) {
      warnings.add('Could not read .gitignore: $error');
      return const [];
    }
  }

  List<String> _suggestIgnoreEntries(
    List<String> untracked,
    List<String> existingPatterns,
  ) {
    final existing = existingPatterns.map((p) => p.trim()).toSet();
    final suggestions = <String>{};
    void add(String pattern) {
      if (pattern.trim().isEmpty) return;
      if (existing.contains(pattern)) return;
      suggestions.add(pattern);
    }

    for (final path in untracked) {
      final normalized = path.replaceAll('\\', '/');
      final segments = normalized.split('/');
      final first = segments.first;
      final basename = segments.last.toLowerCase();
      if (_generatedDirs.contains(first.toLowerCase())) {
        add('$first/');
      }
      if (segments.any((s) => _generatedDirs.contains(s.toLowerCase()))) {
        add(
          '${segments.firstWhere((s) => _generatedDirs.contains(s.toLowerCase()))}/',
        );
      }
      if (basename == '.env' || basename.startsWith('.env.')) {
        add('.env*');
      }
      if (basename.endsWith('.log')) add('*.log');
      if (basename.endsWith('.tmp')) add('*.tmp');
      if (basename.endsWith('.sqlite') || basename.endsWith('.db')) {
        add('*.sqlite');
        add('*.db');
      }
      if (basename.endsWith('.pem') || basename.endsWith('.key')) {
        add('*.pem');
        add('*.key');
      }
    }
    final sorted = suggestions.toList()..sort();
    return _cap(sorted);
  }

  Future<String?> _gitString(
    String root,
    List<String> args,
    List<String> warnings, {
    bool warnOnFailure = true,
  }) async {
    final output = await _gitBytes(
      root,
      args,
      warnings,
      warnOnFailure: warnOnFailure,
    );
    return output?.trim();
  }

  Future<String?> _gitBytes(
    String root,
    List<String> args,
    List<String> warnings, {
    bool warnOnFailure = true,
  }) async {
    Process? process;
    try {
      process = await Process.start('git', args, workingDirectory: root);
      final stdoutFuture = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final stderrFuture = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final exitCode = await process.exitCode.timeout(timeout);
      final stdoutText = await stdoutFuture;
      final stderrText = await stderrFuture;
      if (exitCode == 0) return stdoutText;
      if (warnOnFailure) {
        final trimmed = stderrText.trim();
        warnings.add(
          'git ${args.join(' ')} failed${trimmed.isEmpty ? '' : ': $trimmed'}',
        );
      }
    } on TimeoutException {
      await _terminateTimedOutGitProcess(process);
      warnings.add('git ${args.join(' ')} timed out in $root');
    } on ProcessException catch (error) {
      if (warnOnFailure) {
        warnings.add('git ${args.join(' ')} failed: ${error.message}');
      }
    }
    return null;
  }

  Future<void> _terminateTimedOutGitProcess(Process? process) async {
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill();
    } on Object {
      // Best effort: read-only git inspection should degrade to warnings.
    }
  }

  List<String> _cap(List<String> values) {
    if (values.length <= maxPathListEntries) return values;
    return values.take(maxPathListEntries).toList(growable: false);
  }
}

class _GitStatusSets {
  final Set<String> changedTracked;
  final Set<String> untracked;
  final Set<String> ignored;

  const _GitStatusSets({
    this.changedTracked = const {},
    this.untracked = const {},
    this.ignored = const {},
  });
}

const Set<String> _generatedDirs = {
  '.dart_tool',
  '.gradle',
  '.idea',
  '.mypy_cache',
  '.pytest_cache',
  '.venv',
  '.vs',
  '__pycache__',
  'build',
  'coverage',
  'dist',
  'node_modules',
  'target',
  'venv',
};

String? _blankToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _normalizePath(String path) => path.trim().replaceAll('/', r'\');

String? _normalizeRelativePath(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.replaceAll('\\', '/');
}
