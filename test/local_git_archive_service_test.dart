import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/local_git_archive_service.dart';
import 'package:project_atlas/services/local_git_visibility_service.dart';

void main() {
  final now = DateTime(2026, 7, 18);

  ProjectRegistryEntry registry({
    required String id,
    required String path,
    required DateTime updatedAt,
    String reviewState = 'linked',
    String? gitRoot,
  }) => ProjectRegistryEntry(
    id: id,
    displayName: id,
    localPath: path,
    gitRoot: gitRoot,
    classification: 'project',
    reviewState: reviewState,
    sourceRole: 'primary',
    sourceType: 'local',
    lifecycleState: 'active',
    authorityLevel: 'operator',
    precedence: 0,
    createdAt: now,
    updatedAt: updatedAt,
  );

  LocalGitVisibilityReport report({
    String? root = 'C:/repo',
    String? head = 'abc123',
    int changed = 0,
    int untracked = 0,
  }) => LocalGitVisibilityReport(
    requestedPath: root ?? 'C:/missing',
    gitRoot: root,
    branch: 'main',
    headSha: head,
    remoteUrl: null,
    comparisonRef: null,
    inspectedAt: now,
    localTrackedCount: 1,
    remoteTrackedCount: 0,
    localOnlyTrackedPaths: const [],
    remoteOnlyTrackedPaths: const [],
    changedTrackedPaths: List.filled(changed, 'changed.txt'),
    untrackedPaths: List.filled(untracked, 'new.txt'),
    ignoredPaths: const [],
    gitignorePatterns: const [],
    suggestedIgnoreEntries: const [],
    warnings: const [],
  );

  test(
    'prefers an archive-ready linked local registry over a remote URL',
    () async {
      final inspected = <String>[];
      final service = LocalGitArchiveService(
        isRemotePath: (path) => path.startsWith('https://'),
        inspect: (path) async {
          inspected.add(path);
          return report(root: path);
        },
      );

      final candidate = await service.findCleanCandidate([
        registry(
          id: 'remote',
          path: 'https://example.test/repo.git',
          updatedAt: now.add(const Duration(minutes: 1)),
        ),
        registry(
          id: 'local',
          path: 'C:/repo',
          gitRoot: 'C:/repo',
          updatedAt: now,
        ),
      ]);

      expect(candidate?.registry.id, 'local');
      expect(inspected, ['C:/repo']);
    },
  );

  test(
    'reports a git archive process failure without producing an archive',
    () async {
      final service = LocalGitArchiveService(
        isRemotePath: (_) => false,
        inspect: (_) async => report(),
        runArchive: (_) async => ProcessResult(1, 1, const <int>[], 'blocked'),
      );
      final candidate = await service.findCleanCandidate([
        registry(id: 'local', path: 'C:/repo', updatedAt: now),
      ]);
      final warnings = <String>[];

      final archive = await service.buildArchive(candidate!, warnings);

      expect(archive, isNull);
      expect(warnings.single, contains('blocked'));
    },
  );
}
