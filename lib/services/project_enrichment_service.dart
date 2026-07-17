import 'dart:convert';

import '../db/app_db.dart';

typedef ProjectEnrichmentStatusCallback =
    void Function(String status, {int? current, int? total});

/// A finding produced while auditing project completeness, before it is
/// persisted as a [ProjectEnrichmentFinding] row.
class ProjectEnrichmentFindingDraft {
  final String? projectId;
  final String? registryId;
  final String severity;
  final String category;
  final String title;
  final String? detail;
  final Map<String, Object?> evidence;

  const ProjectEnrichmentFindingDraft({
    this.projectId,
    this.registryId,
    required this.severity,
    required this.category,
    required this.title,
    this.detail,
    this.evidence = const {},
  });
}

/// Result of the verification agent's completeness audit.
class ProjectEnrichmentAudit {
  final List<ProjectEnrichmentFindingDraft> findings;
  final Map<String, Object?> coverage;

  const ProjectEnrichmentAudit({
    required this.findings,
    required this.coverage,
  });
}

/// Result of the identity agent's deterministic metadata refresh.
class ProjectIdentityEnrichmentResult {
  final int considered;
  final int updated;
  final int unchanged;
  final int skipped;
  final List<String> warnings;

  const ProjectIdentityEnrichmentResult({
    required this.considered,
    required this.updated,
    required this.unchanged,
    required this.skipped,
    required this.warnings,
  });
}

/// Owns the DB-backed mechanics of a project enrichment run: step records,
/// proposal drafting, and finding-to-proposal mapping.
///
/// UI-facing run state (running flag, status text, progress and the
/// notifyListeners calls) intentionally stays on AppState.
class ProjectEnrichmentService {
  static const int proposalCap = 120;

  final AppDb db;

  const ProjectEnrichmentService(this.db);

  Future<String> startStep(
    String runId, {
    required String worker,
    required String title,
  }) {
    return db.startProjectEnrichmentStep(
      runId: runId,
      worker: worker,
      title: title,
      startedAt: DateTime.now(),
    );
  }

  Future<void> finishStep(
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

  Future<void> addProposal({
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

  Future<int> createCorrectionProposalsForFindings(
    String runId,
    List<ProjectEnrichmentFindingDraft> findings,
  ) async {
    var created = 0;
    for (final finding in findings) {
      if (created >= proposalCap) break;
      await addProposal(
        runId: runId,
        projectId: finding.projectId,
        registryId: finding.registryId,
        worker: 'correction',
        proposalType: proposalTypeForFinding(finding),
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
          'recommendedAction': recommendedActionForFinding(finding),
          'writeBoundary': 'atlas_only',
          'sourceReposMutated': false,
        },
        confidence: proposalConfidenceForFinding(finding),
      );
      created++;
    }
    return created;
  }

  static String proposalTypeForFinding(ProjectEnrichmentFindingDraft finding) {
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

  static String recommendedActionForFinding(
    ProjectEnrichmentFindingDraft finding,
  ) {
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

  static int proposalConfidenceForFinding(
    ProjectEnrichmentFindingDraft finding,
  ) {
    return switch (finding.severity) {
      'error' => 85,
      'warning' => 75,
      _ => 60,
    };
  }
}
