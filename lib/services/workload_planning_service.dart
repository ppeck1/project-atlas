import '../db/app_db.dart';

const workloadReadinessValues = [
  'ready',
  'blocked',
  'needs_decision',
  'needs_context',
  'review_needed',
];

const workloadSizeValues = ['tiny', 'small', 'medium', 'large'];

const workloadRiskValues = [
  'docs_only',
  'low_code',
  'medium_code',
  'db_schema',
  'release',
  'external_facing',
];

const workloadActorValues = [
  'user',
  'codex',
  'claude',
  'local_llm',
  'manual_review',
];

const workloadVerificationValues = [
  'none',
  'tests',
  'smoke',
  'build',
  'manual_ui',
];

const workloadBoardGroups = [
  'ready',
  'needs_decision',
  'blocked',
  'in_progress',
  'review_needed',
  'done_closed',
];

String normalizeWorkloadReadiness(String? value, {String fallback = 'ready'}) =>
    _normalizeOption(value, workloadReadinessValues, fallback);

String normalizeWorkloadSize(String? value, {String fallback = 'medium'}) =>
    _normalizeOption(value, workloadSizeValues, fallback);

String normalizeWorkloadRisk(String? value, {String fallback = 'low_code'}) =>
    _normalizeOption(value, workloadRiskValues, fallback);

String normalizeWorkloadActor(String? value, {String fallback = 'user'}) =>
    _normalizeOption(value, workloadActorValues, fallback);

String normalizeWorkloadVerification(
  String? value, {
  String fallback = 'none',
}) => _normalizeOption(value, workloadVerificationValues, fallback);

String workloadLabel(String value) {
  final text = value.replaceAll('_', ' ');
  return text.isEmpty ? value : text[0].toUpperCase() + text.substring(1);
}

String? cleanWorkloadText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _normalizeOption(String? value, List<String> allowed, String fallback) {
  final raw = (value ?? '').trim().toLowerCase().replaceAll(' ', '_');
  return allowed.contains(raw) ? raw : fallback;
}

class WorkloadFilters {
  final String? projectId;
  final String? readiness;
  final String? actor;
  final String? risk;
  final String? size;
  final bool blockedOnly;
  final bool reviewNeededOnly;
  final bool staleOnly;
  final bool highPriorityOnly;

  const WorkloadFilters({
    this.projectId,
    this.readiness,
    this.actor,
    this.risk,
    this.size,
    this.blockedOnly = false,
    this.reviewNeededOnly = false,
    this.staleOnly = false,
    this.highPriorityOnly = false,
  });

  WorkloadFilters copyWith({
    String? projectId,
    bool clearProjectId = false,
    String? readiness,
    bool clearReadiness = false,
    String? actor,
    bool clearActor = false,
    String? risk,
    bool clearRisk = false,
    String? size,
    bool clearSize = false,
    bool? blockedOnly,
    bool? reviewNeededOnly,
    bool? staleOnly,
    bool? highPriorityOnly,
  }) {
    return WorkloadFilters(
      projectId: clearProjectId ? null : projectId ?? this.projectId,
      readiness: clearReadiness ? null : readiness ?? this.readiness,
      actor: clearActor ? null : actor ?? this.actor,
      risk: clearRisk ? null : risk ?? this.risk,
      size: clearSize ? null : size ?? this.size,
      blockedOnly: blockedOnly ?? this.blockedOnly,
      reviewNeededOnly: reviewNeededOnly ?? this.reviewNeededOnly,
      staleOnly: staleOnly ?? this.staleOnly,
      highPriorityOnly: highPriorityOnly ?? this.highPriorityOnly,
    );
  }

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'readiness': readiness,
    'actor': actor,
    'risk': risk,
    'size': size,
    'blockedOnly': blockedOnly,
    'reviewNeededOnly': reviewNeededOnly,
    'staleOnly': staleOnly,
    'highPriorityOnly': highPriorityOnly,
  };
}

class WorkloadItemRef {
  final String kind;
  final String id;

  const WorkloadItemRef({required this.kind, required this.id});

  factory WorkloadItemRef.fromCard(WorkloadCard card) =>
      WorkloadItemRef(kind: card.kind, id: card.id);

