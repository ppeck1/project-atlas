import 'dart:convert';

import '../db/app_db.dart';
import 'project_identity_resolver.dart';

class AtlasProjectFreshnessSnapshot {
  final String schema;
  final String status;
  final String confidence;
  final List<String> staleReasons;
  final List<String> attentionReasons;
  final String actionRequiredBeforePlanning;
  final Map<String, Object?> timestamps;
  final Map<String, Object?> localObservation;
  final Map<String, Object?> github;
  final Map<String, Object?> capsule;

  const AtlasProjectFreshnessSnapshot({
    this.schema = 'atlas.project_freshness_snapshot.v1',
    required this.status,
    required this.confidence,
    required this.staleReasons,
    required this.attentionReasons,
    required this.actionRequiredBeforePlanning,
    required this.timestamps,
    required this.localObservation,
    required this.github,
    required this.capsule,
  });

  Map<String, Object?> toJson() => {
    'schema': schema,
    'status': status,
    'confidence': confidence,
    'staleReasons': staleReasons,
    'attentionReasons': attentionReasons,
    'actionRequiredBeforePlanning': actionRequiredBeforePlanning,
    'timestamps': timestamps,
    'localObservation': localObservation,
    'github': github,
    'capsule': capsule,
  };
}

class ProjectFreshnessService {
  static const localObservationTtl = Duration(days: 7);
  static const githubCheckTtl = Duration(days: 7);

  const ProjectFreshnessService();

  AtlasProjectFreshnessSnapshot build({
    required Project project,
    required ProjectRegistryEntry? registry,
    required ProjectObservation? observation,
    required ProjectGitRemoteStatus? githubRemote,
    required int activeWorkItems,
    required int blockedWorkItems,
    AtlasCapsuleStatus? capsule,
    DateTime? now,
  }) {
    final generatedAt = now ?? DateTime.now();
    final staleReasons = <String>{};
    final attentionReasons = <String>{};

    final localStatus = _localObservationStatus(
      registry: registry,
      observation: observation,
      now: generatedAt,
      staleReasons: staleReasons,
      attentionReasons: attentionReasons,
    );
    final githubStatus = _githubStatus(
      project: project,
      observation: observation,
      githubRemote: githubRemote,
      now: generatedAt,
      staleReasons: staleReasons,
      attentionReasons: attentionReasons,
    );
    final capsuleStatus = _capsuleStatus(
      capsule: capsule,
      staleReasons: staleReasons,
      attentionReasons: attentionReasons,
    );

    if (_needsAttentionStatus(project.status)) {
      attentionReasons.add('project_status_${project.status}');
    }
    if (blockedWorkItems > 0) {
      attentionReasons.add('blocked_work_items');
    }
    if (_clean(project.priority) == 'high' && activeWorkItems == 0) {
      attentionReasons.add('high_priority_without_active_work');
    }

    final status = _overallStatus(staleReasons, localStatus, githubStatus);
    final confidence = _confidence(
      status: status,
      staleReasons: staleReasons,
      localStatus: localStatus,
      githubStatus: githubStatus,
      capsuleStatus: capsuleStatus,
    );
    return AtlasProjectFreshnessSnapshot(
      status: status,
      confidence: confidence,
      staleReasons: staleReasons.toList()..sort(),
      attentionReasons: attentionReasons.toList()..sort(),
      actionRequiredBeforePlanning: _actionRequired(
        status: status,
        staleReasons: staleReasons,
      ),
      timestamps: _timestamps(
        project: project,
        observation: observation,
        githubRemote: githubRemote,
        now: generatedAt,
      ),
      localObservation: localStatus,
      github: githubStatus,
      capsule: capsuleStatus,
    );
  }

  Map<String, Object?> _localObservationStatus({
    required ProjectRegistryEntry? registry,
    required ProjectObservation? observation,
    required DateTime now,
    required Set<String> staleReasons,
    required Set<String> attentionReasons,
  }) {
    if (registry == null) {
      staleReasons.add('missing_local_registry');
      return const {
        'status': 'unknown',
        'evidenceSource': 'not_linked',
        'lastObservedAt': null,
        'ageDays': null,
        'dirtyCount': null,
        'confidence': 'missing',
      };
    }
    if (observation == null) {
      staleReasons.add('missing_local_observation');
      return {
        'status': 'unknown',
        'evidenceSource': 'linked_registry_without_observation',
        'registryId': registry.id,
        'lastObservedAt': null,
        'ageDays': null,
        'dirtyCount': null,
        'confidence': 'missing',
      };
    }
    final hasValidObservedAt = _isValidEvidenceTimestamp(
      observation.observedAt,
      now,
    );
    if (!hasValidObservedAt) {
      staleReasons.add('invalid_local_observation_timestamp');
      final dirtyCount = observation.dirtyCount ?? 0;
      if (dirtyCount > 0) attentionReasons.add('local_dirty_state');
      return {
        'status': 'unknown',
        'evidenceSource': 'direct_scan_invalid_timestamp',
        'registryId': registry.id,
        'lastObservedAt': null,
        'ageDays': null,
        'dirtyCount': observation.dirtyCount,
        'branch': observation.branch,
        'headSha': observation.headSha,
        'remoteUrl': observation.remoteUrl,
        'confidence': 'invalid_timestamp',
      };
    }
    final isOld = now.difference(observation.observedAt) > localObservationTtl;
    if (isOld) staleReasons.add('old_local_observation');
    final dirtyCount = observation.dirtyCount ?? 0;
    if (dirtyCount > 0) attentionReasons.add('local_dirty_state');
    return {
      'status': isOld ? 'stale' : 'current',
      'evidenceSource': 'direct_scan',
      'registryId': registry.id,
      'lastObservedAt': observation.observedAt.toIso8601String(),
      'ageDays': _ageDays(now, observation.observedAt),
      'dirtyCount': observation.dirtyCount,
      'branch': observation.branch,
      'headSha': observation.headSha,
      'remoteUrl': observation.remoteUrl,
      'confidence': 'direct_scan',
    };
  }

