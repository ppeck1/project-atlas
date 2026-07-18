import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'atlas_agent_service.dart';
import 'workload_planning_service.dart';

enum ProjectCapsuleView { act, understand, audit, full }

extension ProjectCapsuleViewWireName on ProjectCapsuleView {
  String get wireName => name;
}

class ProjectCapsuleSourceData {
  final AtlasProjectBootstrapContext bootstrap;
  final WorkloadSnapshot workload;

  const ProjectCapsuleSourceData({
    required this.bootstrap,
    required this.workload,
  });
}

abstract interface class ProjectCapsuleSource {
  Future<ProjectCapsuleSourceData?> load(String projectId);
}

class AtlasAgentProjectCapsuleSource implements ProjectCapsuleSource {
  final AtlasAgentService agentService;

  const AtlasAgentProjectCapsuleSource(this.agentService);

  @override
  Future<ProjectCapsuleSourceData?> load(String projectId) async {
    final bootstrap = await agentService.getProjectBootstrapContext(projectId);
    if (bootstrap == null) return null;
    final workload = await agentService.projectWorkload(
      projectId,
      suggestionLimit: 5,
    );
    return ProjectCapsuleSourceData(bootstrap: bootstrap, workload: workload);
  }
}

class ProjectCapsuleAction {
  final String id;
  final String kind;
  final String title;
  final String lane;
  final String owner;
  final String suggestedActor;
  final String readiness;
  final String status;
  final String priority;
  final String risk;
  final String verificationNeeded;
  final String whyHere;
  final String transition;
  final String? blockerReason;

  const ProjectCapsuleAction({
    required this.id,
    required this.kind,
    required this.title,
    required this.lane,
    required this.owner,
    required this.suggestedActor,
    required this.readiness,
    required this.status,
    required this.priority,
    required this.risk,
    required this.verificationNeeded,
    required this.whyHere,
    required this.transition,
    required this.blockerReason,
  });

  factory ProjectCapsuleAction.fromCard(WorkloadCard card) {
    final lane = switch (card.boardGroup) {
      'ready' =>
        card.suggestedActor == 'user' ? 'ready_for_human' : 'ready_for_agent',
      'needs_decision' => 'human_must_decide',
      'in_progress' => card.isLlmQueueItem ? 'agent_working' : 'in_progress',
      'review_needed' => 'ready_for_acceptance',
      'blocked' => 'waiting_on_evidence',
      _ => card.boardGroup,
    };
    final whyHere = switch (card.boardGroup) {
      'ready' =>
        'Atlas ranked this as ready work for ${workloadLabel(card.suggestedActor)}.',
      'needs_decision' =>
        card.readiness == 'needs_context'
            ? 'Shared context is incomplete, so work should not start yet.'
            : 'A human decision is required before this work can become ready.',
      'in_progress' => 'The item is already being worked.',
      'review_needed' =>
        'Work exists, but review or verification is required before acceptance.',
      'blocked' =>
        card.blockerReason == null
            ? 'The item is blocked or waiting.'
            : 'The item is waiting on: ${card.blockerReason}',
      _ => 'Atlas grouped this item as ${workloadLabel(card.boardGroup)}.',
    };
    final transition =
        _clean(card.nextAction) ??
        switch (card.boardGroup) {
          'ready' =>
            card.verificationNeeded == 'none'
                ? 'Start the work, then record the result.'
                : 'Start the work, then attach ${workloadLabel(card.verificationNeeded)} verification.',
          'needs_decision' =>
            'Record the missing decision or context, then mark the item ready.',
          'in_progress' =>
            'Complete the work and submit its result for the required review.',
          'review_needed' =>
            'Review the result and accept, reject, or request revision.',
          'blocked' =>
            card.blockerReason == null
                ? 'Record and resolve the blocker before resuming.'
                : 'Resolve the stated blocker, then reassess readiness.',
          _ => 'Review the item and record its next valid transition.',
        };
    return ProjectCapsuleAction(
      id: card.id,
      kind: card.kind,
      title: card.title,
      lane: lane,
      owner: _clean(card.owner) ?? 'unassigned',
      suggestedActor: card.suggestedActor,
      readiness: card.readiness,
      status: card.status,
      priority: card.priority,
      risk: card.risk,
      verificationNeeded: card.verificationNeeded,
      whyHere: whyHere,
      transition: transition,
      blockerReason: card.blockerReason,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'lane': lane,
    'owner': owner,
    'suggestedActor': suggestedActor,
    'readiness': readiness,
    'status': status,
    'priority': priority,
    'risk': risk,
    'verificationNeeded': verificationNeeded,
    'whyHere': whyHere,
    'transition': transition,
    'blockerReason': blockerReason,
  };
}

class ProjectCapsuleRecommendation {
  final String action;
  final String rationale;
  final String owner;
  final String transition;

