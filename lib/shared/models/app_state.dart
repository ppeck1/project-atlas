import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../db/app_db.dart';
import '../../services/github_remote_metadata_service.dart';
import '../../services/local_git_visibility_service.dart';
import '../../services/local_project_refresh_service.dart';
import '../../services/local_operations_scanner.dart';
import '../../services/ollama_service.dart';
import '../../services/project_runtime_service.dart';
import '../../services/project_summary_models.dart';
import '../../services/shopify_seo_review_service.dart';
import '../../services/telegram_service.dart';
import '../../services/workload_planning_service.dart';

class ProjectLocalRepoSummary {
  final ProjectRegistryEntry? registry;
  final ProjectObservation? observation;
  final List<LocalProjectRefreshItem> refreshItems;
  final List<Document> documents;
  final List<ProjectMediaItem> media;

  const ProjectLocalRepoSummary({
    required this.registry,
    required this.refreshItems,
    required this.documents,
    required this.media,
    this.observation,
  });

  String? get repoRoot =>
      registry == null ? null : registry!.gitRoot ?? registry!.localPath;
  int get sourceFileCount =>
      refreshItems.where((item) => item.sourceKind == 'source_file').length;
  int get documentRefreshCount =>
      refreshItems.where((item) => item.sourceKind == 'document').length;
  int get mediaRefreshCount =>
      refreshItems.where((item) => item.sourceKind == 'media').length;
  int get cardCount =>
      refreshItems.where((item) => item.sourceKind == 'atlas_card').length;
}

class ProjectAiSummarySettings {
  final bool enabled;
  final bool includeLibrary;
  final bool allowBulkRefresh;
  final String? model;

  const ProjectAiSummarySettings({
    this.enabled = false,
    this.includeLibrary = true,
    this.allowBulkRefresh = false,
    this.model,
  });

  ProjectAiSummarySettings copyWith({
    bool? enabled,
    bool? includeLibrary,
    bool? allowBulkRefresh,
    String? model,
  }) {
    return ProjectAiSummarySettings(
      enabled: enabled ?? this.enabled,
      includeLibrary: includeLibrary ?? this.includeLibrary,
      allowBulkRefresh: allowBulkRefresh ?? this.allowBulkRefresh,
      model: model ?? this.model,
    );
  }
}

class ProjectDetailSectionVisibility {
  final Set<String> visibleSectionIds;

  const ProjectDetailSectionVisibility({required this.visibleSectionIds});

  bool isVisible(String sectionId) => visibleSectionIds.contains(sectionId);
}

class ProjectChangeLogEntry {
  final String id;
  final String sourceEventId;
  final String projectId;
  final DateTime timestamp;
  final String level;
  final String actor;
  final String actorType;
  final String area;
  final String action;
  final String? entityType;
  final String? entityId;
  final String summary;
  final Map<String, Object?> changedFields;
  final Map<String, Object?> beforeJson;
  final Map<String, Object?> afterJson;
  final Map<String, Object?> input;
  final Map<String, Object?> output;
  final String? error;
  final String? stackTrace;
  final String? correlationId;

  const ProjectChangeLogEntry({
    required this.id,
    required this.sourceEventId,
    required this.projectId,
    required this.timestamp,
    required this.level,
    required this.actor,
    required this.actorType,
    required this.area,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.summary,
    required this.changedFields,
    required this.beforeJson,
    required this.afterJson,
    required this.input,
    required this.output,
    this.error,
    this.stackTrace,
    this.correlationId,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'sourceEventId': sourceEventId,
    'projectId': projectId,
    'timestamp': timestamp.toIso8601String(),
    'level': level,
    'actor': actor,
    'actorType': actorType,
    'area': area,
    'action': action,
    'entityType': entityType,
    'entityId': entityId,
    'summary': summary,
    'changedFields': changedFields,
    'before': beforeJson,
    'after': afterJson,
    'input': input,
    'output': output,
    'error': error,
    'stackTrace': stackTrace,
    'correlationId': correlationId,
  };
}

class ProjectChangeSummaryRunStatus {
  final String projectId;
  final DateTime startedAt;
  final DateTime? completedAt;
  final bool isRunning;
  final String? output;
  final String? error;

  const ProjectChangeSummaryRunStatus({
    required this.projectId,
    required this.startedAt,
    required this.isRunning,
    this.completedAt,
    this.output,
    this.error,
  });
}

String _pathKey(String value) => value
    .trim()
    .replaceAll('/', r'\')
    .replaceAll(RegExp(r'\\+$'), '')
    .toLowerCase();

class ProjectBundleExportPreview {
  final String schema;
  final String projectId;
  final String projectTitle;
  final bool includeFiles;
  final bool includeLatestSummary;
  final bool includeEventLogs;
  final bool includeChangeLog;
  final bool includeCleanGitArchive;
  final bool includeBootstrapContext;
  final int stages;
  final int workItems;
  final int workItemNotes;
  final int workItemAnalyses;
  final int documents;
  final int copiedDocumentFiles;
  final int media;
  final int copiedMediaFiles;
  final int people;
  final int risks;
  final int decisions;
  final bool hasRegistry;
  final int observations;
  final int refreshItems;
  final int latestSummaryDrafts;
  final int eventLogs;
  final int changeLogEntries;
  final int changeSummaryDrafts;
  final bool cleanGitArchiveReady;
  final List<String> warnings;

  const ProjectBundleExportPreview({
    required this.schema,
    required this.projectId,
    required this.projectTitle,
    required this.includeFiles,
    required this.includeLatestSummary,
    required this.includeEventLogs,
    required this.includeChangeLog,
    required this.includeCleanGitArchive,
    required this.includeBootstrapContext,
    required this.stages,
    required this.workItems,
    required this.workItemNotes,
    required this.workItemAnalyses,
    required this.documents,
    required this.copiedDocumentFiles,
    required this.media,
    required this.copiedMediaFiles,
    required this.people,
    required this.risks,
    required this.decisions,
    required this.hasRegistry,
    required this.observations,
    required this.refreshItems,
    required this.latestSummaryDrafts,
    required this.eventLogs,
    required this.changeLogEntries,
    required this.changeSummaryDrafts,
    required this.cleanGitArchiveReady,
    required this.warnings,
  });

  int get atlasRecordCount =>
      1 +
      stages +
      workItems +
      workItemNotes +
      workItemAnalyses +
      documents +
      media +
      people +
      risks +
      decisions +
      (hasRegistry ? 1 : 0) +
      observations +
      refreshItems +
      latestSummaryDrafts +
      eventLogs +
      changeLogEntries +
      changeSummaryDrafts +
      (includeBootstrapContext ? 1 : 0);

  int get copiedFileCount =>
      includeFiles ? copiedDocumentFiles + copiedMediaFiles : 0;
}

class ContactContinuityResult {
  final String ownerContactId;
  final String ownerName;
  final int contactsSeeded;
  final int projectsConsidered;
  final int projectOwnersUpdated;
  final int projectPeopleAdded;
  final int projectPeopleUpdated;
  final int duplicateContactsRemoved;

  const ContactContinuityResult({
    required this.ownerContactId,
    required this.ownerName,
    required this.contactsSeeded,
    required this.projectsConsidered,
    required this.projectOwnersUpdated,
    required this.projectPeopleAdded,
    required this.projectPeopleUpdated,
    required this.duplicateContactsRemoved,
  });

  Map<String, Object?> toJson() => {
    'ownerContactId': ownerContactId,
    'ownerName': ownerName,
    'contactsSeeded': contactsSeeded,
    'projectsConsidered': projectsConsidered,
    'projectOwnersUpdated': projectOwnersUpdated,
    'projectPeopleAdded': projectPeopleAdded,
    'projectPeopleUpdated': projectPeopleUpdated,
    'duplicateContactsRemoved': duplicateContactsRemoved,
  };
}

class ProjectSummaryRefreshResult {
  final int considered;
  final int refreshed;
  final int skipped;
  final int failed;
  final bool aiUnavailable;
  final bool alreadyRunning;
  final List<String> errors;

  const ProjectSummaryRefreshResult({
    required this.considered,
    required this.refreshed,
    required this.skipped,
    required this.failed,
    required this.aiUnavailable,
    this.alreadyRunning = false,
    required this.errors,
  });
}

class LocalProjectBatchRefreshResult {
  final int considered;
  final int refreshed;
  final int created;
  final int updated;
  final int unchanged;
  final int skipped;
  final int failed;
  final bool alreadyRunning;
  final List<String> warnings;

  const LocalProjectBatchRefreshResult({
    required this.considered,
    required this.refreshed,
    required this.created,
    required this.updated,
    required this.unchanged,
    required this.skipped,
    required this.failed,
    this.alreadyRunning = false,
    required this.warnings,
  });
}

class ProjectReconciliationChannelStatus {
  final String name;
  final String status;
  final int eligible;
  final int processed;
  final int unchanged;
  final int excludedByPolicy;
  final int deferredByCap;
  final int failed;
  final List<String> blockers;
  final List<String> warnings;
  final Map<String, Object?> details;

  const ProjectReconciliationChannelStatus({
    required this.name,
    required this.status,
    this.eligible = 0,
    this.processed = 0,
    this.unchanged = 0,
    this.excludedByPolicy = 0,
    this.deferredByCap = 0,
    this.failed = 0,
    this.blockers = const [],
    this.warnings = const [],
    this.details = const {},
  });

  bool get isBlocked => status == 'blocked' || blockers.isNotEmpty;
  bool get isFailed => status == 'failed' || failed > 0;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status,
    'eligible': eligible,
    'processed': processed,
    'unchanged': unchanged,
    'excludedByPolicy': excludedByPolicy,
    'deferredByCap': deferredByCap,
    'failed': failed,
    'blockers': blockers,
    'warnings': warnings,
    'details': details,
  };
}

class ProjectReconciliationPreview {
  final String projectId;
  final String projectTitle;
  final String outcome;
  final bool sourceReposMutated;
  final String writeBoundary;
  final List<ProjectReconciliationChannelStatus> channels;
  final List<String> blockers;
  final List<String> warnings;
  final LocalProjectRefreshPreview? localRefreshPreview;
  final Map<String, Object?> auditCoverage;

  const ProjectReconciliationPreview({
    required this.projectId,
    required this.projectTitle,
    required this.outcome,
    required this.sourceReposMutated,
    required this.writeBoundary,
    required this.channels,
    required this.blockers,
    required this.warnings,
    required this.auditCoverage,
    this.localRefreshPreview,
  });

  int get refreshableActions =>
      localRefreshPreview?.entries
          .where((entry) => entry.shouldApplyByDefault)
          .length ??
      0;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'projectTitle': projectTitle,
    'outcome': outcome,
    'sourceReposMutated': sourceReposMutated,
    'writeBoundary': writeBoundary,
    'channels': channels.map((channel) => channel.toJson()).toList(),
    'blockers': blockers,
    'warnings': warnings,
    'refreshableActions': refreshableActions,
    'auditCoverage': auditCoverage,
    if (localRefreshPreview != null)
      'localRefresh': {
        'registryId': localRefreshPreview!.registryId,
        'localPath': localRefreshPreview!.localPath,
        'profile': localRefreshPreview!.profile,
        'branch': localRefreshPreview!.branch,
        'headSha': localRefreshPreview!.headSha,
        'dirtyCount': localRefreshPreview!.dirtyCount,
        'remoteUrl': localRefreshPreview!.remoteUrl,
        'observedAt': localRefreshPreview!.observedAt?.toIso8601String(),
        'entries': localRefreshPreview!.entries.length,
        'new': localRefreshPreview!.entries
            .where((entry) => entry.status == 'new')
            .length,
        'changed': localRefreshPreview!.entries
            .where((entry) => entry.status == 'changed')
            .length,
        'unchanged': localRefreshPreview!.entries
            .where((entry) => entry.status == 'unchanged')
            .length,
        'warnings': localRefreshPreview!.warnings,
      },
  };
}

typedef ProjectEnrichmentStatusCallback =
    void Function(String status, {int? current, int? total});

class ProjectEnrichmentRunResult {
  final ProjectEnrichmentRun run;
  final List<ProjectEnrichmentFinding> findings;
  final List<ProjectEnrichmentStep> steps;
  final List<ProjectEnrichmentProposal> proposals;

  const ProjectEnrichmentRunResult({
    required this.run,
    required this.findings,
    this.steps = const [],
    this.proposals = const [],
  });

  Map<String, Object?> toJson() => {
    'run': run.toJson(),
    'findings': findings.map((finding) => finding.toJson()).toList(),
    'steps': steps.map((step) => step.toJson()).toList(),
    'proposals': proposals.map((proposal) => proposal.toJson()).toList(),
  };
}

class ProjectHealthFindingSuppression {
  final String fingerprint;
  final String? projectId;
  final String? registryId;
  final String category;
  final String title;
  final String? detail;
  final String? localPath;
  final String actor;
  final String? note;
  final DateTime suppressedAt;

  const ProjectHealthFindingSuppression({
    required this.fingerprint,
    this.projectId,
    this.registryId,
    required this.category,
    required this.title,
    this.detail,
    this.localPath,
    required this.actor,
    this.note,
    required this.suppressedAt,
  });

  factory ProjectHealthFindingSuppression.fromJson(Map<String, Object?> json) {
    final suppressedAtRaw = json['suppressedAt']?.toString();
    return ProjectHealthFindingSuppression(
      fingerprint: json['fingerprint']?.toString() ?? '',
      projectId: _cleanNullableString(json['projectId']),
      registryId: _cleanNullableString(json['registryId']),
      category: json['category']?.toString() ?? 'unknown',
      title: json['title']?.toString() ?? 'Suppressed finding',
      detail: _cleanNullableString(json['detail']),
      localPath: _cleanNullableString(json['localPath']),
      actor: json['actor']?.toString() ?? 'Operator',
      note: _cleanNullableString(json['note']),
      suppressedAt: suppressedAtRaw == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.tryParse(suppressedAtRaw) ??
                DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'projectId': projectId,
    'registryId': registryId,
    'category': category,
    'title': title,
    'detail': detail,
    'localPath': localPath,
    'actor': actor,
    'note': note,
    'suppressedAt': suppressedAt.toIso8601String(),
  };
}

String? _cleanNullableString(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

typedef GithubArchiveFetcher =
    Future<List<int>> Function(GithubRemoteIdentity identity, String ref);

class _ProjectGitArchive {
  final List<int> bytes;
  final String archivePath;
  final Map<String, Object?> metadata;

  const _ProjectGitArchive({
    required this.bytes,
    required this.archivePath,
    required this.metadata,
  });
}

class _GithubArchiveCandidate {
  final GithubRemoteIdentity identity;
  final String ref;
  final ProjectGitRemoteStatus? status;

  const _GithubArchiveCandidate({
    required this.identity,
    required this.ref,
    required this.status,
  });
}

class _LocalGitArchiveCandidate {
  final ProjectRegistryEntry registry;
  final LocalGitVisibilityReport report;

  const _LocalGitArchiveCandidate({
    required this.registry,
    required this.report,
  });
}

Future<List<int>> _downloadPublicGithubArchive(
  GithubRemoteIdentity identity,
  String ref,
) async {
  final safeRef = ref.trim();
  if (safeRef.isEmpty) {
    throw StateError('GitHub archive ref is required.');
  }
  final uri = Uri.https(
    'codeload.github.com',
    '/${identity.owner}/${identity.repo}/zip/$safeRef',
  );
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 8));
    final response = await request.close().timeout(const Duration(seconds: 20));
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

class _ProjectEnrichmentFindingDraft {
  final String? projectId;
  final String? registryId;
  final String severity;
  final String category;
  final String title;
  final String? detail;
  final Map<String, Object?> evidence;

  const _ProjectEnrichmentFindingDraft({
    this.projectId,
    this.registryId,
    required this.severity,
    required this.category,
    required this.title,
    this.detail,
    this.evidence = const {},
  });
}

class _ProjectEnrichmentAudit {
  final List<_ProjectEnrichmentFindingDraft> findings;
  final Map<String, Object?> coverage;

  const _ProjectEnrichmentAudit({
    required this.findings,
    required this.coverage,
  });
}

class _ProjectIdentityEnrichmentResult {
  final int considered;
  final int updated;
  final int unchanged;
  final int skipped;
  final List<String> warnings;

  const _ProjectIdentityEnrichmentResult({
    required this.considered,
    required this.updated,
    required this.unchanged,
    required this.skipped,
    required this.warnings,
  });
}

/// App-wide state wrapper around [AppDb].
class AppState extends ChangeNotifier {
  final AppDb db;
  final GithubArchiveFetcher _githubArchiveFetcher;
  static const String _projectHealthSuppressionsMetaKey =
      'project_health_finding_suppressions_v1';
  static const Set<String> _safeLocalProjectDocNames = {
    'README.md',
    'ACTIVE_TASK.md',
    'CURRENT_STATE.md',
    'HANDOFF.md',
    'ACCEPTANCE.md',
    'OPERATIONS.md',
    'ROADMAP.md',
    'CHANGELOG.md',
    'CHANGELOG_AGENT.md',
    'DECISIONS.md',
    'AGENTS.md',
    'CLAUDE.md',
    'package.json',
    'pubspec.yaml',
    'pyproject.toml',
  };
  static const int _projectEnrichmentProposalCap = 120;
  static const int _projectSummaryMaxCharsPerDoc = 3000;
  static const int _projectSummaryMaxTotalDocChars = 16000;
  static const Map<String, int> _projectSummaryCategoryWeights = {
    'active_task': 1200,
    'current_state': 1180,
    'handoff': 1160,
    'readme': 1140,
    'acceptance': 1120,
    'operations': 1100,
    'roadmap': 1060,
    'requirements': 1040,
    'change_history': 1020,
    'agent_guidance': 1000,
    'text': 560,
    'source': 240,
    'binary': 160,
    'other': 100,
  };
  static const Set<String> _projectSummaryTextExtensions = {
    'md',
    'mdx',
    'txt',
    'log',
    'rst',
    'html',
    'htm',
    'eml',
    'json',
    'yaml',
    'yml',
    'toml',
    'ini',
    'csv',
    'xml',
  };
  static const Set<String> _projectSummarySourceExtensions = {
    'dart',
    'py',
    'js',
    'ts',
    'tsx',
    'jsx',
    'java',
    'cs',
    'go',
    'rs',
  };

  Timer? _localProjectRefreshTimer;
  bool _summaryRefreshRunning = false;
  bool _localProjectRefreshRunning = false;
  bool _projectEnrichmentRunning = false;
  bool _projectAiSummariesEnabled = false;
  bool _projectAiSummaryIncludeLibrary = true;
  bool _projectAiSummaryAllowBulkRefresh = false;
  String? _projectAiSummaryModel;
  final Map<String, Future<OllamaResult>> _projectChangeSummaryRuns = {};
  final Map<String, ProjectChangeSummaryRunStatus>
  _projectChangeSummaryRunStatuses = {};
  String? _projectEnrichmentStatus;
  DateTime? _projectEnrichmentStartedAt;
  int? _projectEnrichmentProgressCurrent;
  int? _projectEnrichmentProgressTotal;
  final List<StreamSubscription<String?>> _settingsSubscriptions = [];

  bool get isProjectSummaryRefreshRunning => _summaryRefreshRunning;
  bool get projectAiSummariesEnabled => _projectAiSummariesEnabled;
  bool get projectAiSummaryIncludeLibrary => _projectAiSummaryIncludeLibrary;
  bool get projectAiSummaryAllowBulkRefresh =>
      _projectAiSummaryAllowBulkRefresh;
  String? get projectAiSummaryModel => _projectAiSummaryModel;
  ProjectChangeSummaryRunStatus? getProjectChangeSummaryRunStatus(
    String projectId,
  ) => _projectChangeSummaryRunStatuses[projectId];
  bool isProjectChangeSummaryRunning(String projectId) =>
      _projectChangeSummaryRuns.containsKey(projectId);
  bool get isLocalProjectRefreshRunning => _localProjectRefreshRunning;
  bool get isProjectEnrichmentRunning => _projectEnrichmentRunning;
  String? get projectEnrichmentStatus => _projectEnrichmentStatus;
  DateTime? get projectEnrichmentStartedAt => _projectEnrichmentStartedAt;
  double? get projectEnrichmentProgress {
    final total = _projectEnrichmentProgressTotal;
    final current = _projectEnrichmentProgressCurrent;
    if (total == null || current == null || total <= 0) return null;
    return current.clamp(0, total).toDouble() / total;
  }

  String? get projectEnrichmentProgressLabel {
    final total = _projectEnrichmentProgressTotal;
    final current = _projectEnrichmentProgressCurrent;
    if (total == null || current == null || total <= 0) return null;
    return '$current/$total';
  }

