import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart' show SqliteException;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../shared/models/project_metadata.dart';
import 'document_extractor.dart';

import 'db_open.dart';
import 'tables.dart';
import 'timestamp_contract.dart';

part 'app_db.g.dart';

// ---------------------------------------------------------------------------
// Convenience type aliases
// Drift auto-generates a data class per table, e.g. Project for Projects,
// Stage for Stages, etc. These aliases let the rest of the app use the
// names that the UI code already references.
// ---------------------------------------------------------------------------

/// Full project data. Since we added description/desiredOutcome/successCriteria
/// directly to the Projects table, the Drift-generated [Project] class already
/// carries them. This typedef keeps call-sites unchanged.
typedef ProjectFull = Project;

// Drift generates:
//   ProjectPeopleData  (from ProjectPeople — doesn't end in 's', so adds 'Data')
//   ProjectRisk        (from ProjectRisks  — removes 's')
//   ProjectDecision    (from ProjectDecisions — removes 's')
//   EventLogData       (from EventLog — no 's', adds 'Data')
//   OutboxMessage      (from OutboxMessages — removes 's')
typedef ProjectPerson = ProjectPeopleData;

class ProjectUpdateAttribution {
  final String projectId;
  final DateTime updatedAt;
  final String updatedBy;
  final String source;
  final String? contactName;

  const ProjectUpdateAttribution({
    required this.projectId,
    required this.updatedAt,
    required this.updatedBy,
    required this.source,
    this.contactName,
  });
}

class ProjectGitRemoteStatus {
  final String id;
  final String projectId;
  final String? registryId;
  final String provider;
  final String owner;
  final String repo;
  final String remoteUrl;
  final String? htmlUrl;
  final String? visibility;
  final String? defaultBranch;
  final String? onlineHeadSha;
  final bool? isPrivate;
  final bool? isFork;
  final bool? isArchived;
  final DateTime checkedAt;
  final DateTime? remoteUpdatedAt;
  final DateTime? remotePushedAt;
  final String? error;
  final String? rawJson;

  const ProjectGitRemoteStatus({
    required this.id,
    required this.projectId,
    this.registryId,
    required this.provider,
    required this.owner,
    required this.repo,
    required this.remoteUrl,
    this.htmlUrl,
    this.visibility,
    this.defaultBranch,
    this.onlineHeadSha,
    this.isPrivate,
    this.isFork,
    this.isArchived,
    required this.checkedAt,
    this.remoteUpdatedAt,
    this.remotePushedAt,
    this.error,
    this.rawJson,
  });

  String get fullName => '$owner/$repo';
  bool get hasError => error != null && error!.trim().isNotEmpty;

  Map<String, Object?> toJson() => {
    'id': id,
    'projectId': projectId,
    'registryId': registryId,
    'provider': provider,
    'owner': owner,
    'repo': repo,
    'fullName': fullName,
    'remoteUrl': remoteUrl,
    'htmlUrl': htmlUrl,
    'visibility': visibility,
    'defaultBranch': defaultBranch,
    'onlineHeadSha': onlineHeadSha,
    'isPrivate': isPrivate,
    'isFork': isFork,
    'isArchived': isArchived,
    'checkedAt': checkedAt.toIso8601String(),
    'remoteUpdatedAt': remoteUpdatedAt?.toIso8601String(),
    'remotePushedAt': remotePushedAt?.toIso8601String(),
    'error': error,
    'rawJson': rawJson,
  };
}

class ProjectEnrichmentRun {
  final String id;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String status;
  final String scopeJson;
  final int registryEntries;
  final int linkedProjects;
  final int refreshedProjects;
  final int createdItems;
  final int updatedItems;
  final int unchangedItems;
  final int skippedItems;
  final int failedProjects;
  final int summaryConsidered;
  final int summaryRefreshed;
  final int summarySkipped;
  final int summaryFailed;
  final int findings;
  final int openFindings;
  final String warningsJson;
  final String outputJson;

  const ProjectEnrichmentRun({
    required this.id,
    required this.startedAt,
    this.completedAt,
    required this.status,
    required this.scopeJson,
    required this.registryEntries,
    required this.linkedProjects,
    required this.refreshedProjects,
    required this.createdItems,
    required this.updatedItems,
    required this.unchangedItems,
    required this.skippedItems,
    required this.failedProjects,
    required this.summaryConsidered,
    required this.summaryRefreshed,
    required this.summarySkipped,
    required this.summaryFailed,
    required this.findings,
    required this.openFindings,
    required this.warningsJson,
    required this.outputJson,
  });

  List<String> get warnings => _decodeStringList(warningsJson);
  Map<String, Object?> get scope => _decodeObjectMap(scopeJson);
  Map<String, Object?> get output => _decodeObjectMap(outputJson);

  Map<String, Object?> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'status': status,
    'scope': scope,
    'registryEntries': registryEntries,
    'linkedProjects': linkedProjects,
    'refreshedProjects': refreshedProjects,
    'createdItems': createdItems,
    'updatedItems': updatedItems,
    'unchangedItems': unchangedItems,
    'skippedItems': skippedItems,
    'failedProjects': failedProjects,
    'summaryConsidered': summaryConsidered,
    'summaryRefreshed': summaryRefreshed,
    'summarySkipped': summarySkipped,
    'summaryFailed': summaryFailed,
    'findings': findings,
    'openFindings': openFindings,
    'warnings': warnings,
    'output': output,
  };
}

class ProjectHealthWarningGroup {
  final String key;
  final String category;
  final String title;
  final List<String> warnings;

  const ProjectHealthWarningGroup({
    required this.key,
    required this.category,
    required this.title,
    required this.warnings,
  });

  int get count => warnings.length;
  List<String> get examples => warnings.take(5).toList(growable: false);

  Map<String, Object?> toJson() => {
    'key': key,
    'category': category,
    'title': title,
    'count': count,
    'examples': examples,
  };
}

List<ProjectHealthWarningGroup> groupProjectHealthWarnings(
  Iterable<String> warnings,
) {
  final grouped = <String, _ProjectHealthWarningAccumulator>{};
  for (final raw in warnings) {
    final warning = raw.trim();
    if (warning.isEmpty) continue;
    final classification = _classifyProjectHealthWarning(warning);
    grouped
        .putIfAbsent(
          classification.key,
          () => _ProjectHealthWarningAccumulator(classification),
        )
        .warnings
        .add(warning);
  }
  final groups = grouped.values
      .map(
        (entry) => ProjectHealthWarningGroup(
          key: entry.classification.key,
          category: entry.classification.category,
          title: entry.classification.title,
          warnings: List.unmodifiable(entry.warnings),
        ),
      )
      .toList();
  groups.sort((a, b) {
    final category = _warningCategoryRank(
      a.category,
    ).compareTo(_warningCategoryRank(b.category));
    if (category != 0) return category;
    final count = b.count.compareTo(a.count);
    if (count != 0) return count;
    return a.title.compareTo(b.title);
  });
  return List.unmodifiable(groups);
}

class _ProjectHealthWarningAccumulator {
  final _ProjectHealthWarningClassification classification;
  final List<String> warnings = [];

  _ProjectHealthWarningAccumulator(this.classification);
}

class _ProjectHealthWarningClassification {
  final String key;
  final String category;
  final String title;

  const _ProjectHealthWarningClassification({
    required this.key,
    required this.category,
    required this.title,
  });
}

_ProjectHealthWarningClassification _classifyProjectHealthWarning(
  String warning,
) {
  final normalized = _warningClassificationText(warning);
  if (normalized.startsWith('Artifact not imported as source:')) {
    return const _ProjectHealthWarningClassification(
      key: 'artifact_not_imported',
      category: 'source_import',
      title: 'Artifacts skipped as source files',
    );
  }
  if (RegExp(
    r'^Skipped \d+ source file\(s\) over 256 KB\.',
  ).hasMatch(normalized)) {
    return const _ProjectHealthWarningClassification(
      key: 'large_source_files',
      category: 'source_import',
      title: 'Large source files skipped',
    );
  }
  if (normalized.startsWith('Source file refresh plan capped')) {
    return const _ProjectHealthWarningClassification(
      key: 'source_refresh_cap',
      category: 'source_import',
      title: 'Source refresh action cap reached',
    );
  }
  if (normalized.contains('registered local path is a remote URL')) {
    return const _ProjectHealthWarningClassification(
      key: 'remote_url_registry_path',
      category: 'registry',
      title: 'Registry rows skipped because path is a remote URL',
    );
  }
  if (normalized.contains('registered local path does not exist') ||
      normalized.contains('path does not exist')) {
    return const _ProjectHealthWarningClassification(
      key: 'missing_registry_path',
      category: 'registry',
      title: 'Registry rows skipped because path is missing',
    );
  }
  return const _ProjectHealthWarningClassification(
    key: 'other_project_warnings',
    category: 'other',
    title: 'Other project refresh warnings',
  );
}

String _warningClassificationText(String warning) {
  final trimmed = warning.trim();
  if (_isKnownProjectHealthWarningShape(trimmed)) return trimmed;
  final separator = trimmed.indexOf(': ');
  if (separator <= 0 || separator == trimmed.length - 2) return trimmed;
  final withoutProjectPrefix = trimmed.substring(separator + 2).trim();
  return _isKnownProjectHealthWarningShape(withoutProjectPrefix)
      ? withoutProjectPrefix
      : trimmed;
}

bool _isKnownProjectHealthWarningShape(String warning) {
  return warning.startsWith('Artifact not imported as source:') ||
      RegExp(
        r'^Skipped \d+ source file\(s\) over 256 KB\.',
      ).hasMatch(warning) ||
      warning.startsWith('Source file refresh plan capped') ||
      warning.contains('registered local path is a remote URL') ||
      warning.contains('registered local path does not exist') ||
      warning.contains('path does not exist');
}

int _warningCategoryRank(String category) {
  switch (category) {
    case 'registry':
      return 0;
    case 'source_import':
      return 1;
    default:
      return 2;
  }
}

class ProjectEnrichmentFinding {
  final String id;
  final String runId;
  final String? projectId;
  final String? registryId;
  final String severity;
  final String category;
  final String title;
  final String? detail;
  final String evidenceJson;
  final String status;
  final DateTime createdAt;

  const ProjectEnrichmentFinding({
    required this.id,
    required this.runId,
    this.projectId,
    this.registryId,
    required this.severity,
    required this.category,
    required this.title,
    this.detail,
    required this.evidenceJson,
    required this.status,
    required this.createdAt,
  });

  Map<String, Object?> get evidence => _decodeObjectMap(evidenceJson);

  Map<String, Object?> toJson() => {
    'id': id,
    'runId': runId,
    'projectId': projectId,
    'registryId': registryId,
    'severity': severity,
    'category': category,
    'title': title,
    'detail': detail,
    'evidence': evidence,
    'status': status,
    'createdAt': createdAt.toIso8601String(),
  };
}

class ProjectEnrichmentStep {
  final String id;
  final String runId;
  final String worker;
  final String title;
  final String status;
  final DateTime startedAt;
  final DateTime? completedAt;
  final int considered;
  final int createdItems;
  final int updatedItems;
  final int skippedItems;
  final int failedItems;
  final int findings;
  final int proposals;
  final String warningsJson;
  final String outputJson;

  const ProjectEnrichmentStep({
    required this.id,
    required this.runId,
    required this.worker,
    required this.title,
    required this.status,
    required this.startedAt,
    this.completedAt,
    required this.considered,
    required this.createdItems,
    required this.updatedItems,
    required this.skippedItems,
    required this.failedItems,
    required this.findings,
    required this.proposals,
    required this.warningsJson,
    required this.outputJson,
  });

  List<String> get warnings => _decodeStringList(warningsJson);
  Map<String, Object?> get output => _decodeObjectMap(outputJson);

  Map<String, Object?> toJson() => {
    'id': id,
    'runId': runId,
    'worker': worker,
    'title': title,
    'status': status,
    'startedAt': startedAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'considered': considered,
    'createdItems': createdItems,
    'updatedItems': updatedItems,
    'skippedItems': skippedItems,
    'failedItems': failedItems,
    'findings': findings,
    'proposals': proposals,
    'warnings': warnings,
    'output': output,
  };
}

class ProjectEnrichmentProposal {
  final String id;
  final String runId;
  final String? projectId;
  final String? registryId;
  final String worker;
  final String proposalType;
  final String title;
  final String? detail;
  final String payloadJson;
  final int confidence;
  final String status;
  final DateTime createdAt;
  final DateTime? appliedAt;

  const ProjectEnrichmentProposal({
    required this.id,
    required this.runId,
    this.projectId,
    this.registryId,
    required this.worker,
    required this.proposalType,
    required this.title,
    this.detail,
    required this.payloadJson,
    required this.confidence,
    required this.status,
    required this.createdAt,
    this.appliedAt,
  });

  Map<String, Object?> get payload => _decodeObjectMap(payloadJson);

  Map<String, Object?> toJson() => {
    'id': id,
    'runId': runId,
    'projectId': projectId,
    'registryId': registryId,
    'worker': worker,
    'proposalType': proposalType,
    'title': title,
    'detail': detail,
    'payload': payload,
    'confidence': confidence,
    'status': status,
    'createdAt': createdAt.toIso8601String(),
    'appliedAt': appliedAt?.toIso8601String(),
  };
}

class LlmTaskQueueItem {
  final String id;
  final String projectId;
  final String? workItemId;
  final String title;
  final String objective;
  final String contextJson;
  final String priority;
  final String status;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? leasedBy;
  final DateTime? leasedAt;
  final DateTime? leaseExpiresAt;
  final int attempts;
  final String? resultJson;
  final String? error;
  final String? reviewDraftId;
  final DateTime? completedAt;
  final String readiness;
  final String size;
  final String risk;
  final String suggestedActor;
  final String verificationNeeded;
  final String? nextAction;
  final String? blockerReason;
  final String? planningNotes;
  final DateTime? lastReviewedAt;

  const LlmTaskQueueItem({
    required this.id,
    required this.projectId,
    this.workItemId,
    required this.title,
    required this.objective,
    required this.contextJson,
    required this.priority,
    required this.status,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.leasedBy,
    this.leasedAt,
    this.leaseExpiresAt,
    required this.attempts,
    this.resultJson,
    this.error,
    this.reviewDraftId,
    this.completedAt,
    this.readiness = 'ready',
    this.size = 'medium',
    this.risk = 'low_code',
    this.suggestedActor = 'user',
    this.verificationNeeded = 'none',
    this.nextAction,
    this.blockerReason,
    this.planningNotes,
    this.lastReviewedAt,
  });

  Map<String, Object?> get context => _decodeObjectMap(contextJson);
  Map<String, Object?> get result => _decodeObjectMap(resultJson);

  Map<String, Object?> toJson() => {
    'id': id,
    'projectId': projectId,
    'workItemId': workItemId,
    'title': title,
    'objective': objective,
    'context': context,
    'priority': priority,
    'status': status,
    'createdBy': createdBy,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'leasedBy': leasedBy,
    'leasedAt': leasedAt?.toIso8601String(),
    'leaseExpiresAt': leaseExpiresAt?.toIso8601String(),
    'attempts': attempts,
    'result': resultJson == null ? null : result,
    'error': error,
    'reviewDraftId': reviewDraftId,
    'completedAt': completedAt?.toIso8601String(),
    'readiness': readiness,
    'size': size,
    'risk': risk,
    'suggestedActor': suggestedActor,
    'verificationNeeded': verificationNeeded,
    'nextAction': nextAction,
    'blockerReason': blockerReason,
    'planningNotes': planningNotes,
    'lastReviewedAt': lastReviewedAt?.toIso8601String(),
  };
}

List<String> _decodeStringList(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) return const <String>[];
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is List) {
      return decoded.map((item) => item.toString()).toList(growable: false);
    }
  } catch (_) {}
  return const <String>[];
}

Map<String, Object?> _decodeObjectMap(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty)
    return const <String, Object?>{};
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {}
  return const <String, Object?>{};
}

// ---------------------------------------------------------------------------
// AppDb
// ---------------------------------------------------------------------------

@DriftDatabase(
  tables: [
    Projects,
    AppMeta,
    Stages,
    WorkItems,
    WorkItemNotes,
    WorkItemAnalyses,
    Drafts,
    DailyReviews,
    OutboxMessages,
    EventLog,
    Documents,
    DocumentLinks,
    Contacts,
    ProjectPeople,
    ProjectRisks,
    ProjectDecisions,
    Tags,
    ProjectTags,
    ProjectMedia,
    MediaLinks,
    ProjectRegistry,
    ProjectObservations,
    ProjectScanRuns,
    LocalProjectRefreshItems,
    ProjectRuntimeProfiles,
    ProjectRuntimeRuns,
  ],
)
class AppDb extends _$AppDb {
  AppDb() : super(openEncryptedExecutor());
  AppDb.withExecutor(QueryExecutor executor) : super(executor);

  static const kGeneralTasksProjectId = 'atlas-general-tasks';
  static const kGeneralTasksProjectDescription =
      '__atlas_hidden_general_tasks_project__';

  int _lastGeneratedIdMicros = 0;

  // ── AppMeta keys ──────────────────────────────────────────────────────────
  static const kActiveProjectId = 'active_project_id';
  static const kOllamaHost = 'ollama_host';
  static const kOllamaModel = 'ollama_model';
  static const kProjectAiSummariesEnabled = 'project_ai_summaries_enabled';
  static const kProjectAiSummaryIncludeLibrary =
      'project_ai_summary_include_library';
  static const kProjectAiSummaryAllowBulkRefresh =
      'project_ai_summary_allow_bulk_refresh';
  static const kProjectAiSummaryModel = 'project_ai_summary_model';
  static const kProjectRuntimeDefaultDevLaunchpadYamlPath =
      'project_runtime_default_dev_launchpad_yaml_path';
  static const kProjectRuntimeDefaultCapsuleEnabled =
      'project_runtime_default_capsule_enabled';
  static const kProjectRuntimeDefaultCapsuleMode =
      'project_runtime_default_capsule_mode';
  static const kProjectRuntimeDefaultCapsuleSourcePath =
      'project_runtime_default_capsule_source_path';
  static const kProjectRuntimeDefaultCapsuleProfile =
      'project_runtime_default_capsule_profile';
  static const kTelegramBotToken = 'telegram_bot_token';
  static const kTelegramChatId = 'telegram_chat_id';
  static const kTelegramEnabled = 'telegram_enabled';