  const ProjectCapsuleRecommendation({
    required this.action,
    required this.rationale,
    required this.owner,
    required this.transition,
  });

  Map<String, Object?> toJson() => {
    'action': action,
    'rationale': rationale,
    'owner': owner,
    'transition': transition,
  };
}

class ProjectCapsuleSnapshot {
  static const schemaName = 'atlas.project_capsule_snapshot.v1';

  final String schema;
  final DateTime generatedAt;
  final String revisionId;
  final String contentHash;
  final Map<String, Object?> project;
  final Map<String, Object?> intent;
  final Map<String, Object?> acceptedState;
  final Map<String, Object?> scope;
  final Map<String, Object?> safeConstraints;
  final Map<String, Object?> verification;
  final Map<String, Object?> audit;
  final ProjectCapsuleRecommendation recommendation;
  final List<ProjectCapsuleAction> readyItems;
  final List<ProjectCapsuleAction> decisionItems;
  final List<ProjectCapsuleAction> inProgressItems;
  final List<ProjectCapsuleAction> reviewItems;
  final List<ProjectCapsuleAction> blockedItems;
  final List<Map<String, Object?>> decisions;
  final List<Map<String, Object?>> risks;
  final List<String> gaps;
  final List<String> warnings;
  final List<String> errors;
  final int pendingAgentProposals;
  final int pendingLlmTasks;
  final String confidence;

  const ProjectCapsuleSnapshot._({
    required this.schema,
    required this.generatedAt,
    required this.revisionId,
    required this.contentHash,
    required this.project,
    required this.intent,
    required this.acceptedState,
    required this.scope,
    required this.safeConstraints,
    required this.verification,
    required this.audit,
    required this.recommendation,
    required this.readyItems,
    required this.decisionItems,
    required this.inProgressItems,
    required this.reviewItems,
    required this.blockedItems,
    required this.decisions,
    required this.risks,
    required this.gaps,
    required this.warnings,
    required this.errors,
    required this.pendingAgentProposals,
    required this.pendingLlmTasks,
    required this.confidence,
  });

