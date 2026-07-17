import 'dart:io';

import '../db/app_db.dart';
import 'github_remote_metadata_service.dart';

typedef GithubArchiveFetcher =
    Future<List<int>> Function(GithubRemoteIdentity identity, String ref);

/// A cached public GitHub remote status that can serve as the source of an
/// archive download for a project export.
class GithubArchiveCandidate {
  final GithubRemoteIdentity identity;
  final String ref;
  final ProjectGitRemoteStatus? status;

  const GithubArchiveCandidate({
    required this.identity,
    required this.ref,
    required this.status,
  });
}

/// Downloads public GitHub repository archives and resolves which cached
/// remote status (if any) is usable as an archive source for a project.
class GithubArchiveService {
  final AppDb db;

  const GithubArchiveService(this.db);

  /// Builds the codeload URI for a public GitHub archive download.
  /// Throws [StateError] when [ref] is blank.
  static Uri publicArchiveUri(GithubRemoteIdentity identity, String ref) {
    final safeRef = ref.trim();
    if (safeRef.isEmpty) {
      throw StateError('GitHub archive ref is required.');
    }
    return Uri.https(
      'codeload.github.com',
      '/${identity.owner}/${identity.repo}/zip/$safeRef',
    );
  }

  /// Default [GithubArchiveFetcher]: downloads a public repository archive
  /// over HTTPS without authentication.
  static Future<List<int>> downloadPublicGithubArchive(
    GithubRemoteIdentity identity,
    String ref,
  ) async {
    final uri = publicArchiveUri(identity, ref);
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub archive request returned HTTP ${response.statusCode}.',
          uri: uri,
        );
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) {
        throw HttpException('GitHub archive response was empty.', uri: uri);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  /// Finds the first cached public GitHub remote status for [projectId] that
  /// resolves to a usable owner/repo identity and archive ref.
  Future<GithubArchiveCandidate?> findCandidateForProject(
    String projectId,
  ) async {
    final statuses = await db.getProjectGitRemoteStatuses(projectId);
    for (final status in statuses) {
      if (status.provider.toLowerCase() != 'github') continue;
      if (status.hasError) continue;
      final visibility = status.visibility?.trim().toLowerCase();
      final isPublic = status.isPrivate == false || visibility == 'public';
      if (!isPublic) continue;
      final identity = GithubRemoteMetadataService.parseGithubRemoteUrl(
        status.remoteUrl,
      );
      if (identity == null) continue;
      final ref =
          _cleanNullableString(status.onlineHeadSha) ??
          _cleanNullableString(status.defaultBranch);
      if (ref == null) continue;
      return GithubArchiveCandidate(
        identity: identity,
        ref: ref,
        status: status,
      );
    }
    return null;
  }

  static String? _cleanNullableString(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }
}