  AppState(
    this.db, {
    bool enableBackgroundSummaryRefresh = true,
    GithubArchiveFetcher? githubArchiveFetcher,
  }) : _githubArchiveFetcher =
           githubArchiveFetcher ?? _downloadPublicGithubArchive {
    _watchProjectAiSummarySettings();
    unawaited(
      _migrateRuntimeManifestPathSetting().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        debugPrint('[Atlas] runtime manifest setting migration failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return null;
      }),
    );
    _activeProjectSub = db.watchActiveProject().listen(
      (p) {
        _activeProject = p;
        hasActiveProject.value = p != null;
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Atlas] active project stream failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
    unawaited(
      db.ensureDefaultStagesForProjects().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        debugPrint('[Atlas] ensureDefaultStages failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }),
    );
    unawaited(
      purgeExpiredDeletedDocuments().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        debugPrint('[Atlas] purge of expired deleted documents failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }),
    );
    if (enableBackgroundSummaryRefresh) {
      _localProjectRefreshTimer = Timer.periodic(
        const Duration(hours: 12),
        (_) => refreshLinkedLocalProjects(includeSourceDocuments: false),
      );
    }
  }

  static bool _metaBool(String? value, {required bool fallback}) {
    if (value == null || value.isEmpty) return fallback;
    final normalized = value.trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  static String _boolMeta(bool value) => value ? '1' : '0';
  static String? _metaString(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  void _watchBoolSetting(
    String key, {
    required bool fallback,
    required bool Function() current,
    required void Function(bool value) assign,
  }) {
    _settingsSubscriptions.add(
      db.watchMetaString(key).listen((raw) {
        final next = _metaBool(raw, fallback: fallback);
        if (current() == next) return;
        assign(next);
        notifyListeners();
      }),
    );
  }

  void _watchStringSetting(
    String key, {
    required String? Function() current,
    required void Function(String? value) assign,
  }) {
    _settingsSubscriptions.add(
      db.watchMetaString(key).listen((raw) {
        final next = _metaString(raw);
        if (current() == next) return;
        assign(next);
        notifyListeners();
      }),
    );
  }

  void _watchProjectAiSummarySettings() {
    _watchBoolSetting(
      AppDb.kProjectAiSummariesEnabled,
      fallback: false,
      current: () => _projectAiSummariesEnabled,
      assign: (value) => _projectAiSummariesEnabled = value,
    );
    _watchBoolSetting(
      AppDb.kProjectAiSummaryIncludeLibrary,
      fallback: true,
      current: () => _projectAiSummaryIncludeLibrary,
      assign: (value) => _projectAiSummaryIncludeLibrary = value,
    );
    _watchBoolSetting(
      AppDb.kProjectAiSummaryAllowBulkRefresh,
      fallback: false,
      current: () => _projectAiSummaryAllowBulkRefresh,
      assign: (value) => _projectAiSummaryAllowBulkRefresh = value,
    );
    _watchStringSetting(
      AppDb.kProjectAiSummaryModel,
      current: () => _projectAiSummaryModel,
      assign: (value) => _projectAiSummaryModel = value,
    );
  }

  late final StreamSubscription<Project?> _activeProjectSub;
  Project? _activeProject;

  Project? get activeProject => _activeProject;
  final ValueNotifier<bool> hasActiveProject = ValueNotifier<bool>(false);

  // ---------------------------------------------------------------------------
  // Projects
  // ---------------------------------------------------------------------------

  Stream<List<Project>> watchProjects() => db.watchProjects();
  Future<List<Project>> getVisibleProjects({bool includeArchived = true}) =>
      db.getVisibleProjects(includeArchived: includeArchived);
  Stream<Project?> watchProject(String id) => db.watchProject(id);
  Stream<Project?> watchActiveProject() => db.watchActiveProject();

  Future<String?> createProject(String title) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    debugPrint('[Atlas] AppState.createProject: "$t" id=$id');
    await db.createProject(id, t, DateTime.now());
    await db.setActiveProjectId(id);
    await db.logEvent(
      area: 'ui',
      action: 'create_project',
      entityType: 'project',
      entityId: id,
      inputJson: t,
    );
    notifyListeners();
    debugPrint('[Atlas] AppState.createProject: done, notified listeners');
    return id;
  }

  Future<void> setActiveById(String id) async {
    await db.setActiveProjectId(id);
    // No notifyListeners(): _activeProjectSub (watchActiveProject listener in
    // the constructor) fires on this meta write and notifies.
  }

  String _projectDetailVisibleSectionsKey(String projectId) =>
      'project_detail::$projectId::visible_sections';

  Future<ProjectDetailSectionVisibility> loadProjectDetailSectionVisibility(
    String projectId,
    Iterable<String> defaultSectionIds,
  ) async {
    final defaults = defaultSectionIds.toSet();
    final raw = await db.getMetaString(
      _projectDetailVisibleSectionsKey(projectId),
    );
    if (raw == null || raw.trim().isEmpty) {
      return ProjectDetailSectionVisibility(visibleSectionIds: defaults);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final rawIds = decoded['visibleSectionIds'];
        if (rawIds is List) {
          final visible = rawIds
              .whereType<String>()
              .where(defaults.contains)
              .toSet();
          return ProjectDetailSectionVisibility(visibleSectionIds: visible);
        }
      }
    } catch (e) {
      debugPrint('[Atlas] loadProjectDetailSectionVisibility: JSON parse of visible sections failed (continuing): $e');
    }
    return ProjectDetailSectionVisibility(visibleSectionIds: defaults);
  }

  Future<void> saveProjectDetailSectionVisibility(
    String projectId,
    Iterable<String> visibleSectionIds,
    Iterable<String> defaultSectionIds,
  ) async {
    final defaults = defaultSectionIds.toSet();
    final visible = visibleSectionIds.where(defaults.contains).toList()..sort();
    if (visible.length == defaults.length) {
      await db.setMetaString(_projectDetailVisibleSectionsKey(projectId), null);
    } else {
      await db.setMetaString(
        _projectDetailVisibleSectionsKey(projectId),
        jsonEncode({
          'schema': 'project_detail_visible_sections_v1',
          'projectId': projectId,
          'visibleSectionIds': visible,
        }),
      );
    }
    notifyListeners();
  }

  Future<Map<String, int>> mergeProjects({
    required String sourceProjectId,
    required String targetProjectId,
  }) async {
    final result = await db.mergeProjects(
      sourceProjectId: sourceProjectId,
      targetProjectId: targetProjectId,
    );
    notifyListeners();
    return result;
  }

  // ---------------------------------------------------------------------------
  // Stages
  // ---------------------------------------------------------------------------

  Stream<List<Stage>> watchStagesForProject(String projectId) =>
      db.watchStagesForProject(projectId);

  Stream<Stage?> watchActiveStageForProject(String projectId) =>
      db.watchActiveStageForProject(projectId);

  Future<void> setActiveStageForProject(
    String projectId,
    String stageId,
  ) async {
    await db.setActiveStageIdForProject(projectId, stageId);
  }

  // Stage management (stage consumers read via watchStagesForProject streams)
  Future<void> addStage(String projectId, String title) async {
    await db.addStage(projectId, title);
  }

  Future<void> updateStageTitle(String stageId, String title) async {
    await db.updateStageTitle(stageId, title);
  }

  Future<void> deleteStage(String stageId) async {
    await db.deleteStage(stageId);
  }

  Future<void> reorderStage(String stageId, int newPosition) async {
    await db.reorderStage(stageId, newPosition);
  }

  // Daily reviews
  Future<void> saveDailyReview(String summary) => db.saveDailyReview(summary);
  Future<DailyReview?> getDailyReviewForDate(DateTime date) =>
      db.getDailyReviewForDate(date);
  Stream<List<DailyReview>> watchRecentDailyReviews({int limit = 30}) =>
      db.watchRecentDailyReviews(limit: limit);

  // ---------------------------------------------------------------------------
  // Work items
  // ---------------------------------------------------------------------------

  Stream<List<WorkItem>> watchWorkItemsForStage(String stageId) =>
      db.watchWorkItemsForStage(stageId);

  Stream<List<WorkItem>> watchTodayItems() => db.watchTodayItems();
  Stream<List<WorkItem>> watchAllActiveWorkItems() =>
      db.watchAllActiveWorkItems();

  Future<void> addWorkItem(
    String stageId,
    String title, {
    String? description,
    String? owner,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? source,
    String? blockedReason,
    String readiness = 'ready',
    String size = 'medium',
    String risk = 'low_code',
    String suggestedActor = 'user',
    String verificationNeeded = 'none',
    String? nextAction,
    String? planningNotes,
    DateTime? lastReviewedAt,
  }) async {
    await db.logEvent(
      area: 'ui',
      action: 'create_task_request',
      entityType: 'stage',
      entityId: stageId,
      inputJson: title,
    );
    await db.addWorkItem(
      stageId: stageId,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      dueAt: dueAt,
      source: source,
      blockedReason: blockedReason,
      readiness: normalizeWorkloadReadiness(readiness),
      size: normalizeWorkloadSize(size),
      risk: normalizeWorkloadRisk(risk),
      suggestedActor: normalizeWorkloadActor(suggestedActor),
      verificationNeeded: normalizeWorkloadVerification(verificationNeeded),
      nextAction: cleanWorkloadText(nextAction),
      planningNotes: cleanWorkloadText(planningNotes),
      lastReviewedAt: lastReviewedAt,
    );
    await db.logEvent(
      area: 'ui',
      action: 'create_task_success',
      entityType: 'stage',
      entityId: stageId,
      inputJson: title,
    );
    notifyListeners();
  }

  Future<String> addWorkItemToProject(
    String projectId,
    String title, {
    String? description,
    String? owner,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? source,
    String? blockedReason,
    Iterable<String> tagIds = const [],
    String readiness = 'ready',
    String size = 'medium',
    String risk = 'low_code',
    String suggestedActor = 'user',
    String verificationNeeded = 'none',
    String? nextAction,
    String? planningNotes,
    DateTime? lastReviewedAt,
  }) async {
    var stages = await db.getStagesForProject(projectId);
    if (stages.isEmpty) {
      await db.ensureDefaultStagesForProjects();
      stages = await db.getStagesForProject(projectId);
    }
    if (stages.isEmpty) {
      throw StateError('Project has no stage for tasks.');
    }
    await db.logEvent(
      area: 'ui',
      action: 'create_today_task_request',
      entityType: 'project',
      entityId: projectId,
      inputJson: title,
    );
    final workItemId = await db.addWorkItem(
      stageId: stages.first.id,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      dueAt: dueAt,
      source: source,
      blockedReason: blockedReason,
      readiness: normalizeWorkloadReadiness(readiness),
      size: normalizeWorkloadSize(size),
      risk: normalizeWorkloadRisk(risk),
      suggestedActor: normalizeWorkloadActor(suggestedActor),
      verificationNeeded: normalizeWorkloadVerification(verificationNeeded),
      nextAction: cleanWorkloadText(nextAction),
      planningNotes: cleanWorkloadText(planningNotes),
      lastReviewedAt: lastReviewedAt,
    );
    await db.setWorkItemTags(workItemId, tagIds);
    await db.logEvent(
      area: 'ui',
      action: 'create_today_task_success',
      entityType: 'work_item',
      entityId: workItemId,
      inputJson: title,
    );
    notifyListeners();
    return workItemId;
  }

  Future<String> addGeneralWorkItem(
    String title, {
    String? description,
    String? owner,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? source,
    String? blockedReason,
    Iterable<String> tagIds = const [],
    String readiness = 'ready',
    String size = 'medium',
    String risk = 'low_code',
    String suggestedActor = 'user',
    String verificationNeeded = 'none',
    String? nextAction,
    String? planningNotes,
    DateTime? lastReviewedAt,
  }) async {
    final stageId = await db.ensureGeneralTaskStage();
    await db.logEvent(
      area: 'ui',
      action: 'create_general_task_request',
      entityType: 'stage',
      entityId: stageId,
      inputJson: title,
    );
    final workItemId = await db.addWorkItem(
      stageId: stageId,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      dueAt: dueAt,
      source: source,
      blockedReason: blockedReason,
      readiness: normalizeWorkloadReadiness(readiness),
      size: normalizeWorkloadSize(size),
      risk: normalizeWorkloadRisk(risk),
      suggestedActor: normalizeWorkloadActor(suggestedActor),
      verificationNeeded: normalizeWorkloadVerification(verificationNeeded),
      nextAction: cleanWorkloadText(nextAction),
      planningNotes: cleanWorkloadText(planningNotes),
      lastReviewedAt: lastReviewedAt,
    );
    await db.setWorkItemTags(workItemId, tagIds);
    await db.logEvent(
      area: 'ui',
      action: 'create_general_task_success',
      entityType: 'work_item',
      entityId: workItemId,
      inputJson: title,
    );
    notifyListeners();
    return workItemId;
  }

  Future<void> updateWorkItem({
    required String id,
    String? title,
    String? description,
    String? owner,
    String? status,
    String? priority,
    bool clearDueAt = false,
    DateTime? dueAt,
    String? blockedReason,
    bool clearBlockedReason = false,
    bool? phoneQueue,
    String? readiness,
    String? size,
    String? risk,
    String? suggestedActor,
    String? verificationNeeded,
    String? nextAction,
    bool clearNextAction = false,
    String? planningNotes,
    bool clearPlanningNotes = false,
    DateTime? lastReviewedAt,
    bool clearLastReviewedAt = false,
  }) async {
    await db.logEvent(
      area: 'ui',
      action: 'update_task_request',
      entityType: 'work_item',
      entityId: id,
    );
    await db.updateWorkItem(
      id: id,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      clearDueAt: clearDueAt,
      dueAt: dueAt,
      blockedReason: blockedReason,
      clearBlockedReason: clearBlockedReason,
      phoneQueue: phoneQueue,
      readiness: readiness == null
          ? null
          : normalizeWorkloadReadiness(readiness),
      size: size == null ? null : normalizeWorkloadSize(size),
      risk: risk == null ? null : normalizeWorkloadRisk(risk),
      suggestedActor: suggestedActor == null
          ? null
          : normalizeWorkloadActor(suggestedActor),
      verificationNeeded: verificationNeeded == null
          ? null
          : normalizeWorkloadVerification(verificationNeeded),
      nextAction: cleanWorkloadText(nextAction),
      clearNextAction: clearNextAction,
      planningNotes: cleanWorkloadText(planningNotes),
      clearPlanningNotes: clearPlanningNotes,
      lastReviewedAt: lastReviewedAt,
      clearLastReviewedAt: clearLastReviewedAt,
    );
    await db.logEvent(
      area: 'ui',
      action: 'update_task_success',
      entityType: 'work_item',
      entityId: id,
    );
    notifyListeners();
  }

  Future<void> setWorkItemStatus(String id, String status) async {
    await db.setWorkItemStatus(id, status);
  }

  Future<void> toggleWorkDone(String workItemId) async {
    await db.toggleWorkDone(workItemId);
  }

  Future<WorkItem?> getWorkItem(String id) => db.getWorkItem(id);
  Future<Project?> getProjectForWorkItem(String id) =>
      db.getProjectForWorkItem(id);
  Future<List<WorkItem>> getAllActiveWorkItems() => db.getAllActiveWorkItems();
  Future<List<WorkItem>> getTodayItems() => db.getTodayItems();
  Future<List<WorkItem>> getBlockedItems() => db.getBlockedItems();

  Future<List<WorkloadCard>> getWorkloadCards() async {
    final visibleProjects = await db.getProjectsFull();
    final generalProject = await db.getGeneralTasksProject();
    final projects = [
      ...visibleProjects,
      if (generalProject != null &&
          !visibleProjects.any((project) => project.id == generalProject.id))
        generalProject,
    ];
    final stages = <Stage>[];
    final workItems = <WorkItem>[];
    for (final project in projects) {
      final projectStages = await db.getStagesForProject(project.id);
      stages.addAll(projectStages);
      workItems.addAll(await db.getWorkItemsForProject(project.id));
    }
    final llmTasks = await db.getLlmTasks(limit: 1000);
    return WorkloadPlanner.buildCards(
      projects: projects,
      stages: stages,
      workItems: workItems,
      llmTasks: llmTasks,
    );
  }

  Future<WorkloadSnapshot> getWorkloadSnapshot({
    WorkloadFilters filters = const WorkloadFilters(),
    DateTime? now,
    int suggestionLimit = 5,
  }) async {
    final cards = await getWorkloadCards();
    return WorkloadPlanner.snapshot(
      cards: cards,
      filters: filters,
      now: now,
      suggestionLimit: suggestionLimit,
    );
  }

  Future<void> updateWorkloadPlanning({
    required Iterable<WorkloadItemRef> items,
    String? readiness,
    String? size,
    String? risk,
    String? suggestedActor,
    String? verificationNeeded,
    String? nextAction,
    bool clearNextAction = false,
    String? blockerReason,
    bool clearBlockerReason = false,
    String? planningNotes,
    bool clearPlanningNotes = false,
    DateTime? lastReviewedAt,
    bool clearLastReviewedAt = false,
  }) async {
    final refs = items.toList(growable: false);
    for (final ref in refs) {
      switch (ref.kind) {
        case WorkloadCard.workItemKind:
          await db.updateWorkItem(
            id: ref.id,
            readiness: readiness == null
                ? null
                : normalizeWorkloadReadiness(readiness),
            size: size == null ? null : normalizeWorkloadSize(size),
            risk: risk == null ? null : normalizeWorkloadRisk(risk),
            suggestedActor: suggestedActor == null
                ? null
                : normalizeWorkloadActor(suggestedActor),
            verificationNeeded: verificationNeeded == null
                ? null
                : normalizeWorkloadVerification(verificationNeeded),
            nextAction: cleanWorkloadText(nextAction),
            clearNextAction: clearNextAction,
            blockedReason: cleanWorkloadText(blockerReason),
            clearBlockedReason: clearBlockerReason,
            planningNotes: cleanWorkloadText(planningNotes),
            clearPlanningNotes: clearPlanningNotes,
            lastReviewedAt: lastReviewedAt,
            clearLastReviewedAt: clearLastReviewedAt,
          );
          break;
        case WorkloadCard.llmQueueKind:
          await db.updateLlmTaskPlanning(
            id: ref.id,
            readiness: readiness == null
                ? null
                : normalizeWorkloadReadiness(readiness),
            size: size == null ? null : normalizeWorkloadSize(size),
            risk: risk == null ? null : normalizeWorkloadRisk(risk),
            suggestedActor: suggestedActor == null
                ? null
                : normalizeWorkloadActor(suggestedActor),
            verificationNeeded: verificationNeeded == null
                ? null
                : normalizeWorkloadVerification(verificationNeeded),
            nextAction: cleanWorkloadText(nextAction),
            clearNextAction: clearNextAction,
            blockerReason: cleanWorkloadText(blockerReason),
            clearBlockerReason: clearBlockerReason,
            planningNotes: cleanWorkloadText(planningNotes),
            clearPlanningNotes: clearPlanningNotes,
            lastReviewedAt: lastReviewedAt,
            clearLastReviewedAt: clearLastReviewedAt,
          );
          break;
      }
    }
    if (refs.isNotEmpty) {
      await db.logEvent(
        area: 'workload',
        action: 'planning_metadata_updated',
        outputJson: jsonEncode({
          'count': refs.length,
          'items': refs.map((ref) => ref.toJson()).toList(),
        }),
      );
      notifyListeners();
    }
  }

  Future<void> markWorkloadReviewedToday(
    Iterable<WorkloadItemRef> items, {
    DateTime? reviewedAt,
  }) => updateWorkloadPlanning(
    items: items,
    lastReviewedAt: reviewedAt ?? DateTime.now(),
  );

  Future<String> createLlmTaskFromWorkItem(String workItemId) async {
    final item = await db.getWorkItem(workItemId);
    if (item == null) throw StateError('Work item not found: $workItemId');
    final project = await db.getProjectForWorkItem(workItemId);
    if (project == null) {
      throw StateError('Work item has no visible project: $workItemId');
    }
    final taskId = await enqueueLlmTask(
      projectId: project.id,
      workItemId: item.id,
      title: item.title,
      objective:
          cleanWorkloadText(item.nextAction) ??
          cleanWorkloadText(item.description) ??
          item.title,
      priority: item.priority,
      createdBy: 'ui_planning',
      readiness: item.readiness,
      size: item.size,
      risk: item.risk,
      suggestedActor: item.suggestedActor,
      verificationNeeded: item.verificationNeeded,
      nextAction: item.nextAction,
      blockerReason: item.blockedReason,
      planningNotes: item.planningNotes,
      context: {
        'source': 'workboard_bulk_action',
        'workItemId': item.id,
        'projectId': project.id,
        'readiness': item.readiness,
        'size': item.size,
        'risk': item.risk,
        'suggestedActor': item.suggestedActor,
        'verificationNeeded': item.verificationNeeded,
      },
    );
    return taskId;
  }

  Future<void> linkExistingLlmTaskToWorkItem({
    required String taskId,
    required String workItemId,
  }) async {
    final item = await db.getWorkItem(workItemId);
    final task = await db.getLlmTask(taskId);
    if (item == null) throw StateError('Work item not found: $workItemId');
    if (task == null) throw StateError('LLM queue item not found: $taskId');
    final project = await db.getProjectForWorkItem(workItemId);
    if (project == null || project.id != task.projectId) {
      throw StateError(
        'LLM queue item and work item must belong to the same project.',
      );
    }
    await db.linkLlmTaskToWorkItem(id: taskId, workItemId: workItemId);
    await db.logEvent(
      area: 'workload',
      action: 'llm_task_linked_to_work_item',
      entityType: 'work_item',
      entityId: workItemId,
      outputJson: jsonEncode({'taskId': taskId, 'projectId': project.id}),
    );
    notifyListeners();
  }

  Future<Map<String, Object?>> getWorkItemContextBundle(
    String workItemId,
  ) async {
    final item = await db.getWorkItem(workItemId);
    if (item == null) throw StateError('Work item not found: $workItemId');
    final stage = await (db.select(
      db.stages,
    )..where((t) => t.id.equals(item.stageId))).getSingleOrNull();
    final project = stage == null
        ? null
        : await db.getProjectFull(stage.projectId);
    final llmTasks = project == null
        ? const <LlmTaskQueueItem>[]
        : (await db.getLlmTasksForProject(project.id, limit: 200))
              .where((task) => task.workItemId == item.id)
              .toList(growable: false);
    final notes = await (db.select(
      db.workItemNotes,
    )..where((t) => t.workItemId.equals(item.id))).get();
    final analyses = await (db.select(
      db.workItemAnalyses,
    )..where((t) => t.workItemId.equals(item.id))).get();
    final documents = await db.getDocumentsForWorkItem(item.id);
    final media = await db.getProjectMediaForEntity(
      entityType: 'work_item',
      entityId: item.id,
    );
    return {
      'schema': 'atlas.work_item_context_bundle.v1',
      'generatedAt': DateTime.now().toIso8601String(),
      'project': project?.toJson(),
      'stage': stage?.toJson(),
      'workItem': {...item.toJson(), 'blockerReason': item.blockedReason},
      'linkedLlmTasks': llmTasks.map((task) => task.toJson()).toList(),
      'notes': notes.map((note) => note.toJson()).toList(),
      'documents': documents.map((document) => document.toJson()).toList(),
      'media': media.map((item) => item.toJson()).toList(),
      'analyses': analyses.map((analysis) => analysis.toJson()).toList(),
    };
  }

  // ---------------------------------------------------------------------------
  // Governance
  // ---------------------------------------------------------------------------

  Stream<String?> watchWorkOwner(String id) => db.watchWorkOwner(id);
  Future<void> setWorkOwner(String id, String? owner) async {
    await db.setWorkOwner(id, owner);
  }

  Stream<String?> watchBottleneckOwner(String id) =>
      db.watchBottleneckOwner(id);
  Future<void> setBottleneckOwner(String id, String? owner) async {
    await db.setBottleneckOwner(id, owner);
  }

  Stream<bool> watchIsBottleneck(String id) => db.watchIsBottleneck(id);
  Future<void> setIsBottleneck(String id, bool v) async {
    await db.setIsBottleneck(id, v);
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  Future<String?> getSetting(String key) => db.getMetaString(key);
  Future<void> setSetting(String key, String? value) async {
    await db.setMetaString(key, value);
    notifyListeners();
  }

  Stream<String?> watchSetting(String key) => db.watchMetaString(key);

  Future<ProjectAiSummarySettings> loadProjectAiSummarySettings() async {
    final enabled = await getSetting(AppDb.kProjectAiSummariesEnabled);
    final includeLibrary = await getSetting(
      AppDb.kProjectAiSummaryIncludeLibrary,
    );
    final allowBulkRefresh = await getSetting(
      AppDb.kProjectAiSummaryAllowBulkRefresh,
    );
    final model = await getSetting(AppDb.kProjectAiSummaryModel);
    return ProjectAiSummarySettings(
      enabled: _metaBool(enabled, fallback: false),
      includeLibrary: _metaBool(includeLibrary, fallback: true),
      allowBulkRefresh: _metaBool(allowBulkRefresh, fallback: false),
      model: _metaString(model),
    );
  }

  Future<void> saveProjectAiSummarySettings(
    ProjectAiSummarySettings settings,
  ) async {
    await Future.wait([
      db.setMetaString(
        AppDb.kProjectAiSummariesEnabled,
        _boolMeta(settings.enabled),
      ),
      db.setMetaString(
        AppDb.kProjectAiSummaryIncludeLibrary,
        _boolMeta(settings.includeLibrary),
      ),
      db.setMetaString(
        AppDb.kProjectAiSummaryAllowBulkRefresh,
        _boolMeta(settings.allowBulkRefresh),
      ),
      db.setMetaString(
        AppDb.kProjectAiSummaryModel,
        _metaString(settings.model),
      ),
    ]);
    _projectAiSummariesEnabled = settings.enabled;
    _projectAiSummaryIncludeLibrary = settings.includeLibrary;
    _projectAiSummaryAllowBulkRefresh = settings.allowBulkRefresh;
    _projectAiSummaryModel = _metaString(settings.model);
    notifyListeners();
  }

  Future<ProjectRuntimeDefaultsSettings>
  loadProjectRuntimeDefaultsSettings() async {
    final yamlPath = await _migrateRuntimeManifestPathSetting();
    final capsuleEnabled = await getSetting(
      AppDb.kProjectRuntimeDefaultCapsuleEnabled,
    );
    final capsuleMode = await getSetting(
      AppDb.kProjectRuntimeDefaultCapsuleMode,
    );
    final capsuleSourcePath = await getSetting(
      AppDb.kProjectRuntimeDefaultCapsuleSourcePath,
    );
    final capsuleProfile = await getSetting(
      AppDb.kProjectRuntimeDefaultCapsuleProfile,
    );
    return ProjectRuntimeDefaultsSettings(
      runtimeManifestPath: _metaString(yamlPath),
      capsuleEnabled: _metaBool(capsuleEnabled, fallback: true),
      capsuleMode: normalizeCapsuleMode(_metaString(capsuleMode) ?? 'check'),
      capsuleSourcePath:
          _metaString(capsuleSourcePath) ?? defaultProjectProtocolPath,
      capsuleProfile: _metaString(capsuleProfile) ?? 'software_project',
    );
  }

  Future<String?> _migrateRuntimeManifestPathSetting() async {
    return _metaString(
      await db.migrateLegacyRuntimeManifestPathIfUnambiguous(),
    );
  }

  Future<void> saveProjectRuntimeDefaultsSettings(
    ProjectRuntimeDefaultsSettings settings,
  ) async {
    await Future.wait([
      db.setMetaString(
        AppDb.kProjectRuntimeDefaultManifestPath,
        _metaString(settings.runtimeManifestPath),
      ),
      db.setMetaString(
        AppDb.kProjectRuntimeDefaultCapsuleEnabled,
        _boolMeta(settings.capsuleEnabled),
      ),
      db.setMetaString(
        AppDb.kProjectRuntimeDefaultCapsuleMode,
        normalizeCapsuleMode(settings.capsuleMode),
      ),
      db.setMetaString(
        AppDb.kProjectRuntimeDefaultCapsuleSourcePath,
        _metaString(settings.capsuleSourcePath) ?? defaultProjectProtocolPath,
      ),
      db.setMetaString(
        AppDb.kProjectRuntimeDefaultCapsuleProfile,
        _metaString(settings.capsuleProfile),
      ),
    ]);
    notifyListeners();
  }

  Future<ProjectRuntimeProfileDraft> defaultProjectRuntimeProfileDraft({
    String? workingDirectory,
  }) async {
    final settings = await loadProjectRuntimeDefaultsSettings();
    return settings.emptyDraft(workingDirectory: workingDirectory);
  }

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  Stream<List<Draft>> watchDrafts() => db.watchDrafts();
  Future<Draft?> getDraft(String id) => db.getDraft(id);

  Future<String> saveDraft({
    required String kind,
    required String title,
    required String body,
    String? inputJson,
    String? projectId,
    String? workItemId,
  }) async {
    final id = await db.saveDraft(
      kind: kind,
      title: title,
      body: body,
      inputJson: inputJson,
      projectId: projectId,
      workItemId: workItemId,
    );
    return id;
  }

  Future<void> updateDraftReview({
    required String id,
    required bool accepted,
    String? inputJson,
    String? body,
  }) async {
    await db.updateDraftReview(
      id: id,
      accepted: accepted,
      inputJson: inputJson,
      body: body,
    );
  }

  Future<void> deleteDraft(String id) async {
    await db.deleteDraft(id);
  }

  Future<Draft?> getLatestShopifySeoReviewDraft(String projectId) =>
      db.getLatestProjectDraftByKind(projectId, shopifySeoReviewDraftKind);

  Future<ShopifySeoReviewSnapshot?> getLatestShopifySeoReview(
    String projectId,
  ) async {
    final draft = await getLatestShopifySeoReviewDraft(projectId);
    if (draft == null) return null;
    final raw = draft.inputJson?.trim().isNotEmpty == true
        ? draft.inputJson!
        : draft.body;
    return ShopifySeoReviewSnapshot.decode(raw);
  }

  Future<String> saveShopifySeoReviewSnapshot({
    required String projectId,
    required ShopifySeoReviewSnapshot snapshot,
  }) async {
    final id = await saveDraft(
      kind: shopifySeoReviewDraftKind,
      title: 'Shopify SEO review - ${snapshot.shopDomain}',
      body: snapshot.summaryMarkdown(),
      inputJson: snapshot.encode(),
      projectId: projectId,
    );
    await db.logEvent(
      area: 'shopify_seo',
      action: 'review_snapshot_saved',
      entityType: 'project',
      entityId: projectId,
      outputJson: jsonEncode({
        'draftId': id,
        'shopDomain': snapshot.shopDomain,
        'products': snapshot.products.length,
        'source': snapshot.source,
      }),
    );
    return id;
  }

  Future<ShopifySeoReviewSnapshot> seedExampleShopifySeoReview(
    String projectId,
  ) async {
    final snapshot = ShopifySeoReviewSnapshot.sampleExampleStore();
    await saveShopifySeoReviewSnapshot(
      projectId: projectId,
      snapshot: snapshot,
    );
    return snapshot;
  }

  Future<int> queueShopifySeoProductBatches({
    required String projectId,
    required ShopifySeoReviewSnapshot snapshot,
    required Set<String> productIds,
  }) async {
    var count = 0;
    for (final product in snapshot.products) {
      if (!productIds.contains(product.id)) continue;
      if (product.status == 'queued') continue;
      await enqueueLlmTask(
        projectId: projectId,
        title: 'Review Shopify SEO: ${product.title}',
        objective:
            'Review one Shopify product and produce a staged SEO update proposal only. Use the provided SEO analysis and proposal seed. Do not apply live Shopify changes. Do not invent unsupported product claims. Return only approved-field suggestions with evidence and risk notes.',
        context: product.toBatchContext(
          shopDomain: snapshot.shopDomain,
          brandName: snapshot.resolvedBrandName,
        ),
        priority: 'normal',
        createdBy: 'shopify_seo_review',
        readiness: 'ready',
        size: 'small',
        risk: 'external_facing',
        suggestedActor: 'codex',
        verificationNeeded: 'manual_ui',
        nextAction: 'Draft product-level SEO update for approval.',
        planningNotes:
            'Product-level Shopify SEO batch. Live Admin API writes remain disabled until explicit approval wiring exists.',
      );
      count++;
    }
    if (count > 0) {
      await saveShopifySeoReviewSnapshot(
        projectId: projectId,
        snapshot: snapshot.markQueued(productIds),
      );
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // Ollama is human-in-the-loop only. Output is never auto-applied.
  // ---------------------------------------------------------------------------

  OllamaService _buildOllama(String? host, String? model) => OllamaService(
    host: host?.trim().isNotEmpty == true
        ? host!.trim()
        : 'http://localhost:11434',
    model: model?.trim().isNotEmpty == true ? model!.trim() : 'qwen3.5:9b',
  );

  Future<String?> _projectSummaryModelSetting() async {
    final projectSummaryModel = _metaString(
      await getSetting(AppDb.kProjectAiSummaryModel),
    );
    if (projectSummaryModel != null) return projectSummaryModel;
    return getSetting(AppDb.kOllamaModel);
  }

  Future<OllamaResult> summarizeProject(String projectId) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final proj = await (db.select(
      db.projects,
    )..where((t) => t.id.equals(projectId))).getSingleOrNull();

    // Resolve items by querying stages that belong to this project
    final projectStages = await db.getStagesForProject(projectId);
    final stageIds = projectStages.map((s) => s.id).toSet();

    final all = await db.getAllActiveWorkItems();
    final projectItems = all
        .where((i) => stageIds.contains(i.stageId))
        .toList();

    final active = projectItems
        .where((i) => !['done', 'archived'].contains(i.status))
        .map((i) => i.title)
        .toList();
    final blocked = projectItems
        .where((i) => i.blockedReason != null)
        .map((i) => '${i.title} (${i.blockedReason})')
        .toList();
    final done = projectItems
        .where((i) => i.status == 'done')
        .map((i) => i.title)
        .take(10)
        .toList();

    return svc.summarizeProject(
      projectTitle: proj?.title ?? projectId,
      activeItems: active,
      blockedItems: blocked,
      completedRecently: done,
    );
  }

  Future<OllamaResult> summarizeToday() async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final items = await getTodayItems();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return svc.summarizeToday(
      doingItems: items
          .where((i) => i.status == 'doing')
          .map((i) => i.title)
          .toList(),
      overdueItems: items
          .where(
            (i) =>
                i.dueAt != null &&
                i.dueAt!.isBefore(today) &&
                i.status != 'doing',
          )
          .map((i) => i.title)
          .toList(),
      dueTodayItems: items
          .where(
            (i) =>
                i.dueAt != null &&
                !i.dueAt!.isBefore(today) &&
                i.dueAt!.isBefore(today.add(const Duration(days: 1))),
          )
          .map((i) => i.title)
          .toList(),
      blockedItems: items
          .where((i) => i.blockedReason != null)
          .map((i) => '${i.title} - ${i.blockedReason}')
          .toList(),
    );
  }

  Future<OllamaResult> draftEmailForTask(
    String workItemId,
    String instruction,
  ) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final item = await getWorkItem(workItemId);
    if (item == null) {
      return OllamaResult(
        input: instruction,
        output: null,
        kind: 'email_draft',
        title: 'Email Draft',
      );
    }

    return svc.draftEmail(
      taskTitle: item.title,
      taskDescription: item.description,
      blockedReason: item.blockedReason,
      instruction: instruction,
    );
  }

  Future<OllamaResult> extractTasksFromNote(
    String projectId,
    String rawNote,
  ) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final proj = await (db.select(
      db.projects,
    )..where((t) => t.id.equals(projectId))).getSingleOrNull();

    return svc.extractTasksFromNote(
      rawNote: rawNote,
      projectTitle: proj?.title ?? projectId,
    );
  }

  // ---------------------------------------------------------------------------
  // Extended project lifecycle
  // ---------------------------------------------------------------------------

  Stream<List<ProjectFull>> watchProjectsFull() => db.watchProjectsFull();
  Future<List<ProjectFull>> getProjectsFull() => db.getProjectsFull();
  Future<ProjectFull?> getProjectFull(String id) => db.getProjectFull(id);
  Future<Project?> getGeneralTasksProject() => db.getGeneralTasksProject();
  Stream<Map<String, ProjectUpdateAttribution>>
  watchProjectUpdateAttributions() => db.watchProjectUpdateAttributions();
  Future<Map<String, ProjectUpdateAttribution>>
  getProjectUpdateAttributions() => db.getProjectUpdateAttributions();

  Future<void> updateProjectMeta(
    String id,
    Map<String, Object?> fields, {
    String actor = 'Operator',
  }) async {
    final before = await db.getProjectFull(id);
    await db.updateProjectMeta(id, fields);
    final after = await db.getProjectFull(id);
    final changes = _projectMetaChanges(before, after, fields.keys);
    if (changes.isNotEmpty) {
      await db.logEvent(
        area: 'projects',
        action: 'project_metadata_updated',
        entityType: 'project',
        entityId: id,
        inputJson: jsonEncode({'requestedFields': fields.keys.toList()}),
        outputJson: jsonEncode({
          'agent': actor,
          'actor': {'type': _actorTypeForLabel(actor), 'displayName': actor},
          'changedFieldCount': changes.length,
          'changedFields': changes,
        }),
      );
    }
    notifyListeners();
  }

  Map<String, Object?> _projectMetaChanges(
    Project? before,
    Project? after,
    Iterable<String> fieldKeys,
  ) {
    if (before == null || after == null) return const <String, Object?>{};
    final beforeJson = before.toJson();
    final afterJson = after.toJson();
    final result = <String, Object?>{};
    for (final key in fieldKeys) {
      final oldValue = beforeJson[key];
      final newValue = afterJson[key];
      if (oldValue == newValue) continue;
      result[key] = {'from': oldValue, 'to': newValue};
    }
    return result;
  }

  String _actorTypeForLabel(String actor) {
    final normalized = actor.trim().toLowerCase();
    if (normalized == 'atlas agent' ||
        normalized == 'codex' ||
        normalized.startsWith('model:')) {
      return 'ai';
    }
    if (normalized == 'atlas') return 'system';
    return 'operator';
  }

  Stream<ProjectRuntimeProfile?> watchProjectRuntimeProfile(String projectId) =>
      db.watchProjectRuntimeProfile(projectId);

  Future<ProjectRuntimeProfile?> getProjectRuntimeProfile(String projectId) =>
      db.getProjectRuntimeProfile(projectId);

  Stream<List<ProjectRuntimeRun>> watchProjectRuntimeRuns(
    String projectId, {
    int limit = 20,
  }) => db.watchProjectRuntimeRuns(projectId, limit: limit);

  Stream<List<ProjectRuntimeRun>> watchLatestRuntimeRunsForProjects({
    int limit = 200,
  }) => db.watchLatestRuntimeRunsForProjects(limit: limit);

  Future<ProjectRuntimeProfile> saveProjectRuntimeProfileDraft(
    String projectId,
    ProjectRuntimeProfileDraft draft,
  ) async {
    final profile = await db.saveProjectRuntimeProfile(
      projectId: projectId,
      enabled: draft.enabled,
      workingDirectory: _metaString(draft.workingDirectory),
      launchCommand: _metaString(draft.launchCommand),
      stopCommand: _metaString(draft.stopCommand),
      testCommandsJson: encodeStringList(draft.testCommands),
      portsJson: encodeIntList(draft.ports),
      urlsJson: encodeRuntimeUrls(draft.urls),
      healthUrlsJson: encodeStringList(draft.healthUrls),
      notes: _metaString(draft.notes),
      autostart: draft.autostart,
      capsuleEnabled: draft.capsuleEnabled,
      capsuleMode: normalizeCapsuleMode(draft.capsuleMode),
      capsuleSourcePath:
          _metaString(draft.capsuleSourcePath) ?? defaultProjectProtocolPath,
      capsuleProfile: _metaString(draft.capsuleProfile),
      importSource: _metaString(draft.importSource),
      lastImportedAt: draft.lastImportedAt,
    );
    await db.logEvent(
      area: 'runtime',
      action: 'runtime_profile_saved',
      entityType: 'project',
      entityId: projectId,
      outputJson: jsonEncode({'enabled': draft.enabled}),
    );
    return profile;
  }

  Future<void> deleteProjectRuntimeProfile(String projectId) async {
    await db.deleteProjectRuntimeProfile(projectId);
    await db.logEvent(
      area: 'runtime',
      action: 'runtime_profile_deleted',
      entityType: 'project',
      entityId: projectId,
    );
  }

  Future<ProjectRuntimeProfile?> importRuntimeProfileFromManifest(
    String projectId, {
    String? yamlPath,
    RuntimeManifestImporter importer = const RuntimeManifestImporter(),
  }) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) throw StateError('Project not found: $projectId');
    final defaults = await loadProjectRuntimeDefaultsSettings();
    final resolvedYamlPath =
        _metaString(yamlPath) ?? defaults.resolvedRuntimeManifestPath;
    final draft = await importer.readProfileForProject(
      projectTitle: project.title,
      yamlPath: resolvedYamlPath,
    );
    if (draft == null) return null;
    final profile = await saveProjectRuntimeProfileDraft(
      projectId,
      defaults.applyToImportedDraft(draft),
    );
    await db.logEvent(
      area: 'runtime',
      action: 'runtime_profile_imported',
      entityType: 'project',
      entityId: projectId,
      inputJson: resolvedYamlPath,
      outputJson: jsonEncode({'matched': project.title}),
    );
    return profile;
  }

  Future<ProjectRuntimeRun> launchProjectRuntime(String projectId) async {
    final profile = await _runtimeProfileForAction(projectId);
    final run = await ProjectRuntimeService(db: db).runLaunch(profile);
    return run;
  }

  Future<ProjectRuntimeRun> runProjectRuntimeTest(
    String projectId, {
    String? command,
  }) async {
    final profile = await _runtimeProfileForAction(projectId);
    final run = await ProjectRuntimeService(
      db: db,
    ).runTest(profile, command: command);
    return run;
  }

  Future<ProjectRuntimeRun> runProjectRuntimeCapsule(String projectId) async {
    final profile = await _runtimeProfileForAction(projectId);
    final run = await ProjectRuntimeService(db: db).runCapsule(profile);
    return run;
  }

  Future<ProjectRuntimeProfile> _runtimeProfileForAction(
    String projectId,
  ) async {
    final profile = await db.getProjectRuntimeProfile(projectId);
    if (profile == null || !profile.enabled) {
      throw StateError('Runtime profile is not enabled for this project.');
    }
    return profile;
  }

  Future<void> softDeleteProject(String id, String reason) async {
    await db.softDeleteProject(id, reason);
    if (_activeProject?.id == id) await db.setActiveProjectId(null);
    notifyListeners();
  }

  Future<List<WorkItem>> getWorkItemsForProject(String projectId) =>
      db.getWorkItemsForProject(projectId);

  Stream<List<Contact>> watchContacts() => db.watchContacts();
  Future<List<Contact>> getContacts() => db.getContacts();

  Future<ContactContinuityResult> ensureContactContinuity({
    String ownerName = 'Project Owner',
    String? ownerEmail,
    bool assignVisibleProjectsToOwner = true,
    bool ensureOwnerPeopleRows = true,
    bool seedSystemActors = true,
  }) async {
    final cleanOwnerName = _metaString(ownerName) ?? 'Project Owner';
    final seeds = <_ContactSeed>[
      _ContactSeed(
        id: 'contact_operator_project_owner',
        name: cleanOwnerName,
        title: 'Owner / Operator',
        email: ownerEmail,
        notes:
            'Primary Project Atlas owner. Seeded for project ownership continuity.',
      ),
      if (seedSystemActors) ...[
        const _ContactSeed(
          id: 'contact_system_atlas',
          name: 'Atlas',
          title: 'Project Atlas system actor',
          notes:
              'System actor used for app-originated project updates and logs.',
        ),
        const _ContactSeed(
          id: 'contact_system_atlas_agent',
          name: 'Atlas Agent',
          title: 'AI-assisted project actor',
          notes:
              'System actor used when approved Atlas agent proposals update project state.',
        ),
        const _ContactSeed(
          id: 'contact_system_codex',
          name: 'Codex',
          title: 'AI coding agent',
          notes:
              'System actor used for Codex-assisted code and project updates.',
        ),
      ],
    ];
    final modelContact = await _currentModelContactSeed();
    if (seedSystemActors && modelContact != null) {
      seeds.add(modelContact);
    }

    var contactsSeeded = 0;
    String? ownerContactId;
    for (final seed in seeds) {
      final contactId = await _upsertContinuityContact(seed);
      contactsSeeded++;
      if (seed.name == cleanOwnerName) ownerContactId = contactId;
    }
    final duplicateContactsRemoved = await _deduplicateContinuityContacts(
      seeds,
    );

    final ownerContact = await db.getContact(ownerContactId!);
    if (ownerContact == null) {
      throw StateError('Owner contact was not created: $ownerContactId');
    }

    final projects = assignVisibleProjectsToOwner
        ? await db.getProjectsFull()
        : const <Project>[];
    var ownersUpdated = 0;
    var peopleAdded = 0;
    var peopleUpdated = 0;
    for (final project in projects) {
      if (!_sameContactLabel(project.owner, ownerContact)) {
        await updateProjectMeta(project.id, {
          'owner': ownerContact.name,
        }, actor: 'Operator');
        ownersUpdated++;
      }
      if (ensureOwnerPeopleRows) {
        final people = await db.getProjectPeople(project.id);
        final existing = _matchingProjectPerson(people, ownerContact);
        if (existing == null) {
          await db.addProjectPerson(
            project.id,
            ownerContact.name,
            'Owner',
            'Accountable',
          );
          peopleAdded++;
          await db.logEvent(
            area: 'projects',
            action: 'project_owner_person_added',
            entityType: 'project',
            entityId: project.id,
            outputJson: jsonEncode({
              'actor': {'type': 'operator', 'displayName': ownerContact.name},
              'person': ownerContact.name,
              'role': 'Owner',
              'authority': 'Accountable',
            }),
          );
        } else if (_isBlank(existing.role) || _isBlank(existing.authority)) {
          await db.updateProjectPerson(
            existing.id,
            existing.name,
            _isBlank(existing.role) ? 'Owner' : existing.role,
            _isBlank(existing.authority) ? 'Accountable' : existing.authority,
          );
          peopleUpdated++;
        }
      }
    }

    final result = ContactContinuityResult(
      ownerContactId: ownerContact.id,
      ownerName: ownerContact.name,
      contactsSeeded: contactsSeeded,
      projectsConsidered: projects.length,
      projectOwnersUpdated: ownersUpdated,
      projectPeopleAdded: peopleAdded,
      projectPeopleUpdated: peopleUpdated,
      duplicateContactsRemoved: duplicateContactsRemoved,
    );
    await db.logEvent(
      area: 'contacts',
      action: 'contact_continuity_seeded',
      entityType: 'contact',
      entityId: ownerContact.id,
      outputJson: jsonEncode(result.toJson()),
    );
    notifyListeners();
    return result;
  }

  ProjectPerson? _matchingProjectPerson(
    List<ProjectPerson> people,
    Contact contact,
  ) {
    for (final person in people) {
      if (_sameContactLabel(person.name, contact)) return person;
    }
    return null;
  }

  Future<int> _deduplicateContinuityContacts(List<_ContactSeed> seeds) async {
    var removed = 0;
    for (final seed in seeds) {
      final all = await db.getContacts();
      final matches = all
          .where(
            (contact) =>
                contact.name.trim().toLowerCase() ==
                seed.name.trim().toLowerCase(),
          )
          .toList(growable: false);
      if (matches.length <= 1) continue;
      final keep = matches.firstWhere(
        (contact) => contact.id == seed.id,
        orElse: () => matches.first,
      );
      final mergedNotes = matches
          .map((contact) => _metaString(contact.notes))
          .whereType<String>()
          .fold<String?>(null, (merged, notes) {
            if (merged == null) return notes;
            if (merged.contains(notes)) return merged;
            return '$merged\n\n$notes';
          });
      await db.saveContact(
        id: keep.id,
        name: keep.name,
        title: _preferExisting(keep.title, seed.title),
        phone: keep.phone,
        alternatePhone: keep.alternatePhone,
        email: _preferExisting(keep.email, seed.email),
        website: keep.website,
        businessName: keep.businessName,
        notes: _mergeContinuityNotes(mergedNotes, seed.notes),
        photoPath: keep.photoPath,
      );
      for (final duplicate in matches) {
        if (duplicate.id == keep.id) continue;
        await db.deleteContact(duplicate.id);
        removed++;
      }
    }
    return removed;
  }

  Future<String> _upsertContinuityContact(_ContactSeed seed) async {
    final existing = await _findContinuityContact(seed);
    return db.saveContact(
      id: existing?.id ?? seed.id,
      name: seed.name,
      title: _preferExisting(existing?.title, seed.title),
      phone: existing?.phone,
      alternatePhone: existing?.alternatePhone,
      email: _preferExisting(existing?.email, seed.email),
      website: existing?.website,
      businessName: existing?.businessName,
      notes: _mergeContinuityNotes(existing?.notes, seed.notes),
      photoPath: existing?.photoPath,
    );
  }

  Future<Contact?> _findContinuityContact(_ContactSeed seed) async {
    final contacts = await db.getContacts();
    for (final contact in contacts) {
      if (contact.id == seed.id) return contact;
    }
    final seedEmail = _metaString(seed.email)?.toLowerCase();
    if (seedEmail != null) {
      for (final contact in contacts) {
        if (contact.email?.trim().toLowerCase() == seedEmail) {
          return contact;
        }
      }
    }
    final seedName = seed.name.trim().toLowerCase();
    for (final contact in contacts) {
      if (contact.name.trim().toLowerCase() == seedName) return contact;
    }
    return null;
  }

  Future<_ContactSeed?> _currentModelContactSeed() async {
    final model =
        _metaString(await getSetting(AppDb.kProjectAiSummaryModel)) ??
        _metaString(await getSetting(AppDb.kOllamaModel));
    if (model == null) return null;
    return _ContactSeed(
      id: 'contact_model_${_safeFileStem(model).toLowerCase()}',
      name: 'Model: $model',
      title: 'AI model actor',
      notes:
          'Model contact seeded for AI summary/change continuity. Current configured model: $model.',
    );
  }

  String? _preferExisting(String? existing, String? fallback) =>
      _metaString(existing) ?? _metaString(fallback);

  String? _mergeContinuityNotes(String? existing, String? seed) {
    final current = _metaString(existing);
    final next = _metaString(seed);
    if (current == null) return next;
    if (next == null || current.contains(next)) return current;
    return '$current\n\n$next';
  }

  Future<String> saveContact({
    String? id,
    required String name,
    String? title,
    String? phone,
    String? alternatePhone,
    String? email,
    String? website,
    String? businessName,
    String? notes,
    String? photoPath,
  }) async {
    final contactId = await db.saveContact(
      id: id,
      name: name,
      title: title,
      phone: phone,
      alternatePhone: alternatePhone,
      email: email,
      website: website,
      businessName: businessName,
      notes: notes,
      photoPath: photoPath,
    );
    await db.logEvent(
      area: 'contacts',
      action: id == null ? 'contact_created' : 'contact_updated',
      entityType: 'contact',
      entityId: contactId,
      inputJson: name,
    );
    return contactId;
  }

  Future<void> deleteContact(String id) async {
    await db.deleteContact(id);
    await db.logEvent(
      area: 'contacts',
      action: 'contact_deleted',
      entityType: 'contact',
      entityId: id,
    );
  }

  Future<ContactResponsibilities> getContactResponsibilities(
    Contact contact,
  ) async {
    final projects = await db.getProjectsFull();
    final peopleMatches = <ProjectPerson>[];
    final ownedProjects = <Project>[];
    final contributingProjects = <Project>[];
    for (final project in projects) {
      if (_sameContactLabel(project.owner, contact)) ownedProjects.add(project);
      final people = await db.getProjectPeople(project.id);
      for (final person in people) {
        if (_sameContactLabel(person.name, contact)) {
          peopleMatches.add(person);
          contributingProjects.add(project);
        }
      }
    }
    final tasks = (await db.getAllActiveWorkItems())
        .where((item) => _sameContactLabel(item.owner, contact))
        .toList(growable: false);
    return ContactResponsibilities(
      ownedProjects: ownedProjects,
      contributingProjects: contributingProjects,
      projectPeople: peopleMatches,
      workItems: tasks,
    );
  }

  bool _sameContactLabel(String? value, Contact contact) {
    final raw = value?.trim().toLowerCase();
    if (raw == null || raw.isEmpty) return false;
    return raw == contact.name.trim().toLowerCase() ||
        (contact.email?.trim().toLowerCase().isNotEmpty == true &&
            raw == contact.email!.trim().toLowerCase());
  }