  factory ProjectCapsuleSnapshot.derived({
    required DateTime generatedAt,
    required Map<String, Object?> project,
    required Map<String, Object?> intent,
    required Map<String, Object?> acceptedState,
    required Map<String, Object?> scope,
    required Map<String, Object?> safeConstraints,
    required Map<String, Object?> verification,
    required Map<String, Object?> audit,
    required ProjectCapsuleRecommendation recommendation,
    required List<ProjectCapsuleAction> readyItems,
    required List<ProjectCapsuleAction> decisionItems,
    required List<ProjectCapsuleAction> inProgressItems,
    required List<ProjectCapsuleAction> reviewItems,
    required List<ProjectCapsuleAction> blockedItems,
    required List<Map<String, Object?>> decisions,
    required List<Map<String, Object?>> risks,
    required List<String> gaps,
    required List<String> warnings,
    required List<String> errors,
    required int pendingAgentProposals,
    required int pendingLlmTasks,
    required String confidence,
  }) {
    final frozenProject = _deepFreezeMap(project);
    final frozenIntent = _deepFreezeMap(intent);
    final frozenAcceptedState = _deepFreezeMap(acceptedState);
    final frozenScope = _deepFreezeMap(scope);
    final frozenSafeConstraints = _deepFreezeMap(safeConstraints);
    final frozenVerification = _deepFreezeMap(verification);
    final frozenAudit = _deepFreezeMap(audit);
    final frozenReadyItems = List<ProjectCapsuleAction>.unmodifiable(
      readyItems,
    );
    final frozenDecisionItems = List<ProjectCapsuleAction>.unmodifiable(
      decisionItems,
    );
    final frozenInProgressItems = List<ProjectCapsuleAction>.unmodifiable(
      inProgressItems,
    );
    final frozenReviewItems = List<ProjectCapsuleAction>.unmodifiable(
      reviewItems,
    );
    final frozenBlockedItems = List<ProjectCapsuleAction>.unmodifiable(
      blockedItems,
    );
    final frozenDecisions = List<Map<String, Object?>>.unmodifiable(
      decisions.map(_deepFreezeMap),
    );
    final frozenRisks = List<Map<String, Object?>>.unmodifiable(
      risks.map(_deepFreezeMap),
    );
    final frozenGaps = List<String>.unmodifiable(gaps);
    final frozenWarnings = List<String>.unmodifiable(warnings);
    final frozenErrors = List<String>.unmodifiable(errors);
    final content = <String, Object?>{
      'schema': schemaName,
      'project': frozenProject,
      'intent': frozenIntent,
      'acceptedState': frozenAcceptedState,
      'scope': frozenScope,
      'safeConstraints': frozenSafeConstraints,
      'verification': frozenVerification,
      'audit': frozenAudit,
      'recommendation': recommendation.toJson(),
      'readyItems': frozenReadyItems.map((item) => item.toJson()).toList(),
      'decisionItems': frozenDecisionItems
          .map((item) => item.toJson())
          .toList(),
      'inProgressItems': frozenInProgressItems
          .map((item) => item.toJson())
          .toList(),
      'reviewItems': frozenReviewItems.map((item) => item.toJson()).toList(),
      'blockedItems': frozenBlockedItems.map((item) => item.toJson()).toList(),
      'decisions': frozenDecisions,
      'risks': frozenRisks,
      'gaps': frozenGaps,
      'warnings': frozenWarnings,
      'errors': frozenErrors,
      'pendingAgentProposals': pendingAgentProposals,
      'pendingLlmTasks': pendingLlmTasks,
      'confidence': confidence,
    };
    final contentHash = sha256
        .convert(utf8.encode(jsonEncode(_canonicalJsonValue(content))))
        .toString();
    return ProjectCapsuleSnapshot._(
      schema: schemaName,
      generatedAt: generatedAt,
      revisionId: 'derived-${contentHash.substring(0, 12)}',
      contentHash: contentHash,
      project: frozenProject,
      intent: frozenIntent,
      acceptedState: frozenAcceptedState,
      scope: frozenScope,
      safeConstraints: frozenSafeConstraints,
      verification: frozenVerification,
      audit: frozenAudit,
      recommendation: recommendation,
      readyItems: frozenReadyItems,
      decisionItems: frozenDecisionItems,
      inProgressItems: frozenInProgressItems,
      reviewItems: frozenReviewItems,
      blockedItems: frozenBlockedItems,
      decisions: frozenDecisions,
      risks: frozenRisks,
      gaps: frozenGaps,
      warnings: frozenWarnings,
      errors: frozenErrors,
      pendingAgentProposals: pendingAgentProposals,
      pendingLlmTasks: pendingLlmTasks,
      confidence: confidence,
    );
  }

