import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef GhApiRunner = Future<ProcessResult> Function(List<String> args);

class GithubRemoteIdentity {
  final String owner;
  final String repo;
  final String remoteUrl;

  const GithubRemoteIdentity({
    required this.owner,
    required this.repo,
    required this.remoteUrl,
  });

  String get provider => 'github';
  String get fullName => '$owner/$repo';
  String get htmlUrl => 'https://github.com/$owner/$repo';
}

class GithubRemoteMetadataResult {
  final GithubRemoteIdentity identity;
  final String? visibility;
  final String? defaultBranch;
  final String? onlineHeadSha;
  final bool? isPrivate;
  final bool? isFork;
  final bool? isArchived;
  final String? htmlUrl;
  final DateTime checkedAt;
  final DateTime? remoteUpdatedAt;
  final DateTime? remotePushedAt;
  final String? error;
  final String? rawJson;

  const GithubRemoteMetadataResult({
    required this.identity,
    required this.visibility,
    required this.defaultBranch,
    required this.onlineHeadSha,
    required this.isPrivate,
    required this.isFork,
    required this.isArchived,
    required this.htmlUrl,
    required this.checkedAt,
    required this.remoteUpdatedAt,
    required this.remotePushedAt,
    required this.error,
    required this.rawJson,
  });

  bool get hasError => error != null && error!.trim().isNotEmpty;
}

class GithubRemoteMetadataService {
  final GhApiRunner runner;
  final Duration timeout;

  GithubRemoteMetadataService({
    GhApiRunner? runner,
    this.timeout = const Duration(seconds: 8),
  }) : runner = runner ?? _defaultRunner;

  static Future<ProcessResult> _defaultRunner(List<String> args) =>
      Process.run('gh', args);

  static GithubRemoteIdentity? parseGithubRemoteUrl(String? remoteUrl) {
    final trimmed = remoteUrl?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final sanitized = _sanitizeRemoteUrl(trimmed);
    final patterns = [
      RegExp(
        r'github\.com[:/]([^/]+)/([^/\s]+?)(?:\.git)?$',
        caseSensitive: false,
      ),
      RegExp(
        r'^git@github\.com:([^/]+)/([^/\s]+?)(?:\.git)?$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(sanitized);
      if (match == null) continue;
      final owner = match.group(1)?.trim();
      final repo = match.group(2)?.replaceAll(RegExp(r'\.git$'), '').trim();
      if (owner != null &&
          owner.isNotEmpty &&
          repo != null &&
          repo.isNotEmpty) {
        return GithubRemoteIdentity(
          owner: owner,
          repo: repo,
          remoteUrl: sanitized,
        );
      }
    }
    return null;
  }

  static String _sanitizeRemoteUrl(String remoteUrl) {
    try {
      final uri = Uri.parse(remoteUrl);
      if (uri.hasScheme &&
          uri.host.toLowerCase() == 'github.com' &&
          uri.userInfo.isNotEmpty) {
        return uri.replace(userInfo: '').toString();
      }
    } catch (e) {
      debugPrint('[Atlas] GithubRemoteMetadataService._sanitizeRemoteUrl: URI parse failed for "$remoteUrl": $e');
    }
    return remoteUrl;
  }

  Future<GithubRemoteMetadataResult> fetch(
    GithubRemoteIdentity identity,
  ) async {
    final checkedAt = DateTime.now();
    final repoResult = await _runGh([
      'api',
      'repos/${identity.owner}/${identity.repo}',
    ]);
    if (repoResult.exitCode != 0) {
      return GithubRemoteMetadataResult(
        identity: identity,
        visibility: null,
        defaultBranch: null,
        onlineHeadSha: null,
        isPrivate: null,
        isFork: null,
        isArchived: null,
        htmlUrl: identity.htmlUrl,
        checkedAt: checkedAt,
        remoteUpdatedAt: null,
        remotePushedAt: null,
        error: _processError(repoResult),
        rawJson: _stringOutput(repoResult.stdout),
      );
    }

    Map<String, Object?> decoded;
    try {
      final raw = _stringOutput(repoResult.stdout);
      final parsed = jsonDecode(raw);
      if (parsed is! Map) {
        throw const FormatException('GitHub API response was not an object.');
      }
      decoded = Map<String, Object?>.from(parsed);
    } catch (error) {
      return GithubRemoteMetadataResult(
        identity: identity,
        visibility: null,
        defaultBranch: null,
        onlineHeadSha: null,
        isPrivate: null,
        isFork: null,
        isArchived: null,
        htmlUrl: identity.htmlUrl,
        checkedAt: checkedAt,
        remoteUpdatedAt: null,
        remotePushedAt: null,
        error: 'Could not parse GitHub repository metadata: $error',
        rawJson: _stringOutput(repoResult.stdout),
      );
    }

    final defaultBranch = _string(decoded['default_branch']);
    final onlineHeadSha = defaultBranch == null
        ? null
        : await _fetchBranchHeadSha(identity, defaultBranch);
    final isPrivate = _bool(decoded['private']);
    final visibility =
        _string(decoded['visibility']) ??
        (isPrivate == true ? 'private' : 'public');

    return GithubRemoteMetadataResult(
      identity: identity,
      visibility: visibility,
      defaultBranch: defaultBranch,
      onlineHeadSha: onlineHeadSha,
      isPrivate: isPrivate,
      isFork: _bool(decoded['fork']),
      isArchived: _bool(decoded['archived']),
      htmlUrl: _string(decoded['html_url']) ?? identity.htmlUrl,
      checkedAt: checkedAt,
      remoteUpdatedAt: _date(decoded['updated_at']),
      remotePushedAt: _date(decoded['pushed_at']),
      error: null,
      rawJson: jsonEncode(decoded),
    );
  }

  Future<String?> _fetchBranchHeadSha(
    GithubRemoteIdentity identity,
    String branch,
  ) async {
    final result = await _runGh([
      'api',
      'repos/${identity.owner}/${identity.repo}/commits/$branch',
      '--jq',
      '.sha',
    ]);
    if (result.exitCode != 0) return null;
    final sha = _stringOutput(result.stdout).trim();
    return sha.isEmpty ? null : sha;
  }

  Future<ProcessResult> _runGh(List<String> args) =>
      runner(args).timeout(timeout);

  static String _processError(ProcessResult result) {
    final stderr = _stringOutput(result.stderr).trim();
    final stdout = _stringOutput(result.stdout).trim();
    final details = stderr.isNotEmpty ? stderr : stdout;
    return details.isEmpty
        ? 'gh api exited with code ${result.exitCode}'
        : details;
  }

  static String _stringOutput(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is List<int>) return utf8.decode(value, allowMalformed: true);
    return '$value';
  }

  static String? _string(Object? value) {
    final trimmed = value?.toString().trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static bool? _bool(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return null;
  }

  static DateTime? _date(Object? value) {
    final raw = _string(value);
    return raw == null ? null : DateTime.tryParse(raw);
  }
}
