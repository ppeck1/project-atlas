import 'dart:convert';

import '../services/atlas_agent_service.dart';
import '../services/local_git_visibility_service.dart';
import '../services/local_project_refresh_service.dart';
import '../services/workload_planning_service.dart';

class AtlasMcpTool {
  final String name;
  final String description;
  final Map<String, Object?> inputSchema;

  const AtlasMcpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
  };
}

class AtlasMcpCallResult {
  final Object? data;
  final bool isError;

  const AtlasMcpCallResult({required this.data, this.isError = false});

  Map<String, Object?> toJson() => {
    'content': [
      {
        'type': 'text',
        'text': const JsonEncoder.withIndent('  ').convert(data),
      },
    ],
    'isError': isError,
  };
}

class AtlasMcpAdapter {
  final AtlasAgentService agent;

  AtlasMcpAdapter(this.agent);

  static const _projectIdSchema = {
    'type': 'object',
    'properties': {
      'projectId': {'type': 'string'},
    },
    'required': ['projectId'],
  };

  List<AtlasMcpTool> listTools() => const [
    AtlasMcpTool(
      name: 'list_projects',
      description:
          'List visible Project Atlas projects alphabetically with operational counts.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'includeArchived': {'type': 'boolean'},
        },
      },
    ),
    AtlasMcpTool(
      name: 'get_project_status',
      description: 'Get one project status and operational counts.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'get_project_brief',
      description:
          'Get one project brief with lifecycle, tasks, tags, people, risks, decisions, and registry context.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'get_project_identity',
      description:
          'Resolve one Atlas project to its local registry, repo, GitHub, and capsule identity without mutating anything.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'get_project_capsule_status',
      description:
          'Read project protocol metadata and local evidence availability for one linked project.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'get_project_bootstrap_context',
      description:
          'Return the versioned agent startup packet for one project, combining Atlas state, capsule evidence, queue state, and gaps.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'get_stale_projects',
      description:
          'List projects needing attention because of status or blocked work.',
      inputSchema: {'type': 'object', 'properties': {}},
    ),
    AtlasMcpTool(
      name: 'atlas.workload_snapshot',
      description:
          'Read the deterministic workload planning snapshot across projects. Does not mutate state.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'readiness': {'type': 'string'},
          'actor': {'type': 'string'},
          'risk': {'type': 'string'},
          'size': {'type': 'string'},
          'blockedOnly': {'type': 'boolean'},
          'blocksProgressOnly': {'type': 'boolean'},
          'reviewNeededOnly': {'type': 'boolean'},
          'staleOnly': {'type': 'boolean'},
          'highPriorityOnly': {'type': 'boolean'},
          'limit': {'type': 'integer'},
        },
      },
    ),
    AtlasMcpTool(
      name: 'atlas.project_planning_context',
      description:
          'Read a compact redacted planning packet for one project, including accepted state, workload digest, constraints, verification hints, and recent evidence. Does not mutate state.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'atlas.project_workload',
      description:
          'Read one project workload board, snapshot counts, ready execution candidates, and separate planning candidates.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'readiness': {'type': 'string'},
          'actor': {'type': 'string'},
          'risk': {'type': 'string'},
          'size': {'type': 'string'},
          'blockedOnly': {'type': 'boolean'},
          'blocksProgressOnly': {'type': 'boolean'},
          'reviewNeededOnly': {'type': 'boolean'},
          'staleOnly': {'type': 'boolean'},
          'highPriorityOnly': {'type': 'boolean'},
          'limit': {'type': 'integer'},
        },
        'required': ['projectId'],
      },
    ),
    AtlasMcpTool(
      name: 'atlas.suggest_next_work',
      description:
          'Return deterministic ready execution candidates only. Blocked, decision, context, review, in-progress, and closed items are excluded.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'limit': {'type': 'integer'},
        },
      },
    ),
    AtlasMcpTool(
      name: 'atlas.work_item_context_bundle',
      description:
          'Read one work item with project, stage, notes, documents, media, analyses, and linked LLM queue context.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'workItemId': {'type': 'string'},
        },
        'required': ['workItemId'],
      },
    ),
    AtlasMcpTool(
      name: 'list_agent_proposals',
      description:
          'List recent proposal drafts and review status. Does not approve or apply them.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer'},
        },
      },
    ),
    AtlasMcpTool(
      name: 'preview_local_refresh',
      description:
          'Preview local project refresh actions for a linked registry project.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'atlas.project_reconciliation_preview',
      description:
          'Preview project reconciliation readiness and blockers. Read-only; does not mutate source repositories or Atlas records.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'inspect_git_visibility',
      description:
          'Inspect read-only local git visibility for a linked registry project.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'get_github_remote_status',
      description:
          'Get cached GitHub remote metadata for a linked project without network access.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'refresh_github_remote_status',
      description:
          'Refresh cached GitHub remote metadata using read-only gh api calls.',
      inputSchema: _projectIdSchema,
    ),
    AtlasMcpTool(
      name: 'list_project_enrichment_runs',
      description:
          'List recent Atlas enrichment runs with completeness and finding counts.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer'},
        },
      },
    ),
    AtlasMcpTool(
      name: 'get_project_enrichment_run',
      description:
          'Get one Atlas enrichment run with its exception/completeness findings.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'runId': {'type': 'string'},
        },
        'required': ['runId'],
      },
    ),
    AtlasMcpTool(
      name: 'run_project_enrichment',
      description:
          'Run the Atlas-only local project enrichment workflow. This refreshes Atlas records but does not mutate source repositories.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'refreshLinkedProjects': {'type': 'boolean'},
          'includeSourceDocuments': {'type': 'boolean'},
        },
      },
    ),
    AtlasMcpTool(
      name: 'enqueue_llm_task',
      description:
          'Add a project-scoped task to the durable LLM queue. This only queues work; results must return through reviewable drafts.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'workItemId': {'type': 'string'},
          'title': {'type': 'string'},
          'objective': {'type': 'string'},
          'priority': {'type': 'string'},
          'context': {'type': 'object'},
          'createdBy': {'type': 'string'},
        },
        'required': ['projectId', 'title', 'objective'],
      },
    ),
    AtlasMcpTool(
      name: 'list_llm_tasks',
      description:
          'List durable LLM queue tasks, optionally filtered by project or status.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'status': {'type': 'string'},
          'limit': {'type': 'integer'},
        },
      },
    ),
    AtlasMcpTool(
      name: 'get_llm_task',
      description: 'Get one durable LLM queue task by ID.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string'},
        },
        'required': ['taskId'],
      },
    ),
    AtlasMcpTool(
      name: 'get_llm_task_bootstrap',
      description:
          'Get a queued LLM task plus its project bootstrap context for worker startup. Does not claim or mutate the task.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string'},
          'projectId': {'type': 'string'},
        },
        'required': ['taskId'],
      },
    ),
    AtlasMcpTool(
      name: 'claim_llm_task',
      description:
          'Lease the next pending LLM queue task, or a specific task, for a worker.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string'},
          'workerId': {'type': 'string'},
          'leaseMinutes': {'type': 'integer'},
        },
        'required': ['workerId'],
      },
    ),
    AtlasMcpTool(
      name: 'complete_llm_task',
      description:
          'Mark an LLM queue task complete. Optional proposalBody creates a reviewable Atlas draft; it does not directly mutate project records.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string'},
          'workerId': {'type': 'string'},
          'leaseAttempt': {'type': 'integer'},
          'result': {'type': 'object'},
          'proposalTitle': {'type': 'string'},
          'proposalBody': {'type': 'string'},
        },
        'required': ['taskId', 'workerId', 'leaseAttempt', 'result'],
      },
    ),
    AtlasMcpTool(
      name: 'fail_llm_task',
      description: 'Mark an LLM queue task failed with an error payload.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string'},
          'workerId': {'type': 'string'},
          'leaseAttempt': {'type': 'integer'},
          'error': {'type': 'string'},
          'result': {'type': 'object'},
        },
        'required': ['taskId', 'workerId', 'leaseAttempt', 'error'],
      },
    ),
    AtlasMcpTool(
      name: 'propose_status_change',
      description:
          'Create a reviewable status-change proposal draft. Does not apply the change.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'status': {'type': 'string'},
          'reason': {'type': 'string'},
        },
        'required': ['projectId', 'status'],
      },
    ),
    AtlasMcpTool(
      name: 'propose_task_update',
      description:
          'Create a reviewable task create/update proposal draft. Does not apply the change.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'workItemId': {'type': 'string'},
          'title': {'type': 'string'},
          'description': {'type': 'string'},
          'status': {'type': 'string'},
          'priority': {'type': 'string'},
          'dueAt': {'type': 'string'},
          'blockedReason': {'type': 'string'},
          'tagNames': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['projectId', 'title'],
      },
    ),
    AtlasMcpTool(
      name: 'propose_manifest_update',
      description:
          'Create a reviewable project manifest update proposal draft. Does not apply the change.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'fields': {'type': 'object'},
          'reason': {'type': 'string'},
        },
        'required': ['projectId', 'fields'],
      },
    ),
    AtlasMcpTool(
      name: 'record_validation_run',
      description:
          'Create a reviewable validation-run record proposal draft. Does not apply the record.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'command': {'type': 'string'},
          'passed': {'type': 'boolean'},
          'exitCode': {'type': 'integer'},
          'summary': {'type': 'string'},
          'logExcerpt': {'type': 'string'},
        },
        'required': ['projectId', 'command', 'passed'],
      },
    ),
    AtlasMcpTool(
      name: 'record_handoff',
      description:
          'Create a reviewable handoff proposal draft. Does not create the handoff until approved in Atlas.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'title': {'type': 'string'},
          'body': {'type': 'string'},
        },
        'required': ['projectId', 'title', 'body'],
      },
    ),
    AtlasMcpTool(
      name: 'propose_closeout',
      description:
          'Create a reviewable agent closeout proposal with validation, git, packet, and next-action evidence. Does not apply the closeout.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'projectId': {'type': 'string'},
          'runId': {'type': 'string'},
          'runState': {'type': 'string'},
          'summary': {'type': 'string'},
          'scope': {'type': 'object'},
          'changedFiles': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'validation': {
            'type': 'array',
            'items': {'type': 'object'},
          },
          'capsuleDoctor': {'type': 'object'},
          'packetPaths': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'gitState': {'type': 'object'},
          'commitRecommendation': {'type': 'string'},
          'risks': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'overrides': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'nextAction': {'type': 'string'},
        },
        'required': ['projectId', 'summary'],
      },
    ),
  ];

  Future<AtlasMcpCallResult> callTool(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    try {
      return AtlasMcpCallResult(data: await _dispatch(name, arguments));
    } on AtlasLlmTaskTransitionException catch (error) {
      return AtlasMcpCallResult(
        data: {...error.toJson(), 'tool': name},
        isError: true,
      );
    } on AtlasProposalConflict catch (error) {
      return AtlasMcpCallResult(
        data: {...error.toJson(), 'tool': name},
        isError: true,
      );
    } catch (error) {
      return AtlasMcpCallResult(
        data: {'error': error.toString(), 'tool': name},
        isError: true,
      );
    }
  }

  Future<Object?> _dispatch(String name, Map<String, Object?> args) async {
    return switch (name) {
      'list_projects' => (await agent.listProjects(
        includeArchived: _bool(args, 'includeArchived') ?? true,
      )).map((project) => project.toJson()).toList(),
      'get_project_status' => (await agent.getProjectStatus(
        _requiredString(args, 'projectId'),
      ))?.toJson(),
      'get_project_brief' => (await agent.getProjectBrief(
        _requiredString(args, 'projectId'),
      ))?.toJson(),
      'get_project_identity' => (await agent.getProjectIdentity(
        _requiredString(args, 'projectId'),
      ))?.toJson(),
      'get_project_capsule_status' => (await agent.getProjectCapsuleStatus(
        _requiredString(args, 'projectId'),
      ))?.toJson(),
      'get_project_bootstrap_context' =>
        (await agent.getProjectBootstrapContext(
          _requiredString(args, 'projectId'),
        ))?.toJson(),
      'get_stale_projects' =>
        (await agent.getStaleProjects())
            .map((project) => project.toJson())
            .toList(),
      'atlas.workload_snapshot' => (await agent.workloadSnapshot(
        filters: _workloadFilters(args),
        suggestionLimit: _int(args, 'limit') ?? 5,
      )).toJson(),
      'atlas.project_planning_context' =>
        (await agent.getProjectPlanningContext(
          _requiredString(args, 'projectId'),
        ))?.toJson(),
      'atlas.project_workload' => (await agent.projectWorkload(
        _requiredString(args, 'projectId'),
        filters: _workloadFilters(args),
        suggestionLimit: _int(args, 'limit') ?? 5,
      )).toJson(),
      'atlas.suggest_next_work' => await agent.suggestNextWork(
        projectId: _string(args, 'projectId'),
        limit: _int(args, 'limit') ?? 5,
      ),
      'atlas.work_item_context_bundle' => await agent.workItemContextBundle(
        _requiredString(args, 'workItemId'),
      ),
      'list_agent_proposals' => (await agent.listRecentAgentProposalReviews(
        limit: _int(args, 'limit') ?? 50,
      )).map((proposal) => proposal.toJson()).toList(),
      'preview_local_refresh' => _refreshPreviewToJson(
        await agent.previewLocalRefresh(_requiredString(args, 'projectId')),
      ),
      'atlas.project_reconciliation_preview' =>
        (await agent.previewProjectReconciliation(
          _requiredString(args, 'projectId'),
        )).toJson(),
      'inspect_git_visibility' => _gitReportToJson(
        await agent.inspectGitVisibility(_requiredString(args, 'projectId')),
      ),
      'get_github_remote_status' => (await agent.getGithubRemoteStatus(
        _requiredString(args, 'projectId'),
      ))?.toJson(),
      'refresh_github_remote_status' => (await agent.refreshGithubRemoteStatus(
        _requiredString(args, 'projectId'),
      )).toJson(),
      'list_project_enrichment_runs' => (await agent.listProjectEnrichmentRuns(
        limit: _int(args, 'limit') ?? 20,
      )).map((run) => run.toJson()).toList(),
      'get_project_enrichment_run' => await agent.getProjectEnrichmentRun(
        _requiredString(args, 'runId'),
      ),
      'run_project_enrichment' => (await agent.runProjectEnrichment(
        refreshLinkedProjects: _bool(args, 'refreshLinkedProjects') ?? true,
        includeSourceDocuments: _bool(args, 'includeSourceDocuments') ?? true,
        refreshSummaries: false,
      )).toJson(),
      'enqueue_llm_task' => (await agent.enqueueLlmTask(
        projectId: _requiredString(args, 'projectId'),
        workItemId: _string(args, 'workItemId'),
        title: _requiredString(args, 'title'),
        objective: _requiredString(args, 'objective'),
        priority: _string(args, 'priority') ?? 'normal',
        context: _objectMap(args['context']),
        createdBy: _string(args, 'createdBy') ?? 'mcp',
      )).toJson(),
      'list_llm_tasks' => (await agent.listLlmTasks(
        projectId: _string(args, 'projectId'),
        status: _string(args, 'status'),
        limit: _int(args, 'limit') ?? 50,
      )).map((task) => task.toJson()).toList(),
      'get_llm_task' => await agent.getLlmTaskDetail(
        _requiredString(args, 'taskId'),
      ),
      'get_llm_task_bootstrap' => (await agent.getLlmTaskBootstrap(
        _requiredString(args, 'taskId'),
        projectId: _string(args, 'projectId'),
      )).toJson(),
      'claim_llm_task' => (await agent.claimLlmTask(
        taskId: _string(args, 'taskId'),
        workerId: _requiredString(args, 'workerId'),
        leaseMinutes: _int(args, 'leaseMinutes') ?? 60,
      ))?.toJson(),
      'complete_llm_task' => (await agent.completeLlmTask(
        taskId: _requiredString(args, 'taskId'),
        workerId: _requiredString(args, 'workerId'),
        leaseAttempt: _requiredInt(args, 'leaseAttempt'),
        result: _objectMap(args['result']),
        proposalTitle: _string(args, 'proposalTitle'),
        proposalBody: _string(args, 'proposalBody'),
      )).toJson(),
      'fail_llm_task' => (await agent.failLlmTask(
        taskId: _requiredString(args, 'taskId'),
        workerId: _requiredString(args, 'workerId'),
        leaseAttempt: _requiredInt(args, 'leaseAttempt'),
        error: _requiredString(args, 'error'),
        result: _objectMap(args['result']),
      )).toJson(),
      'propose_status_change' => (await agent.proposeStatusChange(
        projectId: _requiredString(args, 'projectId'),
        status: _requiredString(args, 'status'),
        reason: _string(args, 'reason'),
      )).toJson(),
      'propose_task_update' => (await agent.proposeTaskUpdate(
        projectId: _requiredString(args, 'projectId'),
        workItemId: _string(args, 'workItemId'),
        title: _requiredString(args, 'title'),
        description: _string(args, 'description'),
        status: _string(args, 'status') ?? 'next',
        priority: _string(args, 'priority') ?? 'normal',
        dueAt: _date(args, 'dueAt'),
        blockedReason: _string(args, 'blockedReason'),
        tagNames: _stringList(args, 'tagNames'),
      )).toJson(),
      'propose_manifest_update' => (await agent.proposeManifestUpdate(
        projectId: _requiredString(args, 'projectId'),
        fields: _objectMap(args['fields']),
        reason: _string(args, 'reason'),
      )).toJson(),
      'record_validation_run' => (await agent.recordValidationRun(
        projectId: _requiredString(args, 'projectId'),
        command: _requiredString(args, 'command'),
        passed: _requiredBool(args, 'passed'),
        exitCode: _int(args, 'exitCode'),
        summary: _string(args, 'summary'),
        logExcerpt: _string(args, 'logExcerpt'),
      )).toJson(),
      'record_handoff' => (await agent.recordHandoff(
        projectId: _requiredString(args, 'projectId'),
        title: _requiredString(args, 'title'),
        body: _requiredString(args, 'body'),
      )).toJson(),
      'propose_closeout' => (await agent.proposeCloseout(
        projectId: _requiredString(args, 'projectId'),
        runId: _string(args, 'runId'),
        runState: _string(args, 'runState'),
        summary: _requiredString(args, 'summary'),
        scope: _objectMap(args['scope']),
        changedFiles: _stringList(args, 'changedFiles'),
        validation: _objectList(args, 'validation'),
        capsuleDoctor: _objectMap(args['capsuleDoctor']),
        packetPaths: _stringList(args, 'packetPaths'),
        gitState: _objectMap(args['gitState']),
        commitRecommendation: _string(args, 'commitRecommendation'),
        risks: _stringList(args, 'risks'),
        overrides: _stringList(args, 'overrides'),
        nextAction: _string(args, 'nextAction'),
      )).toJson(),
      _ => throw ArgumentError('Unknown Atlas MCP tool: $name'),
    };
  }

  Map<String, Object?> _refreshPreviewToJson(LocalProjectRefreshPreview p) => {
    'registryId': p.registryId,
    'projectId': p.projectId,
    'localPath': p.localPath,
    'profile': p.profile,
    'branch': p.branch,
    'headSha': p.headSha,
    'dirtyCount': p.dirtyCount,
    'remoteUrl': p.remoteUrl,
    'observedAt': p.observedAt?.toIso8601String(),
    'warnings': p.warnings,
    'entries': p.entries
        .map(
          (entry) => {
            'status': entry.status,
            'existingTargetId': entry.existingTargetId,
            'shouldApplyByDefault': entry.shouldApplyByDefault,
            'action': {
              'id': entry.action.id,
              'sourceKind': entry.action.sourceKind,
              'sourceKey': entry.action.sourceKey,
              'targetType': entry.action.targetType,
              'title': entry.action.title,
              'detail': entry.action.detail,
              'fingerprint': entry.action.fingerprint,
              'payload': entry.action.payload,
            },
          },
        )
        .toList(),
  };

  Map<String, Object?> _gitReportToJson(LocalGitVisibilityReport report) => {
    'requestedPath': report.requestedPath,
    'gitRoot': report.gitRoot,
    'branch': report.branch,
    'headSha': report.headSha,
    'remoteUrl': report.remoteUrl,
    'comparisonRef': report.comparisonRef,
    'inspectedAt': report.inspectedAt.toIso8601String(),
    'localTrackedCount': report.localTrackedCount,
    'remoteTrackedCount': report.remoteTrackedCount,
    'localOnlyTrackedPaths': report.localOnlyTrackedPaths,
    'remoteOnlyTrackedPaths': report.remoteOnlyTrackedPaths,
    'changedTrackedPaths': report.changedTrackedPaths,
    'untrackedPaths': report.untrackedPaths,
    'ignoredPaths': report.ignoredPaths,
    'gitignorePatterns': report.gitignorePatterns,
    'suggestedIgnoreEntries': report.suggestedIgnoreEntries,
    'warnings': report.warnings,
  };

  String _requiredString(Map<String, Object?> args, String key) {
    final value = _string(args, key);
    if (value == null) throw ArgumentError('Missing required string: $key');
    return value;
  }

  bool _requiredBool(Map<String, Object?> args, String key) {
    final value = _bool(args, key);
    if (value == null) throw ArgumentError('Missing required boolean: $key');
    return value;
  }

  int _requiredInt(Map<String, Object?> args, String key) {
    final value = _int(args, key);
    if (value == null) throw ArgumentError('Missing required integer: $key');
    return value;
  }

  String? _string(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value == null) return null;
    final trimmed = '$value'.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool? _bool(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is bool) return value;
    if (value is String) {
      return switch (value.trim().toLowerCase()) {
        'true' || '1' || 'yes' => true,
        'false' || '0' || 'no' => false,
        _ => null,
      };
    }
    return null;
  }

  int? _int(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  DateTime? _date(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  List<String> _stringList(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is Iterable) {
      return value
          .map((item) => '$item'.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    final single = _string(args, key);
    return single == null ? const [] : [single];
  }

  WorkloadFilters _workloadFilters(Map<String, Object?> args) =>
      WorkloadFilters(
        projectId: _string(args, 'projectId'),
        readiness: _string(args, 'readiness'),
        actor: _string(args, 'actor'),
        risk: _string(args, 'risk'),
        size: _string(args, 'size'),
        blockedOnly: _bool(args, 'blockedOnly') ?? false,
        blocksProgressOnly: _bool(args, 'blocksProgressOnly') ?? false,
        reviewNeededOnly: _bool(args, 'reviewNeededOnly') ?? false,
        staleOnly: _bool(args, 'staleOnly') ?? false,
        highPriorityOnly: _bool(args, 'highPriorityOnly') ?? false,
      );

  Map<String, Object?> _objectMap(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, value) => MapEntry('$key', value));
  }

  List<Map<String, Object?>> _objectList(
    Map<String, Object?> args,
    String key,
  ) {
    final value = args[key];
    if (value is Iterable) {
      return value
          .whereType<Map>()
          .map((entry) => entry.map((key, value) => MapEntry('$key', value)))
          .toList();
    }
    final single = _objectMap(value);
    return single.isEmpty ? const [] : [single];
  }
}