  Map<String, Object?> toJson({
    ProjectCapsuleView view = ProjectCapsuleView.full,
  }) {
    const acceptanceBoundary = <String, Object?>{
      'agentOutputIsProposal': true,
      'humanAcceptanceRequired': true,
    };
    final common = <String, Object?>{
      'schema': schema,
      'view': view.wireName,
      'generatedAt': generatedAt.toIso8601String(),
      'revisionId': revisionId,
      'contentHash': contentHash,
      'project': project,
      'confidence': confidence,
    };
    final act = <String, Object?>{
      'recommendation': recommendation.toJson(),
      'readyItems': readyItems.map((item) => item.toJson()).toList(),
      'decisionItems': decisionItems.map((item) => item.toJson()).toList(),
      'inProgressItems': inProgressItems.map((item) => item.toJson()).toList(),
      'reviewItems': reviewItems.map((item) => item.toJson()).toList(),
      'blockedItems': blockedItems.map((item) => item.toJson()).toList(),
      'gaps': gaps,
      'warnings': warnings,
      'errors': errors,
      'pendingAgentProposals': pendingAgentProposals,
      'pendingLlmTasks': pendingLlmTasks,
      'acceptanceBoundary': acceptanceBoundary,
    };
    final understand = <String, Object?>{
      'intent': intent,
      'acceptedState': acceptedState,
      'scope': scope,
      'safeConstraints': safeConstraints,
      'decisions': decisions,
      'risks': risks,
      'gaps': gaps,
      'acceptanceBoundary': acceptanceBoundary,
    };
    final auditView = <String, Object?>{
      'audit': audit,
      'verification': verification,
      'warnings': warnings,
      'errors': errors,
      'gaps': gaps,
      'acceptanceBoundary': acceptanceBoundary,
    };
    return switch (view) {
      ProjectCapsuleView.act => {...common, ...act},
      ProjectCapsuleView.understand => {...common, ...understand},
      ProjectCapsuleView.audit => {...common, ...auditView},
      ProjectCapsuleView.full => {
        ...common,
        ...act,
        ...understand,
        ...auditView,
      },
    };
  }
}

class ProjectCapsuleService {
  final ProjectCapsuleSource source;
  final DateTime Function() _now;