  Map<String, Object?> toJson() => {'kind': kind, 'id': id};
}

class WorkloadCard {
  static const workItemKind = 'work_item';
  static const llmQueueKind = 'llm_queue_item';

  final String kind;
  final String id;
  final String projectId;
  final String projectTitle;
  final String title;
  final String? owner;
  final String readiness;
  final String boardGroup;
  final String size;
  final String risk;
  final String suggestedActor;
  final String verificationNeeded;
  final String priority;
  final String status;
  final DateTime? dueAt;
  final String? workItemId;
  final String? llmTaskId;
  final List<String> linkedLlmTaskIds;
  final List<String> linkedLlmTaskStatuses;
  final String? nextAction;
  final String? blockerReason;
  final String? planningNotes;
  final DateTime? lastReviewedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String originKind;
  final bool showInMainWorkboard;

  const WorkloadCard({
    required this.kind,
    required this.id,
    required this.projectId,
    required this.projectTitle,
    required this.title,
    required this.owner,
    required this.readiness,
    required this.boardGroup,
    required this.size,
    required this.risk,
    required this.suggestedActor,
    required this.verificationNeeded,
    required this.priority,
    required this.status,
    required this.dueAt,
    required this.workItemId,
    required this.llmTaskId,
    required this.linkedLlmTaskIds,
    required this.linkedLlmTaskStatuses,
    required this.nextAction,
    required this.blockerReason,
    required this.planningNotes,
    required this.lastReviewedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.originKind,
    required this.showInMainWorkboard,
  });

  bool get isWorkItem => kind == workItemKind;
  bool get isLlmQueueItem => kind == llmQueueKind;
  bool get isBlocked => boardGroup == 'blocked';
  bool get isReviewNeeded => boardGroup == 'review_needed';
  bool get isHighPriority => priority == 'high' || priority == 'urgent';

  bool isStale(DateTime now) {
    final reviewedAt = lastReviewedAt;
    if (reviewedAt == null) return true;
    return reviewedAt.isBefore(now.subtract(const Duration(days: 14)));
  }

  List<String> staleReasons(DateTime now) {
    final reasons = <String>[];
    final reviewedAt = lastReviewedAt;
    if (reviewedAt == null) {
      reasons.add(
        originKind == 'imported_checklist'
            ? 'imported_template_unreviewed'
            : 'no_last_reviewed_at',
      );
    } else if (reviewedAt.isBefore(now.subtract(const Duration(days: 14)))) {
      reasons.add('old_last_reviewed_at');
    }
    if (originKind == 'placeholder') {
      reasons.add('placeholder_title');
    }
    return reasons;
  }

  int score(DateTime now) => WorkloadPlanner.scoreCard(this, now: now);

  Map<String, Object?> toJson({DateTime? now}) {
    final resolvedNow = now ?? DateTime.now();
    return {
      'kind': kind,
      'id': id,
      'projectId': projectId,
      'projectTitle': projectTitle,
      'title': title,
      'owner': owner,
      'readiness': readiness,
      'boardGroup': boardGroup,
      'size': size,
      'risk': risk,
      'suggestedActor': suggestedActor,
      'verificationNeeded': verificationNeeded,
      'priority': priority,
      'status': status,
      'dueAt': dueAt?.toIso8601String(),
      'workItemId': workItemId,
      'llmTaskId': llmTaskId,
      'linkedLlmTaskIds': linkedLlmTaskIds,
      'linkedLlmTaskStatuses': linkedLlmTaskStatuses,
      'llmQueueLinked': linkedLlmTaskIds.isNotEmpty || llmTaskId != null,
      'nextAction': nextAction,
      'blockerReason': blockerReason,
      'planningNotes': planningNotes,
      'lastReviewedAt': lastReviewedAt?.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'stale': isStale(resolvedNow),
      'staleReasons': staleReasons(resolvedNow),
      'originKind': originKind,
      'showInMainWorkboard': showInMainWorkboard,
      'score': score(resolvedNow),
    };
  }
}