  Map<String, Object?> _githubStatus({
    required Project project,
    required ProjectObservation? observation,
    required ProjectGitRemoteStatus? githubRemote,
    required DateTime now,
    required Set<String> staleReasons,
    required Set<String> attentionReasons,
  }) {
    final observedRemote = _clean(observation?.remoteUrl);
    final observedGithubRemote = _looksLikeGithubRemote(observedRemote);
    if (githubRemote == null) {
      if (observedGithubRemote) {
        staleReasons.add('github_remote_detected_but_uncached');
        attentionReasons.add('github_metadata_missing');
      }
      return {
        'refreshStatus': observedGithubRemote
            ? 'missing_cache'
            : 'not_configured',
        'evidenceSource': observedGithubRemote
            ? 'local_git_remote_only'
            : 'none',
        'fullName': null,
        'checkedAt': null,
        'ageDays': null,
        'remotePushedAt': null,
        'onlineHeadSha': null,
        'confidence': observedGithubRemote ? 'medium' : 'not_applicable',
      };
    }

    final evidenceSource = _githubEvidenceSource(githubRemote);
    final isOld = now.difference(githubRemote.checkedAt) > githubCheckTtl;
    var refreshStatus = 'verified';
    if (githubRemote.hasError) {
      refreshStatus = 'failed';
      staleReasons.add('github_refresh_failed');
      attentionReasons.add('github_refresh_failed');
    } else if (isOld) {
      refreshStatus = 'stale';
      staleReasons.add('old_github_check');
    } else if (evidenceSource != 'github_api_verified') {
      refreshStatus = 'unverified';
    }
    if (!githubRemote.hasError && evidenceSource != 'github_api_verified') {
      staleReasons.add('github_metadata_unverified');
    }
    if (githubRemote.defaultBranch != null &&
        githubRemote.onlineHeadSha == null) {
      staleReasons.add('github_online_head_missing');
    }
    if (_clean(project.status) != 'local_only' &&
        githubRemote.remotePushedAt == null &&
        evidenceSource != 'manual') {
      attentionReasons.add('github_remote_push_time_unknown');
    }
    return {
      'refreshStatus': refreshStatus,
      'evidenceSource': evidenceSource,
      'fullName': githubRemote.fullName,
      'checkedAt': githubRemote.checkedAt.toIso8601String(),
      'ageDays': _ageDays(now, githubRemote.checkedAt),
      'remotePushedAt': githubRemote.remotePushedAt?.toIso8601String(),
      'remoteUpdatedAt': githubRemote.remoteUpdatedAt?.toIso8601String(),
      'onlineHeadSha': githubRemote.onlineHeadSha,
      'defaultBranch': githubRemote.defaultBranch,
      'visibility': githubRemote.visibility,
      'error': githubRemote.error,
      'confidence': refreshStatus == 'verified' ? 'high' : 'medium',
    };
  }

  Map<String, Object?> _capsuleStatus({
    required AtlasCapsuleStatus? capsule,
    required Set<String> staleReasons,
    required Set<String> attentionReasons,
  }) {
    if (capsule == null) {
      return const {
        'status': 'not_checked',
        'evidenceAvailability': 'not_checked',
        'warnings': 0,
        'errors': 0,
        'confidence': 'not_checked',
      };
    }
    if (capsule.errors.isNotEmpty) {
      staleReasons.add('capsule_errors');
      attentionReasons.add('capsule_errors');
    }
    if (!capsule.hasMetadata) {
      staleReasons.add('capsule_metadata_missing');
    }
    return {
      'status': capsule.errors.isNotEmpty
          ? 'blocked'
          : capsule.hasMetadata
          ? 'current'
          : 'unknown',
      'evidenceAvailability': capsule.evidenceAvailability,
      'warnings': capsule.warnings.length,
      'errors': capsule.errors.length,
      'confidence': capsule.errors.isEmpty && capsule.hasMetadata
          ? 'direct_metadata'
          : 'incomplete',
    };
  }

