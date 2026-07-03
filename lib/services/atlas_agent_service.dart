import 'dart:convert';

import '../db/app_db.dart';
import '../shared/models/app_state.dart';
import '../shared/models/project_metadata.dart' as project_meta;
import 'local_git_visibility_service.dart';
import 'local_project_refresh_service.dart';
import 'project_identity_resolver.dart';

class AtlasProjectStatus {
  final String id;
  final String title;
  final String status;
  final String? category;
  final String? owner;
  final String? phase;
  final String? priority;
  final DateTime createdAt;
  final int activeWorkItems;
  final int blockedWorkItems;
  final int documents;
  final int media;
  final int risks;
  final int decisions;
  final bool hasLocalRegistry;
  final DateTime? lastLocalObservationAt;
  final Map<String, Object?>? githubRemote;

  const AtlasProjectStatus({
    required this.id,
    required this.title,
    required this.status,
    required this.category,
    required this.owner,
    required this.phase,
    required this.priority,
    required this.createdAt,
    required this.activeWorkItems,
    required this.blockedWorkItems,
    required this.documents,
    required this.media,
    required this.risks,
    required this.decisions,
    required this.hasLocalRegistry,
    required this.lastLocalObservationAt,
    required this.githubRemote,
  });

  bool get needsAttention =>
      AtlasAgentService.attentionProjectStatuses.contains(status) ||
      blockedWorkItems > 0;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'status': status,
    'category': category,
    'owner': owner,
    'phase': phase,
    'priority': priority,
    'createdAt': createdAt.toIso8601String(),
    'activeWorkItems': activeWorkItems,
    'blockedWorkItems': blockedWorkItems,
    'documents': documents,
    'media': media,
    'risks': risks,
    'decisions': decisions,
    'hasLocalRegistry': hasLocalRegistry,
    'lastLocalObservationAt': lastLocalObservationAt?.toIso8601String(),
    'githubRemote': githubRemote,
    'needsAttention': needsAttention,
  };
}

class AtlasProjectBrief {
  final AtlasProjectStatus status;
  final String? description;
  final String? category;
  final String? desiredOutcome;
  final String? successCriteria;
  final String? scopeIncluded;
  final String? scopeExcluded;
  final String? outcomeSummary;
  final String? lessonsLearned;
  final List<Map<String, Object?>> tags;
  final List<Map<String, Object?>> people;
  final List<Map<String, Object?>> risks;
  final List<Map<String, Object?>> decisions;
  final List<Map<String, Object?>> openWorkItems;
  final Map<String, Object?>? localRegistry;
  final Map<String, Object?>? latestLocalObservation;
  final Map<String, Object?>? githubRemote;

  const AtlasProjectBrief({
    required this.status,
    required this.description,
    required this.category,
    required this.desiredOutcome,
    required this.successCriteria,
    required this.scopeIncluded,
    required this.scopeExcluded,
    required this.outcomeSummary,
    required this.lessonsLearned,
    required this.tags,
    required this.people,
    required this.risks,
    required this.decisions,
    required this.openWorkItems,
    required this.localRegistry,
    required this.latestLocalObservation,
    required this.githubRemote,
  });

  Map<String, Object?> toJson() => {
    'status': status.toJson(),
    'description': description,
    'category': category,
    'desiredOutcome': desiredOutcome,
    'successCriteria': successCriteria,
    'scopeIncluded': scopeIncluded,
    'scopeExcluded': scopeExcluded,
    'outcomeSummary': outcomeSummary,
    'lessonsLearned': lessonsLearned,
    'tags': tags,
    'people': people,
    'risks': risks,
    'decisions': decisions,
    'openWorkItems': openWorkItems,
    'localRegistry': localRegistry,
    'latestLocalObservation': latestLocalObservation,
    'githubRemote': githubRemote,
  };
}

class AtlasProjectBootstrapContext {
  final String schema;
  final DateTime generatedAt;
  final AtlasProjectIdentity identity;
  final AtlasProjectBrief brief;
  final AtlasCapsuleStatus capsule;
  final List<Map<String, Object?>> pendingLlmTasks;
  final List<Map<String, Object?>> pendingAgentProposals;
  final String recommendedNextAction;
  final String confidence;
  final List<String> gaps;

  const AtlasProjectBootstrapContext({
    this.schema = 'atlas.project_bootstrap_context.v1',
    required this.generatedAt,
    required this.identity,
    required this.brief,
    required this.capsule,
    required this.pendingLlmTasks,
    required this.pendingAgentProposals,
    required this.recommendedNextAction,
    required this.confidence,
    required this.gaps,
  });

  Map<String, Object?> toJson() => {
    'schema': schema,
    'generatedAt': generatedAt.toIso8601String(),
    'identity': identity.toJson(),
    'brief': brief.toJson(),
    'capsule': capsule.toJson(),
    'pendingLlmTasks': pendingLlmTasks,
    'pendingAgentProposals': pendingAgentProposals,
    'recommendedNextAction': recommendedNextAction,
    'confidence': confidence,
    'gaps': gaps,
  };
}

class AtlasLlmTaskBootstrapContext {
  final String schema;
  final DateTime generatedAt;
  final Map<String, Object?> task;
  final AtlasProjectBootstrapContext projectBootstrap;

  const AtlasLlmTaskBootstrapContext({
    this.schema = 'atlas.llm_task_bootstrap_context.v1',
    required this.generatedAt,
    required this.task,
    required this.projectBootstrap,
  });

  Map<String, Object?> toJson() => {
    'schema': schema,
    'generatedAt': generatedAt.toIso8601String(),
    'task': task,
    'projectBootstrap': projectBootstrap.toJson(),
  };
}

class AtlasProposalResult {
  final String proposalId;
  final String type;
  final String? projectId;
  final String title;
  final Map<String, Object?> payload;
  final List<String> validationErrors;
  final List<String> warnings;
  final DateTime createdAt;
  final String? draftId;

  const AtlasProposalResult({
    required this.proposalId,
    required this.type,
    required this.projectId,
    required this.title,
    required this.payload,
    required this.validationErrors,
    required this.warnings,
    required this.createdAt,
    required this.draftId,
  });

  bool get acceptedForReview => draftId != null && validationErrors.isEmpty;

  Map<String, Object?> toJson() => {
    'proposalId': proposalId,
    'type': type,
    'projectId': projectId,
    'title': title,
    'payload': payload,
    'validationErrors': validationErrors,
    'warnings': warnings,
    'createdAt': createdAt.toIso8601String(),
    'draftId': draftId,
    'acceptedForReview': acceptedForReview,
  };
}

class AtlasProposalDraft {
  final Draft draft;
  final String proposalId;
  final String type;
  final String? projectId;
  final Map<String, Object?> payload;
  final List<String> validationErrors;
  final List<String> warnings;
  final DateTime? createdAt;
  final String reviewStatus;
  final String? reviewMessage;
  final Map<String, Object?> envelope;

  const AtlasProposalDraft({
    required this.draft,
    required this.proposalId,
    required this.type,
    required this.projectId,
    required this.payload,
    required this.validationErrors,
    required this.warnings,
    required this.createdAt,
    required this.reviewStatus,
    required this.reviewMessage,
    required this.envelope,
  });