class WorkloadSnapshot {
  final DateTime generatedAt;
  final WorkloadFilters filters;
  final List<WorkloadCard> cards;
  final List<WorkloadCard> suggestedNextItems;
  final List<WorkloadCard> planningCandidateItems;
  final List<WorkloadCard> reviewNeededItems;
  final Map<String, int> countsByGroup;
  final Map<String, int> tasksByActor;
  final Map<String, int> tasksByRisk;
  final Map<String, int> tasksByOrigin;
  final int staleTasks;
  final int demotedImportedChecklistTasks;

  const WorkloadSnapshot({
    required this.generatedAt,
    required this.filters,
    required this.cards,
    required this.suggestedNextItems,
    required this.planningCandidateItems,
    required this.reviewNeededItems,
    required this.countsByGroup,
    required this.tasksByActor,
    required this.tasksByRisk,
    required this.tasksByOrigin,
    required this.staleTasks,
    required this.demotedImportedChecklistTasks,
  });

  int get readyTasks => countsByGroup['ready'] ?? 0;
  int get blockedTasks => countsByGroup['blocked'] ?? 0;
  int get reviewNeededTasks => countsByGroup['review_needed'] ?? 0;

  Map<String, Object?> toJson() => {
    'schema': 'atlas.workload_snapshot.v1',
    'generatedAt': generatedAt.toIso8601String(),
    'filters': filters.toJson(),
    'counts': {
      'total': cards.length,
      'ready': readyTasks,
      'blocked': blockedTasks,
      'reviewNeeded': reviewNeededTasks,
      'stale': staleTasks,
      'byGroup': countsByGroup,
      'byActor': tasksByActor,
      'byRisk': tasksByRisk,
      'byOrigin': tasksByOrigin,
      'demotedImportedChecklist': demotedImportedChecklistTasks,
    },
    'suggestedNextItems': suggestedNextItems
        .map((card) => card.toJson(now: generatedAt))
        .toList(growable: false),
    'executionCandidates': suggestedNextItems
        .map((card) => card.toJson(now: generatedAt))
        .toList(growable: false),
    'planningCandidateItems': planningCandidateItems
        .map((card) => card.toJson(now: generatedAt))
        .toList(growable: false),
    'reviewNeededItems': reviewNeededItems
        .map((card) => card.toJson(now: generatedAt))
        .toList(growable: false),
    'cards': cards
        .map((card) => card.toJson(now: generatedAt))
        .toList(growable: false),
  };
}