  ProjectCapsuleService(this.source, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  Future<ProjectCapsuleSnapshot?> buildSnapshot(String projectId) async {
    final sourceData = await source.load(projectId);
    if (sourceData == null) return null;
    final bootstrap = sourceData.bootstrap;
    final workload = sourceData.workload;
    final generatedAt = _now();
    final brief = bootstrap.brief;
    final status = brief.status;
    final capsule = bootstrap.capsule;
    final freshness = bootstrap.freshness;

    List<ProjectCapsuleAction> actionsFor(String boardGroup) => workload.cards
        .where((card) => card.boardGroup == boardGroup)
        .take(5)
        .map(ProjectCapsuleAction.fromCard)
        .toList(growable: false);

    final readyItems = workload.suggestedNextItems
        .map(ProjectCapsuleAction.fromCard)
        .toList(growable: false);
    final decisionItems = actionsFor('needs_decision');
    final inProgressItems = actionsFor('in_progress');
    final reviewItems = workload.reviewNeededItems
        .map(ProjectCapsuleAction.fromCard)
        .toList(growable: false);
    final blockedItems = workload.cards
        .where((card) => card.blocksProgress)
        .take(5)
        .map(ProjectCapsuleAction.fromCard)
        .toList(growable: false);

    final gaps = _safeDiagnostics([
      if (_clean(brief.desiredOutcome) == null)
        'Desired outcome is not defined.',
      if (_clean(brief.successCriteria) == null)
        'Success criteria are not defined.',
      ...bootstrap.gaps.where(
        (gap) => !gap.startsWith('No pending LLM task is queued'),
      ),
    ]);
    final warnings = _safeDiagnostics(capsule.warnings);
    final errors = _safeDiagnostics(capsule.errors);
    final validation = _objectMap(capsule.projectManifest?['validation']);
    final timestamps = Map<String, Object?>.from(freshness.timestamps)
      ..remove('generatedAt');

    final project = <String, Object?>{
      'projectId': status.id,
      'title': status.title,
      'status': status.status,
      'category': status.category,
      'owner': status.owner,
      'phase': status.phase,
      'priority': status.priority,
      'needsAttention': status.needsAttention,
    };
    final intent = <String, Object?>{
      'description': brief.description,
      'desiredOutcome': brief.desiredOutcome,
      'successCriteria': brief.successCriteria,
    };
    final currentActive = inProgressItems.isEmpty
        ? null
        : inProgressItems.first.title;
    final acceptedState = <String, Object?>{
      'status': status.status,
      'phase': status.phase,
      'outcomeSummary': brief.outcomeSummary,
      'currentActiveTask': currentActive,
      'latestAcceptedCheckpoint': _firstClean([
        capsule.projectManifest?['accepted_version'],
        capsule.projectManifest?['version'],
        capsule.projectManifest?['schema_version'],
      ]),
      'freshnessStatus': freshness.status,
    };
    final scope = <String, Object?>{
      'included': brief.scopeIncluded,
      'excluded': brief.scopeExcluded,
    };
    final verification = AtlasAgentService.planningVerification(
      validation,
      workload,
    );
    final audit = <String, Object?>{
      'freshness': {
        'status': freshness.status,
        'confidence': freshness.confidence,
        'staleReasons': freshness.staleReasons,
        'attentionReasons': freshness.attentionReasons,
        'actionRequiredBeforePlanning': freshness.actionRequiredBeforePlanning,
        'timestamps': timestamps,
      },
      'sources': {
        'hasLocalRegistry': status.hasLocalRegistry,
        'lastLocalObservationAt': status.lastLocalObservationAt
            ?.toIso8601String(),
        'localObservationAvailable': brief.latestLocalObservation != null,
        'githubRemoteAvailable': brief.githubRemote != null,
      },
      'protocolMetadata': {
        'evidenceAvailability': capsule.evidenceAvailability,
        'hasMetadata': capsule.hasMetadata,
        'profiles': bootstrap.identity.capsuleProfiles,
        'counts': capsule.counts,
      },
    };

    return ProjectCapsuleSnapshot.derived(
      generatedAt: generatedAt,
      project: project,
      intent: intent,
      acceptedState: acceptedState,
      scope: scope,
      safeConstraints: AtlasAgentService.safePlanningConstraints(),
      verification: verification,
      audit: audit,
      recommendation: _recommend(
        bootstrap: bootstrap,
        readyItems: readyItems,
        decisionItems: decisionItems,
        inProgressItems: inProgressItems,
        reviewItems: reviewItems,
        blockedItems: blockedItems,
      ),
      readyItems: readyItems,
      decisionItems: decisionItems,
      inProgressItems: inProgressItems,
      reviewItems: reviewItems,
      blockedItems: blockedItems,
      decisions: brief.decisions.take(5).toList(growable: false),
      risks: brief.risks.take(5).toList(growable: false),
      gaps: gaps,
      warnings: warnings,
      errors: errors,
      pendingAgentProposals: bootstrap.pendingAgentProposals.length,
      pendingLlmTasks: bootstrap.pendingLlmTasks.length,
      confidence: bootstrap.confidence,
    );
  }

  ProjectCapsuleRecommendation _recommend({
    required AtlasProjectBootstrapContext bootstrap,
    required List<ProjectCapsuleAction> readyItems,
    required List<ProjectCapsuleAction> decisionItems,
    required List<ProjectCapsuleAction> inProgressItems,
    required List<ProjectCapsuleAction> reviewItems,
    required List<ProjectCapsuleAction> blockedItems,
  }) {
    if (bootstrap.capsule.errors.isNotEmpty) {
      return const ProjectCapsuleRecommendation(
        action: 'Resolve protocol evidence errors before selecting work.',
        rationale:
            'Project identity or protocol evidence failed validation, so execution is not yet justified.',
        owner: 'human',
        transition:
            'Open Sources & Health, resolve the errors, then refresh Capsule.',
      );
    }
    final freshnessAction = _clean(
      bootstrap.freshness.actionRequiredBeforePlanning,
    );
    if (_requiresFreshnessAction(freshnessAction)) {
      return ProjectCapsuleRecommendation(
        action: freshnessAction!,
        rationale:
            'Project evidence is ${bootstrap.freshness.status}; reconcile it before committing to work.',
        owner: 'human',
        transition: 'Complete the freshness preflight, then refresh Capsule.',
      );
    }
    if (bootstrap.pendingAgentProposals.isNotEmpty) {
      final title = _clean(bootstrap.pendingAgentProposals.first['title']);
      return ProjectCapsuleRecommendation(
        action: title == null
            ? 'Review pending agent proposal.'
            : 'Review $title.',
        rationale: 'Agent output is waiting at the human acceptance boundary.',
        owner: 'human',
        transition: 'Accept, reject, or request revision with evidence.',
      );
    }
    if (reviewItems.isNotEmpty) {
      final item = reviewItems.first;
      return ProjectCapsuleRecommendation(
        action: item.title.toLowerCase().startsWith('review ')
            ? '${item.title}.'
            : 'Review ${item.title}.',
        rationale: item.whyHere,
        owner: 'human',
        transition: item.transition,
      );
    }
    if (decisionItems.isNotEmpty) {
      final item = decisionItems.first;
      return ProjectCapsuleRecommendation(
        action: 'Decide what unblocks ${item.title}.',
        rationale: item.whyHere,
        owner: 'human',
        transition: item.transition,
      );
    }
    if (readyItems.isNotEmpty) {
      final item = readyItems.first;
      return ProjectCapsuleRecommendation(
        action: item.transition,
        rationale: item.whyHere,
        owner: item.owner,
        transition: item.transition,
      );
    }
    if (blockedItems.isNotEmpty) {
      final item = blockedItems.first;
      return ProjectCapsuleRecommendation(
        action: 'Resolve the blocker for ${item.title}.',
        rationale: item.whyHere,
        owner: 'human',
        transition: item.transition,
      );
    }
    if (inProgressItems.isNotEmpty) {
      final item = inProgressItems.first;
      return ProjectCapsuleRecommendation(
        action: 'Monitor ${item.title}.',
        rationale: item.whyHere,
        owner: item.owner,
        transition: item.transition,
      );
    }
    return ProjectCapsuleRecommendation(
      action: bootstrap.recommendedNextAction,
      rationale: 'No execution-ready or review-ready work is recorded.',
      owner: 'human',
      transition:
          'Record a bounded next action with an owner and verification.',
    );
  }
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry('$key', item));
}

Map<String, Object?> _deepFreezeMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key: _deepFreezeValue(entry.value),
    });