  bool get isPending => reviewStatus == AtlasAgentService.reviewStatusPending;
  bool get isApproved =>
      reviewStatus == AtlasAgentService.reviewStatusApproved || draft.accepted;
  bool get isRejected => reviewStatus == AtlasAgentService.reviewStatusRejected;

  factory AtlasProposalDraft.fromDraft(Draft draft) {
    final envelope = _decodeEnvelope(draft.inputJson);
    final createdAtRaw = envelope['createdAt'];
    final reviewStatus =
        _clean(envelope['reviewStatus']) ??
        (draft.accepted
            ? AtlasAgentService.reviewStatusApproved
            : AtlasAgentService.reviewStatusPending);
    return AtlasProposalDraft(
      draft: draft,
      proposalId: _clean(envelope['proposalId']) ?? draft.id,
      type: _clean(envelope['type']) ?? draft.kind,
      projectId: _clean(envelope['projectId']) ?? draft.projectId,
      payload: _objectMap(envelope['payload']),
      validationErrors: _stringList(envelope['validationErrors']),
      warnings: _stringList(envelope['warnings']),
      createdAt: createdAtRaw is String
          ? DateTime.tryParse(createdAtRaw)
          : null,
      reviewStatus: reviewStatus,
      reviewMessage: _clean(envelope['reviewMessage']),
      envelope: envelope,
    );
  }

  Map<String, Object?> toJson() => {
    'draftId': draft.id,
    'proposalId': proposalId,
    'type': type,
    'projectId': projectId,
    'title': draft.title,
    'payload': payload,
    'validationErrors': validationErrors,
    'warnings': warnings,
    'createdAt': createdAt?.toIso8601String(),
    'reviewStatus': reviewStatus,
    'reviewMessage': reviewMessage,
  };