class WorkloadPlanner {
  static List<WorkloadCard> buildCards({
    required List<Project> projects,
    required List<Stage> stages,
    required List<WorkItem> workItems,
    required List<LlmTaskQueueItem> llmTasks,
  }) {
    final projectsById = {for (final project in projects) project.id: project};
    final stagesById = {for (final stage in stages) stage.id: stage};
    final tasksByWorkItemId = <String, List<LlmTaskQueueItem>>{};
    for (final task in llmTasks) {
      final workItemId = cleanWorkloadText(task.workItemId);
      if (workItemId == null) continue;
      tasksByWorkItemId.putIfAbsent(workItemId, () => []).add(task);
    }

    final cards = <WorkloadCard>[];
    for (final item in workItems) {
      final stage = stagesById[item.stageId];
      final project = stage == null ? null : projectsById[stage.projectId];
      if (stage == null || project == null) continue;
      final linkedTasks = tasksByWorkItemId[item.id] ?? const [];
      final readiness = normalizeWorkloadReadiness(item.readiness);
      final blockerReason = cleanWorkloadText(item.blockedReason);
      final status = item.status.trim().isEmpty ? 'next' : item.status.trim();
      final originKind = _originKindForWorkItem(item);
      cards.add(
        WorkloadCard(
          kind: WorkloadCard.workItemKind,
          id: item.id,
          projectId: project.id,
          projectTitle: project.title,
          title: item.title,
          owner: cleanWorkloadText(item.owner),
          readiness: readiness,
          boardGroup: boardGroupFor(
            readiness: readiness,
            status: status,
            blockerReason: blockerReason,
          ),
          size: normalizeWorkloadSize(item.size),
          risk: normalizeWorkloadRisk(item.risk),
          suggestedActor: normalizeWorkloadActor(item.suggestedActor),
          verificationNeeded: normalizeWorkloadVerification(
            item.verificationNeeded,
          ),
          priority: item.priority.trim().isEmpty ? 'normal' : item.priority,
          status: status,
          dueAt: item.dueAt,
          workItemId: item.id,
          llmTaskId: null,
          linkedLlmTaskIds: linkedTasks
              .map((task) => task.id)
              .toList(growable: false),
          linkedLlmTaskStatuses: linkedTasks
              .map((task) => task.status)
              .toList(growable: false),
          nextAction: cleanWorkloadText(item.nextAction),
          blockerReason: blockerReason,
          planningNotes: cleanWorkloadText(item.planningNotes),
          lastReviewedAt: item.lastReviewedAt,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
          originKind: originKind,
          showInMainWorkboard: _showInMainWorkboard(originKind),
        ),
      );
    }

    for (final task in llmTasks) {
      final project = projectsById[task.projectId];
      if (project == null) continue;
      final readiness = normalizeWorkloadReadiness(task.readiness);
      final blockerReason = cleanWorkloadText(task.blockerReason);
      final originKind = _originKindForLlmTask(task);
      cards.add(
        WorkloadCard(
          kind: WorkloadCard.llmQueueKind,
          id: task.id,
          projectId: project.id,
          projectTitle: project.title,
          title: task.title,
          owner: null,
          readiness: readiness,
          boardGroup: boardGroupFor(
            readiness: readiness,
            status: task.status,
            blockerReason: blockerReason,
            isQueueItem: true,
          ),
          size: normalizeWorkloadSize(task.size),
          risk: normalizeWorkloadRisk(task.risk),
          suggestedActor: normalizeWorkloadActor(task.suggestedActor),
          verificationNeeded: normalizeWorkloadVerification(
            task.verificationNeeded,
          ),
          priority: task.priority.trim().isEmpty ? 'normal' : task.priority,
          status: task.status,
          dueAt: null,
          workItemId: cleanWorkloadText(task.workItemId),
          llmTaskId: task.id,
          linkedLlmTaskIds: const [],
          linkedLlmTaskStatuses: const [],
          nextAction: cleanWorkloadText(task.nextAction),
          blockerReason: blockerReason,
          planningNotes: cleanWorkloadText(task.planningNotes),
          lastReviewedAt: task.lastReviewedAt,
          createdAt: task.createdAt,
          updatedAt: task.updatedAt,
          originKind: originKind,
          showInMainWorkboard: _showInMainWorkboard(originKind),
        ),
      );
    }

    cards.sort((a, b) {
      final group = _groupRank(
        a.boardGroup,
      ).compareTo(_groupRank(b.boardGroup));
      if (group != 0) return group;
      final score = a.score(DateTime.now()).compareTo(b.score(DateTime.now()));
      if (score != 0) return score;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return cards;
  }

  static WorkloadSnapshot snapshot({
    required List<WorkloadCard> cards,
    WorkloadFilters filters = const WorkloadFilters(),
    DateTime? now,
    int suggestionLimit = 5,
  }) {
    final generatedAt = now ?? DateTime.now();
    final filtered = applyFilters(cards, filters, now: generatedAt);
    final countsByGroup = <String, int>{
      for (final group in workloadBoardGroups) group: 0,
    };
    final byActor = <String, int>{};
    final byRisk = <String, int>{};
    final byOrigin = <String, int>{};
    var stale = 0;
    for (final card in filtered) {
      countsByGroup[card.boardGroup] =
          (countsByGroup[card.boardGroup] ?? 0) + 1;
      byActor[card.suggestedActor] = (byActor[card.suggestedActor] ?? 0) + 1;
      byRisk[card.risk] = (byRisk[card.risk] ?? 0) + 1;
      byOrigin[card.originKind] = (byOrigin[card.originKind] ?? 0) + 1;
      if (card.isStale(generatedAt)) stale++;
    }
    final demoteImportedChecklist = filters.projectId == null;
    final executionCandidates =
        filtered
            .where(
              (card) => _isExecutionCandidate(
                card,
                demoteImportedChecklist: demoteImportedChecklist,
              ),
            )
            .toList(growable: false)
          ..sort((a, b) {
            final score = a.score(generatedAt).compareTo(b.score(generatedAt));
            if (score != 0) return score;
            return b.updatedAt.compareTo(a.updatedAt);
          });
    final planningCandidates =
        filtered.where(_isPlanningCandidate).toList(growable: false)
          ..sort((a, b) {
            final score = a.score(generatedAt).compareTo(b.score(generatedAt));
            if (score != 0) return score;
            return b.updatedAt.compareTo(a.updatedAt);
          });
    final reviewNeeded =
        filtered
            .where((card) => card.boardGroup == 'review_needed')
            .toList(growable: false)
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return WorkloadSnapshot(
      generatedAt: generatedAt,
      filters: filters,
      cards: List.unmodifiable(filtered),
      suggestedNextItems: List.unmodifiable(
        executionCandidates.take(suggestionLimit),
      ),
      planningCandidateItems: List.unmodifiable(
        planningCandidates.take(suggestionLimit),
      ),
      reviewNeededItems: List.unmodifiable(reviewNeeded.take(suggestionLimit)),
      countsByGroup: Map.unmodifiable(countsByGroup),
      tasksByActor: Map.unmodifiable(byActor),
      tasksByRisk: Map.unmodifiable(byRisk),
      tasksByOrigin: Map.unmodifiable(byOrigin),
      staleTasks: stale,
      demotedImportedChecklistTasks: demoteImportedChecklist
          ? filtered
                .where(
                  (card) =>
                      card.originKind == 'imported_checklist' &&
                      card.boardGroup == 'ready',
                )
                .length
          : 0,
    );
  }

  static List<WorkloadCard> applyFilters(
    List<WorkloadCard> cards,
    WorkloadFilters filters, {
    DateTime? now,
  }) {
    final generatedAt = now ?? DateTime.now();
    return cards
        .where((card) {
          if (filters.projectId != null &&
              card.projectId != filters.projectId) {
            return false;
          }
          if (filters.readiness != null) {
            final readiness = normalizeWorkloadReadiness(filters.readiness);
            if (card.readiness != readiness && card.boardGroup != readiness) {
              return false;
            }
          }
          if (filters.actor != null &&
              card.suggestedActor != normalizeWorkloadActor(filters.actor)) {
            return false;
          }
          if (filters.risk != null &&
              card.risk != normalizeWorkloadRisk(filters.risk)) {
            return false;
          }
          if (filters.size != null &&
              card.size != normalizeWorkloadSize(filters.size)) {
            return false;
          }
          if (filters.blockedOnly && !card.isBlocked) return false;
          if (filters.reviewNeededOnly && !card.isReviewNeeded) return false;
          if (filters.staleOnly && !card.isStale(generatedAt)) return false;
          if (filters.highPriorityOnly && !card.isHighPriority) return false;
          return true;
        })
        .toList(growable: false);
  }

  static String boardGroupFor({
    required String readiness,
    required String status,
    String? blockerReason,
    bool isQueueItem = false,
  }) {
    final cleanStatus = status.trim().toLowerCase();
    if (cleanStatus == 'done' ||
        cleanStatus == 'archived' ||
        cleanStatus == 'completed' ||
        cleanStatus == 'cancelled') {
      return 'done_closed';
    }
    if (cleanStatus == 'doing' || cleanStatus == 'leased') {
      return 'in_progress';
    }
    if (readiness == 'review_needed' || cleanStatus == 'failed') {
      return 'review_needed';
    }
    if (readiness == 'blocked' ||
        cleanStatus == 'waiting' ||
        cleanWorkloadText(blockerReason) != null) {
      return 'blocked';
    }
    if (readiness == 'needs_decision' || readiness == 'needs_context') {
      return 'needs_decision';
    }
    return 'ready';
  }

  static int scoreCard(WorkloadCard card, {DateTime? now}) {
    final generatedAt = now ?? DateTime.now();
    var score = switch (card.boardGroup) {
      'ready' => 0,
      'needs_decision' => card.readiness == 'needs_context' ? 12 : 20,
      'blocked' => 80,
      _ => 200,
    };
    score += switch (card.priority) {
      'urgent' => 0,
      'high' => 4,
      'normal' => 8,
      'low' => 12,
      _ => 10,
    };
    score += switch (card.size) {
      'tiny' => 0,
      'small' => 2,
      'medium' => 5,
      'large' => 10,
      _ => 6,
    };
    score += switch (card.risk) {
      'docs_only' => 0,
      'low_code' => 2,
      'medium_code' => 5,
      'db_schema' => 8,
      'release' => 9,
      'external_facing' => 10,
      _ => 6,
    };
    final dueAt = card.dueAt;
    if (dueAt != null) {
      final today = DateTime(
        generatedAt.year,
        generatedAt.month,
        generatedAt.day,
      );
      if (dueAt.isBefore(today)) {
        score -= 8;
      } else if (dueAt.isBefore(today.add(const Duration(days: 1)))) {
        score -= 4;
      }
    }
    if (card.isStale(generatedAt)) score -= 3;
    return score;
  }

  static bool _isExecutionCandidate(
    WorkloadCard card, {
    bool demoteImportedChecklist = false,
  }) =>
      card.boardGroup == 'ready' &&
      (!demoteImportedChecklist || card.originKind != 'imported_checklist');

  static bool _isPlanningCandidate(WorkloadCard card) =>
      card.boardGroup == 'needs_decision' &&
      (card.readiness == 'needs_decision' || card.readiness == 'needs_context');

  static int _groupRank(String group) => switch (group) {
    'ready' => 0,
    'needs_decision' => 1,
    'blocked' => 2,
    'in_progress' => 3,
    'review_needed' => 4,
    'done_closed' => 5,
    _ => 6,
  };

  static String _originKindForWorkItem(WorkItem item) {
    final source = cleanWorkloadText(item.source)?.toLowerCase() ?? '';
    if (_looksLikeImportedChecklist(item.title, source)) {
      return 'imported_checklist';
    }
    if (_looksLikePlaceholderTitle(item.title)) return 'placeholder';
    if (source.contains('atlas agent proposal')) return 'agent_proposal';
    if (source.contains('local_refresh')) return 'local_refresh';
    return item.source == null ? 'manual' : 'imported_work_item';
  }

  static String _originKindForLlmTask(LlmTaskQueueItem task) {
    final contextSource = cleanWorkloadText(
      task.context['source']?.toString(),
    )?.toLowerCase();
    final createdBy = task.createdBy.trim().toLowerCase();
    if (_looksLikeImportedChecklist(task.title, contextSource ?? createdBy)) {
      return 'imported_checklist';
    }
    if (_looksLikePlaceholderTitle(task.title)) return 'placeholder';
    if (contextSource == 'workboard_bulk_action' ||
        createdBy == 'ui_planning') {
      return 'workboard_generated';
    }
    if (contextSource == 'project_detail_header' || createdBy == 'ui') {
      return 'manual';
    }
    if (createdBy == 'codex' || contextSource == 'codex') {
      return 'agent_generated';
    }
    return 'llm_queue';
  }

  static bool _showInMainWorkboard(String originKind) =>
      originKind != 'imported_checklist';

  static bool _looksLikeImportedChecklist(String title, String source) {
    final normalizedTitle = title.trim().toLowerCase();
    return source.contains('dev launchpad') ||
        source.contains('launchpad') ||
        normalizedTitle.contains('dev launchpad') ||
        normalizedTitle == 'launch project' ||
        normalizedTitle == 'launch the project from dev launchpad.' ||
        normalizedTitle == 'run health checks' ||
        normalizedTitle.startsWith('run health checks ') ||
        normalizedTitle == 'run manifest test command' ||
        normalizedTitle.startsWith('run the manifest test command') ||
        normalizedTitle == 'run manifest build command' ||
        normalizedTitle.startsWith('run the manifest build command') ||
        normalizedTitle == 'let dev launchpad update metadata' ||
        normalizedTitle.startsWith('let dev launchpad update ');
  }

  static bool _looksLikePlaceholderTitle(String title) {
    final normalized = title.trim().toLowerCase();
    return normalized == 'test review' ||
        normalized == 'test' ||
        RegExp(r'^test\d*$').hasMatch(normalized);
  }
}