  // ── Schema ────────────────────────────────────────────────────────────────
  @override
  int get schemaVersion => 21;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(stages);
      if (from < 3) await m.createTable(workItems);
      if (from < 4) {
        // Defensive: ignore duplicate-column errors from partial migrations
        for (final col in [
          workItems.blockedReason,
          workItems.source,
          workItems.phoneQueue,
          workItems.priority,
          workItems.dueAt,
          workItems.updatedAt,
        ]) {
          try {
            await m.addColumn(workItems, col);
          } on SqliteException catch (e) {
            if (!e.message.toLowerCase().contains('already exists') &&
                !e.message.toLowerCase().contains('duplicate column'))
              rethrow;
          }
        }
        for (final fn in <Future<void> Function()>[
          () => m.createTable(drafts),
          () => m.createTable(dailyReviews),
          () => m.createTable(outboxMessages),
        ]) {
          try {
            await fn();
          } on SqliteException catch (e) {
            if (!e.message.toLowerCase().contains('already exists') &&
                !e.message.toLowerCase().contains('duplicate column'))
              rethrow;
          }
        }
      }
      if (from < 5) {
        for (final fn in <Future<void> Function()>[
          () => m.createTable(eventLog),
          () => m.createTable(documents),
          () => m.createTable(documentLinks),
          () => m.createTable(projectPeople),
          () => m.createTable(projectRisks),
          () => m.createTable(projectDecisions),
        ]) {
          try {
            await fn();
          } catch (_) {}
        }
        for (final col in [
          projects.description,
          projects.desiredOutcome,
          projects.successCriteria,
          projects.status,
          projects.deletedAt,
          projects.deleteReason,
        ]) {
          try {
            await m.addColumn(projects, col);
          } catch (_) {}
        }
        for (final col in [stages.bottleneckOwner, stages.isBottleneck]) {
          try {
            await m.addColumn(stages, col);
          } catch (_) {}
        }
      }
      if (from < 6) {
        for (final col in [
          projects.phase,
          projects.priority,
          projects.scopeIncluded,
          projects.scopeExcluded,
          projects.outcomeSummary,
          projects.lessonsLearned,
        ]) {
          try {
            await m.addColumn(projects, col);
          } catch (_) {}
        }
      }
      if (from < 7) {
        for (final fn in <Future<void> Function()>[
          () => m.createTable(workItemNotes),
          () => m.createTable(workItemAnalyses),
        ]) {
          try {
            await fn();
          } catch (_) {}
        }
      }
      if (from < 8) {
        try {
          await m.createTable(contacts);
        } catch (_) {}
      }
      if (from < 9) {
        for (final fn in <Future<void> Function()>[
          () => m.createTable(tags),
          () => m.createTable(projectTags),
          () => m.createTable(projectMedia),
        ]) {
          try {
            await fn();
          } catch (_) {}
        }
      }
      if (from < 10) {
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_reviews_date '
          'ON daily_reviews(review_date)',
        );
      }
      if (from < 11) {
        for (final fn in <Future<void> Function()>[
          () => m.createTable(projectScanRuns),
          () => m.createTable(projectRegistry),
          () => m.createTable(projectObservations),
        ]) {
          try {
            await fn();
          } catch (_) {}
        }
      }
      if (from < 12) {
        try {
          await m.createTable(localProjectRefreshItems);
        } catch (_) {}
      }
      if (from < 18) {
        try {
          await m.addColumn(projects, projects.category);
        } catch (_) {}
        try {
          await m.createTable(mediaLinks);
        } catch (_) {}
      }
      if (from < 19) {
        for (final fn in <Future<void> Function()>[
          () => m.createTable(projectRuntimeProfiles),
          () => m.createTable(projectRuntimeRuns),
        ]) {
          try {
            await fn();
          } catch (_) {}
        }
      }
      if (from < 20) {
        for (final col in [
          workItems.readiness,
          workItems.size,
          workItems.risk,
          workItems.suggestedActor,
          workItems.verificationNeeded,
          workItems.nextAction,
          workItems.planningNotes,
          workItems.lastReviewedAt,
        ]) {
          try {
            await m.addColumn(workItems, col);
          } catch (_) {}
        }
      }
      if (from < 21) {
        await _repairLegacyMillisecondTimestamps();
      }
    },
    beforeOpen: (_) async {
      await _ensureProjectCompatibilityColumns();
      await _ensureWorkItemTagsTable();
      await _ensureMediaLinksTable();
      await _ensureProjectRuntimeTables();
      await _ensureProjectGitRemotesTable();
      await _ensureProjectEnrichmentTables();
      await _ensureLlmTaskQueueTable();
      await _ensureTimestampUnitTriggers();
      await recoverStaleProjectEnrichmentRuns();
    },
  );

  /// Repairs only values that are unambiguously millisecond-scale dates in
  /// the supported 2000-2100 window. The explicit manifest excludes custom
  /// tables whose documented storage contract is milliseconds.
  Future<void> _repairLegacyMillisecondTimestamps() async {
    for (final field in driftTimestampFields) {
      if (!await _timestampFieldExists(field)) continue;
      await customStatement('''
        UPDATE "${field.table}"
        SET "${field.column}" = CAST("${field.column}" / 1000 AS INTEGER)
        WHERE typeof("${field.column}") = 'integer'
          AND ABS("${field.column}") >= $driftEpochSecondThreshold
          AND ABS("${field.column}") < $legacyMillisecondUpperBound
          AND CAST("${field.column}" / 1000 AS INTEGER)
              >= $legacyRepairMinEpochSeconds
          AND CAST("${field.column}" / 1000 AS INTEGER)
              < $legacyRepairMaxEpochSeconds
      ''');
    }
  }

  /// Rejects raw SQLite writes that bypass Drift's DateTime conversion.
  /// Separate update triggers ensure an unrelated update can still repair or
  /// retain a legacy row until its timestamp column is explicitly touched.
  Future<void> _ensureTimestampUnitTriggers() async {
    for (final field in driftTimestampFields) {
      if (!await _timestampFieldExists(field)) continue;
      final message =
          'timestamp_unit_violation:${field.table}.${field.column}:'
          'expected_epoch_seconds';
      final invalid =
          '''
        NEW."${field.column}" IS NOT NULL AND (
          typeof(NEW."${field.column}") != 'integer' OR
          ABS(NEW."${field.column}") >= $driftEpochSecondThreshold
        )
      ''';
      await customStatement('''
        CREATE TRIGGER IF NOT EXISTS
          "guard_${field.triggerStem}_insert"
        BEFORE INSERT ON "${field.table}"
        FOR EACH ROW WHEN $invalid
        BEGIN
          SELECT RAISE(ABORT, '$message');
        END
      ''');
      await customStatement('''
        CREATE TRIGGER IF NOT EXISTS
          "guard_${field.triggerStem}_update"
        BEFORE UPDATE OF "${field.column}" ON "${field.table}"
        FOR EACH ROW WHEN $invalid
        BEGIN
          SELECT RAISE(ABORT, '$message');
        END
      ''');
    }
  }

  Future<bool> _timestampFieldExists(DriftTimestampField field) async {
    final table = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      variables: [Variable<String>(field.table)],
    ).getSingleOrNull();
    if (table == null) return false;
    final columns = await customSelect(
      'PRAGMA table_info("${field.table}")',
    ).get();
    return columns.any((row) => row.data['name'] == field.column);
  }

  /// Repairs older or partially migrated local databases that already report
  /// schemaVersion 5 but are missing nullable project columns used by the
  /// current Drift-generated Projects table. Without this, even a plain
  /// select(projects) can fail with: no such column: deleted_at.
  Future<void> _ensureProjectCompatibilityColumns() async {
    final addColumns = <String>[
      'ALTER TABLE projects ADD COLUMN description TEXT NULL',
      'ALTER TABLE projects ADD COLUMN desired_outcome TEXT NULL',
      'ALTER TABLE projects ADD COLUMN success_criteria TEXT NULL',
      // Use nullable here — we backfill below so the NOT NULL alias still holds.
      "ALTER TABLE projects ADD COLUMN status TEXT DEFAULT 'active'",
      'ALTER TABLE projects ADD COLUMN category TEXT NULL',
      'ALTER TABLE projects ADD COLUMN deleted_at INTEGER NULL',
      'ALTER TABLE projects ADD COLUMN delete_reason TEXT NULL',
      // v6 lifecycle columns
      'ALTER TABLE projects ADD COLUMN phase TEXT NULL',
      'ALTER TABLE projects ADD COLUMN priority TEXT NULL',
      'ALTER TABLE projects ADD COLUMN scope_included TEXT NULL',
      'ALTER TABLE projects ADD COLUMN scope_excluded TEXT NULL',
      'ALTER TABLE projects ADD COLUMN outcome_summary TEXT NULL',
      'ALTER TABLE projects ADD COLUMN lessons_learned TEXT NULL',
      // work_items columns that may be absent on very old schemas
      "ALTER TABLE work_items ADD COLUMN completed INTEGER NOT NULL DEFAULT 0",
      "ALTER TABLE work_items ADD COLUMN phone_queue INTEGER NOT NULL DEFAULT 0",
      "ALTER TABLE work_items ADD COLUMN readiness TEXT NOT NULL DEFAULT 'ready'",
      "ALTER TABLE work_items ADD COLUMN size TEXT NOT NULL DEFAULT 'medium'",
      "ALTER TABLE work_items ADD COLUMN risk TEXT NOT NULL DEFAULT 'low_code'",
      "ALTER TABLE work_items ADD COLUMN suggested_actor TEXT NOT NULL DEFAULT 'user'",
      "ALTER TABLE work_items ADD COLUMN verification_needed TEXT NOT NULL DEFAULT 'none'",
      'ALTER TABLE work_items ADD COLUMN next_action TEXT NULL',
      'ALTER TABLE work_items ADD COLUMN planning_notes TEXT NULL',
      'ALTER TABLE work_items ADD COLUMN last_reviewed_at INTEGER NULL',
      // project_people compatibility columns (older local DBs may miss these)
      'ALTER TABLE project_people ADD COLUMN role TEXT NULL',
      'ALTER TABLE project_people ADD COLUMN authority TEXT NULL',
      // stages compatibility columns (legacy DBs may miss these)
      "ALTER TABLE stages ADD COLUMN is_bottleneck INTEGER NOT NULL DEFAULT 0",
      'ALTER TABLE stages ADD COLUMN bottleneck_owner TEXT NULL',
      // project_risks / project_decisions columns added after initial table creation
      // Note: "desc" must be quoted — DESC is a reserved SQL keyword.
      'ALTER TABLE project_risks ADD COLUMN "desc" TEXT NULL',
      // severity was added to the Drift schema after some DBs were created
      "ALTER TABLE project_risks ADD COLUMN severity TEXT NOT NULL DEFAULT 'medium'",
      'ALTER TABLE project_decisions ADD COLUMN "ctx" TEXT NULL',
    ];

    for (final stmt in addColumns) {
      try {
        await customStatement(stmt);
      } catch (_) {
        // Expected when column already exists — ignore.
      }
    }

    final createTables = <String>[
      '''CREATE TABLE IF NOT EXISTS contacts (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        title TEXT NULL,
        phone TEXT NULL,
        alternate_phone TEXT NULL,
        email TEXT NULL,
        website TEXT NULL,
        business_name TEXT NULL,
        notes TEXT NULL,
        photo_path TEXT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS work_item_notes (
        id TEXT NOT NULL PRIMARY KEY,
        work_item_id TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS work_item_analyses (
        id TEXT NOT NULL PRIMARY KEY,
        work_item_id TEXT NOT NULL,
        prompt TEXT NOT NULL,
        output TEXT NOT NULL,
        model TEXT NULL,
        created_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS tags (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        color TEXT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS project_tags (
        project_id TEXT NOT NULL,
        tag_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (project_id, tag_id)
      )''',
      '''CREATE TABLE IF NOT EXISTS project_media (
        id TEXT NOT NULL PRIMARY KEY,
        project_id TEXT NOT NULL,
        title TEXT NOT NULL,
        original_filename TEXT NOT NULL,
        stored_path TEXT NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'file',
        mime_type TEXT NULL,
        extension TEXT NULL,
        byte_size INTEGER NULL,
        file_modified_at INTEGER NULL,
        caption TEXT NULL,
        is_cover INTEGER NOT NULL DEFAULT 0,
        source TEXT NULL,
        metadata_json TEXT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS media_links (
        id TEXT NOT NULL PRIMARY KEY,
        media_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )''',
    ];

    for (final stmt in createTables) {
      try {
        await customStatement(stmt);
      } catch (_) {}
    }

    try {
      await customStatement(
        'ALTER TABLE project_media ADD COLUMN is_cover INTEGER NOT NULL DEFAULT 0',
      );
    } catch (_) {}

    // If project_people came from an alternate schema branch (role_type / authority_level),
    // rebuild it into the current expected shape so inserts don't fail on NOT NULL legacy cols.
    try {
      final cols = await customSelect(
        'PRAGMA table_info(project_people)',
      ).get();
      final names = cols
          .map((row) => (row.data['name']?.toString() ?? '').toLowerCase())
          .where((name) => name.isNotEmpty)
          .toSet();
      final needsRebuild =
          names.contains('role_type') || names.contains('authority_level');
      if (needsRebuild) {
        await transaction(() async {
          await customStatement(
            '''CREATE TABLE IF NOT EXISTS project_people_new (
            id TEXT NOT NULL PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            role TEXT NULL,
            authority TEXT NULL,
            created_at INTEGER NOT NULL
          )''',
          );

          final roleExpr = names.contains('role')
              ? (names.contains('role_type')
                    ? 'COALESCE(role, role_type)'
                    : 'role')
              : (names.contains('role_type') ? 'role_type' : 'NULL');
          final authorityExpr = names.contains('authority')
              ? (names.contains('authority_level')
                    ? 'COALESCE(authority, authority_level)'
                    : 'authority')
              : (names.contains('authority_level')
                    ? 'authority_level'
                    : 'NULL');

          await customStatement(
            "INSERT INTO project_people_new (id, project_id, name, role, authority, created_at) "
            "SELECT id, project_id, name, $roleExpr, $authorityExpr, "
            "COALESCE(created_at, CAST(strftime('%s','now') AS INTEGER)) "
            "FROM project_people",
          );

          await customStatement('DROP TABLE project_people');
          await customStatement(
            'ALTER TABLE project_people_new RENAME TO project_people',
          );
        });
      }
    } catch (_) {
      // If table doesn't exist yet or pragma fails, regular migrations handle creation.
    }
    // Backfill any rows where non-nullable columns ended up NULL due to
    // partial migrations or SQLite schema-default edge cases.
    final backfills = <String>[
      "UPDATE projects SET status = 'active' WHERE status IS NULL",
      "UPDATE work_items SET status = 'next' WHERE status IS NULL",
      "UPDATE work_items SET priority = 'normal' WHERE priority IS NULL",
      "UPDATE work_items SET completed = 0 WHERE completed IS NULL",
      "UPDATE work_items SET phone_queue = 0 WHERE phone_queue IS NULL",
      // Prevent null-mapping crashes for non-null Drift stage fields
      "UPDATE stages SET title = 'Tasks' WHERE title IS NULL OR TRIM(title) = ''",
      "UPDATE stages SET position = 0 WHERE position IS NULL",
      "UPDATE stages SET created_at = CAST(strftime('%s','now') AS INTEGER) WHERE created_at IS NULL",
      "UPDATE stages SET is_bottleneck = 0 WHERE is_bottleneck IS NULL",
    ];

    for (final stmt in backfills) {
      try {
        await customStatement(stmt);
      } catch (_) {}
    }
  }

  Future<void> _ensureProjectRuntimeTables() async {
    final statements = <String>[
      '''CREATE TABLE IF NOT EXISTS project_runtime_profiles (
        id TEXT NOT NULL PRIMARY KEY,
        project_id TEXT NOT NULL UNIQUE,
        enabled INTEGER NOT NULL DEFAULT 0,
        working_directory TEXT NULL,
        launch_command TEXT NULL,
        stop_command TEXT NULL,
        test_commands_json TEXT NOT NULL DEFAULT '[]',
        ports_json TEXT NOT NULL DEFAULT '[]',
        urls_json TEXT NOT NULL DEFAULT '[]',
        health_urls_json TEXT NOT NULL DEFAULT '[]',
        notes TEXT NULL,
        autostart INTEGER NOT NULL DEFAULT 0,
        capsule_enabled INTEGER NOT NULL DEFAULT 1,
        capsule_mode TEXT NOT NULL DEFAULT 'check',
        capsule_source_path TEXT NULL,
        capsule_profile TEXT NULL,
        import_source TEXT NULL,
        last_imported_at INTEGER NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''',
      '''CREATE TABLE IF NOT EXISTS project_runtime_runs (
        id TEXT NOT NULL PRIMARY KEY,
        profile_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        action TEXT NOT NULL,
        command TEXT NULL,
        status TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        completed_at INTEGER NULL,
        exit_code INTEGER NULL,
        output_text TEXT NULL,
        error_text TEXT NULL,
        capsule_status TEXT NULL,
        capsule_output_text TEXT NULL,
        metadata_json TEXT NULL
      )''',
      'CREATE INDEX IF NOT EXISTS idx_project_runtime_runs_project_started '
          'ON project_runtime_runs(project_id, started_at DESC)',
    ];

    for (final statement in statements) {
      try {
        await customStatement(statement);
      } catch (_) {}
    }
  }

  // ── AppMeta helpers ───────────────────────────────────────────────────────

  Future<String?> getMetaString(String key) async {
    final row = await (select(
      appMeta,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setMetaString(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await (delete(appMeta)..where((t) => t.key.equals(key))).go();
    } else {
      await into(appMeta).insertOnConflictUpdate(
        AppMetaCompanion(key: Value(key), value: Value(value)),
      );
    }
  }

  Stream<String?> watchMetaString(String key) {
    return (select(appMeta)..where((t) => t.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  // ── Projects ──────────────────────────────────────────────────────────────

  bool _isVisibleProject(Project project, {bool includeArchived = true}) {
    final status = project.status.trim().toLowerCase();
    return project.deletedAt == null &&
        status != 'deleted' &&
        (includeArchived || status != 'archived') &&
        project.id != kGeneralTasksProjectId &&
        project.description != kGeneralTasksProjectDescription;
  }

  Stream<List<Project>> watchProjects() =>
      (select(
        projects,
      )..orderBy([(t) => OrderingTerm.asc(t.title)])).watch().map(
        (rows) => rows
            .where((project) => _isVisibleProject(project))
            .toList(growable: false),
      );

  Stream<Project?> watchProject(String id) =>
      (select(projects)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Stream<Project?> watchActiveProject() {
    return watchMetaString(kActiveProjectId).asyncMap((id) async {
      if (id == null || id.isEmpty) return null;
      return (select(
        projects,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
    });
  }

  Future<void> createProject(
    String id,
    String title,
    DateTime createdAt,
  ) async {
    debugPrint('[Atlas] createProject: id=$id title="$title"');
    await into(projects).insert(
      ProjectsCompanion(
        id: Value(id),
        title: Value(title),
        createdAt: Value(createdAt),
        status: const Value('active'),
      ),
    );

    // Auto-create a default stage so the Work screen is immediately usable
    final stageId = _newMicrosId('stage');
    debugPrint(
      '[Atlas] createProject: creating default stage $stageId for project $id',
    );
    await into(stages).insert(
      StagesCompanion(
        id: Value(stageId),
        projectId: Value(id),
        title: const Value('Tasks'),
        position: const Value(0),
        createdAt: Value(DateTime.now()),
      ),
    );

    // Activate if active_project_id is absent, empty, or points to a missing/deleted project
    final current = await getMetaString(kActiveProjectId);
    debugPrint('[Atlas] createProject: current active_project_id=$current');
    bool shouldActivate = current == null || current.isEmpty;
    if (!shouldActivate) {
      final existing = await (select(
        projects,
      )..where((t) => t.id.equals(current))).getSingleOrNull();
      if (existing == null) {
        debugPrint(
          '[Atlas] createProject: active project "$current" is missing/deleted – switching to $id',
        );
        shouldActivate = true;
      }
    }
    if (shouldActivate) {
      await setMetaString(kActiveProjectId, id);
      debugPrint('[Atlas] createProject: set active_project_id=$id');
    }

    try {
      final allActive = await (select(
        projects,
      )..where((t) => t.deletedAt.isNull())).get();
      final stageCount = (await getStagesForProject(id)).length;
      debugPrint(
        '[Atlas] createProject: done – total projects=${allActive.length}, stages for new=$stageCount',
      );
    } catch (e) {
      debugPrint('[Atlas] createProject: done (log query failed: $e)');
    }
  }

  Future<void> setActiveProjectId(String? id) =>
      setMetaString(kActiveProjectId, id);

  /// Ensures every non-deleted project has at least one stage.
  /// Run at startup to heal projects created before auto-stage logic existed.
  Future<void> ensureDefaultStagesForProjects() async {
    final allProjects = await (select(
      projects,
    )..where((t) => t.deletedAt.isNull())).get();
    debugPrint(
      '[Atlas] ensureDefaultStages: checking ${allProjects.length} project(s)',
    );
    for (final p in allProjects) {
      final existing = await getStagesForProject(p.id);
      debugPrint(
        '[Atlas] ensureDefaultStages: project "${p.title}" has ${existing.length} stage(s)',
      );
      if (existing.isEmpty) {
        final stageId = _newMicrosId('stage');
        debugPrint(
          '[Atlas] ensureDefaultStages: creating default stage for project ${p.id}',
        );
        await into(stages).insert(
          StagesCompanion(
            id: Value(stageId),
            projectId: Value(p.id),
            title: const Value('Tasks'),
            position: const Value(0),
            createdAt: Value(DateTime.now()),
          ),
        );
      }
    }
  }

  Future<void> updateProjectMeta(String id, Map<String, Object?> fields) async {
    Value<T?> _v<T>(String key) => fields.containsKey(key)
        ? Value(fields[key] as T?)
        : const Value.absent();

    final companion = ProjectsCompanion(
      title: fields.containsKey('title')
          ? Value(fields['title'] as String)
          : const Value.absent(),
      owner: _v<String>('owner'),
      status: fields.containsKey('status')
          ? Value(normalizeProjectStatusValue(fields['status'] as String?))
          : const Value.absent(),
      category: _v<String>('category'),
      description: _v<String>('description'),
      desiredOutcome: _v<String>('desiredOutcome'),
      successCriteria: _v<String>('successCriteria'),
      phase: _v<String>('phase'),
      priority: _v<String>('priority'),
      scopeIncluded: _v<String>('scopeIncluded'),
      scopeExcluded: _v<String>('scopeExcluded'),
      outcomeSummary: _v<String>('outcomeSummary'),
      lessonsLearned: _v<String>('lessonsLearned'),
    );
    await (update(projects)..where((t) => t.id.equals(id))).write(companion);
  }

  Future<void> softDeleteProject(String id, String reason) async {
    await (update(projects)..where((t) => t.id.equals(id))).write(
      ProjectsCompanion(
        status: const Value('deleted'),
        deletedAt: Value(DateTime.now()),
        deleteReason: Value(reason),
      ),
    );
  }

  // ProjectFull is just a Project (typedef). These return all non-deleted.
  Stream<List<ProjectFull>> watchProjectsFull() => watchProjects();

  Future<List<ProjectFull>> getProjectsFull() =>
      (select(
        projects,
      )..orderBy([(t) => OrderingTerm.asc(t.title)])).get().then(
        (rows) => rows.where(_isVisibleProject).toList(growable: false),
      );

  Future<List<Project>> getVisibleProjects({bool includeArchived = true}) =>
      (select(
        projects,
      )..orderBy([(t) => OrderingTerm.asc(t.title)])).get().then(
        (rows) => rows
            .where(
              (project) =>
                  _isVisibleProject(project, includeArchived: includeArchived),
            )
            .toList(growable: false),
      );

  Future<ProjectFull?> getProjectFull(String id) =>
      (select(projects)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Project?> getGeneralTasksProject() async {
    final rows =
        await (select(projects)
              ..where(
                (t) =>
                    t.id.equals(kGeneralTasksProjectId) |
                    t.description.equals(kGeneralTasksProjectDescription),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
              ..limit(1))
            .get();
    return rows.isEmpty ? null : rows.single;
  }

  Future<List<Project>> getSummaryEligibleProjects() => getProjectsFull().then(
    (rows) => rows
        .where((project) => isSummaryEligibleProjectStatus(project.status))
        .toList(growable: false),
  );

  // ── Stages ────────────────────────────────────────────────────────────────

  Stream<List<Stage>> watchStagesForProject(String projectId) =>
      (select(stages)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .watch();

  Future<List<Stage>> getStagesForProject(String projectId) =>
      (select(stages)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

  Stream<Stage?> watchActiveStageForProject(String projectId) {
    final key = 'active_stage_$projectId';
    return watchMetaString(key).asyncMap((id) async {
      if (id == null || id.isEmpty) {
        // Default to first stage
        return (select(stages)
              ..where((t) => t.projectId.equals(projectId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)])
              ..limit(1))
            .getSingleOrNull();
      }
      return (select(stages)..where((t) => t.id.equals(id))).getSingleOrNull();
    });
  }

  Future<void> setActiveStageIdForProject(String projectId, String stageId) =>
      setMetaString('active_stage_$projectId', stageId);

  // Bottleneck / owner on Stage
  Stream<String?> watchBottleneckOwner(String stageId) =>
      (select(stages)..where((t) => t.id.equals(stageId)))
          .watchSingleOrNull()
          .map((s) => s?.bottleneckOwner);

  Future<void> setBottleneckOwner(String stageId, String? owner) async {
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(bottleneckOwner: Value(owner)),
    );
  }

  Stream<bool> watchIsBottleneck(String stageId) =>
      (select(stages)..where((t) => t.id.equals(stageId)))
          .watchSingleOrNull()
          .map((s) => s?.isBottleneck ?? false);

  Future<void> setIsBottleneck(String stageId, bool v) async {
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(isBottleneck: Value(v)),
    );
  }

  Future<void> addStage(String projectId, String title) async {
    final existing = await (select(
      stages,
    )..where((t) => t.projectId.equals(projectId))).get();
    final nextPos = existing.isEmpty
        ? 0
        : existing.map((s) => s.position).reduce((a, b) => a > b ? a : b) + 1;
    await into(stages).insert(
      StagesCompanion.insert(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        projectId: projectId,
        title: title,
        position: nextPos,
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<void> updateStageTitle(String stageId, String title) async {
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(title: Value(title)),
    );
  }

  Future<void> deleteStage(String stageId) async {
    await (delete(stages)..where((t) => t.id.equals(stageId))).go();
  }

  Future<void> reorderStage(String stageId, int newPosition) async {
    await (update(stages)..where((t) => t.id.equals(stageId))).write(
      StagesCompanion(position: Value(newPosition)),
    );
  }

  // ── Work Items ────────────────────────────────────────────────────────────

  Stream<List<WorkItem>> watchWorkItemsForStage(String stageId) =>
      (select(workItems)
            ..where(
              (t) =>
                  t.stageId.equals(stageId) &
                  t.status.isNotIn(['done', 'archived']),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .watch();

  Stream<List<WorkItem>> watchTodayItems() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return (select(workItems)..where(
          (t) =>
              t.status.isNotIn(['done', 'archived']) &
              (t.status.equals('doing') |
                  t.phoneQueue.equals(true) |
                  t.dueAt.isSmallerOrEqualValue(tomorrow) |
                  t.priority.isIn(['high', 'urgent'])),
        ))
        .watch();
  }

  Future<List<WorkItem>> getTodayItems() {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    return (select(workItems)..where(
          (t) =>
              t.status.isNotIn(['done', 'archived']) &
              (t.status.equals('doing') |
                  t.phoneQueue.equals(true) |
                  t.dueAt.isSmallerOrEqualValue(tomorrow) |
                  t.priority.isIn(['high', 'urgent'])),
        ))
        .get();
  }

  Future<List<WorkItem>> getAllActiveWorkItems() => (select(
    workItems,
  )..where((t) => t.status.isNotIn(['done', 'archived']))).get();

  Future<List<WorkItem>> getBlockedItems() =>
      (select(workItems)..where(
            (t) =>
                t.blockedReason.isNotNull() &
                t.status.isNotIn(['done', 'archived']),
          ))
          .get();

  Future<WorkItem?> getWorkItem(String id) =>
      (select(workItems)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<WorkItem>> getWorkItemsForProject(String projectId) async {
    final stageList = await getStagesForProject(projectId);
    if (stageList.isEmpty) return [];
    final ids = stageList.map((s) => s.id).toList();
    return (select(workItems)..where((t) => t.stageId.isIn(ids))).get();
  }

  Future<String> addWorkItem({
    required String stageId,
    required String title,
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
    final id = _newMicrosId();
    final now = DateTime.now();
    await into(workItems).insert(
      WorkItemsCompanion(
        id: Value(id),
        stageId: Value(stageId),
        title: Value(title),
        description: Value(description),
        owner: Value(owner),
        status: Value(status),
        priority: Value(priority),
        dueAt: Value(dueAt),
        createdAt: Value(now),
        updatedAt: Value(now),
        source: Value(source),
        blockedReason: Value(blockedReason),
        readiness: Value(readiness),
        size: Value(size),
        risk: Value(risk),
        suggestedActor: Value(suggestedActor),
        verificationNeeded: Value(verificationNeeded),
        nextAction: Value(nextAction),
        planningNotes: Value(planningNotes),
        lastReviewedAt: Value(lastReviewedAt),
      ),
    );
    return id;
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
    await (update(workItems)..where((t) => t.id.equals(id))).write(
      WorkItemsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        description: description != null
            ? Value(description)
            : const Value.absent(),
        owner: owner != null ? Value(owner) : const Value.absent(),
        status: status != null ? Value(status) : const Value.absent(),
        priority: priority != null ? Value(priority) : const Value.absent(),
        dueAt: clearDueAt
            ? const Value(null)
            : dueAt != null
            ? Value(dueAt)
            : const Value.absent(),
        blockedReason: clearBlockedReason
            ? const Value(null)
            : blockedReason != null
            ? Value(blockedReason)
            : const Value.absent(),
        phoneQueue: phoneQueue != null
            ? Value(phoneQueue)
            : const Value.absent(),
        readiness: readiness != null ? Value(readiness) : const Value.absent(),
        size: size != null ? Value(size) : const Value.absent(),
        risk: risk != null ? Value(risk) : const Value.absent(),
        suggestedActor: suggestedActor != null
            ? Value(suggestedActor)
            : const Value.absent(),
        verificationNeeded: verificationNeeded != null
            ? Value(verificationNeeded)
            : const Value.absent(),
        nextAction: clearNextAction
            ? const Value(null)
            : nextAction != null
            ? Value(nextAction)
            : const Value.absent(),
        planningNotes: clearPlanningNotes
            ? const Value(null)
            : planningNotes != null
            ? Value(planningNotes)
            : const Value.absent(),
        lastReviewedAt: clearLastReviewedAt
            ? const Value(null)
            : lastReviewedAt != null
            ? Value(lastReviewedAt)
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> setWorkItemStatus(String id, String status) async {
    await (update(workItems)..where((t) => t.id.equals(id))).write(
      WorkItemsCompanion(
        status: Value(status),
        completed: Value(status == 'done'),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> toggleWorkDone(String id) async {
    final item = await getWorkItem(id);
    if (item == null) return;
    final isDone = item.status == 'done';
    await setWorkItemStatus(id, isDone ? 'next' : 'done');
  }

  // Work item owner (used in governance)
  Stream<String?> watchWorkOwner(String workItemId) =>
      (select(workItems)..where((t) => t.id.equals(workItemId)))
          .watchSingleOrNull()
          .map((i) => i?.owner);

  Future<String?> getWorkOwner(String workItemId) async {
    final item = await getWorkItem(workItemId);
    return item?.owner;
  }

  Future<void> setWorkOwner(String workItemId, String? owner) async {
    await updateWorkItem(id: workItemId, owner: owner ?? '');
  }

  // ── Drafts ────────────────────────────────────────────────────────────────

  Stream<List<Draft>> watchDrafts() => (select(
    drafts,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  Future<String> saveDraft({
    required String kind,
    required String title,
    required String body,
    String? inputJson,
    String? projectId,
    String? workItemId,
  }) async {
    final id = _newMicrosId();
    final now = DateTime.now();
    await into(drafts).insert(
      DraftsCompanion(
        id: Value(id),
        kind: Value(kind),
        title: Value(title),
        body: Value(body),
        inputJson: Value(inputJson),
        projectId: Value(projectId),
        workItemId: Value(workItemId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<Draft?> getDraft(String id) =>
      (select(drafts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> updateDraftReview({
    required String id,
    required bool accepted,
    String? inputJson,
    String? body,
  }) async {
    await (update(drafts)..where((t) => t.id.equals(id))).write(
      DraftsCompanion(
        accepted: Value(accepted),
        inputJson: inputJson != null ? Value(inputJson) : const Value.absent(),
        body: body != null ? Value(body) : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteDraft(String id) =>
      (delete(drafts)..where((t) => t.id.equals(id))).go();

  /// Delete all project_summary drafts for [projectId] before saving a fresh one.
  Future<void> deleteProjectSummaryDrafts(String projectId) =>
      (delete(drafts)..where(
            (t) =>
                t.projectId.equals(projectId) &
                t.kind.equals('project_summary'),
          ))
          .go();

  /// Latest cached AI project summary draft for [projectId], or null.
  Future<Draft?> getLatestProjectSummaryDraft(String projectId) =>
      (select(drafts)
            ..where(
              (t) =>
                  t.projectId.equals(projectId) &
                  t.kind.equals('project_summary'),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(1))
          .getSingleOrNull();

  /// Latest cached AI project change summary draft for [projectId], or null.
  Future<Draft?> getLatestProjectChangeSummaryDraft(String projectId) =>
      (select(drafts)
            ..where(
              (t) =>
                  t.projectId.equals(projectId) &
                  t.kind.equals('project_change_summary'),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<Draft?> getLatestProjectDraftByKind(String projectId, String kind) =>
      (select(drafts)
            ..where((t) => t.projectId.equals(projectId) & t.kind.equals(kind))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(1))
          .getSingleOrNull();

  /// True if a project_summary draft for [projectId] was saved today.
  Future<bool> hasTodayProjectSummaryDraft(String projectId) async {
    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day);
    final rows =
        await (select(drafts)
              ..where(
                (t) =>
                    t.projectId.equals(projectId) &
                    t.kind.equals('project_summary') &
                    t.createdAt.isBiggerOrEqualValue(startOfDay),
              )
              ..limit(1))
            .get();
    return rows.isNotEmpty;
  }

  /// Returns a map of documentId → storedPath for all documents linked to [projectId].
  Future<Map<String, String?>> getDocumentPathsForProject(
    String projectId,
  ) async {
    final docs = await (select(
      documents,
    )..where((t) => t.projectId.equals(projectId))).get();
    return {for (final d in docs) d.id: d.storedPath};
  }

  // ── Project governance ────────────────────────────────────────────────────

  Stream<List<Contact>> watchContacts() =>
      (select(contacts)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<List<Contact>> getContacts() =>
      (select(contacts)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<Contact?> getContact(String id) =>
      (select(contacts)..where((t) => t.id.equals(id))).getSingleOrNull();

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
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('Contact name is required.');
    }
    final now = DateTime.now();
    final contactId = id ?? _newMicrosId('contact');
    final existing = await getContact(contactId);
    await into(contacts).insertOnConflictUpdate(
      ContactsCompanion(
        id: Value(contactId),
        name: Value(trimmedName),
        title: Value(_blankToNull(title)),
        phone: Value(_blankToNull(phone)),
        alternatePhone: Value(_blankToNull(alternatePhone)),
        email: Value(_blankToNull(email)),
        website: Value(_blankToNull(website)),
        businessName: Value(_blankToNull(businessName)),
        notes: Value(_blankToNull(notes)),
        photoPath: Value(_blankToNull(photoPath)),
        createdAt: Value(existing?.createdAt ?? now),
        updatedAt: Value(now),
      ),
    );
    return contactId;
  }

  Future<void> deleteContact(String id) =>
      (delete(contacts)..where((t) => t.id.equals(id))).go();

  Future<Contact?> findContactForImport({
    String? id,
    String? email,
    String? name,
  }) async {
    final cleanId = _blankToNull(id);
    if (cleanId != null) {
      final byId = await getContact(cleanId);
      if (byId != null) return byId;
    }
    final cleanEmail = _blankToNull(email)?.toLowerCase();
    if (cleanEmail != null) {
      final byEmail = await (select(
        contacts,
      )..where((t) => t.email.lower().equals(cleanEmail))).getSingleOrNull();
      if (byEmail != null) return byEmail;
    }
    final cleanName = _blankToNull(name)?.toLowerCase();
    if (cleanName != null) {
      return (select(
        contacts,
      )..where((t) => t.name.lower().equals(cleanName))).getSingleOrNull();
    }
    return null;
  }

  String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<List<ProjectPerson>> getProjectPeople(String projectId) =>
      (select(projectPeople)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  Future<void> addProjectPerson(
    String projectId,
    String name,
    String? role,
    String? authority,
  ) async {
    final id = _newMicrosId();
    await into(projectPeople).insert(
      ProjectPeopleCompanion(
        id: Value(id),
        projectId: Value(projectId),
        name: Value(name),
        role: Value(role),
        authority: Value(authority),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateProjectPerson(
    String personId,
    String name,
    String? role,
    String? authority,
  ) async {
    await (update(projectPeople)..where((t) => t.id.equals(personId))).write(
      ProjectPeopleCompanion(
        name: Value(name),
        role: Value(role),
        authority: Value(authority),
      ),
    );
  }

  Future<void> deleteProjectPerson(String personId) =>
      (delete(projectPeople)..where((t) => t.id.equals(personId))).go();

  Future<List<ProjectRisk>> getProjectRisks(String projectId) =>
      (select(projectRisks)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<String> addProjectRisk(
    String projectId,
    String title,
    String? desc,
    String severity,
  ) async {
    final id = _newMicrosId();
    final now = DateTime.now();
    try {
      await into(projectRisks).insert(
        ProjectRisksCompanion(
          id: Value(id),
          projectId: Value(projectId),
          title: Value(title),
          desc: Value(desc),
          severity: Value(severity),
          createdAt: Value(now),
        ),
      );
    } on SqliteException catch (e) {
      // Some databases were created when ProjectRisks had an updatedAt field.
      if (!e.message.contains('updated_at')) rethrow;
      final seconds = now.millisecondsSinceEpoch ~/ 1000;
      await customStatement(
        'INSERT INTO project_risks '
        '(id, project_id, title, "desc", severity, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, projectId, title, desc, severity, seconds, seconds],
      );
    }
    return id;
  }

  Future<void> deleteProjectRisk(String riskId) =>
      (delete(projectRisks)..where((t) => t.id.equals(riskId))).go();

  Future<List<ProjectDecision>> getProjectDecisions(String projectId) =>
      (select(projectDecisions)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<String> addProjectDecision(
    String projectId,
    String title,
    String? ctx,
    String? decider,
  ) async {
    final id = _newMicrosId();
    final now = DateTime.now();
    try {
      await into(projectDecisions).insert(
        ProjectDecisionsCompanion(
          id: Value(id),
          projectId: Value(projectId),
          title: Value(title),
          ctx: Value(ctx),
          decider: Value(decider),
          createdAt: Value(now),
        ),
      );
    } on SqliteException catch (e) {
      // Some databases were created when ProjectDecisions had an updatedAt field.
      // That column was later removed from the Drift schema, so generated INSERTs
      // no longer include it — triggering NOT NULL failures on legacy DBs.
      if (!e.message.contains('updated_at')) rethrow;
      final seconds = now.millisecondsSinceEpoch ~/ 1000;
      await customStatement(
        'INSERT INTO project_decisions '
        '(id, project_id, title, ctx, decider, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, projectId, title, ctx, decider, seconds, seconds],
      );
    }
    return id;
  }

  Future<void> deleteProjectDecision(String decisionId) =>
      (delete(projectDecisions)..where((t) => t.id.equals(decisionId))).go();

  // Project tags

  Stream<List<Tag>> watchTags() =>
      (select(tags)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<List<Tag>> getTags() =>
      (select(tags)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<Tag?> getTag(String id) =>
      (select(tags)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Tag?> findTagByName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return Future.value(null);
    return (select(tags)
          ..where((t) => t.name.lower().equals(trimmed.toLowerCase())))
        .getSingleOrNull();
  }

  Future<String> saveTag({
    String? id,
    required String name,
    String? color,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Tag name is required.');
    }
    final now = DateTime.now();
    final tagId = id ?? _newMicrosId('tag');
    final existing = await getTag(tagId);
    await into(tags).insertOnConflictUpdate(
      TagsCompanion(
        id: Value(tagId),
        name: Value(trimmed),
        color: Value(_blankToNull(color)),
        createdAt: Value(existing?.createdAt ?? now),
        updatedAt: Value(now),
      ),
    );
    return tagId;
  }

  Future<void> updateTag(String id, {String? name, String? color}) async {
    await (update(tags)..where((t) => t.id.equals(id))).write(
      TagsCompanion(
        name: name != null ? Value(name.trim()) : const Value.absent(),
        color: color != null
            ? Value(_blankToNull(color))
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteTag(String id) async {
    await transaction(() async {
      await (delete(projectTags)..where((t) => t.tagId.equals(id))).go();
      await (delete(tags)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<void> assignTagToProject(String projectId, String tagId) async {
    await into(projectTags).insertOnConflictUpdate(
      ProjectTagsCompanion(
        projectId: Value(projectId),
        tagId: Value(tagId),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> unassignTagFromProject(String projectId, String tagId) =>
      (delete(projectTags)..where(
            (t) => t.projectId.equals(projectId) & t.tagId.equals(tagId),
          ))
          .go();

  Future<void> setProjectTags(String projectId, Iterable<String> tagIds) async {
    final uniqueIds = tagIds.where((id) => id.trim().isNotEmpty).toSet();
    await transaction(() async {
      await (delete(
        projectTags,
      )..where((t) => t.projectId.equals(projectId))).go();
      for (final tagId in uniqueIds) {
        await assignTagToProject(projectId, tagId);
      }
    });
  }

  Future<List<ProjectTagAssignment>> getProjectTagAssignments(
    String projectId,
  ) => (select(projectTags)..where((t) => t.projectId.equals(projectId))).get();

  Stream<List<Tag>> watchTagsForProject(String projectId) {
    final query =
        select(
            tags,
          ).join([innerJoin(projectTags, projectTags.tagId.equalsExp(tags.id))])
          ..where(projectTags.projectId.equals(projectId))
          ..orderBy([OrderingTerm.asc(tags.name)]);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(tags)).toList(growable: false),
    );
  }

  Future<List<Tag>> getTagsForProject(String projectId) {
    final query =
        select(
            tags,
          ).join([innerJoin(projectTags, projectTags.tagId.equalsExp(tags.id))])
          ..where(projectTags.projectId.equals(projectId))
          ..orderBy([OrderingTerm.asc(tags.name)]);
    return query.get().then(
      (rows) => rows.map((row) => row.readTable(tags)).toList(growable: false),
    );
  }

  Stream<List<Project>> watchProjectsForTag(String tagId) {
    final query =
        select(projects).join([
            innerJoin(
              projectTags,
              projectTags.projectId.equalsExp(projects.id),
            ),
          ])
          ..where(projectTags.tagId.equals(tagId) & projects.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(projects.createdAt)]);
    return query.watch().map(
      (rows) =>
          rows.map((row) => row.readTable(projects)).toList(growable: false),
    );
  }

  Future<List<Project>> getProjectsForTag(String tagId) {
    final query =
        select(projects).join([
            innerJoin(
              projectTags,
              projectTags.projectId.equalsExp(projects.id),
            ),
          ])
          ..where(projectTags.tagId.equals(tagId) & projects.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(projects.createdAt)]);
    return query.get().then(
      (rows) =>
          rows.map((row) => row.readTable(projects)).toList(growable: false),
    );
  }

  Future<List<Project>> getProjectsMatchingTags(
    Iterable<String> tagIds, {
    bool matchAll = false,
  }) async {
    final ids = tagIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return getProjectsFull();
    final assignments = await (select(
      projectTags,
    )..where((t) => t.tagId.isIn(ids))).get();
    final counts = <String, int>{};
    for (final assignment in assignments) {
      counts.update(
        assignment.projectId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final projectIds = counts.entries
        .where((entry) => !matchAll || entry.value == ids.length)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (projectIds.isEmpty) return const <Project>[];
    return (select(projects)
          ..where((t) => t.id.isIn(projectIds) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  // Project media

  Stream<List<ProjectMediaItem>> watchAllProjectMedia() => (select(
    projectMedia,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  Future<List<ProjectMediaItem>> getAllProjectMedia() => (select(
    projectMedia,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();

  Stream<List<ProjectMediaItem>> watchProjectMedia(String projectId) =>
      (select(projectMedia)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<List<ProjectMediaItem>> getProjectMedia(String projectId) =>
      (select(projectMedia)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<ProjectMediaItem?> getProjectMediaItem(String id) =>
      (select(projectMedia)..where((t) => t.id.equals(id))).getSingleOrNull();

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
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw ArgumentError('Media title is required.');
    }
    final now = DateTime.now();
    final mediaId = id ?? _newMicrosId('media');
    final existing = await getProjectMediaItem(mediaId);
    await into(projectMedia).insertOnConflictUpdate(
      ProjectMediaCompanion(
        id: Value(mediaId),
        projectId: Value(projectId),
        title: Value(trimmedTitle),
        originalFilename: Value(originalFilename),
        storedPath: Value(storedPath),
        mediaType: Value(mediaType),
        mimeType: Value(_blankToNull(mimeType)),
        extension: Value(_blankToNull(extension)),
        byteSize: Value(byteSize),
        fileModifiedAt: Value(fileModifiedAt),
        caption: Value(_blankToNull(caption)),
        isCover: Value(isCover),
        source: Value(_blankToNull(source)),
        metadataJson: Value(_blankToNull(metadataJson)),
        createdAt: Value(existing?.createdAt ?? now),
        updatedAt: Value(now),
      ),
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
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', path);
    }
    final stat = file.statSync();
    final filename = p.basename(path);
    final ext = p.extension(filename).replaceFirst('.', '').toLowerCase();
    final cleanExt = ext.isEmpty ? null : ext;
    return saveProjectMedia(
      projectId: projectId,
      title: title?.trim().isNotEmpty == true ? title!.trim() : filename,
      originalFilename: filename,
      storedPath: path,
      mediaType: _mediaTypeForExtension(cleanExt),
      mimeType: mimeTypeForExtension(cleanExt),
      extension: cleanExt,
      byteSize: stat.size,
      fileModifiedAt: stat.modified,
      caption: caption,
      isCover: isCover,
      source: source,
      metadataJson: metadataJson,
    );
  }

  Future<void> updateProjectMedia(
    String id, {
    String? title,
    String? caption,
    bool? isCover,
    String? source,
    String? metadataJson,
  }) async {
    await (update(projectMedia)..where((t) => t.id.equals(id))).write(
      ProjectMediaCompanion(
        title: title != null ? Value(title.trim()) : const Value.absent(),
        caption: caption != null
            ? Value(_blankToNull(caption))
            : const Value.absent(),
        isCover: isCover != null ? Value(isCover) : const Value.absent(),
        source: source != null
            ? Value(_blankToNull(source))
            : const Value.absent(),
        metadataJson: metadataJson != null
            ? Value(_blankToNull(metadataJson))
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteProjectMedia(String id) async {
    await _ensureMediaLinksTable();
    await transaction(() async {
      await (delete(mediaLinks)..where((t) => t.mediaId.equals(id))).go();
      await (delete(projectMedia)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<void> linkProjectMediaToEntity({
    required String mediaId,
    required String entityType,
    required String entityId,
  }) async {
    await _ensureMediaLinksTable();
    final cleanMediaId = mediaId.trim();
    final cleanEntityType = entityType.trim();
    final cleanEntityId = entityId.trim();
    if (cleanMediaId.isEmpty ||
        cleanEntityType.isEmpty ||
        cleanEntityId.isEmpty) {
      throw ArgumentError('Media link requires mediaId, entityType, entityId.');
    }
    final existing =
        await (select(mediaLinks)..where(
              (t) =>
                  t.mediaId.equals(cleanMediaId) &
                  t.entityType.equals(cleanEntityType) &
                  t.entityId.equals(cleanEntityId),
            ))
            .getSingleOrNull();
    if (existing != null) return;
    await into(mediaLinks).insert(
      MediaLinksCompanion(
        id: Value(
          [
            cleanMediaId,
            cleanEntityType,
            cleanEntityId,
          ].map(_safeIdSegment).join('_'),
        ),
        mediaId: Value(cleanMediaId),
        entityType: Value(cleanEntityType),
        entityId: Value(cleanEntityId),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> unlinkProjectMediaFromEntity({
    required String mediaId,
    required String entityType,
    required String entityId,
  }) async {
    await _ensureMediaLinksTable();
    await (delete(mediaLinks)..where(
          (t) =>
              t.mediaId.equals(mediaId) &
              t.entityType.equals(entityType) &
              t.entityId.equals(entityId),
        ))
        .go();
  }

  Stream<List<ProjectMediaItem>> watchProjectMediaForEntity({
    required String entityType,
    required String entityId,
  }) {
    final query =
        select(projectMedia).join([
            innerJoin(
              mediaLinks,
              mediaLinks.mediaId.equalsExp(projectMedia.id),
            ),
          ])
          ..where(
            mediaLinks.entityType.equals(entityType) &
                mediaLinks.entityId.equals(entityId),
          )
          ..orderBy([OrderingTerm.desc(mediaLinks.createdAt)]);
    return query.watch().map(
      (rows) => rows
          .map((row) => row.readTable(projectMedia))
          .toList(growable: false),
    );
  }

  Future<List<ProjectMediaItem>> getProjectMediaForEntity({
    required String entityType,
    required String entityId,
  }) {
    final query =
        select(projectMedia).join([
            innerJoin(
              mediaLinks,
              mediaLinks.mediaId.equalsExp(projectMedia.id),
            ),
          ])
          ..where(
            mediaLinks.entityType.equals(entityType) &
                mediaLinks.entityId.equals(entityId),
          )
          ..orderBy([OrderingTerm.desc(mediaLinks.createdAt)]);
    return query.get().then(
      (rows) => rows
          .map((row) => row.readTable(projectMedia))
          .toList(growable: false),
    );
  }

  Future<void> setProjectCoverMedia(String projectId, String mediaId) async {
    await transaction(() async {
      await (update(projectMedia)..where((t) => t.projectId.equals(projectId)))
          .write(const ProjectMediaCompanion(isCover: Value(false)));
      await (update(
            projectMedia,
          )..where((t) => t.projectId.equals(projectId) & t.id.equals(mediaId)))
          .write(
            ProjectMediaCompanion(
              isCover: const Value(true),
              updatedAt: Value(DateTime.now()),
            ),
          );
    });
  }

  String _mediaTypeForExtension(String? extension) {
    const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
    const videos = {'mp4', 'mov', 'avi', 'mkv', 'webm'};
    const audio = {'mp3', 'wav', 'm4a', 'aac', 'ogg'};
    if (extension == null) return 'file';
    if (images.contains(extension)) return 'image';
    if (videos.contains(extension)) return 'video';
    if (audio.contains(extension)) return 'audio';
    return 'file';
  }

  // ── Documents ─────────────────────────────────────────────────────────────

  Stream<List<Document>> watchDocuments() => (select(
    documents,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  Stream<List<Document>> watchDocumentsForProject(String projectId) =>
      (select(documents)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<String> importDocumentFromPath(
    String path, {
    String? projectId,
    String? title,
    String? displayTitle,
    String? source,
    String? metadataJson,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', path);
    }
    final name = p.basename(path);
    final rawExt = p.extension(name).replaceFirst('.', '').toLowerCase();
    final ext = rawExt.isEmpty ? null : rawExt;
    final id = _newMicrosId();
    final now = DateTime.now();

    final appDocDir = await getApplicationDocumentsDirectory();
    final atlasDir = Directory(p.join(appDocDir.path, 'atlas_documents'));
    if (!atlasDir.existsSync()) {
      atlasDir.createSync(recursive: true);
    }
    final destFilename = ext != null ? '$id.$ext' : id;
    final destPath = p.join(atlasDir.path, destFilename);
    try {
      await file.copy(destPath);
    } catch (e) {
      throw FileSystemException('Failed to copy file to app storage: $e', path);
    }

    String? extractedTextValue;
    String? renderedMarkdownValue;
    const _maxExtractBytes = 10 * 1024 * 1024;
    try {
      if (ext != null) {
        final destFile = File(destPath);
        final fileSize = await destFile.length();
        if (fileSize <= _maxExtractBytes) {
          Future<String> readText() async {
            try {
              return await destFile.readAsString();
            } on FormatException {
              final bytes = await destFile.readAsBytes();
              return latin1.decode(bytes);
            }
          }

          if (shouldExtractAsPlainText(ext)) {
            extractedTextValue = await readText();
          } else if (ext == 'md' || ext == 'mdx') {
            renderedMarkdownValue = await readText();
          } else if (ext == 'docx') {
            extractedTextValue = extractDocxText(destPath);
          } else if (ext == 'html' || ext == 'htm') {
            final raw = await readText();
            renderedMarkdownValue = raw;
            extractedTextValue = extractHtmlText(destPath);
          } else if (ext == 'eml') {
            final raw = await readText();
            extractedTextValue = stripEmlBody(raw);
          }
        }
      }
    } catch (_) {
      // Extraction failure must not prevent the DB record from being created.
      extractedTextValue = null;
      renderedMarkdownValue = null;
    }

    try {
      await into(documents).insert(
        DocumentsCompanion(
          id: Value(id),
          title: Value(
            displayTitle?.trim().isNotEmpty == true
                ? displayTitle!.trim()
                : title?.trim().isNotEmpty == true
                ? title!.trim()
                : name,
          ),
          originalFilename: Value(name),
          storedPath: Value(destPath),
          extension: Value(ext),
          mimeType: Value(mimeTypeForExtension(ext)),
          projectId: Value(projectId),
          status: const Value('imported'),
          source: Value(source),
          metadataJson: Value(metadataJson),
          extractedText: Value(extractedTextValue),
          renderedMarkdown: Value(renderedMarkdownValue),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
    } catch (e) {
      // Clean up the copied file if the DB insert fails.
      try {
        final copied = File(destPath);
        if (await copied.exists()) await copied.delete();
      } catch (_) {}
      rethrow;
    }
    return id;
  }

  Future<List<Document>> getDocumentsForProject(String projectId) =>
      (select(documents)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<Document?> getProjectDocumentBySource(
    String projectId,
    String source,
  ) =>
      (select(documents)
            ..where(
              (t) => t.projectId.equals(projectId) & t.source.equals(source),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<Document?> getProjectDocumentByOriginalFilename(
    String projectId,
    String originalFilename,
  ) =>
      (select(documents)
            ..where(
              (t) =>
                  t.projectId.equals(projectId) &
                  t.originalFilename.equals(originalFilename),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<bool> documentExists(String id) async =>
      (await (select(
        documents,
      )..where((t) => t.id.equals(id))).getSingleOrNull()) !=
      null;

  Future<String> importGeneratedDocument({
    required String title,
    required String originalFilename,
    required String body,
    String? projectId,
    String? extension,
    String? source,
    String? metadataJson,
  }) async {
    final id = _newMicrosId();
    final now = DateTime.now();
    final ext = extension == null || extension.trim().isEmpty
        ? null
        : extension.trim().replaceFirst('.', '').toLowerCase();
    await into(documents).insert(
      DocumentsCompanion(
        id: Value(id),
        title: Value(title),
        originalFilename: Value(originalFilename),
        storedPath: const Value(null),
        extension: Value(ext),
        mimeType: Value(mimeTypeForExtension(ext)),
        projectId: Value(projectId),
        source: Value(source),
        status: const Value('imported'),
        metadataJson: Value(metadataJson),
        extractedText: Value(body),
        renderedMarkdown: ext == 'md' ? Value(body) : const Value.absent(),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<ProjectMediaItem?> getProjectMediaBySource(
    String projectId,
    String source,
  ) =>
      (select(projectMedia)
            ..where(
              (t) => t.projectId.equals(projectId) & t.source.equals(source),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<void> deleteDocument(String id) async {
    final doc = await (select(
      documents,
    )..where((d) => d.id.equals(id))).getSingleOrNull();
    if (doc == null) return;
    await (delete(documentLinks)..where((l) => l.documentId.equals(id))).go();
    await (delete(documents)..where((d) => d.id.equals(id))).go();
    if (doc.storedPath != null) {
      final file = File(doc.storedPath!);
      if (await file.exists()) await file.delete();
    }
  }

  // ── Event log ─────────────────────────────────────────────────────────────

  Stream<List<Document>> watchDocumentsForWorkItem(String workItemId) {
    final query =
        select(documents).join([
            innerJoin(
              documentLinks,
              documentLinks.documentId.equalsExp(documents.id),
            ),
          ])
          ..where(
            documentLinks.entityType.equals('work_item') &
                documentLinks.entityId.equals(workItemId),
          )
          ..orderBy([OrderingTerm.desc(documents.createdAt)]);
    return query.watch().map(
      (rows) =>
          rows.map((row) => row.readTable(documents)).toList(growable: false),
    );
  }

  Future<List<Document>> getDocumentsForWorkItem(String workItemId) {
    final query =
        select(documents).join([
            innerJoin(
              documentLinks,
              documentLinks.documentId.equalsExp(documents.id),
            ),
          ])
          ..where(
            documentLinks.entityType.equals('work_item') &
                documentLinks.entityId.equals(workItemId),
          )
          ..orderBy([OrderingTerm.desc(documents.createdAt)]);
    return query.get().then(
      (rows) =>
          rows.map((row) => row.readTable(documents)).toList(growable: false),
    );
  }

  Future<void> linkDocumentToWorkItem(
    String documentId,
    String workItemId,
  ) async {
    final existing =
        await (select(documentLinks)..where(
              (t) =>
                  t.documentId.equals(documentId) &
                  t.entityType.equals('work_item') &
                  t.entityId.equals(workItemId),
            ))
            .getSingleOrNull();
    if (existing != null) return;
    await into(documentLinks).insert(
      DocumentLinksCompanion(
        id: Value('${documentId}_${workItemId}_work_item'),
        documentId: Value(documentId),
        entityType: const Value('work_item'),
        entityId: Value(workItemId),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> unlinkDocumentFromWorkItem(
    String documentId,
    String workItemId,
  ) async {
    await (delete(documentLinks)..where(
          (t) =>
              t.documentId.equals(documentId) &
              t.entityType.equals('work_item') &
              t.entityId.equals(workItemId),
        ))
        .go();
  }

  Stream<List<WorkItemNote>> watchNotesForWorkItem(String workItemId) =>
      (select(workItemNotes)
            ..where((t) => t.workItemId.equals(workItemId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<void> addWorkItemNote(String workItemId, String body) async {
    final now = DateTime.now();
    await into(workItemNotes).insert(
      WorkItemNotesCompanion(
        id: Value(_newMicrosId('work_item_note')),
        workItemId: Value(workItemId),
        body: Value(body),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> updateWorkItemNote(String noteId, String body) async {
    await (update(workItemNotes)..where((t) => t.id.equals(noteId))).write(
      WorkItemNotesCompanion(
        body: Value(body),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteWorkItemNote(String noteId) =>
      (delete(workItemNotes)..where((t) => t.id.equals(noteId))).go();

  Stream<List<WorkItemAnalysis>> watchAnalysesForWorkItem(String workItemId) =>
      (select(workItemAnalyses)
            ..where((t) => t.workItemId.equals(workItemId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<void> saveWorkItemAnalysis({
    required String workItemId,
    required String prompt,
    required String output,
    String? model,
  }) async {
    await into(workItemAnalyses).insert(
      WorkItemAnalysesCompanion(
        id: Value(_newMicrosId('work_item_analysis')),
        workItemId: Value(workItemId),
        prompt: Value(prompt),
        output: Value(output),
        model: Value(model),
        createdAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> logEvent({
    String level = 'info',
    required String area,
    required String action,
    String? entityType,
    String? entityId,
    String? inputJson,
    String? outputJson,
    String? correlationId,
    String? error,
  }) async {
    final id = _newMicrosId();
    await into(eventLog).insert(
      EventLogCompanion(
        id: Value(id),
        timestamp: Value(DateTime.now()),
        level: Value(level),
        area: Value(area),
        action: Value(action),
        entityType: Value(entityType),
        entityId: Value(entityId),
        inputJson: Value(inputJson),
        outputJson: Value(outputJson),
        error: Value(error),
        correlationId: Value(correlationId),
      ),
    );
  }

  Future<void> logError({
    required String area,
    required String action,
    required Object error,
    StackTrace? stackTrace,
    String? inputJson,
    String? entityId,
    String? entityType,
  }) async {
    final id = _newMicrosId();
    await into(eventLog).insert(
      EventLogCompanion(
        id: Value(id),
        timestamp: Value(DateTime.now()),
        level: const Value('error'),
        area: Value(area),
        action: Value(action),
        entityType: Value(entityType),
        entityId: Value(entityId),
        inputJson: Value(inputJson),
        error: Value(error.toString()),
        stackTrace: Value(stackTrace?.toString()),
      ),
    );
  }

  Stream<List<EventLogData>> watchRecentEvents() =>
      (select(eventLog)
            ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
            ..limit(500))
          .watch();

  Future<List<EventLogData>> getRecentEvents() =>
      (select(eventLog)
            ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
            ..limit(500))
          .get();

  Future<void> clearEventLog() => delete(eventLog).go();

  // ── Daily Reviews ─────────────────────────────────────────────────────────

  Future<void> saveDailyReview(String summary) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    // Delete existing review for today (upsert by date)
    await (delete(dailyReviews)..where(
          (t) =>
              t.reviewDate.isBiggerOrEqualValue(today) &
              t.reviewDate.isSmallerThanValue(tomorrow),
        ))
        .go();
    await into(dailyReviews).insert(
      DailyReviewsCompanion.insert(
        id: now.millisecondsSinceEpoch.toString(),
        reviewDate: today,
        summary: summary,
        createdAt: now,
      ),
    );
  }

  Future<DailyReview?> getDailyReviewForDate(DateTime date) async {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));
    return (select(dailyReviews)
          ..where(
            (t) =>
                t.reviewDate.isBiggerOrEqualValue(start) &
                t.reviewDate.isSmallerThanValue(end),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Stream<List<DailyReview>> watchRecentDailyReviews({int limit = 30}) =>
      (select(dailyReviews)
            ..orderBy([(t) => OrderingTerm.desc(t.reviewDate)])
            ..limit(limit))
          .watch();

  // ── Outbox ────────────────────────────────────────────────────────────────

  Future<String> addOutboxMessage({
    required String channel,
    required String title,
    required String body,
  }) async {
    final id = _newMicrosId();
    await into(outboxMessages).insert(
      OutboxMessagesCompanion(
        id: Value(id),
        channel: Value(channel),
        title: Value(title),
        body: Value(body),
        createdAt: Value(DateTime.now()),
        status: const Value('pending'),
      ),
    );
    return id;
  }

  Future<void> markOutboxSent(String id) async {
    await (update(outboxMessages)..where((t) => t.id.equals(id))).write(
      OutboxMessagesCompanion(
        status: const Value('sent'),
        sentAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> markOutboxFailed(String id, String error) async {
    await (update(outboxMessages)..where((t) => t.id.equals(id))).write(
      OutboxMessagesCompanion(
        status: const Value('failed'),
        error: Value(error),
      ),
    );
  }

  Stream<List<OutboxMessage>> watchOutboxMessages() =>
      (select(outboxMessages)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(50))
          .watch();
  // ---------------------------------------------------------------------------
  // Compatibility helpers and local operations stores
  // ---------------------------------------------------------------------------

  String _newMicrosId([String suffix = '']) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final next = now <= _lastGeneratedIdMicros
        ? _lastGeneratedIdMicros + 1
        : now;
    _lastGeneratedIdMicros = next;
    return suffix.isEmpty ? next.toString() : '${next}_$suffix';
  }

  DateTime _dateFromSqlValue(Object? value) {
    if (value is DateTime) return value;
    if (value is int) return _dateFromSqlInt(value);
    if (value is String) {
      final parsedInt = int.tryParse(value);
      if (parsedInt != null) return _dateFromSqlInt(parsedInt);
      return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime? _nullableDateFromSqlValue(Object? value) {
    if (value == null) return null;
    final parsed = _dateFromSqlValue(value);
    if (parsed.millisecondsSinceEpoch == 0) return null;
    return parsed;
  }

  DateTime _dateFromSqlInt(int value) {
    final abs = value.abs();
    if (abs >= 100000000000000) {
      return DateTime.fromMicrosecondsSinceEpoch(value);
    }
    if (abs < 100000000000) {
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    return DateTime.fromMillisecondsSinceEpoch(value);
  }

  int? _boolToSql(bool? value) => value == null ? null : (value ? 1 : 0);

  bool? _boolFromSql(Object? value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is int) return value != 0;
    final text = value.toString().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
    return null;
  }

  int _intFromSql(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _safeIdSegment(String value) => value
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  Future<void> _ensureWorkItemTagsTable() async {
    await customStatement('''CREATE TABLE IF NOT EXISTS work_item_tags (
      work_item_id TEXT NOT NULL,
      tag_id TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (work_item_id, tag_id)
    )''');
  }

  Future<void> _ensureMediaLinksTable() async {
    await customStatement('''CREATE TABLE IF NOT EXISTS media_links (
      id TEXT NOT NULL PRIMARY KEY,
      media_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_media_links_entity '
      'ON media_links(entity_type, entity_id, created_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_media_links_media ON media_links(media_id)',
    );
  }

  Future<void> _ensureProjectGitRemotesTable() async {
    await customStatement('''CREATE TABLE IF NOT EXISTS project_git_remotes (
      id TEXT NOT NULL PRIMARY KEY,
      project_id TEXT NOT NULL,
      registry_id TEXT NULL,
      provider TEXT NOT NULL,
      owner TEXT NOT NULL,
      repo TEXT NOT NULL,
      remote_url TEXT NOT NULL,
      html_url TEXT NULL,
      visibility TEXT NULL,
      default_branch TEXT NULL,
      online_head_sha TEXT NULL,
      is_private INTEGER NULL,
      is_fork INTEGER NULL,
      is_archived INTEGER NULL,
      checked_at INTEGER NOT NULL,
      remote_updated_at INTEGER NULL,
      remote_pushed_at INTEGER NULL,
      error TEXT NULL,
      raw_json TEXT NULL
    )''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_project_git_remotes_project '
      'ON project_git_remotes(project_id, checked_at DESC)',
    );
  }

  Future<void> _ensureProjectEnrichmentTables() async {
    await customStatement(
      '''CREATE TABLE IF NOT EXISTS project_enrichment_runs (
      id TEXT NOT NULL PRIMARY KEY,
      started_at INTEGER NOT NULL,
      completed_at INTEGER NULL,
      status TEXT NOT NULL,
      scope_json TEXT NOT NULL,
      registry_entries INTEGER NOT NULL DEFAULT 0,
      linked_projects INTEGER NOT NULL DEFAULT 0,
      refreshed_projects INTEGER NOT NULL DEFAULT 0,
      created_items INTEGER NOT NULL DEFAULT 0,
      updated_items INTEGER NOT NULL DEFAULT 0,
      unchanged_items INTEGER NOT NULL DEFAULT 0,
      skipped_items INTEGER NOT NULL DEFAULT 0,
      failed_projects INTEGER NOT NULL DEFAULT 0,
      summary_considered INTEGER NOT NULL DEFAULT 0,
      summary_refreshed INTEGER NOT NULL DEFAULT 0,
      summary_skipped INTEGER NOT NULL DEFAULT 0,
      summary_failed INTEGER NOT NULL DEFAULT 0,
      findings INTEGER NOT NULL DEFAULT 0,
      open_findings INTEGER NOT NULL DEFAULT 0,
      warnings_json TEXT NOT NULL,
      output_json TEXT NOT NULL
    )''',
    );
    await customStatement(
      '''CREATE TABLE IF NOT EXISTS project_enrichment_findings (
      id TEXT NOT NULL PRIMARY KEY,
      run_id TEXT NOT NULL,
      project_id TEXT NULL,
      registry_id TEXT NULL,
      severity TEXT NOT NULL,
      category TEXT NOT NULL,
      title TEXT NOT NULL,
      detail TEXT NULL,
      evidence_json TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )''',
    );
    await customStatement(
      '''CREATE TABLE IF NOT EXISTS project_enrichment_steps (
      id TEXT NOT NULL PRIMARY KEY,
      run_id TEXT NOT NULL,
      worker TEXT NOT NULL,
      title TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at INTEGER NOT NULL,
      completed_at INTEGER NULL,
      considered INTEGER NOT NULL DEFAULT 0,
      created_items INTEGER NOT NULL DEFAULT 0,
      updated_items INTEGER NOT NULL DEFAULT 0,
      skipped_items INTEGER NOT NULL DEFAULT 0,
      failed_items INTEGER NOT NULL DEFAULT 0,
      findings INTEGER NOT NULL DEFAULT 0,
      proposals INTEGER NOT NULL DEFAULT 0,
      warnings_json TEXT NOT NULL,
      output_json TEXT NOT NULL
    )''',
    );
    await customStatement(
      '''CREATE TABLE IF NOT EXISTS project_enrichment_proposals (
      id TEXT NOT NULL PRIMARY KEY,
      run_id TEXT NOT NULL,
      project_id TEXT NULL,
      registry_id TEXT NULL,
      worker TEXT NOT NULL,
      proposal_type TEXT NOT NULL,
      title TEXT NOT NULL,
      detail TEXT NULL,
      payload_json TEXT NOT NULL,
      confidence INTEGER NOT NULL,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      applied_at INTEGER NULL
    )''',
    );
    for (final stmt in <String>[
      'CREATE INDEX IF NOT EXISTS idx_project_enrichment_runs_started ON project_enrichment_runs(started_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_project_enrichment_findings_run ON project_enrichment_findings(run_id, severity, category)',
      'CREATE INDEX IF NOT EXISTS idx_project_enrichment_findings_project ON project_enrichment_findings(project_id, status)',
      'CREATE INDEX IF NOT EXISTS idx_project_enrichment_steps_run ON project_enrichment_steps(run_id, started_at)',
      'CREATE INDEX IF NOT EXISTS idx_project_enrichment_proposals_run ON project_enrichment_proposals(run_id, status)',
      'CREATE INDEX IF NOT EXISTS idx_project_enrichment_proposals_project ON project_enrichment_proposals(project_id, status)',
    ]) {
      await customStatement(stmt);
    }
  }

  Future<void> _ensureLlmTaskQueueTable() async {
    await customStatement('''CREATE TABLE IF NOT EXISTS llm_task_queue (
      id TEXT NOT NULL PRIMARY KEY,
      project_id TEXT NOT NULL,
      work_item_id TEXT NULL,
      title TEXT NOT NULL,
      objective TEXT NOT NULL,
      context_json TEXT NOT NULL,
      priority TEXT NOT NULL DEFAULT 'normal',
      status TEXT NOT NULL DEFAULT 'pending',
      created_by TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      leased_by TEXT NULL,
      leased_at INTEGER NULL,
      lease_expires_at INTEGER NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      result_json TEXT NULL,
      error TEXT NULL,
      review_draft_id TEXT NULL,
      completed_at INTEGER NULL,
      readiness TEXT NOT NULL DEFAULT 'ready',
      size TEXT NOT NULL DEFAULT 'medium',
      risk TEXT NOT NULL DEFAULT 'low_code',
      suggested_actor TEXT NOT NULL DEFAULT 'user',
      verification_needed TEXT NOT NULL DEFAULT 'none',
      next_action TEXT NULL,
      blocker_reason TEXT NULL,
      planning_notes TEXT NULL,
      last_reviewed_at INTEGER NULL
    )''');
    for (final stmt in <String>[
      "ALTER TABLE llm_task_queue ADD COLUMN readiness TEXT NOT NULL DEFAULT 'ready'",
      "ALTER TABLE llm_task_queue ADD COLUMN size TEXT NOT NULL DEFAULT 'medium'",
      "ALTER TABLE llm_task_queue ADD COLUMN risk TEXT NOT NULL DEFAULT 'low_code'",
      "ALTER TABLE llm_task_queue ADD COLUMN suggested_actor TEXT NOT NULL DEFAULT 'user'",
      "ALTER TABLE llm_task_queue ADD COLUMN verification_needed TEXT NOT NULL DEFAULT 'none'",
      'ALTER TABLE llm_task_queue ADD COLUMN next_action TEXT NULL',
      'ALTER TABLE llm_task_queue ADD COLUMN blocker_reason TEXT NULL',
      'ALTER TABLE llm_task_queue ADD COLUMN planning_notes TEXT NULL',
      'ALTER TABLE llm_task_queue ADD COLUMN last_reviewed_at INTEGER NULL',
    ]) {
      try {
        await customStatement(stmt);
      } catch (_) {}
    }
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_llm_task_queue_project_status '
      'ON llm_task_queue(project_id, status, updated_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_llm_task_queue_claim '
      'ON llm_task_queue(status, priority, created_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_llm_task_queue_work_item '
      'ON llm_task_queue(work_item_id)',
    );
  }

  Future<String> ensureGeneralTaskStage() async {
    final existingProject =
        await (select(projects)
              ..where(
                (t) =>
                    t.id.equals(kGeneralTasksProjectId) |
                    t.description.equals(kGeneralTasksProjectDescription),
              )
              ..limit(1))
            .getSingleOrNull();
    final projectId = existingProject?.id ?? kGeneralTasksProjectId;
    if (existingProject == null) {
      final now = DateTime.now();
      await into(projects).insert(
        ProjectsCompanion(
          id: Value(projectId),
          title: const Value('General Tasks'),
          description: const Value(kGeneralTasksProjectDescription),
          status: const Value('active'),
          createdAt: Value(now),
        ),
      );
    } else if (existingProject.description != kGeneralTasksProjectDescription) {
      await updateProjectMeta(projectId, {
        'description': kGeneralTasksProjectDescription,
      });
    }
    final existingStage =
        await (select(stages)
              ..where((t) => t.projectId.equals(projectId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)])
              ..limit(1))
            .getSingleOrNull();
    if (existingStage != null) return existingStage.id;
    final stageId = _newMicrosId('general_stage');
    await into(stages).insert(
      StagesCompanion(
        id: Value(stageId),
        projectId: Value(projectId),
        title: const Value('General'),
        position: const Value(0),
        createdAt: Value(DateTime.now()),
      ),
    );
    return stageId;
  }

  Stream<List<WorkItem>> watchAllActiveWorkItems() =>
      (select(workItems)
            ..where((t) => t.status.isNotIn(['done', 'archived']))
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .watch();

  Future<bool> workItemExists(String id) async =>
      (await getWorkItem(id)) != null;

  Future<Project?> getProjectForWorkItem(String workItemId) async {
    final item = await getWorkItem(workItemId);
    if (item == null) return null;
    final stage = await (select(
      stages,
    )..where((t) => t.id.equals(item.stageId))).getSingleOrNull();
    if (stage == null) return null;
    final project = await getProjectFull(stage.projectId);
    if (project == null || !_isVisibleProject(project)) return null;
    return project;
  }

  Future<ProjectRisk?> getProjectRisk(String id) =>
      (select(projectRisks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> updateProjectRisk(
    String id, {
    String? title,
    String? desc,
    String? severity,
  }) async {
    await (update(projectRisks)..where((t) => t.id.equals(id))).write(
      ProjectRisksCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        desc: desc != null ? Value(desc) : const Value.absent(),
        severity: severity != null ? Value(severity) : const Value.absent(),
      ),
    );
  }

  Future<ProjectDecision?> getProjectDecision(String id) => (select(
    projectDecisions,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> updateProjectDecision(
    String id, {
    String? title,
    String? ctx,
    String? decider,
  }) async {
    await (update(projectDecisions)..where((t) => t.id.equals(id))).write(
      ProjectDecisionsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        ctx: ctx != null ? Value(ctx) : const Value.absent(),
        decider: decider != null ? Value(decider) : const Value.absent(),
      ),
    );
  }

  Future<void> assignTagToWorkItem(String workItemId, String tagId) async {
    await customStatement(
      'INSERT OR REPLACE INTO work_item_tags '
      '(work_item_id, tag_id, created_at) VALUES (?, ?, ?)',
      [workItemId, tagId, DateTime.now().millisecondsSinceEpoch],
    );
  }

  Future<void> setWorkItemTags(
    String workItemId,
    Iterable<String> tagIds,
  ) async {
    final uniqueIds = tagIds.where((id) => id.trim().isNotEmpty).toSet();
    await transaction(() async {
      await customStatement(
        'DELETE FROM work_item_tags WHERE work_item_id = ?',
        [workItemId],
      );
      for (final tagId in uniqueIds) {
        await assignTagToWorkItem(workItemId, tagId);
      }
    });
  }

  Tag _tagFromRow(QueryRow row) => Tag(
    id: row.data['id'] as String,
    name: row.data['name'] as String,
    color: row.data['color'] as String?,
    createdAt: _dateFromSqlValue(row.data['created_at']),
    updatedAt: _dateFromSqlValue(row.data['updated_at']),
  );

  Future<List<Tag>> getTagsForWorkItem(String workItemId) async {
    final rows = await customSelect(
      '''SELECT t.id, t.name, t.color, t.created_at, t.updated_at
         FROM tags t
         INNER JOIN work_item_tags wt ON wt.tag_id = t.id
         WHERE wt.work_item_id = ?
         ORDER BY LOWER(t.name) ASC''',
      variables: [Variable<String>(workItemId)],
      readsFrom: {tags},
    ).get();
    return rows.map(_tagFromRow).toList(growable: false);
  }

  Future<Map<String, List<Tag>>> getTagsForWorkItems(
    Iterable<String> workItemIds,
  ) async {
    final ids = workItemIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return const <String, List<Tag>>{};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await customSelect(
      '''SELECT wt.work_item_id, t.id, t.name, t.color, t.created_at, t.updated_at
         FROM work_item_tags wt
         INNER JOIN tags t ON wt.tag_id = t.id
         WHERE wt.work_item_id IN ($placeholders)
         ORDER BY LOWER(t.name) ASC''',
      variables: ids.map((id) => Variable<String>(id)).toList(growable: false),
      readsFrom: {tags},
    ).get();
    final result = <String, List<Tag>>{for (final id in ids) id: <Tag>[]};
    for (final row in rows) {
      final workItemId = row.data['work_item_id'] as String;
      result.putIfAbsent(workItemId, () => <Tag>[]).add(_tagFromRow(row));
    }
    return result;
  }

  Future<Map<String, int>> mergeProjects({
    required String sourceProjectId,
    required String targetProjectId,
  }) async {
    if (sourceProjectId == targetProjectId) {
      throw ArgumentError('Choose two different projects to merge.');
    }
    final source = await getProjectFull(sourceProjectId);
    final target = await getProjectFull(targetProjectId);
    if (source == null) throw StateError('Source project not found.');
    if (target == null) throw StateError('Target project not found.');
    final moved = <String, int>{
      'stages': 0,
      'workItems': 0,
      'media': 0,
      'documents': 0,
      'people': 0,
      'risks': 0,
      'decisions': 0,
      'tags': 0,
      'drafts': 0,
      'registry': 0,
    };
    await transaction(() async {
      final sourceStages = await getStagesForProject(sourceProjectId);
      final sourceStageIds = sourceStages.map((stage) => stage.id).toSet();
      for (final stage in sourceStages) {
        await (update(stages)..where((t) => t.id.equals(stage.id))).write(
          StagesCompanion(projectId: Value(targetProjectId)),
        );
      }
      moved['stages'] = sourceStages.length;
      final targetWork = await getWorkItemsForProject(targetProjectId);
      moved['workItems'] = targetWork
          .where((item) => sourceStageIds.contains(item.stageId))
          .length;
      moved['documents'] =
          await (update(documents)
                ..where((t) => t.projectId.equals(sourceProjectId)))
              .write(DocumentsCompanion(projectId: Value(targetProjectId)));
      moved['media'] =
          await (update(projectMedia)
                ..where((t) => t.projectId.equals(sourceProjectId)))
              .write(ProjectMediaCompanion(projectId: Value(targetProjectId)));
      moved['people'] =
          await (update(projectPeople)
                ..where((t) => t.projectId.equals(sourceProjectId)))
              .write(ProjectPeopleCompanion(projectId: Value(targetProjectId)));
      moved['risks'] =
          await (update(projectRisks)
                ..where((t) => t.projectId.equals(sourceProjectId)))
              .write(ProjectRisksCompanion(projectId: Value(targetProjectId)));
      moved['decisions'] =
          await (update(
            projectDecisions,
          )..where((t) => t.projectId.equals(sourceProjectId))).write(
            ProjectDecisionsCompanion(projectId: Value(targetProjectId)),
          );
      final sourceTagAssignments = await getProjectTagAssignments(
        sourceProjectId,
      );
      for (final assignment in sourceTagAssignments) {
        await assignTagToProject(targetProjectId, assignment.tagId);
      }
      await (delete(
        projectTags,
      )..where((t) => t.projectId.equals(sourceProjectId))).go();
      moved['tags'] = sourceTagAssignments.length;
      moved['drafts'] =
          await (update(drafts)
                ..where((t) => t.projectId.equals(sourceProjectId)))
              .write(DraftsCompanion(projectId: Value(targetProjectId)));
      moved['registry'] =
          await (update(
            projectRegistry,
          )..where((t) => t.atlasProjectId.equals(sourceProjectId))).write(
            ProjectRegistryCompanion(atlasProjectId: Value(targetProjectId)),
          );
      await (update(
        projects,
      )..where((t) => t.id.equals(sourceProjectId))).write(
        ProjectsCompanion(
          status: const Value('deleted'),
          deletedAt: Value(DateTime.now()),
          deleteReason: Value('Merged into ${target.title} (${target.id})'),
        ),
      );
    });
    return moved;
  }

  Future<Map<String, ProjectUpdateAttribution>>
  getProjectUpdateAttributions() async {
    final rows = await customSelect('''SELECT p.id AS project_id,
                p.created_at AS updated_at,
                'created' AS source,
                p.owner AS contact_name,
                NULL AS output_json
         FROM projects p
         UNION ALL
         SELECT e.entity_id AS project_id,
                e.timestamp AS updated_at,
                'event_log' AS source,
                p.owner AS contact_name,
                e.output_json AS output_json
         FROM event_log e
         LEFT JOIN projects p ON p.id = e.entity_id
         WHERE e.entity_type = 'project' AND e.entity_id IS NOT NULL
         UNION ALL
         SELECT d.project_id AS project_id,
                d.updated_at AS updated_at,
                'draft' AS source,
                p.owner AS contact_name,
                NULL AS output_json
         FROM drafts d
         LEFT JOIN projects p ON p.id = d.project_id
         WHERE d.project_id IS NOT NULL
         UNION ALL
         SELECT doc.project_id AS project_id,
                doc.updated_at AS updated_at,
                'document' AS source,
                p.owner AS contact_name,
                NULL AS output_json
         FROM documents doc
         LEFT JOIN projects p ON p.id = doc.project_id
         WHERE doc.project_id IS NOT NULL
         UNION ALL
         SELECT pm.project_id AS project_id,
                pm.updated_at AS updated_at,
                'media' AS source,
                p.owner AS contact_name,
                NULL AS output_json
         FROM project_media pm
         LEFT JOIN projects p ON p.id = pm.project_id''').get();
    final result = <String, ProjectUpdateAttribution>{};
    for (final row in rows) {
      final projectId = row.data['project_id']?.toString();
      if (projectId == null || projectId.isEmpty) continue;
      final updatedAt = _dateFromSqlValue(row.data['updated_at']);
      final existing = result[projectId];
      if (existing != null && !updatedAt.isAfter(existing.updatedAt)) continue;
      result[projectId] = ProjectUpdateAttribution(
        projectId: projectId,
        updatedAt: updatedAt,
        updatedBy: _actorFromAttributionOutput(
          row.data['output_json'] as String?,
        ),
        source: row.data['source']?.toString() ?? 'unknown',
        contactName: row.data['contact_name']?.toString(),
      );
    }
    return result;
  }

  Stream<Map<String, ProjectUpdateAttribution>>
  watchProjectUpdateAttributions() => Stream<void>.periodic(
    const Duration(seconds: 30),
  ).asyncMap((_) => getProjectUpdateAttributions()).asBroadcastStream();

  String _actorFromAttributionOutput(String? outputJson) {
    final output = _decodeObjectMap(outputJson);
    final actor = output['actor'];
    if (actor is Map) {
      final displayName =
          actor['displayName']?.toString() ?? actor['name']?.toString();
      if (displayName != null && displayName.trim().isNotEmpty) {
        return displayName.trim();
      }
    } else if (actor is String && actor.trim().isNotEmpty) {
      return actor.trim();
    }
    final agent = output['agent']?.toString().toLowerCase();
    if (agent == 'codex') return 'Codex';
    if (agent == 'operator') return 'Operator';
    if (agent != null && agent.isNotEmpty) return agent;
    return 'Atlas';
  }

  Stream<List<ProjectScanRun>> watchProjectScanRuns({int limit = 50}) =>
      (select(projectScanRuns)
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
            ..limit(limit))
          .watch();

  Future<List<ProjectScanRun>> getProjectScanRuns({int limit = 50}) =>
      (select(projectScanRuns)
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
            ..limit(limit))
          .get();

  Future<ProjectScanRun?> getProjectScanRun(String id) => (select(
    projectScanRuns,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<String> startProjectScanRun({
    required String rootsJson,
    required DateTime startedAt,
  }) async {
    final id = _newMicrosId('scan');
    await into(projectScanRuns).insert(
      ProjectScanRunsCompanion(
        id: Value(id),
        rootsJson: Value(rootsJson),
        startedAt: Value(startedAt),
        status: const Value('running'),
        warningsJson: const Value('[]'),
      ),
    );
    return id;
  }

  Future<void> finishProjectScanRun({
    required String id,
    required DateTime completedAt,
    required String status,
    required int totalSeen,
    required int candidates,
    required int ignored,
    required String warningsJson,
  }) async {
    await (update(projectScanRuns)..where((t) => t.id.equals(id))).write(
      ProjectScanRunsCompanion(
        completedAt: Value(completedAt),
        status: Value(status),
        totalSeen: Value(totalSeen),
        candidates: Value(candidates),
        ignored: Value(ignored),
        warningsJson: Value(warningsJson),
      ),
    );
  }

  Future<void> addProjectObservation({
    required String id,
    String? registryId,
    required String scanRunId,
    required String observedPath,
    required String classificationGuess,
    required int confidence,
    String? branch,
    String? headSha,
    int? dirtyCount,
    String? remoteUrl,
    required String markerFilesJson,
    required String warningsJson,
    required String rawJson,
    required DateTime observedAt,
  }) async {
    await into(projectObservations).insert(
      ProjectObservationsCompanion(
        id: Value(id),
        registryId: Value(registryId),
        scanRunId: Value(scanRunId),
        observedPath: Value(observedPath),
        classificationGuess: Value(classificationGuess),
        confidence: Value(confidence),
        branch: Value(branch),
        headSha: Value(headSha),
        dirtyCount: Value(dirtyCount),
        remoteUrl: Value(remoteUrl),
        markerFilesJson: Value(markerFilesJson),
        warningsJson: Value(warningsJson),
        rawJson: Value(rawJson),
        observedAt: Value(observedAt),
      ),
    );
  }

  Future<List<ProjectObservation>> getProjectObservationsForScanRun(
    String scanRunId,
  ) =>
      (select(projectObservations)
            ..where((t) => t.scanRunId.equals(scanRunId))
            ..orderBy([(t) => OrderingTerm.desc(t.observedAt)]))
          .get();

  Stream<List<ProjectObservation>> watchRecentProjectObservations({
    int limit = 100,
  }) =>
      (select(projectObservations)
            ..orderBy([(t) => OrderingTerm.desc(t.observedAt)])
            ..limit(limit))
          .watch();

  Future<List<ProjectObservation>> getRecentProjectObservations({
    int limit = 100,
  }) =>
      (select(projectObservations)
            ..orderBy([(t) => OrderingTerm.desc(t.observedAt)])
            ..limit(limit))
          .get();

  Future<List<ProjectRegistryEntry>> getProjectRegistry() => (select(
    projectRegistry,
  )..orderBy([(t) => OrderingTerm.asc(t.displayName)])).get();

  Stream<List<ProjectRegistryEntry>> watchProjectRegistry() => (select(
    projectRegistry,
  )..orderBy([(t) => OrderingTerm.asc(t.displayName)])).watch();

  Future<ProjectRegistryEntry?> getProjectRegistryEntry(String id) => (select(
    projectRegistry,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> updateProjectRegistryEntryReviewState({
    required String id,
    required String reviewState,
    String? notes,
    bool clearAtlasProjectId = false,
  }) async {
    await (update(projectRegistry)..where((t) => t.id.equals(id))).write(
      ProjectRegistryCompanion(
        atlasProjectId: clearAtlasProjectId
            ? const Value(null)
            : const Value.absent(),
        reviewState: Value(reviewState),
        notes: notes == null ? const Value.absent() : Value(notes),
        updatedAt: Value(DateTime.now()),
        lastReviewedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<ProjectRegistryEntry> updateProjectRegistryEntryLocalPath({
    required String id,
    required String localPath,
    String? gitRoot,
    String? reviewState,
    String? notes,
  }) async {
    await (update(projectRegistry)..where((t) => t.id.equals(id))).write(
      ProjectRegistryCompanion(
        localPath: Value(localPath),
        gitRoot: Value(gitRoot),
        reviewState: reviewState == null
            ? const Value.absent()
            : Value(reviewState),
        notes: notes == null ? const Value.absent() : Value(notes),
        updatedAt: Value(DateTime.now()),
        lastReviewedAt: Value(DateTime.now()),
      ),
    );
    final updated = await getProjectRegistryEntry(id);
    if (updated == null) {
      throw StateError('Project registry row not found: $id');
    }
    return updated;
  }

  Future<ProjectRegistryEntry?> getProjectRegistryByPath(String path) =>
      (select(projectRegistry)
            ..where((t) => t.localPath.lower().equals(path.toLowerCase()))
            ..limit(1))
          .getSingleOrNull();

  Future<ProjectRegistryEntry?> getProjectRegistryByAtlasProjectId(
    String atlasProjectId,
  ) =>
      (select(projectRegistry)
            ..where((t) => t.atlasProjectId.equals(atlasProjectId))
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<List<ProjectRegistryEntry>> getProjectRegistryEntriesByAtlasProjectId(
    String atlasProjectId,
  ) =>
      (select(projectRegistry)
            ..where((t) => t.atlasProjectId.equals(atlasProjectId))
            ..orderBy([(t) => OrderingTerm.asc(t.displayName)]))
          .get();

  Future<void> unlinkProjectRegistryEntriesForAtlasProject({
    required String atlasProjectId,
    String? exceptRegistryId,
  }) async {
    final rows = await getProjectRegistryEntriesByAtlasProjectId(
      atlasProjectId,
    );
    for (final row in rows) {
      if (exceptRegistryId != null && row.id == exceptRegistryId) continue;
      await (update(projectRegistry)..where((t) => t.id.equals(row.id))).write(
        ProjectRegistryCompanion(
          atlasProjectId: const Value(null),
          reviewState: const Value('accepted'),
          updatedAt: Value(DateTime.now()),
        ),
      );
    }
  }

  Future<void> linkProjectRegistryEntryToAtlasProject({
    required String registryId,
    required String atlasProjectId,
  }) async {
    await (update(
      projectRegistry,
    )..where((t) => t.id.equals(registryId))).write(
      ProjectRegistryCompanion(
        atlasProjectId: Value(atlasProjectId),
        reviewState: const Value('linked'),
        updatedAt: Value(DateTime.now()),
        lastReviewedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<ProjectObservation?> getLatestProjectObservationForPath(
    String localPath,
  ) =>
      (select(projectObservations)
            ..where(
              (t) => t.observedPath.lower().equals(localPath.toLowerCase()),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.observedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<String> reviewProjectObservation({
    required String observationId,
    required String reviewState,
    String? atlasProjectId,
    String? notes,
  }) async {
    final observation = await (select(
      projectObservations,
    )..where((t) => t.id.equals(observationId))).getSingleOrNull();
    if (observation == null) {
      throw StateError('Project observation not found: $observationId');
    }
    final existing = observation.registryId == null
        ? await getProjectRegistryByPath(observation.observedPath)
        : await getProjectRegistryEntry(observation.registryId!);
    final raw = _decodeObjectMap(observation.rawJson);
    final now = DateTime.now();
    final registryId = existing?.id ?? _newMicrosId('registry');
    await into(projectRegistry).insertOnConflictUpdate(
      ProjectRegistryCompanion(
        id: Value(registryId),
        atlasProjectId: reviewState == 'ignored'
            ? const Value(null)
            : Value(atlasProjectId ?? existing?.atlasProjectId),
        displayName: Value(
          raw['displayName']?.toString().trim().isNotEmpty == true
              ? raw['displayName'].toString()
              : p.basename(observation.observedPath),
        ),
        localPath: Value(observation.observedPath),
        gitRoot: Value(raw['gitRoot']?.toString()),
        classification: Value(observation.classificationGuess),
        reviewState: Value(reviewState),
        notes: Value(notes ?? existing?.notes),
        createdAt: Value(existing?.createdAt ?? now),
        updatedAt: Value(now),
        lastReviewedAt: Value(now),
      ),
    );
    await (update(projectObservations)
          ..where((t) => t.id.equals(observationId)))
        .write(ProjectObservationsCompanion(registryId: Value(registryId)));
    return registryId;
  }

  Future<LocalProjectRefreshItem?> getLocalProjectRefreshItem({
    required String registryId,
    required String sourceKind,
    required String sourceKey,
  }) =>
      (select(localProjectRefreshItems)
            ..where(
              (t) =>
                  t.registryId.equals(registryId) &
                  t.sourceKind.equals(sourceKind) &
                  t.sourceKey.equals(sourceKey),
            )
            ..limit(1))
          .getSingleOrNull();

  Future<LocalProjectRefreshItem?> upsertLocalProjectRefreshItem({
    required String registryId,
    required String sourceKind,
    required String sourceKey,
    required String targetType,
    required String targetId,
    required String sourceFingerprint,
    required DateTime lastImportedAt,
  }) async {
    final existing = await getLocalProjectRefreshItem(
      registryId: registryId,
      sourceKind: sourceKind,
      sourceKey: sourceKey,
    );
    final id = existing?.id ?? _newMicrosId('refresh');
    await into(localProjectRefreshItems).insertOnConflictUpdate(
      LocalProjectRefreshItemsCompanion(
        id: Value(id),
        registryId: Value(registryId),
        sourceKind: Value(sourceKind),
        sourceKey: Value(sourceKey),
        targetType: Value(targetType),
        targetId: Value(targetId),
        sourceFingerprint: Value(sourceFingerprint),
        lastImportedAt: Value(lastImportedAt),
      ),
    );
    return (select(
      localProjectRefreshItems,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<List<LocalProjectRefreshItem>> getLocalProjectRefreshItemsForRegistry(
    String registryId,
  ) =>
      (select(localProjectRefreshItems)
            ..where((t) => t.registryId.equals(registryId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sourceKind),
              (t) => OrderingTerm.asc(t.sourceKey),
            ]))
          .get();

  Stream<ProjectRuntimeProfile?> watchProjectRuntimeProfile(String projectId) =>
      (select(projectRuntimeProfiles)
            ..where((t) => t.projectId.equals(projectId))
            ..limit(1))
          .watchSingleOrNull();

  Future<ProjectRuntimeProfile?> getProjectRuntimeProfile(String projectId) =>
      (select(projectRuntimeProfiles)
            ..where((t) => t.projectId.equals(projectId))
            ..limit(1))
          .getSingleOrNull();

  Future<ProjectRuntimeProfile> saveProjectRuntimeProfile({
    required String projectId,
    required bool enabled,
    required String? workingDirectory,
    required String? launchCommand,
    required String? stopCommand,
    required String testCommandsJson,
    required String portsJson,
    required String urlsJson,
    required String healthUrlsJson,
    required String? notes,
    required bool autostart,
    required bool capsuleEnabled,
    required String capsuleMode,
    required String? capsuleSourcePath,
    required String? capsuleProfile,
    String? importSource,
    DateTime? lastImportedAt,
  }) async {
    final existing = await getProjectRuntimeProfile(projectId);
    final now = DateTime.now();
    final id = existing?.id ?? _newMicrosId('runtime');
    await into(projectRuntimeProfiles).insertOnConflictUpdate(
      ProjectRuntimeProfilesCompanion(
        id: Value(id),
        projectId: Value(projectId),
        enabled: Value(enabled),
        workingDirectory: Value(workingDirectory),
        launchCommand: Value(launchCommand),
        stopCommand: Value(stopCommand),
        testCommandsJson: Value(testCommandsJson),
        portsJson: Value(portsJson),
        urlsJson: Value(urlsJson),
        healthUrlsJson: Value(healthUrlsJson),
        notes: Value(notes),
        autostart: Value(autostart),
        capsuleEnabled: Value(capsuleEnabled),
        capsuleMode: Value(capsuleMode),
        capsuleSourcePath: Value(capsuleSourcePath),
        capsuleProfile: Value(capsuleProfile),
        importSource: Value(importSource ?? existing?.importSource),
        lastImportedAt: Value(lastImportedAt ?? existing?.lastImportedAt),
        createdAt: Value(existing?.createdAt ?? now),
        updatedAt: Value(now),
      ),
    );
    final saved = await getProjectRuntimeProfile(projectId);
    if (saved == null) {
      throw StateError('Runtime profile was not saved for project $projectId.');
    }
    return saved;
  }

  Future<void> deleteProjectRuntimeProfile(String projectId) async {
    await (delete(
      projectRuntimeProfiles,
    )..where((t) => t.projectId.equals(projectId))).go();
  }

  Stream<List<ProjectRuntimeRun>> watchProjectRuntimeRuns(
    String projectId, {
    int limit = 20,
  }) =>
      (select(projectRuntimeRuns)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
            ..limit(limit))
          .watch();

  Future<List<ProjectRuntimeRun>> getProjectRuntimeRuns(
    String projectId, {
    int limit = 20,
  }) =>
      (select(projectRuntimeRuns)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
            ..limit(limit))
          .get();

  Stream<List<ProjectRuntimeRun>> watchLatestRuntimeRunsForProjects({
    int limit = 200,
  }) =>
      (select(projectRuntimeRuns)
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
            ..limit(limit))
          .watch();

  Future<ProjectRuntimeRun?> getLatestProjectRuntimeRun(
    String projectId, {
    String? action,
  }) {
    final query = select(projectRuntimeRuns)
      ..where((t) => t.projectId.equals(projectId));
    if (action != null) {
      query.where((t) => t.action.equals(action));
    }
    query
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
      ..limit(1);
    return query.getSingleOrNull();
  }

  Future<ProjectRuntimeRun> startProjectRuntimeRun({
    required String profileId,
    required String projectId,
    required String action,
    String? command,
    String? metadataJson,
  }) async {
    final id = _newMicrosId('runtime_run');
    await into(projectRuntimeRuns).insert(
      ProjectRuntimeRunsCompanion(
        id: Value(id),
        profileId: Value(profileId),
        projectId: Value(projectId),
        action: Value(action),
        command: Value(command),
        status: const Value('running'),
        startedAt: Value(DateTime.now()),
        metadataJson: Value(metadataJson),
      ),
    );
    return (select(
      projectRuntimeRuns,
    )..where((t) => t.id.equals(id))).getSingle();
  }

  Future<ProjectRuntimeRun> finishProjectRuntimeRun({
    required String id,
    required String status,
    int? exitCode,
    String? outputText,
    String? errorText,
    String? capsuleStatus,
    String? capsuleOutputText,
    String? metadataJson,
  }) async {
    await (update(projectRuntimeRuns)..where((t) => t.id.equals(id))).write(
      ProjectRuntimeRunsCompanion(
        status: Value(status),
        completedAt: Value(DateTime.now()),
        exitCode: Value(exitCode),
        outputText: Value(outputText),
        errorText: Value(errorText),
        capsuleStatus: Value(capsuleStatus),
        capsuleOutputText: Value(capsuleOutputText),
        metadataJson: Value(metadataJson),
      ),
    );
    return (select(
      projectRuntimeRuns,
    )..where((t) => t.id.equals(id))).getSingle();
  }

  ProjectGitRemoteStatus _projectGitRemoteStatusFromRow(QueryRow row) =>
      ProjectGitRemoteStatus(
        id: row.data['id'] as String,
        projectId: row.data['project_id'] as String,
        registryId: row.data['registry_id'] as String?,
        provider: row.data['provider'] as String,
        owner: row.data['owner'] as String,
        repo: row.data['repo'] as String,
        remoteUrl: row.data['remote_url'] as String,
        htmlUrl: row.data['html_url'] as String?,
        visibility: row.data['visibility'] as String?,
        defaultBranch: row.data['default_branch'] as String?,
        onlineHeadSha: row.data['online_head_sha'] as String?,
        isPrivate: _boolFromSql(row.data['is_private']),
        isFork: _boolFromSql(row.data['is_fork']),
        isArchived: _boolFromSql(row.data['is_archived']),
        checkedAt: _dateFromSqlValue(row.data['checked_at']),
        remoteUpdatedAt: _nullableDateFromSqlValue(
          row.data['remote_updated_at'],
        ),
        remotePushedAt: _nullableDateFromSqlValue(row.data['remote_pushed_at']),
        error: row.data['error'] as String?,
        rawJson: row.data['raw_json'] as String?,
      );

  Future<ProjectGitRemoteStatus?> getLatestProjectGitRemoteStatus(
    String projectId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM project_git_remotes WHERE project_id = ? ORDER BY checked_at DESC LIMIT 1',
      variables: [Variable<String>(projectId)],
    ).get();
    return rows.isEmpty ? null : _projectGitRemoteStatusFromRow(rows.single);
  }

  Future<List<ProjectGitRemoteStatus>> getProjectGitRemoteStatuses(
    String projectId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM project_git_remotes WHERE project_id = ? ORDER BY checked_at DESC',
      variables: [Variable<String>(projectId)],
    ).get();
    return rows.map(_projectGitRemoteStatusFromRow).toList(growable: false);
  }

  Future<void> deleteProjectGitRemoteStatuses(String projectId) async {
    await _ensureProjectGitRemotesTable();
    await customStatement(
      'DELETE FROM project_git_remotes WHERE project_id = ?',
      [projectId],
    );
  }

  Future<ProjectGitRemoteStatus> upsertProjectGitRemoteStatus({
    required String projectId,
    String? registryId,
    required String provider,
    required String owner,
    required String repo,
    required String remoteUrl,
    String? htmlUrl,
    String? visibility,
    String? defaultBranch,
    String? onlineHeadSha,
    bool? isPrivate,
    bool? isFork,
    bool? isArchived,
    required DateTime checkedAt,
    DateTime? remoteUpdatedAt,
    DateTime? remotePushedAt,
    String? error,
    String? rawJson,
  }) async {
    await _ensureProjectGitRemotesTable();
    final id =
        'github_${_safeIdSegment(projectId)}_${_safeIdSegment(owner)}_${_safeIdSegment(repo)}';
    await customStatement(
      '''INSERT OR REPLACE INTO project_git_remotes (
        id, project_id, registry_id, provider, owner, repo, remote_url, html_url,
        visibility, default_branch, online_head_sha, is_private, is_fork,
        is_archived, checked_at, remote_updated_at, remote_pushed_at, error, raw_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        projectId,
        registryId,
        provider,
        owner,
        repo,
        remoteUrl,
        htmlUrl,
        visibility,
        defaultBranch,
        onlineHeadSha,
        _boolToSql(isPrivate),
        _boolToSql(isFork),
        _boolToSql(isArchived),
        checkedAt.millisecondsSinceEpoch,
        remoteUpdatedAt?.millisecondsSinceEpoch,
        remotePushedAt?.millisecondsSinceEpoch,
        error,
        rawJson,
      ],
    );
    final status = await getLatestProjectGitRemoteStatus(projectId);
    if (status == null)
      throw StateError('Failed to save GitHub remote status.');
    return status;
  }

  ProjectEnrichmentRun _projectEnrichmentRunFromRow(QueryRow row) =>
      ProjectEnrichmentRun(
        id: row.data['id'] as String,
        startedAt: _dateFromSqlValue(row.data['started_at']),
        completedAt: _nullableDateFromSqlValue(row.data['completed_at']),
        status: row.data['status'] as String,
        scopeJson: row.data['scope_json'] as String,
        registryEntries: _intFromSql(row.data['registry_entries']),
        linkedProjects: _intFromSql(row.data['linked_projects']),
        refreshedProjects: _intFromSql(row.data['refreshed_projects']),
        createdItems: _intFromSql(row.data['created_items']),
        updatedItems: _intFromSql(row.data['updated_items']),
        unchangedItems: _intFromSql(row.data['unchanged_items']),
        skippedItems: _intFromSql(row.data['skipped_items']),
        failedProjects: _intFromSql(row.data['failed_projects']),
        summaryConsidered: _intFromSql(row.data['summary_considered']),
        summaryRefreshed: _intFromSql(row.data['summary_refreshed']),
        summarySkipped: _intFromSql(row.data['summary_skipped']),
        summaryFailed: _intFromSql(row.data['summary_failed']),
        findings: _intFromSql(row.data['findings']),
        openFindings: _intFromSql(row.data['open_findings']),
        warningsJson: row.data['warnings_json'] as String,
        outputJson: row.data['output_json'] as String,
      );

  ProjectEnrichmentFinding _projectEnrichmentFindingFromRow(QueryRow row) =>
      ProjectEnrichmentFinding(
        id: row.data['id'] as String,
        runId: row.data['run_id'] as String,
        projectId: row.data['project_id'] as String?,
        registryId: row.data['registry_id'] as String?,
        severity: row.data['severity'] as String,
        category: row.data['category'] as String,
        title: row.data['title'] as String,
        detail: row.data['detail'] as String?,
        evidenceJson: row.data['evidence_json'] as String,
        status: row.data['status'] as String,
        createdAt: _dateFromSqlValue(row.data['created_at']),
      );

  ProjectEnrichmentStep _projectEnrichmentStepFromRow(QueryRow row) =>
      ProjectEnrichmentStep(
        id: row.data['id'] as String,
        runId: row.data['run_id'] as String,
        worker: row.data['worker'] as String,
        title: row.data['title'] as String,
        status: row.data['status'] as String,
        startedAt: _dateFromSqlValue(row.data['started_at']),
        completedAt: _nullableDateFromSqlValue(row.data['completed_at']),
        considered: _intFromSql(row.data['considered']),
        createdItems: _intFromSql(row.data['created_items']),
        updatedItems: _intFromSql(row.data['updated_items']),
        skippedItems: _intFromSql(row.data['skipped_items']),
        failedItems: _intFromSql(row.data['failed_items']),
        findings: _intFromSql(row.data['findings']),
        proposals: _intFromSql(row.data['proposals']),
        warningsJson: row.data['warnings_json'] as String,
        outputJson: row.data['output_json'] as String,
      );

  ProjectEnrichmentProposal _projectEnrichmentProposalFromRow(QueryRow row) =>
      ProjectEnrichmentProposal(
        id: row.data['id'] as String,
        runId: row.data['run_id'] as String,
        projectId: row.data['project_id'] as String?,
        registryId: row.data['registry_id'] as String?,
        worker: row.data['worker'] as String,
        proposalType: row.data['proposal_type'] as String,
        title: row.data['title'] as String,
        detail: row.data['detail'] as String?,
        payloadJson: row.data['payload_json'] as String,
        confidence: _intFromSql(row.data['confidence']),
        status: row.data['status'] as String,
        createdAt: _dateFromSqlValue(row.data['created_at']),
        appliedAt: _nullableDateFromSqlValue(row.data['applied_at']),
      );

  Stream<List<ProjectEnrichmentRun>> watchProjectEnrichmentRuns({
    int limit = 50,
  }) =>
      customSelect(
        'SELECT * FROM project_enrichment_runs ORDER BY started_at DESC LIMIT ?',
        variables: [Variable<int>(limit)],
      ).watch().map(
        (rows) =>
            rows.map(_projectEnrichmentRunFromRow).toList(growable: false),
      );

  Future<List<ProjectEnrichmentRun>> getProjectEnrichmentRuns({
    int limit = 50,
  }) async {
    final rows = await customSelect(
      'SELECT * FROM project_enrichment_runs ORDER BY started_at DESC LIMIT ?',
      variables: [Variable<int>(limit)],
    ).get();
    return rows.map(_projectEnrichmentRunFromRow).toList(growable: false);
  }

  Future<ProjectEnrichmentRun?> getProjectEnrichmentRun(String id) async {
    final rows = await customSelect(
      'SELECT * FROM project_enrichment_runs WHERE id = ? LIMIT 1',
      variables: [Variable<String>(id)],
    ).get();
    return rows.isEmpty ? null : _projectEnrichmentRunFromRow(rows.single);
  }

  Future<String> startProjectEnrichmentRun({
    required DateTime startedAt,
    required String scopeJson,
  }) async {
    await _ensureProjectEnrichmentTables();
    final id = _newMicrosId('enrichment');
    await customStatement(
      '''INSERT INTO project_enrichment_runs (
        id, started_at, status, scope_json, warnings_json, output_json
      ) VALUES (?, ?, ?, ?, ?, ?)''',
      [id, startedAt.millisecondsSinceEpoch, 'running', scopeJson, '[]', '{}'],
    );
    return id;
  }

  Future<void> finishProjectEnrichmentRun({
    required String id,
    required DateTime completedAt,
    required String status,
    required int registryEntries,
    required int linkedProjects,
    required int refreshedProjects,
    required int createdItems,
    required int updatedItems,
    required int unchangedItems,
    required int skippedItems,
    required int failedProjects,
    required int summaryConsidered,
    required int summaryRefreshed,
    required int summarySkipped,
    required int summaryFailed,
    required int findings,
    required int openFindings,
    required String warningsJson,
    required String outputJson,
  }) async {
    await customStatement(
      '''UPDATE project_enrichment_runs SET
        completed_at = ?, status = ?, registry_entries = ?, linked_projects = ?,
        refreshed_projects = ?, created_items = ?, updated_items = ?,
        unchanged_items = ?, skipped_items = ?, failed_projects = ?,
        summary_considered = ?, summary_refreshed = ?, summary_skipped = ?,
        summary_failed = ?, findings = ?, open_findings = ?, warnings_json = ?,
        output_json = ? WHERE id = ?''',
      [
        completedAt.millisecondsSinceEpoch,
        status,
        registryEntries,
        linkedProjects,
        refreshedProjects,
        createdItems,
        updatedItems,
        unchangedItems,
        skippedItems,
        failedProjects,
        summaryConsidered,
        summaryRefreshed,
        summarySkipped,
        summaryFailed,
        findings,
        openFindings,
        warningsJson,
        outputJson,
        id,
      ],
    );
  }

  Future<void> recoverStaleProjectEnrichmentRuns({
    DateTime? recoveredAt,
  }) async {
    await _ensureProjectEnrichmentTables();
    final completedAt = recoveredAt ?? DateTime.now();
    await customStatement(
      '''UPDATE project_enrichment_steps
         SET status = 'interrupted', completed_at = ?, failed_items = CASE WHEN failed_items = 0 THEN 1 ELSE failed_items END
         WHERE status = 'running' AND completed_at IS NULL''',
      [completedAt.millisecondsSinceEpoch],
    );
    await customStatement(
      '''UPDATE project_enrichment_runs
         SET status = 'interrupted', completed_at = ?, warnings_json = ?
         WHERE status = 'running' AND completed_at IS NULL''',
      [
        completedAt.millisecondsSinceEpoch,
        jsonEncode(['Recovered interrupted enrichment run.']),
      ],
    );
  }

  Future<void> failRunningProjectEnrichmentStepsForRun({
    required String runId,
    required DateTime completedAt,
    required String warningsJson,
    required String outputJson,
  }) async {
    await customStatement(
      '''UPDATE project_enrichment_steps
         SET status = 'failed', completed_at = ?, failed_items = CASE WHEN failed_items = 0 THEN 1 ELSE failed_items END,
             warnings_json = ?, output_json = ?
         WHERE run_id = ? AND status = 'running' AND completed_at IS NULL''',
      [completedAt.millisecondsSinceEpoch, warningsJson, outputJson, runId],
    );
  }

  Future<void> addProjectEnrichmentFinding({
    required String id,
    required String runId,
    String? projectId,
    String? registryId,
    required String severity,
    required String category,
    required String title,
    String? detail,
    required String evidenceJson,
    String status = 'open',
    required DateTime createdAt,
  }) async {
    await customStatement(
      '''INSERT OR REPLACE INTO project_enrichment_findings (
        id, run_id, project_id, registry_id, severity, category, title, detail,
        evidence_json, status, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        runId,
        projectId,
        registryId,
        severity,
        category,
        title,
        detail,
        evidenceJson,
        status,
        createdAt.millisecondsSinceEpoch,
      ],
    );
  }

  Future<ProjectEnrichmentFinding?> getProjectEnrichmentFinding(
    String id,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM project_enrichment_findings WHERE id = ? LIMIT 1',
      variables: [Variable<String>(id)],
    ).get();
    return rows.isEmpty ? null : _projectEnrichmentFindingFromRow(rows.single);
  }

  Future<void> updateProjectEnrichmentFindingStatus({
    required String id,
    required String status,
  }) async {
    await _ensureProjectEnrichmentTables();
    await customStatement(
      'UPDATE project_enrichment_findings SET status = ? WHERE id = ?',
      [status, id],
    );
  }

  Future<void> refreshProjectEnrichmentRunOpenFindings(String runId) async {
    await _ensureProjectEnrichmentTables();
    await customStatement(
      '''UPDATE project_enrichment_runs
         SET open_findings = (
           SELECT COUNT(*) FROM project_enrichment_findings
           WHERE run_id = ? AND status = 'open'
         )
         WHERE id = ?''',
      [runId, runId],
    );
  }

  Future<List<ProjectEnrichmentFinding>> getProjectEnrichmentFindingsForRun(
    String runId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM project_enrichment_findings WHERE run_id = ? ORDER BY created_at ASC',
      variables: [Variable<String>(runId)],
    ).get();
    return rows.map(_projectEnrichmentFindingFromRow).toList(growable: false);
  }

  Stream<List<ProjectEnrichmentFinding>> watchProjectEnrichmentFindingsForRun(
    String runId,
  ) =>
      customSelect(
        'SELECT * FROM project_enrichment_findings WHERE run_id = ? ORDER BY created_at ASC',
        variables: [Variable<String>(runId)],
      ).watch().map(
        (rows) =>
            rows.map(_projectEnrichmentFindingFromRow).toList(growable: false),
      );

  Future<List<ProjectEnrichmentFinding>> getOpenProjectEnrichmentFindings({
    String? projectId,
    int limit = 100,
  }) async {
    final rows = await customSelect(
      projectId == null
          ? 'SELECT * FROM project_enrichment_findings WHERE status = ? ORDER BY created_at DESC LIMIT ?'
          : 'SELECT * FROM project_enrichment_findings WHERE status = ? AND project_id = ? ORDER BY created_at DESC LIMIT ?',
      variables: projectId == null
          ? [Variable<String>('open'), Variable<int>(limit)]
          : [
              Variable<String>('open'),
              Variable<String>(projectId),
              Variable<int>(limit),
            ],
    ).get();
    return rows.map(_projectEnrichmentFindingFromRow).toList(growable: false);
  }

  Future<String> startProjectEnrichmentStep({
    required String runId,
    required String worker,
    required String title,
    required DateTime startedAt,
  }) async {
    final id = _newMicrosId('step');
    await customStatement(
      '''INSERT INTO project_enrichment_steps (
        id, run_id, worker, title, status, started_at, warnings_json, output_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        runId,
        worker,
        title,
        'running',
        startedAt.millisecondsSinceEpoch,
        '[]',
        '{}',
      ],
    );
    return id;
  }

  Future<void> finishProjectEnrichmentStep({
    required String id,
    required DateTime completedAt,
    required String status,
    required int considered,
    required int createdItems,
    required int updatedItems,
    required int skippedItems,
    required int failedItems,
    required int findings,
    required int proposals,
    required String warningsJson,
    required String outputJson,
  }) async {
    await customStatement(
      '''UPDATE project_enrichment_steps SET
        completed_at = ?, status = ?, considered = ?, created_items = ?,
        updated_items = ?, skipped_items = ?, failed_items = ?, findings = ?,
        proposals = ?, warnings_json = ?, output_json = ? WHERE id = ?''',
      [
        completedAt.millisecondsSinceEpoch,
        status,
        considered,
        createdItems,
        updatedItems,
        skippedItems,
        failedItems,
        findings,
        proposals,
        warningsJson,
        outputJson,
        id,
      ],
    );
  }

  Future<List<ProjectEnrichmentStep>> getProjectEnrichmentStepsForRun(
    String runId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM project_enrichment_steps WHERE run_id = ? ORDER BY started_at ASC',
      variables: [Variable<String>(runId)],
    ).get();
    return rows.map(_projectEnrichmentStepFromRow).toList(growable: false);
  }

  Stream<List<ProjectEnrichmentStep>> watchProjectEnrichmentStepsForRun(
    String runId,
  ) =>
      customSelect(
        'SELECT * FROM project_enrichment_steps WHERE run_id = ? ORDER BY started_at ASC',
        variables: [Variable<String>(runId)],
      ).watch().map(
        (rows) =>
            rows.map(_projectEnrichmentStepFromRow).toList(growable: false),
      );

  Future<void> addProjectEnrichmentProposal({
    required String id,
    required String runId,
    String? projectId,
    String? registryId,
    required String worker,
    required String proposalType,
    required String title,
    String? detail,
    required String payloadJson,
    required int confidence,
    String status = 'proposed',
    required DateTime createdAt,
  }) async {
    await customStatement(
      '''INSERT OR REPLACE INTO project_enrichment_proposals (
        id, run_id, project_id, registry_id, worker, proposal_type, title,
        detail, payload_json, confidence, status, created_at, applied_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)''',
      [
        id,
        runId,
        projectId,
        registryId,
        worker,
        proposalType,
        title,
        detail,
        payloadJson,
        confidence,
        status,
        createdAt.millisecondsSinceEpoch,
      ],
    );
  }

  Future<List<ProjectEnrichmentProposal>> getProjectEnrichmentProposalsForRun(
    String runId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM project_enrichment_proposals WHERE run_id = ? ORDER BY created_at ASC',
      variables: [Variable<String>(runId)],
    ).get();
    return rows.map(_projectEnrichmentProposalFromRow).toList(growable: false);
  }

  Stream<List<ProjectEnrichmentProposal>> watchProjectEnrichmentProposalsForRun(
    String runId,
  ) =>
      customSelect(
        'SELECT * FROM project_enrichment_proposals WHERE run_id = ? ORDER BY created_at ASC',
        variables: [Variable<String>(runId)],
      ).watch().map(
        (rows) =>
            rows.map(_projectEnrichmentProposalFromRow).toList(growable: false),
      );

  LlmTaskQueueItem _llmTaskQueueItemFromRow(QueryRow row) => LlmTaskQueueItem(
    id: row.data['id'] as String,
    projectId: row.data['project_id'] as String,
    workItemId: row.data['work_item_id'] as String?,
    title: row.data['title'] as String,
    objective: row.data['objective'] as String,
    contextJson: row.data['context_json'] as String,
    priority: row.data['priority'] as String,
    status: row.data['status'] as String,
    createdBy: row.data['created_by'] as String,
    createdAt: _dateFromSqlValue(row.data['created_at']),
    updatedAt: _dateFromSqlValue(row.data['updated_at']),
    leasedBy: row.data['leased_by'] as String?,
    leasedAt: _nullableDateFromSqlValue(row.data['leased_at']),
    leaseExpiresAt: _nullableDateFromSqlValue(row.data['lease_expires_at']),
    attempts: _intFromSql(row.data['attempts']),
    resultJson: row.data['result_json'] as String?,
    error: row.data['error'] as String?,
    reviewDraftId: row.data['review_draft_id'] as String?,
    completedAt: _nullableDateFromSqlValue(row.data['completed_at']),
    readiness: row.data['readiness'] as String? ?? 'ready',
    size: row.data['size'] as String? ?? 'medium',
    risk: row.data['risk'] as String? ?? 'low_code',
    suggestedActor: row.data['suggested_actor'] as String? ?? 'user',
    verificationNeeded: row.data['verification_needed'] as String? ?? 'none',
    nextAction: row.data['next_action'] as String?,
    blockerReason: row.data['blocker_reason'] as String?,
    planningNotes: row.data['planning_notes'] as String?,
    lastReviewedAt: _nullableDateFromSqlValue(row.data['last_reviewed_at']),
  );

  Future<String> enqueueLlmTask({
    required String projectId,
    String? workItemId,
    required String title,
    required String objective,
    required String contextJson,
    String priority = 'normal',
    String createdBy = 'ui',
    DateTime? createdAt,
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
    await _ensureLlmTaskQueueTable();
    final now = createdAt ?? DateTime.now();
    final id = _newMicrosId('llm_task');
    await customStatement(
      '''INSERT INTO llm_task_queue (
        id, project_id, work_item_id, title, objective, context_json, priority,
        status, created_by, created_at, updated_at, attempts, readiness, size,
        risk, suggested_actor, verification_needed, next_action,
        blocker_reason, planning_notes, last_reviewed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        projectId,
        workItemId,
        title,
        objective,
        contextJson,
        priority,
        'pending',
        createdBy,
        now.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
        0,
        readiness,
        size,
        risk,
        suggestedActor,
        verificationNeeded,
        nextAction,
        blockerReason,
        planningNotes,
        lastReviewedAt?.millisecondsSinceEpoch,
      ],
    );
    return id;
  }

  Future<List<LlmTaskQueueItem>> getLlmTasks({
    String? projectId,
    String? status,
    int limit = 50,
  }) async {
    await _ensureLlmTaskQueueTable();
    final clauses = <String>[];
    final variables = <Variable>[];
    if (projectId != null) {
      clauses.add('project_id = ?');
      variables.add(Variable<String>(projectId));
    }
    if (status != null) {
      clauses.add('status = ?');
      variables.add(Variable<String>(status));
    }
    variables.add(Variable<int>(limit));
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = await customSelect('''SELECT * FROM llm_task_queue $where
         ORDER BY CASE status WHEN 'pending' THEN 0 WHEN 'leased' THEN 1 WHEN 'failed' THEN 2 WHEN 'cancelled' THEN 3 ELSE 4 END,
                  CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END,
                  created_at ASC
         LIMIT ?''', variables: variables).get();
    return rows.map(_llmTaskQueueItemFromRow).toList(growable: false);
  }

  Future<List<LlmTaskQueueItem>> getLlmTasksForProject(
    String projectId, {
    int limit = 50,
  }) => getLlmTasks(projectId: projectId, limit: limit);

  Future<LlmTaskQueueItem?> getLlmTask(String id) async {
    await _ensureLlmTaskQueueTable();
    final rows = await customSelect(
      'SELECT * FROM llm_task_queue WHERE id = ? LIMIT 1',
      variables: [Variable<String>(id)],
    ).get();
    return rows.isEmpty ? null : _llmTaskQueueItemFromRow(rows.single);
  }

  Future<LlmTaskQueueItem?> updateLlmTask({
    required String id,
    required String projectId,
    String? workItemId,
    required String title,
    required String objective,
    required String contextJson,
    required String priority,
    DateTime? updatedAt,
  }) async {
    await _ensureLlmTaskQueueTable();
    final existing = await getLlmTask(id);
    if (existing == null) return null;
    if (existing.status == 'completed') return existing;
    final now = updatedAt ?? DateTime.now();
    final editedLeasedTask = existing.status == 'leased';
    await customStatement(
      '''UPDATE llm_task_queue
         SET project_id = ?, work_item_id = ?, title = ?, objective = ?,
             context_json = ?, priority = ?, status = ?, updated_at = ?,
             leased_by = ?, leased_at = ?, lease_expires_at = ?
         WHERE id = ? AND status != 'completed' ''',
      [
        projectId,
        workItemId,
        title,
        objective,
        contextJson,
        priority,
        editedLeasedTask ? 'pending' : existing.status,
        now.millisecondsSinceEpoch,
        editedLeasedTask ? null : existing.leasedBy,
        editedLeasedTask ? null : existing.leasedAt?.millisecondsSinceEpoch,
        editedLeasedTask
            ? null
            : existing.leaseExpiresAt?.millisecondsSinceEpoch,
        id,
      ],
    );
    return getLlmTask(id);
  }

  Future<LlmTaskQueueItem?> updateLlmTaskPlanning({
    required String id,
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
    DateTime? updatedAt,
  }) async {
    await _ensureLlmTaskQueueTable();
    final existing = await getLlmTask(id);
    if (existing == null) return null;
    final now = updatedAt ?? DateTime.now();
    await customStatement(
      '''UPDATE llm_task_queue
         SET readiness = ?, size = ?, risk = ?, suggested_actor = ?,
             verification_needed = ?, next_action = ?, blocker_reason = ?,
             planning_notes = ?, last_reviewed_at = ?, updated_at = ?
         WHERE id = ?''',
      [
        readiness ?? existing.readiness,
        size ?? existing.size,
        risk ?? existing.risk,
        suggestedActor ?? existing.suggestedActor,
        verificationNeeded ?? existing.verificationNeeded,
        clearNextAction ? null : nextAction ?? existing.nextAction,
        clearBlockerReason ? null : blockerReason ?? existing.blockerReason,
        clearPlanningNotes ? null : planningNotes ?? existing.planningNotes,
        clearLastReviewedAt
            ? null
            : lastReviewedAt?.millisecondsSinceEpoch ??
                  existing.lastReviewedAt?.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
        id,
      ],
    );
    return getLlmTask(id);
  }

  Future<LlmTaskQueueItem?> linkLlmTaskToWorkItem({
    required String id,
    required String? workItemId,
    DateTime? updatedAt,
  }) async {
    await _ensureLlmTaskQueueTable();
    final existing = await getLlmTask(id);
    if (existing == null) return null;
    final now = updatedAt ?? DateTime.now();
    await customStatement(
      'UPDATE llm_task_queue SET work_item_id = ?, updated_at = ? WHERE id = ?',
      [workItemId, now.millisecondsSinceEpoch, id],
    );
    return getLlmTask(id);
  }

  Future<LlmTaskQueueItem?> cancelLlmTask({
    required String id,
    String? reason,
    DateTime? cancelledAt,
  }) async {
    await _ensureLlmTaskQueueTable();
    final existing = await getLlmTask(id);
    if (existing == null) return null;
    if (existing.status == 'completed') return existing;
    final doneAt = cancelledAt ?? DateTime.now();
    await customStatement(
      '''UPDATE llm_task_queue
         SET status = 'cancelled', error = ?, completed_at = ?, updated_at = ?,
             leased_by = NULL, leased_at = NULL, lease_expires_at = NULL
         WHERE id = ? AND status != 'completed' ''',
      [
        reason,
        doneAt.millisecondsSinceEpoch,
        doneAt.millisecondsSinceEpoch,
        id,
      ],
    );
    return getLlmTask(id);
  }

  Future<LlmTaskQueueItem?> requeueLlmTask({
    required String id,
    DateTime? updatedAt,
  }) async {
    await _ensureLlmTaskQueueTable();
    final existing = await getLlmTask(id);
    if (existing == null) return null;
    if (!{'failed', 'cancelled'}.contains(existing.status)) return existing;
    final now = updatedAt ?? DateTime.now();
    await customStatement(
      '''UPDATE llm_task_queue
         SET status = 'pending', updated_at = ?, leased_by = NULL,
             leased_at = NULL, lease_expires_at = NULL, result_json = NULL,
             error = NULL, review_draft_id = NULL, completed_at = NULL
         WHERE id = ? AND status IN ('failed', 'cancelled')''',
      [now.millisecondsSinceEpoch, id],
    );
    return getLlmTask(id);
  }

  Future<LlmTaskQueueItem?> claimLlmTask({
    String? taskId,
    required String leasedBy,
    DateTime? now,
    Duration leaseDuration = const Duration(hours: 1),
  }) async {
    await _ensureLlmTaskQueueTable();
    final claimedAt = now ?? DateTime.now();
    final rows = await customSelect(
      taskId == null
          ? '''SELECT * FROM llm_task_queue
               WHERE status = 'pending' OR (status = 'leased' AND lease_expires_at < ?)
               ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END,
                        created_at ASC
               LIMIT 1'''
          : '''SELECT * FROM llm_task_queue
               WHERE id = ? AND (status = 'pending' OR (status = 'leased' AND lease_expires_at < ?))
               LIMIT 1''',
      variables: taskId == null
          ? [Variable<int>(claimedAt.millisecondsSinceEpoch)]
          : [
              Variable<String>(taskId),
              Variable<int>(claimedAt.millisecondsSinceEpoch),
            ],
    ).get();
    if (rows.isEmpty) return null;
    final task = _llmTaskQueueItemFromRow(rows.single);
    final expiresAt = claimedAt.add(leaseDuration);
    await customStatement(
      '''UPDATE llm_task_queue SET status = 'leased', leased_by = ?, leased_at = ?,
         lease_expires_at = ?, attempts = attempts + 1, updated_at = ?, error = NULL
         WHERE id = ?''',
      [
        leasedBy,
        claimedAt.millisecondsSinceEpoch,
        expiresAt.millisecondsSinceEpoch,
        claimedAt.millisecondsSinceEpoch,
        task.id,
      ],
    );
    return getLlmTask(task.id);
  }

  Future<LlmTaskQueueItem?> completeLlmTask({
    required String id,
    required String resultJson,
    String? reviewDraftId,
    DateTime? completedAt,
  }) async {
    final existing = await getLlmTask(id);
    if (existing == null) return null;
    if (existing.status != 'leased') return existing;
    final doneAt = completedAt ?? DateTime.now();
    await customStatement(
      '''UPDATE llm_task_queue SET status = 'completed', result_json = ?, review_draft_id = ?,
         completed_at = ?, updated_at = ?, lease_expires_at = NULL
         WHERE id = ? AND status = 'leased' ''',
      [
        resultJson,
        reviewDraftId,
        doneAt.millisecondsSinceEpoch,
        doneAt.millisecondsSinceEpoch,
        id,
      ],
    );
    return getLlmTask(id);
  }

  Future<LlmTaskQueueItem?> failLlmTask({
    required String id,
    required String error,
    String? resultJson,
    DateTime? completedAt,
  }) async {
    final existing = await getLlmTask(id);
    if (existing == null) return null;
    if (existing.status != 'leased') return existing;
    final failedAt = completedAt ?? DateTime.now();
    await customStatement(
      '''UPDATE llm_task_queue SET status = 'failed', error = ?, result_json = ?,
         completed_at = ?, updated_at = ?, lease_expires_at = NULL
         WHERE id = ? AND status = 'leased' ''',
      [
        error,
        resultJson,
        failedAt.millisecondsSinceEpoch,
        failedAt.millisecondsSinceEpoch,
        id,
      ],
    );
    return getLlmTask(id);
  }
}
