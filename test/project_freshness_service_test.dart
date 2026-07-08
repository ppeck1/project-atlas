import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/project_freshness_service.dart';

void main() {
  group('ProjectFreshnessService', () {
    test('classifies missing observation and stale GitHub cache', () {
      final project = Project(
        id: 'atlas',
        title: 'Project Atlas',
        createdAt: DateTime(2026, 6, 29),
        status: 'active',
        priority: 'high',
      );
      final registry = ProjectRegistryEntry(
        id: 'registry-atlas',
        atlasProjectId: 'atlas',
        displayName: 'Project Atlas',
        localPath: r'B:\dev\Project_Atlas\project-atlas-main',
        gitRoot: r'B:\dev\Project_Atlas\project-atlas-main',
        classification: 'software',
        reviewState: 'linked',
        createdAt: DateTime(2026, 6, 29),
        updatedAt: DateTime(2026, 6, 29),
      );
      final github = ProjectGitRemoteStatus(
        id: 'github_atlas',
        projectId: 'atlas',
        registryId: registry.id,
        provider: 'github',
        owner: 'ppeck1',
        repo: 'project-atlas',
        remoteUrl: 'https://github.com/ppeck1/project-atlas.git',
        defaultBranch: 'main',
        checkedAt: DateTime(2026, 6, 30),
        rawJson: jsonEncode({'source': 'operator_or_local_git'}),
      );

      final snapshot = const ProjectFreshnessService().build(
        project: project,
        registry: registry,
        observation: null,
        githubRemote: github,
        activeWorkItems: 0,
        blockedWorkItems: 0,
        now: DateTime(2026, 7, 8),
      );

      expect(snapshot.status, 'stale');
      expect(snapshot.confidence, 'medium');
      expect(snapshot.staleReasons, contains('missing_local_observation'));
      expect(snapshot.staleReasons, contains('old_github_check'));
      expect(snapshot.staleReasons, contains('github_metadata_unverified'));
      expect(snapshot.staleReasons, contains('github_online_head_missing'));
      expect(
        snapshot.attentionReasons,
        contains('high_priority_without_active_work'),
      );
      expect(snapshot.github['evidenceSource'], 'local_git_remote_only');
      expect(
        snapshot.actionRequiredBeforePlanning,
        'Refresh local project observation before planning.',
      );
    });

    test('treats fresh API-backed GitHub and local scan as current', () {
      final project = Project(
        id: 'atlas',
        title: 'Project Atlas',
        createdAt: DateTime(2026, 6, 29),
        status: 'active',
        priority: 'normal',
      );
      final registry = ProjectRegistryEntry(
        id: 'registry-atlas',
        atlasProjectId: 'atlas',
        displayName: 'Project Atlas',
        localPath: r'B:\dev\Project_Atlas\project-atlas-main',
        gitRoot: r'B:\dev\Project_Atlas\project-atlas-main',
        classification: 'software',
        reviewState: 'linked',
        createdAt: DateTime(2026, 7, 8),
        updatedAt: DateTime(2026, 7, 8),
      );
      final observation = ProjectObservation(
        id: 'obs-atlas',
        registryId: registry.id,
        scanRunId: 'scan-1',
        observedPath: registry.localPath,
        classificationGuess: 'software',
        confidence: 95,
        branch: 'main',
        headSha: 'abc',
        dirtyCount: 0,
        remoteUrl: 'https://github.com/ppeck1/project-atlas.git',
        markerFilesJson: '[]',
        warningsJson: '[]',
        rawJson: '{}',
        observedAt: DateTime(2026, 7, 8, 9),
      );
      final github = ProjectGitRemoteStatus(
        id: 'github_atlas',
        projectId: 'atlas',
        registryId: registry.id,
        provider: 'github',
        owner: 'ppeck1',
        repo: 'project-atlas',
        remoteUrl: 'https://github.com/ppeck1/project-atlas.git',
        visibility: 'public',
        defaultBranch: 'main',
        onlineHeadSha: 'abc',
        checkedAt: DateTime(2026, 7, 8, 9),
        remotePushedAt: DateTime(2026, 7, 8, 8),
        rawJson: jsonEncode({
          'default_branch': 'main',
          'pushed_at': '2026-07-08T08:00:00Z',
        }),
      );

      final snapshot = const ProjectFreshnessService().build(
        project: project,
        registry: registry,
        observation: observation,
        githubRemote: github,
        activeWorkItems: 1,
        blockedWorkItems: 0,
        now: DateTime(2026, 7, 8, 10),
      );

      expect(snapshot.status, 'current');
      expect(snapshot.confidence, 'high');
      expect(snapshot.staleReasons, isEmpty);
      expect(snapshot.github['refreshStatus'], 'verified');
      expect(snapshot.localObservation['evidenceSource'], 'direct_scan');
    });

    test('normalizes impossible local observation timestamps', () {
      final project = Project(
        id: 'atlas',
        title: 'Project Atlas',
        createdAt: DateTime(2026, 6, 29),
        status: 'active',
        priority: 'normal',
      );
      final registry = ProjectRegistryEntry(
        id: 'registry-atlas',
        atlasProjectId: 'atlas',
        displayName: 'Project Atlas',
        localPath: r'B:\dev\Project_Atlas\project-atlas-main',
        gitRoot: r'B:\dev\Project_Atlas\project-atlas-main',
        classification: 'software',
        reviewState: 'linked',
        createdAt: DateTime(2026, 7, 8),
        updatedAt: DateTime(2026, 7, 8),
      );
      final observation = ProjectObservation(
        id: 'obs-atlas',
        registryId: registry.id,
        scanRunId: 'scan-1',
        observedPath: registry.localPath,
        classificationGuess: 'software',
        confidence: 95,
        branch: 'main',
        headSha: 'abc',
        dirtyCount: 2,
        remoteUrl: 'https://github.com/ppeck1/project-atlas.git',
        markerFilesJson: '[]',
        warningsJson: '[]',
        rawJson: '{}',
        observedAt: DateTime(58465, 7, 30),
      );

      final snapshot = const ProjectFreshnessService().build(
        project: project,
        registry: registry,
        observation: observation,
        githubRemote: null,
        activeWorkItems: 1,
        blockedWorkItems: 0,
        now: DateTime(2026, 7, 8, 10),
      );

      expect(snapshot.status, 'stale');
      expect(
        snapshot.staleReasons,
        contains('invalid_local_observation_timestamp'),
      );
      expect(snapshot.attentionReasons, contains('local_dirty_state'));
      expect(snapshot.localObservation['status'], 'unknown');
      expect(
        snapshot.localObservation['evidenceSource'],
        'direct_scan_invalid_timestamp',
      );
      expect(snapshot.localObservation['lastObservedAt'], isNull);
      expect(snapshot.localObservation['ageDays'], isNull);
      expect(snapshot.timestamps['lastLocalObservationAt'], isNull);
      expect(
        snapshot.timestamps['lastLocalObservationConfidence'],
        'invalid_timestamp',
      );
      expect(
        snapshot.actionRequiredBeforePlanning,
        'Refresh local project observation before planning.',
      );
    });
  });
}