  Map<String, Object?> _timestamps({
    required Project project,
    required ProjectObservation? observation,
    required ProjectGitRemoteStatus? githubRemote,
    required DateTime now,
  }) => {
    'generatedAt': now.toIso8601String(),
    'createdAt': project.createdAt.toIso8601String(),
    'createdAtConfidence': _timestampConfidence(project.createdAt),
    'lastLocalObservationAt': _evidenceTimestampIso(
      observation?.observedAt,
      now,
    ),
    'lastLocalObservationConfidence': _evidenceTimestampConfidence(
      observation?.observedAt,
      now,
    ),
    'lastGitHubCheckAt': githubRemote?.checkedAt.toIso8601String(),
    'lastGitHubCheckConfidence': githubRemote == null
        ? 'missing'
        : _githubEvidenceSource(githubRemote),
    'remotePushedAt': githubRemote?.remotePushedAt?.toIso8601String(),
  };

  String _overallStatus(
    Set<String> staleReasons,
    Map<String, Object?> localStatus,
    Map<String, Object?> githubStatus,
  ) {
    if (staleReasons.isEmpty) return 'current';
    if (localStatus['status'] == 'unknown' &&
        githubStatus['refreshStatus'] == 'not_configured') {
      return 'unknown';
    }
    return 'stale';
  }

  String _confidence({
    required String status,
    required Set<String> staleReasons,
    required Map<String, Object?> localStatus,
    required Map<String, Object?> githubStatus,
    required Map<String, Object?> capsuleStatus,
  }) {
    if (status == 'unknown') return 'low';
    if (staleReasons.contains('github_refresh_failed') ||
        staleReasons.contains('capsule_errors')) {
      return 'low';
    }
    if (localStatus['status'] == 'current' &&
        githubStatus['refreshStatus'] == 'verified' &&
        capsuleStatus['status'] != 'blocked') {
      return 'high';
    }
    return 'medium';
  }

  String _actionRequired({
    required String status,
    required Set<String> staleReasons,
  }) {
    if (staleReasons.contains('missing_local_registry')) {
      return 'Link or classify the project local registry before planning.';
    }
    if (staleReasons.contains('missing_local_observation') ||
        staleReasons.contains('invalid_local_observation_timestamp') ||
        staleReasons.contains('old_local_observation')) {
      return 'Refresh local project observation before planning.';
    }
    if (staleReasons.contains('github_remote_detected_but_uncached') ||
        staleReasons.contains('old_github_check') ||
        staleReasons.contains('github_refresh_failed') ||
        staleReasons.contains('github_online_head_missing')) {
      return 'Refresh GitHub metadata before trusting remote state.';
    }
    if (staleReasons.contains('capsule_errors') ||
        staleReasons.contains('capsule_metadata_missing')) {
      return 'Resolve capsule metadata before agent startup.';
    }
    return status == 'current'
        ? 'No freshness preflight action is required.'
        : 'Review freshness reasons before selecting work.';
  }

  String _githubEvidenceSource(ProjectGitRemoteStatus status) {
    final raw = _decodeObjectMap(status.rawJson);
    final source = _clean(raw['source']);
    if (source == 'manual') return 'manual';
    if (source == 'operator_or_local_git') return 'local_git_remote_only';
    if (raw.containsKey('github')) return 'github_api_snapshot';
    if (status.hasError) return 'github_api_failed';
    if (status.visibility != null ||
        status.remotePushedAt != null ||
        status.onlineHeadSha != null ||
        raw.containsKey('default_branch') ||
        raw.containsKey('pushed_at')) {
      return status.onlineHeadSha == null
          ? 'github_api_partial'
          : 'github_api_verified';
    }
    return 'imported_guess';
  }

  static Map<String, Object?> _decodeObjectMap(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {}
    return const {};
  }

  static bool _looksLikeGithubRemote(String? remoteUrl) =>
      remoteUrl != null && remoteUrl.toLowerCase().contains('github.com');

  static String? _clean(Object? value) {
    final trimmed = value?.toString().trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static int? _ageDays(DateTime now, DateTime? then) {
    if (then == null) return null;
    return now.difference(then).inDays;
  }

  static String? _evidenceTimestampIso(DateTime? value, DateTime now) {
    if (value == null || !_isValidEvidenceTimestamp(value, now)) return null;
    return value.toIso8601String();
  }

  static String _evidenceTimestampConfidence(DateTime? value, DateTime now) {
    if (value == null) return 'missing';
    return _isValidEvidenceTimestamp(value, now)
        ? 'direct_scan'
        : 'invalid_timestamp';
  }

  static bool _isValidEvidenceTimestamp(DateTime value, DateTime now) {
    if (value.year < 2000 || value.year > 2100) return false;
    return !value.isAfter(now.add(const Duration(minutes: 5)));
  }

  static String _timestampConfidence(DateTime value) {
    if (value.year < 2000 || value.year > 2100) {
      return 'out_of_range_unknown';
    }
    return 'direct_project_created_at';
  }

  static bool _needsAttentionStatus(String status) =>
      {'needs_review', 'needs_update', 'stale'}.contains(status);
}