  Future<int> exportContactsToJson(String path) async {
    final contacts = await db.getContacts();
    final payload = {
      'schema': 'project_atlas_contacts_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'contacts': contacts.map(_contactToJson).toList(),
    };
    await File(
      path,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    await db.logEvent(
      area: 'contacts',
      action: 'contacts_exported',
      outputJson: jsonEncode({'path': path, 'count': contacts.length}),
    );
    return contacts.length;
  }

  Future<int> exportContactsToCsv(String path) async {
    final contacts = await db.getContacts();
    final rows = <String>[
      'id,name,title,phone,alternatePhone,email,website,businessName,notes,photoPath',
      ...contacts.map(
        (c) => [
          c.id,
          c.name,
          c.title ?? '',
          c.phone ?? '',
          c.alternatePhone ?? '',
          c.email ?? '',
          c.website ?? '',
          c.businessName ?? '',
          c.notes ?? '',
          c.photoPath ?? '',
        ].map(_csvEscape).join(','),
      ),
    ];
    await File(path).writeAsString(rows.join('\n'));
    await db.logEvent(
      area: 'contacts',
      action: 'contacts_exported_csv',
      outputJson: jsonEncode({'path': path, 'count': contacts.length}),
    );
    return contacts.length;
  }

  Future<int> importContactsFromJson(String path) async {
    final raw = await File(path).readAsString();
    final decoded = jsonDecode(raw);
    final list = decoded is Map<String, dynamic>
        ? decoded['contacts'] as List<dynamic>? ?? const []
        : decoded as List<dynamic>;
    var count = 0;
    for (final entry in list.whereType<Map>()) {
      final map = entry.cast<String, dynamic>();
      final existing = await db.findContactForImport(
        id: map['id']?.toString(),
        email: map['email']?.toString(),
        name: map['name']?.toString(),
      );
      await db.saveContact(
        id: existing?.id ?? map['id']?.toString(),
        name: map['name']?.toString() ?? '',
        title: map['title']?.toString(),
        phone: map['phone']?.toString(),
        alternatePhone: map['alternatePhone']?.toString(),
        email: map['email']?.toString(),
        website: map['website']?.toString(),
        businessName: map['businessName']?.toString(),
        notes: map['notes']?.toString(),
        photoPath: map['photoPath']?.toString(),
      );
      count++;
    }
    await db.logEvent(
      area: 'contacts',
      action: 'contacts_imported',
      outputJson: jsonEncode({'path': path, 'count': count}),
    );
    return count;
  }

  Map<String, Object?> _contactToJson(Contact c) => {
    'id': c.id,
    'name': c.name,
    'title': c.title,
    'phone': c.phone,
    'alternatePhone': c.alternatePhone,
    'email': c.email,
    'website': c.website,
    'businessName': c.businessName,
    'notes': c.notes,
    'photoPath': c.photoPath,
  };

  String _csvEscape(String value) {
    final needsQuotes =
        value.contains(',') || value.contains('"') || value.contains('\n');
    final escaped = value.replaceAll('"', '""');
    return needsQuotes ? '"$escaped"' : escaped;
  }

  // People
  Future<List<ProjectPerson>> getProjectPeople(String projectId) =>
      db.getProjectPeople(projectId);
  Future<void> addProjectPerson(
    String projectId,
    String name,
    String? role,
    String? authority,
  ) async {
    await db.addProjectPerson(projectId, name, role, authority);
    notifyListeners();
  }

  Future<void> updateProjectPerson(
    String personId,
    String name,
    String? role,
    String? authority,
  ) async {
    await db.updateProjectPerson(personId, name, role, authority);
    notifyListeners();
  }

  Future<void> deleteProjectPerson(String personId) async {
    await db.deleteProjectPerson(personId);
    notifyListeners();
  }

  // Risks
  Future<List<ProjectRisk>> getProjectRisks(String projectId) =>
      db.getProjectRisks(projectId);
  Future<void> addProjectRisk(
    String projectId,
    String title,
    String? desc,
    String severity,
  ) async {
    await db.addProjectRisk(projectId, title, desc, severity);
    notifyListeners();
  }

  Future<void> deleteProjectRisk(String riskId) async {
    await db.deleteProjectRisk(riskId);
    notifyListeners();
  }

  // Decisions
  Future<List<ProjectDecision>> getProjectDecisions(String projectId) =>
      db.getProjectDecisions(projectId);
  Future<void> addProjectDecision(
    String projectId,
    String title,
    String? ctx,
    String? decider,
  ) async {
    await db.addProjectDecision(projectId, title, ctx, decider);
    notifyListeners();
  }

  Future<void> deleteProjectDecision(String decisionId) async {
    await db.deleteProjectDecision(decisionId);
    notifyListeners();
  }

  // Tags
  Stream<List<Tag>> watchTags() => db.watchTags();
  Future<List<Tag>> getTags() => db.getTags();
  Stream<List<Tag>> watchTagsForProject(String projectId) =>
      db.watchTagsForProject(projectId);
  Stream<Map<String, List<Tag>>> watchTagsByProject() =>
      db.watchTagsByProject();
  Stream<Map<String, List<Tag>>> watchWorkItemTags() => db.watchWorkItemTags();
  Stream<Map<String, ProjectFull>> watchProjectsByStage() =>
      db.watchProjectsByStage();
  Future<List<Tag>> getTagsForProject(String projectId) =>
      db.getTagsForProject(projectId);
  Stream<List<Project>> watchProjectsForTag(String tagId) =>
      db.watchProjectsForTag(tagId);
  Future<List<Project>> getProjectsForTag(String tagId) =>
      db.getProjectsForTag(tagId);
  Future<List<Project>> getProjectsMatchingTags(
    Iterable<String> tagIds, {
    bool matchAll = false,
  }) => db.getProjectsMatchingTags(tagIds, matchAll: matchAll);

  // Tag CRUD: no notifyListeners. All UI consumers read tags/assignments via
  // Drift streams (watchTags, watchTagsByProject, watchTagsForProject,
  // watchWorkItemTags); remaining Future reads are dialog-scoped one-shots.

  Future<String> saveTag({
    String? id,
    required String name,
    String? color,
  }) => db.saveTag(id: id, name: name, color: color);

  Future<void> updateTag(String id, {String? name, String? color}) =>
      db.updateTag(id, name: name, color: color);

  Future<void> deleteTag(String id) => db.deleteTag(id);

  Future<void> assignTagToProject(String projectId, String tagId) =>
      db.assignTagToProject(projectId, tagId);

  Future<void> unassignTagFromProject(String projectId, String tagId) =>
      db.unassignTagFromProject(projectId, tagId);

  Future<void> setProjectTags(String projectId, Iterable<String> tagIds) =>
      db.setProjectTags(projectId, tagIds);

  Future<List<Tag>> getTagsForWorkItem(String workItemId) =>
      db.getTagsForWorkItem(workItemId);

  Future<Map<String, List<Tag>>> getTagsForWorkItems(
    Iterable<String> workItemIds,
  ) => db.getTagsForWorkItems(workItemIds);

  Future<void> setWorkItemTags(String workItemId, Iterable<String> tagIds) =>
      db.setWorkItemTags(workItemId, tagIds);

  // Project media
  Stream<List<ProjectMediaItem>> watchAllProjectMedia() =>
      db.watchAllProjectMedia();
  Future<List<ProjectMediaItem>> getAllProjectMedia() =>
      db.getAllProjectMedia();
  Stream<List<ProjectMediaItem>> watchProjectMedia(String projectId) =>
      db.watchProjectMedia(projectId);
  Future<List<ProjectMediaItem>> getProjectMedia(String projectId) =>
      db.getProjectMedia(projectId);
  Future<ProjectMediaItem?> getProjectMediaItem(String id) =>
      db.getProjectMediaItem(id);

  Future<String> saveProjectMedia({
    String? id,
    required String projectId,
    required String title,
    required String originalFilename,
    required String storedPath,
    String mediaType = 'file',
    String? mimeType,
    String? extension,
    int? byteSize,
    DateTime? fileModifiedAt,
    String? caption,
    bool isCover = false,
    String? source,
    String? metadataJson,
  }) async {
    final mediaId = await db.saveProjectMedia(
      id: id,
      projectId: projectId,
      title: title,
      originalFilename: originalFilename,
      storedPath: storedPath,
      mediaType: mediaType,
      mimeType: mimeType,
      extension: extension,
      byteSize: byteSize,
      fileModifiedAt: fileModifiedAt,
      caption: caption,
      isCover: isCover,
      source: source,
      metadataJson: metadataJson,
    );
    return mediaId;
  }

  Future<String> importProjectMediaFromPath(
    String projectId,
    String path, {
    String? title,
    String? caption,
    bool isCover = false,
    String? source,
    String? metadataJson,
  }) async {
    final sourceFile = File(path);
    if (!sourceFile.existsSync()) {
      throw FileSystemException('File not found', path);
    }
    final mediaDir = await _projectMediaDirectory(projectId);
    final storedPath = await _copyIntoMediaVault(sourceFile, mediaDir);
    final sourcePayload = source?.trim().isNotEmpty == true
        ? source
        : sourceFile.path;
    final metadataPayload = _mergeMediaMetadata(metadataJson, {
      'originalPath': sourceFile.path,
    });
    final mediaId = await db.importProjectMediaFromPath(
      projectId,
      storedPath,
      title: title,
      caption: caption,
      isCover: isCover,
      source: sourcePayload,
      metadataJson: metadataPayload,
    );
    return mediaId;
  }

  Future<void> updateProjectMedia(
    String id, {
    String? title,
    String? caption,
    bool? isCover,
    String? source,
    String? metadataJson,
  }) async {
    await db.updateProjectMedia(
      id,
      title: title,
      caption: caption,
      isCover: isCover,
      source: source,
      metadataJson: metadataJson,
    );
  }

  Future<void> setProjectCoverMedia(String projectId, String mediaId) async {
    await db.setProjectCoverMedia(projectId, mediaId);
  }

  Future<void> deleteProjectMedia(String id) async {
    final media = await db.getProjectMediaItem(id);
    await db.deleteProjectMedia(id);
    if (media != null) {
      await _deleteAppOwnedMediaFileBestEffort(media);
    }
  }

  Stream<List<ProjectMediaItem>> watchMediaForWorkItem(String workItemId) =>
      db.watchProjectMediaForEntity(
        entityType: 'work_item',
        entityId: workItemId,
      );

  Future<List<ProjectMediaItem>> getMediaForWorkItem(String workItemId) => db
      .getProjectMediaForEntity(entityType: 'work_item', entityId: workItemId);

  Stream<List<ProjectMediaItem>> watchMediaForLlmTask(String taskId) =>
      db.watchProjectMediaForEntity(entityType: 'llm_task', entityId: taskId);

  Future<List<ProjectMediaItem>> getMediaForLlmTask(String taskId) =>
      db.getProjectMediaForEntity(entityType: 'llm_task', entityId: taskId);

  Future<void> attachProjectMediaToWorkItem(
    String workItemId,
    String mediaId,
  ) async {
    final project = await db.getProjectForWorkItem(workItemId);
    final media = await db.getProjectMediaItem(mediaId);
    if (project == null) throw StateError('Work item not found: $workItemId');
    if (media == null) throw StateError('Media not found: $mediaId');
    if (media.projectId != project.id) {
      throw StateError('Media belongs to a different project: $mediaId');
    }
    await db.linkProjectMediaToEntity(
      mediaId: mediaId,
      entityType: 'work_item',
      entityId: workItemId,
    );
  }

  Future<String> importWorkItemMediaFromPath(
    String workItemId,
    String path, {
    String? title,
    String? caption,
  }) async {
    final project = await db.getProjectForWorkItem(workItemId);
    if (project == null) throw StateError('Work item not found: $workItemId');
    final mediaId = await importProjectMediaFromPath(
      project.id,
      path,
      title: title,
      caption: caption,
      source: path,
      metadataJson: jsonEncode({'entityType': 'work_item'}),
    );
    await attachProjectMediaToWorkItem(workItemId, mediaId);
    return mediaId;
  }

  Future<void> unlinkProjectMediaFromWorkItem(
    String workItemId,
    String mediaId,
  ) async {
    await db.unlinkProjectMediaFromEntity(
      mediaId: mediaId,
      entityType: 'work_item',
      entityId: workItemId,
    );
  }

  Future<void> attachProjectMediaToLlmTask(
    String taskId,
    String mediaId,
  ) async {
    final task = await db.getLlmTask(taskId);
    final media = await db.getProjectMediaItem(mediaId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    if (media == null) throw StateError('Media not found: $mediaId');
    if (media.projectId != task.projectId) {
      throw StateError('Media belongs to a different project: $mediaId');
    }
    await db.linkProjectMediaToEntity(
      mediaId: mediaId,
      entityType: 'llm_task',
      entityId: taskId,
    );
  }

  Future<String> importLlmTaskMediaFromPath(
    String taskId,
    String path, {
    String? title,
    String? caption,
  }) async {
    final task = await db.getLlmTask(taskId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    final mediaId = await importProjectMediaFromPath(
      task.projectId,
      path,
      title: title,
      caption: caption,
      source: path,
      metadataJson: jsonEncode({'entityType': 'llm_task'}),
    );
    await attachProjectMediaToLlmTask(taskId, mediaId);
    return mediaId;
  }

  Future<void> unlinkProjectMediaFromLlmTask(
    String taskId,
    String mediaId,
  ) async {
    await db.unlinkProjectMediaFromEntity(
      mediaId: mediaId,
      entityType: 'llm_task',
      entityId: taskId,
    );
  }

  /// Immediate, permanent delete (row + links + stored file). Kept for the
  /// purge path and internal replace flows; UI deletion goes through
  /// [softDeleteDocument] so it can be undone.
  Future<void> deleteDocument(String id) async {
    await db.deleteDocument(id);
  }

  /// Soft-deletes a document: hides it from every read query but leaves the
  /// DB row and the file on disk untouched so the action can be undone.
  Future<void> softDeleteDocument(String id) async {
    await db.softDeleteDocument(id);
    await db.logEvent(
      area: 'documents',
      action: 'document_soft_deleted',
      entityType: 'document',
      entityId: id,
    );
    notifyListeners();
  }

  /// Undoes a soft delete.
  Future<void> restoreDocument(String id) async {
    await db.restoreDocument(id);
    await db.logEvent(
      area: 'documents',
      action: 'document_restored',
      entityType: 'document',
      entityId: id,
    );
    notifyListeners();
  }

  /// Permanently removes documents that were soft-deleted at least
  /// [olderThan] ago. The stored file is deleted from disk only when it lives
  /// inside the app-owned `atlas_documents` directory (imports always copy
  /// there; foreign paths are never touched); the row and its links are then
  /// hard-deleted.
  Future<void> purgeExpiredDeletedDocuments({
    Duration olderThan = const Duration(days: 7),
  }) async {
    final expired = await db.getSoftDeletedDocumentsOlderThan(olderThan);
    if (expired.isEmpty) return;
    final appDocDir = await getApplicationDocumentsDirectory();
    final atlasDir = p.normalize(p.join(appDocDir.path, 'atlas_documents'));
    var purged = 0;
    for (final doc in expired) {
      final storedPath = doc.storedPath?.trim() ?? '';
      if (storedPath.isNotEmpty) {
        final normalized = p.normalize(storedPath);
        if (p.isWithin(atlasDir, normalized)) {
          try {
            final file = File(normalized);
            if (await file.exists()) await file.delete();
          } on FileSystemException catch (error) {
            debugPrint(
              '[Atlas] purgeExpiredDeletedDocuments: failed to delete '
              '$normalized: $error',
            );
          }
        }
      }
      await db.deleteDocumentRowOnly(doc.id);
      purged++;
    }
    await db.logEvent(
      area: 'documents',
      action: 'documents_purged',
      outputJson: jsonEncode({'purged': purged}),
    );
  }

  Future<Directory> _projectMediaDirectory(String projectId) async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'project_media', projectId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _copyIntoMediaVault(File source, Directory dir) async {
    final basename = p.basename(source.path);
    final ext = p.extension(basename);
    final stem = p.basenameWithoutExtension(basename);
    var candidate = p.join(dir.path, basename);
    var index = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(dir.path, '${stem}_$index$ext');
      index++;
    }
    final copied = await source.copy(candidate);
    return copied.path;
  }

  Future<void> _deleteAppOwnedMediaFileBestEffort(
    ProjectMediaItem media,
  ) async {
    try {
      final mediaDir = await _projectMediaDirectory(media.projectId);
      final storedPath = media.storedPath.trim();
      if (storedPath.isEmpty) return;

      final normalizedMediaDir = p.normalize(mediaDir.path);
      final normalizedStoredPath = p.normalize(storedPath);
      if (normalizedStoredPath == normalizedMediaDir ||
          !p.isWithin(normalizedMediaDir, normalizedStoredPath)) {
        return;
      }

      final file = File(normalizedStoredPath);
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException catch (error) {
      debugPrint(
        '[Atlas] Failed to delete copied project media file '
        '${media.storedPath}: $error',
      );
    }
  }

  String? _mergeMediaMetadata(String? rawJson, Map<String, Object?> extra) {
    final base = <String, Object?>{};
    if (rawJson != null && rawJson.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawJson);
        if (decoded is Map<String, dynamic>) {
          base.addAll(decoded);
        }
      } catch (_) {
        base['raw'] = rawJson;
      }
    }
    base.addAll(extra);
    return jsonEncode(base);
  }

  // Documents for project
  Stream<List<Document>> watchDocumentsForProject(String projectId) =>
      db.watchDocumentsForProject(projectId);

  // ── Project summary cache ───────────────────────────────────────────────

  // ---------------------------------------------------------------------------
  // Local Operations Registry
  // ---------------------------------------------------------------------------

  Stream<List<ProjectEnrichmentRun>> watchProjectEnrichmentRuns({
    int limit = 50,
  }) => db.watchProjectEnrichmentRuns(limit: limit);

  Future<List<ProjectEnrichmentRun>> getProjectEnrichmentRuns({
    int limit = 50,
  }) => db.getProjectEnrichmentRuns(limit: limit);

  Future<ProjectEnrichmentRun?> getProjectEnrichmentRun(String id) =>
      db.getProjectEnrichmentRun(id);

  Future<List<ProjectEnrichmentFinding>> getProjectEnrichmentFindingsForRun(
    String runId,
  ) => db.getProjectEnrichmentFindingsForRun(runId);

  Future<List<ProjectEnrichmentStep>> getProjectEnrichmentStepsForRun(
    String runId,
  ) => db.getProjectEnrichmentStepsForRun(runId);

  Future<List<ProjectEnrichmentProposal>> getProjectEnrichmentProposalsForRun(
    String runId,
  ) => db.getProjectEnrichmentProposalsForRun(runId);

  Stream<List<ProjectEnrichmentFinding>> watchProjectEnrichmentFindingsForRun(
    String runId,
  ) => db.watchProjectEnrichmentFindingsForRun(runId);

  Stream<List<ProjectEnrichmentStep>> watchProjectEnrichmentStepsForRun(
    String runId,
  ) => db.watchProjectEnrichmentStepsForRun(runId);

  Stream<List<ProjectEnrichmentProposal>> watchProjectEnrichmentProposalsForRun(
    String runId,
  ) => db.watchProjectEnrichmentProposalsForRun(runId);

  Future<List<ProjectEnrichmentFinding>> getOpenProjectEnrichmentFindings({
    String? projectId,
    int limit = 100,
  }) => db.getOpenProjectEnrichmentFindings(projectId: projectId, limit: limit);

  Future<List<ProjectHealthFindingSuppression>>
  getProjectHealthFindingSuppressions() async {
    final raw = await db.getMetaString(_projectHealthSuppressionsMetaKey);
    if (raw == null || raw.trim().isEmpty) {
      return const <ProjectHealthFindingSuppression>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <ProjectHealthFindingSuppression>[];
      return decoded
          .whereType<Map>()
          .map(
            (item) => ProjectHealthFindingSuppression.fromJson(
              Map<String, Object?>.from(item),
            ),
          )
          .where((item) => item.fingerprint.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <ProjectHealthFindingSuppression>[];
    }
  }

  Future<void> clearProjectHealthFindingSuppression(
    String fingerprint, {
    String actor = 'Operator',
  }) async {
    final target = fingerprint.trim();
    if (target.isEmpty) return;
    final suppressions = await getProjectHealthFindingSuppressions();
    final remaining = suppressions
        .where((item) => item.fingerprint != target)
        .toList(growable: false);
    if (remaining.length == suppressions.length) return;
    await _saveProjectHealthFindingSuppressions(remaining);
    await db.logEvent(
      area: 'project_health',
      action: 'project_health_finding_suppression_cleared',
      entityType: 'project_health_suppression',
      entityId: target,
      outputJson: jsonEncode({'actor': actor, 'fingerprint': target}),
    );
    notifyListeners();
  }

  Future<ProjectHealthFindingSuppression> suppressProjectHealthFinding({
    required String findingId,
    String actor = 'Operator',
    String? note,
  }) async {
    final finding = await db.getProjectEnrichmentFinding(findingId);
    if (finding == null) {
      throw StateError('Project health finding not found: $findingId');
    }
    final suppression = _suppressionFromFinding(
      finding,
      actor: actor,
      note: note,
    );
    final suppressions = await getProjectHealthFindingSuppressions();
    final byFingerprint = <String, ProjectHealthFindingSuppression>{
      for (final item in suppressions) item.fingerprint: item,
      suppression.fingerprint: suppression,
    };
    await _saveProjectHealthFindingSuppressions(byFingerprint.values);
    await db.updateProjectEnrichmentFindingStatus(
      id: findingId,
      status: 'suppressed',
    );
    await db.refreshProjectEnrichmentRunOpenFindings(finding.runId);
    await db.logEvent(
      area: 'project_health',
      action: 'project_health_finding_suppressed',
      entityType: finding.projectId == null
          ? 'project_enrichment_finding'
          : 'project',
      entityId: finding.projectId ?? finding.id,
      inputJson: note,
      outputJson: jsonEncode({
        'actor': actor,
        'findingId': finding.id,
        'runId': finding.runId,
        'projectId': finding.projectId,
        'registryId': finding.registryId,
        'fingerprint': suppression.fingerprint,
        'category': finding.category,
        'title': finding.title,
        'suppressedAt': suppression.suppressedAt.toIso8601String(),
      }),
    );
    notifyListeners();
    return suppression;
  }

  Future<List<ProjectHealthFindingSuppression>> suppressProjectHealthFindings({
    required Iterable<String> findingIds,
    String actor = 'Operator',
    String? note,
  }) async {
    final ids = findingIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return const <ProjectHealthFindingSuppression>[];
    final suppressions = <ProjectHealthFindingSuppression>[];
    final runIds = <String>{};
    final existing = await getProjectHealthFindingSuppressions();
    final byFingerprint = <String, ProjectHealthFindingSuppression>{
      for (final item in existing) item.fingerprint: item,
    };
    for (final id in ids) {
      final finding = await db.getProjectEnrichmentFinding(id);
      if (finding == null) {
        throw StateError('Project health finding not found: $id');
      }
      final suppression = _suppressionFromFinding(
        finding,
        actor: actor,
        note: note,
      );
      byFingerprint[suppression.fingerprint] = suppression;
      suppressions.add(suppression);
      runIds.add(finding.runId);
      await db.updateProjectEnrichmentFindingStatus(
        id: finding.id,
        status: 'suppressed',
      );
    }
    await _saveProjectHealthFindingSuppressions(byFingerprint.values);
    for (final runId in runIds) {
      await db.refreshProjectEnrichmentRunOpenFindings(runId);
    }
    await db.logEvent(
      area: 'project_health',
      action: 'project_health_findings_batch_suppressed',
      entityType: 'project_health_suppression',
      entityId: suppressions.first.fingerprint,
      inputJson: note,
      outputJson: jsonEncode({
        'actor': actor,
        'findingIds': ids.toList(),
        'fingerprints': suppressions
            .map((item) => item.fingerprint)
            .toList(growable: false),
        'suppressedAt': DateTime.now().toIso8601String(),
      }),
    );
    notifyListeners();
    return suppressions;
  }

  Future<void> _saveProjectHealthFindingSuppressions(
    Iterable<ProjectHealthFindingSuppression> suppressions,
  ) {
    final rows = suppressions.toList(growable: false)
      ..sort((a, b) => a.suppressedAt.compareTo(b.suppressedAt));
    return db.setMetaString(
      _projectHealthSuppressionsMetaKey,
      jsonEncode(rows.map((item) => item.toJson()).toList(growable: false)),
    );
  }

  Future<ProjectEnrichmentFinding> dismissProjectEnrichmentFinding({
    required String findingId,
    bool ignoreRegistryEntry = false,
    String actor = 'Operator',
    String? note,
  }) async {
    final finding = await db.getProjectEnrichmentFinding(findingId);
    if (finding == null) {
      throw StateError('Project health finding not found: $findingId');
    }
    final now = DateTime.now();
    ProjectRegistryEntry? ignoredRegistry;
    if (ignoreRegistryEntry) {
      final registryId = finding.registryId;
      if (registryId == null || registryId.trim().isEmpty) {
        throw StateError('This finding is not linked to a registry row.');
      }
      ignoredRegistry = await db.getProjectRegistryEntry(registryId);
      if (ignoredRegistry == null) {
        throw StateError('Registry row not found: $registryId');
      }
      final auditNote = [
        ignoredRegistry.notes?.trim(),
        'Ignored from Project Health by $actor at ${now.toIso8601String()}: ${finding.title}${note == null || note.trim().isEmpty ? '' : ' - ${note.trim()}'}',
      ].where((line) => line != null && line.isNotEmpty).join('\n');
      await db.updateProjectRegistryEntryReviewState(
        id: registryId,
        reviewState: 'ignored',
        notes: auditNote,
        clearAtlasProjectId: true,
      );
    }
    await db.updateProjectEnrichmentFindingStatus(
      id: findingId,
      status: 'dismissed',
    );
    await db.refreshProjectEnrichmentRunOpenFindings(finding.runId);
    await db.logEvent(
      area: 'project_health',
      action: ignoreRegistryEntry
          ? 'project_health_registry_finding_ignored'
          : 'project_health_finding_dismissed',
      entityType: finding.projectId == null
          ? 'project_enrichment_finding'
          : 'project',
      entityId: finding.projectId ?? finding.id,
      inputJson: note,
      outputJson: jsonEncode({
        'actor': actor,
        'findingId': finding.id,
        'runId': finding.runId,
        'projectId': finding.projectId,
        'registryId': finding.registryId,
        'ignoredRegistry': ignoredRegistry?.toJson(),
        'category': finding.category,
        'severity': finding.severity,
        'title': finding.title,
        'dismissedAt': now.toIso8601String(),
      }),
    );
    notifyListeners();
    final updated = await db.getProjectEnrichmentFinding(findingId);
    return updated ?? finding;
  }

  Future<List<ProjectEnrichmentFinding>> dismissProjectEnrichmentFindings({
    required Iterable<String> findingIds,
    String actor = 'Operator',
    String? note,
  }) async {
    final ids = findingIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return const <ProjectEnrichmentFinding>[];
    final dismissed = <ProjectEnrichmentFinding>[];
    final runIds = <String>{};
    final now = DateTime.now();
    for (final id in ids) {
      final finding = await db.getProjectEnrichmentFinding(id);
      if (finding == null) {
        throw StateError('Project health finding not found: $id');
      }
      await db.updateProjectEnrichmentFindingStatus(
        id: id,
        status: 'dismissed',
      );
      runIds.add(finding.runId);
      await db.logEvent(
        area: 'project_health',
        action: 'project_health_finding_dismissed',
        entityType: finding.projectId == null
            ? 'project_enrichment_finding'
            : 'project',
        entityId: finding.projectId ?? finding.id,
        inputJson: note,
        outputJson: jsonEncode({
          'actor': actor,
          'findingId': finding.id,
          'runId': finding.runId,
          'projectId': finding.projectId,
          'registryId': finding.registryId,
          'category': finding.category,
          'severity': finding.severity,
          'title': finding.title,
          'dismissedAt': now.toIso8601String(),
        }),
      );
      dismissed.add(await db.getProjectEnrichmentFinding(id) ?? finding);
    }
    for (final runId in runIds) {
      await db.refreshProjectEnrichmentRunOpenFindings(runId);
    }
    if (ids.length > 1) {
      await db.logEvent(
        area: 'project_health',
        action: 'project_health_findings_batch_dismissed',
        entityType: 'project_enrichment_run',
        entityId: dismissed.first.runId,
        inputJson: note,
        outputJson: jsonEncode({
          'actor': actor,
          'findingIds': ids.toList(),
          'dismissedAt': now.toIso8601String(),
        }),
      );
    }
    notifyListeners();
    return dismissed;
  }

  Future<ProjectEnrichmentFinding> markProjectHealthRegistryFindingReviewed({
    required String findingId,
    String actor = 'Operator',
    String? note,
  }) async {
    final findings = await markProjectHealthRegistryFindingsReviewed(
      findingIds: [findingId],
      actor: actor,
      note: note,
    );
    if (findings.isEmpty) {
      throw StateError('Project health finding was not reviewed: $findingId');
    }
    return findings.single;
  }

  Future<List<ProjectEnrichmentFinding>>
  markProjectHealthRegistryFindingsReviewed({
    required Iterable<String> findingIds,
    String actor = 'Operator',
    String? note,
  }) async {
    final ids = findingIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return const <ProjectEnrichmentFinding>[];
    final reviewed = <ProjectEnrichmentFinding>[];
    final runIds = <String>{};
    final now = DateTime.now();
    for (final id in ids) {
      final finding = await db.getProjectEnrichmentFinding(id);
      if (finding == null) {
        throw StateError('Project health finding not found: $id');
      }
      if (finding.category != 'registry' ||
          finding.registryId == null ||
          finding.registryId!.trim().isEmpty ||
          !finding.title.toLowerCase().contains('still needs review')) {
        throw StateError(
          'Only needs-review registry findings can be marked reviewed.',
        );
      }
      final registry = await db.getProjectRegistryEntry(finding.registryId!);
      if (registry == null) {
        throw StateError('Registry row not found: ${finding.registryId}');
      }
      final linkedProjectId = registry.atlasProjectId?.trim();
      final nextReviewState = linkedProjectId == null || linkedProjectId.isEmpty
          ? 'accepted'
          : 'linked';
      final auditNote = [
        registry.notes?.trim(),
        'Marked reviewed from Project Health by $actor at ${now.toIso8601String()}: ${finding.title}${note == null || note.trim().isEmpty ? '' : ' - ${note.trim()}'}',
      ].where((line) => line != null && line.isNotEmpty).join('\n');
      await db.updateProjectRegistryEntryReviewState(
        id: registry.id,
        reviewState: nextReviewState,
        notes: auditNote,
      );
      await db.updateProjectEnrichmentFindingStatus(
        id: finding.id,
        status: 'dismissed',
      );
      runIds.add(finding.runId);
      await db.logEvent(
        area: 'project_health',
        action: 'project_health_registry_finding_reviewed',
        entityType: linkedProjectId == null || linkedProjectId.isEmpty
            ? 'project_registry'
            : 'project',
        entityId: linkedProjectId == null || linkedProjectId.isEmpty
            ? registry.id
            : linkedProjectId,
        inputJson: note,
        outputJson: jsonEncode({
          'actor': actor,
          'findingId': finding.id,
          'runId': finding.runId,
          'registryId': registry.id,
          'projectId': linkedProjectId,
          'oldReviewState': registry.reviewState,
          'newReviewState': nextReviewState,
          'title': finding.title,
          'reviewedAt': now.toIso8601String(),
        }),
      );
      reviewed.add(await db.getProjectEnrichmentFinding(id) ?? finding);
    }
    for (final runId in runIds) {
      await db.refreshProjectEnrichmentRunOpenFindings(runId);
    }
    if (ids.length > 1) {
      await db.logEvent(
        area: 'project_health',
        action: 'project_health_registry_findings_batch_reviewed',
        entityType: 'project_enrichment_run',
        entityId: reviewed.first.runId,
        inputJson: note,
        outputJson: jsonEncode({
          'actor': actor,
          'findingIds': ids.toList(),
          'reviewedAt': now.toIso8601String(),
        }),
      );
    }
    notifyListeners();
    return reviewed;
  }

  Future<String> linkProjectHealthRegistryFindingToProject({
    required String findingId,
    required String projectId,
    String actor = 'Operator',
  }) async {
    final finding = await _requireProjectHealthRegistryFinding(findingId);
    final registryId = finding.registryId!;
    final updatedProjectId = await updateExistingProjectFromRegistryEntry(
      registryId,
      projectId,
      importDocs: false,
      refresh: false,
    );
    await db.updateProjectEnrichmentFindingStatus(
      id: findingId,
      status: 'dismissed',
    );
    await db.refreshProjectEnrichmentRunOpenFindings(finding.runId);
    await db.logEvent(
      area: 'project_health',
      action: 'project_health_registry_finding_linked',
      entityType: 'project',
      entityId: updatedProjectId,
      inputJson: findingId,
      outputJson: jsonEncode({
        'actor': actor,
        'findingId': finding.id,
        'runId': finding.runId,
        'registryId': registryId,
        'projectId': updatedProjectId,
        'title': finding.title,
        'resolvedAt': DateTime.now().toIso8601String(),
      }),
    );
    notifyListeners();
    return updatedProjectId;
  }

  Future<String> importProjectHealthRegistryFindingAsProject({
    required String findingId,
    String actor = 'Operator',
  }) async {
    final finding = await _requireProjectHealthRegistryFinding(findingId);
    final registryId = finding.registryId!;
    final projectId = await importProjectRegistryEntryAsProject(
      registryId,
      importDocs: false,
      refresh: false,
    );
    await db.updateProjectEnrichmentFindingStatus(
      id: findingId,
      status: 'dismissed',
    );
    await db.refreshProjectEnrichmentRunOpenFindings(finding.runId);
    await db.logEvent(
      area: 'project_health',
      action: 'project_health_registry_finding_imported',
      entityType: 'project',
      entityId: projectId,
      inputJson: findingId,
      outputJson: jsonEncode({
        'actor': actor,
        'findingId': finding.id,
        'runId': finding.runId,
        'registryId': registryId,
        'projectId': projectId,
        'title': finding.title,
        'resolvedAt': DateTime.now().toIso8601String(),
      }),
    );
    notifyListeners();
    return projectId;
  }

  Future<ProjectRegistryEntry> replaceProjectHealthRegistryFindingFolder({
    required String findingId,
    required String selectedPath,
    String actor = 'Operator',
  }) async {
    final finding = await _requireProjectHealthRegistryFinding(findingId);
    final registryId = finding.registryId!;
    final registry = await db.getProjectRegistryEntry(registryId);
    if (registry == null) {
      throw StateError('Registry row not found: $registryId');
    }
    final folderPath = selectedPath.trim();
    if (folderPath.isEmpty) {
      throw ArgumentError('Choose a project folder.');
    }
    if (isUnsafeOperationsScanRoot(folderPath)) {
      throw ArgumentError('Choose a project folder, not a drive root.');
    }
    if (!Directory(folderPath).existsSync()) {
      throw FileSystemException('Project folder not found', folderPath);
    }
    final existingForPath = await db.getProjectRegistryByPath(folderPath);
    if (existingForPath != null && existingForPath.id != registry.id) {
      throw StateError(
        'That folder is already registered as ${existingForPath.displayName}.',
      );
    }

    final gitReport = await const LocalGitVisibilityService().inspect(
      folderPath,
    );
    final now = DateTime.now();
    final notes = [
      registry.notes?.trim(),
      'Folder replaced from Project Health by $actor at ${now.toIso8601String()}: ${registry.localPath} -> $folderPath',
    ].where((line) => line != null && line.isNotEmpty).join('\n');
    final linkedProjectId = registry.atlasProjectId?.trim();
    final updated = await db.updateProjectRegistryEntryLocalPath(
      id: registry.id,
      localPath: folderPath,
      gitRoot: gitReport.gitRoot,
      reviewState: linkedProjectId == null || linkedProjectId.isEmpty
          ? 'accepted'
          : 'linked',
      notes: notes,
    );
    if (linkedProjectId != null && linkedProjectId.isNotEmpty) {
      await db.updateProjectMeta(linkedProjectId, {
        'scopeIncluded': 'Local project root: ${updated.localPath}',
      });
    }
    await db.updateProjectEnrichmentFindingStatus(
      id: findingId,
      status: 'dismissed',
    );
    await db.refreshProjectEnrichmentRunOpenFindings(finding.runId);
    await db.logEvent(
      area: 'project_health',
      action: 'project_health_registry_folder_replaced',
      entityType: linkedProjectId == null || linkedProjectId.isEmpty
          ? 'project_registry'
          : 'project',
      entityId: linkedProjectId == null || linkedProjectId.isEmpty
          ? registry.id
          : linkedProjectId,
      inputJson: registry.localPath,
      outputJson: jsonEncode({
        'actor': actor,
        'findingId': finding.id,
        'runId': finding.runId,
        'registryId': registry.id,
        'projectId': linkedProjectId,
        'oldLocalPath': registry.localPath,
        'newLocalPath': updated.localPath,
        'gitRoot': updated.gitRoot,
        'title': finding.title,
        'resolvedAt': now.toIso8601String(),
      }),
    );
    notifyListeners();
    return updated;
  }

  Future<ProjectEnrichmentFinding> _requireProjectHealthRegistryFinding(
    String findingId,
  ) async {
    final finding = await db.getProjectEnrichmentFinding(findingId);
    if (finding == null) {
      throw StateError('Project health finding not found: $findingId');
    }
    final registryId = finding.registryId;
    if (registryId == null || registryId.trim().isEmpty) {
      throw StateError('This finding is not linked to a registry row.');
    }
    return finding;
  }

  ProjectHealthFindingSuppression _suppressionFromFinding(
    ProjectEnrichmentFinding finding, {
    required String actor,
    String? note,
  }) {
    final evidence = finding.evidence;
    return ProjectHealthFindingSuppression(
      fingerprint: _projectHealthFindingFingerprint(
        projectId: finding.projectId,
        registryId: finding.registryId,
        category: finding.category,
        title: finding.title,
        detail: finding.detail,
        evidence: evidence,
      ),
      projectId: finding.projectId,
      registryId: finding.registryId,
      category: finding.category,
      title: finding.title,
      detail: finding.detail,
      localPath: _cleanNullableString(evidence['localPath']),
      actor: actor,
      note: note,
      suppressedAt: DateTime.now(),
    );
  }

  String _fingerprintForFindingDraft(_ProjectEnrichmentFindingDraft finding) {
    return _projectHealthFindingFingerprint(
      projectId: finding.projectId,
      registryId: finding.registryId,
      category: finding.category,
      title: finding.title,
      detail: finding.detail,
      evidence: finding.evidence,
    );
  }

  String _projectHealthFindingFingerprint({
    required String? projectId,
    required String? registryId,
    required String category,
    required String title,
    String? detail,
    Map<String, Object?> evidence = const {},
  }) {
    final localPath = evidence['localPath']?.toString();
    final remoteUrl = evidence['remoteUrl']?.toString();
    final scope = [
      'project:${projectId?.trim() ?? ''}',
      'registry:${registryId?.trim() ?? ''}',
      'path:${_normalizeSuppressionPart(localPath)}',
      'remote:${_normalizeSuppressionPart(remoteUrl)}',
    ].join('|');
    return [
      _normalizeSuppressionPart(category),
      _normalizeSuppressionPart(title),
      _normalizeSuppressionPart(detail),
      scope,
    ].join('::');
  }

  String _normalizeSuppressionPart(String? value) {
    return (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  Future<String> buildProjectHealthRunExportJson(String runId) async {
    final run = await db.getProjectEnrichmentRun(runId);
    if (run == null) {
      throw StateError('Project health run not found: $runId');
    }
    final steps = await db.getProjectEnrichmentStepsForRun(runId);
    final findings = await db.getProjectEnrichmentFindingsForRun(runId);
    final proposals = await db.getProjectEnrichmentProposalsForRun(runId);
    final warningGroups = groupProjectHealthWarnings(run.warnings);
    final suppressions = await getProjectHealthFindingSuppressions();
    final coverage = run.output['coverage'];
    final suppressedFindings = coverage is Map
        ? int.tryParse('${coverage['suppressedFindings'] ?? 0}') ?? 0
        : 0;
    final findingsByStatus = <String, int>{};
    final findingsByCategory = <String, int>{};
    for (final finding in findings) {
      findingsByStatus[finding.status] =
          (findingsByStatus[finding.status] ?? 0) + 1;
      findingsByCategory[finding.category] =
          (findingsByCategory[finding.category] ?? 0) + 1;
    }
    return const JsonEncoder.withIndent('  ').convert({
      'schema': 'project_atlas_project_health_run_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'run': run.toJson(),
      'summary': {
        'steps': steps.length,
        'findings': findings.length,
        'openFindings': findingsByStatus['open'] ?? 0,
        'findingsByStatus': findingsByStatus,
        'findingsByCategory': findingsByCategory,
        'warnings': run.warnings.length,
        'warningGroups': warningGroups.length,
        'suppressedFindings': suppressedFindings,
        'activeSuppressions': suppressions.length,
        'proposals': proposals.length,
      },
      'warningGroups': warningGroups.map((group) => group.toJson()).toList(),
      'steps': steps.map((step) => step.toJson()).toList(),
      'findings': findings.map((finding) => finding.toJson()).toList(),
      'proposals': proposals.map((proposal) => proposal.toJson()).toList(),
    });
  }

  Future<String> saveProjectHealthRunExportToAppFolder(String runId) async {
    final root = await ensureOperationsScansFolder();
    final path = p.join(
      root.path,
      'project_health',
      '${_safeFileStem(runId)}_project_health.json',
    );
    await File(
      path,
    ).writeAsString(await buildProjectHealthRunExportJson(runId));
    return path;
  }

  void _setProjectEnrichmentStatus(
    String status, {
    int? current,
    int? total,
    bool resetProgress = false,
  }) {
    _projectEnrichmentStatus = status;
    if (resetProgress) {
      _projectEnrichmentProgressCurrent = null;
      _projectEnrichmentProgressTotal = null;
    } else {
      if (current != null) _projectEnrichmentProgressCurrent = current;
      if (total != null) _projectEnrichmentProgressTotal = total;
    }
    notifyListeners();
  }

  Future<String> _startEnrichmentStep(
    String runId, {
    required String worker,
    required String title,
  }) {
    _setProjectEnrichmentStatus('$title...', resetProgress: true);
    return db.startProjectEnrichmentStep(
      runId: runId,
      worker: worker,
      title: title,
      startedAt: DateTime.now(),
    );
  }

  Future<void> _finishEnrichmentStep(
    String stepId, {
    required String status,
    int considered = 0,
    int createdItems = 0,
    int updatedItems = 0,
    int skippedItems = 0,
    int failedItems = 0,
    int findings = 0,
    int proposals = 0,
    List<String> warnings = const [],
    Map<String, Object?> output = const {},
  }) {
    return db.finishProjectEnrichmentStep(
      id: stepId,
      completedAt: DateTime.now(),
      status: status,
      considered: considered,
      createdItems: createdItems,
      updatedItems: updatedItems,
      skippedItems: skippedItems,
      failedItems: failedItems,
      findings: findings,
      proposals: proposals,
      warningsJson: jsonEncode(warnings),
      outputJson: jsonEncode(output),
    );
  }

  Future<void> _addEnrichmentProposal({
    required String runId,
    String? projectId,
    String? registryId,
    required String worker,
    required String proposalType,
    required String title,
    String? detail,
    required Map<String, Object?> payload,
    int confidence = 70,
  }) async {
    final now = DateTime.now();
    final raw = [
      runId,
      worker,
      proposalType,
      projectId,
      registryId,
      title,
    ].whereType<String>().join('__');
    await db.addProjectEnrichmentProposal(
      id: 'proposal_${now.microsecondsSinceEpoch}_${raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}',
      runId: runId,
      projectId: projectId,
      registryId: registryId,
      worker: worker,
      proposalType: proposalType,
      title: title,
      detail: detail,
      payloadJson: jsonEncode(payload),
      confidence: confidence,
      createdAt: now,
    );
  }

  Future<int> _createCorrectionProposalsForFindings(
    String runId,
    List<_ProjectEnrichmentFindingDraft> findings,
  ) async {
    var created = 0;
    for (final finding in findings) {
      if (created >= _projectEnrichmentProposalCap) break;
      await _addEnrichmentProposal(
        runId: runId,
        projectId: finding.projectId,
        registryId: finding.registryId,
        worker: 'correction',
        proposalType: _proposalTypeForFinding(finding),
        title: 'Resolve: ${finding.title}',
        detail: finding.detail,
        payload: {
          'schema': 'project_atlas_enrichment_correction_v1',
          'finding': {
            'severity': finding.severity,
            'category': finding.category,
            'title': finding.title,
            'detail': finding.detail,
            'evidence': finding.evidence,
          },
          'recommendedAction': _recommendedActionForFinding(finding),
          'writeBoundary': 'atlas_only',
          'sourceReposMutated': false,
        },
        confidence: _proposalConfidenceForFinding(finding),
      );
      created++;
    }
    return created;
  }

  String _proposalTypeForFinding(_ProjectEnrichmentFindingDraft finding) {
    return switch (finding.category) {
      'registry' => 'registry_review',
      'library' => 'library_import_review',
      'media' => 'media_import_review',
      'identity' => 'identity_update',
      'people' => 'people_role_update',
      'workboard' => 'task_update',
      'governance' => 'governance_update',
      'repository' => 'repository_metadata_review',
      _ => 'enrichment_follow_up',
    };
  }

  String _recommendedActionForFinding(_ProjectEnrichmentFindingDraft finding) {
    return switch (finding.category) {
      'registry' =>
        'Link, import, merge, or ignore the local registry entry in Operations.',
      'library' =>
        'Refresh linked project documents/cards/source files or review import exclusions.',
      'media' =>
        'Attach project media or confirm that this project intentionally has none.',
      'identity' =>
        'Review project identity fields such as description, tags, type, phase, and priority.',
      'people' =>
        'Add owner or people/role assignments, or mark the project as unassigned.',
      'workboard' =>
        'Create or import project tasks, or mark the project as intentionally taskless.',
      'governance' =>
        'Add risks/issues or decision-log entries, or confirm no governance record is needed.',
      'repository' =>
        'Refresh local/GitHub repository metadata or mark the project local-only.',
      _ => 'Review and resolve this enrichment finding.',
    };
  }

  int _proposalConfidenceForFinding(_ProjectEnrichmentFindingDraft finding) {
    return switch (finding.severity) {
      'error' => 85,
      'warning' => 75,
      _ => 60,
    };
  }

  Future<_ProjectIdentityEnrichmentResult> _refreshProjectIdentityRecords(
    List<ProjectRegistryEntry> registry, {
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
    ProjectEnrichmentStatusCallback? onStatus,
  }) async {
    final linked = registry
        .where(
          (entry) =>
              entry.reviewState != 'ignored' &&
              (entry.atlasProjectId ?? '').trim().isNotEmpty,
        )
        .toList(growable: false);
    var considered = 0;
    var updated = 0;
    var unchanged = 0;
    var skipped = 0;
    final warnings = <String>[];

    for (final entry in linked) {
      considered++;
      final projectId = entry.atlasProjectId!.trim();
      onStatus?.call(
        'Updating identity for ${entry.displayName} ($considered/${linked.length}).',
        current: considered,
        total: linked.length,
      );
      final localPath = entry.localPath.trim();
      if (_looksLikeRemotePath(localPath)) {
        skipped++;
        warnings.add(
          '${entry.displayName}: identity update skipped because the registered local path is a remote URL.',
        );
        continue;
      }
      if (!_directoryExistsSafely(localPath)) {
        skipped++;
        warnings.add(
          '${entry.displayName}: identity update skipped because the registered local path does not exist: ${entry.localPath}',
        );
        continue;
      }
      final project = await db.getProjectFull(projectId);
      if (project == null) {
        skipped++;
        warnings.add('${entry.displayName}: linked Atlas project is missing.');
        continue;
      }
      try {
        final plan = await service.buildPlan(entry.localPath);
        warnings.addAll(
          plan.warnings.map((warning) => '${entry.displayName}: $warning'),
        );
        final projectActions = plan.actions
            .where((action) => action.targetType == 'project')
            .toList(growable: false);
        var changed = false;
        if (projectActions.isEmpty) {
          changed = await _applyProjectIdentityTags(
            projectId: projectId,
            entry: entry,
            planProfile: plan.profile,
          );
        } else {
          for (final action in projectActions) {
            changed =
                await _applyProjectIdentityAction(
                  projectId: projectId,
                  entry: entry,
                  action: action,
                  planProfile: plan.profile,
                ) ||
                changed;
          }
        }
        if (changed) {
          updated++;
        } else {
          unchanged++;
        }
      } catch (error) {
        skipped++;
        warnings.add('${entry.displayName}: identity update failed: $error');
      }
    }

    return _ProjectIdentityEnrichmentResult(
      considered: considered,
      updated: updated,
      unchanged: unchanged,
      skipped: skipped,
      warnings: List.unmodifiable(warnings),
    );
  }

  Future<bool> _applyProjectIdentityAction({
    required String projectId,
    required ProjectRegistryEntry entry,
    required LocalProjectRefreshAction action,
    required String planProfile,
  }) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) return false;
    final fields = <String, Object?>{};

    void maybeSet(String key, String? current) {
      final value = _payloadCleanString(action.payload, key);
      if (value == null || value == current?.trim()) return;
      fields[key] = value;
    }

    maybeSet('title', project.title);
    maybeSet('description', project.description);
    maybeSet('desiredOutcome', project.desiredOutcome);
    maybeSet('successCriteria', project.successCriteria);
    maybeSet('phase', project.phase);
    maybeSet('priority', project.priority);
    maybeSet('scopeIncluded', project.scopeIncluded);
    maybeSet('scopeExcluded', project.scopeExcluded);
    maybeSet('outcomeSummary', project.outcomeSummary);
    maybeSet('lessonsLearned', project.lessonsLearned);

    var changed = false;
    if (fields.isNotEmpty) {
      await db.updateProjectMeta(projectId, fields);
      changed = true;
    }
    changed =
        await _applyProjectIdentityTags(
          projectId: projectId,
          entry: entry,
          planProfile: planProfile,
          payload: action.payload,
        ) ||
        changed;
    return changed;
  }

  Future<bool> _applyProjectIdentityTags({
    required String projectId,
    required ProjectRegistryEntry entry,
    required String planProfile,
    Map<String, Object?> payload = const {},
  }) async {
    final manifestType = _payloadCleanString(payload, 'manifestType');
    final manifestGroup = _payloadCleanString(payload, 'manifestGroup');
    final tags = <String>[
      ..._payloadStringList(payload, 'manifestTags'),
      ?manifestType,
      ?manifestGroup,
      entry.classification,
      if (planProfile.trim().isNotEmpty && planProfile != 'unknown')
        planProfile,
    ];
    final observation = await db.getLatestProjectObservationForPath(
      entry.localPath,
    );
    final remoteUrl = observation?.remoteUrl?.trim();
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      tags.add(
        remoteUrl.toLowerCase().contains('github.com') ? 'github' : 'git',
      );
    } else {
      tags.add('local-only');
    }
    if ((observation?.dirtyCount ?? 0) > 0) {
      tags.add('needs-update');
    }
    return _assignProjectTagsByName(projectId, tags);
  }

  Future<bool> _assignProjectTagsByName(
    String projectId,
    Iterable<String> names,
  ) async {
    final existing = await db.getTagsForProject(projectId);
    final assignedNames = existing
        .map((tag) => tag.name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    var changed = false;
    final uniqueNames = <String, String>{};
    for (final rawName in names) {
      final name = _normalizeIdentityTagName(rawName);
      if (name == null) continue;
      uniqueNames.putIfAbsent(name.toLowerCase(), () => name);
    }
    for (final entry in uniqueNames.entries) {
      if (assignedNames.contains(entry.key)) continue;
      final tag = await db.findTagByName(entry.value);
      final tagId = tag?.id ?? await db.saveTag(name: entry.value);
      await db.assignTagToProject(projectId, tagId);
      assignedNames.add(entry.key);
      changed = true;
    }
    return changed;
  }

  String? _normalizeIdentityTagName(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  String? _payloadCleanString(Map<String, Object?> payload, String key) =>
      _normalizeIdentityTagName(payload[key]);

  List<String> _payloadStringList(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is Iterable) {
      return value
          .map(_normalizeIdentityTagName)
          .whereType<String>()
          .toList(growable: false);
    }
    final single = _normalizeIdentityTagName(value);
    return single == null ? const [] : [single];
  }

  Set<String>? _normalizeProjectIdScope(Iterable<String>? projectIds) {
    if (projectIds == null) return null;
    return projectIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  bool _isProjectInScope(String? projectId, Set<String>? scopedProjectIds) {
    final id = projectId?.trim();
    if (scopedProjectIds == null) return true;
    return id != null && id.isNotEmpty && scopedProjectIds.contains(id);
  }

  List<String>? _sortedProjectIdScope(Set<String>? scopedProjectIds) {
    if (scopedProjectIds == null) return null;
    return scopedProjectIds.toList(growable: false)..sort();
  }

  List<ProjectRegistryEntry> _filterProjectRegistryForScope(
    List<ProjectRegistryEntry> registry,
    Set<String>? scopedProjectIds,
  ) {
    if (scopedProjectIds == null) return registry;
    return registry
        .where(
          (entry) => _isProjectInScope(entry.atlasProjectId, scopedProjectIds),
        )
        .toList(growable: false);
  }

  Future<ProjectEnrichmentRunResult> runProjectEnrichment({
    bool refreshLinkedProjects = true,
    bool includeSourceDocuments = true,
    bool refreshSummaries = false,
    bool forceSummaries = false,
    bool includeLibraryInSummaries = true,
    bool analyzeOnly = false,
    bool refreshIdentity = true,
    bool createProposals = true,
    Iterable<String>? projectIds,
    Duration betweenProjects = Duration.zero,
  }) async {
    if (_projectEnrichmentRunning) {
      throw StateError('Project enrichment run is already running.');
    }
    final scopedProjectIds = _normalizeProjectIdScope(projectIds);
    final shouldRefreshLinkedProjects = refreshLinkedProjects && !analyzeOnly;
    final shouldRefreshIdentity = refreshIdentity && !analyzeOnly;
    final shouldCreateProposals = createProposals && !analyzeOnly;
    final startedAt = DateTime.now();
    _projectEnrichmentRunning = true;
    _projectEnrichmentStartedAt = startedAt;
    _projectEnrichmentStatus = analyzeOnly
        ? 'Starting project health analysis.'
        : 'Starting enrichment run.';
    _projectEnrichmentProgressCurrent = null;
    _projectEnrichmentProgressTotal = null;
    notifyListeners();

    final scope = {
      'schema': 'project_atlas_enrichment_run_v1',
      'mode': analyzeOnly ? 'analyze' : 'apply',
      'refreshLinkedProjects': shouldRefreshLinkedProjects,
      'includeSourceDocuments': includeSourceDocuments,
      'refreshIdentity': shouldRefreshIdentity,
      'createProposals': shouldCreateProposals,
      if (scopedProjectIds != null)
        'projectIds': _sortedProjectIdScope(scopedProjectIds),
      'projectAiSummariesEnabled': projectAiSummariesEnabled,
      if (refreshSummaries) 'requestedRefreshSummaries': true,
      if (forceSummaries) 'requestedForceSummaries': true,
      if (!includeLibraryInSummaries)
        'requestedIncludeLibraryInSummaries': false,
      'writeBoundary': 'atlas_only',
      'sourceReposMutated': false,
    };
    _setProjectEnrichmentStatus('Recording enrichment run.');
    late final String runId;
    try {
      runId = await db.startProjectEnrichmentRun(
        startedAt: startedAt,
        scopeJson: jsonEncode(scope),
      );
    } catch (_) {
      _projectEnrichmentRunning = false;
      _projectEnrichmentStatus = null;
      _projectEnrichmentStartedAt = null;
      _projectEnrichmentProgressCurrent = null;
      _projectEnrichmentProgressTotal = null;
      notifyListeners();
      rethrow;
    }

    LocalProjectBatchRefreshResult? refreshResult;
    var registryEntries = 0;
    var linkedProjects = 0;
    var refreshedProjects = 0;
    var createdItems = 0;
    var updatedItems = 0;
    var unchangedItems = 0;
    var skippedItems = 0;
    var failedProjects = 0;
    var identityConsidered = 0;
    var identityUpdated = 0;
    var identityUnchanged = 0;
    var identitySkipped = 0;
    var summaryConsidered = 0;
    var summaryRefreshed = 0;
    var summarySkipped = 0;
    var summaryFailed = 0;
    final warnings = <String>[];
    var savedFindings = const <ProjectEnrichmentFinding>[];
    var savedSteps = const <ProjectEnrichmentStep>[];
    var savedProposals = const <ProjectEnrichmentProposal>[];
    String? activeStepId;
    String? activeWorker;

    Future<String> startTrackedStep({
      required String worker,
      required String title,
    }) async {
      activeWorker = worker;
      activeStepId = await _startEnrichmentStep(
        runId,
        worker: worker,
        title: title,
      );
      return activeStepId!;
    }

    Future<void> finishTrackedStep(
      String stepId, {
      required String status,
      int considered = 0,
      int createdItems = 0,
      int updatedItems = 0,
      int skippedItems = 0,
      int failedItems = 0,
      int findings = 0,
      int proposals = 0,
      List<String> warnings = const [],
      Map<String, Object?> output = const {},
    }) async {
      await _finishEnrichmentStep(
        stepId,
        status: status,
        considered: considered,
        createdItems: createdItems,
        updatedItems: updatedItems,
        skippedItems: skippedItems,
        failedItems: failedItems,
        findings: findings,
        proposals: proposals,
        warnings: warnings,
        output: output,
      );
      if (activeStepId == stepId) {
        activeStepId = null;
        activeWorker = null;
      }
    }

    try {
      final registryStepId = await startTrackedStep(
        worker: 'registry',
        title: 'Registry agent: read local project registry',
      );
      final registryBefore = await db.getProjectRegistry();
      final scopedRegistryBefore = _filterProjectRegistryForScope(
        registryBefore,
        scopedProjectIds,
      );
      registryEntries = scopedRegistryBefore.length;
      linkedProjects = scopedRegistryBefore
          .where((entry) => (entry.atlasProjectId ?? '').isNotEmpty)
          .length;
      final distinctLinkedProjectsBefore = scopedRegistryBefore
          .map((entry) => entry.atlasProjectId?.trim() ?? '')
          .where((projectId) => projectId.isNotEmpty)
          .toSet()
          .length;
      await finishTrackedStep(
        registryStepId,
        status: 'completed',
        considered: registryEntries,
        output: {
          'registryEntries': registryEntries,
          'linkedSources': linkedProjects,
          'linkedProjects': linkedProjects,
          'distinctLinkedProjects': distinctLinkedProjectsBefore,
          'scopeProjectIds': _sortedProjectIdScope(scopedProjectIds),
          'unlinkedRegistryEntries': scopedRegistryBefore
              .where(
                (entry) =>
                    entry.reviewState != 'ignored' &&
                    (entry.atlasProjectId ?? '').isEmpty,
              )
              .length,
        },
      );

      if (shouldRefreshLinkedProjects) {
        final refreshStepId = await startTrackedStep(
          worker: 'documents_media',
          title:
              'Documents/media agent: refresh linked project library records',
        );
        refreshResult = await refreshLinkedLocalProjects(
          includeSourceDocuments: includeSourceDocuments,
          projectIds: scopedProjectIds,
          betweenProjects: betweenProjects,
          onStatus: _setProjectEnrichmentStatus,
        );
        refreshedProjects = refreshResult.refreshed;
        createdItems = refreshResult.created;
        updatedItems = refreshResult.updated;
        unchangedItems = refreshResult.unchanged;
        skippedItems = refreshResult.skipped;
        failedProjects = refreshResult.failed;
        warnings.addAll(refreshResult.warnings);
        if (refreshResult.alreadyRunning) {
          warnings.add('Linked project refresh was already running.');
        }
        await finishTrackedStep(
          refreshStepId,
          status: failedProjects > 0 ? 'completed_with_errors' : 'completed',
          considered: refreshResult.considered,
          createdItems: refreshResult.created,
          updatedItems: refreshResult.updated,
          skippedItems: refreshResult.skipped + refreshResult.unchanged,
          failedItems: refreshResult.failed,
          warnings: refreshResult.warnings,
          output: {
            'refreshed': refreshResult.refreshed,
            'includeSourceDocuments': includeSourceDocuments,
            'alreadyRunning': refreshResult.alreadyRunning,
          },
        );
        _setProjectEnrichmentStatus(
          'Linked refresh complete: $createdItems created, $updatedItems updated, $failedProjects failed.',
        );
      } else {
        final refreshStepId = await startTrackedStep(
          worker: 'documents_media',
          title: analyzeOnly
              ? 'Documents/media agent: skipped for analysis'
              : 'Documents/media agent: skipped by run scope',
        );
        await finishTrackedStep(
          refreshStepId,
          status: 'skipped',
          output: {
            'reason': analyzeOnly
                ? 'analyzeOnly=true'
                : 'refreshLinkedProjects=false',
          },
        );
      }

      final identityStepId = await startTrackedStep(
        worker: 'identity',
        title: shouldRefreshIdentity
            ? 'Identity agent: apply deterministic project metadata and tags'
            : 'Identity agent: skipped by run scope',
      );
      if (shouldRefreshIdentity) {
        final identityResult = await _refreshProjectIdentityRecords(
          scopedRegistryBefore,
          onStatus: _setProjectEnrichmentStatus,
        );
        identityConsidered = identityResult.considered;
        identityUpdated = identityResult.updated;
        identityUnchanged = identityResult.unchanged;
        identitySkipped = identityResult.skipped;
        updatedItems += identityUpdated;
        unchangedItems += identityUnchanged;
        skippedItems += identitySkipped;
        warnings.addAll(identityResult.warnings);
        await finishTrackedStep(
          identityStepId,
          status: identityResult.skipped > 0
              ? 'completed_with_warnings'
              : 'completed',
          considered: identityResult.considered,
          updatedItems: identityResult.updated,
          skippedItems: identityResult.unchanged + identityResult.skipped,
          failedItems: identityResult.skipped,
          warnings: identityResult.warnings,
          output: {
            'autoApplied': true,
            'updatedProjects': identityResult.updated,
            'unchangedProjects': identityResult.unchanged,
            'skippedProjects': identityResult.skipped,
            'sources': [
              'linked project metadata manifest',
              'CURRENT_STATE.md',
              'README.md',
              'local git observation',
            ],
          },
        );
        _setProjectEnrichmentStatus(
          'Identity update complete: ${identityResult.updated} updated, ${identityResult.unchanged} unchanged.',
        );
      } else {
        await finishTrackedStep(
          identityStepId,
          status: 'skipped',
          output: {
            'reason': analyzeOnly
                ? 'analyzeOnly=true'
                : 'refreshIdentity=false',
            'autoApplied': false,
          },
        );
      }

      final verificationStepId = await startTrackedStep(
        worker: 'verification',
        title: 'Verification agent: audit project completeness',
      );
      final registry = await db.getProjectRegistry();
      final scopedRegistry = _filterProjectRegistryForScope(
        registry,
        scopedProjectIds,
      );
      registryEntries = scopedRegistry.length;
      linkedProjects = scopedRegistry
          .where((entry) => (entry.atlasProjectId ?? '').isNotEmpty)
          .length;
      final distinctLinkedProjects = scopedRegistry
          .map((entry) => entry.atlasProjectId?.trim() ?? '')
          .where((projectId) => projectId.isNotEmpty)
          .toSet()
          .length;
      final allProjects = await db.getVisibleProjects();
      final projects = scopedProjectIds == null
          ? allProjects
          : allProjects
                .where((project) => scopedProjectIds.contains(project.id))
                .toList(growable: false);
      final audit = await _buildProjectEnrichmentAudit(
        registry: scopedRegistry,
        projects: projects,
      );
      final suppressions = await getProjectHealthFindingSuppressions();
      final suppressedFingerprints = suppressions
          .map((item) => item.fingerprint)
          .toSet();
      final activeFindings = audit.findings
          .where(
            (finding) => !suppressedFingerprints.contains(
              _fingerprintForFindingDraft(finding),
            ),
          )
          .toList(growable: false);
      final suppressedFindingCount =
          audit.findings.length - activeFindings.length;
      final verificationOutput = {
        ...audit.coverage,
        'suppressedFindings': suppressedFindingCount,
      };
      await finishTrackedStep(
        verificationStepId,
        status: activeFindings.isEmpty
            ? 'completed'
            : 'completed_with_findings',
        considered: projects.length,
        findings: activeFindings.length,
        skippedItems: suppressedFindingCount,
        output: verificationOutput,
      );

      _setProjectEnrichmentStatus(
        'Saving ${activeFindings.length} enrichment findings.',
      );
      for (var i = 0; i < activeFindings.length; i++) {
        final finding = activeFindings[i];
        await db.addProjectEnrichmentFinding(
          id: 'finding_${runId}_$i',
          runId: runId,
          projectId: finding.projectId,
          registryId: finding.registryId,
          severity: finding.severity,
          category: finding.category,
          title: finding.title,
          detail: finding.detail,
          evidenceJson: jsonEncode(finding.evidence),
          createdAt: DateTime.now(),
        );
      }
      savedFindings = await db.getProjectEnrichmentFindingsForRun(runId);
      final correctionStepId = await startTrackedStep(
        worker: 'correction',
        title: shouldCreateProposals
            ? 'Correction agent: draft reviewable follow-up proposals'
            : 'Correction agent: skipped by run scope',
      );
      if (shouldCreateProposals) {
        final proposalCount = await _createCorrectionProposalsForFindings(
          runId,
          activeFindings,
        );
        savedProposals = await db.getProjectEnrichmentProposalsForRun(runId);
        await finishTrackedStep(
          correctionStepId,
          status: proposalCount == 0 ? 'completed' : 'completed_with_proposals',
          considered: activeFindings.length,
          proposals: proposalCount,
          output: {
            'policy': 'proposal_only',
            'autoApplied': false,
            'proposalCap': _projectEnrichmentProposalCap,
          },
        );
      } else {
        await finishTrackedStep(
          correctionStepId,
          status: 'skipped',
          considered: activeFindings.length,
          output: {
            'reason': analyzeOnly
                ? 'analyzeOnly=true'
                : 'createProposals=false',
            'policy': 'analysis_only',
            'autoApplied': false,
          },
        );
      }
      savedSteps = await db.getProjectEnrichmentStepsForRun(runId);
      final openFindings = savedFindings
          .where((finding) => finding.status == 'open')
          .length;
      final status = analyzeOnly
          ? openFindings > 0 || warnings.isNotEmpty
                ? 'analyzed_with_findings'
                : 'analyzed'
          : failedProjects > 0
          ? 'completed_with_errors'
          : openFindings > 0 || warnings.isNotEmpty
          ? 'completed_with_findings'
          : 'completed';
      final output = {
        'mode': analyzeOnly ? 'analyze' : 'apply',
        'linkedSources': linkedProjects,
        'distinctLinkedProjects': distinctLinkedProjects,
        'coverage': verificationOutput,
        'refresh': refreshResult == null
            ? null
            : {
                'considered': refreshResult.considered,
                'refreshed': refreshResult.refreshed,
                'created': refreshResult.created,
                'updated': refreshResult.updated,
                'unchanged': refreshResult.unchanged,
                'skipped': refreshResult.skipped,
                'failed': refreshResult.failed,
                'alreadyRunning': refreshResult.alreadyRunning,
              },
        'identity': {
          'considered': identityConsidered,
          'updated': identityUpdated,
          'unchanged': identityUnchanged,
          'skipped': identitySkipped,
        },
        'workers': savedSteps.map((step) => step.toJson()).toList(),
        'proposals': {
          'count': savedProposals.length,
          'policy': shouldCreateProposals ? 'proposal_only' : 'analysis_only',
          'autoApplied': false,
        },
      };
      _setProjectEnrichmentStatus('Finalizing enrichment run.');
      await db.finishProjectEnrichmentRun(
        id: runId,
        completedAt: DateTime.now(),
        status: status,
        registryEntries: registryEntries,
        linkedProjects: linkedProjects,
        refreshedProjects: refreshedProjects,
        createdItems: createdItems,
        updatedItems: updatedItems,
        unchangedItems: unchangedItems,
        skippedItems: skippedItems,
        failedProjects: failedProjects,
        // Identity updates are counted in updated/unchanged/skipped item totals.
        summaryConsidered: summaryConsidered,
        summaryRefreshed: summaryRefreshed,
        summarySkipped: summarySkipped,
        summaryFailed: summaryFailed,
        findings: savedFindings.length,
        openFindings: openFindings,
        warningsJson: jsonEncode(warnings),
        outputJson: jsonEncode(output),
      );
      await db.logEvent(
        area: 'operations',
        action: 'project_enrichment_completed',
        entityType: 'project_enrichment_run',
        entityId: runId,
        outputJson: jsonEncode({
          'status': status,
          'registryEntries': registryEntries,
          'linkedSources': linkedProjects,
          'linkedProjects': linkedProjects,
          'distinctLinkedProjects': distinctLinkedProjects,
          'findings': savedFindings.length,
          'openFindings': openFindings,
        }),
      );
      final run = await db.getProjectEnrichmentRun(runId);
      if (run == null) {
        throw StateError('Project enrichment run was not saved: $runId');
      }
      return ProjectEnrichmentRunResult(
        run: run,
        findings: savedFindings,
        steps: savedSteps,
        proposals: savedProposals,
      );
    } catch (error, stackTrace) {
      _setProjectEnrichmentStatus('Enrichment failed: $error');
      warnings.add(error.toString());
      final failedAt = DateTime.now();
      final failedWorker = activeWorker;
      final activeFailure = activeStepId != null || activeWorker != null;
      final failedRunOutput = <String, Object?>{'error': error.toString()};
      if (failedWorker != null) {
        failedRunOutput['worker'] = failedWorker;
      }
      if (activeFailure) {
        try {
          await db.failRunningProjectEnrichmentStepsForRun(
            runId: runId,
            completedAt: failedAt,
            warningsJson: jsonEncode([error.toString()]),
            outputJson: jsonEncode(failedRunOutput),
          );
          await db.addProjectEnrichmentFinding(
            id: 'finding_${runId}_error_${failedAt.microsecondsSinceEpoch}',
            runId: runId,
            severity: 'error',
            category: failedWorker ?? 'enrichment',
            title: 'Enrichment worker failed before completing.',
            detail: error.toString(),
            evidenceJson: jsonEncode(failedRunOutput),
            createdAt: failedAt,
          );
          savedFindings = await db.getProjectEnrichmentFindingsForRun(runId);
          activeStepId = null;
          activeWorker = null;
        } catch (cleanupError, cleanupStackTrace) {
          await db.logError(
            area: 'operations',
            action: 'project_enrichment_failure_cleanup_failed',
            error: cleanupError,
            stackTrace: cleanupStackTrace,
            entityType: 'project_enrichment_run',
            entityId: runId,
          );
        }
      }
      await db.finishProjectEnrichmentRun(
        id: runId,
        completedAt: failedAt,
        status: 'failed',
        registryEntries: registryEntries,
        linkedProjects: linkedProjects,
        refreshedProjects: refreshedProjects,
        createdItems: createdItems,
        updatedItems: updatedItems,
        unchangedItems: unchangedItems,
        skippedItems: skippedItems,
        failedProjects: failedProjects,
        summaryConsidered: summaryConsidered,
        summaryRefreshed: summaryRefreshed,
        summarySkipped: summarySkipped,
        summaryFailed: summaryFailed,
        findings: savedFindings.length,
        openFindings: savedFindings
            .where((finding) => finding.status == 'open')
            .length,
        warningsJson: jsonEncode(warnings),
        outputJson: jsonEncode(failedRunOutput),
      );
      await db.logError(
        area: 'operations',
        action: 'project_enrichment_failed',
        error: error,
        stackTrace: stackTrace,
        entityType: 'project_enrichment_run',
        entityId: runId,
      );
      rethrow;
    } finally {
      _projectEnrichmentRunning = false;
      _projectEnrichmentStatus = null;
      _projectEnrichmentStartedAt = null;
      _projectEnrichmentProgressCurrent = null;
      _projectEnrichmentProgressTotal = null;
      notifyListeners();
    }
  }

  Future<_ProjectEnrichmentAudit> _buildProjectEnrichmentAudit({
    required List<ProjectRegistryEntry> registry,
    required List<Project> projects,
  }) async {
    final findings = <_ProjectEnrichmentFindingDraft>[];
    final registryByProjectId = <String, ProjectRegistryEntry>{};
    final registryEntriesByProjectId = <String, List<ProjectRegistryEntry>>{};
    for (final entry in registry) {
      final linkedProjectId = entry.atlasProjectId?.trim();
      if (linkedProjectId == null || linkedProjectId.isEmpty) continue;
      registryEntriesByProjectId
          .putIfAbsent(linkedProjectId, () => <ProjectRegistryEntry>[])
          .add(entry);
      registryByProjectId.putIfAbsent(linkedProjectId, () => entry);
    }
    final projectsById = <String, Project>{
      for (final project in projects) project.id: project,
    };
    final projectIds = projects.map((project) => project.id).toSet();
    var documents = 0;
    var media = 0;
    var sourceFiles = 0;
    var cards = 0;
    var projectsWithDocs = 0;
    var projectsWithMedia = 0;
    var projectsWithSourceFiles = 0;
    var projectsWithCards = 0;
    var projectsWithPeople = 0;
    var projectsWithTags = 0;
    var projectsWithTasks = 0;
    var projectsWithRisks = 0;
    var projectsWithDecisions = 0;
    var projectsWithGithubCache = 0;
    var activePrimarySources = 0;
    var unresolvedSources = 0;
    var legacyRemoteSources = 0;
    var duplicateSourceIdentities = 0;

    void addFinding({
      Project? project,
      ProjectRegistryEntry? registryEntry,
      required String severity,
      required String category,
      required String title,
      String? detail,
      Map<String, Object?> evidence = const {},
    }) {
      findings.add(
        _ProjectEnrichmentFindingDraft(
          projectId: project?.id,
          registryId: registryEntry?.id,
          severity: severity,
          category: category,
          title: title,
          detail: detail,
          evidence: {
            if (project != null) 'projectTitle': project.title,
            if (registryEntry != null) ...{
              'registryDisplayName': registryEntry.displayName,
              'localPath': registryEntry.localPath,
              'reviewState': registryEntry.reviewState,
            },
            ...evidence,
          },
        ),
      );
    }

    for (final entry in registry) {
      final linkedProjectId = entry.atlasProjectId?.trim();
      if (entry.reviewState == 'ignored') continue;
      final localPath = entry.localPath.trim();
      final pathIsRemote = _looksLikeRemotePath(localPath);
      final pathExists = !pathIsRemote && _directoryExistsSafely(localPath);
      final pathHasProblem = pathIsRemote || !pathExists;
      if (pathIsRemote) {
        addFinding(
          registryEntry: entry,
          severity: 'info',
          category: 'registry',
          title: 'Registered local path is a remote URL, not a local folder.',
          detail: entry.localPath,
          evidence: {'pathKind': 'remote_url'},
        );
      } else if (!pathExists) {
        addFinding(
          registryEntry: entry,
          severity: 'error',
          category: 'registry',
          title: 'Registered local path does not exist.',
          detail: entry.localPath,
        );
      }
      if (linkedProjectId == null || linkedProjectId.isEmpty) {
        if (!pathHasProblem && entry.reviewState == 'needs_review') {
          addFinding(
            registryEntry: entry,
            severity: 'warning',
            category: 'registry',
            title: 'Registered local project still needs review.',
            detail:
                'Review it, link it to an existing project, import it as a new project, or mark it ignored.',
          );
        } else if (!pathHasProblem) {
          addFinding(
            registryEntry: entry,
            severity: 'warning',
            category: 'registry',
            title:
                'Registered local project is not linked to an Atlas project.',
            detail:
                'Link it to an existing project, import it as a new project, or mark it ignored.',
          );
        }
      } else if (!projectIds.contains(linkedProjectId)) {
        addFinding(
          registryEntry: entry,
          severity: 'error',
          category: 'registry',
          title: 'Registry row points to a missing Atlas project.',
          detail: linkedProjectId,
        );
      } else if (!pathHasProblem && entry.reviewState == 'needs_review') {
        addFinding(
          registryEntry: entry,
          severity: 'warning',
          category: 'registry',
          title: 'Registered local project still needs review.',
          detail:
              'Review this linked registry row or mark it accepted/ignored.',
        );
      }
    }

    for (final duplicateGroup in registryEntriesByProjectId.entries.where(
      (entry) => entry.value.length > 1,
    )) {
      final linkedProject = projectsById[duplicateGroup.key];
      final entries = duplicateGroup.value;
      addFinding(
        project: linkedProject,
        registryEntry: entries.first,
        severity: 'warning',
        category: 'registry',
        title:
            'Multiple local registry entries are linked to the same Atlas project.',
        detail:
            'Review these registry rows and merge, unlink, or mark duplicates ignored.',
        evidence: {
          'atlasProjectId': duplicateGroup.key,
          'linkedRegistryIds': entries.map((entry) => entry.id).toList(),
          'linkedDisplayNames': entries
              .map((entry) => entry.displayName)
              .toList(),
          'linkedLocalPaths': entries.map((entry) => entry.localPath).toList(),
        },
      );
    }

    final duplicateIdentityGroups = <String, List<ProjectRegistryEntry>>{};
    for (final entry in registry) {
      if (entry.reviewState == 'ignored') continue;
      final identity = _sourceTopologyIdentity(entry);
      if (identity == null) continue;
      duplicateIdentityGroups
          .putIfAbsent(identity, () => <ProjectRegistryEntry>[])
          .add(entry);
    }
    for (final group in duplicateIdentityGroups.entries.where(
      (entry) => entry.value.length > 1,
    )) {
      duplicateSourceIdentities++;
      final entries = group.value;
      addFinding(
        project: entries.first.atlasProjectId == null
            ? null
            : projectsById[entries.first.atlasProjectId],
        registryEntry: entries.first,
        severity: 'warning',
        category: 'source_topology',
        title: 'Multiple source rows share the same normalized identity.',
        detail:
            'Review these source rows before applying identity reconciliation.',
        evidence: {
          'normalizedIdentity': group.key,
          'registryIds': entries.map((entry) => entry.id).toList(),
          'atlasProjectIds': entries
              .map((entry) => entry.atlasProjectId)
              .whereType<String>()
              .toSet()
              .toList(),
          'localPaths': entries.map((entry) => entry.localPath).toList(),
        },
      );
    }

    for (final project in projects) {
      final projectRegistryEntries =
          registryEntriesByProjectId[project.id] ??
          const <ProjectRegistryEntry>[];
      final registryEntry = projectRegistryEntries.firstOrNull;
      final projectPrimarySources = projectRegistryEntries
          .where(_isActivePrimarySource)
          .toList(growable: false);
      final projectUnresolvedSources = projectRegistryEntries
          .where(_isUnresolvedSource)
          .toList(growable: false);
      activePrimarySources += projectPrimarySources.length;
      unresolvedSources += projectUnresolvedSources.length;
      legacyRemoteSources += projectRegistryEntries
          .where((entry) => entry.sourceType == 'remote_url_legacy')
          .length;
      final docs = await db.getDocumentsForProject(project.id);
      final mediaItems = await getProjectMedia(project.id);
      final tags = await getTagsForProject(project.id);
      final people = await getProjectPeople(project.id);
      final items = await getWorkItemsForProject(project.id);
      final risks = await getProjectRisks(project.id);
      final decisions = await getProjectDecisions(project.id);
      final observation = registryEntry == null
          ? null
          : await db.getLatestProjectObservationForPath(
              registryEntry.localPath,
            );
      final github = await getLatestProjectGitRemoteStatus(project.id);
      final refreshItems = registryEntry == null
          ? const <LocalProjectRefreshItem>[]
          : await db.getLocalProjectRefreshItemsForRegistry(registryEntry.id);
      final sourceFileCount = refreshItems
          .where((item) => item.sourceKind == 'source_file')
          .length;
      final cardCount = refreshItems
          .where((item) => item.sourceKind == 'atlas_card')
          .length;

      documents += docs.length;
      media += mediaItems.length;
      sourceFiles += sourceFileCount;
      cards += cardCount;
      if (docs.isNotEmpty) projectsWithDocs++;
      if (mediaItems.isNotEmpty) projectsWithMedia++;
      if (sourceFileCount > 0) projectsWithSourceFiles++;
      if (cardCount > 0) projectsWithCards++;
      if (people.isNotEmpty) projectsWithPeople++;
      if (tags.isNotEmpty) projectsWithTags++;
      if (items.isNotEmpty) projectsWithTasks++;
      if (risks.isNotEmpty) projectsWithRisks++;
      if (decisions.isNotEmpty) projectsWithDecisions++;
      if (github != null) projectsWithGithubCache++;

      if (registryEntry == null) {
        addFinding(
          project: project,
          severity: 'warning',
          category: 'registry',
          title: 'Atlas project is not linked to a local registry entry.',
          detail:
              'Run an Operations scan and link or upload the matching local project.',
        );
      } else if (projectPrimarySources.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'error',
          category: 'source_topology',
          title: 'Project has no active primary working source.',
          detail:
              'Mark one valid local source as primary_working before identity reconciliation.',
          evidence: {
            'linkedRegistryIds': projectRegistryEntries
                .map((entry) => entry.id)
                .toList(),
            'sourceRoles': projectRegistryEntries
                .map((entry) => entry.sourceRole)
                .toSet()
                .toList(),
            'lifecycleStates': projectRegistryEntries
                .map((entry) => entry.lifecycleState)
                .toSet()
                .toList(),
          },
        );
      } else if (projectPrimarySources.length > 1) {
        addFinding(
          project: project,
          registryEntry: projectPrimarySources.first,
          severity: 'error',
          category: 'source_topology',
          title: 'Project has multiple active primary working sources.',
          detail:
              'Resolve source authority before applying identity reconciliation.',
          evidence: {
            'primaryRegistryIds': projectPrimarySources
                .map((entry) => entry.id)
                .toList(),
            'primaryLocalPaths': projectPrimarySources
                .map((entry) => entry.localPath)
                .toList(),
          },
        );
      }
      for (final source in projectUnresolvedSources) {
        addFinding(
          project: project,
          registryEntry: source,
          severity: source.authorityLevel == 'blocked_unresolved'
              ? 'error'
              : 'warning',
          category: 'source_topology',
          title: 'Source topology is unresolved for this project.',
          detail:
              'Review the source role, lifecycle state, and authority before reconciliation.',
          evidence: {
            'sourceRole': source.sourceRole,
            'sourceType': source.sourceType,
            'lifecycleState': source.lifecycleState,
            'authorityLevel': source.authorityLevel,
            'normalizedIdentity': source.normalizedIdentity,
          },
        );
      }
      if (_isBlank(project.description)) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'identity',
          title: 'Project description is blank.',
        );
      }
      if (_isBlank(project.owner)) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'people',
          title: 'Project owner is blank.',
        );
      }
      if (tags.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'identity',
          title: 'Project has no tags.',
        );
      }
      if (docs.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'library',
          title: 'Project has no imported documents.',
        );
      }
      if (_looksLikeSoftwareProject(observation, registryEntry) &&
          sourceFileCount == 0) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'library',
          title: 'Software project has no individual source files imported.',
          detail:
              'Run linked project refresh with source documents enabled, or review source import caps/exclusions.',
        );
      }
      if (_looksLikeCardProject(project, registryEntry) && cardCount == 0) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'library',
          title: 'Card-style project has no individual cards imported.',
          detail:
              'Run linked project refresh and review card source parser coverage.',
        );
      }
      final remote = observation?.remoteUrl;
      final githubIdentity = GithubRemoteMetadataService.parseGithubRemoteUrl(
        remote,
      );
      if (githubIdentity != null && github == null) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'repository',
          title: 'GitHub remote is detected but metadata is not cached.',
          detail:
              'Use Refresh GitHub so Atlas can show public/private/default-branch state.',
          evidence: {'remoteUrl': remote},
        );
      } else if (github?.hasError == true) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'repository',
          title: 'Latest GitHub metadata refresh has a warning.',
          detail: github?.error,
          evidence: {'remoteUrl': github?.remoteUrl},
        );
      }
      final dirtyCount = observation?.dirtyCount ?? 0;
      if (dirtyCount > 0) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'repository',
          title: 'Latest local git observation has uncommitted changes.',
          evidence: {'dirtyCount': dirtyCount},
        );
      }
    }

    final coverage = {
      'projects': projects.length,
      'registryEntries': registry.length,
      'linkedSources': registryEntriesByProjectId.values.fold<int>(
        0,
        (total, entries) => total + entries.length,
      ),
      'linkedProjects': registryByProjectId.length,
      'distinctLinkedProjects': registryByProjectId.length,
      'unlinkedRegistryEntries': registry
          .where(
            (entry) =>
                entry.reviewState != 'ignored' &&
                (entry.atlasProjectId ?? '').isEmpty,
          )
          .length,
      'atlasProjectsWithoutRegistry': projects
          .where((project) => !registryByProjectId.containsKey(project.id))
          .length,
      'documents': documents,
      'media': media,
      'sourceFiles': sourceFiles,
      'cards': cards,
      'projectsWithDocs': projectsWithDocs,
      'projectsWithMedia': projectsWithMedia,
      'projectsWithSourceFiles': projectsWithSourceFiles,
      'projectsWithCards': projectsWithCards,
      'projectsWithPeople': projectsWithPeople,
      'projectsWithTags': projectsWithTags,
      'projectsWithTasks': projectsWithTasks,
      'projectsWithRisks': projectsWithRisks,
      'projectsWithDecisions': projectsWithDecisions,
      'projectsWithGithubCache': projectsWithGithubCache,
      'sourceTopology': {
        'activePrimarySources': activePrimarySources,
        'unresolvedSources': unresolvedSources,
        'legacyRemoteSources': legacyRemoteSources,
        'duplicateNormalizedIdentities': duplicateSourceIdentities,
      },
    };
    return _ProjectEnrichmentAudit(findings: findings, coverage: coverage);
  }

  bool _isActivePrimarySource(ProjectRegistryEntry entry) {
    return entry.reviewState != 'ignored' &&
        entry.sourceRole == 'primary_working' &&
        entry.lifecycleState == 'active';
  }

  bool _isUnresolvedSource(ProjectRegistryEntry entry) {
    return entry.reviewState != 'ignored' &&
        (entry.sourceRole == 'unresolved_candidate' ||
            entry.lifecycleState == 'legacy_remote' ||
            entry.authorityLevel == 'blocked_unresolved');
  }

  String? _sourceTopologyIdentity(ProjectRegistryEntry entry) {
    final normalized = entry.normalizedIdentity?.trim();
    if (normalized != null && normalized.isNotEmpty) return normalized;
    final gitRoot = entry.gitRoot?.trim();
    if (gitRoot != null && gitRoot.isNotEmpty) return _pathKey(gitRoot);
    final localPath = entry.localPath.trim();
    if (localPath.isEmpty) return null;
    return _pathKey(localPath);
  }

  bool _looksLikeSoftwareProject(
    ProjectObservation? observation,
    ProjectRegistryEntry? registry,
  ) {
    final markers = observation == null
        ? const <String>[]
        : _decodeStringList(observation.markerFilesJson);
    const softwareMarkers = {
      'package.json',
      'pubspec.yaml',
      'pyproject.toml',
      'Cargo.toml',
      'go.mod',
      'pom.xml',
      'build.gradle',
    };
    if (markers.any(softwareMarkers.contains)) return true;
    final path = [
      registry?.localPath,
      observation?.observedPath,
    ].whereType<String>().join(' ').toLowerCase();
    return path.contains(r'\src') ||
        path.contains(r'\lib') ||
        path.contains(r'\app') ||
        path.contains('flutter') ||
        path.contains('python') ||
        path.contains('node');
  }

  bool _looksLikeCardProject(Project project, ProjectRegistryEntry? registry) {
    final haystack = [
      project.title,
      project.description,
      registry?.displayName,
      registry?.localPath,
    ].whereType<String>().join(' ').toLowerCase();
    return haystack.contains('goalcard') || haystack.contains('card library');
  }

  bool _isBlank(String? value) => value == null || value.trim().isEmpty;

  bool _looksLikeRemotePath(String value) {
    final lower = value.trim().toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('ssh://') ||
        lower.startsWith('git@');
  }

  bool _directoryExistsSafely(String path) {
    if (path.trim().isEmpty) return false;
    try {
      return Directory(path).existsSync();
    } on FileSystemException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  Stream<List<ProjectScanRun>> watchProjectScanRuns({int limit = 50}) =>
      db.watchProjectScanRuns(limit: limit);

  Future<List<ProjectScanRun>> getProjectScanRuns({int limit = 50}) =>
      db.getProjectScanRuns(limit: limit);

  Stream<List<ProjectObservation>> watchRecentProjectObservations({
    int limit = 500,
  }) => db.watchRecentProjectObservations(limit: limit);

  Future<List<ProjectObservation>> getRecentProjectObservations({
    int limit = 500,
  }) => db.getRecentProjectObservations(limit: limit);

  Stream<List<ProjectRegistryEntry>> watchProjectRegistry() =>
      db.watchProjectRegistry();

  Future<List<ProjectRegistryEntry>> getProjectRegistry() =>
      db.getProjectRegistry();

  Future<ProjectRegistryEntry?> getProjectRegistryForAtlasProject(
    String projectId,
  ) => db.getProjectRegistryByAtlasProjectId(projectId);

  Future<ProjectRegistryEntry> markProjectRegistryEntryPrimarySource(
    String registryId, {
    String actor = 'Operator',
  }) async {
    final before = await db.getProjectRegistryEntry(registryId);
    final updated = await db.markProjectRegistryEntryPrimarySource(
      registryId: registryId,
    );
    await db.logEvent(
      area: 'operations',
      action: 'project_registry_primary_source_marked',
      entityType: 'project_registry',
      entityId: registryId,
      inputJson: jsonEncode(before?.toJson()),
      outputJson: jsonEncode({
        'actor': actor,
        'registryId': registryId,
        'atlasProjectId': updated.atlasProjectId,
        'sourceRole': updated.sourceRole,
        'sourceType': updated.sourceType,
        'lifecycleState': updated.lifecycleState,
        'authorityLevel': updated.authorityLevel,
        'precedence': updated.precedence,
      }),
    );
    return updated;
  }

  Future<ProjectRegistryEntry> ignoreProjectRegistrySource(
    String registryId, {
    String actor = 'Operator',
    String? note,
  }) async {
    final before = await db.getProjectRegistryEntry(registryId);
    if (before == null) {
      throw StateError('Project registry row not found: $registryId');
    }
    final notes = [
      before.notes?.trim(),
      note?.trim(),
      'Source ignored by $actor at ${DateTime.now().toIso8601String()}.',
    ].where((line) => line != null && line.isNotEmpty).join('\n');
    await db.updateProjectRegistryEntryReviewState(
      id: registryId,
      reviewState: 'ignored',
      notes: notes,
      clearAtlasProjectId: true,
    );
    final updated = await db.getProjectRegistryEntry(registryId);
    if (updated == null) {
      throw StateError(
        'Project registry row not found after update: $registryId',
      );
    }
    await db.logEvent(
      area: 'operations',
      action: 'project_registry_source_ignored',
      entityType: 'project_registry',
      entityId: registryId,
      inputJson: jsonEncode(before.toJson()),
      outputJson: jsonEncode({
        'actor': actor,
        'registryId': registryId,
        'previousAtlasProjectId': before.atlasProjectId,
        'reviewState': updated.reviewState,
        'sourceRole': updated.sourceRole,
        'lifecycleState': updated.lifecycleState,
        'authorityLevel': updated.authorityLevel,
      }),
    );
    return updated;
  }

  Future<ProjectRegistryEntry> replaceProjectRegistrySourceFolder({
    required String registryId,
    required String selectedPath,
    String actor = 'Operator',
  }) async {
    final registry = await db.getProjectRegistryEntry(registryId);
    if (registry == null) {
      throw StateError('Project registry row not found: $registryId');
    }
    final folderPath = selectedPath.trim();
    if (folderPath.isEmpty) {
      throw ArgumentError('Choose a project folder.');
    }
    if (isUnsafeOperationsScanRoot(folderPath)) {
      throw ArgumentError('Choose a project folder, not a drive root.');
    }
    if (!Directory(folderPath).existsSync()) {
      throw FileSystemException('Project folder not found', folderPath);
    }
    final existingForPath = await db.getProjectRegistryByPath(folderPath);
    if (existingForPath != null && existingForPath.id != registry.id) {
      throw StateError(
        'That folder is already registered as ${existingForPath.displayName}.',
      );
    }

    final gitReport = await const LocalGitVisibilityService().inspect(
      folderPath,
    );
    final linkedProjectId = registry.atlasProjectId?.trim();
    final now = DateTime.now();
    final notes = [
      registry.notes?.trim(),
      'Folder replaced by $actor at ${now.toIso8601String()}: ${registry.localPath} -> $folderPath',
    ].where((line) => line != null && line.isNotEmpty).join('\n');
    var updated = await db.updateProjectRegistryEntryLocalPath(
      id: registry.id,
      localPath: folderPath,
      gitRoot: gitReport.gitRoot,
      reviewState: linkedProjectId == null || linkedProjectId.isEmpty
          ? 'accepted'
          : 'linked',
      notes: notes,
    );
    if (linkedProjectId != null && linkedProjectId.isNotEmpty) {
      updated = await db.markProjectRegistryEntryPrimarySource(
        registryId: registry.id,
      );
      await db.updateProjectMeta(linkedProjectId, {
        'scopeIncluded': 'Local project root: ${updated.localPath}',
      });
    }
    await db.logEvent(
      area: 'operations',
      action: 'project_registry_source_folder_replaced',
      entityType: linkedProjectId == null || linkedProjectId.isEmpty
          ? 'project_registry'
          : 'project',
      entityId: linkedProjectId == null || linkedProjectId.isEmpty
          ? registry.id
          : linkedProjectId,
      inputJson: registry.localPath,
      outputJson: jsonEncode({
        'actor': actor,
        'registryId': registry.id,
        'previousPath': registry.localPath,
        'localPath': updated.localPath,
        'gitRoot': updated.gitRoot,
        'sourceRole': updated.sourceRole,
        'sourceType': updated.sourceType,
        'lifecycleState': updated.lifecycleState,
        'authorityLevel': updated.authorityLevel,
      }),
    );
    notifyListeners();
    return updated;
  }

  Future<ProjectLocalRepoSummary?> getProjectLocalRepoSummary(
    String projectId,
  ) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    final observation = registry == null
        ? null
        : await db.getLatestProjectObservationForPath(registry.localPath);
    final refreshItems = registry == null
        ? const <LocalProjectRefreshItem>[]
        : await db.getLocalProjectRefreshItemsForRegistry(registry.id);
    final documents = await db.getDocumentsForProject(projectId);
    final media = await db.getProjectMedia(projectId);
    return ProjectLocalRepoSummary(
      registry: registry,
      observation: observation,
      refreshItems: refreshItems,
      documents: documents,
      media: media,
    );
  }

  Future<ProjectObservation?> getLatestLocalProjectObservation(
    String projectId,
  ) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    if (registry == null) return null;
    return db.getLatestProjectObservationForPath(registry.localPath);
  }

  Future<LocalGitVisibilityReport> inspectLocalGitVisibility(
    String projectId, {
    LocalGitVisibilityService service = const LocalGitVisibilityService(),
  }) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    if (registry == null) {
      throw StateError('Project is not linked to a local registry entry.');
    }
    return service.inspect(registry.localPath);
  }

  Future<ProjectGitRemoteStatus?> getLatestProjectGitRemoteStatus(
    String projectId,
  ) => db.getLatestProjectGitRemoteStatus(projectId);

  Future<List<ProjectGitRemoteStatus>> getProjectGitRemoteStatuses(
    String projectId,
  ) => db.getProjectGitRemoteStatuses(projectId);

  Future<ProjectGitRemoteStatus> saveManualProjectGithubRemoteMetadata(
    String projectId,
    String remoteUrl,
  ) async {
    final identity = GithubRemoteMetadataService.parseGithubRemoteUrl(
      remoteUrl,
    );
    if (identity == null) {
      throw StateError('Enter a valid GitHub repository URL.');
    }
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    final checkedAt = DateTime.now();
    final status = await db.upsertProjectGitRemoteStatus(
      projectId: projectId,
      registryId: registry?.id,
      provider: identity.provider,
      owner: identity.owner,
      repo: identity.repo,
      remoteUrl: identity.remoteUrl,
      htmlUrl: identity.htmlUrl,
      checkedAt: checkedAt,
      rawJson: jsonEncode({
        'source': 'manual',
        'savedAt': checkedAt.toIso8601String(),
      }),
    );
    await db.logEvent(
      area: 'github',
      action: 'project_github_metadata_saved_manually',
      entityType: 'project',
      entityId: projectId,
      inputJson: remoteUrl,
      outputJson: jsonEncode(status.toJson()),
    );
    notifyListeners();
    return status;
  }

  Future<void> clearProjectGithubRemoteMetadata(String projectId) async {
    await db.deleteProjectGitRemoteStatuses(projectId);
    await db.logEvent(
      area: 'github',
      action: 'project_github_metadata_cleared',
      entityType: 'project',
      entityId: projectId,
    );
    notifyListeners();
  }

  Future<String> enqueueLlmTask({
    required String projectId,
    String? workItemId,
    required String title,
    required String objective,
    Map<String, Object?> context = const {},
    String priority = 'normal',
    String createdBy = 'ui',
    String readiness = 'ready',
    String size = 'medium',
    String risk = 'low_code',
    String suggestedActor = 'user',
    String verificationNeeded = 'none',
    String? nextAction,
    String? blockerReason,
    String? planningNotes,
    DateTime? lastReviewedAt,
  }) async {
    final id = await db.enqueueLlmTask(
      projectId: projectId,
      workItemId: workItemId,
      title: title,
      objective: objective,
      contextJson: jsonEncode(context),
      priority: priority,
      createdBy: createdBy,
      readiness: normalizeWorkloadReadiness(readiness),
      size: normalizeWorkloadSize(size),
      risk: normalizeWorkloadRisk(risk),
      suggestedActor: normalizeWorkloadActor(suggestedActor),
      verificationNeeded: normalizeWorkloadVerification(verificationNeeded),
      nextAction: cleanWorkloadText(nextAction),
      blockerReason: cleanWorkloadText(blockerReason),
      planningNotes: cleanWorkloadText(planningNotes),
      lastReviewedAt: lastReviewedAt,
    );
    await db.logEvent(
      area: 'llm_queue',
      action: 'task_enqueued',
      entityType: 'project',
      entityId: projectId,
      outputJson: jsonEncode({'taskId': id, 'workItemId': workItemId}),
    );
    notifyListeners();
    return id;
  }

  Future<List<LlmTaskQueueItem>> getLlmTasks({
    String? projectId,
    String? status,
    int limit = 50,
  }) => db.getLlmTasks(projectId: projectId, status: status, limit: limit);

  Future<List<LlmTaskQueueItem>> getLlmTasksForProject(
    String projectId, {
    int limit = 50,
  }) => db.getLlmTasksForProject(projectId, limit: limit);

  Future<LlmTaskQueueItem?> getLlmTask(String taskId) => db.getLlmTask(taskId);

  Future<LlmTaskQueueItem> updateLlmTask({
    required String taskId,
    required String projectId,
    String? workItemId,
    required String title,
    required String objective,
    Map<String, Object?> context = const {},
    String priority = 'normal',
  }) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) {
      throw StateError('LLM task not found: $taskId');
    }
    if (existing.status == 'completed') {
      throw StateError('Completed LLM tasks cannot be edited.');
    }
    final cleanProjectId = projectId.trim();
    final project = await db.getProjectFull(cleanProjectId);
    if (project == null ||
        project.deletedAt != null ||
        project.id == AppDb.kGeneralTasksProjectId) {
      throw StateError('Project not found or not visible: $cleanProjectId');
    }
    final cleanTitle = title.trim();
    final cleanObjective = objective.trim();
    if (cleanTitle.isEmpty) throw StateError('LLM task title is required.');
    if (cleanObjective.isEmpty) {
      throw StateError('LLM task objective is required.');
    }
    const priorities = {'low', 'normal', 'high', 'urgent'};
    final cleanPriority = priority.trim().isEmpty ? 'normal' : priority.trim();
    if (!priorities.contains(cleanPriority)) {
      throw StateError('Unsupported priority: $cleanPriority.');
    }
    final cleanWorkItemId = workItemId?.trim();
    final normalizedWorkItemId =
        cleanWorkItemId == null || cleanWorkItemId.isEmpty
        ? null
        : cleanWorkItemId;
    if (normalizedWorkItemId != null) {
      final item = await db.getWorkItem(normalizedWorkItemId);
      final owningProject = await db.getProjectForWorkItem(
        normalizedWorkItemId,
      );
      if (item == null || owningProject?.id != cleanProjectId) {
        throw StateError(
          'Work item is not part of project $cleanProjectId: $normalizedWorkItemId.',
        );
      }
    }

    final item = await db.updateLlmTask(
      id: taskId,
      projectId: cleanProjectId,
      workItemId: normalizedWorkItemId,
      title: cleanTitle,
      objective: cleanObjective,
      contextJson: jsonEncode(context),
      priority: cleanPriority,
    );
    if (item == null) throw StateError('LLM task disappeared: $taskId');
    await db.logEvent(
      area: 'llm_queue',
      action: 'task_updated',
      entityType: 'llm_task',
      entityId: taskId,
      outputJson: jsonEncode({
        'projectId': cleanProjectId,
        'workItemId': normalizedWorkItemId,
        'leaseRevoked': existing.status == 'leased',
      }),
    );
    notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem?> claimLlmTask({
    String? taskId,
    required String leasedBy,
    Duration leaseDuration = const Duration(hours: 1),
  }) async {
    final item = await db.claimLlmTask(
      taskId: taskId,
      leasedBy: leasedBy,
      leaseDuration: leaseDuration,
    );
    if (item != null) notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem> cancelLlmTask(
    String taskId, {
    String? reason,
  }) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) {
      throw StateError('LLM task not found: $taskId');
    }
    if (existing.status == 'completed') {
      throw StateError('Completed LLM tasks cannot be cancelled.');
    }
    final cleanReason = reason?.trim();
    final item = await db.cancelLlmTask(
      id: taskId,
      reason: cleanReason == null || cleanReason.isEmpty
          ? 'Cancelled by operator.'
          : cleanReason,
    );
    if (item == null) throw StateError('LLM task disappeared: $taskId');
    await db.logEvent(
      area: 'llm_queue',
      action: 'task_cancelled',
      entityType: 'llm_task',
      entityId: taskId,
      outputJson: jsonEncode({'projectId': item.projectId}),
    );
    notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem> requeueLlmTask(String taskId) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) {
      throw StateError('LLM task not found: $taskId');
    }
    if (!{'failed', 'cancelled'}.contains(existing.status)) {
      throw StateError('Only failed or cancelled LLM tasks can be requeued.');
    }
    final item = await db.requeueLlmTask(id: taskId);
    if (item == null) throw StateError('LLM task disappeared: $taskId');
    await db.logEvent(
      area: 'llm_queue',
      action: 'task_requeued',
      entityType: 'llm_task',
      entityId: taskId,
      outputJson: jsonEncode({'projectId': item.projectId}),
    );
    notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem?> completeLlmTask({
    required String taskId,
    required Map<String, Object?> result,
    String? reviewDraftId,
  }) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) return null;
    if (existing.status != 'leased') {
      throw StateError('Only leased LLM tasks can be completed.');
    }
    final item = await db.completeLlmTask(
      id: taskId,
      resultJson: jsonEncode(result),
      reviewDraftId: reviewDraftId,
    );
    notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem?> failLlmTask({
    required String taskId,
    required String error,
    Map<String, Object?> result = const {},
  }) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) return null;
    if (existing.status != 'leased') {
      throw StateError('Only leased LLM tasks can be failed.');
    }
    final item = await db.failLlmTask(
      id: taskId,
      error: error,
      resultJson: result.isEmpty ? null : jsonEncode(result),
    );
    notifyListeners();
    return item;
  }

  Future<ProjectGitRemoteStatus> refreshProjectGithubRemoteMetadata(
    String projectId, {
    GithubRemoteMetadataService? service,
  }) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    if (registry == null) {
      throw StateError('Project is not linked to a local registry entry.');
    }
    final observation = await db.getLatestProjectObservationForPath(
      registry.localPath,
    );
    final remoteUrl = observation?.remoteUrl;
    final identity = GithubRemoteMetadataService.parseGithubRemoteUrl(
      remoteUrl,
    );
    if (identity == null) {
      throw StateError('No GitHub origin remote is recorded for this project.');
    }

    final result = await (service ?? GithubRemoteMetadataService()).fetch(
      identity,
    );
    final status = await db.upsertProjectGitRemoteStatus(
      projectId: projectId,
      registryId: registry.id,
      provider: result.identity.provider,
      owner: result.identity.owner,
      repo: result.identity.repo,
      remoteUrl: result.identity.remoteUrl,
      htmlUrl: result.htmlUrl,
      visibility: result.visibility,
      defaultBranch: result.defaultBranch,
      onlineHeadSha: result.onlineHeadSha,
      isPrivate: result.isPrivate,
      isFork: result.isFork,
      isArchived: result.isArchived,
      checkedAt: result.checkedAt,
      remoteUpdatedAt: result.remoteUpdatedAt,
      remotePushedAt: result.remotePushedAt,
      error: result.error,
      rawJson: result.rawJson,
    );
    await db.logEvent(
      level: result.hasError ? 'warn' : 'info',
      area: 'github',
      action: 'project_github_metadata_refreshed',
      entityType: 'project',
      entityId: projectId,
      inputJson: remoteUrl,
      outputJson: jsonEncode(status.toJson()),
      error: result.error,
    );
    notifyListeners();
    return status;
  }

  Future<String> associateProjectFile(String projectId, String path) async {
    final filePath = path.trim();
    if (filePath.isEmpty) {
      throw ArgumentError('Choose a file to associate.');
    }
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Associated file not found', filePath);
    }
    final filename = p.basename(filePath);
    final extension = p.extension(filename).replaceFirst('.', '').toLowerCase();
    final metadataJson = jsonEncode({
      'associationKind': 'file',
      'originalPath': filePath,
    });
    if (LocalProjectRefreshService.mediaExtensions.contains(extension)) {
      return importProjectMediaFromPath(
        projectId,
        filePath,
        source: 'associated_file:$filePath',
        metadataJson: metadataJson,
      );
    }
    final id = await db.importDocumentFromPath(
      filePath,
      projectId: projectId,
      source: 'associated_file:$filePath',
      metadataJson: metadataJson,
    );
    return id;
  }

  Future<String> associateProjectFolder(String projectId, String path) async {
    final folderPath = path.trim();
    if (folderPath.isEmpty) {
      throw ArgumentError('Choose a folder to associate.');
    }
    if (isUnsafeOperationsScanRoot(folderPath)) {
      throw ArgumentError('Choose a project folder, not a drive root.');
    }
    final folder = Directory(folderPath);
    if (!folder.existsSync()) {
      throw FileSystemException('Associated folder not found', folderPath);
    }
    final title = p.basename(folderPath);
    final stat = folder.statSync();
    return saveProjectMedia(
      projectId: projectId,
      title: title.isEmpty ? folderPath : title,
      originalFilename: title.isEmpty ? folderPath : title,
      storedPath: folderPath,
      mediaType: 'folder',
      fileModifiedAt: stat.modified,
      source: 'associated_folder:$folderPath',
      metadataJson: jsonEncode({
        'associationKind': 'folder',
        'originalPath': folderPath,
      }),
    );
  }

  Future<ProjectRegistryEntry> replaceProjectLocalRepoLink(
    String projectId,
    String selectedPath,
  ) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) {
      throw StateError('Atlas project not found: $projectId');
    }
    final rootPath = selectedPath.trim();
    if (rootPath.isEmpty) {
      throw ArgumentError('Choose a project folder.');
    }
    if (isUnsafeOperationsScanRoot(rootPath)) {
      throw ArgumentError('Choose a project folder, not a drive root.');
    }
    if (!Directory(rootPath).existsSync()) {
      throw FileSystemException('Local repo folder not found', rootPath);
    }
    final gitReport = await const LocalGitVisibilityService().inspect(rootPath);
    final scanRoot = gitReport.gitRoot ?? rootPath;

    final runId = await runLocalOperationsScan(
      scanner: LocalOperationsScanner(roots: [scanRoot], maxDepth: 0),
    );
    final observations = await db.getProjectObservationsForScanRun(runId);
    if (observations.isEmpty) {
      throw StateError('No project markers found in that folder.');
    }
    final observation = _chooseLocalRepoReplacementObservation(
      scanRoot,
      observations,
    );
    final existingForPath = await db.getProjectRegistryByPath(
      observation.observedPath,
    );
    final existingProjectId = existingForPath?.atlasProjectId?.trim();
    if (existingProjectId != null &&
        existingProjectId.isNotEmpty &&
        existingProjectId != projectId) {
      throw StateError(
        'That folder is already linked to another Atlas project.',
      );
    }

    late ProjectRegistryEntry linkedRegistry;
    await db.transaction(() async {
      await db.reviewProjectObservation(
        observationId: observation.id,
        reviewState: 'linked',
        atlasProjectId: projectId,
      );
      final registry = await db.getProjectRegistryByPath(
        observation.observedPath,
      );
      if (registry == null) {
        throw StateError('Project registry row was not created.');
      }
      await db.unlinkProjectRegistryEntriesForAtlasProject(
        atlasProjectId: projectId,
        exceptRegistryId: registry.id,
      );
      await db.linkProjectRegistryEntryToAtlasProject(
        registryId: registry.id,
        atlasProjectId: projectId,
      );
      await db.updateProjectMeta(projectId, {
        'scopeIncluded': 'Local project root: ${registry.localPath}',
      });
      linkedRegistry = (await db.getProjectRegistryEntry(registry.id))!;
    });

    await db.logEvent(
      area: 'projects',
      action: 'local_repo_link_replaced',
      entityType: 'project',
      entityId: projectId,
      inputJson: rootPath,
      outputJson: jsonEncode({
        'registryId': linkedRegistry.id,
        'localPath': linkedRegistry.localPath,
        'gitRoot': linkedRegistry.gitRoot,
        'selectedPath': rootPath,
        'scanRunId': runId,
      }),
    );
    notifyListeners();
    return linkedRegistry;
  }

  ProjectObservation _chooseLocalRepoReplacementObservation(
    String rootPath,
    List<ProjectObservation> observations,
  ) {
    final normalizedRoot = _pathKey(rootPath);
    return observations.firstWhere(
      (observation) => _pathKey(observation.observedPath) == normalizedRoot,
      orElse: () => observations.first,
    );
  }

  Future<ProjectReconciliationPreview> previewProjectReconciliation(
    String projectId, {
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final cleanProjectId = projectId.trim();
    final project = await db.getProjectFull(cleanProjectId);
    if (project == null) {
      throw StateError('Atlas project not found: $cleanProjectId');
    }
    final registryEntries = await db.getProjectRegistryEntriesByAtlasProjectId(
      cleanProjectId,
    );
    final activePrimarySources = registryEntries
        .where(_isActivePrimarySource)
        .toList(growable: false);
    final unresolvedSources = registryEntries
        .where(_isUnresolvedSource)
        .toList(growable: false);
    final legacyRemoteSources = registryEntries
        .where((entry) => entry.sourceType == 'remote_url_legacy')
        .toList(growable: false);
    final topologyBlockers = <String>[];
    final topologyWarnings = <String>[];

    if (registryEntries.isEmpty) {
      topologyBlockers.add('Project has no linked source registry rows.');
    }
    if (activePrimarySources.isEmpty) {
      topologyBlockers.add('Project has no active primary working source.');
    } else if (activePrimarySources.length > 1) {
      topologyBlockers.add(
        'Project has multiple active primary working sources.',
      );
    }
    for (final source in unresolvedSources) {
      final message =
          '${source.displayName}: source topology is unresolved '
          '(${source.sourceRole}, ${source.lifecycleState}, '
          '${source.authorityLevel}).';
      if (source.authorityLevel == 'blocked_unresolved' ||
          source.lifecycleState == 'legacy_remote') {
        topologyBlockers.add(message);
      } else {
        topologyWarnings.add(message);
      }
    }
    for (final source in legacyRemoteSources.where(_isUnresolvedSource)) {
      topologyBlockers.add(
        '${source.displayName}: legacy remote source rows are evidence only.',
      );
    }
    if (activePrimarySources.length == 1) {
      final primary = activePrimarySources.single;
      if (_looksLikeRemotePath(primary.localPath)) {
        topologyBlockers.add(
          '${primary.displayName}: primary source is a remote URL, not a local folder.',
        );
      } else if (!_directoryExistsSafely(primary.localPath)) {
        topologyBlockers.add(
          '${primary.displayName}: primary source folder does not exist.',
        );
      }
    }

    final audit = await _buildProjectEnrichmentAudit(
      registry: registryEntries,
      projects: [project],
    );
    final auditErrors = audit.findings
        .where((finding) => finding.severity == 'error')
        .length;
    final auditWarnings = audit.findings
        .where((finding) => finding.severity == 'warning')
        .length;
    final auditInfos = audit.findings
        .where((finding) => finding.severity == 'info')
        .length;

    LocalProjectRefreshPreview? localRefreshPreview;
    var localRefreshFailed = false;
    final localRefreshWarnings = <String>[];
    if (topologyBlockers.isEmpty && activePrimarySources.length == 1) {
      try {
        localRefreshPreview = await previewLocalProjectRefreshForRegistryEntry(
          activePrimarySources.single.id,
          cleanProjectId,
          service: service,
        );
        localRefreshWarnings.addAll(localRefreshPreview.warnings);
      } catch (error) {
        localRefreshFailed = true;
        localRefreshWarnings.add(error.toString());
      }
    }

    final localEntries =
        localRefreshPreview?.entries ??
        const <LocalProjectRefreshPreviewEntry>[];
    final refreshableActions = localEntries
        .where((entry) => entry.shouldApplyByDefault)
        .length;
    final unchangedActions = localEntries
        .where((entry) => entry.status == 'unchanged')
        .length;
    final deferredByCap = localRefreshWarnings
        .where((warning) => warning.toLowerCase().contains('capped'))
        .length;
    final excludedByPolicy = localRefreshWarnings
        .where(
          (warning) =>
              warning.toLowerCase().contains('excluded') ||
              warning.toLowerCase().contains('over'),
        )
        .length;

    final channels = [
      ProjectReconciliationChannelStatus(
        name: 'source_topology',
        status: topologyBlockers.isEmpty ? 'eligible' : 'blocked',
        eligible: activePrimarySources.length,
        processed: registryEntries.length,
        failed: topologyBlockers.length,
        blockers: List.unmodifiable(topologyBlockers),
        warnings: List.unmodifiable(topologyWarnings),
        details: {
          'linkedSources': registryEntries.length,
          'activePrimarySources': activePrimarySources.length,
          'unresolvedSources': unresolvedSources.length,
          'legacyRemoteSources': legacyRemoteSources.length,
          'primaryRegistryIds': activePrimarySources
              .map((entry) => entry.id)
              .toList(),
        },
      ),
      ProjectReconciliationChannelStatus(
        name: 'local_refresh_preview',
        status: topologyBlockers.isNotEmpty
            ? 'blocked'
            : localRefreshFailed
            ? 'failed'
            : refreshableActions > 0
            ? 'partial'
            : localRefreshWarnings.isNotEmpty
            ? 'current_with_declared_exclusions'
            : 'current',
        eligible: refreshableActions,
        processed: localEntries.length,
        unchanged: unchangedActions,
        excludedByPolicy: excludedByPolicy,
        deferredByCap: deferredByCap,
        failed: localRefreshFailed ? 1 : 0,
        blockers: topologyBlockers.isEmpty
            ? const []
            : const ['Source topology must be resolved first.'],
        warnings: List.unmodifiable(localRefreshWarnings),
        details: {
          'registryId': localRefreshPreview?.registryId,
          'profile': localRefreshPreview?.profile,
          'new': localEntries.where((entry) => entry.status == 'new').length,
          'changed': localEntries
              .where((entry) => entry.status == 'changed')
              .length,
          'unchanged': unchangedActions,
        },
      ),
      ProjectReconciliationChannelStatus(
        name: 'atlas_audit',
        status: auditErrors > 0
            ? 'partial'
            : auditWarnings > 0
            ? 'partial'
            : 'current',
        processed: audit.findings.length,
        failed: auditErrors,
        warnings: audit.findings
            .where((finding) => finding.severity != 'error')
            .map((finding) => finding.title)
            .toList(growable: false),
        details: {
          'errors': auditErrors,
          'warnings': auditWarnings,
          'info': auditInfos,
        },
      ),
    ];

    final allBlockers = channels
        .expand((channel) => channel.blockers)
        .toSet()
        .toList(growable: false);
    final allWarnings = channels
        .expand((channel) => channel.warnings)
        .toSet()
        .toList(growable: false);
    final outcome = allBlockers.isNotEmpty
        ? 'blocked'
        : localRefreshFailed
        ? 'failed'
        : refreshableActions > 0 || auditErrors > 0 || auditWarnings > 0
        ? 'partial'
        : allWarnings.isNotEmpty
        ? 'current_with_declared_exclusions'
        : 'current';

    return ProjectReconciliationPreview(
      projectId: cleanProjectId,
      projectTitle: project.title,
      outcome: outcome,
      sourceReposMutated: false,
      writeBoundary: 'atlas_only_preview',
      channels: List.unmodifiable(channels),
      blockers: List.unmodifiable(allBlockers),
      warnings: List.unmodifiable(allWarnings),
      localRefreshPreview: localRefreshPreview,
      auditCoverage: audit.coverage,
    );
  }

  Future<LocalProjectRefreshPreview> previewLocalProjectRefresh(
    String projectId, {
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    if (registry == null) {
      throw StateError('Project is not linked to a local registry entry.');
    }
    return _buildLocalProjectRefreshPreview(
      registry,
      projectId,
      service: service,
    );
  }

  Future<LocalProjectRefreshPreview> previewLocalProjectRefreshForRegistryEntry(
    String registryId,
    String projectId, {
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final registry = await db.getProjectRegistryEntry(registryId);
    if (registry == null) {
      throw StateError('Project registry entry not found: $registryId');
    }
    final linkedProjectId = registry.atlasProjectId;
    if (linkedProjectId != null &&
        linkedProjectId.isNotEmpty &&
        linkedProjectId != projectId) {
      throw StateError(
        'Registry entry $registryId is linked to $linkedProjectId, not $projectId.',
      );
    }
    return _buildLocalProjectRefreshPreview(
      registry,
      projectId,
      service: service,
    );
  }

  Future<LocalProjectRefreshPreview> _buildLocalProjectRefreshPreview(
    ProjectRegistryEntry registry,
    String projectId, {
    required LocalProjectRefreshService service,
  }) async {
    final observation = await db.getLatestProjectObservationForPath(
      registry.localPath,
    );
    final plan = await service.buildPlan(registry.localPath);
    final entries = <LocalProjectRefreshPreviewEntry>[];
    for (final action in plan.actions) {
      final ledger = await db.getLocalProjectRefreshItem(
        registryId: registry.id,
        sourceKind: action.sourceKind,
        sourceKey: action.sourceKey,
      );
      final status = ledger == null
          ? 'new'
          : ledger.sourceFingerprint == action.fingerprint
          ? 'unchanged'
          : 'changed';
      entries.add(
        LocalProjectRefreshPreviewEntry(
          action: action,
          status: status,
          existingTargetId: ledger?.targetId,
        ),
      );
    }
    return LocalProjectRefreshPreview(
      registryId: registry.id,
      projectId: projectId,
      localPath: registry.localPath,
      profile: plan.profile,
      branch: observation?.branch,
      headSha: observation?.headSha,
      dirtyCount: observation?.dirtyCount,
      remoteUrl: observation?.remoteUrl,
      observedAt: observation?.observedAt,
      entries: entries,
      warnings: plan.warnings,
    );
  }

  Future<LocalProjectRefreshApplyResult> applyLocalProjectRefresh(
    String projectId, {
    Iterable<String>? selectedActionIds,
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final preview = await previewLocalProjectRefresh(
      projectId,
      service: service,
    );
    return _applyLocalProjectRefreshPreview(
      projectId,
      preview,
      selectedActionIds: selectedActionIds,
    );
  }

  Future<LocalProjectRefreshApplyResult>
  applyLocalProjectRefreshForRegistryEntry(
    String registryId,
    String projectId, {
    Iterable<String>? selectedActionIds,
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final preview = await previewLocalProjectRefreshForRegistryEntry(
      registryId,
      projectId,
      service: service,
    );
    return _applyLocalProjectRefreshPreview(
      projectId,
      preview,
      selectedActionIds: selectedActionIds,
    );
  }

  Future<LocalProjectBatchRefreshResult> refreshLinkedLocalProjects({
    bool includeSourceDocuments = true,
    Iterable<String>? projectIds,
    Duration betweenProjects = const Duration(milliseconds: 100),
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
    ProjectEnrichmentStatusCallback? onStatus,
  }) async {
    if (_localProjectRefreshRunning) {
      return const LocalProjectBatchRefreshResult(
        considered: 0,
        refreshed: 0,
        created: 0,
        updated: 0,
        unchanged: 0,
        skipped: 0,
        failed: 0,
        alreadyRunning: true,
        warnings: ['Local project refresh is already running.'],
      );
    }
    _localProjectRefreshRunning = true;
    notifyListeners();
    var considered = 0;
    var refreshed = 0;
    var created = 0;
    var updated = 0;
    var unchanged = 0;
    var skipped = 0;
    var failed = 0;
    final warnings = <String>[];
    final scopedProjectIds = _normalizeProjectIdScope(projectIds);
    try {
      onStatus?.call('Reading linked project registry.', current: 0);
      final registry = await db.getProjectRegistry();
      final linked = registry
          .where(
            (entry) =>
                entry.reviewState != 'ignored' &&
                (entry.atlasProjectId ?? '').isNotEmpty &&
                _isProjectInScope(entry.atlasProjectId, scopedProjectIds),
          )
          .toList(growable: false);
      onStatus?.call(
        linked.isEmpty
            ? 'No linked projects to refresh.'
            : 'Refreshing linked projects (0/${linked.length}).',
        current: 0,
        total: linked.length,
      );
      for (final entry in linked) {
        considered++;
        final projectId = entry.atlasProjectId!;
        onStatus?.call(
          'Refreshing ${entry.displayName} ($considered/${linked.length}).',
          current: considered,
          total: linked.length,
        );
        final localPath = entry.localPath.trim();
        if (_looksLikeRemotePath(localPath)) {
          skipped++;
          warnings.add(
            '${entry.displayName}: registered local path is a remote URL; replace the folder link or ignore the registry row.',
          );
          onStatus?.call(
            'Skipped ${entry.displayName}: registered local path is a remote URL.',
            current: considered,
            total: linked.length,
          );
          continue;
        }
        if (!_directoryExistsSafely(localPath)) {
          skipped++;
          warnings.add(
            '${entry.displayName}: registered local path does not exist: ${entry.localPath}',
          );
          onStatus?.call(
            'Skipped ${entry.displayName}: registered local path does not exist.',
            current: considered,
            total: linked.length,
          );
          continue;
        }
        try {
          final preview = await previewLocalProjectRefreshForRegistryEntry(
            entry.id,
            projectId,
            service: service,
          );
          final selected = preview.entries
              .where((previewEntry) {
                if (!previewEntry.shouldApplyByDefault) return false;
                if (includeSourceDocuments) return true;
                final kind = previewEntry.action.sourceKind;
                return kind != 'source_file' && kind != 'atlas_card';
              })
              .map((previewEntry) => previewEntry.action.id)
              .toList(growable: false);
          final result = await _applyLocalProjectRefreshPreview(
            projectId,
            preview,
            selectedActionIds: selected,
          );
          created += result.created;
          updated += result.updated;
          unchanged += result.unchanged;
          skipped += result.skipped;
          warnings.addAll(result.warnings);
          if (result.created > 0 || result.updated > 0) refreshed++;
          onStatus?.call(
            'Imported ${entry.displayName}: ${result.created} created, ${result.updated} updated.',
            current: considered,
            total: linked.length,
          );
        } catch (error) {
          failed++;
          warnings.add('${entry.displayName}: $error');
          onStatus?.call(
            'Failed ${entry.displayName}: $error',
            current: considered,
            total: linked.length,
          );
        }
        if (betweenProjects > Duration.zero) {
          await Future<void>.delayed(betweenProjects);
        }
      }
      onStatus?.call(
        'Linked refresh complete: $created created, $updated updated, $failed failed.',
        current: linked.length,
        total: linked.length,
      );
      await db.logEvent(
        area: 'operations',
        action: 'linked_local_projects_refreshed',
        outputJson: jsonEncode({
          'considered': considered,
          'refreshed': refreshed,
          'created': created,
          'updated': updated,
          'unchanged': unchanged,
          'skipped': skipped,
          'failed': failed,
          'includeSourceDocuments': includeSourceDocuments,
          'projectIds': _sortedProjectIdScope(scopedProjectIds),
          'warnings': warnings.length,
        }),
      );
      return LocalProjectBatchRefreshResult(
        considered: considered,
        refreshed: refreshed,
        created: created,
        updated: updated,
        unchanged: unchanged,
        skipped: skipped,
        failed: failed,
        warnings: List.unmodifiable(warnings),
      );
    } finally {
      _localProjectRefreshRunning = false;
      notifyListeners();
    }
  }

  Future<LocalProjectRefreshApplyResult> _applyLocalProjectRefreshPreview(
    String projectId,
    LocalProjectRefreshPreview preview, {
    Iterable<String>? selectedActionIds,
  }) async {
    final selected = selectedActionIds?.toSet();
    var created = 0;
    var updated = 0;
    var unchanged = 0;
    var skipped = 0;
    final warnings = <String>[...preview.warnings];

    for (final entry in preview.entries) {
      if (selected != null && !selected.contains(entry.action.id)) {
        skipped++;
        continue;
      }
      if (entry.status == 'unchanged') {
        unchanged++;
        continue;
      }
      try {
        final wasCreated = await _applyLocalProjectRefreshAction(
          preview.registryId,
          projectId,
          entry,
          planProfile: preview.profile,
        );
        if (wasCreated) {
          created++;
        } else {
          updated++;
        }
      } catch (error) {
        warnings.add('${entry.action.title}: $error');
      }
    }

    await db.logEvent(
      area: 'operations',
      action: 'local_project_refresh_applied',
      entityType: 'project',
      entityId: projectId,
      outputJson: jsonEncode({
        'created': created,
        'updated': updated,
        'unchanged': unchanged,
        'skipped': skipped,
        'warnings': warnings.length,
      }),
    );
    notifyListeners();
    return LocalProjectRefreshApplyResult(
      created: created,
      updated: updated,
      unchanged: unchanged,
      skipped: skipped,
      warnings: warnings,
    );
  }

  Future<String> importProjectRegistryEntryAsProject(
    String registryId, {
    bool importDocs = true,
    bool refresh = true,
  }) async {
    final entry = await db.getProjectRegistryEntry(registryId);
    if (entry == null) {
      throw StateError('Project registry entry not found: $registryId');
    }
    if (entry.atlasProjectId != null && entry.atlasProjectId!.isNotEmpty) {
      return entry.atlasProjectId!;
    }
    final matchingProject = await _findSingleMatchingProjectForRegistryEntry(
      entry,
    );
    if (matchingProject != null) {
      return updateExistingProjectFromRegistryEntry(
        registryId,
        matchingProject.id,
        importDocs: importDocs,
        refresh: refresh,
      );
    }

    final now = DateTime.now();
    final projectId = now.microsecondsSinceEpoch.toString();
    await db.transaction(() async {
      await db.createProject(projectId, entry.displayName, now);
      await db.updateProjectMeta(projectId, {
        'description': _projectDescriptionFromRegistry(entry),
        'scopeIncluded': 'Local project root: ${entry.localPath}',
        'scopeExcluded': refresh
            ? 'Repo mutation, GitHub import, and AI summarization were not performed during import.'
            : 'Full source indexing, repo mutation, GitHub import, and AI summarization were not performed during import.',
      });
      await db.linkProjectRegistryEntryToAtlasProject(
        registryId: registryId,
        atlasProjectId: projectId,
      );
      await db.setActiveProjectId(projectId);
    });

    final importedDocs = importDocs
        ? await _importSafeLocalProjectDocs(projectId, entry.localPath)
        : 0;
    LocalProjectRefreshApplyResult? refreshResult;
    if (refresh) {
      refreshResult = await applyLocalProjectRefreshForRegistryEntry(
        registryId,
        projectId,
      );
    }
    await db.logEvent(
      area: 'operations',
      action: 'registry_imported_to_project',
      entityType: 'project',
      entityId: projectId,
      inputJson: registryId,
      outputJson: jsonEncode({
        'localPath': entry.localPath,
        'importedDocuments': importedDocs,
        if (refreshResult != null) ...{
          'refreshCreated': refreshResult.created,
          'refreshUpdated': refreshResult.updated,
          'refreshUnchanged': refreshResult.unchanged,
          'refreshSkipped': refreshResult.skipped,
          'refreshWarnings': refreshResult.warnings.length,
        },
      }),
    );
    notifyListeners();
    return projectId;
  }

  Future<String> updateExistingProjectFromRegistryEntry(
    String registryId,
    String atlasProjectId, {
    bool importDocs = true,
    bool refresh = true,
  }) async {
    final entry = await db.getProjectRegistryEntry(registryId);
    if (entry == null) {
      throw StateError('Project registry entry not found: $registryId');
    }
    final project = await db.getProjectFull(atlasProjectId);
    if (project == null) {
      throw StateError('Atlas project not found: $atlasProjectId');
    }

    await db.transaction(() async {
      await db.linkProjectRegistryEntryToAtlasProject(
        registryId: registryId,
        atlasProjectId: atlasProjectId,
      );
      await db.updateProjectMeta(atlasProjectId, {
        'scopeIncluded': 'Local project root: ${entry.localPath}',
        'scopeExcluded':
            'Full source indexing, repo mutation, GitHub import, and AI summarization were not performed during local update.',
      });
      await db.setActiveProjectId(atlasProjectId);
    });

    final importedDocs = importDocs
        ? await _importSafeLocalProjectDocs(atlasProjectId, entry.localPath)
        : 0;
    LocalProjectRefreshApplyResult? refreshResult;
    if (refresh) {
      refreshResult = await applyLocalProjectRefreshForRegistryEntry(
        registryId,
        atlasProjectId,
      );
    }
    await db.logEvent(
      area: 'operations',
      action: 'registry_updated_existing_project',
      entityType: 'project',
      entityId: atlasProjectId,
      inputJson: registryId,
      outputJson: jsonEncode({
        'localPath': entry.localPath,
        'importedDocuments': importedDocs,
        if (refreshResult != null) ...{
          'refreshCreated': refreshResult.created,
          'refreshUpdated': refreshResult.updated,
          'refreshUnchanged': refreshResult.unchanged,
          'refreshSkipped': refreshResult.skipped,
          'refreshWarnings': refreshResult.warnings.length,
        },
      }),
    );
    notifyListeners();
    return atlasProjectId;
  }

  Future<bool> _applyLocalProjectRefreshAction(
    String registryId,
    String projectId,
    LocalProjectRefreshPreviewEntry entry, {
    required String planProfile,
  }) async {
    final action = entry.action;
    final now = DateTime.now();
    var created = entry.existingTargetId == null;
    String targetId;

    switch (action.targetType) {
      case 'document':
        final path = _payloadNullableString(action, 'path');
        final filename = _payloadString(action, 'filename');
        final title = _payloadNullableString(action, 'title');
        final source = _payloadNullableString(action, 'source');
        final metadataJson = _payloadNullableString(action, 'metadataJson');
        final generatedText = _payloadNullableString(action, 'generatedText');
        final extension = _payloadNullableString(action, 'extension');
        final existingBySource = source == null
            ? null
            : await db.getProjectDocumentBySource(projectId, source);
        final existingId = entry.existingTargetId ?? existingBySource?.id;
        if (existingId != null && await db.documentExists(existingId)) {
          if (entry.status != 'changed') {
            targetId = existingId;
          } else {
            await db.deleteDocument(existingId);
            targetId = await _importRefreshDocument(
              path: path,
              filename: filename,
              title: title,
              source: source,
              metadataJson: metadataJson,
              generatedText: generatedText,
              extension: extension,
              projectId: projectId,
            );
          }
          created = false;
        } else {
          final existing = generatedText == null
              ? await db.getProjectDocumentByOriginalFilename(
                  projectId,
                  filename,
                )
              : null;
          if (existing != null) {
            targetId = existing.id;
            created = false;
          } else {
            targetId = await _importRefreshDocument(
              path: path,
              filename: filename,
              title: title,
              source: source,
              metadataJson: metadataJson,
              generatedText: generatedText,
              extension: extension,
              projectId: projectId,
            );
            created = true;
          }
        }
        break;
      case 'media':
        final path = _payloadString(action, 'path');
        final filename = _payloadString(action, 'filename');
        final title = _payloadString(action, 'title');
        final relativePath = _payloadString(action, 'relativePath');
        final source = 'local_refresh:${action.sourceKey}';
        final existingBySource = await db.getProjectMediaBySource(
          projectId,
          source,
        );
        final existingId = entry.existingTargetId ?? existingBySource?.id;
        final existingMedia = existingId == null
            ? null
            : await db.getProjectMediaItem(existingId);
        if (existingMedia != null && entry.status != 'changed') {
          targetId = existingMedia.id;
          created = false;
        } else {
          if (existingMedia != null) {
            await db.deleteProjectMedia(existingMedia.id);
            created = false;
          }
          targetId = await importProjectMediaFromPath(
            projectId,
            path,
            title: title,
            caption: 'Imported from local project media: $relativePath',
            source: source,
            metadataJson: jsonEncode({
              'refreshSourceKey': action.sourceKey,
              'relativePath': relativePath,
              'filename': filename,
            }),
          );
        }
        break;
      case 'decision':
        final title = _payloadString(action, 'title');
        final ctx = _payloadNullableString(action, 'ctx');
        final decider = _payloadNullableString(action, 'decider');
        if (entry.existingTargetId != null &&
            await db.getProjectDecision(entry.existingTargetId!) != null) {
          await db.updateProjectDecision(
            entry.existingTargetId!,
            title: title,
            ctx: ctx,
            decider: decider,
          );
          targetId = entry.existingTargetId!;
          created = false;
        } else {
          targetId = await db.addProjectDecision(
            projectId,
            title,
            ctx,
            decider,
          );
          created = true;
        }
        break;
      case 'work_item':
        final title = _payloadString(action, 'title');
        final description = _payloadNullableString(action, 'description');
        final status = _payloadString(action, 'status');
        final priority = _payloadString(action, 'priority');
        final blockedReason = _payloadNullableString(action, 'blockedReason');
        if (entry.existingTargetId != null &&
            await db.workItemExists(entry.existingTargetId!)) {
          await db.updateWorkItem(
            id: entry.existingTargetId!,
            title: title,
            description: description,
            status: status,
            priority: priority,
            blockedReason: blockedReason,
            clearBlockedReason: blockedReason == null,
          );
          targetId = entry.existingTargetId!;
          created = false;
        } else {
          final stages = await db.getStagesForProject(projectId);
          if (stages.isEmpty) {
            await db.ensureDefaultStagesForProjects();
          }
          final stageList = await db.getStagesForProject(projectId);
          if (stageList.isEmpty) {
            throw StateError('Project has no stage for imported work items.');
          }
          targetId = await db.addWorkItem(
            stageId: stageList.first.id,
            title: title,
            description: description,
            status: status,
            priority: priority,
            source: _payloadNullableString(action, 'source'),
            blockedReason: blockedReason,
          );
          created = true;
        }
        break;
      case 'risk':
        final title = _payloadString(action, 'title');
        final desc = _payloadNullableString(action, 'desc');
        final severity = _payloadString(action, 'severity');
        if (entry.existingTargetId != null &&
            await db.getProjectRisk(entry.existingTargetId!) != null) {
          await db.updateProjectRisk(
            entry.existingTargetId!,
            title: title,
            desc: desc,
            severity: severity,
          );
          targetId = entry.existingTargetId!;
          created = false;
        } else {
          targetId = await db.addProjectRisk(projectId, title, desc, severity);
          created = true;
        }
        break;
      case 'project':
        final registry = await db.getProjectRegistryEntry(registryId);
        if (registry == null) {
          throw StateError('Project registry entry not found: $registryId');
        }
        await _applyProjectIdentityAction(
          projectId: projectId,
          entry: registry,
          action: action,
          planProfile: planProfile,
        );
        targetId = projectId;
        created = false;
        break;
      default:
        throw StateError('Unsupported refresh target: ${action.targetType}');
    }

    await db.upsertLocalProjectRefreshItem(
      registryId: registryId,
      sourceKind: action.sourceKind,
      sourceKey: action.sourceKey,
      targetType: action.targetType,
      targetId: targetId,
      sourceFingerprint: action.fingerprint,
      lastImportedAt: now,
    );
    return created;
  }

  Future<String> _importRefreshDocument({
    required String? path,
    required String filename,
    required String? title,
    required String? source,
    required String? metadataJson,
    required String? generatedText,
    required String? extension,
    required String projectId,
  }) {
    if (generatedText != null) {
      return db.importGeneratedDocument(
        title: title ?? filename,
        originalFilename: filename,
        body: generatedText,
        projectId: projectId,
        extension: extension,
        source: source,
        metadataJson: metadataJson,
      );
    }
    if (path == null || path.trim().isEmpty) {
      throw StateError('Document refresh action is missing a source path.');
    }
    return db.importDocumentFromPath(
      path,
      projectId: projectId,
      title: title,
      source: source,
      metadataJson: metadataJson,
    );
  }

  String _payloadString(LocalProjectRefreshAction action, String key) {
    final value = action.payload[key];
    if (value == null) {
      throw StateError('Refresh action ${action.id} is missing $key.');
    }
    return '$value';
  }

  String? _payloadNullableString(LocalProjectRefreshAction action, String key) {
    final value = action.payload[key];
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  Future<String> runLocalOperationsScan({
    LocalOperationsScanner scanner = const LocalOperationsScanner(),
  }) async {
    final startedAt = DateTime.now();
    final runId = await db.startProjectScanRun(
      rootsJson: jsonEncode(scanner.roots),
      startedAt: startedAt,
    );
    try {
      final result = await scanner.scan();
      for (var i = 0; i < result.observations.length; i++) {
        final observation = result.observations[i];
        final existing = await db.getProjectRegistryByPath(
          observation.observedPath,
        );
        await db.addProjectObservation(
          id: 'obs_${runId}_$i',
          registryId: existing?.id,
          scanRunId: runId,
          observedPath: observation.observedPath,
          classificationGuess: observation.classificationGuess,
          confidence: observation.confidence,
          branch: observation.branch,
          headSha: observation.headSha,
          dirtyCount: observation.dirtyCount,
          remoteUrl: observation.remoteUrl,
          markerFilesJson: jsonEncode(observation.markerFiles),
          warningsJson: jsonEncode(observation.warnings),
          rawJson: observation.toRawJson(),
          observedAt: observation.observedAt,
        );
      }
      await db.finishProjectScanRun(
        id: runId,
        completedAt: result.completedAt,
        status: 'completed',
        totalSeen: result.totalSeen,
        candidates: result.observations.length,
        ignored: result.ignored,
        warningsJson: jsonEncode(result.warnings),
      );
      await db.logEvent(
        area: 'operations',
        action: 'local_scan_completed',
        entityType: 'project_scan_run',
        entityId: runId,
        outputJson: jsonEncode({
          'roots': result.roots,
          'candidates': result.observations.length,
          'totalSeen': result.totalSeen,
        }),
      );
      return runId;
    } catch (error, stackTrace) {
      await db.finishProjectScanRun(
        id: runId,
        completedAt: DateTime.now(),
        status: 'failed',
        totalSeen: 0,
        candidates: 0,
        ignored: 0,
        warningsJson: jsonEncode([error.toString()]),
      );
      await db.logError(
        area: 'operations',
        action: 'local_scan_failed',
        error: error,
        stackTrace: stackTrace,
        entityType: 'project_scan_run',
        entityId: runId,
      );
      rethrow;
    }
  }

  Future<void> acceptProjectObservation(String observationId) async {
    await db.reviewProjectObservation(
      observationId: observationId,
      reviewState: 'accepted',
    );
  }

  Future<void> acceptProjectObservations(
    Iterable<String> observationIds,
  ) async {
    await _reviewProjectObservations(observationIds, 'accepted');
  }

  Future<void> linkProjectObservation(
    String observationId,
    String atlasProjectId,
  ) async {
    await db.reviewProjectObservation(
      observationId: observationId,
      reviewState: 'linked',
      atlasProjectId: atlasProjectId,
    );
  }

  Future<void> ignoreProjectObservation(String observationId) async {
    await db.reviewProjectObservation(
      observationId: observationId,
      reviewState: 'ignored',
    );
  }

  Future<void> ignoreProjectObservations(
    Iterable<String> observationIds,
  ) async {
    await _reviewProjectObservations(observationIds, 'ignored');
  }

  Future<void> markProjectObservationNeedsReview(String observationId) async {
    await db.reviewProjectObservation(
      observationId: observationId,
      reviewState: 'needs_review',
    );
  }

  Future<void> markProjectObservationsNeedsReview(
    Iterable<String> observationIds,
  ) async {
    await _reviewProjectObservations(observationIds, 'needs_review');
  }

  Future<void> _reviewProjectObservations(
    Iterable<String> observationIds,
    String reviewState,
  ) async {
    final ids = observationIds.toSet();
    if (ids.isEmpty) return;
    for (final id in ids) {
      await db.reviewProjectObservation(
        observationId: id,
        reviewState: reviewState,
      );
    }
  }

  Future<String> buildProjectScanRunExportJson(String scanRunId) async {
    final run = await db.getProjectScanRun(scanRunId);
    if (run == null) {
      throw StateError('Project scan run not found: $scanRunId');
    }
    final observations = await db.getProjectObservationsForScanRun(scanRunId);
    final runWarnings = _decodeStringList(run.warningsJson);
    final observationWarnings = <Map<String, Object?>>[];
    for (final observation in observations) {
      final warnings = _decodeStringList(observation.warningsJson);
      for (final warning in warnings) {
        observationWarnings.add({
          'observationId': observation.id,
          'observedPath': observation.observedPath,
          'displayName': _displayNameFromObservation(observation),
          'warning': warning,
        });
      }
    }
    final payload = {
      'schema': 'project_atlas_local_operations_scan_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'summary': {
        'status': run.status,
        'roots': _decodeStringList(run.rootsJson),
        'totalSeen': run.totalSeen,
        'candidates': run.candidates,
        'ignored': run.ignored,
        'runWarnings': runWarnings.length,
        'observationWarnings': observationWarnings.length,
      },
      'scanRun': run.toJson(),
      'warnings': {'run': runWarnings, 'observations': observationWarnings},
      'observations': observations.map((row) => row.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<String> buildProjectScanRunWarningsExportJson(String scanRunId) async {
    final run = await db.getProjectScanRun(scanRunId);
    if (run == null) {
      throw StateError('Project scan run not found: $scanRunId');
    }
    final observations = await db.getProjectObservationsForScanRun(scanRunId);
    final warningsPayload = _projectScanRunWarningsPayload(run, observations);
    return const JsonEncoder.withIndent('  ').convert({
      'schema': 'project_atlas_local_operations_warnings_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      ...warningsPayload,
    });
  }

  Future<Directory> ensureOperationsScansFolder() async {
    final supportDir = await getApplicationSupportDirectory();
    final root = Directory(p.join(supportDir.path, 'operations_scans'));
    for (final child in ['runs', 'warnings', 'logs', 'project_health']) {
      await Directory(p.join(root.path, child)).create(recursive: true);
    }
    return root;
  }

  Future<String> saveProjectScanRunExportToAppFolder(String scanRunId) async {
    final root = await ensureOperationsScansFolder();
    final path = p.join(
      root.path,
      'runs',
      '${_safeFileStem(scanRunId)}_operations_scan.json',
    );
    await File(
      path,
    ).writeAsString(await buildProjectScanRunExportJson(scanRunId));
    return path;
  }

  Future<String> saveProjectScanRunWarningsToAppFolder(String scanRunId) async {
    final root = await ensureOperationsScansFolder();
    final path = p.join(
      root.path,
      'warnings',
      '${_safeFileStem(scanRunId)}_operations_warnings.json',
    );
    await File(
      path,
    ).writeAsString(await buildProjectScanRunWarningsExportJson(scanRunId));
    return path;
  }

  Future<String> buildOperationsWarningsExportJson({
    int scanRunLimit = 50,
    int observationLimit = 500,
  }) async {
    final runs = await getProjectScanRuns(limit: scanRunLimit);
    final observations = await getRecentProjectObservations(
      limit: observationLimit,
    );
    return const JsonEncoder.withIndent('  ').convert({
      'schema': 'project_atlas_operations_warnings_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      ..._operationsWarningsPayload(
        runs,
        observations,
        scanRunLimit: scanRunLimit,
        observationLimit: observationLimit,
      ),
    });
  }

  Future<String> saveOperationsWarningsToAppFolder({
    int scanRunLimit = 50,
    int observationLimit = 500,
  }) async {
    final root = await ensureOperationsScansFolder();
    final timestamp = _safeFileStem(DateTime.now().toIso8601String());
    final path = p.join(
      root.path,
      'warnings',
      '${timestamp}_operations_warnings.json',
    );
    await File(path).writeAsString(
      await buildOperationsWarningsExportJson(
        scanRunLimit: scanRunLimit,
        observationLimit: observationLimit,
      ),
    );
    return path;
  }

  Future<void> openOperationsScansFolder() async {
    final root = await ensureOperationsScansFolder();
    await Process.start('explorer.exe', [root.path]);
  }

  Future<void> openOperationsWarningsFolder() async {
    final root = await ensureOperationsScansFolder();
    await Process.start('explorer.exe', [p.join(root.path, 'warnings')]);
  }

  List<String> _decodeStringList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((item) => '$item').toList();
    } catch (e) {
      debugPrint('[Atlas] _decodeStringList: JSON parse of string list failed (continuing): $e');
    }
    return const [];
  }

  String _displayNameFromObservation(ProjectObservation observation) {
    try {
      final raw = jsonDecode(observation.rawJson);
      if (raw is Map && raw['displayName'] is String) {
        final value = (raw['displayName'] as String).trim();
        if (value.isNotEmpty) return value;
      }
    } catch (e) {
      debugPrint('[Atlas] _displayNameFromObservation: JSON parse of observation rawJson failed (continuing): $e');
    }
    return p.basename(observation.observedPath);
  }

  String _projectDescriptionFromRegistry(ProjectRegistryEntry entry) {
    final lines = <String>[
      'Imported from the Local Operations Registry.',
      'Local path: ${entry.localPath}',
      'Classification: ${entry.classification}',
    ];
    if ((entry.gitRoot ?? '').trim().isNotEmpty) {
      lines.add('Git root: ${entry.gitRoot}');
    }
    return lines.join('\n');
  }

  Future<ProjectFull?> _findSingleMatchingProjectForRegistryEntry(
    ProjectRegistryEntry entry,
  ) async {
    final key = _projectTitleKey(entry.displayName);
    if (key.isEmpty) return null;
    final matches = (await db.getProjectsFull())
        .where((project) => _projectTitleKey(project.title) == key)
        .toList(growable: false);
    if (matches.length > 1) {
      throw StateError(
        'Multiple Atlas projects already match "${entry.displayName}". Use Update existing in Operations to choose the target project.',
      );
    }
    return matches.isEmpty ? null : matches.single;
  }

  String _projectTitleKey(String value) => value.trim().toLowerCase();

  Future<int> _importSafeLocalProjectDocs(
    String projectId,
    String localPath,
  ) async {
    final dir = Directory(localPath);
    if (!dir.existsSync()) return 0;
    var imported = 0;
    for (final filename in _safeLocalProjectDocNames) {
      final file = File(p.join(dir.path, filename));
      if (!file.existsSync()) continue;
      try {
        final existing = await db.getProjectDocumentByOriginalFilename(
          projectId,
          filename,
        );
        if (existing != null) continue;
        await importDocumentFromPath(file.path, projectId: projectId);
        imported++;
      } catch (error) {
        await db.logEvent(
          level: 'warn',
          area: 'operations',
          action: 'local_project_doc_import_failed',
          entityType: 'project',
          entityId: projectId,
          inputJson: file.path,
          error: error.toString(),
        );
      }
    }
    return imported;
  }

  Map<String, Object?> _projectScanRunWarningsPayload(
    ProjectScanRun run,
    List<ProjectObservation> observations,
  ) {
    final runWarnings = _decodeStringList(run.warningsJson);
    final observationWarnings = <Map<String, Object?>>[];
    for (final observation in observations) {
      final warnings = _decodeStringList(observation.warningsJson);
      for (final warning in warnings) {
        observationWarnings.add({
          'observationId': observation.id,
          'observedPath': observation.observedPath,
          'displayName': _displayNameFromObservation(observation),
          'warning': warning,
        });
      }
    }
    return {
      'summary': {
        'scanRunId': run.id,
        'status': run.status,
        'roots': _decodeStringList(run.rootsJson),
        'totalSeen': run.totalSeen,
        'candidates': run.candidates,
        'ignored': run.ignored,
        'runWarnings': runWarnings.length,
        'observationWarnings': observationWarnings.length,
      },
      'scanRun': run.toJson(),
      'warnings': {'run': runWarnings, 'observations': observationWarnings},
    };
  }

  Map<String, Object?> _operationsWarningsPayload(
    List<ProjectScanRun> runs,
    List<ProjectObservation> observations, {
    required int scanRunLimit,
    required int observationLimit,
  }) {
    final runWarnings = <Map<String, Object?>>[];
    for (final run in runs) {
      for (final warning in _decodeStringList(run.warningsJson)) {
        runWarnings.add({
          'scanRunId': run.id,
          'startedAt': run.startedAt.toIso8601String(),
          'completedAt': run.completedAt?.toIso8601String(),
          'status': run.status,
          'roots': _decodeStringList(run.rootsJson),
          'warning': warning,
        });
      }
    }
    final observationWarnings = <Map<String, Object?>>[];
    for (final observation in observations) {
      for (final warning in _decodeStringList(observation.warningsJson)) {
        observationWarnings.add({
          'observationId': observation.id,
          'scanRunId': observation.scanRunId,
          'observedPath': observation.observedPath,
          'displayName': _displayNameFromObservation(observation),
          'observedAt': observation.observedAt.toIso8601String(),
          'classificationGuess': observation.classificationGuess,
          'confidence': observation.confidence,
          'warning': warning,
        });
      }
    }
    return {
      'summary': {
        'scanRunLimit': scanRunLimit,
        'observationLimit': observationLimit,
        'scanRuns': runs.length,
        'observations': observations.length,
        'runWarnings': runWarnings.length,
        'observationWarnings': observationWarnings.length,
        'totalWarnings': runWarnings.length + observationWarnings.length,
      },
      'warnings': {'run': runWarnings, 'observations': observationWarnings},
    };
  }

  String _safeFileStem(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  Future<Draft?> getLatestProjectSummaryDraft(String projectId) =>
      db.getLatestProjectSummaryDraft(projectId);

  Future<Draft?> getLatestProjectChangeSummaryDraft(String projectId) =>
      db.getLatestProjectChangeSummaryDraft(projectId);

  Future<Map<String, String?>> getDocumentPathsForProject(String projectId) =>
      db.getDocumentPathsForProject(projectId);

  Future<ProjectSummaryEvidencePacket> buildProjectSummaryEvidencePacket(
    String projectId, {
    bool? includeLibrary,
  }) async {
    final proj = await getProjectFull(projectId);
    final items = await getWorkItemsForProject(projectId);
    final resolvedIncludeLibrary =
        includeLibrary ?? projectAiSummaryIncludeLibrary;

    List<ProjectRisk> risks = [];
    List<ProjectDecision> decisions = [];
    List<ProjectPerson> people = [];
    try {
      risks = await getProjectRisks(projectId);
    } catch (e) {
      debugPrint('[Atlas] buildProjectSummaryEvidencePacket: failed to load risks (continuing): $e');
    }
    try {
      decisions = await getProjectDecisions(projectId);
    } catch (e) {
      debugPrint('[Atlas] buildProjectSummaryEvidencePacket: failed to load decisions (continuing): $e');
    }
    try {
      people = await getProjectPeople(projectId);
    } catch (e) {
      debugPrint('[Atlas] buildProjectSummaryEvidencePacket: failed to load people (continuing): $e');
    }

    final suppliedDocs = await db.getDocumentsForProject(projectId);
    final rankedDocs =
        suppliedDocs.map((doc) {
          final classification = _projectSummaryDocumentClassification(doc);
          return (
            doc: doc,
            category: classification.category,
            reason: classification.reason,
            score: classification.score,
          );
        }).toList()..sort((a, b) {
          final scoreCompare = b.score.compareTo(a.score);
          if (scoreCompare != 0) return scoreCompare;
          final titleCompare = a.doc.title.toLowerCase().compareTo(
            b.doc.title.toLowerCase(),
          );
          if (titleCompare != 0) return titleCompare;
          return a.doc.id.compareTo(b.doc.id);
        });
    final warnings = <String>[];
    final contextDocs = <ProjectSummaryContextDoc>[];

    if (!resolvedIncludeLibrary && suppliedDocs.isNotEmpty) {
      warnings.add(
        'Library evidence disabled; ${suppliedDocs.length} linked document(s) available.',
      );
    }

    if (resolvedIncludeLibrary) {
      if (suppliedDocs.isEmpty) {
        warnings.add(
          'Library evidence enabled; no linked documents available.',
        );
      }
      var totalChars = 0;
      var unreadableDocuments = 0;
      var documentCapTruncations = 0;
      var packetCapTruncations = 0;
      var budgetMetadataOnlyDocuments = 0;
      for (var index = 0; index < rankedDocs.length; index++) {
        final ranked = rankedDocs[index];
        final doc = ranked.doc;
        String? excerpt;
        if (totalChars < _projectSummaryMaxTotalDocChars) {
          final rawText = await _readDocumentText(doc);
          if (rawText != null) {
            excerpt = rawText;
            if (excerpt.length > _projectSummaryMaxCharsPerDoc) {
              excerpt = excerpt.substring(0, _projectSummaryMaxCharsPerDoc);
              documentCapTruncations++;
            }
            final remaining = _projectSummaryMaxTotalDocChars - totalChars;
            if (excerpt.length > remaining) {
              excerpt = excerpt.substring(0, remaining);
              packetCapTruncations++;
            }
            totalChars += excerpt.length;
          } else {
            unreadableDocuments++;
          }
        } else {
          budgetMetadataOnlyDocuments++;
        }
        contextDocs.add(
          ProjectSummaryContextDoc(
            id: doc.id,
            title: doc.title,
            extension: doc.extension,
            evidenceCategory: ranked.category,
            excerpt: excerpt,
            storedPath: doc.storedPath,
            canOpenInExplorer: _canOpenSummaryDocument(doc),
            rank: index + 1,
            score: ranked.score,
            selectionReason: ranked.reason,
          ),
        );
      }
      if (contextDocs.isNotEmpty &&
          contextDocs.every((doc) => !doc.hasExcerpt)) {
        warnings.add(
          'No readable excerpts available from linked Library documents.',
        );
      }
      if (unreadableDocuments > 0) {
        warnings.add(
          '$unreadableDocuments linked document(s) had no readable excerpt; metadata only.',
        );
      }
      if (documentCapTruncations > 0) {
        warnings.add(
          '$documentCapTruncations document excerpt(s) truncated at $_projectSummaryMaxCharsPerDoc chars.',
        );
      }
      if (packetCapTruncations > 0 || budgetMetadataOnlyDocuments > 0) {
        final metadataOnlyDetail = budgetMetadataOnlyDocuments > 0
            ? '; $budgetMetadataOnlyDocuments lower-ranked document(s) metadata only.'
            : '.';
        warnings.add(
          'Excerpt budget reached at $_projectSummaryMaxTotalDocChars chars'
          '$metadataOnlyDetail',
        );
      }
    }

    final context = ProjectSummaryContext(
      id: projectId,
      title: proj?.title ?? projectId,
      description: proj?.description,
      desiredOutcome: proj?.desiredOutcome,
      successCriteria: proj?.successCriteria,
      status: proj?.status ?? 'active',
      phase: proj?.phase,
      priority: proj?.priority,
      owner: proj?.owner,
      workItems: items
          .map(
            (i) => ProjectSummaryContextWorkItem(
              id: i.id,
              title: i.title,
              status: i.status,
              priority: i.priority,
              owner: i.owner,
              blockedReason: i.blockedReason,
              dueAt: i.dueAt,
            ),
          )
          .toList(),
      people: people
          .map(
            (p) => ProjectSummaryContextPerson(
              id: p.id,
              name: p.name,
              role: p.role,
              authority: p.authority,
            ),
          )
          .toList(),
      risks: risks
          .map(
            (r) => ProjectSummaryContextRisk(
              id: r.id,
              title: r.title,
              severity: r.severity,
              description: r.desc,
            ),
          )
          .toList(),
      decisions: decisions
          .map(
            (d) => ProjectSummaryContextDecision(
              id: d.id,
              title: d.title,
              context: d.ctx,
              decider: d.decider,
            ),
          )
          .toList(),
      documents: contextDocs,
    );

    return ProjectSummaryEvidencePacket(
      context: context,
      includeLibrary: resolvedIncludeLibrary,
      suppliedDocumentCount: suppliedDocs.length,
      maxExcerptCharsPerDoc: _projectSummaryMaxCharsPerDoc,
      maxTotalExcerptChars: _projectSummaryMaxTotalDocChars,
      warnings: warnings,
    );
  }

  ({String category, String reason, int score})
  _projectSummaryDocumentClassification(Document doc) {
    final category = _projectSummaryEvidenceCategory(doc);
    var score =
        _projectSummaryCategoryWeights[category] ??
        _projectSummaryCategoryWeights['other']!;
    final ext = doc.extension?.toLowerCase();

    if (_projectSummaryTextExtensions.contains(ext)) score += 80;
    if (const {'pdf', 'docx', 'doc'}.contains(ext)) score += 25;
    if (_projectSummarySourceExtensions.contains(ext)) score += 15;
    if (_hasStoredSummaryText(doc)) score += 35;
    if ((doc.source ?? '').toLowerCase().contains('local_project')) {
      score += 20;
    }

    return (
      category: category,
      reason: _projectSummaryDocumentReason(category),
      score: score,
    );
  }

  String _projectSummaryEvidenceCategory(Document doc) {
    final identity = _summaryDocumentIdentity(doc);
    final normalized = identity.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    bool has(String needle) {
      final token = needle.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
      return normalized.contains(token);
    }

    final ext = doc.extension?.toLowerCase();
    if (has('active_task')) return 'active_task';
    if (has('current_state')) return 'current_state';
    if (has('handoff')) return 'handoff';
    if (has('readme')) return 'readme';
    if (has('acceptance')) return 'acceptance';
    if (has('operations')) return 'operations';
    if (has('roadmap')) return 'roadmap';
    if (has('requirements') || has('spec')) return 'requirements';
    if (has('changelog') || has('change_log') || has('history')) {
      return 'change_history';
    }
    if (has('agents') || has('agent') || has('claude')) {
      return 'agent_guidance';
    }
    if (_projectSummarySourceExtensions.contains(ext)) return 'source';
    if (_projectSummaryTextExtensions.contains(ext) ||
        _hasStoredSummaryText(doc)) {
      return 'text';
    }
    if (ext != null && ext.isNotEmpty) return 'binary';
    return 'other';
  }

  String _projectSummaryDocumentReason(String category) {
    switch (category) {
      case 'active_task':
        return 'active task';
      case 'current_state':
        return 'current state';
      case 'handoff':
        return 'handoff';
      case 'readme':
        return 'project readme';
      case 'acceptance':
        return 'acceptance criteria';
      case 'operations':
        return 'operations note';
      case 'roadmap':
        return 'roadmap';
      case 'requirements':
        return 'requirements/spec';
      case 'change_history':
        return 'change history';
      case 'agent_guidance':
        return 'agent guidance';
      case 'source':
        return 'source-like document';
      case 'text':
        return 'text document';
      case 'binary':
        return 'binary or metadata-only document';
      default:
        return 'linked Library document';
    }
  }

  String _summaryDocumentIdentity(Document doc) =>
      '${doc.title} ${doc.originalFilename}'.toLowerCase();

  bool _hasStoredSummaryText(Document doc) =>
      (doc.extractedText ?? doc.renderedMarkdown)?.trim().isNotEmpty == true;

  bool _canOpenSummaryDocument(Document doc) =>
      doc.storedPath != null &&
      doc.storedPath!.isNotEmpty &&
      const [
        'md',
        'txt',
        'json',
        'csv',
        'pdf',
        'docx',
        'doc',
      ].contains(doc.extension?.toLowerCase());

  /// Generates summaries for operational projects that are missing one today.
  /// Runs silently in the background — errors are swallowed per project.
  Future<ProjectSummaryRefreshResult> refreshMissingProjectSummaries({
    bool force = false,
    bool? includeLibrary,
    Duration betweenProjects = const Duration(seconds: 3),
    ProjectEnrichmentStatusCallback? onStatus,
  }) async {
    if (!projectAiSummariesEnabled) {
      onStatus?.call(
        'Project AI summaries are disabled in Settings.',
        current: 0,
        total: 0,
      );
      return const ProjectSummaryRefreshResult(
        considered: 0,
        refreshed: 0,
        skipped: 0,
        failed: 0,
        aiUnavailable: false,
        errors: ['Project AI summaries are disabled in Settings.'],
      );
    }
    if (!projectAiSummaryAllowBulkRefresh) {
      onStatus?.call(
        'Project AI bulk refresh is disabled in Settings.',
        current: 0,
        total: 0,
      );
      return const ProjectSummaryRefreshResult(
        considered: 0,
        refreshed: 0,
        skipped: 0,
        failed: 0,
        aiUnavailable: false,
        errors: ['Project AI bulk refresh is disabled in Settings.'],
      );
    }
    if (_summaryRefreshRunning) {
      return const ProjectSummaryRefreshResult(
        considered: 0,
        refreshed: 0,
        skipped: 0,
        failed: 0,
        aiUnavailable: false,
        alreadyRunning: true,
        errors: ['Project summary refresh is already running.'],
      );
    }
    _summaryRefreshRunning = true;
    notifyListeners();
    var considered = 0;
    var refreshed = 0;
    var skipped = 0;
    var failed = 0;
    var aiUnavailable = false;
    final errors = <String>[];
    final resolvedIncludeLibrary =
        includeLibrary ?? projectAiSummaryIncludeLibrary;
    try {
      onStatus?.call('Checking Ollama summary service.', current: 0);
      final host = await getSetting(AppDb.kOllamaHost);
      final model = await _projectSummaryModelSetting();
      if (!await _buildOllama(host, model).isAvailable()) {
        aiUnavailable = true;
        onStatus?.call('AI summary refresh skipped: Ollama unavailable.');
        await db.logEvent(
          level: 'warn',
          area: 'ai',
          action: 'project_summary_refresh_skipped',
          outputJson: jsonEncode({'reason': 'ollama_unavailable'}),
        );
        return ProjectSummaryRefreshResult(
          considered: considered,
          refreshed: refreshed,
          skipped: skipped,
          failed: failed,
          aiUnavailable: aiUnavailable,
          errors: errors,
        );
      }
      final projects = await db.getSummaryEligibleProjects();
      onStatus?.call(
        projects.isEmpty
            ? 'No summary-eligible projects found.'
            : 'Refreshing AI summaries for ${projects.length} projects.',
        current: 0,
        total: projects.length,
      );
      for (final project in projects) {
        considered++;
        onStatus?.call(
          'Summarizing ${project.title} ($considered/${projects.length}).',
          current: considered,
          total: projects.length,
        );
        if (!force && await db.hasTodayProjectSummaryDraft(project.id)) {
          skipped++;
          onStatus?.call(
            'Skipped ${project.title}: summary exists today.',
            current: considered,
            total: projects.length,
          );
          continue;
        }
        try {
          final outcome = await summarizeProjectFull(
            project.id,
            includeLibrary: resolvedIncludeLibrary,
            trigger: 'bulk_refresh',
          );
          if (outcome.isSuccess) {
            refreshed++;
            onStatus?.call(
              'Summary refreshed for ${project.title}.',
              current: considered,
              total: projects.length,
            );
          } else {
            failed++;
            errors.add('${project.title}: summary returned no output');
            onStatus?.call(
              'Summary failed for ${project.title}: no output.',
              current: considered,
              total: projects.length,
            );
          }
        } catch (error) {
          failed++;
          errors.add('${project.title}: $error');
          onStatus?.call(
            'Summary failed for ${project.title}: $error',
            current: considered,
            total: projects.length,
          );
        }
        // Yield between projects to avoid locking up Ollama.
        if (betweenProjects > Duration.zero) {
          await Future<void>.delayed(betweenProjects);
        }
      }
      onStatus?.call(
        'AI summaries complete: $refreshed refreshed, $failed failed, $skipped skipped.',
        current: projects.length,
        total: projects.length,
      );
      await db.logEvent(
        area: 'ai',
        action: 'project_summary_refresh_completed',
        outputJson: jsonEncode({
          'considered': considered,
          'refreshed': refreshed,
          'skipped': skipped,
          'failed': failed,
          'force': force,
          'includeLibrary': resolvedIncludeLibrary,
        }),
      );
      return ProjectSummaryRefreshResult(
        considered: considered,
        refreshed: refreshed,
        skipped: skipped,
        failed: failed,
        aiUnavailable: aiUnavailable,
        errors: errors,
      );
    } finally {
      _summaryRefreshRunning = false;
      notifyListeners();
    }
  }

  // Project AI summary (with optional library context)
  Future<ProjectSummaryOutcome> summarizeProjectFull(
    String projectId, {
    bool? includeLibrary,
    ProjectSummaryEvidencePacket? evidencePacket,
    String trigger = 'manual',
  }) async {
    if (!projectAiSummariesEnabled) {
      throw StateError('Project AI summaries are disabled in Settings.');
    }
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await _projectSummaryModelSetting();
    final svc = _buildOllama(host, model);
    final packet =
        evidencePacket ??
        await buildProjectSummaryEvidencePacket(
          projectId,
          includeLibrary: includeLibrary,
        );
    final context = packet.context;
    final items = await getWorkItemsForProject(projectId);
    final correlationId =
        'project_summary_${DateTime.now().microsecondsSinceEpoch}';

    await db.logEvent(
      area: 'ai',
      action: 'project_summary_started',
      entityType: 'project_summary',
      entityId: projectId,
      correlationId: correlationId,
      inputJson: jsonEncode(packet.toLogJson(model: model, trigger: trigger)),
    );

    ProjectSummaryOutcome outcome;
    var usedFallback = false;
    try {
      final (:result, :parsed, :validation) = await svc
          .summarizeProjectStructured(context: context);
      outcome = ProjectSummaryOutcome(
        rawOutput: result.output,
        inputText: result.input,
        structured: parsed,
        validationIssues: validation.issues,
        documentPaths: packet.documentPaths,
      );
    } catch (e) {
      usedFallback = true;
      // Fall back to old prose summary on unexpected error
      final blocked = items
          .where((i) => i.blockedReason != null)
          .map((i) => '${i.title} — ${i.blockedReason}')
          .toList();
      final active = items
          .where((i) => !['done', 'archived'].contains(i.status))
          .map((i) => i.title)
          .toList();
      final done = items
          .where((i) => i.status == 'done')
          .map((i) => i.title)
          .take(5)
          .toList();
      final oldResult = await svc.summarizeProject(
        projectTitle: context.title,
        activeItems: active,
        blockedItems: blocked,
        completedRecently: done,
      );
      outcome = ProjectSummaryOutcome(
        rawOutput: oldResult.output,
        inputText: oldResult.input,
        documentPaths: packet.documentPaths,
      );
    }

    String? draftId;
    // Persist as a draft so the project detail screen can load instantly next time.
    if (outcome.isSuccess) {
      try {
        // Replace any existing summary drafts for this project.
        await db.deleteProjectSummaryDrafts(projectId);
        draftId = await db.saveDraft(
          kind: 'project_summary',
          title: 'Project Summary - ${context.title}',
          body: outcome.rawOutput ?? '',
          inputJson: outcome.inputText,
          projectId: projectId,
        );
      } catch (error) {
        await db.logEvent(
          level: 'error',
          area: 'ai',
          action: 'project_summary_draft_save_failed',
          entityType: 'project_summary',
          entityId: projectId,
          correlationId: correlationId,
          error: error.toString(),
          outputJson: jsonEncode({
            'agent': 'atlas',
            'projectId': projectId,
            'model': model,
            'trigger': trigger,
          }),
        );
      }
    }

    final validationCodes = outcome.validationIssues
        .map((issue) => issue.code)
        .toList(growable: false);
    await db.logEvent(
      level: outcome.isSuccess ? 'info' : 'warn',
      area: 'ai',
      action: outcome.isSuccess
          ? 'project_summary_draft_saved'
          : 'project_summary_failed',
      entityType: 'project_summary',
      entityId: projectId,
      correlationId: correlationId,
      outputJson: jsonEncode({
        'agent': 'atlas',
        'actor': {'kind': 'app', 'id': 'atlas', 'displayName': 'Atlas'},
        'projectId': projectId,
        'projectTitle': context.title,
        'model': model,
        'trigger': trigger,
        'draftId': draftId,
        'success': outcome.isSuccess,
        'fallback': usedFallback,
        'hasStructured': outcome.hasStructured,
        'validationIssueCodes': validationCodes,
        'rawOutputChars': outcome.rawOutput?.length ?? 0,
        'evidence': packet.toLogJson(model: model, trigger: trigger),
      }),
    );
    return outcome;
  }

  /// Read raw text from a document, trying in order:
  /// 1. extractedText, 2. renderedMarkdown, 3. disk read for text-like files.
  Future<String?> _readDocumentText(Document doc) async {
    String? clean(String? s) {
      if (s == null || s.trim().isEmpty) return null;
      return s;
    }

    final fromExtracted = clean(doc.extractedText);
    if (fromExtracted != null) return fromExtracted;

    final fromMarkdown = clean(doc.renderedMarkdown);
    if (fromMarkdown != null) return fromMarkdown;

    final path = doc.storedPath;
    final ext = doc.extension?.toLowerCase();
    if (path != null &&
        path.isNotEmpty &&
        _projectSummaryTextExtensions.contains(ext)) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final text = await file.readAsString();
          return clean(text);
        }
      } catch (e) {
        debugPrint('[Atlas] _readDocumentText: failed to read document from disk at $path (continuing): $e');
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Documents
  // ---------------------------------------------------------------------------

  Stream<List<Document>> watchDocuments() => db.watchDocuments();

  Future<void> importDocumentFromPath(String path, {String? projectId}) async {
    try {
      await db.logEvent(
        area: 'documents',
        action: 'import_request',
        inputJson: path,
      );
      await db.importDocumentFromPath(
        path,
        projectId: projectId ?? activeProject?.id,
      );
    } catch (e, st) {
      await db.logError(
        area: 'documents',
        action: 'import_failed',
        error: e,
        stackTrace: st,
        inputJson: path,
      );
      rethrow;
    }
  }

  Stream<List<Document>> watchDocumentsForWorkItem(String workItemId) =>
      db.watchDocumentsForWorkItem(workItemId);

  Future<void> linkDocumentToWorkItem(
    String documentId,
    String workItemId,
  ) async {
    await db.linkDocumentToWorkItem(documentId, workItemId);
    await db.logEvent(
      area: 'documents',
      action: 'document_linked',
      entityType: 'work_item',
      entityId: workItemId,
      inputJson: jsonEncode({'documentId': documentId}),
    );
  }

  Future<void> unlinkDocumentFromWorkItem(
    String documentId,
    String workItemId,
  ) async {
    await db.unlinkDocumentFromWorkItem(documentId, workItemId);
    await db.logEvent(
      area: 'documents',
      action: 'document_unlinked',
      entityType: 'work_item',
      entityId: workItemId,
      inputJson: jsonEncode({'documentId': documentId}),
    );
  }

  Stream<List<WorkItemNote>> watchNotesForWorkItem(String workItemId) =>
      db.watchNotesForWorkItem(workItemId);

  Future<void> addWorkItemNote(String workItemId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    await db.addWorkItemNote(workItemId, trimmed);
    await db.logEvent(
      area: 'work_item_detail',
      action: 'note_created',
      entityType: 'work_item',
      entityId: workItemId,
    );
  }

  Future<void> updateWorkItemNote(String noteId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    await db.updateWorkItemNote(noteId, trimmed);
    await db.logEvent(
      area: 'work_item_detail',
      action: 'note_updated',
      entityType: 'work_item_note',
      entityId: noteId,
    );
  }

  Future<void> deleteWorkItemNote(String noteId) async {
    await db.deleteWorkItemNote(noteId);
    await db.logEvent(
      area: 'work_item_detail',
      action: 'note_deleted',
      entityType: 'work_item_note',
      entityId: noteId,
    );
  }

  Stream<List<WorkItemAnalysis>> watchAnalysesForWorkItem(String workItemId) =>
      db.watchAnalysesForWorkItem(workItemId);

  Future<OllamaResult> analyzeWorkItemReadOnly(String workItemId) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final modelName = model?.trim().isNotEmpty == true
        ? model!.trim()
        : 'qwen3.5:9b';
    final svc = _buildOllama(host, modelName);
    final item = await getWorkItem(workItemId);
    if (item == null) {
      await db.logEvent(
        level: 'error',
        area: 'work_item_detail',
        action: 'analysis_missing_work_item',
        entityType: 'work_item',
        entityId: workItemId,
      );
      return const OllamaResult(
        input: 'Missing work item',
        output: null,
        kind: 'work_item_analysis',
        title: 'Work Item Analysis',
      );
    }

    final docs = await db.getDocumentsForWorkItem(workItemId);
    final linkedDocuments = docs
        .map(
          (d) => LinkedDocumentContext(
            title: d.title,
            text: d.extractedText ?? d.renderedMarkdown ?? '',
          ),
        )
        .toList(growable: false);

    try {
      await db.logEvent(
        area: 'ollama',
        action: 'work_item_analysis_requested',
        entityType: 'work_item',
        entityId: workItemId,
        inputJson: jsonEncode({
          'model': modelName,
          'documentCount': docs.length,
        }),
      );
      final result = await svc.analyzeWorkItemReadOnly(
        title: item.title,
        description: item.description,
        status: item.status,
        priority: item.priority,
        blockedReason: item.blockedReason,
        linkedDocuments: linkedDocuments,
      );
      if (result.isSuccess) {
        await db.saveWorkItemAnalysis(
          workItemId: workItemId,
          prompt: result.input,
          output: result.output!,
          model: modelName,
        );
        await db.logEvent(
          area: 'ollama',
          action: 'work_item_analysis_saved',
          entityType: 'work_item',
          entityId: workItemId,
          outputJson: jsonEncode({'model': modelName}),
        );
      } else {
        await db.logEvent(
          level: 'error',
          area: 'ollama',
          action: 'work_item_analysis_empty',
          entityType: 'work_item',
          entityId: workItemId,
          inputJson: result.input,
        );
      }
      return result;
    } catch (e, st) {
      await db.logError(
        area: 'ollama',
        action: 'work_item_analysis_failed',
        entityType: 'work_item',
        entityId: workItemId,
        inputJson: item.title,
        error: e,
        stackTrace: st,
      );
      return OllamaResult(
        input: item.title,
        output: 'Ollama request failed: $e',
        kind: 'work_item_analysis',
        title: 'Work Item Analysis',
      );
    }
  }

  Stream<List<EventLogData>> watchRecentEvents() => db.watchRecentEvents();
  Future<List<EventLogData>> getRecentEvents() => db.getRecentEvents();
  Future<void> clearEventLog() => db.clearEventLog();

  Future<List<EventLogData>> getProjectEventLogs(
    String projectId, {
    DateTime? since,
    int limit = 500,
    bool includeRelatedWorkItems = true,
    bool newestFirst = true,
  }) async {
    final relatedWorkItemIds = includeRelatedWorkItems
        ? (await db.getWorkItemsForProject(
            projectId,
          )).map((item) => item.id).toSet()
        : const <String>{};
    final cap = limit <= 0 ? 500 : limit;
    final events = await db.getRecentEvents();
    final filtered = events
        .where((event) {
          if (since != null && event.timestamp.isBefore(since)) {
            return false;
          }
          if (event.entityId == projectId) return true;
          if (includeRelatedWorkItems &&
              event.entityType == 'work_item' &&
              event.entityId != null &&
              relatedWorkItemIds.contains(event.entityId)) {
            return true;
          }
          return _eventPayloadMentionsProject(event, projectId);
        })
        .toList(growable: true);
    filtered.sort((a, b) {
      final comparison = a.timestamp.compareTo(b.timestamp);
      return newestFirst ? -comparison : comparison;
    });
    return filtered.take(cap).toList(growable: false);
  }

  Future<List<ProjectChangeLogEntry>> getProjectChangeLog(
    String projectId, {
    DateTime? since,
    int limit = 200,
    bool includeRelatedWorkItems = true,
    bool newestFirst = true,
  }) async {
    final workItems = includeRelatedWorkItems
        ? await db.getWorkItemsForProject(projectId)
        : const <WorkItem>[];
    final workItemTitles = {for (final item in workItems) item.id: item.title};
    final events = await getProjectEventLogs(
      projectId,
      since: since,
      limit: limit,
      includeRelatedWorkItems: includeRelatedWorkItems,
      newestFirst: newestFirst,
    );
    return events
        .map(
          (event) => _projectChangeFromEvent(
            projectId: projectId,
            event: event,
            workItemTitles: workItemTitles,
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, Object?>> buildProjectChangeSummaryEvidencePacket(
    String projectId, {
    DateTime? since,
    int limit = 200,
  }) async {
    final changes = await getProjectChangeLog(
      projectId,
      since: since,
      limit: limit,
    );
    return _projectChangeSummaryEvidencePacket(
      projectId: projectId,
      changes: changes,
      since: since,
      limit: limit,
    );
  }

  Future<Map<String, Object?>> _projectChangeSummaryEvidencePacket({
    required String projectId,
    required List<ProjectChangeLogEntry> changes,
    required DateTime? since,
    required int limit,
  }) async {
    final project = await db.getProjectFull(projectId);
    return {
      'schema': 'project_change_summary_evidence_packet_v1',
      'generatedAt': DateTime.now().toIso8601String(),
      'project': {'id': projectId, 'title': project?.title ?? projectId},
      'window': {'since': since?.toIso8601String(), 'limit': limit},
      'changeCount': changes.length,
      'changes': changes.map((entry) => entry.toJson()).toList(),
    };
  }

  Map<String, Object?> _projectChangeSummaryPromptEvidencePacket(
    Map<String, Object?> evidence,
  ) {
    final changes = evidence['changes'];
    return {
      'schema': 'project_change_summary_prompt_evidence_packet_v1',
      'generatedAt': evidence['generatedAt'],
      'project': evidence['project'],
      'window': evidence['window'],
      'changeCount': evidence['changeCount'],
      'changes': changes is Iterable
          ? changes
                .whereType<Map>()
                .map((raw) {
                  final entry = raw.map(
                    (key, value) => MapEntry('$key', value),
                  );
                  return {
                    'timestamp': entry['timestamp'],
                    'actor': entry['actor'],
                    'actorType': entry['actorType'],
                    'area': entry['area'],
                    'action': entry['action'],
                    'entityType': entry['entityType'],
                    'entityId': entry['entityId'],
                    'summary': entry['summary'],
                    'changedFields': entry['changedFields'],
                    'error': entry['error'],
                    'correlationId': entry['correlationId'],
                  };
                })
                .toList(growable: false)
          : const [],
    };
  }

  Future<OllamaResult> summarizeProjectChanges(
    String projectId, {
    DateTime? since,
    int limit = 80,
    String trigger = 'manual',
  }) async {
    if (!projectAiSummariesEnabled) {
      throw StateError('Project AI summaries are disabled in Settings.');
    }
    final project = await db.getProjectFull(projectId);
    if (project == null) {
      throw StateError('Project not found: $projectId');
    }
    final changes = await getProjectChangeLog(
      projectId,
      since: since,
      limit: limit,
    );
    if (changes.isEmpty) {
      throw StateError('No project changes matched the selected window.');
    }

    final host = await getSetting(AppDb.kOllamaHost);
    final model = await _projectSummaryModelSetting();
    final svc = _buildOllama(host, model);
    final evidence = await _projectChangeSummaryEvidencePacket(
      projectId: projectId,
      changes: changes,
      since: since,
      limit: limit,
    );
    final promptEvidence = _projectChangeSummaryPromptEvidencePacket(evidence);
    final correlationId =
        'project_change_summary_${DateTime.now().microsecondsSinceEpoch}';
    final inputPacket = <String, Object?>{
      'schema': 'project_change_summary_draft_input_v1',
      'model': model,
      'trigger': trigger,
      'evidence': evidence,
      'promptEvidence': promptEvidence,
    };

    await db.logEvent(
      area: 'ai',
      action: 'project_change_summary_started',
      entityType: 'project_change_summary',
      entityId: projectId,
      correlationId: correlationId,
      inputJson: jsonEncode(inputPacket),
    );

    final result = await svc.summarizeProjectChanges(
      projectTitle: project.title,
      evidencePacket: promptEvidence,
    );

    String? draftId;
    if (result.isSuccess) {
      final draftInput = <String, Object?>{
        ...inputPacket,
        'prompt': result.input,
      };
      draftId = await db.saveDraft(
        kind: 'project_change_summary',
        title: 'Project Change Summary - ${project.title}',
        body: result.output ?? '',
        inputJson: const JsonEncoder.withIndent('  ').convert(draftInput),
        projectId: projectId,
      );
      notifyListeners();
    }

    await db.logEvent(
      level: result.isSuccess ? 'info' : 'warn',
      area: 'ai',
      action: result.isSuccess
          ? 'project_change_summary_draft_saved'
          : 'project_change_summary_failed',
      entityType: 'project_change_summary',
      entityId: projectId,
      correlationId: correlationId,
      outputJson: jsonEncode({
        'agent': 'atlas',
        'actor': {'kind': 'app', 'id': 'atlas', 'displayName': 'Atlas'},
        'projectId': projectId,
        'projectTitle': project.title,
        'model': model,
        'trigger': trigger,
        'draftId': draftId,
        'success': result.isSuccess,
        'changeCount': changes.length,
        'rawOutputChars': result.output?.length ?? 0,
        'evidence': evidence,
      }),
    );

    return result;
  }

  Future<OllamaResult> startProjectChangeSummary(
    String projectId, {
    DateTime? since,
    int limit = 80,
    String trigger = 'manual',
  }) {
    final existing = _projectChangeSummaryRuns[projectId];
    if (existing != null) return existing;

    final startedAt = DateTime.now();
    _projectChangeSummaryRunStatuses[projectId] = ProjectChangeSummaryRunStatus(
      projectId: projectId,
      startedAt: startedAt,
      isRunning: true,
    );
    notifyListeners();

    final future = () async {
      try {
        final result = await summarizeProjectChanges(
          projectId,
          since: since,
          limit: limit,
          trigger: trigger,
        );
        final completedAt = DateTime.now();
        _projectChangeSummaryRunStatuses[projectId] =
            ProjectChangeSummaryRunStatus(
              projectId: projectId,
              startedAt: startedAt,
              completedAt: completedAt,
              isRunning: false,
              output: result.isSuccess ? result.output : null,
              error: result.isSuccess
                  ? null
                  : _projectChangeSummaryFailureMessage(result),
            );
        return result;
      } catch (error) {
        final completedAt = DateTime.now();
        _projectChangeSummaryRunStatuses[projectId] =
            ProjectChangeSummaryRunStatus(
              projectId: projectId,
              startedAt: startedAt,
              completedAt: completedAt,
              isRunning: false,
              error: '$error',
            );
        rethrow;
      } finally {
        _projectChangeSummaryRuns.remove(projectId);
        notifyListeners();
      }
    }();

    _projectChangeSummaryRuns[projectId] = future;
    return future;
  }

  String _projectChangeSummaryFailureMessage(OllamaResult result) {
    final output = result.output?.trim();
    if (output == null || output.isEmpty) return 'No output from model.';
    return output;
  }

  ProjectChangeLogEntry _projectChangeFromEvent({
    required String projectId,
    required EventLogData event,
    required Map<String, String> workItemTitles,
  }) {
    final input = _decodeJsonMap(event.inputJson);
    final output = _decodeJsonMap(event.outputJson);
    final changedFields = _extractChangedFields(output);
    final before = _beforeValuesFromChangedFields(changedFields);
    final after = _afterValuesFromChangedFields(changedFields);
    final actor = _actorFromEventPayload(event, input, output);
    final actorType = _actorTypeFromEventPayload(event, input, output, actor);
    final entityLabel =
        event.entityType == 'work_item' && event.entityId != null
        ? workItemTitles[event.entityId!]
        : null;
    return ProjectChangeLogEntry(
      id: 'change_${event.id}',
      sourceEventId: event.id,
      projectId: projectId,
      timestamp: event.timestamp,
      level: event.level,
      actor: actor,
      actorType: actorType,
      area: event.area,
      action: event.action,
      entityType: event.entityType,
      entityId: event.entityId,
      summary: _changeSummaryForEvent(
        event,
        changedFields: changedFields,
        entityLabel: entityLabel,
      ),
      changedFields: changedFields,
      beforeJson: before,
      afterJson: after,
      input: input,
      output: output,
      error: event.error,
      stackTrace: event.stackTrace,
      correlationId: event.correlationId,
    );
  }

  Map<String, Object?> _decodeJsonMap(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } catch (e) {
      debugPrint('[Atlas] _decodeJsonMap: JSON parse of map failed (continuing): $e');
    }
    return {'raw': raw};
  }

  Map<String, Object?> _extractChangedFields(Map<String, Object?> output) {
    final raw = output['changedFields'];
    if (raw is! Map) return const <String, Object?>{};
    return Map<String, Object?>.from(raw);
  }

  Map<String, Object?> _beforeValuesFromChangedFields(
    Map<String, Object?> changedFields,
  ) {
    final values = <String, Object?>{};
    for (final entry in changedFields.entries) {
      final diff = entry.value;
      if (diff is Map && diff.containsKey('from')) {
        values[entry.key] = diff['from'];
      }
    }
    return values;
  }

  Map<String, Object?> _afterValuesFromChangedFields(
    Map<String, Object?> changedFields,
  ) {
    final values = <String, Object?>{};
    for (final entry in changedFields.entries) {
      final diff = entry.value;
      if (diff is Map && diff.containsKey('to')) {
        values[entry.key] = diff['to'];
      }
    }
    return values;
  }

  String _actorFromEventPayload(
    EventLogData event,
    Map<String, Object?> input,
    Map<String, Object?> output,
  ) {
    final actor = output['actor'] ?? input['actor'];
    final actorName = _actorName(actor);
    if (actorName != null) return actorName;
    final agent = _cleanNullableString(output['agent'] ?? input['agent']);
    if (agent != null) return agent;
    if (event.area == 'mcp') return 'MCP';
    if (event.area == 'ollama' || event.action.contains('summary')) {
      return 'Atlas AI';
    }
    if (event.area == 'github') return 'GitHub';
    if (event.area == 'operations' || event.area == 'local_operations') {
      return 'Atlas';
    }
    return 'Operator';
  }

  String? _actorName(Object? actor) {
    if (actor is String && actor.trim().isNotEmpty) return actor.trim();
    if (actor is Map) {
      final displayName =
          actor['displayName']?.toString() ?? actor['name']?.toString();
      if (displayName != null && displayName.trim().isNotEmpty) {
        return displayName.trim();
      }
    }
    return null;
  }

  String _actorTypeFromEventPayload(
    EventLogData event,
    Map<String, Object?> input,
    Map<String, Object?> output,
    String actor,
  ) {
    final rawActor = output['actor'] ?? input['actor'];
    if (rawActor is Map) {
      final rawType =
          rawActor['actorType']?.toString() ??
          rawActor['type']?.toString() ??
          rawActor['kind']?.toString();
      final normalized = _normalizeChangeActorType(rawType);
      if (normalized != null) return normalized;
    }
    if (event.area == 'mcp') return 'mcp';
    if (event.area == 'ollama' || event.action.contains('summary')) {
      return 'ai_model';
    }
    if (event.area == 'operations' || event.area == 'local_operations') {
      return 'import';
    }
    final fromLabel = _normalizeChangeActorType(_actorTypeForLabel(actor));
    return fromLabel ?? 'operator';
  }

  String? _normalizeChangeActorType(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    return switch (normalized) {
      'ai' || 'model' || 'ai_model' => 'ai_model',
      'app' || 'atlas' || 'system' => 'system',
      'mcp' => 'mcp',
      'import' || 'local_operations' || 'operations' => 'import',
      'operator' || 'user' => 'operator',
      _ => 'operator',
    };
  }

  String _changeSummaryForEvent(
    EventLogData event, {
    required Map<String, Object?> changedFields,
    String? entityLabel,
  }) {
    final action = _humanizeIdentifier(event.action);
    if (event.level == 'error') {
      return '$action failed${event.error == null ? '' : ': ${event.error}'}';
    }
    if (changedFields.isNotEmpty) {
      final fields = changedFields.keys.map(_humanizeIdentifier).join(', ');
      return '$action: $fields';
    }
    if (entityLabel != null && entityLabel.trim().isNotEmpty) {
      return '$action: $entityLabel';
    }
    return action;
  }

  String _humanizeIdentifier(String value) {
    final spaced = value
        .replaceAll('_', ' ')
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match.group(1)} ${match.group(2)}',
        )
        .trim()
        .toLowerCase();
    if (spaced.isEmpty) return value;
    return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
  }

  Future<String> getAppDataPath() async {
    final supportDir = await getApplicationSupportDirectory();
    final docsDir = p.join(
      (await getApplicationDocumentsDirectory()).path,
      'atlas_documents',
    );
    return '${supportDir.path}\n$docsDir';
  }

  Future<void> openAppDataFolder() async {
    final supportDir = await getApplicationSupportDirectory();
    await Process.start('explorer.exe', [supportDir.path]);
    final docsDir = Directory(
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        'atlas_documents',
      ),
    );
    if (docsDir.existsSync()) {
      await Process.start('explorer.exe', [docsDir.path]);
    }
  }

  Future<int> exportOperationalBackupToJson(String path) async {
    final allDocs = await db.select(db.documents).get();
    final allMedia = await db.getAllProjectMedia();

    final payload = {
      'schema': 'project_atlas_operational_backup_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'projects': (await db.select(db.projects).get())
          .map((row) => row.toJson())
          .toList(),
      'tags': (await db.getTags()).map((row) => row.toJson()).toList(),
      'projectTags': (await db.select(db.projectTags).get())
          .map((row) => row.toJson())
          .toList(),
      'projectMedia': allMedia.map((row) => row.toJson()).toList(),
      'stages': (await db.select(db.stages).get())
          .map((row) => row.toJson())
          .toList(),
      'workItems': (await db.select(db.workItems).get())
          .map((row) => row.toJson())
          .toList(),
      'workItemNotes': (await db.select(db.workItemNotes).get())
          .map((row) => row.toJson())
          .toList(),
      'workItemAnalyses': (await db.select(db.workItemAnalyses).get())
          .map((row) => row.toJson())
          .toList(),
      'documents': allDocs.map((row) => row.toJson()).toList(),
      'documentLinks': (await db.select(db.documentLinks).get())
          .map((row) => row.toJson())
          .toList(),
      'contacts': (await db.getContacts()).map((row) => row.toJson()).toList(),
      'projectPeople': (await db.select(db.projectPeople).get())
          .map((row) => row.toJson())
          .toList(),
      'projectRisks': (await db.select(db.projectRisks).get())
          .map((row) => row.toJson())
          .toList(),
      'projectDecisions': (await db.select(db.projectDecisions).get())
          .map((row) => row.toJson())
          .toList(),
      'projectRegistry': (await db.select(db.projectRegistry).get())
          .map((row) => row.toJson())
          .toList(),
      'projectScanRuns': (await db.select(db.projectScanRuns).get())
          .map((row) => row.toJson())
          .toList(),
      'projectObservations': (await db.select(db.projectObservations).get())
          .map((row) => row.toJson())
          .toList(),
      'dailyReviews': (await db.select(db.dailyReviews).get())
          .map((row) => row.toJson())
          .toList(),
      'outboxMessages': (await db.select(db.outboxMessages).get())
          .map((row) => row.toJson())
          .toList(),
    };

    final archive = Archive();

    // Add backup.json
    final jsonBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    archive.addFile(ArchiveFile('backup.json', jsonBytes.length, jsonBytes));

    // Add document files
    for (final doc in allDocs) {
      if (doc.storedPath != null) {
        final f = File(doc.storedPath!);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          final name = 'documents/${doc.id}.${doc.extension ?? 'bin'}';
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }
      }
    }

    // Add project media files
    for (final m in allMedia) {
      final f = File(m.storedPath);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        final ext = m.extension ?? m.storedPath.split('.').lastOrNull ?? 'bin';
        archive.addFile(ArchiveFile('media/${m.id}.$ext', bytes.length, bytes));
      }
    }

    // Write ZIP
    final zipBytes = ZipEncoder().encode(archive)!;
    await File(path).writeAsBytes(zipBytes);

    await db.logEvent(
      area: 'backup',
      action: 'operational_backup_exported',
      outputJson: jsonEncode({'path': path}),
    );
    return payload.length;
  }

  Future<ProjectBundleExportPreview> previewProjectBundleExport(
    String projectId, {
    bool includeFiles = true,
    bool includeLatestSummary = false,
    bool includeEventLogs = false,
    bool includeChangeLog = false,
    DateTime? eventLogSince,
    bool includeCleanGitArchive = false,
    bool includeBootstrapContext = true,
  }) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) {
      throw StateError('Project not found: $projectId');
    }
    final stages = await db.getStagesForProject(projectId);
    final workItems = await db.getWorkItemsForProject(projectId);
    final workItemIds = workItems.map((item) => item.id).toList();
    final notes = workItemIds.isEmpty
        ? const <WorkItemNote>[]
        : await (db.select(
            db.workItemNotes,
          )..where((t) => t.workItemId.isIn(workItemIds))).get();
    final analyses = workItemIds.isEmpty
        ? const <WorkItemAnalysis>[]
        : await (db.select(
            db.workItemAnalyses,
          )..where((t) => t.workItemId.isIn(workItemIds))).get();
    final docs = await db.getDocumentsForProject(projectId);
    final media = await db.getProjectMedia(projectId);
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    final registries = await db.getProjectRegistryEntriesByAtlasProjectId(
      projectId,
    );
    final observations = registry == null
        ? const <ProjectObservation>[]
        : await (db.select(db.projectObservations)
                ..where((t) => t.observedPath.equals(registry.localPath))
                ..orderBy([(t) => OrderingTerm.desc(t.observedAt)]))
              .get();
    final refreshItems = registry == null
        ? const <LocalProjectRefreshItem>[]
        : await (db.select(
            db.localProjectRefreshItems,
          )..where((t) => t.registryId.equals(registry.id))).get();
    final latestSummary = includeLatestSummary
        ? await db.getLatestProjectSummaryDraft(projectId)
        : null;
    final latestChangeSummary = includeChangeLog
        ? await db.getLatestProjectChangeSummaryDraft(projectId)
        : null;
    final eventLogs = includeEventLogs
        ? await _projectBundleEventLogs(projectId, eventLogSince)
        : const <EventLogData>[];
    final changeLog = includeChangeLog
        ? await getProjectChangeLog(projectId, since: eventLogSince, limit: 500)
        : const <ProjectChangeLogEntry>[];
    var copiedDocumentFiles = 0;
    var copiedMediaFiles = 0;
    final warnings = <String>[];
    var cleanGitArchiveReady = false;
    if (includeFiles) {
      for (final doc in docs) {
        final storedPath = doc.storedPath;
        if (storedPath == null) continue;
        if (await File(storedPath).exists()) {
          copiedDocumentFiles++;
        } else {
          warnings.add('Document file missing: ${doc.originalFilename}');
        }
      }
      for (final item in media) {
        if (await File(item.storedPath).exists()) {
          copiedMediaFiles++;
        } else {
          warnings.add('Media file missing: ${item.originalFilename}');
        }
      }
    }
    if (includeLatestSummary && latestSummary == null) {
      warnings.add('No cached AI project summary is available.');
    }
    if (includeEventLogs && eventLogs.isEmpty) {
      warnings.add(
        'No project event logs matched the selected timestamp window.',
      );
    }
    if (includeChangeLog && changeLog.isEmpty) {
      warnings.add(
        'No normalized project changes matched the selected timestamp window.',
      );
    }
    if (includeCleanGitArchive) {
      cleanGitArchiveReady = await _projectGitArchiveIsReady(
        projectId,
        registries.isEmpty && registry != null ? [registry] : registries,
        warnings,
      );
    }

    return ProjectBundleExportPreview(
      schema: 'project_atlas_project_bundle_v1',
      projectId: projectId,
      projectTitle: project.title,
      includeFiles: includeFiles,
      includeLatestSummary: includeLatestSummary,
      includeEventLogs: includeEventLogs,
      includeChangeLog: includeChangeLog,
      includeCleanGitArchive: includeCleanGitArchive,
      includeBootstrapContext: includeBootstrapContext,
      stages: stages.length,
      workItems: workItems.length,
      workItemNotes: notes.length,
      workItemAnalyses: analyses.length,
      documents: docs.length,
      copiedDocumentFiles: copiedDocumentFiles,
      media: media.length,
      copiedMediaFiles: copiedMediaFiles,
      people: (await db.getProjectPeople(projectId)).length,
      risks: (await db.getProjectRisks(projectId)).length,
      decisions: (await db.getProjectDecisions(projectId)).length,
      hasRegistry: registry != null,
      observations: observations.length,
      refreshItems: refreshItems.length,
      latestSummaryDrafts: latestSummary == null ? 0 : 1,
      eventLogs: eventLogs.length,
      changeLogEntries: changeLog.length,
      changeSummaryDrafts: latestChangeSummary == null ? 0 : 1,
      cleanGitArchiveReady: cleanGitArchiveReady,
      warnings: List.unmodifiable(warnings),
    );
  }

  Future<int> exportProjectBundleToZip(
    String projectId,
    String path, {
    bool includeFiles = true,
    bool includeLatestSummary = false,
    bool includeEventLogs = false,
    bool includeChangeLog = false,
    DateTime? eventLogSince,
    bool includeCleanGitArchive = false,
    bool includeBootstrapContext = true,
  }) async {
    final preview = await previewProjectBundleExport(
      projectId,
      includeFiles: includeFiles,
      includeLatestSummary: includeLatestSummary,
      includeEventLogs: includeEventLogs,
      includeChangeLog: includeChangeLog,
      eventLogSince: eventLogSince,
      includeCleanGitArchive: includeCleanGitArchive,
      includeBootstrapContext: includeBootstrapContext,
    );
    final project = await db.getProjectFull(projectId);
    if (project == null) {
      throw StateError('Project not found: $projectId');
    }
    final stages = await db.getStagesForProject(projectId);
    final workItems = await db.getWorkItemsForProject(projectId);
    final workItemIds = workItems.map((item) => item.id).toList();
    final docs = await db.getDocumentsForProject(projectId);
    final media = await db.getProjectMedia(projectId);
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    final registries = await db.getProjectRegistryEntriesByAtlasProjectId(
      projectId,
    );
    final observations = registry == null
        ? const <ProjectObservation>[]
        : await (db.select(db.projectObservations)
                ..where((t) => t.observedPath.equals(registry.localPath))
                ..orderBy([(t) => OrderingTerm.desc(t.observedAt)]))
              .get();
    final refreshItems = registry == null
        ? const <LocalProjectRefreshItem>[]
        : await (db.select(
            db.localProjectRefreshItems,
          )..where((t) => t.registryId.equals(registry.id))).get();
    final latestSummary = includeLatestSummary
        ? await db.getLatestProjectSummaryDraft(projectId)
        : null;
    final latestChangeSummary = includeChangeLog
        ? await db.getLatestProjectChangeSummaryDraft(projectId)
        : null;
    final eventLogs = includeEventLogs
        ? await _projectBundleEventLogs(projectId, eventLogSince)
        : const <EventLogData>[];
    final changeLog = includeChangeLog
        ? await getProjectChangeLog(projectId, since: eventLogSince, limit: 500)
        : const <ProjectChangeLogEntry>[];
    final changeSummaryEvidence = includeChangeLog
        ? await _projectChangeSummaryEvidencePacket(
            projectId: projectId,
            changes: changeLog,
            since: eventLogSince,
            limit: 500,
          )
        : null;
    final exportWarnings = [...preview.warnings];
    _ProjectGitArchive? gitArchive;
    if (includeCleanGitArchive && preview.cleanGitArchiveReady) {
      gitArchive = await _buildProjectGitArchive(
        projectId,
        registries.isEmpty && registry != null ? [registry] : registries,
        exportWarnings,
      );
    }

    final exportedAt = DateTime.now().toIso8601String();
    final bootstrapContext = includeBootstrapContext
        ? await _projectBundleBootstrapContext(
            project: project,
            exportedAt: exportedAt,
            workItems: workItems,
            registry: registry,
            registries: registries,
            observations: observations,
            refreshItems: refreshItems,
          )
        : null;
    final bootstrapMarkdown = bootstrapContext == null
        ? null
        : _projectBundleBootstrapMarkdown(bootstrapContext);
    final options = <String, Object?>{
      'includeFiles': includeFiles,
      'includeLatestSummary': includeLatestSummary,
      'includeEventLogs': includeEventLogs,
      'includeChangeLog': includeChangeLog,
      'eventLogSince': eventLogSince?.toIso8601String(),
      'includeCleanGitArchive': includeCleanGitArchive,
      'includeBootstrapContext': includeBootstrapContext,
    };
    final counts = <String, Object?>{
      'atlasRecords': preview.atlasRecordCount,
      'stages': preview.stages,
      'workItems': preview.workItems,
      'workItemNotes': preview.workItemNotes,
      'workItemAnalyses': preview.workItemAnalyses,
      'documents': preview.documents,
      'documentFiles': preview.copiedDocumentFiles,
      'media': preview.media,
      'mediaFiles': preview.copiedMediaFiles,
      'people': preview.people,
      'risks': preview.risks,
      'decisions': preview.decisions,
      'registryLinked': preview.hasRegistry,
      'observations': preview.observations,
      'refreshItems': preview.refreshItems,
      'latestSummaryDrafts': preview.latestSummaryDrafts,
      'eventLogs': preview.eventLogs,
      'changeLogEntries': preview.changeLogEntries,
      'changeSummaryDrafts': preview.changeSummaryDrafts,
      'bootstrapContexts': bootstrapContext == null ? 0 : 1,
    };
    final contents = <String, Object?>{
      'projectBundle': 'project_bundle.json',
      'manifest': 'manifest/export_manifest.json',
      'readme': 'README.md',
      'bootstrapContext': bootstrapContext == null
          ? null
          : 'bootstrap/project_bootstrap_context.json',
      'bootstrapContextMarkdown': bootstrapMarkdown == null
          ? null
          : 'bootstrap/project_bootstrap_context.md',
      'summary': latestSummary == null
          ? null
          : 'summary/latest_project_summary.md',
      'summaryInput': (latestSummary?.inputJson ?? '').trim().isEmpty
          ? null
          : 'summary/latest_project_summary_input.json',
      'eventLogs': eventLogs.isEmpty ? null : 'logs/project_event_log.json',
      'changeLog': includeChangeLog ? 'change_log/project_changes.json' : null,
      'changeSummaryEvidence': includeChangeLog
          ? 'change_log/project_change_summary_evidence.json'
          : null,
      'changeSummary': latestChangeSummary == null
          ? null
          : 'change_log/latest_change_summary.md',
      'changeSummaryInput':
          (latestChangeSummary?.inputJson ?? '').trim().isEmpty
          ? null
          : 'change_log/latest_change_summary_input.json',
      'warnings': exportWarnings.isEmpty ? null : 'logs/export_warnings.txt',
      'cleanGitArchive': gitArchive?.archivePath,
      'documentFiles': includeFiles ? preview.copiedDocumentFiles : 0,
      'mediaFiles': includeFiles ? preview.copiedMediaFiles : 0,
    };
    final exportManifest = <String, Object?>{
      'schema': 'project_atlas_project_bundle_manifest_v1',
      'exportedAt': exportedAt,
      'project': {'id': project.id, 'title': project.title},
      'options': options,
      'counts': counts,
      'contents': contents,
      'warnings': exportWarnings,
    };

    final payload = {
      'schema': 'project_atlas_project_bundle_v1',
      'exportedAt': exportedAt,
      'options': options,
      'warnings': exportWarnings,
      'project': project.toJson(),
      'stages': stages.map((row) => row.toJson()).toList(),
      'workItems': workItems.map((row) => row.toJson()).toList(),
      'workItemNotes': workItemIds.isEmpty
          ? const []
          : (await (db.select(
                  db.workItemNotes,
                )..where((t) => t.workItemId.isIn(workItemIds))).get())
                .map((row) => row.toJson())
                .toList(),
      'workItemAnalyses': workItemIds.isEmpty
          ? const []
          : (await (db.select(
                  db.workItemAnalyses,
                )..where((t) => t.workItemId.isIn(workItemIds))).get())
                .map((row) => row.toJson())
                .toList(),
      'documents': docs.map((row) => row.toJson()).toList(),
      'projectMedia': media.map((row) => row.toJson()).toList(),
      'projectPeople': (await db.getProjectPeople(
        projectId,
      )).map((row) => row.toJson()).toList(),
      'projectRisks': (await db.getProjectRisks(
        projectId,
      )).map((row) => row.toJson()).toList(),
      'projectDecisions': (await db.getProjectDecisions(
        projectId,
      )).map((row) => row.toJson()).toList(),
      'projectRegistry': registry?.toJson(),
      'projectRegistryEntries': registries.map((row) => row.toJson()).toList(),
      'projectObservations': observations.map((row) => row.toJson()).toList(),
      'localProjectRefreshItems': refreshItems
          .map((row) => row.toJson())
          .toList(),
      'latestProjectSummary': latestSummary?.toJson(),
      'projectEventLogs': eventLogs.map((row) => row.toJson()).toList(),
      'projectChangeLog': changeLog.map((row) => row.toJson()).toList(),
      'projectChangeSummaryEvidence': changeSummaryEvidence,
      'latestProjectChangeSummary': latestChangeSummary?.toJson(),
      'cleanGitArchive': gitArchive?.metadata,
      'projectBootstrapContext': bootstrapContext,
    };

    final archive = Archive();
    final jsonBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    archive.addFile(
      ArchiveFile('project_bundle.json', jsonBytes.length, jsonBytes),
    );
    final manifestBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(exportManifest),
    );
    archive.addFile(
      ArchiveFile(
        'manifest/export_manifest.json',
        manifestBytes.length,
        manifestBytes,
      ),
    );
    final readmeBytes = utf8.encode(
      _projectBundleReadme(
        project: project,
        exportedAt: exportedAt,
        options: options,
        counts: counts,
        contents: contents,
        warnings: exportWarnings,
      ),
    );
    archive.addFile(ArchiveFile('README.md', readmeBytes.length, readmeBytes));
    if (bootstrapContext != null && bootstrapMarkdown != null) {
      final bootstrapJsonBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(bootstrapContext),
      );
      archive.addFile(
        ArchiveFile(
          'bootstrap/project_bootstrap_context.json',
          bootstrapJsonBytes.length,
          bootstrapJsonBytes,
        ),
      );
      final bootstrapMarkdownBytes = utf8.encode(bootstrapMarkdown);
      archive.addFile(
        ArchiveFile(
          'bootstrap/project_bootstrap_context.md',
          bootstrapMarkdownBytes.length,
          bootstrapMarkdownBytes,
        ),
      );
    }
    if (exportWarnings.isNotEmpty) {
      final warningBytes = utf8.encode('${exportWarnings.join('\n')}\n');
      archive.addFile(
        ArchiveFile(
          'logs/export_warnings.txt',
          warningBytes.length,
          warningBytes,
        ),
      );
    }
    if (latestSummary != null) {
      final summaryBytes = utf8.encode(latestSummary.body);
      archive.addFile(
        ArchiveFile(
          'summary/latest_project_summary.md',
          summaryBytes.length,
          summaryBytes,
        ),
      );
      if ((latestSummary.inputJson ?? '').trim().isNotEmpty) {
        final inputBytes = utf8.encode(latestSummary.inputJson!);
        archive.addFile(
          ArchiveFile(
            'summary/latest_project_summary_input.json',
            inputBytes.length,
            inputBytes,
          ),
        );
      }
    }
    if (eventLogs.isNotEmpty) {
      final eventBytes = utf8.encode(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(eventLogs.map((row) => row.toJson()).toList()),
      );
      archive.addFile(
        ArchiveFile(
          'logs/project_event_log.json',
          eventBytes.length,
          eventBytes,
        ),
      );
    }
    if (includeChangeLog) {
      final changeBytes = utf8.encode(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(changeLog.map((row) => row.toJson()).toList()),
      );
      archive.addFile(
        ArchiveFile(
          'change_log/project_changes.json',
          changeBytes.length,
          changeBytes,
        ),
      );
      final evidenceBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(changeSummaryEvidence),
      );
      archive.addFile(
        ArchiveFile(
          'change_log/project_change_summary_evidence.json',
          evidenceBytes.length,
          evidenceBytes,
        ),
      );
      if (latestChangeSummary != null) {
        final summaryBytes = utf8.encode(latestChangeSummary.body);
        archive.addFile(
          ArchiveFile(
            'change_log/latest_change_summary.md',
            summaryBytes.length,
            summaryBytes,
          ),
        );
        if ((latestChangeSummary.inputJson ?? '').trim().isNotEmpty) {
          final inputBytes = utf8.encode(latestChangeSummary.inputJson!);
          archive.addFile(
            ArchiveFile(
              'change_log/latest_change_summary_input.json',
              inputBytes.length,
              inputBytes,
            ),
          );
        }
      }
    }
    if (gitArchive != null) {
      archive.addFile(
        ArchiveFile(
          gitArchive.archivePath,
          gitArchive.bytes.length,
          gitArchive.bytes,
        ),
      );
    }

    if (includeFiles) {
      for (final doc in docs) {
        final storedPath = doc.storedPath;
        if (storedPath == null) continue;
        final file = File(storedPath);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final ext = doc.extension == null ? '' : '.${doc.extension}';
        final name =
            'documents/${_safeFileStem(doc.originalFilename)}_${doc.id}$ext';
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
      for (final item in media) {
        final file = File(item.storedPath);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final ext = item.extension == null ? '' : '.${item.extension}';
        final name =
            'media/${_safeFileStem(item.originalFilename)}_${item.id}$ext';
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
    }

    final zipBytes = ZipEncoder().encode(archive)!;
    await File(path).writeAsBytes(zipBytes);
    await db.logEvent(
      area: 'export',
      action: 'project_bundle_exported',
      entityType: 'project',
      entityId: projectId,
      outputJson: jsonEncode({
        'path': path,
        'includeFiles': includeFiles,
        'includeLatestSummary': includeLatestSummary,
        'includeEventLogs': includeEventLogs,
        'includeChangeLog': includeChangeLog,
        'eventLogSince': eventLogSince?.toIso8601String(),
        'includeCleanGitArchive': includeCleanGitArchive,
        'includeBootstrapContext': includeBootstrapContext,
        'atlasRecords': preview.atlasRecordCount,
        'changeLogEntries': preview.changeLogEntries,
        'changeSummaryDrafts': preview.changeSummaryDrafts,
        'copiedFiles': preview.copiedFileCount,
        'warnings': exportWarnings,
      }),
    );
    return payload.length;
  }

  String _projectBundleReadme({
    required ProjectFull project,
    required String exportedAt,
    required Map<String, Object?> options,
    required Map<String, Object?> counts,
    required Map<String, Object?> contents,
    required List<String> warnings,
  }) {
    String formatValue(Object? value) {
      if (value == null) return 'none';
      if (value is bool) return value ? 'yes' : 'no';
      return value.toString();
    }

    final lines = <String>[
      '# ${project.title} Project Bundle',
      '',
      'Exported: $exportedAt',
      'Project ID: ${project.id}',
      '',
      '## Contents',
      for (final entry in contents.entries)
        if (entry.value != null && entry.value != 0)
          '- ${entry.key}: ${formatValue(entry.value)}',
      '',
      '## Options',
      for (final entry in options.entries)
        '- ${entry.key}: ${formatValue(entry.value)}',
      '',
      '## Counts',
      for (final entry in counts.entries)
        '- ${entry.key}: ${formatValue(entry.value)}',
    ];
    if (warnings.isNotEmpty) {
      lines
        ..add('')
        ..add('## Warnings')
        ..addAll(warnings.map((warning) => '- $warning'));
    }
    return '${lines.join('\n')}\n';
  }

  Future<Map<String, Object?>> _projectBundleBootstrapContext({
    required ProjectFull project,
    required String exportedAt,
    required List<WorkItem> workItems,
    required ProjectRegistryEntry? registry,
    required List<ProjectRegistryEntry> registries,
    required List<ProjectObservation> observations,
    required List<LocalProjectRefreshItem> refreshItems,
  }) async {
    final activeWorkItems = workItems
        .where((item) => !{'done', 'archived'}.contains(item.status))
        .toList(growable: false);
    final blockedWorkItems = activeWorkItems
        .where((item) => _metaString(item.blockedReason) != null)
        .toList(growable: false);
    final llmTasks = (await db.getLlmTasksForProject(
      project.id,
      limit: 50,
    )).where((task) => !{'completed', 'cancelled'}.contains(task.status));
    final proposals = (await db.watchDrafts().first)
        .where(_isPendingAgentProposalDraft)
        .where((draft) => draft.projectId == project.id)
        .take(25)
        .map(_agentProposalDraftToBundleJson)
        .toList(growable: false);
    final githubRemote = await db.getLatestProjectGitRemoteStatus(project.id);
    final gaps = <String>[
      if (registry == null) 'Project has no linked local registry entry.',
      if (githubRemote == null) 'Project has no cached GitHub remote status.',
      if (llmTasks.isEmpty && proposals.isEmpty)
        'No pending queue tasks or agent proposals were present at export time.',
    ];
    final pendingLlmTasks = llmTasks
        .map((task) => task.toJson())
        .toList(growable: false);

    return {
      'schema': 'atlas.project_bootstrap_context.v1',
      'generatedAt': exportedAt,
      'project': {
        'id': project.id,
        'title': project.title,
        'status': project.status,
        'category': project.category,
        'owner': project.owner,
        'phase': project.phase,
        'priority': project.priority,
        'description': project.description,
        'desiredOutcome': project.desiredOutcome,
        'successCriteria': project.successCriteria,
        'scopeIncluded': project.scopeIncluded,
        'scopeExcluded': project.scopeExcluded,
        'outcomeSummary': project.outcomeSummary,
        'lessonsLearned': project.lessonsLearned,
        'createdAt': project.createdAt.toIso8601String(),
      },
      'identity': {
        'projectId': project.id,
        'projectTitle': project.title,
        'registryId': registry?.id,
        'localPath': registry?.localPath,
        'gitRoot': registry?.gitRoot,
        'classification': registry?.classification,
        'reviewState': registry?.reviewState,
        'registryEntries': registries.map((row) => row.toJson()).toList(),
        'githubRemote': githubRemote?.toJson(),
      },
      'counts': {
        'activeWorkItems': activeWorkItems.length,
        'blockedWorkItems': blockedWorkItems.length,
        'pendingLlmTasks': pendingLlmTasks.length,
        'pendingAgentProposals': proposals.length,
        'observations': observations.length,
        'refreshItems': refreshItems.length,
      },
      'localEvidence': {
        'hasRegistry': registry != null,
        'latestObservation': observations.isEmpty
            ? null
            : observations.first.toJson(),
        'refreshItems': refreshItems
            .take(25)
            .map((row) => row.toJson())
            .toList(),
      },
      'pendingLlmTasks': pendingLlmTasks,
      'pendingAgentProposals': proposals,
      'recommendedNextAction': _projectBundleBootstrapNextAction(
        pendingLlmTasks: pendingLlmTasks,
        pendingAgentProposals: proposals,
        gaps: gaps,
      ),
      'confidence': gaps.isEmpty
          ? 'high'
          : registry == null
          ? 'low'
          : 'medium',
      'gaps': gaps,
    };
  }

  String _projectBundleBootstrapNextAction({
    required List<Map<String, Object?>> pendingLlmTasks,
    required List<Map<String, Object?>> pendingAgentProposals,
    required List<String> gaps,
  }) {
    if (pendingLlmTasks.isNotEmpty) {
      final title =
          _cleanNullableString(pendingLlmTasks.first['title']) ?? 'queued task';
      return 'Claim next pending LLM task: $title.';
    }
    if (pendingAgentProposals.isNotEmpty) {
      final title =
          _cleanNullableString(pendingAgentProposals.first['title']) ??
          'agent proposal';
      return 'Review pending agent proposal: $title.';
    }
    if (gaps.isNotEmpty) {
      return 'Resolve exported bootstrap gap: ${gaps.first}';
    }
    return 'No pending agent handoff action found in this bundle.';
  }

  String _projectBundleBootstrapMarkdown(Map<String, Object?> context) {
    final project = _bundleObjectMap(context['project']);
    final identity = _bundleObjectMap(context['identity']);
    final counts = _bundleObjectMap(context['counts']);
    final gaps = _bundleStringList(context['gaps']);
    final pendingTasks = _bundleMapList(context['pendingLlmTasks']);
    final proposals = _bundleMapList(context['pendingAgentProposals']);
    final buffer = StringBuffer()
      ..writeln('# Project Bootstrap Context')
      ..writeln()
      ..writeln('Schema: `${context['schema']}`')
      ..writeln('Generated: ${context['generatedAt']}')
      ..writeln()
      ..writeln('## Project')
      ..writeln()
      ..writeln('- ID: ${project['id']}')
      ..writeln('- Title: ${project['title']}')
      ..writeln('- Status: ${project['status']}')
      ..writeln('- Phase: ${project['phase'] ?? 'none'}')
      ..writeln()
      ..writeln('## Identity')
      ..writeln()
      ..writeln('- Registry: ${identity['registryId'] ?? 'none'}')
      ..writeln('- Local path: ${identity['localPath'] ?? 'none'}')
      ..writeln('- Git root: ${identity['gitRoot'] ?? 'none'}')
      ..writeln()
      ..writeln('## Counts')
      ..writeln();
    for (final entry in counts.entries) {
      buffer.writeln('- ${entry.key}: ${entry.value}');
    }
    buffer
      ..writeln()
      ..writeln('## Next Action')
      ..writeln()
      ..writeln(context['recommendedNextAction'] ?? 'none');
    if (pendingTasks.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Pending LLM Tasks')
        ..writeln();
      for (final task in pendingTasks) {
        buffer.writeln(
          '- ${task['title'] ?? task['id']} '
          '(${task['status'] ?? 'unknown'}, ${task['priority'] ?? 'normal'})',
        );
      }
    }
    if (proposals.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Pending Agent Proposals')
        ..writeln();
      for (final proposal in proposals) {
        buffer.writeln(
          '- ${proposal['title'] ?? proposal['proposalId']} '
          '(${proposal['type'] ?? 'proposal'})',
        );
      }
    }
    if (gaps.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Gaps')
        ..writeln();
      for (final gap in gaps) {
        buffer.writeln('- $gap');
      }
    }
    return buffer.toString();
  }

  bool _isPendingAgentProposalDraft(Draft draft) {
    if (draft.kind != 'atlas_agent_proposal' || draft.accepted) return false;
    final envelope = _bundleObjectMap(_bundleJsonDecode(draft.inputJson));
    final reviewStatus =
        _cleanNullableString(envelope['reviewStatus']) ?? 'pending';
    return reviewStatus == 'pending';
  }

  Map<String, Object?> _agentProposalDraftToBundleJson(Draft draft) {
    final envelope = _bundleObjectMap(_bundleJsonDecode(draft.inputJson));
    return {
      'draftId': draft.id,
      'proposalId': envelope['proposalId'] ?? draft.id,
      'type': envelope['type'] ?? draft.kind,
      'projectId': envelope['projectId'] ?? draft.projectId,
      'title': draft.title,
      'reviewStatus': envelope['reviewStatus'] ?? 'pending',
      'validationErrors': _bundleStringList(envelope['validationErrors']),
      'warnings': _bundleStringList(envelope['warnings']),
      'createdAt': draft.createdAt.toIso8601String(),
    };
  }

  Object? _bundleJsonDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _bundleObjectMap(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, value) => MapEntry('$key', value));
  }

  List<String> _bundleStringList(Object? value) {
    if (value is Iterable) {
      return value.map(_cleanNullableString).whereType<String>().toList();
    }
    final single = _cleanNullableString(value);
    return single == null ? const [] : [single];
  }

  List<Map<String, Object?>> _bundleMapList(Object? value) {
    if (value is! Iterable) return const [];
    return value
        .whereType<Map>()
        .map((entry) => entry.map((key, value) => MapEntry('$key', value)))
        .toList();
  }

  Future<List<EventLogData>> _projectBundleEventLogs(
    String projectId,
    DateTime? since,
  ) => getProjectEventLogs(projectId, since: since, limit: 500);

  bool _eventPayloadMentionsProject(EventLogData event, String projectId) {
    final input = event.inputJson ?? '';
    final output = event.outputJson ?? '';
    return input.contains(projectId) || output.contains(projectId);
  }

  Future<bool> _projectGitArchiveIsReady(
    String projectId,
    List<ProjectRegistryEntry> registries,
    List<String> warnings,
  ) async {
    final localWarnings = <String>[];
    final local = await _findCleanLocalGitArchiveCandidate(
      registries,
      warnings: localWarnings,
    );
    if (local != null) return true;
    final github = await _findGithubArchiveCandidate(projectId);
    if (github != null) return true;
    warnings.addAll(localWarnings);
    if (registries.isEmpty) {
      warnings.add(
        'Clean git archive skipped: project has no linked registry entries.',
      );
    }
    warnings.add(
      'Clean git archive skipped: no clean local Git repo or cached public GitHub archive was available.',
    );
    return false;
  }

  Future<_ProjectGitArchive?> _buildProjectGitArchive(
    String projectId,
    List<ProjectRegistryEntry> registries,
    List<String> warnings,
  ) async {
    final localWarnings = <String>[];
    final local = await _findCleanLocalGitArchiveCandidate(
      registries,
      warnings: localWarnings,
    );
    if (local != null) {
      return _buildLocalGitArchive(local, warnings);
    }
    final github = await _findGithubArchiveCandidate(projectId);
    if (github == null) {
      warnings.addAll(localWarnings);
      warnings.add(
        'Clean git archive skipped during export: no clean local Git repo or cached public GitHub archive was available.',
      );
      return null;
    }
    try {
      final bytes = await _githubArchiveFetcher(
        github.identity,
        github.ref,
      ).timeout(const Duration(seconds: 30));
      if (bytes.isEmpty) {
        warnings.add('GitHub archive download returned empty output.');
        return null;
      }
      final safeRepo = _safeFileStem(github.identity.fullName);
      final safeRef = _safeFileStem(github.ref);
      final archivePath = 'git/github_${safeRepo}_$safeRef.zip';
      return _ProjectGitArchive(
        bytes: bytes,
        archivePath: archivePath,
        metadata: {
          'source': 'github',
          'provider': github.identity.provider,
          'owner': github.identity.owner,
          'repo': github.identity.repo,
          'remoteUrl': github.identity.remoteUrl,
          'htmlUrl': github.identity.htmlUrl,
          'ref': github.ref,
          'defaultBranch': github.status?.defaultBranch,
          'onlineHeadSha': github.status?.onlineHeadSha,
          'visibility': github.status?.visibility,
          'archivePath': archivePath,
        },
      );
    } on TimeoutException {
      warnings.addAll(localWarnings);
      warnings.add('GitHub archive download timed out.');
    } catch (error) {
      warnings.addAll(localWarnings);
      warnings.add('GitHub archive download failed: $error');
    }
    return null;
  }

  Future<_ProjectGitArchive?> _buildLocalGitArchive(
    _LocalGitArchiveCandidate candidate,
    List<String> warnings,
  ) async {
    final report = candidate.report;
    final gitRoot = report.gitRoot;
    if (gitRoot == null) return null;
    try {
      final result = await Process.run(
        'git',
        const ['archive', '--format=zip', 'HEAD'],
        workingDirectory: gitRoot,
        stdoutEncoding: null,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      final output = result.stdout;
      if (result.exitCode == 0 && output is List<int> && output.isNotEmpty) {
        const archivePath = 'git/clean_HEAD.zip';
        return _ProjectGitArchive(
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

  Future<_LocalGitArchiveCandidate?> _findCleanLocalGitArchiveCandidate(
    List<ProjectRegistryEntry> registries, {
    List<String>? warnings,
  }) async {
    final failures = <String>[];
    for (final registry in _orderedProjectRegistries(registries)) {
      if (_looksLikeRemotePath(registry.localPath)) {
        failures.add(
          'Git ${registry.displayName}: registered path is a remote URL, not a local folder.',
        );
        continue;
      }
      final report = await const LocalGitVisibilityService().inspect(
        registry.localPath,
      );
      if (_localGitReportIsArchiveReady(report)) {
        return _LocalGitArchiveCandidate(registry: registry, report: report);
      }
      failures.add(_localGitArchiveSkipReason(registry, report));
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

  bool _localGitReportIsArchiveReady(LocalGitVisibilityReport report) =>
      report.isGitRepository &&
      report.gitRoot != null &&
      report.changedTrackedCount == 0 &&
      report.untrackedCount == 0 &&
      (report.headSha ?? '').trim().isNotEmpty;

  String _localGitArchiveSkipReason(
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

  Future<_GithubArchiveCandidate?> _findGithubArchiveCandidate(
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
      return _GithubArchiveCandidate(
        identity: identity,
        ref: ref,
        status: status,
      );
    }
    return null;
  }

  List<ProjectRegistryEntry> _orderedProjectRegistries(
    List<ProjectRegistryEntry> registries,
  ) {
    final ordered = [...registries];
    int score(ProjectRegistryEntry entry) {
      var value = 0;
      if (entry.reviewState != 'linked') value += 10;
      if ((entry.gitRoot ?? '').trim().isEmpty) value += 2;
      if (_looksLikeRemotePath(entry.localPath)) value += 50;
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

  // ---------------------------------------------------------------------------
  // Telegram
  // ---------------------------------------------------------------------------

  Future<TelegramService?> _buildTelegram() async {
    final token = await getSetting(AppDb.kTelegramBotToken);
    final chatId = await getSetting(AppDb.kTelegramChatId);
    if (token == null || token.isEmpty || chatId == null || chatId.isEmpty) {
      return null;
    }
    return TelegramService(botToken: token, chatId: chatId);
  }

  Future<(bool, String?)> sendTodayToTelegram() async {
    final enabled = _metaBool(
      await getSetting(AppDb.kTelegramEnabled),
      fallback: false,
    );
    if (!enabled) {
      return (
        false,
        'Telegram sending is disabled. Enable Telegram in Settings to send.',
      );
    }

    final svc = await _buildTelegram();
    if (svc == null) {
      return (
        false,
        'Telegram not configured. Add bot token and chat ID in Settings.',
      );
    }

    final items = await getTodayItems();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Resolve project labels via DB (not string-prefix hacks)
    Future<String> projectLabel(WorkItem item) async {
      final stage = await (db.select(
        db.stages,
      )..where((t) => t.id.equals(item.stageId))).getSingleOrNull();
      if (stage == null) return item.stageId;
      final proj = await (db.select(
        db.projects,
      )..where((t) => t.id.equals(stage.projectId))).getSingleOrNull();
      return proj?.title ?? stage.projectId;
    }

    String fmtDate(DateTime? dt) => dt == null ? '' : '${dt.month}/${dt.day}';

    final doingItems =
        <
          ({
            String title,
            String project,
            String stage,
            String? dueDate,
            String priority,
          })
        >[];
    final overdueItems =
        <
          ({
            String title,
            String project,
            String stage,
            String? dueDate,
            String priority,
          })
        >[];
    final dueTodayItems =
        <
          ({
            String title,
            String project,
            String stage,
            String? dueDate,
            String priority,
          })
        >[];
    final phoneItems =
        <({String title, String project, String stage, String priority})>[];
    final blockedItems = <({String title, String blockedReason})>[];

    for (final i in items) {
      final label = await projectLabel(i);
      final rec = (
        title: i.title,
        project: label,
        stage: i.stageId,
        dueDate: fmtDate(i.dueAt),
        priority: i.priority,
      );

      if (i.status == 'doing') {
        doingItems.add(rec);
      } else if (i.dueAt != null && i.dueAt!.isBefore(today)) {
        overdueItems.add(rec);
      } else if (i.dueAt != null &&
          i.dueAt!.isBefore(today.add(const Duration(days: 1)))) {
        dueTodayItems.add(rec);
      } else if (i.phoneQueue) {
        phoneItems.add((
          title: i.title,
          project: label,
          stage: i.stageId,
          priority: i.priority,
        ));
      }
      if (i.blockedReason != null) {
        blockedItems.add((title: i.title, blockedReason: i.blockedReason!));
      }
    }

    final message = TelegramService.formatTodayList(
      date: '${now.month}/${now.day}/${now.year}',
      doingItems: doingItems,
      overdueItems: overdueItems,
      dueTodayItems: dueTodayItems,
      blockedItems: blockedItems,
      phoneQueueItems: phoneItems,
    );

    // Record in outbox BEFORE sending so we have a trace even if send fails
    final outboxId = await db.addOutboxMessage(
      channel: 'telegram',
      title: "Today's Task List",
      body: message,
    );

    final (ok, err) = await svc.sendMessage(message);

    if (ok) {
      await db.markOutboxSent(outboxId);
    } else {
      await db.markOutboxFailed(outboxId, err ?? 'Unknown error');
    }

    return (ok, err);
  }

  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _localProjectRefreshTimer?.cancel();
    for (final subscription in _settingsSubscriptions) {
      unawaited(subscription.cancel());
    }
    _activeProjectSub.cancel();
    hasActiveProject.dispose();
    super.dispose();
  }
}

class ContactResponsibilities {
  final List<Project> ownedProjects;
  final List<Project> contributingProjects;
  final List<ProjectPerson> projectPeople;
  final List<WorkItem> workItems;

  const ContactResponsibilities({
    required this.ownedProjects,
    required this.contributingProjects,
    required this.projectPeople,
    required this.workItems,
  });
}

class _ContactSeed {
  final String id;
  final String name;
  final String? title;
  final String? email;
  final String? notes;

  const _ContactSeed({
    required this.id,
    required this.name,
    this.title,
    this.email,
    this.notes,
  });
}