Object? _deepFreezeValue(Object? value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        '${entry.key}': _deepFreezeValue(entry.value),
    });
  }
  if (value is Iterable) {
    return List<Object?>.unmodifiable(value.map(_deepFreezeValue));
  }
  return value;
}

Object? _canonicalJsonValue(Object? value) {
  if (value is Map) {
    final entries =
        value.entries
            .map(
              (entry) =>
                  MapEntry('${entry.key}', _canonicalJsonValue(entry.value)),
            )
            .toList()
          ..sort((left, right) => left.key.compareTo(right.key));
    return <String, Object?>{
      for (final entry in entries) entry.key: entry.value,
    };
  }
  if (value is Set) {
    final items = value.map(_canonicalJsonValue).toList()
      ..sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right)));
    return items;
  }
  if (value is Iterable) return value.map(_canonicalJsonValue).toList();
  if (value is DateTime) return value.toUtc().toIso8601String();
  return value;
}

bool _requiresFreshnessAction(String? value) {
  if (value == null) return false;
  return !value.toLowerCase().startsWith(
    'no freshness preflight action is required',
  );
}

List<String> _safeDiagnostics(Iterable<String> values) =>
    _uniqueStrings(values.map(_sanitizeDiagnostic));

String _sanitizeDiagnostic(String value) => value
    .replaceAll(
      RegExp(r'file:///[^\r\n]*', caseSensitive: false),
      '[local path]',
    )
    .replaceAll(RegExp(r'[A-Za-z]:[\\/][^\r\n]*'), '[local path]')
    .replaceAll(RegExp(r'\\\\[^\\\r\n]+\\[^\r\n]*'), '[local path]')
    .replaceAll(RegExp(r'/(?:Users|home|tmp|var/tmp)/[^\r\n]*'), '[local path]')
    .trim();

String? _clean(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String? _firstClean(Iterable<Object?> values) {
  for (final value in values) {
    final cleaned = _clean(value);
    if (cleaned != null) return cleaned;
  }
  return null;
}

List<String> _uniqueStrings(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final cleaned = value.trim();
    if (cleaned.isEmpty || !seen.add(cleaned)) continue;
    result.add(cleaned);
  }
  return result;
}