  static Map<String, Object?> _decodeEnvelope(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return _objectMap(decoded);
    } catch (_) {
      return const {};
    }
  }

  static Map<String, Object?> _objectMap(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, value) => MapEntry('$key', value));
  }

  static List<String> _stringList(Object? value) {
    if (value is! Iterable) return const [];
    return value.map((item) => '$item').toList(growable: false);
  }

  static String? _clean(Object? value) {
    if (value == null) return null;
    final trimmed = '$value'.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class AtlasProposalApplyResult {
  final String draftId;
  final String proposalId;
  final String type;
  final String reviewStatus;
  final String message;
  final String? entityId;

  const AtlasProposalApplyResult({
    required this.draftId,
    required this.proposalId,
    required this.type,
    required this.reviewStatus,
    required this.message,
    required this.entityId,
  });

  Map<String, Object?> toJson() => {
    'draftId': draftId,
    'proposalId': proposalId,
    'type': type,
    'reviewStatus': reviewStatus,
    'message': message,
    'entityId': entityId,
  };
}

class AtlasAgentService {
  final AppState state;

  AtlasAgentService(this.state);

  static const String proposalDraftKind = 'atlas_agent_proposal';
  static const String handoffDraftKind = 'project_handoff';
  static const String reviewStatusPending = 'pending';
  static const String reviewStatusApproved = 'approved';
  static const String reviewStatusRejected = 'rejected';

  static final Set<String> projectStatuses = Set.unmodifiable(
    project_meta.projectStatusValues,
  );

  static final Set<String> attentionProjectStatuses = Set.unmodifiable(
    project_meta.attentionProjectStatuses,
  );

  static const Set<String> projectPhases = {
    '',
    'idea',
    'design',
    'build',
    'test',
    'ship',
    'stabilize',
  };

  static const Set<String> priorities = {'low', 'normal', 'high', 'urgent'};

  static const Set<String> workItemStatuses = {
    'inbox',
    'next',
    'doing',
    'waiting',
    'done',
    'archived',
  };

  static const Set<String> llmTaskStatuses = {
    'pending',
    'leased',
    'completed',
    'failed',
    'cancelled',
  };

  static const Set<String> manifestFields = {
    'title',
    'owner',
    'status',
    'category',
    'description',
    'desiredOutcome',
    'successCriteria',
    'phase',
    'priority',
    'scopeIncluded',
    'scopeExcluded',
    'outcomeSummary',
    'lessonsLearned',
    'tags',
    'repo',
    'localPath',
    'people',
    'risks',
    'decisions',
  };

  static const Set<String> applyableManifestFields = {
    'title',
    'owner',
    'status',
    'category',
    'description',
    'desiredOutcome',
    'successCriteria',
    'phase',
    'priority',
    'scopeIncluded',
    'scopeExcluded',
    'outcomeSummary',
    'lessonsLearned',
  };

  Future<List<AtlasProjectStatus>> listProjects({
    bool includeArchived = true,
  }) async {
    final projects = includeArchived
        ? await state.getVisibleProjects()
        : await state.getProjectsFull();
    final rows = <AtlasProjectStatus>[];
    for (final project in projects) {
      rows.add(await _buildProjectStatus(project));
    }
    rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return rows;
  }

  Future<AtlasProjectStatus?> getProjectStatus(String projectId) async {
    final project = await _visibleProject(projectId);
    if (project == null) return null;
    return _buildProjectStatus(project);
  }

  Future<AtlasProjectBrief?> getProjectBrief(String projectId) async {
    final project = await _visibleProject(projectId);
    if (project == null) return null;

    final status = await _buildProjectStatus(project);
    final tags = await state.getTagsForProject(projectId);
    final people = await state.getProjectPeople(projectId);
    final risks = await state.getProjectRisks(projectId);
    final decisions = await state.getProjectDecisions(projectId);
    final items = await state.getWorkItemsForProject(projectId);
    final registry = await state.getProjectRegistryForAtlasProject(projectId);
    final observation = await state.getLatestLocalProjectObservation(projectId);
    final githubRemote = await state.getLatestProjectGitRemoteStatus(projectId);
    final openItems =
        items
            .where((item) => !{'done', 'archived'}.contains(item.status))
            .toList()
          ..sort((a, b) {
            final priority = _priorityRank(
              b.priority,
            ).compareTo(_priorityRank(a.priority));
            if (priority != 0) return priority;
            return b.updatedAt.compareTo(a.updatedAt);
          });

    return AtlasProjectBrief(
      status: status,
      description: _clean(project.description),
      category: _clean(project.category),
      desiredOutcome: _clean(project.desiredOutcome),
      successCriteria: _clean(project.successCriteria),
      scopeIncluded: _clean(project.scopeIncluded),
      scopeExcluded: _clean(project.scopeExcluded),
      outcomeSummary: _clean(project.outcomeSummary),
      lessonsLearned: _clean(project.lessonsLearned),
      tags: tags.map(_tagToJson).toList(),
      people: people.map(_personToJson).toList(),
      risks: risks.map(_riskToJson).toList(),
      decisions: decisions.map(_decisionToJson).toList(),
      openWorkItems: openItems.map(_workItemToJson).toList(),
      localRegistry: registry == null ? null : _registryToJson(registry),
      latestLocalObservation: observation == null
          ? null
          : _observationToJson(observation),
      githubRemote: githubRemote?.toJson(),
    );
  }

  Future<AtlasProjectIdentity?> getProjectIdentity(String projectId) async {
    final project = await _visibleProject(projectId);
    if (project == null) return null;
    final registry = await state.getProjectRegistryForAtlasProject(projectId);
    final githubRemote = await state.getLatestProjectGitRemoteStatus(projectId);
    return const ProjectIdentityResolver().resolveIdentity(
      projectId: project.id,
      title: project.title,
      status: project.status,
      localRegistry: registry == null ? null : _registryToJson(registry),
      localPath: registry?.localPath,
      repoRoot: registry?.gitRoot ?? registry?.localPath,
      githubRemote: githubRemote?.toJson(),
    );
  }

  Future<AtlasCapsuleStatus?> getProjectCapsuleStatus(String projectId) async {
    final project = await _visibleProject(projectId);
    if (project == null) return null;
    final registry = await state.getProjectRegistryForAtlasProject(projectId);
    return const ProjectIdentityResolver().resolveCapsuleStatus(
      projectId: projectId,
      localPath: registry?.localPath,
    );
  }

  Future<AtlasProjectBootstrapContext?> getProjectBootstrapContext(
    String projectId,
  ) async {
    final project = await _visibleProject(projectId);
    if (project == null) return null;
    final brief = await getProjectBrief(projectId);
    final identity = await getProjectIdentity(projectId);
    final capsule = await getProjectCapsuleStatus(projectId);
    if (brief == null || identity == null || capsule == null) return null;

    final pendingTasks = await listLlmTasks(
      projectId: projectId,
      status: 'pending',
      limit: 25,
    );
    final pendingProposals = (await listRecentAgentProposalReviews(limit: 25))
        .where(
          (proposal) => proposal.projectId == projectId && proposal.isPending,
        )
        .map((proposal) => proposal.toJson())
        .toList(growable: false);
    final gaps = {
      ...identity.issues,
      if (brief.localRegistry == null) 'Project has no linked local registry.',
      if (pendingTasks.isEmpty)
        'No pending LLM task is queued for this project.',
      ...capsule.errors,
    }.toList(growable: false);
    final recommendedNextAction = pendingTasks.isNotEmpty
        ? 'Claim next pending LLM task: ${pendingTasks.first.title}.'
        : capsule.errors.isNotEmpty
        ? 'Resolve capsule visibility errors before agent startup.'
        : 'Review project brief and create or claim the next work order.';
    final confidence = capsule.errors.isNotEmpty
        ? 'low'
        : capsule.warnings.isNotEmpty || gaps.isNotEmpty
        ? 'medium'
        : 'high';

    return AtlasProjectBootstrapContext(
      generatedAt: DateTime.now(),
      identity: identity,
      brief: brief,
      capsule: capsule,
      pendingLlmTasks: pendingTasks
          .map((task) => task.toJson())
          .toList(growable: false),
      pendingAgentProposals: pendingProposals,
      recommendedNextAction: recommendedNextAction,
      confidence: confidence,
      gaps: gaps,
    );
  }

  Future<List<AtlasProjectStatus>> getStaleProjects() async =>
      (await listProjects())
          .where((project) => project.needsAttention)
          .toList();

  Future<LocalProjectBatchRefreshResult> refreshLinkedLocalProjects({
    bool includeSourceDocuments = true,
  }) => state.refreshLinkedLocalProjects(
    includeSourceDocuments: includeSourceDocuments,
  );

  Future<ProjectEnrichmentRunResult> runProjectEnrichment({
    bool refreshLinkedProjects = true,
    bool includeSourceDocuments = true,
    bool refreshSummaries = false,
  }) => state.runProjectEnrichment(
    refreshLinkedProjects: refreshLinkedProjects,
    includeSourceDocuments: includeSourceDocuments,
    refreshSummaries: refreshSummaries,
    betweenProjects: Duration.zero,
  );

  Future<List<ProjectEnrichmentRun>> listProjectEnrichmentRuns({
    int limit = 20,
  }) => state.getProjectEnrichmentRuns(limit: limit);

  Future<Map<String, Object?>?> getProjectEnrichmentRun(String runId) async {
    final run = await state.getProjectEnrichmentRun(runId);
    if (run == null) return null;
    final findings = await state.getProjectEnrichmentFindingsForRun(runId);
    final steps = await state.getProjectEnrichmentStepsForRun(runId);
    final proposals = await state.getProjectEnrichmentProposalsForRun(runId);
    return {
      'run': run.toJson(),
      'findings': findings.map((finding) => finding.toJson()).toList(),
      'steps': steps.map((step) => step.toJson()).toList(),
      'proposals': proposals.map((proposal) => proposal.toJson()).toList(),
    };
  }

  Future<LocalProjectRefreshPreview> previewLocalRefresh(String projectId) =>
      state.previewLocalProjectRefresh(projectId);

  Future<LocalGitVisibilityReport> inspectGitVisibility(String projectId) =>
      state.inspectLocalGitVisibility(projectId);

  Future<ProjectGitRemoteStatus?> getGithubRemoteStatus(String projectId) =>
      state.getLatestProjectGitRemoteStatus(projectId);

  Future<ProjectGitRemoteStatus> refreshGithubRemoteStatus(String projectId) =>
      state.refreshProjectGithubRemoteMetadata(projectId);

  Future<LlmTaskQueueItem> enqueueLlmTask({
    required String projectId,
    String? workItemId,
    required String title,
    required String objective,
    String priority = 'normal',
    Map<String, Object?> context = const {},
    String createdBy = 'mcp',
  }) async {
    final errors = <String>[];
    await _validateProject(projectId, errors);
    final cleanTitle = _clean(title);
    final cleanObjective = _clean(objective);
    final cleanPriority = _clean(priority) ?? 'normal';
    if (cleanTitle == null) errors.add('LLM task title is required.');
    if (cleanObjective == null) errors.add('LLM task objective is required.');
    if (!priorities.contains(cleanPriority)) {
      errors.add('Unsupported priority: $cleanPriority.');
    }
    if (workItemId != null && workItemId.trim().isNotEmpty) {
      final item = await state.getWorkItem(workItemId);
      final owningProject = await state.getProjectForWorkItem(workItemId);
      if (item == null || owningProject?.id != projectId) {
        errors.add('Work item is not part of project $projectId: $workItemId.');
      }
    }
    if (errors.isNotEmpty) throw StateError(errors.join(' '));
    final taskId = await state.enqueueLlmTask(
      projectId: projectId,
      workItemId: _clean(workItemId),
      title: cleanTitle!,
      objective: cleanObjective!,
      priority: cleanPriority,
      context: context,
      createdBy: _clean(createdBy) ?? 'mcp',
    );
    final task = await state.getLlmTask(taskId);
    if (task == null) throw StateError('LLM task was not saved: $taskId');
    return task;
  }

  Future<List<LlmTaskQueueItem>> listLlmTasks({
    String? projectId,
    String? status,
    int limit = 50,
  }) async {
    final cleanStatus = _clean(status);
    if (cleanStatus != null && !llmTaskStatuses.contains(cleanStatus)) {
      throw StateError('Unsupported LLM task status: $cleanStatus.');
    }
    if (projectId != null && projectId.trim().isNotEmpty) {
      final project = await _visibleProject(projectId);
      if (project == null) {
        throw StateError('Project not found or not visible: $projectId.');
      }
    }
    return state.getLlmTasks(
      projectId: _clean(projectId),
      status: cleanStatus,
      limit: limit,
    );
  }

  Future<LlmTaskQueueItem?> getLlmTask(String taskId) =>
      state.getLlmTask(taskId);

  Future<Map<String, Object?>?> getLlmTaskDetail(String taskId) async {
    final task = await state.getLlmTask(taskId);
    if (task == null) return null;
    final media = await state.getMediaForLlmTask(taskId);
    return {
      ...task.toJson(),
      'media': media.map(_mediaToJson).toList(growable: false),
    };
  }

  Future<AtlasLlmTaskBootstrapContext> getLlmTaskBootstrap(
    String taskId, {
    String? projectId,
  }) async {
    final cleanTaskId = _clean(taskId);
    if (cleanTaskId == null) throw StateError('Task ID is required.');
    final task = await state.getLlmTask(cleanTaskId);
    if (task == null) throw StateError('LLM task not found: $cleanTaskId');
    final expectedProjectId = _clean(projectId);
    if (expectedProjectId != null && task.projectId != expectedProjectId) {
      throw StateError(
        'LLM task $cleanTaskId belongs to ${task.projectId}, not $expectedProjectId.',
      );
    }
    if (task.status == 'completed' || task.status == 'cancelled') {
      throw StateError(
        'LLM task $cleanTaskId is ${task.status}; bootstrap is only available for pending, leased, or failed tasks.',
      );
    }
    final taskDetail = await getLlmTaskDetail(cleanTaskId);
    if (taskDetail == null) {
      throw StateError('LLM task detail not found: $cleanTaskId');
    }
    final projectBootstrap = await getProjectBootstrapContext(task.projectId);
    if (projectBootstrap == null) {
      throw StateError(
        'Project bootstrap context not available for ${task.projectId}.',
      );
    }
    return AtlasLlmTaskBootstrapContext(
      generatedAt: DateTime.now(),
      task: taskDetail,
      projectBootstrap: projectBootstrap,
    );
  }

  Future<LlmTaskQueueItem> updateLlmTask({
    required String taskId,
    required String projectId,
    String? workItemId,
    required String title,
    required String objective,
    String priority = 'normal',
    Map<String, Object?> context = const {},
  }) async {
    final task = await state.getLlmTask(taskId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    if (task.status == 'completed') {
      throw StateError('Completed LLM tasks cannot be edited.');
    }
    final errors = <String>[];
    final cleanProjectId = _clean(projectId);
    if (cleanProjectId == null) {
      errors.add('Project ID is required.');
    } else {
      await _validateProject(cleanProjectId, errors);
    }
    final cleanTitle = _clean(title);
    final cleanObjective = _clean(objective);
    final cleanPriority = _clean(priority) ?? 'normal';
    if (cleanTitle == null) errors.add('LLM task title is required.');
    if (cleanObjective == null) errors.add('LLM task objective is required.');
    if (!priorities.contains(cleanPriority)) {
      errors.add('Unsupported priority: $cleanPriority.');
    }
    final cleanWorkItemId = _clean(workItemId);
    if (cleanWorkItemId != null && cleanProjectId != null) {
      final item = await state.getWorkItem(cleanWorkItemId);
      final owningProject = await state.getProjectForWorkItem(cleanWorkItemId);
      if (item == null || owningProject?.id != cleanProjectId) {
        errors.add(
          'Work item is not part of project $cleanProjectId: $cleanWorkItemId.',
        );
      }
    }
    if (errors.isNotEmpty) throw StateError(errors.join(' '));
    return state.updateLlmTask(
      taskId: taskId,
      projectId: cleanProjectId!,
      workItemId: cleanWorkItemId,
      title: cleanTitle!,
      objective: cleanObjective!,
      priority: cleanPriority,
      context: context,
    );
  }

  Future<LlmTaskQueueItem?> claimLlmTask({
    String? taskId,
    required String workerId,
    int leaseMinutes = 60,
  }) {
    final worker = _clean(workerId);
    if (worker == null) throw StateError('Worker ID is required.');
    return state.claimLlmTask(
      taskId: _clean(taskId),
      leasedBy: worker,
      leaseDuration: Duration(minutes: leaseMinutes <= 0 ? 60 : leaseMinutes),
    );
  }

  Future<LlmTaskQueueItem> completeLlmTask({
    required String taskId,
    String? workerId,
    required Map<String, Object?> result,
    String? proposalTitle,
    String? proposalBody,
  }) async {
    final task = await state.getLlmTask(taskId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    final worker = _clean(workerId);
    if (worker != null && task.leasedBy != null && task.leasedBy != worker) {
      throw StateError('Task is leased by ${task.leasedBy}, not $worker.');
    }
    if (task.status != 'leased') {
      throw StateError(
        'Task must be leased before completion: ${task.status}.',
      );
    }
    String? reviewDraftId;
    final body = _clean(proposalBody);
    if (body != null) {
      final proposal = await recordHandoff(
        projectId: task.projectId,
        title: _clean(proposalTitle) ?? 'LLM result: ${task.title}',
        body: body,
      );
      reviewDraftId = proposal.draftId;
    }
    final completed = await state.completeLlmTask(
      taskId: taskId,
      result: result,
      reviewDraftId: reviewDraftId,
    );
    if (completed == null) throw StateError('LLM task disappeared: $taskId');
    return completed;
  }

  Future<LlmTaskQueueItem> failLlmTask({
    required String taskId,
    String? workerId,
    required String error,
    Map<String, Object?> result = const {},
  }) async {
    final task = await state.getLlmTask(taskId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    final worker = _clean(workerId);
    if (worker != null && task.leasedBy != null && task.leasedBy != worker) {
      throw StateError('Task is leased by ${task.leasedBy}, not $worker.');
    }
    if (task.status != 'leased') {
      throw StateError('Task must be leased before failure: ${task.status}.');
    }
    final cleanError = _clean(error);
    if (cleanError == null) throw StateError('Failure reason is required.');
    final failed = await state.failLlmTask(
      taskId: taskId,
      error: cleanError,
      result: result,
    );
    if (failed == null) throw StateError('LLM task disappeared: $taskId');
    return failed;
  }

  Future<LlmTaskQueueItem> cancelLlmTask({
    required String taskId,
    String? reason,
  }) async {
    final task = await state.getLlmTask(taskId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    if (task.status == 'completed') {
      throw StateError('Completed LLM tasks cannot be cancelled.');
    }
    return state.cancelLlmTask(taskId, reason: _clean(reason));
  }

  Future<LlmTaskQueueItem> requeueLlmTask({required String taskId}) async {
    final task = await state.getLlmTask(taskId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    if (!{'failed', 'cancelled'}.contains(task.status)) {
      throw StateError('Only failed or cancelled LLM tasks can be requeued.');
    }
    return state.requeueLlmTask(taskId);
  }

  Future<List<Draft>> listRecentAgentProposals({int limit = 50}) async {
    final drafts = await state.watchDrafts().first;
    return drafts
        .where((draft) => draft.kind == proposalDraftKind)
        .take(limit)
        .toList();
  }

  Future<List<AtlasProposalDraft>> listRecentAgentProposalReviews({
    int limit = 50,
  }) async => (await listRecentAgentProposals(
    limit: limit,
  )).map(AtlasProposalDraft.fromDraft).toList();

  Future<AtlasProposalDraft?> getAgentProposalReview(String draftId) async {
    final draft = await state.getDraft(draftId);
    if (draft == null || draft.kind != proposalDraftKind) return null;
    return AtlasProposalDraft.fromDraft(draft);
  }

  Future<AtlasProposalApplyResult> approveAgentProposal(String draftId) async {
    final draft = await _loadProposalDraft(draftId);
    final proposal = AtlasProposalDraft.fromDraft(draft);
    if (proposal.isApproved) {
      return AtlasProposalApplyResult(
        draftId: draft.id,
        proposalId: proposal.proposalId,
        type: proposal.type,
        reviewStatus: reviewStatusApproved,
        message: 'Proposal was already approved.',
        entityId: proposal.projectId,
      );
    }
    if (proposal.isRejected) {
      throw StateError('Rejected proposals cannot be approved.');
    }
    if (proposal.validationErrors.isNotEmpty) {
      throw StateError(
        'Proposal has validation errors: ${proposal.validationErrors.join('; ')}',
      );
    }

    final entityId = await _applyProposal(proposal);
    final message = _approvalMessage(proposal, entityId);
    await _markProposalReviewed(
      draft: draft,
      proposal: proposal,
      status: reviewStatusApproved,
      accepted: true,
      message: message,
      entityId: entityId,
    );
    return AtlasProposalApplyResult(
      draftId: draft.id,
      proposalId: proposal.proposalId,
      type: proposal.type,
      reviewStatus: reviewStatusApproved,
      message: message,
      entityId: entityId,
    );
  }

  Future<AtlasProposalApplyResult> rejectAgentProposal(
    String draftId, {
    String? reason,
  }) async {
    final draft = await _loadProposalDraft(draftId);
    final proposal = AtlasProposalDraft.fromDraft(draft);
    if (proposal.isApproved) {
      throw StateError('Approved proposals cannot be rejected.');
    }
    if (proposal.isRejected) {
      return AtlasProposalApplyResult(
        draftId: draft.id,
        proposalId: proposal.proposalId,
        type: proposal.type,
        reviewStatus: reviewStatusRejected,
        message: proposal.reviewMessage ?? 'Proposal was already rejected.',
        entityId: proposal.projectId,
      );
    }
    final message = _clean(reason) ?? 'Rejected by reviewer.';
    await _markProposalReviewed(
      draft: draft,
      proposal: proposal,
      status: reviewStatusRejected,
      accepted: false,
      message: message,
      entityId: proposal.projectId,
    );
    return AtlasProposalApplyResult(
      draftId: draft.id,
      proposalId: proposal.proposalId,
      type: proposal.type,
      reviewStatus: reviewStatusRejected,
      message: message,
      entityId: proposal.projectId,
    );
  }

  Future<AtlasProposalResult> proposeStatusChange({
    required String projectId,
    required String status,
    String? reason,
  }) async {
    final errors = <String>[];
    final project = await _validateProject(projectId, errors);
    final cleanStatus = _clean(status);
    if (cleanStatus == null || !projectStatuses.contains(cleanStatus)) {
      errors.add('Unsupported project status: $status.');
    }
    return _saveProposal(
      type: 'status_change',
      project: project,
      title: project == null
          ? 'Project status change'
          : 'Set ${project.title} to $cleanStatus',
      payload: {'status': cleanStatus, 'reason': _clean(reason)},
      validationErrors: errors,
    );
  }

  Future<AtlasProposalResult> proposeTaskUpdate({
    required String projectId,
    String? workItemId,
    required String title,
    String? description,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? blockedReason,
    Iterable<String> tagNames = const [],
  }) async {
    final errors = <String>[];
    final warnings = <String>[];
    final project = await _validateProject(projectId, errors);
    final cleanTitle = _clean(title);
    final cleanWorkItemId = _clean(workItemId);
    final cleanStatus = _clean(status) ?? 'next';
    final cleanPriority = _clean(priority) ?? 'normal';

    if (cleanTitle == null) {
      errors.add('Task title is required.');
    }
    if (!workItemStatuses.contains(cleanStatus)) {
      errors.add('Unsupported work item status: $status.');
    }
    if (!priorities.contains(cleanPriority)) {
      errors.add('Unsupported priority: $priority.');
    }
    if (cleanWorkItemId != null) {
      final item = await state.getWorkItem(cleanWorkItemId);
      if (item == null) {
        errors.add('Work item not found: $cleanWorkItemId.');
      } else {
        final ownerProject = await state.getProjectForWorkItem(cleanWorkItemId);
        if (ownerProject?.id != projectId) {
          errors.add('Work item does not belong to project $projectId.');
        }
      }
    } else {
      warnings.add('This proposal creates a new project task if approved.');
    }

    return _saveProposal(
      type: 'task_update',
      project: project,
      title: project == null
          ? 'Task update'
          : '${cleanWorkItemId == null ? 'Create' : 'Update'} task for ${project.title}',
      payload: {
        'workItemId': cleanWorkItemId,
        'title': cleanTitle,
        'description': _clean(description),
        'status': cleanStatus,
        'priority': cleanPriority,
        'dueAt': dueAt?.toIso8601String(),
        'blockedReason': _clean(blockedReason),
        'tagNames': _cleanList(tagNames),
      },
      validationErrors: errors,
      warnings: warnings,
    );
  }

  Future<AtlasProposalResult> proposeManifestUpdate({
    required String projectId,
    required Map<String, Object?> fields,
    String? reason,
  }) async {
    final errors = <String>[];
    final project = await _validateProject(projectId, errors);
    final cleanFields = <String, Object?>{};
    for (final entry in fields.entries) {
      if (!manifestFields.contains(entry.key)) {
        errors.add('Unsupported manifest field: ${entry.key}.');
      } else {
        cleanFields[entry.key] = entry.value;
      }
    }
    if (cleanFields.isEmpty) {
      errors.add('At least one manifest field is required.');
    }
    final title = _clean(cleanFields['title'] as String?);
    if (cleanFields.containsKey('title') && title == null) {
      errors.add('Project title cannot be blank.');
    }
    final status = _clean(cleanFields['status'] as String?);
    if (status != null && !projectStatuses.contains(status)) {
      errors.add('Unsupported project status: $status.');
    }
    final phase = _clean(cleanFields['phase'] as String?);
    if (phase != null && !projectPhases.contains(phase)) {
      errors.add('Unsupported project phase: $phase.');
    }
    final priority = _clean(cleanFields['priority'] as String?);
    if (priority != null && !priorities.contains(priority)) {
      errors.add('Unsupported priority: $priority.');
    }

    return _saveProposal(
      type: 'manifest_update',
      project: project,
      title: project == null
          ? 'Project manifest update'
          : 'Update manifest for ${project.title}',
      payload: {'fields': cleanFields, 'reason': _clean(reason)},
      validationErrors: errors,
    );
  }

  Future<AtlasProposalResult> recordValidationRun({
    required String projectId,
    required String command,
    required bool passed,
    int? exitCode,
    String? summary,
    String? logExcerpt,
  }) async {
    final errors = <String>[];
    final project = await _validateProject(projectId, errors);
    if (_clean(command) == null) {
      errors.add('Validation command is required.');
    }
    return _saveProposal(
      type: 'validation_run',
      project: project,
      title: project == null
          ? 'Validation run'
          : 'Record validation for ${project.title}',
      payload: {
        'command': _clean(command),
        'passed': passed,
        'exitCode': exitCode,
        'summary': _clean(summary),
        'logExcerpt': _clean(logExcerpt),
      },
      validationErrors: errors,
    );
  }

  Future<AtlasProposalResult> recordHandoff({
    required String projectId,
    required String title,
    required String body,
  }) async {
    final errors = <String>[];
    final project = await _validateProject(projectId, errors);
    if (_clean(title) == null) {
      errors.add('Handoff title is required.');
    }
    if (_clean(body) == null) {
      errors.add('Handoff body is required.');
    }
    return _saveProposal(
      type: 'handoff_record',
      project: project,
      title: project == null
          ? 'Project handoff'
          : 'Handoff for ${project.title}',
      payload: {'title': _clean(title), 'body': _clean(body)},
      validationErrors: errors,
    );
  }

  Future<AtlasProposalResult> proposeCloseout({
    required String projectId,
    String? runId,
    String? runState,
    required String summary,
    Map<String, Object?> scope = const {},
    Iterable<String> changedFiles = const [],
    Iterable<Map<String, Object?>> validation = const [],
    Map<String, Object?> capsuleDoctor = const {},
    Iterable<String> packetPaths = const [],
    Map<String, Object?> gitState = const {},
    String? commitRecommendation,
    Iterable<String> risks = const [],
    Iterable<String> overrides = const [],
    String? nextAction,
  }) async {
    final errors = <String>[];
    final warnings = <String>[];
    final project = await _validateProject(projectId, errors);
    final cleanSummary = _clean(summary);
    if (cleanSummary == null) {
      errors.add('Closeout summary is required.');
    }
    final cleanValidation = validation
        .map((entry) => Map<String, Object?>.from(entry))
        .toList(growable: false);
    if (cleanValidation.isEmpty) {
      warnings.add('No validation evidence was included.');
    }
    final cleanRunId = _clean(runId);
    if (cleanRunId == null) {
      warnings.add('No run ID was included.');
    }

    return _saveProposal(
      type: 'closeout_record',
      project: project,
      title: project == null
          ? 'Agent closeout'
          : 'Agent closeout for ${project.title}',
      payload: {
        'runId': cleanRunId,
        'runState': _clean(runState),
        'summary': cleanSummary,
        'scope': Map<String, Object?>.from(scope),
        'changedFiles': _cleanList(changedFiles),
        'validation': cleanValidation,
        'capsuleDoctor': Map<String, Object?>.from(capsuleDoctor),
        'packetPaths': _cleanList(packetPaths),
        'gitState': Map<String, Object?>.from(gitState),
        'commitRecommendation': _clean(commitRecommendation),
        'risks': _cleanList(risks),
        'overrides': _cleanList(overrides),
        'nextAction': _clean(nextAction),
      },
      validationErrors: errors,
      warnings: warnings,
    );
  }

  Future<Project?> _visibleProject(String projectId) async {
    final project = await state.getProjectFull(projectId);
    if (project == null ||
        project.deletedAt != null ||
        project.id == AppDb.kGeneralTasksProjectId) {
      return null;
    }
    return project;
  }

  Future<Draft> _loadProposalDraft(String draftId) async {
    final draft = await state.getDraft(draftId);
    if (draft == null) {
      throw StateError('Agent proposal draft not found: $draftId');
    }
    if (draft.kind != proposalDraftKind) {
      throw StateError('Draft is not an agent proposal: $draftId');
    }
    return draft;
  }

  Future<String?> _applyProposal(AtlasProposalDraft proposal) async {
    final projectId = proposal.projectId;
    switch (proposal.type) {
      case 'status_change':
        if (projectId == null) throw StateError('Project ID is required.');
        final status = _payloadString(proposal.payload, 'status');
        if (status == null || !projectStatuses.contains(status)) {
          throw StateError('Unsupported project status: $status');
        }
        await state.updateProjectMeta(projectId, {
          'status': status,
        }, actor: 'Atlas Agent');
        return projectId;
      case 'task_update':
        return _applyTaskProposal(proposal);
      case 'manifest_update':
        return _applyManifestProposal(proposal);
      case 'validation_run':
        return _applyValidationProposal(proposal);
      case 'handoff_record':
        return _applyHandoffProposal(proposal);
      case 'closeout_record':
        return _applyCloseoutProposal(proposal);
      default:
        throw StateError('Unsupported proposal type: ${proposal.type}');
    }
  }

  Future<String> _applyTaskProposal(AtlasProposalDraft proposal) async {
    final projectId = proposal.projectId;
    if (projectId == null) throw StateError('Project ID is required.');
    final title = _payloadString(proposal.payload, 'title');
    if (title == null) throw StateError('Task title is required.');
    final status = _payloadString(proposal.payload, 'status') ?? 'next';
    final priority = _payloadString(proposal.payload, 'priority') ?? 'normal';
    if (!workItemStatuses.contains(status)) {
      throw StateError('Unsupported work item status: $status');
    }
    if (!priorities.contains(priority)) {
      throw StateError('Unsupported priority: $priority');
    }
    final tagNames = _payloadStringList(proposal.payload, 'tagNames');
    final tagIds = await _ensureTagIds(tagNames);
    final dueAt = _payloadDate(proposal.payload, 'dueAt');
    final workItemId = _payloadString(proposal.payload, 'workItemId');
    if (workItemId == null) {
      return state.addWorkItemToProject(
        projectId,
        title,
        description: _payloadString(proposal.payload, 'description'),
        status: status,
        priority: priority,
        dueAt: dueAt,
        blockedReason: _payloadString(proposal.payload, 'blockedReason'),
        source: 'Atlas agent proposal ${proposal.proposalId}',
        tagIds: tagIds,
      );
    }

    await state.updateWorkItem(
      id: workItemId,
      title: title,
      description: _payloadString(proposal.payload, 'description'),
      status: status,
      priority: priority,
      dueAt: dueAt,
      clearDueAt: proposal.payload.containsKey('dueAt') && dueAt == null,
      blockedReason: _payloadString(proposal.payload, 'blockedReason'),
      clearBlockedReason:
          proposal.payload.containsKey('blockedReason') &&
          _payloadString(proposal.payload, 'blockedReason') == null,
    );
    if (tagNames.isNotEmpty) {
      await state.setWorkItemTags(workItemId, tagIds);
    }
    return workItemId;
  }

  Future<String> _applyManifestProposal(AtlasProposalDraft proposal) async {
    final projectId = proposal.projectId;
    if (projectId == null) throw StateError('Project ID is required.');
    final fields = AtlasProposalDraft._objectMap(proposal.payload['fields']);
    final unsupported =
        fields.keys
            .where(
              (key) => key != 'tags' && !applyableManifestFields.contains(key),
            )
            .toList()
          ..sort();
    if (unsupported.isNotEmpty) {
      throw StateError(
        'These manifest fields still require manual review: ${unsupported.join(', ')}',
      );
    }

    final meta = <String, Object?>{};
    for (final entry in fields.entries) {
      if (applyableManifestFields.contains(entry.key)) {
        meta[entry.key] = entry.value;
      }
    }
    if (meta.isNotEmpty) {
      await state.updateProjectMeta(projectId, meta, actor: 'Atlas Agent');
    }
    if (fields.containsKey('tags')) {
      final tagIds = await _ensureTagIds(_valueStringList(fields['tags']));
      await state.setProjectTags(projectId, tagIds);
    }
    return projectId;
  }

  Future<String?> _applyValidationProposal(AtlasProposalDraft proposal) async {
    await state.db.logEvent(
      area: 'agent',
      action: 'validation_run_approved',
      entityType: 'project',
      entityId: proposal.projectId,
      inputJson: jsonEncode(proposal.toJson()),
    );
    return proposal.projectId;
  }

  Future<String> _applyHandoffProposal(AtlasProposalDraft proposal) async {
    final projectId = proposal.projectId;
    if (projectId == null) throw StateError('Project ID is required.');
    final title =
        _payloadString(proposal.payload, 'title') ?? 'Project handoff';
    final body = _payloadString(proposal.payload, 'body');
    if (body == null) throw StateError('Handoff body is required.');
    return state.saveDraft(
      kind: handoffDraftKind,
      title: title,
      body: body,
      projectId: projectId,
      inputJson: jsonEncode({
        'sourceProposalId': proposal.proposalId,
        'sourceDraftId': proposal.draft.id,
      }),
    );
  }

  Future<String> _applyCloseoutProposal(AtlasProposalDraft proposal) async {
    final projectId = proposal.projectId;
    if (projectId == null) throw StateError('Project ID is required.');
    final summary =
        _payloadString(proposal.payload, 'summary') ?? 'Agent closeout';
    final draftId = await state.saveDraft(
      kind: handoffDraftKind,
      title: 'Agent closeout: $summary',
      body: _closeoutHandoffBody(proposal),
      projectId: projectId,
      inputJson: jsonEncode({
        'sourceProposalId': proposal.proposalId,
        'sourceDraftId': proposal.draft.id,
        'sourceType': proposal.type,
      }),
    );
    await state.db.logEvent(
      area: 'agent',
      action: 'closeout_record_approved',
      entityType: 'project',
      entityId: projectId,
      inputJson: jsonEncode(proposal.toJson()),
      outputJson: jsonEncode({'handoffDraftId': draftId}),
    );
    return draftId;
  }

  Future<void> _markProposalReviewed({
    required Draft draft,
    required AtlasProposalDraft proposal,
    required String status,
    required bool accepted,
    required String message,
    required String? entityId,
  }) async {
    final reviewedAt = DateTime.now();
    final envelope = Map<String, Object?>.from(proposal.envelope)
      ..['reviewStatus'] = status
      ..['reviewedAt'] = reviewedAt.toIso8601String()
      ..['reviewMessage'] = message
      ..['reviewEntityId'] = entityId;
    final updatedBody =
        '${draft.body.trimRight()}\n\n---\nReview: $status\n$message\n';
    await state.updateDraftReview(
      id: draft.id,
      accepted: accepted,
      inputJson: jsonEncode(envelope),
      body: updatedBody,
    );
    await state.db.logEvent(
      area: 'agent',
      action: 'proposal_$status',
      entityType: proposal.projectId == null ? 'draft' : 'project',
      entityId: proposal.projectId ?? draft.id,
      inputJson: jsonEncode(proposal.toJson()),
      outputJson: jsonEncode({
        'draftId': draft.id,
        'message': message,
        'entityId': entityId,
      }),
    );
  }

  String _approvalMessage(AtlasProposalDraft proposal, String? entityId) {
    return switch (proposal.type) {
      'status_change' => 'Project status updated.',
      'task_update' =>
        entityId == null
            ? 'Task update approved.'
            : 'Task update approved: $entityId.',
      'manifest_update' => 'Project manifest fields updated.',
      'validation_run' => 'Validation run recorded.',
      'handoff_record' =>
        entityId == null
            ? 'Handoff recorded.'
            : 'Handoff draft created: $entityId.',
      'closeout_record' =>
        entityId == null
            ? 'Closeout recorded.'
            : 'Closeout handoff draft created: $entityId.',
      _ => 'Proposal approved.',
    };
  }

  Future<Project?> _validateProject(
    String projectId,
    List<String> errors,
  ) async {
    final project = await _visibleProject(projectId);
    if (project == null) {
      errors.add('Project not found or not visible: $projectId.');
    }
    return project;
  }

  Future<AtlasProjectStatus> _buildProjectStatus(Project project) async {
    final items = await state.getWorkItemsForProject(project.id);
    final activeItems = items
        .where((item) => !{'done', 'archived'}.contains(item.status))
        .toList();
    final docs = await state.db.getDocumentsForProject(project.id);
    final media = await state.getProjectMedia(project.id);
    final risks = await state.getProjectRisks(project.id);
    final decisions = await state.getProjectDecisions(project.id);
    final registry = await state.getProjectRegistryForAtlasProject(project.id);
    final observation = await state.getLatestLocalProjectObservation(
      project.id,
    );
    final githubRemote = await state.getLatestProjectGitRemoteStatus(
      project.id,
    );

    return AtlasProjectStatus(
      id: project.id,
      title: project.title,
      status: project.status,
      category: _clean(project.category),
      owner: _clean(project.owner),
      phase: _clean(project.phase),
      priority: _clean(project.priority),
      createdAt: project.createdAt,
      activeWorkItems: activeItems.length,
      blockedWorkItems: activeItems
          .where((item) => _clean(item.blockedReason) != null)
          .length,
      documents: docs.length,
      media: media.length,
      risks: risks.length,
      decisions: decisions.length,
      hasLocalRegistry: registry != null,
      lastLocalObservationAt: observation?.observedAt,
      githubRemote: githubRemote?.toJson(),
    );
  }

  Future<AtlasProposalResult> _saveProposal({
    required String type,
    required Project? project,
    required String title,
    required Map<String, Object?> payload,
    required List<String> validationErrors,
    List<String> warnings = const [],
  }) async {
    final now = DateTime.now();
    final proposalId = 'proposal_${now.microsecondsSinceEpoch}';
    final envelope = {
      'schema': 'atlas.agent.proposal.v1',
      'proposalId': proposalId,
      'type': type,
      'projectId': project?.id,
      'payload': payload,
      'validationErrors': validationErrors,
      'warnings': warnings,
      'createdAt': now.toIso8601String(),
    };
    if (validationErrors.isNotEmpty) {
      return AtlasProposalResult(
        proposalId: proposalId,
        type: type,
        projectId: project?.id,
        title: title,
        payload: payload,
        validationErrors: List.unmodifiable(validationErrors),
        warnings: List.unmodifiable(warnings),
        createdAt: now,
        draftId: null,
      );
    }

    final draftId = await state.saveDraft(
      kind: proposalDraftKind,
      title: title,
      body: _proposalBody(type, title, payload, warnings),
      inputJson: jsonEncode(envelope),
      projectId: project?.id,
    );
    await state.db.logEvent(
      area: 'agent',
      action: 'propose_$type',
      entityType: project == null ? 'atlas' : 'project',
      entityId: project?.id,
      inputJson: jsonEncode(envelope),
    );
    return AtlasProposalResult(
      proposalId: proposalId,
      type: type,
      projectId: project?.id,
      title: title,
      payload: payload,
      validationErrors: const [],
      warnings: List.unmodifiable(warnings),
      createdAt: now,
      draftId: draftId,
    );
  }

  String _proposalBody(
    String type,
    String title,
    Map<String, Object?> payload,
    List<String> warnings,
  ) {
    final buffer = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln('Type: `$type`')
      ..writeln()
      ..writeln('```json')
      ..writeln(const JsonEncoder.withIndent('  ').convert(payload))
      ..writeln('```');
    if (warnings.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Warnings:');
      for (final warning in warnings) {
        buffer.writeln('- $warning');
      }
    }
    return buffer.toString();
  }

  String _closeoutHandoffBody(AtlasProposalDraft proposal) {
    final payload = proposal.payload;
    final buffer = StringBuffer()
      ..writeln('# Agent Closeout')
      ..writeln()
      ..writeln('Proposal: `${proposal.proposalId}`')
      ..writeln(
        'Run ID: `${_payloadString(payload, 'runId') ?? 'not provided'}`',
      )
      ..writeln(
        'Run state: `${_payloadString(payload, 'runState') ?? 'unknown'}`',
      )
      ..writeln()
      ..writeln('## Summary')
      ..writeln()
      ..writeln(_payloadString(payload, 'summary') ?? 'No summary provided.');
    _writeStringListSection(
      buffer,
      'Changed files',
      _payloadStringList(payload, 'changedFiles'),
    );
    _writeJsonSection(buffer, 'Validation', payload['validation']);
    _writeJsonSection(buffer, 'Capsule doctor', payload['capsuleDoctor']);
    _writeStringListSection(
      buffer,
      'Packet paths',
      _payloadStringList(payload, 'packetPaths'),
    );
    _writeJsonSection(buffer, 'Git state', payload['gitState']);
    _writeStringListSection(
      buffer,
      'Risks',
      _payloadStringList(payload, 'risks'),
    );
    _writeStringListSection(
      buffer,
      'Overrides',
      _payloadStringList(payload, 'overrides'),
    );
    final commitRecommendation = _payloadString(
      payload,
      'commitRecommendation',
    );
    if (commitRecommendation != null) {
      buffer
        ..writeln()
        ..writeln('## Commit recommendation')
        ..writeln()
        ..writeln(commitRecommendation);
    }
    final nextAction = _payloadString(payload, 'nextAction');
    if (nextAction != null) {
      buffer
        ..writeln()
        ..writeln('## Next action')
        ..writeln()
        ..writeln(nextAction);
    }
    _writeJsonSection(buffer, 'Scope', payload['scope']);
    return buffer.toString();
  }

  static void _writeStringListSection(
    StringBuffer buffer,
    String title,
    List<String> values,
  ) {
    if (values.isEmpty) return;
    buffer
      ..writeln()
      ..writeln('## $title')
      ..writeln();
    for (final value in values) {
      buffer.writeln('- $value');
    }
  }

  static void _writeJsonSection(
    StringBuffer buffer,
    String title,
    Object? value,
  ) {
    final isEmptyMap = value is Map && value.isEmpty;
    final isEmptyList = value is Iterable && value.isEmpty;
    if (value == null || isEmptyMap || isEmptyList) return;
    buffer
      ..writeln()
      ..writeln('## $title')
      ..writeln()
      ..writeln('```json')
      ..writeln(const JsonEncoder.withIndent('  ').convert(value))
      ..writeln('```');
  }

  int _priorityRank(String priority) => switch (priority) {
    'urgent' => 4,
    'high' => 3,
    'normal' => 2,
    'low' => 1,
    _ => 0,
  };

  Map<String, Object?> _tagToJson(Tag tag) => {
    'id': tag.id,
    'name': tag.name,
    'color': tag.color,
  };

  Map<String, Object?> _personToJson(ProjectPerson person) => {
    'id': person.id,
    'name': person.name,
    'role': person.role,
    'authority': person.authority,
    'createdAt': person.createdAt.toIso8601String(),
  };

  Map<String, Object?> _riskToJson(ProjectRisk risk) => {
    'id': risk.id,
    'title': risk.title,
    'description': risk.desc,
    'severity': risk.severity,
    'createdAt': risk.createdAt.toIso8601String(),
  };

  Map<String, Object?> _decisionToJson(ProjectDecision decision) => {
    'id': decision.id,
    'title': decision.title,
    'context': decision.ctx,
    'decider': decision.decider,
    'createdAt': decision.createdAt.toIso8601String(),
  };

  Map<String, Object?> _workItemToJson(WorkItem item) => {
    'id': item.id,
    'title': item.title,
    'description': item.description,
    'owner': item.owner,
    'status': item.status,
    'priority': item.priority,
    'dueAt': item.dueAt?.toIso8601String(),
    'blockedReason': item.blockedReason,
    'source': item.source,
    'createdAt': item.createdAt.toIso8601String(),
    'updatedAt': item.updatedAt.toIso8601String(),
  };

  Map<String, Object?> _mediaToJson(ProjectMediaItem item) => {
    'id': item.id,
    'projectId': item.projectId,
    'title': item.title,
    'originalFilename': item.originalFilename,
    'mediaType': item.mediaType,
    'mimeType': item.mimeType,
    'extension': item.extension,
    'byteSize': item.byteSize,
    'caption': item.caption,
    'source': item.source,
    'storedPath': item.storedPath,
    'createdAt': item.createdAt.toIso8601String(),
    'updatedAt': item.updatedAt.toIso8601String(),
  };

  Map<String, Object?> _registryToJson(ProjectRegistryEntry registry) => {
    'id': registry.id,
    'atlasProjectId': registry.atlasProjectId,
    'displayName': registry.displayName,
    'localPath': registry.localPath,
    'gitRoot': registry.gitRoot,
    'classification': registry.classification,
    'reviewState': registry.reviewState,
    'notes': registry.notes,
    'createdAt': registry.createdAt.toIso8601String(),
    'updatedAt': registry.updatedAt.toIso8601String(),
    'lastReviewedAt': registry.lastReviewedAt?.toIso8601String(),
  };

  Map<String, Object?> _observationToJson(ProjectObservation observation) => {
    'id': observation.id,
    'registryId': observation.registryId,
    'scanRunId': observation.scanRunId,
    'observedPath': observation.observedPath,
    'classificationGuess': observation.classificationGuess,
    'confidence': observation.confidence,
    'branch': observation.branch,
    'headSha': observation.headSha,
    'dirtyCount': observation.dirtyCount,
    'remoteUrl': observation.remoteUrl,
    'markerFilesJson': observation.markerFilesJson,
    'warningsJson': observation.warningsJson,
    'rawJson': observation.rawJson,
    'observedAt': observation.observedAt.toIso8601String(),
  };

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  static List<String> _cleanList(Iterable<String> values) =>
      values.map(_clean).whereType<String>().toSet().toList()..sort();

  static String? _payloadString(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value == null) return null;
    return _clean('$value');
  }

  static List<String> _payloadStringList(
    Map<String, Object?> payload,
    String key,
  ) => _valueStringList(payload[key]);

  static List<String> _valueStringList(Object? value) {
    if (value is Iterable) {
      return value.map((item) => _clean('$item')).whereType<String>().toList();
    }
    final single = _clean(value?.toString());
    return single == null ? const [] : [single];
  }

  static DateTime? _payloadDate(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  Future<List<String>> _ensureTagIds(Iterable<String> tagNames) async {
    final ids = <String>[];
    for (final name in tagNames.map(_clean).whereType<String>()) {
      final existing = await state.db.findTagByName(name);
      ids.add(existing?.id ?? await state.saveTag(name: name));
    }
    return ids.toSet().toList();
  }
}
